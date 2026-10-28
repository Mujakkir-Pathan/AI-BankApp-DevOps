terraform {
  # Partial config on purpose: bucket names are globally unique, so the rest
  # comes from backend.hcl at init time. Copy backend.hcl.example → backend.hcl
  # (gitignored) after running ../bootstrap.
  backend "s3" {}
}
