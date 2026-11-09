open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_turn_sandbox_runtime_registry
include Keeper_turn_sandbox_runtime_work_root
include Keeper_turn_sandbox_runtime_boot
include Keeper_turn_sandbox_runtime_record
include Keeper_turn_sandbox_runtime_run_argv
include Keeper_turn_sandbox_runtime_container
include Keeper_turn_sandbox_runtime_work_volume
include Keeper_turn_sandbox_runtime_start_failure
include Keeper_turn_sandbox_runtime_process_bound
include Keeper_turn_sandbox_runtime_remote_endpoint

type apple_guest_observation =
  | Apple_absent
  | Apple_stopped of Keeper_microvm_boot_plan.reading
  | Apple_running of Keeper_microvm_boot_plan.reading

let read_apple_guest ~timeout_sec ~container_name =
  let backend = Keeper_microvm_backend.Apple_container in
  let unanswered detail =
    match Keeper_microvm_guest_inventory.read ~backend ~guest_name:container_name ~timeout_sec with
    | Ok Keeper_microvm_guest_inventory.Absent ->
      forget_microvm_guest_state ~backend ~container_name;
      Ok Apple_absent
    | Ok Keeper_microvm_guest_inventory.Present -> Error (Guest_state_unreadable detail)
    | Error error -> Error (Guest_state_unreadable (Keeper_microvm_guest_inventory.error_message error)) in
  match Keeper_microvm_cli_output.read ~timeout_sec
      ~argv:(Keeper_sandbox_microvm.inspect_argv_for backend ~container_name) with
  | Error error -> unanswered (Keeper_microvm_cli_output.error_message error)
  | Ok (Unix.WEXITED 0, stdout) ->
    (match Keeper_sandbox_microvm.apple_guest_facts ~container_name stdout with
     | Keeper_microvm_boot_plan.Unreadable detail ->
       Error (Guest_state_unreadable detail)
     | Keeper_microvm_boot_plan.Facts _ as reading ->
       match Keeper_sandbox_microvm.running_of_inspect_json_for backend stdout with
       | Ok false -> Ok (Apple_stopped reading)
       | Ok true -> Ok (Apple_running reading)
       | Error _ -> Error (Guest_state_unreadable "runtime inspect did not report a valid guest state"))
  | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _) ->
    unanswered "runtime inspect did not complete successfully"

(* Guest names contain only a shortened workspace hash. A name match is not
   enough to use or remove an observed guest: compare the full stable labels.
   The runtime offers no conditional stop/delete by this observation, so a
   later replacement is still outside this check's authority. *)
let check_apple_guest_scope ~base_path ~keeper_name ~network_mode ~container_name = function
  | Keeper_microvm_boot_plan.Unreadable detail ->
    Error ("microvm_guest_ownership_unverified: " ^ detail)
  | Keeper_microvm_boot_plan.Facts facts ->
    let expected = Keeper_sandbox_runtime_setup.stable_labels
        ~base_path ~keeper_name
        ~container_kind:Keeper_sandbox_microvm.keeper_vm_container_kind
        ~network_label:(Keeper_types_profile_sandbox.network_mode_to_string network_mode)
      @ [ Keeper_sandbox_microvm.microvm_backend_label_key,
          Keeper_microvm_backend.to_string Keeper_microvm_backend.Apple_container ] in
    if List.for_all (fun (key, value) -> List.assoc_opt key facts.labels = Some value) expected
    then Ok ()
    else Error (Printf.sprintf
        "microvm_guest_ownership_unverified: guest %s has missing or different workspace, keeper, kind, network or backend labels"
        container_name)
;;

let check_apple_guest_observation ~base_path ~keeper_name ~network_mode ~container_name = function
  | Apple_absent -> Ok ()
  | Apple_stopped reading | Apple_running reading ->
    check_apple_guest_scope ~base_path ~keeper_name ~network_mode ~container_name reading
;;

let stop_owned_apple_guest ~base_path ~keeper_name ~network_mode ~timeout_sec ~container_name =
  let open Result.Syntax in
  let* observation = read_apple_guest ~timeout_sec ~container_name
    |> Result.map_error microvm_start_failure_message in
  match observation with
  | Apple_absent -> Ok ()
  | Apple_stopped reading | Apple_running reading ->
    let* () = check_apple_guest_scope ~base_path ~keeper_name ~network_mode ~container_name reading in
    stop_and_delete_microvm_container ~timeout_sec
      ~backend:Keeper_microvm_backend.Apple_container container_name
;;

(* Observe every mode before a caller starts deleting any of them. Each
   effect still re-observes its own name; neither observation is a fence. *)
let check_apple_guest_modes ~base_path ~keeper_name ~timeout_sec =
  let open Result.Syntax in
  List.fold_left (fun result network_mode ->
    let* () = result in
    let container_name = Keeper_sandbox_container_name.make
        (Keeper_sandbox_container_name.Micro_vm_persistent {base_path; keeper_name; network_mode})
      |> Keeper_sandbox_container_name.to_string in
    let* observation = read_apple_guest ~timeout_sec ~container_name
      |> Result.map_error microvm_start_failure_message in
    check_apple_guest_observation ~base_path ~keeper_name ~network_mode ~container_name observation)
    (Ok ()) Keeper_types_profile_sandbox.all_network_modes
;;

(* OCI Entrypoint belongs to the actual image configuration, not the caller's
   requested command or a prefix guessed from the guest's init process. Keep
   this read-only observation separate from the stable requested-plan digest. *)
let read_apple_image_command ~timeout_sec ~(plan : Keeper_microvm_boot_plan.t) reading =
  match reading with
  | Keeper_microvm_boot_plan.Unreadable detail -> Error detail
  | Keeper_microvm_boot_plan.Facts facts ->
    match Keeper_microvm_cli_output.read ~timeout_sec
        ~argv:(Keeper_sandbox_microvm.image_inspect_argv_for Keeper_microvm_backend.Apple_container
          ~image:plan.image) with
    | Error error -> Error (Keeper_microvm_cli_output.error_message error)
    | Ok (Unix.WEXITED 0, raw) ->
      Keeper_microvm_image_command.of_apple_inspect ~reference:plan.image
        ~identity:facts.image_identity raw
      |> Result.map_error Keeper_microvm_image_command.error_message
    | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _) ->
      Error "image inspect did not complete successfully"

(* A guest's environment is observed data, never the expected route. Read
   the current policy network without creating or repairing it at adoption. *)
let apple_policy_environment ~timeout_sec (t : t) =
  let open Result.Syntax in
  match t.network_mode with
  | Keeper_types_profile_sandbox.Network_none | Keeper_types_profile_sandbox.Network_inherit -> Ok []
  | Keeper_types_profile_sandbox.Network_policy ->
    match bound_egress_proxy_port t with
    | None -> Ok []
    | Some port ->
      let* argv = Keeper_sandbox_microvm.policy_network_inspect_argv_for
          Keeper_microvm_backend.Apple_container ~keeper_name:t.meta.name
        |> Result.map_error (fun detail -> Policy_network_unavailable detail) in
      let* status, stdout = Keeper_microvm_cli_output.read ~timeout_sec ~argv
        |> Result.map_error (fun error -> Policy_network_unavailable
            (Keeper_microvm_cli_output.error_message error)) in
      match status with
      | Unix.WEXITED 0 ->
        let* gateway = Keeper_sandbox_microvm.policy_network_gateway ~inspect:stdout
          |> Result.map_error (fun detail -> Policy_network_unavailable detail) in
        Ok (Egress_proxy_decision.client_env ~proxy_url:(Printf.sprintf "http://%s:%d" gateway port))
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
        Error (Policy_network_unavailable "policy network inspect did not complete successfully")

let with_apple_lifecycle_scope ~keeper_name ~unavailable callback =
  match Fs_compat.execution_context (), Fs_compat.get_fs_opt () with
  | Fs_compat.Eio_fiber, Some fs ->
    Keeper_microvm_lifecycle.with_keeper_scope microvm_lifecycle ~keeper_name
      (fun scope -> callback ~fs ~scope)
  | Fs_compat.Non_eio, _ | Fs_compat.Eio_fiber, None -> Error unavailable

let prepare_apple_first_handoff ~timeout_sec (t : t) snapshot ~container_name ~delivery =
  let open Result.Syntax in
  let backend = Keeper_microvm_backend.Apple_container in
  let* () = ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec
    |> Result.map_error (fun detail -> Adopted_guest_volume_unverified detail) in
  let* () = verify_microvm_shim ~base_path:t.config.base_path
      ~backend ~guest_name:container_name
    |> Result.map_error (fun error -> Guest_provisions_unavailable
        (Keeper_microvm_shim_readiness.error_message error)) in
  let* () = ensure_microvm_keeper_work_root ~timeout_sec t ~backend ~container_name
    |> Result.map_error (fun detail -> Adopted_guest_volume_unverified detail) in
  let entry = register_microvm_work_root ~base_path:t.config.base_path ~backend ~container_name in
  let generation = entry.generation in
  let mark_cleanup ~expected state =
    set_microvm_build_cleanup_state ~backend ~keeper_name:t.meta.name ~expected state in
  let effects () = register_microvm_work_effects ~backend ~keeper_name:t.meta.name in
  (match (effects ()).cleanup_state with
   | Build_cleanup_skipped_not_sent | Build_cleanup_confirmed
   | Build_cleanup_finished_incomplete | Build_cleanup_effect_unverified -> ()
   | Build_cleanup_available ->
     (* This reservation belongs to the shared work resource, independently
        of guest readiness. It can only be claimed once in this process. *)
     if mark_cleanup ~expected:Build_cleanup_available Build_cleanup_effect_unverified then (
       let container_config_dir = Keeper_github_identity.container_config_dir
           ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root:t.container_root)
           ~keeper_name:t.meta.name in
       let endpoint = build_microvm_endpoint ~config:t.config ~meta:t.meta
           ~container_root:t.container_root ~uid:t.uid ~gid:t.gid ~container_name
           ~identity_environment:(Keeper_microvm_github_identity.environment snapshot ~container_config_dir)
           ~delivery in
       let observed = match endpoint with
         | Error detail ->
           Log.Keeper.warn ~keeper_name:t.meta.name
             "first handoff build cleanup endpoint unavailable: %s" detail;
           Build_cleanup_skipped_not_sent
         | Ok endpoint ->
           let receipt = ref None in
           let run = Keeper_sandbox_remote.runner ~timeout_sec
               ~on_receipt:(fun observation ->
                 receipt := Some observation;
                 (* The runner publishes this even when cancellation raises
                    before dispatch. Consume the opportunity in that callback;
                    code after [run] will not run on the exception path. *)
                 match observation with
                 | Keeper_sandbox_remote.Execution_unavailable Request_not_sent ->
                   ignore (mark_cleanup ~expected:Build_cleanup_effect_unverified Build_cleanup_skipped_not_sent)
                 | Keeper_sandbox_remote.Execution_observed _
                 | Keeper_sandbox_remote.Execution_unavailable
                     (Transport_unavailable _ | Peer_receipt_missing
                     | Invalid_receipt _ | Shim_refused_without_receipt) -> ()) endpoint in
           let script = Keeper_sandbox_microvm.first_handoff_build_cleanup_script
               ~keeper_work_root:(Keeper_sandbox_microvm.keeper_work_root ~keeper_name:t.meta.name) in
           let outcome = run ~on_stdout_chunk:None ~on_stderr_chunk:None
               ~stdin_content:None ~env:[||] ~cwd:None ~argv:["/bin/sh"; "-eu"; "-c"; script] in
           microvm_build_cleanup_outcome outcome !receipt in
       ignore (mark_cleanup ~expected:Build_cleanup_effect_unverified observed)));
  (* A failed reservation or a readiness change never certifies completion.
     An unknown original rename can still race a later build, even without
     a second send. Keep mutation handoff unavailable until it is resolved. *)
  let* () = match (effects ()).cleanup_state with
    | Build_cleanup_effect_unverified | Build_cleanup_available ->
      Error (Build_cleanup_unresolved (microvm_build_cleanup_unresolved_message ~keeper_name:t.meta.name))
    | Build_cleanup_skipped_not_sent ->
      Log.Keeper.warn ~keeper_name:t.meta.name
        "microvm_build_cleanup_not_sent: cleanup is consumed for this work volume; later handoffs will preserve newly created build output";
      Ok ()
    | Build_cleanup_finished_incomplete ->
      Log.Keeper.warn ~keeper_name:t.meta.name
        "microvm_build_cleanup_incomplete: the shim confirmed a terminal result; preserve real build directories and continue without resending cleanup";
      Ok ()
    | Build_cleanup_confirmed -> Ok () in
  let* () = if complete_microvm_work_root ~base_path:t.config.base_path ~backend ~container_name generation
    then Ok () else Error (Adopted_guest_volume_unverified "microvm guest readiness changed during preparation") in
  (match microvm_work_root_entry ~base_path:t.config.base_path ~backend ~container_name with
   | None -> ()
   | Some entry ->
     match entry.build_links_state with
     | Build_links_prepared -> ()
     | Build_links_effect_unverified ->
       (* Target mkdir is idempotent. An earlier target-only failure must not
          strand this live generation; persistent symlink uncertainty stays
          in the shared resource and never gains replay permission here. *)
       if not (effects ()).links_unverified
          && set_microvm_build_links_state ~base_path:t.config.base_path ~backend
               ~container_name entry.generation ~expected:Build_links_effect_unverified
               Build_links_not_prepared
       then ensure_microvm_build_links ~timeout_sec t ~container_name ~generation:entry.generation
     | Build_links_not_prepared ->
       ensure_microvm_build_links ~timeout_sec t ~container_name ~generation:entry.generation);
  (match microvm_work_root_entry ~base_path:t.config.base_path ~backend ~container_name with
   | Some ready when ready.generation == generation ->
     microvm_build_links_admission ~base_path:t.config.base_path ~backend
       ~keeper_name:t.meta.name ~container_name
     |> Result.map_error (fun detail -> Guest_provisions_unavailable detail)
   | Some _ | None ->
     Error (Adopted_guest_volume_unverified "microvm guest readiness changed during build preparation"))

let start_apple_microvm_container ~fs ~scope ~timeout_sec (t : t) =
  let open Result.Syntax in
  let module Store = Keeper_microvm_github_identity in
  let module Plan = Keeper_microvm_boot_plan in
  let backend = Keeper_microvm_backend.Apple_container in
  let* () = microvm_build_cleanup_admission ~backend ~keeper_name:t.meta.name
    |> Result.map_error (fun detail -> Build_cleanup_unresolved detail) in
  let* image = t.image |> Result.map_error (fun error -> Image_unresolved error) in
  let* guest_size = Env_config_sandbox.Runtime.microvm_guest_size
      ~memory:t.meta.microvm_memory ~cpus:t.meta.microvm_cpus
    |> Result.map_error (fun detail -> Guest_size_invalid detail) in
  let container_name = keeper_vm_name t in
  let* observation = read_apple_guest ~timeout_sec ~container_name in
  let* () = check_apple_guest_observation ~base_path:t.config.base_path ~keeper_name:t.meta.name
      ~network_mode:t.network_mode ~container_name observation
    |> Result.map_error (fun detail -> Guest_ownership_unverified detail) in
  let* stored = match Store.load ~fs ~coordinator:microvm_lifecycle ~scope
      ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend ~network_mode:t.network_mode with
    | Error error as rejected ->
      (match Store.classify_load_error error with
       | Store.Observation_unavailable -> Error (Guest_identity_store_unavailable error)
       | Store.Rejected_snapshot -> Ok rejected)
    | Ok _ as observed -> Ok observed in
  let container_config_dir = Keeper_github_identity.container_config_dir
      ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root:t.container_root)
      ~keeper_name:t.meta.name in
  let* identity_environment = match stored with
    | Ok (Some snapshot) -> Ok (Store.environment snapshot ~container_config_dir)
    | Ok None | Error _ ->
      Keeper_github_identity.capture_tool_identity ~config:t.config ~keeper_name:t.meta.name
      |> Result.map (fun captured -> Keeper_github_identity.captured_environment captured
          ~keeper_name:t.meta.name ~container_config_dir)
      |> Result.map_error (fun detail -> Github_identity_invalid detail) in
  (* Observe optional config and stable workspace labels at the edge once.
     Comparison and a possible Boot retain this exact immutable request. *)
  let config_mount = Keeper_sandbox_runtime_setup.config_mount
      ~base_path:t.config.base_path ~container_root:t.container_root in
  let stable_labels = Keeper_sandbox_runtime_setup.stable_labels
      ~base_path:t.config.base_path ~keeper_name:t.meta.name
      ~container_kind:Keeper_sandbox_microvm.keeper_vm_container_kind
      ~network_label:(Keeper_types_profile_sandbox.network_mode_to_string t.network_mode) in
  let identity_host_dir = Store.host_path ~base_path:t.config.base_path
      ~keeper_name:t.meta.name ~backend ~network_mode:t.network_mode in
  let* delivery = microvm_delivery_for ~base_path:t.config.base_path ~keeper_name:t.meta.name
    |> Result.map_error (fun detail -> Delivery_unresolved detail) in
  let* plan = requested_apple_plan t ~delivery ~image ~guest_size ~identity_host_dir
      ~environment:identity_environment ~config_mount ~stable_labels in
  let* () = Plan.validate plan |> Result.map_error (fun errors -> Invalid_boot_plan errors) in
  let identity_reading = match stored with
    | Ok (Some _) -> Plan.Identity_readable
    | Ok None | Error _ -> Plan.Identity_unreadable in
  let adopt snapshot =
    let* () = prepare_apple_first_handoff ~timeout_sec t snapshot ~container_name ~delivery in
    bind_github_identity_snapshot t (Guest_identity snapshot);
    set_state t (Running {container_name});
    Ok container_name in
  let decision = match observation with
    | Apple_absent | Apple_stopped _ -> Ok `Boot
    | Apple_running reading ->
      let* policy_environment = match reading with
        | Plan.Unreadable _ -> Ok []
        | Plan.Facts facts when facts.plan_label <> Some (Plan.digest plan) -> Ok []
        | Plan.Facts _ -> apple_policy_environment ~timeout_sec t in
      let image_command = read_apple_image_command ~timeout_sec ~plan reading in
      match Plan.assess ~plan ~policy_environment ~identity_reading ~image_command reading with
      | Plan.Refuse refusal -> Error (Guest_facts_refused refusal)
      | Plan.Replace _ -> Ok `Boot
      | Plan.Matches_plan ->
        match delivery with
        | Keeper_types_profile_sandbox.Exec_per_request -> Ok `Adopt
        | Keeper_types_profile_sandbox.Agent_socket ->
          (* The plan matched, but the plan cannot see the agent: only its
             hello says it is there, answers, and speaks this relay (RFC
             microvm-guest-agent-over-socket 3.6). One that does not is
             replaced rather than adopted. *)
          (match
             Keeper_microvm_agent_socket.check_agent
               ~host_socket:(Keeper_microvm_agent_socket.host_path
                               ~base_path:t.config.base_path ~guest_name:container_name)
               ~expected:{ Keeper_guest_socket.uid = t.uid; gid = t.gid }
               ~connect_budget_sec:(float_of_int Keeper_sandbox_microvm.remote_connect_timeout_sec)
               ~budget_sec:timeout_sec
           with
           | Keeper_microvm_agent_socket.Agent_answered -> Ok `Adopt
           | Keeper_microvm_agent_socket.Agent_unusable reason ->
             Log.Keeper.info "microvm agent guest replaced instead of adopted keeper=%s name=%s: %s"
               t.meta.name container_name reason;
             Ok `Boot
           | Keeper_microvm_agent_socket.Check_unavailable detail -> Error (Agent_unchecked detail)) in
  let* decision = decision in
  match decision with
  | `Adopt ->
    (match stored with
     | Ok (Some snapshot) -> adopt snapshot
     | Ok None -> Error (Github_identity_invalid "validated guest identity is missing")
     | Error error -> Error (Guest_identity_store_unavailable error))
  | `Boot ->
    (* Refuse before stopping or replacing any existing guest when a legacy
       helper is present or its owner is unknown. Provisioning reads again
       after teardown; neither read fences another process between them. *)
    let* () = ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec
      |> Result.map_error (fun detail -> Guest_provisions_unavailable detail) in
    let* () = check_apple_guest_modes ~base_path:t.config.base_path
        ~keeper_name:t.meta.name ~timeout_sec
      |> Result.map_error (fun detail -> Unadoptable_guest_not_removed detail) in
    let* nameserver = microvm_boot_nameserver ~backend ~network_mode:t.network_mode
      |> Result.map_error (fun detail -> Network_unexpressible detail) in
    let* () = List.fold_left (fun previous network_mode ->
        let* () = previous in
        if network_mode = t.network_mode then Ok ()
        else
          let stale_name = microvm_container_name ~config:t.config ~keeper_name:t.meta.name ~network_mode in
          let* () = stop_owned_apple_guest ~base_path:t.config.base_path
              ~keeper_name:t.meta.name ~network_mode ~timeout_sec ~container_name:stale_name
            |> Result.map_error (fun detail -> Unadoptable_guest_not_removed detail) in
          Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle ~scope
            ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend ~network_mode ~timeout_sec
          |> Result.map (function
            | Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent -> ())
          |> Result.map_error (fun error -> Guest_identity_store_unavailable error))
        (Ok ()) Keeper_types_profile_sandbox.all_network_modes in
    let* () = match observation with
      | Apple_absent -> Ok ()
      | Apple_running _ | Apple_stopped _ ->
        stop_owned_apple_guest ~base_path:t.config.base_path ~keeper_name:t.meta.name
          ~network_mode:t.network_mode ~timeout_sec ~container_name
        |> Result.map_error (fun detail -> Unadoptable_guest_not_removed detail) in
    let* _removed = Store.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle ~scope
        ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend
        ~network_mode:t.network_mode ~timeout_sec
      |> Result.map_error (fun error -> Guest_identity_store_unavailable error) in
    let* captured = Keeper_github_identity.capture_tool_identity ~config:t.config ~keeper_name:t.meta.name
      |> Result.map_error (fun detail -> Github_identity_invalid detail) in
    let* snapshot = Store.publish_if_guest_absent ~fs ~coordinator:microvm_lifecycle ~scope
        ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend
        ~network_mode:t.network_mode ~timeout_sec captured
      |> Result.map_error (fun error -> Guest_identity_store_unavailable error) in
    let boot_environment = Store.environment snapshot ~container_config_dir in
    (* The plan's environment is this identity wiring plus what the agent
       hands its requests; only the wiring can have moved since. *)
    if boot_environment <> identity_environment then
      Error (Github_identity_invalid "identity wiring changed while preparing the guest; retry with a new request")
    else
      let* () = Keeper_sandbox_microvm.image_present_for backend ~name:t.meta.sandbox_image
          ~image ~timeout_sec |> Result.map_error (fun detail -> Guest_provisions_unavailable detail) in
      let* _provisions = microvm_guest_provisions t ~backend ~timeout_sec
        |> Result.map_error (fun detail -> Guest_provisions_unavailable detail) in
      let* gateway = ensure_policy_network backend ~keeper_name:t.meta.name t.network_mode
        |> Result.map_error (fun detail -> Policy_network_unavailable detail) in
      let policy_proxy = match gateway, bound_egress_proxy_port t with
        | Some gateway, Some port -> Some {Keeper_sandbox_microvm.gateway; port}
        | Some _, None | None, _ -> None in
      let* argv = Keeper_sandbox_microvm.apple_turn_start_argv ~container_name ~plan
          ~lifecycle_labels:(Keeper_sandbox_runtime_setup.lifecycle_labels ())
          ~dns:(Option.map Ipaddr.to_string nameserver) ~policy_proxy
        |> Result.map_error (function
          | Keeper_sandbox_microvm.Apple_invalid_boot_plan errors -> Invalid_boot_plan errors
          | Keeper_sandbox_microvm.Apple_network_unavailable detail -> Network_unexpressible detail
          | Keeper_sandbox_microvm.Apple_constraints_unexpressible refusals ->
            Constraints_unexpressible {backend; refusals}) in
      (* Last before the boot: a socket file left by a guest that did not end
         cleanly stops [container run] (RFC microvm-guest-agent-over-socket 3.6). *)
      let guest_presence () =
        Keeper_microvm_guest_inventory.read ~backend ~guest_name:container_name ~timeout_sec
        |> Result.map_error Keeper_microvm_guest_inventory.error_message in
      let* () = List.fold_left (fun previous {Plan.host_path; guest_path = _} ->
          let* () = previous in
          Keeper_microvm_agent_socket.prepare_host_socket ~guest_presence host_path
          |> Result.map_error (fun error -> Agent_socket_unavailable error))
          (Ok ()) plan.published_sockets in
      bind_github_identity_snapshot t (Guest_identity snapshot);
      let status, output = run_argv_with_status ~timeout_sec argv in
      let* postboot = read_apple_guest ~timeout_sec ~container_name in
      match postboot with
      | Apple_running reading ->
        let policy_environment = match policy_proxy with
          | None -> []
          | Some {gateway; port} -> Egress_proxy_decision.client_env
              ~proxy_url:(Printf.sprintf "http://%s:%d" gateway port) in
        let image_command = read_apple_image_command ~timeout_sec ~plan reading in
        (match Plan.assess ~plan ~policy_environment ~identity_reading:Plan.Identity_readable ~image_command reading with
         | Plan.Matches_plan -> adopt snapshot
         | Plan.Refuse refusal -> Error (Guest_facts_refused refusal)
         | Plan.Replace _ -> Error (Guest_facts_refused
             (Plan.Runtime_reports_other_than_asked [Plan.Plan_label])))
      | Apple_absent | Apple_stopped _ -> Error (Boot_command_failed {status; output})

let sweep_abandoned_microvm_guests
    ~base_path ~command_available ~timeout_sec ~is_pid_alive ~run_argv =
  let module Inventory = Keeper_microvm_guest_inventory in
  let module Declarations = Keeper_microvm_declared_guests in
  let backend = Keeper_microvm_backend.Apple_container in
  let outcomes, removed = with_microvm_inventory_lock (fun () ->
    let other = sweep_process_bound_microvm_guests ~base_path ~command_available
        ~timeout_sec ~is_pid_alive ~run_argv in
    if not (command_available (Keeper_microvm_backend.cli_name backend)) then other, []
    else
      let removed = ref [] in
      let failed = ref [] in
      let declarations = ref (Declarations.read ~base_path) in
      let inventory = Inventory.read_apple ~timeout_sec in
      (match inventory with
       | Error error ->
         failed := ["inventory", Inventory.error_message error]
       | Ok inventory ->
         (match !declarations with
          | Error error -> failed := ["declarations", Declarations.unavailable_message error]
          | Ok _ -> ());
         List.iter (fun row ->
           match Declarations.select ~base_path ~declarations:!declarations row with
           | Declarations.Preserve _ -> ()
           | Declarations.Delete candidate ->
             let current = match !declarations with
               | Error _ as error -> error
               | Ok observed -> Result.map (fun () -> observed) (Declarations.revalidate observed) in
             declarations := current;
             (match current with
              | Error error -> failed := (candidate.guest_name, Declarations.unavailable_message error) :: !failed
              | Ok _ ->
                let modes = List.filter (fun network_mode ->
                  let name = Keeper_sandbox_container_name.make
                      (Keeper_sandbox_container_name.Micro_vm_persistent
                         {base_path; keeper_name=candidate.keeper_name; network_mode})
                    |> Keeper_sandbox_container_name.to_string in
                  String.equal name candidate.guest_name) Keeper_types_profile_sandbox.all_network_modes in
                let observation = match modes with
                  | [network_mode] ->
                    Result.bind
                      (read_apple_guest ~timeout_sec ~container_name:candidate.guest_name
                       |> Result.map_error microvm_start_failure_message)
                      (fun observation ->
                        Result.map (fun () -> observation)
                          (check_apple_guest_observation ~base_path ~keeper_name:candidate.keeper_name
                             ~network_mode ~container_name:candidate.guest_name observation))
                  | [] | _ :: _ :: _ -> Error "guest name does not identify one network mode" in
                (match observation with
                 | Error detail -> failed := (candidate.guest_name, detail) :: !failed
                 | Ok observation ->
                   (* Inspect may wait on the provider. Recheck the same roster
                      after it returns and before any deletion or cleanup. This
                      is still an observation, not a fence against a writer. *)
                   let current = match !declarations with
                     | Error _ as error -> error
                     | Ok observed -> Result.map (fun () -> observed) (Declarations.revalidate observed) in
                   declarations := current;
                   (match current with
                    | Error error ->
                      failed := (candidate.guest_name, Declarations.unavailable_message error) :: !failed
                    | Ok _ ->
                   (* Delete is an effect attempt. Only a new actual complete
                      inventory can establish its postcondition. An already
                      absent name does not authorize a delete. *)
                   let deletion = match observation with
                     | Apple_absent -> None
                     | Apple_stopped _ | Apple_running _ ->
                       Some (Keeper_microvm_cli_output.read ~timeout_sec
                         ~argv:(Keeper_sandbox_microvm.delete_force_argv_for backend
                                  ~container_name:candidate.guest_name)) in
                   match Inventory.read ~backend ~guest_name:candidate.guest_name ~timeout_sec with
                   | Ok Inventory.Absent ->
                     forget_microvm_guest_state ~backend ~container_name:candidate.guest_name;
                     removed := candidate :: !removed
                   | Ok Inventory.Present ->
                     let detail = match deletion with
                       | None -> "guest appeared after absence observation"
                       | Some (Error error) -> Keeper_microvm_cli_output.error_message error
                       | Some (Ok (status, _)) -> "guest remains after deletion " ^ Keeper_sandbox_exec_failure.status_label status in
                     failed := (candidate.guest_name, detail) :: !failed
                   | Error error -> failed := (candidate.guest_name, Inventory.error_message error) :: !failed))))
           (Inventory.rows inventory));
      let removed = List.rev !removed in
      let outcome : Keeper_sandbox_microvm.sweep_outcome =
        {removed=List.map (fun (candidate : Declarations.candidate) -> candidate.guest_name) removed;
         failed=List.rev !failed} in
      (backend, outcome) :: other, removed) in
  (* Snapshot cleanup takes a fresh Keeper owner after inventory exclusion has
     ended. Reacquiring a Keeper inside that exclusion would deadlock. The store
     independently rereads actual absence; the earlier result is not a token. *)
  let cleanup_failures = List.concat_map (fun (candidate : Declarations.candidate) ->
    List.filter_map (fun network_mode ->
      let name = Keeper_sandbox_container_name.make
          (Keeper_sandbox_container_name.Micro_vm_persistent
             {base_path; keeper_name=candidate.keeper_name; network_mode})
        |> Keeper_sandbox_container_name.to_string in
      if not (String.equal name candidate.guest_name) then None
      else
        let result = with_apple_lifecycle_scope ~keeper_name:candidate.keeper_name
            ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
            (fun ~fs ~scope ->
              Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
                ~scope ~base_path ~keeper_name:candidate.keeper_name ~backend ~network_mode ~timeout_sec
              |> Result.map_error Keeper_microvm_github_identity.error_message) in
        match result with
        | Ok (Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent) -> None
        | Error detail -> Some (candidate.guest_name, detail))
      Keeper_types_profile_sandbox.all_network_modes) removed in
  List.map (fun (runtime, (outcome : Keeper_sandbox_microvm.sweep_outcome)) ->
    if runtime = backend then runtime, {outcome with failed=outcome.failed @ cleanup_failures}
    else runtime, outcome) outcomes

let start_microvm_container ?timeout_sec t =
  let result = match microvm_backend_of t with
    | Error detail -> Error (Backend_unresolved detail)
    | Ok Keeper_microvm_backend.Apple_container ->
      let timeout_sec = match timeout_sec with
        | Some seconds -> seconds
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
      with_apple_lifecycle_scope ~keeper_name:t.meta.name ~unavailable:Runtime_context_unavailable
        (fun ~fs ~scope -> start_apple_microvm_container ~fs ~scope ~timeout_sec t)
    | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
      with_microvm_lifecycle_lock ~keeper_name:t.meta.name ~operation:"start_adopt"
        (fun () -> start_process_bound_microvm_container ?timeout_sec t) in
  Result.map_error microvm_start_failure_cause result
;;

(* Shutdown finalization retains the typed backend through registry removal.
   A remote-SSH keeper owns no local container, while Docker and
   microVM names project to different runtimes and must not probe each other. *)
let teardown_keeper_sandbox_by_name
      ?timeout_sec
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(backend : Keeper_sandbox.backend)
      ?microvm_backend
      ()
  =
  let helper_timeout_sec =
    match timeout_sec with
    | Some seconds -> seconds
    | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()
  in
  let timeout_sec =
    Option.value
      timeout_sec
      ~default:
        (Env_config_sandbox.Shell_timeout.timeout_sec
           ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
           ())
  in
  match backend with
  | Keeper_sandbox.Remote_ssh -> Ok ()
  | Keeper_sandbox.Docker ->
    Keeper_sandbox_runtime.remove_persistent_containers
      ~keeper_name
      ~base_path:config.base_path
      ~timeout_sec
      ()
  | Keeper_sandbox.Micro_vm ->
    (* Teardown runs after the registry entry is gone, so there is no meta
       left to read the backend from. The caller passes the one the keeper
       declared; shutdown supplies it from the meta it still holds. Without
       it there is nothing to remove the guest with -- an assumed runtime
       would send `container delete --force` to a guest msb booted and
       report success while it kept running. *)
    (match microvm_backend with
     | None ->
       Error
         (Printf.sprintf
            "microvm_teardown_backend_unresolved: keeper %s's guest cannot be \
             removed without the runtime it was booted on; the caller passes it \
             from the keeper's meta"
            keeper_name)
     | Some microvm_backend ->
       (* Every mode's name, not the current one. The guest name carries the
          network mode so adopt cannot cross modes, and teardown runs after
          the registry entry is gone -- it does not know which mode the guest
          on disk was booted under. Removing only today's name would leave a
          guest from yesterday's mode running with nothing tracking it.

          A name with no guest behind it is not an error: [stop_and_delete]
          is idempotent for an absent guest, which is what makes sweeping the
          whole set cheap. *)
       let guests = List.map (fun network_mode ->
           network_mode, microvm_container_name ~config ~keeper_name ~network_mode)
           Keeper_types_profile_sandbox.all_network_modes in
       let perform stop_guest release_identity =
         let helper_observation = match microvm_backend with
           | Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata -> Ok ()
           | Keeper_microvm_backend.Apple_container ->
             ensure_apple_volume_helpers_absent ~keeper_name ~timeout_sec:helper_timeout_sec in
         let guest_cleanup = List.fold_left (fun previous (network_mode, guest_name) ->
             let current = Result.bind
                 (stop_guest ~network_mode ~guest_name)
                 (fun () -> release_identity ~network_mode ~guest_name) in
             match previous, current with
             | Ok (), result -> result
             | Error _, Ok () -> previous
             | Error _, Error detail ->
               Log.Keeper.warn "microvm teardown %s additional cleanup failed: %s" keeper_name detail;
               previous) (Ok ()) guests in
         match guest_cleanup, helper_observation with
         | (Error _ as error), Error helper_detail ->
           Log.Keeper.warn
             "microvm teardown %s: guest removal failed; helper observation also failed: %s"
             keeper_name helper_detail;
           error
         | (Error _ as error), Ok () -> error
         | Ok (), helper_observation -> helper_observation in
       match microvm_backend with
       | Keeper_microvm_backend.Apple_container ->
         with_apple_lifecycle_scope ~keeper_name
           ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
           (fun ~fs ~scope ->
             Result.bind (check_apple_guest_modes ~base_path:config.base_path ~keeper_name ~timeout_sec)
               (fun () -> perform
                 (fun ~network_mode ~guest_name ->
                   stop_owned_apple_guest ~base_path:config.base_path ~keeper_name
                     ~network_mode ~timeout_sec ~container_name:guest_name)
                 (fun ~network_mode ~guest_name:_ ->
                   Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
                     ~scope ~base_path:config.base_path ~keeper_name ~backend:microvm_backend
                     ~network_mode ~timeout_sec
                   |> Result.map (function
                     | Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent -> ())
                   |> Result.map_error Keeper_microvm_github_identity.error_message)))
       | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
         with_microvm_lifecycle_lock ~keeper_name ~operation:"teardown" (fun () ->
           perform
             (fun ~network_mode:_ ~guest_name ->
               stop_and_delete_microvm_container ~timeout_sec ~backend:microvm_backend guest_name)
             (fun ~network_mode:_ ~guest_name ->
               release_registered_microvm_identity guest_name; Ok ())))
;;

(* Separate from the teardown because a paused keeper is torn down too and
   must come back to its work volume. Only dissolution calls this, after the
   teardown has removed the guest that held the volumes. *)
let remove_keeper_volumes_by_name
      ?timeout_sec
      ~base_path:(base_path : string)
      ~(keeper_name : string)
      ~(backend : Keeper_sandbox.backend)
      ?microvm_backend
      ?sandbox_image
      ()
  =
  let timeout_sec =
    Option.value
      timeout_sec
      ~default:
        (Env_config_sandbox.Shell_timeout.timeout_sec
           ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
           ())
  in
  match backend with
  | Keeper_sandbox.Docker | Keeper_sandbox.Remote_ssh -> Ok ()
  | Keeper_sandbox.Micro_vm ->
    (match microvm_backend with
     | None ->
       Error
         (Printf.sprintf
            "microvm_volume_removal_backend_unresolved: keeper %s's volumes \
             cannot be removed without the runtime that created them"
            keeper_name)
     | Some Keeper_microvm_backend.Apple_container ->
       (* Work and build names contain the Keeper name but not its workspace.
          The marker records confirmed claims, but a legacy or adopted owner
          may be unrecorded and a paused owner may have no container, so the
          release keeps the volumes instead of deleting them. The release
          helper runs on the Keeper's own sandbox image; an unresolvable image
          prevents this call from releasing the claim. *)
       (match sandbox_image with
        | None ->
          Error
            (Printf.sprintf
               "microvm_volume_removal_image_unresolved: keeper %s's volumes \
                cannot be released without an image to run the claims helper; \
                automatic deletion was skipped"
               keeper_name)
        | Some image ->
          (match Keeper_sandbox_microvm.work_volume_name ~keeper_name with
           | Error detail -> Error ("microvm_volume_removal_unnamed: " ^ detail)
           | Ok volume_name ->
             let claimant =
               Keeper_sandbox_runtime_setup.normalize_base_path_for_hash base_path
             in
             (match
                Keeper_sandbox_microvm.release_apple_work_volume_claim
                  ~run:(fun ~timeout_sec argv -> run_argv_with_status_split ~timeout_sec argv)
                  ~timeout_sec
                  ~keeper_name
                  ~volume_name
                  ~image
                  ~claimant
              with
              | Keeper_sandbox_microvm.Kept_for_claimants claimants ->
                Log.Keeper.warn ~keeper_name
                  "keeper removed; its Apple volumes are kept: %d other workspace(s) \
                   still claim them: %s"
                  (List.length claimants)
                  (String.concat ", " claimants);
                Ok ()
              | Keeper_sandbox_microvm.Kept_for_containers owners ->
                Log.Keeper.warn ~keeper_name
                  "keeper removed; its claim was released but its Apple volumes are \
                   kept: containers still reference the keeper: %s"
                  (String.concat ", " owners);
                Ok ()
              | Keeper_sandbox_microvm.Skipped_unverified detail -> Error detail)))
     | Some
         ((Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata) as
          microvm_backend) ->
       (* Both create the work volume as a host directory, but no removal
          spelling is established for either. Name what is left instead of
          reporting a removal that did not happen. *)
       Error
         (Printf.sprintf
            "microvm_volume_removal_not_established: keeper %s's work volume \
             on %s, if present, was not removed; verify ownership across \
             workspaces before deleting it"
            keeper_name
            (Keeper_microvm_backend.to_string microvm_backend)))
;;

let teardown_keeper_sandbox
      ?timeout_sec
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ()
  =
  teardown_keeper_sandbox_by_name
    ?timeout_sec
    ~config
    ~keeper_name:meta.name
    ~backend:meta.sandbox_profile
    (* The meta is still here, so the runtime the guest was booted on travels
       with the removal. Without it a microsandbox guest would be sent
       [container delete --force] and survive its own teardown. *)
    ?microvm_backend:meta.microvm_backend
    ()
;;

let start_container ?timeout_sec (t : t) =
  if is_microvm t
  then start_microvm_container ?timeout_sec t
  else
  (* Only the two refusals of the GitHub identity below blame the Keeper's
     login; every other failure is the container's. *)
  let sandbox_failed detail = Error (Sandbox_unavailable detail) in
  match t.image with
  | Error error -> sandbox_failed (image_unresolved_message error)
  | Ok image ->
  let container_name = docker_container_name_for_image t ~image in
  let probe_state () =
    Keeper_sandbox_runtime.probe_container_state_optional
      ~container_name
      ?timeout_sec
      ()
  in
  let adopt_running () =
    (* The mount is the live config directory, so a login that happened while
       no turn was watching only needs the derived gitconfig rewritten; the
       env baked at creation keeps pointing at the same file. A malformed
       identity state is a typed error here exactly as it is at creation. *)
    match
      Keeper_github_identity.refresh_git_credential_config
        ~config:t.config
        ~keeper_name:t.meta.name
    with
    | Error err ->
      Error
        (Identity_unavailable
           ("docker_container_adopt_failed: github_identity_invalid: " ^ err))
    | Ok _has_git_wiring ->
      set_state t (Running { container_name });
      Ok container_name
  in
  (* Creation is the only path that needs the image, the runtime hardening
     args, and the projections; adoption amortises all of it. *)
  let create () =
    (
      match
        Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class_optional
          ~image
          ?timeout_sec
          ()
      with
      | Error failure ->
        sandbox_failed (Keeper_sandbox_runtime.image_preflight_start_error failure)
      | Ok () ->
        match
          Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime_optional
            ?timeout_sec ()
        with
        | Error detail -> sandbox_failed detail
        | Ok seccomp_args ->
        match Keeper_sandbox_runtime.docker_network_args t.network_mode with
        | Error msg -> sandbox_failed msg
        | Ok (network_args, network_label) ->
        (match
           Keeper_sandbox_runtime.docker_user_identity_mount_args
             ~host_root:t.host_root
             ~uid:t.uid
             ~gid:t.gid
         with
         | Error detail -> sandbox_failed detail
         | Ok identity_mounts ->
         (match
            Keeper_secret_projection.docker_args_for_keeper
              ~base_path:t.config.base_path
              ~keeper_name:t.meta.name
              ~container_name
              ()
          with
          | Error err ->
            sandbox_failed ("docker_container_start_failed: secret_projection: " ^ err)
          | Ok secret_projection ->
           (match
              Keeper_github_identity.docker_args_persistent
                ~config:t.config
                ~keeper_name:t.meta.name
                ~container_masc_dir:
                  (Keeper_sandbox_runtime_setup.container_masc_dir
                     ~container_root:t.container_root)
            with
            | Error err ->
              Eio_guard.protect
                ~finally:secret_projection.cleanup
                (fun () ->
                   Error
                     (Identity_unavailable
                        ("docker_container_start_failed: github_identity_invalid: "
                         ^ err)))
            | Ok github_identity_args ->
            Eio_guard.protect
              ~finally:secret_projection.cleanup
              (fun () ->
              (* No [--rm]: the container outlives the turn, and auto-remove
                 on stop would destroy state a later turn expects to adopt.
                 Removal is the keeper's teardown, not the daemon's. *)
              Keeper_sandbox_runtime_setup.refuse_real_daemon_under_test
                ~what:"start a persistent container";
              let argv =
                Keeper_sandbox_runtime.docker_command_argv ()
                @ [ "run"; "-d"; "--name"; container_name ]
                @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
                @ Keeper_sandbox_runtime.docker_label_args
                    ~base_path:t.config.base_path
                    ~keeper_name:t.meta.name
                    ~container_kind:Keeper_sandbox_runtime.persistent_container_kind
                    ~network_label
                    ()
                @ [ "--user"; Printf.sprintf "%d:%d" t.uid t.gid ]
                @ Keeper_sandbox_runtime.docker_sandbox_env_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ Keeper_sandbox_runtime.docker_nofile_args ()
                @ Env_config_sandbox.Hardening.read_only_rootfs_args ()
                @ [ "--tmpfs"
                  ; Env_config_sandbox.Hardening.tmpfs_mount ()
                  ; "--cap-drop=ALL"
                  ; "--security-opt"
                  ; "no-new-privileges"
                  ]
                @ seccomp_args
                @ [ "--pids-limit"
                  ; string_of_int (Env_config_sandbox.Hardening.pids_limit ())
                  ; "--memory"
                  ; Env_config_sandbox.Hardening.memory ()
                  ; "-v"
                  ; t.host_root ^ ":" ^ t.container_root ^ ":rw"
                  ; "--workdir"
                  ; t.container_root
                  ]
                @ Keeper_sandbox_runtime.docker_config_mount_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ Keeper_sandbox_runtime.docker_workspace_state_mount_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ secret_projection.docker_args
                @ github_identity_args
                @ identity_mounts
                @ network_args
                @ [ image; "tail"; "-f"; "/dev/null" ]
              in
              let st, out = run_argv_with_status ?timeout_sec argv in
              match st with
              | Unix.WEXITED 0 ->
                (* The same probe the start began with. Listed in any state,
                   it is the container this run made. *)
                (match probe_state () with
                 | Ok
                     ( Keeper_sandbox_runtime.Docker_container_running
                     | Keeper_sandbox_runtime.Docker_container_stopped ) ->
                   set_state t (Running { container_name });
                   Ok container_name
                 | Ok Keeper_sandbox_runtime.Docker_container_absent ->
                   (* The daemon does not list the container its run reported.
                      t.state stays Not_started, so the name is removed here,
                      best effort, rather than left for nothing to reclaim. *)
                   let rm_argv =
                     Keeper_sandbox_runtime.docker_remove_argv container_name
                   in
                   let _rm_st, _rm_out =
                     run_argv_with_status ?timeout_sec rm_argv
                   in
                   sandbox_failed
                     (Printf.sprintf
                        "docker_container_absent_after_run: docker run exited 0 \
                         and the daemon does not list %s"
                        container_name)
                 | Error probe_error ->
                   (* The daemon could not be asked. The container this run
                      made may be up, so it is not removed: the next start
                      probes the stable name again and adopts it. *)
                   sandbox_failed
                     (Printf.sprintf
                        "docker_container_state_unknown_after_run: %s"
                        (Exec_policy.truncate_for_log probe_error)))
              | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
                (match probe_state () with
                 | Ok Keeper_sandbox_runtime.Docker_container_running ->
                   (* Another turn or server of this keeper booted the shared
                      name between the absent probe and this run; the run's
                      name loss is the winner's, and this call adopts the
                      winner. *)
                   adopt_running ()
                 | ( Ok
                       ( Keeper_sandbox_runtime.Docker_container_stopped
                       | Keeper_sandbox_runtime.Docker_container_absent )
                   | Error _ ) as container_state ->
                   sandbox_failed
                     (Keeper_sandbox_exec_failure.docker_run_failure_message
                        ~prefix:"docker_container_start_failed"
                        ~base_path_hash:
                          (Keeper_sandbox_runtime.base_path_hash t.config.base_path)
                        ~keeper_name:t.meta.name
                        ~container_kind:
                          Keeper_sandbox_runtime.persistent_container_kind
                        ~network_label:(network_mode_to_string t.network_mode)
                        ~image
                        ~status:st
                        ~container_state
                        ~output:out
                        ())))))))
  in
  match probe_state () with
  | Ok Keeper_sandbox_runtime.Docker_container_running -> adopt_running ()
  | Error probe_error ->
    sandbox_failed
      (Printf.sprintf
         "docker_container_probe_failed: %s"
         (Exec_policy.truncate_for_log probe_error))
  | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
    (* A stopped container keeps its filesystem layer: [docker start] resumes
       it instead of losing the installed state the persistence exists to
       keep. A start failure (image evicted from the daemon, mount source
       vanished) falls through to remove-and-recreate. *)
    let start_argv =
      Keeper_sandbox_runtime.docker_command_argv ()
      @ [ "start"; container_name ]
    in
    let start_st, _start_out =
      run_argv_with_status ?timeout_sec start_argv
    in
    if start_st = Unix.WEXITED 0
    then (
      match
        inspect_container_exists ?timeout_sec container_name
      with
      | Ok () -> adopt_running ()
      | Error inspect_out ->
        sandbox_failed
          (Printf.sprintf
             "docker_container_start_failed: restarted %s but inspect cannot \
              see it: %s"
             container_name
             (Exec_policy.truncate_for_log inspect_out)))
    else (
      let rm_argv =
        Keeper_sandbox_runtime.docker_remove_argv container_name
      in
      let _rm_st, _rm_out = run_argv_with_status ?timeout_sec rm_argv in
      create ())
  | Ok Keeper_sandbox_runtime.Docker_container_absent -> create ()
;;

let ensure_started_with_cause ?(validate_running = false) ?timeout_sec (t : t) =
  match get_state t with
  | Running { container_name } ->
    if not validate_running
    then Ok container_name
    else (
      (* Validation is asked for only by the Docker exec entrypoints, after
         [docker_exec_only] has refused a microvm runtime. *)
      match inspect_container_running ?timeout_sec container_name with
      | Ok () -> Ok container_name
      | Error _ ->
        set_state t Not_started;
        start_container ?timeout_sec t)
  | Not_started -> start_container ?timeout_sec t
;;

(* The exec entrypoints report every start failure as one message. Only the
   identity preparation reads which side failed. *)
let ensure_started ?validate_running ?timeout_sec (t : t) =
  Result.map_error github_identity_preparation_error_message
    (ensure_started_with_cause ?validate_running ?timeout_sec t)
;;

type apple_endpoint_admission =
  | Diagnostic_read
  | Existing_execution
  | Prepared_execution

type apple_endpoint_observation =
  | Apple_snapshot_only
  | Apple_running_guest of { timeout_sec : float; admission : apple_endpoint_admission }

(* The caller holds the Apple lifecycle scope while observing and constructing
   this endpoint. Snapshot-only construction does not authorize guest effects. *)
let apple_endpoint_of_snapshot_owned ~fs ~scope
      ~(config : Workspace.config) ~(meta : keeper_meta) ~network_mode ~container_root
      ~uid ~gid ~container_name ~observation =
  let open Result.Syntax in
  let backend = Keeper_microvm_backend.Apple_container in
  let container_config_dir = Keeper_github_identity.container_config_dir
      ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root)
      ~keeper_name:meta.name in
  let* snapshot = Keeper_microvm_github_identity.load ~fs ~coordinator:microvm_lifecycle ~scope
      ~base_path:config.base_path ~keeper_name:meta.name ~backend ~network_mode
    |> Result.map_error Keeper_microvm_github_identity.error_message in
  match snapshot with
  | None -> Error "microvm host credential snapshot is missing"
  | Some snapshot ->
    (* A guest that was read is reached the way it was booted; a snapshot
       alone has only the keeper TOML's choice to go by. *)
    let* delivery = match observation with
      | Apple_snapshot_only ->
        microvm_delivery_for ~base_path:config.base_path ~keeper_name:meta.name
      | Apple_running_guest {timeout_sec; admission} ->
        let* observed = read_apple_guest ~timeout_sec ~container_name
          |> Result.map_error microvm_start_failure_message in
        (match observed with
         | Apple_absent -> Error "microvm guest is not running"
         | Apple_stopped reading ->
           let* () = check_apple_guest_scope ~base_path:config.base_path
               ~keeper_name:meta.name ~network_mode ~container_name reading in
           (* This stopped observation is already under the lifecycle owner.
              Invalidate before returning so every caller, including captured
              reads and turn execution, can prepare a later handoff. *)
           forget_microvm_guest_state ~backend ~container_name;
           Error "microvm guest is not running"
         | Apple_running reading ->
           let* () = check_apple_guest_scope ~base_path:config.base_path
               ~keeper_name:meta.name ~network_mode ~container_name reading in
           let* () = match admission with
             | Diagnostic_read -> Ok ()
             | Existing_execution | Prepared_execution ->
               let* () = microvm_build_cleanup_admission ~backend ~keeper_name:meta.name in
               microvm_build_link_effect_admission ~backend ~keeper_name:meta.name in
           let* () = match admission with
             | Diagnostic_read -> Ok ()
             | Existing_execution ->
               (* This endpoint can start new work without first preparing it.
                  A later ordinary handoff must not clean that new output. *)
               ignore (set_microvm_build_cleanup_state ~backend ~keeper_name:meta.name
                 ~expected:Build_cleanup_available Build_cleanup_skipped_not_sent);
               Ok ()
             | Prepared_execution ->
               microvm_build_links_admission ~base_path:config.base_path ~backend
                 ~keeper_name:meta.name ~container_name in
           match reading with
           | Keeper_microvm_boot_plan.Facts facts ->
             Ok (Keeper_microvm_agent_socket.delivery_of_facts ~base_path:config.base_path
                   ~guest_name:container_name facts)
           | Keeper_microvm_boot_plan.Unreadable detail -> Error detail) in
    let* () = Keeper_microvm_shim_readiness.verify ~fs ~base_path:config.base_path
        ~backend ~guest_name:container_name
      |> Result.map_error Keeper_microvm_shim_readiness.error_message in
    let identity_environment = Keeper_microvm_github_identity.environment snapshot ~container_config_dir in
    let* endpoint = build_microvm_endpoint ~config ~meta ~container_root ~uid ~gid
        ~container_name ~identity_environment ~delivery in
    Ok (endpoint, Keeper_microvm_github_identity.revision snapshot)
;;

(* Endpoint admission reads the host-side identity snapshot and verifies the shared shim.
   It never starts a guest or prepares build output on behalf of attached reads. *)
let microvm_remote_endpoint_of_running_fields
      ~(config : Workspace.config) ~(meta : keeper_meta) ~network_mode ~container_root
      ~uid ~gid ~container_name ~timeout_sec ~admission =
  let open Result.Syntax in
  let* () = microvm_profile_check meta in
  let* backend = microvm_backend_of_meta meta in
  let container_config_dir = Keeper_github_identity.container_config_dir
      ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root)
      ~keeper_name:meta.name in
  let build identity_environment =
    let* () = verify_microvm_shim ~base_path:config.base_path
        ~backend ~guest_name:container_name
      |> Result.map_error Keeper_microvm_shim_readiness.error_message in
    (* Only Apple publishes a guest socket; the TOML refuses the agent elsewhere. *)
    build_microvm_endpoint ~config ~meta ~container_root ~uid ~gid ~container_name ~identity_environment
      ~delivery:Keeper_types_profile_sandbox.Exec_per_request in
  match backend with
  | Keeper_microvm_backend.Apple_container ->
    with_apple_lifecycle_scope ~keeper_name:meta.name
      ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
      (fun ~fs ~scope ->
        apple_endpoint_of_snapshot_owned ~fs ~scope ~config ~meta ~network_mode ~container_root
          ~uid ~gid ~container_name ~observation:(Apple_running_guest {timeout_sec; admission})
        |> Result.map fst)
  | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
    build (Keeper_github_identity.microvm_git_credential_env
      ~config ~keeper_name:meta.name ~container_config_dir)
;;

let microvm_remote_endpoint_of_running_with_timeout ?timeout_sec ?(admission = Existing_execution) (t : t) ~container_name =
  let timeout_sec = match timeout_sec with
    | Some timeout_sec -> timeout_sec
    | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
  microvm_remote_endpoint_of_running_fields
    ~config:t.config
    ~meta:t.meta
    ~network_mode:t.network_mode
    ~container_root:t.container_root
    ~uid:t.uid
    ~gid:t.gid
    ~container_name
    ~timeout_sec
    ~admission
;;

let microvm_remote_endpoint_of_running (t : t) ~container_name =
  microvm_remote_endpoint_of_running_with_timeout t ~container_name
;;

(* Apple preparation belongs to the canonical Keeper owner, including a
   retry after an incomplete first handoff. Attached readers never run it. *)
let microvm_remote_endpoint ?timeout_sec (t : t) =
  match ensure_started ?timeout_sec t with
  | Error _ as err -> err
  | Ok container_name ->
    let root =
      Result.bind (microvm_backend_of t) (fun backend ->
        let prepared = match backend with
          | Keeper_microvm_backend.Apple_container ->
            Result.is_ok (microvm_build_links_admission ~base_path:t.config.base_path
              ~backend ~keeper_name:t.meta.name ~container_name)
          | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
            microvm_work_root_ready ~base_path:t.config.base_path ~backend ~container_name in
        if prepared
        then Ok ()
        else match backend with
          | Keeper_microvm_backend.Apple_container ->
            start_microvm_container ?timeout_sec t
            |> Result.map (fun _ -> ())
            |> Result.map_error github_identity_preparation_error_message
          | (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) as backend ->
            match ensure_microvm_keeper_work_root ?timeout_sec t ~backend ~container_name with
            | Ok () ->
              mark_microvm_work_root_ready ~base_path:t.config.base_path ~backend ~container_name;
              Ok ()
            | Error _ as err -> err)
    in
    (match root with
     | Error _ as err -> err
     | Ok () -> microvm_remote_endpoint_of_running_with_timeout ?timeout_sec ~admission:Prepared_execution t ~container_name)
;;

(* Reading a keeper's tree needs the guest, not the turn that happens to be
   using it. The guest name is a function of the keeper and the base path,
   and the guest is keeper-lifetime, so a caller holding no lifecycle
   authority can still name and reach one that is up. Endpoint admission
   validates the host-side identity snapshot under a Keeper owner and verifies the
   shared shim. It never calls [ensure_started]. Booting on behalf of a reader
   would spend a VM start, write the identity snapshot and make the work
   root -- effects that belong to the keeper's own turn.

   Apple observes the running guest's scope before returning an endpoint. This
   is not a fence against a replacement after the observation. Other backends
   still rely on [container exec] and [microvm_guest_absence_reason]. *)
let microvm_attached_endpoint ?timeout_sec ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let container_name =
    microvm_container_name
      ~config
      ~keeper_name:meta.name
      ~network_mode:meta.network_mode
  in
  microvm_remote_endpoint_of_running_fields
    ~config
    ~meta
    ~network_mode:meta.network_mode
    ~container_root:(container_root_of_meta meta)
    ~uid:(Unix.getuid ())
    ~gid:(Unix.getgid ())
    ~container_name
    ~timeout_sec:(Option.value timeout_sec
      ~default:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()))
    ~admission:Diagnostic_read
;;

let with_apple_endpoint_observation ~(config : Workspace.config) ~(meta : keeper_meta) ~observation use =
  let open Result.Syntax in
  let* () = microvm_profile_check meta in
  let* backend = microvm_backend_of_meta meta in
  match backend with
  | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
    Error "captured Apple authority requires the Apple microVM backend"
  | Keeper_microvm_backend.Apple_container ->
    let network_mode = meta.network_mode in
    let container_name = microvm_container_name ~config ~keeper_name:meta.name ~network_mode in
    with_apple_lifecycle_scope ~keeper_name:meta.name
      ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
      (fun ~fs ~scope ->
        let* endpoint, revision = apple_endpoint_of_snapshot_owned ~fs ~scope ~config ~meta
            ~network_mode ~container_root:(container_root_of_meta meta) ~uid:(Unix.getuid ())
            ~gid:(Unix.getgid ()) ~container_name ~observation in
        use ~revision endpoint)
;;

let with_apple_snapshot_endpoint ~(config : Workspace.config) ~(meta : keeper_meta) use =
  with_apple_endpoint_observation ~config ~meta ~observation:Apple_snapshot_only use
;;

let with_apple_attached_endpoint ?timeout_sec ~(config : Workspace.config) ~(meta : keeper_meta) use =
  let timeout_sec = Option.value timeout_sec
      ~default:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()) in
  with_apple_endpoint_observation ~config ~meta
    ~observation:(Apple_running_guest {timeout_sec; admission=Diagnostic_read}) use
;;

(* [Some reason] when the guest is not running, so a caller can replace a raw
   exec failure with the fact behind it; [None] when the guest is up or the
   probe itself could not answer, leaving the caller's own error in place. *)
let microvm_guest_absence_reason ?timeout_sec ~(config : Workspace.config)
      ~(meta : keeper_meta) () =
  if meta.sandbox_profile <> Keeper_types_profile_sandbox.Micro_vm
  then None
  else
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    (* No recorded runtime means nothing here can state a fact about the
       guest, so the caller's own error stands rather than a probe run
       against a runtime the keeper never named. *)
    match meta.microvm_backend with
    | None -> None
    | Some backend ->
    let observe () =
      let not_running = match backend with
        | Keeper_microvm_backend.Apple_container ->
          let timeout_sec = Option.value timeout_sec
              ~default:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()) in
          (match read_apple_guest ~timeout_sec ~container_name with
           | Ok Apple_absent -> true
           | Ok (Apple_stopped reading) ->
             Result.is_ok (check_apple_guest_scope ~base_path:config.base_path
               ~keeper_name:meta.name ~network_mode:meta.network_mode ~container_name reading)
           | Ok (Apple_running _) | Error _ -> false)
        | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
          (match probe_microvm_container_state ?timeout_sec ~backend container_name with
           | Ok (Keeper_sandbox_runtime.Docker_container_stopped
                | Keeper_sandbox_runtime.Docker_container_absent) -> true
           | Ok Keeper_sandbox_runtime.Docker_container_running | Error _ -> false) in
      if not not_running then None
      else (
        forget_microvm_work_root ~backend ~container_name;
        Keeper_microvm_shim_readiness.forget ~backend ~guest_name:container_name;
        Some
          (Printf.sprintf
             "microvm_guest_not_running: keeper %s's guest %s is not running; a read \
              attaches to a running guest and never boots one"
             meta.name container_name))
    in
    (* Apple handoff uses this same owner. Never let an earlier failed read
       invalidate a newer handoff after the owner has been released. *)
    match backend, Fs_compat.execution_context () with
    | Keeper_microvm_backend.Apple_container, Fs_compat.Non_eio -> None
    | Keeper_microvm_backend.Apple_container, Fs_compat.Eio_fiber
    | (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox),
      (Fs_compat.Eio_fiber | Fs_compat.Non_eio) ->
      with_microvm_lifecycle_lock ~keeper_name:meta.name ~operation:"absence_probe" observe
;;

let is_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
  if meta.sandbox_profile <> Keeper_types_profile_sandbox.Micro_vm
  then false
  else
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    match meta.microvm_backend with
    | None -> false
    | Some backend -> microvm_work_root_ready ~base_path:config.base_path ~backend ~container_name
;;

let forget_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let container_name =
    microvm_container_name
      ~config
      ~keeper_name:meta.name
      ~network_mode:meta.network_mode
  in
  Option.iter (fun backend ->
    forget_microvm_work_root ~backend ~container_name;
    Keeper_microvm_shim_readiness.forget ~backend ~guest_name:container_name)
    meta.microvm_backend
;;

let retire_current_github_identity_snapshot t =
  update_github_identity_snapshots t (fun snapshots ->
    match snapshots.current with
    | None -> snapshots
    | Some current ->
      { current = None; retired = current :: snapshots.retired })
;;

let stop_container_for_github_identity_refresh ?timeout_sec t =
  if is_microvm t
  then (
    match microvm_backend_of t with
    | Error _ as error -> error
    | Ok Keeper_microvm_backend.Apple_container ->
      let backend = Keeper_microvm_backend.Apple_container in
      let timeout_sec = match timeout_sec with Some seconds -> seconds
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm () in
      with_apple_lifecycle_scope ~keeper_name:t.meta.name
        ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
        (fun ~fs ~scope ->
          Result.bind (ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec)
            (fun () -> Result.bind
              (stop_owned_apple_guest ~base_path:t.config.base_path ~keeper_name:t.meta.name
                 ~network_mode:t.network_mode ~timeout_sec ~container_name:(keeper_vm_name t))
              (fun () ->
              (* The guest is gone even if later snapshot cleanup cannot
                 settle. Do not retain Running authority for the next call. *)
              set_state t Not_started;
              forget_github_identity_snapshots t;
              Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
                ~scope ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend
                ~network_mode:t.network_mode ~timeout_sec
              |> Result.map (function
                | Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent -> ())
              |> Result.map_error Keeper_microvm_github_identity.error_message)))
    | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
    with_microvm_lifecycle_lock ~keeper_name:t.meta.name ~operation:"identity_refresh" (fun () ->
      let container_name = keeper_vm_name t in
      match
        Result.bind (microvm_backend_of t) (fun backend ->
          stop_and_delete_microvm_container ?timeout_sec ~backend container_name)
      with
      | Error _ as error -> error
      | Ok () ->
        release_registered_microvm_identity container_name;
        forget_github_identity_snapshots t;
        set_state t Not_started;
        Ok ()))
  else
    let retire () =
      set_state t Not_started;
      retire_current_github_identity_snapshot t;
      Ok ()
    in
    match get_state t with
    | Not_started -> retire ()
    | Running { container_name } ->
    let timeout_sec =
      Option.value
        timeout_sec
        ~default:
          (Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm ())
    in
    let argv =
      Keeper_sandbox_runtime.docker_remove_argv container_name
    in
    let status, output = run_argv_with_status ~timeout_sec argv in
      (match status with
       | Unix.WEXITED 0 -> retire ()
       | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
         (match
            Keeper_sandbox_runtime.probe_container_state_optional
              ~container_name
              ~timeout_sec
              ()
          with
          | Ok Keeper_sandbox_runtime.Docker_container_absent -> retire ()
          | Ok Keeper_sandbox_runtime.Docker_container_running
          | Ok Keeper_sandbox_runtime.Docker_container_stopped
          | Error _ ->
            Error
              (Printf.sprintf
                 "cannot refresh GitHub identity while turn container %s remains: status=%s output=%s"
                 container_name
                 (Keeper_sandbox_exec_failure.status_label status)
                 (Exec_policy.truncate_for_log output))))
;;

let prepare_github_identity_secret_files ?timeout_sec t =
  (* App-identity keepers get a fresh installation token before any lane
     consumes their hosts file; shared-identity keepers pass through
     untouched (RFC keeper-github-apps). A stale token whose mint fails is
     an error — projecting a credential known to be expired is worse. *)
  match
    Keeper_github_app_broker.ensure_fresh
      ~now:(Time_compat.now ())
      ~http_post:Keeper_github_app_broker.default_http_post
      ~config:t.config
      ~keeper_name:t.meta.name
  with
  | Error err -> Error (Identity_unavailable ("github_app_token_refresh_failed: " ^ err))
  | Ok
      ( Keeper_github_app_broker.No_app_identity
      | Keeper_github_app_broker.Fresh _
      | Keeper_github_app_broker.Refreshed _ ) ->
  if is_microvm t
  then (
    (match microvm_backend_of t with
     | Ok Keeper_microvm_backend.Apple_container | Error _ -> ()
     | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
       ignore (bind_registered_microvm_identity t (keeper_vm_name t)));
    (* The guest's identity is its boot-time snapshot, keeper-lifetime by
       design: only a fresh boot mounts a new one, and a drift from the
       central revision is handled by dropping the handle so the next boot
       rebuilds it. *)
    let ensure_bound () =
      let snapshot_paths () =
        match (Atomic.get t.github_identity_snapshots).current with
        | Some _ -> Ok (github_identity_secret_files t)
        | None -> Error (Identity_unavailable "running container has no GitHub identity snapshot")
      in
      match ensure_started_with_cause ?timeout_sec t with
      | Error _ as error -> error
      | Ok _container_name ->
        (match snapshot_paths () with
         | Ok _ as result -> result
         | Error _ ->
           (* A runtime can retain [Running] across turns while its local
              handle was lost (for example after a failed adoption). Do not
              report a live guest as usable without the credential it was
              booted to mount: force the normal MicroVM start path to
              reconcile the stable guest and registry, which reboots when no
              safe snapshot exists. *)
           set_state t Not_started;
           (match start_container ?timeout_sec t with
            | Error _ as error -> error
            | Ok _ -> snapshot_paths ()))
    in
    match ensure_bound () with
    | Error _ as error -> error
    | Ok paths -> match
      Keeper_github_identity.current_tool_identity_revision
        ~config:t.config
        ~keeper_name:t.meta.name
    with
    | Error detail -> Error (Identity_unavailable detail)
    | Ok central_revision ->
      (match (Atomic.get t.github_identity_snapshots).current with
       | None -> Error (Identity_unavailable "running guest lost its validated identity binding")
       | Some snapshot when String.equal (identity_revision snapshot) central_revision ->
         Ok paths
       | Some _ ->
         (match stop_container_for_github_identity_refresh ?timeout_sec t with
          | Error detail -> Error (Sandbox_unavailable detail)
          | Ok () -> ensure_bound ())))
  else
    (* The persistent Docker container mounts the stable config directory
       read-only, so the token that must stay redacted is the stable
       hosts.yml and binding is [ensure_started] itself -- a central login
       reaches the running container through the mount, with the derived
       gitconfig refreshed at adoption. An unconfigured keeper exposes no
       credential file. *)
    match ensure_started_with_cause ?timeout_sec t with
    | Error _ as error -> error
    | Ok _container_name ->
      (match
         Keeper_github_identity.existing_config_dir
           ~config:t.config
           ~keeper_name:t.meta.name
       with
       | Error detail -> Error (Identity_unavailable detail)
       | Ok None -> Ok []
       | Ok (Some dir) -> Ok [ Filename.concat dir "hosts.yml" ])
;;

(* The argv [run_exec_with_status_split_once] runs: the turn-scoped
   container, the same uid, the rewritten paths. *)
let exec_argv ?stdin ?timeout_sec ~validate_cached_container (t : t) ~cwd ~command_argv =
  let open Result.Syntax in
  let* () = docker_exec_only t in
  let* container_cwd = container_path_of_host t ~host_path:cwd in
  let* container_name =
    ensure_started ~validate_running:validate_cached_container ?timeout_sec t
  in
  let command_argv =
    List.map
      (fun arg ->
         let rewritten =
           Keeper_sandbox_runtime.rewrite_host_root_to_container_root
             ~host_root:t.host_root
             ~container_root:t.container_root
             arg
         in
         if String.equal t.raw_host_root t.host_root
         then rewritten
         else
           Keeper_sandbox_runtime.rewrite_host_root_to_container_root
             ~host_root:t.raw_host_root
             ~container_root:t.container_root
             rewritten)
      command_argv
  in
  Ok
    (exec_prefix t ~container_cwd ~stdin:(Option.value stdin ~default:false)
     @ (container_name :: command_argv))
;;

let run_exec_with_status_split_once
      ?(validate_cached_container = false)
      ?(stdin_content : string option)
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    exec_argv
      ~stdin:(Option.is_some stdin_content)
      ?timeout_sec
      ~validate_cached_container
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok argv ->
    let run ?output_capture () =
      match stdin_content with
      | Some content ->
        run_argv_with_stdin_and_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ?output_capture
          ~stdin_content:content
          argv
      | None ->
        run_argv_with_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ?output_capture
          argv
    in
    let (st, stdout, stderr), files =
      match capture_dir with
      | None -> run (), None
      | Some capture_dir ->
        let result, files =
          Process_output_capture.with_capture ~capture_dir (fun output_capture ->
            run ~output_capture ())
        in
        result, Some files
    in
    Ok (st, stdout, stderr, files)
;;

let run_exec_with_optional_output_files
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_with_status_split_once
      ~validate_cached_container:has_output_callback
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr, _) as failed ->
    (match failed_exec_recovery ?timeout_sec t with
     | Preserve_failed_exec -> failed
     | Restart_failed_exec ->
       set_state t Not_started;
       (match
          run_exec_with_status_split_once
            ?stdin_content
            ?on_stdout_chunk
            ?on_stderr_chunk
            ?timeout_sec
            ?capture_dir
            t
            ~cwd
            ~command_argv
        with
        | Ok _ as ok -> ok
        | Error _ as err -> err)
     | Failed_exec_state_probe_error detail ->
       Error
         (failed_exec_state_probe_error
            ~status
            ~output:(output_for_status ~stdout ~stderr)
            detail))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _, _) as other) ->
    Ok other
;;

let run_exec_with_status_split
      ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
      t ~cwd ~command_argv
  =
  run_exec_with_optional_output_files
    ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    t ~cwd ~command_argv
  |> Result.map (fun (status, stdout, stderr, _) -> status, stdout, stderr)
;;

let run_exec_with_output_files
      ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
      ~capture_dir t ~cwd ~command_argv
  =
  run_exec_with_optional_output_files
    ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    ~capture_dir t ~cwd ~command_argv
;;

let run_exec_with_status
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    run_exec_with_status_split
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (status, stdout, stderr) ->
    Ok (status, output_for_status ~stdout ~stderr)
;;

type exec_pipeline_stage = {
  command_argv : string list;
  cwd : string option;
}

let rewrite_command_argv (t : t) command_argv =
  List.map
    (fun arg ->
      let rewritten =
        Keeper_sandbox_runtime.rewrite_host_root_to_container_root
          ~host_root:t.host_root
          ~container_root:t.container_root
          arg
      in
      if String.equal t.raw_host_root t.host_root
      then rewritten
      else
        Keeper_sandbox_runtime.rewrite_host_root_to_container_root
          ~host_root:t.raw_host_root
          ~container_root:t.container_root
          rewritten)
    command_argv
;;

let docker_exec_pipeline_argv (t : t) ~container_name ~container_cwd command_argv =
  exec_prefix t ~container_cwd ~stdin:true
  @ (container_name :: rewrite_command_argv t command_argv)
;;

let run_exec_pipeline_with_status_once
      ?(validate_cached_container = false)
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      (t : t)
      ~(cwd : string)
      ~(stages : exec_pipeline_stage list)
  =
  let open Result.Syntax in
  let* () = docker_exec_only t in
  let rec project_stages projected = function
    | [] -> Ok (List.rev projected)
    | ({ command_argv; cwd = stage_cwd } : exec_pipeline_stage) :: rest ->
      let* container_cwd =
        container_path_of_host t ~host_path:(Option.value stage_cwd ~default:cwd)
      in
      project_stages ((command_argv, container_cwd) :: projected) rest
  in
  let* projected_stages = project_stages [] stages in
  let* container_name =
    ensure_started ~validate_running:validate_cached_container ?timeout_sec t
  in
  let process_stages =
    List.map
      (fun (command_argv, container_cwd) ->
        let argv = docker_exec_pipeline_argv t ~container_name ~container_cwd command_argv in
        Process_eio.plumbed_stage
          ~argv
          ~env:(Some (sandbox_environment ()))
          ~cwd:(Some (Config_dir_resolver.current_working_dir ())))
      projected_stages
  in
  (* These stages carry no file redirect, so the runner's redirect error is
     out of reach here; it is passed on rather than folded into a status. *)
  run_argv_pipeline_with_status_split
    ?timeout_sec
    ?on_stdout_chunk
    ?on_stderr_chunk
    process_stages
;;

let run_exec_pipeline_with_status ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    t ~cwd ~stages =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_pipeline_with_status_once
      ~validate_cached_container:has_output_callback
      ?timeout_sec
      t
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~cwd
      ~stages
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr) as failed ->
    (match failed_exec_recovery ?timeout_sec t with
     | Preserve_failed_exec -> failed
     | Restart_failed_exec ->
       set_state t Not_started;
       (match
          run_exec_pipeline_with_status_once
            ?timeout_sec
            t
            ?on_stdout_chunk
            ?on_stderr_chunk
            ~cwd
            ~stages
        with
        | Ok _ as ok -> ok
        | Error _ as err -> err)
     | Failed_exec_state_probe_error detail ->
       Error
         (failed_exec_state_probe_error
            ~status
            ~output:(output_for_status ~stdout ~stderr)
            detail))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) as other) ->
    Ok other
;;

let run_command_with_status
      ?(ok_exit_codes = [ 0 ])
      ~timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
      ~(max_bytes : int)
      ()
  =
  match command_argv with
  | [] -> Error "run_command_with_status: command_argv is empty"
  | head_program :: _ ->
    (match run_exec_with_status t ~timeout_sec ~cwd ~command_argv with
     | Error _ as err -> err
     | Ok (st, out) ->
       (match st with
        | Unix.WEXITED code when List.exists (fun ok_code -> ok_code = code) ok_exit_codes
          ->
          let body =
            if String.length out > max_bytes then String.sub out 0 max_bytes else out
          in
          Ok (st, body)
        | Unix.WSIGNALED _ | Unix.WSTOPPED _ | WEXITED _ -> Error (format_docker_exec_error ~head_program ~st ~out)))
;;

let cleanup (t : t) =
  (* Both keeper-lifetime containers -- the microvm guest and the persistent
     Docker container -- outlive the turn: cleanup only drops the handle, so
     the next turn (of this server or a later one) adopts what is still
     running. Removal is the keeper's teardown at shutdown finalization, the
     one point that knows the keeper is gone for good rather than between
     turns. A stopped persistent container is collected by the stale sweep,
     which removes stopped containers of any kind. *)
  match get_state t with
  | Not_started -> ()
  | Running { container_name } ->
    set_state t Not_started;
    ignore container_name
;;

type build_cleanup_report = { cleaned : int; failed : int }

let build_cleanup_report_of_string stdout =
  try
    let open Yojson.Safe.Util in
    let report = Yojson.Safe.from_string stdout in
    match member "skip" report with
    | `String reason -> Error ("Keeper guest cleanup skipped: " ^ reason)
    | `Null ->
      let entries = member "entries" report |> to_list in
      let count action = List.fold_left (fun n entry ->
          if member "action" entry = `String action then n + 1 else n) 0 entries in
      Ok { cleaned = count "cleaned"; failed = count "clean failed" }
    | _ -> Error "invalid Keeper cleanup report"
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    Error "invalid Keeper cleanup report"

type microvm_maintenance_audit_phase = Maintenance_reserved | Maintenance_result

let audit_microvm_maintenance ~(config : Workspace.config) ~(meta : keeper_meta)
    ~phase ~attempt ~outcome ~resolved =
  let phase_name = match phase with
    | Maintenance_reserved -> "reserved"
    | Maintenance_result -> "result" in
  let observation = match attempt.observation with
    | None -> `Null
    | Some (Keeper_sandbox_remote.Execution_unavailable _ as observation) ->
      Keeper_sandbox_remote.execution_observation_to_yojson observation
    | Some (Keeper_sandbox_remote.Execution_observed (receipt, trailer)) ->
      let integer = Option.fold ~none:`Null ~some:(fun n -> `Int n) in
      `Assoc ["status", `String "observed";
        "receipt", Exec_ssh_protocol.execution_receipt_to_yojson receipt;
        "outcome", `Assoc ["exit", integer trailer.exit; "signal", integer trailer.signal;
          "timed_out", `Bool trailer.timed_out;
          "shim_error", Option.fold ~none:`Null ~some:(fun detail -> `String detail) trailer.shim_error]] in
  let result = match outcome with
    | None -> `Null
    | Some (Masc_exec.Sandbox_target.Ran {status; _}) ->
      `Assoc ["kind", `String "payload_result";
        "status", `String (Keeper_sandbox_exec_failure.status_label status)]
    | Some (Masc_exec.Sandbox_target.Transport_failed {failure; _}) ->
      let failure = match failure with
        | Payload_timed_out -> "payload_timed_out"
        | Lane_unavailable -> "lane_unavailable" in
      `Assoc ["kind", `String "transport_failure"; "failure", `String failure] in
  let details = Observability_redact.redact_json_strings (`Assoc
      ["keeper_name", `String meta.name; "operation_id", `String attempt.operation_id;
       "guest_name", `String attempt.container_name; "phase", `String phase_name;
       "execution_observation", observation; "result", result;
       "effect_resolved", `Bool resolved]) in
  try
    Audit_log.log_action config ~agent_id:meta.name
      ~action:(Audit_log.Custom "keeper_microvm_build_maintenance")
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~details ~outcome:(match phase, outcome, resolved with
        | Maintenance_reserved, _, _ -> Audit_log.Success
        | Maintenance_result, Some (Masc_exec.Sandbox_target.Ran {status=Unix.WEXITED 0; _}), true ->
          Audit_log.Success
        | Maintenance_result,
          (None | Some (Masc_exec.Sandbox_target.Ran
            {status=(Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _); _}
            | Transport_failed _)), (true | false) ->
          Audit_log.Failure "maintenance did not report success") ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Observability_redact.redact_text (Printexc.to_string exn))
;;

(* The caller retains the Keeper lifecycle owner through this attempt.
   Its remote effect outlives that scope unless the runner proves termination. *)
let run_microvm_build_maintenance ~config ~(meta : keeper_meta) ~container_name
    ~endpoint ~timeout_sec ~stdin_content ~argv =
  let backend = Keeper_microvm_backend.Apple_container in
  let attempt = {operation_id=Random_id.uuid_v7 (); container_name; observation=None} in
  let settle ~observation ~resolved =
    ignore (settle_microvm_maintenance ~backend ~keeper_name:meta.name
      ~operation_id:attempt.operation_id ~observation ~resolved) in
  if not (reserve_microvm_maintenance ~backend ~keeper_name:meta.name attempt) then
    Result.bind (microvm_build_cleanup_admission ~backend ~keeper_name:meta.name)
      (fun () -> Error "microvm maintenance reservation changed; retry admission")
  else
    (* No request has been sent at reservation. The runner guarantees its
       finally callback on return or exception, replacing this initial fact
       with its own observation before this attempt is settled. *)
    let observation = ref (Some (Keeper_sandbox_remote.Execution_unavailable
        Keeper_sandbox_remote.Request_not_sent)) and outcome = ref None in
    let finish () =
      let state = match !outcome, !observation with
        | Some result, receipt -> microvm_build_cleanup_outcome result receipt
        | None, Some (Keeper_sandbox_remote.Execution_unavailable Request_not_sent) ->
          Build_cleanup_skipped_not_sent
        | None, (Some (Keeper_sandbox_remote.Execution_observed _
            | Execution_unavailable (Transport_unavailable _ | Peer_receipt_missing
              | Invalid_receipt _ | Shim_refused_without_receipt)) | None) ->
          Build_cleanup_effect_unverified in
      let resolved = match state with
        | Build_cleanup_confirmed | Build_cleanup_finished_incomplete
        | Build_cleanup_skipped_not_sent -> true
        | Build_cleanup_available | Build_cleanup_effect_unverified -> false in
      settle ~observation:!observation ~resolved;
      match audit_microvm_maintenance ~config ~meta ~phase:Maintenance_result
          ~attempt:{attempt with observation= !observation} ~outcome:!outcome ~resolved with
      | Ok () -> ()
      | Error detail -> Log.Keeper.warn ~keeper_name:meta.name
          "microvm maintenance %s result audit failed: %s" attempt.operation_id detail in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect finish) (fun () ->
      match audit_microvm_maintenance ~config ~meta ~phase:Maintenance_reserved
          ~attempt ~outcome:None ~resolved:false with
      | Error detail -> Error ("microvm maintenance intent audit failed before dispatch: " ^ detail)
      | Ok () ->
        let run = Keeper_sandbox_remote.runner ~timeout_sec
            ~on_receipt:(fun receipt -> observation := Some receipt) endpoint in
        let result = run ~on_stdout_chunk:None ~on_stderr_chunk:None
            ~stdin_content:(Some stdin_content) ~env:[||] ~cwd:None ~argv in
        outcome := Some result;
        Ok (result, !observation))
;;

(* Called only while the Owner holds its exclusive maintenance slot. Attach to
   the recorded guest; never boot, stop, pause, or refresh its credentials. *)
let cleanup_attached_builds ~(config : Workspace.config) ~(meta : keeper_meta)
    ~retention_sec () =
  match meta.sandbox_profile, meta.microvm_backend with
  | Keeper_types_profile_sandbox.Micro_vm, Some Keeper_microvm_backend.Apple_container ->
    with_apple_lifecycle_scope ~keeper_name:meta.name
      ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
      (fun ~fs ~scope ->
        let open Result.Syntax in
        let backend = Keeper_microvm_backend.Apple_container in
        let* () = microvm_build_cleanup_admission ~backend ~keeper_name:meta.name in
        let container_name = microvm_container_name ~config ~keeper_name:meta.name
            ~network_mode:meta.network_mode in
        let timeout_sec = Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
        (match probe_microvm_container_state ~timeout_sec ~backend container_name with
         | Ok Keeper_sandbox_runtime.Docker_container_running ->
           (match Embedded_config.read "scripts/keeper-build-cleanup.py" with
            | None -> Error "embedded Keeper cleanup payload missing"
            | Some stdin_content ->
              let root = Keeper_sandbox_microvm.keeper_work_root ~keeper_name:meta.name in
              (match apple_endpoint_of_snapshot_owned ~fs ~scope ~config ~meta
                  ~network_mode:meta.network_mode ~container_root:(container_root_of_meta meta)
                  ~uid:(Unix.getuid ()) ~gid:(Unix.getgid ()) ~container_name
                  ~observation:(Apple_running_guest {timeout_sec; admission=Diagnostic_read}) with
               | Error _ as error -> error
               | Ok (endpoint, _) ->
                 let* outcome, observation = run_microvm_build_maintenance ~config ~meta
                     ~container_name ~endpoint ~timeout_sec ~stdin_content
                     ~argv:["python3"; "-"; "--guest-root"; root;
                            "--build-root"; Keeper_sandbox_microvm.build_volume_guest_root; "--idle-hours";
                            string_of_float (retention_sec /. Masc_time_constants.hour); "--apply"] in
                 match outcome, observation with
                 | Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout; _ },
                   Some (Keeper_sandbox_remote.Execution_observed _) ->
                   Result.map Option.some (build_cleanup_report_of_string stdout)
                 | Masc_exec.Sandbox_target.Transport_failed { reason; _ }, _ ->
                   Error ("Keeper guest cleanup transport failed: " ^ reason)
                 | _, (Some (Keeper_sandbox_remote.Execution_unavailable _) | None) ->
                   Error "Keeper guest cleanup exit receipt missing"
                 | Masc_exec.Sandbox_target.Ran
                     { status =
                         (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _)
                     ; _
                     },
                   Some (Keeper_sandbox_remote.Execution_observed _) ->
                   Error "Keeper guest cleanup command failed"))
         | Ok (Keeper_sandbox_runtime.Docker_container_stopped
              | Keeper_sandbox_runtime.Docker_container_absent) -> Ok None
         | Error detail -> Error detail))
  | (Keeper_types_profile_sandbox.Micro_vm, Some (Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata))
  | (Keeper_types_profile_sandbox.Micro_vm, None) | ((Docker | Remote_ssh), _) -> Ok None
