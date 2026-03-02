# ── Launch Template ──

resource "aws_launch_template" "validator" {
  name_prefix   = "${local.name_prefix}-lt-"
  image_id      = data.aws_ami.ubuntu_arm64.id
  instance_type = "t4g.xlarge"

  iam_instance_profile {
    name = aws_iam_instance_profile.validator.name
  }

  vpc_security_group_ids = [aws_security_group.validator.id]

  # IMDSv2 enforced (hop_limit=1 is correct: only the host needs instance metadata,
  # not containers running inside Docker/Minikube)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # Root volume: OS only — chain data lives on the separate aws_ebs_volume
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.validator.arn
      delete_on_termination = true
    }
  }

  # User data: attaches the persistent data volume, formats if new, mounts it
  user_data = base64encode(templatefile(
    "${path.module}/templates/user_data.sh.tpl",
    {
      ebs_volume_id = aws_ebs_volume.data.id
      aws_region    = var.aws_region
      mount_point   = "/opt/validator"
    }
  ))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${local.name_prefix}-node"
      Project = var.project_name
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name    = "${local.name_prefix}-root-vol"
      Project = var.project_name
    }
  }

  monitoring {
    enabled = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Auto Scaling Group ──
#
# Single-instance (max=1) spot validator.
# When a spot instance is interrupted, ASG automatically launches a replacement.
# The user_data script reattaches the persistent EBS volume on the new instance.
#
# NOTE: provider default_tags do NOT propagate to ASG-launched instances.
# The tag { propagate_at_launch = true } blocks below are required for the
# ec2:AttachVolume IAM condition (which checks the Project tag on the instance).

resource "aws_autoscaling_group" "validator" {
  name                = "${local.name_prefix}-asg"
  min_size            = 0
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [local.resolved_subnet_id]

  # capacity-optimized: maximises likelihood of spot capacity, worth slight price premium
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0 # 100% spot
      spot_allocation_strategy                 = "capacity-optimized"

      # Leave spot_max_price unset (empty) to cap at on-demand price,
      # or set var.spot_max_price to a specific limit.
      spot_max_price = var.spot_max_price != "" ? var.spot_max_price : null
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.validator.id
        version            = "$Latest"
      }
    }
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300
  wait_for_capacity_timeout = "10m"

  # Rolling refresh when launch template changes (e.g. new AMI or user data)
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0 # Single-instance: allow downtime during refresh
    }
    triggers = ["launch_template"]
  }

  # Tags must be declared explicitly with propagate_at_launch for ASG-launched instances
  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-node"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "terraform"
    propagate_at_launch = true
  }

  lifecycle {
    # Prevent Terraform from overriding manual scale-in/out (e.g. desired=0 for maintenance)
    ignore_changes = [desired_capacity]
  }
}
