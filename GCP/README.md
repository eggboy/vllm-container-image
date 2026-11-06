# Google deployment

The Dockerfiles at the repo root are unchanged; this folder builds them with Cloud Build into Artifact Registry and deploys them to **Cloud Run with GPUs**
(NVIDIA RTX PRO 6000 Blackwell 96 GB, or NVIDIA L4 24 GB).

```text
GCP/
├── README.md                          ← this guide + validated test results
├── cloudbuild-<model>.yaml            ← Cloud Build config per image (E2_HIGHCPU_32, 500 GB disk, 2 h timeout)
├── deploy-cloudrun.sh                 ← gcloud run deploy presets (GPU type, CPU/RAM, probes, vLLM args)
├── vllm_probe.py                      ← stdlib-only smoke test / benchmark client
└── results/probe-*.json               ← measurements from the 2026-11-06 validation run
```

## 1. Build (Cloud Build → Artifact Registry)

```bash
PROJECT=<project>; REGION=asia-southeast1
gcloud artifacts repositories create vllm --repository-format=docker --location=$REGION --project=$PROJECT
# from the repo root; the build context is the model folder, --file is relative to it
gcloud builds submit --async --project=$PROJECT --region=$REGION \
    --config=GCP/cloudbuild-qwen38-27b.yaml qwen38-27b
```

| Config | Dockerfile | Image:tag | Build time (2026-11-06) |
| :-- | :-- | :-- | :-- |
| `cloudbuild-qwen35-4b.yaml` | `qwen35-4b/Dockerfile.vllm.h100.mig` | `qwen35-4b-vllm:mig2g` | 17 min |
| `cloudbuild-qwen38-27b.yaml` | `qwen38-27b/Dockerfile.vllm.h100` | `qwen38-27b-vllm:h100` | 20.5 min |
| `cloudbuild-kat-coder-v2-5-dev.yaml` | `kat-coder-v2-5-dev/Dockerfile.vllm.a100` | `kat-coder-v2-5-dev-vllm:a100` | 18.5 min |
| `cloudbuild-mimo-v2-6-distill-qwen-9b.yaml` | `mimo-v2-6-distill-qwen-9b/Dockerfile.vllm.h100.mig` | `mimo-v2-6-distill-qwen-9b-vllm:mig2g` | 13.5 min |

Notes that cost us a retry:

- `${PROJECT_ID}` inside a user substitution (`_IMAGE`) is only expanded with `options.dynamicSubstitutions: true` (set in every config).
- Cloud Build runs as the Compute Engine default service account in these projects; it needs `roles/run.builder` or
  `roles/cloudbuild.builds.builder`, otherwise the source upload fails with `storage.objects.get` 403.
- `E2_HIGHCPU_32` + `diskSizeGb: 500` + `timeout: 7200s` per the Cloud Run GPU best-practices page; the 31 GB download + 40 GB push finished in ~20 min.
  Regional builds run 2 at a time by default; the others queue.

## 2. Deploy / test / tear down

```bash
PROJECT=<project> GCP/deploy-cloudrun.sh qwen38-27b-rtx deploy     # blocks until /health passes (≈7 min)
TOKEN=$(gcloud auth print-identity-token)
python3 GCP/vllm_probe.py --base-url "$(PROJECT=<project> GCP/deploy-cloudrun.sh qwen38-27b-rtx url)" \
    --model Qwen3.8-27B --bearer "$TOKEN" --concurrency 16 --max-tokens 600
PROJECT=<project> GCP/deploy-cloudrun.sh qwen38-27b-rtx delete
```

Presets: `qwen35-4b-l4`, `mimo-9b-l4` (L4: 8 vCPU / 32 GiB), `qwen38-27b-rtx`, `kat-coder-rtx` (RTX PRO 6000: 20 vCPU / 80 GiB — the platform minimum). Every
preset uses: `--execution-environment gen2`, `--no-cpu-throttling` (instance-based billing, mandatory for GPUs), `--no-gpu-zonal-redundancy`
(cheaper; quota auto-granted), `--port 8000 --timeout 3600`, `--max-instances 1`, `--no-allow-unauthenticated`, and a startup probe of
`GET /health` every 30 s × 60 = 1800 s (the GPU maximum). The RTX presets override the image `CMD` with `--args` to raise `--max-num-seqs` to 16 for the
96 GB GPU; the L4 presets run the image `CMD` unchanged.

Auth options in `deploy-cloudrun.sh`:
- **Default (Cloud Run IAM)**: `--no-allow-unauthenticated`; clients send `Authorization: Bearer $(gcloud auth print-identity-token)` (or use
  `gcloud run services proxy`).
- **Static API key (`API_KEY_SECRET=<secret-name>`)**: deploys with `--no-invoker-iam-check --set-secrets VLLM_API_KEY=<secret-name>:latest`. Works even when `iam.allowedPolicyMemberDomains` blocks `allUsers` (as long as `run.managed.requireInvokerIam` is not enforced), allowing OpenAI-compatible clients like Antigravity (`agy`) to connect directly over HTTPS with a static `AGY_LLM_GATEWAY_API_KEY` and zero local proxy or `gcloud` dependency.

## 3. Performance Result

| Model / GPU | Deploy → ready | Weight load | torch.compile | KV pool (vLLM) | Tool call | 1 stream | N streams |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| Qwen3.8-27B-FP8 / **RTX PRO 6000** | **6 m 38 s** | 31 GB in 25 s | 50 s | 56 GiB, **1.71 M tokens, 13× at 128K** | parsed (`read_file`, +reasoning) | 45 tok/s, TTFT 0.13 s | 16 streams: **615 tok/s** aggregate, 39 tok/s each |
| KAT-Coder-V2.5-Dev AWQ / **RTX PRO 6000** | 6 m 55 s | 24 GB in 56 s (Marlin WNA16 MoE) | 19 s | 63 GiB, **6.02 M tokens, 46× at 128K** | parsed | **175 tok/s**, TTFT 0.14 s | 16 streams: **1530 tok/s**, 98 tok/s each |
| MiMo-V2.6-Distill-9B BF16 / L4 | 6 m 43 s | 18 GB in 17 s | 31 s | 1.38 GiB, 73 K tokens, **2.2× at 32K** | parsed, but `arguments` came back `{}` (see below) | 16 tok/s, TTFT 0.34 s | 4 streams: 58 tok/s |
| Qwen3.5-4B BF16 / L4 | 6 m 40 s | 8 GB in 8 s | 30 s | 10.9 GiB, 581 K tokens, 17.7× at 32K | parsed | 29 tok/s, TTFT 0.18 s | 8 streams: 200 tok/s |

Extra checks on the 27B: a 65,701-token prompt answered correctly in 9.9 s (~6.6 K tok/s prefill); a 131,073-token prompt was rejected by vLLM with the
expected 400 (Cloud Run itself imposed no body/time limit). Unauthenticated requests get 403 from Cloud Run before reaching vLLM.

Raw numbers: [results/](results/).

## 4. Findings

1. **The RTX PRO 6000 is the right Cloud Run target for the 27B and KAT images.** 96 GB leaves 56–63 GiB for KV cache — more than the 80 GB A100/H100 — and
   the Blackwell FP8 path runs natively (vLLM picked FlashInfer attention, `CompressedTensorsWNA16MoEMethod` + `MARLIN` for KAT).
2. **Cold start is ~6.5–7 min for every image, not 10–20.** Cloud Run streams the image, so weight loading is network-speed (31 GB in 25 s); the rest is
   Cloud Run provisioning (~3.5 min from deploy to container start) plus vLLM's compile/profiling (~2.5 min). Well inside the 30-min probe cap, so
   scale-to-zero is workable; `min-instances 1` costs ≈ $3.2/h (RTX) or ≈ $1.4/h (L4) at Tier-1 prices.
3. **L4 is only for the small tiers.** MiMo-9B BF16 starts but has 1.38 GiB of KV (2 × 32K sequences) and decodes at 16 tok/s; Qwen3.5-4B is comfortable.
   Neither the 27B nor KAT fits an L4.
4. **MiMo tool-call arguments were empty** with `--tool-call-parser mimo` (name parsed, `arguments: {}`); the Qwen3.5/3.8 and KAT images returned full
   arguments with `qwen3_coder`. Re-test MiMo with `--tool-call-parser qwen3_coder` (same `<function=…><parameter=…>` format) before relying on it
   for agents.

## 5. Antigravity (`agy`) BYOM validation

`Qwen3.8-27B` (`qwen38-27b-rtx`, `--max-model-len 262144`) was also validated end-to-end with **Antigravity CLI `agy` 1.5.2** over the Enterprise Gateway
OpenAI wire protocol (`AGY_LLM_GATEWAY_WIRE_PROTOCOL=openai`) — covering `/v1/models` discovery, streaming reasoning (`--reasoning-parser qwen3`), and a
multi-turn `read_file` → `edit_file` → `run_command` (`unittest`) bug-fix loop (85.6% prefix-cache hit rate). Note: routing non-Google models through the
Enterprise Gateway is client-supported (`wireProtocol: "openai"`), not a Google-supported configuration, and `AGY_LLM_GATEWAY_MODELS` must be left unset
so Tier 3 `/v1/models` discovery populates token limits. Full proxy helper and test logs live in the sibling `antigravity-byom` workspace.

## 6. Not yet done (from the plan)

- Phase 4 cold-start experiments (`--enforce-eager`, compile cache on a Cloud Storage volume, weights on ephemeral disk instead of in the image).
- Phase 5 GPU job (≤ 12 h) running a benchmark harness.
- Copilot CLI BYOK end-to-end through `gcloud run services proxy`.
