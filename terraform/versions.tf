terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used in security_groups.tf to auto-detect the deployer's public IP for SSH
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }

  # Uncomment to store state in S3 (recommended for team use):
  # backend "s3" {
  #   bucket  = "your-terraform-state-bucket"
  #   key     = "eth-validator/terraform.tfstate"
  #   region  = "us-east-1"
  #   encrypt = true
  # }
}
