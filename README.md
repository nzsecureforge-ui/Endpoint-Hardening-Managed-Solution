# MSSP Intune Baseline — Deployment Toolkit

Reusable, per-customer-deployable Intune device management baseline, mapped to NIST SP
800-53 Rev 5, ISO/IEC 27001:2022, and CIS Benchmark controls. Built to match the engineering
discipline of the Conditional Access (CA-Baseline) project: official-vendor tooling only,
everything generated from source rather than hand-written, no standing credentials, and a
verification step that doesn't trust the deploy engine's own bookkeeping.

## Why Terraform only manages groups

There is no official HashiCorp or Microsoft Terraform provider for Intune device management
(`deviceManagement/configurationPolicies`, `deviceConfigurations`, `intents`,
`compliancePolicies`) — see the open, unresolved
[hashicorp/terraform-provider-azuread#524](https://github.com/hashicorp/terraform-provider-azuread/issues/524).
The only providers that cover it (`deploymenttheory/terraform-provider-microsoft365`,
`terraprovider/terraform-provider-microsoft365wp`) are small community projects, not
something we're willing to run against a customer tenant as a security best practice.

So this project splits responsibility the same way CA-Baseline did for its one
azuread-unsupported object (Terms of Use):

- **Terraform (`terraform/`, official `hashicorp/azuread` provider)** manages the 9
  always-present device assignment groups (4 pilot rings, 4 static target groups, 1 break-glass
  exclusion) plus up to 3 gated `-Dynamic` groups — plain Entra ID group objects, fully
  supported.
- **The 222 Intune policies** deploy via `deploy/Deploy-IntuneBaseline.ps1`, which calls
  `Invoke-MgGraphRequest` (the official Microsoft Graph PowerShell SDK's raw REST call,
  not the fast-changing `Microsoft.Graph.Beta.DeviceManagement` cmdlet surface) directly
  against the stable Graph beta REST contract.

Both paths use the same app registration (`bootstrap/New-AppRegistration.ps1`) and the same
"generate from source, never hand-edit the output" discipline as CA-Baseline's
`tools/generate.py`.

## Layout

```
scripts/build_baseline.py     Generator. Reads the customer's source policy JSON tree,
                               classifies each file into one of 5 Graph object shapes,
                               strips Graph-managed/read-only fields, cross-references the
                               CIS/NIST/ISO framework mapping workbook, and writes
                               Intune-Baseline/<category>/<slug>.json + manifest.json.
                               Re-run this after any change to source policies — never
                               hand-edit anything under Intune-Baseline/.
scripts/coverage_check.py     Safety net: walks every field in every source JSON and flags
                               anything dropped during cleaning that isn't on the explicit
                               drop list, so a generator bug (a field silently lost) is
                               caught before deploy time. Run after any change to
                               build_baseline.py's clean() function.

source-pack/                   INPUT. The original policy JSON pack (224 files) plus the
                               CIS/NIST/ISO framework mapping workbook. Edit policies HERE,
                               then regenerate. Three files carry Graph-correctness fixes
                               made 2026-09-08 — see "Regenerating from source".

Intune-Baseline/               Generated OUTPUT — 222 policies across 16 categories, plus
                               manifest.json (the single source of truth both the deploy
                               script and the verify script read from). Never hand-edit.

terraform/providers.tf         hashicorp/azuread ~> 3.0, same provider/version as CA-Baseline.
terraform/groups.tf            The always-present groups + up to 3 gated "-Dynamic" tier
                                groups (see "Rollout model" below) + an output block.
terraform/variables.tf         The 3 rollout-stage promotion flags (*_dynamic, default
                                false). The one place this project does use Terraform
                                variables — see "Rollout model" for why.
terraform/terraform.tfvars.example   Per-customer copy target for the 3 flags above.

config/customer.config.psd1.example   Template for the customer-specific values below.
config/Test-CustomerConfig.ps1        Validates a customer's copy before deploy — the
                                       PowerShell-data-file equivalent of a Terraform
                                       variable validation block.

bootstrap/New-AppRegistration.ps1     One-time per-tenant setup: creates the single app
                                       registration used by both Terraform and the deploy
                                       script, grants the 3 app-only Graph roles it needs,
                                       prints ARM_* env vars + a Connect-MgGraph snippet.
bootstrap/Test-Prerequisites.ps1      Delegated, read-only license check (Intune, Defender
                                       for Endpoint P2, Entra ID P1/P2) before you build
                                       anything in a target tenant.

deploy/Deploy-IntuneBaseline.ps1      The deployment engine. Idempotent create-or-update by
                                       name, per Graph shape, from manifest.json.

verify/Verify-Deployment.ps1          Diff of the live tenant against manifest.json, run on
                                       the SAME app-only connection as the deploy script (it
                                       used to open its own delegated connection, which could
                                       verify a different context than you deployed to — see
                                       RECONCILIATION.md 18). Independent of the deploy
                                       script's own logic, same reasoning as CA-Baseline's.

test/Invoke-OfflineReplay.ps1         Replays all 212 policies through the deploy script
                                       against a mocked Graph API and asserts on every
                                       request. No tenant, no credentials. Run before any
                                       deploy and after any change to the pack.
```

### The assignment groups (`terraform/groups.tf`)

| Group | Membership | Used by |
|---|---|---|
| `Intune-Pilot-WindowsWorkstations` | Static/manual | Categories 01-14 (188 policies), at the default `-RolloutStage Pilot` |
| `Intune-Pilot-WindowsServers` | Static/manual | Category 15 (22 policies), at `-RolloutStage Pilot` |
| `Intune-Pilot-macOS` | Static/manual | Category 16 (10 policies), at `-RolloutStage Pilot` |
| `Intune-Pilot-Linux` | Static/manual | The 2 Linux-scoped policies, at `-RolloutStage Pilot` |
| `Intune-Target-WindowsWorkstations` | Static/manual | Categories 01-14, at `-RolloutStage Static` |
| `Intune-Target-WindowsWorkstations-Dynamic` | Dynamic (`deviceOSType -eq "Windows"`, excludes `SRV-*`) — only exists once `windows_workstations_dynamic = true` | Categories 01-14, at `-RolloutStage Dynamic` |
| `Intune-Target-WindowsServers` | Static/manual, no Dynamic tier at all | Category 15, every stage |
| `Intune-Target-macOS` | Static/manual | Category 16, at `-RolloutStage Static` |
| `Intune-Target-macOS-Dynamic` | Dynamic (`deviceOSType -eq "MacMDM"`) — only exists once `macos_dynamic = true` | Category 16, at `-RolloutStage Dynamic` |
| `Intune-Target-Linux` | Static/manual | Linux Defender + Linux Device Encryption, at `-RolloutStage Static` |
| `Intune-Target-Linux-Dynamic` | Dynamic (`deviceOSType -eq "Linux"`) — only exists once `linux_dynamic = true` | Same two policies, at `-RolloutStage Dynamic` |
| `Intune-Excl-BreakGlass` | Static/manual | Excluded from **every** assignment, at every stage. Deliberately one group, not split per platform — see below |

## Rollout model

Not every policy suits every business, and security doesn't automatically get to trump
productivity — the point of this toolkit is a modern, usable, secure service, and getting
there means risk-based decisions made deliberately during pilot and testing, before anything
reaches production. Two existing knobs already support that: `-Categories` / `-SkipCategories`
let you drop a category that doesn't fit a customer's business, and `-AuditModeForFlaggedPolicies`
softens the 3 riskiest ASR rules to audit mode until you're confident. The group model below is
the third: how *broadly* a policy that IS going out gets applied, and how that broadens safely
over time.

Every policy assignment moves through three tiers, controlled by `deploy/Deploy-IntuneBaseline.ps1 -RolloutStage`:

1. **Pilot** (default). Each policy is assigned to the pilot ring for ITS platform —
   `Intune-Pilot-WindowsWorkstations`, `-WindowsServers`, `-macOS` or `-Linux` — using the same
   category-to-platform map the later stages use. Add a small, deliberately-chosen set of pilot
   devices to each by hand.

   Until 2026-09-08 this was a single mixed-platform `Intune-PilotRing` group holding every
   policy. That was *safe* (Intune only ever applies a policy to a matching-platform device, so
   a Windows policy assigned to a pilot Mac was a no-op) but it made Pilot the odd tier out —
   the only stage where all four platforms shared one blast radius and one soak clock, and
   where pilot assignment reporting showed 202 Windows policies targeted at Macs. Splitting it
   lets each platform run its own Pilot → Static → Dynamic timeline, which is what the 3-4 week
   soak model actually wants, and it removed the special case from the deploy script rather
   than adding one: all three tiers now resolve a platform the same way and just apply a
   different tier affix.
2. **Static** (`-RolloutStage Static`). Assignment moves to the platform-specific
   `Intune-Target-<Platform>` group (still static/manual membership). Manually add more
   devices to it as you gain confidence — the recommended cadence is a 3-4 week soak with no
   policy-related issues before expanding further, and the same period again with the fuller
   set before considering production.
3. **Dynamic** (`-RolloutStage Dynamic`). Assignment moves to `Intune-Target-<Platform>-Dynamic`
   — an auto-populated group scoped by OS type. This is "production": every matching device in
   the tenant is in scope from here on, no manual membership management. **This group doesn't
   exist until you provision it deliberately** — see "Promoting a platform to production" below.

`Intune-Excl-BreakGlass` is layered on as an **exclusion** on every single assignment, at every
stage, so break-glass devices are protected no matter where a policy currently sits. Windows
Server has no Dynamic tier at all — Arc-enrolled servers don't populate device attributes
reliably enough for a membership rule — so it stays on its static group forever; the deploy
script warns rather than errors if you request `-RolloutStage Dynamic` for it.

### Promoting a platform to production

```powershell
# after Intune-Target-WindowsWorkstations has run clean for the agreed soak period:
cd terraform
# edit terraform.tfvars: windows_workstations_dynamic = true
terraform apply        # provisions Intune-Target-WindowsWorkstations-Dynamic — a NEW group

cd ../deploy
./Deploy-IntuneBaseline.ps1 -CustomerConfigPath ../config/customer.config.psd1 -RolloutStage Dynamic
```

This is deliberately a **second, new group**, not the static one converted in place. The
`azuread_group` resource's `types` argument (what turns dynamic membership on) is `ForceNew`
in the `hashicorp/azuread` provider — confirmed by reading the provider's own
`group_resource.go` — so toggling it on an *existing* group would make Terraform destroy and
recreate that group, silently breaking every policy assignment that referenced its old object
ID. Provisioning a second purpose-built group instead makes promotion an additive `apply`
followed by a normal deploy re-run, with the static group left in place afterward (harmless,
and a useful audit trail of who was in the pilot/expansion set).

### Why there IS a `terraform/variables.tf`

Every other customer-specific value in this project (the 4 "landmine" policies below, the
macOS onboarding profile path, feature-update deferral days, per-tenant ASR exclusions) lives
in `config/customer.config.psd1`, read by the PowerShell deploy script, not by Terraform. The
3 rollout-stage flags are the one exception, because they gate which Terraform *resources*
exist at all (the `-Dynamic` groups) — that's a Terraform input by nature, not a PowerShell
one. Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars` per engagement;
all 3 default to `false` even if you skip that step, so a fresh engagement can never
accidentally provision straight to production-wide dynamic enforcement.

## Customer-specific "landmine" values

Four policies in the source pack contain a placeholder value that will break something (or do
nothing) if deployed unconfigured — see `RECONCILIATION.md` for the full list of 35 production
notes. `config/Test-CustomerConfig.ps1` refuses to let deploy proceed until these are filled
in with real, non-placeholder values:

1. OneDrive tenant restriction → `EntraTenantId`
2. Teams tenant restriction → `EntraTenantId`
3. Edge extension management → `EdgeApprovedExtensionIds`
4. Chrome extension allow list → `ChromeApprovedExtensionIds`

## One-time setup (per engagement)

1. `pwsh bootstrap/Test-Prerequisites.ps1` — confirm the target tenant has Intune + Defender
   for Endpoint P2 licensing before building anything.
2. `pwsh bootstrap/New-AppRegistration.ps1` — creates `Intune-Baseline-Deploy`, grants
   `DeviceManagementConfiguration.ReadWrite.All`, `Group.ReadWrite.All`,
   `Application.Read.All` (app-only — needs tenant-admin consent, the script prints the
   consent URL), writes `app-registration.env` (gitignored — delete once exported).
3. Copy `config/customer.config.psd1.example` to `config/customer.config.psd1` and fill in
   every required value. `config/customer.config.psd1` is gitignored — it's per-customer,
   never committed.
4. Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars`. Leave all 3
   flags `false` for a new engagement — see "Rollout model" above.
5. **Decide macOS scope now, not mid-deploy.** Category 16 needs
   `WindowsDefenderATPOnboarding.xml` downloaded fresh from this customer's own Defender
   portal — a file that can't be pre-built or reused between customers. Either get it now and
   set `MacOSOnboardingXmlPath` in `customer.config.psd1`, or plan to pass
   `-SkipCategories '16_Defender_for_Endpoint_macOS'` on every `Deploy-IntuneBaseline.ps1`
   run until you're ready to come back to it. Deciding this here avoids the deploy run
   throwing partway through when it reaches category 16 unprepared.
6. **Decide the other two optional customer values now, for the same reason.** Neither blocks
   a deploy — both deploy "successfully" with placeholder values that quietly do nothing,
   which is worse than failing:
   - `ChromeIsolatedOrigins` — the Chrome site-isolation policy ships with a literal
     `<YOURSITE>` placeholder. Set the customer's real origins, or skip that one policy with
     `-SkipPolicyIds '13-Google-Chrome-CIS-Benchmark/Baseline-Chrome-Enable-Site-Isolation-for-specified-origins'`.
   - `QuickMachineRecoverySsid` / `QuickMachineRecoveryPassword` — only if this customer wants
     a WiFi-reachable recovery network for Windows Quick Machine Recovery. Leave `$null` if not.
7. `pwsh test/Invoke-OfflineReplay.ps1` — dry-run the whole pack against a mocked Graph API
   before touching the tenant. Takes about a minute and needs no credentials. Expect
   `All offline replay assertions passed.` See "Before any deploy" below for why this matters
   more than it looks like it should.
8. After the first `terraform apply`, **add pilot devices to the four
   `Intune-Pilot-<Platform>` rings by platform**, and the customer's break-glass devices to
   `Intune-Excl-BreakGlass`. Nothing applies to anything until those groups have members.

### First-engagement gotchas worth reading before you start

Three things cost real time on the first customer and are cheap to avoid on the next:

- **Verify what the customer-value substitution actually produced.** `Verify-Deployment.ps1`
  confirms a policy exists and is assigned; it cannot confirm the *injected value* is the
  customer's, because manifest.json is the generic source. After the first deploy, open the
  OneDrive, Teams, Edge and Chrome policies in the portal and confirm the real tenant ID and
  real extension IDs are there. A bug once made all four deploy with placeholders silently
  (RECONCILIATION.md §14).
- **Run the deploy twice before you trust it.** The script is idempotent create-or-update, so
  the *update* path doesn't execute until the second run. A first clean run only proves half
  the code. The offline replay covers both, which is why step 7 exists.
- **Pass the same scoping flags to verify that you passed to deploy.** Otherwise skipped
  categories are reported as MISSING and bury anything genuinely missing.

## Deploying

```powershell
# 1. Groups (Terraform)
cd terraform
terraform init
terraform plan   # review before apply, same as CA-Baseline
terraform apply

# 2. Policies (Graph SDK) — defaults to -RolloutStage Pilot, i.e. the Intune-Pilot-<Platform> rings
cd ../deploy
. ../config/Test-CustomerConfig.ps1   # or let Deploy-IntuneBaseline.ps1 call it internally
./Deploy-IntuneBaseline.ps1 -CustomerConfigPath ../config/customer.config.psd1
```

By default the 3 `audit_first_recommended` policies (Controlled Folder Access x2, the
constructed webshell ASR rule — Production Notes #17/#29/#30) deploy in audit mode rather
than their source-recorded block mode. Pass `-AuditModeForFlaggedPolicies:$false` to deploy
them in block mode directly, but read Production Notes #17/#29/#30 first.

Use `-Categories` / `-SkipCategories` to scope a run — useful for a phased rollout, or if a
customer's licensing (per `Test-Prerequisites.ps1`) doesn't cover every category, or because a
particular policy just doesn't suit that business.

Every run also defaults to `-RolloutStage Pilot` (see "Rollout model" above) — nothing reaches
a broad, auto-populated group without a deliberate `-RolloutStage Static` and later
`-RolloutStage Dynamic` re-run, each gated by its own soak period.

## Verifying

```powershell
pwsh verify/Verify-Deployment.ps1 -CsvPath "./verification-$(Get-Date -Format yyyy-MM-dd).csv"
```

Signs in delegated (interactive), not with the app-only credential the deploy script uses,
so this human spot-check doesn't add a second standing credential to remember to clean up.
Reads directly from `manifest.json` (built independently from source by
`scripts/build_baseline.py`, not from anything the deploy script itself produces), so a bug
in `Deploy-IntuneBaseline.ps1` shows up as MISMATCH/MISSING rather than being invisible to
its own check. For the 4 customer-value policies, it only confirms the policy exists and is
assigned — verify the injected values by hand in the Intune portal.

It also resolves each matched policy's live assignments to group names, so the output shows
which rollout tier (`Intune-Pilot-<X>` / the static `Intune-Target-<X>` / the `-Dynamic` tier)
every policy is actually sitting at, and whether the break-glass exclusion is present — the
fastest way to confirm a promotion (or a `-SkipCategories` exception) actually landed the way
you intended, and to catch a policy that got created but never assigned.

## Regenerating from source

`source-pack/` holds the original policy JSON (plus `CIS_Compliance_Baseline_v2.xlsx`, the
framework mapping workbook). `Intune-Baseline/` is generated from it. If a policy needs
changing, **edit the file in `source-pack/` and regenerate** — never hand-edit anything under
`Intune-Baseline/`, same rule as CA-Baseline's generated `.tf` files.

```bash
python3 scripts/build_baseline.py     # regenerate Intune-Baseline/ from source-pack/
python3 scripts/coverage_check.py     # confirm no field was silently dropped
pwsh test/Invoke-OfflineReplay.ps1    # confirm the pack still deploys cleanly
```

The generator defaults to `source-pack/` inside this repo, so a fresh clone regenerates with no
configuration. Point it elsewhere with `INTUNE_SOURCE_ROOT` if you keep the pack outside the
repo — but note that **three files in `source-pack/` carry corrections made on 2026-09-08**
that Graph rejected outright in their original upstream form: the webshell ASR rule's enum
value, the Quick Machine Recovery password's Secret setting type, and the consolidated Device
Password policy's over-length description (`RECONCILIATION.md` §9, §15, §16). Pointing at an
older upstream export brings all three bugs back. Diff against `source-pack/` before switching.

## End of engagement

- Delete the app registration created by `New-AppRegistration.ps1` (`Intune-Baseline-Deploy`)
  — it holds `DeviceManagementConfiguration.ReadWrite.All` and `Group.ReadWrite.All`, both
  application-level permissions with no reason to persist past the engagement.
- Confirm `app-registration.env`, `config/customer.config.psd1`, and
  `terraform/terraform.tfvars` were deleted or never committed (all three are gitignored —
  see `.gitignore`).
- Local Terraform state (`terraform/terraform.tfstate*`) is per-customer and gitignored;
  archive it with the engagement's records rather than committing it.
- Record which platforms, if any, were promoted to the Dynamic/production tier (and when) in
  the engagement's own records — that history lives only in `terraform.tfvars` and the
  archived state, not anywhere in this repo.

### Why break-glass is one group, not four

The pilot and target tiers are per-platform; `Intune-Excl-BreakGlass` deliberately is not.
Splitting it was considered and rejected on 2026-09-08.

Break-glass is the control someone reaches for mid-incident, possibly not the person who built
this. A single group has the one property that matters under pressure: put a device in it and
it is excluded, full stop. Four platform-specific exclusion groups would add a way to put an
emergency device in the wrong one, believe it is protected, and be wrong — at exactly the
moment nobody is double-checking. Nothing is gained by splitting: one group can hold a Windows
admin box, a Mac and a Linux jump host at the same time, because Intune only ever applies a
policy to a matching-platform device anyway.

### Migrating a tenant built before the pilot split

A tenant deployed before 2026-09-08 has a single `Intune-PilotRing` group that 200+ policies
are currently assigned to. Order matters:

1. **Write down who is in `Intune-PilotRing` first.** `terraform apply` will destroy that group
   and its membership goes with it.
2. `terraform apply` in `terraform/` — creates the 4 new pilot rings, destroys the old one.
3. Re-run `Deploy-IntuneBaseline.ps1` at `-RolloutStage Pilot`. Every policy is reassigned to
   its platform's ring; the `/assign` call replaces a policy's whole assignment list, so no
   stale reference to the deleted group survives.
4. Add the devices from step 1 into the right new ring by platform.
5. `Verify-Deployment.ps1` — confirm each policy now names the pilot ring you expect.

Between steps 2 and 3 the policies reference a deleted group, which means they are effectively
assigned to nobody. That is harmless in Pilot (that is the whole point of the tier) but do not
leave the gap open, and do not do this mid-incident.

## Before any deploy: run the offline replay

```powershell
pwsh ./test/Invoke-OfflineReplay.ps1
```

Pushes all 212 policies through the real deploy script against a mocked Graph API — no tenant,
no credentials, no side effects — and asserts on every request it would send: all three rollout
stages in both create and update mode, every assignment carrying its tier group *and* the
break-glass exclusion, customer-specific values actually reaching the wire, no leftover
placeholders, no over-length descriptions, and the documented Graph endpoints being the ones
actually called. Takes about a minute.

Run it after any change to the deploy script, the source pack, or the generated
`Intune-Baseline/` output. It exists because five separate deploy failures were each discovered
one at a time in a live tenant, hours apart, when every one of them was findable offline —
see `RECONCILIATION.md` §18.

It verifies what this toolkit *sends*, not what Graph *accepts*. A clean run means a deploy
shouldn't fail structurally partway through; it doesn't mean every policy is right for the
customer.

## Known gaps / unverified assumptions

See `RECONCILIATION.md` for the full, honest list. As of 2026-09-08 every Graph endpoint,
body shape and body parameter name this toolkit uses has been accepted by a live tenant — all
222 policies across all 5 object shapes, in both create and update mode (§19, §21, §22). What
remains open is not whether Graph accepts the requests, but whether the *values* are right for
a given customer: the Edge `ExtensionSettings` JSON map and the ASR audit-mode encodings are
provably sent correctly, but that they render as intended in the Intune portal is still worth
confirming by eye on a first engagement. The hardcoded
2-policy Linux exception list in `Deploy-IntuneBaseline.ps1` (`$LinuxSpecificPolicyIds`) is
also hand-verified against the current source pack, not schema-driven — re-check it if the
source pack changes.

One confirmed-and-fixed gap worth calling out specifically: re-running the deploy script
against a Settings Catalog or compliance policy that already exists (i.e. its content changed
since the last run) used to fail outright — Graph does not support PATCHing a policy's
`settings` in place for these two resource types, full stop, regardless of what this pack's
data contains. The script now handles this by creating the replacement, assigning it, and only
then deleting the old copy — see `RECONCILIATION.md` §13 for the full account, including a
narrow edge case if a run is interrupted mid-update.

**Action required, not just informational — re-check this after your next deploy run.** A
separate bug meant `Patch-CustomerSpecificValues` silently never matched any of its four cases
(EntraTenantId into OneDrive/Teams, EdgeApprovedExtensionIds, ChromeApprovedExtensionIds) on the
first live run — every one of those four policies deployed with the source pack's placeholder
values instead of this customer's real ones, with no error to signal it. It's fixed now, but
after your next run, open the Intune portal (Devices > Configuration) and confirm the OneDrive
and Teams policies show the real Entra tenant ID (not `00000000-...`) and the Edge/Chrome
extension policies show the real approved extension IDs (not an empty/wildcard-blocked list).
Full account in `RECONCILIATION.md` §14.
