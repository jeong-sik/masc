open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_work_root
open Keeper_turn_sandbox_runtime_boot
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_run_argv
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_work_volume
open Keeper_turn_sandbox_runtime_start_failure
open Keeper_turn_sandbox_runtime_remote_endpoint

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
