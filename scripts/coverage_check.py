#!/usr/bin/env python3
"""
coverage_check.py — walks every field in every source policy JSON and flags anything that
disappeared during cleaning that ISN'T on the explicit drop list in build_baseline.py.

Run after any change to build_baseline.py's cleaning rules, before trusting its output —
same purpose as the CA-Baseline project's tools/coverage_check.py: catch a generator bug
(a field silently dropped that should have been kept) rather than discover it at deploy time.

This is a coverage check on KEYS, not values — it confirms every meaningful key that
appeared in the source survives into the cleaned file under the same name, not that the
value round-tripped exactly (build_baseline.py's `clean()` is a pure structural filter and
doesn't rewrite values, so if the key survives, the value did too).
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_baseline import (  # noqa: E402
    SOURCE_ROOT, OUT_ROOT, DROP_EXACT_KEYS, DROP_KEY_SUFFIXES, load_json,
)

EXPECTED_DROPS = DROP_EXACT_KEYS | {"assignments"}


def is_dropped_key(k):
    if k in EXPECTED_DROPS:
        return True
    if k.startswith("#"):
        return True
    if any(k.endswith(suf) for suf in DROP_KEY_SUFFIXES):
        return True
    return False


def find_unexplained_drops(obj, unexplained, path=""):
    """Walks the SOURCE tree only. At each dict, any key not explained by a drop rule is
    expected to survive into the cleaned output — we don't need the cleaned tree at all,
    just build_baseline.py's own drop predicate applied at the point of decision, so a key
    living inside an already-dropped branch (e.g. 'title'/'target' inside a dropped
    '#microsoft.graph.assign' action-link object) is never even considered."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if is_dropped_key(k):
                continue  # this key (and everything under it) is *meant* to disappear
            find_unexplained_drops(v, unexplained, f"{path}.{k}")
    elif isinstance(obj, list):
        for v in obj:
            find_unexplained_drops(v, unexplained, path + "[]")


def main():
    json_files = sorted(glob.glob(os.path.join(SOURCE_ROOT, "**", "*.json"), recursive=True))
    json_files = [f for f in json_files if "CIS_Compliance_Baseline" not in f]

    from build_baseline import clean  # local import to keep drop predicate + clean() honest against drift

    unexplained_drops = []
    for path in json_files:
        try:
            data = load_json(path)
        except Exception:
            continue  # build_baseline.py already surfaces parse errors
        cleaned = clean(data)
        cleaned_keys = set()

        def collect(o):
            if isinstance(o, dict):
                for k, v in o.items():
                    cleaned_keys.add(k)
                    collect(v)
            elif isinstance(o, list):
                for v in o:
                    collect(v)
        collect(cleaned)

        expected_to_survive = []
        find_unexplained_drops(data, expected_to_survive)

        def check(o):
            if isinstance(o, dict):
                for k, v in o.items():
                    if not is_dropped_key(k) and k not in cleaned_keys:
                        unexplained_drops.append((os.path.relpath(path, SOURCE_ROOT), k))
                    if not is_dropped_key(k):
                        check(v)
            elif isinstance(o, list):
                for v in o:
                    check(v)
        check(data)

    if unexplained_drops:
        print(f"{len(unexplained_drops)} UNEXPLAINED KEY DROP(S) — review build_baseline.py's clean():\n")
        for rel, k in unexplained_drops:
            print(f"  {rel}: dropped '{k}'")
        sys.exit(1)

    print(f"Coverage check passed: every field in {len(json_files)} source files is either "
          f"kept in the cleaned output or on the explicit drop list.")


if __name__ == "__main__":
    main()
