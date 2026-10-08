resource "aws_instance" "alt-devops-playground-server" {
  ami                                  = "ami-0303e2e4a29f041a3"
  associate_public_ip_address          = true
  availability_zone                    = "eu-central-1a"
  disable_api_stop                     = false
  disable_api_termination              = false
  ebs_optimized                        = true
  force_destroy                        = false
  get_password_data                    = false
  hibernation                          = false
  instance_initiated_shutdown_behavior = "stop"
  instance_type                        = "t3.small"
  ipv6_address_count                   = 0
  key_name                             = "devops-playground"
  monitoring                           = false
  placement_partition_number           = 0
  region                               = "eu-central-1"
  secondary_private_ips                = []
  security_groups                      = [
      "launch-wizard-1",
  ]
  source_dest_check                    = true
  subnet_id                            = "subnet-09b78eb100211a9ef"
  tags                                 = {
      "Name" = "alt-devops-playground-server"
  }
  tenancy                              = "default"
  vpc_security_group_ids               = [
      "sg-010b4a7fea3f8852d",
  ]
/*
  cpu_options {
      core_count       = 1
      threads_per_core = 2
  }

  credit_specification {
      cpu_credits = "unlimited"
  }

  enclave_options {
      enabled = false
  }

  maintenance_options {
      auto_recovery = "default"
  }

  private_dns_name_options {
      enable_resource_name_dns_a_record    = true
      enable_resource_name_dns_aaaa_record = false
      hostname_type                        = "ip-name"
  }
*/
}

