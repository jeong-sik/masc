(** IDE Bridge — collects Keeper activity events and surfaces them in
    the [.masc-ide/] partition structure for IDE consumption. *)

open Ide_event_types

val ingest_tool_event :
  base_path:string ->
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
  pr_number:int ->
  pr_url:string ->
  pr_title:string ->
  pr_state:string ->
  repo:string ->
  keeper_id:string ->
  turn_id:string ->
  comment_count:int ->
  review_status:string option ->
  timestamp_ms:int64 ->
  unit

(** Try to detect PR creation from Execute tool output and ingest a PR event.
    Only fires when [tool_name = "execute"] and output contains a GitHub PR URL.
    Heuristic — falls back to output parsing if descriptor is not available. *)
val ingest_pr_event_from_hook :
  base_path:string ->
  keeper_id:string ->
  turn_id:string ->
  output_text:string ->
  tool_name:string ->
  unit

(** Ingest PR event from command_descriptor (deterministic).
    Extracts descriptor from tool result JSON, falls back to heuristic.
    Only proceeds when [success] is [true] — failed tool executions
    (auth/network/validation errors) must not produce phantom PR events. *)
val ingest_pr_event_from_descriptor :
  base_path:string ->
  keeper_id:string ->
  turn_id:string ->
  output_text:string ->
  tool_name:string ->
  success:bool ->
  unit

(** Extract command_descriptor from tool result JSON. *)
val extract_descriptor_from_output : string -> command_descriptor option

val parse_pr_url_from_output : string -> (int * string) option
