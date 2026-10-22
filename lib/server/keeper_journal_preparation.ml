module Store = Keeper_chat_operation_store
let ( let* ) = Result.bind
let digest text = Digestif.SHA256.(digest_string text |> to_hex)

type plan =
  { base_path : string; keeper_name : string; source_path : string
  ; snapshot : Fs_compat.owned_regular_file_snapshot; source_hash : string }
type receipt =
  { id : string; base_path : string; keeper_name : string
  ; source_hash : string; prepared_hash : string; copied : Store.Offline.prepared_copy }
type failure =
  | Invalid_keeper of string
  | Workspace_in_use
  | Unsafe_path of string
  | Source_absent
  | Source_changed
  | Companion_present of string
  | Store_failed of Store.error
  | Io_failed of { path : string; detail : string }
  | Invalid_bundle
type error = { bundle_id : string option; failure : failure }
type publication = Published of receipt | Publication_unconfirmed of receipt

let error failure = Error {bundle_id=None;failure}
let error_message {bundle_id;failure} =
  let detail = match failure with
    | Invalid_keeper name -> Keeper_config.invalid_name_error name
    | Workspace_in_use -> "Stop the workspace server before preparing its journal."
    | Unsafe_path detail -> "Unsafe journal preparation path: " ^ detail
    | Source_absent -> "The selected Keeper has no existing operation journal."
    | Source_changed -> "The original journal changed. Assess it again before preparing."
    | Companion_present path -> "Preserve and recover the SQLite companion before preparing: " ^ path
    | Store_failed cause -> Store.error_to_string cause
    | Io_failed {path;detail} -> "Journal preparation I/O failed at " ^ path ^ ": " ^ detail
    | Invalid_bundle -> "The published recovery bundle is incomplete, changed or unsupported." in
  match bundle_id with None -> detail | Some id -> detail ^ " Retain bundle " ^ id ^ " for inspection."

let root base_path = Filename.concat base_path Common.masc_dirname
let bundles base_path = Filename.concat (Filename.concat (root base_path) "upgrades") "journals"
let bundle_path base_path id = Filename.concat (bundles base_path) id
let source_path base_path keeper_name = Store.path_for_keeper
  ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path) ~keeper_name
let source_sha256 (plan : plan) = plan.source_hash
let bundle_id receipt = receipt.id
let plan_to_json (plan : plan) = `Assoc
  ["schema",`String "masc.keeper_journal_plan.v1";
   "base_path",`String plan.base_path;"keeper_name",`String plan.keeper_name;
   "source_path",`String plan.source_path;"source_sha256",`String plan.source_hash;
   "read_only",`Bool true;"ready_to_install",`Bool false]
let receipt_to_json (receipt : receipt) = `Assoc
  ["schema",`String "masc.keeper_journal_bundle.v1";
   "bundle_id",`String receipt.id;"base_path",`String receipt.base_path;
   "keeper_name",`String receipt.keeper_name;
   "source_path",`String (source_path receipt.base_path receipt.keeper_name);
   "source_sha256",`String receipt.source_hash;"prepared_sha256",`String receipt.prepared_hash;
   "operation_count",`Int receipt.copied.operation_count;
   "semantic_count",`Int receipt.copied.semantic_count;
   "batch_member_count",`Int receipt.copied.batch_member_count;
   "next_sequence",`String (Int64.to_string receipt.copied.next_sequence);
   "prior_input_history",`String "unavailable";"ready_to_install",`Bool false]

let boundary path f =
  try f () with
  | Unix.Unix_error (cause,operation,_) ->
    error (Io_failed {path;detail=operation ^ ": " ^ Unix.error_message cause})
  | Sys_error detail | Sqlite3.Error detail | Sqlite3.SqliteError detail -> error (Io_failed {path;detail})
let blocking f = Domain_pool_ref.submit_io_or_inline f

let workspace base_path =
  let base_path = Unix.realpath base_path in
  let stat = Unix.lstat (root base_path) in
  if stat.st_kind=Unix.S_DIR && stat.st_uid=Unix.geteuid () && stat.st_perm land 0o022=0
  then Ok base_path else error (Unsafe_path (root base_path))

let read ~base_path ~absent path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
      ~ownership_root:(root base_path) path with
  | Ok (Some file) -> Ok file
  | Ok None -> error absent
  | Error cause -> error (Unsafe_path (Fs_compat.owned_regular_file_read_error_to_string cause))

let read_private ~base_path path =
  let* file = read ~base_path ~absent:Invalid_bundle path in
  let parent = Unix.lstat (Filename.dirname path) in
  if file.snapshot.permissions land 0o077=0 && parent.st_kind=Unix.S_DIR
      && parent.st_uid=Unix.geteuid () && parent.st_perm land 0o077=0 then Ok file
  else error (Unsafe_path path)

let no_companions path =
  let rec check = function
    | [] -> Ok ()
    | suffix::rest ->
      let companion = path ^ suffix in
      (match Unix.lstat companion with
       | _ -> error (Companion_present companion)
       | exception Unix.Unix_error (Unix.ENOENT,_,_) -> check rest) in
  check ["-journal";"-wal";"-shm"]

let assess ~base_path ~keeper_name = blocking (fun () -> boundary base_path (fun () ->
  if not (Keeper_config.validate_name keeper_name) then error (Invalid_keeper keeper_name) else
  let* base_path = workspace base_path in
  let source_path = source_path base_path keeper_name in
  let* () = no_companions source_path in
  let* file = read ~base_path ~absent:Source_absent source_path in
  let* () = no_companions source_path in
  Ok {base_path;keeper_name;source_path;snapshot=file.snapshot;source_hash=digest file.content}))

let sync_directory path =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
let private_directory path =
  (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST,_,_) -> ());
  let stat = Unix.lstat path in
  if stat.st_kind=Unix.S_DIR && stat.st_uid=Unix.geteuid () && stat.st_perm land 0o077=0 then (
    sync_directory path; sync_directory (Filename.dirname path); Ok ())
  else error (Unsafe_path path)
let write path content = Fs_compat.write_file_atomic_strict_staged_blocking path
    ~write:(fun out -> Unix.fchmod (Unix.descr_of_out_channel out) 0o600; output_string out content)
let written path = function
  | Ok () -> Ok ()
  | Error cause -> error (Io_failed {path;detail=Fs_compat.atomic_replace_failure_to_string cause})
let with_database ~mode path f =
  let db = Sqlite3.db_open ~mode path in
  let closed = ref false in
  let result = Fun.protect ~finally:(fun () -> closed := Sqlite3.db_close db) (fun () -> f db) in
  if !closed then result else error (Io_failed {path;detail="SQLite handle did not close"})

let current_source (plan : plan) =
  let* () = no_companions plan.source_path in
  let* current = read ~base_path:plan.base_path ~absent:Source_absent plan.source_path in
  let* () = no_companions plan.source_path in
  if Fs_compat.equal_owned_regular_file_snapshot plan.snapshot current.snapshot
      && digest current.content=plan.source_hash then Ok current
  else error Source_changed

let prepare_using ~before_publication
    ~(write_manifest : string -> string -> (unit, Fs_compat.atomic_replace_failure) result)
    ~run_dir (plan : plan) = blocking (fun () ->
  let active_bundle = ref None in
  let result = boundary plan.source_path (fun () ->
    let* base_path = workspace plan.base_path in
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Base_path_already_owned _ -> error Workspace_in_use
    | Base_path_rejected cause -> error (Unsafe_path (Server_startup_takeover.base_path_lock_rejection_to_string cause))
    | Base_path_acquired lease ->
      Fun.protect ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease) (fun () ->
        let* original = current_source plan in
        let* () = private_directory (Filename.dirname (bundles base_path)) in
        let* () = private_directory (bundles base_path) in
        let id = Random_id.hex ~bytes:16 in
        let directory = bundle_path base_path id in
        Unix.mkdir directory 0o700;
        active_bundle := Some id;
        sync_directory (bundles base_path);
        let original_path = Filename.concat directory "original.sqlite3" in
        let prepared_path = Filename.concat directory "prepared.sqlite3" in
        let* () = write original_path original.content |> written original_path in
        let fd = Unix.openfile prepared_path [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_EXCL;Unix.O_CLOEXEC] 0o600 in
        Unix.close fd;
        let* copied = with_database ~mode:`READONLY original_path (fun source ->
          with_database ~mode:`NO_CREATE prepared_path (fun destination ->
            Store.Offline.prepare_v2_copy ~source ~destination
            |> Result.map_error (fun failure -> {bundle_id=None;failure=Store_failed failure}))) in
        let* () = Fs_compat.sync_file_and_parent_strict prepared_path
          |> Result.map_error (fun detail -> {bundle_id=None;failure=Io_failed {path=prepared_path;detail}}) in
        let* backup = read_private ~base_path original_path in
        let* () = if digest backup.content=plan.source_hash then Ok () else error Invalid_bundle in
        let* prepared = read_private ~base_path prepared_path in
        let receipt = {id;base_path;keeper_name=plan.keeper_name;source_hash=plan.source_hash;
          prepared_hash=digest prepared.content;copied} in
        before_publication ();
        let* _ = current_source plan in
        let manifest_path = Filename.concat directory "manifest.json" in
        match write_manifest manifest_path (Yojson.Safe.to_string (receipt_to_json receipt)) with
        | Ok () -> Ok (Published receipt)
        | Error {Fs_compat.stage=After_rename;_} -> Ok (Publication_unconfirmed receipt)
        | Error ({Fs_compat.stage=Before_rename;_} as cause) ->
          error (Io_failed {path=manifest_path;detail=Fs_compat.atomic_replace_failure_to_string cause}))) in
  Result.map_error (fun failure -> {failure with bundle_id= !active_bundle}) result)

let prepare ~run_dir plan = prepare_using ~before_publication:(fun () -> ()) ~write_manifest:write ~run_dir plan

let valid_id id = String.length id=32 && String.for_all
  (function '0'..'9' | 'a'..'f' -> true | _ -> false) id
let load_recovery ~base_path ~bundle_id:id = blocking (fun () -> boundary base_path (fun () ->
  if not (valid_id id) then error Invalid_bundle else
  let* base_path = workspace base_path in
  let directory = bundle_path base_path id in
  let original_path = Filename.concat directory "original.sqlite3" in
  let prepared_path = Filename.concat directory "prepared.sqlite3" in
  let manifest_path = Filename.concat directory "manifest.json" in
  let* original = read_private ~base_path original_path in
  let* prepared = read_private ~base_path prepared_path in
  let* manifest = read_private ~base_path manifest_path in
  let* json = try Ok (Yojson.Safe.from_string manifest.content) with Yojson.Json_error _ -> error Invalid_bundle in
  let* keeper_name = match json with
    | `Assoc fields -> (match List.assoc_opt "keeper_name" fields with
      | Some (`String name) when Keeper_config.validate_name name -> Ok name
      | Some _ | None -> error Invalid_bundle)
    | _ -> error Invalid_bundle in
  let* () = no_companions original_path in
  let* () = no_companions prepared_path in
  let* copied = with_database ~mode:`READONLY original_path (fun source ->
    with_database ~mode:`READONLY prepared_path (fun destination ->
      Store.Offline.verify_v2_copy ~source ~destination
      |> Result.map_error (fun failure -> {bundle_id=Some id;failure=Store_failed failure}))) in
  let receipt = {id;base_path;keeper_name;source_hash=digest original.content;
    prepared_hash=digest prepared.content;copied} in
  let* () = if Yojson.Safe.equal json (receipt_to_json receipt) then Ok () else error Invalid_bundle in
  let recheck path (before : Fs_compat.owned_regular_file_contents) =
    let* after = read_private ~base_path path in
    if Fs_compat.equal_owned_regular_file_snapshot before.Fs_compat.snapshot after.snapshot
        && before.content=after.content then Ok () else error Invalid_bundle in
  let* () = recheck original_path original in
  let* () = recheck prepared_path prepared in
  let* () = recheck manifest_path manifest in
  let* () = no_companions original_path in
  let* () = no_companions prepared_path in
  Ok receipt)
  |> Result.map_error (fun failure -> {failure with bundle_id=Some id}))

module For_testing = struct
  let prepare ~before_publication ~sync_manifest_parent ~run_dir plan =
    let write_manifest path content =
      Fs_compat.Atomic_replace_for_testing.write_file_atomic_strict_staged
        ~sync_parent:sync_manifest_parent path ~write:(fun out ->
          Unix.fchmod (Unix.descr_of_out_channel out) 0o600; output_string out content) in
    prepare_using ~before_publication ~write_manifest ~run_dir plan
end
