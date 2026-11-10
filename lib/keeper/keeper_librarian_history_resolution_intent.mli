(** One original's durable resolution requests. Submission identity is the
    canonical original/guard/actor/reason digest; old refusals remain readable.
    At most one non-refused request and one child intent own an original. *)
type refusal = Observation_changed | No_longer_eligible of string
type child = private { request_id:string; request_digest:string }
type phase = Requested | Refused of refusal | Fenced
  | Child_intended of child | Child_confirmed of child
type memory_commit = private {
  request_id:string;
  receipts:Keeper_memory_os_current_types.durable_range_receipt list;
}
type t = private {
  intent_id:string;
  scope:string;
  original_request_id:string;
  expected:Keeper_librarian_history_resolution_state.guard;
  actor:string;
  reason:string;
  submitted_at:float;
  phase:phase;
  child_payload:Lane_addon_request_progress.preparation_intent option;
  memory_commit:memory_commit option;
}
type error = Invalid of string | Conflict of string | Unavailable of string
  | Publication_uncertain of string
val error_to_string : error -> string
val to_public_json : t -> Yojson.Safe.t
(** Contains no original body, preimage or child request body. *)
val decode_published : scope:string -> request_id:string -> Yojson.Safe.t ->
  (t list, string) result
(** Pure strict envelope decoder for the deployment preflight's owned bytes. *)
val submit : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard -> actor:string ->
  reason:string -> now:float -> (t * bool, error) result
(** The bool is true for an existing identical submission. This only persists
    the intent; no scheduling or Memory effect. Changed payloads refuse while
    active or fenced. A definite refusal permits a new guard, preserving both. *)
val read : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (t list, error) result
val active_for_keeper : config:Workspace.config -> keeper_name:string ->
  (t list, error) result
(** Strict complete scope inventory. Any unreadable intent prevents new work. *)
val reload : store:Lane_addon_store.t -> t -> (t, error) result
val refuse : store:Lane_addon_store.t -> expected:t -> refusal -> (t, error) result
val confirm_fence : store:Lane_addon_store.t -> expected:t ->
  Keeper_librarian_history_resolution_state.t -> (t, error) result
val intend_child : store:Lane_addon_store.t -> expected:t ->
  Keeper_librarian_durable_request.t -> (t, error) result
val confirm_child : store:Lane_addon_store.t -> expected:t ->
  Lane_addon_tool_request_owner.retained -> (t, error) result
val observe_memory_commit : store:Lane_addon_store.t -> expected:t ->
  request:Keeper_librarian_durable_request.t ->
  completed:Lane_addon_tool_request_owner.retained -> (t, error) result
(** Serialized Memory-lane use only. Confirm exact current committed range
    receipts under Memory locks without recovery, then retain that observation.
    A missing/pending/uncertain receipt does not establish completion. *)
val intended_child : t -> Lane_addon_request_progress.preparation_intent option
(** Internal continuation/lineage payload, never an HTTP projection. *)
