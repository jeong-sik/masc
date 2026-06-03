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
    | Pr_event _ -> "pr_events.jsonl"
  in
  let path = Filename.concat dir file_name in
  let json = ide_event_to_json event in
  (* Use Fs_compat.append_jsonl for per-path mutex protection.
     Safe for concurrent calls from parallel Eio fibers (Eio.Fiber.List.map)
     and async agent spawns. Fs_compat uses Stdlib.Mutex.protect per path,
     so writes to the same file are serialized; writes to different files
     can proceed concurrently. *)
  Fs_compat.append_jsonl path json

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
  (try append_event ~base_dir:base_path ~partition:default_partition ~event
   with exn ->
     Printf.eprintf "Ide_bridge.ingest_pr_event error: %s\n%!" (Printexc.to_string exn))

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
    let path_start = start + prefix_len in
    let path_len = output_len - path_start in
    let path = String.sub output path_start path_len in
    let parts = String.split_on_char '/' path in
    (match parts with
     | owner :: repo :: "pull" :: number_str :: _ ->
       (* Extract leading digits from number_str — handles URLs followed by
          non-numeric characters (e.g., JSON quotes, path segments) *)
       let number_digits =
         let buf = Buffer.create 8 in
         String.iter (fun c -> if c >= '0' && c <= '9' then Buffer.add_char buf c else ()) number_str;
         Buffer.contents buf
       in
       (match int_of_string_opt number_digits with
        | Some number when number > 0 ->
          let url = Printf.sprintf "https://github.com/%s/%s/pull/%d" owner repo number in
          Some (number, url)
        | _ -> None)
     | _ -> None)

(** Extract command_descriptor from tool result JSON.
    Returns [Some descriptor] if the result contains a valid descriptor field. *)
let extract_descriptor_from_output (output_text : string) : Ide_event_types.command_descriptor option =
  try
    let json = Yojson.Safe.from_string output_text in
    match Yojson.Safe.Util.member "command_descriptor" json with
    | `Assoc _ as descriptor_json ->
      let kind = Yojson.Safe.Util.member "kind" descriptor_json |> Yojson.Safe.Util.to_string in
      (match kind with
       | "gh_pr_create" ->
         let title = Yojson.Safe.Util.member "title" descriptor_json |> Yojson.Safe.Util.to_string in
         let base = Yojson.Safe.Util.member "base" descriptor_json |> Yojson.Safe.Util.to_string in
         let draft = Yojson.Safe.Util.member "draft" descriptor_json |> Yojson.Safe.Util.to_bool in
         Some (Ide_event_types.Gh_pr_create { title; base; draft })
       | "gh_pr_merge" ->
         let pr_number = Yojson.Safe.Util.member "pr_number" descriptor_json |> Yojson.Safe.Util.to_int in
         let squash = Yojson.Safe.Util.member "squash" descriptor_json |> Yojson.Safe.Util.to_bool in
         Some (Ide_event_types.Gh_pr_merge { pr_number; squash })
       | "gh_pr_comment" ->
         let pr_number = Yojson.Safe.Util.member "pr_number" descriptor_json |> Yojson.Safe.Util.to_int in
         let body = Yojson.Safe.Util.member "body" descriptor_json |> Yojson.Safe.Util.to_string in
         Some (Ide_event_types.Gh_pr_comment { pr_number; body })
       | "gh_pr_close" ->
         let pr_number = Yojson.Safe.Util.member "pr_number" descriptor_json |> Yojson.Safe.Util.to_int in
         Some (Ide_event_types.Gh_pr_close { pr_number })
       | "gh_pr_edit" ->
         let pr_number = Yojson.Safe.Util.member "pr_number" descriptor_json |> Yojson.Safe.Util.to_int in
         let title = (match Yojson.Safe.Util.member "title" descriptor_json with
           | `String s -> Some s
           | _ -> None) in
         Some (Ide_event_types.Gh_pr_edit { pr_number; title })
       | "gh_pr_review" ->
         let pr_number = Yojson.Safe.Util.member "pr_number" descriptor_json |> Yojson.Safe.Util.to_int in
         Some (Ide_event_types.Gh_pr_review { pr_number })
       | "git_push" ->
         let remote = Yojson.Safe.Util.member "remote" descriptor_json |> Yojson.Safe.Util.to_string in
         let branch = Yojson.Safe.Util.member "branch" descriptor_json |> Yojson.Safe.Util.to_string in
         let force = Yojson.Safe.Util.member "force" descriptor_json |> Yojson.Safe.Util.to_bool in
         Some (Ide_event_types.Git_push { remote; branch; force })
       | _ -> None)
    | _ -> None
  with _ -> None

(** Ingest PR event from command_descriptor (deterministic).
    Falls back to heuristic output parsing if descriptor is not available. *)
let ingest_pr_event_from_descriptor
    ~base_path
    ~keeper_id
    ~turn_id
    ~output_text
    ~tool_name
  =
  if String.equal tool_name "execute" then
    match extract_descriptor_from_output output_text with
    | Some (Ide_event_types.Gh_pr_create { title; base = _; draft = _ }) ->
      (* PR was created — try to get PR number from output URL *)
      let pr_number, pr_url = match parse_pr_url_from_output output_text with
        | Some (n, url) -> (n, url)
        | None -> (0, "")
      in
      ingest_pr_event
        ~base_path ~pr_number ~pr_url ~pr_title:title
        ~pr_state:"open" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_pr_merge { pr_number; squash = _ }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pr_url:"" ~pr_title:""
        ~pr_state:"merged" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_pr_close { pr_number }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pr_url:"" ~pr_title:""
        ~pr_state:"closed" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_pr_comment { pr_number; body = _ }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pr_url:"" ~pr_title:""
        ~pr_state:"open" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:1 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_pr_edit { pr_number; title = _ }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pr_url:"" ~pr_title:""
        ~pr_state:"open" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_pr_review { pr_number }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pr_url:"" ~pr_title:""
        ~pr_state:"open" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_api_pr_create { repo; title; base = _ }) ->
      let pr_number, pr_url = match parse_pr_url_from_output output_text with
        | Some (n, url) -> (n, url)
        | None -> (0, "")
      in
      ingest_pr_event
        ~base_path ~pr_number ~pr_url ~pr_title:title
        ~pr_state:"open" ~repo ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_api_pr_merge { repo; pr_number }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pr_url:"" ~pr_title:""
        ~pr_state:"merged" ~repo ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_api_pr_comment { repo; pr_number; body = _ }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pr_url:"" ~pr_title:""
        ~pr_state:"open" ~repo ~keeper_id ~turn_id
        ~comment_count:1 ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | Some (Ide_event_types.Gh_issue_create _ | Ide_event_types.Gh_issue_close _ | Ide_event_types.Git_push _ | Ide_event_types.Git_commit _ | Ide_event_types.Generic)
    | None ->
      (* Not a PR operation — fall back to heuristic output parsing *)
      if String.equal tool_name "execute" then
        match parse_pr_url_from_output output_text with
        | Some (pr_number, pr_url) ->
          let repo =
            let prefix = "https://github.com/" in
            let prefix_len = String.length prefix in
            let url_len = String.length pr_url in
            if url_len > prefix_len then
              let path = String.sub pr_url prefix_len (url_len - prefix_len) in
              let parts = String.split_on_char '/' path in
              match parts with
              | owner :: repo_name :: _ -> owner ^ "/" ^ repo_name
              | _ -> "unknown"
            else "unknown"
          in
          ingest_pr_event
            ~base_path ~pr_number ~pr_url ~pr_title:""
            ~pr_state:"open" ~repo ~keeper_id ~turn_id
            ~comment_count:0 ~review_status:None
            ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
        | None -> ()

(** Try to detect PR creation from Execute tool output and ingest a PR event.
    Only fires when [tool_name = "execute"] and output contains a GitHub PR URL.

    FIXME: This is a heuristic. It parses stdout/stderr for GitHub PR URLs
    which is fragile — output format changes, non-GitHub hosts, or URL
    in unexpected position will silently miss. A dedicated [Pr_create] tool
    in the keeper vocabulary would make this deterministic. Until then,
    this is best-effort and may produce false negatives. *)
let ingest_pr_event_from_hook
    ~base_path
    ~keeper_id
    ~turn_id
    ~output_text
    ~tool_name
  =
  if String.equal tool_name "execute" then
    match parse_pr_url_from_output output_text with
    | Some (pr_number, pr_url) ->
      let repo =
        let prefix = "https://github.com/" in
        let prefix_len = String.length prefix in
        let url_len = String.length pr_url in
        if url_len > prefix_len then
          let path = String.sub pr_url prefix_len (url_len - prefix_len) in
          let parts = String.split_on_char '/' path in
          match parts with
          | owner :: repo_name :: _ -> owner ^ "/" ^ repo_name
          | _ -> "unknown"
        else "unknown"
      in
      ingest_pr_event
        ~base_path
        ~pr_number
        ~pr_url
        ~pr_title:""
        ~pr_state:"open"
        ~repo
        ~keeper_id
        ~turn_id
        ~comment_count:0
        ~review_status:None
        ~timestamp_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.0))
    | None -> ()
