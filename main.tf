terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

# Discover available AZs and take the first two
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  cluster_name = "eks-us-east-2"
  vpc_cidr     = "10.0.0.0/16"
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)

  # Create two public and two private /20 subnets deterministically from the /16
  public_subnets = [
    cidrsubnet(local.vpc_cidr, 4, 0),
    cidrsubnet(local.vpc_cidr, 4, 1)
  ]

  private_subnets = [
    cidrsubnet(local.vpc_cidr, 4, 2),
    cidrsubnet(local.vpc_cidr, 4, 3)
  ]

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# VPC with 2 AZs, public+private subnets, NAT for private egress
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.cluster_name}-vpc"
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                       = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }

  tags = local.tags
}

# Launch template to pin the AMI for EKS managed node group
resource "aws_launch_template" "eks_nodes" {
  name_prefix           = "${local.cluster_name}-lt-"
  image_id              = "ami-0c80e2b6ccb9ad6d1"
  update_default_version = true

  # For custom AMIs, provide bootstrap to join the cluster
  user_data = base64encode(<<-EOT
    #!/bin/bash
    /etc/eks/bootstrap.sh "${local.cluster_name}"
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.cluster_name}-node"
    }
  }
}

# EKS cluster with a single managed node group of 3 t3.medium nodes
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = local.cluster_name
  cluster_version                = "1.30"
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      name         = "default"
      min_size     = 3
      max_size     = 3
      desired_size = 3

      # Instance type for worker nodes
      instance_types = ["t3.medium"]
      ami_type       = "CUSTOM"

      # Use the custom AMI via launch template
      launch_template = {
        id      = aws_launch_template.eks_nodes.id
        version = "$Latest"
      }

      # Optional extra tags for nodes
      tags = {
        "Name" = "${local.cluster_name}-mng"
      }
    }
  }

  tags = local.tags
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}
