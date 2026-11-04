data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# Random suffix for the fallback ID of the secret store
resource "random_string" "secret_store_id_suffix" {
  count   = var.secret_store_id == null ? 1 : 0
  length  = 4
  upper   = false
  numeric = false
  special = false
}

# Random suffix for the fallback names of the IAM objects
resource "random_string" "iam_name_suffix" {
  count   = local.iam_name_suffix_required ? 1 : 0
  length  = 4
  upper   = false
  numeric = false
  special = false
}

locals {
  use_pod_identity = var.auth_method == "pod_identity"
  use_irsa         = var.auth_method == "irsa"
  use_iam_role     = local.use_pod_identity || local.use_irsa
  use_iam_user     = var.auth_method == "iam_user"

  # ID of the secret store: the ID passed in, or the generated ID
  secret_store_id = var.secret_store_id != null ? var.secret_store_id : "awssm-${random_string.secret_store_id_suffix[0].result}"

  # A cluster-wide secret store lives in the Operator namespace, an Environment-local store in the Environment namespace
  secret_store_namespace = var.secret_store_cluster_wide ? var.operator_namespace : var.secret_store_namespace

  secrets_manager_region = coalesce(var.secrets_manager_region, data.aws_region.current.region)

  # The Operator needs write access to the default store only, e.g. for storing resource cookies
  secret_store_actions = var.secret_store_default ? [
    "secretsmanager:GetSecretValue",
    "secretsmanager:CreateSecret",
    "secretsmanager:DeleteSecret",
    "secretsmanager:PutSecretValue",
    "secretsmanager:RestoreSecret",
  ] : ["secretsmanager:GetSecretValue"]
  secret_store_resource_arn = join(":", [
    "arn",
    data.aws_partition.current.partition,
    "secretsmanager",
    local.secrets_manager_region,
    data.aws_caller_identity.current.account_id,
    "secret",
    "${var.secret_name_prefix != null ? var.secret_name_prefix : ""}*",
  ])

  cross_account_secret_arns  = distinct([for s in var.cross_account_secrets : s.secret_arn])
  cross_account_kms_key_arns = distinct([for s in var.cross_account_secrets : s.kms_key_arn])

  # AWS limits IAM role and user names to 64 characters, and IAM policy names to 128 characters.
  # Truncate the prefix so the "-" separator and the full random suffix always fit.
  # Secret store IDs only contain characters that IAM allows in names, so no replacement is needed.
  iam_name_max_length = 64
  iam_name_prefix     = substr("humanitec-operator-${local.secret_store_id}", 0, local.iam_name_max_length - 5)
  iam_name_suffix_required = (
    var.iam_policy_name == null ||
    (local.use_iam_role && var.iam_role_create && var.iam_role_name == null) ||
    (local.use_iam_user && var.iam_user_create && var.iam_user_name == null)
  )
  iam_generated_name = local.iam_name_suffix_required ? "${local.iam_name_prefix}-${random_string.iam_name_suffix[0].result}" : null

  # Account IDs and names of existing IAM objects, parsed from their ARNs
  existing_role_arn_parts = var.iam_role_arn != null ? regex(local.iam_role_arn_pattern, var.iam_role_arn) : null
  existing_user_arn_parts = var.iam_user_arn != null ? regex(local.iam_user_arn_pattern, var.iam_user_arn) : null

  # Attributes read back from the IAM role or user, so that references depend on them existing.
  # At most one of each pair exists, so one() yields null if the respective auth method is not used.
  iam_role_arn       = one(concat(aws_iam_role.operator[*].arn, data.aws_iam_role.operator[*].arn))
  iam_role_name      = one(concat(aws_iam_role.operator[*].name, data.aws_iam_role.operator[*].name))
  iam_role_unique_id = one(concat(aws_iam_role.operator[*].unique_id, data.aws_iam_role.operator[*].unique_id))
  iam_user_arn       = one(concat(aws_iam_user.operator[*].arn, data.aws_iam_user.operator[*].arn))
  iam_user_name      = one(concat(aws_iam_user.operator[*].name, data.aws_iam_user.operator[*].user_name))
  iam_user_unique_id = one(concat(aws_iam_user.operator[*].unique_id, data.aws_iam_user.operator[*].user_id))

  # ARN of the IAM identity the Operator uses, either the role or the user
  operator_principal_arn = local.use_iam_role ? local.iam_role_arn : local.iam_user_arn

  # Trust policy of the IAM role, depending on the mechanism used to assume it. null if not available.
  iam_role_trust_policy = one(concat(
    data.aws_iam_policy_document.operator_pod_identity_trust[*].json,
    data.aws_iam_policy_document.operator_irsa_trust[*].json,
  ))

  # EKS Pod Identity association settings for the Operator service account
  pod_identity_association = local.use_pod_identity ? {
    cluster_name    = var.eks_cluster_name
    namespace       = var.operator_namespace
    service_account = var.operator_serviceaccount
  } : null

  # Credentials of the IAM user, either from the access key created by the module or passed in.
  # The secret access key is ephemeral if passed in, and is only ever written to write-only attributes.
  iam_user_access_key_id     = var.iam_user_create ? one(aws_iam_access_key.operator[*].id) : var.iam_user_access_key_id
  iam_user_secret_access_key = var.iam_user_create ? one(aws_iam_access_key.operator[*].secret) : var.iam_user_secret_access_key
  iam_user_credentials_secret_name = (
    local.use_iam_user
    ? coalesce(var.iam_user_credentials_secret_name, "${local.secret_store_id}-credentials")
    : null
  )

  # SecretStore resource, see https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-aws-secrets-manager/
  secret_store_metadata = merge(
    {
      name      = local.secret_store_id
      namespace = local.secret_store_namespace
    },
    var.secret_store_default ? { labels = { "app.humanitec.io/default-store" = "true" } } : {},
  )
  # Authentication of the secret store, depending on the auth method.
  # With an IAM user, the store references the access key in the credentials Secret.
  # With EKS Pod Identity or IRSA, the Operator uses the IAM role of its service account, which requires an empty auth.
  # Select the value by key instead of using a conditional: a conditional would convert both values into a map,
  # and kubernetes_manifest cannot convert an empty map into the auth object of the SecretStore CRD.
  secret_store_auth = {
    iam_user = {
      accessKeyIDSecretRef = {
        name = local.iam_user_credentials_secret_name
        key  = "access_key_id"
      }
      secretAccessKeySecretRef = {
        name = local.iam_user_credentials_secret_name
        key  = "secret_access_key"
      }
    }
    iam_role = {}
  }[local.use_iam_user ? "iam_user" : "iam_role"]

  # Patterns for IAM role and user ARNs, also used by the iam_role_arn and iam_user_arn validations
  iam_role_arn_pattern = "^arn:aws[a-z-]*:iam::(?P<account_id>[0-9]{12}):role/(?:[^/]+/)*(?P<name>[\\w+=,.@-]+)$"
  iam_user_arn_pattern = "^arn:aws[a-z-]*:iam::(?P<account_id>[0-9]{12}):user/(?:[^/]+/)*(?P<name>[\\w+=,.@-]+)$"
}

# IAM policy granting the Operator access to the Secrets Manager

data "aws_iam_policy_document" "operator" {
  version = "2012-10-17"
  statement {
    sid       = "SecretStoreAccess"
    effect    = "Allow"
    actions   = local.secret_store_actions
    resources = [local.secret_store_resource_arn]
  }

  dynamic "statement" {
    for_each = length(local.cross_account_secret_arns) > 0 ? [1] : []
    content {
      sid       = "CrossAccountSecretAccess"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.cross_account_secret_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.cross_account_kms_key_arns) > 0 ? [1] : []
    content {
      sid       = "CrossAccountSecretDecryption"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = local.cross_account_kms_key_arns
    }
  }
}

resource "aws_iam_policy" "operator" {
  name        = coalesce(var.iam_policy_name, local.iam_generated_name)
  path        = var.iam_policy_path
  description = "Humanitec Operator access to the AWS Secrets Manager secret store ${local.secret_store_id}"
  policy      = data.aws_iam_policy_document.operator.json
  tags        = var.iam_policy_tags
}

# IAM role for the Operator service account (auth_method = "pod_identity" or "irsa")

# Trust policy allowing EKS Pod Identity to assume the role
data "aws_iam_policy_document" "operator_pod_identity_trust" {
  count   = local.use_pod_identity ? 1 : 0
  version = "2012-10-17"
  statement {
    sid    = "AllowEksAuthToAssumeRoleForPodIdentity"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

# The OIDC provider of the EKS cluster, required for the IRSA trust policy
data "aws_eks_cluster" "operator" {
  count = local.use_irsa && var.eks_cluster_name != null ? 1 : 0
  name  = var.eks_cluster_name
}

data "aws_iam_openid_connect_provider" "operator" {
  count = length(data.aws_eks_cluster.operator)
  url   = data.aws_eks_cluster.operator[0].identity[0].oidc[0].issuer
}

# Trust policy allowing the Operator service account to assume the role via IRSA
data "aws_iam_policy_document" "operator_irsa_trust" {
  count   = length(data.aws_iam_openid_connect_provider.operator)
  version = "2012-10-17"
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.operator[0].arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${trimprefix(data.aws_iam_openid_connect_provider.operator[0].url, "https://")}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${trimprefix(data.aws_iam_openid_connect_provider.operator[0].url, "https://")}:sub"
      values   = ["system:serviceaccount:${var.operator_namespace}:${var.operator_serviceaccount}"]
    }
  }
}

resource "aws_iam_role" "operator" {
  count                = local.use_iam_role && var.iam_role_create ? 1 : 0
  name                 = coalesce(var.iam_role_name, local.iam_generated_name)
  path                 = var.iam_role_path
  description          = "Humanitec Operator access to the AWS Secrets Manager secret store ${local.secret_store_id}"
  permissions_boundary = var.iam_role_permissions_boundary_arn
  assume_role_policy   = local.iam_role_trust_policy
  tags                 = var.iam_role_tags
}

data "aws_iam_role" "operator" {
  count = local.use_iam_role && !var.iam_role_create ? 1 : 0
  name  = local.existing_role_arn_parts.name

  lifecycle {
    precondition {
      condition     = local.existing_role_arn_parts.account_id == data.aws_caller_identity.current.account_id
      error_message = "iam_role_arn must be located in the account of the aws provider (${data.aws_caller_identity.current.account_id})."
    }
  }
}

resource "aws_iam_role_policy_attachment" "operator" {
  count      = local.use_iam_role ? 1 : 0
  role       = local.iam_role_name
  policy_arn = aws_iam_policy.operator.arn
}

resource "aws_eks_pod_identity_association" "operator" {
  count           = local.use_pod_identity && var.pod_identity_association_create ? 1 : 0
  cluster_name    = local.pod_identity_association.cluster_name
  namespace       = local.pod_identity_association.namespace
  service_account = local.pod_identity_association.service_account
  role_arn        = local.iam_role_arn
}

# IAM user with static credentials (auth_method = "iam_user")

resource "aws_iam_user" "operator" {
  count                = local.use_iam_user && var.iam_user_create ? 1 : 0
  name                 = coalesce(var.iam_user_name, local.iam_generated_name)
  path                 = var.iam_user_path
  permissions_boundary = var.iam_user_permissions_boundary_arn
  tags                 = var.iam_user_tags
}

resource "aws_iam_access_key" "operator" {
  count = length(aws_iam_user.operator)
  user  = aws_iam_user.operator[0].name
}

data "aws_iam_user" "operator" {
  count     = local.use_iam_user && !var.iam_user_create ? 1 : 0
  user_name = local.existing_user_arn_parts.name

  lifecycle {
    precondition {
      condition     = local.existing_user_arn_parts.account_id == data.aws_caller_identity.current.account_id
      error_message = "iam_user_arn must be located in the account of the aws provider (${data.aws_caller_identity.current.account_id})."
    }
  }
}

resource "aws_iam_user_policy_attachment" "operator" {
  count      = local.use_iam_user ? 1 : 0
  user       = local.iam_user_name
  policy_arn = aws_iam_policy.operator.arn
}

# ID of the access key in the Kubernetes Secret. Write-only data is not part of the state, so a change
# cannot be detected on the Secret itself. Every new AWS access key has a new ID, so tracking the ID
# here detects any change of the credentials, e.g. a key rotation, and replaces the Secret.
resource "terraform_data" "iam_user_access_key_id" {
  count = local.use_iam_user ? 1 : 0
  input = local.iam_user_access_key_id
}

# Kubernetes Secret holding the IAM user credentials, in the namespace of the secret store referencing it.
# The credentials are written via the write-only data_wo attribute so that they are not stored in the state.
resource "kubernetes_secret_v1" "operator_credentials" {
  count = local.use_iam_user ? 1 : 0
  metadata {
    name      = local.iam_user_credentials_secret_name
    namespace = local.secret_store_namespace
  }
  data_wo = {
    access_key_id     = local.iam_user_access_key_id
    secret_access_key = local.iam_user_secret_access_key
  }
  # The provider only writes data_wo, and skips reading the Secret data back into the state, if the revision is
  # at least 1. It stays constant, as any change of the credentials replaces the Secret, which writes data_wo anew.
  data_wo_revision = 1

  lifecycle {
    replace_triggered_by = [terraform_data.iam_user_access_key_id[count.index]]
  }
}

# Secret store registration with the Operator

resource "kubernetes_manifest" "secret_store" {
  manifest = {
    apiVersion = "humanitec.io/v1alpha1"
    kind       = "SecretStore"
    metadata   = local.secret_store_metadata
    spec = {
      awssm = {
        region = local.secrets_manager_region
        auth   = local.secret_store_auth
      }
    }
  }

  # Only register the store once the Operator identity has its permissions
  depends_on = [
    aws_iam_role_policy_attachment.operator,
    aws_eks_pod_identity_association.operator,
    aws_iam_user_policy_attachment.operator,
    kubernetes_secret_v1.operator_credentials,
  ]
}

# Policies to configure in the accounts of cross-account secrets

# Resource policy for a secret in another account, allowing the Operator to read it
data "aws_iam_policy_document" "cross_account_secret_resource_policy" {
  version = "2012-10-17"
  statement {
    sid    = "AllowHumanitecOperatorRead"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [local.operator_principal_arn]
    }
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
  }
}

# Key policy statement for the KMS key encrypting a secret in another account, allowing the Operator to decrypt it
data "aws_iam_policy_document" "cross_account_kms_key_policy" {
  version = "2012-10-17"
  statement {
    sid    = "AllowHumanitecOperatorDecrypt"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [local.operator_principal_arn]
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }
}
