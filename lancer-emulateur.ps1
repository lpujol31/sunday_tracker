<#
    lancer-emulateur.ps1 — demarre l'emulateur Android optimise, sans Android Studio

    Interet : Android Studio consomme ~570 Mo juste pour afficher le Device Manager.
    Ce script fait la meme chose en ligne de commande, nettoie les instances
    zombies (cause classique de "l'emulateur ne demarre plus") et reapplique
    les reglages de fluidite a chaque lancement.

    Le bruit de la console de l'emulateur (Ignore IPv6 address, UpdateLayeredWindow,
    adb protocol fault) part dans un fichier de log au lieu de polluer l'ecran :
        %TEMP%\emulateur-sunday.log

    Pas besoin des droits admin.

    Usage, depuis la racine de sunday_tracker :
        .\lancer-emulateur.ps1
        .\lancer-emulateur.ps1 -ColdBoot     # force un demarrage a froid
        .\lancer-emulateur.ps1 -Memoire 3072 # plus de RAM (invalide le snapshot -> 1 boot a froid)
        .\lancer-emulateur.ps1 -Force        # passe outre le garde-fou de RAM hote

    Si PowerShell refuse de l'executer (politique d'execution) :
        powershell -ExecutionPolicy Bypass -File .\lancer-emulateur.ps1
#>

[CmdletBinding()]
param(
    [string]$Avd = 'Pixel_4_API_33_Android_13_OK',
    [switch]$ColdBoot,
    [int]$Memoire = 0,
    [switch]$Force
)

$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$emu = "$sdk\emulator\emulator.exe"
$adb = "$sdk\platform-tools\adb.exe"
$log = "$env:TEMP\emulateur-sunday.log"
$logErr = "$env:TEMP\emulateur-sunday.err.log"

if (-not (Test-Path $emu)) { Write-Host "emulator.exe introuvable dans $sdk" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "=== Nettoyage des instances precedentes ===" -ForegroundColor Cyan
$zombies = Get-Process emulator, qemu-system-x86_64 -ErrorAction SilentlyContinue
if ($zombies) {
    Write-Host "  $($zombies.Count) processus residuel(s) trouve(s), arret..." -ForegroundColor Yellow
    & $adb emu kill | Out-Null
    Start-Sleep -Seconds 3
    Stop-Process -Name emulator, qemu-system-x86_64 -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
} else {
    Write-Host "  aucun processus residuel" -ForegroundColor Green
}

# Les verrous orphelins empechent l'AVD de redemarrer et sont la cause la plus
# frequente d'un emulateur qui refuse de se lancer sans message clair.
$avdDir = "$env:USERPROFILE\.android\avd"
Get-ChildItem $avdDir -Recurse -Filter '*.lock' -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; Write-Host "  verrou supprime : $($_.Name)" -ForegroundColor Yellow } catch {}
}

# Demarrer le serveur adb MAINTENANT, pas pendant l'attente de boot : un serveur
# qui se lance en meme temps que l'emulateur produit les "adb protocol fault".
& $adb start-server 2>$null | Out-Null

Write-Host ""
Write-Host "=== Memoire disponible ===" -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem
$libre = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
Write-Host "  RAM libre : $libre Go / $total Go"

# Sous ~2,5 Go libres, l'emulateur demarre mais SystemUI se fait etrangler par le
# swap : c'est exactement le "System UI isn't responding" au bout de 50 s de boot.
# On bloque au lieu d'avertir, sinon on perd 5 min pour rien.
if ($libre -lt 2.5 -and -not $Force) {
    Write-Host ""
    Write-Host "  STOP : moins de 2,5 Go libres." -ForegroundColor Red
    Write-Host "  L'emulateur va booter puis afficher 'System UI isn't responding'." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Les plus gros consommateurs a fermer :" -ForegroundColor Yellow
    Get-Process | Where-Object { $_.Name -in 'chrome', 'msedge', 'firefox', 'Code', 'studio64', 'Teams', 'ms-teams', 'Outlook', 'slack' } |
        Group-Object Name |
        ForEach-Object { [pscustomobject]@{ Mo = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 0); Processus = $_.Name; Nb = $_.Count } } |
        Sort-Object Mo -Descending | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "  Relancer avec -Force pour tenter quand meme." -ForegroundColor Yellow
    exit 1
}
if ($libre -lt 2.5) { Write-Host "  -Force : on continue malgre la pression memoire." -ForegroundColor Yellow }

Write-Host ""
Write-Host "=== Lancement de $Avd ===" -ForegroundColor Cyan
$emuArgs = @(
    '-avd', $Avd
    '-no-boot-anim'                      # rien a afficher pendant le boot = CPU rendu au systeme
    '-no-audio'                          # aucun son utile ici, un thread audio en moins
    '-dns-server', '8.8.8.8,1.1.1.1'     # coupe l'enumeration des interfaces hote = fin du spam "Ignore IPv6 address"
    '-netdelay', 'none'
    '-netspeed', 'full'
)
if ($ColdBoot) { $emuArgs += '-no-snapshot-load'; Write-Host "  mode cold boot" -ForegroundColor Yellow }
if ($Memoire -gt 0) { $emuArgs += @('-memory', "$Memoire"); Write-Host "  RAM AVD forcee a $Memoire Mo (1er boot a froid, le snapshot ne correspond plus)" -ForegroundColor Yellow }

Remove-Item $log, $logErr -Force -ErrorAction SilentlyContinue
# Fenetre cachee + sorties redirigees : c'est cette console qui crachait
# "Ignore IPv6 address", "UpdateLayeredWindow" et les fautes adb. La fenetre du
# telephone, elle, est creee par l'emulateur lui-meme et reste visible.
Start-Process -FilePath $emu -ArgumentList $emuArgs -WindowStyle Hidden `
    -RedirectStandardOutput $log -RedirectStandardError $logErr

Write-Host "  attente du demarrage complet..." -NoNewline
$deadline = (Get-Date).AddMinutes(7)
$serial = $null

# Etape 1 : attendre que le peripherique passe en etat 'device'.
# Interroger 'adb shell' avant ce moment est precisement ce qui declenche
# "adb protocol fault (couldn't read status)". 'adb devices' est inoffensif.
$graceJusqua = (Get-Date).AddSeconds(30)   # emulator.exe ne lance qemu qu'apres quelques secondes
while ((Get-Date) -lt $deadline) {
    $ligne = (& $adb devices) | Where-Object { $_ -match '^(emulator-\d+)\s+device$' }
    if ($ligne) { $serial = $Matches[1]; break }
    if ((Get-Date) -gt $graceJusqua -and -not (Get-Process emulator, qemu-system-x86_64 -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "  l'emulateur s'est arrete tout seul. Voir $log" -ForegroundColor Red
        exit 1
    }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 4
}

# Etape 2 : le peripherique repond, mais Android n'a pas fini de booter.
$booted = $false
while ($serial -and (Get-Date) -lt $deadline) {
    if ((& $adb -s $serial shell getprop sys.boot_completed) -match '1') { $booted = $true; break }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 4
}
Write-Host ""

if (-not $booted) {
    Write-Host "  TIMEOUT apres 7 min." -ForegroundColor Red
    Write-Host "  Relance avec -ColdBoot. Log : $log" -ForegroundColor Yellow
    Read-Host "Appuyer sur Entree pour fermer"
    exit 1
}

Write-Host "  demarre ($serial)." -ForegroundColor Green

# boot_completed=1 arrive AVANT que SystemUI et Play Services aient fini de se
# reveiller. Marteler adb pile a cet instant, sur un hote deja charge, c'est ce
# qui fait basculer SystemUI en ANR. On laisse passer la bourrasque.
Write-Host "  stabilisation" -NoNewline
1..5 | ForEach-Object { Write-Host "." -NoNewline; Start-Sleep -Seconds 3 }
Write-Host ""

# Les animations sont le principal facteur de lenteur *ressentie* de l'UI.
# Ce reglage vit dans userdata : un wipe data le remet a 1, d'ou la reapplication.
Write-Host ""
Write-Host "=== Reglages de fluidite ===" -ForegroundColor Cyan
$reglages = @(
    'settings put global window_animation_scale 0'
    'settings put global transition_animation_scale 0'
    'settings put global animator_duration_scale 0'
    'settings put global auto_update_apps 0'          # coupe les mises a jour Play Store en tache de fond
    'settings put system screen_off_timeout 1800000'  # 30 min, fin du "Increasing screen off timeout"
)
foreach ($r in $reglages) { & $adb -s $serial shell $r | Out-Null }
Write-Host "  animations desactivees, auto-update Play Store coupe, veille a 30 min" -ForegroundColor Green

Write-Host ""
Write-Host "=== Etat ===" -ForegroundColor Cyan
Write-Host "  resolution : $((& $adb -s $serial shell wm size) -replace 'Physical size:\s*','')"
Write-Host "  densite    : $((& $adb -s $serial shell wm density) -replace 'Physical density:\s*','') dpi"
$q = Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue
if ($q) { Write-Host "  RAM emulateur : $([math]::Round($q.WorkingSet64/1MB,0)) Mo" }
Write-Host "  log emulateur : $log" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Pret. Tu peux lancer 'flutter run' depuis VS Code." -ForegroundColor Green
Write-Host ""
