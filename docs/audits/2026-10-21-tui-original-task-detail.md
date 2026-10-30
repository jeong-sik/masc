# Independent original Task observation

This unit follows #44580. It removes the inspector's dependency on loaded global
Task rows. The six-axis Keeper/TUI objective and matched actual Before/After are
still incomplete; these are source changes, not installed or measured behavior.

| Boundary | As-Is at #44580 | To-Be in this source |
|---|---|---|
| Original Task absent from global rows | `o` cannot open it; generic detail rendering can fall back to lists | `o` reads the exact recorded Task inside its original inspector |
| Global list still loading or failed | No independent original Task read | Direct GET needs neither global rows nor successful listing |
| Archived Task | Existing live-only detail returns 404 | Independent observation distinguishes archive from live backlog |
| Missing Task | No independent original observation | Typed not observed, separate from retained deletion evidence |
| Read failed or interrupted | No independent Task source | Last Task observation plus its failure remains available |
| Late completed reply | Creation lookup alone has ownership | Task ticket also binds the exact original creation ticket and pending object |
| Detail preparation | No independent document | Full decoded Task formatting shares the response CPU worker |

## Contract and source boundaries

1. **Original identity.** Only a current ready single creation fact enables the
   Task read. The request retains that exact creation ticket and Task id; equal
   titles, the current Keeper Task and global-list membership cannot substitute.
   Creation ambiguity, failure and unobserved facts grant no Task selection.
2. **Workspace.** The real GET uses the existing workspace request precondition
   and admission receipt. It carries the captured endpoint/authority/read epoch;
   UI application separately requires the same current original viewer and
   pending request. Route authentication remains the existing public-read policy.
3. **Server observation.** `/api/v1/dashboard/tasks/inspection` returns versioned
   `masc.task-inspection/v1` with exact Task id and a closed wire state: backlog,
   archive, not_observed or deletion_recorded. Required/verified cleanup is
   historical deletion evidence, not a completion or present physical guarantee.
   Raw cleanup diagnostics and storage paths are not returned. Existing live-only
   `/tasks/detail` remains a distinct contract for its existing consumers.
4. **Strict storage.** The query reads the primary backlog, then the exact archive
   row, then rechecks the primary when absent to cover restoration. Duplicate
   requested identities, unidentified archive rows on a negative lookup and
   unreadable storage are failures. A unique positive archive row may remain
   observable beside unrelated unidentified rows. Only after no Task is observed
   does a unique retained deletion receipt become the result. No recovery-copy
   fallback, storage repair or atomic cross-store snapshot is claimed. Existing
   Task decoding policies, including optional nested-field handling, are retained.
5. **Archive sharing.** Full-row/status readers share the same existing immutable
   file-version archive index and invalidation policy. The old status reader still
   validates the requested Task and its status observation; it gains no new
   lifetime, timer or separate cache. Positive Task formatting uses the existing
   authoritative canonical Goal-link reader; its failure remains unavailable.
6. **Transport and effects.** The original creation transport remains immutable,
   including Unconfirmed after a successful observation. Neither lookup repeats
   creation, cancels/deletes a Task, hands work to a Keeper or declares useful
   work/Goal completion. No Composition, discovery, held-job or backend-batch
   execution policy changes in this unit.
7. **Source retention.** Creation and Task observations are distinct fetched
   sources. A Task refresh retains its last value and error. `r` reads the displayed
   source; `b` returns to creation facts; `[`/`]` select original requests. Leaving
   the source retires its pending UI authority before requesting cancellation of
   its owned job. Physical worker termination is a separate, unmeasured event.
8. **Late replies and input.** The common owned result registry and workspace-read
   envelope deliver the result. Creation ticket, Task ticket, original wrapper,
   pending object, workspace authority/read epoch and viewer must still match.
   Reopening the same original cannot admit its old completed reply. Reads do not
   rewrite input, attachments or references and do not navigate to generic lists.
9. **Preparation and rendering.** Response decoding and full decoded Task JSON
   formatting use one existing CPU worker scope. The UI applies the prepared
   immutable snapshot to the existing observation document. Rendering and
   scrolling use its normal viewport; this does not prove paint latency. No new
   wording/layout/snapshot/PTY or helper/count test is authored.
10. **Costs and quantities.** Global list-row prerequisites for this explicit read:
    one matching row -> none. New original Task observation GETs per explicit `o`
    or Task-source `r`: zero -> one, plus existing workspace binding/HTTP policy.
    Effectful inspector calls remain zero. One lightweight unread Task source is
    added per retained original; inspected originals retain a decoded snapshot,
    formatted sections and last error. Strict backlog/Goal reads, archive-index
    decoding/cache checks, full Task formatting and retained-history/document
    wrapping costs remain. No timer, polling, retry loop, cap, path or environment
    knob is added. These quantities do not establish a speedup.
11. **Evidence and integration.** Seventeen changed ML/MLI files parse (six
    interfaces first). Direct Dune dependencies include `masc_tui_task_creation_read`
    in the HTTP loader and `masc.masc_types` in the reader. This is not typing,
    warning, linking, build or executed-test proof. Independent current-head source
    review and whole-stack integration remain separate. Lower refs, including the
    previously recorded #44199 -> #44211 ancestry gap, are not rewritten here.

## Authored actual protocol/resource scenarios (unexecuted)

Two cases extend `test/test_tui_task_cancel_result.ml`:

- Actually create a Task through MCP and lose its reply. Read its creation fact,
  then use the server's independent JSON response and production decoder/source
  through the owned result registry while global Task rows are empty and the list
  has failed. Preserve new input and original Unconfirmed transport. Actually
  cancel it through MCP, age only its terminal timestamp in the private fixture,
  run the production one-day GC archive pass, and observe the exact full archived
  Task without global rows or handoff.
- Hold a completed actual Task read across close/reopen, accept the fresh request
  and refuse the old one. Read an actually unobserved id, perform real persistent
  Task deletion and observe its retained receipt. Corrupt the real archive and
  retain the last deletion observation plus read failure. Withdraw workspace
  authority before applying another completed read; refuse its foreign-scope
  admission and preserve the other workspace's resources.

These scenarios use in-process MCP, persistent private workspaces, the actual
server JSON producer and result lifecycle. They do not execute Main keys, HTTP
networking/preconditions, provider/model/controller/audio, a TUI/PTY, restart or
paint/input measurements. No tests were run. No local Dune/typecheck/build,
CI dispatch/watch/poll, install/restart/live write, subagents, self approval or
merge. Cold usable input and matched actual cohorts (including failed, cancelled,
interrupted, unstarted and unfinished attempts) remain unmeasured.
