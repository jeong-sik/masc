(** IDE Bridge — collects Keeper activity events and surfaces them in
    the [.masc-ide/] partition structure for IDE consumption. *)

open Ide_event_types

let default_partition = Ide_paths.Orphan

let append_event ~base_dir ~partition ~(event : ide_event) =
  let dir = Ide_paths.partition_store_dir ~base_dir partition in
  Fs_compat.mkdir_p dir;
  let file_name =
    match event with
    | Tool_event _ -> "tool_events.jsonl"
    | Turn_event _ -> "turn_events.jsonl"
  in
  let path = Filename.concat dir file_name in
  let json = ide_event_to_json event in
  let line = Yojson.Safe.to_string json in
  let oc = open_out_gen [ Open_creat; Open_append; Open_text ] 0o644 path in
  output_string oc line;
  output_char oc '\n';
  close_out oc

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
  (try append_event ~base_dir:base_path ~partition:default_partition ~event
   with exn ->
     Printf.eprintf "Ide_bridge.ingest_tool_event error: %s\n%!" (Printexc.to_string exn))

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
  (try append_event ~base_dir:base_path ~partition:default_partition ~event
   with exn ->
     Printf.eprintf "Ide_bridge.ingest_turn_event error: %s\n%!" (Printexc.to_string exn))

(** Extract tool event parameters from raw hook data and ingest.
    This is the function called from [keeper_run_tools_hooks.on_tool_executed].
    Separated for direct testability. *)
let ingest_tool_event_from_hook
    ~base_path
    ~tool_name
    ~keeper_id
    ~turn_id
    ~outcome
    ~typed_outcome_str
    ~duration_ms
    ~output_text
    ~(input : Yojson.Safe.t)
  =
  let file_path =
    match Yojson.Safe.Util.member "path" input with
    | `String p -> Some p
    | _ ->
      match Yojson.Safe.Util.member "file_path" input with
      | `String p -> Some p
      | _ -> None
  in
  let summary =
    if String.length output_text > 200 then String.sub output_text 0 200
    else output_text
  in
  ingest_tool_event
    ~base_path
    ~tool_name
    ~keeper_id
    ~turn_id
    ~outcome
    ~typed_outcome:typed_outcome_str
    ~latency_ms:(int_of_float duration_ms)
    ~summary
    ~file_path
    ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))

let parse_pr_url_from_output (output : string) : (int * string) option =
  let prefix = "https://github.com/" in
  let prefix_len = String.length prefix in
  let output_len = String.length output in
  let rec find_prefix i =
    if i + prefix_len > output_len then None
    else if String.sub output i prefix_len = prefix then Some i
    else find_prefix (i + 1)
  in
  match find_prefix 0 with
  | None -> None
  | Some start ->
    (* Extract the path after "https://github.com/" *)
    let path_start = start + prefix_len in
    let path_len = output_len - path_start in
    let path = String.sub output path_start path_len in
    (* path = "owner/repo/pull/123..." or "owner/repo/pull/123/files..." *)
    let parts = String.split_on_char '/' path in
    (match parts with
     | owner :: repo :: "pull" :: number_str :: _ ->
       (* Trim any trailing whitespace/newlines from the number *)
       let number_str = String.trim number_str in
       (try
          let number = int_of_string number_str in
          let url = Printf.sprintf "https://github.com/%s/%s/pull/%d" owner repo number in
          Some (number, url)
        with Failure _ -> None)
     | _ -> None)
