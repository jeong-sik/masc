(** Durable operator work on the existing serialized Memory lane. HTTP only
    persists/observes here and schedules the ordinary catch-up separately. *)
type error = Keeper_librarian_history_resolution_intent.error
type submission = {
  intent:Keeper_librarian_history_resolution_intent.t;
  reobserved:bool;
}
val submit : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard -> actor:string ->
  reason:string -> now:float -> (submission, error) result
(** Durable acceptance only. Callers check the existing initialized/enabled/
    workspace/readiness contracts before requesting ordinary lane scheduling.
    Scheduling failure does not remove this intent. *)
type completion = Not_observed
  | Memory_committed of {request_id:string}
  | Completion_unavailable of string
type atom_range = {
  trace_id:string;
  history_start_boundary_line:int;
  start_atom:int;
  end_atom:int;
}
type official_range = {after_boundary_line:int;selected_through:int;selected_count:int}
type original_range = {atom:atom_range option;official:official_range option}
type observation = {
  intents:Keeper_librarian_history_resolution_intent.t list;
  fence:Keeper_librarian_history_resolution_state.t option;
  completion:completion;
  original_range:(original_range, string) result;
}
val read : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (observation, error) result
(** Read-only exact-original observation. HTTP may use Intent.to_public_json,
    and explicitly select safe fence fields; never State.to_json/preimage. *)
val run_serialized : config:Workspace.config -> keeper_name:string ->
  (unit, error) result
(** Process every active intent before ordinary history discovery. Caller is
    the existing Memory-lane unit/purge exclusion; no inline HTTP execution.
    A definite unreplayable source before child intent is durably refused,
    retaining its fence so ordinary discovery can continue. Unknown
    publication or unreadable state stops this unit. Restart and a
    coalesced ordinary wake discover the same durable intent/child ID. *)
val record_completed_serialized : config:Workspace.config -> keeper_name:string ->
  request:Keeper_librarian_durable_request.t ->
  completed:Lane_addon_tool_request_owner.retained -> (unit, error) result
(** After an actual history commit returns Finished, retain exact receipt
    evidence before the lane proceeds to a newer range. Never called by GET. *)
