(** RFC-0313 W1/W3 — process-wide pacing state store.

    W1 introduced this module as an observe-only shadow; since the W3 flip
    it is the live pacing state: the heartbeat scheduler reads
    [next_due_remaining] when [pacing.mode = enforce] and delays the
    keeper's next turn until the earliest per-runtime revisit is eligible.
    The module name keeps its W1 form until the kill-switch is removed in
    W4 (renaming while both modes exist would mislabel the shadow mode).

    Policy comes from config/runtime.toml [pacing] via {!Runtime.pacing}
    ({!Runtime_schema.pacing_default} when absent).

    Telemetry per observation:
    - counter [Keeper_metrics.PacingShadowEvents]
      labels keeper / runtime / kind (failure | success)
    - gauge [Keeper_metrics.PacingShadowNextDueSec]
      labels keeper — seconds until the keeper's next turn is due under
      pacing (0 when some runtime is eligible now), computed over the
      live runtime catalog. *)

val policy_of_runtime : unit -> Keeper_pacing.policy
(** Pacing policy from runtime.toml [pacing] (defaults when absent). *)

val pacing_enforced : unit -> bool
(** [true] when runtime.toml [pacing].mode = "enforce" (the default):
    failure-driven pause paths are skipped and the scheduler consumes
    pacing. [false] restores the pre-W3 legacy behavior (kill-switch for
    one release; removed in W4). *)

val observe_failure
  :  keeper_name:string
  -> runtime_id:string
  -> retry_after:float option
  -> unit

val observe_success : keeper_name:string -> runtime_id:string -> unit

val snapshot : keeper_name:string -> (string * Keeper_pacing.revisit) list
(** Current pacing schedule for one keeper, sorted by runtime id.
    Empty when nothing has been observed. State is keyed by keeper
    name, so tests isolate by using distinct names — no reset surface
    is exposed. *)

val next_due_remaining : keeper_name:string -> float option
(** Seconds until the keeper's earliest runtime revisit becomes eligible,
    over the live runtime catalog. [None] when the keeper may run now:
    no failures observed, some runtime already eligible, or the runtime
    catalog is empty (pacing cannot gate what it cannot enumerate). *)
