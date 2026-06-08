terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Latest Amazon Linux 2023 AMI for the target region
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Default VPC — simpler for demo; ZTG governs egress the same in any VPC
data "aws_vpc" "default" {
  default = true
}

# Default public subnet in any available AZ
data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# ---------- Key pair ----------

resource "tls_private_key" "runner" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "runner" {
  key_name   = "${var.name_prefix}-runner-key"
  public_key = tls_private_key.runner.public_key_openssh

  tags = {
    Name    = "${var.name_prefix}-runner-key"
    Project = var.project_tag
    Role    = var.role_tag
  }
}

# Write private key to disk with 0600 permissions. This file is .gitignored.
resource "local_sensitive_file" "runner_private_key" {
  content         = tls_private_key.runner.private_key_pem
  filename        = "${path.module}/zenith-demo-key.pem"
  file_permission = "0600"
}

# ---------- IAM instance profile (no AWS permissions attached) ----------
# An empty profile lets the instance identify to AWS for SSM access later if needed.

resource "aws_iam_role" "runner" {
  name = "${var.name_prefix}-runner-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = {
    Project = var.project_tag
    Role    = var.role_tag
  }
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.name_prefix}-runner-profile"
  role = aws_iam_role.runner.name
}

# ---------- Security group ----------

resource "aws_security_group" "runner" {
  name        = "${var.name_prefix}-runner-sg"
  description = "Zenith demo runner SG. SSH from operator only. Egress open - ZTG governs it."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from operator laptop"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  # Egress is fully open at the SG layer. ZTG enforces destination policy.
  egress {
    description = "All egress - governed by ZTG, not this SG"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.name_prefix}-runner-sg"
    Project = var.project_tag
    Role    = var.role_tag
  }
}

# ---------- EC2 instance ----------

resource "aws_instance" "runner" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default_public.ids[0]
  vpc_security_group_ids      = [aws_security_group.runner.id]
  key_name                    = aws_key_pair.runner.key_name
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  associate_public_ip_address = true

  user_data = <<-USERDATA
    #!/bin/bash
    set -e
    exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

    echo "=== [$(date -u +%Y-%m-%dT%H:%M:%SZ)] Zenith demo runner bootstrap starting ==="

    # System update
    yum update -y

    # Base utilities
    yum install -y jq git curl tar

    # Node.js 20 via NodeSource RPM setup script
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    yum install -y nodejs
    echo "node: $(node --version)"
    echo "npm:  $(npm --version)"

    # Create the runner system user if it doesn't already exist
    id runner 2>/dev/null || useradd --create-home --home-dir /home/runner --shell /bin/bash runner

    umask 0022

    echo "=== [$(date -u +%Y-%m-%dT%H:%M:%SZ)] Zenith demo runner bootstrap complete ==="
  USERDATA

  tags = {
    Name    = "${var.name_prefix}-runner"
    Project = var.project_tag
    Role    = var.role_tag
  }

  depends_on = [aws_security_group.runner]
}
