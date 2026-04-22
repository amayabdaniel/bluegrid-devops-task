variable "project" {
  description = "Project name used in tags and resource names."
  type        = string
  default     = "bluegrid-devops-task"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "demo"
}

variable "owner" {
  description = "Owner tag (your name / handle)."
  type        = string
  default     = "daniel-amaya"
}

variable "aws_region" {
  description = "AWS region. us-east-1 is the cheapest and most Free Tier friendly."
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "GitHub repo in OWNER/REPO form. Used to scope the OIDC trust policy."
  type        = string
  # Example: "amayabdaniel/bluegrid-devops-task"
}

variable "github_deploy_refs" {
  description = "Git refs (branches) allowed to assume the deploy role via OIDC."
  type        = list(string)
  default     = ["refs/heads/master", "refs/heads/develop"]
}

variable "instance_type" {
  description = "EC2 instance type. t2.micro is Free Tier eligible."
  type        = string
  default     = "t2.micro"
  validation {
    condition     = contains(["t2.micro", "t3.micro"], var.instance_type)
    error_message = "Stick to Free Tier eligible types (t2.micro or t3.micro)."
  }
}

variable "admin_cidr" {
  description = "Single CIDR (your public IP /32) allowed to SSH on TCP 22. ANY broader value will be rejected."
  type        = string
  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.admin_cidr))
    error_message = "admin_cidr must be a /32 (single host). Look up your IP at https://checkip.amazonaws.com."
  }
}

variable "ssh_public_key" {
  description = "Your SSH public key (contents of id_ed25519.pub or id_rsa.pub) for the deploy user."
  type        = string
  validation {
    condition     = length(regexall("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ", var.ssh_public_key)) > 0
    error_message = "Provide a valid OpenSSH public key starting with ssh-ed25519, ssh-rsa, or ecdsa-sha2-nistp256."
  }
}

variable "app_port_internal" {
  description = "Container port the Spring Boot app listens on inside the container."
  type        = number
  default     = 8080
}

variable "app_port_public" {
  description = "Public port published on the EC2 host. The task brief requires 777."
  type        = number
  default     = 777
  validation {
    condition     = var.app_port_public > 0 && var.app_port_public < 65536
    error_message = "app_port_public must be a valid TCP port."
  }
}

variable "image_ref" {
  description = "Initial image reference to run on the host. The CD workflow updates this on every deploy via SSM."
  type        = string
  default     = "ghcr.io/amayabdaniel/gs-rest-service:master"
}

