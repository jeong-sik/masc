# Original admission capture cost receipt

| Boundary | As-Is | To-Be in source |
|---|---|---|
| Successful admission write | Start clock only; cost folded into whole admission intervals | Immutable returned receipt with attempt start/return clocks |
| Expected capture failure | Original Warn span; ignored Error result at launch | Original failed receipt and existing warning, independent of read outcome |
| No store / missing historical receipt | No separately attributable fact | Explicit unavailable / unobserved; no fabricated success or zero duration |
| Repeated lifecycle observations | No successful capture attribution | Same original receipt carried through producers, UI and late cleanup |
| Comparison | Failed warning spans only | Per-original-attempt capture metric and receipt-state coverage; no double count |

The caller captures original origin before storage, performs that one attempted
append, then assembles its immutable read with the receipt before dispatch. The
original request, submission, admission clock, workspace authority and provenance
are unchanged. No later replacement state or new execution authority is used.
Expected capture failure still permits the original read to run. Unexpected
exceptions/cancellation retain propagation. Routine Info facts omit filesystem
explanations; the existing lazy Warn event retains them.

Both attempt clocks span payload/append through return/error conversion, ending
before lazy warning formatting/output. Returned means append/flush returned;
failed does not prove either was reached or completed. Neither proves fsync,
complete capture, physical worker exit, input readiness, paint or Task progress.
Whole admission intervals retain capture, logging and all other preparation.

Costs: success adds one return clock to the previous entry clock. Expected
failure uses its existing two clocks. Each original read retains a small receipt
and, on failure, the original explanation string. Info JSON repeats small receipt
fields under existing lazy/severity policy. No extra event/backend/flush/timer,
retry, process or settings gate. No Loading or throughput improvement measured.

The strict offline reader retains absent historical receipts as unobserved and
explicit unavailable separately. Exact field/clock checks reject invalid facts.
Every event of an original read must retain its receipt. Present failed receipts
and observed warning spans must agree; contradictions invalidate metrics. The
capture interval is counted once per attempt, with observed/all coverage through
existing metric/Markdown comparison. It is not added to already-inclusive whole
intervals. Filtered, failed, cancelled, unstarted, unfinished and wholly missing
reads stay in the existing denominator. Missing Info/Warn is not capture success.

Two existing actual Ask/answer/Task/frame/store resource cases are extended,
unexecuted. Actual blocked storage and a successful append cross the public
materializer/reader source; returned/failed capture metrics stay independent of
not-started/complete read outcomes. The production local Logs decoder retains
the exact failed original receipt without filesystem text in routine Info.
Existing actual late/partial capsule checks now include receipt identity.
No wording/layout/snapshot/PTY/helper invocation-count tests are added.

Validation is OCaml parsing only (MLI first), Python AST parsing only, source and
diff checks. No consumer/import/CLI/test/build/typecheck/CI/native/model/controller/
audio/PTY execution, install/restart/live write, agents, approval or merge. All
six original axes remain open for actual matched Before/After and visible input/
paint/useful Task progress. A confirmed remaining startup boundary is that the
original settings read is awaited before actual input reader creation; this leaf
does not change that startup contract or invent temporary defaults.
