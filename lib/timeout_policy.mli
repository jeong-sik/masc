(** Timeout policy SSOT for MASC.

    Consolidates the layered wall-clock deadline matrix enumerated in
    https://github.com/jeong-sik/masc/issues/9639, and provides a typed
    [Deadline.t] that can be propagated across subsystems.

    Cooperative-cancel overshoot: OCaml 5 / Eio cancellation is cooperative.
    A fiber that blocks inside an uncancellable region (native HTTP bulk
    read, system call, non-yielding loop) will miss the
    [Eio.Time.with_timeout_exn] deadline and overshoot the configured budget
    by seconds. [overshoot_warn] surfaces the overshoot as a first-class
    log/metric signal so the condition is visible instead of silently
    inflating wall time.

    Related issues: #9639 (meta), #9662 (keeper_llm_bridge ~24s overshoot),
    #9629 (dashboard judge OAS 60s), #9637 (keeper turn 1200s). *)

module Layer : sig
  (** Nested timeout layers, innermost-first.

      Contract: every inner layer's wall cap MUST be less than or equal to
      its enclosing layer's cap. An inner "hard cap" that exceeds the outer
      cap is effectively advisory and a principal source of overshoot. *)
  type t =
    | Tool
    | Oas_bridge
    | Keeper_turn
    | Keeper_cycle
    | Shutdown

  val to_string : t -> string
end

module Deadline : sig
  type t = private {
    layer : Layer.t;
    origin : string;
    wall_cap_s : float;
    set_at : float;
  }

  val make
    :  layer:Layer.t
    -> origin:string
    -> wall_cap_s:float
    -> now:float
    -> t

  val elapsed : t -> now:float -> float

  val remaining : t -> now:float -> float
  (** [remaining t ~now] is [t.wall_cap_s -. elapsed t ~now].
      Negative values mean the deadline has passed by that many seconds. *)
end

val metric_overshoot_total : string
(** Canonical Otel_metric_store counter name (pinned by #9662 contract test):
    [masc_timeout_policy_overshoot_total].  Incremented by
    [overshoot_warn] with [layer] and [origin] labels. *)

val overshoot_warn
  :  ?slack_s:float
  -> deadline:Deadline.t
  -> actual_wall_s:float
  -> unit
  -> bool
(** Emit a warn-level log when [actual_wall_s] exceeds
    [deadline.wall_cap_s] by more than [slack_s].  Also increments
    {!metric_overshoot_total} with [layer] and [origin] labels.
    Returns [true] when an overshoot was detected (caller no
    longer needs to emit a parallel counter). *)
