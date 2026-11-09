open Keeper_meta_contract
open Keeper_types_profile
open Keeper_turn_sandbox_runtime_work_root
open Keeper_turn_sandbox_runtime_record
open Keeper_turn_sandbox_runtime_container
open Keeper_turn_sandbox_runtime_start_failure
open Keeper_turn_sandbox_runtime_apple
open Keeper_turn_sandbox_runtime_endpoint

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
