(** Server_mcp_transport_http_conn — SSE connection lifecycle management.

    All access to global registries is protected by [sse_registry_mutex].
    Individual connection writes are protected by per-connection [info.mutex]. *)

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

(** Single mutex protecting both Hashtbl registries. *)
let sse_registry_mutex = Eio.Mutex.create ()

let env_float_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      try float_of_string raw with Failure _ -> default)

let env_int_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      Option.value ~default:default (int_of_string_opt raw))

let sse_reconnect_min_interval_s =
  env_float_or ~name:"MASC_SSE_RECONNECT_MIN_INTERVAL_S" ~default:1.0

let sse_connect_window_s =
  env_float_or ~name:"MASC_SSE_CONNECT_WINDOW_S" ~default:60.0

let sse_connect_max_in_window =
  env_int_or ~name:"MASC_SSE_CONNECT_MAX_IN_WINDOW" ~default:10

(** Register an SSE connection under [sse_registry_mutex].
    All call sites must use this instead of direct [Hashtbl.replace]. *)
let register_sse_conn ~session_id ~info =
  Eio.Mutex.use_rw ~protect:true sse_registry_mutex (fun () ->
    Hashtbl.replace sse_conn_by_session session_id info)

let close_sse_conn info =
  if not info.closed then (
    info.closed <- true;
    info.stop := true;
    (try Httpun.Body.Writer.close info.writer
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Misc.debug "close_sse_conn: %s"
         (Printexc.to_string exn));
    Sse.unregister_if_current info.session_id info.client_id)

let stop_sse_session session_id =
  let info_opt = Eio.Mutex.use_rw ~protect:true sse_registry_mutex (fun () ->
    match Hashtbl.find_opt sse_conn_by_session session_id with
    | None -> None
    | Some info ->
        Hashtbl.remove sse_conn_by_session session_id;
        Hashtbl.remove sse_connect_guard_by_session session_id;
        Some info) in
  match info_opt with
  | None -> ()
  | Some info -> close_sse_conn info

let is_active_sse_session session_id =
  Eio.Mutex.use_ro sse_registry_mutex (fun () ->
    Hashtbl.mem sse_conn_by_session session_id)

(** Number of active SSE connections. *)
let active_session_count () =
  Eio.Mutex.use_ro sse_registry_mutex (fun () ->
    Hashtbl.length sse_conn_by_session)

let reap_stale_guards () =
  Eio.Mutex.use_rw ~protect:true sse_registry_mutex (fun () ->
    let stale =
      Hashtbl.fold (fun sid _ acc ->
        if not (Hashtbl.mem sse_conn_by_session sid) then sid :: acc
        else acc
      ) sse_connect_guard_by_session []
    in
    List.iter (Hashtbl.remove sse_connect_guard_by_session) stale;
    List.length stale)

let close_all_sse_connections () =
  let infos = Eio.Mutex.use_rw ~protect:true sse_registry_mutex (fun () ->
    let all = Hashtbl.fold (fun _k v acc -> v :: acc) sse_conn_by_session [] in
    Hashtbl.clear sse_conn_by_session;
    Hashtbl.clear sse_connect_guard_by_session;
    all) in
  List.iter close_sse_conn infos;
  Log.Server.info "MASC MCP: Closed %d SSE connections"
    (List.length infos)

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
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _exn ->
      close_sse_conn info;
      false

let make_inline_sse_conn ~session_id writer =
  {
    session_id;
    client_id = -1;
    writer;
    mutex = Eio.Mutex.create ();
    stop = ref false;
    closed = false;
  }

let prune_connect_times ~now times =
  if sse_connect_window_s <= 0.0 then times
  else List.filter (fun ts -> now -. ts <= sse_connect_window_s) times

let check_sse_connect_guard session_id =
  Eio.Mutex.use_rw ~protect:true sse_registry_mutex (fun () ->
    let now = Time_compat.now () in
    let state =
      match Hashtbl.find_opt sse_connect_guard_by_session session_id with
      | Some v -> v
      | None -> { last_connect_at = -.1.0; connect_times = [] }
    in
    let recent = prune_connect_times ~now state.connect_times in
    state.connect_times <- recent;
    let session_wait_s =
      if sse_reconnect_min_interval_s <= 0.0 then
        0.0
      else
        sse_reconnect_min_interval_s -. (now -. state.last_connect_at)
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
        Ok ()))
