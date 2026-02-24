#!/usr/bin/env python3
"""
================================================================================
DOWE Google Sheets -> 2DA Middleman Sync Tool
================================================================================
Version: 1.0  |  Requires: Python 3.8+, requests library
Install: pip install requests

PURPOSE:
    Reads your DOWE config spreadsheets from Google Sheets (published as CSV),
    converts them to NWN 2DA format, drops them into your server override folder,
    and optionally triggers a DOWE hot-reload via RCON.

    The NWN server never touches the internet. The Python script does.
    The server just reads its local .2da files as normal.

WORKFLOW:
    1. Builder edits encounter rates / package config in Google Sheets
    2. This script runs (scheduled via cron/Task Scheduler or manually)
    3. Script downloads CSV -> converts to .2da -> drops in override folder
    4. Builder types  /*reload "password"  in-game
    5. DOWE re-reads the new .2da file. Changes live in seconds.

HOW TO SET UP GOOGLE SHEETS:
    1. Open your Google Sheet
    2. File -> Share -> Publish to web
    3. Select the specific sheet tab (e.g. "enc_dynamic")
    4. Choose "Comma-separated values (.csv)"
    5. Click Publish. Copy the URL.
    6. That URL is your SHEET_URL below.

    IMPORTANT: The first row of your Google Sheet should be the column headers
    exactly as they appear in the .2da file. The script handles everything else.

    Example Sheet layout for enc_dynamic.2da:
    Row 1: LABEL | ACTIVE | CHANCE | INTERVAL | MOB_TABLE | ...
    Row 2: dsrt_roam | 1 | 15 | 6 | enc_mobs_waste | ...

SETUP:
    1. Edit SHEET_MAP below - one entry per 2DA you want synced
    2. Set OUTPUT_DIR to your NWN override/development folder path
    3. Set DRY_RUN = True to preview without writing files
    4. Schedule with Task Scheduler (Windows) or cron (Linux)

WINDOWS TASK SCHEDULER:
    Action: Start a program
    Program: python
    Arguments: C:\\DOWE\\dowe_sheets_sync.py
    Start in: C:\\DOWE\\
    Trigger: Every 5 minutes (or manually)

LINUX CRON (every 10 minutes):
    */10 * * * * /usr/bin/python3 /opt/dowe/dowe_sheets_sync.py >> /opt/dowe/sync.log 2>&1

================================================================================
"""

import os
import sys
import csv
import io
import datetime
import hashlib
import json

try:
    import requests
except ImportError:
    print("ERROR: 'requests' library not installed.")
    print("Run:  pip install requests")
    sys.exit(1)

# ==============================================================================
# CONFIGURATION - EDIT THIS SECTION
# ==============================================================================

# Path to your NWN server's override or development folder.
# The script writes .2da files directly here.
# Windows example: r"C:\NeverwinterNights\NWN\override"
# Linux example:   "/opt/nwn/override"
OUTPUT_DIR = r"C:\NeverwinterNights\NWN\override"

# Set True to preview what would change without writing any files.
DRY_RUN = False

# How often to check for changes (seconds). Only used if running in watch mode.
# For cron/scheduler, leave this as-is (not used).
POLL_INTERVAL = 300

# State file: tracks checksums of last-synced sheets.
# Prevents re-writing .2da files that haven't changed.
STATE_FILE = os.path.join(os.path.dirname(__file__), "sync_state.json")

# Log file path. Set to None to print to stdout only.
LOG_FILE = os.path.join(os.path.dirname(__file__), "sync.log")

# ==============================================================================
# SHEET MAP
# Each entry: "2da_filename": "google_sheets_csv_url"
#
# How to get the CSV URL from Google Sheets:
#   File -> Share -> Publish to web -> Select tab -> CSV -> Copy link
#   URL format: https://docs.google.com/spreadsheets/d/YOUR_ID/pub?gid=SHEET_GID&single=true&output=csv
# ==============================================================================

SHEET_MAP = {
    # 2DA filename (no extension) : Published CSV URL
    "core_package": (
        "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?"
        "gid=0&single=true&output=csv"
    ),
    "enc_dynamic": (
        "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?"
        "gid=123456789&single=true&output=csv"
    ),
    "enc_hub": (
        "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?"
        "gid=987654321&single=true&output=csv"
    ),
    "ai_hub": (
        "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?"
        "gid=111222333&single=true&output=csv"
    ),
    "core_admin": (
        "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/pub?"
        "gid=444555666&single=true&output=csv"
    ),
}

# ==============================================================================
# COLUMN WIDTHS for .2da formatting
# The script auto-detects widths, but you can force minimum widths here.
# Key = 2da name, Value = dict of {column_name: min_width}
# ==============================================================================

FORCED_WIDTHS = {
    "core_package": {
        "PACKAGE": 20,
        "SCRIPT": 20,
        "BOOT_SCRIPT": 20,
        "SHUTDOWN_SCRIPT": 20,
        "DEBUG_VAR": 18,
    },
    "enc_dynamic": {
        "LABEL": 16,
        "MOB_TABLE": 20,
    },
    "ai_hub": {
        "SYSTEM": 16,
        "SCRIPT": 20,
        "DEBUG_VAR": 24,
    },
}

# ==============================================================================
# CORE SYNC LOGIC
# ==============================================================================

def log(msg: str):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {msg}"
    print(line)
    if LOG_FILE:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def load_state() -> dict:
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_state(state: dict):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def checksum(data: str) -> str:
    return hashlib.md5(data.encode("utf-8")).hexdigest()


def download_csv(url: str, name: str) -> str | None:
    """Downloads a published Google Sheet CSV. Returns raw CSV text or None."""
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        return resp.text
    except requests.exceptions.ConnectionError:
        log(f"  ERROR [{name}]: Cannot connect. Check internet / URL.")
        return None
    except requests.exceptions.HTTPError as e:
        log(f"  ERROR [{name}]: HTTP {e.response.status_code}. Sheet may not be published.")
        return None
    except requests.exceptions.Timeout:
        log(f"  ERROR [{name}]: Timeout. Google Sheets may be slow.")
        return None


def csv_to_2da(csv_text: str, name: str) -> str:
    """
    Converts a CSV string to a valid NWN 2DA V2.0 file.

    Rules:
    - Row 0 in CSV = column headers
    - Subsequent rows = data rows (auto-numbered 0, 1, 2...)
    - Empty cells become ****
    - Whitespace in values becomes _ (NWN 2DA doesn't support spaces in cells)
    - The row number column is added automatically as the first column
    """
    reader = csv.reader(io.StringIO(csv_text))
    rows = list(reader)

    if not rows:
        log(f"  WARNING [{name}]: Empty sheet - no rows found.")
        return ""

    # Filter comment rows (rows starting with //) and blank rows
    header_row = None
    data_rows = []
    for row in rows:
        if not row or all(cell.strip() == "" for cell in row):
            continue
        if row[0].strip().startswith("//"):
            continue
        if header_row is None:
            # First non-blank, non-comment row is the header
            header_row = [cell.strip() for cell in row]
        else:
            data_rows.append([cell.strip() for cell in row])

    if not header_row:
        log(f"  WARNING [{name}]: No header row found.")
        return ""

    # Replace empty cells with ****
    clean_rows = []
    for row in data_rows:
        # Pad short rows to match header length
        while len(row) < len(header_row):
            row.append("")
        cleaned = []
        for cell in row[:len(header_row)]:
            if cell == "" or cell is None:
                cleaned.append("****")
            elif " " in cell:
                # NWN 2DA cells cannot contain spaces - replace with underscore
                cleaned.append(cell.replace(" ", "_"))
            else:
                cleaned.append(cell)
        clean_rows.append(cleaned)

    # Compute column widths (max of header length vs any data cell, + 2 padding)
    forced = FORCED_WIDTHS.get(name, {})
    col_widths = []
    for ci, col in enumerate(header_row):
        max_w = len(col)
        for row in clean_rows:
            if ci < len(row):
                max_w = max(max_w, len(row[ci]))
        min_forced = forced.get(col, 0)
        col_widths.append(max(max_w + 2, min_forced + 2))

    # Row index width
    max_row_idx = len(clean_rows) - 1
    idx_width = max(len(str(max_row_idx)) + 2, 6)

    # Build 2DA text
    lines = []
    lines.append("2DA V2.0")
    lines.append("")
    lines.append(f"// Auto-generated by DOWE Sheets Sync  |  Source: {name}")
    lines.append(f"// Last sync: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"// DO NOT EDIT MANUALLY - edit the Google Sheet and re-sync")
    lines.append("")

    # Header line (row index column + all data columns)
    header_parts = [" " * idx_width]
    for ci, col in enumerate(header_row):
        header_parts.append(col.ljust(col_widths[ci]))
    lines.append("".join(header_parts).rstrip())

    # Data rows
    for ri, row in enumerate(clean_rows):
        row_parts = [str(ri).ljust(idx_width)]
        for ci in range(len(header_row)):
            cell = row[ci] if ci < len(row) else "****"
            row_parts.append(cell.ljust(col_widths[ci]))
        lines.append("".join(row_parts).rstrip())

    return "\n".join(lines) + "\n"


def sync_sheet(name: str, url: str, state: dict) -> bool:
    """
    Downloads one sheet, converts to 2DA, writes file if changed.
    Returns True if file was updated.
    """
    log(f"  Checking {name}.2da ...")

    csv_text = download_csv(url, name)
    if csv_text is None:
        return False

    # Check if content changed since last sync
    cs = checksum(csv_text)
    if state.get(name) == cs:
        log(f"  {name}.2da: unchanged (skipped)")
        return False

    # Convert to 2DA format
    tda_text = csv_to_2da(csv_text, name)
    if not tda_text:
        log(f"  ERROR [{name}]: Conversion produced empty output.")
        return False

    # Write to output directory
    out_path = os.path.join(OUTPUT_DIR, f"{name}.2da")

    if DRY_RUN:
        log(f"  DRY RUN: Would write {out_path}")
        log(f"  --- Preview (first 10 lines) ---")
        for line in tda_text.split("\n")[:10]:
            log(f"  | {line}")
        log(f"  --- End preview ---")
    else:
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        # Atomic write: write to temp file then rename
        tmp_path = out_path + ".tmp"
        with open(tmp_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(tda_text)
        os.replace(tmp_path, out_path)
        log(f"  UPDATED: {out_path}  ({len(tda_text.splitlines())} lines)")

    state[name] = cs
    return True


def run_sync():
    """Run one full sync pass over all configured sheets."""
    log("=" * 60)
    log(f"DOWE Sheets Sync starting  (DRY_RUN={DRY_RUN})")
    log(f"Output directory: {OUTPUT_DIR}")
    log(f"Sheets to sync: {len(SHEET_MAP)}")

    if not os.path.exists(OUTPUT_DIR) and not DRY_RUN:
        log(f"WARNING: Output directory does not exist: {OUTPUT_DIR}")
        log("  Set OUTPUT_DIR to your NWN override folder path.")

    state = load_state()
    updated = []

    for name, url in SHEET_MAP.items():
        if "YOUR_SHEET_ID" in url:
            log(f"  SKIP [{name}]: URL not configured yet (still has YOUR_SHEET_ID)")
            continue
        changed = sync_sheet(name, url, state)
        if changed:
            updated.append(name)

    save_state(state)

    if updated:
        log(f"")
        log(f"SYNC COMPLETE: {len(updated)} file(s) updated: {', '.join(updated)}")
        log(f"")
        log(f"NEXT STEP: In-game, type:  /*reload \"your_password\"")
        log(f"  This reloads all DOWE 2DA caches without server restart.")
        log(f"  Or reload specific files:")
        if "core_package" in updated:
            log(f"    /*reload package \"your_password\"")
        if any(n.startswith("enc_") for n in updated):
            log(f"    (enc hub reloads automatically with /*reload)")
        if any(n.startswith("ai_") for n in updated):
            log(f"    (ai hub reloads automatically with /*reload)")
    else:
        log("SYNC COMPLETE: No changes detected.")

    log("=" * 60)
    return updated


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="DOWE Google Sheets -> 2DA Sync Tool")
    parser.add_argument("--dry-run", action="store_true",
                        help="Preview changes without writing files")
    parser.add_argument("--watch", action="store_true",
                        help=f"Keep running, checking every {POLL_INTERVAL}s")
    parser.add_argument("--force", action="store_true",
                        help="Ignore change detection, re-sync all sheets")
    args = parser.parse_args()

    if args.dry_run:
        DRY_RUN = True

    if args.force:
        log("Force mode: clearing change state.")
        if os.path.exists(STATE_FILE):
            os.remove(STATE_FILE)

    if args.watch:
        import time
        log(f"Watch mode: checking every {POLL_INTERVAL} seconds. Ctrl+C to stop.")
        while True:
            run_sync()
            time.sleep(POLL_INTERVAL)
    else:
        run_sync()
