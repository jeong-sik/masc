(** What a durable Librarian reader read: its complete input, once, and for
    each source it read whole the number of elements it saw and one digest
    over them. Strict disk restoration supplies data only: no source-lock,
    physical owner, Memory incarnation, provider, disposition or
    acknowledgement authority. *)
type error =
  | Checkpoint_source of Keeper_checkpoint_store.Saved_history.ref_error
  | Inconsistent_source of string
val error_to_string : error -> string

type boundary_lines =
  (int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list

type checkpoint = private {
  trace_id : Keeper_id.Trace_id.t;
  messages : Agent_core.Types.message list;
  range : Keeper_librarian_range.range;
  boundary_lines_seen : int;
  end_boundary_line : int;
}
val checkpoint : snapshot:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  range:Keeper_librarian_range.range -> boundary_lines_seen:int ->
  end_boundary_line:int -> checkpoint
(** The trace and full messages of one actual read. *)

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

(** What an original keeps of a source it read whole: the number of elements
    it saw and one SHA-256 over all of them, each length-prefixed. Checkpoint
    messages count in their checkpoint encoding
    ({!Agent_core.Checkpoint.message_to_json}); boundary lines and
    official-client rows with their line number and their read result,
    refused rows included. *)
module Held : sig
  type span = private { count : int; digest : string }
  type checkpoint = private {
    trace_id : Keeper_id.Trace_id.t;
    range : Keeper_librarian_range.range;
    boundary_lines_seen : int;
    end_boundary_line : int;
    messages : span;
  }
  type trace = private { id : string; main : span; internal : span }
  type official = private {
    selected : Keeper_librarian_range.official_line list;
    traces : trace list;
  }
  type source = Checkpoint_only of checkpoint | Official_only of official | Mixed of checkpoint * official
end

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
(** Check that [boundaries] and [source] select the original range, cuts and
    official turns and project to [input], and that the receipts and frontier
    agree, without re-reading mutable stores. Keeps [input] and a span of each
    source; neither creation nor restoration grants permission to commit that
    stale input. *)
val input : t -> Keeper_librarian.input
val expected_revision : t -> int option
val with_current : expected_revision:int option -> current:Keeper_librarian.current_selection option ->
  t -> (t, error) result
(** Replace only the complete current Memory basis. Every source span,
    selected range, counterpart, cursor and historical input field is preserved.
    This pure operation grants no new execution or publication authority. *)
val range_id : t -> Keeper_memory_os_current.durable_range_id option
val official_range_id : t -> Keeper_memory_os_current.official_range_id option
val positions : t -> positions
val source : t -> Held.source
val counterparts : t -> Keeper_librarian_input_sources.counterpart_snapshot
val external_before : t -> Keeper_external_read_cursor.observation
val external_prepared : t -> Keeper_external_read_cursor.observation
val runtime_keepers_dir : t -> string
val extent : t -> Keeper_librarian_range.extent
val confirm_sources : boundaries:boundary_lines -> messages:Agent_core.Types.message list option ->
  traces:official_trace list -> t -> (unit, error) result
(** Whether the sources as they are now still hold what the original read:
    the first [count] elements of each have its digest, and those elements
    select the original range, cuts and official turns and project to its
    input as at creation. [messages] are the current checkpoint's, and
    [traces] the current Main and Internal rows of each trace the original
    names. Atom messages are compared in their checkpoint encoding. Reads
    nothing itself. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
(** Field-exact envelope and typed structured children. Original payload JSON and
    ordered message metadata use the complete Librarian input codec. Source
    spans, input and raw counterpart JSON are retained as original JSON text
    so outer host-record canonicalization cannot rewrite payload JSON. Unknown,
    duplicate, missing and internally inconsistent observations refuse. The
    sources are not read: whether they still agree is {!confirm_sources}. *)
