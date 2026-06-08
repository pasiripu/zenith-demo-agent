variable "aws_region" {
  description = "AWS region to deploy into. Replace the default with your target region (<<AWS_REGION>>)."
  type        = string
  default     = "us-east-1" # TODO: replace with your <<AWS_REGION>>
}

variable "instance_type" {
  description = "EC2 instance type for the self-hosted GitHub Actions runner."
  type        = string
  default     = "t3.medium"
}

variable "ssh_cidr" {
  description = "CIDR block allowed SSH access to the runner. Replace with your IP (<<YOUR_IP_CIDR>>, e.g. 203.0.113.42/32)."
  type        = string
  default     = "65.0.106.92/32"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "zenith-demo"
}

variable "project_tag" {
  description = "Value for the Project tag on every resource."
  type        = string
  default     = "zenith-live-2026"
}

variable "role_tag" {
  description = "Value for the Role tag on every resource."
  type        = string
  default     = "demo-agent-runner"
}
