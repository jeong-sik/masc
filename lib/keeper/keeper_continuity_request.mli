(** Request-bound diagnostic evidence. No summary bodies or retirement authority. *)
type selection =
  | Summarized of Librarian_continuity_snapshot.t
  | Absorbed of { trace_id : string; end_atom : int }
  | Without_snapshot
  | Not_applied

type range =
  { origin : Keeper_carried_front.origin
  ; first_atom : int
  ; total_atoms : int
  ; custom_projection_changed : bool
      (** When true this bounded range does not certify the final custom projection. *)
  }

val to_json : keeper:string -> turn_ref:Ids.Turn_ref.t option ->
  unread:Keeper_librarian_request_unread.t -> runtime_id:string -> selection:selection -> range:range option ->
  wire:Llm_provider.Request_wire_observer.observation -> Yojson.Safe.t

val record_best_effort : config:Workspace.config -> keeper_name:string -> turn_ref:Ids.Turn_ref.t option ->
  unread:Keeper_librarian_request_unread.t -> runtime_id:string -> selection:selection -> range:range option ->
  wire:Llm_provider.Request_wire_observer.observation -> unit
(** Append each serialization's turn identity and selection/range metadata at
    the existing pre-dispatch boundary. Missing turn/capture identity or a
    projection not paired with this serialization remains explicitly unbound.
    Ordinary storage failures are diagnostic; reserved exceptions propagate. *)

val selection_to_json : selection -> Yojson.Safe.t
