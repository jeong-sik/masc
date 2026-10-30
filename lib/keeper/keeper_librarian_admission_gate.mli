(** Explicit-candidate adapter of the shared original absorption journal.
    Original absorption evaluations for one restored explicit-candidate answer.
    Caller holds the existing Memory-lane/purge fence and serializes this owner. *)
val scope : Keeper_librarian_admission_capture.owner -> string
val is_scope : string -> bool
val parent_execution_id : Lane_addon_tool_request_owner.retained -> (string, string) result
(** Strict header read for discovery joining only; follow with full validation. *)
val validate_payload :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  read_body:(scope:string -> request_digest:string -> (Yojson.Safe.t, string) result) ->
  owner:Keeper_librarian_admission_capture.owner -> capture:Keeper_librarian_admission_capture.t ->
  parent:Lane_addon_tool_request_owner.retained -> record:Lane_addon_tool_request_owner.retained ->
  (unit, string) result
val validate_preparation_payload :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  read_body:(scope:string -> request_digest:string -> (Yojson.Safe.t, string) result) ->
  owner:Keeper_librarian_admission_capture.owner -> capture:Keeper_librarian_admission_capture.t ->
  parent:Lane_addon_tool_request_owner.retained -> (unit, string) result
(** Pure current payload/source/binding checks for deploy preflight. Does not
    inspect live ownership, read host proofs or grant effect authority. *)
val prepare_root : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> parent:Lane_addon_tool_request_owner.retained ->
  proposal:Yojson.Safe.t -> request_id:string -> authority:Keeper_librarian_absorb_gate.live_authority ->
  (Lane_addon_request_progress.preparation_intent, string) result
(** Build and validate the full immutable first gate request before retaining
    its parent preparation intent. Does not publish or evaluate anything. *)
val recover_root : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t ->
  (Lane_addon_tool_request_owner.retained, string) result
(** Restore the exact full pending parent preparation and publish only its
    original child ID/request. Confirm Captured before acknowledging the parent.
    An acknowledged missing child refuses. No current live configuration or
    provider is required; callers hold the Memory lane and purge fence. *)
val validate_root_preparation : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> (unit, string) result
(** Strict read-only full parent intent and child join. An absent pending child
    is valid incomplete publication; an acknowledged missing or progressed
    unacknowledged child is invalid. Performs no repair. *)
val retain : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> parent:Lane_addon_tool_request_owner.retained ->
  proposal:Yojson.Safe.t -> request_id:string ->
  authority:Keeper_librarian_absorb_gate.live_authority -> predecessor:string option ->
  (Lane_addon_tool_request_owner.retained, string) result
(** Retain before evaluation. Parent must contain the exact answered proposal.
    Blocking Store scope; offload the whole operation in Eio. An explicit retry names a strictly restored completed unsuccessful gate for
    the same parent/proposal. A failed original terminal is Refused/Execution;
    its exact successor intent and ACK must durably precede child execution.
    Uncertainty never permits a replacement attempt. *)
type result = Pending of Lane_addon_tool_request_owner.retained
  | Complete of Keeper_librarian_absorb_gate.run_result * Lane_addon_tool_request_owner.retained
val resume : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> record:Lane_addon_tool_request_owner.retained ->
  live_authority:Keeper_librarian_absorb_gate.live_authority option ->
  before_dispatch:(unit -> (unit, string) Stdlib.result) -> (result, string) Stdlib.result
(** Strictly rejoin parent judgment and original physical capture. Replay every
    completed request through the common gate derivation. Only the first next
    question without an intent can execute, using a live handle whose captured
    authority is exactly the original one. Pending/aborted requests remain
    unknown. Complete replay and terminal publication require no live config.
    No Memory save, candidate ACK, partition or automatic new attempt occurs. *)
val validate : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> record:Lane_addon_tool_request_owner.retained ->
  (unit, string) Stdlib.result
(** Strict read-only validation for complete original discovery. Missing next
    unstarted questions and a final pending request are retained states, not
    complete decisions. Malformed evidence is an error. Blocking Store scope;
    offload the complete operation in Eio. *)
val validate_chain : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> (unit, string) Stdlib.result
(** Read-only complete original chain validation, including an unacknowledged
    exact successor publication intent. A missing acknowledged child refuses.
    Validate all original scopes before invoking local recovery. *)
val recover_retries : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> (unit, string) Stdlib.result
(** Strictly validate the chain, retain only the same full child from a pending
    successor intent, confirm it and acknowledge that ID. No provider/live
    authority is used. Only ACKed children are runnable. Publication uncertainty
    requires a fresh read; it never permits a different successor or retry. *)
val latest : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t ->
  (Lane_addon_tool_request_owner.retained option, string) Stdlib.result
val root : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t ->
  (Lane_addon_tool_request_owner.retained option, string) Stdlib.result
(** [root] returns the first immutable record even while its successor
    publication is pending. [latest] requires every successor ACK and returns
    the unique runnable leaf. Both strictly validate the complete same-owner
    chain; an actually empty matching chain alone returns None. Historical
    [validate] remains independent of latest status. *)
val restore_size_evidence : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
  parent_execution:Keeper_librarian_admission_capture.t -> gate_request_id:string ->
  (Keeper_librarian_absorb_gate.run_result, string) Stdlib.result
(** Strict actual owner/input/parent/transcript/terminal restore. The requested
    ID must be the unique latest original attempt from [latest]; an earlier
    capacity result cannot bypass a pending/unknown successor. Only a complete
    result is returned; the caller separately checks Input_capacity_exceeded.
    Blocking Store scope; offload the complete operation in Eio. *)
