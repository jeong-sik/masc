# Keeper workbench baseline observation, 2026-10-28

This is a sanitized observation record. The original terminal frames, exact
workspace counts and the measurement script remain private working output
under `artifacts/keeper-ux-audit-20261028/`; they contain workspace data and
are not part of this shared record. No frame is an after-change capture.

At 09:09:53 UTC, a separate PTY ran the installed `masc-tui` binary with the
operator's resolved base path, a loopback server and `--refresh 30`, in a macOS
sandbox denying writes under that workspace's `.masc` directory. Host paths
and the local port are omitted from this shared record. Navigation was limited
to opening the Keepers surface. The existing operator TUI was not modified.
The server's `/health?full=1` identified the same effective workspace and
reported the same source commit as the installed TUI,
`ce29779050f54bc8a6d1bafd0b67d03230a1f344`. The installed binary's SHA-256
was `43b664337c707e3a72affb75feb862bb615814331f8a61ff1e37e52f67a1b630`.
This observation does not identify or verify any later PR build.
The health response was observed during the run but its raw body was not
retained; the server identity association here is a recorded observation,
not an independently replayable response receipt.

The PTY was resized, and screen text was decoded with pyte:

| PTY cells | Observation |
| --- | --- |
| 190 × 52 | The roster was visible and many rows contained an ellipsis. |
| 120 × 32 | The roster showed a page of the fleet; many rows contained an ellipsis. |
| 80 × 24 | A smaller page was visible; its rows contained an ellipsis. |

An ellipsis is an observed marker, not proof of a particular amount of lost
text: source content can itself contain one. The body counts in the private
record exclude the header and footer. At
190 × 52, the wide Activity pane began at column 135 and the roster's DETAIL
heading began at column 124; that frame left about ten cells for detail.

An independent second PTY observation at 09:14:50 UTC opened the Schedules
surface at 190 × 52. Its header said the page shows the first 20 requests.
This is a separate observation at a later time, not an atomic
comparison with the roster or the server health snapshot.

The original local frames' SHA-256 values, for future private comparison:

| Frame | SHA-256 |
| --- | --- |
| Keepers 190 × 52 | `fd9275cc4d77b07e0fe9c92f55b9d1c39f3b19edabc50fe89d24ad45c40d18e9` |
| Keepers 120 × 32 | `6e63977713f09c22bcf81736dac28d5567e5fd96d2d24b82a28f49432c5065e7` |
| Keepers 80 × 24 | `4bd88de2f0a0b180e838b779554d14059a437f50b5f0f2378847b36cf124c6e9` |
| Schedules 190 × 52 | `29c61fbf82a5f43baa129ee66a2693afd6118065d62d9de445b2be0e380a28d8` |

This is one observation of a live, changing fleet, not a longitudinal survey.
The sandbox restricted local runtime writes; the separate client still read
the live server. It is not a screenshot of the operator's pre-existing window
or a production verification of the changes proposed in the associated
[research](../../../research/2026-10-28-keeper-workbench.md).
