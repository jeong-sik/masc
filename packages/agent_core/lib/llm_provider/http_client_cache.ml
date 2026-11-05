(* Idle connection cache of [Http_client]. It parks reusable transport
   connections per origin, closes the ones idle past [idle_ttl_seconds], and
   closes everything still parked when the switch it was created with is
   released. The mutable state is reachable only through this module, so
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
  ; last_used_at : float
  }

(* Idle longer than the TTL: no request takes it, and it is closed. *)
let is_expired ~idle_ttl_seconds ~now entry = now -. entry.last_used_at > idle_ttl_seconds

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

type t =
  { sw : Eio.Switch.t
  ; mu : Eio.Mutex.t
  ; max_idle_per_host : int
  ; idle_ttl_seconds : float
  ; mutable entries : entry list Key_map.t
  ; reuse_count_total : int Atomic.t
  ; create_count_total : int Atomic.t
  ; closed : close_counters
  ; stop : bool Atomic.t
  ; now : unit -> float
  }

let create ~sw ?clock ?(max_idle_per_host = 8) ?(idle_ttl_seconds = 60.0) () : t =
  if max_idle_per_host < 1
  then invalid_arg "Http_client_cache.create: max_idle_per_host must be >= 1";
  if idle_ttl_seconds <= 0.0
  then invalid_arg "Http_client_cache.create: idle_ttl_seconds must be > 0";
  let cache =
    let now =
      match clock with
      | Some clock -> fun () -> Eio.Time.now clock
      | None -> Unix.gettimeofday
    in
    { sw
    ; mu = Eio.Mutex.create ()
    ; max_idle_per_host
    ; idle_ttl_seconds
    ; entries = Key_map.empty
    ; reuse_count_total = Atomic.make 0
    ; create_count_total = Atomic.make 0
    ; closed =
        { request_failed_total = Atomic.make 0
        ; not_persistent_total = Atomic.make 0
        ; body_not_drained_total = Atomic.make 0
        ; transport_ended_total = Atomic.make 0
        }
    ; stop = Atomic.make false
    ; now
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
  (* Eviction daemon: reap entries past [idle_ttl_seconds] when a clock
     is supplied. A regular infinite fiber would prevent normal switch
     completion, and the release hook that sets [stop] only runs after all
     fibers finish. Without a clock the cache still works; stale entries
     are closed on switch release. *)
  (match clock with
   | Some clock ->
     Eio.Fiber.fork_daemon ~sw (fun () ->
       let rec loop () =
         if Atomic.get cache.stop
         then `Stop_daemon
         else (
           Eio.Time.sleep clock (cache.idle_ttl_seconds /. 2.0);
           let now = cache.now () in
           let expired =
             Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
               let expired = ref [] in
               let remaining =
                 Key_map.map
                   (List.filter (fun e ->
                      if is_expired ~idle_ttl_seconds:cache.idle_ttl_seconds ~now e
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
       loop ())
   | None -> ());
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
    { idle_per_host
    ; total_idle
    ; reuse_count_total = Atomic.get cache.reuse_count_total
    ; create_count_total = Atomic.get cache.create_count_total
    ; closed_total =
        { request_failed = Atomic.get cache.closed.request_failed_total
        ; not_persistent = Atomic.get cache.closed.not_persistent_total
        ; body_not_drained = Atomic.get cache.closed.body_not_drained_total
        ; transport_ended = Atomic.get cache.closed.transport_ended_total
        }
    })
;;

(* The eviction fiber runs every half TTL, so an entry can outlive the TTL by
   up to that much before it is closed. A request must not take it in that
   time: the server may already have closed it. *)
let take (cache : t) key : connection option =
  if Atomic.get cache.stop
  then None
  else (
    let now = cache.now () in
    let taken, expired =
      Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
        let parked = Key_map.find_opt key cache.entries |> Option.value ~default:[] in
        let expired, fresh =
          List.partition (is_expired ~idle_ttl_seconds:cache.idle_ttl_seconds ~now) parked
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
    let entry = { connection; last_used_at = cache.now () } in
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

(* Protected because a cancelled request still ends its connection: a
   contended [Eio.Mutex.lock] in [park] is a cancellation point, and a
   connection that is neither parked nor closed stays open until the cache's
   switch ends. *)
let release (cache : t) key connection (verdict : Reuse_verdict.t) : unit =
  Eio.Cancel.protect (fun () ->
    match verdict with
    | Park -> park cache key connection
    | Close reason ->
      Atomic.incr (close_counter cache.closed reason);
      Eio.Resource.close connection)
;;

let checkout (cache : t) key ~create =
  match take cache key with
  | Some connection -> Ok connection
  | None ->
    (match create ~sw:cache.sw with
     | Ok connection ->
       Atomic.incr cache.create_count_total;
       Ok connection
     | Error _ as error -> error)
;;
