(** Server_mcp_transport_http_conn — SSE connection lifecycle management.

    The registries are [Atomic.t] maps updated by compare-and-set. A
    connection's response is written and closed only on the domain that runs
    the connection (RFC-0493 §3.2). *)

type sse_conn_info = {
  session_id : string;
  client_id : int;
  response : Server_sse_response.t;
  (* [stop] and [closed] are touched from more than one domain: a close can
     come from the Sse overflow hook, the maintenance fiber or shutdown, so
     they are [Atomic.t], not a plain [ref] / [mutable].
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
let make_sse_conn ~session_id ~client_id ~response () =
  let stop_promise, resolve_stop = Eio.Promise.create () in
  {
    session_id;
    client_id;
    response;
    stop = Atomic.make false;
    closed = Atomic.make false;
    stop_promise;
    resolve_stop;
  }

module SMap = Set_util.StringMap

let sse_conn_by_session : sse_conn_info SMap.t Atomic.t = Atomic.make SMap.empty

type sse_connect_guard_state = {
  last_connect_at : float;
  connect_times : float list;
}

module Connect_guard_key = struct
  type t =
    | Session of string
    | Standalone_observer of { instance_id : string; agent_name : string }

  let compare left right =
    match left, right with
    | Session left, Session right -> String.compare left right
    | Session _, Standalone_observer _ -> -1
    | Standalone_observer _, Session _ -> 1
    | Standalone_observer { instance_id = left_instance; agent_name = left_agent },
      Standalone_observer { instance_id = right_instance; agent_name = right_agent } ->
        let instance_order = String.compare left_instance right_instance in
        if instance_order <> 0 then instance_order else String.compare left_agent right_agent
end

module Guard_map = Map.Make (Connect_guard_key)

let sse_connect_guards :
    sse_connect_guard_state Guard_map.t Atomic.t = Atomic.make Guard_map.empty

(* Read through Env_config_runtime like every other knob. This file used to
   carry its own Sys.getenv_opt wrappers, the one place in the server that did
   not (#28910); the values and the env-var names are unchanged.

   The three knobs are read through [Re_read] thunks, not the cached toplevel
   bindings: the disable contract ([<= 0] disables the guard, negative values
   included) is pinned by tests that set the env var and call the same reader
   the transport uses (task-538). Reading per check also makes a future
   hot-reload of these knobs possible without restarting the server. *)
let sse_reconnect_min_interval_s () =
  Env_config_runtime.Sse_connect_guard.Re_read.reconnect_min_interval_seconds ()

let sse_connect_window_s () = Env_config_runtime.Sse_connect_guard.Re_read.connect_window_seconds ()

let sse_connect_max_in_window () = Env_config_runtime.Sse_connect_guard.Re_read.connect_max_in_window ()

let guard_min_interval_s = function
  | Connect_guard_key.Session _ -> sse_reconnect_min_interval_s ()
  (* Different tabs can open at once with the same credential. Their shared
     window bounds fresh registrations without treating them as one session. *)
  | Connect_guard_key.Standalone_observer _ -> 0.0

let guard_deadline key state =
  let min_interval_s = guard_min_interval_s key in
  let window_s = sse_connect_window_s () in
  let session_deadline =
    if min_interval_s <= 0.0 || state.last_connect_at < 0.0 then
      neg_infinity
    else
      state.last_connect_at +. min_interval_s
  in
  let window_deadline =
    if window_s <= 0.0 then
      neg_infinity
    else
      match state.connect_times with
      | latest :: _ -> latest +. window_s
      | [] -> neg_infinity
  in
  Float.max session_deadline window_deadline

let guard_expired ~now ~key state =
  let connected = match key with
    | Connect_guard_key.Session session_id ->
        SMap.mem session_id (Atomic.get sse_conn_by_session)
    | Connect_guard_key.Standalone_observer _ -> false
  in
  not connected && now >= guard_deadline key state

(** Register an SSE connection in the session registry. All call sites use
    this instead of updating [sse_conn_by_session] directly. *)
let register_sse_conn ~session_id ~info =
  Atomic_util.update sse_conn_by_session (fun map -> SMap.add session_id info map)

let register_sse_conn_if_newer ~session_id ~info =
  let rec install () =
    let current = Atomic.get sse_conn_by_session in
    match SMap.find_opt session_id current with
    | Some existing when existing.client_id >= info.client_id -> false
    | Some _ | None ->
      let next = SMap.add session_id info current in
      if Atomic.compare_and_set sse_conn_by_session current next then true
      else install ()
  in
  install ()

(* Claim the single close of [info]: returns [true] for exactly one caller even
   under concurrent close paths (a disconnect on one domain racing eviction or
   shutdown on another).  The close body below — including
   [Eio.Promise.resolve info.resolve_stop] — must run at most once; a second
   resolve of a one-shot promise raises [Invalid_argument]. *)
let claim_close info = Atomic.compare_and_set info.closed false true

let __test_claim_close = claim_close

(* Any domain may close: this leaves [info.response] alone. The
   [run_sse_pumps] supervisor runs on the connection's domain and closes the
   response there once the stop promise resolves. *)
let close_sse_conn info =
  if claim_close info then (
    Atomic.set info.stop true;
    (* [claim_close] admits exactly one caller, so the promise is resolved
       exactly once. *)
    Eio.Promise.resolve info.resolve_stop ();
    Sse.unregister_if_current info.session_id info.client_id)

(* A workspace lifetime can end after the same MCP session has already opened
   a successor connection. Retire only the connection that owned the lifetime. *)
let stop_sse_conn_if_current info =
  let rec remove () =
    let current = Atomic.get sse_conn_by_session in
    match SMap.find_opt info.session_id current with
    | Some registered when registered == info ->
      let next = SMap.remove info.session_id current in
      if not (Atomic.compare_and_set sse_conn_by_session current next) then remove ()
    | Some _ | None -> ()
  in
  remove ();
  close_sse_conn info

let stop_sse_session_impl ~clear_guard session_id =
  let info_opt = ref None in
  Atomic_util.update sse_conn_by_session (fun map ->
    match SMap.find_opt session_id map with
    | None -> map
    | Some info ->
        info_opt := Some info;
        SMap.remove session_id map
  );
  if clear_guard then
    Atomic_util.update sse_connect_guards (fun map ->
      Guard_map.remove (Connect_guard_key.Session session_id) map);
  match !info_opt with
  | None -> ()
  | Some info -> close_sse_conn info

let stop_sse_session_before ~client_id session_id =
  let info_opt = ref None in
  Atomic_util.update sse_conn_by_session (fun map ->
    match SMap.find_opt session_id map with
    | Some info when info.client_id < client_id ->
        info_opt := Some info;
        SMap.remove session_id map
    | Some _ | None -> map);
  Atomic_util.update sse_connect_guards (fun map ->
    Guard_map.remove (Connect_guard_key.Session session_id) map);
  match !info_opt with
  | None -> ()
  | Some info -> close_sse_conn info

let stop_sse_session session_id =
  stop_sse_session_impl ~clear_guard:true session_id

let stop_sse_session_preserve_guard session_id =
  stop_sse_session_impl ~clear_guard:false session_id

(* RFC-0099 PR-3: the session is stopped as [stop_sse_session] does, and a
   typed Evict + Close event pair goes out on the bus topic. *)
let stop_sse_session_evict session_id
    ~(reason : Session_lifecycle_event.evict_reason) =
  stop_sse_session session_id;
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

(** Number of active SSE connections. *)
let active_session_count () =
  SMap.cardinal (Atomic.get sse_conn_by_session)

let reap_stale_guards () =
  let now = Time_compat.now () in
  let rec reap () =
    let current = Atomic.get sse_connect_guards in
    let next = Guard_map.filter (fun key state ->
      not (guard_expired ~now ~key state)) current in
    if Atomic.compare_and_set sse_connect_guards current next then
      Guard_map.cardinal current - Guard_map.cardinal next
    else reap ()
  in
  reap ()

let close_all_sse_connections () =
  let infos =
    SMap.fold (fun _k v acc -> v :: acc) (Atomic.get sse_conn_by_session) []
  in
  Atomic.set sse_conn_by_session SMap.empty;
  Atomic.set sse_connect_guards Guard_map.empty;
  List.iter close_sse_conn infos;
  Log.Server.info "MASC MCP: Closed %d SSE connections"
    (List.length infos)

let send_raw info data : Server_sse_response.outcome =
  if Atomic.get info.closed || Atomic.get info.stop then Closed
  else
    match Server_sse_response.send info.response data with
    | Written ->
      Sse.touch info.session_id;
      Written
    | (Closed | Stalled) as refused ->
      close_sse_conn info;
      refused

(* What a drain writes, in order (RFC-0493 §3.2). *)
type drain_item =
  | Prime of string
  | Replayed of Sse.delivery
  | Live of Sse.delivery

(* The prime and the replay come first, then the connection's Sse queue.
   Taking a first item does not suspend, and [Sse.take_delivery] suspends
   only before it takes, so a take the pump cancels takes nothing. *)
let drain_source info ~prime ~replay event_stream : drain_item Server_sse_pump.source =
  let first = ref (Prime prime :: List.map (fun delivery -> Replayed delivery) replay) in
  let take_first () =
    match !first with
    | [] -> None
    | item :: rest ->
      first := rest;
      Some item
  in
  { take =
      (fun () ->
        match take_first () with
        | Some item -> item
        | None -> Live (Sse.take_delivery event_stream))
  ; take_nonblocking =
      (fun () ->
        match take_first () with
        | Some _ as item -> item
        | None ->
          Option.map (fun delivery -> Live delivery) (Sse.take_delivery_nonblocking event_stream))
  ; stopped = (fun () -> Atomic.get info.stop || Atomic.get info.closed)
  }

let drain_sse info ~clock ~prime ~replay ~frame_of ~send event_stream =
  (* Every replayed delivery goes in the handoff: one that is not written
     ends the stream, so no live delivery is taken after it. *)
  let handoff = Sse.create_replay_handoff replay in
  Server_sse_pump.run
    ~source:(drain_source info ~prime ~replay event_stream)
    ~step:(function
      | Prime frame -> Server_sse_pump.Send frame
      | Replayed delivery -> Send (frame_of delivery)
      | Live delivery ->
        if Sse.accept_live_delivery handoff delivery then Send (frame_of delivery) else Skip)
    (* The ping pump writes the keepalive. *)
    ~idle:(fun () -> Server_sse_pump.Quiet)
    ~clock
    ~ping_interval_s:Server_mcp_transport_http_headers.sse_ping_interval_s
    ~closed:(fun () -> Server_sse_response.await_closed info.response)
    ~send

(* Run the SSE drain + ping pumps for a connection under a switch scoped to
   that connection's lifetime, rather than directly on the server-lifetime
   [sw]. A child [conn_sw] holds both pumps as daemons; the supervisor blocks
   on [info.stop_promise]. [close_sse_conn] resolves that promise (the single
   chokepoint for every stop path: disconnect, eviction, server shutdown),
   which returns the supervisor, releases [conn_sw], and cancels both pumps —
   including a drain fiber blocked in [Eio.Stream.take] or in a send that
   waits for the socket. Previously both pumps were forked directly on the
   server switch and a stopped session's drain fiber parked forever (#21548).

   The release hook is the one place the response is closed. It runs after
   both pumps have ended, on the connection's domain, and also when [sw] is
   cancelled before anyone closed [info]. If [info] is already closed
   (connection torn down before the pumps started), the promise is already
   resolved and the supervisor returns immediately.

   [Eio.Fiber.fork] runs nothing on a switch that is already off, so then no
   supervisor exists and the response is released here. On a live switch the
   fork runs the supervisor at once, so its release hook is registered before
   [sw] can be cancelled. *)
let release_sse_conn info =
  stop_sse_conn_if_current info;
  Server_sse_response.close info.response

let run_sse_pumps ~sw info ~(drain : unit -> unit) ~(ping : unit -> unit) =
  match Eio.Switch.get_error sw with
  | Some (_ : exn) -> release_sse_conn info
  | None ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run (fun conn_sw ->
        Eio.Switch.on_release conn_sw (fun () -> release_sse_conn info);
        (* A pump returns on its own only after the stop, or after it logged
           an exception it caught (a prime or replay send that raised). The
           connection then has no drain or no ping, so it ends there. *)
        Eio.Fiber.fork_daemon ~sw:conn_sw (fun () ->
          drain ();
          stop_sse_conn_if_current info;
          `Stop_daemon);
        Eio.Fiber.fork_daemon ~sw:conn_sw (fun () ->
          ping ();
          stop_sse_conn_if_current info;
          `Stop_daemon);
        Eio.Promise.await info.stop_promise))

let prune_connect_times ~now times =
  let window_s = sse_connect_window_s () in
  if window_s <= 0.0 then times
  else List.filter (fun ts -> now -. ts <= window_s) times

let check_connect_guard key =
  let now = Time_compat.now () in
  let result = ref (Ok ()) in
  Atomic_util.update sse_connect_guards (fun map ->
    let state =
      match Guard_map.find_opt key map with
      | Some v ->
          let pruned_times = prune_connect_times ~now v.connect_times in
          let v' = { v with connect_times = pruned_times } in
          if guard_expired ~now ~key v' then
            { last_connect_at = -.1.0; connect_times = [] }
          else
            v'
      | None -> { last_connect_at = -.1.0; connect_times = [] }
    in
    let recent = state.connect_times in
    let min_interval_s = guard_min_interval_s key in
    let session_wait_s =
      if min_interval_s <= 0.0 then
        0.0
      else
        min_interval_s -. (now -. state.last_connect_at)
    in
    if session_wait_s > 0.0 then begin
      result := Error (Sse_reject_reason.Session_cooldown, session_wait_s);
      map
    end else begin
      let window_s = sse_connect_window_s () in
      let max_in_window = sse_connect_max_in_window () in
      let window_wait_s =
        if window_s <= 0.0 || max_in_window <= 0 then
          0.0
        else if List.length recent >= max_in_window then
          match List.rev recent with
          | oldest :: _ -> window_s -. (now -. oldest)
          | [] -> 0.0
        else
          0.0
      in
      if window_wait_s > 0.0 then begin
        result := Error (Sse_reject_reason.Window_limit, window_wait_s);
        map
      end else begin
        result := Ok ();
        Guard_map.add key { last_connect_at = now; connect_times = now :: recent } map
      end
    end
  );
  !result

let check_sse_connect_guard session_id =
  check_connect_guard (Connect_guard_key.Session session_id)

let check_standalone_observer_connect_guard ~observer_instance_id
    ~(credential : Masc_domain.agent_credential) =
  if sse_connect_window_s () <= 0.0 || sse_connect_max_in_window () <= 0 then Ok ()
  else
    check_connect_guard
      (Connect_guard_key.Standalone_observer
         { instance_id = observer_instance_id; agent_name = credential.agent_name })
