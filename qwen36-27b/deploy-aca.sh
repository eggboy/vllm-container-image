#!/usr/bin/env bash
# =============================================================================
# deploy-aca.sh — Deploy Qwen3.6-27B-FP8 on Azure Container Apps Serverless GPU
#
# NOTE ON GPU CHOICE (H100 vs A100):
#   Azure Container Apps Serverless GPU does NOT offer an H100 workload profile
#   in any region — the only Consumption GPU profiles available are:
#     - Consumption-GPU-NC8as-T4  (16 GB, too small for a 27B model)
#     - Consumption-GPU-NC24-A100 (80 GB)
#   Qwen3.6-27B-FP8 (~28 GB weights) therefore runs on A100, which is the
#   target the Dockerfile is optimized for. If true H100 is required, it must
#   be hosted on AKS (NC H100 v5) rather than ACA.
#
# Prerequisites:
#   - Azure CLI logged in (az login)
#   - GPU quota approved for Consumption-GPU-NC24-A100
#   - Image already pushed to ACR: crjay.azurecr.io/qwen36-27b-vllm:latest
#
# Usage:
#   chmod +x deploy-aca.sh && ./deploy-aca.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — adjust these as needed
# ---------------------------------------------------------------------------
RESOURCE_GROUP="rg-qwen36-27b"
LOCATION="eastus"
ENVIRONMENT_NAME="aca-env-qwen36-27b"
CONTAINER_APP_NAME="qwen36-27b"
ACR_NAME="crjay"
IMAGE="${ACR_NAME}.azurecr.io/qwen36-27b-vllm:latest"
WORKLOAD_PROFILE_NAME="gpu-a100"
WORKLOAD_PROFILE_TYPE="Consumption-GPU-NC24-A100"

echo "=== Creating Resource Group ==="
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

echo "=== Creating Container Apps Environment ==="
az containerapp env create \
    --name "$ENVIRONMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

echo "=== Adding GPU Workload Profile (A100) ==="
az containerapp env workload-profile add \
    --name "$ENVIRONMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --workload-profile-name "$WORKLOAD_PROFILE_NAME" \
    --workload-profile-type "$WORKLOAD_PROFILE_TYPE"

echo "=== Enabling Artifact Streaming on ACR (faster pull of the ~30GB image) ==="
az acr artifact-streaming create \
    --registry "$ACR_NAME" \
    --image "qwen36-27b-vllm:latest" 2>/dev/null || \
    echo "  (Artifact streaming may already be enabled or not supported on this SKU)"

echo "=== Creating Container App ==="
az containerapp create \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --environment "$ENVIRONMENT_NAME" \
    --image "$IMAGE" \
    --cpu 24 \
    --memory 220Gi \
    --target-port 8000 \
    --ingress external \
    --min-replicas 1 \
    --max-replicas 1 \
    --registry-server "${ACR_NAME}.azurecr.io" \
    --workload-profile-name "$WORKLOAD_PROFILE_NAME" \
    --output none

echo "=== Applying Startup/Liveness/Readiness Probes (YAML) ==="
# vLLM needs a generous startup budget (~21 min) to load FP8 weights and run
# torch.compile for the hybrid GDN backend before /health returns 200.
az containerapp update \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --yaml "$(dirname "$0")/containerapp-probe.yaml" \
    --output none

echo "=== Deployment Complete ==="
FQDN=$(az containerapp show \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.configuration.ingress.fqdn" \
    --output tsv)

echo ""
echo "Application URL: https://${FQDN}"
echo "Health check:    https://${FQDN}/health"
echo "OpenAI API:      https://${FQDN}/v1/chat/completions"
echo ""
echo "The container takes ~10-20 min to fully start (FP8 load + torch.compile)."
echo "Verify readiness with:"
echo "  curl https://${FQDN}/v1/models"
echo ""
echo "Use as Copilot CLI BYOK endpoint:"
echo "  export COPILOT_LLM_BASE_URL=\"https://${FQDN}/v1\""
echo "  export COPILOT_LLM_MODEL=\"Qwen3.6-27B\""
