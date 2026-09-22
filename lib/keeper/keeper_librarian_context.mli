(** Derived working context. Original queue entries remain execution authority. *)
type source = { reference : string; content : Yojson.Safe.t }
type completeness = Current | Needs_reconsideration
type pocket = { id : string; merge_contexts : string list; sources : string list; context : string; next_steps : string list; completeness : completeness }
type snapshot = { generation : string; revision : int; execution_basis : string option; sources : source list; pockets : pocket list }
type version = string * int
type retract_sources_error =
  | Retract_sources_empty
  | Retract_source_reference_empty of { index : int }
  | Retract_source_reference_duplicate of string
  | Retract_snapshot_not_found
  | Retract_snapshot_sha256_invalid
  | Retract_snapshot_conflict of
      { expected_version : version
      ; observed_version : version option
      ; expected_snapshot_sha256 : string
      ; observed_snapshot_sha256 : string option
      }
  | Retract_source_not_found of string
  | Retract_sources_persistence_failed of string
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
val read_with_snapshot_sha256 : keepers_dir:string -> keeper_id:string ->
  ((snapshot * string) option, string) result
(** One decoded snapshot paired with the lowercase SHA-256 of its exact stored
    bytes, suitable for the source-retraction generation+revision+hash CAS. *)
val snapshot_sha256 : snapshot -> string
(** SHA-256 of the exact canonical bytes the writer stores for [snapshot]. *)
val read_for_update : keepers_dir:string -> keeper_id:string -> (snapshot option, string) result
(** Invalid derived bytes are quarantined under their content hash while the
    file lock is held. IO failures never authorize replacing a snapshot. *)
val commit : ?observed_sources:source list -> ?execution_basis:string -> keepers_dir:string -> keeper_id:string -> expected_version:version option ->
  sources:source list -> pocket list -> (snapshot, string) result
(** Exact generation+revision CAS. Explicit merge targets preserve stable pocket
    identity and their prior sources without replaying raw inputs to the model.
    Unselected members survive as Needs_reconsideration with no action advice. *)
val retract_sources : keepers_dir:string -> keeper_id:string -> expected_version:version ->
  expected_snapshot_sha256:string ->
  source_references:string list -> (snapshot, retract_sources_error) result
(** Remove a non-empty set of exact source references under the working-context
    file lock and generation+revision+exact-byte SHA-256 CAS. Every reference
    must exist or the snapshot is unchanged. Pockets untouched by the removed
    references are preserved; a pocket that loses some sources becomes
    [Needs_reconsideration] with empty [next_steps], and one that loses all of
    them is removed. *)
val render : input -> string option
(** Advice requires matching source and execution-progress evidence. *)
