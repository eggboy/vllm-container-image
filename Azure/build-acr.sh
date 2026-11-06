#!/usr/bin/env bash
# =============================================================================
# build-acr.sh — Build the vLLM model images with Azure Container Registry
# Tasks (`az acr build`), i.e. in the cloud, without a local Docker daemon or
# GPU. This is the single home of every `az acr build` command that used to be
# printed in the Dockerfile headers.
#
# Why ACR Tasks and why these flags:
#   - The Dockerfiles download the model weights (9–31 GB) inside the build and
#     bake them into the image, so a build takes a long time and needs disk:
#     ALWAYS pass --timeout 7200 (ACR Tasks default is far shorter).
#   - Large images: a monolithic 30–40 GB image layer cannot reliably finish the
#     registry push inside the ACR Tasks push-step timeout — one transient chunk
#     failure forces a retry of the WHOLE layer. The Dockerfiles therefore copy
#     weights as one layer per shard (or ~4 GB shard group): layers push
#     concurrently (Docker pushes up to 5 at once) and a retry only re-uploads
#     one shard. Keep that pattern when adding models.
#   - ACR Tasks builds are unprivileged: a `RUN ... swapon /swapfile` step (an
#     old attempt to add swap for large downloads) fails with "Operation not
#     permitted" and must not be used.
#   - --file is relative to the build context (the model folder), exactly as
#     the historical per-folder commands ran it:
#       az acr build --registry crjay --image <image:tag> \
#           --file <Dockerfile> --timeout 7200 .
#   - Optional Hugging Face token (avoids download rate limits in CI/CD):
#       --build-arg HF_TOKEN=hf_xxx   (set HF_TOKEN in the environment below)
#
# Usage:
#   ./build-acr.sh                          # build every image
#   ./build-acr.sh qwen38-27b/Dockerfile.vllm.a100 kat-coder-v2-5-dev/Dockerfile.vllm.h100.mig
#   ACR_NAME=myregistry HF_TOKEN=hf_xxx ./build-acr.sh qwen35-4b
#   (arguments are substring filters on "<folder>/<Dockerfile>")
# =============================================================================
set -euo pipefail

ACR_NAME="${ACR_NAME:-crjay}"           # registry name (crjay.azurecr.io)
HF_TOKEN="${HF_TOKEN:-}"                # optional Hugging Face token
TIMEOUT="${TIMEOUT:-7200}"              # seconds; keep long — weights are downloaded in-build
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# <model folder>|<Dockerfile inside that folder>|<image:tag>
IMAGES=(
    # Qwen3.8-27B-FP8 — ACA A100 (tag :latest is what Azure/aca/qwen38-27b/deploy-aca.sh pulls)
    "qwen38-27b|Dockerfile.vllm.a100|qwen38-27b-vllm:latest"
    # Qwen3.8-27B-FP8 — AKS, full H100 80GB
    "qwen38-27b|Dockerfile.vllm.h100|qwen38-27b-vllm:h100"
    # Qwen3.8-27B-FP8 — AKS, H100 MIG 3g.47gb slice (inference-gateway test, Vendor-B)
    "qwen38-27b|Dockerfile.vllm.h100.mig|qwen38-27b-vllm:mig3g"
    # KAT-Coder-V2.5-Dev AWQ-INT4 — ACA A100 (tag :latest is what Azure/aca/kat-coder-v2-5-dev/deploy-aca.sh pulls)
    "kat-coder-v2-5-dev|Dockerfile.vllm.a100|kat-coder-v2-5-dev-vllm:latest"
    # KAT-Coder-V2.5-Dev AWQ-INT4 — AKS, H100 MIG 3g.47gb slice (inference-gateway test, Vendor-A)
    "kat-coder-v2-5-dev|Dockerfile.vllm.h100.mig|kat-coder-v2-5-dev-vllm:mig3g"
    # MiMo-V2.6-Distill-Qwen-9B — AKS, H100 MIG 2g.24gb slice (agent/chat tier)
    "mimo-v2-6-distill-qwen-9b|Dockerfile.vllm.h100.mig|mimo-v2-6-distill-qwen-9b-vllm:latest"
    # Qwen3.5-4B — AKS, H100 MIG 2g.24gb slice (fast / inline-completion tier)
    "qwen35-4b|Dockerfile.vllm.h100.mig|qwen35-4b-vllm:latest"
    # GLM-OCR (no historical ACR command existed; added for completeness)
    "glm-ocr|Dockerfile.vllm|glm-ocr-vllm:latest"
)

selected=()
for entry in "${IMAGES[@]}"; do
    IFS='|' read -r dir dockerfile image <<< "$entry"
    key="${dir}/${dockerfile}"
    if [[ $# -eq 0 ]]; then
        selected+=("$entry")
    else
        for filter in "$@"; do
            if [[ "$key" == *"$filter"* ]]; then
                selected+=("$entry")
                break
            fi
        done
    fi
done

if [[ ${#selected[@]} -eq 0 ]]; then
    echo "No image matches: $*" >&2
    echo "Known images:" >&2
    for entry in "${IMAGES[@]}"; do
        IFS='|' read -r dir dockerfile image <<< "$entry"
        echo "  ${dir}/${dockerfile}  ->  ${image}" >&2
    done
    exit 1
fi

for entry in "${selected[@]}"; do
    IFS='|' read -r dir dockerfile image <<< "$entry"
    context="${REPO_ROOT}/${dir}"
    if [[ ! -f "${context}/${dockerfile}" ]]; then
        echo "Missing ${context}/${dockerfile}" >&2
        exit 1
    fi
    echo "=== az acr build: ${dir}/${dockerfile} -> ${ACR_NAME}.azurecr.io/${image} (timeout ${TIMEOUT}s) ==="
    args=(
        --registry "$ACR_NAME"
        --image "$image"
        --file "$dockerfile"
        --timeout "$TIMEOUT"
    )
    if [[ -n "$HF_TOKEN" ]]; then
        args+=(--build-arg "HF_TOKEN=${HF_TOKEN}")
    fi
    az acr build "${args[@]}" "$context"
done

echo "=== Done. Pull with: docker pull ${ACR_NAME}.azurecr.io/<image:tag> ==="
