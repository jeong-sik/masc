(** Server_mcp_transport_http_conn — SSE connection lifecycle management.

    All access to global registries is protected by [sse_registry_mutex].
    Individual connection writes are protected by per-connection [info.mutex]. *)

type sse_conn_info = {
  session_id : string;
  client_id : int;
  writer : Httpun.Body.Writer.t;
  mutex : Eio.Mutex.t;
  (* [stop] and [closed] are touched from more than one domain once serving
     runs off the main domain (a disconnect close racing keeper-driven eviction
     / shutdown), so they are [Atomic.t], not a plain [ref] / [mutable].
     [closed] is the single-close guard: [claim_close] flips it false->true with
     [compare_and_set] so exactly one caller resolves the one-shot stop promise.

     Readers treat either [stop=true] or [closed=true] as terminal (e.g.
     [send_raw] short-circuits when either flag is set), so the intermediate
     state where one flag is set before the other is benign. The safety
     invariant is not that a particular transient is unobservable, but that
     every reader branches to the closed/stop path as soon as it sees either
     flag. *)
  stop : bool Atomic.t;
  closed : bool Atomic.t;
  (* Resolved exactly once by [close_sse_conn]. [run_sse_pumps] forks the
     drain/ping pumps under a per-connection switch and awaits this promise;
     resolving it releases that switch, cancelling both pumps — including a
     drain fiber blocked in [Eio.Stream.take] that the [stop] flag alone
     cannot interrupt (#21548). *)
  stop_promise : unit Eio.Promise.t;
  resolve_stop : unit Eio.Promise.u;
}

(* Smart constructor: every [sse_conn_info] must carry a fresh stop promise,
   so callers go through this instead of a record literal. *)
let make_sse_conn ~session_id ~client_id ~writer ~mutex () =
  let stop_promise, resolve_stop = Eio.Promise.create () in
  {
    session_id;
    client_id;
    writer;
    mutex;
    stop = Atomic.make false;
    closed = Atomic.make false;
    stop_promise;
    resolve_stop;
  }

module SMap = Set_util.StringMap

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
      Option.value ~default (float_of_string_opt raw))

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

(** Publish [info] only while no newer connection owns [session_id]. *)
let rec register_sse_conn_if_absent ~session_id ~info =
  let map = Atomic.get sse_conn_by_session in
  if SMap.mem session_id map then false
  else
    let updated = SMap.add session_id info map in
    if Atomic.compare_and_set sse_conn_by_session map updated then true
    else register_sse_conn_if_absent ~session_id ~info

(* Claim the single close of [info]: returns [true] for exactly one caller even
   under concurrent close paths (a disconnect on one domain racing eviction or
   shutdown on another).  The close body below — including
   [Eio.Promise.resolve info.resolve_stop] — must run at most once; a second
   resolve of a one-shot promise raises [Invalid_argument]. *)
let claim_close info = Atomic.compare_and_set info.closed false true

let __test_claim_close = claim_close

let close_sse_conn info =
  if claim_close info then (
    Atomic.set info.stop true;
    (* Release the per-connection pump switch (run_sse_pumps). [claim_close]
       admits exactly one caller, so the promise is resolved exactly once. *)
    Eio.Promise.resolve info.resolve_stop ();
    (* Close the writer under [info.mutex] so it cannot run concurrently with a
       [send_raw] / evict write on another domain — httpun's writer is not
       domain-safe, and every write path already serializes on [info.mutex].
       Mirrors [close_stream] in server_activity_http.ml.  [close_sse_conn] is
       never called while [info.mutex] is held (every call site is outside the
       mutex or in an exception handler after [use_rw] has returned), so this is
       deadlock-free even though [Eio.Mutex] is not reentrant.  Requires an Eio
       context, which every production close path already runs within. *)
    Fun.protect
      ~finally:(fun () ->
        (* Client removal is generation-bound and must complete even when the
           writer mutex/close is the cancellation point.  Otherwise the old
           client record would permanently fail [No_current_client]. *)
        Sse.unregister_if_current info.session_id info.client_id)
      (fun () ->
        try
          Eio.Mutex.use_rw ~protect:true info.mutex (fun () ->
              Httpun.Body.Writer.close info.writer)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Misc.debug "close_sse_conn: %s"
            (Printexc.to_string exn)))

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

let rec stop_sse_session_if_current_preserve_guard session_id client_id =
  let map = Atomic.get sse_conn_by_session in
  match SMap.find_opt session_id map with
  | Some info when info.client_id = client_id ->
      let updated = SMap.remove session_id map in
      if Atomic.compare_and_set sse_conn_by_session map updated then
        close_sse_conn info
      else stop_sse_session_if_current_preserve_guard session_id client_id
  | Some _ | None -> ()

(* RFC-0099 PR-3: evicting variant. Writes an SSE [event: evicted]
   close frame to the client (best-effort) BEFORE the writer is
   closed, then publishes a typed Evict + Close event pair on the
   bus topic. Frame write failure is logged-and-swallowed; the
   eviction proceeds regardless. *)
let stop_sse_session_evict session_id
    ~(reason : Session_lifecycle_event.evict_reason) =
  let info_opt = ref None in
  atomic_update sse_conn_by_session (fun map ->
    match SMap.find_opt session_id map with
    | None -> map
    | Some info ->
        info_opt := Some info;
        SMap.remove session_id map);
  atomic_update sse_connect_guard_by_session (fun map ->
    SMap.remove session_id map);
  (match !info_opt with
   | None -> ()
   | Some info ->
       let frame_data =
         `Assoc
           [ ("type", `String "evicted");
             ( "reason",
               `String
                 (Session_lifecycle_event.evict_reason_to_string reason) );
           ]
         |> Yojson.Safe.to_string
       in
       let frame = Sse.format_event ~event_type:"evicted" frame_data in
       (try
          Eio.Mutex.use_rw ~protect:true info.mutex (fun () ->
            if (not (Atomic.get info.closed)) && not (Atomic.get info.stop) then
              Httpun.Body.Writer.write_string info.writer frame)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Misc.debug
              "stop_sse_session_evict: frame write failed for %s: %s"
              session_id (Printexc.to_string exn));
       close_sse_conn info);
  Session_lifecycle_event.publish
    (Session_lifecycle_event.Evict
       { transport = Session_lifecycle_event.SSE; session_id; reason });
  Session_lifecycle_event.publish
    (Session_lifecycle_event.Close
       { transport = Session_lifecycle_event.SSE;
         session_id;
         reason = Session_lifecycle_event.Evicted reason })

let is_active_sse_session session_id =
  SMap.mem session_id (Atomic.get sse_conn_by_session)

let current_sse_connection_client_id session_id =
  SMap.find_opt session_id (Atomic.get sse_conn_by_session)
  |> Option.map (fun info -> info.client_id)

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
  if Atomic.get info.closed || Atomic.get info.stop || Httpun.Body.Writer.is_closed info.writer then (
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
  make_sse_conn ~session_id ~client_id:(-1) ~writer ~mutex:(Eio.Mutex.create ()) ()

(* Run the SSE drain + ping pumps for a connection under a switch scoped to
   that connection's lifetime, rather than directly on the server-lifetime
   [sw]. A child [conn_sw] holds both pumps as daemons; the supervisor blocks
   on [info.stop_promise]. [close_sse_conn] resolves that promise (the single
   chokepoint for every stop path: disconnect, eviction, server shutdown),
   which returns the supervisor, releases [conn_sw], and cancels both pumps —
   including a drain fiber blocked in [Eio.Stream.take] that the [info.stop]
   flag could not interrupt. Previously both pumps were forked directly on the
   server switch and a stopped session's drain fiber parked forever (#21548).

   [fork_daemon] means the daemons are cancelled (not awaited) when the
   supervisor's [conn_sw] body returns, so a blocked pump never wedges the
   supervisor. If [info] is already closed (connection torn down before the
   pumps started), the promise is already resolved and the supervisor returns
   immediately. *)
let run_sse_pumps ~sw ~(stop_promise : unit Eio.Promise.t)
    ~(drain : unit -> unit) ~(ping : unit -> unit) =
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run (fun conn_sw ->
      Eio.Fiber.fork_daemon ~sw:conn_sw (fun () ->
        drain ();
        `Stop_daemon);
      Eio.Fiber.fork_daemon ~sw:conn_sw (fun () ->
        ping ();
        `Stop_daemon);
      Eio.Promise.await stop_promise))

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
      result := Error (Sse_reject_reason.Session_cooldown, session_wait_s);
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
        result := Error (Sse_reject_reason.Window_limit, window_wait_s);
        map
      end else begin
        result := Ok ();
        SMap.add session_id { last_connect_at = now; connect_times = now :: recent } map
      end
    end
  );
  !result
