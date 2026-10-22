(** Receipt-backed disposition of one original accepted admission. Caller owns
    the existing serialized Memory lane and purge fence. No provider or worker
    is called here; the original completed absorption journal is mandatory. *)
type result = Committed of Lane_addon_tool_request_owner.retained | Pending of string
type preparation = Prepared of Lane_addon_tool_request_owner.retained
  | Reload_original
val begin_gate : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t ->
  record:Lane_addon_tool_request_owner.retained -> gate_root_id:string ->
  authority:Keeper_librarian_absorb_gate.live_authority ->
  (preparation, string) Stdlib.result
(** Retain the full immutable gate request/authority as a prerequisite-publication
    intent while the proposal remains Judged. Only its original ID/request can
    recover locally, and provider execution requires the parent's publication
    acknowledgement. This is not an attempted Memory disposition. *)
val validate : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t ->
  record:Lane_addon_tool_request_owner.retained -> (unit, string) Stdlib.result
(** Read-only complete original execution/proposal/preparation/commit validation.
    Pending root publication is retained Judged work and may lack its child;
    acknowledged publication and commit phases require their exact gate root.
    Commit phases require the complete original chain;
    a pending evaluation remains pending. Missing proof
    cannot mint a replacement gate or execute another judgment. Finished also
    requires matching actual committed candidate receipts. *)
val settle : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t ->
  record:Lane_addon_tool_request_owner.retained ->
  gate_request_id:string -> (result, string) Stdlib.result
(** Persist original commit intent before the locked disposition. Recover an
    uncertain commit only from strict matching Current candidate receipts, or
    a fresh complete negative receipt read before retrying that original local
    disposition. Partial/conflicting/unreadable evidence refuses. ACK only
    verified consumed rows; deferred gaps and new tails remain queued. A
    retained Finished record alone never proves Memory or ACK completion. *)
