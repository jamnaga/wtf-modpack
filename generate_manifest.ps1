# Script PowerShell per generare il manifest.json velocemente
$ErrorActionPreference = 'Stop'

$outputFile = "manifest.json"
$onceListFile = ".oncelist"
$ignorePatterns = @()

# Carica la lista dei file "once"
$onceList = @()
if (Test-Path $onceListFile) {
    $onceList = Get-Content $onceListFile | Where-Object { 
        $_ -notmatch '^\s*$' 
    } | ForEach-Object { $_.Trim() -replace '\\', '/' }
}

# Carica i pattern da .gitignore e .manifestignore
foreach ($ignoreFile in @('.gitignore', '.manifestignore')) {
    if (Test-Path $ignoreFile) {
        $patterns = Get-Content $ignoreFile | Where-Object { 
            $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' 
        }
        $ignorePatterns += $patterns
    }
}

# Converti i pattern gitignore in regex PowerShell
function Convert-GitIgnoreToRegex {
    param([string]$pattern)
    
    $pattern = $pattern.Trim()
    
    # Converti / in \
    $pattern = $pattern -replace '/', '\'
    
    # Rimuovi \ iniziale
    if ($pattern.StartsWith('\')) {
        $pattern = $pattern.Substring(1)
    }
    
    # Pattern per directory (termina con \)
    if ($pattern.EndsWith('\')) {
        $pattern = $pattern.TrimEnd('\')
        # Match all'inizio o dopo un \
        return "^$([regex]::Escape($pattern))\\|\\$([regex]::Escape($pattern))\\"
    }
    
    # Pattern con wildcard
    if ($pattern.Contains('*')) {
        $pattern = [regex]::Escape($pattern) -replace '\\\*\\\*', '.*' -replace '\\\*', '[^\\]*'
        return $pattern
    }
    
    # Match esatto
    return "^$([regex]::Escape($pattern))$"
}

# Converti tutti i pattern
$regexPatterns = $ignorePatterns | ForEach-Object { Convert-GitIgnoreToRegex $_ }

# Funzione per controllare se un file deve essere ignorato
function Test-ShouldIgnore {
    param([string]$relativePath)
    
    foreach ($pattern in $regexPatterns) {
        if ($relativePath -match $pattern) {
            return $true
        }
    }
    return $false
}

# Ottieni tutti i file
Write-Host "Scansione dei file..."
$files = Get-ChildItem -Path . -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $relativePath = $_.FullName.Substring((Get-Location).Path.Length + 1)
    
    # Salta i file temporanei e il manifest
    if ($_.Name -eq $outputFile -or $_.Name -eq 'temp_ignore_patterns.txt' -or $_.Name -eq 'temp_all_files.txt') {
        return $false
    }
    
    # Controlla se deve essere ignorato
    return -not (Test-ShouldIgnore $relativePath)
}

Write-Host "Generazione del manifest per $($files.Count) file..."

# Crea l'oggetto JSON
$manifestObj = @{
    files = @()
    generated = (Get-Date -Format "dd/MM/yyyy HH:mm:ss,ff")
}

# Processa ogni file
$fileCount = 0
foreach ($file in $files) {
    $fileCount++
    if ($fileCount % 100 -eq 0) {
        Write-Host "Processati $fileCount/$($files.Count) file..."
    }
    
    try {
        $relativePath = $file.FullName.Substring((Get-Location).Path.Length + 1) -replace '\\', '/'
        
        # Calcola SHA256 usando -LiteralPath per gestire caratteri speciali
        $hashObj = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop
        $hash = $hashObj.Hash.ToLower()
        
        # Determina se il file è nella lista "once"
        $isOnce = $onceList -contains $relativePath
        
        $manifestObj.files += @{
            path = $relativePath
            size = $file.Length
            sha256 = $hash
            once = $isOnce
        }
    }
    catch {
        Write-Warning "Impossibile processare il file: $($file.FullName) - $($_.Exception.Message)"
    }
}

# Scrivi il file JSON
$manifestObj | ConvertTo-Json -Depth 10 | Set-Content -Path $outputFile -Encoding UTF8

Write-Host ""
Write-Host "Manifest generato in $outputFile"
Write-Host "Totale file inclusi: $($files.Count)"
Write-Host ""
