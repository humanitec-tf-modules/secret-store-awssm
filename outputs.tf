output "secret_store_id" {
  description = "ID of the secret store, i.e. the name of the Kubernetes `SecretStore` resource. This is either `secret_store_id` or the generated ID. Use it as the `store` in secret references."
  value       = local.secret_store_id
  # Consumers of the ID should wait for the SecretStore, once it can be created
  depends_on = [kubernetes_manifest.secret_store]
}
output "secret_store_namespace" {
  description = "Name of the Kubernetes namespace of the `SecretStore` resource. This is the Operator namespace for a cluster-wide store, or the Environment namespace for an Environment-local store."
  value       = local.secret_store_namespace
  depends_on  = [kubernetes_manifest.secret_store]
}
output "secret_store_ready" {
  description = "Whether the module manages the `SecretStore` resource. This is `false` if the `SecretStore` CRD was not present on the cluster during planning. In that case, apply the configuration again once the Operator is installed. See [Installation order](#installation-order)."
  value       = local.secret_store_crd_ready
}
output "secrets_manager_region" {
  description = "AWS region of the Secrets Manager."
  value       = local.secrets_manager_region
}
output "aws_account_id" {
  description = "ID of the AWS account of the Secrets Manager and the IAM objects."
  value       = data.aws_caller_identity.current.account_id
}
output "iam_policy_arn" {
  description = "ARN of the IAM policy granting the Operator access to the Secrets Manager."
  value       = aws_iam_policy.operator.arn
}
output "iam_policy_name" {
  description = "Name of the IAM policy granting the Operator access to the Secrets Manager."
  value       = aws_iam_policy.operator.name
}
output "operator_principal_arn" {
  description = "ARN of the IAM role or IAM user used by the Operator, depending on `auth_method`."
  value       = local.operator_principal_arn
}
output "iam_role_arn" {
  description = "ARN of the IAM role used by the Operator. Returns `null` if `auth_method` is `iam_user`."
  value       = local.iam_role_arn
}
output "iam_role_name" {
  description = "Name of the IAM role used by the Operator. Returns `null` if `auth_method` is `iam_user`."
  value       = local.iam_role_name
}
output "iam_role_unique_id" {
  description = "Stable and unique ID of the IAM role used by the Operator. Returns `null` if `auth_method` is `iam_user`."
  value       = local.iam_role_unique_id
}
output "iam_role_trust_policy" {
  description = "Trust policy allowing the Operator service account to assume the IAM role via EKS Pod Identity or IRSA, depending on `auth_method`, in JSON format. If `iam_role_create` is `false`, configure this trust policy on the IAM role yourself. Returns `null` if `auth_method` is `iam_user`, or if `auth_method` is `irsa` and `eks_cluster_name` is not set."
  value       = local.iam_role_trust_policy
}
output "pod_identity_association_id" {
  description = "ID of the EKS Pod Identity association created by the module. Returns `null` if `auth_method` is not `pod_identity` or `pod_identity_association_create` is `false`."
  value       = one(aws_eks_pod_identity_association.operator[*].association_id)
}
output "pod_identity_association" {
  description = "Cluster name, namespace, and service account of the EKS Pod Identity association allowing the Operator to use the IAM role. If `pod_identity_association_create` is `false`, configure an association with these values and the `iam_role_arn` yourself. Returns `null` if `auth_method` is not `pod_identity`."
  value       = local.pod_identity_association
}
output "operator_serviceaccount_annotations" {
  description = "Annotations to set on the Operator service account so that it assumes the IAM role via IRSA, e.g. via the `controllerManager.serviceAccount.annotations` value of the Operator Helm chart. Restart the Operator after changing them. Returns an empty map if `auth_method` is not `irsa`, as EKS Pod Identity requires no annotation."
  value       = local.use_irsa ? tomap({ "eks.amazonaws.com/role-arn" = local.iam_role_arn }) : tomap({})
}
output "iam_user_arn" {
  description = "ARN of the IAM user used by the Operator. Returns `null` if `auth_method` is not `iam_user`."
  value       = local.iam_user_arn
}
output "iam_user_name" {
  description = "Name of the IAM user used by the Operator. Returns `null` if `auth_method` is not `iam_user`."
  value       = local.iam_user_name
}
output "iam_user_unique_id" {
  description = "Stable and unique ID of the IAM user used by the Operator. Returns `null` if `auth_method` is not `iam_user`."
  value       = local.iam_user_unique_id
}
output "iam_user_credentials_secret_name" {
  description = "Name of the Kubernetes Secret holding the access key of the IAM user, located in the `secret_store_namespace`. Returns `null` if `auth_method` is not `iam_user`."
  value       = one(kubernetes_secret_v1.operator_credentials[*].metadata[0].name)
}
output "cross_account_secret_resource_policy" {
  description = "Resource policy allowing the Operator to read a secret, in JSON format. Attach it to each secret in another AWS account you want to reference."
  value       = data.aws_iam_policy_document.cross_account_secret_resource_policy.json
}
output "cross_account_kms_key_policy" {
  description = "Key policy statement allowing the Operator to decrypt a secret, as a policy document in JSON format. Add it to the key policy of the KMS key encrypting each secret in another AWS account you want to reference, e.g. via the `source_policy_documents` of an `aws_iam_policy_document`. Do not use it as the complete key policy."
  value       = data.aws_iam_policy_document.cross_account_kms_key_policy.json
}
