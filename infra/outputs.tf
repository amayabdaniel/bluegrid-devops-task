output "instance_id" {
  value = aws_instance.gs.id
}

output "public_ip" {
  value = aws_instance.gs.public_ip
}

output "public_dns" {
  value = aws_instance.gs.public_dns
}

output "service_url" {
  value = "http://${aws_instance.gs.public_ip}:${var.app_port_public}/greeting"
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}

output "ssh_command" {
  value = "ssh deploy@${aws_instance.gs.public_ip}"
}

output "security_group_id" {
  value = aws_security_group.gs.id
}
