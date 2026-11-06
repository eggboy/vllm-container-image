#!/usr/bin/env bash
# =============================================================================
# deploy-aca.sh — Deploy KAT-Coder-V2.5-Dev on Azure Container Apps Serverless GPU
#
# GPU CHOICE: ACA Serverless GPU offers only Consumption-GPU-NC8as-T4 (16 GB)
#   and Consumption-GPU-NC24-A100 (80 GB) — no H100 profile in any region. The
#   AWQ-INT4 build (~24 GB) runs on the A100 profile. See ../../README.md.
#
# Prerequisites:
#   - Azure CLI logged in (az login)
#   - GPU quota approved for Consumption-GPU-NC24-A100
#   - Image pushed to ACR: crjay.azurecr.io/kat-coder-v2-5-dev-vllm:latest
#     Build it with ACR Tasks from the repo root Dockerfile:
#       ../../build-acr.sh kat-coder-v2-5-dev/Dockerfile.vllm.a100
#     (equivalent to: az acr build --registry crjay --image kat-coder-v2-5-dev-vllm:latest
#      --file Dockerfile.vllm.a100 --timeout 7200 .   run inside ../../../kat-coder-v2-5-dev)
#
# Usage:
#   chmod +x deploy-aca.sh && ./deploy-aca.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — adjust these as needed
# ---------------------------------------------------------------------------
RESOURCE_GROUP="rg-kat-coder-v2-5-dev"
LOCATION="eastus"
ENVIRONMENT_NAME="aca-env-kat-coder-v2-5-dev"
CONTAINER_APP_NAME="kat-coder-v2-5-dev"
ACR_NAME="crjay"
IMAGE="${ACR_NAME}.azurecr.io/kat-coder-v2-5-dev-vllm:latest"
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

echo "=== Enabling Artifact Streaming on ACR ==="
az acr artifact-streaming create \
    --registry "$ACR_NAME" \
    --image "kat-coder-v2-5-dev-vllm:latest" 2>/dev/null || \
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

echo "=== Updating Container App with Startup Probe (YAML) ==="
# Export current config, merge probe settings, and update
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
echo "The container takes ~5-15 min to fully start (AWQ load + torch.compile)."
echo "Test with:"
echo "  curl https://${FQDN}/v1/models"
echo ""
echo "Use as Copilot CLI BYOK endpoint:"
echo "  export COPILOT_LLM_BASE_URL=\"https://${FQDN}/v1\""
echo "  export COPILOT_LLM_MODEL=\"KAT-Coder-V2.5-Dev\""
