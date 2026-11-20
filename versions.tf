terraform {
  # 1.11.0 introduced write-only attributes in Terraform and OpenTofu, and ephemeral variables in OpenTofu.
  required_version = ">= 1.11.0"

  required_providers {
    # 6.0.0 introduced the region attribute of the aws_region data source.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3"
    }
  }
}
