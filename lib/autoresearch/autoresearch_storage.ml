(** Autoresearch_storage — File paths and persistence for autoresearch loops.

    Handles results directory layout, JSONL append, state save/load,
    and swarm link persistence.

    @since 2.80.0 *)

(** Results directory for a loop: .masc/autoresearch/{loop_id}/ *)
let results_dir ~base_path loop_id =
  Filename.concat base_path
    (Filename.concat ".masc"
       (Filename.concat "autoresearch" loop_id))

let results_file ~base_path loop_id =
  Filename.concat (results_dir ~base_path loop_id) "results.jsonl"

let state_file ~base_path loop_id =
  Filename.concat (results_dir ~base_path loop_id) "state.json"

let loop_link_file ~base_path loop_id =
  Filename.concat (results_dir ~base_path loop_id) "swarm.json"

let managed_worktree_dir ~base_path loop_id =
  Filename.concat (results_dir ~base_path loop_id) "worktree"

let session_link_file ~base_path session_id =
  Filename.concat base_path
    (Filename.concat ".masc"
       (Filename.concat "team-sessions"
          (Filename.concat session_id "autoresearch.json")))

let ensure_dir path =
  let rec mkdir_p dir =
    if not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      (try Sys.mkdir dir 0o755 with Sys_error _ -> ())
    end
  in
  mkdir_p path

let append_cycle ~base_path loop_id record =
  let dir = results_dir ~base_path loop_id in
  Fs_compat.mkdir_p dir;
  let path = results_file ~base_path loop_id in
  let line = Yojson.Safe.to_string (Autoresearch_serde.cycle_to_yojson record) ^ "\n" in
  Fs_compat.append_file path line

let save_state ~base_path (state : Autoresearch_types.loop_state) =
  let dir = results_dir ~base_path state.loop_id in
  Fs_compat.mkdir_p dir;
  let path = state_file ~base_path state.loop_id in
  let json = Yojson.Safe.pretty_to_string (Autoresearch_serde.state_to_yojson state) in
  Fs_compat.save_file path json

let save_swarm_link ~base_path (link : Autoresearch_types.swarm_link) =
  let loop_path = loop_link_file ~base_path link.loop_id in
  let session_path = session_link_file ~base_path link.session_id in
  let json = Autoresearch_serde.swarm_link_to_yojson link in
  let write path =
    let dir = Filename.dirname path in
    Fs_compat.mkdir_p dir;
    Fs_compat.save_file path (Yojson.Safe.pretty_to_string json)
  in
  write loop_path;
  write session_path

let load_json_file_result path =
  if not (Fs_compat.file_exists path) then
    None
  else
    try
      let content = Fs_compat.load_file path in
      Some (Ok (Yojson.Safe.from_string content))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Yojson.Json_error msg -> Some (Error msg)
    | exn -> Some (Error (Printexc.to_string exn))

let decode_json_file_result ~path ~kind decode =
  match load_json_file_result path with
  | None -> None
  | Some (Error msg) -> Some (Error (Printf.sprintf "%s load failed for %s: %s" kind path msg))
  | Some (Ok json) ->
      Some
        (match decode json with
         | Ok value -> Ok value
         | Error msg ->
             Error (Printf.sprintf "%s decode failed for %s: %s" kind path msg))

let load_swarm_link_by_loop_result ~base_path loop_id =
  let path = loop_link_file ~base_path loop_id in
  decode_json_file_result ~path ~kind:"swarm link"
    Autoresearch_serde.swarm_link_of_yojson_result

let load_swarm_link_by_loop ~base_path loop_id =
  match load_swarm_link_by_loop_result ~base_path loop_id with
  | None -> None
  | Some (Ok link) -> Some link
  | Some (Error msg) ->
      Log.Autoresearch.warn "%s" msg;
      None

let load_swarm_link_by_session_result ~base_path session_id =
  let path = session_link_file ~base_path session_id in
  decode_json_file_result ~path ~kind:"swarm link"
    Autoresearch_serde.swarm_link_of_yojson_result

let load_swarm_link_by_session ~base_path session_id =
  match load_swarm_link_by_session_result ~base_path session_id with
  | None -> None
  | Some (Ok link) -> Some link
  | Some (Error msg) ->
      Log.Autoresearch.warn "%s" msg;
      None

let load_state_result ~base_path loop_id =
  let path = state_file ~base_path loop_id in
  let file_mtime_opt () =
    try Some ((Unix.stat path).Unix.st_mtime)
    with Unix.Unix_error _ -> None
  in
  match load_json_file_result path with
  | None -> None
  | Some (Error msg) -> Some (Error (Printf.sprintf "autoresearch state load failed for %s: %s" path msg))
  | Some (Ok json) ->
      Some
        (match json with
         | `Assoc fields
           when List.mem_assoc "llm_model" fields
                && not (List.mem_assoc "model_model" fields) ->
             Error
               (Printf.sprintf
                  "unsupported legacy autoresearch state schema for %s: found llm_model; expected model_model"
                  path)
         | _ ->
             (match Autoresearch_serde.state_of_yojson_result json with
              | Ok summary ->
                  Ok
                    (match summary.updated_at with
                     | Some _ -> summary
                     | None -> { summary with updated_at = file_mtime_opt () })
              | Error msg ->
                  Error
                    (Printf.sprintf "autoresearch state decode failed for %s: %s"
                       path msg)))

let load_state ~base_path loop_id =
  match load_state_result ~base_path loop_id with
  | None -> None
  | Some (Ok summary) -> Some summary
  | Some (Error msg) ->
      Log.Autoresearch.error "%s" msg;
      None

let latest_cycle_record ~base_path loop_id =
  let path = results_file ~base_path loop_id in
  if not (Fs_compat.file_exists path) then
    None
  else
    let lines =
      try
        Fs_compat.load_file path
        |> String.split_on_char '\n'
        |> List.filter (fun line -> String.length (String.trim line) > 0)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Autoresearch.warn "cycle history load failed for %s: %s"
            path (Printexc.to_string exn);
          []
    in
    List.fold_left
      (fun last line ->
        match
          try Ok (Yojson.Safe.from_string line)
          with Yojson.Json_error msg -> Error msg
        with
        | Ok json -> (
            match Autoresearch_serde.cycle_of_yojson_result json with
            | Ok cycle -> Some cycle
            | Error msg ->
                Log.Autoresearch.warn "cycle parse failed for %s: %s" path msg;
                last)
        | Error msg ->
            Log.Autoresearch.warn "cycle JSON parse failed for %s: %s" path msg;
            last)
      None lines

(** Load full cycle history from results.jsonl for a loop. *)
let load_cycle_history ~base_path loop_id =
  let path = results_file ~base_path loop_id in
  if not (Fs_compat.file_exists path) then
    []
  else
    let lines =
      try
        Fs_compat.load_file path
        |> String.split_on_char '\n'
        |> List.filter (fun line -> String.length (String.trim line) > 0)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Autoresearch.warn "cycle history load failed for %s: %s"
            path (Printexc.to_string exn);
          []
    in
    List.filter_map
      (fun line ->
        match
          try Ok (Yojson.Safe.from_string line)
          with Yojson.Json_error msg -> Error msg
        with
        | Ok json -> (
            match Autoresearch_serde.cycle_of_yojson_result json with
            | Ok cycle -> Some cycle
            | Error msg ->
                Log.Autoresearch.warn "cycle parse skipped for %s: %s" path msg;
                None)
        | Error msg ->
            Log.Autoresearch.warn "cycle JSON parse skipped for %s: %s" path msg;
            None)
      lines

(** Scan .masc/autoresearch/ for all persisted loop IDs.
    Returns loop IDs (directory names) that contain a state.json file. *)
let scan_persisted_loop_ids ~base_path =
  let dir = Filename.concat base_path (Filename.concat ".masc" "autoresearch") in
  if not (Fs_compat.file_exists dir) then []
  else
    try
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun name ->
             let state_path = Filename.concat (Filename.concat dir name) "state.json" in
             Fs_compat.file_exists state_path)
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []
