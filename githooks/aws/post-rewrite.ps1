#Requires -Version 5.1
# HOOK_VERSION = '2026.06.25'
#
# ──────────────────────────────────────────────────────────────────────────────
#  post-rewrite.ps1  –  safety net after git rebase / git commit --amend (AWS)
#
#  Git fires post-rewrite after `git rebase` and `git commit --amend`. Neither
#  is a pull, but both can re-point HEAD at pkgsinfo that references packages
#  you don't have locally.
#
#  Behaviour: delegates to post-merge with the same change-detection logic.
#  Rebases set ORIG_HEAD, which post-merge consumes naturally. Amends don't
#  change HEAD's reachable commits, so we skip those.
#
#  Env bypass: GIT_NO_VERIFY, SKIP_CIMIAN_HOOKS, SKIP_POST_REWRITE, DISABLE_CUSTOM_HOOKS
# ──────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path (Join-Path $HookDir '..') 'lib\common.ps1')

Test-HookVersion -HookName 'post-rewrite' -HookVersion '2026.06.25'
if (Test-ShouldSkipHook -HookName 'post-rewrite') { exit 0 }
Add-WorktreeCacheLink

# Git passes the rewrite command ('rebase' or 'amend') as the first argument.
$rewriteType = if ($args.Count -ge 1) { $args[0] } else { 'rebase' }
if ($rewriteType -eq 'amend') { exit 0 }

$postMerge = Join-Path $HookDir 'post-merge.ps1'
if (Test-Path $postMerge) {
    & pwsh -NoProfile -File $postMerge @args
    exit $LASTEXITCODE
}
exit 0
