# Ask follow-up publication without shared notification waits

This follows #44605. The six-axis Keeper/TUI objective and matched actual
Before/After remain incomplete. This is a source change, not measured UI speed.

| Boundary | As-Is | To-Be in this source |
|---|---|---|
| Partial source received | workspace_enqueue waits on the bounded notification stream | Same original result registration publishes a retained partial message |
| Aggregate finished/failed | Terminal waits on that same stream | Terminal is retained after its prior partial messages |
| Read authority | Follow-up messages classified as operation outcomes | Both partial/terminal messages are workspace read observations |
| Physical worker | Main owns separate fork/launch-error code | Existing result/job lifecycle owns dispatch, withdrawal and cleanup |
| Canonical frame | HTTP stream builds string phases inline | One typed server frame producer is used by HTTP and actual protocol scenarios |

## Source boundaries and preservation

1. **Original question/answer.** Existing canonical Ask/answer/Task validation,
   expected workspace, source stream state and source ordering remain in the
   actual reader. No current Keeper Task substitution, answer rewrite, wake,
   queue enqueue, creation, model call or useful-work verdict is introduced.
2. **Publication.** `Masc_tui_workspace_result.launch_observation` uses one owned
   registration. A partial checks that original pending token and appends to the
   same atomic FIFO; terminal publication consumes it. No shared stream capacity
   wait, partial coalescing/drop, timer, count limit or synthetic EOF success.
3. **Order/time.** Actual decoded event and received_ns travel unchanged in the
   original async message. The registry adds its separate ready timestamp.
   Publication order is FIFO across finite UI claims; later publications belong
   to the next batch. Existing fair shared/owned delivery policy is unchanged.
4. **Scope.** Both follow-up message variants are now read observations. Captured
   authority/read epoch, original submission wrapper and Snapshot_read ticket
   still need UI admission. An unchanged answer is not authority to apply a reply
   from a withdrawn read lease. Retention never grants a new workspace or ticket.
5. **Failure retention.** A later failure settles only unfinished sources as
   unconfirmed. Earlier admitted Task/Tool/reaction facts retain their independent
   source state/currentness. Access-unavailable, empty, partial and unreceived
   evidence remain distinct. The existing projection/renderer makes no new claim
   that a stored answer, Tool result or Task status is useful-work completion.
6. **Cancellation and cleanup.** Existing workspace job ownership handles actual
   cancellation and registration release. Caller metadata is released on
   no-switch/launch failure/closed result owner and pre-entry withdrawal. Normal
   worker finalization remains after the actual read/cancellation join. Original
   request checks prevent old cleanup from consuming successor ownership.
   Raw cancellation propagates without synthesizing successful completion.
7. **Session lifetime.** Withdrawal/settlement retire only the original pending
   publisher; published partials remain available until claim or session close.
   Close releases unclaimed entries and prevents late parts/terminals from
   reopening the session. Already claimed batches still require UI admission.
   Closing the result owner is not proof that a worker physically terminated.
8. **Protocol producer.** Started/source/completed are closed frame variants.
   The same formatter emits existing workspace/ready/Keeper/Ask/answer identity
   and actual source fields. HTTP SSE shape and client strict sequence checks
   are unchanged; formatting a completion frame does not authorize completion.
9. **Input and rendering.** Existing UI handlers/projectors consume the original
   messages; draft text, attachments, references and source-specific status
   rendering are unchanged. No helper/count, wording/layout/snapshot or PTY
   tests are added. Source/model evidence is not visible paint or input proof.
10. **Costs and structural Before-After.** For P admitted protocol frames and a
    terminal result, mandatory shared notification publications change from
    P+1 to zero; retained FIFO entries change from zero to P+1. P comes from the
    actual validated protocol, not a runtime cap. Added work includes publisher
    closures, pending-token membership/CAS retries and retained frame/clock bytes.
    Existing reads, validation, callbacks, cancellation, UI claims and rendering
    remain and may still block. The TUI Skill catalogue description is shortened
    while topic-specific reference rules remain; source-byte reduction is not
    measured discovery/selection latency. No latency/heap/paint improvement is measured.
11. **Verification/integration.** Seven ML/MLI files parse (two interfaces first).
    Parsing-only checks and direct dependency
    inspection do not prove typing, warnings, builds, runtime, independent source
    approval or stack integration. Existing one-shot/session result producers
    keep their terminal behavior through the shared dispatch core. External lower
    refs and the previously recorded ancestry gap remain unchanged.

## Authored actual protocol/resource scenarios (unexecuted)

`test/test_tui_ask_followup_result.ml` writes actual canonical Ask/answer and Task
records in private workspaces, invokes real follow-up readers, then uses the
server frame producer, strict decoder, original UI projection and common owned
publication lifecycle:

- Fill the real bounded notification stream. Hold the reaction callback while
  the actual original Task source is admitted. Release it, retain the terminal,
  preserve decoded event order and received clocks, and prove actual worker
  registration cleanup without draining that stream. Preserve new input and Task
  resources; a Todo observation is never promoted to useful-work completion.
- After an actual Task part arrives, disconnect the source callback and retain
  the aggregate failure beside that Task. Finish fresh actual reads and refuse
  messages held across reopening or a changed read lease. Preserve real resources
  and the occupied notification.
- Exercise the absent original turn switch and a session closed after an actual
  partial read. Retain the unstarted failure, suppress later publication after
  close, join the real worker cleanup and preserve Task resources.

These are authored scenarios, not executed results. They do not run Main keys,
HTTP networking/authentication, a TUI/PTY, provider/model/controller/audio,
process restart or paint/input measurements. No local Dune/build/typecheck/tests,
CI dispatch/watch/poll, install/restart/live writes, subagents, self approval or
merge. Failed/cancelled/interrupted/unstarted/unfinished samples remain required
in matched actual Before/After; full goal completion is unproven.
