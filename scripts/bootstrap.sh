#!/bin/bash
set -euo pipefail

# Bootstrap script: wires the EC2 instance (already running after terraform apply)
# into the GitHub Actions self-hosted runner pool and installs Claude Code.
#
# Idempotent: safe to re-run. Existing runner registration is left in place;
# if a runner with the same name already exists, GitHub will reject the duplicate
# and the script will report it clearly.
#
# Assumption: this script runs from the repo root on your laptop, not on the EC2 instance.

# --- Configuration ---
# TODO: if you forked this under a different org, update GITHUB_REPO_OWNER
GITHUB_REPO_OWNER="pasiripu"
GITHUB_REPO_NAME="zenith-demo-agent"
GITHUB_REPO="${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}"

KEY_PATH="./infra/zenith-demo-key.pem"
EC2_USER="ec2-user"
RUNNER_DIR="/home/runner/actions-runner"
RUNNER_LABELS="self-hosted,demo-runner"

# --- Helpers ---
info()  { echo "[bootstrap] INFO:  $*"; }
ok()    { echo "[bootstrap] OK:    $*"; }
error() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

# --- Step 1: Verify prerequisites ---
info "Verifying prerequisites..."

if ! command -v aws &>/dev/null; then
  error "aws CLI not found. Install it and run 'aws configure' or set AWS_PROFILE."
fi

if ! aws sts get-caller-identity --query Account --output text &>/dev/null; then
  error "aws CLI is not authenticated. Run 'aws configure' or export credentials."
fi
ok "AWS CLI authenticated"

if ! command -v gh &>/dev/null; then
  error "gh CLI not found. Install from https://cli.github.com/"
fi

if ! gh auth status &>/dev/null; then
  error "gh CLI is not authenticated. Run 'gh auth login'."
fi
ok "gh CLI authenticated"

if ! command -v terraform &>/dev/null; then
  error "terraform not found in PATH."
fi

info "Checking Terraform state for instance..."
cd infra
if ! terraform output instance_id &>/dev/null; then
  cd ..
  error "No Terraform state found in ./infra. Run 'terraform init && terraform apply' first."
fi

# --- Step 2: Read public IP from Terraform ---
PUBLIC_IP="$(terraform output -raw public_ip)"
cd ..  # back to repo root

if [[ -z "$PUBLIC_IP" ]]; then
  error "terraform output returned an empty public_ip. Did the apply succeed?"
fi
ok "Runner public IP: ${PUBLIC_IP}"

if [[ ! -f "$KEY_PATH" ]]; then
  error "Private key not found at ${KEY_PATH}. Did terraform apply write it?"
fi

SSH_CMD="ssh -i ${KEY_PATH} -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${EC2_USER}@${PUBLIC_IP}"

info "Waiting for SSH to be available on ${PUBLIC_IP}..."
for i in $(seq 1 18); do
  if $SSH_CMD "echo ssh-ok" &>/dev/null 2>&1; then
    ok "SSH reachable"
    break
  fi
  echo "    ... attempt ${i}/18, waiting 10s"
  sleep 10
  if [[ $i -eq 18 ]]; then
    error "SSH did not become available after 3 minutes. Is the SG ssh_cidr set to your IP?"
  fi
done

# --- Step 3: Install Claude Code on the instance ---
info "Installing Claude Code globally on the runner..."

# NodeSource installs Node with a root-owned global module dir, so the
# global npm install needs sudo even though we're connecting as ec2-user.
$SSH_CMD "bash -lc 'sudo npm install -g @anthropic-ai/claude-code 2>&1'"
CLAUDE_VERSION=$($SSH_CMD "bash -lc 'claude --version 2>&1'" )
ok "Claude Code installed: ${CLAUDE_VERSION}"

# --- Step 4: Get GitHub Actions runner registration token ---
info "Fetching GitHub Actions runner registration token..."
REG_TOKEN="$(gh api \
  -X POST \
  "repos/${GITHUB_REPO}/actions/runners/registration-token" \
  --jq '.token')"

if [[ -z "$REG_TOKEN" ]]; then
  error "Failed to fetch registration token. Does the repo exist and do you have admin access?"
fi
ok "Registration token obtained (not shown)"

# --- Step 5: Download, configure, and install the runner on EC2 ---
info "Downloading and configuring the GitHub Actions runner on the instance..."

# Fetch latest runner version from GitHub releases
RUNNER_VERSION="$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | sed 's/v//')"
RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"

info "Runner version: ${RUNNER_VERSION}"

$SSH_CMD "bash -lc \"
  set -e

  # Create runner directory
  sudo mkdir -p ${RUNNER_DIR}
  sudo chown runner:runner ${RUNNER_DIR}

  # Download runner (skip if tarball already exists)
  if [[ ! -f /home/runner/${RUNNER_TARBALL} ]]; then
    echo 'Downloading runner tarball...'
    sudo -u runner curl -fsSL '${RUNNER_URL}' -o /home/runner/${RUNNER_TARBALL}
  else
    echo 'Runner tarball already present, skipping download.'
  fi

  # Extract
  if [[ ! -f ${RUNNER_DIR}/config.sh ]]; then
    echo 'Extracting runner...'
    sudo -u runner tar -xzf /home/runner/${RUNNER_TARBALL} -C ${RUNNER_DIR}
  else
    echo 'Runner already extracted.'
  fi

  # Configure (skip if .runner file exists — already configured)
  if [[ ! -f ${RUNNER_DIR}/.runner ]]; then
    echo 'Configuring runner...'
    cd ${RUNNER_DIR}
    sudo -u runner ./config.sh \
      --unattended \
      --token '${REG_TOKEN}' \
      --url 'https://github.com/${GITHUB_REPO}' \
      --labels '${RUNNER_LABELS}' \
      --name 'zenith-demo-runner'
  else
    echo 'Runner already configured (.runner file exists).'
  fi

  # Install and start as a systemd service. svc.sh writes a .service marker
  # file once installed — check that rather than globbing systemctl unit names.
  cd ${RUNNER_DIR}
  if [[ ! -f .service ]]; then
    echo 'Installing runner service...'
    sudo ./svc.sh install runner
    sudo ./svc.sh start
  else
    echo 'Runner service already installed — ensuring it is started.'
    sudo ./svc.sh start || true
  fi

  echo 'Runner service status:'
  sudo ./svc.sh status
\""

ok "Runner installed and started on ${PUBLIC_IP}"

# --- Step 6: Verify runner shows as online ---
info "Verifying runner appears online in GitHub..."
sleep 5  # give the runner a moment to phone home

RUNNER_STATUS="$(gh api "repos/${GITHUB_REPO}/actions/runners" --jq '.runners[] | select(.name=="zenith-demo-runner") | .status')"
if [[ "$RUNNER_STATUS" == "online" ]]; then
  ok "Runner 'zenith-demo-runner' is ONLINE in GitHub"
else
  echo "[bootstrap] WARN: Runner status is '${RUNNER_STATUS:-not found}'. It may take a few more seconds."
  echo "            Check: gh api repos/${GITHUB_REPO}/actions/runners"
fi

# --- Step 7: Print success summary ---
WORKLOAD_IDENTITY="$(cd infra && terraform output -raw runner_workload_identity)"

echo ""
echo "================================================================"
echo " BOOTSTRAP COMPLETE"
echo "================================================================"
echo ""
echo " Runner public IP : ${PUBLIC_IP}"
echo " SSH command      : ssh -i ${KEY_PATH} ${EC2_USER}@${PUBLIC_IP}"
echo " Runner name      : zenith-demo-runner"
echo " GitHub repo      : https://github.com/${GITHUB_REPO}"
echo ""
echo " ZTG workload identity string (paste into your ZTG policy):"
echo "   ${WORKLOAD_IDENTITY}"
echo ""
echo "================================================================"
echo " NEXT STEPS"
echo "================================================================"
echo ""
echo " 1. Set the ANTHROPIC_API_KEY secret in the repo (do this interactively):"
echo ""
echo "    gh secret set ANTHROPIC_API_KEY --repo ${GITHUB_REPO}"
echo ""
echo "    (Do NOT use --body or pipe the key — keep it out of shell history)"
echo ""
echo " 2. Wire ZTG to the runner's egress if not already done."
echo "    Then verify enforcement:"
echo "    scp -i ${KEY_PATH} scripts/demo-fallback.sh ${EC2_USER}@${PUBLIC_IP}:/home/runner/"
echo "    ssh -i ${KEY_PATH} ${EC2_USER}@${PUBLIC_IP} 'bash /home/runner/demo-fallback.sh'"
echo ""
echo " 3. Trigger the demo workflow:"
echo "    gh workflow run code-review-agent.yml --repo ${GITHUB_REPO}"
echo ""
