provider "aws" {
  region = "us-east-1"
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "demo-eks-cluster"
  cluster_version = "1.29"

  # Let the module create a VPC for you
  create_vpc = true

  vpc_cidr = "10.0.0.0/16"
  subnet_ids = []         # Not needed if create_vpc = true
  vpc_id     = null       # Not needed if create_vpc = true

  azs = ["us-east-1a", "us-east-1b"]

  eks_managed_node_groups = {
    default = {
      desired_capacity = 2
      max_capacity     = 3
      min_capacity     = 1
      instance_types   = ["t3.medium"]
    }
  }
}
