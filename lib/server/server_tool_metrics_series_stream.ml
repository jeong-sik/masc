let stream_path = "/api/v1/tool-metrics/series/stream"

type snapshot = {
  json : Yojson.Safe.t;
  next_change_at : float;
}

let read_snapshot ~config ~(request : Server_dashboard_http_agent_api.tool_series_request) ~now =
  let open Result.Syntax in
  let* window = Server_dashboard_http_agent_api.tool_series_window request ~until:now in
  let* observed = Tool_metrics_store.observe_series ~masc_root:(Workspace.masc_dir config)
      ~window ?tool_name:request.tool_name () in
  Ok { json = Tool_metrics_series.to_json ~generated_at:now ?tool_name:request.tool_name
        ~public_names:Keeper_tool_descriptor_resolution.public_names_for_internal observed.series
     ; next_change_at = observed.next_change_at }
;;

let observation_dataset = Workspace_dataset_event.dataset_name
    (Workspace_dataset_event.Dashboard_observation { topic = `Tool_metrics; scope = `Workspace })

let is_invalidation (event : Sse.external_event) =
  if Safe_ops.json_string_opt "type" event.ext_payload <> Some Workspace_dataset_event.event_type
     || Safe_ops.json_string_opt "dataset" event.ext_payload <> Some observation_dataset
  then false
  else match Sse_event.dashboard_observation_changed_payload_of_json event.ext_payload with
    | Error _ -> false
    | Ok payload -> payload.topic = `Tool_metrics || payload.topic = `Tools
;;

let response_headers owner =
  Httpun.Headers.of_list
    (Http_server_eio.Response.scoped_headers ()
     @ [ "content-type", "text/event-stream"; "cache-control", "no-cache"
       ; "connection", "close"; "x-accel-buffering", "no"
       ; Sse_wire.instance_header, Server_observer_scope.stream_instance owner
       ; Server_mcp_transport_http_headers.observer_idle_timeout_header,
         string_of_int Server_mcp_transport_http_headers.observer_idle_timeout_ms ])
;;

let data_frame json = "data: " ^ Yojson.Safe.to_string json ^ "\n\n"

let serve ~sw ~clock ~owner ~request reqd =
  let config = Server_observer_scope.stream_config owner in
  let current () = Server_observer_scope.stream_is_current owner in
  let authority = Sse.runtime_authority_exn ~base_path:config.Workspace.base_path in
  let response = Httpun.Response.create ~headers:(response_headers owner) `OK in
  let output = Server_sse_response.respond ~clock
      ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
      ~flush_headers_immediately:true reqd response in
  Eio.Fiber.fork ~sw (fun () ->
    let run () = Eio.Switch.run (fun stream_sw ->
      let wake = Eio.Stream.create 1 in
      let wake_mu = Stdlib.Mutex.create () in
      let active = Atomic.make true in
      let id = "tool-series:" ^ Random_id.uuid_v7 () in
      let callback event =
        if Atomic.get active && current () && is_invalidation event then
          Stdlib.Mutex.protect wake_mu (fun () ->
            if Eio.Stream.is_empty wake then Eio.Stream.add wake ()) in
      Server_bootstrap_http.with_cleanups_on_release ~sw:stream_sw
        [ (fun () -> Atomic.set active false; Sse.unsubscribe_external id)
        ; (fun () -> Server_sse_response.close output) ];
      (* Register before the pool read. A write during that read retains
         one wake, so the first snapshot cannot swallow the newest commit. *)
      Sse.subscribe_external ~runtime_authority:authority ~id ~callback
        ~observer_instance_id:(Server_observer_scope.stream_instance owner)
        ~is_alive:(fun () -> Atomic.get active && current ()) ();
      let send frame = current () && (match Server_sse_response.send output frame with
        | Written -> true
        | Closed | Stalled -> false) in
      let rec deliver () =
        if current () && not (Server_sse_response.is_closed output) then
          let result = Pool_work.submit (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
            read_snapshot ~config ~request ~now:(Time_compat.now ()))) in
          match result with
          | Error detail -> ignore (send (data_frame (`Assoc ["error", `String detail])))
          | Ok snapshot -> if send (data_frame snapshot.json) then wait snapshot.next_change_at
      and wait deadline =
        let remaining = max 0.0 (deadline -. Time_compat.now ()) in
        let delay = min remaining Server_mcp_transport_http_headers.sse_ping_interval_s in
        let action = Eio.Fiber.first
            (fun () -> Server_sse_response.await_closed output; `Closed)
            (fun () -> Eio.Fiber.first
              (fun () -> Eio.Stream.take wake; `Changed)
              (fun () -> Eio.Time.sleep clock delay;
                if Time_compat.now () >= deadline then `Deadline else `Keepalive)) in
        if not (current ()) then () else match action with
        | `Closed -> ()
        | `Changed -> deliver ()
        | `Deadline ->
            Dashboard_cache.invalidate
              (Server_dashboard_http_agent_api.tool_series_cache_key config request);
            deliver ()
        | `Keepalive ->
            if send ": keepalive\n\n" then wait deadline
      in
      Eio.Fiber.first
        (fun () -> Server_observer_scope.await_stream_replaced owner)
        (fun () -> Eio.Fiber.first
          (fun () -> Server_sse_response.await_closed output) deliver)) in
    match run () with
    | () -> ()
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Log.Server.warn "Tool series stream failed: %s" (Printexc.to_string exn))
;;

let add_routes ~sw ~clock router =
  router |> Server_route.get Server_route.Public_read stream_path (fun state req reqd ->
    Http_server_eio.Response.with_scoped_headers
      (Http_server_eio.Response.scoped_headers () @ Server_auth.public_read_cors_headers req) (fun () ->
    match Server_dashboard_http_agent_api.tool_series_request req with
    | Error detail -> Http_server_eio.Response.json_value ~status:`Bad_request
        (`Assoc ["error", `String detail]) reqd
    | Ok request ->
        (match Server_observer_scope.admit_stream ~state req with
         | Error error -> Server_observer_scope.refuse_stream error reqd
         | Ok owner -> serve ~sw ~clock ~owner ~request reqd)))
;;
