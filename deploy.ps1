# deploy.ps1 — Build Android release de Sunday Tracker (app mobile).
# Usage : depuis le dossier du projet, lance   .\deploy.ps1
#
# Fait, dans l'ordre :
#   1. bump automatique du build number dans pubspec.yaml (format yyyyMMdd + sequence)
#   2. flutter clean            (build complet garanti)
#   3. flutter build apk --release
#
# Options :
#   .\deploy.ps1 -NoBump    -> ne touche pas a la version (rebuild tel quel)
#   .\deploy.ps1 -Bundle    -> genere un app bundle (.aab) au lieu d'un APK

param(
  [switch]$NoBump,
  [switch]$Bundle
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
    # [^\r\n]* : ne remplace que le contenu de la ligne version, sans toucher aux
    # sauts de ligne (preserve la ligne vide qui suit).
    $content = $content -replace '(?m)^version:[^\r\n]*', "version: $newVersion"
    [System.IO.File]::WriteAllText($pubspec, $content, $utf8NoBom)
    Write-Host "[deploy] Version : $semver+$oldBuild  ->  $newVersion" -ForegroundColor Cyan
  } else {
    Write-Host "[deploy] AVERTISSEMENT : ligne 'version:' introuvable/format inattendu, bump ignore." -ForegroundColor Yellow
  }
} else {
  $content = [System.IO.File]::ReadAllText($pubspec, [System.Text.Encoding]::UTF8)
  if ($content -match '(?m)^version:\s*(\S+)\s*$') {
    Write-Host "[deploy] Version courante (inchangee) : $($Matches[1])" -ForegroundColor Cyan
  }
}

# --- 2. flutter clean ------------------------------------------------------------
# clean OBLIGATOIRE : un build incremental produit par intermittence un binaire
# incomplet sur cette machine. Le clean garantit un build complet a chaque fois.
Write-Host "[deploy] flutter clean ..." -ForegroundColor Cyan
flutter clean
if ($LASTEXITCODE -ne 0) { Write-Host "[deploy] ECHEC du flutter clean. Build annule." -ForegroundColor Red; exit 1 }

# --- 3. Build Android release ----------------------------------------------------
if ($Bundle) {
  Write-Host "[deploy] flutter build appbundle --release ..." -ForegroundColor Cyan
  flutter build appbundle --release
  $artifact = Join-Path $PSScriptRoot 'build\app\outputs\bundle\release\app-release.aab'
} else {
  Write-Host "[deploy] flutter build apk --release ..." -ForegroundColor Cyan
  flutter build apk --release
  $artifact = Join-Path $PSScriptRoot 'build\app\outputs\flutter-apk\app-release.apk'
}
if ($LASTEXITCODE -ne 0) { Write-Host "[deploy] ECHEC du build Flutter. Build annule." -ForegroundColor Red; exit 1 }

Write-Host "[deploy] OK -> $artifact" -ForegroundColor Green
