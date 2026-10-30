(** Shared original absorption journal for independent Librarian purposes.
    The purpose adapter owns complete original domain validation and supplies
    an independent scope/kind. Caller still owns the Memory lane and purge fence;
    no scope, decoded transcript or observer projection supplies effect authority. *)
type inputs = Keeper_librarian_runtime.durable_absorption
module type Capture = sig
  type owner
  type t
  val gate_scope : owner -> string
  val gate_kind : string
  (** Host constants/addressing for this purpose; never worker-supplied aliases.
      Stable addressing must not hide old records after a missing/replaced epoch. *)
  val scope : owner -> string
  val keeper_id : owner -> string
  val base_path : owner -> string
  val keepers_dir : owner -> string
  val observe_owner : base_path:string -> keepers_dir:string -> keeper_id:string -> (owner, string) result
  val owner_to_json : owner -> Yojson.Safe.t
  val owner_matches_json : owner -> Yojson.Safe.t -> (unit, string) result
  val request_id : t -> string
  val to_json : t -> Yojson.Safe.t
  val request : t -> (Lane_addon_exact.request, string) result
  val confirm_final : store:Lane_addon_store.t -> t -> Lane_addon_exact.final -> (unit, string) result
  val gate_inputs : t -> Yojson.Safe.t -> (inputs, string) result
  (** Revalidate the complete original domain proposal and derive its original
      absorption inputs. No current-source substitution or provider fallback. *)
end

module Make (Capture : Capture) : sig
  (** Original absorption evaluations for one restored purpose-bound answer.
      Caller holds the existing Memory-lane/purge fence and serializes this owner. *)
  val scope : Capture.owner -> string
  val parent_execution_id : Lane_addon_tool_request_owner.retained -> (string, string) result
  (** Strict header read for discovery joining only; follow with full validation. *)
  val prepare_root : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t -> parent:Lane_addon_tool_request_owner.retained ->
    proposal:Yojson.Safe.t -> request_id:string -> authority:Keeper_librarian_absorb_gate.live_authority ->
    (Lane_addon_request_progress.preparation_intent, string) result
  (** Build and validate the full immutable first gate request before retaining
      its parent preparation intent. Does not publish or evaluate anything. *)
  val recover_root : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t ->
    (Lane_addon_tool_request_owner.retained, string) result
  (** Restore the exact full pending parent preparation and publish only its
      original child ID/request. Confirm Captured before acknowledging the parent.
      An acknowledged missing child refuses. No current live configuration or
      provider is required; callers hold the Memory lane and purge fence. *)
  val validate_root_preparation : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t -> (unit, string) result
  (** Strict read-only full parent intent and child join. An absent pending child
      is valid incomplete publication; an acknowledged missing or progressed
      unacknowledged child is invalid. Performs no repair. *)
  val retain : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t -> parent:Lane_addon_tool_request_owner.retained ->
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
  val resume : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t -> record:Lane_addon_tool_request_owner.retained ->
    live_authority:Keeper_librarian_absorb_gate.live_authority option ->
    before_dispatch:(unit -> (unit, string) Stdlib.result) -> (result, string) Stdlib.result
  (** Strictly rejoin parent judgment and original physical capture. Replay every
      completed request through the common gate derivation. Only the first next
      question without an intent can execute, using a live handle whose captured
      authority is exactly the original one. Pending/aborted requests remain
      unknown. Complete replay and terminal publication require no live config.
      No Memory save, candidate ACK, partition or automatic new attempt occurs. *)
  val validate : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t -> record:Lane_addon_tool_request_owner.retained ->
    (unit, string) Stdlib.result
  (** Strict read-only validation for complete original discovery. Missing next
      unstarted questions and a final pending request are retained states, not
      complete decisions. Malformed evidence is an error. Blocking Store scope;
      offload the complete operation in Eio. *)
  val validate_chain : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t -> (unit, string) Stdlib.result
  (** Read-only complete original chain validation, including an unacknowledged
      exact successor publication intent. A missing acknowledged child refuses.
      Validate all original scopes before invoking local recovery. *)
  val recover_retries : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t -> (unit, string) Stdlib.result
  (** Strictly validate the chain, retain only the same full child from a pending
      successor intent, confirm it and acknowledge that ID. No provider/live
      authority is used. Only ACKed children are runnable. Publication uncertainty
      requires a fresh read; it never permits a different successor or retry. *)
  val latest : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t ->
    (Lane_addon_tool_request_owner.retained option, string) Stdlib.result
  val root : store:Lane_addon_store.t -> owner:Capture.owner ->
    capture:Capture.t ->
    (Lane_addon_tool_request_owner.retained option, string) Stdlib.result
  (** [root] returns the first immutable record even while its successor
      publication is pending. [latest] requires every successor ACK and returns
      the unique runnable leaf. Both strictly validate the complete same-owner
      chain; an actually empty matching chain alone returns None. Historical
      [validate] remains independent of latest status. *)
  val restore_size_evidence : store:Lane_addon_store.t ->
    owner:Capture.owner ->
    parent_execution:Capture.t -> gate_request_id:string ->
    (Keeper_librarian_absorb_gate.run_result, string) Stdlib.result
  (** Strict actual owner/input/parent/transcript/terminal restore. The requested
      ID must be the unique latest original attempt from [latest]; an earlier
      capacity result cannot bypass a pending/unknown successor. Only a complete
      result is returned; the caller separately checks Input_capacity_exceeded.
      Blocking Store scope; offload the complete operation in Eio. *)
  module Inventory : sig
    type t
    type chain
    val read : store:Lane_addon_store.t -> owner:Capture.owner -> (t, string) Stdlib.result
    (** Acquire and strictly decode the complete gate scope once for one
        read-only inventory-validation pass under the caller's serialized owner.
        Not an atomic cross-scope snapshot, global cache or effect authority. *)
    val record_count : t -> int
    (** Gate records this observation decoded. Pass observation only. *)
    val executions : t -> string list
    (** Every execution ID the observed gate records name. *)
    val execution_records : t -> execution_id:string -> Lane_addon_tool_request_owner.retained list
    (** The observed gate records of one execution, in scope order. A caller
        may settle them: [Lane_addon_tool_request_owner.settle] moves a record
        only while the scope still holds it unchanged. *)
    val validate : t -> capture:Capture.t -> parent:Lane_addon_tool_request_owner.retained ->
      (chain, string) Stdlib.result
    (** Bind an already restored original parent to this same-owner observation.
        Validate complete lineage and derive the parent-preparation verdict without rereading the
        gate scope or parent body. Keep this view within the same validation
        pass; mutation, recovery and dispatch must use the fresh-read APIs. *)
    val root : chain -> Lane_addon_tool_request_owner.retained option
    val latest : chain -> (Lane_addon_tool_request_owner.retained option, string) Stdlib.result
    val validate_root_preparation : chain -> (unit, string) Stdlib.result
    val restore_size_evidence : chain -> gate_request_id:string ->
      (Keeper_librarian_absorb_gate.run_result, string) Stdlib.result
  end

end
