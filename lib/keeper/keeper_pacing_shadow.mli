(** RFC-0313 W1 — observe-only pacing shadow.

    Computes what [Keeper_pacing] WOULD schedule for each keeper and
    emits telemetry; changes no behavior. Consumers flip to reading
    this state in RFC-0313 W3, after the storm-replay harness pins the
    schedule against test/fixtures/pacing_storm_20260706/.

    Telemetry per observation:
    - counter [Keeper_metrics.PacingShadowEvents]
      labels keeper / runtime / kind (failure | success)
    - gauge [Keeper_metrics.PacingShadowNextDueSec]
      labels keeper — seconds until the keeper's next turn would be due
      under pacing (0 when some runtime is eligible now), computed over
      the live runtime catalog.

    [retry_after] is the provider hint when the caller has one in hand;
    W1 call sites pass [None] (the hint is threaded through routing in
    RFC-0313 W2). *)

val observe_failure
  :  keeper_name:string
  -> runtime_id:string
  -> retry_after:float option
  -> unit

val observe_success : keeper_name:string -> runtime_id:string -> unit

val snapshot : keeper_name:string -> (string * Keeper_pacing.revisit) list
(** Current shadow schedule for one keeper, sorted by runtime id.
    Empty when nothing has been observed. State is keyed by keeper
    name, so tests isolate by using distinct names — no reset surface
    is exposed. *)
