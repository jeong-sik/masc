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

(** {1 Agent Quota Tier Contract} *)

type agent_quota_tier = Rate_limit_types.agent_quota_tier =
  | P0
  | P1
  | P2

type agent_quota_control = Rate_limit_types.agent_quota_control =
  | LeaseExpiry
  | Backpressure
  | AdaptiveRate

type agent_quota_tier_contract =
  Rate_limit_types.agent_quota_tier_contract = {
  contract_tier: agent_quota_tier;
  code: string;
  label: string;
  workload_label: string;
  share_percent: int;
  default_req_per_min: int;
}

type agent_quota_allocation = Rate_limit_types.agent_quota_allocation = {
  allocation_tier: agent_quota_tier;
  allocation_percent: int;
  allocation_req_per_min: int;
}

let default_agent_quota_total_per_min = 1000

let agent_quota_tiers = [P0; P1; P2]

let agent_quota_tier_rank = function
  | P0 -> 0
  | P1 -> 1
  | P2 -> 2

let agent_quota_tier_code = function
  | P0 -> "P0"
  | P1 -> "P1"
  | P2 -> "P2"

let agent_quota_tier_label = function
  | P0 -> "P0 Critical"
  | P1 -> "P1 Standard"
  | P2 -> "P2 Background"

let agent_quota_tier_workload_label = function
  | P0 -> "architecture-deploy"
  | P1 -> "feature-test"
  | P2 -> "monitoring-docs"

let agent_quota_tier_share_percent = function
  | P0 -> 40
  | P1 -> 40
  | P2 -> 20

let agent_quota_control_label = function
  | LeaseExpiry -> "lease-expiry"
  | Backpressure -> "backpressure"
  | AdaptiveRate -> "adaptive-rate"

let agent_quota_control_labels =
  List.map agent_quota_control_label [LeaseExpiry; Backpressure; AdaptiveRate]

let agent_quota_tier_contract tier =
  let share_percent = agent_quota_tier_share_percent tier in
  {
    contract_tier = tier;
    code = agent_quota_tier_code tier;
    label = agent_quota_tier_label tier;
    workload_label = agent_quota_tier_workload_label tier;
    share_percent;
    default_req_per_min =
      default_agent_quota_total_per_min * share_percent / 100;
  }

let agent_quota_tier_contracts =
  List.map agent_quota_tier_contract agent_quota_tiers

let agent_quota_tier_of_task_priority priority =
  if priority <= 1 then P0
  else if priority <= 3 then P1
  else P2

let validate_agent_quota_total ~total_req_per_min =
  if total_req_per_min <= 0 then
    Error
      (Printf.sprintf
         "agent quota total_req_per_min must be positive, got %d"
         total_req_per_min)
  else
    Ok ()

let sort_agent_quota_allocations allocations =
  List.sort
    (fun a b ->
      compare
        (agent_quota_tier_rank a.allocation_tier)
        (agent_quota_tier_rank b.allocation_tier))
    allocations

let has_exact_agent_quota_tiers allocations =
  match sort_agent_quota_allocations allocations with
  | [
      { allocation_tier = P0; _ };
      { allocation_tier = P1; _ };
      { allocation_tier = P2; _ };
    ] -> true
  | _ -> false

let validate_agent_quota_allocations ~total_req_per_min allocations =
  match validate_agent_quota_total ~total_req_per_min with
  | Error _ as e -> e
  | Ok () ->
    if not (has_exact_agent_quota_tiers allocations) then
      Error "agent quota allocations must include exactly P0, P1, and P2"
    else
      match
        List.find_opt
          (fun allocation -> allocation.allocation_req_per_min < 0)
          allocations
      with
      | Some allocation ->
        Error
          (Printf.sprintf
             "agent quota allocation for %s must be non-negative, got %d"
             (agent_quota_tier_code allocation.allocation_tier)
             allocation.allocation_req_per_min)
      | None ->
        let allocated =
          List.fold_left
            (fun total allocation -> total + allocation.allocation_req_per_min)
            0 allocations
        in
        if allocated = total_req_per_min then
          Ok ()
        else
          Error
            (Printf.sprintf
               "agent quota allocation sum mismatch: expected %d, got %d"
               total_req_per_min allocated)

let compute_agent_quota_allocations ~total_req_per_min =
  match validate_agent_quota_total ~total_req_per_min with
  | Error _ as e -> e
  | Ok () ->
    let allocations =
      List.map
        (fun tier ->
          let allocation_percent = agent_quota_tier_share_percent tier in
          {
            allocation_tier = tier;
            allocation_percent;
            allocation_req_per_min =
              total_req_per_min * allocation_percent / 100;
          })
        agent_quota_tiers
    in
    let allocated =
      List.fold_left
        (fun total allocation -> total + allocation.allocation_req_per_min)
        0 allocations
    in
    let rec assign_remainder remaining = function
      | [] -> []
      | allocation :: rest when remaining > 0 ->
        {
          allocation with
          allocation_req_per_min = allocation.allocation_req_per_min + 1;
        }
        :: assign_remainder (remaining - 1) rest
      | rest -> rest
    in
    let allocations = assign_remainder (total_req_per_min - allocated) allocations in
    match validate_agent_quota_allocations ~total_req_per_min allocations with
    | Ok () -> Ok allocations
    | Error _ as e -> e

(** {1 Configuration} *)

let default_rate = 60.0  (* 12+ concurrent keepers need higher throughput *)
let default_burst = 150

let default_agent_rate = 20.0
let default_agent_burst = 50

let rate_from_env () = Env_config.Rate_bucket.rate

let burst_from_env () = Env_config.Rate_bucket.burst

let agent_rate_from_env () = Env_config.Rate_bucket.agent_rate

let agent_burst_from_env () = Env_config.Rate_bucket.agent_burst

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

let create_from_env () =
  create ~rate:(rate_from_env ()) ~burst:(burst_from_env ()) ()

let create_agent_from_env () =
  create ~rate:(agent_rate_from_env ()) ~burst:(agent_burst_from_env ()) ()

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

let global = Eio.Lazy.from_fun ~cancel:`Protect create_from_env

let check_global ~key =
  check (Eio.Lazy.force global) ~key

let remaining_global ~key =
  remaining (Eio.Lazy.force global) ~key

(** {1 Per-Agent Global Instance}

    A separate token-bucket limiter keyed by resolved agent name or bearer
    token hash.  Uses lower defaults than the per-IP global limiter so that a
    single agent cannot starve others even if they share the same egress IP. *)

let agent_global =
  Eio.Lazy.from_fun ~cancel:`Protect create_agent_from_env

let check_agent_global ~key =
  check (Eio.Lazy.force agent_global) ~key

let remaining_agent_global ~key =
  remaining (Eio.Lazy.force agent_global) ~key

(** {1 Automatic Cleanup Loop} *)

(** Start a background fiber that periodically cleans up stale rate limit buckets.
    Call this once at server startup with the main switch. *)
let start_cleanup_loop ~sw ~clock ?(interval=Env_config.RateLimit.cleanup_interval_seconds) limiter =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock interval;
      (try
         let older_than_seconds =
           int_of_float Env_config.RateLimit.entry_max_age_seconds
         in
         let removed = cleanup limiter ~older_than_seconds in
         if removed > 0 then
           Log.Misc.info "Cleaned up %d stale buckets" removed
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "rate_limit cleanup iteration failed: %s"
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
  start_cleanup_loop ~sw ~clock (Eio.Lazy.force global);
  start_cleanup_loop ~sw ~clock (Eio.Lazy.force agent_global)
