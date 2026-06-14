#!/usr/bin/env python3
"""Motore di sincronizzazione di un LOD package Distant Horizons MULTI-MONDO.

Un singolo package contiene i DistantHorizons.sqlite di TUTTI i mondi, con
struttura interna  <cartella_mondo>/DistantHorizons.sqlite  ed extractTo = la
radice  Distant_Horizons_server_data/Minecraft+Server/ .  Così update.sh estrae
ogni sqlite nella cartella del mondo giusto senza modifiche (7z mantiene i path).

Sincronizzazione (most-recent-wins su LastModifiedUnixDateTime):
  - mondo presente sia nel package che in locale  -> merge
  - mondo presente solo in locale                 -> aggiunto
  - mondo presente solo nel package               -> preservato
  - mondo in .dhignore                            -> escluso dal package

Lo swap nella cartella del package è l'ULTIMO passo, dopo che merge, integrity
e verifica round-trip (per ogni mondo) sono passati. In caso di errore prima,
il package originale resta intatto.

Uso:
  dh_update_package.py PACKAGE_DIR SERVER_DATA_DIR [--plan] [--dry-run]
                       [--keep-version] [--seven-z BIN] [--dhignore FILE]

  --plan   stampa (JSON) i mondi e il loro stato senza estrarre nulla, poi esce.

Output: progresso su stdout; riga finale "RESULT <json>" con le statistiche.
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

SQLITE_NAME = "DistantHorizons.sqlite"
DATA_TABLES = {
    "FullData":   "LastModifiedUnixDateTime",
    "ChunkHash":  "LastModifiedUnixDateTime",
    "BeaconBeam": "LastModifiedUnixDateTime",
}
DEFAULT_SPLIT = 100 * 1024 * 1024


def log(msg):
    print(msg, flush=True)


def die(msg, code=1):
    print(f"ERRORE: {msg}", file=sys.stderr, flush=True)
    print("Il package originale NON è stato modificato.", file=sys.stderr, flush=True)
    sys.exit(code)


def detect_7z(explicit=None):
    if explicit and shutil.which(explicit):
        return explicit
    for cand in ("7z", "7zz", "7za"):
        p = shutil.which(cand)
        if p:
            return p
    return None


# ───── introspezione / merge (provato su dati reali) ─────
def table_info(con, table, schema="main"):
    cols, pk = [], []
    for row in con.execute(f"PRAGMA {schema}.table_info('{table}')"):
        cols.append(row[1])
        if row[5]:
            pk.append((row[5], row[1]))
    pk.sort()
    return cols, [name for _, name in pk]


def merge_table(con, table, ts_col):
    cols, pk_cols = table_info(con, table, "main")
    inc_cols, inc_pk = table_info(con, table, "inc")
    if not pk_cols:
        raise RuntimeError(f"{table}: nessuna primary key")
    if ts_col not in cols:
        raise RuntimeError(f"{table}: manca la colonna timestamp {ts_col}")
    if set(cols) != set(inc_cols):
        raise RuntimeError(
            f"Schema diverso per {table}: base={sorted(cols)} incoming={sorted(inc_cols)}"
        )
    if pk_cols != inc_pk:
        raise RuntimeError(f"Primary key diversa per {table}: base={pk_cols} incoming={inc_pk}")

    pk_join = " AND ".join(f"m.{c}=i.{c}" for c in pk_cols)
    base_before = con.execute(f"SELECT count(*) FROM main.{table}").fetchone()[0]
    added = con.execute(
        f"SELECT count(*) FROM inc.{table} i "
        f"WHERE NOT EXISTS (SELECT 1 FROM main.{table} m WHERE {pk_join})"
    ).fetchone()[0]
    updated = con.execute(
        f"SELECT count(*) FROM inc.{table} i JOIN main.{table} m ON {pk_join} "
        f"WHERE i.{ts_col} > m.{ts_col}"
    ).fetchone()[0]

    col_list = ",".join(cols)
    non_pk = [c for c in cols if c not in pk_cols]
    pk_target = ",".join(pk_cols)
    if non_pk:
        set_clause = ",".join(f"{c}=excluded.{c}" for c in non_pk)
        con.execute(
            f"INSERT INTO main.{table} ({col_list}) "
            f"SELECT {col_list} FROM inc.{table} WHERE true "
            f"ON CONFLICT({pk_target}) DO UPDATE SET {set_clause} "
            f"WHERE excluded.{ts_col} > main.{table}.{ts_col}"
        )
    else:
        con.execute(
            f"INSERT OR IGNORE INTO main.{table} ({col_list}) SELECT {col_list} FROM inc.{table}"
        )

    base_after = con.execute(f"SELECT count(*) FROM main.{table}").fetchone()[0]
    if base_after != base_before + added:
        raise RuntimeError(f"{table}: conteggio incoerente ({base_before}+{added} != {base_after})")
    return {"table": table, "before": base_before, "added": added, "updated": updated, "after": base_after}


def merge_into(base_path, incoming_path):
    con = sqlite3.connect(base_path)
    try:
        con.execute("PRAGMA foreign_keys=OFF")
        con.execute("ATTACH DATABASE ? AS inc", (incoming_path,))
        base_t = {r[0] for r in con.execute("SELECT name FROM main.sqlite_master WHERE type='table'")}
        inc_t = {r[0] for r in con.execute("SELECT name FROM inc.sqlite_master WHERE type='table'")}
        stats = []
        con.execute("BEGIN")
        try:
            for table, ts_col in DATA_TABLES.items():
                if table in base_t and table in inc_t:
                    stats.append(merge_table(con, table, ts_col))
            con.execute("COMMIT")
        except Exception:
            con.execute("ROLLBACK")
            raise
        return stats
    finally:
        con.close()


def snapshot_source(source_path, dest_path):
    src = sqlite3.connect(source_path, timeout=15)
    try:
        src.execute("PRAGMA busy_timeout=15000")
        dst = sqlite3.connect(dest_path)
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()


def vacuum_into(src_path, dest_path):
    con = sqlite3.connect(src_path)
    try:
        con.execute("VACUUM INTO ?", (dest_path,))
    finally:
        con.close()


def counts_per_table(db_path):
    con = sqlite3.connect(db_path)
    try:
        existing = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        return {t: con.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
                for t in DATA_TABLES if t in existing}
    finally:
        con.close()


def integrity_ok(db_path):
    con = sqlite3.connect(db_path)
    try:
        return con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    finally:
        con.close()


def run_7z(seven_z, args, cwd=None):
    proc = subprocess.run([seven_z] + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=cwd)
    if proc.returncode != 0:
        raise RuntimeError(f"7z fallito ({proc.returncode}):\n{proc.stdout.decode(errors='replace')}")


def bump_version(v):
    if v and re.match(r"^\d+\.\d+\.\d+$", v):
        a, b, c = v.split(".")
        return f"{a}.{b}.{int(c)+1}"
    return v


# ───── logica multi-mondo ─────
def package_worlds(cfg):
    """Dai (extractTo, filesToExtract) del package ricava:
       {world_folder: internal_archive_path}  +  canonical_root (relativo al modpack).
    Gestisce sia il formato flat (un solo sqlite, extractTo=.../<world>/) sia il
    multi-mondo (extractTo=.../Minecraft+Server/, fte=<world>/DistantHorizons.sqlite)."""
    extract_to = (cfg.get("extractTo") or "").rstrip("/")
    fte = cfg.get("filesToExtract") or []
    worlds = {}
    root = None
    for rel in fte:
        dest_full = os.path.normpath(os.path.join(extract_to, rel))
        world = os.path.basename(os.path.dirname(dest_full))
        r = os.path.dirname(os.path.dirname(dest_full))
        root = r if root is None else root
        worlds[world] = rel  # path interno all'archivio == voce di filesToExtract
    return worlds, root


def load_dhignore(path):
    s = set()
    if path and os.path.isfile(path):
        for line in open(path, encoding="utf-8", errors="ignore"):
            line = line.strip()
            if line and not line.startswith("#"):
                s.add(line.rstrip("/"))
    return s


def scan_source_worlds(server_data_dir, ignore):
    """Mondi locali: {world_folder: sqlite_path}, esclusi quelli in .dhignore."""
    out = {}
    if not os.path.isdir(server_data_dir):
        return out
    for name in sorted(os.listdir(server_data_dir)):
        d = os.path.join(server_data_dir, name)
        sq = os.path.join(d, SQLITE_NAME)
        if os.path.isdir(d) and os.path.isfile(sq) and name not in ignore:
            out[name] = sq
    return out


def build_plan(cfg, server_data_dir, ignore):
    base_worlds, root = package_worlds(cfg)
    src_worlds = scan_source_worlds(server_data_dir, ignore)
    all_names = sorted(set(base_worlds) | set(src_worlds))
    items = []
    for w in all_names:
        in_base = w in base_worlds
        in_src = w in src_worlds
        state = "merge" if (in_base and in_src) else ("new" if in_src else "keep")
        size = os.path.getsize(src_worlds[w]) if in_src else None
        items.append({"world": w, "state": state, "in_base": in_base,
                      "in_source": in_src, "source_size": size})
    # mondi nel base che sono in .dhignore -> verranno rimossi
    removed = sorted(w for w in base_worlds if w in ignore)
    return {"root": root, "worlds": items, "removed_by_ignore": removed,
            "ignored": sorted(ignore)}


def main():
    raw = sys.argv[1:]
    flags = {"--plan", "--dry-run", "--keep-version"}
    plan_only = "--plan" in raw
    dry_run = "--dry-run" in raw
    keep_version = "--keep-version" in raw
    seven_z_arg = None
    dhignore_path = None
    i = 0
    pos = []
    while i < len(raw):
        a = raw[i]
        if a == "--seven-z":
            seven_z_arg = raw[i + 1]; i += 2; continue
        if a == "--dhignore":
            dhignore_path = raw[i + 1]; i += 2; continue
        if a in flags:
            i += 1; continue
        pos.append(a); i += 1
    if len(pos) < 2:
        die("uso: dh_update_package.py PACKAGE_DIR SERVER_DATA_DIR [--plan|--dry-run]")
    package_dir, server_data_dir = pos[0], pos[1]

    pkg_json_path = os.path.join(package_dir, "package.json")
    if not os.path.isfile(pkg_json_path):
        die(f"package.json non trovato in {package_dir}")
    with open(pkg_json_path, encoding="utf-8") as f:
        cfg = json.load(f)

    ignore = load_dhignore(dhignore_path)

    # --plan: anteprima veloce, nessuna estrazione
    if plan_only:
        print("RESULT " + json.dumps(build_plan(cfg, server_data_dir, ignore)))
        return

    parts = cfg.get("parts") or []
    if not parts:
        die("package.json: 'parts' vuoto")
    base_worlds, canonical_root = package_worlds(cfg)
    src_worlds = scan_source_worlds(server_data_dir, ignore)

    seven_z = detect_7z(seven_z_arg)
    if not seven_z:
        die("7z non trovato (installa: brew install p7zip)")

    first_part = os.path.join(package_dir, parts[0])
    if not os.path.isfile(first_part):
        die(f"parte mancante: {first_part}")
    split_bytes = os.path.getsize(first_part) if len(parts) > 1 else DEFAULT_SPLIT

    work = tempfile.mkdtemp(prefix="dh_sync.")
    try:
        extract_dir = os.path.join(work, "extract")
        merged_dir = os.path.join(work, "merged")
        os.makedirs(extract_dir); os.makedirs(merged_dir)

        log(f"[1/7] Estrazione package corrente ({len(parts)} parti, {len(base_worlds)} mondi)...")
        run_7z(seven_z, ["x", "-y", f"-o{extract_dir}", first_part])

        # Riposiziona ogni mondo del base in un work-tree canonico extract/<world>/sqlite
        base_paths = {}
        for world, internal in base_worlds.items():
            extracted = os.path.join(extract_dir, internal)
            if not os.path.isfile(extracted):
                die(f"estrazione: manca {internal} per il mondo {world}")
            if not integrity_ok(extracted):
                die(f"il sqlite del mondo {world} nel package è corrotto")
            base_paths[world] = extracted

        log(f"[2/7] Scansione sorgenti: {len(src_worlds)} mondi locali"
            + (f" ({len(ignore)} ignorati)" if ignore else ""))

        all_worlds = sorted((set(base_worlds) | set(src_worlds)) - ignore)
        per_world = []  # statistiche
        log("[3/7] Merge / aggiunta per mondo...")
        for world in all_worlds:
            out_path = os.path.join(merged_dir, world, SQLITE_NAME)
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            in_base = world in base_worlds
            in_src = world in src_worlds
            if in_base and in_src:
                snap = os.path.join(work, f"inc_{world}.sqlite")
                snapshot_source(src_worlds[world], snap)
                if not integrity_ok(snap):
                    die(f"snapshot corrotto per il mondo {world}")
                stats = merge_into(base_paths[world], snap)
                os.remove(snap)
                vacuum_into(base_paths[world], out_path)
                added = sum(s["added"] for s in stats)
                updated = sum(s["updated"] for s in stats)
                per_world.append({"world": world, "state": "merge", "stats": stats})
                log(f"      [merge] {world}: +{added} nuovi, ~{updated} aggiornati")
            elif in_src:
                snap = os.path.join(work, f"inc_{world}.sqlite")
                snapshot_source(src_worlds[world], snap)
                if not integrity_ok(snap):
                    die(f"snapshot corrotto per il mondo {world}")
                vacuum_into(snap, out_path)
                os.remove(snap)
                per_world.append({"world": world, "state": "new"})
                log(f"      [nuovo] {world}: aggiunto")
            else:  # solo base
                vacuum_into(base_paths[world], out_path)
                per_world.append({"world": world, "state": "keep"})
                log(f"      [tieni] {world}: preservato (assente in locale)")
            if not integrity_ok(out_path):
                die(f"integrity_check fallito per {world} dopo VACUUM")

        merged_counts = {w: counts_per_table(os.path.join(merged_dir, w, SQLITE_NAME))
                         for w in all_worlds}

        if dry_run:
            log(f"[dry-run] {len(all_worlds)} mondi pronti.")
            print("RESULT " + json.dumps({"worlds": all_worlds, "per_world": per_world,
                                          "merged_counts": merged_counts, "dry_run": True}))
            return

        log(f"[4/7] Compressione 7z dell'albero ({len(all_worlds)} mondi, split {split_bytes}b, ultra)...")
        out_dir = os.path.join(work, "out")
        os.makedirs(out_dir)
        archive = os.path.join(out_dir, SQLITE_NAME + ".7z")
        # cd in merged_dir e archivia "." -> path interni puliti <world>/DistantHorizons.sqlite
        run_7z(seven_z, ["a", "-t7z", "-mx=9", "-mmt=on", "-ms=on",
                         f"-v{split_bytes}b", archive, "."], cwd=merged_dir)
        new_parts = sorted(fn for fn in os.listdir(out_dir) if fn.startswith(SQLITE_NAME + ".7z"))
        if not new_parts:
            die("la compressione non ha prodotto parti")
        log(f"      generate {len(new_parts)} parti")

        log("[5/7] Verifica round-trip per ogni mondo...")
        verify_dir = os.path.join(work, "verify")
        os.makedirs(verify_dir)
        run_7z(seven_z, ["x", "-y", f"-o{verify_dir}", os.path.join(out_dir, new_parts[0])])
        new_fte = []
        for world in all_worlds:
            rel = f"{world}/{SQLITE_NAME}"
            rt = os.path.join(verify_dir, world, SQLITE_NAME)
            if not os.path.isfile(rt):
                die(f"round-trip: manca {rel}")
            if not integrity_ok(rt):
                die(f"round-trip: {world} corrotto")
            if counts_per_table(rt) != merged_counts[world]:
                die(f"round-trip: conteggi diversi per {world}")
            new_fte.append(rel)
        log(f"      OK: {len(new_fte)} mondi verificati")

        log("[6/7] Swap parti...")
        for fn in os.listdir(package_dir):
            if re.search(r"\.7z(\.\d+)?$", fn):
                os.remove(os.path.join(package_dir, fn))
        for fn in new_parts:
            shutil.move(os.path.join(out_dir, fn), os.path.join(package_dir, fn))

        log("[7/7] Aggiornamento package.json...")
        cfg["parts"] = new_parts
        cfg["extractTo"] = (canonical_root.rstrip("/") + "/") if canonical_root else cfg.get("extractTo")
        cfg["filesToExtract"] = new_fte
        cfg["overwrite"] = True
        if not keep_version:
            cfg["version"] = bump_version(cfg.get("version", ""))
        with open(pkg_json_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        log(f"      version={cfg.get('version')} | mondi={len(new_fte)} | parti={len(new_parts)}"
            f" | extractTo={cfg['extractTo']}")

        print("RESULT " + json.dumps({"worlds": all_worlds, "per_world": per_world,
                                      "merged_counts": merged_counts, "new_parts": new_parts,
                                      "version": cfg.get("version"), "extractTo": cfg["extractTo"]}))
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        print(f"ERRORE: {exc}", file=sys.stderr, flush=True)
        print("Il package originale NON è stato modificato.", file=sys.stderr, flush=True)
        sys.exit(1)
