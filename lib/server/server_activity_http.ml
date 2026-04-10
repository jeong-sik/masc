
type deps = {
  query_param : Httpun.Request.t -> string -> string option;
  int_query_param : Httpun.Request.t -> string -> default:int -> int;
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  get_switch : unit -> Eio.Switch.t option;
  get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t option;
  get_session_id_any : Httpun.Request.t -> string option;
}

let clamp ~min_v ~max_v value = max min_v (min max_v value)

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

(* room_filter removed — namespace retired (#unify-namespace). *)

let last_event_id request =
  match Httpun.Headers.get request.Httpun.Request.headers "last-event-id" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value -> max 0 value
      | None -> 0)
  | None -> 0

let events_http_json ~deps ~state request =

  let kinds = kind_filters deps request in
  let after_seq =
    deps.int_query_param request "after_seq" ~default:0 |> max 0
  in
  let limit =
    deps.int_query_param request "limit" ~default:200
    |> clamp ~min_v:1 ~max_v:1000
  in
  Activity_graph.json_response state.Mcp_server.room_config ~kinds
    ~after_seq ~limit ()

let parse_since_ms (raw : string) : int option =
  let len = String.length raw in
  if len < 2 then None
  else
    let suffix = raw.[len - 1] in
    let num_str = String.sub raw 0 (len - 1) in
    match (int_of_string_opt num_str, suffix) with
    | Some n, 'h' -> Some (n * 3600 * 1000)
    | Some n, 'd' -> Some (n * 24 * 3600 * 1000)
    | _ -> None

let graph_http_json ~deps ~state request =

  let kinds = kind_filters deps request in
  let limit =
    deps.int_query_param request "limit" ~default:500
    |> clamp ~min_v:50 ~max_v:2000
  in
  let timeline_limit =
    deps.int_query_param request "timeline_limit" ~default:80
    |> clamp ~min_v:10 ~max_v:200
  in
  let since_ms =
    match deps.query_param request "since" with
    | Some raw ->
        (match parse_since_ms raw with
         | Some delta_ms ->
             let now_ms = int_of_float (Time_compat.now () *. 1000.0) in
             Some (now_ms - delta_ms)
         | None -> None)
    | None -> None
  in
  Activity_graph.graph_json state.Mcp_server.room_config ~kinds ~limit
    ~timeline_limit ?since_ms ()

let swimlane_http_json ~deps ~state request =

  let limit =
    deps.int_query_param request "limit" ~default:500
    |> clamp ~min_v:1 ~max_v:2000
  in
  let since_ms =
    match deps.query_param request "since" with
    | Some raw ->
        (match parse_since_ms raw with
         | Some delta_ms ->
             let now_ms = int_of_float (Time_compat.now () *. 1000.0) in
             Some (now_ms - delta_ms)
         | None -> None)
    | None -> None
  in
  Activity_graph.agent_spans_json state.Mcp_server.room_config ~limit
    ?since_ms ()

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

let handle_stream ~deps ~state request reqd =
  let origin = deps.get_origin request in
  let session_id =
    Mcp_session.get_or_generate (deps.get_session_id_any request)
  in

  let kinds = kind_filters deps request in
  let replay_limit =
    deps.int_query_param request "limit" ~default:500
    |> clamp ~min_v:1 ~max_v:1000
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
       (Printf.sprintf ": activity-stream after=%d\nretry: 3000\n\n"
          after_seq));
  let replay =
    Activity_graph.list_events state.Mcp_server.room_config ~kinds
      ~after_seq ~limit:replay_limit ()
  in
  List.iter (fun value -> ignore (send_raw info (Activity_graph.format_sse_event value))) replay;
  (match (deps.get_switch (), deps.get_clock ()) with
  | Some sw, Some clock ->
      Eio.Fiber.fork ~sw (fun () ->
          let is_cancelled = function
            | Eio.Cancel.Cancelled _ -> true
            | _ -> false
          in
          let rec loop () =
            if not !(info.stop) then begin
              (try Eio.Time.sleep clock keepalive_interval_s
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> if is_cancelled exn then raise exn);
              if not !(info.stop) then
                ignore (send_raw info ": keepalive\n\n");
              loop ()
            end
          in
          try loop ()
          with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            if not (is_cancelled exn) then close_stream info;
            Activity_graph.unregister_if_current info.session_id info.client_id)
  | _ -> ());
  ()
