# Secret store

variable "secret_store_id" {
  description = "ID of the secret store. It is the name of the Kubernetes `SecretStore` resource and the `store` value used in secret references. If you also register the secret store with the Platform Orchestrator, use the same ID there. If not set, the module generates an ID in the pattern `awssm-<random>`, with `<random>` being a random string of four lowercase letters, e.g. `awssm-kxqp`. Use the `secret_store_id` output to read it."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_store_id == null || (can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.secret_store_id)) && length(coalesce(var.secret_store_id, "-")) <= 63)
    error_message = "secret_store_id must consist of lowercase alphanumeric characters or '-', start and end with an alphanumeric character, and be at most 63 characters long"
  }
}
variable "secret_store_cluster_wide" {
  description = "Whether the secret store is cluster-wide, i.e. usable by all Deployments onto the cluster. A cluster-wide store is created in the `operator_namespace`. If `false`, the store is Environment-local and created in `secret_store_namespace`, so it can only be used by Deployments into that namespace."
  type        = bool
  nullable    = false
  default     = true
}
variable "secret_store_namespace" {
  description = "Name of the Kubernetes namespace of the Environment for an Environment-local secret store. Required if `secret_store_cluster_wide` is `false`, must not be set otherwise. The namespace must exist."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_store_cluster_wide ? var.secret_store_namespace == null : var.secret_store_namespace != null
    error_message = "secret_store_namespace must be set if secret_store_cluster_wide is false, and must not be set otherwise"
  }
}
variable "secret_store_default" {
  description = "Whether the secret store is the default secret store of the Operator. Only a cluster-wide secret store can be the default store, so set it to `false` for an Environment-local store. The Operator gets read/write access to the default store, and read-only access to any other store."
  type        = bool
  nullable    = false
  default     = true

  validation {
    condition     = !var.secret_store_default || var.secret_store_cluster_wide
    error_message = "secret_store_default can only be true if secret_store_cluster_wide is true. An Environment-local secret store cannot be the default store, so set secret_store_default to false"
  }
}
variable "secrets_manager_region" {
  description = "AWS region of the Secrets Manager. If not set, the region of the `aws` provider is used. The Secrets Manager is always located in the account of the `aws` provider. Use `cross_account_secrets` to access secrets in other accounts."
  type        = string
  nullable    = true
  default     = null
}
variable "secret_name_prefix" {
  description = "Prefix of the names of the secrets in the Secrets Manager the Operator may access, e.g. `humanitec/`. If not set, the Operator may access all secrets in the Secrets Manager. Use it if you organize your secrets hierarchically."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_name_prefix == null || can(regex("^[\\w/+=.@-]+$", var.secret_name_prefix))
    error_message = "secret_name_prefix must only contain alphanumeric characters and the characters /_+=.@-"
  }
}
variable "cross_account_secrets" {
  description = "Secrets in other AWS accounts the Operator may read, each with the ARN of the KMS key encrypting the secret. Reference such a secret by its ARN in a secret reference. In the account of each secret, you must also configure the resource policy of the secret and the key policy of the KMS key yourself. Use the `cross_account_secret_resource_policy` and `cross_account_kms_key_policy` outputs to configure them."
  type = list(object({
    secret_arn  = string
    kms_key_arn = string
  }))
  nullable = false
  default  = []

  validation {
    condition = alltrue([
      for s in var.cross_account_secrets : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", s.secret_arn))
    ])
    error_message = "Each secret_arn in cross_account_secrets must be a Secrets Manager secret ARN like arn:aws:secretsmanager:eu-west-1:123456789012:secret:my-secret-AbCdEf"
  }

  validation {
    condition = alltrue([
      for s in var.cross_account_secrets : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", s.kms_key_arn))
    ])
    error_message = "Each kms_key_arn in cross_account_secrets must be a KMS key ARN like arn:aws:kms:eu-west-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab. Aliases are not supported"
  }
}

# Operator

variable "operator_namespace" {
  description = "Name of the Kubernetes namespace of the Humanitec Operator."
  type        = string
  nullable    = false
  default     = "humanitec-operator-system"
}
variable "operator_serviceaccount" {
  description = "Name of the Kubernetes service account of the Humanitec Operator. Used for the EKS Pod Identity association if `auth_method` is `pod_identity`, and in the IRSA trust policy if `auth_method` is `irsa`."
  type        = string
  nullable    = false
  default     = "humanitec-operator-controller-manager"
}
variable "auth_method" {
  description = "How the Operator authenticates against AWS Secrets Manager. `pod_identity` (recommended): the Operator assumes an IAM role via EKS Pod Identity. `irsa`: the Operator assumes an IAM role via IAM Roles for Service Accounts (IRSA). `iam_user`: the Operator uses static credentials of an IAM user, stored in a Kubernetes Secret."
  type        = string
  nullable    = false
  default     = "pod_identity"

  validation {
    condition     = contains(["pod_identity", "irsa", "iam_user"], var.auth_method)
    error_message = "auth_method must be one of: pod_identity, irsa, iam_user"
  }
}

# IAM policy

variable "iam_policy_name" {
  description = "Name of the AWS IAM policy granting the Operator access to the Secrets Manager. If not set, the module generates a name from the secret store ID and a random four-letter suffix."
  type        = string
  nullable    = true
  default     = null
}
variable "iam_policy_path" {
  description = "Path of the AWS IAM policy, e.g. `/humanitec/`. If not set, the policy is created with the path `/`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_policy_path == null || can(regex("^/(?:[^/]+/)*$", var.iam_policy_path))
    error_message = "iam_policy_path must begin and end with a forward slash, e.g. /humanitec/"
  }
}
variable "iam_policy_tags" {
  description = "Tags to assign to the AWS IAM policy."
  type        = map(string)
  nullable    = true
  default     = null
}

# IAM role (auth_method = "pod_identity" or "irsa")

variable "iam_role_create" {
  description = "Whether to create the AWS IAM role used by the Operator. Only used if `auth_method` is `pod_identity` or `irsa`. If `false`, `iam_role_arn` must be the ARN of an existing IAM role."
  type        = bool
  nullable    = false
  default     = true
}
variable "iam_role_name" {
  description = "Name of the AWS IAM role to create for the Operator. Only used if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `true`. If not set, the module generates a name from the secret store ID and a random four-letter suffix, truncated to 64 characters."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_role_name == null || (contains(["pod_identity", "irsa"], var.auth_method) && var.iam_role_create)
    error_message = "iam_role_name must only be set if auth_method is pod_identity or irsa, and iam_role_create is true. Use iam_role_arn to pass in an existing IAM role"
  }
}
variable "iam_role_path" {
  description = "Path of the AWS IAM role to create for the Operator, e.g. `/humanitec/`. If not set, the role is created with the path `/`. Only used if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `true`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_role_path == null || (contains(["pod_identity", "irsa"], var.auth_method) && var.iam_role_create)
    error_message = "iam_role_path must only be set if auth_method is pod_identity or irsa, and iam_role_create is true"
  }

  validation {
    condition     = var.iam_role_path == null || can(regex("^/(?:[^/]+/)*$", var.iam_role_path))
    error_message = "iam_role_path must begin and end with a forward slash, e.g. /humanitec/"
  }
}
variable "iam_role_permissions_boundary_arn" {
  description = "ARN of the IAM policy to set as the permissions boundary of the AWS IAM role created for the Operator. Only used if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `true`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_role_permissions_boundary_arn == null || (contains(["pod_identity", "irsa"], var.auth_method) && var.iam_role_create)
    error_message = "iam_role_permissions_boundary_arn must only be set if auth_method is pod_identity or irsa, and iam_role_create is true"
  }
}
variable "iam_role_tags" {
  description = "Tags to assign to the AWS IAM role created by the module. Only used if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `true`."
  type        = map(string)
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_role_tags == null || (contains(["pod_identity", "irsa"], var.auth_method) && var.iam_role_create)
    error_message = "iam_role_tags must only be set if auth_method is pod_identity or irsa, and iam_role_create is true"
  }
}
variable "iam_role_arn" {
  description = "The ARN of an existing AWS IAM role to be used by the Operator. It must be located in the account of the `aws` provider that is passed in to the module, and its trust policy must allow the Operator service account to assume it via EKS Pod Identity or IRSA, depending on `auth_method`. Use the `iam_role_trust_policy` output to configure it. Required if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `false`. Must not be set otherwise."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = (contains(["pod_identity", "irsa"], var.auth_method) && !var.iam_role_create) == (var.iam_role_arn != null)
    error_message = "iam_role_arn must be set if auth_method is pod_identity or irsa, and iam_role_create is false. It must not be set otherwise"
  }

  validation {
    condition     = var.iam_role_arn == null || can(regex(local.iam_role_arn_pattern, var.iam_role_arn))
    error_message = "iam_role_arn must be an IAM role ARN like arn:aws:iam::123456789012:role/my-role"
  }
}
variable "pod_identity_association_create" {
  description = "Whether to create the EKS Pod Identity association linking the Operator service account to the IAM role. Only used if `auth_method` is `pod_identity`. Set to `false` if you manage the association yourself. Use the `pod_identity_association` output to configure it."
  type        = bool
  nullable    = false
  default     = true
}
variable "eks_cluster_name" {
  description = "The name of the EKS cluster hosting the Operator. Required if `auth_method` is `pod_identity` and `pod_identity_association_create` is `true`, or if `auth_method` is `irsa` and `iam_role_create` is `true`. For IRSA, the cluster must be located in the account and region of the `aws` provider and have an IAM OIDC provider. Optional otherwise: if set, it is included in the `pod_identity_association` output for EKS Pod Identity, and the `iam_role_trust_policy` output is provided for IRSA. Must not be set if `auth_method` is `iam_user`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = !(var.auth_method == "pod_identity" && var.pod_identity_association_create) || var.eks_cluster_name != null
    error_message = "eks_cluster_name must be set if auth_method is pod_identity and pod_identity_association_create is true"
  }

  validation {
    condition     = !(var.auth_method == "irsa" && var.iam_role_create) || var.eks_cluster_name != null
    error_message = "eks_cluster_name must be set if auth_method is irsa and iam_role_create is true"
  }

  validation {
    condition     = var.auth_method != "iam_user" || var.eks_cluster_name == null
    error_message = "eks_cluster_name must not be set if auth_method is iam_user"
  }
}

# IAM user (auth_method = "iam_user")

variable "iam_user_create" {
  description = "Whether to create the AWS IAM user and its access key used by the Operator. Only used if `auth_method` is `iam_user`. If `true`, the secret access key of the created access key is stored in the OpenTofu/Terraform state as part of the `aws_iam_access_key` resource. If `false`, `iam_user_arn`, `iam_user_access_key_id`, and `iam_user_secret_access_key` must be set for an existing IAM user, and the secret access key is not stored in the state."
  type        = bool
  nullable    = false
  default     = true
}
variable "iam_user_name" {
  description = "Name of the AWS IAM user to create for the Operator. Only used if `auth_method` is `iam_user` and `iam_user_create` is `true`. If not set, the module generates a name from the secret store ID and a random four-letter suffix, truncated to 64 characters."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_user_name == null || (var.auth_method == "iam_user" && var.iam_user_create)
    error_message = "iam_user_name must only be set if auth_method is iam_user and iam_user_create is true. Use iam_user_arn to pass in an existing IAM user"
  }
}
variable "iam_user_path" {
  description = "Path of the AWS IAM user to create for the Operator, e.g. `/humanitec/`. If not set, the user is created with the path `/`. Only used if `auth_method` is `iam_user` and `iam_user_create` is `true`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_user_path == null || (var.auth_method == "iam_user" && var.iam_user_create)
    error_message = "iam_user_path must only be set if auth_method is iam_user and iam_user_create is true"
  }

  validation {
    condition     = var.iam_user_path == null || can(regex("^/(?:[^/]+/)*$", var.iam_user_path))
    error_message = "iam_user_path must begin and end with a forward slash, e.g. /humanitec/"
  }
}
variable "iam_user_permissions_boundary_arn" {
  description = "ARN of the IAM policy to set as the permissions boundary of the AWS IAM user created for the Operator. Only used if `auth_method` is `iam_user` and `iam_user_create` is `true`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_user_permissions_boundary_arn == null || (var.auth_method == "iam_user" && var.iam_user_create)
    error_message = "iam_user_permissions_boundary_arn must only be set if auth_method is iam_user and iam_user_create is true"
  }
}
variable "iam_user_tags" {
  description = "Tags to assign to the AWS IAM user created by the module. Only used if `auth_method` is `iam_user` and `iam_user_create` is `true`."
  type        = map(string)
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_user_tags == null || (var.auth_method == "iam_user" && var.iam_user_create)
    error_message = "iam_user_tags must only be set if auth_method is iam_user and iam_user_create is true"
  }
}
variable "iam_user_arn" {
  description = "The ARN of an existing AWS IAM user to be used by the Operator. It must be located in the account of the `aws` provider that is passed in to the module. Required if `auth_method` is `iam_user` and `iam_user_create` is `false`, must not be set otherwise."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = (var.auth_method == "iam_user" && !var.iam_user_create) == (var.iam_user_arn != null)
    error_message = "iam_user_arn must be set if auth_method is iam_user and iam_user_create is false, and must not be set otherwise"
  }

  validation {
    condition     = var.iam_user_arn == null || can(regex(local.iam_user_arn_pattern, var.iam_user_arn))
    error_message = "iam_user_arn must be an IAM user ARN like arn:aws:iam::123456789012:user/my-user"
  }
}
variable "iam_user_access_key_id" {
  description = "Access key ID of the existing AWS IAM user passed in via `iam_user_arn`. Required if `auth_method` is `iam_user` and `iam_user_create` is `false`, must not be set otherwise. The access key ID is stored in the state. When it changes, e.g. when rotating the access key, the module replaces the Kubernetes Secret holding the credentials."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = (var.auth_method == "iam_user" && !var.iam_user_create) == (var.iam_user_access_key_id != null)
    error_message = "iam_user_access_key_id must be set if auth_method is iam_user and iam_user_create is false, and must not be set otherwise"
  }
}
# Not nullable with an empty string meaning "not set": Terraform tests cannot run an apply
# with an ephemeral variable that is null.
variable "iam_user_secret_access_key" {
  description = "Secret access key of the existing AWS IAM user passed in via `iam_user_arn`. Required if `auth_method` is `iam_user` and `iam_user_create` is `false`, must be empty otherwise. The variable is ephemeral, so the value can come from an ephemeral source. It is not stored in the state or plan, as the module only writes it to a write-only attribute of the Kubernetes Secret. The Kubernetes Secret is only updated if `iam_user_access_key_id` changes as well, which is always the case for a new AWS access key."
  type        = string
  nullable    = false
  sensitive   = true
  ephemeral   = true
  default     = ""

  validation {
    condition     = (var.auth_method == "iam_user" && !var.iam_user_create) == (var.iam_user_secret_access_key != "")
    error_message = "iam_user_secret_access_key must be set if auth_method is iam_user and iam_user_create is false, and must be empty otherwise"
  }
}
variable "iam_user_credentials_secret_name" {
  description = "Name of the Kubernetes Secret holding the access key of the AWS IAM user. It is created in the namespace of the secret store. The access key is written to the Secret via a write-only attribute, so the Secret does not add it to the state. Only used if `auth_method` is `iam_user`. If not set, the name is `<secret store ID>-credentials`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.iam_user_credentials_secret_name == null || var.auth_method == "iam_user"
    error_message = "iam_user_credentials_secret_name must only be set if auth_method is iam_user"
  }
}
