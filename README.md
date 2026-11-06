# vllm-container-image

Self-contained [vLLM](https://docs.vllm.ai/) serving images for open-weight
coding/agent models. Each image bakes one model's weights into the image (no
runtime download, no volume, no Hugging Face token at run time) and starts an
OpenAI-compatible server on port 8000.

Nothing in the images is tied to a cloud or an orchestrator: they run with
plain Docker, Compose, Kubernetes, or anything that can schedule a container
with an NVIDIA GPU. The only axis the variants differ on is the GPU they are
sized for. Azure-specific material (ACR Tasks builds, Azure Container Apps
deployment scripts and probes, AKS/MIG conventions) lives in
[`Azure/`](Azure/README.md); Google Cloud Run GPU material (Cloud Build configs, deploy presets, validated measurements) lives in [`GCP/`](GCP/README.md).

## Images

| Folder | Model (checkpoint) | License | GPU target | Dockerfile | Context / seqs |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `qwen38-27b/` | [Qwen/Qwen3.8-27B-FP8](https://huggingface.co/Qwen/Qwen3.8-27B-FP8) | Apache-2.0 | 1× A100 80GB | `Dockerfile.vllm.a100` | 128K / 8 |
| | | | 1× H100 80GB | `Dockerfile.vllm.h100` | 128K / 8 |
| | | | H100 MIG 3g.47gb | `Dockerfile.vllm.h100.mig` | 32K / 4 |
| `kat-coder-v2-5-dev/` | [Kwaipilot/KAT-Coder-V2.5-Dev](https://huggingface.co/Kwaipilot/KAT-Coder-V2.5-Dev) via [cyankiwi AWQ-INT4](https://huggingface.co/cyankiwi/KAT-Coder-V2.5-Dev-AWQ-INT4) | Apache-2.0 | 1× A100 80GB | `Dockerfile.vllm.a100` | 128K / 8 |
| | | | H100 MIG 3g.47gb | `Dockerfile.vllm.h100.mig` | 128K / 4 |
| `mimo-v2-6-distill-qwen-9b/` | [XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B) | MIT | H100 MIG 2g.24gb | `Dockerfile.vllm.h100.mig` | 32K / 4 |
| `qwen35-4b/` | [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) | Apache-2.0 | H100 MIG 2g.24gb | `Dockerfile.vllm.h100.mig` | 32K / 8 |
| `glm-ocr/` | [zai-org/GLM-OCR](https://huggingface.co/zai-org/GLM-OCR) | — | any | `Dockerfile.vllm` | — |

Served model names (the `model` field clients send): `Qwen3.8-27B`,
`KAT-Coder-V2.5-Dev`, `MiMo-V2.6-Distill-Qwen-9B`, `Qwen3.5-4B`.

Every Dockerfile header documents the model choice (benchmark evidence), the
memory budget behind each vLLM flag, and the exact `docker build` / `docker
run` commands for that variant. All images run `vllm/vllm-openai:v0.32.0`.

## Build

The build downloads the weights into the image, so allow for the download
size (9–31 GB) and the resulting image size.

```bash
docker build -f qwen38-27b/Dockerfile.vllm.h100 -t qwen38-27b-vllm:h100 qwen38-27b
# optional, avoids Hugging Face rate limits:
docker build --build-arg HF_TOKEN=hf_xxx -f qwen38-27b/Dockerfile.vllm.h100 -t qwen38-27b-vllm:h100 qwen38-27b
```

Weights are copied into the image as several ~4–5 GB layers (one per shard or
shard group) rather than one monolithic layer, so a failed registry push
retries one layer, not the whole model.

To build in Azure Container Registry instead (no local Docker/GPU), use
[`Azure/build-acr.sh`](Azure/build-acr.sh).

## Run

```bash
docker run --gpus all --ipc=host -p 8000:8000 \
    -e VLLM_API_KEY=change-me \
    qwen38-27b-vllm:h100

curl -H "Authorization: Bearer change-me" http://localhost:8000/v1/models
```

- `--ipc=host` (or `--shm-size=8g`): vLLM uses shared memory between its
  processes.
- `VLLM_API_KEY` is optional; without it the endpoint is unauthenticated.
- MIG variants: pass the slice instead of the whole GPU, e.g.
  `--gpus '"device=MIG-<uuid>"'` (UUIDs from `nvidia-smi -L`).

Coding-agent client example (GitHub Copilot CLI BYOK):

```bash
export COPILOT_LLM_BASE_URL="http://<host>:8000/v1"
export COPILOT_LLM_MODEL="Qwen3.8-27B"
```

## Startup time and health probes

`/health` returns 200 only after the model is fully loaded and ready. The first
start of a container is slow: weight load, torch.compile and CUDA graph
capture for the hybrid Gated DeltaNet backend. Budget:

| Image | First start |
| :-- | :-- |
| Qwen3.8-27B (any variant) | 5–20 min |
| KAT-Coder-V2.5-Dev | 5–15 min |
| MiMo-V2.6-Distill-Qwen-9B | 3–10 min |
| Qwen3.5-4B | 2–8 min |

Each image carries a Docker `HEALTHCHECK` with a matching `--start-period`.
Orchestrators ignore `HEALTHCHECK`, so configure their own probes with the
same budget, e.g. a Kubernetes `startupProbe` on `GET /health:8000` with
`periodSeconds: 20` and `failureThreshold: 60` (~20 min), then liveness and
readiness probes on the same endpoint with short periods. Serverless platforms
that cap `initialDelaySeconds` usually let you extend the window through the
period and failure threshold instead.

## Changing a model's serving parameters

Override the `CMD` at run time; `ENTRYPOINT` is `vllm serve`, so pass the full
argument list:

```bash
docker run --gpus all --ipc=host -p 8000:8000 qwen38-27b-vllm:h100 \
    /model/qwen38-27b --host 0.0.0.0 --port 8000 --served-model-name Qwen3.8-27B \
    --kv-cache-dtype fp8 --language-model-only --max-model-len 65536 ...
```

The per-flag comments in each Dockerfile explain which values are safe to
change on that GPU.
