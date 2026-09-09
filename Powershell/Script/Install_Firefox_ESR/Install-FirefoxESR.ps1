#Requires -Version 5.1
<#
.SYNOPSIS
    Czysta instalacja najnowszego Mozilla Firefox ESR na Windows 11 (wariant MSI).

.DESCRIPTION
    1. Wykrywa wszystkie zainstalowane wersje Firefox (HKLM x64/x86 + HKCU).
    2. Pobiera numer aktualnej wersji ESR z oficjalnego API Mozilli.
    3. Jesli aktualna wersja ESR jest juz zainstalowana -> konczy (chyba ze -Force).
    4. Cicho odinstalowuje WSZYSTKIE wersje (EXE: helper.exe /S, MSI: msiexec /x).
    5. Pobiera i cicho instaluje najnowszy instalator ESR w formacie MSI.
    6. Weryfikuje instalacje po pliku firefox.exe.

    UWAGA: uzyto MSI zamiast EXE, poniewaz instalator EXE (/S) po instalacji
    URUCHAMIA Firefox jako proces potomny, przez co Start-Process -Wait wisi
    w nieskonczonosc w sesji zdalnej. MSI nie startuje przegladarki, zwraca
    deterministyczny ExitCode i tworzy pelny log.

.PARAMETER Lang
    Kod jezyka instalatora (domyslnie pl).

.PARAMETER Force
    Instaluj ponownie, nawet jesli aktualny ESR jest juz zainstalowany.

.PARAMETER KeepExisting
    Pomin deinstalacje istniejacych wersji (instalacja "na wierzch").

.PARAMETER Proxy
    Opcjonalny serwer proxy dla pobierania (np. http://proxy.us.edu.pl:8080).

.EXAMPLE
    .\Install-FirefoxESR.ps1
    .\Install-FirefoxESR.ps1 -Force -Lang pl
#>

[CmdletBinding()]
param(
    [string]$Lang        = 'pl',
    [switch]$Force,
    [switch]$KeepExisting,
    [string]$Proxy,
    [string]$LogPath     = "$env:ProgramData\FirefoxESR-Install.log"
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ----------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level='INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Get-InstalledFirefox {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Mozilla Firefox*' } |
        Select-Object DisplayName, DisplayVersion, UninstallString
}

function Wait-Removed {
    param([string]$DisplayName, [int]$TimeoutSec = 90)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (-not (Get-InstalledFirefox | Where-Object DisplayName -eq $DisplayName)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}
# ----------------------------------------------------------------------

Write-Log "=== START: czysta instalacja Firefox ESR (lang=$Lang) na $env:COMPUTERNAME ==="

# --- 1. Wykrycie zainstalowanych wersji ------------------------------
$installed = @(Get-InstalledFirefox)
if ($installed.Count) {
    Write-Log "Wykryto zainstalowane wersje:"
    $installed | ForEach-Object { Write-Log ("  - {0} [{1}]" -f $_.DisplayName, $_.DisplayVersion) }
} else {
    Write-Log "Firefox nie jest obecnie zainstalowany."
}

# --- 2. Aktualna wersja ESR z API Mozilli ----------------------------
$irmArgs = @{ Uri = 'https://product-details.mozilla.org/1.0/firefox_versions.json'; UseBasicParsing = $true }
if ($Proxy) { $irmArgs.Proxy = $Proxy; $irmArgs.ProxyUseDefaultCredentials = $true }
$latestEsr      = (Invoke-RestMethod @irmArgs).FIREFOX_ESR      # np. "140.15.0esr"
$latestEsrClean = $latestEsr -replace 'esr$',''                 # np. "140.15.0"
if (-not $latestEsrClean) { Write-Log "Nie udalo sie pobrac numeru wersji ESR." 'ERROR'; exit 1 }
Write-Log "Najnowsza wersja ESR wg Mozilla: $latestEsrClean"

# --- 3. Czy juz aktualny? --------------------------------------------
if (-not $Force -and ($installed | Where-Object DisplayVersion -eq $latestEsrClean)) {
    Write-Log "Firefox ESR $latestEsrClean jest juz zainstalowany. Uzyj -Force aby wymusic. Koniec." 'OK'
    exit 0
}

# --- 4. Deinstalacja istniejacych wersji (EXE + MSI) -----------------
if ($installed.Count -and -not $KeepExisting) {
    Write-Log "Zamykam dzialajace procesy firefox.exe..."
    Get-Process -Name firefox -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2

    foreach ($fx in $installed) {
        try {
            $us = $fx.UninstallString
            if ($us -match 'helper\.exe') {
                # instalacja typu EXE (NSIS) -> cicha deinstalacja przez helper.exe /S
                $helper = $null
                if ($us -match '"?(.*helper\.exe)"?') { $helper = $Matches[1] }
                if ($helper -and (Test-Path $helper)) {
                    Write-Log "Odinstalowuje (EXE): $($fx.DisplayName)"
                    Start-Process -FilePath $helper -ArgumentList '/S' -Wait
                } else {
                    Write-Log "Brak dzialajacego helper.exe dla: $($fx.DisplayName)" 'WARN'; continue
                }
            }
            elseif ($us -match '\{[0-9A-Fa-f\-]{36}\}') {
                # instalacja typu MSI -> cicha deinstalacja przez msiexec /x{GUID}
                $guid = $Matches[0]
                Write-Log "Odinstalowuje (MSI): $($fx.DisplayName)  $guid"
                Start-Process msiexec.exe -ArgumentList "/x$guid /qn /norestart" -Wait
            }
            else {
                Write-Log "Nieznany typ uninstallera dla: $($fx.DisplayName)" 'WARN'; continue
            }

            if (Wait-Removed -DisplayName $fx.DisplayName) { Write-Log "  usunieto." }
            else { Write-Log "  timeout deinstalacji: $($fx.DisplayName)" 'WARN' }
        } catch {
            Write-Log "Blad deinstalacji $($fx.DisplayName): $_" 'ERROR'
        }
    }

    $left = @(Get-InstalledFirefox)
    if ($left.Count) { $left | ForEach-Object { Write-Log "Pozostalo w rejestrze: $($_.DisplayName)" 'WARN' } }
    else { Write-Log "Wszystkie wersje usuniete." }
}

# --- 5. Pobranie i cicha instalacja (MSI) ----------------------------
$installer   = Join-Path $env:TEMP "firefox-esr-$latestEsrClean-$Lang.msi"
$downloadUrl = "https://download.mozilla.org/?product=firefox-esr-msi-latest-ssl&os=win64&lang=$Lang"

$iwrArgs = @{ Uri = $downloadUrl; OutFile = $installer; UseBasicParsing = $true }
if ($Proxy) { $iwrArgs.Proxy = $Proxy; $iwrArgs.ProxyUseDefaultCredentials = $true }

Write-Log "Pobieram instalator MSI: $downloadUrl"
Invoke-WebRequest @iwrArgs
$sizeMB = [math]::Round((Get-Item $installer).Length / 1MB, 1)
if ($sizeMB -lt 40) { Write-Log "Pobrany plik podejrzanie maly ($sizeMB MB) - przerywam." 'ERROR'; exit 1 }
Write-Log "Pobrano: $installer ($sizeMB MB)"

$msiLog = "$env:ProgramData\FirefoxESR-msi.log"
Write-Log "Instaluje cicho (msiexec /qn)..."
$proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
    '/i', "`"$installer`"", '/qn', '/norestart', '/l*v', "`"$msiLog`""
)
Write-Log "msiexec zakonczyl sie kodem: $($proc.ExitCode) (0 lub 3010 = OK)"
if ($proc.ExitCode -notin 0,3010) {
    Write-Log "Instalacja MSI nieudana. Szczegoly w logu: $msiLog" 'ERROR'
    exit 1
}

# --- 6. Weryfikacja --------------------------------------------------
Start-Sleep -Seconds 3
$exe = 'C:\Program Files\Mozilla Firefox\firefox.exe'
if (Test-Path $exe) {
    $ver = (Get-Item $exe).VersionInfo.ProductVersion
    if ($ver -like "$latestEsrClean*") {
        Write-Log "WERYFIKACJA OK: Firefox ESR $ver zainstalowany poprawnie." 'OK'
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        Write-Log "=== KONIEC ==="
        exit 0
    } else {
        Write-Log "UWAGA: zainstalowana wersja $ver != oczekiwana $latestEsrClean" 'WARN'
        exit 2
    }
} else {
    Write-Log "BLAD: firefox.exe nie znaleziony po instalacji." 'ERROR'
    exit 1
}
