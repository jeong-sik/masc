(* Idle connection cache of [Http_client]. It parks reusable transport
   connections per origin, closes the ones idle past [idle_ttl_seconds] on
   the monotonic clock it was created with, and closes everything still
   parked when the switch it was created with is released. The mutable state is reachable only through this module, so
   every access goes through the mutex. *)

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

type entry =
  { connection : connection
  ; last_used_at : Mtime.t
  }

(* Idle longer than the TTL: no request takes it, and it is closed. *)
let is_expired ~idle_ttl ~now entry =
  Mtime.Span.is_longer (Mtime.span entry.last_used_at now) ~than:idle_ttl
;;

let close_entries entries =
  Eio.Cancel.protect (fun () ->
    List.iter
      (fun e ->
         try Eio.Resource.close e.connection with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | _ -> ())
      entries)
;;

type close_counts =
  { request_failed : int
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
  ; not_persistent_total : int Atomic.t
  ; body_not_drained_total : int Atomic.t
  ; transport_ended_total : int Atomic.t
  }

let close_counter counters : Reuse_verdict.close_reason -> int Atomic.t = function
  | Request_failed -> counters.request_failed_total
  | Not_persistent -> counters.not_persistent_total
  | Body_not_drained -> counters.body_not_drained_total
  | Transport_ended -> counters.transport_ended_total
;;

let make_close_counters () =
  { request_failed_total = Atomic.make 0
  ; not_persistent_total = Atomic.make 0
  ; body_not_drained_total = Atomic.make 0
  ; transport_ended_total = Atomic.make 0
  }
;;

let read_close_counters counters =
  { request_failed = Atomic.get counters.request_failed_total
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
    Eio.Cancel.protect (fun () ->
      List.iter
        (fun e ->
           try Eio.Resource.close e.connection with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | _ -> ())
        leftover));
  (* Eviction daemon: every half TTL on the monotonic clock, it closes the
     entries idle past the TTL. A regular infinite fiber would prevent
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
        let expired =
          Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
            let expired = ref [] in
            let remaining =
              Key_map.map
                (List.filter (fun e ->
                   if is_expired ~idle_ttl:cache.idle_ttl ~now e
                   then (
                     expired := e :: !expired;
                     false)
                   else true))
                cache.entries
            in
            cache.entries <- remaining;
            !expired)
        in
        close_entries expired;
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
let take (cache : t) key : connection option =
  if Atomic.get cache.stop
  then None
  else (
    let now = now cache in
    let taken, expired =
      Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
        let parked = Key_map.find_opt key cache.entries |> Option.value ~default:[] in
        let expired, fresh =
          List.partition (is_expired ~idle_ttl:cache.idle_ttl ~now) parked
        in
        match fresh with
        | e :: rest ->
          cache.entries <- Key_map.add key rest cache.entries;
          Atomic.incr cache.reuse_count_total;
          Some e.connection, expired
        | [] ->
          cache.entries <- Key_map.remove key cache.entries;
          None, expired)
    in
    close_entries expired;
    taken)
;;

let park (cache : t) key connection : unit =
  if Atomic.get cache.stop
  then Eio.Resource.close connection
  else (
    let entry = { connection; last_used_at = now cache } in
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
  ; connection : connection
  ; provenance : provenance
  ; released : bool Atomic.t
  }

let lease_connection lease = lease.connection

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
  let { cache; key; connection; provenance; released = _ } = lease in
  Eio.Cancel.protect (fun () ->
    match verdict with
    | Park -> park cache key connection
    | Close reason ->
      Atomic.incr (close_counter cache.closed reason);
      (match provenance with
       | Reused -> Atomic.incr (close_counter cache.closed_after_reuse reason)
       | Created -> ());
      Eio.Resource.close connection)
;;

let checkout (cache : t) key ~create =
  match take cache key with
  | Some connection ->
    Ok { cache; key; connection; provenance = Reused; released = Atomic.make false }
  | None ->
    (match create ~sw:cache.sw with
     | Ok connection ->
       Atomic.incr cache.create_count_total;
       Ok { cache; key; connection; provenance = Created; released = Atomic.make false }
     | Error _ as error -> error)
;;
