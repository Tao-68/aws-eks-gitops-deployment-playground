/* Completed import of EC2 instance
import {
  to = aws_instance.devops-playground-server
  identity = {
    id = "i-0f13512d756e6fa23"
  }
}
*/

resource "aws_instance" "devops-playground-server" {
  ami                    = "ami-0303e2e4a29f041a3"
  instance_type          = "t3.small"
  key_name               = "devops-playground"
  subnet_id              = "subnet-09b78eb100211a9ef"
  vpc_security_group_ids = [aws_security_group.this.id]
    root_block_device {
    volume_size = 20
  }
  lifecycle {
    prevent_destroy = true
  }
  tags = {
    Name = "devops-playground-server"
  }
}

resource "aws_instance" "bastion" {
  ami                    = "ami-0dbce11a00a38ace4"
  instance_type          = "t3.micro"
  key_name               = "devops-playground"
  subnet_id              = "subnet-09b78eb100211a9ef"
  vpc_security_group_ids = [aws_security_group.bastion.id]
  tags = {
    Name = "devops-playground-bastion"
  }
}

