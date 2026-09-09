```powershell
# Pobranie listy procesów i filtrowanie
Get-Process | Where-Object {$_.CPU -gt 100}
```


## Krok 1 — połączenie zdalne

$cred = Get-Credential            # konto z prawami admina lokalnego na stacji
$comp = 'NAZWA-STACJI'            # nazwa NetBIOS / FQDN / IP

Test-WSMan -ComputerName $comp    # sprawdzenie, czy WinRM odpowiada

Jeśli Test-WSMan zwróci błąd — WinRM na stacji nie jest włączony. W domenie włącz go GPO (Computer Configuration > Policies > Administrative Templates > Windows Remote Management (WinRM) > WinRM Service > Allow remote server management).

## Krok 2 — uruchomienie skryptu na stacji

Wariant A (najprościej, domyślne parametry — czysta instalacja, lang=pl). Pobieranie i instalacja wykonują się na stacji:

powershell
Invoke-Command -ComputerName $comp -Credential $cred -FilePath 'C:\Skrypty\Install-FirefoxESR.ps1'

Wariant B (pełna kontrola parametrów, np. -Force albo -Proxy):

powershell
$s = New-PSSession -ComputerName $comp -Credential $cred
Copy-Item .\Install-FirefoxESR.ps1 -Destination 'C:\Windows\Temp\' -ToSession $s
Invoke-Command -Session $s -ScriptBlock {
    & 'C:\Windows\Temp\Install-FirefoxESR.ps1' -Force -Lang pl
}
Remove-PSSession $s

Wiele stacji naraz: -ComputerName 'PC01','PC02','PC03' — Invoke-Command odpali równolegle.

Co robi skrypt (mapowanie na Twoje punkty)
Twój punkt	Realizacja w skrypcie
2.1 sprawdź wersję	Get-InstalledFirefox — rejestr HKLM x64/x86 + HKCU
2.2 odinstaluj	helper.exe /S + polling rejestru (Wait-Removed) do faktycznego usunięcia; pomijane przez -KeepExisting
2.3 aktualna wersja ESR	product-details.mozilla.org/1.0/firefox_versions.json → pole FIREFOX_ESR
2.4 pobierz + zainstaluj	download.mozilla.org/?product=firefox-esr-latest-ssl → /S
2.5 weryfikacja	odczyt ProductVersion z firefox.exe + porównanie

Log: C:\ProgramData\FirefoxESR-Install.log na stacji. Kody wyjścia: 0 OK / już aktualny, 1 błąd, 2 wersja się nie zgadza.

Dwie uwagi
Stacja musi mieć dostęp do internetu (do download.mozilla.org i product-details.mozilla.org). Jeśli macie proxy — dodaj -Proxy http://proxy...:8080. Jeśli stacje w ogóle nie wychodzą w świat, trzeba odwrócić logikę: pobrać instalator raz na Twoim komputerze, skopiować -ToSession i uruchomić lokalnie — mogę dać taki wariant offline.
-Force przez Wariant A nie zadziała (Invoke-Command -FilePath przekazuje argumenty tylko pozycyjnie i nie ogarnia switchy) — do przełączników użyj Wariantu B.

Problemy:

Najczęstsza przyczyna: plik pobrany przez przeglądarkę ma Mark of the Web (Zone.Identifier = internet), a przy RemoteSigned pobrane skrypty muszą być podpisane. Zdejmij znacznik:

powershell
Unblock-File -Path 'C:\Dane_Uzytkownika\Install-FirefoxESR.ps1'

Get-ExecutionPolicy -List

Diagnoza z równoległej sesji

Otwórz nowe okno PowerShell na swojej stacji:

powershell
$comp = 'NB-4TT4453'
$cred = Get-Credential
Invoke-Command -ComputerName $comp -Credential $cred -ScriptBlock {
    "--- proces instalatora (CPU / czas startu) ---"
    Get-Process | Where-Object { $_.Name -match 'firefox|setup' } |
        Select-Object Name, Id, CPU, StartTime,
            @{n='WS_MB';e={[int]($_.WorkingSet64/1MB)}} | Format-Table -Auto
    "--- czy jakies okno czeka na klik (klucz!) ---"
    Get-Process | Where-Object MainWindowTitle | Select-Object Name, MainWindowTitle
    "--- stan katalogu docelowego ---"
    if (Test-Path 'C:\Program Files\Mozilla Firefox') {
        $n = (Get-ChildItem 'C:\Program Files\Mozilla Firefox' -Recurse -EA SilentlyContinue).Count
        "Plikow: $n  |  firefox.exe: $([bool](Test-Path 'C:\Program Files\Mozilla Firefox\firefox.exe'))"
    } else { "Katalog docelowy jeszcze nie istnieje" }
}

Odpal to dwa razy z odstępem ~15 s i porównaj:

CPU rośnie i przybywa plików → instaluje, po prostu wolno (AV/EDR skanuje 70 MB). Poczekaj jeszcze.
CPU stoi, plików nie przybywa, brak firefox.exe, proces wisi → zawieszony. Jeśli w drugiej sekcji pojawi się jakikolwiek MainWindowTitle instalatora — masz potwierdzenie ukrytego okna.
Jeśli wisi — ubij i wróć
powershell
Invoke-Command -ComputerName $comp -Credential $cred -ScriptBlock {
    Get-Process | Where-Object { $_.Name -match 'firefox|setup' } | Stop-Process -Force
}

Po ubiciu dziecka Start-Process -Wait w pierwszym oknie od razu wróci (albo zamknij tamto okno).


