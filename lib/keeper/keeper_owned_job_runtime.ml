module Store = Keeper_owned_job_store
module Backend = Keeper_owned_job_backend
module Invocation = Keeper_owned_job_invocation
open Result.Syntax

let save (record : Store.record) ~phase ~cancel_requested ~outputs ~detail =
  if phase = record.phase && cancel_requested = record.cancel_requested
     && outputs = record.outputs && detail = record.detail
  then Ok record
  else Store.transition record ~phase ~cancel_requested ~outputs ~detail

let note (record : Store.record) detail =
  save record ~phase:record.phase ~cancel_requested:record.cancel_requested
    ~outputs:record.outputs ~detail:(Some detail)

type settlement =
  | Confirmed of Store.record
  | Unconfirmed of Store.record * Store.reconciliation_hold
let record_of_settlement = function Confirmed record | Unconfirmed (record, _) -> record
let reconciliation_of_settlement = function
  | Confirmed _ -> Store.Phase_confirmed
  | Unconfirmed (_, reason) -> Store.Phase_held reason

let observe (record : Store.record) observation =
  let preserve reason detail =
    Result.map (fun record -> Unconfirmed (record, reason)) (note record detail) in
  let settle phase = save record ~phase ~cancel_requested:record.cancel_requested
      ~outputs:record.outputs ~detail:None |> Result.map (fun record -> Confirmed record) in
  let absent_outputs_evidence container_id =
    Printf.sprintf
      "exact owned container %s absent after confirmed launch; original outputs unrecoverable"
      container_id
  in
  match record.phase, observation with
  | Store.Create_requested, Backend.Created id -> settle (Store.Created id)
  | Store.Start_requested expected, Backend.Running id when id = expected ->
      settle (Store.Running id)
  | (Store.Start_requested expected | Store.Running expected), Backend.Stopped (id,exit_code)
      when id = expected -> settle (Store.Exited {container_id=id;exit_code})
  | Store.Created expected, Backend.Created id when id = expected -> settle record.phase
  | Store.Running expected, Backend.Running id when id = expected -> settle record.phase
  | Store.Exited {container_id;exit_code}, Backend.Stopped (id,code)
      when id = container_id && code = exit_code -> settle record.phase
  | (Store.Create_requested | Store.Created _ | Store.Start_requested _ | Store.Running _),
    Backend.Absent when record.cancel_requested ->
      settle Store.Cancelled_unconfirmed_launch
  | Store.Cancelled_unconfirmed_launch, Backend.Absent -> Ok (Confirmed record)
  | Store.Cancelled_unconfirmed_launch, (Backend.Created _ | Backend.Running _ | Backend.Stopped _) ->
      preserve Store.Cancelled_job_orphan
        "same-label container after a cancelled launch is an orphan; cancellation evidence is retained"
  | (Store.Running container_id | Store.Exited {container_id; _}), Backend.Absent ->
      (match record.outputs with
       | Some _ ->
           preserve Store.Backend_absent "saved backend job is absent; launch intent is retained, no relaunch"
       | None ->
           (* Exact inventory absence after a confirmed Running or Exited phase:
              the original container is gone, so its outputs (and, for Running,
              its final exit code) can never be observed. Close the result as
              Outputs_unavailable instead of Waiting forever. *)
           let evidence = absent_outputs_evidence container_id in
           Result.map (fun record -> Confirmed record)
             (save record ~phase:record.phase ~cancel_requested:record.cancel_requested
                ~outputs:(Some (Store.Outputs_unavailable {evidence}))
                ~detail:(Some evidence)))
  | (Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
      | Store.Running _ | Store.Exited _ | Store.Cancelled_before_start _
      | Store.Cancelled_unconfirmed_launch), Backend.Unconfirmed detail ->
      preserve Store.Backend_unconfirmed detail
  | (Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
      | Store.Cancelled_before_start _), Backend.Absent ->
      (* Termination policy for Absent without a cancel request (tracked in
         #42799 checklist "termination policy for Absent without cancellation").
         Chosen: (a) surface, not (b) time bound.
         - No relaunch: a same-label container may still appear late, so closing
           or retrying on a clock could run the job twice.
         - Return a typed Backend_absent hold with the exact current action.
           Public status retains it alongside the original phase, so a saved
           Created phase cannot appear ready after this refusal. No journal
           schema change is needed. Explicit cancellation closes via
           Cancelled_unconfirmed_launch above.
         Maintenance retains this typed hold in its process-local supervisor.
         An unchanged owner needs only a presence hint before deciding whether
         a new full inspection is necessary. *)
      preserve Store.Backend_absent "saved backend job is absent; launch intent is retained, no relaunch"
  | (Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
    | Store.Running _ | Store.Exited _ | Store.Cancelled_before_start _),
    (Backend.Created _ | Backend.Running _ | Backend.Stopped _) ->
      preserve Store.Backend_mismatch "backend observation differs from durable job phase or handle"

let backend_result record = function
  | Ok observation -> observe record observation
  | Error error -> Result.map (fun record -> Unconfirmed (record, Store.Backend_error))
      (note record (Backend.error_to_string error))

let collect (record : Store.record) =
  match record.phase, record.outputs with
  | Store.Exited {container_id;_}, None ->
      (match Backend.logs ~container_id record.preparation with
       | Error error -> note record (Backend.error_to_string error)
       | Ok logs ->
           save record ~phase:record.phase ~cancel_requested:record.cancel_requested
             ~outputs:(Some (Store.Outputs_complete (logs.stdout, logs.stderr))) ~detail:None)
  | (Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
    | Store.Running _ | Store.Cancelled_before_start _ | Store.Cancelled_unconfirmed_launch), _
  | Store.Exited _, Some _ -> Ok record

let collect_settlement = function
  | Unconfirmed _ as held -> Ok held
  | Confirmed record -> Result.map (fun record -> Confirmed record) (collect record)

let launch_created (record : Store.record) =
  match record.phase with
  | Store.Created id ->
      if record.cancel_requested then
        save record ~phase:(Store.Cancelled_before_start (Some id))
          ~cancel_requested:true ~outputs:None ~detail:None
        |> Result.map (fun record -> Confirmed record)
      else
        let* intent = save record ~phase:(Store.Start_requested id)
            ~cancel_requested:false ~outputs:None ~detail:None in
        let* settled = backend_result intent (Backend.start ~container_id:id intent.preparation) in
        collect_settlement settled
  | Store.Prepared | Store.Create_requested | Store.Start_requested _ | Store.Running _
  | Store.Exited _ | Store.Cancelled_before_start _ | Store.Cancelled_unconfirmed_launch ->
      Ok (Confirmed record)

let reconcile_settlement (record : Store.record) =
  match record.phase with
  | Store.Prepared ->
      if record.cancel_requested then
        save record ~phase:(Store.Cancelled_before_start None) ~cancel_requested:true
          ~outputs:None ~detail:None
        |> Result.map (fun record -> Confirmed record)
      else Ok (Confirmed record)
  | Store.Cancelled_before_start _ -> Ok (Confirmed record)
  | Store.Cancelled_unconfirmed_launch ->
      if record.cleanup <> Store.Resources_retained then Ok (Confirmed record)
      else observe record (Backend.inspect record.preparation)
  | Store.Create_requested | Store.Created _ | Store.Start_requested _
  | Store.Running _ | Store.Exited _ ->
      if Store.result_ready record then Ok (Confirmed record) else
      let* observed =
        if record.cancel_requested then match record.phase with
          | Store.Start_requested container_id | Store.Running container_id ->
              backend_result record (Backend.cancel ~container_id record.preparation)
          | Store.Create_requested | Store.Created _ | Store.Exited _ ->
              observe record (Backend.inspect record.preparation)
          | Store.Prepared | Store.Cancelled_before_start _
          | Store.Cancelled_unconfirmed_launch -> Ok (Confirmed record)
        else observe record (Backend.inspect record.preparation) in
      (match observed with
       | Unconfirmed _ -> Ok observed
       | Confirmed record -> let* started = launch_created record in collect_settlement started)

let reconcile record =
  Result.map record_of_settlement (reconcile_settlement record)

type held_absent = Store.record

let reconcile_for_recovery ?presence_round ?previous (record : Store.record) =
  let result = match previous with
    | Some held when held = record ->
        (match Backend.presence_hint ?round:presence_round record.preparation with
         | Backend.No_owned_container_seen ->
             Log.Keeper.debug "owned_job_recovery job_id=%s observation=presence_not_seen"
               (Store.Job_id.to_string record.job_id);
             Ok (Unconfirmed (record, Store.Backend_absent))
         | Backend.Owned_container_seen ->
             Log.Keeper.debug "owned_job_recovery job_id=%s observation=presence_seen_full_inspection"
               (Store.Job_id.to_string record.job_id);
             reconcile_settlement record
         | Backend.Presence_unavailable error ->
             Log.Keeper.debug "owned_job_recovery job_id=%s observation=presence_unavailable"
               (Store.Job_id.to_string record.job_id);
             backend_result record (Error error))
    | Some _ | None -> reconcile_settlement record
  in
  Result.map (fun settlement ->
    let held = match settlement with
      | Unconfirmed (record, Store.Backend_absent) -> Some record
      | Confirmed _
      | Unconfirmed (_, (Store.Backend_unconfirmed | Store.Backend_mismatch
          | Store.Cancelled_job_orphan | Store.Backend_error)) -> None
    in
    record_of_settlement settlement, held) result

let rec cleanup (record : Store.record) =
  let next state = let* record = Store.advance_cleanup record state in cleanup record in
  let run_cleanup operation confirmed =
    match operation () with
    | Ok () -> next confirmed
    | Error error ->
      let detail = Backend.error_to_string error in
      let* _ = note record detail in
      Error (Store.Invalid_authority detail)
  in
  match record.cleanup with
  | Store.Resources_retained -> next Store.Container_removal_requested
  | Store.Container_removal_requested ->
    let* target = match record.phase, record.outputs with
      | Store.Exited {container_id;exit_code}, _ -> Ok (Backend.After_exit {container_id;exit_code})
      | Store.Running id, Some (Store.Outputs_unavailable _) -> Ok (Backend.Absent_after_launch id)
      | Store.Cancelled_before_start (Some id), _ -> Ok (Backend.Before_start id)
      | (Store.Cancelled_before_start None | Store.Cancelled_unconfirmed_launch), _ -> Ok Backend.Never_created
      | (Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _), _
      | Store.Running _, (None | Some (Store.Outputs_complete _)) ->
        Error (Store.Invalid_authority "resource cleanup requires the original terminal handle") in
    run_cleanup (fun () -> Backend.remove_container ~target record.preparation) Store.Container_removed
  | Store.Container_removed -> next Store.Data_removal_requested
  | Store.Data_removal_requested -> run_cleanup (fun () -> Backend.remove_data record.preparation) Store.Resources_removed
  | Store.Resources_removed -> Ok record

let launch (record : Store.record) =
  let* intent = save record ~phase:Store.Create_requested ~cancel_requested:false
      ~outputs:None ~detail:None in
  let* settled = backend_result intent (Backend.create intent.preparation) in
  match settled with
  | Confirmed record -> launch_created record
  | Unconfirmed _ -> Ok settled

let inputs_of_json = function
  | None -> Ok []
  | Some (`List values) ->
      let decode = function
        | `Assoc fields when List.sort String.compare (List.map fst fields) = ["artifact";"path"] ->
            (match List.assoc_opt "path" fields, List.assoc_opt "artifact" fields with
             | Some (`String path), Some value ->
                 (match Tool_output.normalized_artifact_ref_of_json value with
                  | Tool_output.Decoded_normalized_artifact_ref artifact -> Ok Store.{path;artifact}
                  | Tool_output.Not_normalized_artifact_ref -> Error "input is not a normalized artifact"
                  | Tool_output.Invalid_normalized_artifact_ref {detail} -> Error detail)
             | _ -> Error "input requires path and artifact")
        | _ -> Error "input has missing, duplicate or unknown fields" in
      let rec loop = function [] -> Ok [] | value :: rest ->
        let* value = decode value in let* rest = loop rest in Ok (value :: rest) in loop values
  | Some _ -> Error "inputs must be an array"

let start_arguments = function
  | `Assoc fields when
      List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
      && List.for_all (fun (name,_) -> List.mem name ["argv";"inputs"]) fields ->
      let* argv = match List.assoc_opt "argv" fields with
        | Some (`List ((`String program) :: rest)) when program <> "" ->
            let rec strings = function [] -> Ok [] | `String arg :: rest ->
              let* rest = strings rest in Ok (arg :: rest)
              | _ -> Error "argv must contain strings" in
            let* args = strings rest in Ok (program :: args)
        | _ -> Error "argv requires a program and its arguments" in
      let* inputs = inputs_of_json (List.assoc_opt "inputs" fields) in Ok (argv,inputs)
  | _ -> Error "invalid job start object"

let job_argument = function
  | `Assoc ["job_id", `String id] -> Store.Job_id.of_string id
  | _ -> Error "job_id is the only accepted field"

let failure ?job_id ~effect_disposition class_ message =
  match job_id with
  | None -> Keeper_tool_execution.failure ~class_ ~effect_disposition message
  | Some job_id -> Keeper_tool_execution.failure_data ~class_ ~effect_disposition
      ~message (`Assoc ["job_id", `String (Store.Job_id.to_string job_id)])

let finish ~tool_name ~start_time ~job_id = function
  | Ok settled ->
      let record = record_of_settlement settled in
      let retained_artifacts = match record.outputs with
        | Some (Store.Outputs_complete (stdout, stderr)) -> [stdout; stderr]
        | Some (Store.Outputs_unavailable _) | None -> [] in
      let result = Tool_result.make_ok ~tool_name ~start_time
          ~data:(Store.result_json ~reconciliation:(reconciliation_of_settlement settled) record) ()
        |> Tool_result.with_retained_artifacts retained_artifacts in
      (match Tool_bridge.attach_artifact_manifest
          ~projection:Tool_output.Inline_with_structured_diagnostic
          ~base_path:record.base_path result with
       | Ok result -> Keeper_tool_execution.of_tool_result result
       | Error error -> failure ~job_id
           ~effect_disposition:Tool_result.Effect_outcome_unknown
           Tool_result.Runtime_failure
           ("Job result manifest publication failed; the durable job handle is retained. "
            ^ "Read keeper_job_status for the same job_id; do not start a replacement job. "
            ^ error.Tool_bridge.message))
  | Error error -> failure ~job_id ~effect_disposition:Tool_result.Effect_outcome_unknown
      Tool_result.Runtime_failure (Store.error_to_string error)

let handle ~config ~meta ~owned_job_replay ~source_context ~continuation_channel ~tool_use_id ~turn_ref ~trace_id ~name ~args =
  let start_time = Tool_timing.start () in
  let invalid message = failure ~effect_disposition:Tool_result.Proven_pre_effect
      Tool_result.Policy_rejection message in
  match Tool_schemas_owned_job.find_definition name with
  | None -> invalid "unknown owned job tool"
  | Some {action=Tool_schemas_owned_job.Start;_} ->
      (match start_arguments args with
       | Error detail -> invalid detail
       | Ok (argv,inputs) ->
           let trace_id = match source_context with
             | Some context -> context.Keeper_tool_call_log_context.trace_id
             | None -> trace_id in
           let turn_ref = match turn_ref, source_context with
             | Some _, _ -> turn_ref
             | None, Some context ->
                 (match context.Keeper_tool_call_log_context.trace_id, context.turn with
                  | Some trace_id, Some absolute_turn -> Some (Ids.Turn_ref.make ~trace_id ~absolute_turn)
                  | None, _ | _, None -> None)
             | None, None -> None in
           let current_source = Store.
             { task_id = Option.bind source_context (fun context -> context.Keeper_tool_call_log_context.task_id)
             ; keeper_turn_id = Option.bind source_context (fun context -> context.Keeper_tool_call_log_context.keeper_turn_id)
             ; turn_ref; tool_use_id; trace_id } in
           let source = match owned_job_replay with
             | Some replay -> Invocation.replay_source replay
             | None -> current_source in
           let prepare job_id =
             let* base_path = Store.canonical_base_path config.Workspace.base_path in
             let* paths = Store.prepare_workspace ~base_path job_id inputs in
             let spec = Backend.{job_id=Store.Job_id.to_string job_id;keeper_name=meta.Keeper_meta_contract.name;
                                 base_path;workspace_host_path=paths.workspace;argv} in
             let* preparation = Backend.prepare ~config ~meta ~docker_config_path:paths.cli_config_dir spec
                 |> Result.map_error (fun error -> Store.Invalid_authority (Backend.error_to_string error)) in
             let completion_channel = match continuation_channel with
               | Some channel -> channel
               | None -> Keeper_continuation_channel.unrouted "job invocation did not capture an originating channel" in
             Store.create ~base_path ~keeper_name:meta.name ~job_id ~source ~completion_channel ~preparation ~inputs in
           let start_new job_id = match prepare job_id with
             | Error error -> failure ~job_id ~effect_disposition:Tool_result.Proven_pre_effect
                 Tool_result.Runtime_failure (Store.error_to_string error)
             | Ok record -> finish ~tool_name:name ~start_time ~job_id (launch record) in
           (match Invocation.invocation_of_source source with
            | Error detail -> invalid detail
            | Ok invocation ->
           let reservation = match owned_job_replay with
             | Some replay ->
                 (match Invocation.reserve_existing ~base_path:config.base_path ~keeper_name:meta.name
                     replay ~argv ~inputs with
                  | Ok prior -> Ok (Some (Invocation.Existing prior))
                  | Error ({cause=Store.Missing;_} as missing) ->
                      (match Store.source_absent ~base_path:config.base_path ~keeper_name:meta.name
                          ~source:(Invocation.replay_source replay), invocation with
                       | Ok true, Some invocation ->
                           Invocation.reserve ~base_path:config.base_path ~keeper_name:meta.name
                             ~invocation ~source ~argv ~inputs |> Result.map Option.some
                       | Ok true, None | Ok false, _ -> Error missing
                       | Error cause, _ -> Error {job_id=None;cause})
                  | Error ({cause=(Store.Invalid_authority _ | Store.Corrupt _ | Store.Conflict
                      | Store.Io_failed _ | Store.Commit_unconfirmed _);_} as error) -> Error error)
             | None ->
                 (match invocation with
                  | None -> Ok None
                  | Some invocation ->
                      Invocation.reserve ~base_path:config.base_path ~keeper_name:meta.name
                        ~invocation ~source ~argv ~inputs |> Result.map Option.some) in
           (match reservation with
            | Ok None -> start_new (Store.Job_id.fresh ())
            | Ok (Some (Invocation.Fresh reservation)) -> start_new reservation.job_id
            | Error error -> failure ?job_id:error.Invocation.job_id
                ~effect_disposition:Tool_result.Effect_outcome_unknown
                Tool_result.Policy_rejection (Store.error_to_string error.cause)
            | Ok (Some (Invocation.Existing reservation)) ->
              let job_id = reservation.job_id in
              let result =
                let* record = Store.load ~base_path:reservation.base_path
                    ~keeper_name:reservation.keeper_name job_id in
                let spec = Backend.specification record.preparation in
                if Store.source_to_json record.source <> Store.source_to_json reservation.source
                   || spec.argv <> argv || record.inputs <> inputs
                then Error (Store.Invalid_authority "invocation binding differs from its original job journal")
                else match record.phase with
                  | Store.Prepared when not record.cancel_requested -> launch record
                  | Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
                  | Store.Running _ | Store.Exited _ | Store.Cancelled_before_start _
                  | Store.Cancelled_unconfirmed_launch -> reconcile_settlement record in
              finish ~tool_name:name ~start_time ~job_id result)))
  | Some {action=Tool_schemas_owned_job.Read_result;_} ->
      (match job_argument args with
       | Error detail -> invalid detail
       | Ok job_id ->
           (match Store.load ~base_path:config.Workspace.base_path ~keeper_name:meta.name job_id with
            | Error error -> failure ~job_id ~effect_disposition:Tool_result.Proven_pre_effect
                Tool_result.Policy_rejection (Store.error_to_string error)
            | Ok record ->
                if Store.result_ready record then
                  finish ~tool_name:name ~start_time ~job_id (Ok (Confirmed record))
                else
                  Keeper_tool_execution.deferred_owned_job_result ~job_id (Store.result_json record)))
  | Some {action=(Tool_schemas_owned_job.Status | Tool_schemas_owned_job.Cancel) as action;_} ->
      (match job_argument args with
       | Error detail -> invalid detail
       | Ok job_id ->
           (match Store.load ~base_path:config.Workspace.base_path ~keeper_name:meta.name job_id with
            | Error error -> failure ~job_id ~effect_disposition:Tool_result.Proven_pre_effect
                Tool_result.Policy_rejection (Store.error_to_string error)
            | Ok record ->
                let result =
                  let* record = match action with
                    | Tool_schemas_owned_job.Cancel -> save record ~phase:record.phase
                        ~cancel_requested:true ~outputs:record.outputs ~detail:record.detail
                    | Tool_schemas_owned_job.Status -> Ok record
                    | Tool_schemas_owned_job.Start | Tool_schemas_owned_job.Read_result ->
                        Error (Store.Invalid_authority "action is not reconciliation") in
                  reconcile_settlement record in finish ~tool_name:name ~start_time ~job_id result))
