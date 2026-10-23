#!/usr/bin/env bash
#
# floci-setup.sh — Bootstrap a local floci-az emulator stack:
#   1. Create an ACR registry resource
#   2. Create an AKS cluster (real k3s mode)
#   3. Fetch a WORKING kubeconfig (real k3s one, not the mock-token one)
#   4. Fix containerd's insecure-registry config so image pulls from the
#      emulated ACR don't fail with "http: server gave HTTP response to
#      HTTPS client"
#   5. Install ingress-nginx
#
# Usage:
#   ./floci-setup.sh                # full setup
#   ./floci-setup.sh acr            # only step 1
#   ./floci-setup.sh aks            # only steps 2-4
#   ./floci-setup.sh ingress        # only step 5
#
# Requires: docker, curl, kubectl, jq (brew install jq)

set -euo pipefail

# ---- Config (edit to match your setup) -------------------------------
MGMT_HOST="http://localhost:4577"
SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000001"
RESOURCE_GROUP="my-rg"
ACR_NAME="myregistry"
AKS_NAME="my-cluster"
KUBECONFIG_PATH="${HOME}/.kube/floci-my-cluster.yaml"   # durable, not /tmp
# -----------------------------------------------------------------------

log()  { echo -e "\033[1;34m[floci-setup]\033[0m $*"; }
err()  { echo -e "\033[1;31m[floci-setup][error]\033[0m $*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { err "'$1' is required but not installed."; exit 1; }
}

setup_acr() {
  log "Creating ACR registry '${ACR_NAME}' in resource group '${RESOURCE_GROUP}'..."
  curl -sf -X PUT \
    "${MGMT_HOST}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}?api-version=2023-01-01-preview" \
    -H "Content-Type: application/json" \
    -d '{"location":"eastus","sku":{"name":"Basic"}}' | jq .

  log "Fetching assigned registry port..."
  REGISTRY_PORT=$(curl -sf \
    "${MGMT_HOST}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}?api-version=2023-01-01-preview" \
    | jq -r '.properties.localPort')
  log "ACR '${ACR_NAME}' is available at localhost:${REGISTRY_PORT}"
  log "  Push example: docker push localhost:${REGISTRY_PORT}/${ACR_NAME}/myapp:latest"
}

setup_aks() {
  log "Creating AKS cluster '${AKS_NAME}' in resource group '${RESOURCE_GROUP}'..."
  curl -sf -X PUT \
    "${MGMT_HOST}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerService/managedClusters/${AKS_NAME}?api-version=2023-01-01-preview" \
    -H "Content-Type: application/json" \
    -d '{
      "location": "eastus",
      "properties": {
        "dnsPrefix": "'"${AKS_NAME}"'-dns",
        "agentPoolProfiles": [{
          "name": "nodepool1",
          "count": 1,
          "vmSize": "Standard_DS2_v2",
          "osType": "Linux",
          "mode": "System"
        }]
      }
    }' | jq .

  log "Polling until provisioningState=Succeeded (can take 30-90s on first run)..."
  for i in $(seq 1 30); do
    STATE=$(curl -sf \
      "${MGMT_HOST}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerService/managedClusters/${AKS_NAME}?api-version=2023-01-01-preview" \
      | jq -r '.properties.provisioningState')
    log "  attempt $i: ${STATE}"
    [ "${STATE}" = "Succeeded" ] && break
    sleep 5
  done
  if [ "${STATE}" != "Succeeded" ]; then
    err "Cluster did not reach Succeeded in time. Check 'docker ps -a | grep aks' and container logs."
    exit 1
  fi

  fetch_kubeconfig
  fix_insecure_registry
}

fetch_kubeconfig() {
  log "Locating the k3s container for '${AKS_NAME}'..."
  AKS_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i aks | head -n1)
  if [ -z "${AKS_CONTAINER}" ]; then
    err "No running AKS/k3s container found (docker ps | grep aks)."
    exit 1
  fi
  log "Found container: ${AKS_CONTAINER}"

  # The management-API's listClusterAdminCredential returns a MOCK token that
  # the real k3s API server rejects. The only valid kubeconfig is the one
  # k3s itself writes inside the container.
  HOST_PORT=$(docker port "${AKS_CONTAINER}" 6443/tcp | cut -d: -f2)
  if [ -z "${HOST_PORT}" ]; then
    err "Could not determine host-published port for 6443 on ${AKS_CONTAINER}."
    exit 1
  fi

  mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
  docker exec "${AKS_CONTAINER}" cat /etc/rancher/k3s/k3s.yaml \
    | sed "s#server: https://127.0.0.1:6443#server: https://localhost:${HOST_PORT}#" \
    > "${KUBECONFIG_PATH}"

  log "Kubeconfig written to ${KUBECONFIG_PATH}"
  log "Run: export KUBECONFIG=${KUBECONFIG_PATH}"

  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl get nodes
}

fix_insecure_registry() {
  log "Configuring containerd to trust the HTTP-only mock registry..."
  AKS_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i aks | head -n1)

  # Adjust this host:port to match your ACR sidecar registry's address as
  # seen from inside the cluster (service DNS name or container name:port).
  local REGISTRY_HOST="floci-az-acr-registry:5000"

  docker exec "${AKS_CONTAINER}" sh -c "cat > /etc/rancher/k3s/registries.yaml" <<EOF
mirrors:
  "${REGISTRY_HOST}":
    endpoint:
      - "http://${REGISTRY_HOST}"
configs:
  "${REGISTRY_HOST}":
    tls:
      insecure_skip_verify: true
EOF

  log "registries.yaml written. Restarting container to apply (containerd reads it at startup)..."
  docker restart "${AKS_CONTAINER}"

  log "Waiting for node to rejoin..."
  sleep 10
  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl get nodes
}

setup_ingress() {
  export KUBECONFIG="${KUBECONFIG_PATH}"
  log "Installing ingress-nginx controller..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/cloud/deploy.yaml

  log "Waiting for ingress-nginx controller pod to be Ready..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s

  log "Done. Reach your app with:"
  log "  kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8081:80"
  log "  curl http://localhost:8081/<your-path>"
}

main() {
  require docker; require curl; require kubectl; require jq

  case "${1:-all}" in
    acr)     setup_acr ;;
    aks)     setup_aks ;;
    ingress) setup_ingress ;;
    all)     setup_acr; setup_aks; setup_ingress ;;
    *) err "Unknown argument: $1 (expected: acr|aks|ingress|all)"; exit 1 ;;
  esac

  log "Setup complete."
}

main "$@"
