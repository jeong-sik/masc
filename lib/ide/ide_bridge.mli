(** IDE Bridge — collects Keeper activity events and surfaces them in
    the per-codebase [.masc-ide/] store layout for IDE consumption. *)


type event_kind =
  | Tool
  | Turn

val event_kind_of_string : string -> event_kind option
val event_kind_to_string : event_kind -> string

val list_events :
  base_path:string ->
  codebase:string ->
  ?kind:event_kind ->
  ?keeper_id:string ->
  ?limit:int ->
  ?offset:int ->
  unit ->
  Yojson.Safe.t list

val install_agent_observation_sinks : unit -> unit
(** Register IDE storage as the sink for neutral [Agent_observation] events. *)

val ingest_tool_event :
  base_path:string ->
  codebase:string ->
  tool_name:string ->
  keeper_id:string ->
  turn_id:string ->
  outcome:string ->
  typed_outcome:string ->
  latency_ms:int ->
  summary:string ->
  file_path:string option ->
  timestamp_ms:int64 ->
  unit ->
  unit
(** Low-level writer: the caller names the codebase and the file
    path explicitly. Producers go through
    {!ingest_tool_event_from_hook}, which projects both from the fact's
    attribution. *)

(** Extract and ingest tool event from raw hook parameters.
    [typed_outcome_str] is pre-computed from [Keeper_tool_outcome.t]. *)
val ingest_tool_event_from_hook :
  base_path:string ->
  attribution:Agent_observation.attribution ->
  tool_name:string ->
  keeper_id:string ->
  turn_id:string ->
  outcome:string ->
  typed_outcome_str:string ->
  duration_ms:float ->
  output_text:string ->
  input:Yojson.Safe.t ->
  unit

(** Rotation/tail-read internals exposed for tests only. Production code
    reaches these through [append_event]/[list_events] with the default
    thresholds. *)
module For_testing : sig


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
