(** Derived working context. Original queue entries remain execution authority. *)
type source = { reference : string; content : Yojson.Safe.t }
type completeness = Current | Needs_reconsideration
type pocket = { id : string; merge_contexts : string list; sources : string list; context : string; next_steps : string list; completeness : completeness }
type snapshot = { generation : string; revision : int; execution_basis : string option; sources : source list; pockets : pocket list }
type version = string * int
type input = { sources : source list; previous : snapshot option; unavailable : string list; execution_basis : string option }
val version : snapshot -> version
val current_references : snapshot -> string list
val empty : input
val source_of_event : Keeper_event_queue_state.pending_selection -> source
val source_of_chat : Keeper_chat_operation.t -> source
val prompt_json : input -> Yojson.Safe.t
val pockets_of_json : sources:source list -> Yojson.Safe.t -> (pocket list, string) result
val select : input -> Yojson.Safe.t -> (pocket list, string) result
val pockets_to_json : pocket list -> Yojson.Safe.t
val path : keepers_dir:string -> keeper_id:string -> string
val read : keepers_dir:string -> keeper_id:string -> (snapshot option, string) result
val read_for_update : keepers_dir:string -> keeper_id:string -> (snapshot option, string) result
(** Invalid derived bytes are quarantined under their content hash while the
    file lock is held. IO failures never authorize replacing a snapshot. *)
val commit : ?observed_sources:source list -> ?execution_basis:string -> keepers_dir:string -> keeper_id:string -> expected_version:version option ->
  sources:source list -> pocket list -> (snapshot, string) result
(** Exact generation+revision CAS. Explicit merge targets preserve stable pocket
    identity and their prior sources without replaying raw inputs to the model.
    Unselected members survive as Needs_reconsideration with no action advice. *)
val render : input -> string option
(** Advice requires matching source and execution-progress evidence. *)
