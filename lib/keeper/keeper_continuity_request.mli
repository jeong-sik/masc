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

val to_json : runtime_id:string -> selection:selection -> range:range ->
  wire:Llm_provider.Request_wire_observer.observation -> Yojson.Safe.t

val record_best_effort : config:Workspace.config -> keeper_name:string ->
  runtime_id:string -> selection:selection -> range:range ->
  wire:Llm_provider.Request_wire_observer.observation -> unit
(** Append request identity and selection/range metadata at the existing
    pre-dispatch boundary. Missing capture identity is explicitly unbound.
    Ordinary storage failures are diagnostic; reserved exceptions propagate. *)
