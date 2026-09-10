terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0" # check registry.terraform.io/providers/hashicorp/azuread for the
                          # current release before first `terraform init` — this provider
                          # ships often. Same version constraint as the CA-Baseline project,
                          # kept in sync deliberately.
    }
  }
}

# Same auth pattern as CA-Baseline/terraform/providers.tf: client-secret auth via the app
# registration created by bootstrap/New-AppRegistration.ps1 (demo/one-engagement tenant),
# values from ARM_TENANT_ID / ARM_CLIENT_ID / ARM_CLIENT_SECRET environment variables so
# nothing sensitive lives in this repo. Swap for OIDC/federated credentials before this runs
# against anything longer-lived than a single engagement.
provider "azuread" {}
