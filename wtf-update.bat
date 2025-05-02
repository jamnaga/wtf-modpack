@echo off
REM --------------------------------------------
REM 1) Controllo se git e installato
REM --------------------------------------------
where git >nul 2>&1
if errorlevel 1 (
    echo Git non trovato. Avvio installazione con winget...
    winget install --id Git.Git -e --source winget
    if errorlevel 1 (
        echo Errore durante l’installazione di Git. Esco.
        exit /b 1
    )
) else (
    echo Git gia installato.
)

REM --------------------------------------------
REM 2) Sincronizzo la cartella corrente col repo
REM --------------------------------------------
if exist ".git" (
    echo E gia un repository git. Eseguo git pull...
    git -C . pull
) else (
    echo Non e un repo git: inizializzo e prelevo i file da origin/main...
    git init
    git remote add origin https://github.com/jamnaga/wtf-modpack
    git fetch origin
    git pull -f origin latest
    git checkout -f latest
)

echo.
echo Operazione completata.
pause
