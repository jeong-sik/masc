(** IDE Bridge — collects Keeper activity events and surfaces them in
    the [.masc-ide/] partition structure for IDE consumption.

    Bridges the Keeper/Tool layer (rich observability) to the IDE layer
    (JSONL files in [.masc-ide/]). *)

open Ide_event_types

(** {1 Ingest Functions} *)

(** Record a tool call event. Called from Keeper hooks after every tool execution. *)
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
  unit

(** Record a PR event. Parsed from shell command output. *)
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

(** Record a comment event. *)
val ingest_comment_event :
  base_path:string ->
  comment_id:string ->
  pr_number:int option ->
  board_post_id:string option ->
  author:string ->
  content:string ->
  keeper_id:string ->
  turn_id:string ->
  timestamp_ms:int64 ->
  unit

(** Record a turn lifecycle event. *)
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

(** {1 PR Output Parsing} *)

(** Try to extract PR number and URL from shell command output.
    Returns [Some (number, url)] if a GitHub PR URL is found. *)
val parse_pr_url_from_output : string -> (int * string) option

(** {1 Query Functions} *)

(** Load all events for a partition, sorted by timestamp descending. *)
val list_events :
  base_dir:string ->
  partition:Ide_paths.partition ->
  unit ->
  Yojson.Safe.t list

(** Load events across all partitions. *)
val list_all_events :
  base_dir:string ->
  unit ->
  Yojson.Safe.t list
