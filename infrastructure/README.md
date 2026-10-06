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
| Front Door rule set | Packages cached for a year; swaps the client token for a read-only SAS. |
| WAF policy (Standard, custom rule) | Rejects `/deployment/` requests without the client token with a 403, before the cache. |
| Role assignments                                     | The pipeline identity gets Storage Blob Data Contributor, Key Vault Secrets User and CDN Endpoint Contributor.                    |

## How clients authenticate

Cimian clients send a shared token in an `X-Cimian-Token` header, set through
the `AdditionalHttpHeaders` key in `Config.yaml`. Two layers act on it.

1. **A WAF custom rule rejects bad requests before the cache.** Any request
   under `/deployment/` without the exact token gets a 403 from Front Door's
   WAF. The WAF runs before the cache lookup, and that ordering is the point.
   Front Door keys its cache on the URL alone, so an auth check placed after
   the cache could let an unauthenticated request receive an object an
   authorised client had pulled into the cache. `/bootstrap/*` sits outside
   the rule and stays public.
2. **A rule-set rule turns the token into storage access.** For requests that
   pass, Front Door drops the header and appends a read-only SAS before
   forwarding to the private container.

Terraform generates the token and stores it in Key Vault as
`cimian-client-token`, so the package that writes client preferences reads it
from there at build time. The token is also visible in the WAF policy to anyone
with read access on the resource group, so keep that role assignment narrow.

The SAS is reissued every `sas_rotation_days` and is valid for twice that, so
the infra pipeline must run at least that often. The monthly schedule on both
pipelines does it.

## Secrets and the pipelines

The token and the SAS live in Terraform state, and a saved plan file holds
them in plain text too. So:

- **Plans are never uploaded as artifacts.** Artifacts on a public repo can be
  downloaded by anyone signed in. The apply job plans and applies in one job,
  inside the protected environment.
- **Pull requests get no cloud credential.** They run `terraform fmt`,
  `terraform init -backend=false` and `terraform validate` only. A pull request
  can change the workflow it runs, so any credential it could reach is one it
  could leak.
- **In GitHub,** only the `environment:cimian-infrastructure` federated
  subject may hold state or Key Vault access. Never add a federated credential
  for `pull_request` that can read state or the vault.
- **In Azure DevOps,** add a Branch control check on the service connection
  allowing only `refs/heads/main`. A pull request build then cannot use the
  connection, even if it edits the YAML to ask for it.
- **No output carries a secret.** Values derived from the token and the SAS
  are marked sensitive by their providers, so plan output prints
  `(sensitive value)` instead of them.

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
