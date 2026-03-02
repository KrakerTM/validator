output "kms_key_arn" {
  description = "KMS CMK ARN — provide this to tools/encrypt-keystore.sh when running offline"
  value       = aws_kms_key.validator.arn
}

output "kms_key_alias" {
  description = "KMS alias (hardcoded to match tools/encrypt-keystore.sh)"
  value       = aws_kms_alias.validator.name
}

output "ebs_volume_id" {
  description = "Persistent data volume ID — KEEP THIS SAFE. Chain data lives here."
  value       = aws_ebs_volume.data.id
}

output "ebs_availability_zone" {
  description = "AZ of the data volume — the validator instance must launch in this AZ"
  value       = aws_ebs_volume.data.availability_zone
}

output "asg_name" {
  description = "ASG name — use to manually set desired_capacity to 0 for maintenance"
  value       = aws_autoscaling_group.validator.name
}

output "launch_template_id" {
  description = "Launch template ID"
  value       = aws_launch_template.validator.id
}

output "security_group_id" {
  description = "Validator security group ID"
  value       = aws_security_group.validator.id
}

output "iam_role_arn" {
  description = "IAM role ARN attached to the validator instance"
  value       = aws_iam_role.validator.arn
}

output "instance_profile_name" {
  description = "IAM instance profile name"
  value       = aws_iam_instance_profile.validator.name
}

output "ami_id" {
  description = "Ubuntu 24.04 LTS ARM64 AMI resolved at apply time"
  value       = data.aws_ami.ubuntu_arm64.id
}

output "ami_name" {
  description = "Full AMI name (shows Ubuntu version)"
  value       = data.aws_ami.ubuntu_arm64.name
}

output "vpc_id" {
  description = "VPC used for the validator"
  value       = local.resolved_vpc_id
}

output "subnet_id" {
  description = "Subnet used for the validator (in var.availability_zone)"
  value       = local.resolved_subnet_id
}

output "ssm_connect_command" {
  description = "Command to connect via SSM Session Manager (no SSH required)"
  value       = "aws ssm start-session --target <INSTANCE_ID> --region ${var.aws_region}"
}
