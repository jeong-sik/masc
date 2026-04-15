(** Circuit Breaker for MASC agents

    Simple failure-based protection:
    - 3 failures in 1 minute → 5 minute cooldown
    - Prevents cascading failures in multi-agent systems

    Research basis:
    - Trust-Vulnerability Paradox (TVP) - arxiv:2510.18563v1
    - "3+ failures/min" threshold from operational experience

    Implementation: all breaker records are immutable and stored in a
    persistent [StringMap].  The single mutable field [breakers] in [t]
    is protected by [Eio.Mutex].

    @since 0.6.0 - MASC Social v4 Tier 1
*)

module StringMap = Map.Make (String)

(** {1 Types} *)

type state =
  | Closed        (** Normal operation *)
  | Open of {
      until: float;     (** Unix timestamp when to retry *)
      reason: string;   (** Why the breaker opened *)
      failure_count: int; (** Number of failures that triggered open *)
    }
  | HalfOpen      (** Testing if service recovered *)

type failure_record = {
  timestamp: float;
  reason: string;
}

type breaker = {
  agent_id: string;
  state: state;
  failures: failure_record list;
  last_check: float;
}

type t = {
  mutable breakers: breaker StringMap.t;
  mutex: Eio.Mutex.t;
  failure_threshold: int;     (** Failures before opening (default: 3) *)
  failure_window_sec: float;  (** Window to count failures (default: 60s) *)
  cooldown_sec: float;        (** How long to stay open (default: 300s) *)
}

(** {1 Configuration} *)

let default_failure_threshold = 3
let default_failure_window = 60.0    (* 1 minute *)
let default_cooldown = 300.0         (* 5 minutes *)

(** {1 Creation} *)

let create
    ?(failure_threshold = default_failure_threshold)
    ?(failure_window = default_failure_window)
    ?(cooldown = default_cooldown)
    () =
  {
    breakers = StringMap.empty;
    mutex = Eio.Mutex.create ();
    failure_threshold;
    failure_window_sec = failure_window;
    cooldown_sec = cooldown;
  }

let create_from_env () = create ()

(** {1 Internal Helpers} *)

let with_lock t f =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> f ())

(** Write a breaker back to the map. *)
let put_breaker t breaker =
  t.breakers <- StringMap.add breaker.agent_id breaker t.breakers

let get_or_create_breaker t ~agent_id =
  match StringMap.find_opt agent_id t.breakers with
  | Some b -> b
  | None ->
      let b = {
        agent_id;
        state = Closed;
        failures = [];
        last_check = Time_compat.now ();
      } in
      t.breakers <- StringMap.add agent_id b t.breakers;
      b

(** Return a new breaker with expired failures removed. *)
let prune_old_failures t breaker =
  let threshold = Time_compat.now () -. t.failure_window_sec in
  { breaker with failures = List.filter (fun f -> f.timestamp > threshold) breaker.failures }

(** {1 Core Operations} *)

(** Record a failure for an agent *)
let record_failure t ~agent_id ~reason =
  with_lock t (fun () ->
    let breaker = get_or_create_breaker t ~agent_id in
    let now = Time_compat.now () in
    let breaker = { breaker with
      failures = { timestamp = now; reason } :: breaker.failures } in
    let breaker = prune_old_failures t breaker in
    let failure_count = List.length breaker.failures in
    let breaker =
      if failure_count >= t.failure_threshold then begin
        Log.Session.warn "[CircuitBreaker] OPENED for %s: %d failures" agent_id failure_count;
        { breaker with state = Open {
          until = now +. t.cooldown_sec;
          reason = Printf.sprintf "%d failures in %.0fs: %s"
                     failure_count t.failure_window_sec reason;
          failure_count;
        } }
      end else breaker
    in
    put_breaker t breaker
  )

(** Record a success - helps transition from HalfOpen to Closed *)
let record_success t ~agent_id =
  with_lock t (fun () ->
    let breaker = get_or_create_breaker t ~agent_id in
    match breaker.state with
    | HalfOpen ->
        Log.Session.info "[CircuitBreaker] CLOSED for %s after recovery" agent_id;
        put_breaker t { breaker with state = Closed; failures = [] }
    | Closed ->
        put_breaker t (prune_old_failures t breaker)
    | Open _ ->
        ()
  )

(** Check if an agent is allowed to proceed *)
let check t ~agent_id : (unit, string) result =
  with_lock t (fun () ->
    let breaker = get_or_create_breaker t ~agent_id in
    let now = Time_compat.now () in
    let breaker = { breaker with last_check = now } in

    match breaker.state with
    | Closed ->
        put_breaker t breaker;
        Ok ()

    | Open { until; reason = _; _ } when now >= until ->
        Log.Session.info "[CircuitBreaker] HALF-OPEN for %s, testing..." agent_id;
        put_breaker t { breaker with state = HalfOpen };
        Ok ()

    | Open { until; reason; failure_count } ->
        put_breaker t breaker;
        let remaining = int_of_float (until -. now) in
        Error (Printf.sprintf
          "Circuit breaker OPEN for %s (%d failures). Retry in %ds. Reason: %s"
          agent_id failure_count remaining reason)

    | HalfOpen ->
        put_breaker t breaker;
        Ok ()
  )

(** Force-open a breaker (for manual suspension) *)
let force_open t ~agent_id ~reason ~duration_sec =
  with_lock t (fun () ->
    let breaker = get_or_create_breaker t ~agent_id in
    let now = Time_compat.now () in
    put_breaker t { breaker with state = Open {
      until = now +. duration_sec;
      reason = "MANUAL: " ^ reason;
      failure_count = 0;
    } };
    Log.Session.warn "[CircuitBreaker] FORCE-OPENED for %s: %s (%.0fs)"
      agent_id reason duration_sec
  )

(** Force-close a breaker (for manual recovery) *)
let force_close t ~agent_id =
  with_lock t (fun () ->
    let breaker = get_or_create_breaker t ~agent_id in
    put_breaker t { breaker with state = Closed; failures = [] };
    Log.Session.info "[CircuitBreaker] FORCE-CLOSED for %s" agent_id
  )

(** {1 Status & Statistics} *)

type breaker_status = {
  agent_id: string;
  state_name: string;
  recent_failures: int;
  open_until: float option;
  open_reason: string option;
}

let get_status t ~agent_id =
  with_lock t (fun () ->
    match StringMap.find_opt agent_id t.breakers with
    | None -> {
        agent_id;
        state_name = "closed";
        recent_failures = 0;
        open_until = None;
        open_reason = None;
      }
    | Some breaker ->
        let breaker = prune_old_failures t breaker in
        put_breaker t breaker;
        let state_name, open_until, open_reason = match breaker.state with
          | Closed -> ("closed", None, None)
          | HalfOpen -> ("half_open", None, None)
          | Open { until; reason; _ } -> ("open", Some until, Some reason)
        in
        {
          agent_id;
          state_name;
          recent_failures = List.length breaker.failures;
          open_until;
          open_reason;
        }
  )

let status_to_json (s : breaker_status) : Yojson.Safe.t =
  `Assoc [
    ("agent_id", `String s.agent_id);
    ("state", `String s.state_name);
    ("recent_failures", `Int s.recent_failures);
    ("open_until", Json_util.float_opt_to_json s.open_until);
    ("open_reason", Json_util.string_opt_to_json s.open_reason);
  ]

let list_all_breakers t =
  with_lock t (fun () ->
    StringMap.fold (fun agent_id breaker acc ->
      let breaker = prune_old_failures t breaker in
      put_breaker t breaker;
      let state_name, open_until, open_reason = match breaker.state with
        | Closed -> ("closed", None, None)
        | HalfOpen -> ("half_open", None, None)
        | Open { until; reason; _ } -> ("open", Some until, Some reason)
      in
      let status = {
        agent_id;
        state_name;
        recent_failures = List.length breaker.failures;
        open_until;
        open_reason;
      } in
      status :: acc
    ) t.breakers []
  )

(** {1 Cleanup} *)

let cleanup t ~older_than_seconds =
  with_lock t (fun () ->
    let now = Time_compat.now () in
    let threshold = now -. float_of_int older_than_seconds in
    let removed, kept =
      StringMap.fold (fun agent_id breaker (n, m) ->
        match breaker.state with
        | Closed when breaker.last_check < threshold -> (n + 1, m)
        | _ -> (n, StringMap.add agent_id breaker m)
      ) t.breakers (0, StringMap.empty)
    in
    t.breakers <- kept;
    removed
  )

(** {1 Wrap — Combined check + execute + record} *)

(** Execute [f] with circuit breaker protection.
    Returns [Error msg] if breaker is open.
    Records success/failure automatically. *)
let wrap t ~agent_id (f : unit -> ('a, string) result) : ('a, string) result =
  match check t ~agent_id with
  | Error msg -> Error msg
  | Ok () ->
      match f () with
      | Ok _ as ok ->
          record_success t ~agent_id;
          ok
      | Error msg as err ->
          record_failure t ~agent_id ~reason:msg;
          err

(** Exception-catching variant of [wrap].
    Re-raises [Eio.Cancel.Cancelled] to preserve cooperative cancellation. *)
let wrap_exn t ~agent_id (f : unit -> 'a) : ('a, string) result =
  match check t ~agent_id with
  | Error msg -> Error msg
  | Ok () ->
      (try
         let result = f () in
         record_success t ~agent_id;
         Ok result
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         let msg = Printexc.to_string exn in
         record_failure t ~agent_id ~reason:msg;
         Error msg)

(** {1 Global Instance}

    Uses [Eio.Lazy] instead of [Stdlib.Lazy] because [Lazy.force] is not
    fiber-safe: concurrent forcing raises [CamlinternalLazy.Undefined].
    [Eio.Lazy] blocks the second caller until init completes.
    [cancel:`Protect] ensures init finishes even if the forcing fiber
    is cancelled. *)

let global = Eio.Lazy.from_fun ~cancel:`Protect create_from_env

let check_global ~agent_id = check (Eio.Lazy.force global) ~agent_id
let record_failure_global ~agent_id ~reason = record_failure (Eio.Lazy.force global) ~agent_id ~reason
let record_success_global ~agent_id = record_success (Eio.Lazy.force global) ~agent_id
let force_open_global ~agent_id ~reason ~duration_sec =
  force_open (Eio.Lazy.force global) ~agent_id ~reason ~duration_sec
let force_close_global ~agent_id = force_close (Eio.Lazy.force global) ~agent_id
let get_status_global ~agent_id = get_status (Eio.Lazy.force global) ~agent_id
