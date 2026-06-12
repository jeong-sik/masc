(** IDE Bridge — collects Keeper activity events and surfaces them in
    the [.masc-ide/] partition structure for IDE consumption. *)

open Ide_event_types

let default_partition = Ide_paths.Orphan

type event_kind =
  | Tool
  | Turn
  | Pr

let event_kind_to_string = function
  | Tool -> "tool"
  | Turn -> "turn"
  | Pr -> "pr"
;;

let event_kind_of_string = function
  | "tool" -> Some Tool
  | "turn" -> Some Turn
  | "pr" -> Some Pr
  | _ -> None
;;

let event_file_name = function
  | Tool -> "tool_events.jsonl"
  | Turn -> "turn_events.jsonl"
  | Pr -> "pr_events.jsonl"
;;

let cursor_file_name = "cursor_events.jsonl"

let event_kind_of_event = function
  | Tool_event _ -> Tool
  | Turn_event _ -> Turn
  | Pr_event _ -> Pr
;;

let append_event ~base_dir ~partition ~(event : ide_event) =
  let dir = Ide_paths.partition_store_dir ~base_dir partition in
  Fs_compat.mkdir_p dir;
  let file_name = event_file_name (event_kind_of_event event) in
  let path = Filename.concat dir file_name in
  let json = ide_event_to_json event in
  (* Use Fs_compat.append_jsonl for per-path mutex protection.
     Safe for concurrent calls from parallel Eio fibers (Eio.Fiber.List.map)
     and async agent spawns. Fs_compat uses Stdlib.Mutex.protect per path,
     so writes to the same file are serialized; writes to different files
     can proceed concurrently. *)
  Fs_compat.append_jsonl path json

let append_cursor ~base_dir ~partition json =
  let dir = Ide_paths.partition_store_dir ~base_dir partition in
  Fs_compat.mkdir_p dir;
  let path = Filename.concat dir cursor_file_name in
  Fs_compat.append_jsonl path json

let string_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) when s <> "" -> Some s
     | _ -> None)
  | _ -> None
;;

let int64_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int i) -> Some (Int64.of_int i)
     | Some (`Intlit s) -> Int64.of_string_opt s
     | _ -> None)
  | _ -> None
;;

let int_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int i) -> Some i
     | Some (`Intlit s) -> int_of_string_opt s
     | Some (`String s) -> int_of_string_opt (String.trim s)
     | _ -> None)
  | _ -> None
;;

let event_timestamp_ms json =
  match int64_field "timestamp_ms" json with
  | Some ts -> ts
  | None ->
    (* DET-OK: malformed or historical bridge rows without timestamps sort last;
       the reader does not synthesize event identity or mutate the stored row. *)
    0L
;;

let event_matches_kind kind json =
  match string_field "type" json with
  | Some wire_kind -> String.equal wire_kind (event_kind_to_string kind)
  | None -> false
;;

let event_matches_keeper keeper_id json =
  match keeper_id with
  | None -> true
  | Some expected ->
    (match string_field "keeper_id" json with
     | Some actual -> String.equal actual expected
     | None -> false)
;;

let cursor_matches_file file_path json =
  match file_path with
  | None -> true
  | Some expected ->
    (match string_field "file_path" json with
     | Some actual -> String.equal actual expected
     | None -> false)
;;

let valid_focus_mode = function
  | "reading" | "editing" | "reviewing" | "planning" -> true
  | _ -> false
;;

let cursor_is_valid json =
  match
    ( string_field "keeper_id" json
    , string_field "file_path" json
    , int_field "line" json
    , int_field "column" json
    , string_field "focus_mode" json )
  with
  | Some _, Some file_path, Some line, Some column, Some focus_mode ->
    String.trim file_path <> "" && line >= 1 && column >= 0 && valid_focus_mode focus_mode
  | _ -> false
;;

let cursor_timestamp_ms json =
  match int64_field "last_update" json with
  | Some ts -> ts
  | None ->
    (match int64_field "timestamp_ms" json with
     | Some ts -> ts
     | None -> 0L)
;;

let compare_cursor_json left right =
  let by_time = Int64.compare (cursor_timestamp_ms right) (cursor_timestamp_ms left) in
  if by_time <> 0 then by_time else compare left right
;;

let normalize_limit = function
  | Some n when n > 0 -> min n 200
  | _ -> 50
;;

let normalize_offset = function
  | Some n when n > 0 -> n
  | _ -> 0
;;

let drop n items =
  let rec loop remaining = function
    | [] -> []
    | rest when remaining <= 0 -> rest
    | _ :: rest -> loop (remaining - 1) rest
  in
  loop n items
;;

let take n items =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop n [] items
;;

let compare_event_json left right =
  let by_time = Int64.compare (event_timestamp_ms right) (event_timestamp_ms left) in
  if by_time <> 0 then by_time else compare left right
;;

let now_ms () =
  (* NDT-OK: IDE bridge timestamps are runtime telemetry for operator ordering;
     they are not used to make deterministic build or scheduling decisions. *)
  Int64.of_float (Unix.gettimeofday () *. 1000.0)
;;

let annotation_kind_to_ide = function
  | Agent_observation.Comment -> Ide_annotation_types.Comment
  | Agent_observation.Decision -> Ide_annotation_types.Decision
  | Agent_observation.Question -> Ide_annotation_types.Question
  | Agent_observation.Bookmark -> Ide_annotation_types.Bookmark
;;

let list_kind_events ~base_path ~partition ~kind ?keeper_id () =
  let dir = Ide_paths.partition_store_dir ~base_dir:base_path partition in
  let path = Filename.concat dir (event_file_name kind) in
  Fs_compat.fold_jsonl_lines
    ~init:[]
    ~f:(fun acc ~line_no:_ json ->
      if event_matches_kind kind json && event_matches_keeper keeper_id json
      then json :: acc
      else acc)
    path
;;

let latest_cursor_per_keeper cursors =
  let seen = Hashtbl.create 8 in
  let acc = ref [] in
  List.iter
    (fun json ->
       match string_field "keeper_id" json with
       | Some keeper_id when not (Hashtbl.mem seen keeper_id) ->
         Hashtbl.add seen keeper_id ();
         acc := json :: !acc
       | _ -> ())
    cursors;
  List.rev !acc
;;

let list_cursors
    ~base_path
    ?(partition = default_partition)
    ?keeper_id
    ?file_path
    ?limit
    ?offset
    ()
  =
  let dir = Ide_paths.partition_store_dir ~base_dir:base_path partition in
  let path = Filename.concat dir cursor_file_name in
  let cursors =
    Fs_compat.fold_jsonl_lines
      ~init:[]
      ~f:(fun acc ~line_no:_ json ->
        if cursor_is_valid json
           && event_matches_keeper keeper_id json
           && cursor_matches_file file_path json
        then json :: acc
        else acc)
      path
    |> List.sort compare_cursor_json
    |> latest_cursor_per_keeper
  in
  cursors |> drop (normalize_offset offset) |> take (normalize_limit limit)

let list_events
    ~base_path
    ?(partition = default_partition)
    ?kind
    ?keeper_id
    ?limit
    ?offset
    ()
  =
  let kinds =
    match kind with
    | Some k -> [ k ]
    | None -> [ Tool; Turn; Pr ]
  in
  let events =
    List.concat_map
      (fun kind -> list_kind_events ~base_path ~partition ~kind ?keeper_id ())
      kinds
    |> List.sort compare_event_json
  in
  events |> drop (normalize_offset offset) |> take (normalize_limit limit)

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
    ?command_descriptor
    ()
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
      ; command_descriptor
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
    ~pull_request_url
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
      ; pull_request_url
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
       | "git_commit" ->
         let message = Yojson.Safe.Util.member "message" descriptor_json |> Yojson.Safe.Util.to_string in
         Some (Ide_event_types.Git_commit { message })
       | "pipe_chain" ->
         let first_cmd = Yojson.Safe.Util.member "first_cmd" descriptor_json |> Yojson.Safe.Util.to_string in
         let last_cmd = Yojson.Safe.Util.member "last_cmd" descriptor_json |> Yojson.Safe.Util.to_string in
         let length = Yojson.Safe.Util.member "length" descriptor_json |> Yojson.Safe.Util.to_int in
         Some (Ide_event_types.Pipe_chain { first_cmd; last_cmd; length })
       | "gh_api_pr_create" ->
         let repo = Yojson.Safe.Util.member "repo" descriptor_json |> Yojson.Safe.Util.to_string in
         let title = Yojson.Safe.Util.member "title" descriptor_json |> Yojson.Safe.Util.to_string in
         let base = Yojson.Safe.Util.member "base" descriptor_json |> Yojson.Safe.Util.to_string in
         Some (Ide_event_types.Gh_api_pr_create { repo; title; base })
       | "gh_api_pr_merge" ->
         let repo = Yojson.Safe.Util.member "repo" descriptor_json |> Yojson.Safe.Util.to_string in
         let pr_number = Yojson.Safe.Util.member "pr_number" descriptor_json |> Yojson.Safe.Util.to_int in
         Some (Ide_event_types.Gh_api_pr_merge { repo; pr_number })
       | "gh_api_pr_comment" ->
         let repo = Yojson.Safe.Util.member "repo" descriptor_json |> Yojson.Safe.Util.to_string in
         let pr_number = Yojson.Safe.Util.member "pr_number" descriptor_json |> Yojson.Safe.Util.to_int in
         let body = Yojson.Safe.Util.member "body" descriptor_json |> Yojson.Safe.Util.to_string in
         Some (Ide_event_types.Gh_api_pr_comment { repo; pr_number; body })
       | _ -> None)
    | _ -> None
  with _ -> None

let string_contains s needle =
  let s_len = String.length s in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then true
    else if i + needle_len > s_len then false
    else if String.sub s i needle_len = needle then true
    else loop (i + 1)
  in
  loop 0
;;

let cursor_file_path_of_input input =
  let non_empty = function
    | Some s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
    | None -> None
  in
  match non_empty (string_field "file_path" input) with
  | Some _ as path -> path
  | None -> non_empty (string_field "path" input)
;;

let cursor_line_of_input input =
  match int_field "line" input with
  | Some n -> Some n
  | None -> int_field "line_start" input
;;

let focus_mode_of_tool_input ~tool_name input =
  match string_field "focus_mode" input with
  | Some mode when valid_focus_mode mode -> mode
  | _ ->
    let lowered = String.lowercase_ascii tool_name in
    if string_contains lowered "review"
    then "reviewing"
    else if string_contains lowered "read" || string_contains lowered "search"
    then "reading"
    else if string_contains lowered "write"
            || string_contains lowered "edit"
            || string_contains lowered "patch"
            || string_contains lowered "annotate"
    then "editing"
    else "planning"
;;

let turn_number_of_id turn_id =
  let digits = Buffer.create (String.length turn_id) in
  String.iter
    (fun c -> if c >= '0' && c <= '9' then Buffer.add_char digits c)
    turn_id;
  let raw = Buffer.contents digits in
  if raw = "" then None else int_of_string_opt raw
;;

let cursor_event_json
    ~keeper_id
    ~file_path
    ~line
    ~column
    ?selection_end
    ~focus_mode
    ~last_update
    ~tool_name
    ?turn
    ~turn_id
    ()
  =
  let fields =
    [ "keeper_id", `String keeper_id
    ; "file_path", `String file_path
    ; "line", `Int line
    ; "column", `Int column
    ; "focus_mode", `String focus_mode
    ; "last_update", `Intlit (Int64.to_string last_update)
    ; "timestamp_ms", `Intlit (Int64.to_string last_update)
    ; "tool_name", `String tool_name
    ; "turn_id", `String turn_id
    ]
  in
  let fields =
    match selection_end with
    | Some (line, column) ->
      ( "selection_end"
      , `Assoc [ "line", `Int line; "column", `Int column ] )
      :: fields
    | None -> fields
  in
  let fields =
    match turn with
    | Some turn -> ("turn", `Int turn) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)
;;

let ingest_cursor_event_from_hook
    ~base_path
    ~tool_name
    ~keeper_id
    ~turn_id
    ~timestamp_ms
    ~(input : Yojson.Safe.t)
  =
  match cursor_file_path_of_input input, cursor_line_of_input input with
  | Some file_path, Some line when line >= 1 ->
    let column =
      match int_field "column" input with
      | Some n when n >= 0 -> n
      | _ -> 0
    in
    let selection_end =
      match int_field "line_end" input with
      | Some line_end when line_end > line -> Some (line_end, column)
      | _ -> None
    in
    let json =
      cursor_event_json
        ~keeper_id
        ~file_path
        ~line
        ~column
        ?selection_end
        ~focus_mode:(focus_mode_of_tool_input ~tool_name input)
        ~last_update:timestamp_ms
        ~tool_name
        ?turn:(turn_number_of_id turn_id)
        ~turn_id
        ()
    in
    (try append_cursor ~base_dir:base_path ~partition:default_partition json
     with exn ->
       Printf.eprintf
         "Ide_bridge.ingest_cursor_event_from_hook error: %s\n%!"
         (Printexc.to_string exn))
  | _ -> ()

let ingest_cursor_event
    ~base_path
    ~keeper_id
    ~file_path
    ~line
    ?column
    ?selection_end
    ?focus_mode
    ~source
    ()
  =
  let column = Option.value column ~default:0 in
  let focus_mode = Option.value focus_mode ~default:"edit" in
  let timestamp_ms = now_ms () in
  let json =
    cursor_event_json
      ~keeper_id
      ~file_path
      ~line
      ~column
      ?selection_end
      ~focus_mode
      ~last_update:timestamp_ms
      ~tool_name:source
      ~turn_id:""
      ()
  in
  (try append_cursor ~base_dir:base_path ~partition:default_partition json
   with exn ->
     Printf.eprintf
       "Ide_bridge.ingest_cursor_event error: %s\n%!"
       (Printexc.to_string exn))
;;
;;

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
  let command_descriptor = extract_descriptor_from_output output_text in
  let timestamp_ms = now_ms () in
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
    ?command_descriptor
    ~timestamp_ms
    ();
  ingest_cursor_event_from_hook
    ~base_path
    ~tool_name
    ~keeper_id
    ~turn_id
    ~timestamp_ms
    ~input

let pull_request_result_from_json (json : Yojson.Safe.t) : (int * string) option =
  let int_opt = function
    | `Int n -> Some n
    | `Intlit s | `String s -> int_of_string_opt s
    | _ -> None
  in
  let string_non_empty_opt = function
    | `String s when String.trim s <> "" -> Some s
    | _ -> None
  in
  let first_string fields =
    List.find_map (fun field -> Yojson.Safe.Util.member field json |> string_non_empty_opt) fields
  in
  match int_opt (Yojson.Safe.Util.member "number" json), first_string [ "html_url"; "url" ] with
  | Some number, Some url when number > 0 -> Some (number, url)
  | _ -> None

let parse_pull_request_result_from_output (output : string) : (int * string) option =
  let rec from_json json =
    match pull_request_result_from_json json with
    | Some _ as result -> result
    | None ->
      (match Yojson.Safe.Util.member "output" json with
       | `String nested_output ->
         (try Yojson.Safe.from_string nested_output |> from_json with
          | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _ -> None)
       | _ -> None)
  in
  try Yojson.Safe.from_string output |> from_json with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _ -> None

let parse_github_pr_url_candidate raw =
  let candidate = String.trim raw in
  let parts = String.split_on_char '/' candidate in
  match parts with
  | "https:" :: "" :: "github.com" :: _owner :: _repo :: "pull" :: number :: _ ->
    Option.bind (int_of_string_opt number) (fun n ->
      if n > 0 then Some (n, candidate) else None)
  | _ -> None

let descriptor_confirmed_pr_url_from_output output =
  let raw_output =
    try
      match Yojson.Safe.from_string output |> Yojson.Safe.Util.member "output" with
      | `String nested -> nested
      | _ -> output
    with
    | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _ -> output
  in
  raw_output
  |> String.split_on_char '\n'
  |> List.find_map parse_github_pr_url_candidate

let explicit_tool_success_from_output output =
  try
    let json = Yojson.Safe.from_string output in
    let bool_field name =
      match Yojson.Safe.Util.member name json with
      | `Bool value -> Some value
      | _ -> None
    in
    match bool_field "ok" with
    | Some value -> value
    | None -> Option.value ~default:false (bool_field "success")
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _ -> false

(** Ingest PR event from command_descriptor (deterministic).
    Reads PR number/URL only from structured result JSON when available.
    Only proceeds when [success] is [true] — failed tool executions
    (auth/network/validation errors) must not produce phantom PR events. *)
let ingest_pr_event_from_descriptor
    ~base_path
    ~keeper_id
    ~turn_id
    ~output_text
    ~tool_name
    ~success
  =
  (* Gate: only ingest PR events from successful tool executions.
     Failed commands (auth/network/validation errors) preserve the
     command_descriptor in their output, which would otherwise produce
     phantom PR #0 events. *)
  if not success then ()
  else if String.equal (String.lowercase_ascii tool_name) "execute" then
    match extract_descriptor_from_output output_text with
    | Some (Ide_event_types.Gh_pr_create { title; base = _; draft = _ }) ->
      let pr_number, pull_request_url = match parse_pull_request_result_from_output output_text with
        | Some (n, url) -> (n, url)
        | None ->
          Option.value
            ~default:(0, "")
            (descriptor_confirmed_pr_url_from_output output_text)
      in
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url ~pr_title:title
        ~pr_state:"open" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_pr_merge { pr_number; squash = _ }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url:"" ~pr_title:""
        ~pr_state:"merged" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_pr_close { pr_number }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url:"" ~pr_title:""
        ~pr_state:"closed" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_pr_comment { pr_number; body = _ }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url:"" ~pr_title:""
        ~pr_state:"open" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:1 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_pr_edit { pr_number; title = _ }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url:"" ~pr_title:""
        ~pr_state:"open" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_pr_review { pr_number }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url:"" ~pr_title:""
        ~pr_state:"open" ~repo:"" ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_api_pr_create { repo; title; base = _ }) ->
      let pr_number, pull_request_url = match parse_pull_request_result_from_output output_text with
        | Some (n, url) -> (n, url)
        | None -> (0, "")
      in
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url ~pr_title:title
        ~pr_state:"open" ~repo ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_api_pr_merge { repo; pr_number }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url:"" ~pr_title:""
        ~pr_state:"merged" ~repo ~keeper_id ~turn_id
        ~comment_count:0 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_api_pr_comment { repo; pr_number; body = _ }) ->
      ingest_pr_event
        ~base_path ~pr_number ~pull_request_url:"" ~pr_title:""
        ~pr_state:"open" ~repo ~keeper_id ~turn_id
        ~comment_count:1 ~review_status:None
        ~timestamp_ms:(now_ms ())
    | Some (Ide_event_types.Gh_issue_create _ | Ide_event_types.Gh_issue_close _ | Ide_event_types.Git_push _ | Ide_event_types.Git_commit _ | Ide_event_types.Pipe_chain _ | Ide_event_types.Generic)
    | None -> ()

(** Ingest PR creation/update events from Execute tool output.
    This legacy hook entrypoint intentionally delegates to descriptor-backed
    ingestion only; raw stdout URL scanning is not a reliable PR signal. *)
let ingest_pr_event_from_hook
    ~base_path
    ~keeper_id
    ~turn_id
    ~output_text
    ~tool_name
  =
  ingest_pr_event_from_descriptor
    ~base_path
    ~keeper_id
    ~turn_id
    ~output_text
    ~tool_name
    ~success:(explicit_tool_success_from_output output_text)

let install_agent_observation_sinks () =
  Agent_observation.register_tool_event_sink
    (fun (event : Agent_observation.tool_event) ->
      ingest_tool_event_from_hook
        ~base_path:event.base_path
        ~tool_name:event.tool_name
        ~keeper_id:event.keeper_id
        ~turn_id:event.turn_id
        ~outcome:event.outcome
        ~typed_outcome_str:event.typed_outcome
        ~duration_ms:event.duration_ms
        ~output_text:event.output_text
        ~input:event.input);
  Agent_observation.register_pr_event_sink
    (fun (event : Agent_observation.pr_event) ->
      ingest_pr_event_from_descriptor
        ~base_path:event.base_path
        ~keeper_id:event.keeper_id
        ~turn_id:event.turn_id
        ~output_text:event.output_text
        ~tool_name:event.tool_name
        ~success:event.success);
  Agent_observation.register_turn_event_sink
    (fun (event : Agent_observation.turn_event) ->
      ingest_turn_event
        ~base_path:event.base_path
        ~turn_id:event.turn_id
        ~keeper_id:event.keeper_id
        ~phase:event.phase
        ~model_used:event.model_used
        ~tools_used:event.tools_used
        ~stop_reason:event.stop_reason
        ~duration_ms:event.duration_ms
        ~timestamp_ms:event.timestamp_ms);
  Agent_observation.register_write_region_sink
    (fun (event : Agent_observation.write_region_event) ->
      Ide_region_tracker.ingest_tool_call
        ~base_dir:event.base_path
        ~partition:event.partition
        ~keeper_id:event.keeper_id
        ~turn:event.turn
        event.tool_call_json);
  Agent_observation.register_annotation_sink
    (fun ({ base_path
           ; keeper_id
           ; file_path
           ; line_start
           ; line_end
           ; kind
           ; content
           ; goal_id
           ; task_id
           ; board_post_id
           ; comment_id
           ; pr_id
           ; git_ref
           ; log_id
           ; session_id
           ; operation_id
           ; worker_run_id
           }
          : Agent_observation.annotation_request) ->
      match
        Ide_annotations.create
          ~base_dir:base_path
          ~keeper_id
          ~file_path
          ~line_start
          ~line_end
          ~kind:(annotation_kind_to_ide kind)
          ~content
          ?goal_id
          ?task_id
          ?board_post_id
          ?comment_id
          ?pr_id
          ?git_ref
          ?log_id
          ?session_id
          ?operation_id
          ?worker_run_id
          ()
      with
      | Error msg -> Error msg
      | Ok annotation ->
        Ok
          { Agent_observation.id = annotation.id
          ; file_path = annotation.file_path
          ; line_start = annotation.line_start
          ; line_end = annotation.line_end
          })
;;

let () = install_agent_observation_sinks ()
