################################################################################
# ExamplePay Production - eu-west-1 (DR / EU Traffic)
################################################################################

terraform {
  required_version = ">= 1.6.0"

  backend "s3" {
    bucket         = "examplepay-prod-tfstate-eu-west-1"
    key            = "eks/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "examplepay-prod-tfstate-lock"
    encrypt        = true
  }

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
      version = "~> 2.12"
    }
  }
}

provider "aws" {
  region = "eu-west-1"

  assume_role {
    role_arn = "arn:aws:iam::role/TerraformDeployRole"
  }

  default_tags {
    tags = {
      Environment = "prod"
      ManagedBy   = "terraform"
      Project     = "examplepay"
      Region      = "eu-west-1"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "eu-west-1"]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "eu-west-1"]
    }
  }
}

################################################################################
# Local Variables
################################################################################

locals {
  cluster_name = "examplepay-prod-eu"
  region       = "eu-west-1"

  azs = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

  vpc_cidr             = "10.20.0.0/16"
  private_subnet_cidrs = ["10.20.0.0/19", "10.20.32.0/19", "10.20.64.0/19"]
  public_subnet_cidrs  = ["10.20.128.0/22", "10.20.132.0/22", "10.20.136.0/22"]

  common_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

################################################################################
# Bastion Security Group
################################################################################

resource "aws_security_group" "bastion" {
  name_prefix = "${local.cluster_name}-bastion-"
  vpc_id      = module.vpc.vpc_id
  description = "Security group for bastion host / VPN access to EKS API"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.cluster_name}-bastion-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source = "../../../modules/vpc"

  name               = local.cluster_name
  cidr               = local.vpc_cidr
  availability_zones = local.azs

  private_subnet_cidrs = local.private_subnet_cidrs
  public_subnet_cidrs  = local.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = false
  enable_flow_logs     = true
  flow_log_destination = "s3"

  tags = local.common_tags
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source = "../../../modules/eks"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids

  bastion_security_group_id = aws_security_group.bastion.id
  bootstrap_node_count      = 2
  log_retention_days        = 90

  tags = local.common_tags
}

################################################################################
# Transit Gateway (accept peering from us-east-1)
################################################################################

module "transit_gateway" {
  source = "../../../modules/transit-gateway"

  name       = local.cluster_name
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  tags = local.common_tags
}
