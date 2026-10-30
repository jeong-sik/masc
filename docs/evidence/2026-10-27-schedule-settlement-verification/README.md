# Schedule recovery and exact-attempt verification

These are three completed, selected Test runs. Their case counts are not added
together as independent end-to-end scenarios; the suites overlap and the heads differ.
The third run executes the pending-settlement runner change at its own exact head.

| Workflow/run | Executed head/ref | Conclusion | Actual suites/cases |
| --- | --- | --- | --- |
| [Test40358821346](https://github.com/jeong-sik/masc/actions/runs/40358821346) | `b07769be553f54d14873c72f9ccd161d4085799e` / `fix/schedule-ledger-commit-result-20261027` | success | Store59 + Consumer58 = 117 PASS; FAIL0/SKIP0 |
| [Test40365052184](https://github.com/jeong-sik/masc/actions/runs/40365052184) | `fa23bf437c3679bb4b7bd7c47eb592675697e370` / `fix/schedule-attempt-authority-20261027` | success | Domain37 + Store66 + Runner24 + Tool wiring64 + Consumer58 + Dashboard HTTP171 = 420 PASS; FAIL0/SKIP0 |
| [Test40374192059](https://github.com/jeong-sik/masc/actions/runs/40374192059) | `c52f799e52d3683bd2a4c624f0f6adfe36015ec9` / `fix/schedule-pending-settlement-20261027` | success | Runner30 + Consumer60 + Tool wiring64 + Lane act7 = 161 PASS; FAIL0/SKIP0 |

Each directory contains `result.json` with the workflow identity, exact head/ref,
conclusion, original archive/member hashes and derivative selection hash.
The run metadata was read again through the terminal Actions REST endpoint
during retention; `api_source` records that new observation and exact gh stdout
hash separately from the earlier suite-log capture.
`selected.json` retains every actual suite header, case verdict and final summary,
with Python `splitlines()` source line numbers. ANSI SGR color codes alone are
removed. The omitted output includes compiler commands, application logs and
Alcotest assertion chatter; its original member hash remains separate from the
selection hash. Raw archives and member bytes stay in ignored capture directories.
The archive hashes were recomputed locally and checked before selection.

The 117-case run exercises the real filesystem/runner/store/consumer composition
for startup recovery: a genuine Running attempt, failed actual publication,
failed first maintenance recovery, restored storage and another cadence with the
same immutable loop state. It also executes the Memory backend/local mirror
commit-result regression. Memory is volatile authoritative state; successful
in-process reread does not establish restart durability. No actual server
process restart or Keeper/model is executed by these cases.

The 420-case run includes that source and adds exact-attempt capability and
candidate fencing. Cases cover old versus newer same-clock attempts, exact typed
receipt replay, absent/invalid/duplicate identity evidence, primary read/write
refusal, historical recovery, cross-scope authority and real candidate replacement
at the runner/store boundary. Domain request cases 7–16 also execute the existing
fixed-offset daily, DST/IANA refusal and cron parser/calendar policies.
Dashboard HTTP171 exercises its selected suite, not the complete rendered UI.

The earlier dependency failure of Test40363492025 at `dd332955dd87d839322f9ac1c566e559cd426ce2`
preceded the successful 420-case run: `Fs_compat` was missing from the direct
library dependencies. No suite executed in that failed run. Its original failure
remains a separate Actions record and is not rewritten as a successful run.
The even earlier startup fixture compile failure and its capture clarification
remain in [the startup bundle](../2026-10-27-schedule-startup-recovery/README.md).

The third run executes PR46248's pending-intent loop through production maintenance
composition, real filesystem publication faults and actual Eio cancellation. Cases
retain the original Retry/Occurrence/Schedule verdict, recurrence anchor and finish
stamp; retry settlement without invoking the consumer; admit healthy unrelated
work; retain progress through typed errors and postprocessing faults; and fence
newer attempts. These are focused suite executions, not actual server binary fault
recovery, whole regression, arbitrary-effect exactly-once, model/provider failover,
production installation or visible TUI behavior.

## Later pending-loop compilation failure

[Test40369739062](https://github.com/jeong-sik/masc/actions/runs/40369739062),
workflow **Test**, head `22014660f23d80e8043846230fdd1a9b3b40278f`, ref
`fix/schedule-pending-settlement-20261027`, completed **failure before suite
execution**. Its four requested aliases produced no case verdicts: the direct
`Eio` reference lacked a dependency. [Its capture](test40369739062/result.json)
retains the exact diagnostic and rendered capture hash. The repair reuses the
already linked canonical cancellation wrapper in commit
`2861571c6fa3b6403cf12980feea3a109dabca71`. Test40371389026 was requested at that
head/ref with the same four aliases; its later failure is recorded below.

[Test40371389026](https://github.com/jeong-sik/masc/actions/runs/40371389026),
workflow **Test**, head `2861571c6fa3b6403cf12980feea3a109dabca71`, the same
ref/four aliases, also completed **failure before suite execution**. The
existing strict warning4 gate rejected the broad settlement-error pattern.
[The exact diagnostic](test40371389026/result.json) preserves both typed-variant
warnings; the fix explicitly enumerates the constructors without weakening
the warning or assertions. It is committed as `4c94fcce84f59c751ebd4867a2f0dee0e3abb188`. Current source
`c52f799e52d3683bd2a4c624f0f6adfe36015ec9` also clarifies permanent authority
refusal and post-tick observation crash semantics. The same four aliases were requested as workflow **Test40374192059**, head
`c52f799e52d3683bd2a4c624f0f6adfe36015ec9`, ref
`fix/schedule-pending-settlement-20261027`; [the original request receipt](test40374192059-request.json)
remains an unchanged request-time snapshot. The later terminal observation and
raw-log verification are separately retained in [the result](test40374192059/result.json)
and [169 selected source lines](test40374192059/selected.json): **161 PASS, FAIL0/SKIP0**.
Both earlier compile failures remain failures; they executed no suites.
