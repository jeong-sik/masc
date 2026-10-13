module Store = Keeper_owned_job_store
module Backend = Keeper_owned_job_backend
let ( let* ) = Result.bind

let save (record : Store.record) ~phase ~cancel_requested ~outputs ~detail =
  if phase = record.phase && cancel_requested = record.cancel_requested
     && outputs = record.outputs && detail = record.detail
  then Ok record
  else Store.transition record ~phase ~cancel_requested ~outputs ~detail

let note (record : Store.record) detail =
  save record ~phase:record.phase ~cancel_requested:record.cancel_requested
    ~outputs:record.outputs ~detail:(Some detail)

type settlement = Confirmed of Store.record | Unconfirmed of Store.record
let record_of_settlement = function Confirmed record | Unconfirmed record -> record

let observe (record : Store.record) observation =
  let preserve detail = Result.map (fun record -> Unconfirmed record) (note record detail) in
  let settle phase = save record ~phase ~cancel_requested:record.cancel_requested
      ~outputs:record.outputs ~detail:None |> Result.map (fun record -> Confirmed record) in
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
  | _, Backend.Unconfirmed detail -> preserve detail
  | _, Backend.Absent -> preserve "saved backend job is absent; launch intent is retained, no relaunch"
  | _, (Backend.Created _ | Backend.Running _ | Backend.Stopped _) ->
      preserve "backend observation differs from durable job phase or handle"

let backend_result record = function
  | Ok observation -> observe record observation
  | Error error -> Result.map (fun record -> Unconfirmed record)
      (note record (Backend.error_to_string error))

let collect (record : Store.record) =
  match record.phase, record.outputs with
  | Store.Exited {container_id;_}, None ->
      (match Backend.logs ~container_id record.preparation with
       | Error error -> note record (Backend.error_to_string error)
       | Ok logs ->
           save record ~phase:record.phase ~cancel_requested:record.cancel_requested
             ~outputs:(Some (logs.stdout,logs.stderr)) ~detail:None)
  | (Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
    | Store.Running _ | Store.Cancelled_before_start _), _
  | Store.Exited _, Some _ -> Ok record

let launch_created (record : Store.record) =
  match record.phase with
  | Store.Created id ->
      if record.cancel_requested then
        save record ~phase:(Store.Cancelled_before_start (Some id))
          ~cancel_requested:true ~outputs:None ~detail:None
      else
        let* intent = save record ~phase:(Store.Start_requested id)
            ~cancel_requested:false ~outputs:None ~detail:None in
        let* settled = backend_result intent (Backend.start ~container_id:id intent.preparation) in
        (match settled with Confirmed observed -> collect observed
         | Unconfirmed observed -> Ok observed)
  | Store.Prepared | Store.Create_requested | Store.Start_requested _ | Store.Running _
  | Store.Exited _ | Store.Cancelled_before_start _ -> Ok record

let reconcile (record : Store.record) =
  match record.phase with
  | Store.Prepared ->
      if record.cancel_requested then
        save record ~phase:(Store.Cancelled_before_start None) ~cancel_requested:true
          ~outputs:None ~detail:None
      else Ok record
  | Store.Cancelled_before_start _ -> Ok record
  | Store.Create_requested | Store.Created _ | Store.Start_requested _
  | Store.Running _ | Store.Exited _ ->
      let* observed =
        if record.cancel_requested then match record.phase with
          | Store.Start_requested container_id | Store.Running container_id ->
              backend_result record (Backend.cancel ~container_id record.preparation)
          | Store.Create_requested | Store.Created _ | Store.Exited _ ->
              observe record (Backend.inspect record.preparation)
          | Store.Prepared | Store.Cancelled_before_start _ -> Ok (Confirmed record)
        else observe record (Backend.inspect record.preparation) in
      (match observed with
       | Unconfirmed record -> Ok record
       | Confirmed record -> let* started = launch_created record in collect started)

let launch (record : Store.record) =
  let* intent = save record ~phase:Store.Create_requested ~cancel_requested:false
      ~outputs:None ~detail:None in
  let* settled = backend_result intent (Backend.create intent.preparation) in
  match settled with Confirmed record -> launch_created record
  | Unconfirmed _ -> Ok (record_of_settlement settled)

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

let finish ~job_id = function
  | Ok record -> Keeper_tool_execution.success_data (Store.result_json record)
  | Error error -> failure ~job_id ~effect_disposition:Tool_result.Effect_outcome_unknown
      Tool_result.Runtime_failure (Store.error_to_string error)

let handle ~config ~meta ~source_context ~tool_use_id ~turn_ref ~trace_id ~name ~args =
  let invalid message = failure ~effect_disposition:Tool_result.Proven_pre_effect
      Tool_result.Policy_rejection message in
  match Tool_schemas_owned_job.find_definition name with
  | None -> invalid "unknown owned job tool"
  | Some {action=Tool_schemas_owned_job.Start;_} ->
      (match start_arguments args with
       | Error detail -> invalid detail
       | Ok (argv,inputs) ->
           let job_id = Store.Job_id.fresh () in
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
           let source = Store.
             { task_id = Option.bind source_context (fun context -> context.Keeper_tool_call_log_context.task_id)
             ; keeper_turn_id = Option.bind source_context (fun context -> context.Keeper_tool_call_log_context.keeper_turn_id)
             ; turn_ref; tool_use_id; trace_id } in
           let prepare () =
             let* base_path = Store.canonical_base_path config.Workspace.base_path in
             let* paths = Store.prepare_workspace ~base_path job_id inputs in
             let spec = Backend.{job_id=Store.Job_id.to_string job_id;keeper_name=meta.Keeper_meta_contract.name;
                                 base_path;workspace_host_path=paths.workspace;argv} in
             let* preparation = Backend.prepare ~config ~meta ~docker_config_path:paths.cli_config_dir spec
                 |> Result.map_error (fun error -> Store.Invalid_authority (Backend.error_to_string error)) in
             Store.create ~base_path ~keeper_name:meta.name ~job_id ~source ~preparation ~inputs in
           (match prepare () with
            | Error error -> failure ~job_id ~effect_disposition:Tool_result.Proven_pre_effect
                Tool_result.Runtime_failure (Store.error_to_string error)
            | Ok record -> finish ~job_id (launch record)))
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
                    | Tool_schemas_owned_job.Start -> Error (Store.Invalid_authority "start is not reconciliation") in
                  reconcile record in finish ~job_id result))
