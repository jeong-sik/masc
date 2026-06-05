(** Runtime telemetry emitters (RFC-0206). Re-homed otel_metric_store counter ticks
    from deleted [Runtime_metrics]; metric-name strings preserved verbatim
    (operator dashboard seam). *)

val on_provider_cooldown : provider:string -> reason:string -> unit
(** Tick the per-provider cooldown-entry counter
    ([masc_runtime_provider_cooldown_total]). *)

val on_runtime_metrics_eviction : unit -> unit
(** Tick the metrics LRU eviction counter
    ([masc_runtime_metrics_eviction_total]). *)

val on_runtime_audit_failure : stage:string -> unit
(** Tick the audit subsystem failure counter
    ([masc_runtime_audit_failure_total]). *)
