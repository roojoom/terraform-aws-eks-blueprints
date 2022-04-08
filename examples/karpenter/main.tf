terraform {
  required_version = ">= 1.0.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.66.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.6.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.4.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.13.1"
    }
  }

  backend "local" {
    path = "local_tf_state/terraform-main.tfstate"
  }
}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {}

data "aws_eks_cluster" "cluster" {
  name = module.aws-eks-accelerator-for-terraform.eks_cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.aws-eks-accelerator-for-terraform.eks_cluster_id
}

data "aws_ami" "amazonlinux2eks" {
  most_recent = true
  filter {
    name   = "name"
    values = [local.amazonlinux2eks]
  }
  owners = ["amazon"]
}

data "aws_ami" "bottlerocket" {
  most_recent = true
  filter {
    name   = "name"
    values = [local.bottlerocket]
  }
  owners = ["amazon"]
}

provider "aws" {
  region = data.aws_region.current.id
  alias  = "default"
}

provider "kubernetes" {
  experiments {
    manifest_resource = true
  }
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    token                  = data.aws_eks_cluster_auth.cluster.token
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
  apply_retry_count      = 10
}

locals {
  tenant      = var.tenant      # AWS account name or unique id for tenant
  environment = var.environment # Environment area eg., preprod or prod
  zone        = var.zone        # Environment with in one sub_tenant or business unit
  azs         = slice(data.aws_availability_zones.available.names, 0, 3)

  cluster_version = var.cluster_version

  vpc_cidr        = "10.0.0.0/16"
  vpc_name        = join("-", [local.tenant, local.environment, local.zone, "vpc"])
  cluster_name    = join("-", [local.tenant, local.environment, local.zone, "eks"])
  node_group_name = "self-ondemand"
  amazonlinux2eks = "amazon-eks-node-${var.cluster_version}-*"
  bottlerocket    = "bottlerocket-aws-k8s-${var.cluster_version}-x86_64-*"

  terraform_version = "Terraform v1.0.1"
}

module "aws_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "v3.2.0"

  name = local.vpc_name
  cidr = local.vpc_cidr
  azs  = local.azs

  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  create_igw           = true
  enable_dns_hostnames = true
  single_nat_gateway   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}
#---------------------------------------------------------------
# Example to consume aws-eks-accelerator-for-terraform module
#---------------------------------------------------------------
module "aws-eks-accelerator-for-terraform" {
  source = "../.."

  tenant            = local.tenant
  environment       = local.environment
  zone              = local.zone
  terraform_version = local.terraform_version

  # EKS Cluster VPC and Subnet mandatory config
  vpc_id             = module.aws_vpc.vpc_id
  private_subnet_ids = module.aws_vpc.private_subnets

  # EKS CONTROL PLANE VARIABLES
  cluster_version = local.cluster_version

  # Allow Ingress rule for Worker node groups from Cluster Sec group for Karpenter
  node_security_group_additional_rules = {
    ingress_nodes_karpenter_port = {
      description                   = "Cluster API to Nodegroup for Karpenter"
      protocol                      = "tcp"
      from_port                     = 8443
      to_port                       = 8443
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }
  # Self-managed Node Group
  # Karpenter requires one node to get up and running
  self_managed_node_groups = {
    self_mg_4 = {
      node_group_name    = local.node_group_name
      launch_template_os = "amazonlinux2eks"
      max_size           = 1
      subnet_ids         = module.aws_vpc.private_subnets
    }
  }
}


# Creates Launch templates for Karpenter
# Launch template outputs will be used in Karpenter Provisioners yaml files. Checkout this examples/karpenter/provisioners/default_provisioner_with_launch_templates.yaml
module "karpenter-launch-templates" {
  source         = "../../modules/launch-templates"
  eks_cluster_id = module.aws-eks-accelerator-for-terraform.eks_cluster_id
  tags           = { Name = "karpenter" }

  launch_template_config = {
    linux = {
      ami                    = data.aws_ami.amazonlinux2eks.id
      launch_template_prefix = "karpenter"
      iam_instance_profile   = module.aws-eks-accelerator-for-terraform.self_managed_node_group_iam_instance_profile_id[0]
      vpc_security_group_ids = [module.aws-eks-accelerator-for-terraform.worker_node_security_group_id]
      block_device_mappings = [
        {
          device_name = "/dev/xvda"
          volume_type = "gp3"
          volume_size = "200"
        }
      ]
    },
    bottlerocket = {
      ami                    = data.aws_ami.bottlerocket.id
      launch_template_os     = "bottlerocket"
      launch_template_prefix = "bottle"
      iam_instance_profile   = module.aws-eks-accelerator-for-terraform.self_managed_node_group_iam_instance_profile_id[0]
      vpc_security_group_ids = [module.aws-eks-accelerator-for-terraform.worker_node_security_group_id]
      block_device_mappings = [
        {
          device_name = "/dev/xvda"
          volume_type = "gp3"
          volume_size = "200"
        }
      ]
    },
  }
}

module "kubernetes-addons" {
  source = "../../modules/kubernetes-addons"

  eks_cluster_id = module.aws-eks-accelerator-for-terraform.eks_cluster_id

  # Deploys Karpenter add-on
  enable_karpenter = true

  depends_on = [module.aws-eks-accelerator-for-terraform.self_managed_node_groups]
}

# Deploying default provisioner for Karpenter autoscaler
data "kubectl_path_documents" "karpenter_provisioners" {
  pattern = "${path.module}/provisioners/default_provisioner.yaml"
  vars = {
    azs                     = join(",", local.azs)
    iam-instance-profile-id = format("%s-%s", local.cluster_name, local.node_group_name)
    eks-cluster-id          = local.cluster_name
  }
}

# You can also deploy multiple provisioner files with the below code snippet
# data "kubectl_path_documents" "karpenter_provisioners" {
#   pattern = "${path.module}/provisioners/*.yaml"
# }

resource "kubectl_manifest" "karpenter_provisioner" {
  for_each  = toset(data.kubectl_path_documents.karpenter_provisioners.documents)
  yaml_body = each.value

  depends_on = [module.kubernetes-addons]
}

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = module.aws-eks-accelerator-for-terraform.configure_kubectl
}
