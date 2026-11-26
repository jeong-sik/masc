let stream_path = "/api/v1/models/metrics/stream"
let max_window_minutes = 7 * 24 * 60
let max_cached_windows = 8
let max_cached_staleness_s = 900.0

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
  if window_minutes <= 0 || window_minutes > max_window_minutes
  then
    Error
      (Printf.sprintf "window must be between 1 and %d minutes" max_window_minutes)
  else if bucket_minutes < 0 || bucket_minutes > max_int / 60
  then Error "bucket_min must be a non-negative duration in minutes"
  else Ok { window_minutes; bucket_minutes }
;;

type snapshot = {
  json : Yojson.Safe.t;
  next_change_at : float option;
  retry_read : bool;
}

let cost_usd_of_aggregate (agg : Model_inference_metrics.aggregate) : float option =
  match agg.cost_read with
  | Error _ -> None
  | Ok _ ->
    let sum, count =
      List.fold_left
        (fun (acc, n) (s : Model_inference_metrics.model_stats) ->
           match s.total_cost_usd with
           | Some v when Float.is_finite v && v >= 0.0 -> acc +. v, n + 1
           | Some _ | None -> acc, n)
        (0.0, 0)
        agg.models
    in
    if count > 0 then Some sum else None
;;

let read_snapshot_with_cost ~base_path ~(request : request) ~now kept =
  let next, reading = Model_inference_metrics_kept.refresh ~base_path ~now
      ~window_minutes:request.window_minutes kept in
  let result = Model_inference_metrics.aggregate_reading
      ~window_minutes:request.window_minutes ~bucket_minutes:request.bucket_minutes reading in
  let cost_opt =
    match result with
    | Ok agg -> cost_usd_of_aggregate agg
    | Error _ -> None
  in
  let snapshot = Result.map (fun aggregate ->
    { json = Model_inference_metrics.to_json aggregate
    ; next_change_at = Model_inference_metrics_kept.next_change next
        ~window_minutes:request.window_minutes ~after:now
    ; retry_read = (match reading.cost_read with Ok _ -> false | Error _ -> true)
    }) result in
  next, cost_opt, Result.map_error Model_inference_metrics.read_error_to_string snapshot
;;

let read_snapshot ~base_path ~(request : request) ~now kept =
  let next, _cost_opt, res = read_snapshot_with_cost ~base_path ~request ~now kept in
  next, res
;;

module Window_map = Map.Make (struct
  type t = string * int

  let compare (left_path, left_window) (right_path, right_window) =
    let c = String.compare left_path right_path in
    if c <> 0 then c else Int.compare left_window right_window
end)

type cached_kept_entry =
  { kept_value : Model_inference_metrics_kept.t
  ; kept_cost_usd : float option
  ; kept_access_seq : int
  ; kept_updated_at : float
  }

type shared_kept_state =
  { entries : cached_kept_entry Window_map.t
  ; next_seq : int
  }

(* Lock-free immutable cache state updated via CAS, safe across Eio fibers and
   pool domains. Entries older than [max_cached_staleness_s] are evicted on
   access or insertion, and {!Model_inference_metrics_kept.refresh} folds only
   newline-terminated JSONL lines via {!Dated_jsonl.fold_file_appended_entries_result}. *)
let shared_kept_state : shared_kept_state Atomic.t =
  Atomic.make { entries = Window_map.empty; next_seq = 0 }

let rec update_shared_kept_state f =
  let current = Atomic.get shared_kept_state in
  let next, output = f current in
  if Atomic.compare_and_set shared_kept_state current next
  then output
  else update_shared_kept_state f
;;

let prune_stale_shared_kept ~now entries =
  Window_map.filter
    (fun _key entry ->
       now < entry.kept_updated_at
       || now -. entry.kept_updated_at <= max_cached_staleness_s)
    entries
;;

let oldest_shared_kept_key entries =
  Window_map.fold
    (fun key entry oldest ->
       match oldest with
       | None -> Some (key, entry.kept_access_seq)
       | Some (_oldest_key, oldest_seq) ->
         if entry.kept_access_seq < oldest_seq
         then Some (key, entry.kept_access_seq)
         else oldest)
    entries
    None
  |> Option.map fst
;;

let rec evict_excess_shared_kept entries =
  if Window_map.cardinal entries > max_cached_windows
  then (
    match oldest_shared_kept_key entries with
    | None -> entries
    | Some oldest_key ->
      evict_excess_shared_kept (Window_map.remove oldest_key entries))
  else entries
;;

let load_shared_kept ~base_path ~window_minutes ~now ~fallback =
  let key = base_path, window_minutes in
  update_shared_kept_state (fun state ->
    let entries = prune_stale_shared_kept ~now state.entries in
    match Window_map.find_opt key entries with
    | Some entry when now >= entry.kept_updated_at ->
      let seq = state.next_seq + 1 in
      let entries =
        Window_map.add key { entry with kept_access_seq = seq } entries
      in
      { entries; next_seq = seq }, entry.kept_value
    | Some _ | None -> { state with entries }, fallback)
;;

let store_shared_kept ~base_path ~window_minutes ~now ?cost_usd kept_value =
  let key = base_path, window_minutes in
  update_shared_kept_state (fun state ->
    let entries = prune_stale_shared_kept ~now state.entries in
    match Window_map.find_opt key entries with
    | Some existing when existing.kept_updated_at > now ->
      { state with entries }, ()
    | Some _ | None ->
      let kept_access_seq = state.next_seq + 1 in
      let entries =
        Window_map.add
          key
          { kept_value; kept_cost_usd = cost_usd; kept_access_seq; kept_updated_at = now }
          entries
        |> evict_excess_shared_kept
      in
      { entries; next_seq = kept_access_seq }, ())
;;

let read_cached_snapshot ~base_path ~(request : request) ~now =
  let previous =
    load_shared_kept ~base_path ~window_minutes:request.window_minutes ~now
      ~fallback:Model_inference_metrics_kept.empty
  in
  let next, cost_usd, result =
    read_snapshot_with_cost ~base_path ~request ~now previous
  in
  store_shared_kept ~base_path ~window_minutes:request.window_minutes ~now ?cost_usd next;
  result
;;

let peek_cached_cost_24h_usd ~base_path ~now =
  let state = Atomic.get shared_kept_state in
  match Window_map.find_opt (base_path, 1440) state.entries with
  | Some entry
    when now < entry.kept_updated_at
         || now -. entry.kept_updated_at <= max_cached_staleness_s ->
    entry.kept_cost_usd
  | Some _ | None -> None
;;

let read_cost_24h_usd ~base_path ~now =
  let request = { window_minutes = 1440; bucket_minutes = 0 } in
  let previous =
    load_shared_kept ~base_path ~window_minutes:1440 ~now
      ~fallback:Model_inference_metrics_kept.empty
  in
  let next, cost_usd, _result =
    read_snapshot_with_cost ~base_path ~request ~now previous
  in
  store_shared_kept ~base_path ~window_minutes:1440 ~now ?cost_usd next;
  cost_usd
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
  let base_path = (Server_observer_scope.stream_config owner).base_path in
  let current () = Server_observer_scope.stream_is_current owner in
  let authority = Sse.runtime_authority_exn ~base_path in
  let response = Httpun.Response.create ~headers:(response_headers owner) `OK in
  let output = Server_sse_response.respond ~sw ~clock
      ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
      ~flush_headers_immediately:true reqd response in
  Eio.Fiber.fork ~sw (fun () ->
    let run () = Eio.Switch.run (fun stream_sw ->
      let initial_now = Time_compat.now () in
      let kept =
        ref
          ( initial_now
          , load_shared_kept ~base_path ~window_minutes:request.window_minutes
              ~now:initial_now ~fallback:Model_inference_metrics_kept.empty )
      in
      let wake = Eio.Stream.create 1 in
      let wake_mu = Stdlib.Mutex.create () in
      let active = Atomic.make true in
      let id = "model-metrics:" ^ Random_id.uuid_v7 () in
      let callback event =
        if Atomic.get active && current () && is_invalidation event then
          Stdlib.Mutex.protect wake_mu (fun () ->
            if Eio.Stream.is_empty wake then Eio.Stream.add wake ()) in
      Server_bootstrap_http.with_cleanups_on_release ~sw:stream_sw
        [ (fun () -> Atomic.set active false; Sse.unsubscribe_external id)
        ; (fun () -> Server_sse_response.close output) ];
      (* Subscribe before the first pool read. A concurrent committed source
         retains one trailing read, including while the first answer is sent. *)
      Sse.subscribe_external ~runtime_authority:authority ~id ~callback
        ~observer_instance_id:(Server_observer_scope.stream_instance owner)
        ~is_alive:(fun () -> Atomic.get active && current ()) ();
      let send frame = current () && (match Server_sse_response.send output frame with
        | Written -> true
        | Closed | Stalled -> false) in
      let rec deliver () =
        if current () && not (Server_sse_response.is_closed output) then (
          let fallback_at, fallback_val = !kept in
          let next_at, next, result = Pool_work.submit (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
            let now = Time_compat.now () in
            let fallback =
              if now >= fallback_at
              then fallback_val
              else Model_inference_metrics_kept.empty
            in
            let previous =
              load_shared_kept ~base_path ~window_minutes:request.window_minutes
                ~now ~fallback
            in
            let next, cost_usd, result =
              read_snapshot_with_cost ~base_path ~request ~now previous
            in
            store_shared_kept ~base_path ~window_minutes:request.window_minutes
              ~now ?cost_usd next;
            now, next, result)) in
          kept := (next_at, next);
          match result with
          | Error detail -> ignore (send (data_frame (`Assoc ["error", `String detail])))
          | Ok snapshot ->
              if send (data_frame snapshot.json) && not snapshot.retry_read then wait snapshot.next_change_at)
      and wait deadline =
        (* With no deadline only a change or the end wakes the stream. *)
        let due () = match deadline with
          | None -> Eio.Fiber.await_cancel ()
          | Some at -> Eio.Time.sleep clock (max 0.0 (at -. Time_compat.now ())) in
        let action = Eio.Fiber.first
            (fun () -> Server_sse_response.await_closed output; `Closed)
            (fun () -> Eio.Fiber.first
              (fun () -> Eio.Stream.take wake; `Changed)
              (fun () -> due (); `Deadline)) in
        match action with
        | `Closed -> ()
        | `Changed | `Deadline -> deliver ()
      in
      Eio.Fiber.first
        (fun () -> Server_observer_scope.await_stream_replaced owner)
        (fun () -> Eio.Fiber.first
          (fun () -> Server_sse_response.await_closed output) deliver)) in
    match run () with
    | () -> ()
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Log.Server.warn "Model metric stream failed: %s" (Printexc.to_string exn))
;;

let add_routes ~sw ~clock router =
  router |> Server_route.get Server_route.Public_read stream_path (fun state req reqd ->
    Http_server_eio.Response.with_scoped_headers
      (Http_server_eio.Response.scoped_headers () @ Server_auth.public_read_cors_headers req) (fun () ->
    match request req with
    | Error detail -> Http_server_eio.Response.json_value ~status:`Bad_request
        (`Assoc ["error", `String detail]) reqd
    | Ok request ->
        (match Server_observer_scope.admit_stream ~state req with
         | Error error -> Server_observer_scope.refuse_stream error reqd
         | Ok owner -> serve ~sw ~clock ~owner ~request reqd)))
;;
