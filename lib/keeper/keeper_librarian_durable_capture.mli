(** Complete immutable observations selected by the durable Librarian reader.
    Strict disk restoration supplies data only: no source-lock, physical owner,
    Memory incarnation, provider, disposition or acknowledgement authority. *)
type error =
  | Checkpoint_source of Keeper_checkpoint_store.Saved_history.ref_error
  | Inconsistent_source of string
val error_to_string : error -> string

type boundary_lines =
  (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list

type checkpoint = private {
  reference : Keeper_checkpoint_ref.t;
  canonical_bytes : string;
  messages : Agent_core.Types.message list;
  range : Keeper_librarian_range.range;
  boundary_lines_seen : int;
  end_boundary_line : int;
}
val checkpoint : snapshot:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  range:Keeper_librarian_range.range -> boundary_lines_seen:int ->
  end_boundary_line:int -> checkpoint
(** Retain bytes, reference and full messages from the same actual read. A
    restored checkpoint never becomes an exact-source or source-lock token. *)

type official_trace = {
  trace_id : string;
  main : (int * (Keeper_turn_fragments.line, Keeper_turn_fragments.read_error) result) list;
  internal : (int * (Keeper_turn_fragments.line, Keeper_turn_fragments.read_error) result) list;
}
type official = {
  selected : Keeper_librarian_range.official_line list;
  traces : official_trace list;
}
type source = Checkpoint_only of checkpoint | Official_only of official | Mixed of checkpoint * official

type projection = {
  messages : Agent_core.Types.message list;
  tool_observations : Keeper_librarian.tool_observation list;
  historical_task_contexts : Keeper_librarian_task_context.t list;
}
val tool_observations : Agent_core.Types.message list -> Keeper_librarian.tool_observation list
val project_source : boundaries:boundary_lines -> source -> (projection, error) result
(** The same pure projection used by the real selector and strict restoration;
    preserves interleaving and original historical attribution offsets. *)

type positions = {
  current : Keeper_librarian_progress.t option;
  selection : Keeper_librarian_progress.t option;
  counterpart : Keeper_librarian_progress.t option;
  official : Keeper_librarian_official_progress.t option;
}

type t
val create : runtime_keepers_dir:string -> extent:Keeper_librarian_range.extent ->
  boundaries:boundary_lines -> positions:positions -> source:source ->
  counterparts:Keeper_librarian_input_sources.counterpart_snapshot ->
  external_before:Keeper_external_read_cursor.observation ->
  external_prepared:Keeper_external_read_cursor.observation ->
  expected_revision:int option ->
  range_id:Keeper_memory_os_current.durable_range_id option ->
  official_range_id:Keeper_memory_os_current.official_range_id option ->
  Keeper_librarian.input -> (t, error) result
(** Check source/input/receipt/frontier consistency without re-reading mutable
    stores. The selected records and complete input survive later source changes;
    creation and restoration grant no permission to commit that stale input. *)
val input : t -> Keeper_librarian.input
val expected_revision : t -> int option
val range_id : t -> Keeper_memory_os_current.durable_range_id option
val official_range_id : t -> Keeper_memory_os_current.official_range_id option
val boundaries : t -> boundary_lines
val positions : t -> positions
val source : t -> source
val counterparts : t -> Keeper_librarian_input_sources.counterpart_snapshot
val external_before : t -> Keeper_external_read_cursor.observation
val external_prepared : t -> Keeper_external_read_cursor.observation
val runtime_keepers_dir : t -> string
val extent : t -> Keeper_librarian_range.extent
val to_json : t -> Yojson.Safe.t
(** Restores complete data only. Every checkpoint-persisted message field
    must agree with the retained exact canonical bytes; additional complete
    lineage fields remain separately retained and are not execution authority. *)
val of_json : Yojson.Safe.t -> (t, error) result
(** Field-exact envelope and typed structured children. Original payload JSON and
    ordered message metadata use the complete Librarian input codec. Complete
    source, input and raw counterpart JSON are retained as original JSON text
    so outer host-record canonicalization cannot rewrite payload JSON. Unknown,
    duplicate, missing and internally inconsistent observations refuse. *)
