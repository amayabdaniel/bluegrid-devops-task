resource "aws_security_group" "gs" {
  name        = "${var.project}-sg"
  description = "gs-rest-service host"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "app_public" {
  security_group_id = aws_security_group.gs.id
  description       = "gs-rest-service public"
  ip_protocol       = "tcp"
  from_port         = var.app_port_public
  to_port           = var.app_port_public
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "ssh_admin" {
  security_group_id = aws_security_group.gs.id
  description       = "ssh from admin"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.admin_cidr
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.gs.id
  description       = "https"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.gs.id
  description       = "dns"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ntp" {
  security_group_id = aws_security_group.gs.id
  description       = "ntp"
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_key_pair" "deploy" {
  key_name_prefix = "${var.project}-"
  public_key      = var.ssh_public_key
}

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

resource "aws_instance" "gs" {
  # checkov:skip=CKV_AWS_88: public IP required by brief (port 777 from internet)
  # checkov:skip=CKV_AWS_126: detailed monitoring is paid, brief forbids spend
  # checkov:skip=CKV_AWS_135: t2.micro does not support EBS optimization
  ami           = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type
  subnet_id     = data.aws_subnets.default.ids[0]

  vpc_security_group_ids      = [aws_security_group.gs.id]
  key_name                    = aws_key_pair.deploy.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true
  monitoring                  = false
  ebs_optimized               = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

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
    ignore_changes = [ami]
  }
}
