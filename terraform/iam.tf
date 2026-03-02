# ── EC2 Instance Role ──

resource "aws_iam_role" "validator" {
  name        = "${local.name_prefix}-role"
  description = "EC2 instance role for Ethereum validator (${var.environment})"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ── Least-privilege policy ──
# KMS: decrypt keystores only (no encrypt, no generate-data-key)
# EC2: attach the one specific data volume to self + describe for idempotency check
resource "aws_iam_role_policy" "validator" {
  name = "${local.name_prefix}-policy"
  role = aws_iam_role.validator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Keystore decryption — used by provision.sh via aws kms decrypt
      {
        Sid    = "KMSDecryptKeystores"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.validator.arn
      },
      # EBS volume operations — EC2 needs these to use the encrypted root and data volumes.
      # kms:CreateGrant lets EC2 create a grant so the hypervisor can access the volume key.
      # Condition GrantIsForAWSResource ensures the grant is only usable by an AWS service.
      {
        Sid    = "KMSEBSVolumeAccess"
        Effect = "Allow"
        Action = [
          "kms:CreateGrant",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo"
        ]
        Resource = aws_kms_key.validator.arn
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      },
      # DescribeVolumes is needed by the user_data idempotency check
      # (detect if volume is already attached before calling AttachVolume)
      {
        Sid      = "EBSDescribe"
        Effect   = "Allow"
        Action   = ["ec2:DescribeVolumes"]
        Resource = "*"
      },
      # AttachVolume requires BOTH the volume resource and the instance resource.
      # Tag condition ensures the instance must carry the Project tag (propagated
      # by the ASG tag blocks) — prevents attaching to unrelated instances.
      {
        Sid    = "EBSSelfAttach"
        Effect = "Allow"
        Action = ["ec2:AttachVolume"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/${aws_ebs_volume.data.id}",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project" = var.project_name
          }
        }
      }
    ]
  })
}

# SSM Session Manager: allows shell access without opening SSH port
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.validator.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "validator" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.validator.name
}
