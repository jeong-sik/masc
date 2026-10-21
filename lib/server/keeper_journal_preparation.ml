module Store = Keeper_chat_operation_store
module Checkpoint = Keeper_checkpoint_store
module Semantic = Keeper_semantic_execution
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
  | Bundle_workspace_mismatch of { recorded_base_path : string; current_base_path : string }
  | Input_selection_invalid of string
  | Input_source_changed of string
  | Input_history_unresolved of string
  | Input_retention_unconfirmed of Checkpoint.checkpoint_installation
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
    | Invalid_bundle -> "The published recovery bundle is incomplete, changed or unsupported."
    | Bundle_workspace_mismatch {recorded_base_path;current_base_path} ->
      Printf.sprintf "This bundle records workspace %S, but was read under %S. Preserve its files and manifest; relocation requires explicit reconciliation."
        recorded_base_path current_base_path
    | Input_selection_invalid detail -> "Input adoption selection is invalid: " ^ detail
    | Input_source_changed path -> "Input adoption evidence changed; assess again: " ^ path
    | Input_history_unresolved detail -> "Input history requires explicit repair: " ^ detail
    | Input_retention_unconfirmed _ -> "Checkpoint retention was not durably confirmed. Preserve any retained file; no adoption was published." in
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
  let* recorded_base_path = match json with
    | `Assoc fields -> (match List.assoc_opt "base_path" fields with
      | Some (`String path) when not (Filename.is_relative path) -> Ok path
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
  (* Validate the complete recorded manifest before distinguishing relocation.
     Its old paths are compared as data only, never opened or rebound. *)
  let recorded_receipt = {receipt with base_path=recorded_base_path} in
  let* () = if Yojson.Safe.equal json (receipt_to_json recorded_receipt) then Ok () else error Invalid_bundle in
  let recheck path (before : Fs_compat.owned_regular_file_contents) =
    let* after = read_private ~base_path path in
    if Fs_compat.equal_owned_regular_file_snapshot before.Fs_compat.snapshot after.snapshot
        && before.content=after.content then Ok () else error Invalid_bundle in
  let* () = recheck original_path original in
  let* () = recheck prepared_path prepared in
  let* () = recheck manifest_path manifest in
  let* () = no_companions original_path in
  let* () = no_companions prepared_path in
  if recorded_base_path=base_path then Ok receipt
  else error (Bundle_workspace_mismatch {recorded_base_path;current_base_path=base_path}))
  |> Result.map_error (fun failure -> {failure with bundle_id=Some id}))

type input_plan =
  { ip_bundle : receipt; ip_original : plan
  ; ip_metadata : string * Fs_compat.owned_regular_file_contents
  ; ip_canonical : string * Fs_compat.owned_regular_file_contents
  ; ip_checkpoint : Checkpoint.exact_checkpoint_snapshot
  ; ip_related : (string * Fs_compat.owned_regular_file_contents) list }
type input_adoption =
  { ia_id : string; ia_bundle : receipt; ia_metadata_hash : string
  ; ia_reference : Keeper_checkpoint_ref.t; ia_derivative_hash : string
  ; ia_records : Store.Offline.input_adoption_copy }
type input_publication = Input_adopted of input_adoption | Input_adoption_unconfirmed of input_adoption

let input_directories base_path = Filename.concat (Filename.concat (root base_path) "upgrades") "journal-inputs"
let input_directory base_path id = Filename.concat (input_directories base_path) id
let session_root base_path = Keeper_fs.session_store_path_for_runtime_root (root base_path)
let session_dir base_path trace_id = Filename.concat (session_root base_path) (Keeper_id.Trace_id.to_string trace_id)
let retained_path base_path (reference : Keeper_checkpoint_ref.t) =
  Filename.concat (Filename.concat (session_dir base_path reference.trace_id) Checkpoint.retained_dirname)
    (reference.sha256 ^ ".json")
let input_checkpoint_sha256 plan = (Checkpoint.exact_snapshot_reference plan.ip_checkpoint).sha256
let input_adoption_id receipt = receipt.ia_id
let reference_json (reference : Keeper_checkpoint_ref.t) = `Assoc
  ["trace_id",`String (Keeper_id.Trace_id.to_string reference.trace_id);
   "turn_count",`Int reference.turn_count;"sha256",`String reference.sha256]
let input_plan_to_json plan =
  let checkpoint = Checkpoint.exact_snapshot_checkpoint plan.ip_checkpoint in
  `Assoc ["schema",`String "masc.keeper_journal_input_plan.v1";
    "source_bundle",receipt_to_json plan.ip_bundle;
    "checkpoint",reference_json (Checkpoint.exact_snapshot_reference plan.ip_checkpoint);
    "metadata_sha256",`String (digest (snd plan.ip_metadata).content);
    "pending_input",(match checkpoint.pending_input with None -> `Null
      | Some pending -> Agent_core.Agent_input_request.pending_to_json pending);
    "operator_decision_required",`Bool true;"read_only",`Bool true;"ready_to_install",`Bool false]
let input_adoption_to_json receipt =
  let counts = receipt.ia_records.original_records in
  `Assoc ["schema",`String "masc.keeper_journal_input_adoption.v1";
    "adoption_id",`String receipt.ia_id;"source_bundle",receipt_to_json receipt.ia_bundle;
    "decision",`String "adopt_exact_canonical_input";"actor_uid",`Int (Unix.geteuid ());
    "checkpoint",reference_json receipt.ia_reference;
    "metadata_sha256",`String receipt.ia_metadata_hash;
    "derivative_sha256",`String receipt.ia_derivative_hash;
    "operation_count",`Int counts.operation_count;"semantic_count",`Int counts.semantic_count;
    "batch_member_count",`Int counts.batch_member_count;
    "next_sequence",`String (Int64.to_string counts.next_sequence);
    "prior_input_history",`String "unavailable";"ready_to_install",`Bool false]

let decode_json contents =
  try Ok (Yojson.Safe.from_string contents) with Yojson.Json_error _ -> error Invalid_bundle
let decode_meta ~keeper_name ~trace_id bytes =
  let* json = decode_json bytes in
  let* meta = Keeper_meta_json.meta_of_json json
    |> Result.map_error (fun detail -> {bundle_id=None;failure=Input_selection_invalid detail}) in
  if meta.name=keeper_name && Keeper_id.Trace_id.equal meta.runtime.trace_id trace_id then Ok ()
  else error (Input_selection_invalid "Keeper metadata does not name the selected current trace")
let decode_checkpoint ~trace_id bytes =
  Checkpoint.exact_snapshot_of_canonical_bytes ~expected_session_id:trace_id bytes
  |> Result.map_error (fun cause -> {bundle_id=None;
    failure=Input_selection_invalid (Checkpoint.checkpoint_ref_load_error_to_string cause)})
let same_pending left right = Option.equal (fun left right -> Yojson.Safe.equal
  (Agent_core.Agent_input_request.pending_to_json left)
  (Agent_core.Agent_input_request.pending_to_json right)) left right
let rec preserves_messages prefix messages = match prefix,messages with
  | [],_ -> true
  | expected::prefix,actual::messages -> expected=actual && preserves_messages prefix messages
  | _::_,[] -> false
let read_reference ~base_path ~path reference =
  let* file = read ~base_path ~absent:(Input_history_unresolved path) path in
  let* snapshot = decode_checkpoint ~trace_id:reference.Keeper_checkpoint_ref.trace_id file.content in
  if Keeper_checkpoint_ref.equal reference (Checkpoint.exact_snapshot_reference snapshot)
  then Ok (file,snapshot) else error (Input_history_unresolved ("retained reference changed: " ^ path))
let unchanged ~base_path (path,(before : Fs_compat.owned_regular_file_contents)) =
  let* after = read ~base_path ~absent:(Input_source_changed path) path in
  if Fs_compat.equal_owned_regular_file_snapshot before.snapshot after.snapshot && before.content=after.content
  then Ok () else error (Input_source_changed path)
let rec unchanged_files ~base_path = function
  | [] -> Ok ()
  | file::rest -> let* () = unchanged ~base_path file in unchanged_files ~base_path rest
type bundle_part = Original_journal | Prepared_journal | Bundle_manifest
let bundle_part_name = function Original_journal -> "original.sqlite3"
  | Prepared_journal -> "prepared.sqlite3" | Bundle_manifest -> "manifest.json"
let capture_bundle_files (receipt : receipt) =
  let rec capture acc = function
    | [] -> Ok (List.rev acc)
    | part::rest -> let path = Filename.concat (bundle_path receipt.base_path receipt.id) (bundle_part_name part) in
      let* file = read_private ~base_path:receipt.base_path path in
      let* () = match part with
        | Original_journal -> if digest file.content=receipt.source_hash then Ok () else error Invalid_bundle
        | Prepared_journal -> if digest file.content=receipt.prepared_hash then Ok () else error Invalid_bundle
        | Bundle_manifest -> let* json = decode_json file.content in
          if Yojson.Safe.equal json (receipt_to_json receipt) then Ok () else error Invalid_bundle
        in
      capture ((path,file)::acc) rest in
  capture [] [Original_journal;Prepared_journal;Bundle_manifest]
let continuation_evidence (bundle : receipt) snapshot =
  let reference = Checkpoint.exact_snapshot_reference snapshot in
  let selected = Checkpoint.exact_snapshot_checkpoint snapshot in
  let path = Filename.concat (bundle_path bundle.base_path bundle.id) "prepared.sqlite3" in
  let* observed = Store.inspect_outstanding ~path
    |> Result.map_error (fun cause -> {bundle_id=None;failure=Store_failed cause}) in
  let* executions = match observed with
    | Store.Missing_store -> error Invalid_bundle
    | Stored_operations {semantic_executions;_} -> Ok semantic_executions in
  let rec inspect acc = function
    | [] -> Ok acc
    | (execution : Semantic.t)::rest ->
      let* () = match execution.native_call with
        | Keeper_native_call.Active call
        | Terminal_unacknowledged (call,{Agent_core.Agent.recovery=Operator_repair_required Effect_outcome_unknown;_}) ->
          if Keeper_id.Trace_id.equal call.checkpoint.trace_id reference.trace_id
          then error (Input_history_unresolved "selected trace has an active or unknown-effect native call") else Ok ()
        | No_native_call | Terminal_unacknowledged (_,{Agent_core.Agent.recovery=Retire;_}) -> Ok () in
      let* acc = match execution.native_call with
        | Keeper_native_call.No_native_call -> Ok acc
        | Active call | Terminal_unacknowledged (call,_) ->
          if not (Keeper_id.Trace_id.equal call.checkpoint.trace_id reference.trace_id) then Ok acc else
          let seed_path = retained_path bundle.base_path call.seed_checkpoint in
          let latest_path = retained_path bundle.base_path call.checkpoint in
          let* seed_file,seed = read_reference ~base_path:bundle.base_path ~path:seed_path call.seed_checkpoint in
          let* latest_file,latest = read_reference ~base_path:bundle.base_path ~path:latest_path call.checkpoint in
          if preserves_messages (Checkpoint.exact_snapshot_checkpoint seed).messages
              (Checkpoint.exact_snapshot_checkpoint latest).messages
          then Ok ((seed_path,seed_file)::(latest_path,latest_file)::acc)
          else error (Input_history_unresolved "native continuation does not preserve its admission seed history") in
      let rec capture acc = function
        | [] -> inspect acc rest
        | (retained : Keeper_checkpoint_ref.t)::remaining ->
          if not (Keeper_id.Trace_id.equal retained.trace_id reference.trace_id) then capture acc remaining
          else
            let path = retained_path bundle.base_path retained in
            let* file,known = read_reference ~base_path:bundle.base_path ~path retained in
            let known = Checkpoint.exact_snapshot_checkpoint known in
            if same_pending known.pending_input selected.pending_input
                && preserves_messages known.messages selected.messages
            then capture ((path,file)::acc) remaining
            else error (Input_history_unresolved "selected canonical input conflicts with retained pending/history evidence") in
      capture acc (Semantic.continuation_checkpoints execution) in
  inspect [] executions

let assess_input ~base_path ~bundle_id ~trace_id = blocking (fun () -> boundary base_path (fun () ->
  let* trace_id = Keeper_id.Trace_id.of_string trace_id
    |> Result.map_error (fun detail -> {bundle_id=None;failure=Input_selection_invalid detail}) in
  let* bundle = load_recovery ~base_path ~bundle_id in
  let base_path = bundle.base_path in
  let* original = assess ~base_path ~keeper_name:bundle.keeper_name in
  let* () = if original.source_hash=bundle.source_hash then Ok () else error Source_changed in
  let* related = capture_bundle_files bundle in
  let metadata_path = Filename.concat (Common.keepers_runtime_dir_of_base ~base_path)
    (Keeper_runtime_root_entry.keeper_basename ~keeper_name:bundle.keeper_name Keeper_runtime_root_entry.Metadata) in
  let* metadata = read ~base_path ~absent:(Input_selection_invalid "current Keeper metadata is absent") metadata_path in
  let* () = decode_meta ~keeper_name:bundle.keeper_name ~trace_id metadata.content in
  let canonical_path = Checkpoint.agent_core_checkpoint_path ~session_dir:(session_dir base_path trace_id)
    ~session_id:(Keeper_id.Trace_id.to_string trace_id) in
  let* canonical = read ~base_path ~absent:(Input_selection_invalid "current canonical checkpoint is absent") canonical_path in
  let* checkpoint = decode_checkpoint ~trace_id canonical.content in
  let* continuations = continuation_evidence bundle checkpoint in
  let plan = {ip_bundle=bundle;ip_original=original;ip_metadata=(metadata_path,metadata);
    ip_canonical=(canonical_path,canonical);ip_checkpoint=checkpoint;ip_related=related @ continuations} in
  let* _ = current_source original in
  let* () = unchanged_files ~base_path (plan.ip_metadata::plan.ip_canonical::plan.ip_related) in
  Ok plan))

let check_input_plan plan =
  let* _ = current_source plan.ip_original in
  let* () = no_companions (Filename.concat (bundle_path plan.ip_bundle.base_path plan.ip_bundle.id) "original.sqlite3") in
  let* () = no_companions (Filename.concat (bundle_path plan.ip_bundle.base_path plan.ip_bundle.id) "prepared.sqlite3") in
  unchanged_files ~base_path:plan.ip_bundle.base_path (plan.ip_metadata::plan.ip_canonical::plan.ip_related)

let confirm_input_retention outcome =
  let auxiliary = match outcome with
    | Checkpoint.Installed installed -> installed.auxiliary
    | Not_installed refused -> refused.auxiliary in
  List.iter (function
    | Checkpoint.Commit_observer_failed ((Eio.Cancel.Cancelled _ as cause),backtrace)
    | Post_commit_unwind_interrupted ((Eio.Cancel.Cancelled _ as cause),backtrace) ->
      Printexc.raise_with_backtrace cause backtrace
    | Commit_observer_failed _ | Post_commit_unwind_interrupted _
    | Commit_durability_unknown _ | Release_process_lock_failed _ -> ()) auxiliary;
  match outcome with
  | Checkpoint.Installed {auxiliary=[];_} -> Ok ()
  | Installed {auxiliary=_::_;_} | Not_installed _ -> error (Input_retention_unconfirmed outcome)

let adopt_input_using ~before_publication
    ~(write_manifest : string -> string -> (unit, Fs_compat.atomic_replace_failure) result)
    ~run_dir ~expected_checkpoint_sha256 plan = blocking (fun () ->
  let active_bundle = ref None in
  let base_path = plan.ip_bundle.base_path in
  let result = boundary base_path (fun () ->
    let* () = if expected_checkpoint_sha256=input_checkpoint_sha256 plan then Ok ()
      else error (Input_selection_invalid "checkpoint SHA does not match the reviewed input plan") in
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Base_path_already_owned _ -> error Workspace_in_use
    | Base_path_rejected cause -> error (Unsafe_path (Server_startup_takeover.base_path_lock_rejection_to_string cause))
    | Base_path_acquired lease ->
      Fun.protect ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease) (fun () ->
        let* () = check_input_plan plan in
        let* () = private_directory (input_directories base_path) in
        let id = Random_id.hex ~bytes:16 in
        let directory = input_directory base_path id in
        Unix.mkdir directory 0o700; active_bundle := Some id; sync_directory (input_directories base_path);
        let reference = Checkpoint.exact_snapshot_reference plan.ip_checkpoint in
        let* () = Checkpoint.retain_exact_snapshot
          ~session_dir:(session_dir base_path reference.trace_id) plan.ip_checkpoint
          |> confirm_input_retention in
        let* retained,_ = read_reference ~base_path ~path:(retained_path base_path reference) reference in
        let metadata_path = Filename.concat directory "metadata.json" in
        let checkpoint_path = Filename.concat directory "checkpoint.json" in
        let* () = write metadata_path (snd plan.ip_metadata).content |> written metadata_path in
        let* () = write checkpoint_path (snd plan.ip_canonical).content |> written checkpoint_path in
        let* metadata = read_private ~base_path metadata_path in
        let* checkpoint = read_private ~base_path checkpoint_path in
        let* () = if metadata.content=(snd plan.ip_metadata).content
            && checkpoint.content=(snd plan.ip_canonical).content then Ok () else error Invalid_bundle in
        let destination = Filename.concat directory "adopted.sqlite3" in
        let fd = Unix.openfile destination [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_EXCL;Unix.O_CLOEXEC] 0o600 in
        Unix.close fd;
        let source = Filename.concat (bundle_path base_path plan.ip_bundle.id) "prepared.sqlite3" in
        let* adopted = with_database ~mode:`READONLY source (fun source ->
          with_database ~mode:`NO_CREATE destination (fun destination ->
            Store.Offline.prepare_input_adoption_copy ~source ~destination
              ~adoptions:[Operator_adopts_checkpoint reference]
            |> Result.map_error (fun cause -> {bundle_id=None;failure=Store_failed cause}))) in
        let* () = Fs_compat.sync_file_and_parent_strict destination
          |> Result.map_error (fun detail -> {bundle_id=None;failure=Io_failed {path=destination;detail}}) in
        let* derivative = read_private ~base_path destination in
        let receipt = {ia_id=id;ia_bundle=plan.ip_bundle;ia_metadata_hash=digest (snd plan.ip_metadata).content;
          ia_reference=reference;ia_derivative_hash=digest derivative.content;ia_records=adopted} in
        before_publication ();
        let* () = check_input_plan plan in
        let* () = unchanged_files ~base_path
          [retained_path base_path reference,retained;metadata_path,metadata;checkpoint_path,checkpoint;destination,derivative] in
        let* () = no_companions destination in
        let manifest_path = Filename.concat directory "manifest.json" in
        match write_manifest manifest_path (Yojson.Safe.to_string (input_adoption_to_json receipt)) with
        | Ok () -> Ok (Input_adopted receipt)
        | Error {Fs_compat.stage=After_rename;_} -> Ok (Input_adoption_unconfirmed receipt)
        | Error ({Fs_compat.stage=Before_rename;_} as cause) ->
          error (Io_failed {path=manifest_path;detail=Fs_compat.atomic_replace_failure_to_string cause}))) in
  Result.map_error (fun failure -> {failure with bundle_id= !active_bundle}) result)
let adopt_input ~run_dir ~expected_checkpoint_sha256 plan =
  adopt_input_using ~before_publication:(fun () -> ()) ~write_manifest:write ~run_dir ~expected_checkpoint_sha256 plan

let json_string key = function
  | `Assoc fields -> (match List.assoc_opt key fields with Some (`String text) -> Ok text
    | Some _ | None -> error Invalid_bundle)
  | _ -> error Invalid_bundle
let json_member key = function
  | `Assoc fields -> (match List.assoc_opt key fields with Some value -> Ok value | None -> error Invalid_bundle)
  | _ -> error Invalid_bundle
let load_input_adoption ~base_path ~adoption_id:id = blocking (fun () -> boundary base_path (fun () ->
  if not (valid_id id) then error Invalid_bundle else
  let* base_path = workspace base_path in
  let directory = input_directory base_path id in
  let paths = List.map (Filename.concat directory) ["manifest.json";"metadata.json";"checkpoint.json";"adopted.sqlite3"] in
  let rec capture acc = function
    | [] -> Ok (List.rev acc)
    | path::rest -> let* file = read_private ~base_path path in capture ((path,file)::acc) rest in
  let* files = capture [] paths in
  match files with
  | [(_,manifest);(_,metadata);(_,checkpoint);(derivative_path,derivative)] ->
    let* json = decode_json manifest.content in
    let* source_json = json_member "source_bundle" json in
    let* source_id = json_string "bundle_id" source_json in
    let* bundle = load_recovery ~base_path ~bundle_id:source_id in
    let* reference_json = json_member "checkpoint" json in
    let* trace = json_string "trace_id" reference_json in
    let* trace_id = Keeper_id.Trace_id.of_string trace
      |> Result.map_error (fun detail -> {bundle_id=None;failure=Input_selection_invalid detail}) in
    let* () = decode_meta ~keeper_name:bundle.keeper_name ~trace_id metadata.content in
    let* snapshot = decode_checkpoint ~trace_id checkpoint.content in
    let reference = Checkpoint.exact_snapshot_reference snapshot in
    let* related = capture_bundle_files bundle in
    let* retained,_ = read_reference ~base_path ~path:(retained_path base_path reference) reference in
    let source_path = Filename.concat (bundle_path base_path source_id) "prepared.sqlite3" in
    let* () = no_companions derivative_path in
    let* adopted = with_database ~mode:`READONLY source_path (fun source ->
      with_database ~mode:`READONLY derivative_path (fun destination ->
        Store.Offline.verify_input_adoption_copy ~source ~destination
          ~adoptions:[Operator_adopts_checkpoint reference]
        |> Result.map_error (fun cause -> {bundle_id=None;failure=Store_failed cause}))) in
    let receipt = {ia_id=id;ia_bundle=bundle;ia_metadata_hash=digest metadata.content;
      ia_reference=reference;ia_derivative_hash=digest derivative.content;ia_records=adopted} in
    let* () = if Yojson.Safe.equal json (input_adoption_to_json receipt) then Ok () else error Invalid_bundle in
    let* () = unchanged_files ~base_path ((retained_path base_path reference,retained)::files @ related) in
    let* () = no_companions source_path in
    let* () = no_companions (Filename.concat (bundle_path base_path source_id) "original.sqlite3") in
    let* () = no_companions derivative_path in
    Ok receipt
  | [] | [_] | [_;_] | [_;_;_] | _::_::_::_::_::_ -> error Invalid_bundle)
  |> Result.map_error (fun failure -> {failure with bundle_id=Some id}))

module For_testing = struct
  let confirm_input_retention = confirm_input_retention
  let prepare ~before_publication ~sync_manifest_parent ~run_dir plan =
    let write_manifest path content =
      Fs_compat.Atomic_replace_for_testing.write_file_atomic_strict_staged
        ~sync_parent:sync_manifest_parent path ~write:(fun out ->
          Unix.fchmod (Unix.descr_of_out_channel out) 0o600; output_string out content) in
    prepare_using ~before_publication ~write_manifest ~run_dir plan
  let adopt_input ~before_publication ~sync_manifest_parent ~run_dir ~expected_checkpoint_sha256 plan =
    let write_manifest path content =
      Fs_compat.Atomic_replace_for_testing.write_file_atomic_strict_staged
        ~sync_parent:sync_manifest_parent path ~write:(fun out ->
          Unix.fchmod (Unix.descr_of_out_channel out) 0o600; output_string out content) in
    adopt_input_using ~before_publication ~write_manifest ~run_dir ~expected_checkpoint_sha256 plan
end
