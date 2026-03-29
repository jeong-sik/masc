open Tool_repair_loop_types

let repair_root config =
  Filename.concat (Room.masc_dir config) "repair_loops"

let loop_dir config loop_id =
  Filename.concat (repair_root config) loop_id

let state_file config loop_id =
  Filename.concat (loop_dir config loop_id) "state.json"

let attempt_dir config loop_id attempt_index =
  Filename.concat (loop_dir config loop_id)
    (Printf.sprintf "attempt-%02d" attempt_index)

let attempt_code_file config loop_id attempt_index =
  Filename.concat (attempt_dir config loop_id attempt_index) "candidate.ml"

let ensure_loop_dir config loop_id =
  Fs_compat.mkdir_p (loop_dir config loop_id)

let ensure_attempt_dir config loop_id attempt_index =
  Fs_compat.mkdir_p (attempt_dir config loop_id attempt_index)

let save_state config (state : state) =
  ensure_loop_dir config state.loop_id;
  Fs_compat.save_file (state_file config state.loop_id)
    (Yojson.Safe.pretty_to_string (state_to_json state))

let load_state config loop_id =
  let path = state_file config loop_id in
  if Sys.file_exists path then
    try Ok (Yojson.Safe.from_file path |> state_of_json)
    with exn ->
      Error
        (Printf.sprintf "repair loop state load failed for %s: %s" loop_id
           (Printexc.to_string exn))
  else
    Error (Printf.sprintf "repair loop not found: %s" loop_id)

let write_attempt_code config loop_id attempt_index code =
  ensure_attempt_dir config loop_id attempt_index;
  let path = attempt_code_file config loop_id attempt_index in
  Fs_compat.save_file path code;
  path

let write_attempt_aux config loop_id attempt_index name content =
  ensure_attempt_dir config loop_id attempt_index;
  let path = Filename.concat (attempt_dir config loop_id attempt_index) name in
  Fs_compat.save_file path content;
  path

let maybe_read_file path =
  if Sys.file_exists path then Some (In_channel.with_open_bin path In_channel.input_all)
  else None

let restore_file path original_content =
  match original_content with
  | Some content -> Fs_compat.save_file path content
  | None ->
      if Sys.file_exists path then Sys.remove path

let append_event config loop_id event_type payload =
  ensure_loop_dir config loop_id;
  let path = Filename.concat (loop_dir config loop_id) "events.jsonl" in
  Fs_compat.append_jsonl path
    (`Assoc
      [
        ("timestamp", `Float (Time_compat.now ()));
        ("event_type", `String event_type);
        ("payload", payload);
      ])
