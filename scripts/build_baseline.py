#!/usr/bin/env python3
"""
build_baseline.py — generates the reviewable Intune-Baseline/ tree and manifest.json
from the raw Microsoft Graph export JSON (and macOS .mobileconfig files) delivered in
MSSP_Intune_Service_Terraform/.

Mirrors the philosophy of the Conditional Access project's tools/generate.py: never
hand-edit the output. If the source pack changes, re-run this script from the repo root.

What it does:
  1. Loads every source file, sniffing UTF-16 vs UTF-8 (the source pack is a mix — see
     RECONCILIATION.md "Encoding" section). This was a real, silent landmine: about 88%
     of the JSON files are UTF-16LE, and a naive `Get-Content -Raw | ConvertFrom-Json`
     or `json.load()` either throws or silently mis-parses them.
  2. Classifies each file by its Graph object shape (@odata.context / @odata.type) into
     one of five buckets — settings_catalog_policy, legacy_device_configuration,
     endpoint_security_intent, compliance_policy, macos_custom_configuration — because
     each bucket deploys through a different Graph endpoint / cmdlet family.
  3. Strips Graph response-only noise (ids, timestamps, @odata.*.associationLink /
     .navigationLink, #microsoft.graph.* action links, assignments, settingCount, etc.)
     recursively, leaving a clean, human-reviewable *request-shaped* JSON body — these
     are the generated artifacts a reviewer should actually read, the equivalent of the
     CA project's policies_*.tf files.
  4. Cross-references CIS_Compliance_Baseline_v2.xlsx's "Compliance Baseline" sheet by
     filename to attach NIST SP 800-53 / ISO 27001 control mappings and the author's own
     production notes to each policy, so that metadata travels with the policy instead of
     living only in a spreadsheet nobody re-opens at deploy time.
  5. Writes:
       Intune-Baseline/<category>/<slug>.json   - one cleaned policy body per file
       Intune-Baseline/manifest.json            - the deploy engine's source of truth
     manifest.json is also what Verify-Deployment.ps1's expected-state diff is built
     from (via build_expected_manifest.py), independently of Deploy-IntuneBaseline.ps1,
     so a bug in the deploy engine can't hide itself from its own verification — same
     reasoning as the CA project's RECONCILIATION.md approach to expected-matrix.json.

Run from the repo root:
    python3 scripts/build_baseline.py
"""
import base64
import glob
import json
import os
import re
import sys

try:
    import openpyxl
except ImportError:
    print("Missing dependency: pip install openpyxl --break-system-packages", file=sys.stderr)
    raise

# Where the ORIGINAL policy JSON pack lives — the input this generator reads.
# Defaults to source-pack/ inside this repo, which is where the shipped copy sits, so a fresh
# clone regenerates with no configuration. Override with INTUNE_SOURCE_ROOT to point at a
# different pack (e.g. a customer-specific fork, or a newer upstream export).
#
# NOTE for anyone reusing this on a new engagement: three files in source-pack/ carry
# corrections made on 2026-09-08 that Graph rejected outright in their original form — the
# webshell ASR rule's enum value, the Quick Machine Recovery password's Secret setting type,
# and the consolidated Device Password policy's over-length description (RECONCILIATION.md
# sections 9, 15, 16). If you point INTUNE_SOURCE_ROOT at an older upstream export, those
# three bugs come back. Diff against source-pack/ before switching.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_ROOT = os.environ.get("INTUNE_SOURCE_ROOT", os.path.join(_REPO_ROOT, "source-pack"))
if not os.path.isdir(SOURCE_ROOT):
    raise SystemExit(
        f"Source policy pack not found at {SOURCE_ROOT}.\n"
        "Expected it at source-pack/ inside this repo (that is where the shipped copy lives).\n"
        "If your pack is elsewhere, set INTUNE_SOURCE_ROOT to its path and re-run, e.g.:\n"
        "  $env:INTUNE_SOURCE_ROOT = 'C:\\path\\to\\MSSP_Intune_Service_Terraform'   # PowerShell\n"
        "  export INTUNE_SOURCE_ROOT=/path/to/MSSP_Intune_Service_Terraform          # bash"
    )
OUT_ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Intune-Baseline")
XLSX_PATH = os.path.join(SOURCE_ROOT, "CIS_Compliance_Baseline_v2.xlsx")

# ---------------------------------------------------------------------------
# Encoding-safe load (Landmine #1 — see RECONCILIATION.md)
# ---------------------------------------------------------------------------

def sniff_encoding(path):
    with open(path, "rb") as f:
        head = f.read(4)
    if head[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return "utf-16"        # generic form auto-detects LE/BE and strips the BOM
    if head[:3] == b"\xef\xbb\xbf":
        return "utf-8-sig"
    return "utf-8"


def load_json(path):
    enc = sniff_encoding(path)
    with open(path, "r", encoding=enc) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

def classify(data):
    ctx = data.get("@odata.context", "")
    odata_type = data.get("@odata.type", "")
    if "compliancePolicies" in ctx:
        return "compliance_policy"
    if "configurationPolicies" in ctx:
        return "settings_catalog_policy"
    if "intents" in ctx:
        return "endpoint_security_intent"
    if "deviceConfigurations" in ctx:
        return "legacy_device_configuration"
    raise ValueError(f"Unrecognized shape: context={ctx!r} type={odata_type!r}")


# ---------------------------------------------------------------------------
# Response-noise stripping — recursive, shape-agnostic
# ---------------------------------------------------------------------------

DROP_EXACT_KEYS = {
    "@odata.context", "@odata.id", "@odata.editLink",
    "id", "createdDateTime", "lastModifiedDateTime", "createdDateTime@odata.type",
    "lastModifiedDateTime@odata.type", "creationSource", "priorityMetaData",
    "settingCount", "supportsScopeTags", "version", "isAssigned",
    "isMigratingToConfigurationPolicy", "assignments",
    "assignments@odata.context",
}
DROP_KEY_SUFFIXES = ("@odata.associationLink", "@odata.navigationLink", "@odata.context")


def clean(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in DROP_EXACT_KEYS:
                continue
            if k.startswith("#"):          # #microsoft.graph.<action> link objects
                continue
            if any(k.endswith(suf) for suf in DROP_KEY_SUFFIXES):
                continue
            out[k] = clean(v)
        return out
    if isinstance(obj, list):
        return [clean(v) for v in obj]
    return obj


# ---------------------------------------------------------------------------
# Framework mapping (from the workbook, keyed by exact filename)
# ---------------------------------------------------------------------------

def load_framework_map():
    wb = openpyxl.load_workbook(XLSX_PATH, data_only=True)
    ws = wb["Compliance Baseline"]
    rows = list(ws.iter_rows(values_only=True))
    header_idx = None
    for i, r in enumerate(rows):
        if r and r[0] == "#":
            header_idx = i
            break
    fmap = {}
    if header_idx is None:
        return fmap
    for r in rows[header_idx + 1:]:
        if not r or r[0] is None or not isinstance(r[0], int):
            continue
        _, policy_name, platform, level, source, domain, nist, iso, notes = (list(r) + [None] * 9)[:9]
        if policy_name:
            fmap[policy_name.strip()] = {
                "platform": platform,
                "cis_level": level,
                "source": source,
                "control_domain": domain,
                "nist_800_53": nist,
                "iso_27001_2022": iso,
                "auditor_notes": notes,
            }
    return fmap


# ---------------------------------------------------------------------------
# Slugging
# ---------------------------------------------------------------------------

# Graph's hard limit on deviceManagementConfigurationPolicy.description — exceeding it
# fails the CREATE with a 400 rather than being trimmed server-side.
DESCRIPTION_MAX_CHARS = 1000


def slugify(name):
    s = re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-")
    s = re.sub(r"-{2,}", "-", s)
    return s[:120]


# Known "landmine" policies that MUST NOT deploy with source defaults — see
# RECONCILIATION.md and CIS_Compliance_Baseline_v2.xlsx "Production Notes & Warnings".
# Keyed by exact source filename (without extension).
CUSTOMER_VALUE_REQUIRED = {
    "Baseline - One Drive management settings": "entra_tenant_id",
    "Baseline - Teams - Restrict sign in to Teams to accounts in specific tenants": "entra_tenant_id",
    "CISv3 - EDGE - L2 - Configure extension management settings": "edge_approved_extension_ids",
    "Baseline - Chrome - Configure extension installation allow list": "chrome_approved_extension_ids",
    "Baseline - Cloud Remediation  quick machine recovery": "quick_machine_recovery_network",
}

# Policies that must ship in audit mode first per the production notes, not the
# source pack's literal recorded value (several ASR "Block" files are misleadingly
# named — the note is what matters, not the filename).
AUDIT_FIRST_RECOMMENDED = {
    "ASR - BLOCK - Enable Controlled Folder Access",
    "Windows-Server-ASR-Enable-Controlled-Folder-Access",
    "Windows-Server-ASR-Block-Webshell-Creation-Exchange",
}


def main():
    os.makedirs(OUT_ROOT, exist_ok=True)
    fmap = load_framework_map()

    manifest = []
    errors = []
    truncated_descriptions = []

    json_files = sorted(glob.glob(os.path.join(SOURCE_ROOT, "**", "*.json"), recursive=True))
    json_files = [f for f in json_files if "CIS_Compliance_Baseline" not in f]

    for path in json_files:
        rel = os.path.relpath(path, SOURCE_ROOT)
        category = rel.split(os.sep)[0]
        base_name = os.path.splitext(os.path.basename(path))[0]
        try:
            data = load_json(path)
            shape = classify(data)
            cleaned = clean(data)
        except Exception as e:
            errors.append((rel, str(e)))
            continue

        # Graph enforces a 1000-character limit on a policy's Description and rejects the
        # whole CREATE with "The field Description must be a string with a maximum length
        # of 1000" — confirmed live, 2026-09-08, on the consolidated Device Password
        # policy (1004 chars, four over). Truncate here at build time rather than letting
        # it halt a deploy run partway through, and say so loudly so the source file gets
        # tightened properly instead of silently losing its tail.
        desc = cleaned.get("description")
        if isinstance(desc, str) and len(desc) > DESCRIPTION_MAX_CHARS:
            cut = desc[:DESCRIPTION_MAX_CHARS - 15].rstrip()
            # back off to the last sentence/line break so the truncation reads cleanly
            for sep in ("\n", ". "):
                idx = cut.rfind(sep)
                if idx > DESCRIPTION_MAX_CHARS // 2:
                    cut = cut[:idx].rstrip()
                    break
            cleaned["description"] = cut + " [truncated]"
            truncated_descriptions.append((rel, len(desc)))

        display_name = cleaned.get("name") or cleaned.get("displayName") or base_name
        slug = slugify(display_name)
        out_dir = os.path.join(OUT_ROOT, category)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, slug + ".json")
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(cleaned, f, indent=2, ensure_ascii=False)
            f.write("\n")

        fw = fmap.get(base_name, {})
        manifest.append({
            "id": slugify(category) + "/" + slug,
            "display_name": display_name,
            "category": category,
            "shape": shape,
            "source_file": rel,
            "source_encoding": sniff_encoding(path),
            "clean_file": os.path.relpath(out_path, OUT_ROOT),
            "requires_customer_value": CUSTOMER_VALUE_REQUIRED.get(base_name),
            "audit_first_recommended": base_name in AUDIT_FIRST_RECOMMENDED,
            "framework": fw,
        })

    # macOS .mobileconfig files — not JSON; wrap whole file as base64 payload.
    mobileconfig_files = sorted(glob.glob(os.path.join(SOURCE_ROOT, "**", "*.mobileconfig"), recursive=True))
    macos_out_dir = os.path.join(OUT_ROOT, "16_Defender_for_Endpoint_macOS")
    os.makedirs(macos_out_dir, exist_ok=True)
    # Deployment order matters — see README_Onboarding_Package.md / Production Notes #33.
    MACOS_DEPLOY_ORDER = [
        "sysext", "netfilter", "fulldisk", "background_services", "notif",
        "accessibility", "bluetooth", "com.microsoft.autoupdate2",
        "com.microsoft.wdav", "firewall",
    ]

    def macos_order_key(path):
        base = os.path.splitext(os.path.basename(path))[0]
        try:
            return MACOS_DEPLOY_ORDER.index(base)
        except ValueError:
            return len(MACOS_DEPLOY_ORDER)

    for path in sorted(mobileconfig_files, key=macos_order_key):
        base_name = os.path.splitext(os.path.basename(path))[0]
        with open(path, "rb") as f:
            raw = f.read()
        payload_b64 = base64.b64encode(raw).decode("ascii")
        out_path = os.path.join(macos_out_dir, base_name + ".payload.b64.txt")
        with open(out_path, "w", encoding="ascii") as f:
            f.write(payload_b64)
        manifest.append({
            "id": "16_Defender_for_Endpoint_macOS/" + base_name,
            "display_name": base_name,
            "category": "16_Defender_for_Endpoint_macOS",
            "shape": "macos_custom_configuration",
            "source_file": os.path.relpath(path, SOURCE_ROOT),
            "source_encoding": "binary/plist-xml",
            "clean_file": os.path.relpath(out_path, OUT_ROOT),
            "payload_file_name": os.path.basename(path),
            "requires_customer_value": None,
            "audit_first_recommended": False,
            "deploy_order": macos_order_key(path),
            "framework": {},
            "notes": (
                "Onboarding package (com.microsoft.wdav.atp / WindowsDefenderATPOnboarding.xml) "
                "is NOT in this pack — it is tenant-specific and must be downloaded fresh per "
                "customer from the Defender portal and deployed LAST. See README_Onboarding_Package.md."
            ) if base_name == "com.microsoft.wdav" else None,
        })

    manifest_path = os.path.join(OUT_ROOT, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump({"policies": manifest, "count": len(manifest)}, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"Wrote {len(manifest)} manifest entries to {manifest_path}")
    print(f"Cleaned policy JSON under {OUT_ROOT}/<category>/")
    if truncated_descriptions:
        print(
            f"\n{len(truncated_descriptions)} DESCRIPTION(S) EXCEEDED GRAPH'S "
            f"{DESCRIPTION_MAX_CHARS}-CHAR LIMIT AND WERE TRUNCATED — tighten the source "
            "file's description so nothing is lost:",
            file=sys.stderr,
        )
        for rel, n in truncated_descriptions:
            print(f"  {rel}: {n} chars", file=sys.stderr)
    if errors:
        print(f"\n{len(errors)} FILE(S) FAILED TO CLASSIFY/PARSE:", file=sys.stderr)
        for rel, err in errors:
            print(f"  {rel}: {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
