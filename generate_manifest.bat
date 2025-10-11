@echo off
setlocal enabledelayedexpansion

set "OUTPUT_FILE=manifest.json"

rem Elimina il file di output se esiste
if exist "%OUTPUT_FILE%" del "%OUTPUT_FILE%"

echo { > "%OUTPUT_FILE%"
echo   "files": [ >> "%OUTPUT_FILE%"

set "FIRST=1"

rem Utilizza git ls-files per ottenere solo i file tracciati (escludendo gitignored)
for /f "delims=" %%F in ('git ls-files') do (
    if exist "%%F" (
        set "FILEPATH=%%F"
        
        rem Converti il percorso per l'output JSON (backslash -> forward slash)
        set "JSONPATH=!FILEPATH:\=/!"
        
        rem Ottieni la dimensione del file
        for %%A in ("%%F") do set "FILESIZE=%%~zA"
        
        rem Calcola SHA256
        set "HASH="
        for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "%%F" SHA256 2^>nul') do (
            if not defined HASH (
                set "HASH=%%H"
                set "HASH=!HASH: =!"
            )
        )
        
        rem Aggiungi virgola se non è il primo elemento
        if !FIRST! equ 0 (
            echo     ^}, >> "%OUTPUT_FILE%"
        )
        set "FIRST=0"
        
        rem Scrivi l'entry JSON
        echo     { >> "%OUTPUT_FILE%"
        echo       "path": "!JSONPATH!", >> "%OUTPUT_FILE%"
        echo       "size": !FILESIZE!, >> "%OUTPUT_FILE%"
        echo       "sha256": "!HASH!" >> "%OUTPUT_FILE%"
    )
)

rem Chiudi l'ultimo elemento e l'array
echo     } >> "%OUTPUT_FILE%"
echo   ], >> "%OUTPUT_FILE%"
echo   "generated": "%DATE% %TIME%" >> "%OUTPUT_FILE%"
echo } >> "%OUTPUT_FILE%"

echo.
echo Manifest generato in %OUTPUT_FILE%
echo.
pause
