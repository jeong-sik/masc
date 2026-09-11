type port = int
type error = Invalid_port | Invalid_configuration | Configuration_unavailable | Write_failed
let ( let* ) = Result.bind
let error_message = function
  | Invalid_port -> "The HTTP port must be an integer from 1 through 65535."
  | Invalid_configuration -> "The workspace connection.toml has an invalid server.http_port. Repair it or supply --port."
  | Configuration_unavailable -> "The workspace connection configuration could not be read safely."
  | Write_failed -> "The selected HTTP port could not be saved durably. Supply --port on the next connection."
let port n = if n > 0 && n <= 65535 then Ok n else Error Invalid_port
let to_int n = n
let path base_path =
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config") "connection.toml"
let parse text =
  match Otoml.Parser.from_string_result text with
  | Error _ -> Error Invalid_configuration
  | Ok document ->
    match Otoml.find_opt document (fun value -> value) ["server"] with
    | None -> Ok None
    | Some (Otoml.TomlTable fields | Otoml.TomlInlineTable fields) ->
      (match List.assoc_opt "http_port" fields with
       | None -> Ok None
       | Some (Otoml.TomlInteger n) -> port n |> Result.map Option.some |> Result.map_error (fun _ -> Invalid_configuration)
       | Some _ -> Error Invalid_configuration)
    | Some _ -> Error Invalid_configuration
let snapshot file =
  try
    let _ = Unix.lstat file in
    Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:(Filename.dirname file) file
    |> Result.map_error (fun _ -> Configuration_unavailable)
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
     | Unix.Unix_error _ -> Error Configuration_unavailable
let read ~base_path =
  let* file = snapshot (path base_path) in
  match file with None -> Ok None | Some value -> parse value.Fs_compat.content
let resolve ~base_path ~cli ~environment =
  match cli with
  | Some value -> port value
  | None ->
    match Env_config_core.trim_opt environment with
    | Some value -> (match int_of_string_opt value with Some n -> port n | None -> Error Invalid_port)
    | None ->
      let* stored = match base_path with None -> Ok None | Some base_path -> read ~base_path in
      match stored with Some value -> Ok value | None -> port Masc_network_defaults.masc_http_default_port
let save ~base_path ~port =
  let file = path base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname file);
    match File_lock_eio.with_durable_lock_observed ~lock_path:(file ^ ".lock") (fun () ->
      let* original = snapshot file in
      let contents,mode = match original with
        | None -> "",0o600
        | Some value -> value.Fs_compat.content,value.snapshot.permissions in
      let* _ = parse contents in
      let updated = Toml_line_editor.edit_table_int contents ~path:"server" ~key:"http_port" ~value:port in
      let* stored = parse updated in
      let* () = if stored = Some port then Ok () else Error Invalid_configuration in
      match Fs_compat.write_file_atomic_strict_staged file ~write:(fun channel ->
        Unix.fchmod (Unix.descr_of_out_channel channel) mode; output_string channel updated) with
      | Ok () -> Ok () | Error _ -> Error Write_failed) with
    | File_lock_eio.Body_completed {value;release_error=None} -> value
    | File_lock_eio.Body_completed {release_error=Some _;_} | File_lock_eio.Lock_not_acquired _ -> Error Write_failed
  with Sys_error _ | Unix.Unix_error _ -> Error Write_failed
