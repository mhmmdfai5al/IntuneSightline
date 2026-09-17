## What this changes

<!-- One or two sentences. -->

## Why

<!-- The problem, not the patch. -->

## Testing

There is no tenant in CI, so functional testing is manual.

- [ ] `./tests/Invoke-Checks.ps1` passes
- [ ] Run against a real tenant, with the shape described below

**Tenant shape tested:** <!-- devices, policies, groups; platforms; anything unusual -->

**What the output showed:** <!-- row counts, and whether coverage came back complete -->

## If this adds or changes a tool

- [ ] The manifest declares only read permissions
- [ ] The tool draws no UI of its own; input fields are declared in the manifest
- [ ] Output goes through `Save-SightlineDataset`
- [ ] Coverage is passed through from `Get-SightlineGraphCollection`, not discarded
- [ ] The shell still knows nothing about this tool
