let stream_path = "/api/v1/models/metrics/stream"

type request = { window_minutes : int; bucket_minutes : int }

let request req =
  let open Result.Syntax in
  let integer name default = match Server_utils.query_param req name with
    | None -> Ok default
    | Some raw -> (match int_of_string_opt raw with
      | Some value -> Ok value
      | None -> Error (name ^ " must be an integer")) in
  let* window_minutes = integer "window" 30 in
  let* bucket_minutes = integer "bucket_min" 0 in
  if window_minutes <= 0 then Error "window must be positive"
  else if bucket_minutes < 0 || bucket_minutes > max_int / 60
  then Error "bucket_min must be a non-negative duration in minutes"
  else Ok { window_minutes; bucket_minutes }
;;

type snapshot = {
  json : Yojson.Safe.t;
  next_change_at : float option;
  retry_read : bool;
}

let read_snapshot ~base_path ~(request : request) ~now kept =
  let next, reading = Model_inference_metrics_kept.refresh ~base_path ~now
      ~window_minutes:request.window_minutes kept in
  let result = Model_inference_metrics.aggregate_reading
      ~window_minutes:request.window_minutes ~bucket_minutes:request.bucket_minutes reading in
  let snapshot = Result.map (fun aggregate ->
    { json = Model_inference_metrics.to_json aggregate
    ; next_change_at = Model_inference_metrics_kept.next_change next
        ~window_minutes:request.window_minutes ~after:now
    ; retry_read = (match reading.cost_read with Ok _ -> false | Error _ -> true)
    }) result in
  next, Result.map_error Model_inference_metrics.read_error_to_string snapshot
;;

let observation_dataset = Workspace_dataset_event.dataset_name
    (Workspace_dataset_event.Dashboard_observation { topic = `Model_metrics; scope = `Workspace })

let is_invalidation (event : Sse.external_event) =
  if Safe_ops.json_string_opt "type" event.ext_payload <> Some Workspace_dataset_event.event_type
     || Safe_ops.json_string_opt "dataset" event.ext_payload <> Some observation_dataset
  then false
  else match Sse_event.dashboard_observation_changed_payload_of_json event.ext_payload with
    | Error _ -> false
    | Ok payload -> payload.topic = `Model_metrics
;;

let response_headers () =
  Httpun.Headers.of_list
    (Http_server_eio.Response.scoped_headers ()
     @ [ "content-type", "text/event-stream"; "cache-control", "no-cache"
       ; "connection", "close"; "x-accel-buffering", "no"
       ; Server_mcp_transport_http_headers.observer_idle_timeout_header,
         string_of_int Server_mcp_transport_http_headers.observer_idle_timeout_ms ])
;;

let data_frame json = "data: " ^ Yojson.Safe.to_string json ^ "\n\n"

let serve ~sw ~clock ~base_path ~request reqd =
  let authority = Sse.runtime_authority_exn ~base_path in
  let response = Httpun.Response.create ~headers:(response_headers ()) `OK in
  let output = Server_sse_response.respond ~clock
      ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
      ~flush_headers_immediately:true reqd response in
  Eio.Fiber.fork ~sw (fun () ->
    let run () = Eio.Switch.run (fun stream_sw ->
      let kept = ref Model_inference_metrics_kept.empty in
      let wake = Eio.Stream.create 1 in
      let wake_mu = Stdlib.Mutex.create () in
      let active = Atomic.make true in
      let id = "model-metrics:" ^ Random_id.uuid_v7 () in
      let callback event =
        if Atomic.get active && is_invalidation event then
          Stdlib.Mutex.protect wake_mu (fun () ->
            if Eio.Stream.is_empty wake then Eio.Stream.add wake ()) in
      Server_bootstrap_http.with_cleanups_on_release ~sw:stream_sw
        [ (fun () -> Atomic.set active false; Sse.unsubscribe_external id)
        ; (fun () -> Server_sse_response.close output) ];
      (* Subscribe before the first pool read. A concurrent committed source
         retains one trailing read, including while the first answer is sent. *)
      Sse.subscribe_external ~runtime_authority:authority ~id ~callback
        ~is_alive:(fun () -> Atomic.get active) ();
      let send frame = match Server_sse_response.send output frame with
        | Written -> true
        | Closed | Stalled -> false in
      let rec deliver () =
        if not (Server_sse_response.is_closed output) then (
          let previous = !kept in
          let next, result = Pool_work.submit (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
            read_snapshot ~base_path ~request ~now:(Time_compat.now ()) previous)) in
          kept := next;
          match result with
          | Error detail -> ignore (send (data_frame (`Assoc ["error", `String detail])))
          | Ok snapshot ->
              if send (data_frame snapshot.json) && not snapshot.retry_read then wait snapshot.next_change_at)
      and wait deadline =
        let delay = match deadline with
          | None -> Server_mcp_transport_http_headers.sse_ping_interval_s
          | Some at -> min (max 0.0 (at -. Time_compat.now ()))
              Server_mcp_transport_http_headers.sse_ping_interval_s in
        let action = Eio.Fiber.first
            (fun () -> Server_sse_response.await_closed output; `Closed)
            (fun () -> Eio.Fiber.first
              (fun () -> Eio.Stream.take wake; `Changed)
              (fun () -> Eio.Time.sleep clock delay;
                match deadline with
                | Some at when Time_compat.now () >= at -> `Deadline
                | Some _ | None -> `Keepalive)) in
        match action with
        | `Closed -> ()
        | `Changed | `Deadline -> deliver ()
        | `Keepalive -> if send ": keepalive\n\n" then wait deadline
      in
      Eio.Fiber.first (fun () -> Server_sse_response.await_closed output) deliver) in
    match run () with
    | () -> ()
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Log.Server.warn "Model metric stream failed: %s" (Printexc.to_string exn))
;;

let add_routes ~sw ~clock router =
  router |> Server_route.get Server_route.Public_read stream_path (fun state req reqd ->
    match request req with
    | Error detail -> Http_server_eio.Response.json_value ~status:`Bad_request
        (`Assoc ["error", `String detail]) reqd
    | Ok request -> serve ~sw ~clock ~base_path:(Mcp_server.workspace_config state).base_path ~request reqd)
;;
