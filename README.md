# IntuneSightline

Read-only reporting for Microsoft Intune. Focused tools that answer questions the admin
center answers badly, and write the answer to a workbook or a self-contained HTML page.

No modules to install. Nothing writes to your tenant.

![IntuneSightline launch page](docs/images/launch-page.png)

<details>
<summary>Connect page</summary>

![Connect to a tenant](docs/images/connect-page.png)

</details>

Sample output is in [`docs/samples`](docs/samples) - fabricated data, a fictional
tenant, nothing real. Open one to see the shape of the output before running anything
against your own tenant.

Download the latest zip from [Releases](../../releases/latest), extract it, and run:

```powershell
./Start-IntuneSightline.ps1
```

On Windows, files extracted from a downloaded zip are marked as coming from the internet
and PowerShell will refuse to run them. Unblock them once, from the extracted folder:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

A preflight check runs, then a page opens at `127.0.0.1:8787`. Enter your tenant ID and
the application ID of a registration with the permissions listed under
[Prerequisites](#prerequisites), press Connect, and sign in. Both values are remembered.

## The problem

The Intune admin center cannot tell you everything that targets a group. It will not show
you which policies are assigned to nothing. It cannot explain why one device behaves
differently from the one next to it. And it will not give you your scripts back as files.

Each tool here answers one of those.

## Tools

| Tool | Answers |
|---|---|
| Android device journey | How an Android device was enrolled, the groups that resulted, and everything that reaches it |
| Assignment inventory | One row per assignment: what targets what, across the whole tenant |
| Bulk group membership export | Resolves a list of device names or serial numbers to the Entra Object IDs needed to bulk-add them to a group |
| Change history | Who changed what and when, from the Intune audit log. Includes deletions and renames |
| Orphaned and unassigned | Finds policies, scripts and filters that nothing is assigned to or that target nothing |
| Recover scripts | Pulls script bodies out of Intune and writes them to disk as files |
| Windows device journey | How a Windows device was enrolled, the groups that resulted, and everything that reaches it |
| iOS/iPadOS device journey | How an iPhone or iPad was enrolled, the groups that resulted, and everything that reaches it |
| macOS device journey | How a Mac was enrolled, the groups that resulted, and everything that reaches it |

## What it will not do

**It does not render reports in the browser.** Tools write files. The page shows progress
and a link to the output folder, nothing more. That keeps the interface the same size
however many tools there are.

**It does not write to your tenant.** Every Graph call is a read, and a tool declaring a
write permission is rejected when it loads.

**It does not listen on the network.** The server binds to `127.0.0.1` only.

## The launch page and the reports both follow the Intune admin centre

Tools are grouped by the same headings Intune itself uses — Devices, Apps and
policies, Scripts and remediations, Tenant administration — so nothing on the page
needs learning separately from the portal you already know.

Both the launch page and every HTML report support a light and a dark theme, matching
your system by default with a toggle to override it. An HTML report opens in whichever
theme you were using when you ran it, and always prints on a plain white background
regardless of screen theme, so a copy attached to a ticket stays legible.

## Every export says what it could see

A snapshot is not "the tenant" — it is what one account could read. Scope tags, licensing
and throttling all filter results, so two admins running the same tool can legitimately
get different files.

Every export therefore carries the tenant, the collecting account, the permissions it
held, and a per-source coverage list. A source marked `INCOMPLETE` means results absent
from the export may still exist; the reason is shown beside it, for example
`403 (Forbidden)`.

Clean is not the same as complete, and the file says which one you have.

## Architecture

![Four layers: browser, shell, tools, core, then Graph and files out](docs/images/architecture.svg)

**shell** serves the page, builds each tool's form from its manifest, runs one job at a
time in a background runspace, and relays progress. It contains no tool-specific code —
a check fails the build if it ever does.

**tools** are independent. Each is a manifest plus one script. Drop a folder in, reload
the page, and it appears.

**core** is a library tools call: authentication, Graph paging and throttling, batching,
output paths, provenance. Core never calls tools.

Platform differences — paths, opening files, launching a browser — live in one file.

See [docs/architecture.md](docs/architecture.md) for the tool contract and the reasoning.

## Prerequisites

- PowerShell 7.0 or later. Tested on Windows and macOS; nothing in it is Windows-specific.
- An Intune-licensed tenant.
- An Entra app registration, with the delegated Microsoft Graph permissions below granted
  admin consent. All are read-only.

| Permission | Used for |
|---|---|
| `User.Read` | Your sign-in identity and the tenant name shown in every export |
| `DeviceManagementManagedDevices.Read.All` | Finding devices by name or serial |
| `DeviceManagementConfiguration.Read.All` | Policies, compliance, profiles and their assignments |
| `DeviceManagementServiceConfig.Read.All` | Autopilot, ADE, enrolment profiles, enrolment and VPP tokens |
| `DeviceManagementApps.Read.All` | Apps, app assignments, the audit log |
| `DeviceManagementScripts.Read.All` | Remediation, platform and macOS shell scripts |
| `DeviceManagementRBAC.Read.All` | Resolving Intune roles in Change history (on by default) |
| `Group.Read.All` | Group names, membership and nesting |
| `Directory.Read.All` | Entra device objects, registered owners, Object IDs for bulk membership, the app registration's name |
| `User.ReadBasic.All` | User lookup in Change history |

With all ten granted, no tool hits a permission gap. With fewer, the app still runs with
whatever is consented; a missing permission shows either as a greyed-out tool or as an
incomplete source in that report's coverage table.

`DeviceManagementScripts.Read.All` is easy to miss. Microsoft moved the script endpoints
onto it from `DeviceManagementConfiguration.Read.All` in July 2025, so a registration
created before then will return `403 (Forbidden)` for scripts until it is added.

## Permissions

Sign-in requests `https://graph.microsoft.com/.default`, which returns exactly the
permissions your tenant has already consented for that application — no more. A tool
whose declared permissions are missing is greyed out with the specific permission named,
rather than failing partway through.

Write permissions are dropped from the working set at sign-in and the discarded list is
printed. See [SECURITY.md](SECURITY.md).

## Known limitations

- **Encrypted OMA-URI values cannot be read.** Graph returns a placeholder; the real
  value needs a per-setting authenticated call and cannot be decrypted offline.
- **Some data lives on two endpoints.** Security baselines split between
  `deviceManagement/intents` and `configurationPolicies`. Querying one silently misses
  the other, so both are read.
- **Audit filtering is limited to date and activity type.** The actor and the affected
  resource are nested objects Intune will not filter on, so a "changed by" filter is
  applied after collection. Run time follows how many events happened, not how many match.
- **Entra does not record when a device joined a dynamic group.** Reports show how
  membership arises, not when it began.
- **Conditional Access, on-premises Group Policy and local policy are out of scope.**
  They affect real outcomes and cannot be seen from here.

## Checks

```powershell
./tests/Invoke-Checks.ps1
```

Static checks needing no tenant, run on every push to `main` and every pull request. Each exists because
something shipped broken.

For functional testing against a real tenant:

```powershell
./tests/Invoke-LiveTests.ps1
```

Signs in the same way the app does, then runs every production tool across each of its
options - isolated per tool, in its own runspace, exactly like a live job - and reports
pass or fail for each. Asks for one real device per platform; leave any blank to skip
that platform. Needs a real tenant, so it never runs in CI; run it by hand before a
release.

## Licence

MIT. See [LICENSE](LICENSE).
