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
   none after, with the following refresh saving in 0.7s.

   Creating it is not free of the operator's own machine, though, and two
   properties the file's existence does not carry have to be asserted
   separately:

   - [security] writes the new keychain into the search list of whichever HOME
     it runs under, and masc ran it with the operator's real HOME. Measured on
     2026-08-27: 415 entries in ~/Library/Preferences/com.apple.security.plist,
     398 of them deleted test temp dirs, 403 of the 415 pointing at nothing.
     Every find-generic-password by every process on the machine walks that
     list. Each [security] child now runs with HOME set to the managed home so
     the write lands beside the keychain it describes.
   - A keychain [create-keychain] made reports `lock-on-sleep timeout=300s`, so
     it relocks five minutes after the last read, and lock state lives in the
     securityd session, so a reboot leaves it locked. A locked one under this
     name cannot be reopened: macOS routes an unlock of a keychain called
     `login.keychain-db` through the account login password, and no login
     window ever runs for the managed HOME. Every later read then raises a
     dialog nobody can satisfy — 81 of them in the 24h before 2026-08-27
     12:00, each within 15s of a [security] keychain search. Preparation
     clears the auto-lock at creation and rebuilds a keychain carried over
     from an earlier process. *)
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

(* Permissions are the security boundary. Plan mode merely adds an instruction.
   Directory arguments (without glob suffixes) are recursive CLI grants:
   https://antigravity.google/docs/permissions?tab=cli . *)
(* Do not emit a wildcard command grant: agy 1.2.11 uses it for both sandboxed and
   unsandboxed execution, and rejects the former [unsandboxed] action. With
   --sandbox, the vendor's implicit grant covers sandboxed commands; an escape
   remains Ask, which print mode cannot approve. Read posture denies both. *)
let native_settings_json ~posture ~workspaces =
  let read = List.map (fun path -> "read_file(" ^ path ^ ")") workspaces in
  let write = List.map (fun path -> "write_file(" ^ path ^ ")") workspaces in
  let allow, deny = match (posture : Runtime_native_tools.posture) with
    | Native_none -> [], ["read_file(*)"; "write_file(*)"; "command(*)"]
    | Native_read -> read, ["write_file(*)"; "command(*)"]
    | Native_full -> read @ write, [] in
  let strings values = `List (List.map (fun value -> `String value) values) in
  `Assoc ["permissions", `Assoc
    ["allow", strings ("mcp(masc/*)" :: allow);
     "deny", strings (deny @ ["read_url(*)"; "execute_url(*)"])]]
;;

let settings_json () =
  native_settings_json ~posture:Runtime_native_tools.Native_none ~workspaces:[]
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
let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

(* HOME decides which search list [security] writes to and which login
   keychain it resolves by convention. Every call is scoped to the managed
   home so neither answer is the operator's. *)
let security_environment ~home_dir =
  ("HOME=" ^ home_dir)
  :: (Unix.environment ()
      |> Array.to_list
      |> List.filter (fun entry -> env_key entry <> "HOME"))
  |> Array.of_list
;;

let run_security_direct ~env args =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let close () = try Unix.close devnull with Unix.Unix_error _ -> () in
  match
    Unix.create_process_env
      security_tool
      (Array.of_list (security_tool :: args))
      env
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

let run_security_eio mgr ~env args =
  match
    Eio.Switch.run (fun sw ->
      Eio.Process.spawn ~sw mgr ~env (security_tool :: args) |> Eio.Process.await)
  with
  | `Exited 0 -> Ok ()
  | `Exited code -> Error (Printf.sprintf "security exited with %d" code)
  | `Signaled signal -> Error (Printf.sprintf "security killed by signal %d" signal)
  | exception Eio.Cancel.Cancelled cause -> raise (Eio.Cancel.Cancelled cause)
  | exception exn -> Error (Printexc.to_string exn)
;;

let run_security ~home_dir args =
  let env = security_environment ~home_dir in
  match Process_eio.get_proc_mgr () with
  | Ok mgr -> run_security_eio mgr ~env args
  | Error _ -> run_security_direct ~env args
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

(* Whether a keychain is locked cannot be read without risking the dialog this
   whole path exists to prevent: [security] has no non-interactive mode, and
   [unlock-keychain] answers about the passphrase rather than the lock —
   measured 2026-08-27, it returns 51 on an unlocked keychain masc created and
   0 on one an operator had already unlocked through the dialog.

   So preparation does not ask. Lock state lives in the securityd session, the
   keychain is created with no auto-lock, and securityd outlives every turn
   but not a boot — which restarts masc too. Rebuilding the keychain the first
   time a process prepares a given home therefore covers every case masc can
   distinguish, at the cost of the token copy the old keychain held. The 0600
   seed beside it carries the same token, and the CLI writes a fresh copy on
   its next refresh. *)
let provisioned_this_process = Hashtbl.create 8
let provisioned_lock = Mutex.create ()

let claim_first_preparation home_dir =
  Mutex.protect provisioned_lock (fun () ->
    if Hashtbl.mem provisioned_this_process home_dir
    then false
    else (
      Hashtbl.replace provisioned_this_process home_dir ();
      true))
;;

let create_login_keychain ~home_dir path =
  let library = Filename.concat home_dir "Library" in
  let keychains = Filename.concat library "Keychains" in
  let ( let* ) = Result.bind in
  let* () = mkdir_if_absent library in
  let* () = verify_owned_directory library in
  let* () = mkdir_if_absent keychains in
  let* () = verify_owned_directory keychains in
  (* The passphrase is inert for this name — nothing can unlock the keychain
     later, whatever it is — and it guards nothing the filesystem does not
     already guard: the keychain holds a copy of the OAuth token that sits
     beside it at 0600 inside a 0700 home. *)
  let* () = run_security ~home_dir [ "create-keychain"; "-p"; ""; path ] in
  (* No [-l], no [-u] and no [-t]: the keychain reports `no-timeout` and stops
     relocking five minutes after the last read or when the machine sleeps.
     Without it the keychain locks itself into the unrecoverable state within
     the hour. *)
  let* () = run_security ~home_dir [ "set-keychain-settings"; path ] in
  (* [security] writes it 0644. Narrowing is reported rather than swallowed:
     the 0700 home above still keeps other users out, so a failure here is not
     fatal, but it does mean the file is readable to anything that reaches the
     directory. *)
  try
    Unix.chmod path 0o600;
    Ok ()
  with
  | Unix.Unix_error (error, fn, arg) ->
    Error ("created, but could not narrow to 0600: " ^ unix_error_detail error fn arg)
;;

let provision ~home_dir path =
  match create_login_keychain ~home_dir path with
  | Ok () -> Provisioned
  | Error detail -> Failed detail
;;

(* [delete-keychain] takes the file and any search-list entry macOS made for it
   when it was created, so the rebuild starts from nothing. *)
let replace_keychain ~home_dir path =
  match run_security ~home_dir [ "delete-keychain"; path ] with
  | Ok () -> provision ~home_dir path
  | Error detail -> Failed ("stale keychain could not be replaced: " ^ detail)
;;

let ensure_login_keychain home_dir =
  let path =
    List.fold_left Filename.concat home_dir [ "Library"; "Keychains"; "login.keychain-db" ]
  in
  if not (try Unix.access security_tool [ Unix.X_OK ]; true with Unix.Unix_error _ -> false)
  then Unsupported
  else (
    match inspect_keychain_path path with
    | `Unusable detail -> Failed detail
    | `Missing ->
      ignore (claim_first_preparation home_dir : bool);
      provision ~home_dir path
    | `Present ->
      (* Carried over from a securityd session this process cannot ask about. *)
      if claim_first_preparation home_dir
      then replace_keychain ~home_dir path
      else Present)
;;

let keeper_owner_leaf ~keeper_name ~oauth_source =
  let identity = Yojson.Safe.to_string
      (`List [`String keeper_name; `String oauth_source]) in
  "keeper-" ^ (Digestif.SHA256.digest_string identity |> Digestif.SHA256.to_hex)
;;

let prepare_owner_directory ~runtime_root ~owner_leaf =
  if not (Fs_compat.is_capability_leaf owner_leaf)
  then Error (Invalid_owner_leaf owner_leaf)
  else
    let* () = verify_runtime_root runtime_root in
    let* official_clients = ensure_private_child runtime_root "official-clients" in
    let* antigravity_root = ensure_private_child official_clients "antigravity" in
    ensure_private_child antigravity_root owner_leaf
;;

let prepare_home_storage ~home_dir ~oauth_seed =
  let* gemini_dir = ensure_private_child home_dir ".gemini" in
  let* cli_dir = ensure_private_child gemini_dir "antigravity-cli" in
  let* config_dir = ensure_private_child gemini_dir "config" in
  let settings_path = Filename.concat cli_dir "settings.json" in
  let mcp_config_path = Filename.concat config_dir "mcp_config.json" in
  let oauth_path = Filename.concat cli_dir "antigravity-oauth-token" in
  let* () = match inspect_managed_oauth oauth_path with
    | Error _ as error -> error
    | Ok `Present -> Ok ()
    | Ok `Missing ->
      (match oauth_seed with
       | None -> Ok ()
       | Some seed -> write_private_file
           ~make_error:(fun path detail -> Invalid_managed_oauth {path; detail}) oauth_path seed) in
  Ok (home_dir, settings_path, mcp_config_path, oauth_path)
;;

let home_with_keychain (home_dir, settings_path, mcp_config_path, oauth_path) =
  (* Keychain setup may use Eio.Process; keep it on the owning fiber. *)
  let keychain = ensure_login_keychain home_dir in
  {home_dir; settings_path; mcp_config_path; oauth_path; keychain}
;;

let generation_error path detail = Invalid_managed_oauth {path; detail}
let source_digest bytes = Digestif.SHA256.(to_hex (digest_string bytes))

let parse_generation_record ~path body =
  let invalid () = Error (generation_error path "invalid account generation record") in
  try match Yojson.Safe.from_string body with
  | `Assoc fields when List.length fields = 2 ->
    (match List.assoc_opt "source_sha256" fields, List.assoc_opt "revision" fields with
     | Some (`String source_sha256), Some (`String revision)
       when String.length source_sha256 = 64 &&
         String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) source_sha256 ->
       (match Random_id.parse_uuid_v7 revision with
        | Ok revision -> Ok (source_sha256, revision)
        | Error _ -> invalid ())
     | _ -> invalid ())
  | _ -> invalid ()
  with Yojson.Json_error _ -> invalid ()
;;

let sync_directory path =
  let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let existing_generation ~store ~revision =
  let home_dir = Filename.concat store revision in
  let gemini_dir = Filename.concat home_dir ".gemini" in
  let cli_dir = Filename.concat gemini_dir "antigravity-cli" in
  let config_dir = Filename.concat gemini_dir "config" in
  let* () = List.fold_left (fun checked path ->
      let* () = checked in verify_private_directory path)
      (Ok ()) [home_dir; gemini_dir; cli_dir; config_dir] in
  let oauth_path = Filename.concat cli_dir "antigravity-oauth-token" in
  let* () = match inspect_managed_oauth oauth_path with
    | Ok `Present -> Ok ()
    | Ok `Missing -> Error (generation_error oauth_path "account generation credential is missing")
    | Error _ as error -> error in
  Ok (home_dir, Filename.concat cli_dir "settings.json",
      Filename.concat config_dir "mcp_config.json", oauth_path)
;;

let select_generation ~runtime_root ~owner_leaf ~oauth_source =
  let* store = prepare_owner_directory ~runtime_root ~owner_leaf in
  let* source_bytes = read_oauth_seed oauth_source in
  let source_sha256 = source_digest source_bytes in
  let record_path = Filename.concat store "current.json" in
  let* previous = load_private_oauth_file ~make_error:generation_error record_path in
  let* previous = match previous with
    | None -> Ok None
    | Some file -> parse_generation_record ~path:record_path file.content |> Result.map Option.some in
  match previous with
  | Some (previous_sha256, revision) when String.equal source_sha256 previous_sha256 ->
    existing_generation ~store ~revision
  | None | Some _ ->
    let revision = Random_id.uuid_v7 () in
    let home_dir = Filename.concat store revision in
    Unix.mkdir home_dir 0o700;
    let* paths = prepare_home_storage ~home_dir ~oauth_seed:(Some source_bytes) in
    (* Persist the nested directory entries before publishing the pointer.
       The token itself was written by the strict private atomic writer. *)
    sync_directory (Filename.concat home_dir ".gemini");
    sync_directory home_dir;
    let record = Yojson.Safe.to_string (`Assoc ["source_sha256", `String source_sha256;
                                              "revision", `String revision]) in
    let* () = Fs_compat.save_file_atomic_strict record_path record
      |> Result.map_error (fun _ -> generation_error record_path "account generation publication failed") in
    Ok paths
;;

let with_prepared_account ~runtime_root ~owner_leaf ~oauth_source publish_policy =
  let* () = Eio_guard.run_in_systhread ~label:"antigravity-account-root" (fun () ->
    if not (Fs_compat.is_capability_leaf owner_leaf)
    then Error (Invalid_owner_leaf owner_leaf)
    else verify_runtime_root runtime_root) in
  let lock_path = Filename.concat runtime_root ("antigravity-" ^ owner_leaf ^ ".prepare.lock") in
  match File_lock_eio.with_durable_lock ~lock_path (fun () ->
    let* paths = Eio_guard.run_in_systhread ~label:"antigravity-account-generation" (fun () ->
      try select_generation ~runtime_root ~owner_leaf ~oauth_source with
      | Sys_error detail -> Error (generation_error runtime_root detail)
      | Unix.Unix_error (error, fn, arg) ->
        Error (generation_error runtime_root (unix_error_detail error fn arg))) in
    let home = home_with_keychain paths in
    publish_policy home) with
  | Ok result -> result
  | Error error -> Error (Invalid_runtime_root (File_lock_eio.durable_lock_error_to_string error))
;;

let prepare_account ~runtime_root ~owner_leaf ~oauth_source =
  with_prepared_account ~runtime_root ~owner_leaf ~oauth_source Result.ok
;;

let prepare ~runtime_root ~owner_leaf ~oauth_source =
  with_prepared_account ~runtime_root ~owner_leaf ~oauth_source (fun home ->
    let* () = write_private_settings home.settings_path in
    Ok home)
;;

let prepare_for_login ~runtime_root ~owner_leaf =
  let* paths = Eio_guard.run_in_systhread ~label:"antigravity-login-storage" (fun () ->
    let* home_dir = prepare_owner_directory ~runtime_root ~owner_leaf in
    prepare_home_storage ~home_dir ~oauth_seed:None) in
  let home = home_with_keychain paths in
  let* () = write_private_settings home.settings_path in
  Ok home
;;

let oauth_path t = t.oauth_path
let home_dir t = t.home_dir
type native_workspace = Shared_workspace of string | Private_workspace

let canonical_workspace path =
  try
    if Filename.is_relative path || (Unix.lstat path).Unix.st_kind <> Unix.S_DIR
    then Error (Unsafe_directory {path; detail="native workspace must be an absolute real directory"})
    else
      let canonical = Unix.realpath path in
      if not (String.equal path canonical || String.equal path (canonical ^ "/"))
      then Error (Unsafe_directory {path; detail="native workspace must not traverse symbolic links"})
      else if String.exists (function '*' | '?' | '[' | ']' | '(' | ')' -> true | _ -> false) canonical
      then Error (Unsafe_directory {path; detail="native workspace contains permission-pattern syntax"})
      else Ok canonical
  with Unix.Unix_error (error, fn, arg) ->
    Error (Unsafe_directory {path; detail=unix_error_detail error fn arg})
;;

let prepare_native_workspace t ~workspace =
  match workspace with
  | Private_workspace -> ensure_private_child t.home_dir "native-workspace"
  | Shared_workspace path -> canonical_workspace path
;;

let prepare_native_tools t ~posture ~workspace ~additional_workspaces =
  let* cwd = prepare_native_workspace t ~workspace in
  let rec validate = function
    | [] -> Ok []
    | path :: rest ->
      let* path = canonical_workspace path in
      let* rest = validate rest in
      Ok (path :: rest) in
  let* additional_workspaces = validate additional_workspaces in
  let* () = write_private_file
    ~make_error:(fun path detail -> Settings_write_failed {path; detail})
    t.settings_path
    (native_settings_json ~posture ~workspaces:(cwd :: additional_workspaces)
     |> Yojson.Safe.pretty_to_string) in
  Ok cwd
;;

(* Native callers publish their intended policy once. Resetting a shared
   account to the default policy first would revoke an overlapping reader's
   permissions between two atomic writes. The credential seed still only
   initializes missing managed state, retaining vendor refreshes. *)
let prepare_native ~runtime_root ~owner_leaf ~oauth_source ~posture ~workspace
    ~additional_workspaces =
  with_prepared_account ~runtime_root ~owner_leaf ~oauth_source (fun home ->
    let* cwd = Eio_guard.run_in_systhread ~label:"antigravity-native-policy" (fun () ->
      prepare_native_tools home ~posture ~workspace ~additional_workspaces) in
    Ok (home, cwd))
;;

let write_context_observation_settings t ~command =
  let settings = `Assoc [
    "statusLine", `Assoc ["type", `String "command"; "command", `String command; "enabled", `Bool true];
    "altScreenMode", `String "never";
    "permissions", `Assoc ["allow", `List []; "deny", `List (List.map (fun name -> `String name)
      ["read_file(*)"; "write_file(*)"; "read_url(*)"; "execute_url(*)"; "command(*)"])]] in
  write_private_file ~make_error:(fun path detail -> Settings_write_failed {path;detail})
    t.settings_path (Yojson.Safe.to_string settings)

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
  let native_settings_json = native_settings_json
  let security_environment = security_environment
  let replace_keychain = replace_keychain
end
