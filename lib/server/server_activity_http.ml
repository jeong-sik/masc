
type deps = {
  query_param : Httpun.Request.t -> string -> string option;
  int_query_param : Httpun.Request.t -> string -> default:int -> int;
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  get_switch : unit -> Eio.Switch.t option;
  get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t option;
  get_session_id_any : Httpun.Request.t -> string option;
}

let split_csv raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun value -> value <> "")

let kind_filters deps request =
  let from_kinds =
    match deps.query_param request "kinds" with
    | Some raw -> split_csv raw
    | None -> []
  in
  let from_kind =
    match deps.query_param request "kind" with
    | Some raw -> split_csv raw
    | None -> []
  in
  from_kinds @ from_kind |> List.sort_uniq String.compare

(* workspace_filter removed — namespace retired (#unify-namespace). *)

let last_event_id request =
  match Httpun.Headers.get request.Httpun.Request.headers "last-event-id" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value -> max 0 value
      | None -> 0)
  | None -> 0

(* RFC-0201 Step 1.  Default-shaped queries (kinds=[], after_seq=0)
   read from [Dashboard_snapshot.current ()].activity_events_default —
   the snapshot is refreshed every interval_sec by the background
   refresh fiber, so the HTTP path is a wait-free atomic read plus a
   list slice down to the request's [limit].  Non-default queries
   (cursor, kinds filter) fall through to the cache+offload path
   from PR #19150. *)
let slice_default_events_to_limit json ~limit =
  match json with
  | `Assoc fields ->
    let events_list =
      match List.assoc_opt "events" fields with
      | Some (`List xs) -> xs
      | _ -> []
    in
    let len = List.length events_list in
    let sliced =
      if len <= limit then events_list
      else
        (* Drop the oldest entries; snapshot is sorted seq-ascending so
           the most recent [limit] events live at the tail.  Matches
           [Activity_graph.json_response]'s own tail-slice semantics for
           [after_seq=0]. *)
        let drop_count = len - limit in
        List.filteri (fun i _ -> i >= drop_count) events_list
    in
    let next_after_seq =
      match List.rev sliced with
      | (`Assoc last_fields) :: _ ->
        (match List.assoc_opt "seq" last_fields with
         | Some (`Int n) -> `Int n
         | _ -> List.assoc_opt "next_after_seq" fields |> Option.value ~default:(`Int 0))
      | _ ->
        List.assoc_opt "after_seq" fields |> Option.value ~default:(`Int 0)
    in
    let replaced =
      List.map (fun (k, v) ->
        match k with
        | "events" -> (k, `List sliced)
        | "count" -> (k, `Int (List.length sliced))
        | "limit" -> (k, `Int limit)
        | "next_after_seq" -> (k, next_after_seq)
        | _ -> (k, v)) fields
    in
    `Assoc replaced
  | other -> other

let events_http_json ~deps ~state request =

  let kinds = kind_filters deps request in
  let after_seq =
    deps.int_query_param request "after_seq" ~default:0 |> max 0
  in
  let limit =
    deps.int_query_param request "limit" ~default:200
    |> Server_utils.clamp ~min_v:1 ~max_v:1000
  in
  let is_default_query = kinds = [] && after_seq = 0 in
  let snapshot_hit =
    if is_default_query then
      match Dashboard_snapshot.current () with
      | Some snap when snap.activity_events_default <> `Null ->
        Some (slice_default_events_to_limit snap.activity_events_default ~limit)
      | _ -> None
    else None
  in
  match snapshot_hit with
  | Some json -> json
  | None ->
    (* RFC-0201 Step 5.  Cache wrap retired — non-default queries
       (cursor / kinds filter) are operator-driven and rare, so a
       per-key Dashboard_cache entry has marginal hit-rate value.
       Offload via Domain_pool_ref still protects the HTTP main
       domain from JSONL-scan stall. *)
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Activity_graph.json_response (Mcp_server.workspace_config state) ~kinds
        ~after_seq ~limit ())

let parse_since_ms (raw : string) : int option =
  let len = String.length raw in
  if len < 2 then None
  else
  let suffix = raw.[len - 1] in
  let num_str = String.sub raw 0 (len - 1) in
  match (int_of_string_opt num_str, suffix) with
    | Some n, 'm' -> Some (n * 60 * 1000)
    | Some n, 'h' -> Some (n * Masc_time_constants.hour_int * 1000)
    | Some n, 'd' -> Some (n * Masc_time_constants.day_int * 1000)
    | _ -> None

let graph_http_json ~deps ~state request =

  let kinds = kind_filters deps request in
  let limit =
    deps.int_query_param request "limit" ~default:500
    |> Server_utils.clamp ~min_v:50 ~max_v:2000
  in
  let timeline_limit =
    deps.int_query_param request "timeline_limit" ~default:80
    |> Server_utils.clamp ~min_v:10 ~max_v:200
  in
  let since_raw =
    deps.query_param request "since" |> Option.value ~default:""
  in
  (* RFC-0201 Step 2.  Match the snapshot's pre-computed shape
     exactly: [kinds=[]], [limit=500], [timeline_limit=80],
     [since_raw=""].  Aggregated result returned as-is — cannot
     be re-sliced post-compute (unlike Step 1's events list). *)
  let is_default_query =
    kinds = []
    && limit = 500
    && timeline_limit = 80
    && since_raw = ""
  in
  let snapshot_hit =
    if is_default_query then
      match Dashboard_snapshot.current () with
      | Some snap when snap.activity_graph_default <> `Null ->
        Some snap.activity_graph_default
      | _ -> None
    else None
  in
  match snapshot_hit with
  | Some json -> json
  | None ->
    (* RFC-0201 Step 5 — cache wrap retired (see events_http_json). *)
    Domain_pool_ref.submit_io_or_inline (fun () ->
      let since_ms =
        match parse_since_ms since_raw with
        | Some delta_ms ->
            let now_ms = int_of_float (Time_compat.now () *. 1000.0) in
            Some (now_ms - delta_ms)
        | None -> None
      in
      Activity_graph.graph_json (Mcp_server.workspace_config state) ~kinds ~limit
        ~timeline_limit ?since_ms ())

let swimlane_http_json ~deps ~state request =

  let limit =
    deps.int_query_param request "limit" ~default:500
    |> Server_utils.clamp ~min_v:1 ~max_v:2000
  in
  let since_raw =
    deps.query_param request "since" |> Option.value ~default:""
  in
  (* RFC-0201 Step 3.  Snapshot shape: [limit=500], [since_raw=""]
     — exact match required (aggregated result not sliceable). *)
  let is_default_query = limit = 500 && since_raw = "" in
  let snapshot_hit =
    if is_default_query then
      match Dashboard_snapshot.current () with
      | Some snap when snap.activity_swimlane_default <> `Null ->
        Some snap.activity_swimlane_default
      | _ -> None
    else None
  in
  match snapshot_hit with
  | Some json -> json
  | None ->
    (* RFC-0201 Step 5 — cache wrap retired (see events_http_json). *)
    Domain_pool_ref.submit_io_or_inline (fun () ->
      let since_ms =
        match parse_since_ms since_raw with
        | Some delta_ms ->
            let now_ms = int_of_float (Time_compat.now () *. 1000.0) in
            Some (now_ms - delta_ms)
        | None -> None
      in
      Activity_graph.agent_spans_json (Mcp_server.workspace_config state) ~limit
        ?since_ms ())

let stream_headers ~deps origin =
  Httpun.Headers.of_list
    ([
       ("content-type", "text/event-stream");
       ("cache-control", "no-cache");
       ("connection", "keep-alive");
       ("x-accel-buffering", "no");
     ]
    @ deps.cors_headers origin)

let keepalive_interval_s = 30.0

type stream_info = {
  session_id : string;
  client_id : int;
  writer : Httpun.Body.Writer.t;
  mutex : Eio.Mutex.t;
  stop : bool ref;
  mutable closed : bool;
}

let send_raw info data =
  Eio.Mutex.use_rw ~protect:true info.mutex (fun () ->
      if !(info.stop) || info.closed || Httpun.Body.Writer.is_closed info.writer then
        false
      else
        try
          Httpun.Body.Writer.write_string info.writer data;
          Httpun.Body.Writer.flush info.writer (fun _ -> ());
          true
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Log.Social.warn "send_raw write failed: %s" (Printexc.to_string exn);
          info.closed <- true;
          false)

let close_stream info =
  Eio.Mutex.use_rw ~protect:true info.mutex (fun () ->
      if not info.closed then begin
        info.closed <- true;
        info.stop := true;
        if not (Httpun.Body.Writer.is_closed info.writer) then
          Httpun.Body.Writer.close info.writer
      end)

(* Keepalive loop for an activity SSE stream. Sleeps [interval_s] then calls
   [send]; repeats until [stop] is set or [send] returns [false] (the client is
   gone — writer closed / write failed). Setting [stop] on a [false] send makes
   a disconnected client terminate the loop instead of spinning on the
   server-lifetime switch until shutdown.

   Root cause of #21562: the previous loop did [ignore (send_raw …)] and only
   re-checked [info.stop], which nothing on the disconnect path ever set — so
   one fiber leaked per disconnected SSE client. [Eio.Time.sleep] is a
   cancellation point, so cancelling the owning switch still interrupts a
   parked loop promptly and [Eio.Cancel.Cancelled] propagates to the caller for
   fiber teardown. The blocking wait is injected as [sleep] so the loop's
   control flow is deterministic and unit-testable in isolation from the clock.
   Exposed for unit testing. *)
let run_keepalive_loop ~sleep ~stop ~send =
  let rec loop () =
    if not !stop
    then begin
      sleep ();
      if not !stop then if send () then loop () else stop := true
    end
  in
  loop ()

let handle_stream ~deps ~state request reqd =
  let origin = deps.get_origin request in
  let session_id =
    Mcp_session.get_or_generate (deps.get_session_id_any request)
  in

  let kinds = kind_filters deps request in
  let replay_limit =
    deps.int_query_param request "limit" ~default:500
    |> Server_utils.clamp ~min_v:1 ~max_v:1000
  in
  let after_seq =
    max (last_event_id request)
      (deps.int_query_param request "after_seq" ~default:0)
  in
  let headers = stream_headers ~deps origin in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let info_ref : stream_info option ref = ref None in
  let push event =
    match !info_ref with
    | Some info ->
        if not (send_raw info event) then
          Activity_graph.unregister_if_current info.session_id info.client_id
    | None -> ()
  in
  let client_id =
    Activity_graph.register session_id ~push ~last_seq:after_seq
      ~kind_filters:kinds ()
  in
  let info =
    {
      session_id;
      client_id;
      writer;
      mutex = Eio.Mutex.create ();
      stop = ref false;
      closed = false;
    }
  in
  info_ref := Some info;
  ignore
    (send_raw info
       (Server_mcp_transport_http_headers.sse_comment_with_retry
          ~comment:(Printf.sprintf "activity-stream after=%d" after_seq)));
  let replay =
    Activity_graph.list_events (Mcp_server.workspace_config state) ~kinds
      ~after_seq ~limit:replay_limit ()
  in
  List.iter (fun value -> ignore (send_raw info (Activity_graph.format_sse_event value))) replay;
  (match (deps.get_switch (), deps.get_clock ()) with
  | Some sw, Some clock ->
      Eio.Fiber.fork ~sw (fun () ->
          Fun.protect
            ~finally:(fun () ->
              Activity_graph.unregister_if_current info.session_id info.client_id)
            (fun () ->
              match
                run_keepalive_loop
                  ~sleep:(fun () -> Eio.Time.sleep clock keepalive_interval_s)
                  ~stop:info.stop
                  ~send:(fun () -> send_raw info ": keepalive\n\n")
              with
              | () -> close_stream info
              | exception (Eio.Cancel.Cancelled _ as e) -> raise e
              | exception exn ->
                  Log.Social.warn "activity keepalive fiber exception: %s"
                    (Printexc.to_string exn);
                  close_stream info))
  | None, _ | Some _, None -> ());
  ()
