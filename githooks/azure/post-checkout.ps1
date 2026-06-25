#Requires -Version 5.1
# HOOK_VERSION = '2026.06.25'
#
# ──────────────────────────────────────────────────────────────────────────────
#  post-checkout.ps1  –  per-admin fresh-clone setup (Azure)
#
#  This is a SCAFFOLD showing where org-specific setup belongs. Typical work:
#    - Worktree cache linking (handled by lib/common.ps1 — always).
#    - Hook version check (handled by lib/common.ps1 — always).
#    - Fetch secrets from Azure Key Vault:
#         az keyvault secret show --vault-name $Vault --name ... --query value -o tsv
#      and write them to terraform.tfvars / local.settings.json / .env files
#      your local dev tooling expects.
#    - Install local CLI tools the admin needs.
#
#  This hook is intentionally minimal — secrets management is org-specific.
#  Fork it and add your Key Vault fetches, config writes, and tool installs.
#
#  Runs on fresh clone and on every branch switch.
#  Manual run: pwsh -File githooks/azure/post-checkout.ps1 --force
#
#  Env bypass: GIT_NO_VERIFY, SKIP_CIMIAN_HOOKS, DISABLE_CUSTOM_HOOKS
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path (Join-Path $HookDir '..') 'lib\common.ps1')

Test-HookVersion -HookName 'post-checkout' -HookVersion '2026.06.25'
if (Test-ShouldSkipHook -HookName 'post-checkout') { exit 0 }
Add-WorktreeCacheLink

# Enforce rebase-based pull strategy — keeps history linear.
$RepoRoot = Get-CimianRepoRoot
if (-not $RepoRoot) { exit 0 }
git -C $RepoRoot config pull.rebase true 2>$null | Out-Null

# ── Secrets scaffold (replace with your org's Key Vault fetches) ─────────────
# Example pattern — uncomment and customise for your environment.
#
#   $forceRun = ($args -contains '--force') -or ($args -contains '-f')
#   $vaultName = if ($env:CIMIAN_KEY_VAULT_NAME) { $env:CIMIAN_KEY_VAULT_NAME } else { 'your-vault-name' }
#   $tfvars = Join-Path $RepoRoot 'infrastructure\terraform.tfvars'
#
#   if (-not $forceRun -and (Test-Path $tfvars)) { exit 0 }
#
#   $secret = az keyvault secret show --vault-name $vaultName --name 'SomeSecret' --query value -o tsv 2>$null
#   Set-Content -Path $tfvars -Value "some_secret = `"$secret`""

exit 0
