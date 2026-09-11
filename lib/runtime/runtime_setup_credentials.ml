type pending = { path : string; mutable retained : bool }
type error = Invalid_secret | Private_storage_unavailable | Provider_not_http | Configuration_rejected | Configuration_changed
let error_message = function
  | Invalid_secret -> "Enter one raw API key, not a credential document."
  | Private_storage_unavailable -> "Private credential storage is unavailable. Check the user configuration directory permissions."
  | Provider_not_http -> "Select an existing HTTP provider connection."
  | Configuration_rejected -> "The connection configuration could not be saved; its existing settings were preserved."
  | Configuration_changed -> "Connection settings changed. Refresh before applying an API key."
let reference_path pending = pending.path
let retain pending = pending.retained <- true
let remove_uncommitted pending =
  if not pending.retained then
    try Unix.unlink pending.path with Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let valid_secret secret =
  secret <> "" && not (String.exists (fun c -> Char.code c < 32 || Char.code c = 127) secret)
  && (try match Yojson.Safe.from_string secret with `Assoc _ | `List _ -> false | _ -> true
      with Yojson.Json_error _ -> true)
let save ~secret () =
  let secret = String.trim secret in
  if not (valid_secret secret) then Error Invalid_secret else
  match Env_config_core.default_base_path_record_path_opt () with
  | None -> Error Private_storage_unavailable
  | Some record ->
    let parent = Filename.dirname record in
    if Filename.is_relative parent then Error Private_storage_unavailable else
    let directory = Filename.concat parent "credentials" in
    try
      Fs_compat.mkdir_p parent;
      (try Unix.mkdir directory 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let stat = Unix.lstat directory in
      if stat.st_kind <> Unix.S_DIR || stat.st_uid <> Unix.geteuid () || stat.st_perm land 0o077 <> 0
      then Error Private_storage_unavailable
      else
        let path = Filename.concat (Unix.realpath directory) ("api-" ^ Auth.generate_token ()) in
        let pending = { path; retained = false } in
        (try Auth.save_private_text_file path secret; Ok pending with
         | Eio.Cancel.Cancelled _ as cancellation ->
           let backtrace = Printexc.get_raw_backtrace () in
           remove_uncommitted pending;
           Printexc.raise_with_backtrace cancellation backtrace
         | Sys_error _ | Unix.Unix_error _ ->
           remove_uncommitted pending; Error Private_storage_unavailable)
    with Sys_error _ | Unix.Unix_error _ -> Error Private_storage_unavailable
exception Provider_rejected
exception Revision_changed
let apply_to_provider ~runtime_config_path ~provider_id ~expected_source_revision pending =
  let edit contents =
    let observed = Runtime.config_observation ~path:runtime_config_path contents in
    if Runtime.config_source_revision_to_string observed.source_revision <> expected_source_revision
    then raise Revision_changed;
    let config = match Runtime_toml.parse_string contents with
      | Ok config -> config | Error _ -> raise Provider_rejected in
    let provider = List.find_opt (fun (p : Runtime_schema.provider) -> p.id = provider_id) config.providers in
    (match provider with Some { transport = Runtime_schema.Http _; _ } -> () | _ -> raise Provider_rejected);
    let table = "providers.\"" ^ Toml_line_editor.escape_string provider_id ^ "\".credentials" in
    List.fold_left (fun text (key, value) ->
      Toml_line_editor.edit_table_scalar text ~path:table ~key ~value)
      contents ["type", Some "file"; "path", Some pending.path; "key", None; "value", None]
  in
  try
    match Runtime.edit_config_text ~runtime_config_path edit with
    | Ok receipt -> retain pending; Ok receipt
    | Error _ -> Error Configuration_rejected
  with Provider_rejected -> Error Provider_not_http | Revision_changed -> Error Configuration_changed
