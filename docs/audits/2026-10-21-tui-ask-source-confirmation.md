# Ask follow-up source confirmation beside its original evidence

| Original facts | As-Is | To-Be |
| --- | --- | --- |
| Latest source unconfirmed, earlier missing/unlinked Task retained | Prior value without per-source status | Earlier observation plus latest-source unconfirmed |
| Latest source unconfirmed, no value ever admitted | Generic observation unavailable | Latest source unconfirmed; no invented read result |
| Retained unavailable wake source during refresh | Pending could be hidden | Original source pending shown |
| Retained unavailable wake source after partial failure | No source confirmation notice | Earlier observation plus latest-source unconfirmed |
| Fresh Task/source admitted before sibling transport failure | Fresh source stays received in model | Same fresh source; no whole-response downgrade |
| Fresh unavailable source merges earlier positive evidence | Received with non-current retained facts | Same receipt/freshness distinction and existing retained-evidence warning |

The model already distinguishes `Followup_pending`, `Followup_received` and
`Followup_unconfirmed`. A new read retains old values and clears positive-value
current flags. Its strict stream retains independently admitted source results;
completion marks only remaining pending sources unconfirmed. The renderer
previously gave received and unconfirmed the same empty notice, and omitted the
notice entirely for an unavailable reaction value. Negative Task constructors
have no positive-evidence current flag, making that omitted source state material.

Only the original answer-feedback projection changes. Retained values receive
their actual source status; no-value unconfirmed reads stay unknown. Unconfirmed
source notices use warning style, including an earlier unlinked Task. The normal
Task freshness text no longer presumes the latest read finished while a new read
is still pending. Received sources keep their original styling and positive
freshness checks. A received unavailable source can retain older positive values
without recertifying them; existing current/completeness diagnostics remain.

Original Ask/answer/stimulus/Task identity, protocol ordering, source admission,
retention, request cancellation, JSON observations and action authority are
unchanged. No synthetic Task, current-Keeper Task fallback, request, timer,
retry, state, cache or effect permission is added. Source unconfirmed does not
prove physical read entry, failure/cancellation cause, worker exit or absence.
Wake delivery, Tool results and Task phase still do not establish answer
causation, useful work or whole Goal completion.

Additional frame work is source-state/value matching, notice formatting and
wrapping. The existing shared answer-feedback buffer still owns both measured
height and displayed rows. This is an unexecuted source comparison, not a screen
or latency observation. Existing strict-stream and actual state-admission
scenarios cover partial reception/retention but are not executed in this session.
No wording/layout/row/snapshot/PTY test is added. Only the changed renderer
receives parsing, with unchanged model/protocol/authority sources compared to
the parent. No typing/warnings/link/build/behavior test, CI, TUI/controller/
native/model run, install/restart/live write, independent approval or merge is
established. Actual display/input, useful work and matched Before/After remain
unverified; no speedup is inferred.

All six original axes remain open: original Ask/Task useful work, exact
preparation/frozen discovery, ordinary/nested/dynamic/effectful Composition
continuity, held-job/shared-backend continuation, cold usable input/TUI
readability/visibility, and matched actual cohorts retaining failed/cancelled/
interrupted/not-started/unfinished attempts.
