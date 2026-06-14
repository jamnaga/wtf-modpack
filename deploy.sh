#!/usr/bin/env bash
# deploy.sh — GDC Modpack deploy tool con TUI
# Integra generate_manifest.sh e permette di creare package 7z splittati
# a partire da una lista di file.

set -uo pipefail

# Locale POSIX per numeri: evita che printf/bc producano numeri con la virgola
# (es. it_IT) che poi rompono il parsing successivo.
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Path configurabili: il default punta al modpack, ma possono essere
# sovrascritte da variabili d'ambiente (utile per test in sandbox).
PACKAGES_DIR="${DEPLOY_PACKAGES_DIR:-$SCRIPT_DIR/packages}"
GENERATE_MANIFEST="${DEPLOY_GENERATE_MANIFEST:-$SCRIPT_DIR/generate_manifest.sh}"
MANIFESTIGNORE="$SCRIPT_DIR/.manifestignore"
DH_ENGINE="$SCRIPT_DIR/tools/dh_update_package.py"
DH_SERVER_DATA="${DEPLOY_DH_SERVER_DATA:-$SCRIPT_DIR/Distant_Horizons_server_data/Minecraft+Server}"

# ───── Stato globale wizard (no array associativi: bash 3.2 compat) ─────
PKG_NAME=""
PKG_DESCRIPTION=""
PKG_VERSION=""
PKG_ACTION=""
PKG_EXTRACT_TO=""
PKG_REQUIRED=""
PKG_OVERWRITE=""
PKG_PROGRESS_MESSAGE=""
PKG_SPLIT_SIZE=""
PKG_FILES=()              # path sorgente assoluti (o relativi a SCRIPT_DIR)
PKG_FILES_INSIDE_ROOT=()  # parallelo a PKG_FILES: "1" se dentro modpack, "" altrimenti

# ───── ANSI / TUI helpers ─────
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_INV=$'\033[7m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_CYAN=""
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_INV=""
fi

ui_clear()  { printf '\033[2J\033[H'; }
ui_hide_cursor() { printf '\033[?25l'; }
ui_show_cursor() { printf '\033[?25h'; }

cleanup() {
  ui_show_cursor
  printf '%s' "$C_RESET"
}
trap cleanup EXIT INT TERM

term_cols() {
  local c
  c=$(tput cols 2>/dev/null || echo 80)
  [[ -z "$c" || "$c" -lt 40 ]] && c=80
  echo "$c"
}

ui_header() {
  local title="$1"
  local cols; cols=$(term_cols)
  local line=""
  local i=0
  while [[ $i -lt $cols ]]; do line+="─"; i=$((i+1)); done
  printf '%s%s%s\n' "$C_CYAN" "$line" "$C_RESET"
  printf '%s%s GDC Modpack Deploy %s %s%s\n' "$C_BOLD$C_CYAN" "│" "•" "$title$C_RESET"
  printf '%s%s%s\n\n' "$C_CYAN" "$line" "$C_RESET"
}

ui_footer() {
  local hint="${1:-}"
  printf '\n%s%s%s\n' "$C_DIM" "$hint" "$C_RESET"
}

# Legge un tasto: gestisce sequenze ESC per le frecce.
# Bash 3.2 su macOS gestisce male i timeout subsecond → leggiamo byte-per-byte
# con timeout breve per intercettare l'intera sequenza CSI / SS3.
read_key() {
  local key="" c
  IFS= read -rsn1 c 2>/dev/null || return 1
  key="$c"
  if [[ "$c" == $'\033' ]]; then
    # Cattura il secondo byte: '[' (CSI) oppure 'O' (SS3 = application mode)
    if IFS= read -rsn1 -t 1 c 2>/dev/null; then
      key+="$c"
      if [[ "$c" == "[" || "$c" == "O" ]]; then
        # Cattura il byte finale (A/B/C/D per le frecce)
        if IFS= read -rsn1 -t 1 c 2>/dev/null; then
          key+="$c"
        fi
      fi
    fi
  fi
  printf '%s' "$key"
}

# Menu interattivo. Uso: ui_menu "Titolo" "opzione1" "opzione2" ...
# Imposta UI_MENU_INDEX con l'indice scelto (0-based), o 255 se annullato.
UI_MENU_INDEX=0
ui_menu() {
  local title="$1"; shift
  local options=("$@")
  local n=${#options[@]}
  local idx=0
  local key i prefix line

  ui_hide_cursor
  while true; do
    ui_clear
    ui_header "$title"
    i=0
    while [[ $i -lt $n ]]; do
      if [[ $i -eq $idx ]]; then
        prefix="${C_GREEN}▶ ${C_INV}"
        line="${prefix} ${options[$i]} ${C_RESET}"
      else
        prefix="  "
        line="${prefix} ${options[$i]}"
      fi
      printf '%s\n' "$line"
      i=$((i+1))
    done
    ui_footer "↑↓ per spostarti  •  Invio per selezionare  •  q per annullare"

    key=$(read_key)
    case "$key" in
      $'\033[A'|$'\033OA'|k) idx=$(( (idx - 1 + n) % n )) ;;
      $'\033[B'|$'\033OB'|j) idx=$(( (idx + 1) % n )) ;;
      ""|$'\n')              UI_MENU_INDEX=$idx; ui_show_cursor; return 0 ;;
      q|Q)                   UI_MENU_INDEX=255; ui_show_cursor; return 1 ;;
    esac
  done
}

# Input testuale con default. Uso: ui_input "etichetta" "default"
# Imposta UI_INPUT_VALUE.
UI_INPUT_VALUE=""
ui_input() {
  local label="$1"
  local default="${2:-}"
  ui_show_cursor
  if [[ -n "$default" ]]; then
    printf '%s%s%s [%s%s%s]: ' "$C_BOLD" "$label" "$C_RESET" "$C_DIM" "$default" "$C_RESET"
  else
    printf '%s%s%s: ' "$C_BOLD" "$label" "$C_RESET"
  fi
  IFS= read -r UI_INPUT_VALUE
  if [[ -z "$UI_INPUT_VALUE" && -n "$default" ]]; then
    UI_INPUT_VALUE="$default"
  fi
}

ui_yesno() {
  local prompt="$1"
  local default="${2:-n}"
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  ui_show_cursor
  printf '%s%s%s %s: ' "$C_BOLD" "$prompt" "$C_RESET" "$hint"
  local ans
  IFS= read -r ans
  ans="$(printf '%s' "$ans" | tr 'A-Z' 'a-z')"
  [[ -z "$ans" ]] && ans="$default"
  [[ "$ans" == "y" || "$ans" == "yes" || "$ans" == "s" || "$ans" == "si" ]]
}

ui_pause() {
  ui_show_cursor
  printf '\n%s%s%s' "$C_DIM" "Premi Invio per continuare..." "$C_RESET"
  IFS= read -r _
}

ui_info()  { printf '%s[i]%s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
ui_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
ui_error() { printf '%s[x]%s %s\n' "$C_RED"    "$C_RESET" "$1"; }
ui_ok()    { printf '%s[✓]%s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }

# ───── Utility ─────

# Restituisce il binario 7z disponibile (7z, 7zz) o "" se assente.
detect_7z() {
  if command -v 7z   >/dev/null 2>&1; then echo "7z";  return; fi
  if command -v 7zz  >/dev/null 2>&1; then echo "7zz"; return; fi
  echo ""
}

# Sanitizza un nome per uso come directory/filename: lascia [A-Za-z0-9._-],
# sostituisce gli spazi e tutto il resto con underscore, collassa i ripetuti.
sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed -E 's/_+/_/g; s/^_|_$//g'
}

# Codifica una stringa per JSON (gestisce backslash, quote, newline, tab).
json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' <<<"$1"
}

# Stampa true/false JSON da una stringa "y"/"n"/"true"/"false"/vuoto.
bool_json() {
  local v
  v="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$v" in
    y|yes|true|1|s|si) echo "true" ;;
    n|no|false|0)      echo "false" ;;
    *)                 echo "" ;;
  esac
}

# Verifica se un path è "dentro" l'albero del modpack che il manifest scansiona:
# cioè dentro SCRIPT_DIR e NON dentro packages/.
# Stampa "1" se dentro+a rischio duplicazione, "" altrimenti.
file_inside_manifest_tree() {
  local f="$1"
  local abs
  if [[ "$f" = /* ]]; then
    abs="$f"
  else
    abs="$SCRIPT_DIR/$f"
  fi
  case "$abs" in
    "$SCRIPT_DIR"/packages/*) echo "" ;;
    "$SCRIPT_DIR"/*)          echo "1" ;;
    *)                        echo "" ;;
  esac
}

human_size() {
  # awk fa floating point internamente e usa sempre il punto decimale,
  # immune al locale e senza dipendere da bc.
  awk -v b="${1:-0}" 'BEGIN {
    if      (b < 1024)       printf "%d B",    b
    else if (b < 1048576)    printf "%.1f KB", b/1024
    else if (b < 1073741824) printf "%.1f MB", b/1048576
    else                     printf "%.2f GB", b/1073741824
  }'
}

file_size_bytes() {
  # BSD stat (macOS) vs GNU stat
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null || echo 0
}

# ───── Azioni principali ─────

action_regenerate_manifest() {
  ui_clear
  ui_header "Rigenera manifest.json"
  if [[ ! -x "$GENERATE_MANIFEST" ]]; then
    if [[ -f "$GENERATE_MANIFEST" ]]; then
      ui_warn "generate_manifest.sh non eseguibile, lo rendo eseguibile."
      chmod +x "$GENERATE_MANIFEST"
    else
      ui_error "generate_manifest.sh non trovato in $SCRIPT_DIR"
      ui_pause
      return 1
    fi
  fi

  ui_info "Eseguo $GENERATE_MANIFEST..."
  echo
  if bash "$GENERATE_MANIFEST"; then
    echo
    ui_ok "Manifest rigenerato."
  else
    echo
    ui_error "Errore durante la generazione del manifest."
  fi
  ui_pause
}

action_list_packages() {
  ui_clear
  ui_header "Packages esistenti"
  if [[ ! -d "$PACKAGES_DIR" ]]; then
    ui_info "Nessuna cartella packages/ presente."
    ui_pause
    return 0
  fi

  local found=0
  local d
  for d in "$PACKAGES_DIR"/*/; do
    [[ -d "$d" ]] || continue
    found=1
    local name
    name="$(basename "$d")"
    printf '%s%s%s\n' "$C_BOLD" "$name" "$C_RESET"
    if [[ -f "$d/package.json" ]]; then
      python3 - "$d/package.json" <<'PY' || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print(f"   [errore lettura package.json: {e}]")
    sys.exit(0)
def line(k, v):
    if v is None: return
    print(f"   {k}: {v}")
line("description", cfg.get("description"))
line("version",     cfg.get("version"))
line("archiveType", cfg.get("archiveType"))
line("action",      cfg.get("action"))
line("extractTo",   cfg.get("extractTo"))
parts = cfg.get("parts") or []
if parts:
    print(f"   parts: {len(parts)}")
PY
    else
      ui_warn "   manca package.json"
    fi
    echo
  done

  [[ "$found" -eq 0 ]] && ui_info "Nessun package presente."
  ui_pause
}

action_delete_package() {
  ui_clear
  ui_header "Elimina package"
  if [[ ! -d "$PACKAGES_DIR" ]]; then
    ui_info "Nessuna cartella packages/."
    ui_pause
    return 0
  fi

  local pkgs=()
  local d
  for d in "$PACKAGES_DIR"/*/; do
    [[ -d "$d" ]] || continue
    pkgs+=("$(basename "$d")")
  done

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    ui_info "Nessun package da eliminare."
    ui_pause
    return 0
  fi

  pkgs+=("« Annulla »")
  ui_menu "Quale package eliminare?" "${pkgs[@]}" || return 0
  local idx=$UI_MENU_INDEX
  if [[ $idx -ge $((${#pkgs[@]} - 1)) ]]; then
    return 0
  fi

  local target="${pkgs[$idx]}"
  ui_clear
  ui_header "Elimina package"
  ui_warn "Sto per eliminare in modo PERMANENTE:"
  printf '  %s%s%s\n\n' "$C_RED" "$PACKAGES_DIR/$target" "$C_RESET"
  if ui_yesno "Confermi la cancellazione?" "n"; then
    rm -rf "$PACKAGES_DIR/$target"
    ui_ok "Package eliminato: $target"
  else
    ui_info "Operazione annullata."
  fi
  ui_pause
}

# ───── Wizard creazione package ─────

reset_pkg_state() {
  PKG_NAME=""
  PKG_DESCRIPTION=""
  PKG_VERSION="1.0.0"
  PKG_ACTION="extract"
  PKG_EXTRACT_TO=""
  PKG_REQUIRED="true"
  PKG_OVERWRITE="false"
  PKG_PROGRESS_MESSAGE=""
  PKG_SPLIT_SIZE="100m"
  PKG_FILES=()
  PKG_FILES_INSIDE_ROOT=()
}

wizard_show_files() {
  if [[ ${#PKG_FILES[@]} -eq 0 ]]; then
    printf '   %s(nessun file selezionato)%s\n' "$C_DIM" "$C_RESET"
    return
  fi
  local i=0
  local total_bytes=0
  local sz
  while [[ $i -lt ${#PKG_FILES[@]} ]]; do
    sz=$(file_size_bytes "${PKG_FILES[$i]}")
    total_bytes=$((total_bytes + sz))
    local warn=""
    [[ -n "${PKG_FILES_INSIDE_ROOT[$i]}" ]] && warn=" ${C_YELLOW}[dentro modpack: rischio duplicazione]${C_RESET}"
    printf '   %2d. %s  %s(%s)%s%s\n' $((i+1)) "${PKG_FILES[$i]}" "$C_DIM" "$(human_size "$sz")" "$C_RESET" "$warn"
    i=$((i+1))
  done
  printf '   %s——————%s\n' "$C_DIM" "$C_RESET"
  printf '   Totale: %s%s%s su %d file\n' "$C_BOLD" "$(human_size "$total_bytes")" "$C_RESET" "${#PKG_FILES[@]}"
}

wizard_add_files() {
  while true; do
    ui_clear
    ui_header "Crea package — file selezionati"
    wizard_show_files
    echo
    ui_input "Path o glob da aggiungere (vuoto = fine, 'r N' = rimuovi #N, 'c' = svuota)" ""
    local entry="$UI_INPUT_VALUE"
    # Trim leading/trailing whitespace (tipici da copy-paste o autocompletion del terminale)
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    # Rimuovi virgolette di apertura/chiusura attorno al path:
    # - ASCII:        '...'  oppure  "..."
    # - Unicode curly: ‘...’  oppure  “...”
    # (macOS sostituisce spesso le virgolette dritte in app come Notes/Pages.)
    local _LSQUO=$'\xe2\x80\x98' _RSQUO=$'\xe2\x80\x99'
    local _LDQUO=$'\xe2\x80\x9c' _RDQUO=$'\xe2\x80\x9d'
    if [[ ${#entry} -ge 2 ]]; then
      if [[ "$entry" == \'*\' || "$entry" == \"*\" ]]; then
        entry="${entry:1:${#entry}-2}"
      elif [[ "$entry" == "${_LSQUO}"*"${_RSQUO}" ]]; then
        entry="${entry#$_LSQUO}"; entry="${entry%$_RSQUO}"
      elif [[ "$entry" == "${_LDQUO}"*"${_RDQUO}" ]]; then
        entry="${entry#$_LDQUO}"; entry="${entry%$_RDQUO}"
      fi
    fi
    [[ -z "$entry" ]] && break

    if [[ "$entry" == "c" ]]; then
      PKG_FILES=()
      PKG_FILES_INSIDE_ROOT=()
      continue
    fi

    if [[ "$entry" =~ ^r[[:space:]]+([0-9]+)$ ]]; then
      local rm_idx="${BASH_REMATCH[1]}"
      rm_idx=$((rm_idx - 1))
      if [[ $rm_idx -ge 0 && $rm_idx -lt ${#PKG_FILES[@]} ]]; then
        local new_files=() new_inside=()
        local i=0
        while [[ $i -lt ${#PKG_FILES[@]} ]]; do
          if [[ $i -ne $rm_idx ]]; then
            new_files+=("${PKG_FILES[$i]}")
            new_inside+=("${PKG_FILES_INSIDE_ROOT[$i]}")
          fi
          i=$((i+1))
        done
        PKG_FILES=("${new_files[@]+"${new_files[@]}"}")
        PKG_FILES_INSIDE_ROOT=("${new_inside[@]+"${new_inside[@]}"}")
      else
        ui_warn "Indice fuori range."
        ui_pause
      fi
      continue
    fi

    # Espandi tilde
    entry="${entry/#\~/$HOME}"

    # Glob expansion: niente prefix di SCRIPT_DIR se path assoluto
    local matches=()
    if [[ "$entry" == *"*"* || "$entry" == *"?"* || "$entry" == *"["* ]]; then
      # Glob: relativo a SCRIPT_DIR se non assoluto
      local pattern="$entry"
      [[ "$pattern" != /* ]] && pattern="$SCRIPT_DIR/$pattern"
      # Disabilita word splitting (IFS vuoto) per preservare gli spazi nel path,
      # mantenendo il pathname expansion (glob). Altrimenti "Application Support"
      # verrebbe spezzato in due parole prima dell'espansione del glob.
      local oldIFS="$IFS"
      IFS=
      shopt -s nullglob
      local m
      for m in $pattern; do matches+=("$m"); done
      shopt -u nullglob
      IFS="$oldIFS"
      if [[ ${#matches[@]} -eq 0 ]]; then
        ui_warn "Nessun file matcha: $entry"
        ui_pause
        continue
      fi
    else
      local f="$entry"
      [[ "$f" != /* ]] && f="$SCRIPT_DIR/$f"
      if [[ ! -e "$f" ]]; then
        ui_warn "File non trovato: $entry"
        ui_pause
        continue
      fi
      matches=("$f")
    fi

    # Espandi ricorsivamente le directory: dato un match (da glob o path singolo),
    # se è un file lo prende, se è una dir fa find -type f (esclude .DS_Store).
    local file_list=()
    local m
    for m in "${matches[@]}"; do
      if [[ -d "$m" ]]; then
        local ff
        while IFS= read -r -d '' ff; do
          file_list+=("$ff")
        done < <(find "$m" -type f ! -name '.DS_Store' -print0 2>/dev/null)
      elif [[ -f "$m" ]]; then
        file_list+=("$m")
      else
        ui_warn "Salto (non è file né directory): $m"
      fi
    done

    if [[ ${#file_list[@]} -eq 0 ]]; then
      ui_warn "Niente da aggiungere."
      ui_pause
      continue
    fi

    # Conferma se l'operazione coinvolge molti file (evita aggiunte accidentali)
    if [[ ${#file_list[@]} -gt 50 ]]; then
      echo
      ui_info "Stai per aggiungere ${#file_list[@]} file."
      if ! ui_yesno "Continuare?" "y"; then
        continue
      fi
    fi

    # Aggiungi al package, ignora duplicati
    local added=0
    local f
    for f in "${file_list[@]}"; do
      local dup=0
      local existing
      for existing in "${PKG_FILES[@]+"${PKG_FILES[@]}"}"; do
        if [[ "$existing" == "$f" ]]; then dup=1; break; fi
      done
      [[ $dup -eq 1 ]] && continue
      PKG_FILES+=("$f")
      PKG_FILES_INSIDE_ROOT+=("$(file_inside_manifest_tree "$f")")
      added=$((added + 1))
    done

    if [[ $added -gt 0 ]]; then
      ui_ok "Aggiunti $added file (totale: ${#PKG_FILES[@]})"
      sleep 1
    fi
  done
}

wizard_collect_metadata() {
  ui_clear
  ui_header "Crea package — metadati (1/2)"
  echo

  while true; do
    ui_input "Nome del package (es. 'GDC Online DH Chunks')" ""
    PKG_NAME="$UI_INPUT_VALUE"
    if [[ -z "$PKG_NAME" ]]; then
      ui_warn "Il nome è obbligatorio."
      continue
    fi
    local sanitized
    sanitized="$(sanitize_name "$PKG_NAME")"
    if [[ -z "$sanitized" ]]; then
      ui_warn "Nome non valido dopo sanitizzazione."
      continue
    fi
    if [[ -d "$PACKAGES_DIR/$sanitized" ]]; then
      ui_warn "Esiste già un package chiamato '$sanitized'."
      if ui_yesno "Sovrascrivere?" "n"; then
        rm -rf "$PACKAGES_DIR/$sanitized"
        break
      fi
    else
      break
    fi
  done

  ui_input "Descrizione" ""
  PKG_DESCRIPTION="$UI_INPUT_VALUE"

  ui_input "Versione" "$PKG_VERSION"
  PKG_VERSION="$UI_INPUT_VALUE"

  # Action: extract / copy
  ui_menu "Action (cosa fa il client col package)" "extract — estrai l'archivio" "copy — copia i file così come sono" "« indietro »"
  case "$UI_MENU_INDEX" in
    0) PKG_ACTION="extract" ;;
    1) PKG_ACTION="copy" ;;
    *) return 1 ;;
  esac

  ui_clear
  ui_header "Crea package — metadati (2/2)"
  echo
  ui_input "extractTo (percorso relativo al modpack, es. 'mods/' o 'Distant_Horizons_server_data/...')" ""
  PKG_EXTRACT_TO="$UI_INPUT_VALUE"

  ui_menu "Required?" "true — installazione obbligatoria" "false — opzionale"
  [[ "$UI_MENU_INDEX" -eq 0 ]] && PKG_REQUIRED="true" || PKG_REQUIRED="false"

  ui_menu "Overwrite (sovrascrive file esistenti lato client)?" "false" "true"
  [[ "$UI_MENU_INDEX" -eq 0 ]] && PKG_OVERWRITE="false" || PKG_OVERWRITE="true"

  ui_input "progressMessage (placeholder: *currentPart*, *totalParts*, *percentage*, vuoto = omesso)" ""
  PKG_PROGRESS_MESSAGE="$UI_INPUT_VALUE"

  ui_input "Dimensione split 7z (es. 50m, 100m, 1g)" "$PKG_SPLIT_SIZE"
  PKG_SPLIT_SIZE="$UI_INPUT_VALUE"

  return 0
}

wizard_preview() {
  ui_clear
  ui_header "Conferma creazione package"
  printf '%sName:%s        %s\n'    "$C_BOLD" "$C_RESET" "$PKG_NAME"
  printf '%sDescription:%s %s\n'    "$C_BOLD" "$C_RESET" "$PKG_DESCRIPTION"
  printf '%sVersion:%s     %s\n'    "$C_BOLD" "$C_RESET" "$PKG_VERSION"
  printf '%sAction:%s      %s\n'    "$C_BOLD" "$C_RESET" "$PKG_ACTION"
  printf '%sExtractTo:%s   %s\n'    "$C_BOLD" "$C_RESET" "$PKG_EXTRACT_TO"
  printf '%sRequired:%s    %s\n'    "$C_BOLD" "$C_RESET" "$PKG_REQUIRED"
  printf '%sOverwrite:%s   %s\n'    "$C_BOLD" "$C_RESET" "$PKG_OVERWRITE"
  printf '%sProgressMsg:%s %s\n'    "$C_BOLD" "$C_RESET" "${PKG_PROGRESS_MESSAGE:-—}"
  printf '%sSplit size:%s  %s\n'    "$C_BOLD" "$C_RESET" "$PKG_SPLIT_SIZE"
  echo
  printf '%sFile:%s\n' "$C_BOLD" "$C_RESET"
  wizard_show_files
  echo

  # avviso duplicazione
  local any_inside=0
  local v
  for v in "${PKG_FILES_INSIDE_ROOT[@]+"${PKG_FILES_INSIDE_ROOT[@]}"}"; do
    [[ -n "$v" ]] && any_inside=1
  done
  if [[ $any_inside -eq 1 ]]; then
    ui_warn "Alcuni file selezionati stanno DENTRO il modpack: finiranno sia in 'files' che in 'packages.files'"
    ui_warn "del manifest (doppio download per i client). Valuta se aggiungerli a .manifestignore."
    echo
  fi

  if ui_yesno "Procedere con la creazione?" "y"; then
    return 0
  fi
  return 1
}

wizard_execute() {
  local seven_z
  seven_z="$(detect_7z)"
  if [[ -z "$seven_z" ]]; then
    ui_error "Né '7z' né '7zz' trovati nel PATH."
    ui_info "Installa con: brew install p7zip"
    ui_pause
    return 1
  fi

  local sanitized
  sanitized="$(sanitize_name "$PKG_NAME")"
  local pkg_dir="$PACKAGES_DIR/$sanitized"
  mkdir -p "$pkg_dir"

  # Stage: dir temporanea per dare a 7z basename puliti
  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/gdc-deploy.XXXXXX")"
  trap 'rm -rf "$stage"' RETURN

  ui_clear
  ui_header "Creazione package: $PKG_NAME"
  ui_info "Stage temporaneo: $stage"
  echo

  # Copia file nello stage. Se collidono basename, antepone un contatore.
  local i=0
  local staged_files=()
  while [[ $i -lt ${#PKG_FILES[@]} ]]; do
    local src="${PKG_FILES[$i]}"
    local base
    base="$(basename "$src")"
    local dest="$stage/$base"
    if [[ -e "$dest" ]]; then
      local n=2
      while [[ -e "$stage/${n}_$base" ]]; do n=$((n+1)); done
      dest="$stage/${n}_$base"
    fi
    printf '  copia %s → %s\n' "$src" "$(basename "$dest")"
    if ! cp "$src" "$dest"; then
      ui_error "Errore copia $src"
      rm -rf "$stage"; trap - RETURN
      ui_pause
      return 1
    fi
    staged_files+=("$(basename "$dest")")
    i=$((i+1))
  done

  # Calcola nomi degli archivi
  local archive_base="$sanitized.7z"
  echo
  ui_info "Comprimo con $seven_z (ultra, split=$PKG_SPLIT_SIZE)..."

  # Costruisci la lista di file da passare a 7z (basename, dato che faremo cd)
  pushd "$stage" >/dev/null || return 1
  if ! "$seven_z" a -t7z -mx=9 -mmt=on -ms=on "-v${PKG_SPLIT_SIZE}" "$archive_base" "${staged_files[@]}" >/dev/null; then
    popd >/dev/null || true
    ui_error "Errore durante la compressione 7z."
    rm -rf "$stage"; trap - RETURN
    ui_pause
    return 1
  fi

  # Raccogli i parts generati
  local parts=()
  if [[ -f "$archive_base" ]]; then
    # Caso: archivio singolo (sotto soglia di split → 7z genera un solo file)
    parts+=("$archive_base")
  else
    local p
    for p in "$archive_base".*; do
      [[ -f "$p" ]] && parts+=("$(basename "$p")")
    done
  fi
  popd >/dev/null || true

  if [[ ${#parts[@]} -eq 0 ]]; then
    ui_error "Nessun archivio generato."
    rm -rf "$stage"; trap - RETURN
    ui_pause
    return 1
  fi

  # Sposta i parts nella cartella del package
  # Svuota la dir destinazione (escluso package.json se esiste — lo riscriviamo comunque)
  rm -f "$pkg_dir"/*.7z "$pkg_dir"/*.7z.* 2>/dev/null || true
  local p
  for p in "${parts[@]}"; do
    mv "$stage/$p" "$pkg_dir/$p"
  done

  # Pulizia stage
  rm -rf "$stage"; trap - RETURN

  # filesToExtract = i basename originali (quelli messi nello stage)
  local parts_nl fte_nl
  parts_nl=$(printf '%s\n' "${parts[@]}")
  fte_nl=$(printf '%s\n' "${staged_files[@]}")

  # Scrivi package.json via python3 per JSON corretto
  write_package_json "$pkg_dir/package.json" "$parts_nl" "$fte_nl"

  echo
  ui_ok "Package creato in: $pkg_dir"
  ui_info "Parts: ${#parts[@]}"
  local total=0
  for p in "${parts[@]}"; do
    total=$((total + $(file_size_bytes "$pkg_dir/$p")))
  done
  ui_info "Dimensione totale: $(human_size "$total")"

  echo
  if ui_yesno "Rigenerare ora il manifest.json?" "y"; then
    echo
    bash "$GENERATE_MANIFEST" && ui_ok "Manifest rigenerato." || ui_error "Errore generazione manifest."
  fi
  ui_pause
}

# Scrive package.json. $1=path output, $2=parts (newline-separated), $3=filesToExtract (newline-separated).
write_package_json() {
  local out="$1" parts_nl="$2" fte_nl="$3"

  PKG_OUT_PATH="$out" \
  PKG_NAME_E="$PKG_NAME" \
  PKG_DESC_E="$PKG_DESCRIPTION" \
  PKG_VERSION_E="$PKG_VERSION" \
  PKG_ACTION_E="$PKG_ACTION" \
  PKG_EXTRACT_TO_E="$PKG_EXTRACT_TO" \
  PKG_REQUIRED_E="$PKG_REQUIRED" \
  PKG_OVERWRITE_E="$PKG_OVERWRITE" \
  PKG_PROGRESS_MESSAGE_E="$PKG_PROGRESS_MESSAGE" \
  PKG_PARTS_E="$parts_nl" \
  PKG_FTE_E="$fte_nl" \
  python3 - <<'PY'
import json, os

def env_or_none(name):
    v = os.environ.get(name, "")
    return v if v else None

def env_bool(name):
    v = os.environ.get(name, "").lower()
    if v in ("true","1","yes","y","s","si"): return True
    if v in ("false","0","no","n"): return False
    return None

def env_list(name):
    raw = os.environ.get(name, "")
    return [line for line in raw.splitlines() if line]

cfg = {
    "name":             env_or_none("PKG_NAME_E"),
    "description":      env_or_none("PKG_DESC_E"),
    "version":          env_or_none("PKG_VERSION_E"),
    "archiveType":      "7z",
    "parts":            env_list("PKG_PARTS_E"),
    "extractTo":        env_or_none("PKG_EXTRACT_TO_E"),
    "filesToExtract":   env_list("PKG_FTE_E"),
    "action":           env_or_none("PKG_ACTION_E"),
    "overwrite":        env_bool("PKG_OVERWRITE_E"),
    "required":         env_bool("PKG_REQUIRED_E"),
    "progressMessage":  env_or_none("PKG_PROGRESS_MESSAGE_E"),
}

# Rimuovi chiavi con valore None o lista vuota (tranne campi obbligatori)
required_keys = {"name", "version", "archiveType", "parts", "action"}
clean = {}
for k, v in cfg.items():
    if k in required_keys:
        clean[k] = v
        continue
    if v is None: continue
    if isinstance(v, list) and not v: continue
    clean[k] = v

out_path = os.environ["PKG_OUT_PATH"]
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(clean, f, ensure_ascii=False, indent=2)
PY
}

action_create_package() {
  reset_pkg_state

  # 1) Metadati
  if ! wizard_collect_metadata; then
    return 0
  fi

  # 2) Selezione file
  wizard_add_files

  if [[ ${#PKG_FILES[@]} -eq 0 ]]; then
    ui_clear
    ui_header "Crea package"
    ui_error "Nessun file selezionato. Operazione annullata."
    ui_pause
    return 1
  fi

  # 3) Conferma + esegui
  if wizard_preview; then
    wizard_execute
  else
    ui_info "Operazione annullata."
    ui_pause
  fi
}

action_full_deploy() {
  action_create_package
  ui_clear
  ui_header "Deploy completo"
  ui_info "Rigenerazione manifest finale..."
  echo
  bash "$GENERATE_MANIFEST" && ui_ok "Deploy completato." || ui_error "Errore manifest."
  ui_pause
}

# ───── Aggiorna LOD Package (Distant Horizons) ─────
#
# Sincronizza UN package DH multi-mondo con i dati LOD locali: scopre tutti i
# mondi sotto Distant_Horizons_server_data/Minecraft+Server/, li fonde nel
# package (most-recent-wins) e rigenera le parti 7z. Vedi tools/dh_update_package.py.

action_update_lod_package() {
  ui_clear
  ui_header "Aggiorna LOD Package (Distant Horizons)"

  # Prerequisiti
  if [[ ! -f "$DH_ENGINE" ]]; then
    ui_error "Motore non trovato: $DH_ENGINE"
    ui_pause; return 1
  fi
  if ! python3 -c 'import sqlite3' 2>/dev/null; then
    ui_error "Modulo python sqlite3 non disponibile."
    ui_pause; return 1
  fi
  local sevenz; sevenz="$(detect_7z)"
  if [[ -z "$sevenz" ]]; then
    ui_error "7z non trovato. Installa con: brew install p7zip"
    ui_pause; return 1
  fi

  # 1) Rileva i package DH (filesToExtract contiene DistantHorizons.sqlite)
  local detect
  detect=$(python3 - "$PACKAGES_DIR" <<'PY'
import json, os, sys
root = sys.argv[1]
if os.path.isdir(root):
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        pj = os.path.join(d, "package.json")
        if not os.path.isfile(pj):
            continue
        try:
            cfg = json.load(open(pj, encoding="utf-8"))
        except Exception:
            continue
        fte = cfg.get("filesToExtract") or []
        if any(str(x).endswith("DistantHorizons.sqlite") for x in fte):
            print("\t".join([d, cfg.get("name") or name]))
PY
)
  if [[ -z "$detect" ]]; then
    ui_error "Nessun package DH trovato in packages/."
    ui_info "(serve un package con filesToExtract = DistantHorizons.sqlite)"
    ui_pause; return 1
  fi

  local PKG_DIRS=() PKG_NAMES=()
  while IFS=$'\t' read -r d n; do
    [[ -z "$d" ]] && continue
    PKG_DIRS+=("$d"); PKG_NAMES+=("$n")
  done <<< "$detect"

  # 2) Scegli quale package (menu solo se più d'uno)
  local pidx=0
  if [[ ${#PKG_DIRS[@]} -gt 1 ]]; then
    local opts=() i=0
    while [[ $i -lt ${#PKG_NAMES[@]} ]]; do opts+=("${PKG_NAMES[$i]}"); i=$((i+1)); done
    opts+=("« Annulla »")
    ui_menu "Quale LOD package aggiornare?" "${opts[@]}" || return 0
    pidx=$UI_MENU_INDEX
    [[ $pidx -ge ${#PKG_DIRS[@]} ]] && return 0
  fi
  local pkg_dir="${PKG_DIRS[$pidx]}"
  local pkg_name="${PKG_NAMES[$pidx]}"

  # 3) Sorgente-radice: locale (default) o cartella esterna con struttura <mondo>/DistantHorizons.sqlite
  local server_data="$DH_SERVER_DATA"
  ui_clear
  ui_header "Aggiorna LOD Package — sorgente"
  printf '%sPackage:%s  %s\n' "$C_BOLD" "$C_RESET" "$pkg_name"
  printf '%sLocale:%s   %s\n\n' "$C_BOLD" "$C_RESET" "$server_data"
  if ui_yesno "Usare una cartella sorgente DIVERSA da quella locale?" "n"; then
    ui_input "Percorso radice (contiene le cartelle <mondo>/DistantHorizons.sqlite)" ""
    local ext="$UI_INPUT_VALUE"
    ext="${ext#"${ext%%[![:space:]]*}"}"; ext="${ext%"${ext##*[![:space:]]}"}"
    if [[ "$ext" == \'*\' || "$ext" == \"*\" ]] && [[ ${#ext} -ge 2 ]]; then
      ext="${ext:1:${#ext}-2}"
    fi
    ext="${ext/#\~/$HOME}"
    [[ -z "$ext" ]] && return 0
    if [[ ! -d "$ext" ]]; then
      ui_error "Cartella non trovata: $ext"
      ui_pause; return 1
    fi
    server_data="$ext"
  fi

  local dhignore="$SCRIPT_DIR/.dhignore"

  # 4) Anteprima veloce (--plan): elenco mondi senza estrarre nulla
  ui_clear
  ui_header "Aggiorna LOD Package — anteprima"
  local plan
  plan=$(python3 "$DH_ENGINE" "$pkg_dir" "$server_data" --plan --dhignore "$dhignore" 2>/dev/null)
  if [[ -z "$plan" ]]; then
    ui_error "Impossibile generare l'anteprima."
    ui_pause; return 1
  fi

  # Renderizza il piano: l'elenco mondi su stdout + una riga sentinella col totale.
  # Il plan viaggia via env var (DH_PLAN), non via stdin: lo stdin qui è il
  # heredoc dello script python, non possono coesistere.
  local rendered
  rendered=$(DH_PLAN="$plan" python3 - <<'PY'
import json, os
line = os.environ.get("DH_PLAN", "")
p = json.loads(line[7:]) if line.startswith("RESULT ") else None
if not p:
    print("__WORLDS__=0"); raise SystemExit
labels = {"merge": "merge ", "new": "NUOVO ", "keep": "tieni "}
for w in p["worlds"]:
    sz = f"{w['source_size']/1048576:6.1f} MB" if w.get("source_size") else "      -   "
    print(f"  {labels.get(w['state'], w['state']):6} {sz}  {w['world']}")
if p.get("removed_by_ignore"):
    print("  rimossi (.dhignore): " + ", ".join(p["removed_by_ignore"]))
print(f"__WORLDS__={len(p['worlds'])}")
PY
)
  local n_worlds
  n_worlds=$(printf '%s\n' "$rendered" | sed -n 's/^__WORLDS__=//p')
  printf '%s\n' "$rendered" | grep -v '^__WORLDS__='
  echo
  ui_info "merge = mondo già nel package fuso col locale  •  NUOVO = aggiunto  •  tieni = preservato"
  ui_warn "Controlla i mondi NUOVI: se uno è di un altro server, aggiungilo a .dhignore"
  ui_info "(.dhignore: un nome-cartella per riga, in $dhignore)"
  echo

  if [[ "${n_worlds:-0}" -eq 0 ]]; then
    ui_error "Nessun mondo da includere."
    ui_pause; return 1
  fi

  ui_info "Regola di merge: vince il dato con timestamp più recente."
  echo
  if ! ui_yesno "Sincronizzare $n_worlds mondi nel package?" "y"; then
    ui_info "Operazione annullata."
    ui_pause; return 0
  fi

  # 5) Esegui il motore (output live)
  ui_clear
  ui_header "Sincronizzazione in corso: $pkg_name"
  echo
  if python3 "$DH_ENGINE" "$pkg_dir" "$server_data" --seven-z "$sevenz" --dhignore "$dhignore"; then
    echo
    ui_ok "LOD package multi-mondo aggiornato con successo."
    echo
    if ui_yesno "Rigenerare ora il manifest.json?" "y"; then
      echo
      bash "$GENERATE_MANIFEST" && ui_ok "Manifest rigenerato." || ui_error "Errore manifest."
    fi
  else
    echo
    ui_error "Aggiornamento fallito. Il package originale non è stato modificato."
  fi
  ui_pause
}

# ───── Main loop ─────

main_menu() {
  while true; do
    ui_menu "Menu principale" \
      "Rigenera manifest.json" \
      "Crea nuovo package" \
      "Aggiorna LOD Package (DH Chunks — tutti i mondi)" \
      "Elenca packages esistenti" \
      "Elimina package" \
      "Crea package + rigenera manifest (deploy completo)" \
      "Esci"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      # 'q' o ESC sul menu principale = esci
      break
    fi
    case "$UI_MENU_INDEX" in
      0) action_regenerate_manifest ;;
      1) action_create_package ;;
      2) action_update_lod_package ;;
      3) action_list_packages ;;
      4) action_delete_package ;;
      5) action_full_deploy ;;
      6) break ;;
    esac
  done
  ui_clear
  ui_show_cursor
  printf '%sArrivederci.%s\n' "$C_CYAN" "$C_RESET"
}

# Sanity check di base
if ! command -v python3 >/dev/null 2>&1; then
  echo "Errore: python3 non trovato (richiesto da generate_manifest e da deploy)." >&2
  exit 1
fi

main_menu
