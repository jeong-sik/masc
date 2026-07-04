(** IDE Bridge — collects Keeper activity events and surfaces them in
    the [.masc-ide/] partition structure for IDE consumption. *)

open Ide_event_types

let default_partition = Ide_paths.Legacy_default

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

(* ── Segment rotation + tail-read (IDE Observation Plane v2 A2/A3) ───────
   The event store was a single append-only [<kind>_events.jsonl] with no
   rotation, so it grew without bound (~4.2 MB/day) and every read folded
   the whole file (a live 143 MB tool_events.jsonl stalled the main Eio
   domain for ~2 s per read). We keep the flat filename as the live segment
   and rotate it to numbered archives [<kind>_events.jsonl.<n>] (higher [n]
   = more recent rotation); reads tail the newest segment(s) only.

   Size-based rotation on the flat layout is chosen over date-sharding
   because it keeps the live filename stable (existing readers/tests still
   observe [<kind>_events.jsonl]) and because the pre-existing oversized
   file is rotated out on its first oversized append and then ages off
   under retention — no separate migration of legacy data is needed. *)

let default_max_segment_bytes = 32 * 1024 * 1024

(* Retain this many archived segments beyond the live one; older archives
   are pruned. Segment-count (not byte-budget) retention keeps rotation
   math trivial and lets a legacy oversized segment age out over N
   rotations rather than persisting forever. *)
let default_max_retained_segments = 8

(* Filtered ([keeper_id]) reads scan a bounded tail window instead of the
   whole store, so a specific keeper's events are surfaced only from the
   recent window. This is the deliberate A3 bound: an observation panel
   shows recent activity, not an exhaustive history scan. Unfiltered reads
   only ever need [offset + limit] rows. *)
let max_keeper_filter_scan_lines = 1000

let segment_index_of_name ~live_basename name =
  let prefix = live_basename ^ "." in
  let plen = String.length prefix in
  if String.length name > plen && String.sub name 0 plen = prefix
  then int_of_string_opt (String.sub name plen (String.length name - plen))
  else None
;;

let archive_indices ~path =
  let dir = Filename.dirname path in
  let live_basename = Filename.basename path in
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | entries ->
    Array.to_list entries
    |> List.filter_map (fun name -> segment_index_of_name ~live_basename name)
;;

let archive_path ~path index = Printf.sprintf "%s.%d" path index

let rotation_mutex_registry : (string, Stdlib.Mutex.t) Hashtbl.t = Hashtbl.create 16
let rotation_mutex_registry_mu = Stdlib.Mutex.create ()

let rotation_mutex_for path =
  Stdlib.Mutex.lock rotation_mutex_registry_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock rotation_mutex_registry_mu)
    (fun () ->
       match Hashtbl.find_opt rotation_mutex_registry path with
       | Some m -> m
       | None ->
         let m = Stdlib.Mutex.create () in
         Hashtbl.replace rotation_mutex_registry path m;
         m)
;;

let with_rotation_lock ~path f =
  let m = rotation_mutex_for path in
  Stdlib.Mutex.lock m;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock m) f
;;

(* Rotate the live segment out when it is at or above [max_segment_bytes].
   The new archive index is [max existing + 1], so a concurrent rotation
   never clobbers an existing archive. Caller must hold [with_rotation_lock]
   for [path]: otherwise a racing appender can recreate the live file between
   another caller's index calculation and [rename_if_exists], causing the
   second rename to overwrite the archive chosen by the first. *)
let maybe_rotate ~path ~max_segment_bytes =
  if max_segment_bytes > 0
  then (
    match Fs_compat.file_size path with
    | Some size when size >= max_segment_bytes ->
      let next = 1 + List.fold_left max 0 (archive_indices ~path) in
      ignore
        (Fs_compat.rename_if_exists ~src:path ~dst:(archive_path ~path next) : bool)
    | Some _ | None -> ())
;;

(* Delete the oldest archives beyond [max_retained_segments]. Racing prunes
   converge: [Sys.remove] of an already-removed file raises [Sys_error],
   which is ignored. *)
let prune_segments ~path ~max_retained_segments =
  if max_retained_segments >= 0
  then (
    let indices = List.sort compare (archive_indices ~path) in
    let excess = List.length indices - max_retained_segments in
    if excess > 0
    then
      List.iteri
        (fun i index ->
          if i < excess
          then (try Sys.remove (archive_path ~path index) with Sys_error _ -> ()))
        indices)
;;

let append_rotating ~path ~max_segment_bytes ~max_retained_segments json =
  with_rotation_lock ~path (fun () ->
    maybe_rotate ~path ~max_segment_bytes;
    (* Fresh-fd append (not the fd-cached [Fs_compat.append_jsonl]): a cached
       writer keyed by the live path would keep writing into a just-renamed
       archive inode after rotation. [append_file] opens/closes per call and
       serializes concurrent writers per path, matching the prior append. *)
    Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n");
    prune_segments ~path ~max_retained_segments)
;;

(* Segment files newest-first: live segment, then archives by descending
   index. Only existing files are returned. *)
let segment_paths_newest_first ~path =
  let archives =
    archive_indices ~path
    |> List.sort (fun a b -> compare b a)
    |> List.map (fun index -> archive_path ~path index)
  in
  (if Fs_compat.file_exists path then [ path ] else []) @ archives
;;

(* Collect the newest [budget] raw JSONL lines across segments, tailing the
   newest segment first and expanding to older segments only until [budget]
   lines are gathered. [Dated_jsonl.load_tail_lines] reads each segment
   backwards in chunks, so cost scales with [budget], not with file size. *)
let tail_read_lines ~path ~budget =
  if budget <= 0
  then []
  else (
    let rec loop segments acc remaining =
      if remaining <= 0
      then acc
      else (
        match segments with
        | [] -> acc
        | seg :: rest ->
          let lines =
            try Dated_jsonl.load_tail_lines seg ~max_lines:remaining with
            | Sys_error _ -> []
          in
          loop rest (acc @ lines) (remaining - List.length lines))
    in
    loop (segment_paths_newest_first ~path) [] budget)
;;

let append_event ~base_dir ~partition ~(event : ide_event) =
  let dir = Ide_paths.partition_store_dir ~base_dir partition in
  Fs_compat.mkdir_p dir;
  let file_name = event_file_name (event_kind_of_event event) in
  let path = Filename.concat dir file_name in
  let json = ide_event_to_json event in
  append_rotating
    ~path
    ~max_segment_bytes:default_max_segment_bytes
    ~max_retained_segments:default_max_retained_segments
    json

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

(* Tail-read at most [scan_budget] newest rows for one kind, then filter.
   Replaces the previous whole-file [fold_jsonl_lines] fold (O(file size))
   with a segment tail-read (O(scan_budget)). Order of the result is not
   significant — [list_events] sorts by timestamp before paging. *)
let list_kind_events ~base_path ~partition ~kind ?keeper_id ~scan_budget () =
  let dir = Ide_paths.partition_store_dir ~base_dir:base_path partition in
  let path = Filename.concat dir (event_file_name kind) in
  let lines = tail_read_lines ~path ~budget:scan_budget in
  let jsons, _malformed = Fs_compat.parse_jsonl_lines ~source:path lines in
  List.filter
    (fun json -> event_matches_kind kind json && event_matches_keeper keeper_id json)
    jsons
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
  let limit = normalize_limit limit in
  let offset = normalize_offset offset in
  (* A keeper-filtered read scans a bounded tail window so a sparse keeper
     still surfaces recent events; an unfiltered read only needs the page. *)
  let scan_budget =
    let page = offset + limit in
    match keeper_id with
    | None -> page
    | Some _ -> max page max_keeper_filter_scan_lines
  in
  let events =
    List.concat_map
      (fun kind -> list_kind_events ~base_path ~partition ~kind ?keeper_id ~scan_budget ())
      kinds
    |> List.sort compare_event_json
  in
  events |> drop offset |> take limit

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

let focus_mode_of_tool_input input =
  match string_field "focus_mode" input with
  | Some mode when valid_focus_mode mode -> Some mode
  | Some _ | None -> None
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
  match cursor_file_path_of_input input, cursor_line_of_input input, focus_mode_of_tool_input input with
  | Some file_path, Some line, Some focus_mode when line >= 1 ->
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
        ~focus_mode
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
  let focus_mode =
    match focus_mode with
    | None -> Some "editing"
    | Some mode when valid_focus_mode mode -> Some mode
    | Some _ -> None
  in
  match focus_mode with
  | None -> ()
  | Some focus_mode ->
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
    ~tool_name:_
    ~success
  =
  (* Gate: only ingest PR events from successful tool executions.
     Failed commands (auth/network/validation errors) preserve the
     command_descriptor in their output, which would otherwise produce
     phantom PR #0 events. *)
  if not success then ()
  else
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

(** Ingest PR creation/update events from descriptor-backed tool output.
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
  (* tool/pr/turn sinks fire on the keeper turn fiber (main Eio domain). Their
     bodies parse tool output (Yojson) and append JSONL — synchronous I/O that
     stalls the fleet under load. Defer that work to the ingestion writer fiber
     via [Ide_ingest_queue.submit]: the hot path only allocates a closure and
     enqueues; the parse+append run off-domain. When no writer is installed
     (tests, pre-bootstrap) [submit] runs inline, preserving prior behavior.
     write_region and annotation sinks stay synchronous — annotation returns a
     Result the caller consumes, so it cannot be deferred. *)
  Agent_observation.register_tool_event_sink
    (fun (event : Agent_observation.tool_event) ->
      Ide_ingest_queue.submit (fun () ->
        ingest_tool_event_from_hook
          ~base_path:event.base_path
          ~tool_name:event.tool_name
          ~keeper_id:event.keeper_id
          ~turn_id:event.turn_id
          ~outcome:event.outcome
          ~typed_outcome_str:event.typed_outcome
          ~duration_ms:event.duration_ms
          ~output_text:event.output_text
          ~input:event.input));
  Agent_observation.register_pr_event_sink
    (fun (event : Agent_observation.pr_event) ->
      Ide_ingest_queue.submit (fun () ->
        ingest_pr_event_from_descriptor
          ~base_path:event.base_path
          ~keeper_id:event.keeper_id
          ~turn_id:event.turn_id
          ~output_text:event.output_text
          ~tool_name:event.tool_name
          ~success:event.success));
  Agent_observation.register_turn_event_sink
    (fun (event : Agent_observation.turn_event) ->
      Ide_ingest_queue.submit (fun () ->
        ingest_turn_event
          ~base_path:event.base_path
          ~turn_id:event.turn_id
          ~keeper_id:event.keeper_id
          ~phase:event.phase
          ~model_used:event.model_used
          ~tools_used:event.tools_used
          ~stop_reason:event.stop_reason
          ~duration_ms:event.duration_ms
          ~timestamp_ms:event.timestamp_ms));
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
           ; partition
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
          ~partition
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

(* Expose the rotation/tail-read internals so tests can drive them with
   small thresholds without writing multi-megabyte segments. Not part of
   the production surface. *)
module For_testing = struct
  let default_max_segment_bytes = default_max_segment_bytes
  let default_max_retained_segments = default_max_retained_segments
  let append_rotating = append_rotating
  let tail_read_lines = tail_read_lines
  let segment_paths_newest_first = segment_paths_newest_first
  let archive_indices = archive_indices
end

let () = install_agent_observation_sinks ()
