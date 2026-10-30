# Installed SDK 0.6.1.11: same-space dialog observation

The installed CLI independently advanced from 0.6.0.20 to 0.6.1.11.
No upgrade was performed by this probe. The actual version observation
records CLI 0.6.1.11, Chromium 156.0.8078.48 and Node 24.22.1 on stderr.
The complete current and earlier usage guides were byte-identical (23,156
bytes, v2.1.0, SHA256
`fda27e8639c68c6745e63e49199ac39c8aa93d083303512376f9f27577edb25d`).
No newly documented Page method displaced an existing MASC adapter.

## Controlled observation

The fresh goal-owned space was 8/p1. No other browser space was operated.
The original guardian opened the local fixture confirm. Its click receipt
and immediate page.info both reported that dialog with the same frameId.

A second SDK process resumed 8 and wrote its before_info marker immediately
before awaiting page.info. The marker remained at that stage for the next
7.409 seconds, through the recorded observation-before-release. The original
guardian was then explicitly asked to dismiss: dismissDialog returned true,
its next info contained no dialog, and the fixture output was false.
The second process then completed: info contained no dialog and its own
dismissDialog returned false.

This controlled correlation reproduces the process-state asymmetry relevant
to MASC: switching SDK processes is not proven to preserve the opener's
dialog observation/handling. It supports retaining one serial SDK session
while native Page methods continue to own locator/actionability/waits.
The before_info marker is not a packet-level dispatch trace and does not
prove the exact internal blocking cause or a universal hang.

## Completion and limits

The final screenshot was inspected. A third round called finish exactly
once and recorded space 8 absent from immediate listTaskSpaces. The selected
cleanup record retains IDs/ownership and the original record hash while
omitting other spaces' names, profile metadata and page titles. The owned
fixture server was signalled normally; the exact original PID 89169 was
subsequently absent. Parent tool observations reported both SDK executions
exit 0 and the server session exit 143; those terminal outputs were not
redirected into these artifacts and are not independent exported proof.

The opener stayed alive for recovery; no abandoned-dialog recovery case
was induced. Version was observed shortly after the probe, without hashing
each executing SDK process. This is SDK/component evidence, not execution
of the MASC adapter, a new real Keeper run, production readiness or a full
regression. Earlier Keeper evidence remains bound to its recorded SDK/source.

The executed scripts, fixture, direct state files and selected observations
are retained; SHA256SUMS.json covers every file in this directory except itself.
