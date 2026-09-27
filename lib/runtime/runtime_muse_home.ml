type t = { config_home : string; account_revision : string }

type error =
  | Invalid_account_home of string
  | Sign_in_required
  | State_unavailable of string

let error_to_string = function
  | Invalid_account_home detail -> "Muse account home: " ^ detail
  | Sign_in_required -> "Muse account has no file-backed sign-in; sign in to the selected account home"
  | State_unavailable detail -> "Muse managed configuration: " ^ detail

let config_home t = t.config_home
let private_tmpdir t = Filename.concat t.config_home "tmp"
let account_revision t = t.account_revision
let ( let* ) = Result.bind
let unavailable detail = Error (State_unavailable detail)
let digest text = Digestif.SHA256.(to_hex (digest_string text))

let check_directory ~private_ path =
  let stat = Unix.lstat path in
  if stat.Unix.st_kind <> Unix.S_DIR || stat.Unix.st_uid <> Unix.geteuid ()
     || (private_ && stat.Unix.st_perm land 0o077 <> 0)
  then unavailable "managed path is not an owned private directory"
  else Ok ()

let ensure_directory ~private_ path =
  (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  check_directory ~private_ path

let directories root parts =
  List.fold_left
    (fun parent (name, private_) ->
       let* parent = parent in
       let path = Filename.concat parent name in
       let* () = ensure_directory ~private_ path in
       Ok path)
    (Ok root) parts

let read_optional ~ownership_root path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root path with
  | Error _ -> unavailable "credential or generation record failed owned-file validation"
  | Ok None -> Ok None
  | Ok (Some file) ->
    if file.snapshot.permissions land 0o077 <> 0
    then unavailable "credential or generation record is not private"
    else Ok (Some file.content)

let write_private path body =
  let channel = open_out_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel body; flush channel; Unix.fsync (Unix.descr_of_out_channel channel))

let sync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)

let settings =
  Yojson.Safe.to_string
    (`Assoc [ "schema_version", `Int 1
            ; "permissions", `Assoc [ "schema_version", `Int 1
                                    ; "default_profile", `String ":ask-me" ] ])

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

let validate_auth body =
  try match Yojson.Safe.from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "schema_version" fields, List.assoc_opt "providers" fields with
     | Some (`Int 1), Some (`Assoc providers) ->
       (match List.assoc_opt "meta" providers with
        | Some (`Assoc (_ :: _)) -> Ok ()
        | None | Some (`Assoc []) -> Error Sign_in_required
        | Some _ -> unavailable "selected account has malformed Meta credentials")
     | _ -> unavailable "selected account has an unsupported auth document")
  | _ -> unavailable "selected account has an invalid auth document"
  with Yojson.Json_error _ -> unavailable "selected account has an unreadable auth document"

let prepare_locked ~account_home ~store ~source =
  let* source_bytes = read_optional ~ownership_root:account_home source in
  match source_bytes with
  | None -> Error Sign_in_required
  | Some source_bytes ->
    let* () = validate_auth source_bytes in
    let source_sha256 = digest source_bytes in
    let record_path = Filename.concat store "current.json" in
    let* previous = read_optional ~ownership_root:store record_path in
    let* previous = match previous with
      | None -> Ok None
      | Some body -> Result.map Option.some (parse_record body) in
    (match previous with
     | Some (previous_sha256, revision) when String.equal source_sha256 previous_sha256 ->
       let generation = Filename.concat store revision in
       let* () = check_directory ~private_:true (Filename.concat generation "tmp") in
       let* auth = read_optional ~ownership_root:store (Filename.concat generation "muse/auth.json") in
       let* current_settings = read_optional ~ownership_root:store (Filename.concat generation "muse/settings.json") in
       let* () = match current_settings with
         | Some body when String.equal body settings -> Ok ()
         | None | Some _ -> unavailable "managed permission settings changed or are missing" in
       (match auth with
        | None -> Error Sign_in_required
        | Some body ->
          let* () = validate_auth body in
          Ok { config_home = generation; account_revision = revision })
     | None | Some _ ->
       let revision = Random_id.uuid_v7 () in
       let* directory = directories store [ revision, true; "muse", true ] in
       write_private (Filename.concat directory "settings.json") settings;
       write_private (Filename.concat directory "auth.json") source_bytes;
       sync_directory directory;
       let generation = Filename.dirname directory in
       let* _ = directories generation [ "tmp", true ] in
       sync_directory generation;
       let record = Yojson.Safe.to_string (`Assoc [ "source_sha256", `String source_sha256
                                                ; "revision", `String revision ]) in
       (* The strict atomic writer creates its tempfile with mode 0600 and
          fsyncs both it and the parent directory; no post-publication chmod. *)
       let* () = Fs_compat.save_file_atomic_strict record_path record |> Result.map_error (fun _ -> State_unavailable "credential generation publication failed") in
       Ok { config_home = generation; account_revision = revision })

let protect operation =
  try operation () with
  | Sys_error _ | Unix.Unix_error _ -> unavailable "private account state could not be accessed"

let prepare ~account_home =
  let* account_home = Runtime_account_home.of_string account_home
    |> Result.map_error (fun detail -> Invalid_account_home detail) in
  protect (fun () ->
    (* Configured spelling remains the caller's account/session identity. Resolve
       only the filesystem ownership boundary: an account HOME may itself be a
       symlink, while credential and managed-state descendants may not be. *)
    let* account_home, store = Eio_guard.run_in_systhread ~label:"muse-managed-account-directories" (fun () ->
      let account_home = Unix.realpath account_home in
      let* () = check_directory ~private_:false account_home in
      let* store = directories account_home [ ".local", false; "state", false; "masc", true; "muse-config", true ] in
      Ok (account_home, store)) in
    let source = Filename.concat account_home ".config/muse/auth.json" in
    match File_lock_eio.with_durable_lock ~lock_path:(Filename.concat store "prepare.lock")
        (fun () -> Eio_guard.run_in_systhread ~label:"muse-managed-account-generation"
            (fun () -> prepare_locked ~account_home ~store ~source)) with
    | Ok result -> result
    | Error _ -> unavailable "credential generation lock failed")

let prepare_native_workspace ~runtime_root ~keeper_name ~account_home =
  let* account_home = Runtime_account_home.of_string account_home
    |> Result.map_error (fun detail -> Invalid_account_home detail) in
  if Filename.is_relative runtime_root then unavailable "runtime root must be absolute"
  else protect (fun () ->
    let identity = digest (Yojson.Safe.to_string (`List [ `String keeper_name; `String account_home ])) in
    Eio_guard.run_in_systhread ~label:"muse-native-workspace" (fun () ->
      directories runtime_root [ "official-clients", true; "muse", true; identity, true; "workspace", true ]))
