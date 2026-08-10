type error =
  | Invalid_runtime_root of string
  | Invalid_owner_leaf of string
  | Unsafe_directory of
      { path : string
      ; detail : string
      }
  | Invalid_oauth_source of
      { path : string
      ; detail : string
      }
  | Invalid_managed_oauth of
      { path : string
      ; detail : string
      }
  | Settings_write_failed of
      { path : string
      ; detail : string
      }
  | Mcp_config_write_failed of
      { path : string
      ; detail : string
      }
  | Mcp_config_cleanup_failed of
      { path : string
      ; detail : string
      }

type t =
  { home_dir : string
  ; settings_path : string
  ; mcp_config_path : string
  ; oauth_path : string
  }

let error_to_string = function
  | Invalid_runtime_root detail -> "invalid Antigravity runtime root: " ^ detail
  | Invalid_owner_leaf owner_leaf ->
    Printf.sprintf "invalid Antigravity owner leaf %S" owner_leaf
  | Unsafe_directory { path; detail } ->
    Printf.sprintf "unsafe Antigravity directory %s: %s" path detail
  | Invalid_oauth_source { path; detail } ->
    Printf.sprintf "invalid Antigravity OAuth source %s: %s" path detail
  | Invalid_managed_oauth { path; detail } ->
    Printf.sprintf "invalid managed Antigravity OAuth file %s: %s" path detail
  | Settings_write_failed { path; detail } ->
    Printf.sprintf "failed to write Antigravity settings %s: %s" path detail
  | Mcp_config_write_failed { path; detail } ->
    Printf.sprintf "failed to write Antigravity MCP config %s: %s" path detail
  | Mcp_config_cleanup_failed { path; detail } ->
    Printf.sprintf "failed to clear Antigravity MCP config %s: %s" path detail
;;

let unix_error_detail error fn arg =
  Printf.sprintf
    "%s%s%s"
    (Unix.error_message error)
    (if String.equal fn "" then "" else ": " ^ fn)
    (if String.equal arg "" then "" else " " ^ arg)
;;

let file_kind_name = function
  | Unix.S_REG -> "regular_file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let effective_uid = Unix.geteuid ()

let verify_runtime_root path =
  if Filename.is_relative path
  then Error (Invalid_runtime_root "path must be absolute")
  else
    try
      let stat = Unix.lstat path in
      let canonical_path = Unix.realpath path in
      if not (String.equal canonical_path path)
      then
        Error
          (Invalid_runtime_root
             (Printf.sprintf "path resolves to %s instead of itself" canonical_path))
      else if stat.Unix.st_kind <> Unix.S_DIR
      then
        Error
          (Invalid_runtime_root
             (Printf.sprintf
                "%s has kind %s"
                path
                (file_kind_name stat.Unix.st_kind)))
      else if stat.Unix.st_uid <> effective_uid
      then
        Error
          (Invalid_runtime_root
             (Printf.sprintf
                "%s is owned by uid %d, expected %d"
                path
                stat.Unix.st_uid
                effective_uid))
      else Ok ()
    with
    | Unix.Unix_error (error, fn, arg) ->
      Error (Invalid_runtime_root (unix_error_detail error fn arg))
;;

let verify_private_directory path =
  try
    let stat = Unix.lstat path in
    let canonical_path = Unix.realpath path in
    if not (String.equal canonical_path path)
    then
      Error
        (Unsafe_directory
           { path; detail = Printf.sprintf "path resolves to %s" canonical_path })
    else if stat.Unix.st_kind <> Unix.S_DIR
    then
      Error
        (Unsafe_directory
           { path
           ; detail = "expected directory, found " ^ file_kind_name stat.Unix.st_kind
           })
    else if stat.Unix.st_uid <> effective_uid
    then
      Error
        (Unsafe_directory
           { path
           ; detail =
               Printf.sprintf
                 "owned by uid %d, expected %d"
                 stat.Unix.st_uid
                 effective_uid
           })
    else
      let mode = stat.Unix.st_perm land 0o7777 in
      if mode <> 0o700
      then
        Error
          (Unsafe_directory
             { path
             ; detail = Printf.sprintf "mode is %04o, expected 0700" mode
             })
      else Ok ()
  with
  | Unix.Unix_error (error, fn, arg) ->
    Error (Unsafe_directory { path; detail = unix_error_detail error fn arg })
;;

let ensure_private_child parent leaf =
  let path = Filename.concat parent leaf in
  let created =
    try
      Unix.mkdir path 0o700;
      Ok ()
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
    | Unix.Unix_error (error, fn, arg) ->
      Error (Unsafe_directory { path; detail = unix_error_detail error fn arg })
  in
  match created with
  | Error _ as error -> error
  | Ok () -> Result.map (fun () -> path) (verify_private_directory path)
;;

let settings_json () =
  `Assoc
    [ ( "permissions"
      , `Assoc
          [ "allow", `List [ `String "mcp(masc/*)" ]
          ; ( "deny"
            , `List
                (List.map
                   (fun permission -> `String permission)
                   [ "read_file(*)"
                   ; "write_file(*)"
                   ; "read_url(*)"
                   ; "execute_url(*)"
                   ; "command(*)"
                   ; "unsandboxed(*)"
                   ]) )
          ] )
    ; "toolPermission", `String "request-review"
    ]
;;

let write_private_file ~make_error path contents =
  match Fs_compat.save_file_atomic_strict path contents with
  | Error detail -> Error (make_error path detail)
  | Ok () ->
    (try
       Unix.chmod path 0o600;
       let stat = Unix.lstat path in
       let mode = stat.Unix.st_perm land 0o7777 in
       if stat.Unix.st_kind <> Unix.S_REG
       then
         Error (make_error path ("expected regular file, found " ^ file_kind_name stat.Unix.st_kind))
       else if stat.Unix.st_uid <> effective_uid || mode <> 0o600
       then
         Error
           (make_error
              path
              (Printf.sprintf
                 "owner/mode mismatch: uid=%d mode=%04o"
                 stat.Unix.st_uid
                 mode))
       else Ok ()
     with
     | Unix.Unix_error (error, fn, arg) ->
       Error (make_error path (unix_error_detail error fn arg)))
;;

let write_private_settings path =
  write_private_file
    ~make_error:(fun path detail -> Settings_write_failed { path; detail })
    path
    (settings_json () |> Yojson.Safe.pretty_to_string)
;;

let load_private_oauth_file ~make_error path =
  match
    Fs_compat.load_owned_regular_file_with_snapshot
      ~ownership_root:(Filename.dirname path)
      path
  with
  | Ok (Some contents)
    when contents.snapshot.owner_uid <> effective_uid
         || contents.snapshot.permissions <> 0o600 ->
    Error
      (make_error
         path
         (Printf.sprintf
            "owner/mode mismatch: uid=%d mode=%04o"
            contents.snapshot.owner_uid
            contents.snapshot.permissions))
  | Ok contents -> Ok contents
  | Error error ->
    Error
      (make_error path (Fs_compat.owned_regular_file_read_error_to_string error))
;;

let read_oauth_seed path =
  if Filename.is_relative path
  then Error (Invalid_oauth_source { path; detail = "path must be absolute" })
  else
    match
      load_private_oauth_file
        ~make_error:(fun path detail -> Invalid_oauth_source { path; detail })
        path
    with
    | Ok (Some contents) -> Ok contents.content
    | Ok None -> Error (Invalid_oauth_source { path; detail = "file is missing" })
    | Error _ as error -> error
;;

let inspect_managed_oauth path =
  load_private_oauth_file
    ~make_error:(fun path detail -> Invalid_managed_oauth { path; detail })
    path
  |> Result.map (function
    | Some _ -> `Present
    | None -> `Missing)
;;

let ( let* ) = Result.bind

let prepare ~runtime_root ~owner_leaf ~oauth_source =
  if not (Fs_compat.is_capability_leaf owner_leaf)
  then Error (Invalid_owner_leaf owner_leaf)
  else
    let* () = verify_runtime_root runtime_root in
    let* oauth_seed = read_oauth_seed oauth_source in
    let* official_clients = ensure_private_child runtime_root "official-clients" in
    let* antigravity_root = ensure_private_child official_clients "antigravity" in
    let* home_dir = ensure_private_child antigravity_root owner_leaf in
    let* gemini_dir = ensure_private_child home_dir ".gemini" in
    let* cli_dir = ensure_private_child gemini_dir "antigravity-cli" in
    let* config_dir = ensure_private_child gemini_dir "config" in
    let settings_path = Filename.concat cli_dir "settings.json" in
    let mcp_config_path = Filename.concat config_dir "mcp_config.json" in
    let oauth_path = Filename.concat cli_dir "antigravity-oauth-token" in
    let* () =
      match inspect_managed_oauth oauth_path with
      | Error _ as error -> error
      | Ok `Present -> Ok ()
      | Ok `Missing ->
        write_private_file
          ~make_error:(fun path detail -> Invalid_managed_oauth { path; detail })
          oauth_path
          oauth_seed
    in
    let* () = write_private_settings settings_path in
    Ok { home_dir; settings_path; mcp_config_path; oauth_path }
;;

let home_dir t = t.home_dir

let publish_mcp_config t config =
  write_private_file
    ~make_error:(fun path detail -> Mcp_config_write_failed { path; detail })
    t.mcp_config_path
    (Yojson.Safe.pretty_to_string config)
;;

let clear_mcp_config t =
  let path = t.mcp_config_path in
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG || stat.Unix.st_uid <> effective_uid
    then
      Error
        (Mcp_config_cleanup_failed
           { path; detail = "refusing to remove a non-owned regular file" })
    else (
      Unix.unlink path;
      Ok ())
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error (error, fn, arg) ->
    Error
      (Mcp_config_cleanup_failed
         { path; detail = unix_error_detail error fn arg })
;;

module For_testing = struct
  type paths =
    { settings_path : string
    ; mcp_config_path : string
    ; oauth_path : string
    }

  let paths (t : t) =
    { settings_path = t.settings_path
    ; mcp_config_path = t.mcp_config_path
    ; oauth_path = t.oauth_path
    }
  ;;

  let settings_json = settings_json
end
