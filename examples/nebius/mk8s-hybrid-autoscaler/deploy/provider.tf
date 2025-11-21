terraform {
  required_version = ">= 1.5.0"

  required_providers {
    nebius = {
      source = "terraform-provider.storage.eu-north1.nebius.cloud/nebius/nebius"
    }
  }
}

provider "nebius" {
  # iam_token is read from NEBIUS_IAM_TOKEN environment variable
}
