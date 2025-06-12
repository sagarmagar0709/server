# Terraform setup for a secure 3-tier web app architecture with S3 static website

provider "aws" {
  region = "us-east-1"
}

# -----------------------------
# S3 Bucket for Static Website
# -----------------------------
resource "aws_s3_bucket" "static_website" {
  bucket = "sagar-static-site-demo"
  acl    = "public-read"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }

  force_destroy = true
}

resource "aws_s3_bucket_policy" "static_site_policy" {
  bucket = aws_s3_bucket.static_website.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadGetObject",
        Effect    = "Allow",
        Principal = "*",
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.static_website.arn}/*"
      }
    ]
  })
}

# ----------------------
# VPC & Networking Setup
# ----------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.1"

  name = "web-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

# ----------------------
# ALB for Web Tier
# ----------------------
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "8.7.0"

  name            = "web-alb"
  load_balancer_type = "application"
  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.public_subnets
  enable_deletion_protection = false

  security_groups = [aws_security_group.alb_sg.id]

  target_groups = [
    {
      name_prefix      = "webapp"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
      health_check = {
        path = "/"
      }
    }
  ]

  listeners = [
    {
      port     = 80
      protocol = "HTTP"
      default_action = {
        type             = "forward"
        target_group_index = 0
      }
    }
  ]
}

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
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

# -------------------
# EC2 with Auto Scaling
# -------------------
module "ec2_asg" {
  source = "terraform-aws-modules/autoscaling/aws"

  name = "web-asg"

  launch_template_name = "web-template"
  launch_template_version = "$Latest"

  vpc_zone_identifier = module.vpc.private_subnets
  min_size            = 2
  max_size            = 4

  target_group_arns = [module.alb.target_group_arns[0]]

  instance_type = "t3.micro"
  image_id      = data.aws_ami.amazon_linux.id

  security_groups = [aws_security_group.ec2_sg.id]
}

resource "aws_security_group" "ec2_sg" {
  name   = "ec2-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# -------------------
# RDS Multi-AZ MySQL
# -------------------
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.3.0"

  identifier = "webapp-db"

  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  name              = "appdb"
  username          = "admin"
  password          = "StrongPassword123"

  multi_az           = true
  subnet_ids         = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot = true
}

resource "aws_security_group" "db_sg" {
  name   = "db-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ----------------
# CloudTrail + GuardDuty + IAM Least Privilege
# ----------------
resource "aws_cloudtrail" "main" {
  name                          = "cloudtrail"
  s3_bucket_name                = aws_s3_bucket.logs.id
  include_global_service_events = true
  is_multi_region_trail        = true
  enable_log_file_validation   = true
}

resource "aws_guardduty_detector" "main" {
  enable = true
}

# Least privilege IAM policy example
resource "aws_iam_policy" "least_priv" {
  name        = "LeastPrivPolicy"
  description = "Minimal S3 and EC2 access"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["ec2:Describe*", "s3:GetObject"],
        Resource = "*"
      }
    ]
  })
}

# -------------
# Logging & Backup
# -------------
resource "aws_s3_bucket" "logs" {
  bucket = "sagar-logs-secure"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_backup_vault" "default" {
  name = "default"
}

resource "aws_backup_plan" "backup" {
  name = "daily-backup"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.default.name
    schedule          = "cron(0 12 * * ? *)"
    lifecycle {
      delete_after = 30
    }
  }
}

resource "aws_backup_selection" "rds_selection" {
  name         = "rds-backup"
  iam_role_arn = aws_iam_role.backup_role.arn
  plan_id      = aws_backup_plan.backup.id

  resources = [module.db.db_instance_arn]
}

resource "aws_iam_role" "backup_role" {
  name = "backup-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "backup.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup_attach" {
  role       = aws_iam_role.backup_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
