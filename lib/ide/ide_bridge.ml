(** IDE Bridge — collects Keeper activity events and surfaces them in
    the [.masc-ide/] partition structure for IDE consumption.

    This module bridges the gap between the Keeper/Tool layer (which produces
    rich observability data) and the IDE layer (which reads from JSONL files
    in [.masc-ide/]).

    Events are appended to partition-scoped JSONL files:
    - [tool_events.jsonl] — all tool call outcomes
    - [pr_events.jsonl] — PR creation/update/merge
    - [turn_events.jsonl] — turn lifecycle
    - [comments.jsonl] — PR/board comments

    The existing [regions.jsonl] continues to be written by {!Ide_region_tracker}. *)

open Ide_event_types

(** {1 Partition Resolution} *)

(** Default partition for bridge events. Uses Orphan since bridge events
    are not tied to a specific repo URL. *)
let default_partition = Ide_paths.Orphan

(** {1 Event Append} *)

let append_event ~base_dir ~partition ~(event : ide_event) =
  let dir = Ide_paths.partition_store_dir ~base_dir partition in
  Fs_compat.mkdir_p dir;
  let file_name =
    match event with
    | Region_event _ -> "regions.jsonl"
    | Tool_event _ -> "tool_events.jsonl"
    | Pr_event _ -> "pr_events.jsonl"
    | Comment_event _ -> "comments.jsonl"
    | Turn_event _ -> "turn_events.jsonl"
  in
  let path = Filename.concat dir file_name in
  let json = ide_event_to_json event in
  Fs_compat.append_jsonl path json

(** {1 Ingest Functions} *)

(** Record a tool call event. Called from Keeper hooks after every tool execution. *)
let ingest_tool_event
    ~base_path
    ~tool_name
    ~keeper_id
    ~turn_id
    ~outcome
    ~typed_outcome
    ~latency_ms
    ~summary
    ~file_path
    ~timestamp_ms
  =
  let truncated_summary =
    if String.length summary > 200 then String.sub summary 0 200 ^ "..."
    else summary
  in
  let event =
    Tool_event
      { tool_name
      ; keeper_id
      ; turn_id
      ; outcome
      ; typed_outcome
      ; latency_ms
      ; summary = truncated_summary
      ; file_path
      ; timestamp_ms
      }
  in
  append_event ~base_dir:base_path ~partition:default_partition ~event

(** Record a PR event. Parsed from shell command output. *)
let ingest_pr_event
    ~base_path
    ~pr_number
    ~pr_url
    ~pr_title
    ~pr_state
    ~repo
    ~keeper_id
    ~turn_id
    ~comment_count
    ~review_status
    ~timestamp_ms
  =
  let event =
    Pr_event
      { pr_number
      ; pr_url
      ; pr_title
      ; pr_state
      ; repo
      ; keeper_id
      ; turn_id
      ; comment_count
      ; review_status
      ; timestamp_ms
      }
  in
  append_event ~base_dir:base_path ~partition:Orphan ~event

(** Record a comment event. *)
let ingest_comment_event
    ~base_path
    ~comment_id
    ~pr_number
    ~board_post_id
    ~author
    ~content
    ~keeper_id
    ~turn_id
    ~timestamp_ms
  =
  let event =
    Comment_event
      { comment_id
      ; pr_number
      ; board_post_id
      ; author
      ; content
      ; keeper_id
      ; turn_id
      ; timestamp_ms
      }
  in
  append_event ~base_dir:base_path ~partition:Orphan ~event

(** Record a turn lifecycle event. *)
let ingest_turn_event
    ~base_path
    ~turn_id
    ~keeper_id
    ~phase
    ~model_used
    ~tools_used
    ~stop_reason
    ~duration_ms
    ~timestamp_ms
  =
  let event =
    Turn_event
      { turn_id
      ; keeper_id
      ; phase
      ; model_used
      ; tools_used
      ; stop_reason
      ; duration_ms
      ; timestamp_ms
      }
  in
  append_event ~base_dir:base_path ~partition:Orphan ~event

(** {1 PR Output Parsing} *)

(** Try to extract PR number and URL from shell command output.
    Handles [gh pr create] output format:
    - "https://github.com/owner/repo/pull/123"
    - "https://github.com/owner/repo/pull/123/files" *)
let parse_pr_url_from_output (output : string) : (int * string) option =
  (* Find "https://github.com/" prefix *)
  let prefix = "https://github.com/" in
  let prefix_len = String.length prefix in
  let output_len = String.length output in
  (* Search for the prefix in the output *)
  let rec find_prefix i =
    if i + prefix_len > output_len then None
    else if String.sub output i prefix_len = prefix then Some i
    else find_prefix (i + 1)
  in
  match find_prefix 0 with
  | None -> None
  | Some start ->
    let rest = String.sub output start (output_len - start) in
    (* rest = "owner/repo/pull/123..." or "owner/repo/pull/123/files..." *)
    (* Split by '/' *)
    let parts = String.split_on_char '/' rest in
    match parts with
    | owner :: repo :: "pull" :: number_str :: _ ->
      (try
         let number = int_of_string number_str in
         let url = Printf.sprintf "https://github.com/%s/%s/pull/%d" owner repo number in
         Some (number, url)
       with Failure _ -> None)
    | _ -> None

(** {1 Query Functions} *)

(** Load all events for a partition, sorted by timestamp descending. *)
let list_events ~base_dir ~partition () =
  let dir = Ide_paths.partition_store_dir ~base_dir partition in
  let load file_name =
    let path = Filename.concat dir file_name in
    if Fs_compat.file_exists path then
      Fs_compat.load_jsonl path
    else []
  in
  let tool_events = load "tool_events.jsonl" in
  let pr_events = load "pr_events.jsonl" in
  let turn_events = load "turn_events.jsonl" in
  let comments = load "comments.jsonl" in
  let all = tool_events @ pr_events @ turn_events @ comments in
  let get_ts json =
    match Yojson.Safe.Util.member "timestamp_ms" json with
    | `Intlit s -> (try Int64.of_string s with _ -> 0L)
    | `Int n -> Int64.of_int n
    | _ -> 0L
  in
  List.sort (fun a b -> Int64.compare (get_ts b) (get_ts a)) all

(** Load events for Orphan partition (default). *)
let list_all_events ~base_dir () =
  list_events ~base_dir ~partition:Ide_paths.Orphan ()
