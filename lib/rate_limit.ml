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
  { tokens : float
  ; last_update : float
  }

type msg =
  | Check of string * float * bool Eio.Promise.u
  | Remaining of string * int Eio.Promise.u
  | Cleanup of float * int Eio.Promise.u

type t =
  { rate : float
  ; burst : int
  ; mailbox : msg Eio.Stream.t
  }

(** {1 Configuration} *)

let default_rate = 60.0 (* 12+ concurrent keepers need higher throughput *)
let default_burst = 150
let rate_from_env () = Env_config.Rate_bucket.rate
let burst_from_env () = Env_config.Rate_bucket.burst

(** {1 Limiter Creation} *)

let process_msg state limiter msg =
  match msg with
  | Check (key, now, p) ->
    let bucket =
      match StringMap.find_opt key state with
      | Some b -> b
      | None -> { tokens = float_of_int limiter.burst; last_update = now }
    in
    let elapsed = now -. bucket.last_update in
    let new_tokens = bucket.tokens +. (elapsed *. limiter.rate) in
    let capped_tokens = min (float_of_int limiter.burst) new_tokens in
    if capped_tokens >= 1.0
    then (
      let bucket' = { tokens = capped_tokens -. 1.0; last_update = now } in
      Eio.Promise.resolve p true;
      StringMap.add key bucket' state)
    else (
      let bucket' = { tokens = capped_tokens; last_update = now } in
      Eio.Promise.resolve p false;
      StringMap.add key bucket' state)
  | Remaining (key, p) ->
    (match StringMap.find_opt key state with
     | Some b -> Eio.Promise.resolve p (int_of_float b.tokens)
     | None -> Eio.Promise.resolve p limiter.burst);
    state
  | Cleanup (threshold, p) ->
    let to_remove =
      StringMap.fold
        (fun key bucket acc ->
           if bucket.last_update <= threshold then key :: acc else acc)
        state
        []
    in
    let state' = List.fold_left (fun m k -> StringMap.remove k m) state to_remove in
    Eio.Promise.resolve p (List.length to_remove);
    state'
;;

let start_actor_if_needed ~sw limiter =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop state =
      let msg = Eio.Stream.take limiter.mailbox in
      loop (process_msg state limiter msg)
    in
    loop StringMap.empty)
;;

let create ?(rate = default_rate) ?(burst = default_burst) () =
  { rate; burst; mailbox = Eio.Stream.create max_int }
;;

let rate t = t.rate
let burst t = t.burst
let create_from_env () = create ~rate:(rate_from_env ()) ~burst:(burst_from_env ()) ()

(** {1 Rate Checking} *)

let check limiter ~key =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add limiter.mailbox (Check (key, Time_compat.now (), r));
  Eio.Promise.await p
;;

let remaining limiter ~key =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add limiter.mailbox (Remaining (key, r));
  Eio.Promise.await p
;;

(** {1 Cleanup} *)

let cleanup limiter ~older_than_seconds =
  let now = Time_compat.now () in
  let threshold = now -. float_of_int older_than_seconds in
  let p, r = Eio.Promise.create () in
  Eio.Stream.add limiter.mailbox (Cleanup (threshold, r));
  Eio.Promise.await p
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
  start_actor_if_needed ~sw limiter;
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
