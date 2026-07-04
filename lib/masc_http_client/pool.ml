(** RFC-0107 Phase D Connection Pool — piaf-backed implementation.

    Design constraints from RFC-0107 Phase D design note and Phase B
    Prior Art research:

    - piaf [Client.t] is per-endpoint (single host). Multi-host pool
      ([Host_key -> queue]) is built here.
    - Pool itself is process-lifetime, attached to a long-lived
      [Eio.Switch] (typically server root_sw).
    - Scoped [request] API over naked acquire/release for leak resistance
      (Eio #244 exactly-one-owner principle).
    - No silent retry — caller decides. (RFC-0107 §"Workaround
      Rejection Bar" anti-pattern.)

    Sub-modules:
    - [Host_key]: pure host identity (scheme, host, port) — pool key.
    - [Idle_entry]: idle piaf [Client.t] + last_used timestamp.
    - [Stats]: monotonically increasing counters for telemetry. *)

(* ── Config ────────────────────────────────────────────────────── *)

type config = {
  max_idle_per_host : int;
  max_total_idle    : int;
  idle_ttl_seconds  : float;
  connect_timeout_seconds : float;
}

let default_config = {
  max_idle_per_host = 8;
  max_total_idle    = 256;
  idle_ttl_seconds  = 60.0;
  connect_timeout_seconds = 5.0;
}

(* ── Host_key ──────────────────────────────────────────────────── *)

module Host_key = struct
  type t = {
    scheme : string;   (* "http" | "https" *)
    host   : string;
    port   : int;
  }

  let compare a b =
    match String.compare a.scheme b.scheme with
    | 0 -> (match String.compare a.host b.host with
            | 0 -> Int.compare a.port b.port
            | n -> n)
    | n -> n

  let to_string k = Printf.sprintf "%s://%s:%d" k.scheme k.host k.port

  let default_port = function "https" -> 443 | _ -> 80

  let of_uri uri =
    let scheme = Uri.scheme uri |> Option.value ~default:"http" in
    (* [Uri.host] returns [Some ""] for URLs like "http:///path" instead
       of [None] (empty authority section). Treat empty as missing so
       downstream connect doesn't try to resolve "". *)
    let host =
      match Uri.host uri with
      | Some "" | None -> "localhost"
      | Some h -> h
    in
    let port = Uri.port uri |> Option.value ~default:(default_port scheme) in
    { scheme; host; port }
end

module Host_map = Map.Make (Host_key)

(* ── Idle entry ────────────────────────────────────────────────── *)

(* A reusable piaf Client.t parked on the pool's switch.  Each entry
   carries its [last_used_ts] so the eviction fiber can age it out
   after [idle_ttl_seconds].

   piaf Client.t internals manage the underlying TCP/TLS socket and
   are bound to the user-supplied [sw].  Because we create clients on
   the pool's long-lived switch, parked entries survive turn
   boundaries (RFC-0107 §3.3 hierarchy). *)
type idle_entry = {
  client      : Piaf.Client.t;
  last_used_ts : float;
}

(* ── Stats counters (mutable refs) ─────────────────────────────── *)

type stats_counters = {
  mutable reuse_count_total  : int;
  mutable evict_count_total  : int;
  mutable evict_failure_count_total : int;
  mutable create_count_total : int;
  mutable inflight           : int;
}

let new_counters () =
  { reuse_count_total = 0;
    evict_count_total = 0;
    evict_failure_count_total = 0;
    create_count_total = 0;
    inflight = 0; }

(* ── Pool state ────────────────────────────────────────────────── *)

(* [idle] is a per-host queue of reusable clients, newest-first (push
   at head on release, pop from head on acquire — LIFO favors warmest
   socket).  Protected by [mu] for race-free reads/writes from
   multiple fibers.  [mu] is [Eio.Mutex] with [~protect:true] so the
   mutex recovers cleanly when a fiber is cancelled mid-critical-section
   (e.g. Eio.Cancel from timeout racing) instead of staying permanently
   poisoned.  We never call user callbacks while holding it. *)
type t = {
  sw       : Eio.Switch.t;
  env      : Eio_unix.Stdenv.base;
  config   : config;
  mu       : Eio.Mutex.t;
  mutable idle : idle_entry list Host_map.t;
  stop     : bool Atomic.t;
  counters : stats_counters;
}

(* Mutex-guarded read/write helpers.

   We must NOT hold [mu] while calling piaf (network IO, may sleep).
   Pattern: pick idle entry under lock → release lock → use entry. *)
let with_mu t f =
  Eio.Mutex.use_rw ~protect:true t.mu f

(* ── Idle eviction fiber ───────────────────────────────────────── *)

let evict_expired_entries t now =
  with_mu t (fun () ->
    let evicted_clients = ref [] in
    let remaining =
      Host_map.map (fun entries ->
        List.filter (fun e ->
          if now -. e.last_used_ts > t.config.idle_ttl_seconds
          then begin
            evicted_clients := e.client :: !evicted_clients;
            t.counters.evict_count_total <- t.counters.evict_count_total + 1;
            false
          end else true
        ) entries
      ) t.idle
    in
    t.idle <- remaining;
    !evicted_clients)
  |> List.iter (fun c ->
       try Piaf.Client.shutdown c
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | _ -> ()
       (* Shutdown is best-effort; the pool already dropped the ref so
          a Piaf-level error here cannot leak a client.  But
          [Eio.Cancel.Cancelled] must propagate so the enclosing fiber
          honors structured-concurrency cancellation (RFC-0106) — the
          previous bare [with _ -> ()] silently swallowed Cancelled,
          letting a dying fiber finish iterating clients instead of
          unwinding promptly. *))

let start_eviction_fiber t =
  Eio.Fiber.fork ~sw:t.sw (fun () ->
    let clock = Eio.Stdenv.clock t.env in
    let rec loop () =
      if Atomic.get t.stop then ()
      else begin
        Eio.Time.sleep clock (t.config.idle_ttl_seconds /. 2.0);
        let now = Eio.Time.now clock in
        (try evict_expired_entries t now
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             t.counters.evict_failure_count_total
               <- t.counters.evict_failure_count_total + 1;
             Log.Http.error
               "[masc_http_client.pool] eviction fiber caught \
                exception (count=%d): %s"
               t.counters.evict_failure_count_total
               (Printexc.to_string exn));
        loop ()
      end
    in
    loop ())

(* ── create / shutdown ─────────────────────────────────────────── *)

let create ~sw ~env ?(config = default_config) () : t =
  let t = {
    sw;
    env;
    config;
    mu = Eio.Mutex.create ();
    idle = Host_map.empty;
    stop = Atomic.make false;
    counters = new_counters ();
  } in
  (* Pool teardown: stop eviction fiber + close all idle clients on
     switch release. In-flight requests outlive this via per-call
     sub-switches. *)
  Eio.Switch.on_release sw (fun () ->
    Atomic.set t.stop true;
    (* Snapshot+clear under lock; close outside lock. *)
    let leftover =
      with_mu t (fun () ->
        let all = Host_map.fold
                    (fun _ entries acc -> entries @ acc)
                    t.idle []
        in
        t.idle <- Host_map.empty;
        all)
    in
    List.iter (fun e ->
      try Piaf.Client.shutdown e.client
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> ()
    ) leftover);
  start_eviction_fiber t;
  t

(* ── acquire / release ─────────────────────────────────────────── *)

(* Try to take a warm client for [key]; returns [None] if the host's
   queue is empty.  No network IO. *)
let try_acquire_idle t key =
  with_mu t (fun () ->
    match Host_map.find_opt key t.idle with
    | None | Some [] -> None
    | Some (e :: rest) ->
      let updated = if rest = [] then Host_map.remove key t.idle
                    else Host_map.add key rest t.idle in
      t.idle <- updated;
      t.counters.reuse_count_total <- t.counters.reuse_count_total + 1;
      Some e.client)

(* Build a fresh piaf client.  Returns [Result] mirroring piaf's API
   so callers can surface DNS/TCP/TLS failures distinctly. *)
let create_fresh t uri =
  match Piaf.Client.create ~sw:t.sw t.env uri with
  | Ok c ->
    t.counters.create_count_total <- t.counters.create_count_total + 1;
    Ok c
  | Error err ->
    Error (Piaf.Error.to_string (err :> Piaf.Error.t))

(* Count idle entries (host_map -> int). For [max_total_idle]. *)
let count_idle t =
  with_mu t (fun () ->
    Host_map.fold (fun _ entries acc -> List.length entries + acc) t.idle 0)

(* Park a client back into the pool, or close it if the pool is full
   or marked stopped.  [close_only] forces close (used when the
   request errored mid-flight and the connection is suspect). *)
let release t key client ~close_only =
  let now =
    try Eio.Time.now (Eio.Stdenv.clock t.env)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> 0.0
    (* If the clock effect raises a non-Cancel exception we are in a
       teardown/shutdown shape and 0.0 is a safe fallback — the only
       use of [now] below is for the [last_used] field on a parked
       entry which will get evicted on the next tick.  But Cancelled
       must propagate per RFC-0106 so the surrounding fiber unwinds
       instead of parking a client during a structured cancellation. *)
  in
  let should_park =
    not close_only
    && not (Atomic.get t.stop)
    && count_idle t < t.config.max_total_idle
  in
  if should_park then begin
    let parked = ref false in
    with_mu t (fun () ->
      let existing = Host_map.find_opt key t.idle |> Option.value ~default:[] in
      if List.length existing < t.config.max_idle_per_host then begin
        let entry = { client; last_used_ts = now } in
        t.idle <- Host_map.add key (entry :: existing) t.idle;
        parked := true
      end);
    if not !parked then begin
      (try Piaf.Client.shutdown client
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | _ -> ());
      with_mu t (fun () ->
        t.counters.evict_count_total <- t.counters.evict_count_total + 1)
    end
  end else
    try Piaf.Client.shutdown client
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> ()

(* ── Public request API ────────────────────────────────────────── *)

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

type http_method = [ `GET | `POST | `PUT | `DELETE | `HEAD | `PATCH ]

let method_to_piaf : http_method -> Piaf.Method.t = function
  | `GET    -> `GET
  | `POST   -> `POST
  | `PUT    -> `PUT
  | `DELETE -> `DELETE
  | `HEAD   -> `HEAD
  | `PATCH  -> `Other "PATCH"

let close_unreleased_client released release_once =
  Eio.Cancel.protect (fun () ->
    if not !released
    then
      try release_once ~close_only:true with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Misc.debug
          "masc_http_client pool ignored close-only release failure: %s"
          (Printexc.to_string exn))

let path_and_query uri =
  let p = Uri.path uri in
  let p = if p = "" then "/" else p in
  match Uri.query uri with
  | [] -> p
  | _ -> p ^ "?" ^ Uri.encoded_of_query (Uri.query uri)

(* Wrap a single request: acquire-or-create client, send, release.
   Errors return [Error string]; the connection is dropped (close)
   on error, parked on success. *)
let do_request t ?headers ?body ~method_ uri : (response, string) result =
  let key = Host_key.of_uri uri in
  let host_origin = Uri.with_uri ~path:(Some "") ~query:None uri in
  let acquired =
    match try_acquire_idle t key with
    | Some c -> Ok c
    | None -> create_fresh t host_origin
  in
  match acquired with
  | Error e -> Error e
  | Ok client ->
    (* Mirror [do_request_with_idle_timeout]: guarantee the client is released
       on EVERY exit. [Pool.request] wraps this call in [with_optional_timeout]'s
       [Eio.Fiber.first]; when the timeout wins it cancels this fiber, and the
       cancel can land inside [Piaf.Body.to_string] — past the explicit releases
       below. Without the finally the Piaf client/socket is neither parked nor
       closed and the FD leaks (#21547). [Eio.Cancel.protect] lets the blocking
       shutdown complete under cancellation; exceptions are swallowed so the
       finalizer cannot mask the original via [Fun.Finally_raised] (CLAUDE.md
       OCaml cleanup rule). *)
    let released = ref false in
    let release_once ~close_only =
      if not !released then begin
        released := true;
        release t key client ~close_only
      end
    in
    let path = path_and_query uri in
    let body_piaf = Option.map Piaf.Body.of_string body in
    Fun.protect
      ~finally:(fun () ->
        close_unreleased_client released release_once)
      (fun () ->
        t.counters.inflight <- t.counters.inflight + 1;
        let result =
          Fun.protect
            ~finally:(fun () -> t.counters.inflight <- t.counters.inflight - 1)
            (fun () ->
               try
                 Piaf.Client.request client ?headers ?body:body_piaf
                   ~meth:(method_to_piaf method_) path
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn -> Error (`Msg (Printexc.to_string exn)))
        in
        match result with
        | Error err ->
          (* Connection is suspect; close, do not park. *)
          release_once ~close_only:true;
          Error (Piaf.Error.to_string (err :> Piaf.Error.t))
        | Ok resp ->
          let status = Piaf.Status.to_code (Piaf.Response.status resp) in
          let headers_list =
            Piaf.Response.headers resp |> Piaf.Headers.to_list
          in
          let body_result = Piaf.Body.to_string (Piaf.Response.body resp) in
          (match body_result with
           | Error err ->
             release_once ~close_only:true;
             Error (Piaf.Error.to_string (err :> Piaf.Error.t))
           | Ok body_str ->
             release_once ~close_only:false;
             Ok { status; headers = headers_list; body = body_str }))

(* Optional wall-clock timeout race; mirrors masc_http_client pattern. *)
let with_optional_timeout
    (type a) ?clock ?timeout_seconds (f : unit -> (a, string) result) :
  (a, string) result =
  match clock, timeout_seconds with
  | Some clock, Some t when t > 0.0 ->
    Eio.Fiber.first
      (fun () -> f ())
      (fun () ->
         Eio.Time.sleep clock t;
         Error (Printf.sprintf "Pool.request: timeout after %.1fs" t))
  | _ -> f ()

let request t ?(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t option)
    ?timeout_seconds ~method_ ~url ?headers ?body () =
  with_optional_timeout ?clock ?timeout_seconds @@ fun () ->
  let uri = Uri.of_string url in
  do_request t ?headers ?body ~method_ uri

(* ── RFC-0129: idle-timeout request with streaming progress ────── *)

type body_progress = {
  first_byte_at_sec : float option;
  last_chunk_at_sec : float option;
  bytes_received    : int;
}

let empty_body_progress = {
  first_byte_at_sec = None;
  last_chunk_at_sec = None;
  bytes_received    = 0;
}

(* Read [body] chunk-by-chunk, tracking progress, with a watchdog fiber
   that cancels when no chunk has arrived for [idle_timeout_sec].

   The body iter fiber and the idle watcher race via [Eio.Fiber.first].
   Whichever finishes first wins; the loser is auto-cancelled. The
   [progress] ref is shared between fibers but only the body fiber
   writes it (Eio is single-domain, no atomic needed). *)
let read_body_with_idle
    ?progress_ref
    ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
    ~(start_sec : float)
    ~(idle_timeout_sec : float)
    (body : Piaf.Body.t)
  : (string * body_progress, string * body_progress) result =
  let buf = Buffer.create 16384 in
  let progress =
    match progress_ref with
    | Some progress -> progress
    | None -> ref empty_body_progress
  in
  let now () = Eio.Time.now clock in
  let on_chunk chunk =
    Buffer.add_string buf chunk;
    let elapsed = now () -. start_sec in
    let first =
      match !progress.first_byte_at_sec with
      | None -> Some elapsed
      | s -> s
    in
    progress := {
      first_byte_at_sec = first;
      last_chunk_at_sec = Some elapsed;
      bytes_received = !progress.bytes_received + String.length chunk;
    }
  in
  Eio.Fiber.first
    (fun () ->
       match Piaf.Body.iter_string ~f:on_chunk body with
       | Ok () -> Ok (Buffer.contents buf, !progress)
       | Error err ->
         Error (Piaf.Error.to_string (err :> Piaf.Error.t), !progress))
    (fun () ->
       (* Idle watcher: sleep one idle window, then compare the last
          observed chunk timestamp. If the body fiber did not record a
          new chunk during the sleep, we declare idle and return Error.
          Otherwise loop. *)
       let rec watch () =
         let last_known = !progress.last_chunk_at_sec in
         Eio.Time.sleep clock idle_timeout_sec;
         if !progress.last_chunk_at_sec = last_known then
           Error
             (Printf.sprintf "idle timeout after %.1fs" idle_timeout_sec,
              !progress)
         else
           watch ()
       in
       watch ())

(* Variant of [do_request] that uses streaming body iteration + idle
   timeout instead of [Piaf.Body.to_string]. Mirrors do_request's
   error-on-suspect-connection / park-on-success policy. *)
let do_request_with_idle_timeout t
    ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
    ~(idle_timeout_sec : float)
    ?progress_ref
    ?headers ?body ~method_ uri
  : (response * body_progress, string * body_progress) result =
  let key = Host_key.of_uri uri in
  let host_origin = Uri.with_uri ~path:(Some "") ~query:None uri in
  let acquired =
    match try_acquire_idle t key with
    | Some c -> Ok c
    | None ->
      (match create_fresh t host_origin with
       | Ok c -> Ok c
       | Error e -> Error e)
  in
  match acquired with
  | Error e -> Error (e, empty_body_progress)
  | Ok client ->
    let released = ref false in
    let release_once ~close_only =
      if not !released then begin
        released := true;
        release t key client ~close_only
      end
    in
    let path = path_and_query uri in
    let body_piaf = Option.map Piaf.Body.of_string body in
    let start_sec = Eio.Time.now clock in
    Fun.protect
      ~finally:(fun () ->
        (* Cancel-safe close. [request_with_idle_timeout]'s outer
           [total_timeout_sec] [Eio.Fiber.first] can cancel this fiber mid-body;
           without [Eio.Cancel.protect] the blocking Piaf shutdown would not
           complete (socket FD leak) and a [Cancelled] raised here would mask the
           original via [Fun.Finally_raised] (CLAUDE.md OCaml cleanup rule). *)
        close_unreleased_client released release_once)
      (fun () ->
         t.counters.inflight <- t.counters.inflight + 1;
         let result =
           Fun.protect
             ~finally:(fun () ->
               t.counters.inflight <- t.counters.inflight - 1)
             (fun () ->
                try
                  Piaf.Client.request client ?headers ?body:body_piaf
                    ~meth:(method_to_piaf method_) path
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn -> Error (`Msg (Printexc.to_string exn)))
         in
         match result with
         | Error err ->
           release_once ~close_only:true;
           Error (Piaf.Error.to_string (err :> Piaf.Error.t), empty_body_progress)
         | Ok resp ->
           let status = Piaf.Status.to_code (Piaf.Response.status resp) in
           let headers_list =
             Piaf.Response.headers resp |> Piaf.Headers.to_list
           in
           (match
              read_body_with_idle ?progress_ref ~clock ~start_sec ~idle_timeout_sec
                (Piaf.Response.body resp)
            with
            | Error (err, p) ->
              (* Idle-cancelled or piaf error: connection is suspect. *)
              release_once ~close_only:true;
              Error (err, p)
            | Ok (body_str, p) ->
              release_once ~close_only:false;
              Ok ({ status; headers = headers_list; body = body_str }, p)))

let request_with_idle_timeout t
    ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
    ~idle_timeout_sec
    ?total_timeout_sec
    ~method_ ~url ?headers ?body () =
  let progress_ref = ref empty_body_progress in
  let run () =
    let uri = Uri.of_string url in
    do_request_with_idle_timeout t ~clock ~idle_timeout_sec ~progress_ref
      ?headers ?body ~method_ uri
  in
  match total_timeout_sec with
  | None -> run ()
  | Some t_total when t_total > 0.0 ->
    Eio.Fiber.first
      (fun () -> run ())
      (fun () ->
	       Eio.Time.sleep clock t_total;
	       Error
	         (Printf.sprintf "total timeout after %.1fs" t_total,
	          !progress_ref))
  | Some _ -> run ()

(* ── Stats ─────────────────────────────────────────────────────── *)

type stats = {
  idle_per_host : (string * int) list;
  total_idle : int;
  total_inflight : int;
  reuse_count_total : int;
  evict_count_total : int;
  evict_failure_count_total : int;
  create_count_total : int;
}

let stats t : stats =
  with_mu t (fun () ->
    let idle_per_host =
      Host_map.bindings t.idle
      |> List.map (fun (k, v) -> Host_key.to_string k, List.length v)
    in
    let total_idle =
      List.fold_left (fun acc (_, n) -> acc + n) 0 idle_per_host
    in
    { idle_per_host;
      total_idle;
      total_inflight = t.counters.inflight;
      reuse_count_total = t.counters.reuse_count_total;
      evict_count_total = t.counters.evict_count_total;
      evict_failure_count_total = t.counters.evict_failure_count_total;
      create_count_total = t.counters.create_count_total; })

(* ── Test-only ─────────────────────────────────────────────────── *)

module For_testing = struct
  module Host_key = Host_key
  let close_unreleased_client = close_unreleased_client
  let read_body_with_idle = read_body_with_idle
end
