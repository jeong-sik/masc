open Tool_repair_loop_types

let repair_root config =
  Filename.concat (Room.masc_dir config) "repair_loops"

let is_valid_loop_id_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false

let validate_loop_id loop_id =
  let loop_id = String.trim loop_id in
  if loop_id = "" then
    Error "loop_id must not be empty"
  else if String.equal loop_id "." || String.equal loop_id ".." then
    Error "loop_id contains invalid path components"
  else if String.contains loop_id '/' || String.contains loop_id '\\' then
    Error "loop_id must not contain path separators"
  else if not (String.for_all is_valid_loop_id_char loop_id) then
    Error "loop_id contains invalid characters"
  else
    Ok loop_id

let validated_loop_id_exn loop_id =
  match validate_loop_id loop_id with
  | Ok loop_id -> loop_id
  | Error message -> invalid_arg message

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
  let loop_id = validated_loop_id_exn loop_id in
  Fs_compat.mkdir_p (loop_dir config loop_id)

let ensure_attempt_dir config loop_id attempt_index =
  let loop_id = validated_loop_id_exn loop_id in
  Fs_compat.mkdir_p (attempt_dir config loop_id attempt_index)

let save_state config (state : state) =
  let loop_id = validated_loop_id_exn state.loop_id in
  ensure_loop_dir config loop_id;
  Fs_compat.save_file (state_file config loop_id)
    (Yojson.Safe.pretty_to_string (state_to_json state))

let load_state config loop_id =
  match validate_loop_id loop_id with
  | Error message -> Error message
  | Ok loop_id ->
      let path = state_file config loop_id in
      if Sys.file_exists path then
        try Ok (Yojson.Safe.from_file path |> state_of_json)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Error
            (Printf.sprintf "repair loop state load failed for %s: %s" loop_id
               (Printexc.to_string exn))
      else
        Error (Printf.sprintf "repair loop not found: %s" loop_id)

let write_attempt_code config loop_id attempt_index code =
  let loop_id = validated_loop_id_exn loop_id in
  ensure_attempt_dir config loop_id attempt_index;
  let path = attempt_code_file config loop_id attempt_index in
  Fs_compat.save_file path code;
  path

let write_attempt_aux config loop_id attempt_index name content =
  let loop_id = validated_loop_id_exn loop_id in
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
  let loop_id = validated_loop_id_exn loop_id in
  ensure_loop_dir config loop_id;
  let path = Filename.concat (loop_dir config loop_id) "events.jsonl" in
  Fs_compat.append_jsonl path
    (`Assoc
      [
        ("timestamp", `Float (Time_compat.now ()));
        ("event_type", `String event_type);
        ("payload", payload);
      ])
