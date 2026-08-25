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

(* macOS finds a HOME's login keychain by path convention —
   [$HOME/Library/Keychains/login.keychain-db] — and nothing else. The HOME
   masc hands the CLI has no such file, so `security` reports no default
   keychain at all and the CLI's token save asks macOS to create one. That
   authorization (system.keychain.create.loginkc) opens an operator dialog on
   a turn nobody is watching. The CLI waits 5s, gives up, and writes the token
   to a file instead, so the turn survives — the cost is the stall and the
   dialog, once per token refresh (~hourly, per keeper). masc#28922.

   Creating the file is the whole fix; no default-keychain setting is needed.
   Measured on 2026-08-25: 13 `Keyring SaveToken timed out` in one day before,
   none after, with the following refresh saving in 0.7s. *)
type keychain_state =
  | Present
  | Provisioned
  | Unsupported
  | Failed of string

type t =
  { home_dir : string
  ; settings_path : string
  ; mcp_config_path : string
  ; oauth_path : string
  ; keychain : keychain_state
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

(* Only the whole-tool pattern [tool(*)] matches in agy 1.1.12: a path-scoped
   argument such as [read_file(<dir>/*)] matched neither a direct child nor a
   nested file in either list (measured 2026-08-14), so "deny everything
   except the client's own artifact files" is not expressible. [read_file]
   therefore stays denied wholesale even though that also denies the client's
   own large-MCP-output artifacts (results over ~10KB are materialized to a
   brain file the model is told to view): the workspace masc passes as
   [--add-dir] is the operator checkout, whose [.masc/auth] tokens a
   workspace-wide read grant would expose. A rule denial comes back to the
   model as a typed tool error and the turn continues; an unlisted tool would
   instead take the review path, which auto-denies in print mode and ends the
   turn with an empty SUCCESS response.

   No [toolPermission] key: agy 1.1.12 does not read it (the client rewrites
   this file without it and initializes toolPermission=request-review from
   its own default). *)
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

let security_tool = "/usr/bin/security"

let mkdir_if_absent path =
  try
    Unix.mkdir path 0o700;
    Ok ()
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
  | Unix.Unix_error (error, fn, arg) -> Error (unix_error_detail error fn arg)
;;

(* [verify_private_directory]'s exact-0700 contract does not apply to these
   two: the CLI creates [Library] itself at 0755 for its own caches, so
   demanding a mode here would fail every turn on a home that already exists.
   Ownership plus the 0700 home above them is what keeps the keychain
   private. *)
let verify_owned_directory path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_DIR
    then Error ("expected directory, found " ^ file_kind_name stat.Unix.st_kind)
    else if stat.Unix.st_uid <> effective_uid
    then
      Error
        (Printf.sprintf
           "owned by uid %d, expected %d"
           stat.Unix.st_uid
           effective_uid)
    else Ok ()
  with
  | Unix.Unix_error (error, fn, arg) -> Error (unix_error_detail error fn arg)
;;

(* The keychain has to be created by [security]; the format is not something
   to write by hand. Spawning goes through the Eio process manager whenever a
   runtime is up: a raw [Unix.waitpid] inside a fiber is interrupted by Eio's
   own signal handling, which took down every lifecycle case in
   test_keeper_antigravity_runtime with EINTR. The direct path stays for
   callers with no Eio runtime, which is how preparation is exercised in
   test_runtime_antigravity_home, and retries EINTR for the same reason. *)
let run_security_direct args =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let close () = try Unix.close devnull with Unix.Unix_error _ -> () in
  match
    Unix.create_process
      security_tool
      (Array.of_list (security_tool :: args))
      devnull
      devnull
      devnull
  with
  | exception Unix.Unix_error (error, fn, arg) ->
    close ();
    Error (unix_error_detail error fn arg)
  | pid ->
    let rec wait () =
      match Unix.waitpid [] pid with
      | _, status -> Ok status
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
      | exception Unix.Unix_error (error, fn, arg) ->
        Error (unix_error_detail error fn arg)
    in
    let result = wait () in
    close ();
    Result.bind result (function
      | Unix.WEXITED 0 -> Ok ()
      | Unix.WEXITED code -> Error (Printf.sprintf "security exited with %d" code)
      | Unix.WSIGNALED signal ->
        Error (Printf.sprintf "security killed by signal %d" signal)
      | Unix.WSTOPPED signal ->
        Error (Printf.sprintf "security stopped by signal %d" signal))
;;

let run_security_eio mgr args =
  match
    Eio.Switch.run (fun sw ->
      Eio.Process.spawn ~sw mgr (security_tool :: args) |> Eio.Process.await)
  with
  | `Exited 0 -> Ok ()
  | `Exited code -> Error (Printf.sprintf "security exited with %d" code)
  | `Signaled signal -> Error (Printf.sprintf "security killed by signal %d" signal)
  | exception Eio.Cancel.Cancelled cause -> raise (Eio.Cancel.Cancelled cause)
  | exception exn -> Error (Printexc.to_string exn)
;;

let run_security args =
  match Process_eio.get_proc_mgr () with
  | Ok mgr -> run_security_eio mgr args
  | Error _ -> run_security_direct args
;;

let inspect_keychain_path path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG
    then `Unusable ("expected regular file, found " ^ file_kind_name stat.Unix.st_kind)
    else if stat.Unix.st_uid <> effective_uid
    then
      `Unusable
        (Printf.sprintf "owned by uid %d, expected %d" stat.Unix.st_uid effective_uid)
    else `Present
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> `Missing
  | Unix.Unix_error (error, fn, arg) -> `Unusable (unix_error_detail error fn arg)
;;

(* Never fails preparation. A home without a keychain still runs turns — the
   CLI falls back to file storage — so a failure here costs the stall and the
   dialog, not the turn. The state is carried out so the caller can say so
   instead of the attempt disappearing. *)
let ensure_login_keychain home_dir =
  let path =
    List.fold_left Filename.concat home_dir [ "Library"; "Keychains"; "login.keychain-db" ]
  in
  match inspect_keychain_path path with
  | `Present -> Present
  | `Unusable detail -> Failed detail
  | `Missing ->
    if not (try Unix.access security_tool [ Unix.X_OK ]; true with Unix.Unix_error _ -> false)
    then Unsupported
    else (
      let library = Filename.concat home_dir "Library" in
      let keychains = Filename.concat library "Keychains" in
      let ( let* ) = Result.bind in
      let provisioned =
        let* () = mkdir_if_absent library in
        let* () = verify_owned_directory library in
        let* () = mkdir_if_absent keychains in
        let* () = verify_owned_directory keychains in
        (* The empty passphrase leaves the keychain unlocked for every later
           turn, which is the point: no operator is present to type one. It
           guards nothing that the filesystem does not already guard — the
           file holds the same OAuth token that sits beside it at 0600 inside
           a 0700 home, and any passphrase usable unattended would have to be
           stored next to it. *)
        let* () = run_security [ "create-keychain"; "-p"; ""; path ] in
        (* [security] writes it 0644. Narrowing is reported rather than
           swallowed: the 0700 home above still keeps other users out, so a
           failure here is not fatal, but it does mean the file is readable to
           anything that reaches the directory. *)
        try
          Unix.chmod path 0o600;
          Ok ()
        with
        | Unix.Unix_error (error, fn, arg) ->
          Error ("created, but could not narrow to 0600: " ^ unix_error_detail error fn arg)
      in
      match provisioned with
      | Ok () -> Provisioned
      | Error detail -> Failed detail)
;;

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
    let keychain = ensure_login_keychain home_dir in
    Ok { home_dir; settings_path; mcp_config_path; oauth_path; keychain }
;;

let home_dir t = t.home_dir
let keychain_state t = t.keychain

let keychain_state_to_string = function
  | Present -> "present"
  | Provisioned -> "provisioned"
  | Unsupported -> "unsupported"
  | Failed detail -> "failed: " ^ detail
;;

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
