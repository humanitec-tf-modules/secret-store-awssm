# Mock all providers so the tests run without access to AWS or a Kubernetes cluster
mock_provider "kubernetes" {}
mock_provider "random" {
  # The mocked result does not honor the length attribute
  mock_resource "random_string" {
    defaults = {
      result = "abcd"
    }
  }
}
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "eu-west-1"
    }
  }
  # The mocked policy document does not render its statements
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\"}"
    }
  }
  mock_data "aws_eks_cluster" {
    defaults = {
      identity = [{
        oidc = [{
          issuer = "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
        }]
      }]
    }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/created-policy"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn       = "arn:aws:iam::123456789012:role/created-role"
      unique_id = "AROA11111111111111111"
    }
  }
  mock_data "aws_iam_role" {
    defaults = {
      arn       = "arn:aws:iam::123456789012:role/existing-path/existing-role"
      unique_id = "AROA22222222222222222"
    }
  }
  mock_resource "aws_iam_user" {
    defaults = {
      arn       = "arn:aws:iam::123456789012:user/created-user"
      unique_id = "AIDA11111111111111111"
    }
  }
  mock_resource "aws_iam_access_key" {
    defaults = {
      id     = "AKIA11111111111111111"
      secret = "created-secret-access-key"
    }
  }
  mock_data "aws_iam_user" {
    defaults = {
      arn     = "arn:aws:iam::123456789012:user/existing-path/existing-user"
      user_id = "AIDA22222222222222222"
    }
  }
  mock_resource "aws_eks_pod_identity_association" {
    defaults = {
      association_id = "a-0000000000000000"
    }
  }
}

# The minimum set of variables
variables {
  secret_store_id  = "my-awssm"
  eks_cluster_name = "my-cluster"
  # Terraform tests require ephemeral variables to be set explicitly in apply runs
  iam_user_secret_access_key = ""
}

# Default case

run "defaults" {
  # The random suffix of the generated names is only known after apply
  command = apply

  # IAM policy
  assert {
    condition     = aws_iam_policy.operator.name == "humanitec-operator-my-awssm-abcd"
    error_message = "IAM policy name should be generated as humanitec-operator-<secret_store_id>-<suffix>, got ${aws_iam_policy.operator.name}"
  }
  assert {
    condition     = aws_iam_policy.operator.path == null && aws_iam_policy.operator.tags == null
    error_message = "IAM policy should have no custom path and no tags by default"
  }
  assert {
    condition     = aws_iam_policy.operator.policy == data.aws_iam_policy_document.operator.json
    error_message = "IAM policy should use the Operator policy document"
  }
  assert {
    condition = (
      length(data.aws_iam_policy_document.operator.statement) == 1 &&
      data.aws_iam_policy_document.operator.statement[0].effect == "Allow" &&
      toset(data.aws_iam_policy_document.operator.statement[0].actions) == toset([
        "secretsmanager:GetSecretValue",
        "secretsmanager:CreateSecret",
        "secretsmanager:DeleteSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:RestoreSecret",
      ])
    )
    error_message = "IAM policy should allow reading and writing secrets for the default store"
  }
  assert {
    condition     = toset(data.aws_iam_policy_document.operator.statement[0].resources) == toset(["arn:aws:secretsmanager:eu-west-1:123456789012:secret:*"])
    error_message = "IAM policy should allow access to all secrets of the Secrets Manager in the account and region of the aws provider"
  }

  # Secret store ID
  assert {
    condition     = length(random_string.secret_store_id_suffix) == 0
    error_message = "No random suffix should be generated if secret_store_id is set"
  }

  # IAM role
  assert {
    condition     = length(aws_iam_role.operator) == 1 && length(data.aws_iam_role.operator) == 0
    error_message = "IAM role should be created by default"
  }
  assert {
    condition     = aws_iam_role.operator[0].name == "humanitec-operator-my-awssm-abcd"
    error_message = "IAM role name should be generated as humanitec-operator-<secret_store_id>-<suffix>, got ${aws_iam_role.operator[0].name}"
  }
  assert {
    condition     = aws_iam_role.operator[0].path == null && aws_iam_role.operator[0].permissions_boundary == null && aws_iam_role.operator[0].tags == null
    error_message = "IAM role should have no custom path, no permissions boundary and no tags by default"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.operator[0].role == "humanitec-operator-my-awssm-abcd" && aws_iam_role_policy_attachment.operator[0].policy_arn == "arn:aws:iam::123456789012:policy/created-policy"
    error_message = "IAM policy should be attached to the IAM role"
  }

  # EKS Pod Identity trust policy
  assert {
    condition     = aws_iam_role.operator[0].assume_role_policy == data.aws_iam_policy_document.operator_pod_identity_trust[0].json
    error_message = "IAM role should use the EKS Pod Identity trust policy"
  }
  assert {
    condition = (
      length(data.aws_iam_policy_document.operator_pod_identity_trust[0].statement) == 1 &&
      data.aws_iam_policy_document.operator_pod_identity_trust[0].statement[0].effect == "Allow" &&
      toset(data.aws_iam_policy_document.operator_pod_identity_trust[0].statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"])
    )
    error_message = "Trust policy should allow sts:AssumeRole and sts:TagSession"
  }
  assert {
    condition = [for p in data.aws_iam_policy_document.operator_pod_identity_trust[0].statement[0].principals : {
      type        = p.type
      identifiers = toset(p.identifiers)
    }] == [{ type = "Service", identifiers = toset(["pods.eks.amazonaws.com"]) }]
    error_message = "Trust policy should trust the EKS Pod Identity service principal"
  }
  assert {
    condition = (
      length(data.aws_eks_cluster.operator) == 0 &&
      length(data.aws_iam_openid_connect_provider.operator) == 0 &&
      length(data.aws_iam_policy_document.operator_irsa_trust) == 0
    )
    error_message = "No IRSA trust policy should be used with EKS Pod Identity"
  }

  # Pod Identity association
  assert {
    condition = (
      aws_eks_pod_identity_association.operator[0].cluster_name == "my-cluster" &&
      aws_eks_pod_identity_association.operator[0].namespace == "humanitec-operator-system" &&
      aws_eks_pod_identity_association.operator[0].service_account == "humanitec-operator-controller-manager"
    )
    error_message = "Pod Identity association should be for the Operator service account in eks_cluster_name"
  }
  assert {
    condition     = aws_eks_pod_identity_association.operator[0].role_arn == aws_iam_role.operator[0].arn
    error_message = "Pod Identity association should use the new IAM role"
  }

  # No IAM user
  assert {
    condition = (
      length(aws_iam_user.operator) == 0 &&
      length(data.aws_iam_user.operator) == 0 &&
      length(aws_iam_access_key.operator) == 0 &&
      length(aws_iam_user_policy_attachment.operator) == 0 &&
      length(kubernetes_secret_v1.operator_credentials) == 0
    )
    error_message = "No IAM user, access key or credentials Secret should be used with an IAM role"
  }

  # Secret store
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.apiVersion == "humanitec.io/v1alpha1" &&
      kubernetes_manifest.secret_store.manifest.kind == "SecretStore"
    )
    error_message = "Secret store should be a humanitec.io/v1alpha1 SecretStore"
  }
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.name == "my-awssm" &&
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "humanitec-operator-system"
    )
    error_message = "Secret store should be named secret_store_id and be cluster-wide in the Operator namespace by default"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.labels["app.humanitec.io/default-store"] == "true" && length(kubernetes_manifest.secret_store.manifest.metadata.labels) == 1
    error_message = "Secret store should be labelled as the default store by default"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.spec.awssm.region == "eu-west-1"
    error_message = "Secret store should use the region of the aws provider by default"
  }
  assert {
    condition     = length(kubernetes_manifest.secret_store.manifest.spec.awssm.auth) == 0
    error_message = "Secret store should have an empty auth configuration with an IAM role"
  }

  # Outputs
  assert {
    condition = (
      output.secret_store_id == "my-awssm" &&
      output.secret_store_namespace == "humanitec-operator-system" &&
      output.secrets_manager_region == "eu-west-1" &&
      output.aws_account_id == "123456789012"
    )
    error_message = "Secret store ID, namespace, region and account outputs should use the defaults"
  }
  assert {
    condition = (
      output.iam_policy_arn == "arn:aws:iam::123456789012:policy/created-policy" &&
      output.iam_policy_name == "humanitec-operator-my-awssm-abcd"
    )
    error_message = "IAM policy ARN and name outputs should be those of the new IAM policy"
  }
  assert {
    condition = (
      output.iam_role_arn == "arn:aws:iam::123456789012:role/created-role" &&
      output.iam_role_name == "humanitec-operator-my-awssm-abcd" &&
      output.iam_role_unique_id == "AROA11111111111111111" &&
      output.operator_principal_arn == "arn:aws:iam::123456789012:role/created-role"
    )
    error_message = "IAM role and principal outputs should be those of the new IAM role"
  }
  assert {
    condition     = output.iam_role_trust_policy == data.aws_iam_policy_document.operator_pod_identity_trust[0].json
    error_message = "IAM role trust policy output should be the EKS Pod Identity trust policy"
  }
  assert {
    condition     = output.pod_identity_association_id == "a-0000000000000000"
    error_message = "Pod Identity association ID output should be the ID of the created association"
  }
  assert {
    condition = output.pod_identity_association == {
      cluster_name    = "my-cluster"
      namespace       = "humanitec-operator-system"
      service_account = "humanitec-operator-controller-manager"
    }
    error_message = "Pod Identity association output should contain the cluster name, namespace and service account of the Operator"
  }
  assert {
    condition     = length(output.operator_serviceaccount_annotations) == 0
    error_message = "Operator service account annotations output should be empty with EKS Pod Identity"
  }
  assert {
    condition = (
      output.iam_user_arn == null &&
      output.iam_user_name == null &&
      output.iam_user_unique_id == null &&
      output.iam_user_credentials_secret_name == null
    )
    error_message = "IAM user outputs should be null with an IAM role"
  }
  assert {
    condition     = output.cross_account_secret_resource_policy == data.aws_iam_policy_document.cross_account_secret_resource_policy.json
    error_message = "Cross-account secret resource policy output should be the policy document"
  }
  assert {
    condition = [for p in data.aws_iam_policy_document.cross_account_secret_resource_policy.statement[0].principals : {
      type        = p.type
      identifiers = toset(p.identifiers)
    }] == [{ type = "AWS", identifiers = toset(["arn:aws:iam::123456789012:role/created-role"]) }]
    error_message = "Cross-account secret resource policy should allow the IAM role of the Operator"
  }
}

run "irsa" {
  command = apply

  variables {
    auth_method = "irsa"
  }

  assert {
    condition     = aws_iam_role.operator[0].name == "humanitec-operator-my-awssm-abcd"
    error_message = "IAM role name should be generated as humanitec-operator-<secret_store_id>-<suffix>, got ${aws_iam_role.operator[0].name}"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.operator[0].role == "humanitec-operator-my-awssm-abcd"
    error_message = "IAM policy should be attached to the IAM role"
  }
  assert {
    condition     = length(aws_eks_pod_identity_association.operator) == 0 && length(data.aws_iam_policy_document.operator_pod_identity_trust) == 0
    error_message = "No EKS Pod Identity association or trust policy should be used with IRSA"
  }

  # IRSA trust policy
  assert {
    condition     = data.aws_eks_cluster.operator[0].name == "my-cluster"
    error_message = "EKS cluster should be read by eks_cluster_name"
  }
  assert {
    condition     = data.aws_iam_openid_connect_provider.operator[0].url == "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
    error_message = "OIDC provider should be read by the issuer URL of the EKS cluster"
  }
  assert {
    condition     = aws_iam_role.operator[0].assume_role_policy == data.aws_iam_policy_document.operator_irsa_trust[0].json
    error_message = "IAM role should use the IRSA trust policy"
  }
  assert {
    condition = (
      length(data.aws_iam_policy_document.operator_irsa_trust[0].statement) == 1 &&
      data.aws_iam_policy_document.operator_irsa_trust[0].statement[0].effect == "Allow" &&
      toset(data.aws_iam_policy_document.operator_irsa_trust[0].statement[0].actions) == toset(["sts:AssumeRoleWithWebIdentity"])
    )
    error_message = "Trust policy should allow sts:AssumeRoleWithWebIdentity"
  }
  assert {
    condition = [for p in data.aws_iam_policy_document.operator_irsa_trust[0].statement[0].principals : {
      type        = p.type
      identifiers = toset(p.identifiers)
      }] == [{
      type        = "Federated"
      identifiers = toset(["arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"])
    }]
    error_message = "Trust policy should trust the OIDC provider of the EKS cluster"
  }
  assert {
    condition = toset([for c in data.aws_iam_policy_document.operator_irsa_trust[0].statement[0].condition : {
      test     = c.test
      variable = c.variable
      values   = toset(c.values)
      }]) == toset([
      {
        test     = "StringEquals"
        variable = "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:aud"
        values   = toset(["sts.amazonaws.com"])
      },
      {
        test     = "StringEquals"
        variable = "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub"
        values   = toset(["system:serviceaccount:humanitec-operator-system:humanitec-operator-controller-manager"])
      },
    ])
    error_message = "Trust policy should be restricted to the audience sts.amazonaws.com and the Operator service account"
  }

  # Secret store
  assert {
    condition     = length(kubernetes_manifest.secret_store.manifest.spec.awssm.auth) == 0
    error_message = "Secret store should have an empty auth configuration with IRSA"
  }

  # Outputs
  assert {
    condition     = output.iam_role_trust_policy == data.aws_iam_policy_document.operator_irsa_trust[0].json
    error_message = "IAM role trust policy output should be the IRSA trust policy"
  }
  assert {
    condition     = output.operator_serviceaccount_annotations == tomap({ "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/created-role" })
    error_message = "Operator service account annotations output should contain the IRSA role ARN annotation"
  }
  assert {
    condition     = output.pod_identity_association_id == null && output.pod_identity_association == null
    error_message = "Pod Identity association outputs should be null with IRSA"
  }
}

# Variations of the secret store

run "generated_secret_store_id" {
  command = apply

  variables {
    secret_store_id = null
  }

  assert {
    condition     = length(random_string.secret_store_id_suffix) == 1 && random_string.secret_store_id_suffix[0].length == 4
    error_message = "A random suffix of four characters should be generated for the secret store ID"
  }
  assert {
    condition = (
      random_string.secret_store_id_suffix[0].upper == false &&
      random_string.secret_store_id_suffix[0].numeric == false &&
      random_string.secret_store_id_suffix[0].special == false
    )
    error_message = "The random suffix of the secret store ID should consist of lowercase letters only"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.name == "awssm-abcd"
    error_message = "Secret store ID should be generated as awssm-<random>, got ${kubernetes_manifest.secret_store.manifest.metadata.name}"
  }
  assert {
    condition     = output.secret_store_id == "awssm-abcd"
    error_message = "Secret store ID output should be the generated ID"
  }
  assert {
    condition     = aws_iam_role.operator[0].name == "humanitec-operator-awssm-abcd-abcd" && aws_iam_policy.operator.name == "humanitec-operator-awssm-abcd-abcd"
    error_message = "Generated IAM names should be based on the generated secret store ID"
  }
}

run "generated_secret_store_id_with_user" {
  command = apply

  variables {
    secret_store_id  = null
    auth_method      = "iam_user"
    eks_cluster_name = null
  }

  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "awssm-abcd-credentials"
    error_message = "Credentials Secret name should be based on the generated secret store ID"
  }
}

run "non_default_store" {
  command = apply

  variables {
    secret_store_default = false
  }

  assert {
    condition     = !can(kubernetes_manifest.secret_store.manifest.metadata.labels)
    error_message = "Non-default secret store should not be labelled as the default store"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.namespace == "humanitec-operator-system"
    error_message = "Non-default secret store should still be cluster-wide by default"
  }
  assert {
    condition     = toset(data.aws_iam_policy_document.operator.statement[0].actions) == toset(["secretsmanager:GetSecretValue"])
    error_message = "IAM policy should only allow reading secrets for a non-default store"
  }
}

run "environment_local_store" {
  command = apply

  variables {
    secret_store_default      = false
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.namespace == "my-app-development"
    error_message = "Environment-local secret store should be created in secret_store_namespace"
  }
  assert {
    condition     = !can(kubernetes_manifest.secret_store.manifest.metadata.labels)
    error_message = "Environment-local secret store should not be labelled as the default store"
  }
  assert {
    condition     = output.secret_store_namespace == "my-app-development"
    error_message = "Secret store namespace output should be secret_store_namespace"
  }
  assert {
    condition = (
      aws_eks_pod_identity_association.operator[0].namespace == "humanitec-operator-system" &&
      aws_eks_pod_identity_association.operator[0].service_account == "humanitec-operator-controller-manager"
    )
    error_message = "Pod Identity association should still be for the Operator service account for an Environment-local store"
  }
}

# Complete cases

run "complete_create_role_pod_identity" {
  command = apply

  variables {
    operator_namespace                = "my-operator"
    operator_serviceaccount           = "my-operator-sa"
    auth_method                       = "pod_identity"
    iam_role_create                   = true
    iam_role_name                     = "my-role"
    iam_role_path                     = "/humanitec/"
    iam_role_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/my-boundary"
    iam_role_tags                     = { env = "test" }
    pod_identity_association_create   = true
    eks_cluster_name                  = "my-cluster"
  }

  # IAM role
  assert {
    condition = (
      aws_iam_role.operator[0].name == "my-role" &&
      aws_iam_role.operator[0].path == "/humanitec/" &&
      aws_iam_role.operator[0].permissions_boundary == "arn:aws:iam::123456789012:policy/my-boundary" &&
      aws_iam_role.operator[0].tags == tomap({ env = "test" })
    )
    error_message = "IAM role should use iam_role_name, iam_role_path, iam_role_permissions_boundary_arn and iam_role_tags"
  }

  # Pod Identity association
  assert {
    condition = (
      aws_eks_pod_identity_association.operator[0].namespace == "my-operator" &&
      aws_eks_pod_identity_association.operator[0].service_account == "my-operator-sa"
    )
    error_message = "Pod Identity association should use the custom Operator namespace and service account"
  }

  # Outputs
  assert {
    condition = output.pod_identity_association == {
      cluster_name    = "my-cluster"
      namespace       = "my-operator"
      service_account = "my-operator-sa"
    }
    error_message = "Pod Identity association output should use the custom Operator namespace and service account"
  }
  assert {
    condition     = output.secret_store_namespace == "my-operator"
    error_message = "Cluster-wide secret store should be in the custom Operator namespace"
  }
}

run "complete_create_role_irsa" {
  command = apply

  variables {
    secret_store_id                   = "complete-awssm"
    secret_store_default              = true
    secrets_manager_region            = "us-east-1"
    secret_name_prefix                = "humanitec/"
    operator_namespace                = "my-operator"
    operator_serviceaccount           = "my-operator-sa"
    iam_policy_name                   = "my-policy"
    iam_policy_path                   = "/humanitec/"
    iam_policy_tags                   = { env = "test" }
    auth_method                       = "irsa"
    iam_role_create                   = true
    iam_role_name                     = "my-role"
    iam_role_path                     = "/humanitec/"
    iam_role_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/my-boundary"
    iam_role_tags                     = { env = "test" }
    eks_cluster_name                  = "my-cluster"
  }

  # IAM policy
  assert {
    condition     = length(random_string.iam_name_suffix) == 0
    error_message = "No random suffix should be generated if all IAM names are set"
  }
  assert {
    condition = (
      aws_iam_policy.operator.name == "my-policy" &&
      aws_iam_policy.operator.path == "/humanitec/" &&
      aws_iam_policy.operator.tags == tomap({ env = "test" })
    )
    error_message = "IAM policy should use iam_policy_name, iam_policy_path and iam_policy_tags"
  }
  assert {
    condition     = toset(data.aws_iam_policy_document.operator.statement[0].resources) == toset(["arn:aws:secretsmanager:us-east-1:123456789012:secret:humanitec/*"])
    error_message = "IAM policy should be restricted to secrets_manager_region and secret_name_prefix"
  }

  # IAM role
  assert {
    condition = (
      aws_iam_role.operator[0].name == "my-role" &&
      aws_iam_role.operator[0].path == "/humanitec/" &&
      aws_iam_role.operator[0].permissions_boundary == "arn:aws:iam::123456789012:policy/my-boundary" &&
      aws_iam_role.operator[0].tags == tomap({ env = "test" })
    )
    error_message = "IAM role should use iam_role_name, iam_role_path, iam_role_permissions_boundary_arn and iam_role_tags"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.operator[0].role == "my-role"
    error_message = "IAM policy should be attached to the custom IAM role"
  }
  assert {
    condition = toset([for c in data.aws_iam_policy_document.operator_irsa_trust[0].statement[0].condition : c.values[0] if endswith(c.variable, ":sub")]) == toset([
      "system:serviceaccount:my-operator:my-operator-sa"
    ])
    error_message = "Trust policy should trust the custom Operator namespace and service account"
  }

  # Secret store
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.name == "complete-awssm" &&
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "my-operator" &&
      kubernetes_manifest.secret_store.manifest.spec.awssm.region == "us-east-1"
    )
    error_message = "Secret store should use secret_store_id, operator_namespace and secrets_manager_region"
  }

  # Outputs
  assert {
    condition     = output.iam_role_name == "my-role" && output.iam_policy_name == "my-policy"
    error_message = "IAM role and policy name outputs should be the custom names"
  }
  assert {
    condition     = output.secrets_manager_region == "us-east-1"
    error_message = "Secrets Manager region output should be secrets_manager_region"
  }
}

run "complete_existing_role_pod_identity" {
  command = apply

  variables {
    iam_role_create = false
    iam_role_arn    = "arn:aws:iam::123456789012:role/existing-path/existing-role"
  }

  # IAM role
  assert {
    condition     = length(aws_iam_role.operator) == 0
    error_message = "IAM role should not be created if iam_role_create is false"
  }
  assert {
    condition     = data.aws_iam_role.operator[0].name == "existing-role"
    error_message = "Existing IAM role should be read by the name in iam_role_arn"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.operator[0].role == "existing-role"
    error_message = "IAM policy should be attached to the existing IAM role"
  }

  # Pod Identity association
  assert {
    condition     = aws_eks_pod_identity_association.operator[0].role_arn == var.iam_role_arn
    error_message = "Pod Identity association should use the existing IAM role"
  }

  # Outputs
  assert {
    condition = (
      output.iam_role_arn == var.iam_role_arn &&
      output.iam_role_name == "existing-role" &&
      output.iam_role_unique_id == "AROA22222222222222222" &&
      output.operator_principal_arn == var.iam_role_arn
    )
    error_message = "IAM role and principal outputs should be those of the existing IAM role"
  }
  assert {
    condition     = output.iam_role_trust_policy == data.aws_iam_policy_document.operator_pod_identity_trust[0].json
    error_message = "IAM role trust policy output should be provided to configure an existing IAM role"
  }
  assert {
    condition     = length(output.operator_serviceaccount_annotations) == 0
    error_message = "Operator service account annotations output should be empty with EKS Pod Identity"
  }
}

run "complete_existing_role_irsa" {
  command = apply

  variables {
    auth_method     = "irsa"
    iam_role_create = false
    iam_role_arn    = "arn:aws:iam::123456789012:role/existing-path/existing-role"
  }

  assert {
    condition     = length(aws_iam_role.operator) == 0 && aws_iam_role_policy_attachment.operator[0].role == "existing-role"
    error_message = "IAM policy should be attached to the existing IAM role"
  }
  assert {
    condition     = output.iam_role_trust_policy == data.aws_iam_policy_document.operator_irsa_trust[0].json
    error_message = "IAM role trust policy output should be provided to configure an existing IAM role"
  }
  assert {
    condition     = output.operator_serviceaccount_annotations == tomap({ "eks.amazonaws.com/role-arn" = var.iam_role_arn })
    error_message = "Operator service account annotations output should contain the existing IAM role ARN"
  }
}

run "complete_create_user" {
  command = apply

  variables {
    auth_method                       = "iam_user"
    eks_cluster_name                  = null
    iam_user_create                   = true
    iam_user_name                     = "my-user"
    iam_user_path                     = "/humanitec/"
    iam_user_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/my-boundary"
    iam_user_tags                     = { env = "test" }
    iam_user_credentials_secret_name  = "my-credentials"
  }

  # IAM user
  assert {
    condition = (
      aws_iam_user.operator[0].name == "my-user" &&
      aws_iam_user.operator[0].path == "/humanitec/" &&
      aws_iam_user.operator[0].permissions_boundary == "arn:aws:iam::123456789012:policy/my-boundary" &&
      aws_iam_user.operator[0].tags == tomap({ env = "test" })
    )
    error_message = "IAM user should use iam_user_name, iam_user_path, iam_user_permissions_boundary_arn and iam_user_tags"
  }
  assert {
    condition     = aws_iam_access_key.operator[0].user == "my-user"
    error_message = "Access key should be created for the IAM user"
  }
  assert {
    condition     = aws_iam_user_policy_attachment.operator[0].user == "my-user" && aws_iam_user_policy_attachment.operator[0].policy_arn == aws_iam_policy.operator.arn
    error_message = "IAM policy should be attached to the IAM user"
  }

  # No IAM role
  assert {
    condition = (
      length(aws_iam_role.operator) == 0 &&
      length(data.aws_iam_role.operator) == 0 &&
      length(aws_iam_role_policy_attachment.operator) == 0 &&
      length(data.aws_eks_cluster.operator) == 0
    )
    error_message = "No IAM role should be used with an IAM user"
  }

  # Credentials Secret
  assert {
    condition = (
      kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "my-credentials" &&
      kubernetes_secret_v1.operator_credentials[0].metadata[0].namespace == "humanitec-operator-system"
    )
    error_message = "Credentials Secret should be named iam_user_credentials_secret_name and be in the namespace of the secret store"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo_revision == 1
    error_message = "Credentials Secret should set data_wo_revision so that the provider writes data_wo and does not read the created access key back into the state"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo == null
    error_message = "Credentials Secret should not store the created access key in the state via data_wo"
  }
  assert {
    condition     = terraform_data.iam_user_access_key_id[0].output == "AKIA11111111111111111"
    error_message = "ID of the created access key should be tracked to replace the credentials Secret on change"
  }

  # Secret store
  assert {
    condition = kubernetes_manifest.secret_store.manifest.spec.awssm.auth == tomap({
      accessKeyIDSecretRef     = { name = "my-credentials", key = "access_key_id" }
      secretAccessKeySecretRef = { name = "my-credentials", key = "secret_access_key" }
    })
    error_message = "Secret store should reference the access key in the credentials Secret"
  }

  # Outputs
  assert {
    condition = (
      output.iam_user_arn == "arn:aws:iam::123456789012:user/created-user" &&
      output.iam_user_name == "my-user" &&
      output.iam_user_unique_id == "AIDA11111111111111111" &&
      output.operator_principal_arn == "arn:aws:iam::123456789012:user/created-user"
    )
    error_message = "IAM user and principal outputs should be those of the new IAM user"
  }
  assert {
    condition     = output.iam_user_credentials_secret_name == "my-credentials"
    error_message = "Credentials Secret name output should be iam_user_credentials_secret_name"
  }
  assert {
    condition = (
      output.iam_role_arn == null &&
      output.iam_role_name == null &&
      output.iam_role_unique_id == null &&
      output.iam_role_trust_policy == null &&
      length(output.operator_serviceaccount_annotations) == 0
    )
    error_message = "IAM role outputs should be null or empty with an IAM user"
  }
  assert {
    condition = (
      length(aws_eks_pod_identity_association.operator) == 0 &&
      output.pod_identity_association_id == null &&
      output.pod_identity_association == null
    )
    error_message = "No Pod Identity association should be used with an IAM user"
  }
}

run "complete_existing_user" {
  command = apply

  variables {
    auth_method                = "iam_user"
    eks_cluster_name           = null
    iam_user_create            = false
    iam_user_arn               = "arn:aws:iam::123456789012:user/existing-path/existing-user"
    iam_user_access_key_id     = "AKIA22222222222222222"
    iam_user_secret_access_key = "existing-secret-access-key"
  }

  # IAM user
  assert {
    condition     = length(aws_iam_user.operator) == 0 && length(aws_iam_access_key.operator) == 0
    error_message = "Neither an IAM user nor an access key should be created if iam_user_create is false"
  }
  assert {
    condition     = data.aws_iam_user.operator[0].user_name == "existing-user"
    error_message = "Existing IAM user should be read by the name in iam_user_arn"
  }
  assert {
    condition     = aws_iam_user_policy_attachment.operator[0].user == "existing-user"
    error_message = "IAM policy should be attached to the existing IAM user"
  }

  # Credentials Secret
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "my-awssm-credentials"
    error_message = "Credentials Secret name should be generated as <secret_store_id>-credentials"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo_revision == 1
    error_message = "Credentials Secret should set data_wo_revision so that the provider writes data_wo and does not read the access key passed in back into the state"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo == null
    error_message = "Credentials Secret should not store the access key passed in in the state via data_wo"
  }
  assert {
    condition     = terraform_data.iam_user_access_key_id[0].output == "AKIA22222222222222222"
    error_message = "ID of the access key passed in should be tracked to replace the credentials Secret on change"
  }

  # Outputs
  assert {
    condition = (
      output.iam_user_arn == var.iam_user_arn &&
      output.iam_user_name == "existing-user" &&
      output.iam_user_unique_id == "AIDA22222222222222222" &&
      output.operator_principal_arn == var.iam_user_arn
    )
    error_message = "IAM user and principal outputs should be those of the existing IAM user"
  }
}

run "environment_local_store_with_user" {
  command = apply

  variables {
    auth_method               = "iam_user"
    eks_cluster_name          = null
    secret_store_default      = false
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].namespace == "my-app-development"
    error_message = "Credentials Secret should be in the namespace of the Environment-local secret store"
  }
  assert {
    condition     = aws_iam_user.operator[0].name == "humanitec-operator-my-awssm-abcd"
    error_message = "IAM user name should be generated as humanitec-operator-<secret_store_id>-<suffix>, got ${aws_iam_user.operator[0].name}"
  }
}

run "cross_account_secrets" {
  command = apply

  variables {
    cross_account_secrets = [
      {
        secret_arn  = "arn:aws:secretsmanager:eu-west-1:210987654321:secret:my-secret-AbCdEf"
        kms_key_arn = "arn:aws:kms:eu-west-1:210987654321:key/1234abcd-12ab-34cd-56ef-1234567890ab"
      },
      {
        secret_arn  = "arn:aws:secretsmanager:eu-west-1:210987654321:secret:other-secret-GhIjKl"
        kms_key_arn = "arn:aws:kms:eu-west-1:210987654321:key/1234abcd-12ab-34cd-56ef-1234567890ab"
      },
    ]
  }

  assert {
    condition     = length(data.aws_iam_policy_document.operator.statement) == 3
    error_message = "IAM policy should contain statements for the secret store, the cross-account secrets, and their KMS keys"
  }
  assert {
    condition = (
      toset(data.aws_iam_policy_document.operator.statement[1].actions) == toset(["secretsmanager:GetSecretValue"]) &&
      toset(data.aws_iam_policy_document.operator.statement[1].resources) == toset([
        "arn:aws:secretsmanager:eu-west-1:210987654321:secret:my-secret-AbCdEf",
        "arn:aws:secretsmanager:eu-west-1:210987654321:secret:other-secret-GhIjKl",
      ])
    )
    error_message = "IAM policy should allow reading the cross-account secrets"
  }
  assert {
    condition = (
      toset(data.aws_iam_policy_document.operator.statement[2].actions) == toset(["kms:Decrypt"]) &&
      data.aws_iam_policy_document.operator.statement[2].resources == toset(["arn:aws:kms:eu-west-1:210987654321:key/1234abcd-12ab-34cd-56ef-1234567890ab"])
    )
    error_message = "IAM policy should allow decrypting with each distinct KMS key once"
  }
  assert {
    condition = (
      toset(data.aws_iam_policy_document.cross_account_kms_key_policy.statement[0].actions) == toset(["kms:Decrypt", "kms:DescribeKey"]) &&
      [for p in data.aws_iam_policy_document.cross_account_kms_key_policy.statement[0].principals : toset(p.identifiers)] == [toset(["arn:aws:iam::123456789012:role/created-role"])]
    )
    error_message = "Cross-account KMS key policy should allow the Operator to decrypt and describe the key"
  }
}

# Edge cases

run "generated_name_is_truncated" {
  command = apply

  variables {
    secret_store_id = "s${join("", [for i in range(62) : "s"])}"
  }

  assert {
    condition     = length(aws_iam_role.operator[0].name) == 64
    error_message = "Generated IAM role name should be truncated to 64 characters, got ${length(aws_iam_role.operator[0].name)}"
  }
  assert {
    condition     = endswith(aws_iam_role.operator[0].name, "-abcd") && endswith(aws_iam_policy.operator.name, "-abcd")
    error_message = "Generated IAM names should keep the full random suffix"
  }
}

run "create_role_without_association" {
  command = apply

  # eks_cluster_name is still set from the file-level variables
  variables {
    pod_identity_association_create = false
  }

  assert {
    condition     = length(aws_iam_role.operator) == 1 && length(aws_eks_pod_identity_association.operator) == 0
    error_message = "IAM role, but no Pod Identity association should be created if pod_identity_association_create is false"
  }
  assert {
    condition     = output.pod_identity_association_id == null
    error_message = "Pod Identity association ID output should be null if no association is created"
  }
  assert {
    condition = output.pod_identity_association == {
      cluster_name    = "my-cluster"
      namespace       = "humanitec-operator-system"
      service_account = "humanitec-operator-controller-manager"
    }
    error_message = "Pod Identity association output should provide the values to configure an association yourself"
  }
}

run "existing_role_pod_identity_without_association" {
  command = apply

  variables {
    iam_role_create                 = false
    iam_role_arn                    = "arn:aws:iam::123456789012:role/existing-role"
    pod_identity_association_create = false
    eks_cluster_name                = null
  }

  assert {
    condition     = length(aws_iam_role.operator) == 0 && length(aws_eks_pod_identity_association.operator) == 0
    error_message = "Neither an IAM role nor a Pod Identity association should be created"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.operator[0].role == "existing-role"
    error_message = "IAM policy should be attached to the existing IAM role"
  }
  assert {
    condition     = output.iam_role_trust_policy == data.aws_iam_policy_document.operator_pod_identity_trust[0].json
    error_message = "IAM role trust policy output should be provided without eks_cluster_name for EKS Pod Identity"
  }
  assert {
    condition = (
      output.pod_identity_association.cluster_name == null &&
      output.pod_identity_association.namespace == "humanitec-operator-system" &&
      output.pod_identity_association.service_account == "humanitec-operator-controller-manager"
    )
    error_message = "Pod Identity association output should provide the namespace and service account, and no cluster name if eks_cluster_name is not set"
  }
}

run "existing_role_irsa_without_eks_cluster_name" {
  command = apply

  variables {
    auth_method      = "irsa"
    iam_role_create  = false
    iam_role_arn     = "arn:aws:iam::123456789012:role/existing-role"
    eks_cluster_name = null
  }

  assert {
    condition     = data.aws_iam_role.operator[0].name == "existing-role"
    error_message = "Existing IAM role should be read from an ARN without path"
  }
  assert {
    condition     = length(data.aws_eks_cluster.operator) == 0 && output.iam_role_trust_policy == null
    error_message = "IAM role trust policy output should be null if eks_cluster_name is not set"
  }
}

run "existing_role_in_other_partition" {
  command = apply

  variables {
    iam_role_create = false
    iam_role_arn    = "arn:aws-us-gov:iam::123456789012:role/existing-role"
  }

  assert {
    condition     = data.aws_iam_role.operator[0].name == "existing-role"
    error_message = "Existing IAM role should be read from an ARN in a partition other than aws"
  }
}

# Validation failures

run "rejects_invalid_secret_store_id" {
  command = plan

  variables {
    secret_store_id = "My_Store"
  }

  expect_failures = [var.secret_store_id]
}

run "rejects_invalid_auth_method" {
  command = plan

  variables {
    auth_method = "workload_identity"
  }

  expect_failures = [var.auth_method]
}

run "default_store_must_be_cluster_wide" {
  command = plan

  # secret_store_default is true by default
  variables {
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  expect_failures = [var.secret_store_default]
}

run "environment_local_store_requires_namespace" {
  command = plan

  variables {
    secret_store_default      = false
    secret_store_cluster_wide = false
  }

  expect_failures = [var.secret_store_namespace]
}

run "cluster_wide_store_rejects_namespace" {
  command = plan

  variables {
    secret_store_namespace = "my-app-development"
  }

  expect_failures = [var.secret_store_namespace]
}

run "rejects_invalid_secret_name_prefix" {
  command = plan

  variables {
    secret_name_prefix = "humanitec/*"
  }

  expect_failures = [var.secret_name_prefix]
}

run "rejects_invalid_cross_account_secret_arn" {
  command = plan

  variables {
    cross_account_secrets = [{
      secret_arn  = "my-secret"
      kms_key_arn = "arn:aws:kms:eu-west-1:210987654321:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    }]
  }

  expect_failures = [var.cross_account_secrets]
}

run "rejects_cross_account_kms_key_alias" {
  command = plan

  variables {
    cross_account_secrets = [{
      secret_arn  = "arn:aws:secretsmanager:eu-west-1:210987654321:secret:my-secret-AbCdEf"
      kms_key_arn = "arn:aws:kms:eu-west-1:210987654321:alias/my-key"
    }]
  }

  expect_failures = [var.cross_account_secrets]
}

run "rejects_invalid_iam_policy_path" {
  command = plan

  variables {
    iam_policy_path = "humanitec"
  }

  expect_failures = [var.iam_policy_path]
}

run "association_requires_eks_cluster_name" {
  command = plan

  variables {
    eks_cluster_name = null
  }

  expect_failures = [var.eks_cluster_name]
}

run "association_requires_eks_cluster_name_for_existing_role" {
  command = plan

  variables {
    iam_role_create  = false
    iam_role_arn     = "arn:aws:iam::123456789012:role/existing-role"
    eks_cluster_name = null
  }

  expect_failures = [var.eks_cluster_name]
}

run "irsa_create_role_requires_eks_cluster_name" {
  command = plan

  variables {
    auth_method      = "irsa"
    eks_cluster_name = null
  }

  expect_failures = [var.eks_cluster_name]
}

run "irsa_rejects_iam_role_arn" {
  command = plan

  variables {
    auth_method  = "irsa"
    iam_role_arn = "arn:aws:iam::123456789012:role/existing-role"
  }

  expect_failures = [var.iam_role_arn]
}

run "create_role_rejects_iam_role_arn" {
  command = plan

  variables {
    iam_role_arn = "arn:aws:iam::123456789012:role/existing-role"
  }

  expect_failures = [var.iam_role_arn]
}

run "create_role_rejects_invalid_path" {
  command = plan

  variables {
    iam_role_path = "humanitec"
  }

  expect_failures = [var.iam_role_path]
}

run "existing_role_requires_iam_role_arn" {
  command = plan

  variables {
    iam_role_create = false
  }

  expect_failures = [var.iam_role_arn]
}

run "existing_role_rejects_invalid_iam_role_arn" {
  command = plan

  variables {
    iam_role_create = false
    iam_role_arn    = "arn:aws:iam::123456789012:policy/existing-policy"
  }

  expect_failures = [var.iam_role_arn]
}

run "existing_role_rejects_other_account" {
  command = plan

  variables {
    iam_role_create = false
    iam_role_arn    = "arn:aws:iam::210987654321:role/existing-role"
  }

  expect_failures = [data.aws_iam_role.operator]
}

run "existing_role_rejects_name" {
  command = plan

  variables {
    iam_role_create = false
    iam_role_arn    = "arn:aws:iam::123456789012:role/existing-role"
    iam_role_name   = "my-role"
  }

  expect_failures = [var.iam_role_name]
}

run "existing_role_rejects_tags" {
  command = plan

  variables {
    iam_role_create = false
    iam_role_arn    = "arn:aws:iam::123456789012:role/existing-role"
    iam_role_tags   = { env = "test" }
  }

  expect_failures = [var.iam_role_tags]
}

run "iam_user_rejects_eks_cluster_name" {
  command = plan

  variables {
    auth_method = "iam_user"
  }

  expect_failures = [var.eks_cluster_name]
}

run "iam_user_rejects_iam_role_settings" {
  command = plan

  variables {
    auth_method                       = "iam_user"
    eks_cluster_name                  = null
    iam_role_name                     = "my-role"
    iam_role_path                     = "/humanitec/"
    iam_role_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/my-boundary"
    iam_role_tags                     = { env = "test" }
  }

  expect_failures = [
    var.iam_role_name,
    var.iam_role_path,
    var.iam_role_permissions_boundary_arn,
    var.iam_role_tags,
  ]
}

run "iam_role_rejects_iam_user_settings" {
  command = plan

  variables {
    iam_user_name                     = "my-user"
    iam_user_path                     = "/humanitec/"
    iam_user_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/my-boundary"
    iam_user_tags                     = { env = "test" }
    iam_user_credentials_secret_name  = "my-credentials"
  }

  expect_failures = [
    var.iam_user_name,
    var.iam_user_path,
    var.iam_user_permissions_boundary_arn,
    var.iam_user_tags,
    var.iam_user_credentials_secret_name,
  ]
}

run "create_user_rejects_existing_user_settings" {
  command = plan

  variables {
    auth_method                = "iam_user"
    eks_cluster_name           = null
    iam_user_arn               = "arn:aws:iam::123456789012:user/existing-user"
    iam_user_access_key_id     = "AKIA22222222222222222"
    iam_user_secret_access_key = "existing-secret-access-key"
  }

  expect_failures = [
    var.iam_user_arn,
    var.iam_user_access_key_id,
    var.iam_user_secret_access_key,
  ]
}

run "existing_user_requires_arn_and_access_key" {
  command = plan

  variables {
    auth_method      = "iam_user"
    eks_cluster_name = null
    iam_user_create  = false
  }

  expect_failures = [
    var.iam_user_arn,
    var.iam_user_access_key_id,
    var.iam_user_secret_access_key,
  ]
}

run "existing_user_rejects_invalid_iam_user_arn" {
  command = plan

  variables {
    auth_method                = "iam_user"
    eks_cluster_name           = null
    iam_user_create            = false
    iam_user_arn               = "arn:aws:iam::123456789012:role/existing-role"
    iam_user_access_key_id     = "AKIA22222222222222222"
    iam_user_secret_access_key = "existing-secret-access-key"
  }

  expect_failures = [var.iam_user_arn]
}

run "existing_user_rejects_other_account" {
  command = plan

  variables {
    auth_method                = "iam_user"
    eks_cluster_name           = null
    iam_user_create            = false
    iam_user_arn               = "arn:aws:iam::210987654321:user/existing-user"
    iam_user_access_key_id     = "AKIA22222222222222222"
    iam_user_secret_access_key = "existing-secret-access-key"
  }

  expect_failures = [data.aws_iam_user.operator]
}
