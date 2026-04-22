# =============================================================================
# Network: Security Group for the EC2 host
# =============================================================================
# Strict egress = HTTPS-only (so the host can pull images, talk to SSM,
# send Slack webhooks, and download dnf updates) plus DNS. No SMTP, no plain
# HTTP. Anything else has to be added explicitly.
# =============================================================================

resource "aws_security_group" "gs" {
  name        = "${var.project}-sg"
  description = "gs-rest-service host: 777 from world, 22 from admin only"
  vpc_id      = data.aws_vpc.default.id
}

# Inbound: app port 777 from anywhere
resource "aws_vpc_security_group_ingress_rule" "app_public" {
  security_group_id = aws_security_group.gs.id
  description       = "gs-rest-service public"
  ip_protocol       = "tcp"
  from_port         = var.app_port_public
  to_port           = var.app_port_public
  cidr_ipv4         = "0.0.0.0/0"
}

# Inbound: SSH 22 from your IP only
resource "aws_vpc_security_group_ingress_rule" "ssh_admin" {
  security_group_id = aws_security_group.gs.id
  description       = "SSH from admin only"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.admin_cidr
}

# Egress: HTTPS for image pulls, SSM, Slack, package updates
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.gs.id
  description       = "HTTPS to anywhere (image pulls, SSM, Slack, updates)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Egress: DNS (UDP) — needed before HTTPS resolves
resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.gs.id
  description       = "DNS resolution"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"
}

# Egress: NTP (UDP 123) — clock sync matters for cosign / TLS
resource "aws_vpc_security_group_egress_rule" "ntp" {
  security_group_id = aws_security_group.gs.id
  description       = "NTP for clock sync"
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
  cidr_ipv4         = "0.0.0.0/0"
}

# =============================================================================
# Key pair
# =============================================================================

resource "aws_key_pair" "deploy" {
  key_name_prefix = "${var.project}-"
  public_key      = var.ssh_public_key
}

# =============================================================================
# IAM instance profile: minimum to be reachable via SSM Session Manager / RunCommand
# =============================================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name_prefix        = "${var.project}-ec2-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "${var.project}-ec2-"
  role        = aws_iam_role.ec2.name
}

# =============================================================================
# EC2 instance
# =============================================================================

resource "aws_instance" "gs" {
  # checkov:skip=CKV_AWS_88: Public IP is REQUIRED — the brief mandates the
  #   service be reachable on port 777 from the public internet.
  # checkov:skip=CKV_AWS_126: Detailed CloudWatch monitoring costs money and
  #   the brief explicitly forbids commercial spend.
  # checkov:skip=CKV_AWS_135: t2.micro does not support EBS optimization;
  #   setting it true would be a no-op at best, an error at worst.
  ami           = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type
  subnet_id     = data.aws_subnets.default.ids[0]

  vpc_security_group_ids      = [aws_security_group.gs.id]
  key_name                    = aws_key_pair.deploy.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true
  monitoring                  = false # detailed monitoring is NOT free tier
  ebs_optimized               = false # t2.micro doesn't support it anyway

  # ----- IMDSv2 enforced (defends against SSRF -> creds theft) -----
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # ----- Encrypted root volume (Free Tier: 30 GB EBS gp3) -----
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
    tags = {
      Name = "${var.project}-root"
    }
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/userdata.sh.tftpl", {
    ssh_public_key    = var.ssh_public_key
    image_ref         = var.image_ref
    app_port_internal = var.app_port_internal
    app_port_public   = var.app_port_public
  })

  tags = {
    Name = "${var.project}-host"
  }

  lifecycle {
    ignore_changes = [ami] # let dnf-automatic patch in place; rebuild on demand
  }
}
