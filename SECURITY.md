# Security

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately
through GitHub's "Report a vulnerability" option on the Security tab, or by
email to the address on my GitHub profile.

Expect an acknowledgement within a few days.

## What this tool does with your tenant

**It only reads.** No code path creates, changes or deletes anything in Intune or
Entra. Most Graph calls are GETs; batched reads travel as one POST to Graph's `$batch`
endpoint, and every request inside it is a GET.

**Write permissions are discarded at sign-in.** Scopes are filtered to reads before
anything else runs, and a tool manifest declaring a write permission is rejected at
load. IntuneSightline also asks Entra for a token narrowed to reads, but Entra usually
reissues every consented scope regardless. When it does, the page lists the write
permissions the token carries and states that they are never used.

**Nothing about your tenant leaves your machine.** Tenant data goes only between
`login.microsoftonline.com`, `graph.microsoft.com` and your computer. The one other
call is an update check at startup to `api.github.com`, which sends nothing about your
tenant. There is no telemetry or analytics.

**The web interface is loopback only.** The local server listens on `127.0.0.1` and
`localhost` and is not reachable from the network.

**Tokens are never written to disk.** They exist in memory for the life of the
process. `config.json` stores only the tenant and application IDs.

**Uploaded files are temporary.** A CSV uploaded to a tool is saved to an `_uploads`
folder and deleted when the run that uses it ends, whether it succeeds or fails.
Anything left over, such as a file uploaded but never run, is cleared the next time
the app starts.

## What exports contain

Exports describe your tenant configuration and may include device names, user
principal names, group names and policy contents. Treat them as you would any
configuration extract.

Every export records the tenant, the collecting account, and what was and was not
covered: on the first sheet of a workbook, in `_provenance.txt` alongside CSV files,
and inside each HTML report.
