# Onboarding package — must be generated per tenant

The 8 profiles in this folder are generic and identical for every tenant — they configure
system extensions, permissions, and antivirus behaviour, none of which are tenant-specific.

The ONE thing that cannot be pre-built for you is the onboarding package itself, because
it embeds your customer's actual org ID / onboarding token. It cannot be downloaded generically
or reused between tenants.

## How to get it, per customer

1. In the Microsoft Defender portal (security.microsoft.com) for that customer's tenant:
   **Settings > Endpoints > Device management > Onboarding**
2. Operating system: **macOS**
3. Deployment method: **Mobile Device Management / Microsoft Intune**
4. Click **Download onboarding package** — saves `GatewayWindowsDefenderATPOnboardingPackage.zip`
5. Unzip it. You need `intune/WindowsDefenderATPOnboarding.xml`.

## How to deploy it

In Intune: **Devices > Configuration > Create > macOS > Templates > Custom**
- Custom configuration profile name: must be exactly `com.microsoft.wdav.atp` (case-sensitive,
  no typos — Microsoft's docs specifically warn a wrong name means the settings are silently
  ignored)
- Upload `WindowsDefenderATPOnboarding.xml` as the configuration profile file
- Assign to the same Mac device group as the other 8 profiles in this folder

Do this once per customer tenant, right before the final rollout — it's the last profile
in the deployment order (see Production Notes / Import Guide for the full sequence).
