# Reconciliation Notes

Honest record of what this toolkit does, the landmines it had to work around, and — most
importantly — what has NOT been verified against a live tenant yet. Same purpose as the
CA-Baseline project's `RECONCILIATION.md`: a reviewer or a future engagement shouldn't have
to re-derive any of this from the code.

## 1. Source pack encoding

88% of the source JSON files (188 of 212) are UTF-16LE, the rest UTF-8. `Get-Content -Raw |
ConvertFrom-Json` or a naive `json.load(open(path))` either throws or silently mis-parses the
UTF-16 files. `scripts/build_baseline.py`'s `sniff_encoding()` reads the first 4 bytes of each
file, checks for a UTF-16 BOM (`\xff\xfe` / `\xfe\xff`) or a UTF-8 BOM (`\xef\xbb\xbf`), and
picks Python's generic `"utf-16"` codec (not the explicit `"utf-16-le"`) so the BOM is stripped
automatically rather than left as a stray `U+FEFF` before the opening `{`. Every source file's
detected encoding is recorded per-policy in `manifest.json`'s `source_encoding` field, so this
is auditable rather than assumed.

## 2. Five Graph object shapes, one generator

The 222 policies classify into 5 buckets by `@odata.context` (see `classify()` in
`build_baseline.py`):

| Shape | Count | Graph endpoint | Notes |
|---|---|---|---|
| `settings_catalog_policy` | 202 | `deviceManagement/configurationPolicies` | Majority of the pack |
| `macos_custom_configuration` | 10 | `deviceManagement/deviceConfigurations` (`macOSCustomConfiguration`) | Source files are `.mobileconfig`, not JSON — see §5 |
| `legacy_device_configuration` | 7 | `deviceManagement/deviceConfigurations` | Older custom-profile shape |
| `endpoint_security_intent` | 2 | `deviceManagement/intents` | Account Protection, BitLocker — see §6 |
| `compliance_policy` | 1 | `deviceManagement/compliancePolicies` | Linux Device Encryption — see §7 |

Rather than hand-converting 222 files across 5 shapes (impractical given source payloads up
to 254KB, and there's no Terraform-plan-diff benefit to gain from inlining each one as a
static resource block the way CA-Baseline did for Conditional Access policies), one generic
cleaner (`clean()`) strips Graph response-only/read-only fields recursively and shape-agnostically:

- Exact keys dropped: `@odata.context`, `@odata.id`, `@odata.editLink`, `id`,
  `createdDateTime`, `lastModifiedDateTime` (+ their `@odata.type` companions),
  `creationSource`, `priorityMetaData`, `settingCount`, `supportsScopeTags`, `version`,
  `isAssigned`, `isMigratingToConfigurationPolicy`, `assignments`,
  `assignments@odata.context`.
- Suffix-matched keys dropped at any depth: anything ending `@odata.associationLink`,
  `@odata.navigationLink`, or `@odata.context` (field-prefixed variants like
  `settings@odata.context` needed the suffix rule — an exact-key-only match missed them on
  the first pass; see §9).
- Any key starting `#` (a `#microsoft.graph.<action>` action-link object) is dropped
  entirely, including everything nested under it.

The result is a clean, human-reviewable *request-shaped* JSON body per policy — the
generated artifact a reviewer actually reads, equivalent to CA-Baseline's `policies_*.tf`.

## 3. Coverage check

`scripts/coverage_check.py` walks every source file's field tree and flags any key that (a)
was not on the explicit drop list above and (b) doesn't survive into the cleaned output —
catching a generator bug (a field silently lost that should have been kept) before it's
discovered at deploy time, same purpose as CA-Baseline's own `tools/coverage_check.py`.

**Fixed during this build**: the first implementation did a blind key-set collection across
the entire raw source tree, then diffed it against the cleaned tree's key set. That produced
422 false positives — generic key names like `title` and `target` that exist *only* nested
inside `#microsoft.graph.*` action-link objects (e.g.
`{"title": "microsoft.graph.assign", "target": "https://graph.microsoft.com/..."}`), which
`clean()` correctly drops in their entirety because the parent key starts with `#`. The blind
collector still gathered those nested key names as if they were meaningful top-level content
expected to survive, then flagged their absence as a drop. Fixed by rewriting the walker to
use `clean()`'s own `is_dropped_key()` predicate and only recurse into a key's children when
that key itself was not dropped — so contents of an already-dropped branch are never
considered "expected to survive" in the first place. Current run: **0 unexplained drops
across 212 source files.**

## 4. Framework mapping coverage

164 of 222 policies (74%) carry a NIST 800-53 / ISO 27001:2022 / CIS control mapping, pulled
from `CIS_Compliance_Baseline_v2.xlsx`'s "Compliance Baseline" sheet by exact source filename
match. The 58 without a mapping are concentrated in: category 01 Defender for Endpoint (14),
category 11 Edge CIS Benchmark (11), category 16 macOS Defender (10 — the `.mobileconfig`
files were never in the mapping sheet to begin with), category 02 Windows CIS Hardening (5),
and smaller counts elsewhere. These aren't unmapped by omission from this generator — the
source workbook itself doesn't have entries for them. Confirm with the customer's compliance
lead whether that's expected before treating framework coverage claims as complete for an
audit.

## 5. macOS deployment (category 16)

The 10 macOS profiles are `.mobileconfig` (plist XML), not JSON, so `build_baseline.py`
handles them separately: each is base64-encoded whole into a `.payload.b64.txt` file (no
attempt to parse or clean the plist — Apple's format, left byte-for-byte intact) and given a
`deploy_order` field in the manifest per the fixed sequence in `MACOS_DEPLOY_ORDER` (sysext →
netfilter → fulldisk → background_services → notif → accessibility → bluetooth → autoupdate →
`com.microsoft.wdav` → firewall) — **not** alphabetical, per
`README_Onboarding_Package.md` and Production Note #33 in the source workbook.

The Defender for Endpoint onboarding package itself
(`WindowsDefenderATPOnboarding.xml`/`com.microsoft.wdav.atp`) is deliberately **not** in this
pack — it's tenant-specific, generated per-customer from the Defender portal, and must be
downloaded fresh and deployed last, after every other macOS profile. The manifest entry for
`com.microsoft.wdav` carries a `notes` field pointing back to
`README_Onboarding_Package.md` so this isn't silently forgotten mid-engagement.

## 6. Endpoint Security intents — least-exercised path

Only 2 policies (Account Protection, BitLocker) use the `deviceManagement/intents` shape. Graph's
create flow for intents is create-then-`updateSettings` (create the intent shell, then PATCH
its settings in a second call) rather than the single-POST pattern every other shape uses.
`deploy/Deploy-IntuneBaseline.ps1`'s `Deploy-EndpointSecurityIntent` function implements this
two-step flow from the documented Graph contract, but **it is the least-verified deploy path
in this toolkit** — with only 2 source examples to derive the shape from and no live-tenant
run yet, budget extra time on first deploy specifically for these two policies.

## 7. Compliance policy — reporting only, not enforcement

The one `compliance_policy` entry (Linux Device Encryption) is a Graph **compliance** policy,
not a configuration/enforcement policy — it reports whether a device is encrypted, it does
not enforce encryption itself (Production Note #24 in the source workbook). Don't represent
this policy to a customer as "enforces disk encryption on Linux" — it's a visibility control,
and pairing it with an actual enforcement mechanism (e.g. a Linux MDM config profile or a
fleet management tool) is a separate decision outside this pack's scope.

## 8. Customer-specific "landmine" values

Four policies contain a placeholder in the source pack that does something wrong (or nothing)
if deployed as-is:

| Policy | Placeholder value's problem | Config key |
|---|---|---|
| OneDrive tenant restriction | Blocks OneDrive entirely for every tenant except the one hardcoded in the source file, unless replaced with the customer's own Entra tenant ID | `EntraTenantId` |
| Teams tenant restriction | Same failure mode, for Teams sign-in | `EntraTenantId` |
| Edge extension management (CIS L2) | Ships with an empty/wildcard allow list — depending on how Edge interprets it, this can silently block every extension the customer's users currently rely on | `EdgeApprovedExtensionIds` |
| Chrome extension allow list | Same failure mode as Edge, for Chrome | `ChromeApprovedExtensionIds` |
| Cloud Remediation / quick machine recovery | Ships with placeholder WiFi SSID/password text — non-functional recovery network, not a Graph error | `QuickMachineRecoverySsid` / `QuickMachineRecoveryPassword` (optional — see §15) |

`config/Test-CustomerConfig.ps1` refuses to proceed if any of the first four are missing or
still hold the placeholder value from `customer.config.psd1.example`, throwing an error that
names the specific production note it corresponds to. The fifth (Quick Machine Recovery) is
opt-in per engagement and only warns, per §15.

**§14 is the important one to read here**: all four of the original substitutions above were
confirmed, 2026-09-08, to have never actually applied on the first live deploy run — a separate
id-format bug in `Patch-CustomerSpecificValues` meant every one of them silently no-opped. See
§14 for the full account and what to re-verify in the portal after the fix.

**Honesty note on the Edge patch specifically**: the Edge extension-management policy's
source JSON stores its value as a literal `"*"` string. The Microsoft-documented
`ExtensionSettings` JSON-map schema `Patch-CustomerSpecificValues` builds from
`EdgeApprovedExtensionIds` is inferred from Microsoft's general Edge policy documentation,
not observed directly in this source file (there was nothing to observe — the source value is
a wildcard, not an example of the populated schema). **This has not been verified against a
live tenant.** Confirm the patched value renders correctly in the Intune portal / on a test
device before relying on it for a real customer.

## 9. Audit-mode-first policies

Three policies carry `audit_first_recommended: true` in the manifest, per Production Notes
#17/#29/#30: two Controlled Folder Access variants (client + Windows Server) and the
constructed webshell ASR rule for Exchange. Several of these are misleadingly named "BLOCK"
in the source file name even though the recommendation is audit-mode first — the manifest
flag reflects the production note, not the filename.

`deploy/Deploy-IntuneBaseline.ps1`'s `Set-AuditModeIfFlagged` implements this as a targeted
regex substitution on the ASR action enum value, deliberately narrow (an explicit list of
known encodings, not a generic ASR-family mode-flipper) to avoid overclaiming certainty about
how the enum is encoded across every ASR rule shape.

**Update, 2026-09-08 — confirmed against a live tenant, first deploy run:** this caution paid
off immediately. The constructed Windows Server webshell ASR rule
(`Windows-Server-ASR-Block-Webshell-Creation-Exchange`, flagged `⚠ CONSTRUCTED` in its own
`auditor_notes` — never present in the original source repo, hand-built from the documented
ASR rule GUID) shipped with a numeric choice value (`..._1`) that Graph rejected outright with
a 400, whose error body helpfully listed the actual valid options for that setting:
`_off` / `_block` / `_audit` / `_warn` — a **word-based** encoding, not the numeric one the
two Controlled Folder Access variants use. This wasn't a value the audit-mode substitution
regex could have flipped correctly either way, since it doesn't match the numeric pattern —
the source JSON itself was wrong, unrelated to the block/audit question.

Fixed: the source JSON (in the uploaded source pack, not hand-edited under `Intune-Baseline/`
— regenerated via `build_baseline.py` per the project's usual discipline) now records
`..._block`, and `Set-AuditModeIfFlagged` gained a second, explicit substitution
(`blockwebshellcreationforservers_block"` → `..._audit"`) alongside the numeric one. Confirm
in the Intune portal after re-deploying that this policy now shows "Audit," and that the two
Controlled Folder Access variants (the numeric-encoding path, unaffected by this fix) also
show "Audit" as expected — those two are still unverified in the sense that they simply
haven't errored yet, not that they've been confirmed correct in the portal.

## 10. Other unverified-against-a-live-tenant assumptions (summary)

For a quick pre-engagement checklist, everything in this toolkit that was derived from
documentation/source-JSON-shape rather than exercised against a real tenant:

1. §6/§17 — Endpoint Security intents. **CONFIRMED WORKING LIVE, 2026-09-08.** Both intents
   (Account Protection, BitLocker) created successfully via
   `POST /deviceManagement/templates/{templateId}/createInstance` and were found present and
   correctly assigned by `Verify-Deployment.ps1` against the live tenant. This closes the
   longest-standing unverified item in this file: the intents' older
   `definitionId`/`valueJson` `settingsDelta` payload format is accepted by Graph as this pack
   records it. Their SEMANTIC correctness (that the BitLocker/Account Protection settings say
   what the customer wants) is a separate portal review, still worth doing once.
2. §8 — Edge `ExtensionSettings` JSON patch schema. Still unverified.
3. §9/§18 — ASR audit-mode enum substitution. **Superseded — see §18.** The numeric
   `_actiontype_1`/`_actionmode_1` encoding described here turned out not to exist anywhere in
   this pack; the substitution matched nothing and has been removed. Real encodings are ASR
   word suffixes (`_block`/`_audit`) and the `EnableControlledFolderAccess` integer enum
   (`_1` block / `_2` audit). All 3 flagged policies are now correctly governed in both
   directions. Still unverified: that they render as "Audit" in the portal, not merely that
   the right value was sent.
4. §12 — Mixed include+exclude `assignments` body (break-glass exclusion layered onto every
   assignment, whichever tier's group is the inclusion target) — Microsoft's documented
   pattern, and the first live run deployed 71 policies this way without a Graph error before
   stopping on the unrelated §9 issue, so the *shape* of the request is confirmed workable;
   the exclusion side specifically (does the break-glass group actually show as excluded in
   the portal) is still unverified.
5. §12 — The 2-policy Linux exception list (`$LinuxSpecificPolicyIds` in
   `Deploy-IntuneBaseline.ps1`) is hand-verified against the current source pack's naming, not
   schema-driven — manifest.json has no explicit per-policy platform field.
6. §12 — **Confirmed, 2026-09-08**: `terraform/groups.tf` and `variables.tf` ran cleanly
   through a real `terraform init` / `plan` / `apply` on a live tenant — 6 groups created, plan
   output matched what the deploy guide predicted, `terraform output assignment_group_ids`
   returned real object IDs with the `*_dynamic` keys correctly `null`. No `terraform validate`
   issues surfaced. This item is resolved; kept here as the record of when it was confirmed.
7. §13 — **Confirmed and fixed, 2026-09-08**: `Deploy-SettingsCatalogLike`'s UPDATE path (re-
   running the deploy against an already-created Settings Catalog / compliance policy) PATCHed
   `settings` directly and Graph rejected it outright (navigation property PATCH isn't
   supported for this resource type — a Graph-wide limitation, not a bug in this pack's data).
   Fixed by switching that path to create-new/assign/delete-old. `compliancePolicies`
   specifically has not yet had a policy reach its own UPDATE branch to confirm it fails/is
   fixed identically to `configurationPolicies` — treat as likely-but-unconfirmed until one
   does.
8. §14 — **Serious bug, confirmed and fixed, 2026-09-08**: `Patch-CustomerSpecificValues`'s
   four id-matching switch cases used the wrong (underscored) category-segment format and
   silently never matched on the first live run — every OneDrive/Teams/Edge/Chrome policy
   already deployed went out with source-pack placeholder values, not this customer's real
   ones, with no error at all. Fixed by correcting all four keys to the real hyphenated id
   format. **Action required, not just informational**: re-check these four policies in the
   Intune portal after the next run to confirm the real values actually landed — see §14.
9. §17/§18 — **Found and fixed offline, 2026-09-08, before ever being hit in a run**:
   endpoint security intent creation used an undocumented endpoint and could not have worked;
   the audit-mode override silently governed only 1 of its 3 flagged policies and its
   promote-to-block direction was a no-op; `Verify-Deployment.ps1` opened its own delegated
   Graph connection conflicting with the deploy script's app-only one; the Chrome Site
   Isolation policy had an unpatched `<YOURSITE>` placeholder. All fixed and covered by the
   offline replay harness described in §18.
10. §15 — **Confirmed and fixed, 2026-09-08**: Cloud Remediation / Quick Machine Recovery's
   network password setting needed `SecretSettingValue` (with `valueState`), not `StringSettingValue`
   — confirmed against both the live Graph 400 and the `RemoteRemediation` CSP's own Microsoft
   Learn reference. Source JSON corrected and regenerated; the policy also gained a proper
   (optional) customer-value slot for a real recovery-network SSID/password.

None of these are guesses made up from nothing — all ten were built from Microsoft's or
HashiCorp's documented contracts and the actual source JSON shapes — but "documented" and
"exercised against a live tenant" are different levels of confidence, and this list exists so
that difference isn't lost as each item moves from assumption to confirmed (or confirmed
broken and fixed, per §9) over the course of this project's first live-tenant run.

## 11. Coverage-check-only scope, and value round-trip

`coverage_check.py` verifies structural coverage — that a key from source either survives
into the cleaned output or is on the explicit, reviewed drop list. It does not independently
re-verify that values round-trip unchanged, but this is safe by construction: `clean()` is a
pure structural filter (drop or keep, recursively) that never rewrites a value it keeps — so
if a key survives, its value survived byte-for-byte with it.

## 12. Rollout model (Pilot -> Static -> Dynamic) — design history

Originally `terraform/groups.tf` created the three OS-type target groups
(`Intune-Target-WindowsWorkstations`/`-macOS`/`-Linux`) as dynamic-membership groups from the
moment `terraform apply` ran, with `Intune-PilotRing` scoped only to the 3
`audit_first_recommended` policies. That meant the first `terraform apply` for a category like
02 (Windows CIS hardening) would auto-populate every matching Windows device in the tenant
immediately — no soft rollout at all — and `Intune-Target-Linux` / `Intune-PilotRing` /
`Intune-Excl-BreakGlass` were created but never actually referenced by
`Deploy-IntuneBaseline.ps1`'s assignment logic (only WindowsWorkstations/WindowsServers/MacOS
were wired in).

This was corrected to the three-tier model documented in `README.md` "Rollout model": every
policy assigns to `Intune-PilotRing` by default (`-RolloutStage Pilot`), then to a static
per-platform group (`-RolloutStage Static`, manually expanded over an agreed soak period), then
to a dynamic per-platform group (`-RolloutStage Dynamic`, provisioned only once a
`terraform.tfvars` flag is flipped). Two implementation details worth recording:

- **Why the Dynamic tier is a second group, not the static one promoted in place.** The
  `hashicorp/azuread` provider's `azuread_group` resource marks its `types` argument (what
  turns `DynamicMembership` on) as `ForceNew` — read directly from the provider's
  `internal/services/groups/group_resource.go` on GitHub, not assumed. Flipping `types` on an
  *existing* group would make Terraform destroy and recreate it, which would silently orphan
  every Intune policy assignment pointing at the old group's object ID (Graph assignments
  reference a group by ID, not name). Provisioning `Intune-Target-<Platform>-Dynamic` as a
  separate resource, gated by `count = var.<platform>_dynamic ? 1 : 0`, avoids that entirely —
  this is the one part of this section that's verified against the provider's actual source,
  not an assumption.
- **The Linux exception list.** Categories 01 and 06 mix Windows and Linux policies under a
  Windows-titled category (01 is literally "...(Windows + Linux)"). manifest.json has no
  per-policy platform field, so `Deploy-IntuneBaseline.ps1` hardcodes the two policy IDs that
  are actually Linux-scoped (`Baseline-Defender-for-Endpoint-Linux`,
  `Baseline-Linux-Device-Encryption`) rather than deriving it from the manifest schema. This
  was cross-checked against `terraform/groups.tf`'s own original description of the Linux
  group's purpose ("Linux Defender baseline and the Linux Device Encryption COMPLIANCE
  policy"), so it's not a guess, but it is a hand-maintained list — re-verify it if the source
  pack is ever regenerated with additional or renamed Linux policies.

## 13. Settings Catalog / compliance policy updates — recreate, not PATCH

Confirmed live, 2026-09-08, on the second deploy run (the one re-run after the §9 webshell-ASR
fix): `Deploy-SettingsCatalogLike` (used for both `settings_catalog_policy` and
`compliance_policy` shapes — the bulk of the 212-policy pack) originally PATCHed the full policy
body, including `settings`, straight onto `configurationPolicies('{id}')` /
`compliancePolicies('{id}')` when an existing policy by that name was found. The very first time
that code path actually ran — every earlier run had only ever hit the CREATE branch — Graph
rejected it:

```
PATCH .../configurationPolicies('{id}')
400 ModelValidationFailure: Cannot apply PATCH to navigation property 'settings' on entity type
'microsoft.management.services.api.deviceManagementConfigurationPolicy'.
```

This is not specific to this script or this policy — it's a documented, still-open Graph
limitation: `settings` is a navigation property (a collection relationship), and Graph does not
support replacing a navigation property's contents through a PATCH on its parent. Verified
against Microsoft's own "Update deviceManagementConfigurationPolicy" reference (the documented
request body has `name`/`description`/`platforms`/`technologies`/`roleScopeTagIds`/etc. — no
`settings`) and against `microsoftgraph/powershell-intune-samples#286`, where Microsoft Graph
engineers confirm the same error for the same resource type with no supported settings-PATCH
workaround offered. This is a materially different bug from the §9 webshell issue: §9 was a bad
*value* inside a correctly-shaped request; this is the request *shape* itself being
unsupported by Graph for this resource type, and it could only ever surface once a
previously-created policy was deployed a second time with the UPDATE branch actually exercised.

**Fix:** `Deploy-SettingsCatalogLike`'s update path is now create-new -> assign -> delete-old,
instead of PATCH. Create happens first specifically so a failed create never leaves the tenant
without the policy at all; the old copy is only deleted after the new one is confirmed created
and assigned. This mirrors the endpoint-security-intent path's existing pattern of never trying
to PATCH settings directly (intents instead use the documented `/updateSettings` action with a
`settingsDelta` body — a real Graph action that simply doesn't have an equivalent for
`configurationPolicies`/`compliancePolicies`).

Known edge case, left in as a code comment: if the script is interrupted between the create and
the delete (network blip, Ctrl+C, the assign call itself throwing), both the old and new copies
of that one policy exist under the same name until the next run — which will delete whichever
one `Get-ExistingByName` happens to return first, and can leave a true orphan/duplicate behind
in rare cases. Given `$ErrorActionPreference = 'Stop'` halts the whole run on any failure
anyway, this is judged acceptable, but worth checking the portal for a duplicate name on that
one specific policy if a run is ever interrupted mid-update rather than mid-create.

Not yet re-verified: whether `compliancePolicies` (the other consumer of
`Deploy-SettingsCatalogLike`) behaves identically to `configurationPolicies` under this same
fix — no compliance policy in this pack had reached its UPDATE branch as of this write-up, only
`configurationPolicies` has been confirmed live.

## 14. Customer-value patching silently never ran — id format mismatch

**Serious, confirmed 2026-09-08.** `Patch-CustomerSpecificValues`'s `switch ($Id)` cases were
written with underscored category segments, e.g.
`"05_Tenant_and_Account_Access_Control/Baseline-One-Drive-management-settings"`. The real
`$Policy.id` value — generated by `build_baseline.py`'s `slugify()`, which collapses every run
of non-alphanumeric characters (including `_`) to a single `-` — is actually
`"05-Tenant-and-Account-Access-Control/Baseline-One-Drive-management-settings"` (hyphenated).
These never matched. All four of the original customer-value substitutions —
`EntraTenantId` into the OneDrive and Teams tenant-restriction policies, `EdgeApprovedExtensionIds`
and `ChromeApprovedExtensionIds` into their respective extension allow-lists — silently fell
through to the function's default `return $Body` (unchanged) for the entire first deploy run,
with no error, warning, or any other signal that the patch never applied. This was found while
adding a fifth case (§ below) and manually checking whether the existing four would actually
fire — they would not have been caught by simply re-running the deploy, since a silent no-op
produces no error to surface.

**Real-world impact of this bug, as deployed:** every policy already created on this tenant
under categories 05 (OneDrive tenant restriction, Teams tenant restriction), 11 (Edge extension
management), and 13 (Chrome extension allow-list) went out with the *source pack's placeholder
values* — tenant ID `00000000-0000-0000-0000-000000000000`, and `"*"` blocked with zero
approved extensions — not this customer's real Entra tenant ID or approved extension IDs,
regardless of what was actually entered in `customer.config.psd1`. Per Production Notes #1,
#14, #21, #23 this is exactly the HIGH-risk failure mode `Test-CustomerConfig.ps1` was built to
prevent — except the prevention only covers the config file being wrong, not the deploy script
silently failing to use a config file that was right. This is precisely what Pilot Ring exists
to catch before Static/Dynamic promotion; nothing outside Pilot Ring was exposed to this.

**Fix:** all four switch keys corrected to the real hyphenated id format, verified directly
against `Intune-Baseline/manifest.json`'s actual `id` values (not re-derived by hand) for every
`requires_customer_value` entry. The four `Set-JsonLeafValue -DefinitionIdSuffix` values
themselves were also independently re-checked against the real source JSON for each of the
four policies — confirmed present, and confirmed collection vs. single-value matches each
policy's actual `simpleSettingCollectionValue` vs `simpleSettingValue` shape — since this bug
means none of the four had ever actually been exercised end-to-end before now either.

**What this means for you before promoting past Pilot:** once this fix is deployed and the
script re-run, the OneDrive/Teams/Edge/Chrome policies will show `UPDATE (recreate)` and pick up
the real values from `customer.config.psd1` for the first time. Re-verify in the Intune portal
(Devices > Configuration) that the OneDrive and Teams policies show the real tenant ID and that
the Edge/Chrome extension lists show the real approved extension IDs, not `00000000-...` / an
empty allow-list — don't assume the fix worked just because the run completes without error,
given that's exactly how this bug hid for the entire first run.

## 15. Cloud Remediation / Quick Machine Recovery — Secret setting type + optional customer value

Confirmed live, 2026-09-08: `Baseline - Cloud Remediation / quick machine recovery` (category
14) failed on CREATE with `Simple Setting has unexpected value. Expected value type Secret does
not match actual value type String` for
`..._networkcredentials_networkpassword`. Verified against the `RemoteRemediation` CSP's own
Microsoft Learn reference: `NetworkPassword` is documented as the sensitive/password node of
the four under `NetworkSettings/NetworkCredentials` (`NetworkSSID`, `NetworkPassword`,
`NetworkPasswordEncryptionStore`, `NetworkPasswordEncryptionType`) — the Settings Catalog
schema requires it as `#microsoft.graph.deviceManagementConfigurationSecretSettingValue` (with
a `valueState`), not the plain `StringSettingValue` the source file had it as.

Separately, and not itself a Graph error: the source file's placeholder text was also
mismatched between fields — `networkpassword` held the string `"<YOUR WIFI NETWORK>"` (an SSID-
shaped placeholder) and `networkpasswordencryptionstore` held `"<YOUR WIFI PASSWORD>"` — almost
certainly a copy-paste slip while the source pack was assembled. Corrected the true source JSON
to: `networkpassword` → `SecretSettingValue` type, `valueState: "notEncrypted"`, placeholder
text `"<YOUR WIFI PASSWORD>"`; `networkpasswordencryptionstore` → placeholder text noting it's
unused at this policy's shipped `NetworkPasswordEncryptionType` (`_2`, "encrypt using MDM
certificate" — the store node only matters for `_3`, "custom certificate"). Regenerated
`Intune-Baseline/` via `build_baseline.py` + `coverage_check.py`.

This policy embeds a real customer WiFi network's SSID and password so devices can join it
during offline recovery — genuinely customer-specific, in the same class as `EntraTenantId` and
the extension allow-lists (§14), so it was added to `build_baseline.py`'s
`CUSTOMER_VALUE_REQUIRED` map (`requires_customer_value: "quick_machine_recovery_network"`) and
given a `Patch-CustomerSpecificValues` case keyed on the corrected id format. Deliberately
**not** added to `Test-CustomerConfig.ps1`'s hard-required checks — unlike OneDrive/Teams/Edge/
Chrome, this feature is opt-in per engagement, not something every customer needs configured,
so leaving `QuickMachineRecoverySsid`/`QuickMachineRecoveryPassword` unset only produces a
`Write-Warning` at deploy time, not a hard stop.

## 16. Graph's 1000-character description limit

Confirmed live, 2026-09-08: `Baseline - Device Password Policy (Consolidated)` failed CREATE
with `dCV2Policy.Description : The field Description must be a string with a maximum length of
1000` — its description was 1004 characters, four over. Graph rejects the whole request rather
than trimming server-side.

Two changes, deliberately both:

1. **The source file was tightened**, not truncated — the description was reworded down to 962
   characters with every one of its seven CIS values and its full rationale intact. That
   description exists to explain why six separate source policies were consolidated into one
   (see §2), so losing its tail to an automated cut would have destroyed the actual reason the
   file exists.
2. **`build_baseline.py` now enforces the limit at build time** (`DESCRIPTION_MAX_CHARS`),
   truncating anything over it at a sentence or line boundary, appending ` [truncated]`, and
   printing a loud stderr warning naming the file and its real length. This is a backstop for
   future source packs, not the preferred fix — the warning exists specifically so the source
   file gets tightened by hand (as in point 1) rather than quietly shipping a cut-off
   description.

A full scan of the generated pack after this fix found no other field near a Graph length
limit: longest `name` is 123 chars, longest `displayName` 74, longest `description` now 962. So
this specific class of failure is cleared for the current source pack, not just for the one
policy that happened to surface it.

## 17. Endpoint security intents were never creatable as written

Found 2026-09-08 during an offline pre-flight audit — **not** by hitting it in a deploy run,
because this pack's two intents (`Baseline - Account Protection`, `Baseline - Bitlocker
Policy`) sit late enough in the order that no run had reached them yet.

`Deploy-EndpointSecurityIntent` created an intent with `POST /deviceManagement/intents`,
passing `templateId` as a body property. That is not a documented create path for this
resource — Microsoft's documented way to create an endpoint security intent is the
`createInstance` action on the **template** the intent derives from:

```
POST /deviceManagement/templates/{templateId}/createInstance
{ "displayName": ..., "description": ..., "settingsDelta": [...], "roleScopeTagIds": [...] }
```

Settings are supplied *in the create call* via `settingsDelta`, so the follow-up
`updateSettings` call is only needed when updating an existing intent, not when creating one.
The update path was also carrying `templateId` in its PATCH body, which isn't an updatable
property on an existing intent; it now sends only `displayName`/`description`/`roleScopeTagIds`
and pushes settings through the documented `updateSettings` action.

Both branches are now exercised in the offline replay harness (see §18) and produce exactly the
documented request shapes. Still genuinely unverified: whether the live tenant accepts these two
specific intents' `settingsDelta` payloads, since intent settings use the older
`definitionId`/`valueJson` format rather than the Settings Catalog schema. This item moves from
"wrong by construction" to "right shape, unconfirmed payload."

## 18. Offline replay harness — what was found by running the pack without a tenant

After a run of one-error-at-a-time failures (§9, §13, §14, §15, §16), the whole pack was
replayed offline against a mocked Graph layer: every one of the 212 in-scope policies pushed
through the real `Deploy-IntuneBaseline.ps1` code paths, with every outgoing request captured
and asserted on, across all three rollout stages, in both create and update modes. This is the
check that should have been run before the first live deploy. What it caught:

- **§17**, above — endpoint security intent creation was impossible as written.
- **The audit-mode override silently did nothing for 2 of its 3 policies.** `Set-AuditModeIfFlagged`
  substituted `_actiontype_1`/`_actionmode_1` → `_2`. A scan of every choice value in all 212
  policies found that encoding **appears nowhere in this pack** — it was fictional. The pack's
  real encodings are word suffixes for ASR rules (18 values already `_audit`, 14 `_block`) and
  the `EnableControlledFolderAccess` integer enum (`_1` = Enabled/block, `_2` = Audit Mode, per
  the Defender CSP reference) for Controlled Folder Access. Both Controlled Folder Access
  policies already ship as `_2`, so they were correct by accident, but the function was warning
  loudly about them on every run while genuinely not governing them.
- **`-AuditModeForFlaggedPolicies:$false` did not work at all.** It only ever flipped
  block → audit, never the reverse, so the documented "promote a reviewed pilot to block mode"
  workflow was a no-op for every policy already recorded as audit — which is both Controlled
  Folder Access policies. The function is now bidirectional and this is covered by the harness.
- **`Verify-Deployment.ps1` called `Connect-MgGraph -Scopes ...` itself**, requesting delegated
  scopes. `Deploy-IntuneBaseline.ps1` deliberately requires a pre-existing app-only connection,
  so verifying right after deploying would either fail or silently re-authenticate as a
  different principal and verify a context you hadn't deployed to. It now requires the same
  existing connection the deploy script does.
- **The Chrome Site Isolation placeholder (§15's sibling)** — `<YOURSITE>`, with no patch case
  at all. Caught by scanning every value in the generated pack for placeholder-shaped strings
  rather than waiting for it to deploy silently and protect nothing.

What the harness asserts, and what now passes on every run:

| Assertion | Result |
|---|---|
| All 212 policies execute without throwing, all 3 stages, create + update | pass |
| 212 assignment calls, every one naming the tier's group *and* the break-glass exclusion | pass |
| Real Entra tenant ID reaches the OneDrive + Teams bodies | pass (2 calls) |
| Real approved extension IDs reach the Edge + Chrome bodies | pass (2 calls) |
| No outgoing `description` over Graph's 1000-char limit | pass |
| No unhandled placeholder in any outgoing body | pass — the only 3 remaining are the SSID/password/origins values that raise explicit warnings |
| Dynamic stage fails loudly when the `*-Dynamic` groups don't exist yet | pass |
| `-SkipPolicyIds` filters, and throws on an id matching nothing | pass |
| `Verify-Deployment.ps1` runs end to end and reports assignment + exclusion state | pass |

**What this still does not prove.** The harness verifies the *requests this toolkit sends*; it
cannot verify Graph's *responses*. Every item in §10 that depends on a live tenant accepting a
payload remains open — the intents' `settingsDelta` payloads, the Edge `ExtensionSettings` map
rendering correctly in the portal, whether policies show as expected in the Intune UI. A clean
harness run means the pack should no longer fail *structurally* partway through a deploy; it
does not mean every policy is semantically right for the customer.

## 19. First clean full deploy — what the live run actually confirmed

**2026-09-08.** After the fixes in §13-§18, a full `-RolloutStage Pilot` run completed with no
errors, and `Verify-Deployment.ps1` (run independently against the live tenant, reading
manifest.json rather than anything the deploy script produced) reported:

```
212 checked, 0 missing, 0 created-but-unassigned, 0 missing the break-glass exclusion.
```

with no unrecognized policies in the tenant. That single line closes several items that had
been open since this toolkit was written, because it is end-to-end evidence rather than
inference:

- **All 5 Graph object shapes deploy successfully** — 202 settings catalog, 7 legacy device
  configurations, 2 endpoint security intents, 1 compliance policy. The intents (§17) and the
  compliance policy's `setScheduledActions` call (§13's sibling fix) were both first-ever live
  executions and both worked.
- **The mixed include+exclude assignment body is confirmed** (§10 item 4, previously "shape
  confirmed workable, exclusion side unverified"). Verify independently re-read each policy's
  live assignments and found `Intune-Excl-BreakGlass` present as an exclusion on all 212 — so
  the exclusion side is now confirmed against the tenant, not just accepted without error.
- **Every policy is assigned** — 0 created-but-unassigned means no policy exists in the tenant
  without a rollout-tier group, which is the specific failure mode that would leave a policy
  silently applying to nobody (or, worse later, to everybody).

Deliberately still NOT confirmed by this run, and still requiring a human in the portal:

- The 4 customer-value policies (§14). Verify confirms they exist and are assigned; it cannot
  confirm the injected values are right, because manifest.json is the generic source and has
  nothing to compare a customer-specific value against. Given §14's bug meant these deployed
  with placeholder values on every earlier run, **these four are the one thing that genuinely
  needs eyes on the portal before this tenant moves past Pilot.**
- Whether audit-mode policies render as "Audit" in the portal UI (§9/§18) rather than merely
  having had the right value sent.
- Whether any policy is semantically wrong for this customer — which is what the Pilot ring
  soak period is for, and is a risk decision, not a correctness check.

## 20. Pilot ring split per platform; break-glass deliberately not

**2026-09-08, design change.** The single mixed-platform `Intune-PilotRing` group was replaced
by four per-platform pilot rings (`Intune-Pilot-WindowsWorkstations` / `-WindowsServers` /
`-macOS` / `-Linux`). The old group was never unsafe — Intune only applies a policy to a
matching-platform device, so the 202 Windows policies assigned to a pilot Mac were no-ops — but
it made Pilot the only tier that ignored platform, which cost three things: platforms couldn't
run independent soak clocks without juggling `-Categories`, pilot assignment reporting was
misleading (policies "assigned" to devices they could never apply to), and Pilot was a special
case in `Get-EffectiveGroupKey` rather than a tier like the others.

The split **removed** code rather than adding it. All three stages now resolve the policy's
platform through the same `$categoryGroupKey` map and apply a tier affix: `Pilot` prefixes,
`Dynamic` suffixes, `Static` uses the bare key. Distribution: 188 Windows workstation, 22
Windows Server, 10 macOS, 2 Linux.

**Break-glass was deliberately NOT split**, though symmetry argues for it. Break-glass is used
mid-incident by whoever is on call, and one group has the property that matters under pressure:
a device in it is excluded from everything, full stop. Four exclusion groups create a failure
mode with no compensating benefit — someone adds an emergency device to the Windows exclusion
group while the policy actually biting is a server or Linux one, and believes they're covered.
A single group already holds mixed-platform devices safely, since each is only excluded from
policies that would ever target it. Recorded here because the asymmetry looks like an oversight
if you only read `groups.tf`, and someone will eventually be tempted to "fix" it.

Verified before delivery, not after: `test/Invoke-OfflineReplay.ps1` gained four assertions —
that every assignment names a per-platform pilot ring, that Windows Server policies use their
own ring (not the workstation one), that exactly the 2 Linux-scoped policies use the Linux ring,
and that no assignment names two pilot rings at once. All pass, alongside the existing 21.

**Migration is not automatic** for a tenant already deployed against the old group — see
README.md "Migrating a tenant built before the pilot split". The old group's membership is
destroyed by `terraform apply`, so it has to be recorded first and re-added by platform after.

## 21. updateSettings takes "settings"; createInstance takes "settingsDelta"

**2026-09-08, second live run.** After the §17 fix made intent CREATION work (confirmed — both
intents deployed and verified in §19), the next run hit the intent UPDATE branch for the first
time, because the intents now already existed. Graph answered with:

```
POST .../intents('{id}')/updateSettings
400 BadRequest: "settings is a required field"
```

The cause is a genuine inconsistency in the Graph API that is very easy to conflate, and I did
conflate it: the two intent actions take the **same shape of data under different parameter
names**.

| Action | Body parameter |
|---|---|
| `POST /deviceManagement/templates/{templateId}/createInstance` | `settingsDelta` |
| `POST /deviceManagement/intents/{id}/updateSettings` | `settings` |

Both verified against Microsoft's own reference pages, not inferred. The create branch was
already correct (and is confirmed working live in §19); only the update branch was wrong.

This is the same failure *pattern* as §13 and §14: a branch that had never executed, failing
the first time it did. The offline replay harness (§18) did exercise this branch — it just
asserted that `updateSettings` was *called*, not what parameter name the body used, because at
the time I had no ground truth for the name. That gap is now closed: the harness asserts the
exact body parameter for all four action endpoints this toolkit calls —
`createInstance`/`settingsDelta`, `updateSettings`/`settings`, `assign`/`assignments`,
`setScheduledActions`/`scheduledActions` — so none of them can silently drift back.

**All four action endpoints are now confirmed live.** `assign`, `setScheduledActions` and
`createInstance` in §19; `updateSettings` on the run immediately after this fix (2026-09-08),
which completed with no errors through the intent update branch. That closes the last
Graph-contract unknown in this toolkit: every endpoint and every body parameter it uses has now
been accepted by a real tenant, not just matched against documentation.

## 22. Status as of the end of 2026-09-08

Every Graph endpoint, body shape and body parameter name this toolkit uses has now been
accepted by a live tenant. The bugs found across this day — §13 (settings can't be PATCHed),
§14 (customer values silently never substituted), §15 (Secret setting type), §16 (description
length), §17 (intent creation endpoint), §18 (audit-mode encodings, verify auth), §21
(updateSettings parameter name) — share one shape: **a code path that had never executed,
failing the first time it did.** Five were found the expensive way, one live run at a time;
the rest were found offline in a single pass once `test/Invoke-OfflineReplay.ps1` existed.

The lesson worth carrying to the next engagement: idempotent-by-name deploy scripts have two
distinct code paths per object shape (create and update), and the update path does not execute
until the *second* run against a tenant. A first clean run proves half the code. Run the
offline replay in both modes before trusting either.

Remaining open items are no longer about whether Graph accepts the requests. They are:

1. **The 4 customer-value policies need a portal check** (§14) — verify confirms they exist
   and are assigned, but cannot confirm the injected values are the customer's. Because of
   §14's bug these deployed with placeholder values on every run before 2026-09-08.
2. **Audit-mode policies should be eyeballed in the portal** (§18) — the right value is
   provably sent; that it renders as "Audit" in the UI is unconfirmed.
3. **Semantic fit for this customer** — whether each policy is *right* for this business, as
   opposed to correctly deployed. That is what the pilot soak period is for, and it is a risk
   decision, not a correctness check.
