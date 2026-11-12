(* Idle connection cache of [Http_client]. It parks reusable transport
   connections per origin, closes the ones idle past [idle_ttl_seconds] on
   the monotonic clock it was created with, and closes everything still
   parked when the switch it was created with is released. Each connection
   is opened on a switch of its own, so a failure of a fiber that holds it
   open ends that connection and not the cache's switch. The mutable state
   is reachable only through this module, so every access goes through the
   mutex. *)

type connection = [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t

module Key = struct
  type t =
    { scheme : string
    ; host : string
    ; port : int
    }

  let compare a b =
    match String.compare a.scheme b.scheme with
    | 0 ->
      (match String.compare a.host b.host with
       | 0 -> Int.compare a.port b.port
       | n -> n)
    | n -> n
  ;;
end

module Key_map = Map.Make (Key)

(* A connection and the switch [create] opened it on. [open_owned] runs
   that switch in a daemon of its own. *)
type owned =
  { connection : connection
  ; owner : Eio.Switch.t
  }

(* The owner's switch is cancelled once a fiber on it failed or the cache's
   switch is being cancelled, and finished once its daemon returned. Either
   way the fibers that hold the connection open may be gone. *)
let owner_is_on owned = Option.is_none (Eio.Switch.get_error owned.owner)

type entry =
  { owned : owned
  ; last_used_at : Mtime.t
  }

(* Idle longer than the TTL, or its owner is off: no request takes it, and
   it is closed. *)
let is_reusable ~idle_ttl ~now entry =
  owner_is_on entry.owned
  && not (Mtime.Span.is_longer (Mtime.span entry.last_used_at now) ~than:idle_ttl)
;;

let close_entries entries =
  Eio.Cancel.protect (fun () ->
    List.iter
      (fun e ->
         try Eio.Resource.close e.owned.connection with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | _ -> ())
      entries)
;;

type close_counts =
  { request_failed : int
  ; request_not_delivered : int
  ; not_persistent : int
  ; body_not_drained : int
  ; transport_ended : int
  }

type stats =
  { idle_per_host : (string * int) list
  ; total_idle : int
  ; reuse_count_total : int
  ; create_count_total : int
  ; closed_total : close_counts
  ; closed_after_reuse : close_counts
  }

type close_counters =
  { request_failed_total : int Atomic.t
  ; request_not_delivered_total : int Atomic.t
  ; not_persistent_total : int Atomic.t
  ; body_not_drained_total : int Atomic.t
  ; transport_ended_total : int Atomic.t
  }

let close_counter counters : Reuse_verdict.close_reason -> int Atomic.t = function
  | Request_failed -> counters.request_failed_total
  | Request_not_delivered -> counters.request_not_delivered_total
  | Not_persistent -> counters.not_persistent_total
  | Body_not_drained -> counters.body_not_drained_total
  | Transport_ended -> counters.transport_ended_total
;;

let make_close_counters () =
  { request_failed_total = Atomic.make 0
  ; request_not_delivered_total = Atomic.make 0
  ; not_persistent_total = Atomic.make 0
  ; body_not_drained_total = Atomic.make 0
  ; transport_ended_total = Atomic.make 0
  }
;;

let read_close_counters counters =
  { request_failed = Atomic.get counters.request_failed_total
  ; request_not_delivered = Atomic.get counters.request_not_delivered_total
  ; not_persistent = Atomic.get counters.not_persistent_total
  ; body_not_drained = Atomic.get counters.body_not_drained_total
  ; transport_ended = Atomic.get counters.transport_ended_total
  }
;;

type t =
  { sw : Eio.Switch.t
  ; mu : Eio.Mutex.t
  ; max_idle_per_host : int
  ; idle_ttl : Mtime.span
  ; mutable entries : entry list Key_map.t
  ; reuse_count_total : int Atomic.t
  ; create_count_total : int Atomic.t
  ; closed : close_counters
  ; closed_after_reuse : close_counters
  ; stop : bool Atomic.t
  ; mono_clock : Eio.Time.Mono.ty Eio.Resource.t
  }

let now cache = Eio.Time.Mono.now cache.mono_clock

(* [Mtime.Span.of_float_ns] is [None] for a negative, non-finite, or
   2{^53} ns or longer value, and rounds a value under 1 ns to zero. *)
let idle_ttl_of_seconds seconds =
  match Mtime.Span.of_float_ns (seconds *. 1e9) with
  | Some span when Mtime.Span.is_longer span ~than:Mtime.Span.zero -> span
  | Some _ | None ->
    invalid_arg
      "Http_client_cache.create: idle_ttl_seconds must be at least 1 ns and below 2^53 ns"
;;

let create ~sw ~mono_clock ?(max_idle_per_host = 8) ?(idle_ttl_seconds = 60.0) () : t =
  if max_idle_per_host < 1
  then invalid_arg "Http_client_cache.create: max_idle_per_host must be >= 1";
  let idle_ttl = idle_ttl_of_seconds idle_ttl_seconds in
  let cache =
    { sw
    ; mu = Eio.Mutex.create ()
    ; max_idle_per_host
    ; idle_ttl
    ; entries = Key_map.empty
    ; reuse_count_total = Atomic.make 0
    ; create_count_total = Atomic.make 0
    ; closed = make_close_counters ()
    ; closed_after_reuse = make_close_counters ()
    ; stop = Atomic.make false
    ; mono_clock = (mono_clock :> Eio.Time.Mono.ty Eio.Resource.t)
    }
  in
  Eio.Switch.on_release sw (fun () ->
    Atomic.set cache.stop true;
    let leftover =
      Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
        let all =
          Key_map.fold
            (fun _ entries acc -> List.rev_append entries acc)
            cache.entries
            []
        in
        cache.entries <- Key_map.empty;
        all)
    in
    close_entries leftover);
  (* Eviction daemon: every half TTL on the monotonic clock, it closes the
     entries [is_reusable] refuses. A regular infinite fiber would prevent
     normal switch completion, and the release hook that sets [stop] only
     runs after all fibers finish. *)
  let eviction_interval =
    Mtime.Span.of_uint64_ns (Int64.div (Mtime.Span.to_uint64_ns idle_ttl) 2L)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      if Atomic.get cache.stop
      then `Stop_daemon
      else (
        Eio.Time.Mono.sleep_span cache.mono_clock eviction_interval;
        let now = now cache in
        let stale =
          Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
            let stale = ref [] in
            let remaining =
              Key_map.map
                (List.filter (fun e ->
                   if is_reusable ~idle_ttl:cache.idle_ttl ~now e
                   then true
                   else (
                     stale := e :: !stale;
                     false)))
                cache.entries
            in
            cache.entries <- remaining;
            !stale)
        in
        close_entries stale;
        loop ())
    in
    loop ());
  cache
;;

let stats (cache : t) : stats =
  Eio.Mutex.use_ro cache.mu (fun () ->
    let idle_per_host =
      Key_map.bindings cache.entries
      |> List.map (fun ({ Key.scheme; host; port }, v) ->
        Printf.sprintf "%s://%s:%d" scheme host port, List.length v)
    in
    let total_idle = List.fold_left (fun acc (_, n) -> acc + n) 0 idle_per_host in
    (* [release] counts a close in [closed] before [closed_after_reuse], and a
       reader on another domain may run between the two. Reading in the other
       order keeps every reason's reused count at or below its total. *)
    let closed_after_reuse = read_close_counters cache.closed_after_reuse in
    let closed_total = read_close_counters cache.closed in
    { idle_per_host
    ; total_idle
    ; reuse_count_total = Atomic.get cache.reuse_count_total
    ; create_count_total = Atomic.get cache.create_count_total
    ; closed_total
    ; closed_after_reuse
    })
;;

(* The eviction fiber runs every half TTL, so an entry can outlive the TTL by
   up to that much before it is closed. A request must not take it in that
   time: the server may already have closed it. *)
let take (cache : t) key : owned option =
  if Atomic.get cache.stop
  then None
  else (
    let now = now cache in
    let taken, stale =
      Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
        let parked = Key_map.find_opt key cache.entries |> Option.value ~default:[] in
        let reusable, stale =
          List.partition (is_reusable ~idle_ttl:cache.idle_ttl ~now) parked
        in
        match reusable with
        | e :: rest ->
          cache.entries <- Key_map.add key rest cache.entries;
          Atomic.incr cache.reuse_count_total;
          Some e.owned, stale
        | [] ->
          cache.entries <- Key_map.remove key cache.entries;
          None, stale)
    in
    close_entries stale;
    taken)
;;

(* A connection whose owner is off is closed: the fibers that hold it open
   may be gone, and the next request would meet that. *)
let park (cache : t) key owned : unit =
  let { connection; owner = _ } = owned in
  if Atomic.get cache.stop || not (owner_is_on owned)
  then Eio.Resource.close connection
  else (
    let entry = { owned; last_used_at = now cache } in
    let parked =
      Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
        let existing = Key_map.find_opt key cache.entries |> Option.value ~default:[] in
        if List.length existing < cache.max_idle_per_host
        then (
          cache.entries <- Key_map.add key (entry :: existing) cache.entries;
          true)
        else false)
    in
    if not parked then Eio.Resource.close connection)
;;

type provenance =
  | Reused
  | Created

type lease =
  { cache : t
  ; key : Key.t
  ; owned : owned
  ; provenance : provenance
  ; released : bool Atomic.t
  }

let lease_connection lease = lease.owned.connection

(* Protected because a cancelled request still ends its connection: a
   contended [Eio.Mutex.lock] in [park] is a cancellation point, and a
   connection that is neither parked nor closed stays open until the cache's
   switch ends. *)
let release lease (verdict : Reuse_verdict.t) : unit =
  (* A second release would park one socket twice, and two later requests
     would share it. Like [Eio.Promise.resolve] on a resolved promise, it
     raises instead of acting. *)
  if not (Atomic.compare_and_set lease.released false true)
  then invalid_arg "Http_client_cache.release: the lease was already released";
  let { cache; key; owned; provenance; released = _ } = lease in
  Eio.Cancel.protect (fun () ->
    match verdict with
    | Park -> park cache key owned
    | Close reason ->
      Atomic.incr (close_counter cache.closed reason);
      (match provenance with
       | Reused -> Atomic.incr (close_counter cache.closed_after_reuse reason)
       | Created -> ());
      Eio.Resource.close owned.connection)
;;

(* [connection], whose close also ends the daemon that runs its owner's
   switch. Every path that closes it, in this module or outside, ends that
   daemon. *)
let ending_owner_on_close ~end_owner (connection : connection) : connection =
  let module Flow = struct
    type t = unit

    let read_methods = []
    let single_read () buffer = Eio.Flow.single_read connection buffer
    let single_write () buffers = Eio.Flow.single_write connection buffers
    let copy () ~src = Eio.Flow.copy src connection
    let shutdown () command = Eio.Flow.shutdown connection command
  end
  in
  let close () =
    match Eio.Resource.close connection with
    | () -> end_owner ()
    | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      end_owner ();
      Printexc.raise_with_backtrace exn bt
  in
  Eio.Resource.T
    ( ()
    , Eio.Resource.handler
        (Eio.Resource.H (Eio.Resource.Close, close)
         :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Flow))) )
;;

(* Runs [create] in the calling fiber on a switch of its own, which a daemon
   on the cache's switch runs. A fiber that raises fails the switch it was
   forked on (eio__core.mli [Fiber.fork]: "If the fiber raises an exception,
   [Switch.fail sw] is called"), and "If {!fail} is called, [run] will
   re-raise the exception (after everything is cleaned up)" ([Switch.run]).
   So a fiber [create] leaves on the owner switch, such as
   [Tcp_address_race]'s connection daemon, fails the owner switch alone: the
   daemon here catches what [Switch.run] re-raises, logs it and ends, and
   [is_reusable] and [park] then keep the connection from any later request.
   The owner switch is a child of the cache's switch, so cancelling the
   cache's switch still closes the connection. The daemon ends when the
   connection is closed, or at once when [create] gives none. *)
let open_owned (cache : t) ~create =
  (* "If [sw] is already off then [fn] fails immediately, but the calling
     thread continues" ([Fiber.fork]): the owner switch would never be
     published. *)
  Eio.Switch.check cache.sw;
  let published, publish = Eio.Promise.create () in
  let ended, end_ = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw:cache.sw (fun () ->
    (match
       Eio.Switch.run ~name:"provider-connection-owner" (fun owner ->
         Eio.Promise.resolve publish owner;
         Eio.Promise.await ended)
     with
     | () -> ()
     | exception Eio.Cancel.Cancelled _ when Eio.Fiber.is_cancelled () -> ()
     | exception exn ->
       Diag.warn
         "http_client_cache"
         "a cached connection's owner failed, so the connection is not handed out \
          again: %s"
         (Printexc.to_string exn));
    `Stop_daemon);
  (* Resolved already: a forked fiber runs at once, "without switching to
     any other fiber first" (eio__core.mli [Fiber.fork]), up to its first
     wait, which is [ended]. *)
  let owner = Eio.Promise.await published in
  let end_owner () = ignore (Eio.Promise.try_resolve end_ () : bool) in
  match create ~sw:owner with
  | Ok connection -> Ok { connection = ending_owner_on_close ~end_owner connection; owner }
  | Error _ as error ->
    end_owner ();
    error
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    end_owner ();
    Printexc.raise_with_backtrace exn bt
;;

let checkout (cache : t) key ~create =
  match take cache key with
  | Some owned ->
    Ok { cache; key; owned; provenance = Reused; released = Atomic.make false }
  | None ->
    (match open_owned cache ~create with
     | Ok owned ->
       Atomic.incr cache.create_count_total;
       Ok { cache; key; owned; provenance = Created; released = Atomic.make false }
     | Error _ as error -> error)
;;

let%test_module "a connection owner that fails" =
  (module struct
    exception Owner_failed

    let key = { Key.scheme = "http"; host = "owner.test"; port = 80 }

    (* A connection with no peer: reads end at once and writes are dropped. *)
    let peerless_connection ~closed : connection =
      let module Flow = struct
        type t = unit

        let read_methods = []
        let single_read () _ = raise End_of_file
        let single_write () buffers = Cstruct.lenv buffers
        let copy () ~src:_ = ()
        let shutdown () _ = ()
      end
      in
      Eio.Resource.T
        ( ()
        , Eio.Resource.handler
            (Eio.Resource.H (Eio.Resource.Close, fun () -> closed := true)
             :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Flow))) )
    ;;

    (* A [create] that leaves on the given switch a fiber holding the
       connection, which raises once [fail] is resolved. *)
    let create_failing_after ~fail ~opened ~closed ~sw : (connection, unit) result =
      Eio.Fiber.fork_daemon ~sw (fun () ->
        Eio.Promise.await fail;
        raise Owner_failed);
      incr opened;
      Ok (peerless_connection ~closed)
    ;;

    let lease_of = function
      | Ok lease -> lease
      | Error () -> failwith "checkout returned the Error of a create that has none"
    ;;

    (* [logged] is resolved when the cache logs a warning. *)
    let with_cache f =
      Eio_main.run
      @@ fun env ->
      let logged, log = Eio.Promise.create () in
      Diag.with_sink
        (fun level ~ctx _message ->
           match level with
           | Diag.Warn when String.equal ctx "http_client_cache" ->
             ignore (Eio.Promise.try_resolve log () : bool)
           | Diag.Debug | Diag.Info | Diag.Warn | Diag.Error -> ())
        (fun () ->
           Eio.Switch.run
           @@ fun sw ->
           let cache = create ~sw ~mono_clock:(Eio.Stdenv.mono_clock env) () in
           f ~sw ~cache ~logged)
    ;;

    let%test "an owner that fails while its connection is parked leaves the switch on" =
      with_cache
      @@ fun ~sw ~cache ~logged ->
      let fail, fail_owner = Eio.Promise.create () in
      let never, _ = Eio.Promise.create () in
      let opened = ref 0 in
      let first_closed = ref false in
      let first =
        lease_of
          (checkout cache key ~create:(create_failing_after ~fail ~opened ~closed:first_closed))
      in
      release first Park;
      Eio.Promise.resolve fail_owner ();
      Eio.Promise.await logged;
      let switch_on = Option.is_none (Eio.Switch.get_error sw) in
      let second =
        lease_of
          (checkout cache key
             ~create:(create_failing_after ~fail:never ~opened ~closed:(ref false)))
      in
      let ({ reuse_count_total; total_idle; _ } : stats) = stats cache in
      release second (Close Request_failed);
      switch_on && !opened = 2 && reuse_count_total = 0 && total_idle = 0 && !first_closed
    ;;

    let%test "a connection whose owner failed while it was leased is closed, not parked" =
      with_cache
      @@ fun ~sw ~cache ~logged ->
      let fail, fail_owner = Eio.Promise.create () in
      let closed = ref false in
      let lease =
        lease_of
          (checkout cache key ~create:(create_failing_after ~fail ~opened:(ref 0) ~closed))
      in
      Eio.Promise.resolve fail_owner ();
      Eio.Promise.await logged;
      release lease Park;
      Option.is_none (Eio.Switch.get_error sw) && (stats cache).total_idle = 0 && !closed
    ;;
  end)
;;
