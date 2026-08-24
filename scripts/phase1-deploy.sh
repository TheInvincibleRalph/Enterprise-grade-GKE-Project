#!/usr/bin/env bash
# Phase 1 — Full deployment orchestrator
# Run from repo root after Phase 0 (GCP project, APIs, impersonation login)
# is complete.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
VAR_FILE="${VAR_FILE:-${TF_DIR}/terraform.tfvars}"

# Auth: Terraform uses Application Default Credentials — the impersonated
# terraform-sa from Phase 0. NO JSON key, NO GOOGLE_APPLICATION_CREDENTIALS
# (that var would override the impersonation; if it's exported, unset it).

usage() {
  cat <<EOF
Usage: $0 [step]

Steps (default: all):
  terraform   Apply GKE infrastructure
  cilium      Install Cilium CNI
  gateway     Install Envoy Gateway + Coraza WAF
  boutique    Deploy Online Boutique demo
  verify      Deploy WireGuard encryption test pods

Environment variables:
  VAR_FILE         Terraform var file (default: infra/terraform/terraform.tfvars)
  BOUTIQUE_HOST    Domain for boutique ingress (e.g. boutique.yourname.dev)
  SKIP_TERRAFORM   Set to 1 to skip terraform apply

Examples:
  cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars
  # Edit terraform.tfvars with your project_id
  $0

  BOUTIQUE_HOST=boutique.yourname.dev $0 boutique
EOF
}

run_terraform() {
  if [[ "${SKIP_TERRAFORM:-0}" == "1" ]]; then
    echo "==> Skipping Terraform (SKIP_TERRAFORM=1)"
    return
  fi

  if [[ ! -f "${VAR_FILE}" ]]; then
    echo "Missing ${VAR_FILE}"
    echo "Copy terraform.tfvars.example to terraform.tfvars and set project_id"
    exit 1
  fi

  echo "==> Phase 1.1: Terraform apply"
  cd "${TF_DIR}"

  # Remote state backend (GCS). Requires the tfstate bucket to exist and the
  # impersonated Terraform SA to have storage access on it. Fall back to local
  # state if the backend is unavailable or backend.hcl is missing.
  if [[ -f "backend.hcl" ]]; then
    echo "==> Initializing GCS state backend (bucket: $(grep bucket backend.hcl | head -1 | awk -F'"' '{print $2}'))"
    terraform init -backend-config=backend.hcl || {
      echo "WARNING: GCS backend init failed (missing storage permission on the tfstate bucket?); falling back to local state"
      terraform init -input=false
    }
  else
    echo "WARNING: backend.hcl missing; using local state"
    terraform init -input=false
  fi

  terraform apply -var-file="${VAR_FILE}" -auto-approve

  echo "==> Configuring kubectl"
  eval "$(terraform output -raw get_credentials_command)"
  cd "${ROOT_DIR}"
}

run_cilium() {
  echo "==> Phase 1.2: Cilium"
  bash "${ROOT_DIR}/scripts/install-cilium.sh"
}

run_gateway() {
  echo "==> Phase 1.3: Envoy Gateway + Coraza WAF"
  bash "${ROOT_DIR}/scripts/install-envoy-gateway.sh"
}

run_boutique() {
  echo "==> Phase 1.4: Online Boutique"
  bash "${ROOT_DIR}/scripts/deploy-boutique.sh"
}

run_verify() {
  echo "==> Phase 1.2 verify: encryption test pods"
  kubectl apply -f "${ROOT_DIR}/kubernetes/cilium/encryption-test.yaml"
  kubectl wait --for=condition=Ready pod/netshoot-a -n test-a --timeout=120s
  kubectl wait --for=condition=Ready pod/netshoot-b -n test-b --timeout=120s
  echo "Pods ready. Test connectivity:"
  echo "  kubectl exec -n test-a netshoot-a -- curl -s http://\$(kubectl get pod netshoot-b -n test-b -o jsonpath='{.status.podIP}')"
}

STEP="${1:-all}"

case "${STEP}" in
  terraform) run_terraform ;;
  cilium)    run_cilium ;;
  gateway)   run_gateway ;;
  boutique)  run_boutique ;;
  verify)    run_verify ;;
  all)
    run_terraform
    run_cilium
    run_gateway
    run_boutique
    run_verify
    echo ""
    echo "==> Phase 1 complete"
    echo "Next steps:"
    echo "  1. Point Cloudflare DNS to the Envoy Gateway LB IP"
    echo "  2. BOUTIQUE_HOST=boutique.yourdomain.dev ./scripts/deploy-boutique.sh"
    echo "  3. ./scripts/waf-test.sh https://boutique.yourdomain.dev"
    echo "  4. ./scripts/zap-scan.sh https://boutique.yourdomain.dev"
    ;;
  -h|--help) usage ;;
  *)
    echo "Unknown step: ${STEP}"
    usage
    exit 1
    ;;
esac
