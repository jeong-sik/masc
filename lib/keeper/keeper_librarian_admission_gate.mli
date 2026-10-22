(** Original absorption evaluations for one restored explicit-candidate answer.
    Caller holds the existing Memory-lane/purge fence and serializes this owner. *)
val scope : Keeper_librarian_admission_capture.owner -> string
val parent_execution_id : Lane_addon_tool_request_owner.retained -> (string, string) result
(** Strict header read for discovery joining only; follow with full validation. *)
val retain : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> parent:Lane_addon_tool_request_owner.retained ->
  proposal:Yojson.Safe.t -> request_id:string ->
  authority:Keeper_librarian_absorb_gate.live_authority -> predecessor:string option ->
  (Lane_addon_tool_request_owner.retained, string) result
(** Retain before evaluation. Parent must contain the exact answered proposal.
    Blocking Store scope; offload the whole operation in Eio. An explicit retry names a strictly restored completed unsuccessful gate for
    the same parent/proposal. Uncertainty never permits a replacement attempt. *)
type result = Pending of Lane_addon_tool_request_owner.retained
  | Complete of Keeper_librarian_absorb_gate.run_result * Lane_addon_tool_request_owner.retained
val resume : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  capture:Keeper_librarian_admission_capture.t -> record:Lane_addon_tool_request_owner.retained ->
  live_authority:Keeper_librarian_absorb_gate.live_authority option -> (result, string) Stdlib.result
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
val restore_size_evidence : store:Lane_addon_store.t ->
  owner:Keeper_librarian_admission_capture.owner ->
  parent_execution:Keeper_librarian_admission_capture.t -> gate_request_id:string ->
  (Keeper_librarian_absorb_gate.run_result, string) Stdlib.result
(** Strict actual owner/input/parent/transcript/terminal restore. Only a complete
    result is returned; the caller separately checks Input_capacity_exceeded.
    Blocking Store scope; offload the complete operation in Eio. *)
