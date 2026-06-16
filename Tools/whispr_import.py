#!/usr/bin/env python3
"""
whispr_import.py — bulk-import tone profiles and keyword corrections into
WhisprSoft, plus export the current ones.

WhisprSoft stores both lists in macOS UserDefaults (domain `com.whisprsoft`) as
JSON encoded into binary `Data` blobs:

  rewriteProfiles            -> [{ "id", "name", "instruction" }]
  keywordCorrections         -> [{ "id", "from", "to" }]
  selectedRewriteProfileID   -> a profile id string (left untouched here)

This script reads/writes those blobs through `defaults` (the cfprefs-blessed
path), so it stays consistent with a running app's cache.

IMPORTANT: the app holds these in memory and rewrites them on any in-app edit,
so importing while it's open would clobber your changes. The script refuses to
write while WhisprSoft is running unless you pass --quit (it quits the app
first, writes, and optionally --relaunch afterwards). A full-domain backup is
saved before every write (restore with `defaults import com.whisprsoft FILE`).

----------------------------------------------------------------------------
USAGE

  # Corrections — pairs are FROM TO  (FROM is matched whole-word, case-insensitive;
  # TO is pasted verbatim). `from` is stored lowercase, matching the app.
  Tools/whispr_import.py corrections --quit --relaunch \
      "chem soft" "Kemsoft"  "shit audio" "Schiit Audio"

  # Tones — pairs are NAME INSTRUCTION
  Tools/whispr_import.py tones --quit \
      "Terse" "Cut every nonessential word. Keep it blunt and short."

  # Bulk from a TSV file (one pair per line, a literal TAB between the columns;
  # blank lines and #-comments skipped). col1=FROM/NAME, col2=TO/INSTRUCTION.
  Tools/whispr_import.py corrections --quit --tsv my_corrections.tsv
  Tools/whispr_import.py tones       --quit --json my_tones.json   # [{name,instruction}], id optional

  # Replace the whole list instead of merging/upserting:
  Tools/whispr_import.py tones --quit --replace --json my_tones.json

  # Preview the merged result without writing anything:
  Tools/whispr_import.py corrections --dry-run "kip" "Kipp"

  # Dump what's stored now (round-trip: export, edit, re-import with --json):
  Tools/whispr_import.py export all
  Tools/whispr_import.py export tones > my_tones.json

MERGE SEMANTICS (default — use --replace to overwrite instead):
  Corrections upsert by `from` (lowercased); tones upsert by `name`
  (case-insensitive). An existing match keeps its id and gets the new value;
  anything new is appended with a fresh uppercase UUID.
"""

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import uuid
from datetime import datetime

DOMAIN = "com.whisprsoft"
APP_NAME = "WhisprSoft"
BACKUP_DIR = os.path.expanduser("~/.whispr_import_backups")

KEYS = {
    "corrections": "keywordCorrections",
    "tones": "rewriteProfiles",
}
# (value1 field, value2 field) for each kind, plus the upsert key field.
FIELDS = {
    "corrections": ("from", "to"),
    "tones": ("name", "instruction"),
}
UPSERT_KEY = {"corrections": "from", "tones": "name"}


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# ---------------------------------------------------------------- read / write

def read_list(kind):
    """The current list for `kind`, decoded from its Data/JSON blob ([] if absent)."""
    key = KEYS[kind]
    # `defaults export -` emits an XML plist of the whole domain through cfprefsd,
    # so it agrees with a running app's cache. The blob comes back as bytes.
    res = run(["defaults", "export", DOMAIN, "-"])
    if res.returncode != 0:
        die(f"could not read defaults domain {DOMAIN}: {res.stderr.strip()}")
    try:
        domain = plistlib.loads(res.stdout.encode("utf-8"))
    except Exception as e:
        die(f"could not parse defaults for {DOMAIN}: {e}")
    blob = domain.get(key)
    if blob is None:
        return []
    if not isinstance(blob, (bytes, bytearray)):
        die(f"unexpected type for {key}: {type(blob).__name__} (expected Data)")
    try:
        items = json.loads(bytes(blob).decode("utf-8"))
    except Exception as e:
        die(f"existing {key} is not valid JSON: {e}")
    if not isinstance(items, list):
        die(f"existing {key} is not a JSON array")
    return items


def write_list(kind, items):
    """Encode items to JSON and store them as the key's Data blob via `defaults`."""
    key = KEYS[kind]
    data = json.dumps(items, ensure_ascii=False).encode("utf-8")
    res = run(["defaults", "write", DOMAIN, key, "-data", data.hex()])
    if res.returncode != 0:
        die(f"failed to write {key}: {res.stderr.strip()}")


# ----------------------------------------------------------------- app control

def app_running():
    return run(["pgrep", "-x", APP_NAME]).returncode == 0


def quit_app():
    print(f"quitting {APP_NAME}…")
    run(["osascript", "-e", f'quit app "{APP_NAME}"'])
    for _ in range(50):  # up to ~5s
        if not app_running():
            return
        time.sleep(0.1)
    die(f"{APP_NAME} did not quit; aborting before writing")


def relaunch_app():
    print(f"relaunching {APP_NAME}…")
    run(["open", "-b", DOMAIN])


def backup_domain():
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(BACKUP_DIR, f"{DOMAIN}.{stamp}.plist")
    res = run(["defaults", "export", DOMAIN, path])
    if res.returncode != 0:
        die(f"backup failed: {res.stderr.strip()}")
    print(f"backed up current prefs → {path}")
    print(f"  (restore with: defaults import {DOMAIN} {path})")
    return path


# ----------------------------------------------------------------- import core

def parse_inputs(kind, args):
    """Collect (value1, value2) pairs from positional args, --tsv, and --json."""
    f1, f2 = FIELDS[kind]
    incoming = []  # list of dicts {f1:..., f2:...}

    pos = args.pairs
    if len(pos) % 2 != 0:
        die(f"positional values must come in pairs ({f1.upper()} {f2.upper()}); "
            f"got {len(pos)} value(s)")
    for i in range(0, len(pos), 2):
        incoming.append({f1: pos[i], f2: pos[i + 1]})

    if args.tsv:
        for lineno, raw in enumerate(read_text(args.tsv).splitlines(), 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) < 2:
                die(f"--tsv line {lineno}: expected two TAB-separated columns")
            incoming.append({f1: cols[0], f2: cols[1]})

    if args.json:
        try:
            data = json.loads(read_text(args.json))
        except Exception as e:
            die(f"--json: invalid JSON: {e}")
        if not isinstance(data, list):
            die("--json: top level must be an array")
        for obj in data:
            if not isinstance(obj, dict) or f1 not in obj or f2 not in obj:
                die(f"--json: each item needs \"{f1}\" and \"{f2}\"")
            incoming.append({f1: obj[f1], f2: obj[f2]})

    return incoming


def read_text(path):
    if path == "-":
        return sys.stdin.read()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError as e:
        die(f"cannot read {path}: {e}")


def normalize(kind, item):
    """Clean an incoming pair to the app's conventions; None to skip."""
    f1, f2 = FIELDS[kind]
    v1 = str(item[f1]).strip()
    v2 = str(item[f2]).strip()
    if kind == "corrections":
        v1 = v1.lower()  # the app stores `from` lowercase (match is case-insensitive)
        if not v1:
            print(f"  skipping correction with blank FROM (→ {v2!r})", file=sys.stderr)
            return None
    else:  # tones
        if not v1:
            print(f"  skipping tone with blank NAME (→ {v2[:40]!r}…)", file=sys.stderr)
            return None
        if not v2:
            print(f"  note: tone {v1!r} has a blank instruction (behaves as Default)",
                  file=sys.stderr)
    return {f1: v1, f2: v2}


def merge(kind, current, incoming, replace):
    """Upsert incoming into current (or replace wholesale). Returns (items, added, updated)."""
    f1, f2 = FIELDS[kind]
    keyf = UPSERT_KEY[kind]

    def norm_key(s):
        return str(s).strip().lower()

    base = [] if replace else list(current)
    index = {norm_key(it.get(keyf, "")): i for i, it in enumerate(base)}
    added = updated = 0

    for item in incoming:
        clean = normalize(kind, item)
        if clean is None:
            continue
        k = norm_key(clean[keyf])
        if k in index:
            existing = base[index[k]]
            existing[f1] = clean[f1]
            existing[f2] = clean[f2]
            existing.setdefault("id", new_id())
            updated += 1
        else:
            row = {"id": new_id(), f1: clean[f1], f2: clean[f2]}
            index[k] = len(base)
            base.append(row)
            added += 1
    return base, added, updated


def new_id():
    return str(uuid.uuid4()).upper()  # matches Swift's UUID().uuidString


# ----------------------------------------------------------------------- verbs

def cmd_import(kind, args):
    # Fail fast (before any work or output): refuse to write under a running app
    # unless --quit, so the user gets one clear message, not a summary-then-error.
    if not args.dry_run and app_running() and not args.quit:
        die(f"{APP_NAME} is running — pass --quit to quit it first (otherwise "
            f"it would overwrite this import on its next save)")

    incoming = parse_inputs(kind, args)
    if not incoming:
        die("nothing to import — pass value pairs, --tsv, or --json")

    current = read_list(kind)
    result, added, updated = merge(kind, current, incoming, args.replace)

    f1, f2 = FIELDS[kind]
    print(f"{kind}: {len(current)} existing → {len(result)} total "
          f"({added} added, {updated} updated"
          f"{', REPLACED' if args.replace else ''})")

    if args.dry_run:
        print("--- dry run (nothing written) ---")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    if app_running():  # only reachable with --quit (guarded above)
        quit_app()

    backup_domain()
    write_list(kind, result)
    print(f"wrote {len(result)} {kind} to {DOMAIN}.")

    if args.relaunch:
        relaunch_app()
    else:
        print(f"(relaunch {APP_NAME} to see the changes; or re-run with --relaunch)")


def cmd_export(which):
    out = {}
    if which in ("corrections", "all"):
        out["corrections"] = read_list("corrections")
    if which in ("tones", "all"):
        out["tones"] = read_list("tones")
    # For a single kind, print just the array so it round-trips into --json.
    print(json.dumps(out if which == "all" else out[which],
                     ensure_ascii=False, indent=2))


# ------------------------------------------------------------------------ main

def build_parser():
    p = argparse.ArgumentParser(
        prog="whispr_import.py",
        description="Bulk-import / export WhisprSoft tone profiles and corrections.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("USAGE", 1)[-1] if "USAGE" in __doc__ else None,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    for kind, (f1, f2) in FIELDS.items():
        sp = sub.add_parser(kind, help=f"import {kind} ({f1.upper()} {f2.upper()} pairs)")
        sp.add_argument("pairs", nargs="*", metavar="VALUE",
                        help=f"flat list of {f1.upper()} {f2.upper()} pairs")
        sp.add_argument("--tsv", metavar="FILE",
                        help="TSV file: col1<TAB>col2 per line ('-' = stdin)")
        sp.add_argument("--json", metavar="FILE",
                        help=f"JSON array of {{{f1},{f2}}} objects ('-' = stdin)")
        sp.add_argument("--replace", action="store_true",
                        help="replace the whole list instead of merging")
        sp.add_argument("--quit", action="store_true",
                        help=f"quit {APP_NAME} before writing (required if it's running)")
        sp.add_argument("--relaunch", action="store_true",
                        help=f"relaunch {APP_NAME} after writing")
        sp.add_argument("--dry-run", action="store_true",
                        help="print the merged result; write nothing")

    ex = sub.add_parser("export", help="print current corrections/tones as JSON")
    ex.add_argument("which", nargs="?", default="all",
                    choices=["corrections", "tones", "all"])
    return p


def main():
    if sys.platform != "darwin":
        die("this tool uses macOS `defaults`; run it on the Mac with WhisprSoft installed")
    args = build_parser().parse_args()
    if args.cmd == "export":
        cmd_export(args.which)
    else:
        cmd_import(args.cmd, args)


if __name__ == "__main__":
    main()
