###############################################################################
# versions.tf
#
# Pins the Terraform CLI version and each provider version we use.
#
# WHY pin versions?
#   - A new Terraform or AWS provider release can change resource schemas,
#     deprecate arguments, or emit different plans. Pinning makes today's
#     `terraform apply` reproducible next month, next year, and on a CI runner.
#   - `~> 1.6` means ">= 1.6.0, < 2.0.0" — we accept minor+patch upgrades
#     (bug fixes, small features) but NOT a breaking major bump.
###############################################################################

terraform {
  required_version = "~> 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # Used by rds.tf to generate a strong DB password at apply time that is
    # never written to code, never passed via CLI, and stored in Secrets Manager.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
