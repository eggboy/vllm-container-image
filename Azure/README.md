# Azure deployment guide

Everything Azure-specific for this repo lives in this folder. The Dockerfiles
at the repo root are cloud-agnostic; this folder holds how to **build them with
ACR Tasks**, how to **run them on Azure Container Apps (ACA) Serverless GPU**,
and the conventions of the **AKS H100 / MIG inference-gateway deployment**.

```text
Azure/
├── README.md                               ← this guide (all Azure notes)
├── build-acr.sh                            ← az acr build for every image (ACR Tasks)
└── aca/
    ├── qwen38-27b/
    │   ├── deploy-aca.sh                   ← end-to-end ACA deployment (A100)
    │   └── containerapp-probe.yaml         ← startup/liveness/readiness probes
    └── kat-coder-v2-5-dev/
        ├── deploy-aca.sh
        └── containerapp-probe.yaml
```

## 1. Build images with ACR Tasks

`az acr build` builds in Azure (no local Docker daemon or GPU). Every image and
its historical command is encoded in [build-acr.sh](build-acr.sh):

| Repo Dockerfile | Image:tag pushed to `crjay.azurecr.io` | Azure target |
| :-- | :-- | :-- |
| `qwen38-27b/Dockerfile.vllm.a100` | `qwen38-27b-vllm:latest` | ACA Serverless GPU, Consumption-GPU-NC24-A100 |
| `qwen38-27b/Dockerfile.vllm.h100` | `qwen38-27b-vllm:h100` | AKS, NC H100 v5 (full 80 GB GPU) |
| `qwen38-27b/Dockerfile.vllm.h100.mig` | `qwen38-27b-vllm:mig3g` | AKS, H100 MIG 3g.47gb (gateway test, Vendor-B) |
| `kat-coder-v2-5-dev/Dockerfile.vllm.a100` | `kat-coder-v2-5-dev-vllm:latest` | ACA Serverless GPU, Consumption-GPU-NC24-A100 |
| `kat-coder-v2-5-dev/Dockerfile.vllm.h100.mig` | `kat-coder-v2-5-dev-vllm:mig3g` | AKS, H100 MIG 3g.47gb (gateway test, Vendor-A) |
| `mimo-v2-6-distill-qwen-9b/Dockerfile.vllm.h100.mig` | `mimo-v2-6-distill-qwen-9b-vllm:latest` | AKS, H100 MIG 2g.24gb (agent/chat tier) |
| `qwen35-4b/Dockerfile.vllm.h100.mig` | `qwen35-4b-vllm:latest` | AKS, H100 MIG 2g.24gb (fast / inline-completion tier) |
| `glm-ocr/Dockerfile.vllm` | `glm-ocr-vllm:latest` | any |

The command shape, exactly as it used to be printed in each Dockerfile header
(run inside the model folder; `--file` is relative to the build context):

```bash
az acr build --registry crjay --image qwen38-27b-vllm:latest \
    --file Dockerfile.vllm.a100 --timeout 7200 .
# optional HF token (avoids download rate limits):
az acr build --registry crjay --image qwen38-27b-vllm:latest \
    --file Dockerfile.vllm.a100 --build-arg HF_TOKEN=hf_xxx --timeout 7200 .
```

or, from anywhere:

```bash
Azure/build-acr.sh                                   # all images
Azure/build-acr.sh qwen38-27b/Dockerfile.vllm.a100   # one image (substring filter)
ACR_NAME=myregistry HF_TOKEN=hf_xxx Azure/build-acr.sh kat-coder-v2-5-dev
```

ACR Tasks specifics that shaped the Dockerfiles:

- **`--timeout 7200` always.** The weights (9–31 GB) are downloaded inside the
  build; "large image — keep the long timeout".
- **One image layer per weight shard.** A monolithic 30–40 GB `COPY` layer
  cannot reliably finish the registry push inside the ACR Tasks push-step
  timeout: a single transient chunk failure forces a retry of the WHOLE layer.
  Per-shard layers push concurrently (Docker pushes up to 5 at once) and a
  retry only re-uploads one ~4–5 GB shard. All root Dockerfiles follow this
  (`layers-[0-9].safetensors` groups for Qwen3.8-27B, `model-0000N-of-0000M`
  for the others).
- **No `swapon` in `RUN` steps.** An earlier H100 Dockerfile tried
  `dd … /swapfile && swapon /swapfile` to add swap for the download; ACR Tasks
  builds are unprivileged, so this fails with `Operation not permitted` (and
  would not persist across layers anyway). It was removed.
- **Artifact streaming.** For the ~30 GB ACA images the deploy scripts enable
  `az acr artifact-streaming create --registry crjay --image <image:tag>` so
  Container Apps can start pulling layers on demand; the command is allowed to
  fail ("may already be enabled or not supported on this SKU").

## 2. Azure Container Apps — Serverless GPU

### 2.1 GPU choice (H100 vs A100)

ACA Serverless GPU does **not** offer an H100 workload profile in any region.
The only Consumption GPU profiles are:

| Workload profile type | GPU | Notes |
| :-- | :-- | :-- |
| `Consumption-GPU-NC8as-T4` | T4 16 GB | too small for a 27B model |
| `Consumption-GPU-NC24-A100` | A100 80 GB | **used here**; 24 vCPUs, 220 GiB system memory |

So the ACA images are the `Dockerfile.vllm.a100` variants (FP8 Marlin W8A16
for Qwen3.8-27B-FP8 ~31 GB; AWQ-INT4 experts for KAT-Coder-V2.5-Dev ~24 GB).
If true H100 is required (native FP8 compute), host on **AKS with NC H100 v5**
instead (`Dockerfile.vllm.h100`), see §3.

### 2.2 Prerequisites

- Azure CLI logged in (`az login`)
- GPU quota approved for `Consumption-GPU-NC24-A100`
- Image already pushed to ACR (`crjay.azurecr.io/<image>:latest`, see §1)

### 2.3 What `deploy-aca.sh` does

Both scripts ([qwen38-27b](aca/qwen38-27b/deploy-aca.sh),
[kat-coder-v2-5-dev](aca/kat-coder-v2-5-dev/deploy-aca.sh)) are identical in
shape; configuration is at the top of each file:

| Variable | qwen38-27b | kat-coder-v2-5-dev |
| :-- | :-- | :-- |
| `RESOURCE_GROUP` | `rg-qwen38-27b` | `rg-kat-coder-v2-5-dev` |
| `LOCATION` | `eastus` | `eastus` |
| `ENVIRONMENT_NAME` | `aca-env-qwen38-27b` | `aca-env-kat-coder-v2-5-dev` |
| `CONTAINER_APP_NAME` | `qwen38-27b` | `kat-coder-v2-5-dev` |
| `ACR_NAME` / `IMAGE` | `crjay` / `crjay.azurecr.io/qwen38-27b-vllm:latest` | `crjay` / `crjay.azurecr.io/kat-coder-v2-5-dev-vllm:latest` |
| `WORKLOAD_PROFILE_NAME` / `_TYPE` | `gpu-a100` / `Consumption-GPU-NC24-A100` | same |

Steps (each is one `az` command in the script):

1. `az group create` — resource group in `LOCATION`.
2. `az containerapp env create` — Container Apps environment.
3. `az containerapp env workload-profile add` — adds the `gpu-a100`
   profile of type `Consumption-GPU-NC24-A100` to the environment.
4. `az acr artifact-streaming create` — enables streaming for the image
   (best-effort, see §1).
5. `az containerapp create` with `--cpu 24 --memory 220Gi --target-port 8000
   --ingress external --min-replicas 1 --max-replicas 1 --registry-server
   crjay.azurecr.io --workload-profile-name gpu-a100`.
6. `az containerapp update --yaml containerapp-probe.yaml` — applies the
   startup/liveness/readiness probes (§2.4). vLLM needs a generous startup
   budget (~21 min) to load the weights and run torch.compile for the hybrid
   GDN backend before `/health` returns 200.
7. `az containerapp show … ingress.fqdn` — prints the public URL,
   `/health`, `/v1/chat/completions`, and the Copilot CLI BYOK settings:

   ```bash
   export COPILOT_LLM_BASE_URL="https://<fqdn>/v1"
   export COPILOT_LLM_MODEL="Qwen3.8-27B"        # or KAT-Coder-V2.5-Dev
   ```

   Verify readiness with `curl https://<fqdn>/v1/models`. The container takes
   ~10–20 min (Qwen3.8-27B: FP8 load + torch.compile) or ~5–15 min
   (KAT-Coder: AWQ load + Marlin repacking + torch.compile) to fully start.

Usage: `chmod +x deploy-aca.sh && ./deploy-aca.sh` (the probe YAML is
resolved relative to the script, so keep the two files together).

### 2.4 Probes (`containerapp-probe.yaml`)

Why custom probes: Azure Container Apps does **not** add default probes for GPU
workload profiles. Without an explicit startup probe the platform may kill the
container before the model finishes loading — a premature ("immature")
startup timeout.

What makes start-up slow (vLLM `/health` returns 200 ONLY after the model is
fully loaded and ready):

1. Image pull — the model weights (~31 GB FP8 / ~24 GB AWQ) are baked into the
   image.
2. Weight load into GPU HBM + FP8 Marlin kernel prep (Qwen3.8) / AWQ Marlin
   repacking (KAT).
3. torch.compile + CUDA graph capture for the hybrid Gated DeltaNet backend —
   the long pole; first-run compilation can take several minutes.

Startup budget: `initialDelaySeconds (60) + failureThreshold (60) ×
periodSeconds (20) = 1260 s` ≈ **21 minutes** for both apps (the KAT app used
to run with `60 + 60 × 10 = 660 s` ≈ 11 min when it served the GPTQ build; it
was raised because a new vLLM release compiles from a cold cache).

ACA constraints to remember:

- `initialDelaySeconds` is constrained to the range **[0, 60]**. To extend the
  startup window, increase `periodSeconds` (max **240**) or `failureThreshold`
  — NOT `initialDelaySeconds`.
- Liveness and readiness probes only begin AFTER the startup probe first
  succeeds, so their short `initialDelaySeconds` (10 s) will not kill the
  container during boot. Both use `GET /health:8000`; liveness every 30 s,
  readiness every 10 s, `failureThreshold: 3`.
- The YAML also pins the container resources (`cpu: 24`, `memory: 220Gi`) and
  the image, because `az containerapp update --yaml` replaces the template.

### 2.5 Dockerfile notes that were ACA-specific

These used to sit in the `Dockerfile.vllm.a100` headers and are the reasons
behind the current flags:

- Target: Azure Container Apps Serverless GPU (NVIDIA A100 80GB), profile
  `Consumption-GPU-NC24-A100` — 80 GB HBM2e, 2 TB/s, FP8 KV-cache via software
  quantization, 24 vCPUs / 220 GiB system memory, torch.compile + CUDA graphs
  (default O2 FULL_AND_PIECEWISE), Mamba hybrid `--mamba-cache-mode align` +
  chunked prefill.
- Context is capped at 131072 (128K) "for Copilot BYOK compatibility" even
  though the models support 262K natively (balances concurrency on 80 GB).
- The Docker `HEALTHCHECK` in the image mirrors the ACA startup probe (ACA
  ignores it; the YAML above is authoritative).
- Image labels formerly read "(A100 ACA)"; they are now hardware-only.

## 3. AKS (NC H100 v5) — full GPU and MIG inference-gateway test

### 3.1 Images per node type

| Node / slice | Image | Purpose |
| :-- | :-- | :-- |
| H100 80 GB (whole GPU) | `qwen38-27b-vllm:h100` | "Target: AKS with NVIDIA H100 80GB GPU" — native FP8 serving of Qwen3.8-27B (was `qwen35-coder-27b-vllm:optimized`, Qwen3.5-27B BF16) |
| H100 94 GB, MIG **3g.47gb** (~47 GB visible) | `kat-coder-v2-5-dev-vllm:mig3g` | **Vendor-A** of the A/B test (was `kimi-dev-72b-vllm:latest`, Kimi-Dev-72B AWQ, 8K ctx) |
| H100 94 GB, MIG **3g.47gb** | `qwen38-27b-vllm:mig3g` | **Vendor-B** of the A/B test (was `qwen25-coder-32b-vllm:latest`, Qwen2.5-Coder-32B AWQ) |
| H100 94 GB, MIG **2g.24gb** (~24 GB visible to vLLM) | `mimo-v2-6-distill-qwen-9b-vllm:latest` | **Agent/chat tier** (was `qwen25-coder-7b-vllm:latest`) |
| H100 94 GB, MIG **2g.24gb** | `qwen35-4b-vllm:latest` | **Fast / inline-completion tier** (was `qwen25-coder-1-5b-vllm:latest`) |

### 3.2 The "Kimi-vs-Qwen" inference-gateway test (Option B)

"Option B" = the MIG layout above: two vendor models side by side on 3g.47gb
slices behind one inference gateway, plus two small tiers on 2g.24gb slices.
Historically Vendor-A was Moonshot Kimi-Dev-72B and Vendor-B was Qwen2.5-
Coder-32B; after the 2026-11 model refresh Vendor-A is KAT-Coder-V2.5-Dev
(Kuaishou; Moonshot has shipped nothing self-hostable since Kimi-Dev-72B) and
Vendor-B is Qwen3.8-27B. Image labels formerly ended with
"for the AKS inference-gateway test".

Conventions the Kubernetes manifests (kept outside this repo) rely on:

- **Routing:** `--served-model-name` (`Qwen3.8-27B`, `KAT-Coder-V2.5-Dev`,
  `MiMo-V2.6-Distill-Qwen-9B`, `Qwen3.5-4B`) == the model id a client sends ==
  the value the gateway `HTTPRoute` matches on the `X-Gateway-Model-Name`
  header. Changing a served name means changing the route.
- **Auth:** the images do not set an API key; the runtime Kubernetes
  `Deployment` injects `VLLM_API_KEY` for endpoint auth.
- **Tool calling is mandatory** for GitHub Copilot BYOK (CLI + agent) — every
  image runs with `--enable-auto-tool-choice` and a tool-call parser
  (`qwen3_coder` / `mimo`; the 2024-era images used `hermes`).
- **Context:** 128K, which Copilot BYOK recommends, will NOT fit a 24 GB
  slice — the 2g.24gb tiers serve 32K; use the roomier MIG3g models (Option B)
  for longer context. The 3g.47gb KAT image serves 128K; the 3g.47gb
  Qwen3.8-27B image serves 32K (65536 also starts, with ~1 resident
  full-context sequence).
- **Probes:** same start-up profile as ACA — size the `startupProbe` on
  `GET /health:8000` for ~20 min (e.g. `periodSeconds: 20`,
  `failureThreshold: 60`), then liveness/readiness on the same endpoint.
- **MIG device selection:** pass the MIG UUID (`nvidia-smi -L`) via the
  device plugin / `NVIDIA_VISIBLE_DEVICES`; vLLM sees the slice as one GPU.

## 4. History (previous model generations)

The previous Azure artifacts are in git history at commit `205f601`
(`git show 205f601:<path>`):

| Path at `205f601` | Served |
| :-- | :-- |
| `qwen36-27b/deploy-aca.sh`, `qwen36-27b/containerapp-probe.yaml` | Qwen3.6-27B-FP8 on ACA A100 (`qwen36-27b-vllm:latest`, rg `rg-qwen36-27b`) |
| `qwen36-35b-a3b/deploy-aca.sh`, `qwen36-35b-a3b/containerapp-probe.yaml` | Qwen3.6-35B-A3B GPTQ-Int4 on ACA A100 (`qwen36-35b-a3b-vllm:latest`, 11-min probe budget) |
| `qwen35-27b/Dockerfile.vllm.h100.optimized` | Qwen3.5-27B BF16 on AKS H100 (`qwen35-coder-27b-vllm:optimized`; pinned vLLM 0.6.3 and had the `swapon` step) |
| `kimi-dev-72b/…`, `qwen25-coder-32b/…`, `qwen25-coder-7b/…`, `qwen25-coder-1-5b/…` (`Dockerfile.vllm.h100.mig`) | the previous MIG test images (`*-vllm:latest`) |

The current `Azure/aca/*` files are the renamed, updated successors of the
first two rows (names, weight sizes and probe budgets updated for Qwen3.8-27B
and KAT-Coder-V2.5-Dev); the commands are otherwise unchanged.
