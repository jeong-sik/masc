(** Explicit fencing for Dispatch_pending(Absent) history originals only.
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
