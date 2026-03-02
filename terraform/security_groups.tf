# ── Validator Security Group ──
#
# Exposed ports:
#   30303 tcp+udp — Nethermind execution layer P2P
#   9000  tcp+udp — Nimbus consensus layer P2P
#   22    tcp     — SSH 
#
# NOT exposed (intentionally absent from ingress):
#   5052  — Nimbus beacon REST API (access via kubectl port-forward or SSM tunnel)
#   8545  — Nethermind JSON-RPC (internal to Minikube only)
#   8551  — Engine API / JWT (internal Nethermind↔Nimbus only)
#   3000  — Grafana (access via kubectl port-forward)
#   9090  — Prometheus (internal only)


# Gets pub IP of executor 
data "http" "myip" {
  url = "https://ipv4.icanhazip.com"
}

resource "aws_security_group" "validator" {
  name        = "${local.name_prefix}-sg"
  description = "Ethereum validator node P2P and SSH only"
  vpc_id      = local.resolved_vpc_id

  # ── Nethermind P2P ──
  ingress {
    description = "Nethermind P2P TCP"
    from_port   = 30303
    to_port     = 30303
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Nethermind P2P UDP"
    from_port   = 30303
    to_port     = 30303
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ── Nimbus consensus P2P ──
  ingress {
    description = "Nimbus P2P TCP"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Nimbus P2P UDP"
    from_port   = 9000
    to_port     = 9000
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ── SSH ──
  # Restrict to your IP(s) via var.ssh_cidr_blocks in terraform.tfvars.
  # Alternatively, remove this rule entirely and use SSM Session Manager.
  ingress {
    description = "SSH operator access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.myip.response_body)}/32"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}
