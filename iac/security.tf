/* Completed import of Security Group and Rules
import {
  to = aws_security_group.this
  id = "sg-010b4a7fea3f8852d"
}

import {
  to = aws_vpc_security_group_ingress_rule.allow_ssh
  id = "sgr-0261a3330f9a06c98"
}

import {
  to = aws_vpc_security_group_egress_rule.allow_http
  id = "sgr-082b496b3af3a3d3b"
}
*/

resource "aws_security_group" "this" {
  name        = "launch-wizard-1"
  description = "launch-wizard-1 created 2026-10-04T13:39:07.277Z"
  vpc_id      = "vpc-01c0a423e3be1437b"
}

/* Remove direct SSH access to only allow access through bastion host
resource "aws_vpc_security_group_ingress_rule" "allow_ssh" {
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.admin_cidr
  security_group_id = aws_security_group.this.id
}
*/

resource "aws_vpc_security_group_egress_rule" "allow_http" {
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  security_group_id = aws_security_group.this.id
}

// Bastion Host
resource "aws_security_group" "bastion" {
  name        = "devops-playground-bastion"
  description = "Security group for the devops-playground bastion host."
  vpc_id      = "vpc-01c0a423e3be1437b"
}

resource "aws_vpc_security_group_ingress_rule" "bastion_allow_ssh" {
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.admin_cidr
  security_group_id = aws_security_group.bastion.id
}

resource "aws_vpc_security_group_ingress_rule" "bastion_vpn" {
  from_port         = 51820
  to_port           = 51820
  ip_protocol       = "udp"
  cidr_ipv4         = "0.0.0.0/0"
  security_group_id = aws_security_group.bastion.id
}

resource "aws_vpc_security_group_egress_rule" "bastion_allow_http" {
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  security_group_id = aws_security_group.bastion.id
}

// Bastion to Server SSH access
resource "aws_vpc_security_group_ingress_rule" "allow_ssh_from_bastion" {
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = aws_security_group.bastion.id
}
