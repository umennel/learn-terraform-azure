# Terraform on Azure: Blob Storage Backend and HCP Terraform

This repository contains two Azure-focused Terraform learning examples. The first
shows how to use Azure Blob Storage as a remote backend for Terraform state, while
the second demonstrates running Terraform in [HCP Terraform](https://app.terraform.io)
(formerly Terraform Cloud) with Azure workload identity federation (OIDC).

## Terraform with Azure Blob Storage Backend

This first section walks through a complete Terraform workflow using Azure Blob
Storage as the remote backend for state. The typical lifecycle is: set up the
backend, initialize Terraform, deploy infrastructure, inspect the state, and then
tear everything down when you are finished.

### 1. Set up the Azure storage backend

Depending on which state management approach you choose, the commented `cloud`
block in [main.tf](main.tf) may need to be enabled or adjusted. In the Azure Blob
Storage backend example, the `backend "azurerm"` configuration is used; in the
HCP Terraform example, the `cloud { ... }` configuration is the one that should be
configured instead.

Create a resource group that will contain the storage account used to persist the
Terraform state file.

```bash
az group create -n rg-terraform-state --location switzerlandnorth
```

Create the storage account itself. This is the Azure resource that will host the
state file for Terraform.

```bash
az storage account create   --resource-group rg-terraform-state   --name stmenutfstatedev
```

Create a Blob container named `tfstate` inside the storage account. Terraform
stores the remote state file in this container, which allows multiple runs and
team members to share the same state securely.

```bash
az storage container create   --name "tfstate"   --account-name "stmenutfstatedev"   --auth-mode login
```

Enable versioning on the Blob service so previous state versions are retained. This
is useful for recovering an earlier state or reviewing changes made over time.

```bash
az storage account blob-service-properties update   --resource-group rg-terraform-state   --account-name "stmenutfstatedev"   --enable-versioning true
```

If you are using `--auth-mode login`, make sure the user running Terraform has
appropriate Azure RBAC permissions for Blob storage. A role like `Storage Blob
Data Contributor` or `Storage Blob
Data Owner` is usually required.

### 2. Configure the Terraform Backend

The backend configuration in [main.tf](main.tf) is set for Azure Blob Storage state
management. It uses the `azurerm` backend with Azure AD authentication enabled
(`use_azuread_auth = true`), and points to the storage account `stmenutfstatedev`,
the `tfstate` container, and the state key `prod/terraform.tfstate`.

```hcl
terraform {
  backend "azurerm" {
    use_cli              = true
    use_azuread_auth     = true
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stmenutfstatedev"
    container_name       = "tfstate"
    key                  = "prod/terraform.tfstate"
  }
}
```

This is the configuration used for the Azure Blob Storage backend flow. The
commented `cloud` block in the same file is the alternative configuration for the
HCP Terraform workflow and should only be enabled when you are using that state
management method instead.

### 3. Initialize Terraform

Before Terraform can plan or apply resources, it must initialize the working
configuration. This step downloads the required provider plugins and configures the
backend so state is stored in the Azure Blob container instead of a local file.

```bash
terraform init
```

### 4. Deploy resources

Run a plan to preview the infrastructure changes, then apply them to create the
resources in Azure. This is the point where Terraform compares the desired state
with the current state and provisions anything that is missing.

```bash
terraform plan
terraform apply
```

### 5. Examine the state

After the deployment, inspect the Terraform state to confirm what resources are
managed and that the backend is working correctly. This is especially useful when
troubleshooting drift, verifying resource creation, or checking the current state
for a project.

```bash
terraform show
```

### 6. Tear down the environment

When you are finished with the exercise, destroy the managed resources to avoid
ongoing Azure costs. Terraform removes the infrastructure described in the
configuration, and the state backend remains available if you want to use it again.

```bash
terraform destroy
```

## Terraform on Azure with HCP Terraform and federated credentials

Here, the interesting part is not the infrastructure — it is the authentication. No client
secret or certificate is ever created, stored, or rotated. Instead, HCP Terraform
authenticates to Azure using **workload identity federation** (OIDC).

### How the authentication works

1. During a run, HCP Terraform mints a short-lived OIDC token describing that run:
   which organization, project, workspace, and whether the run is in its `plan` or
   `apply` phase.
2. The AzureRM provider exchanges that token with Microsoft Entra ID for an Azure
   access token.
3. Entra ID accepts the exchange only if the token's issuer, subject, and audience
   match a **federated identity credential** registered on the app registration.
4. The service principal behind that app registration holds the Azure RBAC role that
   actually permits the changes.

Because the subject string encodes the run phase, `plan` and `apply` need **two**
federated credentials — a run would otherwise fail at apply time even though the plan
succeeded.

### Prerequisites

* Azure CLI, signed in with permission to create app registrations in the tenant and
   role assignments on the target subscription.
* Terraform >= 1.1.0.
* An HCP Terraform organization, and an account that can create workspaces and
   variable sets in it.

Collect the values referenced below up front:

| Variable          | Where it comes from                                             |
| ----------------- | --------------------------------------------------------------- |
| `tenantId`        | `az account show --query tenantId -o tsv`                        |
| `subscriptionId`  | `az account show --query id -o tsv`                              |
| `displayName`     | Your choice, e.g. `learn-terraform-azure`                        |
| `appId`           | Output of the app registration step                              |
| `spId`            | Object ID of the service principal created for that app          |

The configuration ships with placeholder identifiers. Replace `example-org` with your
own HCP Terraform organization name in [main.tf](main.tf),
[credential-plan.json](credential-plan.json), and
[credential-apply.json](credential-apply.json), and adjust the workspace and project
names if yours differ.

### 1. Sign in

```bash
az login --tenant ${tenantId}
az account set --subscription ${subscriptionId}
```

### 2. Create the app registration and service principal

The app registration is the identity HCP Terraform will impersonate; the service
principal is its representation inside your tenant and the thing role assignments
attach to.

```bash
# Creates the application object; note the returned appId (client ID)
az ad app create --display-name "${displayName}" --query appId -o tsv

# Creates the service principal; note the returned id (object ID)
az ad sp create --id ${appId} --query id -o tsv
```

### 3. Grant Azure permissions

`Contributor` at subscription scope is convenient for a learning project. For anything
real, scope the assignment to a single resource group and prefer the narrowest role
that still lets the configuration converge.

```bash
az role assignment create \
  --assignee-object-id "${spId}" \
  --assignee-principal-type "ServicePrincipal" \
  --role "Contributor" \
  --scope "/subscriptions/${subscriptionId}"
```

Use `--assignee-object-id` rather than `--assignee`: freshly created principals are
not always resolvable by name yet, and the explicit object ID avoids a replication
race.

### 4. Set up the HCP Terraform workspace

Create the workspace and reference it from the `cloud` block in [main.tf](main.tf):

```hcl
cloud {
  organization = "example-org"
  workspaces {
    name = "learn-terraform-azure"
  }
}
```

Then add these **environment** variables (not Terraform variables) to the workspace,
or to a variable set associated with the project:

| Variable                   | Value              | Purpose                                                   |
| -------------------------- | ------------------ | --------------------------------------------------------- |
| `TFC_AZURE_PROVIDER_AUTH`  | `true`             | Tells HCP Terraform to generate the OIDC token for the run |
| `TFC_AZURE_RUN_CLIENT_ID`  | `${appId}`         | The app registration to authenticate as                    |
| `ARM_TENANT_ID`            | `${tenantId}`      | Entra ID tenant to exchange the token with                 |
| `ARM_SUBSCRIPTION_ID`      | `${subscriptionId}`| Subscription the provider targets                          |

Do __not__ set `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, or `ARM_USE_OIDC` yourself —
HCP Terraform injects the OIDC settings for you, and a stray secret will take
precedence and mask federation problems.

Putting the variables in a project-scoped variable set means additional workspaces in
the same project inherit them, but note that each workspace still needs its own
federated credentials, because the workspace name is part of the subject.

### 5. Create the federated credentials

The two parameter files must match your organization, project, and workspace exactly.
The subject is compared as a literal string — a renamed workspace or a project called
something other than `Default Project` will break the exchange.

[credential-plan.json](credential-plan.json):

```json
{
    "name": "terraform-plan",
    "issuer": "https://app.terraform.io",
    "subject": "organization:example-org:project:Default Project:workspace:learn-terraform-azure:run_phase:plan",
    "description": "Testing terraform plan",
    "audiences": ["api://AzureADTokenExchange"]
}
```

[credential-apply.json](credential-apply.json) is identical except for the name and
the trailing `run_phase:apply`.

```bash
az ad app federated-credential create --id ${appId} --parameters credential-plan.json
az ad app federated-credential create --id ${appId} --parameters credential-apply.json
```

Verify with:

```bash
az ad app federated-credential list --id ${appId} -o table
```

### 6. Run it

```bash
terraform login    # once, to authenticate the CLI against HCP Terraform
terraform init
terraform plan
terraform apply
```

Runs execute remotely in HCP Terraform, so the Azure credentials never exist on your
machine — your local CLI only needs an HCP Terraform token. Watch the run in the web
UI to see the plan and apply phases authenticate separately.

Tear down when finished:

```bash
terraform destroy
```

### Troubleshooting

__`AADSTS70021: No matching federated identity record found`__ — the subject in the
token does not match any credential. Compare the subject in the run log against
`az ad app federated-credential list` character for character; the usual culprits are
the project name, a renamed workspace, or a missing `run_phase:apply` credential.

**Plan succeeds, apply fails to authenticate** — you created only the `plan`
credential.

**`AuthorizationFailed` during apply** — federation worked, RBAC did not. Check the
role assignment scope, and allow a minute for assignment propagation.

__Provider ignores the OIDC settings__ — an `ARM_CLIENT_SECRET` or `ARM_CLIENT_ID`
left over in the workspace is overriding them.

### Notes

* An app registration supports a limited number of federated credentials, so a
   separate app registration per workspace scales better than one shared identity, and
   keeps blast radius small.
