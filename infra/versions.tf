terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.41"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }

  # Local backend by default. Swap to S3+DynamoDB lock for team use:
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "bluegrid/devops-task/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "your-tfstate-locks"
  #   encrypt        = true
  # }
}
