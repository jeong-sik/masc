(** Rate Limiting for masc-mcp

    Provides token bucket rate limiting per client/agent.

    Configuration via environment:
    - MASC_RATE_LIMIT: requests per second (default: 20)
    - MASC_RATE_BURST: burst capacity (default: 50)

    @since 0.4.0
*)

module StringMap = Map.Make (String)

(** {1 Token Bucket Algorithm} *)

type bucket = {
  mutable tokens: float;
  mutable last_update: float;
}

type t = {
  rate: float;
  burst: int;
  buckets: bucket StringMap.t ref;
  mutex: Eio.Mutex.t;
}

(** {1 Configuration} *)

let default_rate = 60.0  (* 12+ concurrent keepers need higher throughput *)
let default_burst = 150

let default_agent_rate = 20.0
let default_agent_burst = 50

let rate_of_config () = Env_config.Rate_bucket.rate

let burst_of_config () = Env_config.Rate_bucket.burst

let agent_rate_of_config () = Env_config.Rate_bucket.agent_rate

let agent_burst_of_config () = Env_config.Rate_bucket.agent_burst

(** {1 Limiter Creation} *)

let create ?(rate=default_rate) ?(burst=default_burst) () =
  {
    rate;
    burst;
    buckets = ref StringMap.empty;
    mutex = Eio.Mutex.create ();
  }

let rate t = t.rate
let burst t = t.burst

let create_of_config () =
  create ~rate:(rate_of_config ()) ~burst:(burst_of_config ()) ()

let create_agent_of_config () =
  create ~rate:(agent_rate_of_config ()) ~burst:(agent_burst_of_config ()) ()

(** {1 Rate Checking} *)

let with_lock limiter f =
  Eio.Mutex.use_rw ~protect:true limiter.mutex (fun () -> f ())

let check limiter ~key =
  with_lock limiter (fun () ->
    let now = Time_compat.now () in
    let bucket = match StringMap.find_opt key !(limiter.buckets) with
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

    if bucket.tokens >= 1.0 then begin
      bucket.tokens <- bucket.tokens -. 1.0;
      true
    end else
      false
  )

let remaining limiter ~key =
  with_lock limiter (fun () ->
    match StringMap.find_opt key !(limiter.buckets) with
    | Some b -> int_of_float b.tokens
    | None -> limiter.burst
  )

(** {1 Cleanup} *)

let cleanup limiter ~older_than_seconds =
  with_lock limiter (fun () ->
    let now = Time_compat.now () in
    let threshold = now -. float_of_int older_than_seconds in
    let to_remove = StringMap.fold (fun key bucket acc ->
      if bucket.last_update <= threshold then key :: acc
      else acc
    ) !(limiter.buckets) [] in
    limiter.buckets := List.fold_left (fun m k -> StringMap.remove k m) !(limiter.buckets) to_remove;
    List.length to_remove
  )

(** {1 Global Instance}

    Uses [Eio.Lazy] for fiber-safe initialization.
    [cancel:`Protect] ensures init completes even if forcing fiber is cancelled. *)

let global = Eio.Lazy.from_fun ~cancel:`Protect create_of_config

let check_global ~key =
  check (Eio.Lazy.force global) ~key

let remaining_global ~key =
  remaining (Eio.Lazy.force global) ~key

(** {1 Per-Agent Global Instance}

    A separate token-bucket limiter keyed by resolved agent name or bearer
    token hash.  Uses lower defaults than the per-IP global limiter so that a
    single agent cannot starve others even if they share the same egress IP. *)

let agent_global =
  Eio.Lazy.from_fun ~cancel:`Protect create_agent_of_config

let check_agent_global ~key =
  check (Eio.Lazy.force agent_global) ~key

let remaining_agent_global ~key =
  remaining (Eio.Lazy.force agent_global) ~key

(** {1 Automatic Cleanup Loop} *)

(** Start a background fiber that periodically cleans up stale rate limit buckets.
    Call this once at server startup with the main switch. *)
let start_cleanup_loop ~sw ~clock ?(label = "rate-limit")
    ?(interval=Env_config.RateLimit.cleanup_interval_seconds) limiter =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock interval;
      (try
         let older_than_seconds =
           int_of_float Env_config.RateLimit.entry_max_age_seconds
         in
         let removed = cleanup limiter ~older_than_seconds in
         if removed > 0 then
           Log.Misc.info "Cleaned up %d stale %s buckets" removed label
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "rate_limit cleanup iteration failed for %s limiter: %s"
           label
           (Printexc.to_string exn));
      loop ()
    in
    loop ()
  )

(** {1 HTTP Helpers} *)

let headers limiter ~key =
  let remaining = remaining limiter ~key in
  [
    ("X-RateLimit-Limit", string_of_int limiter.burst);
    ("X-RateLimit-Remaining", string_of_int remaining);
  ]

let too_many_requests_body () =
  {|{"error":"Too Many Requests","message":"Rate limit exceeded"}|}

let too_many_agent_requests_body () =
  {|{"error":"Too Many Requests","message":"Per-agent rate limit exceeded"}|}

(** Headers to include in a 429 Too Many Requests response.
    Includes [Retry-After] (seconds until the bucket refills by one token)
    in addition to the standard rate-limit informational headers. *)
let too_many_requests_headers limiter ~key =
  let base = headers limiter ~key in
  (* Estimate refill time: one token arrives after 1/rate seconds. *)
  let retry_after_s = if limiter.rate > 0.0 then
    max 1 (int_of_float (Float.ceil (1.0 /. limiter.rate)))
  else
    1
  in
  ("Retry-After", string_of_int retry_after_s) :: base

let headers_global ~key =
  headers (Eio.Lazy.force global) ~key

let headers_agent_global ~key =
  headers (Eio.Lazy.force agent_global) ~key

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

(** {1 Agent Key Extraction} *)

(** Derive a stable per-agent rate-limit key from either a bearer token
    (preferred — uses the first 32 hex chars of its SHA-256 to avoid storing
    the raw credential) or an agent-name string.  Returns [None] when neither
    is provided (anonymous / loopback request). *)
let agent_key_of_token_or_name ?token ?agent_name () =
  match token with
  | Some t when t <> "" ->
      (* Use the first 32 hex chars (16 bytes, 128 bits) of the token's SHA-256
         digest as the rate-limit key.  This is sufficient for identifying
         distinct clients in a rate-limit bucket table while avoiding storage of
         raw credentials.  The reduced entropy (vs. 256 bits) is intentional and
         acceptable for a best-effort rate-limit use case: in the negligible
         collision scenario two distinct tokens would share a bucket, which is
         safe (one may consume the other's quota) but not a security hazard.
         SHA-256 hex is always 64 chars, so String.sub 0 32 is safe. *)
      let digest = Digestif.SHA256.(to_hex (digest_string t)) in
      Some ("token:" ^ String.sub digest 0 32)
  | _ ->
      (match agent_name with
       | Some name when name <> "" -> Some ("agent:" ^ name)
       | _ -> None)

(** {1 Global Startup Helper} *)

(** Start the global rate-limit cleanup loops.  Call once at server startup.
    Starts loops for both the per-IP global limiter and the per-agent limiter. *)
let start_global_cleanup_loop ~sw ~clock =
  start_cleanup_loop ~sw ~clock ~label:"ip" (Eio.Lazy.force global);
  start_cleanup_loop ~sw ~clock ~label:"agent" (Eio.Lazy.force agent_global)
