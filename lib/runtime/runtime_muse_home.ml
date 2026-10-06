type t = { config_home : string; account_revision : string; account_home : string; physical_home : string }

type sign_in_gap =
  | No_file_sign_in
  | Keychain_sign_in
  | Unsupported_credential_storage of string

type error =
  | Invalid_account_home of string
  | Sign_in_required of sign_in_gap
  | State_unavailable of string

(* Both of masc's Muse sign-ins run the client with the file credential
   backend; a plain [muse login] on macOS writes to the Keychain again. *)
let sign_in_again =
  "sign in again from masc (/login muse in the TUI, or the installer's Muse sign-in)"

let error_to_string = function
  | Invalid_account_home detail -> "Muse account home: " ^ detail
  | Sign_in_required No_file_sign_in ->
    "Muse account has no file-backed sign-in; sign in to the selected account home"
  | Sign_in_required Keychain_sign_in ->
    "Muse account keeps its sign-in in the macOS Keychain, which masc cannot hand to \
     a selected account; " ^ sign_in_again
  | Sign_in_required (Unsupported_credential_storage storage) ->
    Printf.sprintf
      "Muse account records its sign-in in storage %S, which masc cannot read; %s"
      storage sign_in_again
  | State_unavailable detail -> "Muse managed configuration: " ^ detail

let account_home t = t.account_home
let physical_home t = t.physical_home
let config_home t = t.config_home
let private_tmpdir t = Filename.concat t.config_home "tmp"
let account_revision t = t.account_revision
let ( let* ) = Result.bind
let unavailable detail = Error (State_unavailable detail)
let digest text = Digestif.SHA256.(to_hex (digest_string text))

let check_directory_stat ~private_ (stat : Unix.stats) =
  if stat.Unix.st_kind <> Unix.S_DIR || stat.Unix.st_uid <> Unix.geteuid ()
     || (private_ && stat.Unix.st_perm land 0o077 <> 0)
  then unavailable "managed path is not an owned private directory"
  else if stat.Unix.st_perm land 0o022 <> 0
  then unavailable "managed path is writable by group or other users"
  else Ok ()

let check_directory ~private_ path = check_directory_stat ~private_ (Unix.lstat path)

let sync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)

let ensure_directory_with_sync ~sync ~private_ path =
  (try Unix.mkdir path 0o700
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let* () = check_directory ~private_ path in
  (* EEXIST proves visibility, not durability: a prior attempt may have been
     interrupted after mkdir or failed its parent fsync. Reconfirm publication
     before using either a newly created or an existing directory. *)
  sync (Filename.dirname path);
  Ok ()

let ensure_directory = ensure_directory_with_sync ~sync:sync_directory

let directories root parts =
  List.fold_left
    (fun parent (name, private_) ->
       let* parent = parent in
       let path = Filename.concat parent name in
       let* () = ensure_directory ~private_ path in
       Ok path)
    (Ok root) parts

let check_file_snapshot (snapshot : Fs_compat.owned_regular_file_snapshot) =
  if snapshot.owner_uid <> Unix.geteuid () || snapshot.permissions land 0o077 <> 0
  then unavailable "credential or generation record is not owned and private"
  else Ok ()

let read_optional ~ownership_root path =
  match Fs_compat.load_owned_regular_file_with_snapshot
      ~owner_uid:(Unix.geteuid ()) ~ownership_root path with
  | Error _ -> unavailable "credential or generation record failed owned-file validation"
  | Ok None -> Ok None
  | Ok (Some file) ->
    let* () = check_file_snapshot file.snapshot in
    Ok (Some file.content)

let write_private path body =
  let channel = open_out_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel body; flush channel; Unix.fsync (Unix.descr_of_out_channel channel))

(* Muse Code runs observer agents beside the main session, and "each enabled
   observer makes its own model calls" on the same subscription
   (dev.meta.ai/docs/muse-code/extending). A Keeper keeps its own goals,
   verification and memory, so every observer the host bundles is turned off
   through [runtime_capabilities]. The ids are the host's capability names for
   its bundled reminder plugin (muse 1.4.3). *)
type observer =
  | Memory
  | Skill_reminder
  | Verify_reminder
  | Goal_reminder
  | Todo_reminder
  | Scope_reminder
[@@deriving enumerate]

let observer_capability_id = function
  | Memory -> "plugin:tbh-reminders:reminder:memory"
  | Skill_reminder -> "plugin:tbh-reminders:reminder:skill-reminder"
  | Verify_reminder -> "plugin:tbh-reminders:reminder:verify-reminder"
  | Goal_reminder -> "plugin:tbh-reminders:reminder:goal-reminder"
  | Todo_reminder -> "plugin:tbh-reminders:reminder:todo-reminder"
  | Scope_reminder -> "plugin:tbh-reminders:reminder:scope-reminder"

let settings =
  Yojson.Safe.to_string
    (`Assoc [ "schema_version", `Int 1
            ; "permissions", `Assoc [ "schema_version", `Int 1
                                    ; "default_profile", `String ":ask-me" ]
            ; "runtime_capabilities",
              `Assoc (List.map (fun observer ->
                  observer_capability_id observer, `Assoc [ "enabled", `Bool false ])
                  all_of_observer) ])

let parse_record body =
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      (match List.assoc_opt "source_sha256" fields, List.assoc_opt "revision" fields with
       | Some (`String source_sha256), Some (`String revision)
         when List.length fields = 2 && String.length source_sha256 = 64
              && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) source_sha256 ->
         (match Random_id.parse_uuid_v7 revision with
          | Ok revision -> Ok (source_sha256, revision)
          | Error _ -> unavailable "invalid credential generation identity")
       | _ -> unavailable "invalid credential generation record")
    | _ -> unavailable "invalid credential generation record"
  with Yojson.Json_error _ -> unavailable "unreadable credential generation record"

type credential_storage = In_file | In_keychain

(* The vendor marks a sign-in whose secrets it moved into the macOS Keychain
   with [storage: "keychain"] and leaves only metadata in auth.json. The
   vendor binary names no other marker value, so a slot without one is read as
   inline; the file backend's own name [file] is read the same way. Only the
   inline form survives the copy into a managed
   generation, which is why every Muse child runs with the file backend
   (Runtime_muse_serve). *)
let credential_storage meta =
  match List.assoc_opt "storage" meta with
  | None | Some (`String "file") -> Ok In_file
  | Some (`String "keychain") -> Ok In_keychain
  | Some (`String other) -> Error (Sign_in_required (Unsupported_credential_storage other))
  | Some _ -> unavailable "selected account has a malformed Meta credential storage field"

let validate_auth body =
  try match Yojson.Safe.from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "schema_version" fields, List.assoc_opt "providers" fields with
     | Some (`Int 1), Some (`Assoc providers) ->
       (match List.assoc_opt "meta" providers with
        | Some (`Assoc ((_ :: _) as meta)) ->
          let* storage = credential_storage meta in
          (match storage with
           | In_file -> Ok ()
           | In_keychain -> Error (Sign_in_required Keychain_sign_in))
        | None | Some (`Assoc []) -> Error (Sign_in_required No_file_sign_in)
        | Some _ -> unavailable "selected account has malformed Meta credentials")
     | _ -> unavailable "selected account has an unsupported auth document")
  | _ -> unavailable "selected account has an invalid auth document"
  with Yojson.Json_error _ -> unavailable "selected account has an unreadable auth document"

let prepare_locked ~sync_store ~selected_account_home ~account_home ~store ~source =
  let* source_bytes = read_optional ~ownership_root:account_home source in
  match source_bytes with
  | None -> Error (Sign_in_required No_file_sign_in)
  | Some source_bytes ->
    let* () = validate_auth source_bytes in
    let source_sha256 = digest source_bytes in
    let record_path = Filename.concat store "current.json" in
    let* previous = read_optional ~ownership_root:store record_path in
    let* previous = match previous with
      | None -> Ok None
      | Some body -> Result.map Option.some (parse_record body) in
    let publish auth_bytes =
      let revision = Random_id.uuid_v7 () in
      let* directory = directories store [ revision, true; "muse", true ] in
      write_private (Filename.concat directory "settings.json") settings;
      write_private (Filename.concat directory "auth.json") auth_bytes;
      sync_directory directory;
      let generation = Filename.dirname directory in
      let* _ = directories generation [ "tmp", true ] in
      sync_directory generation;
      let record = Yojson.Safe.to_string (`Assoc [ "source_sha256", `String source_sha256
                                               ; "revision", `String revision ]) in
      (* The strict atomic writer creates its tempfile with mode 0600 and
         fsyncs both it and the parent directory; no post-publication chmod. *)
      let* () = Fs_compat.save_file_atomic_strict record_path record |> Result.map_error (fun _ -> State_unavailable "credential generation publication failed") in
      Ok { config_home = generation; account_revision = revision; account_home = selected_account_home; physical_home = account_home }
    in
    (match previous with
     | Some (previous_sha256, revision) when String.equal source_sha256 previous_sha256 ->
       let generation = Filename.concat store revision in
       let* () = check_directory ~private_:true (Filename.concat generation "tmp") in
       let* auth = read_optional ~ownership_root:store (Filename.concat generation "muse/auth.json") in
       let* current_settings = read_optional ~ownership_root:store (Filename.concat generation "muse/settings.json") in
       (match auth with
        | None -> Error (Sign_in_required No_file_sign_in)
        | Some body ->
          let* () = validate_auth body in
          (match current_settings with
           | Some current when String.equal current settings ->
             (* A previous current.json rename may have become visible even when
                its parent fsync failed. Reconfirm that pointer before admission. *)
             sync_store store;
             Ok { config_home = generation; account_revision = revision; account_home = selected_account_home; physical_home = account_home }
           | None | Some _ ->
             (* The generation runs settings other than the current managed
                ones: an earlier masc wrote another policy, or the file was
                edited. It is never admitted again. A new generation with the
                current settings carries its credentials, vendor refreshes
                included, and its new revision starts Keeper sessions afresh,
                since the host commits a session's permission profile when the
                session starts. *)
             publish body))
     | None | Some _ -> publish source_bytes)

(* The vendor launcher (v3) keeps its sign-in at [muse/auth.json] under
   XDG_CONFIG_HOME, and under [HOME/.config] when that is unset. *)
let auth_path_in ~config_home = Filename.concat config_home "muse/auth.json"

(* Where the vendor CLI writes its sign-in for a HOME: XDG_CONFIG_HOME is
   [HOME/.config] for login. *)
let source_auth_path ~account_home =
  auth_path_in ~config_home:(Filename.concat account_home ".config")

(* The child inherits XDG_CONFIG_HOME and HOME, and never MUSE_AUTH_PATH. *)
let auth_path = function
  | Some account_home -> Some (source_auth_path ~account_home)
  | None ->
    (match
       Env_config_core.raw_value_opt "XDG_CONFIG_HOME", Env_config_core.raw_value_opt "HOME"
     with
     | Some config_home, _ when config_home <> "" -> Some (auth_path_in ~config_home)
     | (Some _ | None), Some home when home <> "" -> Some (source_auth_path ~account_home:home)
     | (Some _ | None), (Some _ | None) -> None)

let protect operation =
  try operation () with
  | Sys_error _ | Unix.Unix_error _ -> unavailable "private account state could not be accessed"

let prepare_with_store_sync ~sync_store ~account_home =
  let* account_home = Runtime_account_home.of_string account_home
    |> Result.map_error (fun detail -> Invalid_account_home detail) in
  let selected_account_home = account_home in
  protect (fun () ->
    (* Configured spelling remains the caller's account/session identity. Resolve
       only the filesystem ownership boundary: an account HOME may itself be a
       symlink, while credential and managed-state descendants may not be. *)
    let* account_home, store = Eio_guard.run_in_systhread ~label:"muse-managed-account-directories" (fun () ->
      let account_home = Unix.realpath account_home in
      let* () = check_directory ~private_:false account_home in
      let* store = directories account_home [ ".local", false; "state", false; "masc", true; "muse-config", true ] in
      Ok (account_home, store)) in
    let source = source_auth_path ~account_home in
    match File_lock_eio.with_durable_lock ~lock_path:(Filename.concat store "prepare.lock")
        (fun () -> Eio_guard.run_in_systhread ~label:"muse-managed-account-generation"
            (fun () -> prepare_locked ~sync_store ~selected_account_home ~account_home ~store ~source)) with
    | Ok result -> result
    | Error _ -> unavailable "credential generation lock failed")

let prepare ~account_home =
  prepare_with_store_sync ~sync_store:sync_directory ~account_home

let prepare_native_workspace ~runtime_root ~keeper_name ~account_home =
  let* account_home = Runtime_account_home.of_string account_home
    |> Result.map_error (fun detail -> Invalid_account_home detail) in
  if Filename.is_relative runtime_root then unavailable "runtime root must be absolute"
  else protect (fun () ->
    let identity = digest (Yojson.Safe.to_string (`List [ `String keeper_name; `String account_home ])) in
    Eio_guard.run_in_systhread ~label:"muse-native-workspace" (fun () ->
      directories runtime_root [ "official-clients", true; "muse", true; identity, true; "workspace", true ]))

module For_testing = struct
  let prepare_with_store_sync = prepare_with_store_sync
  let check_directory_stat = check_directory_stat
  let check_file_snapshot = check_file_snapshot
  let ensure_directory_with_sync = ensure_directory_with_sync
end
