###############################################################################
# providers.tf
#
# Configures the AWS provider and sets DEFAULT TAGS that get applied to every
# resource Terraform creates — no need to repeat `tags = {...}` on each block.
#
# WHY default_tags?
#   - Real cost tracking: Cost Explorer can group-by tag "Project" so you see
#     AutoTier spend separately from CloudDeck.
#   - Operational hygiene: if you see an orphaned resource later, tags tell
#     you which project/engineer owns it.
#   - Defensible in interviews: "every resource is tagged" is a real-world
#     governance control, not a bonus.
###############################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repo        = "github.com/jeianjaz/AutoTier"
    }
  }
}
