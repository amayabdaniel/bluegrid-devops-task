output "instance_id" {
  description = "EC2 instance ID — used by the CD workflow as the SSM target."
  value       = aws_instance.gs.id
}

output "public_ip" {
  description = "Public IPv4 of the host."
  value       = aws_instance.gs.public_ip
}

output "public_dns" {
  description = "Public DNS of the host."
  value       = aws_instance.gs.public_dns
}

output "service_url" {
  description = "URL the monitor and the defence-call demo will hit."
  value       = "http://${aws_instance.gs.public_ip}:${var.app_port_public}/greeting"
}

output "github_deploy_role_arn" {
  description = "Set this as repo variable AWS_DEPLOY_ROLE_ARN; configure-aws-credentials assumes it via OIDC."
  value       = aws_iam_role.github_deploy.arn
}

output "ssh_command" {
  description = "Convenience SSH command (uses the deploy user, key from your ~/.ssh)."
  value       = "ssh deploy@${aws_instance.gs.public_ip}"
}

output "security_group_id" {
  description = "Security Group ID for the host."
  value       = aws_security_group.gs.id
}
