# run.ps1 — Lance Sunday Tracker sur le device branche (flutter run).
# Usage : depuis le dossier du projet, lance   .\run.ps1
#
# Fait, dans l'ordre :
#   1. bump automatique du build number dans pubspec.yaml (format yyyyMMdd + sequence)
#   2. flutter run   (mode debug par defaut, --release avec -Release)
#
# Options :
#   .\run.ps1 -Release    -> lance en mode release (kDebugMode=false, distanceFilter=5)
#   .\run.ps1 -NoBump     -> ne touche pas a la version

param(
  [switch]$Release,
  [switch]$NoBump
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# --- 1. Bump du build number -----------------------------------------------------
$pubspec = Join-Path $PSScriptRoot 'pubspec.yaml'
if (-not $NoBump) {
  # Lecture/ecriture en UTF-8 SANS BOM via .NET : Get-Content/Set-Content de
  # PowerShell 5.1 corrompent les accents et ajoutent un BOM (mojibake).
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $content = [System.IO.File]::ReadAllText($pubspec, [System.Text.Encoding]::UTF8)

  if ($content -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$') {
    $semver   = $Matches[1]
    $oldBuild = $Matches[2]
    $today    = Get-Date -Format 'yyyyMMdd'

    if ($oldBuild.Length -ge 8 -and $oldBuild.Substring(0, 8) -eq $today) {
      # meme jour -> on incremente la sequence (2 derniers chiffres)
      $seq = [int]$oldBuild.Substring(8)
      $newBuild = $today + ('{0:D2}' -f ($seq + 1))
    } else {
      # nouveau jour -> sequence 01
      $newBuild = $today + '01'
    }

    $newVersion = "$semver+$newBuild"
    $content = $content -replace '(?m)^version:[^\r\n]*', "version: $newVersion"
    [System.IO.File]::WriteAllText($pubspec, $content, $utf8NoBom)
    Write-Host "[run] Version : $semver+$oldBuild  ->  $newVersion" -ForegroundColor Cyan
  } else {
    Write-Host "[run] AVERTISSEMENT : ligne 'version:' introuvable/format inattendu, bump ignore." -ForegroundColor Yellow
  }
} else {
  $content = [System.IO.File]::ReadAllText($pubspec, [System.Text.Encoding]::UTF8)
  if ($content -match '(?m)^version:\s*(\S+)\s*$') {
    Write-Host "[run] Version courante (inchangee) : $($Matches[1])" -ForegroundColor Cyan
  }
}

# --- 2. flutter run --------------------------------------------------------------
if ($Release) {
  Write-Host "[run] flutter run --release ..." -ForegroundColor Cyan
  flutter run --release
} else {
  Write-Host "[run] flutter run (debug) ..." -ForegroundColor Cyan
  flutter run
}
