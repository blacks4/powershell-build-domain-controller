provider "aws" {}

data "http" "engineer_ip" {
  url = "https://ipv4.icanhazip.com"
}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_ami" "windows" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-${var.windows_server_version}-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  selected_ami_id   = var.ami_id != null ? var.ami_id : data.aws_ami.windows[0].id
  engineer_rdp_cidr = "${chomp(data.http.engineer_ip.response_body)}/32"
  extra_rdp_cidrs   = toset([for cidr in var.additional_allowed_rdp_cidr_blocks : trimspace(cidr) if trimspace(cidr) != ""])

  ad_ingress_rules = [
    {
      description = "DNS TCP from VPC"
      from_port   = 53
      to_port     = 53
      protocol    = "tcp"
    },
    {
      description = "DNS UDP from VPC"
      from_port   = 53
      to_port     = 53
      protocol    = "udp"
    },
    {
      description = "Kerberos TCP from VPC"
      from_port   = 88
      to_port     = 88
      protocol    = "tcp"
    },
    {
      description = "Kerberos UDP from VPC"
      from_port   = 88
      to_port     = 88
      protocol    = "udp"
    },
    {
      description = "RPC endpoint mapper from VPC"
      from_port   = 135
      to_port     = 135
      protocol    = "tcp"
    },
    {
      description = "LDAP from VPC"
      from_port   = 389
      to_port     = 389
      protocol    = "tcp"
    },
    {
      description = "SMB from VPC"
      from_port   = 445
      to_port     = 445
      protocol    = "tcp"
    },
    {
      description = "Kerberos password change TCP from VPC"
      from_port   = 464
      to_port     = 464
      protocol    = "tcp"
    },
    {
      description = "Kerberos password change UDP from VPC"
      from_port   = 464
      to_port     = 464
      protocol    = "udp"
    },
    {
      description = "DFSR from VPC"
      from_port   = 5722
      to_port     = 5722
      protocol    = "tcp"
    },
    {
      description = "AD Web Services from VPC"
      from_port   = 9389
      to_port     = 9389
      protocol    = "tcp"
    },
    {
      description = "Global catalog from VPC"
      from_port   = 3268
      to_port     = 3268
      protocol    = "tcp"
    },
    {
      description = "Global catalog over SSL from VPC"
      from_port   = 3269
      to_port     = 3269
      protocol    = "tcp"
    },
    {
      description = "Dynamic RPC from VPC"
      from_port   = 49152
      to_port     = 65535
      protocol    = "tcp"
    },
  ]

  rendered_user_data = templatefile("${path.module}/dc_build.ps1.tftpl", {
    server_name    = var.server_name
    domain_name    = var.domain_name
    netbios_name   = var.netbios_name
    dsrm_password  = var.dsrm_password
    ca_common_name = var.ca_common_name
  })

  route53_zone_name_normalized  = var.route53_zone_name == null ? null : "${trimsuffix(var.route53_zone_name, ".")}."
  route53_record_name_effective = coalesce(var.route53_record_name, "${var.server_name}.${var.domain_name}")
  certificate_target_host       = var.create_route53_record ? trimsuffix(aws_route53_record.dc[0].fqdn, ".") : aws_eip.dc.public_ip
}

resource "aws_security_group" "dc" {
  name_prefix = "${var.server_name}-dc-"
  description = "Security group for ${var.server_name} domain controller"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.ad_ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = [data.aws_vpc.selected.cidr_block]
    }
  }

  ingress {
    description = "LDAPS from Vault"
    from_port   = 636
    to_port     = 636
    protocol    = "tcp"
    cidr_blocks = [var.vault_ip_cidr]
  }

  ingress {
    description = "RDP from engineer WAN IP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [local.engineer_rdp_cidr]
  }

  dynamic "ingress" {
    for_each = local.extra_rdp_cidrs
    content {
      description = "RDP administration"
      from_port   = 3389
      to_port     = 3389
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.server_name}-dc-sg"
  }
}

resource "aws_instance" "dc" {
  ami                         = local.selected_ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.dc.id]
  associate_public_ip_address = false
  get_password_data           = false
  user_data                   = local.rendered_user_data

  tags = {
    Name = "${var.server_name}.${var.domain_name}"
    Role = "domain-controller"
  }
}

resource "aws_eip" "dc" {
  domain   = "vpc"
  instance = aws_instance.dc.id

  tags = {
    Name = "${var.server_name}-eip"
  }
}

data "aws_route53_zone" "selected" {
  count        = var.create_route53_record ? 1 : 0
  name         = local.route53_zone_name_normalized
  private_zone = var.route53_private_zone
}

resource "aws_route53_record" "dc" {
  count   = var.create_route53_record ? 1 : 0
  zone_id = data.aws_route53_zone.selected[0].zone_id
  name    = local.route53_record_name_effective
  type    = "A"
  ttl     = 300
  records = [aws_eip.dc.public_ip]
}

resource "terraform_data" "ldaps_certificate" {
  triggers_replace = [
    aws_instance.dc.id,
    aws_instance.dc.private_ip,
    aws_eip.dc.public_ip,
    local.route53_record_name_effective,
    var.vault_ip_cidr,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      cert_file="${path.module}/cert.pem"
      rm -f "$cert_file"

      for attempt in $(seq 1 60); do
        if openssl s_client -showcerts -connect "${local.certificate_target_host}:636" </dev/null 2>/dev/null \
          | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "$cert_file"; then
          if [ -s "$cert_file" ]; then
            exit 0
          fi
        fi

        sleep 30
      done

      echo "Unable to extract LDAPS certificate from ${local.certificate_target_host}:636" >&2
      exit 1
    EOT
  }

  depends_on = [
    aws_instance.dc,
    aws_eip.dc,
    aws_route53_record.dc,
  ]
}
