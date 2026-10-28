# Terraform bootstrap — S3 state bucket

One-time setup layer with **local state** that creates the S3 bucket holding
the parent `../` configuration's state. Bucket names are globally unique, so
this layer must exist before `../backend.tf` can be initialized.

## Usage

```bash
cd terraform/bootstrap
terraform init
terraform apply
terraform output -raw backend_hcl > ../backend.hcl   # gitignored
cd ..
terraform init        # picks up backend.hcl, offers to migrate any local state
```

## Notes

- `backend.hcl` is gitignored — it is account-specific. Commit
  `backend.hcl.example` as the template instead.
- State locking is **S3-native** (`use_lockfile = true`, GA since Terraform
  1.11) — no DynamoDB lock table needed.
- Teardown order matters: destroy `../` first, then this layer. Destroying
  this bucket while it still holds state data-loses the cluster inventory.
