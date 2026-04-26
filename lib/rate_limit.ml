(** Rate Limiting for masc-mcp

    Provides token bucket rate limiting per client/agent.

    Configuration via environment:
    - MASC_RATE_LIMIT: requests per second (default: 20)
    - MASC_RATE_BURST: burst capacity (default: 50)

    @since 0.4.0
*)

module StringMap = Map.Make (String)

(** {1 Token Bucket Algorithm} *)

type bucket =
  { mutable tokens : float
  ; mutable last_update : float
  }

type t =
  { rate : float
  ; burst : int
  ; buckets : bucket StringMap.t ref
  ; mutex : Eio.Mutex.t
  }

(** {1 Configuration} *)

let default_rate = 60.0 (* 12+ concurrent keepers need higher throughput *)
let default_burst = 150
let rate_from_env () = Env_config.Rate_bucket.rate
let burst_from_env () = Env_config.Rate_bucket.burst

(** {1 Limiter Creation} *)

let create ?(rate = default_rate) ?(burst = default_burst) () =
  { rate; burst; buckets = ref StringMap.empty; mutex = Eio.Mutex.create () }
;;

let rate t = t.rate
let burst t = t.burst
let create_from_env () = create ~rate:(rate_from_env ()) ~burst:(burst_from_env ()) ()

(** {1 Rate Checking} *)

let with_lock limiter f = Eio.Mutex.use_rw ~protect:true limiter.mutex (fun () -> f ())

let check limiter ~key =
  with_lock limiter (fun () ->
    let now = Time_compat.now () in
    let bucket =
      match StringMap.find_opt key !(limiter.buckets) with
      | Some b -> b
      | None ->
        let b = { tokens = float_of_int limiter.burst; last_update = now } in
        limiter.buckets := StringMap.add key b !(limiter.buckets);
        b
    in
    let elapsed = now -. bucket.last_update in
    let new_tokens = bucket.tokens +. (elapsed *. limiter.rate) in
    bucket.tokens <- min (float_of_int limiter.burst) new_tokens;
    bucket.last_update <- now;
    if bucket.tokens >= 1.0
    then (
      bucket.tokens <- bucket.tokens -. 1.0;
      true)
    else false)
;;

let remaining limiter ~key =
  with_lock limiter (fun () ->
    match StringMap.find_opt key !(limiter.buckets) with
    | Some b -> int_of_float b.tokens
    | None -> limiter.burst)
;;

(** {1 Cleanup} *)

let cleanup limiter ~older_than_seconds =
  with_lock limiter (fun () ->
    let now = Time_compat.now () in
    let threshold = now -. float_of_int older_than_seconds in
    let to_remove =
      StringMap.fold
        (fun key bucket acc ->
           if bucket.last_update <= threshold then key :: acc else acc)
        !(limiter.buckets)
        []
    in
    limiter.buckets
    := List.fold_left (fun m k -> StringMap.remove k m) !(limiter.buckets) to_remove;
    List.length to_remove)
;;

(** {1 Global Instance}

    Uses [Eio.Lazy] for fiber-safe initialization.
    [cancel:`Protect] ensures init completes even if forcing fiber is cancelled. *)

let global = Eio.Lazy.from_fun ~cancel:`Protect create_from_env
let check_global ~key = check (Eio.Lazy.force global) ~key
let remaining_global ~key = remaining (Eio.Lazy.force global) ~key

(** {1 Automatic Cleanup Loop} *)

(** Start a background fiber that periodically cleans up stale rate limit buckets.
    Call this once at server startup with the main switch. *)
let start_cleanup_loop
      ~sw
      ~clock
      ?(interval = Env_config.RateLimit.cleanup_interval_seconds)
      limiter
  =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock interval;
      (try
         let older_than_seconds =
           int_of_float Env_config.RateLimit.entry_max_age_seconds
         in
         let removed = cleanup limiter ~older_than_seconds in
         if removed > 0 then Log.Misc.info "Cleaned up %d stale buckets" removed
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn "rate_limit cleanup iteration failed: %s" (Printexc.to_string exn));
      loop ()
    in
    loop ())
;;

(** {1 HTTP Helpers} *)

let headers limiter ~key =
  let remaining = remaining limiter ~key in
  [ "X-RateLimit-Limit", string_of_int limiter.burst
  ; "X-RateLimit-Remaining", string_of_int remaining
  ]
;;

let too_many_requests_body () =
  {|{"error":"Too Many Requests","message":"Rate limit exceeded"}|}
;;

let headers_global ~key = headers (Eio.Lazy.force global) ~key

(** {1 Client Address Key Extraction} *)

(** Convert an [Eio.Net.Sockaddr.stream] to a rate-limit key string.
    For TCP connections the key is the client IP address (dotted-decimal for
    IPv4, colon-hex for IPv6).  Unix-domain sockets use a "unix:" prefix so
    they never collide with TCP keys.  The port is excluded so that all
    connections from the same host share one rate-limit bucket. *)
let key_of_sockaddr (client_addr : Eio.Net.Sockaddr.stream) =
  match client_addr with
  | `Tcp (ip, _) -> Fmt.str "%a" Eio.Net.Ipaddr.pp ip
  | `Unix path -> "unix:" ^ Filename.basename path
;;

(** {1 Global Startup Helper} *)

(** Start the global rate-limit cleanup loop.  Call once at server startup. *)
let start_global_cleanup_loop ~sw ~clock =
  start_cleanup_loop ~sw ~clock (Eio.Lazy.force global)
;;
