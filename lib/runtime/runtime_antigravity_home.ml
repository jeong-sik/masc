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
  | Invalid_oauth_link of
      { path : string
      ; detail : string
      }
  | Settings_write_failed of
      { path : string
      ; detail : string
      }

type t =
  { home_dir : string
  ; workspace_dir : string
  ; settings_path : string
  ; mcp_config_path : string
  ; oauth_link_path : string
  }

let error_to_string = function
  | Invalid_runtime_root detail -> "invalid Antigravity runtime root: " ^ detail
  | Invalid_owner_leaf owner_leaf ->
    Printf.sprintf "invalid Antigravity owner leaf %S" owner_leaf
  | Unsafe_directory { path; detail } ->
    Printf.sprintf "unsafe Antigravity directory %s: %s" path detail
  | Invalid_oauth_source { path; detail } ->
    Printf.sprintf "invalid Antigravity OAuth source %s: %s" path detail
  | Invalid_oauth_link { path; detail } ->
    Printf.sprintf "invalid Antigravity OAuth link %s: %s" path detail
  | Settings_write_failed { path; detail } ->
    Printf.sprintf "failed to write Antigravity settings %s: %s" path detail
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
      if stat.Unix.st_kind <> Unix.S_DIR
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
    if stat.Unix.st_kind <> Unix.S_DIR
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

let write_private_settings path =
  let contents = settings_json () |> Yojson.Safe.pretty_to_string in
  match Fs_compat.save_file_atomic_strict path contents with
  | Error detail -> Error (Settings_write_failed { path; detail })
  | Ok () ->
    (try
       Unix.chmod path 0o600;
       let stat = Unix.lstat path in
       let mode = stat.Unix.st_perm land 0o7777 in
       if stat.Unix.st_kind <> Unix.S_REG
       then
         Error
           (Settings_write_failed
              { path
              ; detail = "expected regular file, found " ^ file_kind_name stat.Unix.st_kind
              })
       else if stat.Unix.st_uid <> effective_uid || mode <> 0o600
       then
         Error
           (Settings_write_failed
              { path
              ; detail =
                  Printf.sprintf
                    "owner/mode mismatch: uid=%d mode=%04o"
                    stat.Unix.st_uid
                    mode
              })
       else Ok ()
     with
     | Unix.Unix_error (error, fn, arg) ->
       Error
         (Settings_write_failed
            { path; detail = unix_error_detail error fn arg }))
;;

let validate_oauth_source path =
  if Filename.is_relative path
  then Error (Invalid_oauth_source { path; detail = "path must be absolute" })
  else
    try
      let lexical_stat = Unix.lstat path in
      if lexical_stat.Unix.st_kind <> Unix.S_REG
      then
        Error
          (Invalid_oauth_source
             { path
             ; detail =
                 "expected regular file, found "
                 ^ file_kind_name lexical_stat.Unix.st_kind
             })
      else
        let canonical_path = Unix.realpath path in
        let stat = Unix.lstat canonical_path in
        if
          stat.Unix.st_kind <> Unix.S_REG
          || stat.Unix.st_dev <> lexical_stat.Unix.st_dev
          || stat.Unix.st_ino <> lexical_stat.Unix.st_ino
        then
          Error
            (Invalid_oauth_source
               { path; detail = "file identity changed while resolving the source" })
        else if stat.Unix.st_uid <> effective_uid
      then
        Error
          (Invalid_oauth_source
             { path
             ; detail =
                 Printf.sprintf
                   "owned by uid %d, expected %d"
                   stat.Unix.st_uid
                   effective_uid
             })
      else
        let mode = stat.Unix.st_perm land 0o7777 in
        if mode <> 0o600
        then
          Error
            (Invalid_oauth_source
               { path
               ; detail = Printf.sprintf "mode is %04o, expected 0600" mode
               })
        else Ok canonical_path
    with
    | Unix.Unix_error (error, fn, arg) ->
      Error
        (Invalid_oauth_source
           { path; detail = unix_error_detail error fn arg })
;;

let ensure_oauth_link ~source path =
  let verify () =
    try
      let stat = Unix.lstat path in
      if stat.Unix.st_kind <> Unix.S_LNK
      then
        Error
          (Invalid_oauth_link
             { path
             ; detail = "expected symbolic link, found " ^ file_kind_name stat.Unix.st_kind
             })
      else
        let target = Unix.readlink path in
        if String.equal target source
        then Ok ()
        else
          Error
            (Invalid_oauth_link
               { path
               ; detail = Printf.sprintf "target is %S, expected %S" target source
               })
    with
    | Unix.Unix_error (error, fn, arg) ->
      Error
        (Invalid_oauth_link
           { path; detail = unix_error_detail error fn arg })
  in
  try
    match Unix.lstat path with
    | _ -> verify ()
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      (try
         Unix.symlink source path;
         verify ()
       with
       | Unix.Unix_error (error, fn, arg) ->
         Error
           (Invalid_oauth_link
              { path; detail = unix_error_detail error fn arg }))
  with
  | Unix.Unix_error (error, fn, arg) ->
    Error
      (Invalid_oauth_link
         { path; detail = unix_error_detail error fn arg })
;;

let ( let* ) = Result.bind

let prepare ~runtime_root ~owner_leaf ~oauth_source =
  if not (Fs_compat.is_capability_leaf owner_leaf)
  then Error (Invalid_owner_leaf owner_leaf)
  else
    let* () = verify_runtime_root runtime_root in
    let* oauth_source = validate_oauth_source oauth_source in
    let* official_clients = ensure_private_child runtime_root "official-clients" in
    let* antigravity_root = ensure_private_child official_clients "antigravity" in
    let* home_dir = ensure_private_child antigravity_root owner_leaf in
    let* workspace_dir = ensure_private_child home_dir "workspace" in
    let* gemini_dir = ensure_private_child home_dir ".gemini" in
    let* cli_dir = ensure_private_child gemini_dir "antigravity-cli" in
    let* config_dir = ensure_private_child gemini_dir "config" in
    let settings_path = Filename.concat cli_dir "settings.json" in
    let mcp_config_path = Filename.concat config_dir "mcp_config.json" in
    let oauth_link_path = Filename.concat cli_dir "antigravity-oauth-token" in
    let* () = write_private_settings settings_path in
    let* () = ensure_oauth_link ~source:oauth_source oauth_link_path in
    Ok { home_dir; workspace_dir; settings_path; mcp_config_path; oauth_link_path }
;;

let child_environment t = [ "HOME", t.home_dir ]
