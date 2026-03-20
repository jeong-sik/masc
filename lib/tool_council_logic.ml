(** Council tools — business logic for Governance V2 rulings and execution. *)

open Yojson.Safe.Util
open Tool_council_helpers

module GV2 = Council.Governance_v2

let collect_evidence_refs (bundle : GV2.case_bundle) =
  let petition_refs =
    bundle.GV2.petitions
    |> List.concat_map (fun (petition : GV2.petition) -> petition.GV2.source_refs)
  in
  let brief_refs =
    bundle.GV2.case_.GV2.briefs
    |> List.concat_map (fun (brief : GV2.case_brief) -> brief.GV2.evidence_refs)
  in
  List.sort_uniq String.compare (petition_refs @ brief_refs)

let build_ruling (bundle : GV2.case_bundle) : GV2.ruling =
  let support_count =
    bundle.GV2.case_.GV2.briefs
    |> List.filter (fun brief -> brief.GV2.stance = GV2.Support)
    |> List.length
  in
  let oppose_count =
    bundle.GV2.case_.GV2.briefs
    |> List.filter (fun brief -> brief.GV2.stance = GV2.Oppose)
    |> List.length
  in
  let evidence_refs = collect_evidence_refs bundle in
  let generated_at = Time_compat.now () in
  let base_summary, confidence, auto_execution_state =
    if bundle.GV2.case_.GV2.briefs = [] then
      ( "Petition filed. Awaiting briefs before a ruling can trigger execution.",
        0.0,
        "pending_ruling" )
    else if support_count = 0 || oppose_count >= support_count then
      ( "Opposition is not resolved. Keep the case open but block execution until a stronger brief wins.",
        0.48,
        "blocked" )
    else
      match bundle.GV2.case_.GV2.risk_class with
      | GV2.High ->
          ( "Ruling supports execution, but the requested action is high risk and requires human confirmation.",
            0.86,
            "needs_human_gate" )
      | GV2.Low ->
          ( "Ruling supports execution and the request is low risk, so the order can be executed automatically.",
            0.86,
            "queued_auto" )
  in
  ({
     id = gen_id "ruling";
     case_id = bundle.GV2.case_.id;
     status =
       if auto_execution_state = "blocked" then "blocked"
       else if auto_execution_state = "pending_ruling" then "pending"
       else "approved";
     summary = base_summary;
     confidence;
     provenance = "judgment";
     generated_at;
     expires_at = Some (generated_at +. 300.0);
     keeper_name = "governance-judge";
     model_used = Some "heuristic:governance_v2";
     risk_class = bundle.GV2.case_.GV2.risk_class;
     evidence_refs;
     recommended_action = bundle.GV2.case_.GV2.requested_action;
     auto_execution_state;
   }
    : GV2.ruling)

let build_execution_order (bundle : GV2.case_bundle) (ruling : GV2.ruling) :
    GV2.execution_order option =
  match ruling.GV2.recommended_action with
  | None -> None
  | Some request ->
      let status =
        match ruling.GV2.auto_execution_state with
        | "needs_human_gate" -> GV2.Needs_human_gate_order
        | "queued_auto" -> GV2.Queued_auto
        | "blocked" -> GV2.Blocked_order
        | _ -> GV2.Blocked_order
      in
      Some
        ({
           id = gen_id "order";
           case_id = bundle.GV2.case_.id;
           status;
           risk_class = bundle.GV2.case_.GV2.risk_class;
           action_request = Some request;
           created_at = Time_compat.now ();
           updated_at = Time_compat.now ();
           execution_ref = None;
           result_summary = None;
           actor = None;
         }
          : GV2.execution_order)

let prepare_operation_payload case_title target_id payload =
  let payload_assoc =
    match payload with
    | Some (`Assoc fields) -> fields
    | Some _ | None -> []
  in
  let has_field key = List.exists (fun (field, _) -> String.equal field key) payload_assoc in
  let fields =
    payload_assoc
    |> (fun fields ->
         if has_field "objective" then fields
         else ("objective", `String case_title) :: fields)
    |> (fun fields ->
         if has_field "assigned_unit_id" then fields
         else
           match target_id with
           | Some value when String.trim value <> "" ->
               ("assigned_unit_id", `String value) :: fields
           | _ -> fields)
  in
  `Assoc fields

let execute_action ctx (case_ : GV2.case_record) (order : GV2.execution_order) =
  match order.GV2.action_request with
  | None -> Error "execution order has no action_request"
  | Some request -> (
      match String.lowercase_ascii request.GV2.action_type with
      | "add_task" ->
          let room_config = ensure_room_ready ctx in
          let payload = request.GV2.payload |> Option.value ~default:(`Assoc []) in
          let title =
            payload |> member "title" |> to_string_option |> Option.value ~default:case_.title
          in
          let description =
            payload |> member "description" |> to_string_option |> Option.value ~default:""
          in
          let priority =
            payload |> member "priority" |> to_int_option |> Option.value ~default:2
          in
          let result =
            Room.add_task room_config ~title ~priority ~description
          in
          let execution_ref =
            match extract_task_id result with
            | Some task_id -> Some task_id
            | None ->
                if contains_text result "task-" then Some result else None
          in
          Ok
            {
              order with
              status =
                (match order.GV2.status with
                | GV2.Queued_auto -> GV2.Auto_executed
                | _ -> GV2.Done);
              updated_at = Time_compat.now ();
              execution_ref;
              result_summary = Some result;
              actor = Some ctx.agent_name;
            }
      | "start_operation" ->
          let room_config = ensure_room_ready ctx in
          let payload =
            prepare_operation_payload case_.title request.GV2.target_id request.GV2.payload
          in
          (match
             Command_plane_v2.start_operation
               room_config
               ~actor:ctx.agent_name payload
           with
          | Ok operation ->
              let result =
                Printf.sprintf
                  "Started managed operation %s: %s"
                  operation.operation_id operation.objective
              in
              Ok
                {
                  order with
                  status =
                    (match order.GV2.status with
                    | GV2.Queued_auto -> GV2.Auto_executed
                    | _ -> GV2.Done);
                  updated_at = Time_compat.now ();
                  execution_ref = Some operation.operation_id;
                  result_summary = Some result;
                  actor = Some ctx.agent_name;
                }
          | Error message -> Error message)
      | "set_param" ->
          let payload = request.GV2.payload |> Option.value ~default:(`Assoc []) in
          let param_key =
            payload |> member "param_key" |> to_string_option
            |> Option.value ~default:""
          in
          let value = payload |> member "value" in
          if String.trim param_key = "" then
            Error "set_param requires param_key in payload"
          else (
            let old_value =
              match Runtime_params.registry ()
                    |> List.find_opt (fun (k, _, _, _) -> k = param_key) with
              | Some (_, current, _, _) -> current
              | None -> `Null
            in
            match Runtime_params.set_by_key param_key value with
            | Ok () ->
                (* Persist and audit *)
                Runtime_params.persist ~base_path:ctx.base_path;
                Runtime_params.record_audit ~base_path:ctx.base_path
                  ~key:param_key ~old_value ~new_value:value
                  ?case_id:(Some case_.GV2.id) ~actor:ctx.agent_name ();
                (* SSE broadcast *)
                Sse.broadcast
                  (`Assoc
                     [
                       ("type", `String "governance_param_changed");
                       ("param_key", `String param_key);
                       ("old_value", old_value);
                       ("new_value", value);
                       ("case_id", `String case_.GV2.id);
                       ("actor", `String ctx.agent_name);
                     ]);
                let result_msg =
                  Printf.sprintf "Set %s = %s" param_key
                    (Yojson.Safe.to_string value)
                in
                Ok
                  {
                    order with
                    status =
                      (match order.GV2.status with
                      | GV2.Queued_auto -> GV2.Auto_executed
                      | _ -> GV2.Done);
                    updated_at = Time_compat.now ();
                    execution_ref = Some param_key;
                    result_summary = Some result_msg;
                    actor = Some ctx.agent_name;
                  }
            | Error msg ->
                Error (Printf.sprintf "set_param failed for %s: %s" param_key msg))
      | "release_task" ->
          let room_config = ensure_room_ready ctx in
          let task_id =
            resolve_target_id ?payload:request.GV2.payload ~prefix:"task-" case_
              request
          in
          (match task_id with
          | None | Some "" -> Error "release_task requires target_id or task-* source_ref"
          | Some task_id -> (
              match
                Room.force_release_task_r room_config ~agent_name:ctx.agent_name
                  ~task_id ()
              with
              | Ok result ->
                  Ok
                    {
                      order with
                      status =
                        (match order.GV2.status with
                        | GV2.Queued_auto -> GV2.Auto_executed
                        | _ -> GV2.Done);
                      updated_at = Time_compat.now ();
                      execution_ref = Some task_id;
                      result_summary = Some result;
                      actor = Some ctx.agent_name;
                    }
              | Error e ->
                  Error
                    (Printf.sprintf "release_task failed for %s: %s" task_id
                       (Types.masc_error_to_string e))))
      | "flag_post" ->
          let post_id =
            resolve_target_id ?payload:request.GV2.payload ~prefix:"post-" case_
              request
          in
          (match post_id with
          | None | Some "" -> Error "flag_post requires target_id or post-* source_ref"
          | Some post_id -> (
              match Board_dispatch.delete_post ~post_id with
              | Ok () ->
                  let result_msg =
                    Printf.sprintf "Hard-deleted board artifact %s" post_id
                  in
                  Ok
                    {
                      order with
                      status =
                        (match order.GV2.status with
                        | GV2.Queued_auto -> GV2.Auto_executed
                        | _ -> GV2.Done);
                      updated_at = Time_compat.now ();
                      execution_ref = Some post_id;
                      result_summary = Some result_msg;
                      actor = Some ctx.agent_name;
                    }
              | Error err ->
                  Error
                    (Printf.sprintf "flag_post failed for %s: %s" post_id
                       (Board.show_board_error err))))
      | "restart_keeper" ->
          let room_config = ensure_room_ready ctx in
          let keeper_name =
            resolve_target_id ?payload:request.GV2.payload ~prefix:"keeper-" case_
              request
          in
          (match keeper_name with
          | None | Some "" ->
              Error "restart_keeper requires target_id or keeper-* source_ref"
          | Some keeper_name -> (
              match Keeper_types.read_meta room_config keeper_name with
              | Error msg -> Error msg
              | Ok None ->
                  Error
                    (Printf.sprintf "restart_keeper target not found: %s"
                       keeper_name)
              | Ok (Some meta) ->
                  Keeper_runtime.stop_keepalive keeper_name;
                  ignore
                    (Keeper_types.register_resident_keeper_from_meta room_config
                       meta);
                  let result_msg =
                    Printf.sprintf
                      "Stopped keepalive for %s. Desired resident state remains true and keeper reconcile will bring it back."
                      keeper_name
                  in
                  Ok
                    {
                      order with
                      status =
                        (match order.GV2.status with
                        | GV2.Queued_auto -> GV2.Auto_executed
                        | _ -> GV2.Done);
                      updated_at = Time_compat.now ();
                      execution_ref = Some keeper_name;
                      result_summary = Some result_msg;
                      actor = Some ctx.agent_name;
                    }))
      | action_type ->
          Error
            (Printf.sprintf
               "unsupported execution action_type for governance v2: '%s'. \
                Supported: add_task, start_operation, set_param, release_task, \
                flag_post, restart_keeper"
               (String.trim action_type)))
