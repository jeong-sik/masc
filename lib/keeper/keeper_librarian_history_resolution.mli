(** Explicit fencing of history originals with distinct absence and Cut APIs.
    Lock order: original source sessions, aggregate Memory, snapshot, owner scope.
    No mailbox call, model/worker RPC, source ACK, cursor movement or cleanup.
    Offload the complete blocking scope, including its lock release, in Eio. *)
type error =
  | Original_absent
  | Ineligible of string
  | Observation_changed
  | Range_already_recorded
  | Already_fenced of Keeper_librarian_history_resolution_state.t
  | Unavailable of string
  | Publication_uncertain of string

type preview = private {
  expected : Keeper_librarian_history_resolution_state.guard;
  scope : string;
  request_id : string;
  request_digest : string;
}

val error_to_string : error -> string
val preview : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (preview, error) result
(** Read-only preparation. Pending Memory publication or unreadable receipts
    refuse; this does not run publication recovery or initialize an epoch. *)
val preview_cut : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (preview, error) result
(** A separate observation of a terminal execution-stage Cut. Acquires and
    releases the real Exact claim during observation, but retains no grant.
    No completed latest execution, gate or replacement preparation, settlement,
    prior range receipt or changed source position is allowed. This API is
    not connected to HTTP submission or automatic successor preparation. *)
val read : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (Keeper_librarian_history_resolution_state.t option, error) result
val fence_serialized : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard ->
  actor:string -> reason:string -> now:float ->
  (Keeper_librarian_history_resolution_state.t, error) result
(** Must run inside this Keeper's existing serialized Memory lane, like
    completed-history publication. HTTP callers must enqueue durable intent,
    not invoke this concurrently with that lane. The old captured Memory
    revision may differ; [expected] is the preview's current basis. A successful
    result proves only the durable fence. There is no followup execution here.
    [Publication_uncertain] may follow a visible write: reobserve this exact ID. *)
val fence_cut_serialized : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard ->
  actor:string -> reason:string -> now:float ->
  (Keeper_librarian_history_resolution_state.t, error) result
(** The Cut counterpart of [fence_serialized]. Holds the real original
    claim through publication and strict readback within the same source and
    Memory critical section. Preserves the original Unknown and its source;
    grants no successor, Memory write or ACK. The existing continuation worker
    refuses this new authority until its Cut recovery contract is implemented. *)
