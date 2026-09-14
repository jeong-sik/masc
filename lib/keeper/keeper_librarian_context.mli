(** Derived working context. Original queue entries remain execution authority. *)
type source = { reference : string; content : Yojson.Safe.t }
type completeness = Current | Needs_reconsideration
type pocket = { sources : string list; context : string; next_steps : string list; completeness : completeness }
type snapshot = { revision : int; sources : source list; pockets : pocket list }
type input = { sources : source list; previous : snapshot option; unavailable : string list }
val current_references : snapshot -> string list
val empty : input
val source_of_event : Keeper_event_queue_state.pending_selection -> source
val source_of_chat : Keeper_chat_operation.t -> source
val prompt_json : input -> Yojson.Safe.t
val pockets_of_json : sources:source list -> Yojson.Safe.t -> (pocket list, string) result
val select : input -> Yojson.Safe.t -> (pocket list, string) result
val pockets_to_json : pocket list -> Yojson.Safe.t
val read : keepers_dir:string -> keeper_id:string -> (snapshot option, string) result
val commit : ?observed_sources:source list -> keepers_dir:string -> keeper_id:string -> expected_revision:int option ->
  sources:source list -> pocket list -> (snapshot, string) result
(** CAS merges a selected subset with previous pockets. Unselected members
    survive as Needs_reconsideration pockets without actionable next steps.
    Original queues are never mutated. *)
val render : input -> string option
(** All pockets remain visible, with explicit source freshness. Next steps are
    exposed only when every source is present in the current observation. New or
    changed sources retain their ordinary intake path.
    No model judgment ACKs, completes, cancels, or grants authority to a source. *)
