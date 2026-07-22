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

let worker_result ~compute ~net ~policy ~topology ~request_id ~keeper ~prompt
      ~preset ~web_tools request_sw =
  let request : Fusion_types.fusion_request =
    { run_id = request_id
    ; keeper
    ; prompt
    ; preset
    ; web_tools
    ; depth = Fusion_types.Fusion_depth.Top
    ; trigger = Fusion_types.Explicit_tool_call
    }
  in
  match compute ~sw:request_sw ~net ~policy ~topology ~request () with
  | Fusion_orchestrator.Computed evidence ->
    Keeper_types_profile.tool_result_ok_data
      (Fusion_types.deliberation_evidence_to_yojson evidence)
  | Fusion_orchestrator.Compute_denied reason ->
    Keeper_types_profile.tool_result_error_data
      (`Assoc
         [ "error", `String "fusion_compute_denied"
         ; "reason", `String (Fusion_types.deny_reason_label reason)
         ])
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
      ~policy ?continuation_channel ~args () =
  let tool_name = "masc_fusion" in
  let prompt = Tool_args.get_string args "prompt" "" in
  let preset = Tool_args.get_string args "preset" policy.Fusion_policy.default_preset in
  let web_tools = Tool_args.get_bool args "web_tools" false in
  let default_topology =
    Fusion_types.fusion_topology_to_string Fusion_types.Simple
  in
  let topology_wire = Tool_args.get_string args "topology" default_topology in
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
    (match Fusion_policy.decide_top_level ~policy ~preset with
     | Error reason ->
       status_result ~tool_name ~class_:Tool_result.Workflow_rejection ~ok:false
         [ "status", `String "denied"
         ; "reason", `String (Fusion_types.deny_reason_label reason)
         ]
     | Ok () ->
       let channel =
         Option.value continuation_channel
           ~default:(Keeper_continuation_channel.unrouted "no originating connector")
       in
       let payload : Fusion_delivery_obligation.accepted_payload =
         { keeper_name = keeper
         ; submitted_by = keeper
         ; prompt
         ; preset
         ; web_tools
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
              Fusion_run_registry.register_running (Fusion_run_registry.global ())
                ~run_id ~keeper ~preset ~started_at:obligation.accepted_at;
              Fusion_sink.broadcast_run_status
                ~registry:(Fusion_run_registry.global ()) ~run_id;
              Ok ())
       in
       match
         Keeper_msg_async.submit_with_request_id ~on_accepted
           ~on_worker_settled:(Fusion_delivery_projector.on_worker_settled ~base_path:base_dir)
           ~background_sw:sw ~base_path:base_dir ~caller:keeper ~keeper_name:keeper
           ~f:(fun ~request_id request_sw ->
             worker_result ~compute ~net ~policy ~topology ~request_id ~keeper
               ~prompt ~preset ~web_tools request_sw)
           ()
       with
       | Error error -> submit_error_result ~tool_name error
       | Ok { Keeper_msg_async.request_id; acceptance = Durably_accepted } ->
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
         status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:false
           [ "error", `String "fusion_acceptance_uncertain"
           ; "run_id", `String request_id
           ; "reconciliation_required", `Bool true
           ; "reason", `String reason
           ])
;;

let handle_result = handle_with_compute_result ~compute:Fusion_orchestrator.compute

let handle ~sw ~net ~base_dir ~keeper ~now_unix ~policy ?continuation_channel
      ~args () =
  Tool_result.message
    (handle_result ~sw ~net ~base_dir ~keeper ~now_unix ~policy
       ?continuation_channel ~args ())
;;

module For_test = struct
  type nonrec compute_runner = compute_runner

  let handle_with_compute ~compute ~sw ~net ~base_dir ~keeper ~now_unix ~policy
        ?continuation_channel ~args () =
    Tool_result.message
      (handle_with_compute_result ~compute ~sw ~net ~base_dir ~keeper ~now_unix
         ~policy ?continuation_channel ~args ())
  ;;
end
