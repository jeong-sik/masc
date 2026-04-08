(** Team session persistence helpers. *)

open Room_utils
module U = Yojson.Safe.Util

let sessions_root config =
  Filename.concat (masc_dir config) "team-sessions"

let session_dir config session_id =
  Filename.concat (sessions_root config) session_id

let checkpoints_dir config session_id =
  Filename.concat (session_dir config session_id) "checkpoints"

let worker_runs_dir config session_id =
  Filename.concat (session_dir config session_id) "worker-runs"

let workers_dir config session_id =
  Filename.concat (session_dir config session_id) "workers"

let worker_container_dir config session_id worker_name =
  Filename.concat (workers_dir config session_id) worker_name

let worker_container_meta_path config session_id worker_name =
  Filename.concat (worker_container_dir config session_id worker_name) "meta.json"

let worker_container_checkpoint_path config session_id worker_name =
  Filename.concat (worker_container_dir config session_id worker_name) "checkpoint.json"

let worker_container_turn_log_path config session_id worker_name =
  Filename.concat (worker_container_dir config session_id worker_name) "turns.jsonl"

let worker_run_dir config session_id worker_run_id =
  Filename.concat (worker_runs_dir config session_id) worker_run_id

let worker_run_json_path config session_id worker_run_id =
  Filename.concat (worker_run_dir config session_id worker_run_id) "run.json"

let worker_run_checkpoint_path config session_id worker_run_id =
  Filename.concat (worker_run_dir config session_id worker_run_id) "checkpoint.json"

let worker_run_meta_path config session_id worker_run_id =
  Filename.concat (worker_run_dir config session_id worker_run_id) "meta.json"

let worker_run_proof_path config session_id worker_run_id =
  Filename.concat (worker_run_dir config session_id worker_run_id) "proof.json"

let session_json_path config session_id =
  Filename.concat (session_dir config session_id) "session.json"

let events_jsonl_path config session_id =
  Filename.concat (session_dir config session_id) "events.jsonl"

let report_md_path config session_id =
  Filename.concat (session_dir config session_id) "report.md"

let report_json_path config session_id =
  Filename.concat (session_dir config session_id) "report.json"

let proof_md_path config session_id =
  Filename.concat (session_dir config session_id) "proof.md"

let proof_json_path config session_id =
  Filename.concat (session_dir config session_id) "proof.json"

let now_iso () = Types.now_iso ()

let _session_list_last_source = Atomic.make "idle"
let _session_list_last_rows_scanned = Atomic.make 0
let _session_list_last_rows_parsed = Atomic.make 0
let _session_list_last_rows_returned = Atomic.make 0
let _session_list_total_invocations = Atomic.make 0
let _session_list_last_pg_recent_attempted = Atomic.make false
let _session_list_last_fallback_reason = Atomic.make ""
let _session_list_last_error = Atomic.make ""
let _session_list_last_since_unix = Atomic.make 0.0
let _session_list_last_limit = Atomic.make 0
let _session_list_last_query_prefix = Atomic.make ""

let record_session_list_diagnostics ~pg_recent_attempted ~fallback_reason
    ~last_error ~since_unix ~limit ~query_prefix ~source ~rows_scanned ~rows_parsed
    ~rows_returned =
  Atomic.set _session_list_last_source source;
  Atomic.set _session_list_last_rows_scanned rows_scanned;
  Atomic.set _session_list_last_rows_parsed rows_parsed;
  Atomic.set _session_list_last_rows_returned rows_returned;
  Atomic.set _session_list_last_pg_recent_attempted pg_recent_attempted;
  Atomic.set _session_list_last_fallback_reason
    (Option.value ~default:"" fallback_reason);
  Atomic.set _session_list_last_error (Option.value ~default:"" last_error);
  Atomic.set _session_list_last_since_unix since_unix;
  Atomic.set _session_list_last_limit limit;
  Atomic.set _session_list_last_query_prefix query_prefix;
  Atomic.fetch_and_add _session_list_total_invocations 1 |> ignore

let session_list_diagnostics_json () =
  `Assoc
    [
      ("source", `String (Atomic.get _session_list_last_source));
      ("rows_scanned", `Int (Atomic.get _session_list_last_rows_scanned));
      ("rows_parsed", `Int (Atomic.get _session_list_last_rows_parsed));
      ("rows_returned", `Int (Atomic.get _session_list_last_rows_returned));
      ("pg_recent_attempted", `Bool (Atomic.get _session_list_last_pg_recent_attempted));
      ( "fallback_reason",
        match String.trim (Atomic.get _session_list_last_fallback_reason) with
        | "" -> `Null
        | value -> `String value );
      ( "last_error",
        match String.trim (Atomic.get _session_list_last_error) with
        | "" -> `Null
        | value -> `String value );
      ("since_unix", `Float (Atomic.get _session_list_last_since_unix));
      ("limit", `Int (Atomic.get _session_list_last_limit));
      ("query_prefix", `String (Atomic.get _session_list_last_query_prefix));
      ("total_invocations", `Int (Atomic.get _session_list_total_invocations));
    ]

let ensure_session_dirs config session_id =
  mkdir_p (session_dir config session_id);
  mkdir_p (checkpoints_dir config session_id);
  mkdir_p (worker_runs_dir config session_id)

let read_text_file path =
  if Fs_compat.file_exists path then
    Fs_compat.load_file path
  else
    ""

let write_text_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  let tmp = path ^ ".tmp" in
  Fs_compat.save_file tmp content;
  Unix.rename tmp path

let append_text_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.append_file path content

let read_artifact_text config path =
  Room_utils.read_text config path

let write_artifact_text config path content =
  Room_utils.write_text config path content

let append_artifact_text config path content =
  Room_utils.append_text config path content

let notify_team_session_mutation config ~session_id =
  !Room_hooks.on_team_session_mutation_fn config ~session_id

let save_session config (session : Team_session_types.session) =
  let path = session_json_path config session.session_id in
  with_file_lock config path (fun () ->
      write_json config path (Team_session_types.session_to_yojson session));
  notify_team_session_mutation config ~session_id:session.session_id

let load_session config session_id : Team_session_types.session option =
  let path = session_json_path config session_id in
  match read_json_opt config path with
  | None -> None
  | Some json -> Team_session_types.session_of_yojson json

let load_session_or_error config session_id =
  match load_session config session_id with
  | Some s -> Ok s
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)

let json_string_member_opt key json =
  match U.member key json with
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let json_string_list_member key json =
  match U.member key json with
  | `List items ->
      items
      |> List.filter_map (function
           | `String value when String.trim value <> "" ->
               Some (String.trim value)
           | _ -> None)
  | _ -> []

let assoc_remove key fields =
  List.filter (fun (candidate, _) -> not (String.equal candidate key)) fields

let assoc_put key value fields = (key, value) :: assoc_remove key fields

let assoc_put_opt_string key value fields =
  match value with
  | Some value when String.trim value <> "" ->
      assoc_put key (`String (String.trim value)) fields
  | _ -> fields

let assoc_put_string_list key values fields =
  match Team_session_types.dedup_strings values with
  | [] -> fields
  | values ->
      assoc_put key (`List (List.map (fun value -> `String value) values)) fields

let option_or_else fallback opt =
  match opt with
  | Some _ -> opt
  | None -> fallback ()

let operation_id_for_session config session_id =
  match load_session config session_id with
  | Some session -> session.Team_session_types.operation_id
  | None -> None

let trace_ref_json_session_worker ~session_id ~worker_run_id json =
  match json with
  | `Assoc fields ->
      `Assoc
        (fields
        |> assoc_put_opt_string "session_id"
             (option_or_else (fun () -> Some session_id)
                (json_string_member_opt "session_id" json))
        |> assoc_put_opt_string "worker_run_id"
                (json_string_member_opt "worker_run_id" json
             |> option_or_else (fun () -> Some worker_run_id)))
  | _ -> json

let trace_ref_json_of_json json =
  match U.member "trace_ref" json with
  | `Assoc _ as trace_ref -> Some trace_ref
  | _ -> (
      match U.member "telemetry" json with
      | `Assoc _ as telemetry -> (
          match U.member "trace_ref" telemetry with
          | `Assoc _ as trace_ref -> Some trace_ref
          | _ -> None)
      | _ -> None)

let worker_run_id_of_json json =
  json_string_member_opt "worker_run_id" json
  |> option_or_else (fun () ->
         match trace_ref_json_of_json json with
         | Some trace_ref -> json_string_member_opt "worker_run_id" trace_ref
         | None -> None)

let evidence_refs_of_json json =
  let worker_run_refs =
    match worker_run_id_of_json json with
    | Some worker_run_id -> [ "worker-run:" ^ worker_run_id ]
    | None -> []
  in
  Team_session_types.dedup_strings
    (json_string_list_member "evidence_refs" json
    @ json_string_list_member "tool_trace_refs" json
    @ json_string_list_member "raw_evidence_refs" json
    @
    (match json_string_member_opt "checkpoint_ref" json with
    | Some value -> [ value ]
    | None -> [])
    @ worker_run_refs)

let normalize_session_event_detail config ~session_id detail =
  let detail =
    match detail with
    | `Assoc _ -> detail
    | _ -> `Assoc []
  in
  let operation_id =
    json_string_member_opt "operation_id" detail
    |> option_or_else (fun () -> operation_id_for_session config session_id)
  in
  let worker_run_id = worker_run_id_of_json detail in
  let evidence_refs = evidence_refs_of_json detail in
  match detail with
  | `Assoc fields ->
      `Assoc
        (fields
        |> assoc_put "session_id" (`String session_id)
        |> assoc_put_opt_string "operation_id" operation_id
        |> assoc_put_opt_string "worker_run_id" worker_run_id
        |> assoc_put_string_list "evidence_refs" evidence_refs)
  | _ -> detail

let normalize_worker_run_meta_json config ~session_id ~worker_run_id json =
  let json =
    match json with
    | `Assoc _ -> json
    | _ -> `Assoc []
  in
  let operation_id =
    json_string_member_opt "operation_id" json
    |> option_or_else (fun () -> operation_id_for_session config session_id)
  in
  let evidence_refs = evidence_refs_of_json json in
  match json with
  | `Assoc fields ->
      let fields =
        match U.member "trace_ref" json with
        | `Assoc _ as trace_ref ->
            assoc_put "trace_ref"
              (trace_ref_json_session_worker ~session_id ~worker_run_id trace_ref)
              fields
        | _ -> fields
      in
      `Assoc
        (fields
        |> assoc_put "session_id" (`String session_id)
        |> assoc_put "worker_run_id" (`String worker_run_id)
        |> assoc_put_opt_string "operation_id" operation_id
        |> assoc_put_string_list "evidence_refs" evidence_refs)
  | _ -> json

let activity_room_id (_config : Room_utils.config) = "default"

let detail_string key detail =
  match Yojson.Safe.Util.member key detail with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let emit_activity_event config ~session_id ~(event_type : string)
    ~(detail : Yojson.Safe.t) =
  let session_subject = Activity_graph.entity ~kind:"operation" session_id in
  let actor_entity name = Activity_graph.entity ~kind:"agent" name in
  let actor_name detail =
    detail_string "actor" detail
    |> option_or_else (fun () -> detail_string "created_by" detail)
    |> option_or_else (fun () -> detail_string "agent" detail)
  in
  let activity_kind_and_tags =
    match event_type with
    | "session_started" ->
        Some
          ( "operation.started",
            [ "team_session"; "operation.started" ] )
    | "session_finalized" ->
        Some
          ( "operation.finalized",
            [ "team_session"; "operation.finalized" ] )
    | "recovered_after_restart" ->
        Some
          ( "operation.resumed",
            [ "team_session"; "operation.resumed" ] )
    | "team_turn" ->
        Some ("team.turn", [ "team_session"; "team.turn" ])
    | "team_turn_failed" ->
        Some ("team.turn_failed", [ "team_session"; "team.turn_failed" ])
    | "team_step_spawn" ->
        Some ("team.spawn", [ "team_session"; "team.spawn" ])
    | "team_step_spawn_requested" ->
        Some
          ( "team.spawn_requested",
            [ "team_session"; "team.spawn_requested" ] )
    | "team_step_delegate" ->
        Some ("team.delegate", [ "team_session"; "team.delegate" ])
    | "team_step_delegate_requested" ->
        Some
          ( "team.delegate_requested",
            [ "team_session"; "team.delegate_requested" ] )
    | "team_step_delegate_denied" ->
        Some
          ( "team.delegate_denied",
            [ "team_session"; "team.delegate_denied" ] )
    | "team_run_deliverable" ->
        Some ("team.deliverable", [ "team_session"; "team.deliverable" ])
    | "swarm_iteration_start" ->
        Some
          ( "swarm.iteration_start",
            [ "team_session"; "swarm.iteration_start" ] )
    | "swarm_iteration_end" ->
        Some
          ( "swarm.iteration_end",
            [ "team_session"; "swarm.iteration_end" ] )
    | "swarm_agent_start" ->
        Some ("swarm.agent_start", [ "team_session"; "swarm.agent_start" ])
    | "swarm_agent_done" ->
        Some ("swarm.agent_done", [ "team_session"; "swarm.agent_done" ])
    | "swarm_converged" ->
        Some ("swarm.converged", [ "team_session"; "swarm.converged" ])
    | "swarm_error" ->
        Some ("swarm.error", [ "team_session"; "swarm.error" ])
    | other ->
        Some
          ( "team_session." ^ other,
            [ "team_session"; other ] )
  in
  let emit ?actor ?subject ~kind ~tags () =
    try
      ignore
        (Activity_graph.emit config ~room_id:(activity_room_id config)
           ?actor ?subject ~kind ~payload:detail ~tags ())
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Session.warn "team session activity emit failed (%s): %s" kind
          (Printexc.to_string exn)
  in
  match activity_kind_and_tags with
  | Some (kind, tags) ->
      emit
        ?actor:(Option.map actor_entity (actor_name detail))
        ~subject:session_subject ~kind ~tags ()
  | None -> ()

let append_event config session_id ~(event_type : string) ~(detail : Yojson.Safe.t) =
  let detail = normalize_session_event_detail config ~session_id detail in
  let ts = Time_compat.now () in
  let entry : Team_session_types.event_entry =
    { ts; ts_iso = now_iso (); event_type; detail }
  in
  let line = Yojson.Safe.to_string (Team_session_types.event_entry_to_yojson entry) ^ "\n" in
  let path = events_jsonl_path config session_id in
  with_file_lock config path (fun () -> append_artifact_text config path line);
  emit_activity_event config ~session_id ~event_type ~detail;
  notify_team_session_mutation config ~session_id

let take_last n lst =
  if n <= 0 then []
  else
    let total = List.length lst in
    if total <= n then lst
    else lst |> List.filteri (fun i _ -> i >= total - n)

let parse_event_lines lines =
  List.filter_map
    (fun line ->
      let trimmed = String.trim line in
      if trimmed = "" then None
      else
        match Safe_ops.parse_json_safe ~context:"team_session.events" trimmed with
        | Ok json -> Some json
        | Error _ -> None)
    lines

(** Read the last [max_lines] from a file by reading the tail [max_bytes].
    Offloaded to system thread to avoid blocking the Eio scheduler. *)
let read_tail_lines path ~max_bytes ~max_lines =
  if max_lines <= 0 || max_bytes <= 0 || not (Fs_compat.file_exists path) then
    []
  else
    let f () =
      try
        let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
        Fun.protect
          ~finally:(fun () -> Unix.close fd)
          (fun () ->
            let stats = Unix.fstat fd in
            let file_size = stats.Unix.st_size in
            if file_size <= 0 then []
            else
              let bytes_to_read = min file_size max_bytes in
              let start_pos = max 0 (file_size - bytes_to_read) in
              ignore (Unix.lseek fd start_pos Unix.SEEK_SET);
              let buf = Bytes.create bytes_to_read in
              let rec read_loop offset remaining =
                if remaining <= 0 then offset
                else
                  match Unix.read fd buf offset remaining with
                  | 0 -> offset
                  | n -> read_loop (offset + n) (remaining - n)
              in
              let read_len = read_loop 0 bytes_to_read in
              if read_len <= 0 then []
              else
                let chunk = Bytes.sub_string buf 0 read_len in
                let normalized =
                  if start_pos = 0 then chunk
                  else
                    match String.index_opt chunk '\n' with
                    | Some idx ->
                        String.sub chunk (idx + 1) (String.length chunk - idx - 1)
                    | None -> ""
                in
                normalized
                |> String.split_on_char '\n'
                |> List.filter (fun line -> String.trim line <> "")
                |> take_last max_lines)
      with
      | Unix.Unix_error _ | Sys_error _ -> []
    in
    Eio_guard.run_in_systhread f

let read_events ?max_events config session_id : Yojson.Safe.t list =
  let path = events_jsonl_path config session_id in
  if not (path_exists config path) then
    []
  else
    match config.backend with
    | FileSystem _ when Fs_compat.file_exists path -> (
        match max_events with
        | Some n when n > 0 ->
            let tail_lines =
              read_tail_lines path
                ~max_bytes:(max 262_144 (n * 4096))
                ~max_lines:(n * 3)
            in
            let tail_parsed = parse_event_lines tail_lines in
            if List.length tail_parsed >= n then
              take_last n tail_parsed
            else
              let content = read_artifact_text config path in
              let all_lines = String.split_on_char '\n' content in
              parse_event_lines all_lines |> take_last n
        | _ ->
            let content = read_artifact_text config path in
            let all_lines = String.split_on_char '\n' content in
            parse_event_lines all_lines)
    | _ ->
        let content = read_artifact_text config path in
        let all_lines = String.split_on_char '\n' content in
        let parsed = parse_event_lines all_lines in
        (match max_events with
         | Some n when n > 0 -> take_last n parsed
         | _ -> parsed)

let write_checkpoint config session_id (checkpoint : Team_session_types.checkpoint) =
  let filename = Printf.sprintf "%Ld.json" (Int64.of_float (checkpoint.ts *. 1000.0)) in
  let path = Filename.concat (checkpoints_dir config session_id) filename in
  write_json config path (Team_session_types.checkpoint_to_yojson checkpoint);
  notify_team_session_mutation config ~session_id

let save_worker_run_json config session_id worker_run_id json =
  let path = worker_run_json_path config session_id worker_run_id in
  write_json config path json;
  notify_team_session_mutation config ~session_id

let save_worker_run_checkpoint_text config session_id worker_run_id content =
  let path = worker_run_checkpoint_path config session_id worker_run_id in
  write_text_file path content;
  notify_team_session_mutation config ~session_id

let save_worker_run_meta_json config session_id worker_run_id json =
  let path = worker_run_meta_path config session_id worker_run_id in
  write_json config path
    (normalize_worker_run_meta_json config ~session_id ~worker_run_id json);
  notify_team_session_mutation config ~session_id

let save_worker_run_proof_json config session_id worker_run_id json =
  let path = worker_run_proof_path config session_id worker_run_id in
  write_json config path json;
  notify_team_session_mutation config ~session_id

let immediate_dir_entries config dir =
  Room_utils.list_dir config dir
  |> List.filter_map (fun entry ->
         match String.split_on_char '/' entry with
         | segment :: _ when String.trim segment <> "" -> Some segment
         | _ -> None)
  |> Team_session_types.dedup_strings
  |> List.sort String.compare

let list_worker_run_ids config session_id =
  let dir = worker_runs_dir config session_id in
  immediate_dir_entries config dir

let list_checkpoint_paths config session_id =
  let dir = checkpoints_dir config session_id in
  Room_utils.list_dir config dir
  |> List.filter (fun name ->
         name <> ""
         && not (String.contains name '/')
         && Filename.check_suffix name ".json")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

let load_latest_checkpoint config session_id : Team_session_types.checkpoint option =
  match List.rev (list_checkpoint_paths config session_id) with
  | [] -> None
  | latest :: _ -> (
      try
        let json = read_json config latest in
        match Team_session_types.checkpoint_of_yojson json with
        | Ok cp -> Some cp
        | Error e ->
            Log.Session.error "checkpoint parse error (%s): %s" latest e;
            None
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Session.error "checkpoint load error (%s): %s" latest
          (Printexc.to_string exn);
        None)

let read_recent_events config session_id ~max_count :
    Team_session_types.event_entry list =
  try
    let raw = read_events ~max_events:max_count config session_id in
    List.filter_map
      (fun json ->
        match Team_session_types.event_entry_of_yojson json with
        | Ok e -> Some e
        | Error _ -> None)
      raw
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Session.error "read_recent_events error (%s): %s"
      session_id (Printexc.to_string exn);
    []

let session_recency_ts (session : Team_session_types.session) =
  match Resilience.Time.parse_iso8601_opt session.updated_at_iso with
  | Some ts -> ts
  | None -> session.started_at

let sort_sessions_by_recency sessions =
  List.sort
    (fun (left : Team_session_types.session) (right : Team_session_types.session) ->
      Float.compare (session_recency_ts right) (session_recency_ts left))
    sessions

let parse_session_row ~context value =
  let trimmed = String.trim value in
  if trimmed = "" then
    None
  else
    match Safe_ops.parse_json_safe ~context trimmed with
    | Ok json -> Team_session_types.session_of_yojson json
    | Error _ -> None

let session_query_prefix config =
  match key_of_path config (sessions_root config) with
  | Some key when String.trim key <> "" -> key ^ ":"
  | _ -> "team-sessions:"

let pg_recent_default_limit = 200

(** List sessions, optionally filtering by mtime to avoid loading stale history.
    [~since_unix] skips directories whose mtime is older than the given Unix timestamp.
    [~limit] caps the number of returned sessions (0 = unlimited).
    This turns a 1448-file full scan into loading only active/recent sessions. *)
let list_sessions ?(since_unix = 0.0) ?(limit = 0) config : Team_session_types.session list =
  let query_prefix = session_query_prefix config in
  let take_limit lst =
    if limit <= 0 then lst
    else
      let rec aux acc n = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | x :: xs -> aux (x :: acc) (n - 1) xs
      in
      aux [] limit lst
  in
  let pg_recent_attempted, pg_recent_result =
    match config.backend with
    | PostgresNative backend ->
        (* Always prefer PG when available. Safety cap prevents unbounded
           queries when caller omits limit. See #2778, #2770. *)
        let row_limit =
          if limit > 0 then limit
          else 10_000
        in
        ( true,
          Backend.Postgres.get_all_matching_recent backend
            ~prefix:query_prefix ~suffix:":session.json"
            ~updated_since:(max 0.0 since_unix) ~limit:row_limit )
    | _ -> (false, Error (Backend_types.BackendNotSupported "pg recent path unavailable"))
  in
  let fallback_reason = ref None in
  let last_error = ref None in
  let set_fallback reason err =
    fallback_reason := Some reason;
    last_error := Some (Backend_types.show_error err)
  in
  match
    match pg_recent_result with
    | Ok rows -> Ok ("pg_recent", rows)
    | Error err -> (
        if pg_recent_attempted then
          Log.Session.warn "list_sessions PG recent fallback: %s"
            (Backend_types.show_error err);
        set_fallback
          (if pg_recent_attempted then "pg_recent_failed"
           else "pg_recent_unavailable")
          err;
        match
          (match config.backend with
           | FileSystem _ -> Error (Backend_types.BackendNotSupported "force optimized filesystem scan")
           | _ -> backend_get_all config ~prefix:query_prefix)
        with
        | Ok rows -> Ok ("backend_get_all", rows)
        | Error err ->
            set_fallback "backend_get_all_failed" err;
            Error err)
  with
  | Ok (source, pairs) ->
      let parsed =
        pairs
      |> List.filter_map (fun (key, value) ->
             if not (String.ends_with ~suffix:":session.json" key) then None
             else parse_session_row ~context:"list_sessions" value)
      in
      let limited =
        parsed |> sort_sessions_by_recency |> take_limit
      in
      record_session_list_diagnostics ~pg_recent_attempted
        ~fallback_reason:!fallback_reason ~last_error:!last_error ~since_unix ~query_prefix
        ~limit ~source
        ~rows_scanned:(List.length pairs)
        ~rows_parsed:(List.length parsed)
        ~rows_returned:(List.length limited);
      limited
  | Error err ->
      set_fallback "filesystem_scan" err;
      let root = sessions_root config in
      if not (path_exists config root) then (
        record_session_list_diagnostics
          ~pg_recent_attempted ~fallback_reason:!fallback_reason
          ~last_error:!last_error ~since_unix ~limit ~query_prefix ~source:"filesystem"
          ~rows_scanned:0 ~rows_parsed:0 ~rows_returned:0;
        [])
      else
        let dirs = Sys.readdir root |> Array.to_list in
        let filtered =
          if since_unix <= 0.0 then dirs
          else
            List.filter (fun session_id ->
              let dir_path = Filename.concat root session_id in
              try
                let stat = Unix.stat dir_path in
                if stat.Unix.st_mtime >= since_unix then true
                else
                  (* Lightweight status check: keep Running/Paused sessions
                     even when mtime is stale (long-lived sessions).
                     Read first 512 bytes of session.json for quick substring match. *)
                  let state_path = Filename.concat dir_path "session.json" in
                  (try
                    let content = Fs_compat.load_file state_path in
                    let snippet =
                      if String.length content > 512 then String.sub content 0 512
                      else content
                    in
                    (* Status field appears early in the JSON *)
                    let has_sub haystack needle =
                      let nl = String.length needle in
                      let hl = String.length haystack in
                      if nl > hl then false
                      else
                        let found = ref false in
                        let i = ref 0 in
                        while !i <= hl - nl && not !found do
                          if String.sub haystack !i nl = needle then found := true
                          else incr i
                        done;
                        !found
                    in
                    has_sub snippet {|"Running"|}
                || has_sub snippet {|"Paused"|}
                  with Sys_error _ | End_of_file | Eio.Io _ -> false)
              with Unix.Unix_error _ -> true
            ) dirs
        in
        let parsed =
          List.filter_map (fun session_id -> load_session config session_id) filtered
        in
        let limited =
          parsed |> sort_sessions_by_recency |> take_limit
        in
        record_session_list_diagnostics ~pg_recent_attempted
          ~fallback_reason:!fallback_reason ~last_error:!last_error ~since_unix ~query_prefix
          ~limit ~source:"filesystem"
          ~rows_scanned:(List.length filtered)
          ~rows_parsed:(List.length parsed)
          ~rows_returned:(List.length limited);
        limited

let update_session config session_id f =
  let path = session_json_path config session_id in
  with_file_lock config path (fun () ->
      if not (path_exists config path) then
        Error (Printf.sprintf "team session not found: %s" session_id)
      else
        match Team_session_types.session_of_yojson (read_json config path) with
        | None ->
            Error
              (Printf.sprintf "team session parse failed: %s" session_id)
        | Some session ->
            let updated = f session in
            write_json config path
              (Team_session_types.session_to_yojson updated);
            Ok updated)

let mark_report_generated config session_id =
  update_session config session_id (fun s ->
      { s with generated_report = true; updated_at_iso = now_iso () })

let make_session_id () =
  let ms = Int64.of_float (Time_compat.now () *. 1000.0) in
  let high = Int64.of_int (Random.bits ()) in
  let low = Int64.of_int (Random.bits ()) in
  let rnd = Int64.logor (Int64.shift_left high 30) low in
  Printf.sprintf "ts-%Ld-%015Lx" ms rnd

let relative_artifacts_dir config session_id =
  let root = sessions_root config in
  let abs = session_dir config session_id in
  let root_prefix = root ^ Filename.dir_sep in
  if String.length abs >= String.length root_prefix
     && String.sub abs 0 (String.length root_prefix) = root_prefix
  then
    Filename.concat ".masc/team-sessions"
      (String.sub abs (String.length root_prefix)
         (String.length abs - String.length root_prefix))
  else
    Filename.concat ".masc/team-sessions" session_id
