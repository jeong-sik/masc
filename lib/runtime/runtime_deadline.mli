(** Runtime per-attempt deadline value carrying a wall-clock time horizon.

    RFC-0192 § 2 invariant carrier:
    [effective_attempt_budget(i) = min(default_amplifier, deadline - now())]

    The value is an explicit caller-provided deadline; this module does not
    derive policy or queueing limits.

    The pure {!remaining_at} / {!composed_attempt_budget_at} variants take
    an explicit [now_s] so the math is unit-testable without an Eio runtime.
    The clock-bearing wrappers ({!of_seconds_from_now} etc.) call
    {!Eio.Time.now} under the hood and are tested via integration. *)

type t

(** {1 Construction} *)

(** [create ~expires_at_s] is the wall-clock absolute time when this
    deadline elapses. Exposed primarily for tests. *)
val create : expires_at_s:float -> t

(** [of_seconds_from_now ~clock secs] is a deadline [secs] in the future
    relative to [clock]. Use this in production code. *)
val of_seconds_from_now :
  clock:float Eio.Time.clock_ty Eio.Resource.t -> float -> t

(** [expires_at d] is the underlying wall-clock seconds since Unix epoch.
    Exposed for telemetry and logging; do not use for arithmetic — prefer
    {!remaining_seconds} / {!composed_attempt_budget} to keep callers
    independent of the time source. *)
val expires_at : t -> float

(** {1 Pure math (unit-testable, no Eio runtime needed)} *)

(** [remaining_at ~now_s d] is [max 0.0 (expires_at d -. now_s)]. Never
    negative; an expired deadline returns [0.0]. *)
val remaining_at : now_s:float -> t -> float

(** [composed_attempt_budget_at ~now_s ~deadline ~amplifier] is the
    RFC-0192 § 2 invariant:
    [min amplifier (remaining_at ~now_s deadline)].

    [amplifier] is the per-attempt default (existing
    [Env_config_keeper.RuntimeTierWait.timeout_s ()]) and acts as the
    upper bound. [deadline] acts as the lower bound. The result is
    never negative. *)
val composed_attempt_budget_at :
  now_s:float -> deadline:t -> amplifier:float -> float

(** [is_expired_at ~now_s d] is [remaining_at ~now_s d = 0.0]. *)
val is_expired_at : now_s:float -> t -> bool

(** {1 Clock-bearing convenience wrappers (for production callers)} *)

val remaining_seconds :
  clock:float Eio.Time.clock_ty Eio.Resource.t -> t -> float

val composed_attempt_budget :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  deadline:t ->
  amplifier:float ->
  float

val is_expired :
  clock:float Eio.Time.clock_ty Eio.Resource.t -> t -> bool
