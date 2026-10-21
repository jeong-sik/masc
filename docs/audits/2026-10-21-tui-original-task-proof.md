# Original Task history and retained submission evidence

This follows #44597. The six-axis Keeper/TUI objective and matched actual
Before/After remain incomplete. This document describes source changes only.

| Boundary | As-Is at #44597 | To-Be in this source |
|---|---|---|
| Original Task evidence path | Current/archive Task observation only | Same original inspector has independent history and submission sources |
| Stored events | Existing summary omits verdict reasons/authority fields | Complete original event records remain readable, with exact observed submission ids |
| History continuation | Available only in separate Task/Tools paths | h starts a fresh prefix; H reads its known older cursor |
| Historical evidence | Endpoint requires a live awaiting Task and chooses its current submission | Exact Task + submission read works for retained requests after settlement/archive |
| Evidence refresh failed | No original-inspector evidence source | Last evidence plus refusal/failure retained; r stays pinned |
| Late response | Task/creation ownership only | History/evidence tickets share original wrapper, creation ticket, workspace and pending ownership |
| Binary artifact | Existing verification pane has pixel support | Original inspector exposes full identity/preview availability; pixel drawing remains outside this unit |

## Source preservation and boundaries

1. **Original identity.** Reads start only from a ready single original creation
   fact. History names that exact Task; verification ids come from ready Task or
   history observations. `v` is an explicit next/first selection, and evidence `r`
   keeps its exact prior key. No global row, successor Task, title or current
   assignee substitutes for the original. No automatic discovery/read fan-out.
2. **History protocol.** The existing versioned page reader validates Task,
   cursor echo, continuation and per-response demand. Raw records remain display
   data; control uses validated ids. Optional verification ids are exact nonblank
   strings; duplicate or malformed fields fail. First-observed identity order is
   retained across pages with an immutable set. No page count/total history cap,
   timer or retry loop is added. Prefix exhaustion is not lost-history proof.
3. **Full event evidence.** Existing typed summaries remain available to other
   consumers. The immutable prefix also retains complete original records, so the
   explicit inspector does not drop verdict reasons, notes, actor/authority or
   other recorded fields. JSON preparation occurs with decode on the CPU path.
4. **Exact retained submission.** The existing CanAdmin evidence route now
   requires both `task_id` and `verification_id`; TUI callers send both. It reads
   that durable request without a live Task/awaiting-status dependency. Missing
   requests remain unavailable; supersession/deletion retention policy is not
   changed. A historical snapshot is not current status or approval permission.
5. **Store/security.** The request must be a single exact path component and its
   durable header must name that same id and requested Task. Producer identity
   comes from the recorded header, never a successor assignee. A trusted CanAdmin
   caller supplies operator identity. Existing producer-bound authority reads
   keep their producer check and also reject mismatched request headers. No new
   permission, raw file path request, verdict authority or evidence mutation.
6. **Workspace and delivery.** History/evidence HTTP reads use the existing
   captured workspace precondition/receipt. Common owned results retain the
   workspace-read envelope. UI application requires original viewer/wrapper,
   creation ticket, source ticket, pending object and authority/read epoch. Shared
   begin/complete helpers apply the same ownership rule to all four inspector
   sources. A completed response cannot acquire a reopened or foreign scope.
7. **Failure retention.** Task, creation, history and evidence remain separate
   fetched sources. Access-unavailable evidence is a failure, preserving prior
   content beside its reason. Transport, interpretation and workspace failures
   stay distinguishable. Closing/source changes retire pending UI authority and
   request only owned observation cancellation; physical termination is separate.
8. **Effects and input.** Creation transport remains immutable, including
   Unconfirmed after evidence reads. No replay, queue handoff, status/verdict
   change, Goal completion or input/attachment/reference rewrite is introduced.
   A captured submission is evidence of submission, not useful-work completion.
9. **Document content.** All captured notes, collaboration text/hash, text
   artifacts and unreadable/truncated causes remain readable. Binary captions
   include full reference/hash and preview availability; this diagnostic reader
   does not draw pixels. Existing verification pixel rendering is unchanged.
10. **Costs/structural Before-After.** Original-inspector history/evidence reads:
    unavailable -> one existing endpoint GET per explicit action. Live backlog
    lookups for the operator evidence route: one -> zero. Creation/effectful
    inspector calls remain zero. Added costs include two lightweight unread
    sources per original, captured records/id set, retained evidence snapshots,
    full-prefix formatting/concatenation and existing HTTP/worker/cancellation
    work. No latency, heap or paint speedup is inferred from these quantities.
11. **Evidence/integration.** Sixteen ML/MLI files parse (five interfaces first).
    Parsing-only checks and direct dependency inspection
    do not prove typing, warnings, linking, execution or visible UI. The reader's
    direct dependency on the existing binary-caption producer is declared.
    Independent current-head review and stack integration remain separate;
    external lower refs and recorded ancestry gaps are preserved.

## Authored actual protocol/resource scenarios (unexecuted)

Two cases extend `test/test_tui_task_cancel_result.ml`:

- Actually create a Task through MCP and lose its response, claim/start/submit,
  commit a real rejection, submit again and approve. Age only the terminal fixture
  timestamp and run production GC. Read the archived Task's history through actual
  one-event pages and the production result registry; retain both exact submitted
  ids. Read both persistent snapshots after archival, preserve new input, empty
  global rows, original Unconfirmed transport and no handoff.
- Actually submit/settle a Task, read its persistent evidence, corrupt the real
  request and then mismatch its header id. Failed refreshes retain the prior
  evidence. Restore it, hold a completed read across close/reopen and refuse the
  old ticket. Another Task cannot borrow the snapshot; a non-component request id
  is rejected. Hold a history reply across workspace withdrawal and preserve the
  other workspace's actual resources and the restored evidence bytes.

Existing current-verification resource fixtures are adapted to the required
exact query. No helper/count, wording/layout/snapshot or PTY tests are added.
These scenarios do not execute Main keys, HTTP authentication/networking,
provider/model/controller/audio, a TUI/PTY, process restart or pixels/paint/input
measurements. Tests are not run. No local Dune/build/typecheck, CI dispatch/watch,
install/restart/live writes, subagents, self approval or merge. Matched actual
cohorts must still include failed/cancelled/interrupted/unstarted/unfinished work.
