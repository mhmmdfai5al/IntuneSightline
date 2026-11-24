# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- README screenshots show the current version and all nine tools, made from
  fictional tenant data.

## [1.3.2] - 2026-11-24

Corrects the version number 1.3.1 shipped with.

### Fixed
- 1.3.1 reported itself as 1.3.0, at the top of the page and in every export, so its
  own update banner offered 1.3.1 to people already running it.
- The Bulk group membership export template began its header with the literal text
  `\xEF\xBB\xBF` instead of a byte-order mark. Present since 1.2.0.
- Live tests: Bulk group membership export always failed, because no input file was
  built for it; a tool the app would grey out was reported as failed rather than
  skipped with its reason; saved tenant and application IDs were looked for in the
  wrong folder.

### Changed
- README: the server listens on loopback, `127.0.0.1` and `localhost`, not
  `127.0.0.1` alone.
- Samples are described as covering every tool except Bulk group membership export.

- The release workflow stops before publishing if the tag does not match the app
  version, or CHANGELOG.md has no dated section for it. Both 1.3.0 and 1.3.1 would
  have been stopped.

### Removed
- Two functions in `core/Preflight.ps1` that nothing called.

## [1.3.1] - 2026-11-22

Documentation corrected against the code, and a release zip that includes `docs/`.
This release reports itself as 1.3.0; 1.3.2 corrects that.

### Changed
- Setup documentation matches the code. `SETUP.md` covers the app registration, its
  `http://localhost` redirect URI, consent, and the sign-in errors with their fixes.
  The README gains a Quick start, a permissions-by-tool table, the Intune role the
  signed-in account needs, and where reports go.
- `SECURITY.md` corrected: batched reads travel as a POST to `$batch`; the update
  check calls `api.github.com`; write permissions are listed on the page, not in the
  terminal; provenance is on a workbook's first sheet, not always `_provenance.txt`.
- `CONTRIBUTING.md` and the architecture doc corrected: the worked example's
  location, declaring every permission, the version rule, and the section headings.
- Bug report template lists the current tools.
- The release zip includes `docs/`, so the README's images and links work.

### Fixed
- An uploaded CSV that was never run stayed on disk. Leftover uploads are now cleared
  each time the app starts.

## [1.3.0] - 2026-11-21

Tools declare every permission they use, and a missing optional one no longer greys
a tool out.

### Added
- Optional permissions. A manifest can declare `optionalScopes`, each with an
  `affects` line. A tool missing one still runs; its card says what the run will
  leave out and which permission adds it back. Only required permissions grey a
  tool out.
- Alternative permissions. Any scope entry can list alternatives, satisfied by
  whichever one the tenant has consented - Graph usually accepts several for the
  same call.
- A static check that every PowerShell file parses. The existing checks read text
  and passed over a file the parser rejects.

### Changed
- Every manifest now declares every permission its tool uses. Device journeys:
  scripts, apps and Entra device objects are optional (`Device.Read.All` or
  `Directory.Read.All`). Assignment inventory and Orphaned and unassigned: scripts and
  apps optional. Recover scripts needs either `DeviceManagementScripts.Read.All` or
  `DeviceManagementApps.Read.All`, no longer `DeviceManagementConfiguration.Read.All`,
  which it never used. Change history needs only `DeviceManagementApps.Read.All`; roles
  and the account filter are optional. Bulk group membership export accepts
  `Device.Read.All` in place of `Directory.Read.All`.
- A setup guide, `SETUP.md`, covering the app registration and its
  `http://localhost` redirect URI; without it sign-in fails with AADSTS500113.
- Architecture doc no longer claims no app registration is needed.
- README permissions table says what happens when each permission is missing, and
  names `Device.Read.All` as the least privileged option for device objects.
- CI actions moved to Node 24 releases - `actions/checkout@v6` and
  `softprops/action-gh-release@v3`. GitHub removed Node 20 from Actions runners in
  September 2026; the old versions only kept working because runners forced them onto
  Node 24, which is what the deprecation warning on every run was reporting.

### Fixed
- The update banner offered any release whose version differed from the running one,
  so a newer build was told to "update" to an older release. It now appears only when
  the latest release is newer.
- Change history did not load: a duplicated function header stopped the file
  parsing. Present since 1.0.0.
- Device journeys said "Not a member of any group" when membership could not be
  read. They now say "Group membership could not be read : 403 (Forbidden)." and the
  coverage table marks that source incomplete instead of complete.
- Device journeys dropped a device from the report when its Entra object could not
  be read. The device now appears, without groups.
- Change history left a user's role blank when their group membership could not be
  read - the same as holding no role. It now shows "could not be read : 403
  (Forbidden)."
- Change history checked the account filter twice.

## [1.2.0] - 2026-11-16

A new tool, a new core capability any future tool can reuse - file upload - and a
README that now lists every permission the app needs.

### Added
- File upload as a core capability, not one tool's private plumbing. A manifest
  field declaring `type: "file"` gets a real browser file picker; the raw bytes
  are POSTed to a new endpoint, staged to a temporary folder, and the tool
  receives back a plain file path - identical to how an existing `path` field
  already works. Deliberately not multipart/form-data, since PowerShell's
  built-in web server has no native parser for it and there is no benefit here:
  only ever one file at a time.
- **Bulk group membership export** - uploads a CSV of device names or serial
  numbers and resolves each to the Entra Object ID needed for Entra's own
  "Bulk operations > Import members" feature on a group's Members page. The
  output matches that feature's own template exactly - same column header, same
  UTF-8-with-BOM and CRLF formatting, confirmed against a real file exported
  from Entra rather than assumed from documentation - so it can be uploaded
  there directly with no reformatting. A second sheet lists anything that
  couldn't be matched, with why. Resolution is batched in three passes (name,
  then serial for what's left, then the Entra Object ID lookup), not one
  request per device. The uploaded file is deleted once the run finishes,
  success or failure, since it may carry device or user information.
- Auto-detected template downloads: a tool that ships its own `template.csv`
  gets a download link on its card for free, with no new manifest field every
  other tool would have to ignore.
- `.gitattributes`, declaring `.png`, `.jpg`, `.xlsx` and `.zip` as binary, so Git can't
  mistake an image or workbook for text and corrupt it on commit.

### Changed
- README: "Requirements" replaced by a "Prerequisites" section listing all ten delegated
  Graph permissions the app uses and what each is for, with a note on
  `DeviceManagementScripts.Read.All` - split out by Microsoft in July 2025 and the usual
  cause of a 403 on script sources in older app registrations.
- README: quick start now points to Releases and includes the Windows `Unblock-File`
  step a downloaded zip needs. The architecture section uses the same diagram as
  `docs/architecture.md`. An incomplete coverage source is documented as showing its
  reason.
- The static checker reads allowed manifest field types from `core/Tools.ps1` instead of
  keeping its own copy, so the app and its checks cannot disagree.

### Fixed
- README said "No app registration required"; Connect rejects an empty client ID, so one
  is always required. Also removed a stale tool count, and corrected that CI runs on
  pushes to `main`.
- `.gitignore` excluded every `.xlsx` and `.csv`, so the four sample workbooks in
  `docs/samples/` had never reached the repository, and a tool's `template.csv` would
  have been left out of every commit. Both are now excepted explicitly.
- Live test logs, which record the tenant ID, were written inside the repo folder and not
  ignored. Now ignored.

## [1.1.1] - 2026-09-22

Two user-facing changes, an integrity fix to the codebase, and developer-facing
additions that don't change the app's behaviour: a functional test harness and a proper
architecture diagram.

### Added
- `tests/Invoke-LiveTests.ps1` - a functional test script for the eight production
  tools against a real tenant. Signs in once using the app's own real PKCE flow,
  then runs each tool in its own isolated runspace (mirroring exactly how a live
  job is isolated in `core/Jobs.ps1`), so two tools' same-named local helpers can
  never collide. A tool passes if it completes without a thrown exception, its own
  result status is not "Failed", and its declared output path actually exists
  afterward. Prompts once per platform for a real device to test the journey
  tools against; the tenant-wide tools need no input. Prints a summary table and
  writes a timestamped log. Needs a real tenant, so it never runs in CI.
- The live test script sweeps every boolean and select field a tool declares in
  its own manifest, not just the default parameter set - one field varied per case
  against an otherwise-default baseline, so a failure names the one input that
  changed. A capability added to any tool's manifest tomorrow is tested on the very
  next run, with no change to this script. Text fields and multiselects stay at
  their default, since the script has no domain knowledge to fill them meaningfully.
- `tests/live-test-expectations.json` - a small, centrally maintained set of
  file-existence rules the live test script checks after a case's baseline pass
  already holds. A rule says "when this field is set to this value, a file
  matching this pattern should exist" - checked with Test-Path against a glob,
  nothing more. It never opens a file to look inside it: whether a value is
  correct stays a human's call, always. One rule to start - writeHtml=true
  should produce an .html file - and more can be added to this one file as
  they're identified, rather than as new scripts.
- `docs/images/architecture.svg` - the four-layer architecture diagram, replacing
  the ASCII version in `docs/architecture.md`.

### Changed
- Failure reasons are now shown next to "incomplete" everywhere a coverage table
  appears - the launch page, every HTML report, and the workbook export. Previously
  the bare word "INCOMPLETE" gave no way to tell a permission gap from a throttle
  from a genuinely empty result; it now reads, for example, "0 item(s), incomplete
  : 403 (Forbidden)." - the HTTP code and reason only, no explanatory prose, since
  the audience already knows what a 403 means.

### Fixed
- Windows device journey never filtered its device search by platform, so a device
  name shared with a Mac or Android device could return the wrong one. Now scoped
  to Windows devices only, matching how every other platform's journey tool already
  worked.
- `core/Graph.ps1` contained a genuine duplicate: three functions were each defined
  twice, identically. PowerShell silently uses the last definition, so this was
  correct by luck rather than by a passing check - the duplication itself had gone
  undetected across several builds. Rebuilt with exactly one copy of each function.
- The project's own duplicate-function check used a regex that truncated function
  names at the first digit, weakening it for any name containing one (the codebase
  already has one: `...Base64Script`). Two distinct functions sharing a prefix
  before a digit would have been falsely flagged as duplicates. Fixed to allow
  digits in the checked portion of a name.

## [1.0.0] - 2026-09-18
 - 2026-09-18

Three new platforms, a themed interface across the launch page and every HTML
report, and a launch page reorganised around the Intune admin centre's own
navigation rather than an internal taxonomy of our own. This is the first
version built against real output from every tool it ships.

### Added

**New tools**
- **iOS/iPadOS device journey** - how an iPhone or iPad was enrolled, covering every
  enrolment route (Automated Device Enrolment, Apple Configurator, direct enrolment,
  device enrolment manager, account-driven and Company Portal). Where the route is
  ADE, shows the enrolment token, its expiry, and the profile's supervision and
  user-authentication settings. Volume Purchase Program token expiry is checked and
  surfaced as a warning; per-app licensing (VPP, Store, line of business, web clip) is
  shown against each app that reaches the device, derived from the app's own type
  rather than inferred from the presence of a token.
- **macOS device journey** - the same shape, adapted to how Intune actually enrols a
  Mac. Handles the case where a device enrolled through Setup Assistant (legacy) has
  no Microsoft Entra device object at all: rather than failing, the report states
  plainly that the device is managed but that nothing targeted at a group can reach
  it. Reports FileVault state and user-approved (supervision) state, and names the
  enrolment route as ambiguous rather than guessing when Intune's own
  `deviceEnrollmentType` value cannot distinguish ADE from Apple Configurator.
- **Android device journey** - covers all five Android Enterprise enrolment modes
  (fully managed, dedicated, corporate-owned work profile, and both AOSP variants),
  plus personally-owned work profile (BYOD), which is labelled "Personally owned -
  work profile (BYOD)" rather than "unmanaged" since the device is fully managed
  inside its work profile. Shows the Device Owner enrolment token's name, type,
  expiry, creation date and usage count where one applies.
- **Windows device journey** superseded the original Autopilot-only version: it now
  resolves any enrolled Windows device first and treats an Autopilot registration as
  optional enrichment, so co-managed, hybrid joined and manually enrolled devices are
  covered rather than only Autopilot ones.

**Interface**
- A light and a dark theme (Portal Light / Portal Dark, matching Fluent's own
  palette), on the launch page and on every journey tool's HTML export. Follows the
  system preference by default; a toggle overrides it and the choice is remembered.
  An exported report opens in whichever theme was active when it was generated - the
  theme travels with the run, since the report opens from a file and cannot read the
  launch page's saved choice itself - and always prints on a plain white background
  regardless of screen theme.
- The launch page is grouped under the Intune admin centre's own section headings
  (Devices - by platform; Apps and policies - assignments; Scripts and remediations;
  Tenant administration - audit logs) instead of an internal taxonomy, and platforms
  are ordered the way Intune orders them rather than alphabetically.
- Each section's own heading now carries the description once, rather than every tool
  in a terse section repeating a near-identical sentence that differs only in platform
  name.
- The app's own version is shown in the status bar, defined once in
  `Start-IntuneSightline.ps1`.
- A background check against the latest GitHub release shows a banner with a link
  when a newer version exists. Notice only - no download, no install. Fails silently
  offline or before the first release exists, and never blocks the page.
- A Stop button on any running job. Stopping is best-effort - a Graph request already
  in flight completes first - and any file already written is left in place, marked
  as partial rather than complete.

**Core**
- Graph JSON batching (`core/Batch.ps1`), applied to assignment inventory - roughly a
  20x reduction in round trips on a large tenant, since assignments are a navigation
  property with no bulk endpoint.

### Changed
- Device 360 is hidden from the launch page while its role relative to the platform
  journey tools is reconsidered. The tool and its code are unchanged and can still be
  run directly; only its place in the list is affected.
- Assignment status on an app or policy now distinguishes Required, Available,
  Uninstall and Excluded for apps, and Included/Excluded for policies, read from each
  assignment's own `intent` rather than inferred from its target type alone - a
  Required and an Available app were previously indistinguishable.

### Fixed
- The static checks now resolve each tool's function calls against that tool's own
  code plus core only, rather than against every tool's code pooled together. The
  pooled version could not catch a tool calling a function that only existed in a
  different tool, which surfaced only once the two were loaded independently by the
  running app.
- A tenant's live Application (client) ID and Tenant ID were hardcoded as placeholder
  text in the connect form and would have shipped in the public repository. Replaced
  with a neutral all-zero placeholder, and the checks now fail the build on any GUID
  in a committable file other than the Microsoft Graph PowerShell client ID and that
  placeholder.
- Three PowerShell pitfalls that had each caused a runtime failure are now checked for
  on every file: a function defined twice, where PowerShell silently uses the last
  definition and edits to the first are lost; `@()` placed inside an `if` block rather
  than around the whole expression, which unrolls a single-item result to a scalar and
  breaks the very first `.Count` call on it; and `.Add()` called on something that was
  never declared as a list.

## [0.9.0] - 2026-09-13

First public release. Every tool runs, each has been exercised against a production
tenant, and none has months of use behind it — hence 0.9 rather than 1.0.

### Added

- **Assignment inventory** - one row per assignment across nine policy surfaces, with
  unassigned and tenant-wide breakouts.
- **Device journey** - traces one or two devices from how they were joined and enrolled,
  through group membership, to everything that reaches them. Works for Autopilot,
  co-managed, hybrid joined and manually enrolled devices alike, and states the join type
  and the account that performed the join. Writes a self-contained HTML report showing how
  each membership arose.
- **Change history** - audit events by date range, optionally narrowed to one object or
  one account, including deletions and renames.
- **Device 360** - up to five devices side by side, with Intune's own conflict verdict and
  a differences view.
- **Orphaned and unassigned** - policies assigned to nothing, assignments pointing at
  deleted or empty groups, unused assignment filters.
- **Recover scripts** - remediation, platform, macOS and Win32 script bodies decoded to
  disk.
- Browser sign-in on the loopback interface, requesting `.default` so no permission is
  asked for that the tenant has not already consented.
- Graph JSON batching in core, used by assignment inventory.
- Workbook and CSV output, every export carrying tenant, collecting account, permissions
  held, and per-source coverage.
- Static checks with no tenant dependency, run in CI on every push and pull request.

### Known limitations

See the README. In short: encrypted OMA-URI values cannot be read, audit filtering is
limited to date and activity type, Entra does not record when a device joined a dynamic
group, and Conditional Access and on-premises policy are out of scope.
