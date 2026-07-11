(** Masc_http_client — typed pool front-end for outbound HTTP.

    All callers go through a per-domain [Pool.t] via
    [post_sync] / [get_sync] / [get_response_sync]; each OCaml Domain
    (OS thread) gets its own pool instance stored in [Domain.DLS],
    keyed lazily on first HTTP call.

    Why per-domain: [Eio.Switch] is domain-local.  A global singleton
    pool created on the main domain would cause
    [Invalid_argument "Switch accessed from wrong domain!"] when
    Domain_pool worker fibers try to make HTTP requests through it.
    Per-domain pools eliminate this class of error entirely because
    each pool's Piaf connections share the creating domain's switch.

    Why [Domain.DLS]: zero-cost fast path ([Domain.DLS.get] is a
    domain-local array lookup — no mutex, no blocking).  Pool creation
    happens at most once per domain lifetime.  This avoids the
    [Stdlib.Mutex] blocking problem where locking a mutex blocks
    the entire domain's fiber scheduler.

    Prior art: the original design used a global singleton pool whose
    Eio.Switch belonged to the main domain.  Fibers running on
    Domain_pool worker domains would access this switch →
    [Invalid_argument "Switch accessed from wrong domain!"] →
    [Eio.Mutex.Poisoned] on the pool mutex → permanent 500 on every
    outbound HTTP call until restart.  See PR #20476 for the full
    incident analysis. *)

(** POST with structured error handling.
    DNS resolution, TLS, and I/O errors return Error instead of crashing the fiber. *)
type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let default_request_timeout_sec = 10.0

(** Apply an optional Eio wall-clock timeout around a request. When both
    [clock] and [timeout_sec] are supplied, a sleep fiber races the request
    fiber; whichever finishes first wins and the loser is cancelled. On
    timeout the caller receives [Error "timeout after ..."] instead of the
    underlying HTTP result. When either argument is omitted the behaviour
    is identical to the pre-timeout implementation, so existing callers
    need not be updated.

    We use [Eio.Fiber.first] instead of [Eio.Time.with_timeout] because the
    latter requires the inner function's Error constructor to be a
    polymorphic variant compatible with [> `Timeout], while our callers use
    plain [string] error payloads. *)
let with_optional_timeout ?clock ?timeout_sec f =
  match clock, timeout_sec with
  | Some clock, Some timeout_sec when timeout_sec > 0.0 ->
      Eio.Fiber.first
        (fun () -> f ())
        (fun () ->
          Eio.Time.sleep clock timeout_sec;
          Error (Printf.sprintf "timeout after %.1fs" timeout_sec))
  | _ -> f ()

(* ── Per-domain pool via Domain.DLS ───────────────────────────────── *)

(* [Domain.DLS] provides a mutex-free, per-domain key-value store.
   [Domain.DLS.get] is O(1) — a domain-local array index lookup with
   no synchronization overhead.  This makes the fast path (pool
   already exists) essentially free.

   Pool lifecycle: each pool registers [Eio.Switch.on_release] during
   [Pool.create], so cleanup happens automatically when the domain's
   switch is released.  No explicit teardown needed. *)

let pool_key : Pool.t option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let pool_init_error () =
  Error
    "masc_http_client: Eio_context.set_env not called — \
     RFC-0107 Phase D pool cannot be initialized.  This indicates a \
     bootstrap-order bug (Pool.request from before \
     Server_runtime_bootstrap.create_server_state)."

(* Registry of all created pools, for metrics aggregation.
   Stdlib.Mutex protected because writes (pool creation) and reads
   (metrics snapshots) happen on different domains.  This mutex is
   NOT on the request hot path — it's touched only during pool
   creation (once per domain) and periodic metrics export. *)
let all_pools : (int * Pool.t) list ref = ref []
let all_pools_mu = Stdlib.Mutex.create ()

let register_pool did p =
  Stdlib.Mutex.lock all_pools_mu;
  (try all_pools := (did, p) :: !all_pools with
   | exn -> Stdlib.Mutex.unlock all_pools_mu; raise exn);
  Stdlib.Mutex.unlock all_pools_mu

let with_pool f =
  match Domain.DLS.get pool_key with
  | Some p -> f p
  | None ->
    (match Eio_context.get_switch_opt (), Eio_context.get_env_opt () with
     | Some sw, Some env ->
       let p = Pool.create ~sw ~env () in
       Domain.DLS.set pool_key (Some p);
       register_pool (Domain.self () :> int) p;
       f p
     | _ -> pool_init_error ())

(* ── Public API ───────────────────────────────────────────────────── *)

let post_sync ?clock ?timeout_sec ~url ~headers ~body () =
  with_optional_timeout ?clock ?timeout_sec @@ fun () ->
  with_pool @@ fun pool ->
  match Pool.request pool ?clock ?timeout_seconds:timeout_sec
          ~method_:`POST ~url ~headers ~body () with
  | Ok { Pool.status; body; _ } -> Ok (status, body)
  | Error e -> Error e

(** PATCH with structured error handling. *)
let patch_sync ?clock ?timeout_sec ~url ~headers ~body () =
  with_optional_timeout ?clock ?timeout_sec @@ fun () ->
  with_pool @@ fun pool ->
  match Pool.request pool ?clock ?timeout_seconds:timeout_sec
          ~method_:`PATCH ~url ~headers ~body () with
  | Ok { Pool.status; body; _ } -> Ok (status, body)
  | Error e -> Error e

(** GET with structured error handling. *)
let get_response_sync ?clock ?timeout_sec ~url ~headers () =
  with_optional_timeout ?clock ?timeout_sec @@ fun () ->
  with_pool @@ fun pool ->
  match Pool.request pool ?clock ?timeout_seconds:timeout_sec
          ~method_:`GET ~url ~headers () with
  | Ok { Pool.status; headers; body } ->
    Ok { status; headers; body }
  | Error e -> Error e

(** GET with structured error handling. *)
let get_sync ?clock ?timeout_sec ~url ~headers () =
  match get_response_sync ?clock ?timeout_sec ~url ~headers () with
  | Ok response -> Ok (response.status, response.body)
  | Error _ as error -> error

module For_testing = struct
  let with_request_timeout ~clock ~timeout_sec f =
    with_optional_timeout ~clock ~timeout_sec f
end

(* ── Observability ────────────────────────────────────────────────── *)

(** Return the pool for the current domain, if initialized.
    Backward-compatible accessor for telemetry consumers. *)
let pool_singleton_opt () : Pool.t option = Domain.DLS.get pool_key

(** Return all domain pools created so far.
    Used by [Pool_metrics] to aggregate counters across domains.
    Thread-safe via [Stdlib.Mutex]; only touched during pool creation
    and periodic metrics export, never on the request hot path. *)
let all_domain_pools () : (int * Pool.t) list =
  Stdlib.Mutex.lock all_pools_mu;
  let pools = !all_pools in
  Stdlib.Mutex.unlock all_pools_mu;
  pools

module Pool = Pool
