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

let load_json_file path =
  if not (Fs_compat.file_exists path) then
    None
  else
    try
      let content = Fs_compat.load_file path in
      Some (Yojson.Safe.from_string content)
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None

let load_swarm_link_by_loop ~base_path loop_id =
  load_json_file (loop_link_file ~base_path loop_id)
  |> Option.map Autoresearch_serde.swarm_link_of_yojson

let load_swarm_link_by_session ~base_path session_id =
  load_json_file (session_link_file ~base_path session_id)
  |> Option.map Autoresearch_serde.swarm_link_of_yojson

let load_state ~base_path loop_id =
  load_json_file (state_file ~base_path loop_id)
  |> Option.map Autoresearch_serde.state_of_yojson

let latest_cycle_record ~base_path loop_id =
  let path = results_file ~base_path loop_id in
  if not (Fs_compat.file_exists path) then
    None
  else
    let lines = Fs_compat.load_jsonl path in
    List.fold_left (fun last json ->
      try Some (Autoresearch_serde.cycle_of_yojson json)
      with
      | Yojson.Json_error _ -> last
      | exn ->
          Log.Autoresearch.warn "cycle parse failed: %s" (Printexc.to_string exn);
          last
    ) None lines
