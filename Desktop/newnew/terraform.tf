provider "aws" {
  region = "us-east-1"  # Change to your desired region
}

resource "aws_instance" "example" {
  count         = 3  # This will create 2 instances
  ami           = "ami-02114c987fa96ee6c"  # Amazon Linux 2 AMI (replace with a suitable AMI ID for your region)
  instance_type = "t2.micro"  # Change instance type if needed

  tags = {
    Name = "MyInstance-${count.index + 1}"
  }
}
