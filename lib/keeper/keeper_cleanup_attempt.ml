let read_meta ~(config : Workspace.config) ~keeper_name =
  match Keeper_meta_store.read_effective_meta_resolved config keeper_name with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some (resolved_name, meta)) ->
    if String.equal resolved_name keeper_name && String.equal meta.name keeper_name
    then Ok (Some meta)
    else
      Error
        (Printf.sprintf
           "Keeper cleanup identity mismatch: owner=%s resolved=%s payload=%s"
           keeper_name
           resolved_name
           meta.name)
;;

let enabled = function
  | Keeper_cleanup_step.Guest_builds ->
    Runtime_params.get Runtime_settings.keeper_build_cleanup_enabled
  | Keeper_cleanup_step.Remote_workspace ->
    Runtime_params.get Runtime_settings.keeper_remote_workspace_cleanup_enabled
;;

let steps_for (meta : Keeper_meta_contract.keeper_meta) =
  List.filter
    (fun step ->
      Keeper_cleanup_step.applies_to
        step
        ~sandbox_profile:meta.sandbox_profile
        ~microvm_backend:meta.microvm_backend)
    Keeper_cleanup_step.all
;;

(* The steps come from the TOML-resolved meta. Choosing from a projected or
   stored meta sent every Remote_ssh Keeper to [Guest_builds], whose
   Remote_ssh arm returns [Ok None]: the 2026-11-09 09:09Z pass logged
   owners=34 builds=34 workspaces=0. *)
let select ~config ~enabled ~keeper_name =
  match read_meta ~config ~keeper_name with
  | Error detail -> Error (Keeper_cleanup_status.Unreadable detail)
  | Ok None -> Error Keeper_cleanup_status.Without_meta
  | Ok (Some meta) ->
    (match steps_for meta with
     | [] -> Error Keeper_cleanup_status.No_step
     | _ :: _ as applicable ->
       (match List.filter enabled applicable with
        | [] -> Error Keeper_cleanup_status.Switched_off
        | _ :: _ as steps -> Ok steps))
;;

(* [Ok None] is a payload that found no running guest to attach to. *)
let outcome_of_run = function
  | Error detail -> Keeper_cleanup_status.Failed detail
  | Ok None -> Keeper_cleanup_status.Not_running
  | Ok (Some report) -> Keeper_cleanup_status.Reclaimed report
;;

let outcome_of_admission = function
  | Error error ->
    Keeper_cleanup_status.Failed (Keeper_owner_registry.command_error_to_string error)
  | Ok (`Busy block) ->
    Keeper_cleanup_status.Deferred (Keeper_owner.autonomous_block_to_string block)
  | Ok (`Ran result) -> outcome_of_run result
;;

let admit ~(config : Workspace.config) ~keeper_name step run =
  match Keeper_cleanup_step.admission step with
  | Keeper_cleanup_step.Beside_turns -> outcome_of_run (run ())
  | Keeper_cleanup_step.Idle_owner ->
    outcome_of_admission
      (Keeper_owner_registry.run_maintenance_if_idle
         ~defer_to_chat:true
         ~base_path:config.base_path
         ~keeper_name
         run)
;;

let with_current_meta ~config ~keeper_name run =
  match read_meta ~config ~keeper_name with
  | Error detail -> Error detail
  | Ok None -> Error "no stored Keeper meta"
  | Ok (Some meta) -> run meta
;;

let attempt ~(config : Workspace.config) ~keeper_name step : Keeper_cleanup_status.attempt =
  match step with
  | Keeper_cleanup_step.Guest_builds ->
    Keeper_cleanup_status.Guest_builds
      (admit ~config ~keeper_name step (fun () ->
         with_current_meta ~config ~keeper_name (fun meta ->
           Keeper_turn_sandbox_runtime.cleanup_attached_builds
             ~config
             ~meta
             ~retention_sec:
               (Runtime_params.get Runtime_settings.keeper_build_cleanup_retention_sec)
             ()
           |> Result.map
                (Option.map (fun { Keeper_turn_sandbox_runtime.cleaned; failed } ->
                   { Keeper_cleanup_status.cleaned; failed })))))
  | Keeper_cleanup_step.Remote_workspace ->
    Keeper_cleanup_status.Remote_workspace
      (admit ~config ~keeper_name step (fun () ->
         with_current_meta ~config ~keeper_name (fun meta ->
           Keeper_remote_workspace_cleanup.cleanup
             ~config
             ~meta
             ~retention_sec:
               (Runtime_params.get
                  Runtime_settings.keeper_remote_workspace_cleanup_retention_sec)
             ~timeout_sec:
               (Runtime_params.get
                  Runtime_settings.keeper_remote_workspace_cleanup_timeout_sec)
             ()
           |> Result.map
                (fun
                    { Keeper_remote_workspace_cleanup.removed
                    ; skipped
                    ; failed
                    ; freed_kib
                    ; available_kib
                    }
                  ->
                  Some
                    { Keeper_cleanup_status.removed; skipped; failed; freed_kib; available_kib }))))
;;

let failed step reason : Keeper_cleanup_status.attempt =
  match step with
  | Keeper_cleanup_step.Guest_builds ->
    Keeper_cleanup_status.Guest_builds (Keeper_cleanup_status.Failed reason)
  | Keeper_cleanup_step.Remote_workspace ->
    Keeper_cleanup_status.Remote_workspace (Keeper_cleanup_status.Failed reason)
;;

let run ~config ~keeper_name step =
  try attempt ~config ~keeper_name step with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> failed step (Printexc.to_string exn)
;;
