data "aws_caller_identity" "current" {}

# ── VPC and subnet ──
# If vpc_id / subnet_id variables are set, those take precedence.
# Otherwise we fall back to the default VPC and its default subnet in the target AZ.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "validator" {
  vpc_id            = local.resolved_vpc_id
  availability_zone = var.availability_zone
  default_for_az    = var.subnet_id == "" ? true : null
  id                = var.subnet_id != "" ? var.subnet_id : null
}

locals {
  resolved_vpc_id    = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default.id
  resolved_subnet_id = data.aws_subnet.validator.id
}

# ── AMI: Ubuntu 24.04 LTS ARM64 (Canonical) ──
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
