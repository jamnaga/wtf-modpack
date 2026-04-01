#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Errore: python3 non trovato. Installa Python 3 per usare questo script." >&2
  exit 1
fi

echo "Generazione manifest in corso..."
echo

python3 - <<'PY'
import datetime
import fnmatch
import hashlib
import json
from pathlib import Path

ROOT = Path.cwd()
OUTPUT_FILE = "manifest.json"
ONCE_LIST_FILE = ".oncelist"
IGNORE_FILES = (".gitignore", ".manifestignore")
AUTO_EXCLUDE_PREFIXES = (".venv/",)


def normalize_rel(path: Path) -> str:
    rel = path.as_posix()
    if rel.startswith("./"):
        return rel[2:]
    return rel


def load_once_list() -> set[str]:
    once_list_path = ROOT / ONCE_LIST_FILE
    if not once_list_path.exists():
        return set()

    items: set[str] = set()
    for line in once_list_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        items.add(line.replace("\\", "/").lstrip("./"))
    return items


def load_ignore_patterns() -> list[str]:
    patterns: list[str] = []
    for ignore_name in IGNORE_FILES:
        ignore_path = ROOT / ignore_name
        if not ignore_path.exists():
            continue

        for raw_line in ignore_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            # Non gestiamo pattern negati per mantenere lo script semplice e prevedibile.
            if line.startswith("!"):
                continue
            patterns.append(line.replace("\\", "/"))
    return patterns


def match_segment_pattern(rel_path: str, pattern: str, directory_only: bool) -> bool:
    parts = rel_path.split("/")

    if "/" in pattern:
        if fnmatch.fnmatch(rel_path, pattern):
            return True
        if directory_only:
            return rel_path == pattern or rel_path.startswith(pattern + "/")
        return False

    for part in parts:
        if fnmatch.fnmatch(part, pattern):
            return True
    return False


def should_ignore(rel_path: str, patterns: list[str]) -> bool:
    rel_path = rel_path.replace("\\", "/")

    for raw in patterns:
        pattern = raw.strip()
        if not pattern:
            continue

        anchored = pattern.startswith("/")
        directory_only = pattern.endswith("/")

        if anchored:
            pattern = pattern[1:]
        if directory_only:
            pattern = pattern[:-1]

        if not pattern:
            continue

        if anchored:
            if directory_only:
                if rel_path == pattern or rel_path.startswith(pattern + "/"):
                    return True
            else:
                if fnmatch.fnmatch(rel_path, pattern):
                    return True
        else:
            if match_segment_pattern(rel_path, pattern, directory_only):
                return True

    return False


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def scan_files(ignore_patterns: list[str]) -> list[Path]:
    files: list[Path] = []
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue

        rel = normalize_rel(p.relative_to(ROOT))

        if p.name in {OUTPUT_FILE, "temp_ignore_patterns.txt", "temp_all_files.txt"}:
            continue

        if any(rel == prefix[:-1] or rel.startswith(prefix) for prefix in AUTO_EXCLUDE_PREFIXES):
            continue

        if should_ignore(rel, ignore_patterns):
            continue

        files.append(p)

    files.sort(key=lambda path: normalize_rel(path.relative_to(ROOT)))
    return files


def scan_packages() -> list[dict]:
    packages_dir = ROOT / "packages"
    if not packages_dir.exists() or not packages_dir.is_dir():
        return []

    results: list[dict] = []

    for package_dir in sorted([p for p in packages_dir.iterdir() if p.is_dir()], key=lambda p: p.name.lower()):
        package_json = package_dir / "package.json"
        if not package_json.exists():
            continue

        try:
            config = json.loads(package_json.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"Avviso: impossibile processare il pacchetto {package_dir.name}: {exc}")
            continue

        package_files = sorted(
            [p for p in package_dir.iterdir() if p.is_file() and p.name != "package.json"],
            key=lambda p: p.name.lower(),
        )

        pkg_obj = {
            "name": config.get("name"),
            "description": config.get("description"),
            "version": config.get("version"),
            "archiveType": config.get("archiveType"),
            "parts": config.get("parts"),
            "extractTo": config.get("extractTo"),
            "filesToExtract": config.get("filesToExtract"),
            "action": config.get("action"),
            "overwrite": config.get("overwrite"),
            "required": config.get("required"),
            "progressMessage": config.get("progressMessage"),
            "files": [],
        }

        for file_path in package_files:
            rel = normalize_rel(file_path.relative_to(ROOT))
            pkg_obj["files"].append(
                {
                    "path": rel,
                    "size": file_path.stat().st_size,
                    "sha256": sha256_file(file_path),
                }
            )

        results.append(pkg_obj)

    return results


once_list = load_once_list()
ignore_patterns = load_ignore_patterns()

print("Scansione dei file...")
all_files = scan_files(ignore_patterns)
print(f"Generazione del manifest per {len(all_files)} file...")

print("Scansione dei pacchetti...")
packages = scan_packages()
print(f"Trovati {len(packages)} pacchetti")

manifest = {
    "files": [],
    "packages": packages,
}

now = datetime.datetime.now()
manifest["generated"] = now.strftime("%d/%m/%Y %H:%M:%S,") + f"{int(now.microsecond / 10000):02d}"

for idx, file_path in enumerate(all_files, 1):
    if idx % 100 == 0:
        print(f"Processati {idx}/{len(all_files)} file...")

    rel = normalize_rel(file_path.relative_to(ROOT))
    manifest["files"].append(
        {
            "path": rel,
            "size": file_path.stat().st_size,
            "sha256": sha256_file(file_path),
            "once": rel in once_list,
        }
    )

output_path = ROOT / OUTPUT_FILE
output_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=4), encoding="utf-8")

print()
print(f"Manifest generato in {OUTPUT_FILE}")
print(f"Totale file inclusi: {len(all_files)}")
print()
PY
