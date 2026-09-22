type approval_item = {
  ap_token : string;
  ap_trace_id : string;
  ap_actor : string;
  ap_action_type : string;
  ap_target_type : string;
  ap_target_id : string option;
  ap_payload : Yojson.Safe.t;
  ap_delegated_tool : string;
  ap_created_at : string;
  ap_expires_at : string option;
  ap_summary : string;
}

type approval_snapshot = {
  aps_items : approval_item list;
  aps_actor_filter : string option;
  aps_filter_active : bool;
  aps_visible_count : int;
  aps_total_count : int;
  aps_hidden_count : int;
}

type approval_decision =
  | Confirm
  | Deny

type pending_approval_action = {
  paa_token : string;
  paa_decision : approval_decision;
}

type approval_gate_transition =
  | Gate_blocked_inflight
  | Gate_arm of pending_approval_action
  | Gate_submit

type confirm_outcome =
  | Completed of Yojson.Safe.t
  | Deferred of Yojson.Safe.t
  | Execution_failed of Yojson.Safe.t * string

module Flow : sig
  type generation = private int
  type t

  val initial : t
  val action_inflight : t -> bool
  val observe : t -> generation
  val begin_action : t -> (t * generation, [ `Already_inflight ]) result
  val finish_action : t -> generation -> t * bool
  val is_current : t -> generation -> bool
end

(** Which answer of one background listing may still replace what is on
    screen. A listing is superseded two ways and they are different clocks:
    by an operator press ({!Flow}, one for every listing) and by a later
    fetch of the same listing (this, one per listing). One counter for both
    made unrelated listings drop each other's answers (#37461); the press
    clock alone let an older fetch of a listing overwrite a newer one that
    had already landed (task-1672). *)
module Listing_order : sig
  type t
  type ticket

  val initial : t

  (** Number the next fetch of this listing and note the press generation
      it goes out under. Does not move the press clock. *)
  val dispatch : t -> Flow.t -> t * ticket

  (** [true] when no press opened since the fetch went out and no later
      fetch of the same listing has already been admitted. An admitted
      answer becomes the newest; a refused one changes nothing. *)
  val admit : t -> Flow.t -> ticket -> t * bool
end

val decode_snapshot : Yojson.Safe.t -> (approval_snapshot, string) result
val approval_decision_wire : approval_decision -> string
val approval_payload_for_terminal : Yojson.Safe.t -> string
(** Serialize the raw typed payload, then escape terminal control code points.
    The raw payload remains unchanged for confirmation semantics. *)
val approval_gate_transition :
  inflight:bool ->
  pending:pending_approval_action option ->
  token:string ->
  decision:approval_decision ->
  approval_gate_transition
(** Reindex the selected approval across a snapshot replacement, falling back
    to the bounded numeric cursor only when that token is absent. *)
val reconcile_cursor :
  current_items:approval_item list ->
  cursor:int ->
  next_items:approval_item list ->
  int
val decode_confirm_response :
  expected_token:string ->
  expected_decision:approval_decision ->
  Yojson.Safe.t ->
  (confirm_outcome, string) result
