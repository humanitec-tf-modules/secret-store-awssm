# AWS Secrets Manager as an Operator secret store

This repository contains an OpenTofu/Terraform module to connect an instance of [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager) as a secret store to the [Humanitec Operator](https://developer.humanitec.com/platform-orchestrator/docs/integration-and-extensions/humanitec-operator/overview/) running on an Amazon Elastic Kubernetes Service (EKS) cluster. It implements the setup described in [Connect to AWS Secrets Manager](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-aws-secrets-manager/).

The module creates:

- An AWS IAM policy granting the Operator access to the Secrets Manager. The Operator gets read/write access to the [default secret store](https://developer.humanitec.com/platform-orchestrator/docs/integration-and-extensions/humanitec-operator/architecture/#the-default-secret-store), and read-only access to any other store
- The AWS IAM identity used by the Operator, and attaches the policy to it. Depending on `auth_method`, this is one of:
  - `pod_identity` (default, recommended): An IAM role assumed by the Operator service account via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html), plus the EKS Pod Identity association
  - `irsa`: An IAM role assumed by the Operator service account via [IAM Roles for Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) (IRSA)
  - `iam_user`: An IAM user with an access key, plus a Kubernetes Secret holding the access key
- The `SecretStore` Kubernetes resource registering the secret store with the Operator, either cluster-wide or Environment-local

You can also bring your own IAM role or IAM user instead of having the module create it.

> [!NOTE]
> The module does not register the secret store with the Platform Orchestrator. Follow the [instructions](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-aws-secrets-manager/#register-the-secret-store-with-the-platform-orchestrator) to do so, using the same secret store ID.

Prerequisites:

- The Humanitec Operator is installed on the cluster before you plan the module. See [Installation order](#installation-order)
- If you use EKS Pod Identity, the [EKS Pod Identity Agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html) add-on is installed on the EKS cluster
- If you use IRSA and let the module create the IAM role, an [IAM OIDC provider](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html) exists for the EKS cluster in the account of the `aws` provider
- For an Environment-local secret store, the Environment namespace exists

The Secrets Manager is located in the AWS account of the `aws` provider passed in to the module. Use [cross-account secret references](#reference-secrets-in-other-aws-accounts) to access secrets in other AWS accounts.

## Installation order

The module creates the `SecretStore` resource using a `kubernetes_manifest`, which reads the `SecretStore` custom resource definition (CRD) from the cluster during planning. The Humanitec Operator Helm chart installs this CRD. Therefore, the Operator must already be installed when you plan the module.

If you install the Operator in the same OpenTofu/Terraform configuration as the present module, e.g. via a `helm_release`, apply the Operator before you add the module, e.g. in a separate stage or using `-target`. Adding a `depends_on` on the module is not sufficient, as the CRD is required during planning already.

> [!NOTE]
> **Architectural decision**
> 
> A provider such as [alekc/kubectl](https://registry.terraform.io/providers/alekc/kubectl), which does not require the CRD to exist at plan time, would allow a single apply. However, it would introduce another external community provider, require users to configure and pass in a third provider, and require an additional module input to order the SecretStore after the Operator installation. It would also need retry handling, as a newly installed CRD can take a moment before the API server accepts resources of its type. The module therefore accepts the two-pass limitation. It only applies when the Operator is installed in the same run as the module, e.g. on a new cluster.

With IRSA, the Operator service account also needs an annotation with the ARN of the IAM role. See [Use IRSA](#use-irsa) for how to provide it.

## Usage

### Common usage: Default secret store with EKS Pod Identity

This configuration creates a cluster-wide secret store, as well as the IAM policy, the IAM role, and the EKS Pod Identity association for the Operator service account. The secret store is the default store of the Operator, as `secret_store_default` is `true` by default.

```hcl
module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id  = "my-awssm"
  eks_cluster_name = aws_eks_cluster.my_eks_cluster.name
}
```

The module does not modify the Operator installation. Once the module has created the EKS Pod Identity association, restart the Operator to pick up the IAM role:

```shell
kubectl rollout restart deployment -n humanitec-operator-system humanitec-operator-controller-manager
```

### Use IRSA

With IRSA, the Operator service account must be annotated with the ARN of the IAM role it assumes. The module does not modify the Operator installation, so you need to set the annotation via the Helm values of the Operator. As the Operator must be installed before the module (see [Installation order](#installation-order)), there are two ways to do so.

#### Recommended: Set a fixed IAM role name

Set a fixed `iam_role_name` so that you know the ARN of the IAM role before running the module. This lets you set the annotation when you install the Operator, before the module creates the IAM role. Once the module has created the IAM role, the Operator can assume it without any further changes.

```hcl
locals {
  operator_iam_role_name = "humanitec-operator-my-awssm"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}


❌❌ TODO consider not showing the helm_release because we will use the Operator module going forward
# Apply the Operator before adding the module, see "Installation order"
resource "helm_release" "humanitec_operator" {
  name       = "humanitec-operator"
  namespace  = "humanitec-operator-system"
  repository = "oci://ghcr.io/humanitec/charts"
  chart      = "humanitec-operator"

  values = [
    yamlencode({
      controllerManager = {
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.operator_iam_role_name}"
          }
        }
      }
    })
  ]
}

module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id  = "my-awssm"
  eks_cluster_name = aws_eks_cluster.my_eks_cluster.name

  auth_method   = "irsa"
  iam_role_name = local.operator_iam_role_name
}
```

If you also set `iam_role_path`, include the path in the ARN, e.g. `role/humanitec/humanitec-operator-my-awssm` for the path `/humanitec/`.

#### Alternative: Use the generated IAM role name

If you do not set `iam_role_name`, the module generates a name with a random suffix, so the ARN is only known after running the module. In this case, run the module first and then update the Helm values of the existing Operator installation with the annotations from the `operator_serviceaccount_annotations` output:

```hcl
module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id  = "my-awssm"
  eks_cluster_name = aws_eks_cluster.my_eks_cluster.name

  auth_method = "irsa"
}

❌❌ TODO consider not showing the helm_release because we will use the Operator module going forward
resource "helm_release" "humanitec_operator" {
  name       = "humanitec-operator"
  namespace  = "humanitec-operator-system"
  repository = "oci://ghcr.io/humanitec/charts"
  chart      = "humanitec-operator"

  values = [
    yamlencode({
      controllerManager = {
        serviceAccount = {
          annotations = module.my_awssm_secret_store.operator_serviceaccount_annotations
        }
      }
    })
  ]
}
```

Then restart the Operator to pick up the IAM role:

```shell
kubectl rollout restart deployment -n humanitec-operator-system humanitec-operator-controller-manager
```

### One IAM role for all secret stores

> [!IMPORTANT]
> The Operator uses exactly one IAM role. With EKS Pod Identity, this is the role of the Pod Identity association of the Operator service account, and EKS allows only one association per service account. With IRSA, this is the role annotated on the Operator service account. All secret stores on the cluster that use EKS Pod Identity or IRSA therefore share that IAM role. Let at most one instance of the module create the IAM role and the EKS Pod Identity association, preferably the one for the `default` store, and pass the IAM role in to all other instances with `iam_role_create = false`, `iam_role_arn`, and `pod_identity_association_create = false`. See [Non-default secret store](#non-default-secret-store).
>
> Each instance of the module still creates its own IAM policy and attaches it to the shared IAM role, so the Operator has the combined access of all these secret stores through each of them. Each policy counts towards the [quota of managed policies per IAM role](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html), which is 10 by default.
>
> This does not apply to `auth_method = "iam_user"`, where each secret store references its own credentials. Use IAM users for secret stores that need a separate identity, such as [Environment-local secret stores](#environment-local-secret-stores).

### Non-default secret store

Set `secret_store_default` to `false` to create a cluster-wide secret store that is not the default store, e.g. if you already have a default store. The Operator gets read-only access to this store.

This configuration adds a non-default secret store for the Secrets Manager in a second region next to the [default secret store](#common-usage-default-secret-store-with-eks-pod-identity) created by another instance of the module. As the [Operator uses only one IAM role](#one-iam-role-for-all-secret-stores), it reuses the IAM role and EKS Pod Identity association of the default store, and only attaches a read-only IAM policy for the second region to the IAM role.

```hcl
module "my_other_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id        = "my-other-awssm"
  secret_store_default   = false
  secrets_manager_region = "eu-west-1"

  iam_role_create                 = false
  iam_role_arn                    = module.my_awssm_secret_store.iam_role_arn
  pod_identity_association_create = false
}
```

### Environment-local secret stores

An Environment-local secret store is located in the namespace of an Environment, so that only Deployments into that namespace can use it. It cannot be the default store, so `secret_store_default` must be set to `false`, and the Operator gets read-only access to it. The Operator always needs a cluster-wide [default secret store](https://developer.humanitec.com/platform-orchestrator/docs/integration-and-extensions/humanitec-operator/architecture/#the-default-secret-store) in addition to any Environment-local stores.

Environment-local stores only isolate the Environments from each other if each store uses a separate IAM identity, with access to the secrets of its Environment only. With EKS Pod Identity or IRSA, all secret stores [share the one IAM role of the Operator](#one-iam-role-for-all-secret-stores), including the default store with its read/write access. The `SecretStore` resource cannot name another IAM role for the Operator to assume either. The only separate identity is therefore an IAM user with static credentials, so the examples use `auth_method = "iam_user"`.

Each instance of the module then creates or uses a dedicated IAM user, a Kubernetes Secret holding its access key in the Environment namespace, and a read-only IAM policy attached to the IAM user. The secret stores do not share any IAM objects, so removing one secret store does not affect the others. All inputs about the IAM role and the EKS Pod Identity association can keep their defaults, and `eks_cluster_name` must not be set.

The access of the cluster-wide stores also matters, as any Deployment can use them. If the default store can read all secrets of the Secrets Manager, so can every Environment through it. Therefore, keep the secrets of each Environment under its own name prefix, and restrict the default store to another prefix with `secret_name_prefix`. For a default store with a prefix, the module also grants access to the prefix `resources/`, under which the Operator stores [resource cookies](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-aws-secrets-manager/#resource-cookies), so do not use it for the secrets of an Environment. Alternatively, place the secrets of the Environments in a different region than the default store.

#### One IAM user per Environment

This configuration creates the default secret store restricted to the secrets under `shared/` and the resource cookies, and one Environment-local secret store per Environment namespace. Each Environment-local store has its own IAM user, which can only read the secrets under the prefix of its Environment, e.g. `my-app-development/`.

```hcl
locals {
  environment_namespaces = toset(["my-app-development", "my-app-staging"])
}

# Default secret store, restricted to shared secrets and the resource cookies of the Operator
module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id    = "my-awssm"
  secret_name_prefix = "shared/"
  eks_cluster_name   = aws_eks_cluster.my_eks_cluster.name
}

# Environment-local secret stores, each with its own IAM user
module "my_environment_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }
  for_each = local.environment_namespaces

  secret_store_id           = "my-awssm-${each.key}"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = each.key
  secret_name_prefix        = "${each.key}/"

  auth_method = "iam_user"
}
```

> [!WARNING]
> The Kubernetes Secret holding the access key is located in the Environment namespace. Anyone who can read Secrets in that namespace can use the IAM user, and thus read the secrets of that Environment. The secret access key is also stored in the OpenTofu/Terraform state, see [Use an IAM user with static credentials](#use-an-iam-user-with-static-credentials). To keep it out of the state, bring your own IAM users as shown below.

#### Bring your own IAM users

This configuration uses your own IAM user and access key per Environment, as described in [Bring your own IAM user](#bring-your-own-iam-user). The module attaches a read-only IAM policy for the secrets of the Environment to each IAM user. It reads the secret access keys from ephemeral sources, so they are not stored in the state.

```hcl
locals {
  environment_iam_users = {
    "my-app-development" = {
      arn           = "arn:aws:iam::123456789012:user/humanitec-operator-my-app-development"
      access_key_id = "AKIAIOSFODNN7EXAMPLE"
    }
    "my-app-staging" = {
      arn           = "arn:aws:iam::123456789012:user/humanitec-operator-my-app-staging"
      access_key_id = "AKIAI44QH8DHBEXAMPLE"
    }
  }
}

ephemeral "aws_secretsmanager_secret_version" "operator_user_access_key" {
  for_each  = local.environment_iam_users
  secret_id = "humanitec/operator-user-access-key-${each.key}"
}

module "my_environment_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }
  for_each = local.environment_iam_users

  secret_store_id           = "my-awssm-${each.key}"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = each.key
  secret_name_prefix        = "${each.key}/"

  auth_method                = "iam_user"
  iam_user_create            = false
  iam_user_arn               = each.value.arn
  iam_user_access_key_id     = each.value.access_key_id
  iam_user_secret_access_key = ephemeral.aws_secretsmanager_secret_version.operator_user_access_key[each.key].secret_string
}
```

### Restrict access to a path and use a different region

This configuration creates the default secret store for a Secrets Manager in a region other than the one of the `aws` provider, and restricts the Operator to secrets whose names start with `humanitec/`. As this is the default store, the Operator also gets access to the secrets starting with `resources/`, where it stores its [resource cookies](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-aws-secrets-manager/#resource-cookies). It also customizes the names, path, and tags of the IAM objects.

```hcl
module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id        = "my-awssm"
  secrets_manager_region = "eu-central-1"
  secret_name_prefix     = "humanitec/"
  eks_cluster_name       = aws_eks_cluster.my_eks_cluster.name

  iam_policy_name = "humanitec-operator-my-awssm"
  iam_policy_path = "/humanitec/"
  iam_role_name   = "humanitec-operator-my-awssm"
  iam_role_path   = "/humanitec/"
  iam_role_tags = {
    "tag1" = "value1"
  }
}
```

### Bring your own IAM role

This configuration creates the default secret store, using your own AWS IAM role for the Operator. The module attaches the IAM policy to it, and creates the EKS Pod Identity association. The trust policy of the role must allow the Operator service account to assume it via EKS Pod Identity or IRSA, depending on `auth_method`. Use the `iam_role_trust_policy` output of the present module for the required trust policy. For IRSA, the output is only provided if you set `eks_cluster_name`.

```hcl
module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id  = "my-awssm"
  eks_cluster_name = aws_eks_cluster.my_eks_cluster.name

  iam_role_create = false
  iam_role_arn    = aws_iam_role.my_own_operator_role.arn
}
```

### Manage the EKS Pod Identity association yourself

This configuration creates the default secret store and the IAM role, but not the EKS Pod Identity association. Use the `iam_role_arn` and `pod_identity_association` outputs of the present module to configure the association yourself. `eks_cluster_name` is optional in this case.

```hcl
module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id = "my-awssm"

  pod_identity_association_create = false
}
```

### Use an IAM user with static credentials

This configuration creates the default secret store, as well as an AWS IAM user and an access key for the Operator. It stores the access key in a Kubernetes Secret referenced by the secret store. Using an IAM user requires you to maintain static credentials, so prefer EKS Pod Identity or IRSA where possible.

```hcl
module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id = "my-awssm"

  auth_method = "iam_user"
}
```

> [!WARNING]
> If the module creates the IAM user, the secret access key is stored in the OpenTofu/Terraform state as part of the `aws_iam_access_key` resource. Make sure your state is stored securely, or [bring your own IAM user](#bring-your-own-iam-user) to keep the key out of the state.

### Bring your own IAM user

This configuration creates the default secret store, using your own AWS IAM user and access key for the Operator. The module attaches the IAM policy to the user, and stores the access key in a Kubernetes Secret referenced by the secret store.

The secret access key is not stored in the state or plan: `iam_user_secret_access_key` is an ephemeral variable, and the module only writes the key to the write-only `data_wo` attribute of the Kubernetes Secret. To keep the key out of your own state as well, read it from an ephemeral source, e.g. a secret in AWS Secrets Manager:

```hcl
ephemeral "aws_secretsmanager_secret_version" "operator_user_access_key" {
  secret_id = "humanitec/operator-user-access-key"
}

module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id = "my-awssm"

  auth_method                = "iam_user"
  iam_user_create            = false
  iam_user_arn               = "arn:aws:iam::123456789012:user/my-operator-user"
  iam_user_access_key_id     = "AKIAIOSFODNN7EXAMPLE"
  iam_user_secret_access_key = ephemeral.aws_secretsmanager_secret_version.operator_user_access_key.secret_string
}
```

The access key ID must not be ephemeral, as the module keeps it in the state to detect changes of the write-only credentials. When you rotate the access key, pass in the new access key ID and secret access key. The new ID makes the module replace the Kubernetes Secret with the new credentials. Changing only the secret access key does not update the Kubernetes Secret, but every new AWS access key has a new ID.

### Reference secrets in other AWS accounts

The Operator can read secrets located in other AWS accounts, as described in the [AWS guide for accessing secrets from a different account](https://docs.aws.amazon.com/secretsmanager/latest/userguide/auth-and-access_examples_cross.html). Each such secret must be encrypted with a customer managed KMS key.

List the secrets and their KMS keys in `cross_account_secrets`. This configuration creates the default secret store, and the module allows the Operator IAM role or user to read the secrets and decrypt them.

```hcl
module "my_awssm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-awssm?ref=vX.Y.Z"
  providers = {
    aws        = aws
    kubernetes = kubernetes
  }

  secret_store_id  = "my-awssm"
  eks_cluster_name = aws_eks_cluster.my_eks_cluster.name

  cross_account_secrets = [
    {
      secret_arn  = aws_secretsmanager_secret.shared.arn
      kms_key_arn = aws_kms_key.shared.arn
    },
  ]
}
```

In the account of each secret, you must also allow the Operator to read the secret and decrypt it with the KMS key. Use the `cross_account_secret_resource_policy` and `cross_account_kms_key_policy` outputs of the present module, e.g. with an `aws` provider configured for that account:

```hcl
resource "aws_secretsmanager_secret_policy" "shared" {
  provider   = aws.secrets_account
  secret_arn = aws_secretsmanager_secret.shared.arn
  policy     = module.my_awssm_secret_store.cross_account_secret_resource_policy
}

# Merge the statement for the Operator into the complete key policy
data "aws_iam_policy_document" "shared_key" {
  source_policy_documents = [module.my_awssm_secret_store.cross_account_kms_key_policy]

  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.secrets_account.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

resource "aws_kms_key_policy" "shared" {
  provider = aws.secrets_account
  key_id   = aws_kms_key.shared.id
  policy   = data.aws_iam_policy_document.shared_key.json
}
```

Reference the secret by its ARN in a [secret reference](https://developer.humanitec.com/platform-orchestrator/docs/platform-orchestrator/security/secret-references/):

```json
{
  "store": "my-awssm",
  "ref": "arn:aws:secretsmanager:eu-west-1:210987654321:secret:my-secret-AbCdEf"
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0.0, < 7.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_eks_pod_identity_association.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_access_key.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_access_key) | resource |
| [aws_iam_policy.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_user.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user) | resource |
| [aws_iam_user_policy_attachment.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user_policy_attachment) | resource |
| [kubernetes_manifest.secret_store](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest) | resource |
| [kubernetes_secret_v1.operator_credentials](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [random_string.iam_name_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [random_string.secret_store_id_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [terraform_data.iam_user_access_key_id](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_eks_cluster.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_cluster) | data source |
| [aws_iam_openid_connect_provider.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_openid_connect_provider) | data source |
| [aws_iam_policy_document.cross_account_kms_key_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cross_account_secret_resource_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.operator_irsa_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.operator_pod_identity_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_role.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role) | data source |
| [aws_iam_user.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_user) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_auth_method"></a> [auth\_method](#input\_auth\_method) | How the Operator authenticates against AWS Secrets Manager. `pod_identity` (recommended): the Operator assumes an IAM role via EKS Pod Identity. `irsa`: the Operator assumes an IAM role via IAM Roles for Service Accounts (IRSA). `iam_user`: the Operator uses static credentials of an IAM user, stored in a Kubernetes Secret. | `string` | `"pod_identity"` | no |
| <a name="input_cross_account_secrets"></a> [cross\_account\_secrets](#input\_cross\_account\_secrets) | Secrets in other AWS accounts the Operator may read, each with the ARN of the KMS key encrypting the secret. Reference such a secret by its ARN in a secret reference. In the account of each secret, you must also configure the resource policy of the secret and the key policy of the KMS key yourself. Use the `cross_account_secret_resource_policy` and `cross_account_kms_key_policy` outputs to configure them. | <pre>list(object({<br/>    secret_arn  = string<br/>    kms_key_arn = string<br/>  }))</pre> | `[]` | no |
| <a name="input_eks_cluster_name"></a> [eks\_cluster\_name](#input\_eks\_cluster\_name) | The name of the EKS cluster hosting the Operator. Required if `auth_method` is `pod_identity` and `pod_identity_association_create` is `true`, or if `auth_method` is `irsa` and `iam_role_create` is `true`. For IRSA, the cluster must be located in the account and region of the `aws` provider and have an IAM OIDC provider. Optional otherwise: if set, it is included in the `pod_identity_association` output for EKS Pod Identity, and the `iam_role_trust_policy` output is provided for IRSA. Must not be set if `auth_method` is `iam_user`. | `string` | `null` | no |
| <a name="input_iam_policy_name"></a> [iam\_policy\_name](#input\_iam\_policy\_name) | Name of the AWS IAM policy granting the Operator access to the Secrets Manager. If not set, the module generates a name from the secret store ID and a random four-letter suffix. | `string` | `null` | no |
| <a name="input_iam_policy_path"></a> [iam\_policy\_path](#input\_iam\_policy\_path) | Path of the AWS IAM policy, e.g. `/humanitec/`. If not set, the policy is created with the path `/`. | `string` | `null` | no |
| <a name="input_iam_policy_tags"></a> [iam\_policy\_tags](#input\_iam\_policy\_tags) | Tags to assign to the AWS IAM policy. | `map(string)` | `null` | no |
| <a name="input_iam_role_arn"></a> [iam\_role\_arn](#input\_iam\_role\_arn) | The ARN of an existing AWS IAM role to be used by the Operator. It must be located in the account of the `aws` provider that is passed in to the module, and its trust policy must allow the Operator service account to assume it via EKS Pod Identity or IRSA, depending on `auth_method`. Use the `iam_role_trust_policy` output to configure it. Required if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `false`. Must not be set otherwise. | `string` | `null` | no |
| <a name="input_iam_role_create"></a> [iam\_role\_create](#input\_iam\_role\_create) | Whether to create the AWS IAM role used by the Operator. Only used if `auth_method` is `pod_identity` or `irsa`. If `false`, `iam_role_arn` must be the ARN of an existing IAM role. | `bool` | `true` | no |
| <a name="input_iam_role_name"></a> [iam\_role\_name](#input\_iam\_role\_name) | Name of the AWS IAM role to create for the Operator. Only used if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `true`. If not set, the module generates a name from the secret store ID and a random four-letter suffix, truncated to 64 characters. | `string` | `null` | no |
| <a name="input_iam_role_path"></a> [iam\_role\_path](#input\_iam\_role\_path) | Path of the AWS IAM role to create for the Operator, e.g. `/humanitec/`. If not set, the role is created with the path `/`. Only used if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `true`. | `string` | `null` | no |
| <a name="input_iam_role_permissions_boundary_arn"></a> [iam\_role\_permissions\_boundary\_arn](#input\_iam\_role\_permissions\_boundary\_arn) | ARN of the IAM policy to set as the permissions boundary of the AWS IAM role created for the Operator. Only used if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `true`. | `string` | `null` | no |
| <a name="input_iam_role_tags"></a> [iam\_role\_tags](#input\_iam\_role\_tags) | Tags to assign to the AWS IAM role created by the module. Only used if `auth_method` is `pod_identity` or `irsa`, and `iam_role_create` is `true`. | `map(string)` | `null` | no |
| <a name="input_iam_user_access_key_id"></a> [iam\_user\_access\_key\_id](#input\_iam\_user\_access\_key\_id) | Access key ID of the existing AWS IAM user passed in via `iam_user_arn`. Required if `auth_method` is `iam_user` and `iam_user_create` is `false`, must not be set otherwise. The access key ID is stored in the state. When it changes, e.g. when rotating the access key, the module replaces the Kubernetes Secret holding the credentials. | `string` | `null` | no |
| <a name="input_iam_user_arn"></a> [iam\_user\_arn](#input\_iam\_user\_arn) | The ARN of an existing AWS IAM user to be used by the Operator. It must be located in the account of the `aws` provider that is passed in to the module. Required if `auth_method` is `iam_user` and `iam_user_create` is `false`, must not be set otherwise. | `string` | `null` | no |
| <a name="input_iam_user_create"></a> [iam\_user\_create](#input\_iam\_user\_create) | Whether to create the AWS IAM user and its access key used by the Operator. Only used if `auth_method` is `iam_user`. If `true`, the secret access key of the created access key is stored in the OpenTofu/Terraform state as part of the `aws_iam_access_key` resource. If `false`, `iam_user_arn`, `iam_user_access_key_id`, and `iam_user_secret_access_key` must be set for an existing IAM user, and the secret access key is not stored in the state. | `bool` | `true` | no |
| <a name="input_iam_user_credentials_secret_name"></a> [iam\_user\_credentials\_secret\_name](#input\_iam\_user\_credentials\_secret\_name) | Name of the Kubernetes Secret holding the access key of the AWS IAM user. It is created in the namespace of the secret store. The access key is written to the Secret via a write-only attribute, so the Secret does not add it to the state. Only used if `auth_method` is `iam_user`. If not set, the name is `<secret store ID>-credentials`. | `string` | `null` | no |
| <a name="input_iam_user_name"></a> [iam\_user\_name](#input\_iam\_user\_name) | Name of the AWS IAM user to create for the Operator. Only used if `auth_method` is `iam_user` and `iam_user_create` is `true`. If not set, the module generates a name from the secret store ID and a random four-letter suffix, truncated to 64 characters. | `string` | `null` | no |
| <a name="input_iam_user_path"></a> [iam\_user\_path](#input\_iam\_user\_path) | Path of the AWS IAM user to create for the Operator, e.g. `/humanitec/`. If not set, the user is created with the path `/`. Only used if `auth_method` is `iam_user` and `iam_user_create` is `true`. | `string` | `null` | no |
| <a name="input_iam_user_permissions_boundary_arn"></a> [iam\_user\_permissions\_boundary\_arn](#input\_iam\_user\_permissions\_boundary\_arn) | ARN of the IAM policy to set as the permissions boundary of the AWS IAM user created for the Operator. Only used if `auth_method` is `iam_user` and `iam_user_create` is `true`. | `string` | `null` | no |
| <a name="input_iam_user_secret_access_key"></a> [iam\_user\_secret\_access\_key](#input\_iam\_user\_secret\_access\_key) | Secret access key of the existing AWS IAM user passed in via `iam_user_arn`. Required if `auth_method` is `iam_user` and `iam_user_create` is `false`, must be empty otherwise. The variable is ephemeral, so the value can come from an ephemeral source. It is not stored in the state or plan, as the module only writes it to a write-only attribute of the Kubernetes Secret. The Kubernetes Secret is only updated if `iam_user_access_key_id` changes as well, which is always the case for a new AWS access key. | `string` | `""` | no |
| <a name="input_iam_user_tags"></a> [iam\_user\_tags](#input\_iam\_user\_tags) | Tags to assign to the AWS IAM user created by the module. Only used if `auth_method` is `iam_user` and `iam_user_create` is `true`. | `map(string)` | `null` | no |
| <a name="input_operator_namespace"></a> [operator\_namespace](#input\_operator\_namespace) | Name of the Kubernetes namespace of the Humanitec Operator. | `string` | `"humanitec-operator-system"` | no |
| <a name="input_operator_serviceaccount"></a> [operator\_serviceaccount](#input\_operator\_serviceaccount) | Name of the Kubernetes service account of the Humanitec Operator. Used for the EKS Pod Identity association if `auth_method` is `pod_identity`, and in the IRSA trust policy if `auth_method` is `irsa`. | `string` | `"humanitec-operator-controller-manager"` | no |
| <a name="input_pod_identity_association_create"></a> [pod\_identity\_association\_create](#input\_pod\_identity\_association\_create) | Whether to create the EKS Pod Identity association linking the Operator service account to the IAM role. Only used if `auth_method` is `pod_identity`. Set to `false` if you manage the association yourself. Use the `pod_identity_association` output to configure it. | `bool` | `true` | no |
| <a name="input_secret_name_prefix"></a> [secret\_name\_prefix](#input\_secret\_name\_prefix) | Prefix of the names of the secrets in the Secrets Manager the Operator may access, e.g. `humanitec/`. If not set, the Operator may access all secrets in the Secrets Manager. Use it if you organize your secrets hierarchically. For the default store, the Operator may also access the secrets with the prefix `resources/`, where it stores resource cookies. | `string` | `null` | no |
| <a name="input_secret_store_cluster_wide"></a> [secret\_store\_cluster\_wide](#input\_secret\_store\_cluster\_wide) | Whether the secret store is cluster-wide, i.e. usable by all Deployments onto the cluster. A cluster-wide store is created in the `operator_namespace`. If `false`, the store is Environment-local and created in `secret_store_namespace`, so it can only be used by Deployments into that namespace. | `bool` | `true` | no |
| <a name="input_secret_store_default"></a> [secret\_store\_default](#input\_secret\_store\_default) | Whether the secret store is the default secret store of the Operator. Only a cluster-wide secret store can be the default store, so set it to `false` for an Environment-local store. The Operator gets read/write access to the default store, and read-only access to any other store. | `bool` | `true` | no |
| <a name="input_secret_store_id"></a> [secret\_store\_id](#input\_secret\_store\_id) | ID of the secret store. It is the name of the Kubernetes `SecretStore` resource and the `store` value used in secret references. If you also register the secret store with the Platform Orchestrator, use the same ID there. If not set, the module generates an ID in the pattern `awssm-<random>`, with `<random>` being a random string of four lowercase letters, e.g. `awssm-kxqp`. Use the `secret_store_id` output to read it. | `string` | `null` | no |
| <a name="input_secret_store_namespace"></a> [secret\_store\_namespace](#input\_secret\_store\_namespace) | Name of the Kubernetes namespace of the Environment for an Environment-local secret store. Required if `secret_store_cluster_wide` is `false`, must not be set otherwise. The namespace must exist. | `string` | `null` | no |
| <a name="input_secrets_manager_region"></a> [secrets\_manager\_region](#input\_secrets\_manager\_region) | AWS region of the Secrets Manager. If not set, the region of the `aws` provider is used. The Secrets Manager is always located in the account of the `aws` provider. Use `cross_account_secrets` to access secrets in other accounts. | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_aws_account_id"></a> [aws\_account\_id](#output\_aws\_account\_id) | ID of the AWS account of the Secrets Manager and the IAM objects. |
| <a name="output_cross_account_kms_key_policy"></a> [cross\_account\_kms\_key\_policy](#output\_cross\_account\_kms\_key\_policy) | Key policy statement allowing the Operator to decrypt a secret, as a policy document in JSON format. Add it to the key policy of the KMS key encrypting each secret in another AWS account you want to reference, e.g. via the `source_policy_documents` of an `aws_iam_policy_document`. Do not use it as the complete key policy. |
| <a name="output_cross_account_secret_resource_policy"></a> [cross\_account\_secret\_resource\_policy](#output\_cross\_account\_secret\_resource\_policy) | Resource policy allowing the Operator to read a secret, in JSON format. Attach it to each secret in another AWS account you want to reference. |
| <a name="output_iam_policy_arn"></a> [iam\_policy\_arn](#output\_iam\_policy\_arn) | ARN of the IAM policy granting the Operator access to the Secrets Manager. |
| <a name="output_iam_policy_name"></a> [iam\_policy\_name](#output\_iam\_policy\_name) | Name of the IAM policy granting the Operator access to the Secrets Manager. |
| <a name="output_iam_role_arn"></a> [iam\_role\_arn](#output\_iam\_role\_arn) | ARN of the IAM role used by the Operator. Returns `null` if `auth_method` is `iam_user`. |
| <a name="output_iam_role_name"></a> [iam\_role\_name](#output\_iam\_role\_name) | Name of the IAM role used by the Operator. Returns `null` if `auth_method` is `iam_user`. |
| <a name="output_iam_role_trust_policy"></a> [iam\_role\_trust\_policy](#output\_iam\_role\_trust\_policy) | Trust policy allowing the Operator service account to assume the IAM role via EKS Pod Identity or IRSA, depending on `auth_method`, in JSON format. If `iam_role_create` is `false`, configure this trust policy on the IAM role yourself. Returns `null` if `auth_method` is `iam_user`, or if `auth_method` is `irsa` and `eks_cluster_name` is not set. |
| <a name="output_iam_role_unique_id"></a> [iam\_role\_unique\_id](#output\_iam\_role\_unique\_id) | Stable and unique ID of the IAM role used by the Operator. Returns `null` if `auth_method` is `iam_user`. |
| <a name="output_iam_user_arn"></a> [iam\_user\_arn](#output\_iam\_user\_arn) | ARN of the IAM user used by the Operator. Returns `null` if `auth_method` is not `iam_user`. |
| <a name="output_iam_user_credentials_secret_name"></a> [iam\_user\_credentials\_secret\_name](#output\_iam\_user\_credentials\_secret\_name) | Name of the Kubernetes Secret holding the access key of the IAM user, located in the `secret_store_namespace`. Returns `null` if `auth_method` is not `iam_user`. |
| <a name="output_iam_user_name"></a> [iam\_user\_name](#output\_iam\_user\_name) | Name of the IAM user used by the Operator. Returns `null` if `auth_method` is not `iam_user`. |
| <a name="output_iam_user_unique_id"></a> [iam\_user\_unique\_id](#output\_iam\_user\_unique\_id) | Stable and unique ID of the IAM user used by the Operator. Returns `null` if `auth_method` is not `iam_user`. |
| <a name="output_operator_principal_arn"></a> [operator\_principal\_arn](#output\_operator\_principal\_arn) | ARN of the IAM role or IAM user used by the Operator, depending on `auth_method`. |
| <a name="output_operator_serviceaccount_annotations"></a> [operator\_serviceaccount\_annotations](#output\_operator\_serviceaccount\_annotations) | Annotations to set on the Operator service account so that it assumes the IAM role via IRSA, e.g. via the `controllerManager.serviceAccount.annotations` value of the Operator Helm chart. Restart the Operator after changing them. Returns an empty map if `auth_method` is not `irsa`, as EKS Pod Identity requires no annotation. |
| <a name="output_pod_identity_association"></a> [pod\_identity\_association](#output\_pod\_identity\_association) | Cluster name, namespace, and service account of the EKS Pod Identity association allowing the Operator to use the IAM role. If `pod_identity_association_create` is `false`, configure an association with these values and the `iam_role_arn` yourself. Returns `null` if `auth_method` is not `pod_identity`. |
| <a name="output_pod_identity_association_id"></a> [pod\_identity\_association\_id](#output\_pod\_identity\_association\_id) | ID of the EKS Pod Identity association created by the module. Returns `null` if `auth_method` is not `pod_identity` or `pod_identity_association_create` is `false`. |
| <a name="output_secret_store_id"></a> [secret\_store\_id](#output\_secret\_store\_id) | ID of the secret store, i.e. the name of the Kubernetes `SecretStore` resource. This is either `secret_store_id` or the generated ID. Use it as the `store` in secret references. |
| <a name="output_secret_store_namespace"></a> [secret\_store\_namespace](#output\_secret\_store\_namespace) | Name of the Kubernetes namespace of the `SecretStore` resource. This is the Operator namespace for a cluster-wide store, or the Environment namespace for an Environment-local store. |
| <a name="output_secrets_manager_region"></a> [secrets\_manager\_region](#output\_secrets\_manager\_region) | AWS region of the Secrets Manager. |
<!-- END_TF_DOCS -->
