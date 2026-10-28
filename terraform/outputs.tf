# Cluster
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for cluster authentication"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN (for IRSA if needed)"
  value       = module.eks.oidc_provider_arn
}

# Networking
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs (worker nodes)"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet IDs (load balancers)"
  value       = module.vpc.public_subnets
}

# Quick commands
output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}"
}

output "argocd_initial_password" {
  description = "Command to get ArgoCD initial admin password"
  value       = "kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
}

# Secrets
output "set_bankapp_secret" {
  description = "Set the MySQL credential in Secrets Manager. Run this once after terraform apply; the ExternalSecret in k8s/external-secret.yml projects it into the bankapp namespace."

  value = <<-EOT
    DBPASS=$(openssl rand -hex 16)
    aws secretsmanager put-secret-value \
      --secret-id ${aws_secretsmanager_secret.bankapp.name} \
      --region ${local.region} \
      --secret-string "$(jq -nc --arg p "$DBPASS" \
          '{MYSQL_ROOT_PASSWORD:$p, MYSQL_USER:"root", MYSQL_PASSWORD:$p}')"
  EOT
}
