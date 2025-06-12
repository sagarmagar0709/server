# Terraform configuration to launch a 3-tier architecture with S3 static website hosting

provider "aws" {
  region = "us-east-1"
}

# S3 Static Website Bucket
resource "aws_s3_bucket" "static_website" {
  bucket = "sagar-static-website-demo"
  acl    = "public-read"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_s3_bucket_policy" "website_policy" {
  bucket = aws_s3_bucket.static_website.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject"]
        Resource  = ["${aws_s3_bucket.static_website.arn}/*"]
      }
    ]
  })
}

# VPC
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name   = "my-vpc"
  cidr   = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
  create_database_subnet_group = true
  database_subnets       = ["10.0.5.0/24", "10.0.6.0/24"]
}

# Security Group
resource "aws_security_group" "web_sg" {
  name        = "web-sg"
  description = "Allow HTTP"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch Template
resource "aws_launch_template" "app" {
  name_prefix   = "app-template"
  image_id      = "ami-0c02fb55956c7d316" # Amazon Linux 2
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.web_sg.id]
  user_data              = filebase64("./user_data.sh")
}

# Auto Scaling Group
resource "aws_autoscaling_group" "app_asg" {
  desired_capacity     = 2
  max_size             = 3
  min_size             = 1
  vpc_zone_identifier  = module.vpc.private_subnets
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "AppServer"
    propagate_at_launch = true
  }
}

# ALB
module "alb" {
  source = "terraform-aws-modules/alb/aws"

  name               = "web-alb"
  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets

  security_groups = [aws_security_group.web_sg.id]

  target_groups = [
    {
      name_prefix      = "app"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
      health_check     = {
        path                = "/"
        protocol            = "HTTP"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 5
        unhealthy_threshold = 2
      }
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]
}

# RDS
module "rds" {
  source = "terraform-aws-modules/rds/aws"

  identifier = "mydb"
  engine     = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage    = 20
  storage_encrypted    = true
  multi_az             = true
  db_subnet_group_name = module.vpc.database_subnet_group

  username = "admin"
  password = "Password123!"

  vpc_security_group_ids = [aws_security_group.web_sg.id]
  subnet_ids             = module.vpc.private_subnets
  publicly_accessible    = false
  skip_final_snapshot    = true
}

# IAM - Least Privilege Example
resource "aws_iam_policy" "read_s3" {
  name = "ReadOnlyS3Policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = ["s3:GetObject"],
        Effect = "Allow",
        Resource = "*"
      }
    ]
  })
}

# Enable CloudTrail
resource "aws_cloudtrail" "main" {
  name                          = "main-trail"
  s3_bucket_name                = aws_s3_bucket.static_website.bucket
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true
}

# Enable GuardDuty
resource "aws_guardduty_detector" "main" {
  enable = true
}

# AWS Backup Plan
resource "aws_backup_vault" "default" {
  name = "default"
}

resource "aws_backup_plan" "rds_backup" {
  name = "rds-backup"

  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.default.name
    schedule          = "cron(0 12 * * ? *)"
    lifecycle {
      delete_after = 30
    }
  }
}

resource "aws_backup_selection" "rds_selection" {
  name         = "rds-selection"
  plan_id      = aws_backup_plan.rds_backup.id
  resources    = [module.rds.db_instance_arn]
  iam_role_arn = aws_iam_role.backup_role.arn
}

resource "aws_iam_role" "backup_role" {
  name = "backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "backup.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}
