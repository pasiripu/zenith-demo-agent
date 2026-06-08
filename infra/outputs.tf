output "instance_id" {
  description = "EC2 instance ID of the self-hosted runner."
  value       = aws_instance.runner.id
}

output "public_ip" {
  description = "Public IP address of the self-hosted runner."
  value       = aws_instance.runner.public_ip
}

output "private_ip" {
  description = "Private IP address of the self-hosted runner within the VPC."
  value       = aws_instance.runner.private_ip
}

output "ssh_command" {
  description = "Ready-to-run SSH command to connect to the runner."
  value       = "ssh -i ./zenith-demo-key.pem ec2-user@${aws_instance.runner.public_ip}"
}

output "runner_workload_identity" {
  description = "Paste this string into your ZTG workload identity policy to identify this runner."
  value       = "instance-id=${aws_instance.runner.id} | tags: Project=${var.project_tag}, Role=${var.role_tag}, Name=${var.name_prefix}-runner | public-ip=${aws_instance.runner.public_ip}"
}
