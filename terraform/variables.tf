variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ for the EBS volume and validator instance. EBS volumes are AZ-scoped — the ASG subnet must be in this same AZ or AttachVolume will fail."
  type        = string
  default     = "us-east-1a"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "eth-validator"
}

variable "environment" {
  description = "Environment label (testnet, mainnet)"
  type        = string
  default     = "testnet"
}



variable "vpc_id" {
  description = "VPC ID. Leave empty to use the default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID for the validator instance. Must be in var.availability_zone. Leave empty to use the default subnet in that AZ."
  type        = string
  default     = ""
}

variable "ebs_volume_size_gb" {
  description = "Size of the persistent EBS data volume in GB. Nethermind needs ~300GB + Nimbus ~100GB + headroom."
  type        = number
  default     = 500
}

variable "ebs_iops" {
  description = "gp3 IOPS for the data volume. 3000 is the free baseline; provisioned IOPS above 3000 add cost."
  type        = number
  default     = 3000
}

variable "ebs_throughput_mbps" {
  description = "gp3 throughput in MB/s. 125 is the free baseline; 250 is a reasonable upgrade for sync."
  type        = number
  default     = 250
}

variable "spot_max_price" {
  description = "Maximum spot price per hour as a string (e.g. \"0.08\"). Leave empty to cap at on-demand price."
  type        = string
  default     = ""
}
