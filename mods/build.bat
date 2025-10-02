@echo off
rem ---------------------------------------------------
rem Script: build.bat
rem Descrizione: Crea due file ZIP:
rem   - client.zip: comprime tutti i file .jar della directory corrente.
rem   - server.zip: comprime tutti i file .jar che NON contengono la stringa "[client]" nel nome.
rem ---------------------------------------------------

rem Controlla se esistono file .jar nella directory corrente
dir /b *.jar >nul 2>&1
if errorlevel 1 (
    echo Nessun file .jar trovato nella directory corrente.
    goto end
)

echo Creazione di client.zip con tutti i file .jar...
rem Usa PowerShell per comprimere tutti i file .jar in client.zip
powershell -command "Compress-Archive -Path '*.jar' -DestinationPath './build/latest/client.zip' -Force"
if errorlevel 1 (
    echo Errore nella creazione di client.zip.
    goto end
)
echo client.zip creato con successo.
echo.

echo Creazione di server.zip con i file .jar che non contengono "[client]" nel nome...
rem Abilita delayed expansion per gestire le variabili in loop
setlocal enabledelayedexpansion
set "fileList="

rem Cicla su tutti i file .jar presenti
for %%F in (*.jar) do (
    rem Verifica se il nome contiene la stringa [client] (ricerca case-insensitive)
    echo %%F | findstr /I "\[client\]" >nul
    if errorlevel 1 (
        rem Il file non contiene "[client]", aggiungilo alla lista
        rem Se la variabile fileList è vuota, inizializza con il nome
        if "!fileList!"=="" (
            set "fileList=%%F"
        ) else (
            set "fileList=!fileList!','%%F"
        )
    )
)

rem Controlla se esistono file senza "[client]"
if "!fileList!"=="" (
    echo Nessun file .jar privo di "[client]" trovato. server.zip non verrà creato.
    goto end_local
)

rem Poiché il comando Compress-Archive richiede una lista di file separata da virgole,
rem costruiamo la stringa per il parametro -LiteralPath.
set "psCommand=Compress-Archive -LiteralPath '%fileList%' -DestinationPath './build/latest/server.zip' -Force"
powershell -command "%psCommand%"
if errorlevel 1 (
    echo Errore nella creazione di server.zip.
    goto end_local
)
echo server.zip creato con successo.

:end_local
endlocal

:end
echo Operazione completata.
pause
