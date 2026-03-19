(** Council tools - Governance V2 petition/case/ruling surface. *)

open Yojson.Safe.Util
open Tool_args
open Tool_council_json

module GV2 = Council.Governance_v2

type context = {
  base_path : string;
  agent_name : string;
  room_config : Room.config option;
}

type result = bool * string

let gen_id prefix =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF in
  Printf.sprintf "%s-%d-%06x" prefix ts hash

let room_config_of_ctx (ctx : context) =
  match ctx.room_config with
  | Some config -> config
  | None -> Room.default_config ctx.base_path

let ensure_room_ready (ctx : context) =
  let config = room_config_of_ctx ctx in
  if not (Room.is_initialized config) then
    ignore (Room.init config ~agent_name:(Some ctx.agent_name));
  config

let contains_text haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= hay_len
    && ((String.sub haystack idx needle_len = needle) || loop (idx + 1))
  in
  needle_len = 0 || loop 0

let extract_task_id text =
  let len = String.length text in
  let rec seek idx =
    if idx + 5 > len then None
    else if String.sub text idx 5 = "task-" then
      let stop = ref (idx + 5) in
      while
        !stop < len
        &&
        match text.[!stop] with
        | '0' .. '9' -> true
        | _ -> false
      do
        incr stop
      done;
      if !stop > idx + 5 then Some (String.sub text idx (!stop - idx))
      else seek (idx + 1)
    else seek (idx + 1)
  in
  seek 0

let first_some left right =
  match left with Some _ -> left | None -> right

let supported_execution_action_types =
  [
    "add_task";
    "start_operation";
    "set_param";
    "release_task";
    "restart_keeper";
    "flag_post";
  ]

let resolve_target_id ?payload ~prefix (case_ : GV2.case_record)
    (request : GV2.action_request) =
  let payload_target =
    match payload with
    | Some payload ->
        payload |> member "target_id" |> to_string_option
        |> fun value -> first_some value (payload |> member "task_id" |> to_string_option)
        |> fun value -> first_some value (payload |> member "post_id" |> to_string_option)
        |> fun value -> first_some value (payload |> member "keeper_name" |> to_string_option)
    | None -> None
  in
  let from_source_refs =
    case_.GV2.source_refs
    |> List.find_map (fun ref_ ->
           if String.starts_with ~prefix ref_ && String.length ref_ > String.length prefix
           then
             Some
               (String.sub ref_ (String.length prefix)
                  (String.length ref_ - String.length prefix))
           else None)
  in
  request.GV2.target_id |> fun value -> first_some value payload_target
  |> fun value -> first_some value from_source_refs

let parse_requested_action args =
  match member "requested_action" args with
  | `Null -> Ok None
  | (`Assoc _ as value) ->
      let action_type =
        value |> member "action_type" |> to_string_option |> Option.value ~default:""
        |> String.trim
      in
      if action_type = "" then
        Error "requested_action.action_type is required"
      else if
        not
          (List.mem
             (String.lowercase_ascii action_type)
             supported_execution_action_types)
      then
        Error
          (Printf.sprintf
             "unsupported requested_action.action_type: %s"
             action_type)
      else
        let payload =
          match value |> member "payload" with
          | `Null -> None
          | payload -> Some payload
        in
        Ok
          (Some
             ({
                action_type;
                target_type = value |> member "target_type" |> to_string_option;
                target_id = value |> member "target_id" |> to_string_option;
                payload;
              }
               : GV2.action_request))
  | _ -> Error "requested_action must be an object"

let high_risk_action_types =
  [
    "delete";
    "reset";
    "merge";
    "room_pause";
    "room_resume";
    "team_stop";
    "keeper_recover";
    "swarm_run_continue";
    "swarm_run_rerun";
    "swarm_run_abandon";
  ]

let derive_risk_class args requested_action =
  match get_string args "risk_class" "" |> String.lowercase_ascii with
  | "low" -> Ok GV2.Low
  | "high" -> Ok GV2.High
  | "" -> (
      match requested_action with
      | Some request
        when List.mem
               (String.lowercase_ascii request.GV2.action_type)
               high_risk_action_types ->
          Ok GV2.High
      | _ -> Ok GV2.Low)
  | value -> Error (Printf.sprintf "invalid risk_class: %s" value)

let parse_stance args =
  match get_string args "stance" "support" |> String.lowercase_ascii with
  | "support" -> Ok GV2.Support
  | "oppose" -> Ok GV2.Oppose
  | "neutral" -> Ok GV2.Neutral
  | value -> Error (Printf.sprintf "invalid stance: %s" value)

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
                      "Stopped keepalive for %s. Desired resident state remains true and guardian reconcile will bring it back."
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
               "unsupported execution action_type for governance v2: %s"
               action_type))

(* TODO(M-13): V1 governance tools (debate, consensus, sessions) are deprecated.
   Full removal requires auditing all callers and cleaning up the Debate/Consensus
   modules in lib/council/. For now, log a deprecation warning and return an error
   directing callers to V2 equivalents.
   V1 tools: masc_debate_start, masc_debate_argue, masc_debate_close,
             masc_debate_status, masc_debates, masc_consensus_start,
             masc_consensus_vote, masc_consensus_close, masc_consensus_result,
             masc_sessions *)
let removed_surface name =
  Log.Governance.warn "DEPRECATED V1 tool called: %s — migrate to Governance V2" name;
  ( false,
    Printf.sprintf
      "%s removed in Governance V2. Use masc_petition_submit, masc_case_brief_submit, masc_cases, masc_case_status, masc_ruling_status, or masc_execution_orders."
      name )

let handle_petition_submit ctx args =
  let title = get_string args "title" "" in
  if String.trim title = "" then
    (false, "title is required")
  else
    match parse_requested_action args with
    | Error message -> (false, message)
    | Ok requested_action -> (
        match derive_risk_class args requested_action with
        | Error message -> (false, message)
        | Ok risk_class ->
            let origin =
              let value = get_string args "origin" "human" |> String.trim in
              if value = "" then "human" else value
            in
            let subject_type =
              let value = get_string args "subject_type" "task" |> String.trim in
              if value = "" then "task" else value
            in
            let source_refs = get_string_list args "source_refs" in
            match
              GV2.submit_petition ctx.base_path ~title ~origin ~subject_type
                ~risk_class ~requested_action ~source_refs
                ~created_by:ctx.agent_name
            with
            | Error message -> (false, message)
            | Ok result -> (
                match GV2.get_case_bundle ctx.base_path result.case_.id with
                | Error message -> (false, message)
                | Ok bundle ->
                    let ruling = build_ruling bundle in
                    let _ = GV2.save_ruling ctx.base_path ruling in
                    let json =
                      `Assoc
                        [
                          ("petition", petition_json result.petition);
                          ("case", case_json result.case_);
                          ("merged", `Bool result.merged);
                          ("ruling", ruling_json ruling);
                        ]
                    in
                    (true, Yojson.Safe.pretty_to_string json)))

let handle_case_brief_submit ctx args =
  let case_id = get_string args "case_id" "" in
  let summary = get_string args "summary" "" in
  if String.trim case_id = "" || String.trim summary = "" then
    (false, "case_id and summary are required")
  else
    match parse_stance args with
    | Error message -> (false, message)
    | Ok stance ->
        let evidence_refs = get_string_list args "evidence_refs" in
        (match
           GV2.submit_brief ctx.base_path ~case_id ~author:ctx.agent_name ~stance
             ~summary ~evidence_refs
         with
        | Error message -> (false, message)
        | Ok _case -> (
            match GV2.get_case_bundle ctx.base_path case_id with
            | Error message -> (false, message)
            | Ok bundle ->
                let ruling = build_ruling bundle in
                let _ = GV2.save_ruling ctx.base_path ruling in
                let order =
                  match build_execution_order bundle ruling with
                  | None -> None
                  | Some initial_order -> (
                      let _ = GV2.save_execution_order ctx.base_path initial_order in
                      match initial_order.GV2.status with
                      | GV2.Queued_auto -> (
                          match execute_action ctx bundle.GV2.case_ initial_order with
                          | Ok executed_order ->
                              let _ = GV2.update_execution_order ctx.base_path executed_order in
                              Some executed_order
                          | Error message ->
                              let blocked_order =
                                {
                                  initial_order with
                                  status = GV2.Blocked_order;
                                  updated_at = Time_compat.now ();
                                  result_summary = Some message;
                                  actor = Some ctx.agent_name;
                                }
                              in
                              let _ = GV2.update_execution_order ctx.base_path blocked_order in
                              Some blocked_order)
                      | _ -> Some initial_order)
                in
                (match GV2.get_case_bundle ctx.base_path case_id with
                | Error message -> (false, message)
                | Ok fresh_bundle ->
                    let json =
                      `Assoc
                        [
                          ("case", case_json fresh_bundle.case_);
                          ("ruling", ruling_json ruling);
                          ( "execution_order",
                            match order with
                            | Some value -> execution_order_json value
                            | None -> `Null );
                        ]
                    in
                    (true, Yojson.Safe.pretty_to_string json))))

let status_filter_of_string = function
  | "pending_ruling" -> Some GV2.Pending_ruling
  | "ready_auto_execute" -> Some GV2.Ready_auto_execute
  | "needs_human_gate" -> Some GV2.Needs_human_gate
  | "executed" -> Some GV2.Executed
  | "blocked" -> Some GV2.Blocked
  | "closed" -> Some GV2.Closed
  | _ -> None

let handle_cases ctx args =
  let include_test = get_bool args "include_test" false in
  let status_filter =
    get_string args "status" "" |> String.lowercase_ascii |> status_filter_of_string
  in
  let cases = GV2.list_cases ~include_test ?status_filter ctx.base_path in
  let items = `List (List.map case_json cases) in
  (true, Yojson.Safe.pretty_to_string items)

let handle_case_status ctx args =
  let case_id = get_string args "case_id" "" in
  if String.trim case_id = "" then
    (false, "case_id is required")
  else
    match GV2.get_case_bundle ctx.base_path case_id with
    | Error message -> (false, message)
    | Ok bundle -> (true, Yojson.Safe.pretty_to_string (case_bundle_json bundle))

let handle_ruling_status ctx args =
  let case_id = get_string args "case_id" "" in
  if String.trim case_id = "" then
    (false, "case_id is required")
  else
    match GV2.get_case_bundle ctx.base_path case_id with
    | Error message -> (false, message)
    | Ok bundle -> (
        match bundle.GV2.ruling with
        | Some ruling -> (true, Yojson.Safe.pretty_to_string (ruling_json ruling))
        | None -> (false, "ruling not found"))

let handle_execution_orders ctx args =
  let case_id = get_string args "case_id" "" |> String.trim in
  let decision = get_string args "decision" "" |> String.lowercase_ascii |> String.trim in
  match (case_id, decision) with
  | "", "" ->
      let orders = GV2.list_execution_orders ctx.base_path in
      let json = `List (List.map execution_order_json orders) in
      (true, Yojson.Safe.pretty_to_string json)
  | "", _ -> (false, "case_id is required when decision is provided")
  | _, "" -> (
      match GV2.get_case_bundle ctx.base_path case_id with
      | Error message -> (false, message)
      | Ok bundle -> (
          match bundle.GV2.execution_order with
          | Some order ->
              (true, Yojson.Safe.pretty_to_string (execution_order_json order))
          | None -> (false, "execution order not found")))
  | _, "deny" -> (
      match GV2.get_case_bundle ctx.base_path case_id with
      | Error message -> (false, message)
      | Ok bundle -> (
          match bundle.GV2.execution_order with
          | None -> (false, "execution order not found")
          | Some order ->
              let denied =
                {
                  order with
                  status = GV2.Denied;
                  updated_at = Time_compat.now ();
                  result_summary = Some "Denied by human gate";
                  actor = Some ctx.agent_name;
                }
              in
              let _ = GV2.update_execution_order ctx.base_path denied in
              let _ = GV2.set_case_status ctx.base_path ~case_id ~status:GV2.Closed in
              (true, Yojson.Safe.pretty_to_string (execution_order_json denied))))
  | _, "confirm" -> (
      match GV2.get_case_bundle ctx.base_path case_id with
      | Error message -> (false, message)
      | Ok bundle -> (
          match bundle.GV2.execution_order with
          | None -> (false, "execution order not found")
          | Some order when order.GV2.status <> GV2.Needs_human_gate_order ->
              (false, "execution order is not waiting for human confirmation")
          | Some order -> (
              match execute_action ctx bundle.GV2.case_ order with
              | Error message ->
                  let blocked =
                    {
                      order with
                      status = GV2.Blocked_order;
                      updated_at = Time_compat.now ();
                      result_summary = Some message;
                      actor = Some ctx.agent_name;
                    }
                  in
                  let _ = GV2.update_execution_order ctx.base_path blocked in
                  (false, message)
              | Ok executed ->
                  let _ = GV2.update_execution_order ctx.base_path executed in
                  (true, Yojson.Safe.pretty_to_string (execution_order_json executed)))))
  | _, other ->
      (false, Printf.sprintf "unsupported decision: %s" other)

let handle_governance_status ctx _args =
  let cases : GV2.case_record list = GV2.list_cases ctx.base_path in
  let counts =
    List.fold_left
      (fun (pending, ready, human_gate, executed, blocked)
           (case_ : GV2.case_record) ->
        match case_.GV2.status with
        | GV2.Pending_ruling -> (pending + 1, ready, human_gate, executed, blocked)
        | GV2.Ready_auto_execute -> (pending, ready + 1, human_gate, executed, blocked)
        | GV2.Needs_human_gate -> (pending, ready, human_gate + 1, executed, blocked)
        | GV2.Executed -> (pending, ready, human_gate, executed + 1, blocked)
        | GV2.Blocked | GV2.Closed -> (pending, ready, human_gate, executed, blocked + 1))
      (0, 0, 0, 0, 0) cases
  in
  let pending, ready, human_gate, executed, blocked = counts in
  let json =
    `Assoc
      [
        ("cases_open", `Int (List.length cases));
        ("pending_ruling", `Int pending);
        ("ready_auto_execute", `Int ready);
        ("needs_human_gate", `Int human_gate);
        ("executed", `Int executed);
        ("blocked", `Int blocked);
      ]
  in
  (true, Yojson.Safe.pretty_to_string json)

let handle_route _ctx args =
  let query = get_string args "query" "" in
  if String.trim query = "" then (false, "query is required")
  else
    let decision = Council.RouterApi.route query in
    let json =
      `Assoc
        [
          ("reason", `String decision.reason);
          ("agents", json_string_list (List.map (fun agent -> agent.Council.Router.name) decision.agents));
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)

let handle_execute _ctx args =
  let topic = get_string args "topic" "" in
  let result_str = get_string args "result" "majority" in
  if String.trim topic = "" then
    (false, "topic is required")
  else
    let result =
      match String.lowercase_ascii result_str with
      | "unanimous" -> Council.Consensus.Unanimous Council.Consensus.Approve
      | "deadlock" -> Council.Consensus.Deadlock
      | _ -> Council.Consensus.Majority 2
    in
    match Council.ExecutorApi.execute ~topic ~result with
    | Some output ->
        let json =
          `Assoc
            [
              ("topic", `String topic);
              ("result", `String result_str);
              ("output", `String output.output);
              ("stdout", `String output.stdout);
              ("stderr", `String output.stderr);
            ]
        in
        (true, Yojson.Safe.pretty_to_string json)
    | None -> (false, "no executor matched the topic")

let handle_execute_dry_run _ctx args =
  let topic = get_string args "topic" "" in
  let result_str = get_string args "result" "majority" in
  if String.trim topic = "" then
    (false, "topic is required")
  else
    let result =
      match String.lowercase_ascii result_str with
      | "unanimous" -> Council.Consensus.Unanimous Council.Consensus.Approve
      | "deadlock" -> Council.Consensus.Deadlock
      | _ -> Council.Consensus.Majority 2
    in
    (true, Council.ExecutorApi.dry_run ~topic ~result)

let schemas : Types.tool_schema list = [
  {
    name = "masc_petition_submit";
    description = "Submit a Governance V2 petition. Creates or merges a case, records requested action metadata, and files the item into the petition inbox.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Petition title or agenda item");
        ]);
        ("origin", `Assoc [
          ("type", `String "string");
          ("description", `String "Origin tag such as human, automation, test, or harness");
        ]);
        ("subject_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Subject classification such as task, operation, policy, or dispute");
        ]);
        ("risk_class", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "low"; `String "high"]);
          ("description", `String "Explicit risk classification. If omitted, the runtime derives it from the requested action.");
        ]);
        ("requested_action", `Assoc [
          ("type", `String "object");
          ("description", `String "Action metadata to execute when the case is adopted");
          ("properties", `Assoc [
            ("action_type", `Assoc [("type", `String "string")]);
            ("target_type", `Assoc [("type", `String "string")]);
            ("target_id", `Assoc [("type", `String "string")]);
            ("payload", `Assoc [("type", `String "object")]);
          ]);
        ]);
        ("source_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence or source references attached to the petition");
        ]);
      ]);
      ("required", `List [`String "title"]);
    ];
  };
  {
    name = "masc_case_brief_submit";
    description = "Add a support/oppose/neutral brief to a Governance V2 case. Brief submission can trigger a ruling and execution order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("stance", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "support"; `String "oppose"; `String "neutral"]);
          ("description", `String "Brief stance for the case");
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Short brief text");
        ]);
        ("evidence_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence references supporting the brief");
        ]);
      ]);
      ("required", `List [`String "case_id"; `String "summary"]);
    ];
  };
  {
    name = "masc_cases";
    description = "List Governance V2 cases. Use this instead of the legacy debate/session listing tools.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional case status filter");
        ]);
        ("include_test", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include test/harness cases that are hidden by default");
        ]);
      ]);
    ];
  };
  {
    name = "masc_case_status";
    description = "Read a single Governance V2 case bundle including petitions, briefs, ruling, and execution order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };
  {
    name = "masc_ruling_status";
    description = "Read the latest Governance V2 ruling (approved, denied, pending) for a case. Use when checking whether a governance petition has been decided before proceeding with the action.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };
  {
    name = "masc_execution_orders";
    description = "List Governance V2 execution orders, inspect one case order, or confirm/deny a human gate.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "confirm"; `String "deny"]);
          ("description", `String "Optional human-gate decision for a high-risk execution order");
        ]);
      ]);
    ];
  };
  {
    name = "masc_governance_status";
    description = "Get Governance V2 status (pending rulings, auto-executable cases, human-gated orders, executed cases).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_route *)
  {
    name = "masc_route";
    description = "Route a query to the best-fit agents using MoE-style selection, returning selected agents and estimated cost. \
Use when you have a task and need to identify which agents should handle it. \
Pair with masc_dispatch_assign to actually assign work to the selected agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "The query to route");
        ]);
        ("max_agents", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max agents to select (default: 3)");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };

  (* masc_execute *)
  {
    name = "masc_execute";
    description = "Execute an action based on a governance decision by matching the topic pattern to a handler. \
Use when a governance ruling has been made and the resulting action needs to run (e.g., 'Merge PR #123'). \
Call masc_execute_dry_run first to preview. Pair with masc_execution_orders for the order context.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The decision topic (e.g., 'Merge PR #456')");
        ]);
        ("result", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "unanimous"; `String "majority"; `String "deadlock"]);
          ("description", `String "Voting result (default: majority)");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

  (* masc_execute_dry_run *)
  {
    name = "masc_execute_dry_run";
    description = "Preview what action a governance execution would take without actually running it. \
Use when you want to verify the matched handler and parameters before committing to masc_execute. \
Pair with masc_execute to run the action after confirming the dry-run output.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The decision topic");
        ]);
        ("result", `Assoc [
          ("type", `String "string");
          ("description", `String "Voting result");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

]

let handle_governance_feed ctx args =
  let filter = get_string args "filter" "decisions" |> String.lowercase_ascii in
  let limit = get_int args "limit" 20 in
  let items = ref [] in
  (* Parameter change audit trail *)
  if filter = "decisions" || filter = "all" then begin
    let audit = Runtime_params.recent_audit ~base_path:ctx.base_path limit in
    List.iter (fun entry ->
      items := `Assoc [ ("kind", `String "param_change"); ("data", entry) ] :: !items
    ) audit
  end;
  (* Active governance cases *)
  if filter = "decisions" || filter = "all" then begin
    let cases = GV2.list_cases ctx.base_path in
    let active = List.filter (fun (c : GV2.case_record) ->
      match c.status with GV2.Closed -> false | _ -> true) cases in
    List.iter (fun c ->
      items := `Assoc [ ("kind", `String "case"); ("data", case_json c) ] :: !items
    ) active
  end;
  (* Human board posts *)
  if filter = "human_only" || filter = "all" then begin
    let posts = Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit () in
    let human = List.filter (fun (p : Board.post) ->
      p.post_kind = Board.Human_post) posts in
    List.iter (fun p ->
      items := `Assoc [
        ("kind", `String "human_post");
        ("data", Board.post_to_yojson p);
      ] :: !items
    ) human
  end;
  (* Reverse to restore source order (cons reverses each batch) then take *)
  let all = List.rev !items in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  let result = take limit all in
  (true, Yojson.Safe.pretty_to_string (`List result))

let handle_runtime_params _ctx _args =
  let params = Runtime_params.registry () in
  let items =
    List.map
      (fun (key, current, default, has_override) ->
        `Assoc
          [
            ("key", `String key);
            ("current", current);
            ("default", default);
            ("has_override", `Bool has_override);
          ])
      params
  in
  let surfaces = Governance_registry.surfaces_json () in
  let json =
    `Assoc
      [
        ("parameters", `List items);
        ("surfaces", surfaces);
      ]
  in
  (true, Yojson.Safe.pretty_to_string json)

let handle_set_param ctx args =
  let param_key = get_string args "param_key" "" |> String.trim in
  let value_json =
    match Yojson.Safe.Util.member "value" args with
    | `Null -> None
    | v -> Some v
  in
  let reason = get_string args "reason" "" in
  if param_key = "" then (false, "param_key is required")
  else
    match value_json with
    | None -> (false, "value is required")
    | Some value ->
        let risk =
          Governance_registry.surfaces
          |> List.find_opt (fun (s : Governance_registry.surface) ->
               List.mem param_key s.param_keys)
          |> Option.map (fun (s : Governance_registry.surface) -> s.risk)
          |> Option.value ~default:"low"
        in
        if risk = "high" then
          let title =
            Printf.sprintf "Set %s = %s%s" param_key
              (Yojson.Safe.to_string value)
              (if reason <> "" then " (" ^ reason ^ ")" else "")
          in
          let petition_args =
            `Assoc
              [
                ("title", `String title);
                ("origin", `String "agent");
                ("subject_type", `String "param_change");
                ("risk_class", `String "high");
                ( "requested_action",
                  `Assoc
                    [
                      ("action_type", `String "set_param");
                      ( "payload",
                        `Assoc
                          [
                            ("param_key", `String param_key);
                            ("value", value);
                          ] );
                    ] );
                ("source_refs", `List [ `String param_key ]);
              ]
          in
          let (ok, msg) = handle_petition_submit ctx petition_args in
          if ok then
            (true, Printf.sprintf "High-risk parameter. Governance petition created.\n%s" msg)
          else
            (false, Printf.sprintf "Failed to create governance petition: %s" msg)
        else begin
          let old_value =
            match Runtime_params.registry ()
                  |> List.find_opt (fun (k, _, _, _) -> k = param_key) with
            | Some (_, current, _, _) -> current
            | None -> `Null
          in
          match Runtime_params.set_by_key param_key value with
          | Error msg -> (false, Printf.sprintf "set_param failed: %s" msg)
          | Ok () ->
              Runtime_params.persist ~base_path:ctx.base_path;
              Runtime_params.record_audit ~base_path:ctx.base_path
                ~key:param_key ~old_value ~new_value:value
                ~actor:ctx.agent_name ();
              Sse.broadcast
                (`Assoc
                   [
                     ("type", `String "governance_param_changed");
                     ("param_key", `String param_key);
                     ("old_value", old_value);
                     ("new_value", value);
                     ("actor", `String ctx.agent_name);
                   ]);
              (true,
               Printf.sprintf "Set %s = %s (low-risk, applied immediately)"
                 param_key (Yojson.Safe.to_string value))
        end

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_petition_submit" -> Some (handle_petition_submit ctx args)
  | "masc_case_brief_submit" -> Some (handle_case_brief_submit ctx args)
  | "masc_cases" -> Some (handle_cases ctx args)
  | "masc_case_status" -> Some (handle_case_status ctx args)
  | "masc_ruling_status" -> Some (handle_ruling_status ctx args)
  | "masc_execution_orders" -> Some (handle_execution_orders ctx args)
  | "masc_governance_status" -> Some (handle_governance_status ctx args)
  | "masc_governance_feed" -> Some (handle_governance_feed ctx args)
  | "masc_runtime_params" -> Some (handle_runtime_params ctx args)
  | "masc_set_param" -> Some (handle_set_param ctx args)
  | "masc_route" -> Some (handle_route ctx args)
  | "masc_execute" -> Some (handle_execute ctx args)
  | "masc_execute_dry_run" -> Some (handle_execute_dry_run ctx args)
  | "masc_debate_start"
  | "masc_debate_argue"
  | "masc_debate_close"
  | "masc_debate_status"
  | "masc_debates"
  | "masc_consensus_start"
  | "masc_consensus_vote"
  | "masc_consensus_close"
  | "masc_consensus_result"
  | "masc_sessions" ->
      Some (removed_surface name)
  | _ -> None

let definitions = Tool_council_schemas.definitions
