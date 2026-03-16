type deps = Server_mcp_transport_http_types.deps

type sse_conn_info = {
  session_id : string;
  client_id : int;
  writer : Httpun.Body.Writer.t;
  mutex : Eio.Mutex.t;
  stop : bool ref;
  mutable closed : bool;
}

let sse_conn_by_session : (string, sse_conn_info) Hashtbl.t = Hashtbl.create 128

type sse_connect_guard_state = {
  mutable last_connect_at : float;
  mutable connect_times : float list;
}

let sse_connect_guard_by_session :
    (string, sse_connect_guard_state) Hashtbl.t =
  Hashtbl.create 256

let env_float_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      try float_of_string raw with _ -> default)

let env_int_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      try int_of_string raw with _ -> default)

let sse_reconnect_min_interval_s =
  env_float_or ~name:"MASC_SSE_RECONNECT_MIN_INTERVAL_S" ~default:0.0
  |> Float.max 0.0

let sse_connect_window_s =
  env_float_or ~name:"MASC_SSE_CONNECT_WINDOW_S" ~default:0.0 |> Float.max 0.0

let sse_connect_max_in_window =
  env_int_or ~name:"MASC_SSE_CONNECT_MAX_IN_WINDOW" ~default:0 |> max 0

let prune_connect_times ~now times =
  if sse_connect_window_s <= 0.0 then times
  else List.filter (fun ts -> now -. ts <= sse_connect_window_s) times

let check_sse_connect_guard session_id =
  let now = Time_compat.now () in
  let state =
    match Hashtbl.find_opt sse_connect_guard_by_session session_id with
    | Some v -> v
    | None -> { last_connect_at = -.1.0; connect_times = [] }
  in
  let recent = prune_connect_times ~now state.connect_times in
  state.connect_times <- recent;
  let session_wait_s =
    if sse_reconnect_min_interval_s <= 0.0 then 0.0
    else sse_reconnect_min_interval_s -. (now -. state.last_connect_at)
  in
  if session_wait_s > 0.0 then
    Error ("session_cooldown", session_wait_s)
  else
    let window_wait_s =
      if sse_connect_window_s <= 0.0 || sse_connect_max_in_window <= 0 then
        0.0
      else if List.length recent >= sse_connect_max_in_window then
        match List.rev recent with
        | oldest :: _ -> sse_connect_window_s -. (now -. oldest)
        | [] -> 0.0
      else
        0.0
    in
    if window_wait_s > 0.0 then
      Error ("window_limit", window_wait_s)
    else (
      state.last_connect_at <- now;
      state.connect_times <- now :: recent;
      Hashtbl.replace sse_connect_guard_by_session session_id state;
      Ok ())

let respond_sse_rate_limited ~deps ~origin ~session_id ~protocol_version
    ~reason ~retry_after_s reqd =
  let retry_after_s = Float.max retry_after_s 0.001 in
  let retry_after_header =
    retry_after_s |> Float.ceil |> int_of_float |> max 1 |> string_of_int
  in
  let body =
    `Assoc
      [
        ("error", `String "sse_connection_rate_limited");
        ("reason", `String reason);
        ("retry_after_seconds", `Float retry_after_s);
      ]
    |> Yojson.Safe.to_string
  in
  let headers =
    Httpun.Headers.of_list
      (("content-length", string_of_int (String.length body))
      :: ("retry-after", retry_after_header)
      :: Server_mcp_transport_http_headers.json_headers ~deps session_id
           protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `Too_many_requests in
  Httpun.Reqd.respond_with_string reqd response body

let close_sse_conn info =
  if not info.closed then (
    info.closed <- true;
    info.stop := true;
    (try Httpun.Body.Writer.close info.writer
     with exn ->
       Log.Misc.debug "close_sse_conn: %s"
         (Printexc.to_string exn));
    Sse.unregister_if_current info.session_id info.client_id)

let stop_sse_session session_id =
  match Hashtbl.find_opt sse_conn_by_session session_id with
  | None -> ()
  | Some info ->
      Hashtbl.remove sse_conn_by_session session_id;
      close_sse_conn info

let close_all_sse_connections () =
  let sessions = Hashtbl.fold (fun k _ acc -> k :: acc) sse_conn_by_session [] in
  List.iter stop_sse_session sessions;
  Log.Server.info "🚀 MASC MCP: Closed %d SSE connections"
    (List.length sessions)

let send_raw info data =
  if info.closed || !(info.stop) || Httpun.Body.Writer.is_closed info.writer then (
    close_sse_conn info;
    false)
  else
    try
      Eio.Mutex.use_rw ~protect:true info.mutex (fun () ->
          Httpun.Body.Writer.write_string info.writer data;
          Httpun.Body.Writer.flush info.writer (fun _ -> ()));
      Sse.touch info.session_id;
      true
    with _exn ->
      close_sse_conn info;
      false
