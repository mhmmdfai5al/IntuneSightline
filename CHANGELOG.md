# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Project checks: the "shell stays ignorant of individual tools" rule was
  matching the section grouping's short platform-name lookup (`SHORT_NAMES` in
  `app.js`) as a violation, since that map necessarily names each journey
  tool's id to pick its label. That lookup is display data, not tool-specific
  behaviour, and is now explicitly exempted; the rule still fires on any
  genuine per-tool reference elsewhere in the shell.

### Added
- App version, shown in the status bar, defined once in `Start-IntuneSightline.ps1`.
- Update notice: checks the latest GitHub release in the background at startup and
  shows a banner with a link when a newer version exists. No download or install -
  notice only.

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
