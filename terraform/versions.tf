terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.80" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # Bucket is created once by hand (README step 1)
  backend "s3" {
    bucket       = "innovatech-tfstate-zc2026"
    key          = "hybrid-cloud/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "innovatech-hybrid", ManagedBy = "terraform", Assignment = "CS2-MA-NCA" }
  }
}
