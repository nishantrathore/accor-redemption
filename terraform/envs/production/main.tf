terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }

  backend "s3" {
    bucket         = "accor-tf-state-prod"
    key            = "redemption/production/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "accor-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "redemption"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "sre-team"
    }
  }
}

# ── VPC ──────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  name               = "redemption-${var.environment}"
  cidr               = var.vpc_cidr
  availability_zones = var.availability_zones
  environment        = var.environment
}

# ── IAM ──────────────────────────────────────────────────────────────────────
module "iam" {
  source = "../../modules/iam"

  cluster_name = "redemption-${var.environment}"
  environment  = var.environment
  aws_region   = var.aws_region
  account_id   = data.aws_caller_identity.current.account_id
}

# ── Security Groups ──────────────────────────────────────────────────────────
module "security_groups" {
  source = "../../modules/security-groups"

  name        = "redemption-${var.environment}"
  vpc_id      = module.vpc.vpc_id
  environment = var.environment
}

# ── EKS ──────────────────────────────────────────────────────────────────────
module "eks" {
  source = "../../modules/eks"

  cluster_name       = "redemption-${var.environment}"
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  cluster_role_arn        = module.iam.cluster_role_arn
  node_role_arn           = module.iam.node_role_arn
  cluster_sg_id           = module.security_groups.cluster_sg_id
  additional_sg_ids       = [module.security_groups.nodes_sg_id]

  # Baseline node group — always on, across 3 AZs
  baseline_node_config = {
    instance_types = ["m6i.xlarge"]
    min_size       = 3
    desired_size   = 3
    max_size       = 6
    capacity_type  = "ON_DEMAND"
  }

  # Burst node group — Spot, scales during Flash Sales
  burst_node_config = {
    instance_types = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge"]
    min_size       = 0
    desired_size   = 0
    max_size       = 30
    capacity_type  = "SPOT"
  }

  environment = var.environment
}

data "aws_caller_identity" "current" {}
