type deps = {
  query_param : Httpun.Request.t -> string -> string option;
  int_query_param : Httpun.Request.t -> string -> default:int -> int;
  operator_actor_hint : Httpun.Request.t -> string option;
  get_session_id_any : Httpun.Request.t -> string option;
  auth_token_from_request : Httpun.Request.t -> string option;
  get_switch : unit -> Eio.Switch.t;
  get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t;
  get_net : unit -> [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
}

let assoc_add key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | json -> `Assoc [ ("payload", json); (key, value) ]

let command_plane_actor deps request =
  Option.value ~default:"dashboard" (deps.operator_actor_hint request)

let command_plane_tool_ctx ~deps ~state request :
    (_, _) Tool_command_plane.context =
  {
    config = state.Mcp_server.room_config;
    agent_name = command_plane_actor deps request;
    sw = Some (deps.get_switch ());
    clock = Some (deps.get_clock ());
    net = Some (deps.get_net ());
    mcp_state = Some state;
    mcp_session_id = deps.get_session_id_any request;
    auth_token = deps.auth_token_from_request request;
  }

let tool_command_plane_http_json ~deps ~state request ~name ~args =
  match
    Tool_command_plane.dispatch
      (command_plane_tool_ctx ~deps ~state request)
      ~name ~args
  with
  | Some (true, payload) -> (
      try Ok (Yojson.Safe.from_string payload)
      with Yojson.Json_error message -> Error ("invalid tool json: " ^ message))
  | Some (false, payload) -> (
      try
        match Yojson.Safe.from_string payload with
        | `Assoc fields -> (
            match List.assoc_opt "message" fields with
            | Some (`String message) -> Error message
            | _ -> Error payload)
        | _ -> Error payload
      with Yojson.Json_error _ -> Error payload)
  | None -> Error ("unsupported command-plane tool: " ^ name)

let command_plane_summary_http_json ~state =
  let config = state.Mcp_server.room_config in
  let summary = Command_plane_v2.summary_json config in
  let swarm_status =
    if Room.is_initialized config then
      Swarm_status.build_json ~timeline_limit_override:6 config
    else Swarm_status.empty_json
  in
  assoc_add "swarm_status" swarm_status summary

let command_plane_snapshot_http_json ~state =
  let config = state.Mcp_server.room_config in
  let snapshot = Command_plane_v2.snapshot_json config in
  let swarm_status =
    if Room.is_initialized config then
      Swarm_status.build_json_from_snapshot config snapshot
    else Swarm_status.empty_json
  in
  assoc_add "swarm_status" swarm_status snapshot

let command_plane_topology_http_json ~state =
  Command_plane_v2.topology_json state.Mcp_server.room_config

let command_plane_units_http_json ~state =
  Command_plane_v2.list_units_json state.Mcp_server.room_config

let command_plane_operations_http_json ~deps ~state request =
  let operation_id = deps.query_param request "operation_id" in
  Command_plane_v2.operation_status_json state.Mcp_server.room_config ?operation_id ()

let command_plane_detachments_http_json ~deps ~state request =
  let operation_id = deps.query_param request "operation_id" in
  let detachment_id = deps.query_param request "detachment_id" in
  Command_plane_v2.list_detachments_json state.Mcp_server.room_config ?operation_id
    ?detachment_id

let command_plane_detachment_status_http_json ~deps ~state request =
  let args =
    `Assoc
      [
        ( "detachment_id",
          match deps.query_param request "detachment_id" with
          | Some value -> `String value
          | None -> `Null );
      ]
  in
  Command_plane_v2.detachment_status_json state.Mcp_server.room_config args

let command_plane_decisions_http_json ~deps ~state request =
  let decision_id = deps.query_param request "decision_id" in
  Command_plane_v2.list_policy_decisions_json state.Mcp_server.room_config
    ?decision_id

let command_plane_capacity_http_json ~state =
  Command_plane_v2.capacity_json state.Mcp_server.room_config

let command_plane_alerts_http_json ~state =
  Command_plane_v2.list_alerts_json state.Mcp_server.room_config

let command_plane_traces_http_json ~deps ~state request =
  let operation_id = deps.query_param request "operation_id" in
  let limit =
    deps.int_query_param request "limit" ~default:25 |> fun v -> max 1 (min 200 v)
  in
  Command_plane_v2.list_traces_json state.Mcp_server.room_config ?operation_id
    ~limit ()

let command_plane_swarm_http_json ~deps ~state request =
  let run_id = deps.query_param request "run_id" in
  let operation_id = deps.query_param request "operation_id" in
  Command_plane_v2.swarm_live_json state.Mcp_server.room_config ?run_id
    ?operation_id ()

let command_plane_unit_define_http_json ~deps ~state request ~args =
  Command_plane_v2.unit_update_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_start_http_json ~deps ~state request ~args =
  tool_command_plane_http_json ~deps ~state request ~name:"masc_operation_start"
    ~args

let command_plane_chain_summary_http_json ~deps ~state request =
  tool_command_plane_http_json ~deps ~state request ~name:"masc_chain_snapshot"
    ~args:(`Assoc [])

let command_plane_chain_run_http_json ~deps ~state request run_id =
  tool_command_plane_http_json ~deps ~state request ~name:"masc_chain_run_get"
    ~args:(`Assoc [ ("run_id", `String run_id) ])

let chain_http_error_status message =
  let starts_with ~prefix value =
    let prefix_len = String.length prefix in
    String.length value >= prefix_len
    && String.equal (String.sub value 0 prefix_len) prefix
  in
  if starts_with ~prefix:"invalid chain run_id:" message then
    `Bad_request
  else if starts_with ~prefix:"chain run not found:" message then
    `Not_found
  else
    `Bad_gateway

let stream_native_chain_events_http ~deps ~request reqd =
  let origin = deps.get_origin request in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ deps.cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let sub_ref : Chain_telemetry.subscription option ref = ref None in
  let log_chain_sse message =
    Printf.eprintf "[chain-sse] %s\n%!" message
  in
  let close_stream ?reason () =
    let sub_to_remove, should_close =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          let sub = !sub_ref in
          sub_ref := None;
          if !closed then
            (sub, false)
          else (
            closed := true;
            (sub, true)))
    in
    Option.iter Chain_telemetry.unsubscribe sub_to_remove;
    if should_close then (
      Option.iter log_chain_sse reason;
      try
        if not (Httpun.Body.Writer.is_closed writer) then
          Httpun.Body.Writer.close writer
      with Invalid_argument _ -> ())
  in
  let send_raw frame =
    let write_result =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          if !closed || Httpun.Body.Writer.is_closed writer then
            `Closed
          else
            try
              Httpun.Body.Writer.write_string writer frame;
              Httpun.Body.Writer.flush writer (fun _ -> ());
              `Sent
            with exn -> `Error exn)
    in
    match write_result with
    | `Sent -> true
    | `Closed ->
        close_stream ();
        false
    | `Error exn ->
        close_stream
          ~reason:
            (Printf.sprintf "stream write failed: %s" (Printexc.to_string exn))
          ();
        false
  in
  (try
     let sub =
       Chain_telemetry.subscribe (fun event ->
           let payload = Chain_native_eio.chain_event_json event |> Yojson.Safe.to_string in
           let frame =
             Sse.format_event
               ~event_type:(Chain_native_eio.chain_event_name event)
               payload
           in
           ignore (send_raw frame))
     in
     Eio.Mutex.use_rw ~protect:true mutex (fun () -> sub_ref := Some sub);
     if send_raw ": native chain stream\nretry: 3000\n\n" then
       Eio.Fiber.fork ~sw:(deps.get_switch ()) (fun () ->
           try
             while not !closed do
               Eio.Time.sleep (deps.get_clock ()) 30.0;
               if not (send_raw ": keepalive\n\n") then close_stream ()
             done
           with exn ->
             close_stream
               ~reason:
                 (Printf.sprintf "keepalive loop failed: %s"
                    (Printexc.to_string exn))
               ())
     else
       close_stream ~reason:"initial stream write failed" ()
   with exn ->
     close_stream
       ~reason:
         (Printf.sprintf "subscription setup failed: %s"
            (Printexc.to_string exn))
       ())

let proxy_chain_events_http ~deps ~request reqd =
  let endpoint = Llm_client_eio.resolve_endpoint () in
  let path = Llm_client_eio.endpoint_path endpoint "/chain/events" in
  let origin = deps.get_origin request in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ deps.cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let upstream_request =
    let auth_header =
      match endpoint.api_key with
      | Some value -> [ Printf.sprintf "Authorization: Bearer %s" value ]
      | None -> []
    in
    Printf.sprintf
      "GET %s HTTP/1.1\r\nHost: %s:%d\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n%s\r\n\r\n"
      path endpoint.host endpoint.port
      (String.concat "\r\n" auth_header)
  in
  Eio.Fiber.fork ~sw:(deps.get_switch ()) (fun () ->
      let safe_close () =
        try Httpun.Body.Writer.close writer with Invalid_argument _ -> ()
      in
      let send_error message =
        (try
           let payload =
             Printf.sprintf "event: error\ndata: {\"message\":%s}\n\n"
               (Yojson.Safe.to_string (`String message))
           in
           Httpun.Body.Writer.write_string writer payload;
           Httpun.Body.Writer.flush writer ignore
         with _ -> ());
        safe_close ()
      in
      try
        Eio.Net.with_tcp_connect ~host:endpoint.host
          ~service:(string_of_int endpoint.port) (deps.get_net ())
        @@ fun flow ->
        Eio.Flow.copy_string upstream_request flow;
        let header_buf = Buffer.create 4096 in
        let rec read_headers () =
          let chunk = Cstruct.create 2048 in
          match Eio.Flow.single_read flow chunk with
          | n ->
              Buffer.add_string header_buf (Cstruct.to_string ~len:n chunk);
              let current = Buffer.contents header_buf in
              (try
                 let idx = Str.search_forward (Str.regexp "\r\n\r\n") current 0 in
                 let headers_part = String.sub current 0 idx in
                 let body_start = idx + 4 in
                 let body_rest =
                   if body_start >= String.length current then ""
                   else
                     String.sub current body_start
                       (String.length current - body_start)
                 in
                 Ok (headers_part, body_rest)
               with Not_found -> read_headers ())
          | exception End_of_file ->
              Error
                "llm-mcp closed chain/events stream before headers were received"
        in
        match read_headers () with
        | Error message -> send_error message
        | Ok (headers_part, body_rest) ->
            let status_line =
              match String.split_on_char '\n' headers_part with
              | line :: _ -> String.trim line
              | [] -> "HTTP/1.1 502 Bad Gateway"
            in
            let status_code =
              match String.split_on_char ' ' status_line with
              | _http :: code :: _ -> (try int_of_string code with _ -> 502)
              | _ -> 502
            in
            if status_code < 200 || status_code >= 300 then
              send_error
                (Printf.sprintf "llm-mcp /chain/events upstream returned %d"
                   status_code)
            else (
              if body_rest <> "" then (
                Httpun.Body.Writer.write_string writer body_rest;
                Httpun.Body.Writer.flush writer ignore);
              let rec pump () =
                let chunk = Cstruct.create 4096 in
                match Eio.Flow.single_read flow chunk with
                | n ->
                    Httpun.Body.Writer.write_string writer
                      (Cstruct.to_string ~len:n chunk);
                    Httpun.Body.Writer.flush writer ignore;
                    pump ()
                | exception End_of_file -> safe_close ()
                | exception exn -> send_error (Printexc.to_string exn)
              in
              pump ())
      with exn -> send_error (Printexc.to_string exn))

let command_plane_chain_events_http ~deps ~request reqd =
  match Tool_command_plane.chain_backend () with
  | Tool_command_plane.Native ->
      stream_native_chain_events_http ~deps ~request reqd
  | Tool_command_plane.Compat_llm_mcp ->
      proxy_chain_events_http ~deps ~request reqd

let stream_native_chain_events_h2 ~deps ~request h2_reqd =
  let origin = deps.get_origin request in
  let headers =
    H2.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("x-accel-buffering", "no");
       ]
      @ deps.cors_headers origin)
  in
  let response = H2.Response.create ~headers `OK in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd
      response
  in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let sub_ref : Chain_telemetry.subscription option ref = ref None in
  let log_chain_sse message =
    Printf.eprintf "[chain-sse/h2] %s\n%!" message
  in
  let close_stream ?reason () =
    let sub_to_remove, should_close =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          let sub = !sub_ref in
          sub_ref := None;
          if !closed then
            (sub, false)
          else (
            closed := true;
            (sub, true)))
    in
    Option.iter Chain_telemetry.unsubscribe sub_to_remove;
    if should_close then (
      Option.iter log_chain_sse reason;
      try
        if not (H2.Body.Writer.is_closed writer) then H2.Body.Writer.close writer
      with Invalid_argument _ -> ())
  in
  let send_raw frame =
    let write_result =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          if !closed || H2.Body.Writer.is_closed writer then
            `Closed
          else
            try
              H2.Body.Writer.write_string writer frame;
              H2.Body.Writer.flush writer (fun _ -> ());
              `Sent
            with exn -> `Error exn)
    in
    match write_result with
    | `Sent -> true
    | `Closed ->
        close_stream ();
        false
    | `Error exn ->
        close_stream
          ~reason:
            (Printf.sprintf "stream write failed: %s" (Printexc.to_string exn))
          ();
        false
  in
  (try
     let sub =
       Chain_telemetry.subscribe (fun event ->
           let payload = Chain_native_eio.chain_event_json event |> Yojson.Safe.to_string in
           let frame =
             Sse.format_event
               ~event_type:(Chain_native_eio.chain_event_name event)
               payload
           in
           ignore (send_raw frame))
     in
     Eio.Mutex.use_rw ~protect:true mutex (fun () -> sub_ref := Some sub);
     if send_raw ": native chain stream\nretry: 3000\n\n" then
       Eio.Fiber.fork ~sw:(deps.get_switch ()) (fun () ->
           try
             while not !closed do
               Eio.Time.sleep (deps.get_clock ()) 30.0;
               if not (send_raw ": keepalive\n\n") then close_stream ()
             done
           with exn ->
             close_stream
               ~reason:
                 (Printf.sprintf "keepalive loop failed: %s"
                    (Printexc.to_string exn))
               ())
     else
       close_stream ~reason:"initial stream write failed" ()
   with exn ->
     close_stream
       ~reason:
         (Printf.sprintf "subscription setup failed: %s"
            (Printexc.to_string exn))
       ())

let proxy_chain_events_h2 ~deps ~request h2_reqd =
  let endpoint = Llm_client_eio.resolve_endpoint () in
  let path = Llm_client_eio.endpoint_path endpoint "/chain/events" in
  let origin = deps.get_origin request in
  let headers =
    H2.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("x-accel-buffering", "no");
       ]
      @ deps.cors_headers origin)
  in
  let response = H2.Response.create ~headers `OK in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd
      response
  in
  let upstream_request =
    let auth_header =
      match endpoint.api_key with
      | Some value -> [ Printf.sprintf "Authorization: Bearer %s" value ]
      | None -> []
    in
    Printf.sprintf
      "GET %s HTTP/1.1\r\nHost: %s:%d\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n%s\r\n\r\n"
      path endpoint.host endpoint.port
      (String.concat "\r\n" auth_header)
  in
  Eio.Fiber.fork ~sw:(deps.get_switch ()) (fun () ->
      let safe_close () =
        try H2.Body.Writer.close writer with Invalid_argument _ -> ()
      in
      let send_error message =
        (try
           let payload =
             Printf.sprintf "event: error\ndata: {\"message\":%s}\n\n"
               (Yojson.Safe.to_string (`String message))
           in
           H2.Body.Writer.write_string writer payload;
           H2.Body.Writer.flush writer ignore
         with _ -> ());
        safe_close ()
      in
      try
        Eio.Net.with_tcp_connect ~host:endpoint.host
          ~service:(string_of_int endpoint.port) (deps.get_net ())
        @@ fun flow ->
        Eio.Flow.copy_string upstream_request flow;
        let header_buf = Buffer.create 4096 in
        let rec read_headers () =
          let chunk = Cstruct.create 2048 in
          match Eio.Flow.single_read flow chunk with
          | n ->
              Buffer.add_string header_buf (Cstruct.to_string ~len:n chunk);
              let current = Buffer.contents header_buf in
              (try
                 let idx = Str.search_forward (Str.regexp "\r\n\r\n") current 0 in
                 let headers_part = String.sub current 0 idx in
                 let body_start = idx + 4 in
                 let body_rest =
                   if body_start >= String.length current then ""
                   else
                     String.sub current body_start
                       (String.length current - body_start)
                 in
                 Ok (headers_part, body_rest)
               with Not_found -> read_headers ())
          | exception End_of_file ->
              Error
                "llm-mcp closed chain/events stream before headers were received"
        in
        match read_headers () with
        | Error message -> send_error message
        | Ok (headers_part, body_rest) ->
            let status_line =
              match String.split_on_char '\n' headers_part with
              | line :: _ -> String.trim line
              | [] -> "HTTP/1.1 502 Bad Gateway"
            in
            let status_code =
              match String.split_on_char ' ' status_line with
              | _http :: code :: _ -> (try int_of_string code with _ -> 502)
              | _ -> 502
            in
            if status_code < 200 || status_code >= 300 then
              send_error
                (Printf.sprintf "llm-mcp /chain/events upstream returned %d"
                   status_code)
            else (
              if String.length body_rest > 0 then (
                H2.Body.Writer.write_string writer body_rest;
                H2.Body.Writer.flush writer ignore);
              let rec pump () =
                let chunk = Cstruct.create 4096 in
                match Eio.Flow.single_read flow chunk with
                | n when n > 0 ->
                    H2.Body.Writer.write_bigstring writer ~off:0 ~len:n
                      (Cstruct.to_bigarray chunk);
                    H2.Body.Writer.flush writer ignore;
                    pump ()
                | _ -> safe_close ()
                | exception End_of_file -> safe_close ()
                | exception exn -> send_error (Printexc.to_string exn)
              in
              pump ())
      with exn -> send_error (Printexc.to_string exn))

let command_plane_chain_events_h2 ~deps ~request h2_reqd =
  match Tool_command_plane.chain_backend () with
  | Tool_command_plane.Native ->
      stream_native_chain_events_h2 ~deps ~request h2_reqd
  | Tool_command_plane.Compat_llm_mcp ->
      proxy_chain_events_h2 ~deps ~request h2_reqd

let command_plane_operation_checkpoint_http_json ~deps ~state request ~args =
  match
    Command_plane_v2.checkpoint_operation state.Mcp_server.room_config
      ~actor:(command_plane_actor deps request) args
  with
  | Ok operation ->
      Ok
        (`Assoc
          [
            ("status", `String "ok");
            ("result", Command_plane_v2.operation_to_json operation);
            ( "traces",
              Command_plane_v2.list_traces_json state.Mcp_server.room_config
                ~operation_id:operation.operation_id () );
          ])
  | Error message -> Error message
  | exception Invalid_argument message -> Error message

let command_plane_unit_reparent_http_json ~deps ~state request ~args =
  Command_plane_v2.unit_reparent_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_unit_reassign_http_json ~deps ~state request ~args =
  Command_plane_v2.unit_reassign_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_pause_http_json ~deps ~state request ~args =
  Command_plane_v2.pause_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_resume_http_json ~deps ~state request ~args =
  Command_plane_v2.resume_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_stop_http_json ~deps ~state request ~args =
  Command_plane_v2.stop_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_finalize_http_json ~deps ~state request ~args =
  Command_plane_v2.finalize_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_plan_http_json ~state _request ~args =
  Ok (Command_plane_v2.dispatch_plan_json state.Mcp_server.room_config args)

let command_plane_dispatch_assign_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_assign_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_rebalance_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_rebalance_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_escalate_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_escalate_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_recall_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_recall_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_tick_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_tick_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_status_http_json ~state =
  Command_plane_v2.policy_status_json state.Mcp_server.room_config

let command_plane_policy_approve_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_approve_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_deny_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_deny_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_update_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_update_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_freeze_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_freeze_unit_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_kill_switch_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_kill_switch_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_help_http_json () =
  let str_list values = `List (List.map (fun value -> `String value) values) in
  let concept ~id ~title ~summary =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("summary", `String summary);
      ]
  in
  let step ~id ~title ~tool ~summary ~success_signals ~pitfalls =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("tool", `String tool);
        ("summary", `String summary);
        ("success_signals", str_list success_signals);
        ("pitfalls", str_list pitfalls);
      ]
  in
  let path ~id ~title ~summary ~when_to_use ~steps =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("summary", `String summary);
        ("when_to_use", `String when_to_use);
        ("steps", `List steps);
      ]
  in
  let tool_group ~id ~title ~description ~tools =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("description", `String description);
        ("tools", str_list tools);
      ]
  in
  let pitfall ~id ~title ~symptom ~why ~fix_tool ~fix_summary =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("symptom", `String symptom);
        ("why", `String why);
        ("fix_tool", `String fix_tool);
        ("fix_summary", `String fix_summary);
      ]
  in
  let example ~id ~title ~path_id ~transport ~request ~response ~notes =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("path_id", `String path_id);
        ("transport", `String transport);
        ("request", request);
        ("response", response);
        ("notes", str_list notes);
      ]
  in
  `Assoc
    [
      ("version", `String "1");
      ("generated_at", `String (Types.now_iso ()));
      ( "docs",
        `List
          [
            `Assoc
              [
                ("title", `String "Command Plane Runbook");
                ("path", `String "docs/COMMAND-PLANE-RUNBOOK.md");
              ];
            `Assoc
              [
                ("title", `String "Benchmark Runbook");
                ("path", `String "docs/BENCHMARK-RUNBOOK.md");
              ];
            `Assoc
              [
                ("title", `String "Supervisor Mode");
                ("path", `String "docs/SUPERVISOR-MODE.md");
              ];
            `Assoc
              [
                ("title", `String "Swarm Delivery Runbook");
                ("path", `String "docs/SWARM-DELIVERY-RUNBOOK.md");
              ];
          ] );
      ( "concepts",
        `List
          [
            concept ~id:"room" ~title:"Room"
              ~summary:
                "The coordination scope. In practice masc_set_room resolves to the repo-root room, not an arbitrary nested worktree.";
            concept ~id:"task" ~title:"Task"
              ~summary:
                "Backlog work item. Claiming a task does not automatically set the session current_task pointer.";
            concept ~id:"operation" ~title:"Operation"
              ~summary:
                "Managed CPv2 execution unit owned by company/platoon/squad hierarchy.";
            concept ~id:"detachment" ~title:"Detachment"
              ~summary:
                "Scheduler/runtime view of active work under an operation. Use it to inspect progress, liveness, and runtime binding.";
            concept ~id:"policy_decision" ~title:"Policy Decision"
              ~summary:
                "Pending approval item. Cross-platoon moves and disruptive actions stop here until approved or denied.";
            concept ~id:"trace" ~title:"Trace"
              ~summary:
                "End-to-end lineage of operation, checkpoint, dispatch, and policy events.";
          ] );
      ( "golden_paths",
        `List
          [
            path ~id:"room_task_hygiene" ~title:"Room / Task Hygiene"
              ~summary:
                "Minimal MCP sequence before doing any real work in a room."
              ~when_to_use:
                "Use this before benchmark runs, CPv2 experiments, or ordinary implementation work."
              ~steps:
                [
                  step ~id:"join" ~title:"Join the room" ~tool:"masc_join"
                    ~summary:
                      "Register agent identity and capabilities in the repo-root room."
                    ~success_signals:
                      [ "agent visible in masc_status"; "room agent roster includes your agent" ]
                    ~pitfalls:
                      [ "masc_set_room points at repo root semantics"; "without join you are invisible to scheduling" ];
                  step ~id:"claim" ~title:"Claim or create work" ~tool:"masc_claim"
                    ~summary:
                      "Claim an existing task or create one first with masc_add_task when the backlog is empty."
                    ~success_signals:
                      [ "task assignee is your agent"; "task status becomes claimed/in_progress" ]
                    ~pitfalls:
                      [ "claiming alone does not set current_task" ];
                  step ~id:"set-task" ~title:"Bind current task" ~tool:"masc_plan_set_task"
                    ~summary:
                      "Set the current session task pointer so later planning and logs target the correct task."
                    ~success_signals:
                      [ "masc_plan_get_task returns the claimed task id" ]
                    ~pitfalls:
                      [ "dashboard can show claimed task and missing current_task at the same time" ];
                  step ~id:"heartbeat" ~title:"Refresh presence" ~tool:"masc_heartbeat"
                    ~summary:
                      "Update liveness before or during long-running work."
                    ~success_signals:
                      [ "agent status stays active/busy"; "last_seen remains fresh" ]
                    ~pitfalls:
                      [ "without heartbeat an otherwise healthy agent looks zombie/stale" ];
                ];
            path ~id:"cpv2_benchmark" ~title:"CPv2 Benchmark / Swarm"
              ~summary:
                "Canonical benchmark path for company → platoon → squad → agent orchestration."
              ~when_to_use:
                "Use this for real swarm experiments, benchmarking, long-running command-plane work, and 4→16→64 agent rehearsals."
              ~steps:
                [
                  step ~id:"define-units" ~title:"Define hierarchy" ~tool:"masc_unit_define"
                    ~summary:
                      "Create managed company/platoon/squad/agent units with policy and budget envelopes."
                    ~success_signals:
                      [ "masc_observe_topology shows managed units"; "capacity rows appear for units" ]
                    ~pitfalls:
                      [ "missing leaders or empty live rosters block operation start" ];
                  step ~id:"start-operation" ~title:"Start operation" ~tool:"masc_operation_start"
                    ~summary:
                      "Create the managed benchmark operation and bind it to the target unit."
                    ~success_signals:
                      [ "operation appears in masc_observe_operations"; "trace_id is issued" ]
                    ~pitfalls:
                      [ "starting directly on a frozen or killed unit fails" ];
                  step ~id:"dispatch" ~title:"Materialize detachments" ~tool:"masc_dispatch_tick"
                    ~summary:
                      "Run the scheduler/reconciler to create or update detachments."
                    ~success_signals:
                      [ "masc_detachment_list returns active detachments"; "operation moves from planned to active runtime" ]
                    ~pitfalls:
                      [ "active op with zero detachments usually means tick has not been run yet" ];
                  step ~id:"observe" ~title:"Observe runtime" ~tool:"masc_detachment_status"
                    ~summary:
                      "Inspect detachments, topology, alerts, and trace events while the operation runs."
                    ~success_signals:
                      [ "heartbeat_deadline and last_progress_at advance"; "alerts/traces explain stalls or approvals" ]
                    ~pitfalls:
                      [ "pending approvals stop cross-platoon movement until policy action happens" ];
                  step ~id:"approve" ~title:"Handle approval queue" ~tool:"masc_policy_approve"
                    ~summary:
                      "Approve or deny pending policy decisions for strict actions."
                    ~success_signals:
                      [ "decision leaves pending state"; "next tick applies the move or leaves a denial trace" ]
                    ~pitfalls:
                      [ "dispatch_rebalance can legitimately return pending_approval" ];
                  step ~id:"checkpoint" ~title:"Checkpoint and finalize" ~tool:"masc_operation_checkpoint"
                    ~summary:
                      "Record durable state, then finish with masc_operation_finalize when done."
                    ~success_signals:
                      [ "checkpoint_ref stored on operation"; "finalized operation is completed in operations view" ]
                    ~pitfalls:
                      [ "stop/finalize without checkpoint loses resume breadcrumbs" ];
                ];
            path ~id:"supervisor_session" ~title:"Supervisor / Team Session"
              ~summary:
                "Guided intervention loop for supervised implementation sessions."
              ~when_to_use:
                "Use this when a human or supervisor agent steers a team session instead of running direct CPv2 benchmark orchestration."
              ~steps:
                [
                  step ~id:"snapshot" ~title:"Read operator snapshot" ~tool:"masc_operator_snapshot"
                    ~summary:"Read state first from the small operator surface."
                    ~success_signals:[ "summary/full snapshot available" ]
                    ~pitfalls:[ "this is not the benchmark canonical path" ];
                  step ~id:"intervene" ~title:"Preview intervention" ~tool:"masc_operator_action"
                    ~summary:"Prepare a small intervention such as team_note or team_task_inject."
                    ~success_signals:[ "preview token or immediate action result returned" ]
                    ~pitfalls:[ "disruptive actions require confirm" ];
                  step ~id:"confirm" ~title:"Confirm disruptive action" ~tool:"masc_operator_confirm"
                    ~summary:"Execute the previewed intervention once a human approves it."
                    ~success_signals:[ "intervention trace appended"; "team-session reflects the change" ]
                    ~pitfalls:[ "do not mix this path with CPv2 benchmark commands in the same explanation" ];
                ];
          ] );
      ( "tool_groups",
        `List
          [
            tool_group ~id:"room-task" ~title:"Room / Task Hygiene"
              ~description:
                "Core room/task tools every session should use before higher-level workflows."
              ~tools:
                [ "masc_set_room"; "masc_join"; "masc_status"; "masc_claim"; "masc_plan_set_task"; "masc_heartbeat" ];
            tool_group ~id:"cpv2-core" ~title:"CPv2 Benchmark Core"
              ~description:
                "Canonical swarm/benchmark tool family."
              ~tools:
                [ "masc_unit_define"; "masc_operation_start"; "masc_dispatch_tick"; "masc_detachment_list"; "masc_detachment_status"; "masc_observe_topology"; "masc_observe_operations"; "masc_observe_alerts"; "masc_observe_traces"; "masc_policy_status"; "masc_policy_approve"; "masc_policy_deny"; "masc_operation_checkpoint"; "masc_operation_finalize" ];
            tool_group ~id:"supervisor" ~title:"Supervisor Session"
              ~description:
                "Small operator loop for intervention-oriented sessions."
              ~tools:
                [ "masc_operator_snapshot"; "masc_operator_action"; "masc_operator_confirm"; "masc_team_session_events" ];
          ] );
      ( "pitfalls",
        `List
          [
            pitfall ~id:"repo-root-room" ~title:"Room path resolves to repo root"
              ~symptom:"You point masc_set_room at a worktree but the room still behaves like the repo root."
              ~why:"Room semantics are repo-root scoped; worktrees share the same room substrate."
              ~fix_tool:"masc_join"
              ~fix_summary:"Treat worktrees as code-isolation only. Join the repo-root room and reason about shared room state.";
            pitfall ~id:"claimed-not-current" ~title:"Claimed task is not current task"
              ~symptom:"Task is claimed, but planning/log tools still act like no current task is selected."
              ~why:"Claim mutates backlog ownership; it does not set the session current_task pointer."
              ~fix_tool:"masc_plan_set_task"
              ~fix_summary:"Call masc_plan_set_task immediately after claiming the task.";
            pitfall ~id:"heartbeat-stale" ~title:"Agent looks stale"
              ~symptom:"Your agent appears inactive/zombie during long work even though the process is alive."
              ~why:"Heartbeat/liveness was not refreshed recently."
              ~fix_tool:"masc_heartbeat"
              ~fix_summary:"Call masc_heartbeat periodically during long operations or before observing state.";
            pitfall ~id:"no-detachments" ~title:"Operation exists but no detachments"
              ~symptom:"Operation is visible, but detachments list is empty."
              ~why:"The scheduler has not reconciled yet, or the target unit is blocked."
              ~fix_tool:"masc_dispatch_tick"
              ~fix_summary:"Run masc_dispatch_tick, then inspect topology/capacity or policy queue if detachments still do not appear.";
            pitfall ~id:"pending-approval" ~title:"Dispatch is blocked by approval"
              ~symptom:"dispatch_rebalance or related control action returns pending_approval."
              ~why:"Strict cross-platoon or disruptive action requires a policy decision."
              ~fix_tool:"masc_policy_approve"
              ~fix_summary:"Review the pending decision and approve/deny it before running tick again.";
            pitfall ~id:"http-actor-defaults-dashboard"
              ~title:"HTTP actor defaults to dashboard"
              ~symptom:"Operation or trace entries show actor=dashboard even though a human or agent initiated the request."
              ~why:"Mutating HTTP endpoints use dashboard as the fallback actor unless x-masc-agent, x-masc-agent-name, or agent_name is provided."
              ~fix_tool:"masc_operation_start"
              ~fix_summary:"Send x-masc-agent-name (or x-masc-agent) on mutating HTTP requests when actor attribution matters.";
          ] );
      ( "examples",
        `List
          [
            example ~id:"join-room" ~title:"Join room for task hygiene"
              ~path_id:"room_task_hygiene" ~transport:"mcp"
              ~request:
                (`Assoc
                   [
                     ("tool", `String "masc_join");
                     ("arguments",
                      `Assoc
                        [
                          ("agent_name", `String "codex");
                          ("capabilities",
                           `List [ `String "ocaml"; `String "dashboard"; `String "documentation" ]);
                        ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("agent", `String "codex-...");
                     ("status", `String "joined");
                     ("room", `String "repo-root room");
                   ])
              ~notes:
                [ "Response is trimmed to canonical fields."; "Use masc_status next to confirm visibility." ];
            example ~id:"start-op" ~title:"Start benchmark operation"
              ~path_id:"cpv2_benchmark" ~transport:"http"
              ~request:
                (`Assoc
                   [
                     ("method", `String "POST");
                     ("path", `String "/api/v1/command-plane/operations");
                     ("headers", `Assoc [ ("x-masc-agent-name", `String "codex") ]);
                     ("body",
                      `Assoc
                        [
                          ("assigned_unit_id", `String "squad-research-normalize");
                          ("objective", `String "Normalize and verify latest AI research items");
                          ("autonomy_level", `String "L4_Autonomous");
                          ("policy_class", `String "guarded");
                        ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("status", `String "ok");
                     ("result",
                      `Assoc
                        [
                          ("operation_id", `String "op-...");
                          ("trace_id", `String "trace-...");
                          ("status", `String "active");
                        ]);
                   ])
              ~notes:
                [
                  "Run dispatch/tick after operation start to materialize detachments.";
                  "Without x-masc-agent-name (or x-masc-agent), actor attribution falls back to dashboard.";
                ];
            example ~id:"approval" ~title:"Approve strict action"
              ~path_id:"cpv2_benchmark" ~transport:"mcp"
              ~request:
                (`Assoc
                   [
                     ("tool", `String "masc_policy_approve");
                     ("arguments",
                      `Assoc [ ("decision_id", `String "decision-...") ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("status", `String "ok");
                     ("decision_id", `String "decision-...");
                     ("approval_state", `String "approved");
                   ])
              ~notes:
                [ "Follow with masc_dispatch_tick to apply the approved move." ];
          ] );
    ]

let command_plane_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
