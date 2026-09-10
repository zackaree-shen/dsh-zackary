# dsh-sync pre-commit hook, native PowerShell implementation.
#
# The bash sibling (hooks/pre-commit) needs a real bash + cmp/cp/dirname. On
# Windows `C:\Windows\system32\bash.exe` is only the WSL launcher, so that body
# cannot run there — this file is the Windows equivalent and install.ps1 wires a
# .cmd wrapper to it.
#
# Auto-syncs the locally installed dsh-sync skill back into the repo, so a skill
# edit on any machine can never be forgotten.
#
# Convention: where the skill is installed, ~/.agents/skills/dsh-sync/SKILL.md is
# the source of truth. Never edit the repo copy directly.
$ErrorActionPreference = 'Stop'

# Locate the repo root from git itself, so a worktree or a custom
# core.hooksPath still resolves correctly.
$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) { exit 0 }
$repoRoot = $repoRoot.Trim()

$home2 = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$localSkill = Join-Path $home2 '.agents\skills\dsh-sync\SKILL.md'
$repoSkill = Join-Path $repoRoot '.agents\skills\dsh-sync\SKILL.md'

# Skill not installed on this machine -> nothing to sync.
if (-not (Test-Path -LiteralPath $localSkill)) { exit 0 }

# Already in sync -> no-op (cheap length check first, then bytes).
$src = Get-Item -LiteralPath $localSkill
if (Test-Path -LiteralPath $repoSkill) {
  $dst = Get-Item -LiteralPath $repoSkill
  if ($src.Length -eq $dst.Length) {
    $a = [System.IO.File]::ReadAllBytes($localSkill)
    $b = [System.IO.File]::ReadAllBytes($repoSkill)
    if ([System.Linq.Enumerable]::SequenceEqual($a, $b)) { exit 0 }
  }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repoSkill) | Out-Null
Copy-Item -LiteralPath $localSkill -Destination $repoSkill -Force
& git -C $repoRoot add -- .agents/skills/dsh-sync/SKILL.md
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host 'dsh-sync: local skill synced into repo (staged .agents/skills/dsh-sync/SKILL.md)'
exit 0
