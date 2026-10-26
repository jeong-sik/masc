module Shim = Keeper_sandbox_microvm

type initialization_failure =
  | Startup_shim_missing of Unix.error
  | Config_write_failed of Fs_compat.atomic_replace_failure

type verification_failure =
  | Guest_shim_missing of Unix.error
  | Sidecar_rejected of string

type error =
  | Invalid_base_path of Config_dir_resolver.canonical_base_path_error
  | Not_initialized
  | Initialization_conflict
  | Initialization_failed of initialization_failure
  | Verification_failed of verification_failure
  | Verification_invalidated

let error_message = function
  | Invalid_base_path _ -> "microvm shim base path is invalid"
  | Not_initialized -> "microvm shim startup initialization has not run"
  | Initialization_conflict -> "microvm shim startup payload PATH differs from this process initialization"
  | Initialization_failed (Startup_shim_missing _)
  | Verification_failed (Guest_shim_missing _) ->
    "microvm_shim_missing: install the architecture-matched guest shim for this base"
  | Initialization_failed (Config_write_failed _) -> "microvm_shim_config_unwritable: startup config publication failed"
  | Verification_failed (Sidecar_rejected _) -> "microvm shim sidecar verification failed; check the installed binary and sidecar"
  | Verification_invalidated -> "microvm shim guest verification was invalidated by guest replacement"

let ( let* ) = Result.bind

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
  }

let initializations : (string * initialization) list Atomic.t = Atomic.make []

let initialize_files ~base ~payload_path =
  Eio_guard.run_in_systhread ~label:"microvm-shim-startup-config" (fun () ->
    let dir = Config_dir_resolver.microvm_shim_dir ~base_path:base in
    let binary = Filename.concat dir Shim.shim_binary_name in
    match Unix.access binary [Unix.X_OK] with
    | exception Unix.Unix_error (error, _, _) ->
      Error (Initialization_failed (Startup_shim_missing error))
    | () ->
      let config = Filename.concat dir Shim.shim_config_name in
      Fs_compat.write_file_atomic_strict_staged_blocking config
        ~write:(fun output -> output_string output (Shim.shim_config_content ~payload_path))
      |> Result.map_error (fun error -> Initialization_failed (Config_write_failed error)))

let new_initialization ~base ~payload_path =
  let outcome = Atomic.make None in
  let work = Eio.Lazy.from_fun ~cancel:`Record (fun () ->
    protect_work (fun () ->
      let result = initialize_files ~base ~payload_path in
      Atomic.set outcome (Some result);
      result)) in
  {payload_path; outcome; work}

let initialize ~base_path ~payload_path =
  Eio_guard.check_if_ready ();
  let* base = base_key ~base_path in
  let candidate = new_initialization ~base ~payload_path in
  let rec select () =
    let observed = Atomic.get initializations in
    match List.assoc_opt base observed with
    | Some entry when not (String.equal entry.payload_path payload_path) -> Error Initialization_conflict
    | Some entry ->
      (match Atomic.get entry.outcome with
       | None | Some (Ok ()) -> Ok entry
       | Some (Error _) ->
         let updated = (base, candidate) :: List.remove_assoc base observed in
         if Atomic.compare_and_set initializations observed updated then Ok candidate
         else select ())
    | None ->
      if Atomic.compare_and_set initializations observed ((base, candidate) :: observed)
      then Ok candidate else select () in
  let* entry = select () in
  let result = Eio.Lazy.force entry.work in
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
  let* provenance = Executor_pool_ref.submit_or_inline (fun () ->
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

let verify ~base_path ~backend ~guest_name =
  Eio_guard.check_if_ready ();
  let* base = base_key ~base_path in
  let initialized = match List.assoc_opt base (Atomic.get initializations) with
    | None -> Error Not_initialized
    | Some entry -> Eio.Lazy.force entry.work in
  Eio_guard.check_if_ready ();
  let* () = initialized in
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
