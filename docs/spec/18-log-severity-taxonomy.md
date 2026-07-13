# Structured log severity contract

Log severity is chosen at the typed event emission boundary. Consumers never
recover severity by matching message strings, tool names, provider names, or a
count/time threshold.

| Severity | Typed event meaning |
|----------|---------------------|
| `Debug` | Optional diagnostic detail for an otherwise represented event |
| `Info` | Expected lifecycle, turn, tool, Gate, Job, or persistence success |
| `Warn` | The requested local operation returned an explicit failure while the owning lane remains usable |
| `Error` | The system cannot durably represent or preserve the requested state transition |

Every failure carries its native typed result, Keeper/lane identity,
correlation id, timestamp, and provenance. Repeated failures remain repeated
observations; they are not silently rate-limited and do not escalate into
Keeper pause, risk class, or operator hierarchy. HITL pending is an expected
Gate state and does not imply that the Keeper is blocked.

Historical completion-contract, pause-human, command-syntax, and
provider-specific severity patterns are not part of this contract.
