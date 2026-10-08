import {
  to = aws_instance.devops-playground-server
  identity = {
    id = "i-0f13512d756e6fa23"
  }
}

resource "aws_instance" "devops-playground-server" {
  ami                 = "ami-0303e2e4a29f041a3"
  instance_type       = "t3.micro"
  tags = {
    Name = "devops-playground-server"
  }
}

