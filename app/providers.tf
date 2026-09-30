provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "youtube-cloud-backup"
      ManagedBy = "terraform"
    }
  }
}
