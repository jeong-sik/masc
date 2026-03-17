(** Team session persistence helpers. *)

open Room_utils

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

let ensure_session_dirs config session_id =
  mkdir_p (session_dir config session_id);
  mkdir_p (checkpoints_dir config session_id);
  mkdir_p (worker_runs_dir config session_id)

let read_text_file path =
  if Sys.file_exists path then
    In_channel.with_open_text path In_channel.input_all
  else
    ""

let write_text_file path content =
  mkdir_p (Filename.dirname path);
  let tmp = path ^ ".tmp" in
  Out_channel.with_open_text tmp (fun oc ->
    Out_channel.output_string oc content;
    Out_channel.flush oc);
  Unix.rename tmp path

let append_text_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out_gen [ Open_creat; Open_append; Open_wronly ] 0o600 path in
  Common.protect ~module_name:"team_session_store" ~finally_label:"finalizer"
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let save_session config (session : Team_session_types.session) =
  let path = session_json_path config session.session_id in
  with_file_lock config path (fun () ->
      write_json config path (Team_session_types.session_to_yojson session))

let load_session config session_id : Team_session_types.session option =
  let path = session_json_path config session_id in
  match read_json_opt config path with
  | None -> None
  | Some json -> Team_session_types.session_of_yojson json

let load_session_or_error config session_id =
  match load_session config session_id with
  | Some s -> Ok s
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)

let append_event config session_id ~(event_type : string) ~(detail : Yojson.Safe.t) =
  let ts = Time_compat.now () in
  let entry : Team_session_types.event_entry =
    { ts; ts_iso = now_iso (); event_type; detail }
  in
  let line = Yojson.Safe.to_string (Team_session_types.event_entry_to_yojson entry) ^ "\n" in
  let path = events_jsonl_path config session_id in
  with_file_lock config path (fun () -> append_text_file path line)

let read_events ?max_events config session_id : Yojson.Safe.t list =
  let path = events_jsonl_path config session_id in
  if not (path_exists config path) then
    []
  else
    (* Read-only: no lock needed. Append-only JSONL is safe for concurrent reads. *)
    match max_events with
    | Some n when n > 0 ->
        let q = Queue.create () in
        In_channel.with_open_text path (fun ic ->
            (try
               while true do
                 let line = input_line ic in
                 let trimmed = String.trim line in
                 if trimmed <> "" then
                   match
                     Safe_ops.parse_json_safe ~context:"team_session.events" trimmed
                   with
                   | Ok json ->
                       Queue.add json q;
                       if Queue.length q > n then ignore (Queue.take q)
                   | Error _ -> ()
               done
             with End_of_file -> ());
            Queue.to_seq q |> List.of_seq)
    | _ ->
        In_channel.with_open_text path (fun ic ->
            let rec loop acc =
              match input_line ic with
              | line ->
                  let trimmed = String.trim line in
                  let acc' =
                    if trimmed = "" then
                      acc
                    else
                      match
                        Safe_ops.parse_json_safe ~context:"team_session.events" trimmed
                      with
                      | Ok json -> json :: acc
                      | Error _ -> acc
                  in
                  loop acc'
              | exception End_of_file -> List.rev acc
            in
            loop [])

let write_checkpoint config session_id (checkpoint : Team_session_types.checkpoint) =
  let filename = Printf.sprintf "%Ld.json" (Int64.of_float (checkpoint.ts *. 1000.0)) in
  let path = Filename.concat (checkpoints_dir config session_id) filename in
  write_json config path (Team_session_types.checkpoint_to_yojson checkpoint)

let save_worker_run_json config session_id worker_run_id json =
  let path = worker_run_json_path config session_id worker_run_id in
  write_json config path json

let save_worker_run_checkpoint_text config session_id worker_run_id content =
  let path = worker_run_checkpoint_path config session_id worker_run_id in
  write_text_file path content

let save_worker_run_meta_json config session_id worker_run_id json =
  let path = worker_run_meta_path config session_id worker_run_id in
  write_json config path json

let list_worker_run_ids config session_id =
  let dir = worker_runs_dir config session_id in
  if not (path_exists config dir) then
    []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.sort String.compare

let list_checkpoint_paths config session_id =
  let dir = checkpoints_dir config session_id in
  if not (path_exists config dir) then
    []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".json")
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
      with exn ->
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
  with exn ->
    Log.Session.error "read_recent_events error (%s): %s"
      session_id (Printexc.to_string exn);
    []

(** List sessions, optionally filtering by mtime to avoid loading stale history.
    [~since_unix] skips directories whose mtime is older than the given Unix timestamp.
    This turns a 1448-file full scan into loading only active/recent sessions. *)
let list_sessions ?(since_unix = 0.0) config : Team_session_types.session list =
  match backend_get_all config ~prefix:"team-sessions:" with
  | Ok pairs ->
      pairs
      |> List.filter_map (fun (key, value) ->
             if not (String.ends_with ~suffix:":session.json" key) then None
             else
               let trimmed = String.trim value in
               if trimmed = "" then None
               else
                 match Safe_ops.parse_json_safe ~context:"list_sessions" trimmed with
                 | Ok json -> Team_session_types.session_of_yojson json
                 | Error _ -> None)
  | Error _ ->
      let root = sessions_root config in
      if not (path_exists config root) then []
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
                    let ic = open_in state_path in
                    let buf = Bytes.create 512 in
                    let n =
                      Common.protect ~module_name:"team_session_store"
                        ~finally_label:"finalizer"
                        ~finally:(fun () -> close_in_noerr ic)
                        (fun () -> input ic buf 0 512)
                    in
                    let snippet = Bytes.sub_string buf 0 n in
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
                  with Sys_error _ | End_of_file -> false)
              with Unix.Unix_error _ -> true
            ) dirs
        in
        List.filter_map (fun session_id -> load_session config session_id) filtered

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
