(** IDE Bridge — collects Keeper activity events and surfaces them in
    the [.masc-ide/] partition structure for IDE consumption. *)

open Ide_event_types

type event_kind =
  | Tool
  | Turn
  | Pr

val event_kind_of_string : string -> event_kind option
val event_kind_to_string : event_kind -> string

val list_events :
  base_path:string ->
  ?partition:Ide_paths.partition ->
  ?kind:event_kind ->
  ?keeper_id:string ->
  ?limit:int ->
  ?offset:int ->
  unit ->
  Yojson.Safe.t list

val list_cursors :
  base_path:string ->
  ?partition:Ide_paths.partition ->
  ?keeper_id:string ->
  ?file_path:string ->
  ?limit:int ->
  ?offset:int ->
  unit ->
  Yojson.Safe.t list

val cursor_focus_mode_of_string : string -> string option
(** Return the canonical cursor focus mode when [mode] is part of the IDE
    cursor contract. *)

(** Ingest a cursor event from an external source (e.g. editor or LSP).
    Unlike [ingest_cursor_event_from_hook], this does not require a tool hook
    context and uses the provided [source] label as the tool_name field. *)
val ingest_cursor_event :
  base_path:string ->
  ?partition:Ide_paths.partition ->
  keeper_id:string ->
  file_path:string ->
  line:int ->
  ?column:int ->
  ?selection_end:(int * int) ->
  ?focus_mode:string ->
  source:string ->
  unit ->
  (unit, string) result
(** Return latest valid cursor records, newest first. Cursor records are
    produced from tool hooks only when the hook input contains a non-empty
    file path and a positive line number. *)

val install_agent_observation_sinks : unit -> unit
(** Register IDE storage as the sink for neutral [Agent_observation] events,
    including write-region observations. *)

val ingest_tool_event :
  base_path:string ->
  ?partition:Ide_paths.partition ->
  tool_name:string ->
  keeper_id:string ->
  turn_id:string ->
  outcome:string ->
  typed_outcome:string ->
  latency_ms:int ->
  summary:string ->
  file_path:string option ->
  timestamp_ms:int64 ->
  ?command_descriptor:command_descriptor ->
  unit ->
  unit

val ingest_turn_event :
  base_path:string ->
  partition:Ide_paths.partition ->
  turn_id:string ->
  keeper_id:string ->
  phase:string ->
  model_used:string option ->
  tools_used:string list ->
  stop_reason:string option ->
  duration_ms:int option ->
  timestamp_ms:int64 ->
  unit

(** Extract and ingest tool event from raw hook parameters.
    [typed_outcome_str] is pre-computed from [Keeper_tool_outcome.t]. *)
val ingest_tool_event_from_hook :
  base_path:string ->
  partition:Ide_paths.partition ->
  tool_name:string ->
  keeper_id:string ->
  turn_id:string ->
  outcome:string ->
  typed_outcome_str:string ->
  duration_ms:float ->
  output_text:string ->
  input:Yojson.Safe.t ->
  unit

val ingest_pr_event :
  base_path:string ->
  partition:Ide_paths.partition ->
  pr_number:int ->
  pull_request_url:string ->
  pr_title:string ->
  pr_state:string ->
  repo:string ->
  keeper_id:string ->
  turn_id:string ->
  comment_count:int ->
  review_status:string option ->
  timestamp_ms:int64 ->
  unit

(** Ingest descriptor-backed PR events from successful tool output.
    Raw stdout URL scanning is intentionally not a PR signal; only an explicit
    successful wrapper result with a command descriptor may ingest PR events. *)
val ingest_pr_event_from_hook :
  base_path:string ->
  partition:Ide_paths.partition ->
  keeper_id:string ->
  turn_id:string ->
  output_text:string ->
  tool_name:string ->
  unit

(** Ingest PR event from command_descriptor (deterministic).
    Extracts descriptor and structured PR result JSON from tool result JSON.
    For descriptor-confirmed [gh pr create] only, falls back to the GitHub CLI's
    documented stdout URL when no structured result JSON is present.
    Only proceeds when [success] is [true] — failed tool executions
    (auth/network/validation errors) must not produce phantom PR events. *)
val ingest_pr_event_from_descriptor :
  base_path:string ->
  partition:Ide_paths.partition ->
  keeper_id:string ->
  turn_id:string ->
  output_text:string ->
  tool_name:string ->
  success:bool ->
  unit

(** Extract command_descriptor from tool result JSON. *)
val extract_descriptor_from_output : string -> command_descriptor option

val parse_pull_request_result_from_output : string -> (int * string) option

(** Rotation/tail-read internals exposed for tests only. Production code
    reaches these through [append_event]/[list_events] with the default
    thresholds. *)
module For_testing : sig
  val default_max_segment_bytes : int
  val default_max_retained_segments : int

  (** Rotation-aware append: rotate the live segment out when it reaches
      [max_segment_bytes], append the row, then prune archives beyond
      [max_retained_segments]. *)
  val append_rotating :
    path:string ->
    max_segment_bytes:int ->
    max_retained_segments:int ->
    Yojson.Safe.t ->
    unit

  (** Newest [budget] raw JSONL lines across segments (live first, then
      archives newest-first), oldest-first within the collected set. *)
  val tail_read_lines : path:string -> budget:int -> string list

  (** Existing segment files newest-first: live, then archives by
      descending index. *)
  val segment_paths_newest_first : path:string -> string list

  (** Archive indices present for [path] (the [<path>.<n>] files). *)
  val archive_indices : path:string -> int list
end
