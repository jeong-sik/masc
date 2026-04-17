(** Activity_feed — Unified activity timeline

    Aggregates events from different JSONL sources into a single
    chronological timeline for agent dashboards and keeper observations.

    Sources:
    - Task files (`.masc/tasks/*.json`)
    - Board posts (`.masc/board_posts.jsonl`)
    - Board comments (`.masc/board_comments.jsonl`)
    - Mention inbox (`.masc/mention_inbox.jsonl`)
    - Debates (`.masc/debates/*.json`)

    @since Phase 3B — Keeper Deliberation Engine
*)

type activity_item = {
  id: string;
  kind: string; [@default ""]
  agent_name: string; [@default ""]
  summary: string; [@default ""]
  detail_json: Yojson.Safe.t; [@default `Null]
  created_at: float; [@default 0.0]
} [@@deriving yojson { strict = false }]

(** {1 JSON Serialization}

    [activity_item_to_yojson] and [activity_item_of_yojson] are generated
    by [ppx_deriving_yojson].  Legacy wrappers below keep the [option]
    API for callers that haven't migrated to [result]. *)

let activity_item_to_json : activity_item -> Yojson.Safe.t =
  activity_item_to_yojson

let activity_item_of_json (json : Yojson.Safe.t) : activity_item option =
  match activity_item_of_yojson json with
  | Ok item when item.id <> "" -> Some item
  | Ok _ -> None
  | Error msg ->
    Log.Feed.warn "activity_item_of_json: %s" msg;
    None

(** {1 JSONL Helpers} *)

let warn_read_failure ~kind ~path msg =
  Log.Feed.warn "%s read failed for %s: %s" kind path msg

let warn_parse_failure ~kind ~path ~line_no msg =
  Log.Feed.warn "%s parse failed for %s line %d: %s" kind path line_no msg

let load_jsonl_safe ?(kind = "jsonl") (path : string) : Yojson.Safe.t list =
  if not (Fs_compat.file_exists path) then []
  else
    match Safe_ops.read_file_safe path with
    | Error msg ->
        warn_read_failure ~kind ~path msg;
        []
    | Ok content ->
        content
        |> String.split_on_char '\n'
        |> List.mapi (fun line_no line -> (line_no + 1, line))
        |> List.filter_map (fun (line_no, line) ->
               let trimmed = String.trim line in
               if trimmed = "" then None
               else
                 try Some (Yojson.Safe.from_string trimmed)
                 with Yojson.Json_error msg ->
                   warn_parse_failure ~kind ~path ~line_no msg;
                   None)

(** Fallback timestamp used when a source record has no parseable
    [created_at].  Using epoch (0.0) instead of [Time_compat.now ()]
    ensures items with missing timestamps sort to the end of the
    timeline rather than being silently reordered to "now". *)
let timestamp_fallback = 0.0

let parse_created_at_or_fallback ~kind ~path raw =
  let raw = String.trim raw in
  let fallback () =
    Log.Feed.warn "%s timestamp parse fallback for %s: %S" kind path raw;
    timestamp_fallback
  in
  if raw = "" then fallback ()
  else
    try
      Scanf.sscanf raw "%d-%d-%dT%d:%d:%d"
        (fun y m d h mi s ->
           let tm = {
             Unix.tm_sec = s; tm_min = mi; tm_hour = h;
             tm_mday = d; tm_mon = m - 1; tm_year = y - 1900;
             tm_wday = 0; tm_yday = 0; tm_isdst = false;
           } in
           let local_epoch, _ = Unix.mktime tm in
           let utc_as_local, _ = Unix.mktime (Unix.gmtime local_epoch) in
           let tz_offset = local_epoch -. utc_as_local in
           local_epoch +. tz_offset)
    with
    | Scanf.Scan_failure _ | Failure _ | End_of_file -> fallback ()
    | exn ->
        Log.Feed.warn "%s timestamp parse error for %s: %s" kind path
          (Printexc.to_string exn);
        fallback ()

(** {1 Source Readers} *)

(** Read task activity from `.masc/tasks/` directory. *)
let task_activities (config : Coord.config) : activity_item list =
  let tasks_dir = Filename.concat (Coord.masc_dir config) "tasks" in
  if not (Fs_compat.file_exists tasks_dir) || not (Sys.is_directory tasks_dir) then []
  else
    let files =
      try Sys.readdir tasks_dir |> Array.to_list
      with
      | Sys_error msg ->
          Log.Feed.warn "task activity read failed for %s: %s" tasks_dir msg;
          []
    in
    files
    |> List.filter (fun fname -> Filename.check_suffix fname ".json")
    |> List.filter_map (fun fname ->
        let path = Filename.concat tasks_dir fname in
        match Safe_ops.read_json_file_safe path with
        | Error msg ->
            Log.Feed.warn "task activity JSON read failed for %s: %s" path msg;
            None
        | Ok json ->
          let id = Safe_ops.json_string ~default:"" "id" json in
          let status = Safe_ops.json_string ~default:"" "status" json in
          let assignee = Safe_ops.json_string ~default:"" "assignee" json in
          let title = Safe_ops.json_string ~default:"" "title" json in
          let created_at_str = Safe_ops.json_string ~default:"" "created_at" json in
          let created_at = parse_created_at_or_fallback ~kind:"task activity" ~path created_at_str in
          let agent = if assignee <> "" then assignee else "system" in
          let summary = Printf.sprintf "Task %s: %s (%s)" id title status in
          if id = "" then None
          else Some {
            id = "act-task-" ^ id;
            kind = "task";
            agent_name = agent;
            summary;
            detail_json = json;
            created_at;
          })

(** Read board post activity from `.masc/board_posts.jsonl`. *)
let board_post_activities (config : Coord.config) : activity_item list =
  let path = Filename.concat (Coord.masc_dir config) "board_posts.jsonl" in
  load_jsonl_safe ~kind:"board post" path
  |> List.filter_map (fun json ->
      let id = Safe_ops.json_string ~default:"" "id" json in
      let author = Safe_ops.json_string ~default:"" "author" json in
      let title = Safe_ops.json_string ~default:"" "title" json in
      let content = Safe_ops.json_string ~default:"" "content" json in
      let created_at =
        match Safe_ops.json_float_opt "created_at" json with
        | Some ts -> ts
        | None ->
            Log.Feed.warn "board post missing/invalid created_at for %s" path;
            timestamp_fallback
      in
      if id = "" then None
      else
        let preview = if title <> "" then title
          else
            (* UTF-8-safe truncation (#7690): byte-based String.sub
               corrupted activity-events/*.jsonl for Korean content. *)
            String_util.utf8_safe ~max_bytes:83 ~suffix:"..." content
            |> String_util.to_string
        in
        Some {
          id = "act-post-" ^ id;
          kind = "board_post";
          agent_name = author;
          summary = Printf.sprintf "Posted: %s" preview;
          detail_json = json;
          created_at;
        })

(** Read board comment activity from `.masc/board_comments.jsonl`. *)
let board_comment_activities (config : Coord.config) : activity_item list =
  let path = Filename.concat (Coord.masc_dir config) "board_comments.jsonl" in
  load_jsonl_safe ~kind:"board comment" path
  |> List.filter_map (fun json ->
      let id = Safe_ops.json_string ~default:"" "id" json in
      let author = Safe_ops.json_string ~default:"" "author" json in
      let content = Safe_ops.json_string ~default:"" "content" json in
      let created_at =
        match Safe_ops.json_float_opt "created_at" json with
        | Some ts -> ts
        | None ->
            Log.Feed.warn "board comment missing/invalid created_at for %s" path;
            timestamp_fallback
      in
      if id = "" then None
      else
        let preview =
          (* UTF-8-safe truncation (#7690). *)
          String_util.utf8_safe ~max_bytes:83 ~suffix:"..." content
          |> String_util.to_string
        in
        Some {
          id = "act-comment-" ^ id;
          kind = "board_comment";
          agent_name = author;
          summary = Printf.sprintf "Commented: %s" preview;
          detail_json = json;
          created_at;
        })

(** Read mention activity from `.masc/mention_inbox.jsonl`. *)
let mention_activities (config : Coord.config) : activity_item list =
  let path = Mention_inbox.inbox_path config in
  load_jsonl_safe ~kind:"mention inbox" path
  |> List.filter_map (fun json ->
      let id = Safe_ops.json_string ~default:"" "id" json in
      let source_agent = Safe_ops.json_string ~default:"" "source_agent" json in
      let target_agent = Safe_ops.json_string ~default:"" "target_agent" json in
      let content_preview = Safe_ops.json_string ~default:"" "content_preview" json in
      let created_at =
        match Safe_ops.json_float_opt "created_at" json with
        | Some ts -> ts
        | None ->
            Log.Feed.warn "mention inbox missing/invalid created_at for %s" path;
            timestamp_fallback
      in
      if id = "" then None
      else Some {
        id = "act-mention-" ^ id;
        kind = "mention";
        agent_name = source_agent;
        summary = Printf.sprintf "@%s mentioned @%s: %s"
                    source_agent target_agent
                    (String_util.utf8_safe ~max_bytes:63 ~suffix:"..."
                       content_preview
                     |> String_util.to_string);
        detail_json = json;
        created_at;
      })

(** {1 Unified Timeline} *)

let recent_activity (config : Coord.config) ?agent_name ~(limit : int) ()
    : activity_item list =
  let all_items =
    List.concat [
      task_activities config;
      board_post_activities config;
      board_comment_activities config;
      mention_activities config;
    ]
  in
  let filtered = match agent_name with
    | None -> all_items
    | Some name ->
      List.filter (fun item -> item.agent_name = name) all_items
  in
  let sorted =
    List.sort (fun a b -> compare b.created_at a.created_at) filtered
  in
  let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> take (n - 1) (x :: acc) rest
  in
  take limit [] sorted
