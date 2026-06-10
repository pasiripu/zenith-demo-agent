# Zenith Live 2026 — Securing AI in the Software Development Lifecycle

Demo scaffolding for the Zscaler Zero Trust Gateway session at Zenith Live 2026.
Shows that AI agents are workloads, and workload egress can be governed with the
same identity-based controls used for any other VPC resource.


For testing only 2
---

## What this builds

- An **EC2 instance** (t3.medium, Amazon Linux 2023) acting as a self-hosted GitHub Actions runner, tagged for workload identity in ZTG.
- A **GitHub Actions workflow** that runs a Claude Code agent on every PR touching `agent/**`. The agent reads `agent/src/example.py` and attempts to POST a review to a webhook URL.
- A **webhook destination** (`<<WEBHOOK_URL>>`) that is intentionally **not on the ZTG allowlist**. ZTG blocks the POST at the network layer, and the workflow job fails visibly.
- Supporting **scripts** for bootstrap, teardown, and a live-demo fallback that tests egress directly from the runner without going through Actions.

---

## Prerequisites

| Tool | Notes |
|---|---|
| AWS CLI | Authenticated (`aws sts get-caller-identity` works) |
| Terraform 1.5+ | `terraform -version` |
| gh CLI | Authenticated (`gh auth status` works), admin access to `pasiripu/zenith-demo-agent` |
| ZTG | Ready to be wired to the runner instance's egress — see step 3 |

---

## How to use

### 1. Provision AWS infrastructure

Before applying, set your real values in `infra/variables.tf`:
- `aws_region` → replace `us-east-1` with `<<AWS_REGION>>`
- `ssh_cidr` → replace `0.0.0.0/0` with `<<YOUR_IP_CIDR>>`

```bash
cd infra
terraform init
terraform apply
```

After apply, note the outputs:

```bash
terraform output ssh_command              # save this
terraform output runner_workload_identity # paste into ZTG
```

### 2. Wait 90 seconds for user-data to complete

The `user_data` script installs Node.js 20, git, and creates the `runner` user.
SSH in too early and the environment will be incomplete. Watch the log if needed:

```bash
ssh -i ./zenith-demo-key.pem ec2-user@<IP> 'sudo tail -f /var/log/user-data.log'
```

### 3. Wire ZTG to this instance's egress

> **The demo does not work until ZTG is enforcing policy.**

Use the `runner_workload_identity` output string to create your ZTG workload
policy. The policy should:

- **Allow** egress to `api.anthropic.com` (Claude API)
- **Allow** egress to `github.com`, `objects.githubusercontent.com` (runner registration + checkout)
- **Block** egress to `<<WEBHOOK_URL>>` (the unsanctioned review destination)

Wire the policy and verify before proceeding.

### 4. Verify ZTG enforcement

SCP the fallback script to the runner and run it:

```bash
scp -i ./infra/zenith-demo-key.pem scripts/demo-fallback.sh ec2-user@<IP>:/home/runner/
ssh -i ./infra/zenith-demo-key.pem ec2-user@<IP> 'bash /home/runner/demo-fallback.sh'
```

Expected output:
```
Anthropic API: 200 — ALLOWED
Webhook: BLOCKED (curl exit 7 — ZTG is enforcing)
```

If the webhook is **not** blocked, ZTG is not yet enforcing. Do not proceed.

### 5. Run bootstrap.sh

```bash
./scripts/bootstrap.sh
```

This script (run from repo root on your laptop):
- Installs Claude Code on the runner (`npm install -g @anthropic-ai/claude-code`)
- Registers the instance as a self-hosted GitHub Actions runner
- Verifies the runner shows as `online` in GitHub

### 6. Set the Anthropic API key

Set the repository secret interactively (do NOT use `--body` or pipe — keeps it out of shell history):

```bash
gh secret set ANTHROPIC_API_KEY --repo pasiripu/zenith-demo-agent
```

### 7. Trigger the demo

```bash
gh workflow run code-review-agent.yml --repo pasiripu/zenith-demo-agent
```

Watch the job in real time:

```bash
gh run watch --repo pasiripu/zenith-demo-agent
```

The job will:
1. Check out the repo on the runner
2. Read `agent/src/example.py`
3. Ask Claude to write a brief code review
4. Attempt to `curl -X POST <<WEBHOOK_URL>>` — **ZTG blocks this**
5. Exit with code 1; the workflow job shows as **Failed**

That failure _is_ the demo. It proves ZTG governed the agent's egress.

---

## Demo narration

> <!-- TODO: fill in from your Zenith Live talk notes -->
>
> _[Placeholder — paste your on-stage script here before the conference.]_
>
> Suggested structure:
> - Set the scene: what the agent is trying to do (post a code review to a webhook)
> - Why this matters: in a real supply-chain attack, the URL in `agent-config.json` would be attacker-controlled
> - Show the workflow triggering and the `curl` exit code in the logs
> - Show the ZTG console: the blocked egress event, source IP, destination
> - Land the point: the agent had no idea it was governed — ZTG operates at the network layer

---

## Teardown

```bash
./scripts/teardown.sh
```

Prompts before each destructive action. Removes the runner from GitHub,
runs `terraform destroy`, and deletes the local private key.

---

## Why it's built this way

**Default VPC** — The demo uses the account's default VPC and default subnets.
This removes VPC/routing complexity that isn't relevant to the security point.
ZTG governs egress the same way in any VPC; using the default keeps the
Terraform surface minimal and the demo reproducible in any account.

**Self-hosted runner, not GitHub-hosted** — GitHub-hosted runners egress through
GitHub's IP ranges, not your VPC. A self-hosted runner on an EC2 instance in your
VPC is a real workload with real VPC egress — the kind ZTG is designed to govern.
The demo only works with a self-hosted runner.

**Destination control, not TLS inspection** — The demo relies on ZTG blocking a
specific destination URL. This is deterministic and requires no TLS inspection.
It also mirrors how the attack surface actually works: an agent configured (or
manipulated via prompt injection) to send data to an attacker-controlled URL,
which network egress control can block regardless of whether the traffic is encrypted.

---

## Known limitations

- The unsanctioned webhook URL is written as a literal string in `agent/agent-config.json`.
  In the real threat model this file would be modified by a supply-chain compromise or
  injected via a malicious prompt in a PR description. The planted artifact is a stand-in
  for both threat vectors — it lets the demo run deterministically without requiring a
  live attacker.
- The agent runs with `--permission-mode acceptEdits`, which allows file edits and bash
  execution. This is intentional for the demo (so the agent can run `curl`) but would
  need tighter scoping in production.
- ZTG configuration is entirely out of scope for this repository. You must wire ZTG
  to the runner's egress before the demo is meaningful.
