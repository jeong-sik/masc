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

module SMap = Map.Make(String)

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then ()
  else atomic_update atomic f

let sse_conn_by_session : sse_conn_info SMap.t Atomic.t = Atomic.make SMap.empty

type sse_connect_guard_state = {
  last_connect_at : float;
  connect_times : float list;
}

let sse_connect_guard_by_session :
    sse_connect_guard_state SMap.t Atomic.t = Atomic.make SMap.empty

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

let guard_deadline state =
  let session_deadline =
    if sse_reconnect_min_interval_s <= 0.0 || state.last_connect_at < 0.0 then
      neg_infinity
    else
      state.last_connect_at +. sse_reconnect_min_interval_s
  in
  let window_deadline =
    if sse_connect_window_s <= 0.0 then
      neg_infinity
    else
      match state.connect_times with
      | latest :: _ -> latest +. sse_connect_window_s
      | [] -> neg_infinity
  in
  Float.max session_deadline window_deadline

let guard_expired ~now ~session_id state =
  not (SMap.mem session_id (Atomic.get sse_conn_by_session)) && now >= guard_deadline state

(** Register an SSE connection under [sse_registry_mutex].
    All call sites must use this instead of direct [Hashtbl.replace]. *)
let register_sse_conn ~session_id ~info =
  atomic_update sse_conn_by_session (fun map -> SMap.add session_id info map)

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

let stop_sse_session_impl ~clear_guard session_id =
  let info_opt = ref None in
  atomic_update sse_conn_by_session (fun map ->
    match SMap.find_opt session_id map with
    | None -> map
    | Some info ->
        info_opt := Some info;
        SMap.remove session_id map
  );
  if clear_guard then
    atomic_update sse_connect_guard_by_session (fun map -> SMap.remove session_id map);
  match !info_opt with
  | None -> ()
  | Some info -> close_sse_conn info

let stop_sse_session session_id =
  stop_sse_session_impl ~clear_guard:true session_id

let stop_sse_session_preserve_guard session_id =
  stop_sse_session_impl ~clear_guard:false session_id

let is_active_sse_session session_id =
  SMap.mem session_id (Atomic.get sse_conn_by_session)

(** Number of active SSE connections. *)
let active_session_count () =
  SMap.cardinal (Atomic.get sse_conn_by_session)

let reap_stale_guards () =
  let now = Time_compat.now () in
  let stale =
    SMap.fold (fun sid state acc ->
      if guard_expired ~now ~session_id:sid state then sid :: acc
      else acc
    ) (Atomic.get sse_connect_guard_by_session) []
  in
  if stale <> [] then
    atomic_update sse_connect_guard_by_session (fun map ->
      List.fold_left (fun acc sid -> SMap.remove sid acc) map stale
    );
  List.length stale

let close_all_sse_connections () =
  let infos =
    SMap.fold (fun _k v acc -> v :: acc) (Atomic.get sse_conn_by_session) []
  in
  Atomic.set sse_conn_by_session SMap.empty;
  Atomic.set sse_connect_guard_by_session SMap.empty;
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
  let now = Time_compat.now () in
  let result = ref (Ok ()) in
  atomic_update sse_connect_guard_by_session (fun map ->
    let state =
      match SMap.find_opt session_id map with
      | Some v ->
          let pruned_times = prune_connect_times ~now v.connect_times in
          let v' = { v with connect_times = pruned_times } in
          if guard_expired ~now ~session_id v' then
            { last_connect_at = -.1.0; connect_times = [] }
          else
            v'
      | None -> { last_connect_at = -.1.0; connect_times = [] }
    in
    let recent = state.connect_times in
    let session_wait_s =
      if sse_reconnect_min_interval_s <= 0.0 then
        0.0
      else
        sse_reconnect_min_interval_s -. (now -. state.last_connect_at)
    in
    if session_wait_s > 0.0 then begin
      result := Error ("session_cooldown", session_wait_s);
      map
    end else begin
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
      if window_wait_s > 0.0 then begin
        result := Error ("window_limit", window_wait_s);
        map
      end else begin
        result := Ok ();
        SMap.add session_id { last_connect_at = now; connect_times = now :: recent } map
      end
    end
  );
  !result
