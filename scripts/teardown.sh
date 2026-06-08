#!/bin/bash
set -euo pipefail

# Teardown script: removes the GitHub Actions runner registration and destroys
# all AWS infrastructure created by terraform apply.
#
# Each destructive step prompts for confirmation before proceeding.

# --- Configuration ---
# TODO: update if you changed the repo owner
GITHUB_REPO_OWNER="pasiripu"
GITHUB_REPO_NAME="zenith-demo-agent"
GITHUB_REPO="${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}"

KEY_PATH="./infra/zenith-demo-key.pem"
EC2_USER="ec2-user"
RUNNER_DIR="/home/runner/actions-runner"

# --- Helpers ---
info()   { echo "[teardown] INFO:  $*"; }
ok()     { echo "[teardown] OK:    $*"; }
warn()   { echo "[teardown] WARN:  $*"; }
error()  { echo "[teardown] ERROR: $*" >&2; exit 1; }

confirm() {
  local msg="$1"
  echo ""
  echo "[teardown] *** CONFIRM: ${msg} ***"
  read -r -p "            Type 'yes' to proceed, anything else to skip: " answer
  if [[ "$answer" != "yes" ]]; then
    warn "Skipped: ${msg}"
    return 1
  fi
  return 0
}

echo ""
echo "================================================================"
echo " ZENITH DEMO TEARDOWN"
echo "================================================================"
echo ""
echo " This script will:"
echo "   1. Remove the self-hosted runner from GitHub"
echo "   2. Run terraform destroy"
echo "   3. Delete the local private key file"
echo ""
echo " Each step requires confirmation."
echo ""

# --- Step 1: Remove self-hosted runner from GitHub ---
if confirm "Remove self-hosted runner from GitHub repo '${GITHUB_REPO}'?"; then
  info "Fetching runner remove token from GitHub..."

  if ! gh auth status &>/dev/null; then
    error "gh CLI is not authenticated. Run 'gh auth login'."
  fi

  REMOVE_TOKEN="$(gh api \
    -X POST \
    "repos/${GITHUB_REPO}/actions/runners/remove-token" \
    --jq '.token')"

  if [[ -z "$REMOVE_TOKEN" ]]; then
    warn "Could not fetch remove token. The runner may already be gone, or you may lack admin access."
  else
    info "Got remove token. Connecting to EC2 instance to deregister runner..."

    # Read the public IP from Terraform state (may already be destroyed; tolerate failure)
    PUBLIC_IP=""
    if cd infra && terraform output public_ip &>/dev/null 2>&1; then
      PUBLIC_IP="$(terraform output -raw public_ip 2>/dev/null || true)"
      cd ..
    else
      cd .. 2>/dev/null || true
    fi

    if [[ -n "$PUBLIC_IP" && -f "$KEY_PATH" ]]; then
      SSH_CMD="ssh -i ${KEY_PATH} -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${EC2_USER}@${PUBLIC_IP}"
      info "Deregistering runner on ${PUBLIC_IP}..."
      $SSH_CMD "bash -lc \"
        if [[ -f ${RUNNER_DIR}/config.sh ]]; then
          cd ${RUNNER_DIR}
          sudo ./svc.sh stop  2>/dev/null || true
          sudo ./svc.sh uninstall 2>/dev/null || true
          sudo -u runner ./config.sh remove --token '${REMOVE_TOKEN}'
          echo 'Runner deregistered.'
        else
          echo 'Runner directory not found — may already be removed.'
        fi
      \"" || warn "SSH to instance failed — runner may already be gone."
      ok "Runner deregistered"
    else
      warn "Cannot reach EC2 instance (no IP or key). Runner registration in GitHub may need manual cleanup."
      info "Manual cleanup: gh api repos/${GITHUB_REPO}/actions/runners | jq '.runners[] | .id'"
      info "Then: gh api -X DELETE repos/${GITHUB_REPO}/actions/runners/<id>"
    fi
  fi
fi

# --- Step 2: Terraform destroy ---
if confirm "Run 'terraform destroy' to delete all AWS resources?"; then
  info "Running terraform destroy..."
  cd infra
  terraform destroy
  cd ..
  ok "AWS resources destroyed"
fi

# --- Step 3: Delete private key ---
if [[ -f "$KEY_PATH" ]]; then
  if confirm "Delete local private key file '${KEY_PATH}'?"; then
    rm -f "$KEY_PATH"
    ok "Deleted ${KEY_PATH}"
  fi
else
  info "Key file ${KEY_PATH} already gone."
fi

echo ""
echo "================================================================"
echo " TEARDOWN COMPLETE"
echo "================================================================"
echo ""
echo " Verify cleanup:"
echo "   aws ec2 describe-instances --filters 'Name=tag:Project,Values=zenith-live-2026'"
echo "   gh api repos/${GITHUB_REPO}/actions/runners"
echo ""
