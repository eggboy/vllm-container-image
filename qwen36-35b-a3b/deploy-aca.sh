#!/usr/bin/env bash
# =============================================================================
# deploy-aca.sh — Deploy Qwen3.6-35B-A3B on Azure Container Apps Serverless GPU
#
# Prerequisites:
#   - Azure CLI logged in (az login)
#   - GPU quota approved for Consumption-GPU-NC24-A100
#   - Image pushed to ACR: crjay.azurecr.io/qwen36-35b-a3b-vllm:latest
#
# Usage:
#   chmod +x deploy-aca.sh && ./deploy-aca.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — adjust these as needed
# ---------------------------------------------------------------------------
RESOURCE_GROUP="rg-qwen36-35b-a3b"
LOCATION="eastus"
ENVIRONMENT_NAME="aca-env-qwen36-35b-a3b"
CONTAINER_APP_NAME="qwen36-35b-a3b"
ACR_NAME="crjay"
IMAGE="${ACR_NAME}.azurecr.io/qwen36-35b-a3b-vllm:latest"
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
    --image "qwen36-35b-a3b-vllm:latest" 2>/dev/null || \
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
echo "Test with:"
echo "  curl https://${FQDN}/v1/models"
