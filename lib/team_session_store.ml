(** Team session persistence helpers. *)

open Room_utils

let sessions_root config =
  Filename.concat (masc_dir config) "team-sessions"

let session_dir config session_id =
  Filename.concat (sessions_root config) session_id

let checkpoints_dir config session_id =
  Filename.concat (session_dir config session_id) "checkpoints"

let session_json_path config session_id =
  Filename.concat (session_dir config session_id) "session.json"

let events_jsonl_path config session_id =
  Filename.concat (session_dir config session_id) "events.jsonl"

let report_md_path config session_id =
  Filename.concat (session_dir config session_id) "report.md"

let report_json_path config session_id =
  Filename.concat (session_dir config session_id) "report.json"

let now_iso () = Types.now_iso ()

let ensure_session_dirs config session_id =
  mkdir_p (session_dir config session_id);
  mkdir_p (checkpoints_dir config session_id)

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
  if path_exists config path then
    Team_session_types.session_of_yojson (read_json config path)
  else
    None

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

let read_events config session_id : Yojson.Safe.t list =
  let path = events_jsonl_path config session_id in
  if not (Sys.file_exists path) then
    []
  else
    let content = In_channel.with_open_text path In_channel.input_all in
    content
    |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
           let trimmed = String.trim line in
           if trimmed = "" then None
           else
             match Safe_ops.parse_json_safe ~context:"team_session.events" trimmed with
             | Ok json -> Some json
             | Error _ -> None)

let write_checkpoint config session_id (checkpoint : Team_session_types.checkpoint) =
  let filename = Printf.sprintf "%Ld.json" (Int64.of_float (checkpoint.ts *. 1000.0)) in
  let path = Filename.concat (checkpoints_dir config session_id) filename in
  write_json config path (Team_session_types.checkpoint_to_yojson checkpoint)

let list_checkpoint_paths config session_id =
  let dir = checkpoints_dir config session_id in
  if not (Sys.file_exists dir) then
    []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".json")
    |> List.sort String.compare
    |> List.map (Filename.concat dir)

let list_sessions config : Team_session_types.session list =
  let root = sessions_root config in
  if not (Sys.file_exists root) then
    []
  else
    Sys.readdir root
    |> Array.to_list
    |> List.filter_map (fun session_id -> load_session config session_id)

let update_session config session_id f =
  match load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      let updated = f session in
      save_session config updated;
      Ok updated

let mark_report_generated config session_id =
  update_session config session_id (fun s ->
      { s with generated_report = true; updated_at_iso = now_iso () })

let make_session_id () =
  let ms = Int64.of_float (Time_compat.now () *. 1000.0) in
  let rnd = Random.bits () land 0xFFFF in
  Printf.sprintf "ts-%Ld-%04x" ms rnd

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
