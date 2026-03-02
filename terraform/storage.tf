# ── Persistent EBS Data Volume ──
#
# This volume survives spot instance interruptions. When a new instance
# is launched by the ASG, user_data.sh.tpl reattaches and remounts it.
#
# Capacity planning:
#   Nethermind (Hoodi EL): ~200–300GB (growing)
#   Nimbus (Hoodi CL):     ~50–100GB  (growing)
#   Headroom:              ~100GB
#   Total:                 500GB
#
# gp3 baseline: 3000 IOPS and 125 MB/s included at no extra charge.
# throughput=250 is billed above baseline but improves initial sync speed.

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.ebs_volume_size_gb
  type              = "gp3"
  iops              = var.ebs_iops
  throughput        = var.ebs_throughput_mbps
  encrypted         = true
  kms_key_id        = aws_kms_key.validator.arn

  tags = {
    Name    = "${local.name_prefix}-data"
    Project = var.project_name
  }

  lifecycle {
    # Prevents accidental deletion of chain data via terraform destroy.
    # To intentionally delete: comment this out, plan, apply, then destroy.
    prevent_destroy = true

    # Tag changes (e.g. adding a billing tag) should not trigger a replacement.
    ignore_changes = [tags]
  }
}
