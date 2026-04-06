(** Telemetry_unified — Read-only aggregation of scattered telemetry stores.

    Provides a single, time-sorted view over five separate JSONL stores:
    - [.masc/keepers/<name>/metrics/] — Per-keeper turn metrics (richest)
    - [.masc/telemetry/]              — Agent lifecycle and tool call events
    - [.masc/tool_calls/]             — Full I/O for keeper tool calls
    - [.masc/tool_usage/]             — System_internal surface tool calls
    - [data/tool-metrics/]            — Tool duration/success metrics

    Each returned entry is tagged with a ["source"] field for discrimination.
    No write paths are modified; this module is purely a read-side fan-in.

    @since 2.251.0 *)

(** Telemetry source discriminator. *)
type source =
  | Keeper_metric  (** Per-keeper turn/heartbeat metrics *)
  | Agent_event    (** Agent lifecycle, task, handoff events *)
  | Tool_call_io   (** Keeper tool calls with full input/output *)
  | Tool_usage     (** System_internal surface tool invocations *)
  | Tool_metric    (** Tool duration and success metrics *)

val source_to_string : source -> string
val source_of_string : string -> source option
val all_sources : source list

val read_unified :
  base_path:string ->
  ?sources:source list ->
  ?keeper_name:string ->
  ?n:int ->
  unit ->
  Yojson.Safe.t list
(** [read_unified ~base_path ?sources ?keeper_name ?n ()] reads entries
    from [sources] (default: all five), optionally filtered by
    [keeper_name], and returns at most [n] entries (default 100)
    sorted by timestamp descending (newest first).

    Each entry is a JSON object with an added ["source"] field. *)

val summary_json :
  base_path:string ->
  unit ->
  Yojson.Safe.t
(** [summary_json ~base_path ()] returns a JSON overview of each source:
    path, entry count, and whether the store directory exists. *)
