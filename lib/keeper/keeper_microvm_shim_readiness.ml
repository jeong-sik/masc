module Shim = Keeper_sandbox_microvm

type initialization_failure =
  | Startup_shim_missing of Unix.error

type verification_failure =
  | Guest_shim_missing of Unix.error
  | Sidecar_rejected of string

type config_failure =
  | Config_missing
  | Recovery_context_unavailable
  | Config_inspection_failed of Fs_compat.owned_regular_file_read_error
  | Config_not_canonical
  | Config_owner_or_mode_refused
  | Recovery_registry_failed of Fs_compat.Publication_recovery.registry_error
  | Recovery_lane_failed of Fs_compat.Publication_recovery.lane_open_error
  | Recovery_lane_release_failed of
      { primary : error option
      ; release_failure : Fs_compat.Publication_recovery.lane_release_failure
      }
  | Recovery_target_invalid of Fs_compat.capability_publication_target_error
  | Recovery_publication_failed of Fs_compat.capability_write_error
  | Recovery_sync_failed of Fs_compat.owned_regular_file_read_error
  | Recovery_io_failed of exn

and error =
  | Invalid_base_path of Config_dir_resolver.canonical_base_path_error
  | Not_initialized
  | Initialization_conflict
  | Initialization_failed of initialization_failure
  | Verification_failed of verification_failure
  | Verification_invalidated
  | Config_unavailable of config_failure

(* These diagnostics cross into Keeper-visible errors. Keep syscall and OS
   cause, but never render the path or arbitrary exception text. *)
let safe_exception = function
  | Unix.Unix_error (error, operation, _) ->
    Printf.sprintf "operation=%s os=%s" operation (Unix.error_message error)
  | Eio.Io (Eio.Fs.E error, _) ->
    (match error with
     | Eio.Fs.Permission_denied _ -> "permission_denied"
     | Eio.Fs.Not_found _ -> "not_found"
     | Eio.Fs.Already_exists _ -> "already_exists"
     | Eio.Fs.File_too_large -> "file_too_large"
     | Eio.Fs.Not_native _ -> "not_native")
  | Eio.Io _ -> "io_error"
  | Sys_error _ -> "system_io_error"
  | _ -> "other_error"

let read_operation = function
  | Fs_compat.Inspect_parent -> "inspect_parent"
  | Inspect_path -> "inspect_path"
  | Open_path -> "open"
  | Inspect_descriptor -> "inspect_descriptor"
  | Read_contents -> "read"
  | Close_descriptor -> "close"

let read_failure (error : Fs_compat.owned_regular_file_read_error) =
  let primary = match error.failure with
    | Ownership_boundary_rejected _ -> "ownership_boundary_rejected"
    | Path_is_not_regular_file {kind; _} -> "not_regular=" ^ Fs_compat.file_kind_to_string kind
    | Filesystem_identity_changed _ -> "identity_changed"
    | Owned_path_owner_mismatch _ -> "owner_mismatch"
    | Owned_path_writable_by_others _ -> "writable_by_others"
    | Owned_file_operation_failed {operation; cause; _} ->
      Printf.sprintf "stage=%s %s" (read_operation operation) (safe_exception cause) in
  match error.close_failure with
  | None -> primary
  | Some cause -> primary ^ "; close=" ^ safe_exception cause

let write_failure (error : Fs_compat.capability_write_error) =
  let primary = match error.primary_failure with
    | Write_primary_failure {stage; cause} ->
      let reason = match cause with
        | Invalid_recovery_target _ -> "invalid_recovery_target"
        | Mutation_contended -> "mutation_contended"
        | Target_already_exists -> "target_already_exists"
        | Posix_descriptor_unavailable -> "descriptor_unavailable"
        | Unexpected_resource_kind _ -> "unexpected_resource_kind"
        | Resource_identity_unavailable -> "identity_unavailable"
        | Resource_identity_changed -> "identity_changed"
        | Payload_write_failed {exception_; _} | Operation_failed {exception_; _} ->
          safe_exception exception_ in
      Printf.sprintf "stage=%s %s" (Fs_compat.capability_write_stage_to_string stage) reason
    | Recovery_primary_failure failure ->
      Printf.sprintf "recovery_phase=%s recovery_effect=%s"
        (Fs_compat.capability_recovery_failure_phase failure |> Fs_compat.capability_recovery_phase_to_string)
        (Fs_compat.capability_recovery_failure_effect failure |> Fs_compat.capability_recovery_effect_to_string)
    | Recovery_access_primary_failure _ -> "recovery_access_unavailable" in
  Printf.sprintf "operation=%s target_effect=%s %s cleanup_failures=%d"
    (Fs_compat.capability_write_operation_to_string error.operation)
    (Fs_compat.capability_write_target_effect_to_string error.target_effect)
    primary (List.length error.cleanup_failures)

let rec error_message = function
  | Invalid_base_path _ -> "microvm shim base path is invalid"
  | Not_initialized -> "microvm shim startup initialization has not run"
  | Initialization_conflict -> "microvm shim startup payload PATH differs from this process initialization"
  | Initialization_failed (Startup_shim_missing _)
  | Verification_failed (Guest_shim_missing _) ->
    "microvm_shim_missing: install the architecture-matched guest shim for this base"
  | Verification_failed (Sidecar_rejected _) -> "microvm shim sidecar verification failed; check the installed binary and sidecar"
  | Verification_invalidated -> "microvm shim guest verification was invalidated by guest replacement"
  | Config_unavailable Config_missing ->
    "microvm_shim_config_missing: the host shim config disappeared during recovery"
  | Config_unavailable Recovery_context_unavailable ->
    "microvm_shim_recovery_context_unavailable: the current server filesystem is unavailable"
  | Config_unavailable (Config_not_canonical | Config_owner_or_mode_refused) ->
    "microvm_shim_config_conflict: the existing host shim config is not the expected safe config; it was preserved"
  | Config_unavailable (Config_inspection_failed error) ->
    "microvm_shim_config_unreadable: " ^ read_failure error
  | Config_unavailable (Recovery_sync_failed error) ->
    "microvm_shim_config_sync_failed: " ^ read_failure error
  | Config_unavailable (Recovery_publication_failed error) ->
    "microvm_shim_config_publication_failed: " ^ write_failure error
  | Config_unavailable (Recovery_lane_release_failed {primary; release_failure}) ->
    "microvm_shim_config_recovery_lane_release_failed: "
    ^ Fs_compat.Publication_recovery.safe_lane_release_failure release_failure
    ^ (match primary with None -> "" | Some error -> "; primary=" ^ error_message error)
  | Config_unavailable (Recovery_io_failed error) ->
    "microvm_shim_config_recovery_io_failed: " ^ safe_exception error
  | Config_unavailable (Recovery_registry_failed error) ->
    "microvm_shim_config_recovery_registry_failed: "
    ^ Fs_compat.Publication_recovery.safe_registry_error error
  | Config_unavailable (Recovery_lane_failed error) ->
    "microvm_shim_config_recovery_lane_failed: "
    ^ Fs_compat.Publication_recovery.safe_lane_open_error error
  | Config_unavailable (Recovery_target_invalid _) -> "microvm_shim_config_recovery_target_invalid"

open Result.Syntax

let protect_work f =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> f ()
  | Fs_compat.Eio_fiber -> Eio.Cancel.protect f

let base_key ~base_path =
  let* base = Config_dir_resolver.canonical_base_path base_path
    |> Result.map_error (fun error -> Invalid_base_path error) in
  Ok (Eio_guard.run_in_systhread ~label:"microvm-shim-base-identity"
    (fun () -> Fs_compat.realpath_lenient base))

type initialization =
  { payload_path : string
  ; outcome : (unit, error) result option Atomic.t
  ; work : (unit, error) result Eio.Lazy.t
  ; config_lock : Eio.Mutex.t
  ; recovery_required : bool ref
  }

let initializations : (string * initialization) list Atomic.t = Atomic.make []

let check_startup_binary ~base =
  Eio_guard.run_in_systhread ~label:"microvm-shim-startup-binary" (fun () ->
    let binary = Filename.concat
        (Config_dir_resolver.microvm_shim_dir ~base_path:base) Shim.shim_binary_name in
    match Unix.access binary [Unix.X_OK] with
    | exception Unix.Unix_error (error, _, _) ->
      Error (Initialization_failed (Startup_shim_missing error))
    | () -> Ok ())

(* Startup replacement and missing-file creation use the same durable owner.
   A fresh registry is opened for each attempted publication: a cached ready
   registry cannot discover an obligation created by a failed attempt. *)
let with_config_lane ~fs ~base f =
  let dir = Config_dir_resolver.microvm_shim_dir ~base_path:base in
  let registry_root = Config_dir_resolver.masc_root ~base_path:base in
  try
    Eio.Switch.run @@ fun sw ->
    Eio.Path.with_open_dir Eio.Path.(fs / dir) (fun parent ->
      let stat = Eio.Path.stat ~follow:true parent in
      let* target = Fs_compat.capability_publication_target
          ~allowed_root_path:dir ~allowed_root_device:stat.dev ~allowed_root_inode:stat.ino
          ~parent_components:[] ~target_leaf:Shim.shim_config_name ~permissions:0o600
        |> Result.map_error (fun error -> Config_unavailable (Recovery_target_invalid error)) in
      let* registry = Fs_compat.Publication_recovery.open_namespaced_registry ~sw ~fs
          ~registry_root:Eio.Path.(fs / registry_root) ~namespace:"microvm-shim-recovery"
        |> Result.map_error (fun error -> Config_unavailable (Recovery_registry_failed error)) in
      match Fs_compat.Publication_recovery.with_lane ~registry ~owner:"microvm-shim-config"
          (fun recovery -> f ~sw ~parent ~target ~recovery) with
      | Error error -> Error (Config_unavailable (Recovery_lane_failed error))
      | Ok (Fs_compat.Publication_recovery.Lane_released result) -> result
      | Ok (Fs_compat.Publication_recovery.Lane_release_failed {value; release_failure}) ->
        let primary = match value with Ok () -> None | Error error -> Some error in
        Error (Config_unavailable (Recovery_lane_release_failed {primary; release_failure})))
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Invalid_argument _) as error ->
    Error (Config_unavailable (Recovery_io_failed error))

type config_observation = Config_absent | Config_canonical

let inspect_config ~base ~payload_path =
  let dir = Config_dir_resolver.microvm_shim_dir ~base_path:base in
  let path = Filename.concat dir Shim.shim_config_name in
  let expected = Shim.shim_config_content ~payload_path in
  let* observed = Eio_guard.run_in_systhread ~label:"microvm-shim-config-inspect" (fun () ->
      Fs_compat.load_owned_regular_file_range ~ownership_root:dir ~offset:0
        ~max_bytes:(String.length expected + 1) path)
    |> Result.map_error (fun error -> Config_unavailable (Config_inspection_failed error)) in
  match observed with
  | None -> Ok Config_absent
  | Some {content; snapshot} ->
    if snapshot.owner_uid <> 0 && snapshot.owner_uid <> Unix.geteuid ()
       || snapshot.permissions land 0o022 <> 0
    then Error (Config_unavailable Config_owner_or_mode_refused)
    else if snapshot.file_size <> String.length expected || not (String.equal content expected)
    then Error (Config_unavailable Config_not_canonical)
    else Ok Config_canonical

let competing_create (error : Fs_compat.capability_write_error) =
  match error with
  | {target_effect = Target_unchanged; cleanup_failures = [];
     primary_failure = Write_primary_failure {cause = Target_already_exists; _}; _} -> true
  | {target_effect = Target_unchanged; cleanup_failures = [];
     primary_failure = Write_primary_failure
       {stage = Publish_exclusive;
        cause = Operation_failed {exception_ = Unix.Unix_error (Unix.EEXIST, _, _); _}}; _} -> true
  | _ -> false

let same_config_stat (left : Eio.File.Stat.t) (right : Eio.File.Stat.t) =
  left.dev = right.dev && left.ino = right.ino && left.kind = right.kind
  && left.uid = right.uid && left.gid = right.gid && left.perm = right.perm
  && left.nlink = right.nlink && left.size = right.size
  && left.mtime = right.mtime && left.ctime = right.ctime

(* Reconciliation can preserve an uncertain publication without proving the
   target's directory sync. Read and sync the same owned descriptor, keeping
   the byte comparison bound to its snapshot throughout. *)
let sync_canonical_config ~sw ~parent ~payload_path =
  let* reader = Fs_compat.open_owned_reader ~sw ~parent ~leaf:Shim.shim_config_name
    |> Result.map_error (fun error -> Config_unavailable (Recovery_sync_failed error)) in
  let before = Fs_compat.owned_reader_stat reader in
  let expected = Shim.shim_config_content ~payload_path in
  let content = Fs_compat.owned_reader_pread reader ~offset:0L ~length:(String.length expected + 1) in
  let after_read = Fs_compat.owned_reader_stat reader in
  if not (same_config_stat before after_read) || not (String.equal content expected)
  then Error (Config_unavailable Config_not_canonical)
  else
    let* () = Fs_compat.sync_owned_reader ~parent ~leaf:Shim.shim_config_name reader
      |> Result.map_error (fun error -> Config_unavailable (Recovery_sync_failed error)) in
    let after_sync = Fs_compat.owned_reader_stat reader in
    if same_config_stat before after_sync then Ok ()
    else Error (Config_unavailable Config_not_canonical)

let ensure_config_in_lane ~base ~payload_path ~sw ~parent ~target ~recovery =
  let* observed = inspect_config ~base ~payload_path in
  match observed with
  | Config_canonical -> sync_canonical_config ~sw ~parent ~payload_path
  | Config_absent ->
    let expected = Shim.shim_config_content ~payload_path in
    let publication = Fs_compat.create_capability_file_exclusive
        ~recovery ~parent ~target expected in
    let* () = match publication with
      | Ok () -> Ok ()
      | Error error when competing_create error -> Ok ()
      | Error error -> Error (Config_unavailable (Recovery_publication_failed error)) in
    let* observed = inspect_config ~base ~payload_path in
    (match observed with
     | Config_canonical -> sync_canonical_config ~sw ~parent ~payload_path
     | Config_absent -> Error (Config_unavailable Config_missing))

(* The caller holds [config_lock]. Existing unexpected files are never
   replaced during recovery. A failed publication requires a fresh lane
   before even an apparently matching target can be admitted. *)
let ensure_config_locked entry ~fs ~base =
  let recover () =
    entry.recovery_required := true;
    let result = with_config_lane ~fs ~base
        (ensure_config_in_lane ~base ~payload_path:entry.payload_path) in
    (match result with Ok () -> entry.recovery_required := false | Error _ -> ());
    result in
  if !(entry.recovery_required) then recover ()
  else
    let* observed = inspect_config ~base ~payload_path:entry.payload_path in
    match observed with Config_canonical -> Ok () | Config_absent -> recover ()

let initialize_files ~fs ~base ~payload_path =
  let* () = check_startup_binary ~base in
  with_config_lane ~fs ~base (fun ~sw:_ ~parent ~target ~recovery ->
    Fs_compat.replace_capability_file ~recovery ~parent ~target
      (Shim.shim_config_content ~payload_path)
    |> Result.map_error (fun error -> Config_unavailable (Recovery_publication_failed error)))

let new_initialization ~fs ~base ~payload_path =
  let outcome = Atomic.make None in
  let config_lock = Eio.Mutex.create () in
  let recovery_required = ref true in
  let work = Eio.Lazy.from_fun ~cancel:`Record (fun () ->
    protect_work (fun () ->
      Eio.Mutex.use_rw ~protect:true config_lock (fun () ->
        let result = initialize_files ~fs ~base ~payload_path in
        (match result with Ok () -> recovery_required := false | Error _ -> ());
        Atomic.set outcome (Some result);
        result))) in
  {payload_path; outcome; work; config_lock; recovery_required}

let recover_initialization entry ~fs ~base =
  Eio.Mutex.use_rw ~protect:true entry.config_lock (fun () ->
    match Atomic.get entry.outcome with
    | Some (Ok ()) -> Ok ()
    | None -> Error Not_initialized
    | Some (Error _) ->
      let* () = check_startup_binary ~base in
      let* () = ensure_config_locked entry ~fs ~base in
      Atomic.set entry.outcome (Some (Ok ()));
      Ok ())

let initialize ~fs ~base_path ~payload_path =
  Eio_guard.check_if_ready ();
  let* base = base_key ~base_path in
  let candidate = new_initialization ~fs ~base ~payload_path in
  let rec select () =
    let observed = Atomic.get initializations in
    match List.assoc_opt base observed with
    | Some entry when not (String.equal entry.payload_path payload_path) -> Error Initialization_conflict
    | Some entry -> Ok entry
    | None ->
      if Atomic.compare_and_set initializations observed ((base, candidate) :: observed)
      then Ok candidate else select () in
  let* entry = select () in
  let result = match Atomic.get entry.outcome with
    | None -> Eio.Lazy.force entry.work
    | Some (Ok ()) -> Ok ()
    | Some (Error _) -> recover_initialization entry ~fs ~base in
  Eio_guard.check_if_ready ();
  result

type key = string * Keeper_microvm_backend.t * string
type verification = { token : unit ref; work : (unit, error) result Eio.Lazy.t }
let verifications : (key * verification) list Atomic.t = Atomic.make []

let same_key (base, backend, guest) (other_base, other_backend, other_guest) =
  String.equal base other_base && backend = other_backend && String.equal guest other_guest

let current_token key token =
  List.exists (fun (candidate, entry) -> same_key key candidate && entry.token == token)
    (Atomic.get verifications)

let rec retire key token =
  let observed = Atomic.get verifications in
  let updated = List.filter (fun (candidate, entry) ->
    not (same_key key candidate && entry.token == token)) observed in
  if not (Atomic.compare_and_set verifications observed updated) then retire key token

let verify_files ~base =
  let dir = Config_dir_resolver.microvm_shim_dir ~base_path:base in
  let* () = Eio_guard.run_in_systhread ~label:"microvm-shim-executable" (fun () ->
    match Unix.access (Filename.concat dir Shim.shim_binary_name) [Unix.X_OK] with
    | () -> Ok ()
    | exception Unix.Unix_error (error, _, _) -> Error (Verification_failed (Guest_shim_missing error))) in
  let* provenance = Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
    Eio_guard.run_in_systhread ~label:"microvm-shim-sidecar" (fun () -> Shim.verify_shim_sidecar ~dir))
    |> Result.map_error (fun detail -> Verification_failed (Sidecar_rejected detail)) in
  (match provenance with
   | Shim.Shim_verified {sha256} ->
     Log.Keeper.info "microvm guest shim verified against its sidecar: sha256 %s" sha256
   | Shim.Shim_unverified ->
     Log.Keeper.info "microvm guest shim has no sidecar; running a hand-built shim unverified");
  Ok ()

let new_verification key =
  let base, _, _ = key in
  let token = ref () in
  let work = Eio.Lazy.from_fun ~cancel:`Record (fun () ->
    protect_work (fun () ->
      match verify_files ~base with
      | Ok () as result -> result
      | Error _ as result -> retire key token; result
      | exception error ->
        let backtrace = Printexc.get_raw_backtrace () in
        retire key token;
        Printexc.raise_with_backtrace error backtrace)) in
  {token; work}

let current_fs () =
  match Fs_compat.execution_context (), Fs_compat.get_fs_opt () with
  | Fs_compat.Eio_fiber, Some fs -> Ok fs
  | Fs_compat.Non_eio, _ | Fs_compat.Eio_fiber, None ->
    Error (Config_unavailable Recovery_context_unavailable)

let ensure_entry entry ~fs ~base =
  let* () = match Atomic.get entry.outcome with
    | None -> Eio.Lazy.force entry.work
    | Some (Ok ()) -> Ok ()
    | Some (Error _) -> recover_initialization entry ~fs ~base in
  Eio.Mutex.use_rw ~protect:true entry.config_lock (fun () ->
    ensure_config_locked entry ~fs ~base)

let ensure_config ~fs ~base_path =
  Eio_guard.check_if_ready ();
  let* base = base_key ~base_path in
  let* entry = match List.assoc_opt base (Atomic.get initializations) with
    | None -> Error Not_initialized
    | Some entry -> Ok entry in
  let result = ensure_entry entry ~fs ~base in
  Eio_guard.check_if_ready ();
  result

let verify ~fs ~base_path ~backend ~guest_name =
  Eio_guard.check_if_ready ();
  let* base = base_key ~base_path in
  let* initialization = match List.assoc_opt base (Atomic.get initializations) with
    | None -> Error Not_initialized
    | Some entry -> Ok entry in
  let readiness = ensure_entry initialization ~fs ~base in
  Eio_guard.check_if_ready ();
  let* () = readiness in
  let key = base, backend, guest_name in
  let candidate = new_verification key in
  let rec select () =
    let observed = Atomic.get verifications in
    match List.find_opt (fun (existing, _) -> same_key key existing) observed with
    | Some (_, entry) -> entry
    | None ->
      if Atomic.compare_and_set verifications observed ((key, candidate) :: observed)
      then candidate else select () in
  let entry = select () in
  let result = Eio.Lazy.force entry.work in
  Eio_guard.check_if_ready ();
  let* () = result in
  if current_token key entry.token then Ok () else Error Verification_invalidated

let rec forget ~backend ~guest_name =
  let observed = Atomic.get verifications in
  let updated = List.filter (fun ((_, other_backend, other_guest), _) ->
    not (backend = other_backend && String.equal guest_name other_guest)) observed in
  if not (Atomic.compare_and_set verifications observed updated)
  then forget ~backend ~guest_name
