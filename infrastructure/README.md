# Infrastructure

Terraform for the cloud side of a Cimian repo on Azure: the storage the repo
lives in, the Front Door that serves it, and the Key Vault that holds its
secrets. The pipelines in `../pipelines/*/infrastructure.yml` plan it on every
pull request and apply it from `main` behind an approval.

## What it creates

| Resource                                             | Purpose                                                                                                                           |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Storage account, `repo` container (private)          | The Cimian repo: `deployment/{catalogs,manifests,pkgsinfo,icons,pkgs}`. The push pipelines sync here.                             |
| `public` container (anonymous blob read, no listing) | Files BootstrapMate fetches at the ESP, under `bootstrap/`, before the machine has a credential.                                  |
| Key Vault, RBAC authorization                        | No access policies. Holds the client token and anything else the pipelines read, such as the signing certificate.                 |
| Front Door Standard profile and endpoint             | `/deployment/*` to the `repo` container, `/bootstrap/*` to `public/bootstrap`. Optional custom domain with a managed certificate. |
| Front Door rule set                                  | Packages cached for a year; the client token check that admits a request to the private container.                                |
| Role assignments                                     | The pipeline identity gets Storage Blob Data Contributor, Key Vault Secrets User and CDN Endpoint Contributor.                    |

## How clients authenticate

Cimian clients send a shared token in an `X-Cimian-Token` header, set through
the `AdditionalHttpHeaders` key in `Config.yaml`. When the header matches,
Front Door drops it and appends a read-only SAS before forwarding to the
private container. A request without it reaches the container with no SAS and
gets a 403.

Terraform generates the token and stores it in Key Vault as
`cimian-client-token`, so the package that writes client preferences reads it
from there at build time. The SAS is reissued every `sas_rotation_days` and is
valid for twice that, so the infra pipeline must run at least that often. A
schedule on the pipeline does it.

The token and the SAS both end up in Terraform state. Keep state in its own
storage account, readable only by the pipeline identity and the people who
administer it.

## Before the first apply

1. Create the state storage account and container by hand, or from a separate
   bootstrap configuration. This config never manages its own state.
2. Give the pipeline identity Storage Blob Data Contributor on the state
   container. To create role assignments, it also needs Owner, or User Access
   Administrator plus Contributor, on the target resource group.
3. Copy `terraform.tfvars.example` to `terraform.tfvars` (gitignored) and fill
   it in. For CI, set the same values as `TF_VAR_*` variables instead.
4. Copy `backend.hcl.example` to `backend.hcl` (gitignored) to run locally:

```sh
terraform init -backend-config=backend.hcl
```

Then check what it would do:

```sh
terraform plan
```

5. With a custom domain, add the `_dnsauth` TXT record from the
   `custom_domain_validation_token` output and a CNAME to the endpoint host.

## Things to know

- `prevent_destroy` is set on the storage account. A plan that replaces it
  fails until that line is removed in a reviewed change.
- `/deployment/pkgs/*` is never purged by the push pipelines. Package files are
  version-named, so a new build is a new path.
- After the first deploy, request a cached package with no token and expect a 403. That confirms an authenticated request's cache entry is not served to an
  unauthenticated one.
