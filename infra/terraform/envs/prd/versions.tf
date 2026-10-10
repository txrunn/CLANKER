terraform {
  required_version = ">= 1.9.0"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }

  # State stays on the operator's machine (gitignored). It contains no
  # secrets: keys flow from .env to Ansible without passing through Terraform.
  # To share state, swap in any remote backend; nothing else changes.
  backend "local" {
    path = "terraform.tfstate"
  }
}
