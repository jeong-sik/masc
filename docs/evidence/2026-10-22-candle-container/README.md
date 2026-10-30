# Candle worker: actual container and persistent-volume continuity

Frozen source `d35d2559c56814b38615545a5f4f081304bccc05`, actual Docker execution
on 2026-10-21 15:45:36–39 UTC. This adds a real container/storage boundary to
the separately published Python13 and compiled host26 checks. Those scopes are
not combined into a host/provider/settlement end-to-end claim.

Three actual containers used immutable image
`sha256:dfa4491a3c5c6ffac467e2e2ac2aa58cd46109d38fafea0f2ec0b492ce6ee00a`,
a readonly package mount and the same owned named volume. The first submitted
two requests, then exited normally. The second read the same pending requests
and received **scripted** answered/unknown terminals. The third read those
original terminals after replacement, accepted identical ACK and rejected
changed terminal/input reuse. The final host-request listing was empty.

`docker-commands.json.gz`, the three request/reply files, image/container/volume
inspect outputs and exported original state are primary records. `receipt.json`
records the bounded result. `candle-container-session-20261022.json` records the
exact seven source file digests and original Docker build command. The driver
is included as execution provenance, not a new product regression test.

The [independent evidence review](candle-container-independent-review-20261022.md)
rechecked source bytes, exact container/image IDs, raw command outputs, identical
pending requests and terminal records, and exported-state digests. PASS applies
only to these observed worker/container/persistence boundaries.

Every owned container was removed by exact ID after owner-label validation.
Original state was copied out before the owned test volume was removed. The
unique image remains an artifact. No production original-engine lease cleanup,
host Runtime installation Off/On, actual provider, host Paid exactly-once,
Dashboard or TUI was exercised here. The synthetic caller and scripted terminals
are not production principal admission or provider outcomes. The normal EOF
replacement is not a crash/power-loss or in-flight cancellation test.

Browser stack source has since changed through whole-stack rebase; this frozen
execution does not automatically validate that new source. E01 remains open
until the original host obligation survives actual managed Off/On and settles
under the host-owned model/ledger contracts.
