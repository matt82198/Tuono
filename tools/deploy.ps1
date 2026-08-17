<#
.SYNOPSIS
  Mirror this repo into the live WoW AddOns folder.

.DESCRIPTION
  The game loads the addon from Interface\AddOns\Tuono, not from this repo. This copies
  the shipping files across and deletes nothing it did not put there.

  Repo-only files (.git, docs, tests, tools) are never deployed: the client would not read
  them, and tests/ contains a WoW API stub that must never shadow the real client.

.PARAMETER AddOnsPath
  Override the AddOns directory. Defaults to the standard 64-bit retail install.

.PARAMETER WhatIf
  Show what would be copied without copying.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns"
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $AddOnsPath 'Tuono'

if (-not (Test-Path $AddOnsPath)) {
    throw "AddOns folder not found: $AddOnsPath`nPass -AddOnsPath to point at your install."
}

# The .toc is the manifest: it names every file the client will load, in order. Deploying
# anything not listed there is dead weight; deploying a file listed but absent is a silent
# load failure. So the .toc drives the copy rather than a directory sweep.
$toc = Join-Path $repo 'Tuono.toc'
if (-not (Test-Path $toc)) { throw "Missing Tuono.toc at $toc" }

$files = @('Tuono.toc')
$missing = @()
foreach ($line in (Get-Content $toc)) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
    $files += $trimmed
    if (-not (Test-Path (Join-Path $repo $trimmed))) { $missing += $trimmed }
}

if ($missing.Count -gt 0) {
    throw "Tuono.toc lists $($missing.Count) file(s) that do not exist:`n  " + ($missing -join "`n  ")
}

# Non-Lua assets the .toc does not list but the addon references at runtime.
foreach ($asset in @('logo.tga')) {
    if (Test-Path (Join-Path $repo $asset)) { $files += $asset }
}

if ($PSCmdlet.ShouldProcess($dest, "Deploy $($files.Count) files")) {
    foreach ($rel in $files) {
        $src = Join-Path $repo $rel
        $dst = Join-Path $dest $rel
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item $src -Destination $dst -Force
    }
    Write-Host "Deployed $($files.Count) files to $dest" -ForegroundColor Green
    Write-Host "Run /reload in game to pick them up." -ForegroundColor DarkGray
} else {
    $files | ForEach-Object { Write-Host "  would copy $_" }
}
