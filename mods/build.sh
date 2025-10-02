#!/bin/bash
# Questo script zippa tutti i file .jar presenti nella cartella corrente
# in un archivio chiamato "client.zip", e poi zippa tutti i file .jar che
# non contengono la stringa "[client]" nel nome in un archivio chiamato "server.zip".

# Controlla se ci sono file .jar nella directory
jar_files=( *.jar )
if [ "${jar_files[0]}" = "*.jar" ]; then
  echo "Nessun file .jar trovato nella directory corrente."
  exit 1
fi

echo "Creazione di client.zip con tutti i file .jar..."
# Crea client.zip includendo tutti i file .jar presenti nella directory
zip -q ./build/latest/client.zip *.jar
if [ $? -eq 0 ]; then
  echo "client.zip creato con successo."
else
  echo "Si è verificato un errore nella creazione di client.zip."
  exit 1
fi

echo "Creazione di server.zip con i file .jar che non contengono '[client]' nel nome..."
# Usa find per selezionare i file .jar che non contengono la stringa "[client]" nel nome.
# Il pattern "\[client\]" protegge le parentesi perché altrimenti verrebbero interpretate come un'espressione regolare.
files_to_zip=$(find . -maxdepth 1 -type f -name "*.jar" ! -name "*\[client\]*")

# Verifica se esistono file da zippare per server.zip
if [ -z "$files_to_zip" ]; then
  echo "Nessun file .jar senza '[client]' trovato. server.zip non verrà creato."
else
  # Creazione dello zip server.zip
  # Poiché find restituisce i file con il prefisso "./", li passiamo a zip.
  zip -q ./build/latest/server.zip $files_to_zip
  if [ $? -eq 0 ]; then
    echo "server.zip creato con successo."
  else
    echo "Si è verificato un errore nella creazione di server.zip."
    exit 1
  fi
fi

echo "Operazione completata."
