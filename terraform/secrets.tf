# AWS Secrets Manager + External Secrets Operator wiring.
#
# The plaintext Secret (k8s/secrets.yml) is gone on purpose: credentials now
# live in Secrets Manager and are projected into the cluster by the External
# Secrets Operator (installed by gitops/argocd/platform/external-secrets.yaml).

data "aws_caller_identity" "current" {}

# Container-only: the password itself is set out of band with the
# set_bankapp_secret output (see outputs.tf).
resource "aws_secretsmanager_secret" "bankapp" {
  name        = var.bankapp_secret_name
  description = "BankApp in-cluster MySQL credentials. Value set out of band; see terraform/README.md."

  # 0 = delete now. The 30-day default blocks recreating this secret for a month after destroy.
  recovery_window_in_days = 0

  tags = local.tags
}

# Pod Identity, not IRSA: no SA annotation, and associations may name
# namespaces that don't exist yet at apply time.
module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                           = "${local.name}-external-secrets"
  attach_external_secrets_policy = true

  external_secrets_create_permission = false

  external_secrets_ssm_parameter_arns = []

  external_secrets_secrets_manager_arns = [
    "arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:bankapp/*",
  ]

  associations = {
    this = {
      cluster_name = module.eks.cluster_name
      namespace    = "external-secrets"
      # Must match the ServiceAccount the ESO chart creates.
      service_account = "external-secrets"
    }
  }

  tags = local.tags
}
