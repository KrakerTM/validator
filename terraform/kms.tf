# ── KMS CMK for validator keystore envelope encryption ──
#
# IMPORTANT: aws_kms_key has NO inline policy argument here.
# The key policy is managed by the separate aws_kms_key_policy resource below.
# This breaks the circular dependency:
#   aws_kms_key needs IAM role ARN (for key policy)
#   aws_iam_role_policy needs KMS key ARN (for resource scope)
# Solution: create both key and role with no cross-references,
# then bind them together via aws_kms_key_policy which depends on both.

resource "aws_kms_key" "validator" {
  description             = "Ethereum validator keystore encryption (${var.environment})"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = 30

  tags = {
    Name = "${local.name_prefix}-keystore-key"
  }
}

# Alias must match the value in tools/encrypt-keystore.sh
resource "aws_kms_alias" "validator" {
  name          = "alias/eth-validator-keystore"
  target_key_id = aws_kms_key.validator.key_id
}

# Key policy applied after the IAM role exists — no circular dependency.
# Replaces the default key policy entirely.
resource "aws_kms_key_policy" "validator" {
  key_id = aws_kms_key.validator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Root account retains full admin access (prevents accidental lockout)
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },

      # Auto Scaling service-linked role — REQUIRED in the key policy itself.
      # The root-account statement enables IAM control for regular IAM entities,
      # but AWS Auto Scaling's service-linked role must be explicitly listed here.
      # Without this, ASG cannot launch instances with encrypted EBS volumes.
      # Two statements are needed per AWS documentation:
      #   1. Crypto operations (encrypt/decrypt the volume data key)
      #   2. CreateGrant (lets EC2 hypervisor access the key for ongoing I/O)
      {
        Sid    = "AllowAutoScalingCryptoOps"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowAutoScalingCreateGrant"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
        }
        Action   = ["kms:CreateGrant"]
        Resource = "*"
        Condition = {
          Bool = {
            # Ensures the grant is only usable by AWS services (EC2 hypervisor),
            # not arbitrary callers
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      },

      # EC2 instance role: decrypt-only, and only with the correct encryption context.
      # Encryption context "purpose=validator-keystore" matches provision.sh and
      # tools/encrypt-keystore.sh — requests without this context are denied.
      {
        Sid    = "AllowValidatorDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.validator.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:EncryptionContext:purpose" = "validator-keystore"
          }
        }
      }
    ]
  })

  depends_on = [aws_iam_role.validator]
}
