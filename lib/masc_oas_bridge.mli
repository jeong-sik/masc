(* lib/masc_oas_bridge.mli *)

(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces strict structural timeouts, cancellation safety, and type isolation. *)

(** Safe execution of a generic OAS operation with a mandatory timeout.
    Requires an initialized {!Masc_eio_env} carrying an Eio clock.

    Catches [Eio.Time.Timeout] and [Eio.Cancel.Cancelled] to perform functional rollback.
    [caller] (#10094) labels the Otel_metric_store timeout counter so the
    operator can attribute timeouts to specific call sites.
    Missing {!Masc_eio_env} returns a typed [Internal_contract_rejected] SDK
    error without running [fn]. Raises [Invalid_argument] only when [timeout_s]
    is not positive or infinite. *)
val run_safe
  :  caller:string
  -> timeout_s:float
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result

(** [run_unbounded ~caller fn] runs [fn] without a structural timeout.

    This is for intentional no-timeout callers only; normal OAS boundaries
    should use {!run_safe} or {!run_with_caller}.  Missing {!Masc_eio_env}
    returns a typed [Internal_contract_rejected] SDK error without running [fn],
    and initialized calls preserve the same cancellation and error conversion
    behaviour as {!run_safe}. *)
val run_unbounded
  :  caller:string
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result

(** Single entry point that resolves the per-caller timeout from
    [Env_config_oas_bridge] and labels the resulting Otel_metric_store
    counter.  Preferred over [run_safe] for new callers — the
    timeout is no longer a hardcoded literal but an
    env-overridable per-caller budget.  See [Env_config_oas_bridge]
    for the per-caller default table, env-var layout, and invalid-env fallback.

    Inherits the timeout validation contract from [run_safe].
    [Env_config_oas_bridge.timeout_sec] clamps non-positive and [nan]
    env overrides to the default and accepts ["infinity"] as no-fire.
    Infinite budgets dispatch through {!run_unbounded}; finite budgets
    dispatch through {!run_safe}. *)
val run_with_caller
  :  caller:Env_config_oas_bridge.caller
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
