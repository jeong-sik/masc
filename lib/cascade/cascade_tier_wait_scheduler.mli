(** Cascade_tier_wait_scheduler — bounded wait layer over tier admission.

    RFC-0153 Phase C.1. Wraps {!Cascade_tier_admission} with per-tier
    FIFO queues, fiber-per-waiter backoff, and a configurable timeout.

    Design principles (from approved design report 2026-05-24):
    - Non-blocking core preserved; wait layer is opt-in.
    - Caller retains control — no hidden blocking queues.
    - Fiber-per-waiter with independent backoff/timeout.
    - Timeout state is per-fiber and traceable, not opaque.

    External validation:
    - Kubernetes workqueue [AddRateLimited] / [AddAfter] pattern:
      per-item backoff with configurable base + cap.
    - Rust [tower::limit::ConcurrencyLimitLayer] composition:
      this module composes *on top of* admission without modifying it.

    @since RFC-0153 Phase C.1 *)

(** {1 Configuration} *)

type backoff_strategy =
  | Constant of float
      (** Always wait [s] seconds between retries. *)
  | Linear of { initial_s : float; max_s : float }
      (** [initial_s], [initial_s + delta], ... up to [max_s]. *)
  | Exponential of { initial_s : float; factor : float; max_s : float }
      (** [initial_s], [initial_s * factor], [initial_s * factor^2], ...
          up to [max_s]. *)

type wait_config = {
  backoff : backoff_strategy;
      (** Default: [Exponential { initial_s = 0.5; factor = 2.0; max_s = 8.0 }]. *)
  timeout_s : float;
      (** Wall-clock timeout per [try_admission_or_wait] call.
          Default: [30.0]. *)
  max_retries : int option;
      (** [None] = unlimited retries within [timeout_s].
          [Some n] = give up after [n] capacity_full rejections. *)
}

val default_wait_config : wait_config
(** Exponential 0.5s / 2x / 8s, 30s timeout, unlimited retries. *)

(** {1 Result types} *)

type rejection_detail =
  | Timeout_expired of {
      tier_id : string;
      total_waited_s : float;
      attempts : int;
    }
  | Max_retries_exceeded of {
      tier_id : string;
      retries : int;
      total_waited_s : float;
    }
  | Cancelled of { tier_id : string }
      (** The Eio switch was cancelled while waiting. *)

val pp_rejection_detail : Format.formatter -> rejection_detail -> unit

(** {1 Scheduler} *)

type t
(** Per-process scheduler state. Wraps a {!Cascade_tier_admission.t}
    with per-tier wait queues. Thread-safe under Eio. *)

val create :
  ?default_wait_config:wait_config ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Cascade_tier_admission.t ->
  t
(** [create ~default_wait_config ?clock admission] wraps an existing
    admission controller with the wait scheduler layer.

    [clock] enables {!Eio.Time.sleep}-based backoff. When omitted,
    backoff falls back to yield-based polling (less efficient, for
    environments without clock access). *)

(** {1 Main API} *)

val try_admission_or_wait :
  t ->
  tier_id:string ->
  ?wait_config:wait_config ->
  sw:Eio.Switch.t ->
  (unit -> 'a) ->
  ('a, rejection_detail) result
(** [try_admission_or_wait t ~tier_id ?wait_config ~sw f] attempts
    admission on the underlying tier.

    If capacity is available, [f ()] runs immediately (zero wait).
    If full, the calling fiber enters a bounded wait loop with backoff
    until either:
    - Admission becomes available → [Ok (f ())], or
    - [timeout_s] elapses → [Error (Timeout_expired _)], or
    - [max_retries] exceeded → [Error (Max_retries_exceeded _)], or
    - [sw] is cancelled → [Error (Cancelled _)].

    On admission, release happens automatically when [f] returns
    (whether normally or by exception) via the underlying
    {!Cascade_tier_admission.release}. Callers do NOT call release
    manually. *)

(** {1 Notification (for external release paths)} *)

val on_admission_release : t -> tier_id:string -> unit
(** Signal that a slot was released in [tier_id]. Wakes the oldest
    waiting fiber (FIFO) if any.

    Callers using {!try_admission_or_wait} do NOT need this — release
    is handled internally. Exposed for external release paths. *)

(** {1 Observability} *)

type tier_wait_stats = {
  tier_id : string;
  waiting_fibers : int;
  total_admitted : int;
  total_rejected : int;
  total_timeouts : int;
  avg_wait_s : float;
}

val stats : t -> tier_id:string -> tier_wait_stats option
(** Snapshot of wait statistics for a tier. [None] if the tier has
    never been waited on. Safe to call from any fiber. *)

val all_stats : t -> tier_wait_stats list
(** Stats for all tiers that have seen wait activity. *)
