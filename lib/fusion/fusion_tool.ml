let status_result ~tool_name ~class_ ~ok fields =
  let data = `Assoc (("ok", `Bool ok) :: fields) in
  if ok
  then Tool_result.make_ok ~tool_name ~start_time:0.0 ~data ()
  else
    Tool_result.make_err ~tool_name ~class_ ~start_time:0.0 ~data
      (Yojson.Safe.to_string data)
;;

type compute_runner =
  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> policy:Fusion_policy.t
  -> topology:Fusion_types.fusion_topology
  -> request:Fusion_types.fusion_request
  -> unit
  -> Fusion_orchestrator.compute_outcome

(* 거절 라벨 옆에 붙일 사람이 읽는 사유. 라벨만으로 뜻이 다 전해지는 갈래는 [None]. *)
let deny_detail = function
  | Fusion_types.Roster_invalid detail -> Some detail
  | Fusion_types.Disabled | Fusion_types.Preset_unknown _ | Fusion_types.Depth_exceeded ->
    None
;;

let worker_result ~compute ~net ~policy ~topology ~request_id ~keeper ~prompt
      ~preset ~web_tools ~roster request_sw =
  let request : Fusion_types.fusion_request =
    { run_id = request_id
    ; keeper
    ; prompt
    ; preset
    ; web_tools
    ; roster
    ; depth = Fusion_types.Fusion_depth.Top
    ; trigger = Fusion_types.Explicit_tool_call
    }
  in
  match compute ~sw:request_sw ~net ~policy ~topology ~request () with
  | Fusion_orchestrator.Computed evidence ->
    Keeper_types_profile.tool_result_ok_data
      (Fusion_types.deliberation_evidence_to_yojson evidence)
  | Fusion_orchestrator.Compute_denied reason ->
    Keeper_types_profile.tool_result_error_data ~class_:Tool_result.Workflow_rejection
      (`Assoc
         ([ "error", `String "fusion_compute_denied"
          ; "reason", `String (Fusion_types.deny_reason_label reason)
          ]
          @ (match deny_detail reason with
             | None -> []
             | Some detail -> [ "detail", `String detail ])))
;;

(* 실행별 명단 인자 (RFC fusion-seat-routes §2.4). 키가 없으면 preset 의 그 칸을
   그대로 쓴다. 키가 있으면 값이 경로 이름이어야 하고, 틀린 모양은 없는 것으로 읽지
   않고 거절한다. 경로 이름은 앞뒤 공백을 뗀 값으로 적는다. *)
let judge_arg_error =
  "judge must be a non-empty route name (a [runtime.lanes] lane or a runtime id)"
;;

let panel_arg_error =
  "panel must be a non-empty list of non-empty route names ([runtime.lanes] lanes or runtime ids)"
;;

let route_name = function
  | `String value -> Fusion_types.route_name value
  | _ -> None
;;

let roster_of_args args : (Fusion_types.roster, string) result =
  let judge_route =
    match Json_util.assoc_member_opt "judge" args with
    | None -> Ok None
    | Some json ->
      (match route_name json with
       | Some route -> Ok (Some route)
       | None -> Error judge_arg_error)
  in
  let panel_routes =
    match Json_util.assoc_member_opt "panel" args with
    | None -> Ok None
    | Some (`List (_ :: _ as items)) ->
      let routes = List.filter_map route_name items in
      if List.compare_lengths routes items = 0 then Ok (Some routes) else Error panel_arg_error
    | Some _ -> Error panel_arg_error
  in
  match judge_route, panel_routes with
  | Ok judge_route, Ok panel_routes -> Ok { Fusion_types.judge_route; panel_routes }
  | Error message, _ | Ok _, Error message -> Error message
;;

(* 명단이 적은 경로 이름을 제출할 때 모두 풀어 본다. 실행 중에도 자리마다 다시 풀지만,
   못 푸는 이름으로 실행을 만들면 모든 자리가 같은 이유로 실패한 기록만 남는다. *)
let first_unresolved_route (roster : Fusion_types.roster) =
  Option.to_list roster.judge_route @ List.concat (Option.to_list roster.panel_routes)
  |> List.find_map (fun route ->
    match Fusion_seat.resolve route with
    | Ok _ -> None
    | Error failure -> Some (route, failure))
;;

let route_failure_fields route = function
  | Fusion_seat.Unknown_route _ ->
    [ ( "error"
      , `String
          (Printf.sprintf "route %S is neither a [runtime.lanes] lane nor a runtime id"
             route) )
    ; "reason", `String "unknown_route"
    ; "route", `String route
    ]
  | Fusion_seat.Route_unavailable detail ->
    [ ( "error"
      , `String
          (Printf.sprintf "route %S names a runtime whose catalog entry is missing: %s"
             route detail) )
    ; "reason", `String "route_unavailable"
    ; "route", `String route
    ]
;;

let denied_result ~tool_name reason =
  status_result ~tool_name ~class_:Tool_result.Workflow_rejection ~ok:false
    ([ "status", `String "denied"
     ; "reason", `String (Fusion_types.deny_reason_label reason)
     ]
     @ (match deny_detail reason with
        | None -> []
        | Some detail -> [ "error", `String detail ]))
;;

let submit_error_result ~tool_name error =
  let data =
    match Keeper_msg_async.submit_error_to_json error with
    | `Assoc fields -> `Assoc (("ok", `Bool false) :: fields)
    | data -> `Assoc [ "ok", `Bool false; "error", data ]
  in
  Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure
    ~start_time:0.0 ~data (Yojson.Safe.to_string data)
;;

let handle_with_compute_result ~compute ~sw ~net ~base_dir ~keeper ~now_unix
      ~policy ?source_context ?continuation_channel ?(registry = Fusion_run_registry.global ()) ~args () =
  let tool_name = "masc_fusion" in
  let prompt = match source_context with
    | Some context -> Fusion_request_context.render context
    | None -> Tool_args.get_string args "prompt" "" in
  let preset = Tool_args.get_string args "preset" policy.Fusion_policy.default_preset in
  let web_tools = Tool_args.get_bool args "web_tools" false in
  let default_topology =
    Fusion_types.fusion_topology_to_string Fusion_types.Simple
  in
  let topology_wire = Tool_args.get_string args "topology" default_topology in
  let context_matches = match source_context with
    | None -> true
    | Some context -> Fusion_request_context.keeper context = keeper
        && Fusion_request_context.question context = Tool_args.get_string args "prompt" "" in
  if not context_matches then
    status_result ~tool_name ~class_:Tool_result.Workflow_rejection ~ok:false
      ["error", `String "source context differs from the calling Keeper or question"]
  else
  match String.equal (String.trim prompt) "", Fusion_types.fusion_topology_of_string topology_wire with
  | true, _ ->
    status_result ~tool_name ~class_:Tool_result.Workflow_rejection ~ok:false
      [ "error", `String "prompt is required" ]
  | false, None ->
    status_result ~tool_name ~class_:Tool_result.Workflow_rejection ~ok:false
      [ ( "error"
        , `String
            (Printf.sprintf "topology must be one of: %s"
               (String.concat ", " Fusion_types.all_fusion_topology_strings)) )
      ]
  | false, Some topology ->
    (match roster_of_args args with
     | Error message ->
       status_result ~tool_name ~class_:Tool_result.Workflow_rejection ~ok:false
         [ "error", `String message ]
     | Ok roster ->
    match Fusion_policy.decide_top_level ~policy ~preset with
     | Error reason -> denied_result ~tool_name reason
     | Ok () ->
    match first_unresolved_route roster with
     | Some (route, failure) ->
       status_result ~tool_name ~class_:Tool_result.Workflow_rejection ~ok:false
         (route_failure_fields route failure)
     | None ->
    match Fusion_policy.effective_preset ~policy ~preset ~roster with
     | Error reason -> denied_result ~tool_name reason
     | Ok _ ->
       let channel =
         Option.value continuation_channel
           ~default:(Keeper_continuation_channel.unrouted "no originating connector")
       in
       let payload : Fusion_delivery_obligation.accepted_payload =
         { keeper_name = keeper
         ; submitted_by = keeper
         ; prompt
         ; source_context
         ; preset
         ; web_tools
         ; roster
         ; topology
         ; channel
         }
       in
       let on_accepted request_id =
         match Keeper_chat_delivery_identity.Request_id.of_string request_id with
         | Error detail -> Error detail
         | Ok request_id ->
           (match
              Fusion_delivery_obligation.prepare ~base_path:base_dir ~request_id
                ~payload ~accepted_at:now_unix
            with
            | Error error -> Error (Fusion_delivery_obligation.error_to_string error)
            | Ok (Fusion_delivery_obligation.Prepared obligation
                 | Fusion_delivery_obligation.Already_present obligation) ->
              let run_id =
                Keeper_chat_delivery_identity.Request_id.to_string obligation.request_id
              in
              Fusion_run_registry.register_running registry ~run_id ~keeper ~preset
                ~roster ~topology ~started_at:obligation.accepted_at;
              Fusion_sink.broadcast_run_status ~registry ~run_id;
              Ok ())
       in
       match
         Keeper_msg_async.submit_with_request_id ~on_accepted
           ~on_worker_settled:
             (Fusion_delivery_projector.on_worker_settled ~registry ~base_path:base_dir)
           ~background_sw:sw ~base_path:base_dir ~caller:keeper ~keeper_name:keeper
           ~f:(fun ~request_id request_sw ->
             worker_result ~compute ~net ~policy ~topology ~request_id ~keeper
               ~prompt ~preset ~web_tools ~roster request_sw)
           ()
       with
       | Error error -> submit_error_result ~tool_name error
       | Ok { Keeper_msg_async.request_id; acceptance = Durably_accepted } ->
         Log.Keeper.info ~keeper_name:keeper
           "fusion run %s durably accepted (async delivery)" request_id;
         status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:true
           [ "status", `String "fusion_started"
           ; "run_id", `String request_id
           ; ( "delivery"
             , `String
                 "async: you will be woken with the result when deliberation completes; the conclusion or failure remains durable. No need to poll masc_fusion_status." )
           ]
       | Ok
           { Keeper_msg_async.request_id
           ; acceptance = Reconciliation_required { reason }
           } ->
         Log.Keeper.warn ~keeper_name:keeper
           "fusion run %s acceptance uncertain, reconciliation required: %s"
           request_id reason;
         status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:false
           [ "error", `String "fusion_acceptance_uncertain"
           ; "run_id", `String request_id
           ; "reconciliation_required", `Bool true
           ; "reason", `String reason
           ])
;;

let handle_result ~sw ~net ~base_dir ~keeper ~now_unix ~policy ?source_context ?continuation_channel
      ?(registry = Fusion_run_registry.global ()) ~args () =
  (* base_dir 를 여기서 부분 적용한다. [compute_runner] 계약을 넓히지 않으면서
     official-client 패널리스트가 spawn 될 디렉터리를 orchestrator 아래로
     내려보내는 유일한 지점이다 — MASC base path 에는 전역 접근자가 없다. *)
  let compute ~sw ~net ~policy ~topology ~request () =
    let on_progress progress =
      Fusion_run_registry.mark_progress registry ~run_id:request.Fusion_types.run_id
        ~progress;
      Fusion_sink.broadcast_run_status ~registry ~run_id:request.run_id
    in
    Fusion_orchestrator.compute ~base_dir ~sw ~net ~policy ~topology ~request
      ~on_progress ()
  in
  handle_with_compute_result ~compute ~sw ~net ~base_dir ~keeper ~now_unix
    ~policy ?source_context ?continuation_channel ~registry ~args ()
;;

let handle ~sw ~net ~base_dir ~keeper ~now_unix ~policy ?source_context ?continuation_channel
      ~args () =
  Tool_result.message
    (handle_result ~sw ~net ~base_dir ~keeper ~now_unix ~policy
       ?source_context ?continuation_channel ~args ())
;;

module For_test = struct
  type nonrec compute_runner = compute_runner

  let handle_with_compute ~compute ~sw ~net ~base_dir ~keeper ~now_unix ~policy
        ?source_context ?continuation_channel ?registry ~args () =
    Tool_result.message
      (handle_with_compute_result ~compute ~sw ~net ~base_dir ~keeper ~now_unix
         ~policy ?source_context ?continuation_channel ?registry ~args ())
  ;;
end
