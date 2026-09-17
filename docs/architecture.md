# Architecture

## Four layers, one direction

```
browser  ──HTTP 127.0.0.1──  shell  ──dispatch──  tools  ──calls──  core
                                                                      │
                                                        Graph (read) ─┴─ files out
```

Calls only ever run left to right. Core never calls a tool; the shell never reaches past
a tool into Graph. The property that matters is that adding the twentieth tool costs what
adding the second did.

## Why the browser is a launcher, not a viewer

An early version rendered results in the page. It was abandoned deliberately.

Report layouts differ per tool, so a rendering shell has to learn something about every
tool it displays — and then grows a special case each time one is added. That is the
opposite of a fixed-size interface.

Tools write files instead. The page shows a list, a progress bar, and a link. It has
three states and does not gain a fourth when tools are added.

Where a tool wants a richer presentation, it generates a self-contained HTML file of its
own. That complexity sits inside the tool, not in the shell, and a mistake there breaks
one report rather than all of them.

## The tool contract

A tool is a folder containing two files.

**`manifest.json`** declares identity, required permissions, and input fields:

```json
{
  "id": "orphan-audit",
  "name": "Orphaned and unassigned",
  "description": "Finds policies, scripts and filters that nothing is assigned to.",
  "note": "Shown above the fields when a tool has a cost worth knowing before pressing Run.",
  "category": "Hygiene",
  "version": "1.0.0",
  "entryPoint": "Invoke-Tool.ps1",
  "requiredScopes": ["DeviceManagementConfiguration.Read.All"],
  "fields": [
    { "id": "includeApps", "type": "boolean", "label": "Include apps", "default": false }
  ]
}
```

Field types: `text`, `number`, `boolean`, `path`, `select`, `multiselect`. A `text` field
may declare a `pattern` and `patternMessage`; the browser validates as the admin types
and the server re-checks before running.

**`Invoke-Tool.ps1`** exposes one function:

```powershell
function Invoke-Tool {
    param(
        [Parameter(Mandatory)] [hashtable]   $Parameters,
        [Parameter(Mandatory)] [scriptblock] $ReportProgress
    )
    ...
    return New-SightlineToolResult -Status 'Success' -OutputPath $folder -Message '...'
}
```

Tools never draw UI, never choose their own output paths, and never return data — the
file is the deliverable.

## Why tools cannot draw their own UI

Native dialogs would tie the tool to one operating system. Declaring fields in the
manifest means the shell renders them, identically everywhere, and a tool can be
contributed by someone who never touches the interface.

## Read-only by construction

Three independent mechanisms, none of which relies on a tool behaving:

1. Sign-in requests `.default` and drops every write scope from the working set.
2. A manifest declaring a write permission is rejected when the tool loads.
3. The static checks fail the build if either rule is broken.

There is no code path through which a tool could write, because none exists to call.

## Coverage, not just results

`Get-SightlineGraphCollection` returns `Items`, `Count`, `Complete` and `Failure`
together. A caller cannot read the results without also being handed whether collection
finished.

Every export records per-source coverage for the same reason. A report that says nothing
was found, without saying whether it looked everywhere, is worse than no report.

## One job at a time

Jobs run in a background runspace so a long collection does not block the HTTP listener,
and only one runs at a time. No admin runs four collections simultaneously, and
serialising removes a large class of state bugs.

The progress callback is bound with `GetNewClosure()` — without it PowerShell resolves
its variables at the call site, so a tool with a variable named `$state` would silently
write progress into the wrong object.

## Batching

`core/Batch.ps1` combines up to 20 Graph requests per call. Assignments are a navigation
property absent from list responses, so a tool walking a policy surface would otherwise
issue one request per policy — a thousand round trips on a large tenant, against fifty
batched.

Three things about `$batch` are easy to get wrong and are handled: the batch returns 200
even when requests inside it failed, responses come back in any order and must be
correlated by id, and throttled sub-requests are not retried automatically.

## What is deliberately not here

**No module dependency.** Microsoft Graph is a REST API; the SDK is one wrapper over it.
Calling the endpoints directly means nothing to `Install-Module` before a first run.

**No app registration requirement.** Requiring one would exclude scope-tagged and
delegated admins who cannot create one, and they are exactly who this is for.

**No computed conflict analysis.** Intune evaluates conflicts server-side across every
policy targeting a device, including policies the signed-in admin cannot see. Comparing
settings locally would run only on what this account could read, so under scope tags it
would report "no conflicts" on a device that has one. A false clean result is worse than
no result.
