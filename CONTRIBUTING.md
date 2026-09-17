# Contributing

The point of the architecture is that you can add a tool without touching the
shell. If a change requires editing the shell to accommodate one tool, the
manifest needs a new field instead.

## Adding a tool

Create `tools/<your-id>/` with a `manifest.json` and an `Invoke-Tool.ps1`. The
README has a worked example.

## Rules

0. **Validate input in the manifest where you can.** A `text` field may declare a
   `pattern` (a regex) and a `patternMessage`. The shell checks it as the admin
   types and the server re-checks before running, so a typo never costs a long
   collection. Format checks belong here; existence checks belong in the tool,
   before the collection pass.

1. **Never draw UI.** No WPF, no WinForms, no `Read-Host`. Declare input fields
   in the manifest; the shell renders them. This is what keeps tools working on
   every platform.
2. **Read-only.** Manifests declaring a write scope are rejected at load.
3. **Report progress through `$ReportProgress`,** not `Write-Host`. Nothing is
   watching the console.
4. **Write files through core.** Build named datasets and hand them to
   `Save-SightlineDataset`; it writes the workbook or the CSVs and puts the
   provenance in sheet one. Tools do not pick their own paths, formats or
   encodings.

   ```powershell
   Save-SightlineDataset -Folder $folder -Provenance $provenance -Format $format `
       -BaseName 'my-tool' -Sheets @(
           @{ Name = 'Findings'; Rows = @($rows) }
       )
   ```

   The output format field is appended to every tool by core - do not declare
   `outputFormat` in your manifest. Read it with `$Parameters.outputFormat`.
5. **Record coverage honestly.** `Get-SightlineGraphCollection` returns
   `Complete` and `Failure` alongside the items. Pass them through. A tool that
   reports zero results without saying whether collection finished is worse than
   no tool.
6. **Return `New-SightlineToolResult`.** Never return the data itself - the file
   is the deliverable.

## Three PowerShell traps worth knowing

**Collections unroll on return.** `Set-StrictMode -Version Latest` is on, so an
empty `List` comes back as `$null` and `$null.Count` is a hard error. Use
`return @($collection)` in the function and `@()` at the call site.

**`@()` must wrap the whole `if`, not sit inside it.** An `if` block's output
passes through the pipeline, which unrolls a one-element array back to a
scalar - and a scalar has no `.Count` under StrictMode. So this is wrong:

```powershell
$ids = if ($map.ContainsKey($k)) { @($map[$k]) } else { @() }   # breaks on exactly one item
$ids = @(if ($map.ContainsKey($k)) { $map[$k] } else { @() })   # correct
```

Zero and two-plus items both behave; only the single-item case fails, so this
survives casual testing.

**Variables resolve dynamically inside scriptblocks.** A scriptblock invoked
with `&` looks up variables in the caller's scope, so a loop variable can
shadow one the scriptblock expected to find. The progress callback is bound
with `GetNewClosure()` for this reason, but the same trap applies to anything
you write that takes a scriptblock.

## Testing

There is no tenant in CI, so test against your own and say in the PR which
tenant shape you tried - size, platforms, and whether anything came back
incomplete.
