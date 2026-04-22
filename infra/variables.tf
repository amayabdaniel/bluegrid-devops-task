variable "project" {
  type    = string
  default = "bluegrid-devops-task"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "owner" {
  type    = string
  default = "daniel-amaya"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "github_repo" {
  type = string
}

variable "github_deploy_refs" {
  type    = list(string)
  default = ["refs/heads/master", "refs/heads/develop"]
}

variable "github_deploy_environments" {
  type    = list(string)
  default = ["production"]
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
  validation {
    condition     = contains(["t2.micro", "t3.micro"], var.instance_type)
    error_message = "Use a free-tier eligible type (t2.micro or t3.micro)."
  }
}

variable "admin_cidr" {
  type = string
  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.admin_cidr))
    error_message = "admin_cidr must be a /32."
  }
}

variable "ssh_public_key" {
  type = string
  validation {
    condition     = length(regexall("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ", var.ssh_public_key)) > 0
    error_message = "Provide an OpenSSH public key."
  }
}

variable "app_port_internal" {
  type    = number
  default = 8080
}

variable "app_port_public" {
  type    = number
  default = 777
  validation {
    condition     = var.app_port_public > 0 && var.app_port_public < 65536
    error_message = "app_port_public must be a valid TCP port."
  }
}

variable "image_ref" {
  type    = string
  default = "ghcr.io/amayabdaniel/gs-rest-service:master"
}
