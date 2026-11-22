let claims_image = "base"

let default_timeout_sec () =
  Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Env_config_sandbox.Shell_timeout.Io ()
;;

let resolve_claims_image ~base_path image =
  if String.equal image ""
  then Ok None
  else (
    match Keeper_sandbox_image_catalog.name_error ~field:"image" image with
    | None ->
      (match
         Keeper_sandbox_image_resolver.resolve_in_workspace
           ~base_path
           ~store:(Keeper_sandbox_image_catalog.Microvm Keeper_microvm_backend.Apple_container)
           (Some image)
       with
       | Ok pinned -> Ok (Some pinned.Keeper_sandbox_image_catalog.reference)
       | Error error -> Error (Keeper_sandbox_image_resolver.error_to_string error))
    | Some _ ->
      if Keeper_sandbox_image_catalog.is_reference image
      then Ok (Some image)
      else
        Error
          (Printf.sprintf "%S is neither a catalog name nor a repository:tag reference" image))
;;

type ready = Apple_container_answered

let apple_container_ready () =
  let run = Sandbox_readiness.system_runner in
  match
    Sandbox_readiness.apple_container_service ~host:(Sandbox_readiness.detect_host ~run) ~run
  with
  | Sandbox_readiness.Service_ready -> Ok Apple_container_answered
  | ( Sandbox_readiness.Missing_prerequisite _ | Sandbox_readiness.Unsupported_host _
    | Sandbox_readiness.Unsupported_capability _ | Sandbox_readiness.Probe_failed _
    | Sandbox_readiness.Needs_configuration _ ) as service ->
    Error (Sandbox_readiness.state_message service)
;;

(* The same boundary every keeper CLI spawn crosses: the environment is
   scrubbed of keeper-secret keys and the descriptor is accounted, so neither
   the operator tool nor the periodic report leaks what a keeper lane would
   not see. *)
let run_cli ~timeout_sec argv =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_with_status_split
      ~timeout_sec
      ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
      ~cwd:(Config_dir_resolver.current_working_dir ())
      argv)
;;

let run Apple_container_answered ~base_path ~claims_image ~timeout_sec ~request =
  let module Declarations = Keeper_microvm_declared_guests in
  let execute () =
    match Declarations.read ~base_path with
    | Error unavailable ->
      Error
        (Printf.sprintf
           "cannot read keeper declarations for volume GC: %s"
           (Declarations.unavailable_message unavailable))
    | Ok declarations ->
      (match Declarations.protected_keeper_names declarations with
       | None ->
         Error
           "keeper declaration roster has unreadable declarations; preserving volumes"
       | Some protected_names ->
         let registered_keeper name = List.exists (String.equal name) protected_names in
         let revalidate () =
           Declarations.revalidate declarations
           |> Result.map_error Declarations.unavailable_message
         in
         let workspace_hash = Keeper_sandbox_microvm.base_path_volume_hash ~base_path in
         Keeper_volume_gc.apple_keeper_volume_gc_for_workspace
           ~workspace_hash
           ~revalidate
           ~run:run_cli
           ~timeout_sec
           ~registered_keeper
           ~claims_image
           ~request
           ())
  in
  match request with
  | Keeper_volume_gc.Report_only -> execute ()
  | Keeper_volume_gc.Reclaim_named _ ->
    Keeper_turn_sandbox_runtime_registry.with_microvm_inventory_lock execute
;;
