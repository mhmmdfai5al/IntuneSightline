# Security

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately
through GitHub's "Report a vulnerability" option on the Security tab, or by
email to the address on my GitHub profile.

Expect an acknowledgement within a few days.

## What this tool does with your tenant

**It only reads.** Every Graph call is a GET. There is no code path that writes,
modifies, or deletes anything in Intune or Entra.

**Write permissions are discarded at sign-in.** Scopes are filtered to reads
before anything else runs, and a tool manifest declaring a write permission is
rejected at load. IntuneSightline also attempts to exchange the token for a
narrower grant, though Entra usually reissues every consented scope regardless
of what was asked for. When that happens the startup output says so plainly
rather than implying a guarantee it did not get.

**Nothing is sent anywhere.** The only network destinations are
`login.microsoftonline.com` and `graph.microsoft.com`. There is no telemetry,
no analytics, and no external service.

**The web interface is loopback only.** The local server binds to `127.0.0.1`
and is not reachable from the network.

**Tokens are never written to disk.** They exist in memory for the life of the
process. `config.json` stores only tenant and client identifiers.

## What exports contain

Exports describe your tenant configuration and may include device names, user
principal names, group names, and policy contents. Treat them as you would any
configuration extract. Every export folder carries a `_provenance.txt` recording
the tenant, the collecting account, and what was and was not covered.
