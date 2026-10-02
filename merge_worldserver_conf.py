#!/usr/bin/env python3
"""
Merge an existing AzerothCore *.conf into a newly updated *.conf.dist.

Policy:
1) New .dist is always the template and is NEVER modified.
2) Keys found in both files keep the old .conf value.
3) Keys new in .dist keep the new default value.
4) Keys found only in the old .conf are appended to the generated file
   under a clearly marked compatibility/custom section.
5) A merge report is generated next to the output.

Usage:
  python3 merge_worldserver_conf.py \
      /srv/wow/etc/worldserver.conf \
      /srv/wow/etc/worldserver.conf.dist \
      /srv/wow/etc/worldserver.conf.new

Then review the report and, if desired:
  mv /srv/wow/etc/worldserver.conf.new /srv/wow/etc/worldserver.conf
"""

from __future__ import annotations
import argparse
import hashlib
import os
import re
import tempfile
from collections import OrderedDict, defaultdict
from pathlib import Path

ASSIGN_RE = re.compile(
    r'^(\s*)([A-Za-z0-9_.-]+)(\s*=\s*)(.*?)(\r?\n?)$'
)

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def parse_active_assignments(text: str):
    """
    Return:
      last_value[key] = raw RHS from the last active assignment
      occurrences[key] = [(line_no, rhs), ...]
      order = keys in first-seen order
    Commented lines (# / ;) are ignored.
    """
    last_value = OrderedDict()
    occurrences = defaultdict(list)
    order = []

    for lineno, line in enumerate(text.splitlines(keepends=True), 1):
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#") or stripped.startswith(";"):
            continue

        m = ASSIGN_RE.match(line)
        if not m:
            continue

        key = m.group(2)
        rhs = m.group(4).strip()

        if key not in occurrences:
            order.append(key)

        occurrences[key].append((lineno, rhs))
        last_value[key] = rhs

    return last_value, occurrences, order

def main():
    ap = argparse.ArgumentParser(
        description="Merge old AzerothCore .conf values into a new .conf.dist template"
    )
    ap.add_argument("old_conf", help="Existing configured .conf")
    ap.add_argument("new_dist", help="New source-updated .conf.dist")
    ap.add_argument("output", help="Generated merged .conf")
    args = ap.parse_args()

    old_path = Path(args.old_conf).resolve()
    dist_path = Path(args.new_dist).resolve()
    out_path = Path(args.output).resolve()

    if not old_path.is_file():
        raise SystemExit(f"[ERROR] old config not found: {old_path}")
    if not dist_path.is_file():
        raise SystemExit(f"[ERROR] new dist not found: {dist_path}")

    if out_path == dist_path:
        raise SystemExit("[ERROR] output must not overwrite .dist")
    if out_path == old_path:
        raise SystemExit("[ERROR] output must be a new file; do not overwrite old config directly")

    old_hash_before = sha256(old_path)
    dist_hash_before = sha256(dist_path)

    old_text = old_path.read_text(encoding="utf-8", errors="replace")
    dist_text = dist_path.read_text(encoding="utf-8", errors="replace")

    old_values, old_occurrences, old_order = parse_active_assignments(old_text)
    dist_values, dist_occurrences, dist_order = parse_active_assignments(dist_text)

    common = set(old_values) & set(dist_values)
    dist_only = [k for k in dist_order if k not in old_values]
    old_only = [k for k in old_order if k not in dist_values]
    duplicate_old = {
        k: v for k, v in old_occurrences.items() if len(v) > 1
    }

    # Rebuild from the NEW .dist, changing only RHS values for matching keys.
    out_lines = []
    for line in dist_text.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith("#") or stripped.startswith(";"):
            out_lines.append(line)
            continue

        m = ASSIGN_RE.match(line)
        if m and m.group(2) in old_values:
            key = m.group(2)
            newline = m.group(5) or "\n"
            out_lines.append(
                f"{m.group(1)}{key}{m.group(3)}{old_values[key]}{newline}"
            )
        else:
            out_lines.append(line)

    # Preserve settings that no longer exist in the core .dist.
    # These are often module/custom settings. Keeping them avoids silent loss.
    if old_only:
        if out_lines and not out_lines[-1].endswith(("\n", "\r")):
            out_lines[-1] += "\n"

        out_lines.extend([
            "\n",
            "###################################################################################################\n",
            "# PRESERVED SETTINGS FROM PREVIOUS worldserver.conf\n",
            "# These keys do not exist in the new worldserver.conf.dist.\n",
            "# They may be module/custom settings or legacy settings removed/renamed by the new core.\n",
            "# Review the merge report after each source update.\n",
            "###################################################################################################\n",
            "\n",
        ])

        for key in old_only:
            out_lines.append(f"{key} = {old_values[key]}\n")

    out_text = "".join(out_lines)

    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Atomic write.
    fd, tmp_name = tempfile.mkstemp(
        prefix=out_path.name + ".",
        suffix=".tmp",
        dir=str(out_path.parent),
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(out_text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, out_path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise

    # Verify inputs were not modified.
    old_hash_after = sha256(old_path)
    dist_hash_after = sha256(dist_path)
    if old_hash_before != old_hash_after:
        raise SystemExit("[ERROR] old .conf changed unexpectedly")
    if dist_hash_before != dist_hash_after:
        raise SystemExit("[ERROR] .dist changed unexpectedly")

    changed_from_dist = [
        k for k in dist_order
        if k in old_values and old_values[k] != dist_values[k]
    ]

    report_path = out_path.with_name(out_path.name + ".merge_report.txt")
    with report_path.open("w", encoding="utf-8") as f:
        f.write("AzerothCore configuration merge report\n")
        f.write("=" * 72 + "\n")
        f.write(f"Old config : {old_path}\n")
        f.write(f"New dist   : {dist_path}\n")
        f.write(f"Output     : {out_path}\n\n")

        f.write(f"Old active keys             : {len(old_values)}\n")
        f.write(f"New .dist active keys       : {len(dist_values)}\n")
        f.write(f"Values inherited from old   : {len(common)}\n")
        f.write(f"Old values differing from new defaults: {len(changed_from_dist)}\n")
        f.write(f"New keys kept at new default: {len(dist_only)}\n")
        f.write(f"Old-only keys preserved     : {len(old_only)}\n")
        f.write(f"Duplicate keys in old conf  : {len(duplicate_old)}\n\n")

        if dist_only:
            f.write("[NEW KEYS - NEW .dist DEFAULT KEPT]\n")
            for k in dist_only:
                f.write(f"  {k}\n")
            f.write("\n")

        if old_only:
            f.write("[OLD-ONLY KEYS - APPENDED TO GENERATED CONFIG]\n")
            for k in old_only:
                f.write(f"  {k}\n")
            f.write("\n")

        if duplicate_old:
            f.write("[DUPLICATE KEYS IN OLD CONFIG - LAST ACTIVE VALUE USED]\n")
            for k, entries in duplicate_old.items():
                lines = ", ".join(str(n) for n, _ in entries)
                f.write(f"  {k}: lines {lines}\n")
            f.write("\n")

        f.write("[INPUT FILE INTEGRITY]\n")
        f.write(f"  old .conf sha256 unchanged : {old_hash_before}\n")
        f.write(f"  new .dist sha256 unchanged : {dist_hash_before}\n")

    print("[OK] merge completed")
    print(f"[OK] generated : {out_path}")
    print(f"[OK] report    : {report_path}")
    print(f"[OK] .dist left untouched")
    print(f"[INFO] inherited old values : {len(common)}")
    print(f"[INFO] new defaults kept     : {len(dist_only)}")
    print(f"[INFO] old-only preserved    : {len(old_only)}")
    if duplicate_old:
        print(f"[WARN] duplicate old keys    : {len(duplicate_old)} (last active value used)")

if __name__ == "__main__":
    main()
