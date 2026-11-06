#!/usr/bin/env bash
# =============================================================================
# deploy-cloudrun.sh — Deploy one of the vLLM model images to Cloud Run with a GPU.
#
# Usage:
#   ./deploy-cloudrun.sh <preset> [deploy|delete|describe|url]
#   presets: qwen35-4b-l4 | mimo-9b-l4 | qwen38-27b-rtx | kat-coder-rtx
#   env:     PROJECT (required), REGION (default asia-southeast1),
#            REPO (default vllm), SERVICE_SUFFIX (default ""),
#            API_KEY_SECRET (optional Secret Manager name; when set, deploys
#            with --no-invoker-iam-check + VLLM_API_KEY from Secret Manager so
#            OpenAI/Antigravity clients authenticate directly with a static key)
#
# Cloud Run GPU facts encoded below (docs, 2026-11):
#   - one GPU per instance; nvidia-rtx-pro-6000 (96 GB) needs >= 20 CPU / 80 GiB,
#     nvidia-l4 (24 GB) needs >= 4 CPU / 16 GiB (8 / 32 recommended)
#   - instance-based billing is mandatory (--no-cpu-throttling)
#   - startup probe: failureThreshold x periodSeconds <= 1800 s on GPU
#   - zonal redundancy off = cheaper + quota auto-granted (3 GPUs/region)
#   - images must be in Artifact Registry (built by cloudbuild-*.yaml)
# =============================================================================
set -euo pipefail

PRESET="${1:?preset required}"
ACTION="${2:-deploy}"
PROJECT="${PROJECT:?set PROJECT}"
REGION="${REGION:-asia-southeast1}"
REPO="${REPO:-vllm}"
AR="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}"

case "$PRESET" in
  qwen35-4b-l4)
    SERVICE="qwen35-4b${SERVICE_SUFFIX:-}"
    IMAGE="${AR}/qwen35-4b-vllm:mig2g"
    GPU_TYPE="nvidia-l4"; CPU=8; MEMORY=32Gi; CONCURRENCY=8
    ARGS=""   # image CMD as-is (32K ctx, 8 seqs, thinking off)
    ;;
  mimo-9b-l4)
    SERVICE="mimo-v2-6-distill-qwen-9b${SERVICE_SUFFIX:-}"
    IMAGE="${AR}/mimo-v2-6-distill-qwen-9b-vllm:mig2g"
    GPU_TYPE="nvidia-l4"; CPU=8; MEMORY=32Gi; CONCURRENCY=4
    ARGS=""   # image CMD as-is (32K ctx, 4 seqs)
    ;;
  qwen38-27b-rtx)
    SERVICE="qwen38-27b${SERVICE_SUFFIX:-}"
    IMAGE="${AR}/qwen38-27b-vllm:h100"
    GPU_TYPE="nvidia-rtx-pro-6000"; CPU=20; MEMORY=80Gi; CONCURRENCY=16
    # 96 GB VRAM (~1.71M KV tokens): run full 262K native context (coding agents like
    # Antigravity send max_completion_tokens=65535 + ~22K system/tool prompt).
    ARGS="/model/qwen38-27b,--host,0.0.0.0,--port,8000,--tensor-parallel-size,1,--trust-remote-code,\
--gpu-memory-utilization,0.92,--max-model-len,262144,--dtype,auto,--kv-cache-dtype,fp8,\
--language-model-only,--enable-prefix-caching,--mamba-cache-mode,align,--enable-chunked-prefill,\
--max-num-batched-tokens,8384,--performance-mode,interactivity,--enable-auto-tool-choice,\
--reasoning-parser,qwen3,--tool-call-parser,qwen3_coder,--max-num-seqs,16,--served-model-name,Qwen3.8-27B"
    ;;
  kat-coder-rtx)
    SERVICE="kat-coder-v2-5-dev${SERVICE_SUFFIX:-}"
    IMAGE="${AR}/kat-coder-v2-5-dev-vllm:a100"
    GPU_TYPE="nvidia-rtx-pro-6000"; CPU=20; MEMORY=80Gi; CONCURRENCY=16
    ARGS="/model/kat-coder-v2-5-dev,--host,0.0.0.0,--port,8000,--tensor-parallel-size,1,--trust-remote-code,\
--quantization,compressed-tensors,--dtype,float16,--language-model-only,--gpu-memory-utilization,0.92,\
--max-model-len,131072,--kv-cache-dtype,fp8,--enable-prefix-caching,--mamba-cache-mode,align,\
--enable-chunked-prefill,--max-num-batched-tokens,8384,--enable-auto-tool-choice,--reasoning-parser,qwen3,\
--tool-call-parser,qwen3_coder,--max-num-seqs,16,--served-model-name,KAT-Coder-V2.5-Dev"
    ;;
  *) echo "unknown preset: $PRESET" >&2; exit 1 ;;
esac

case "$ACTION" in
  deploy)
    cmd=(gcloud run deploy "$SERVICE"
      --project "$PROJECT" --region "$REGION"
      --image "$IMAGE"
      --execution-environment gen2
      --gpu 1 --gpu-type "$GPU_TYPE" --no-gpu-zonal-redundancy
      --cpu "$CPU" --memory "$MEMORY" --no-cpu-throttling
      --port 8000 --timeout 3600 --concurrency "$CONCURRENCY"
      --min-instances 0 --max-instances 1
      --startup-probe "httpGet.path=/health,httpGet.port=8000,periodSeconds=30,timeoutSeconds=10,failureThreshold=60"
      --labels "repo=vllm-container-image,test=cloud-run-gpu")
    if [[ -n "${API_KEY_SECRET:-}" ]]; then
      cmd+=(--no-invoker-iam-check --set-secrets "VLLM_API_KEY=${API_KEY_SECRET}:latest")
    else
      cmd+=(--no-allow-unauthenticated)
    fi
    if [[ -n "$ARGS" ]]; then cmd+=(--args "$ARGS"); fi
    echo "+ ${cmd[*]}"
    "${cmd[@]}"
    ;;
  delete)
    gcloud run services delete "$SERVICE" --project "$PROJECT" --region "$REGION" --quiet
    ;;
  describe)
    gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION"
    ;;
  url)
    gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" --format "value(status.url)"
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 1 ;;
esac
