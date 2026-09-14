# Terraform on Azure with HCP Terraform and federated credentials

A small learning project that provisions an Azure resource group and virtual network
([main.tf](main.tf)) while keeping state in [HCP Terraform](https://app.terraform.io)
(formerly Terraform Cloud).

The interesting part is not the infrastructure — it is the authentication. No client
secret or certificate is ever created, stored, or rotated. Instead, HCP Terraform
authenticates to Azure using **workload identity federation** (OIDC).

## How the authentication works

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

## Prerequisites

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

## 1. Sign in

```bash
az login --tenant ${tenantId}
az account set --subscription ${subscriptionId}
```

## 2. Create the app registration and service principal

The app registration is the identity HCP Terraform will impersonate; the service
principal is its representation inside your tenant and the thing role assignments
attach to.

```bash
# Creates the application object; note the returned appId (client ID)
az ad app create --display-name "${displayName}" --query appId -o tsv

# Creates the service principal; note the returned id (object ID)
az ad sp create --id ${appId} --query id -o tsv
```

## 3. Grant Azure permissions

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

## 4. Set up the HCP Terraform workspace

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

Do **not** set `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, or `ARM_USE_OIDC` yourself —
HCP Terraform injects the OIDC settings for you, and a stray secret will take
precedence and mask federation problems.

Putting the variables in a project-scoped variable set means additional workspaces in
the same project inherit them, but note that each workspace still needs its own
federated credentials, because the workspace name is part of the subject.

## 5. Create the federated credentials

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

## 6. Run it

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

## Troubleshooting

**`AADSTS70021: No matching federated identity record found`** — the subject in the
token does not match any credential. Compare the subject in the run log against
`az ad app federated-credential list` character for character; the usual culprits are
the project name, a renamed workspace, or a missing `run_phase:apply` credential.

**Plan succeeds, apply fails to authenticate** — you created only the `plan`
credential.

**`AuthorizationFailed` during apply** — federation worked, RBAC did not. Check the
role assignment scope, and allow a minute for assignment propagation.

**Provider ignores the OIDC settings** — an `ARM_CLIENT_SECRET` or `ARM_CLIENT_ID`
left over in the workspace is overriding them.

## Notes

* An app registration supports a limited number of federated credentials, so a
  separate app registration per workspace scales better than one shared identity, and
  keeps blast radius small.
