# infra/

Terraform module that provisions the AWS resources for the Zenith Live 2026 demo runner.

## What it creates

| Resource | Name | Notes |
|---|---|---|
| EC2 instance | `zenith-demo-runner` | t3.medium, Amazon Linux 2023, public IP |
| Security group | `zenith-demo-runner-sg` | SSH from your IP only; all egress open for ZTG |
| Key pair | `zenith-demo-runner-key` | RSA 4096, generated in Terraform |
| Private key file | `./zenith-demo-key.pem` | Written to disk at 0600; .gitignored |
| IAM role + profile | `zenith-demo-runner-role` | No AWS permissions; SSM attach point |

## Before you apply

1. Set your real values in `variables.tf` (or pass with `-var`):
   - `aws_region` — replace the `us-east-1` default with `<<AWS_REGION>>`
   - `ssh_cidr` — replace `0.0.0.0/0` with `<<YOUR_IP_CIDR>>`
2. Ensure your AWS CLI is authenticated: `aws sts get-caller-identity`

## Apply

```bash
cd infra
terraform init
terraform apply
```

> **Important — wait 90 seconds after apply completes.**
> The `user_data` script installs Node.js, git, and creates the `runner` user.
> If you SSH in too early, the environment won't be ready for `bootstrap.sh`.

## Wire ZTG before running bootstrap.sh

> **The demo does not work until ZTG is enforcing egress policy on this instance.**
>
> After `terraform apply`, the `runner_workload_identity` output gives you the
> string to paste into your ZTG workload policy. Wire that policy **before**
> running `../scripts/bootstrap.sh`. If you run bootstrap first, the runner's
> GitHub registration call may be intercepted by a policy not yet tuned for it.

## Outputs

After apply:

```bash
terraform output ssh_command            # copy-paste SSH command
terraform output runner_workload_identity  # paste into ZTG policy
```

## Destroy

```bash
terraform destroy
```

Or use the teardown script from the repo root: `./scripts/teardown.sh`
