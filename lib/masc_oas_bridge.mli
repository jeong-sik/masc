(* lib/masc_oas_bridge.mli *)

(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces strict structural timeouts, cancellation safety, and type isolation. *)

(** Safe execution of a generic OAS operation with a mandatory timeout.
    Requires an initialized {!Masc_eio_env} carrying an Eio clock; if the clock is
    unavailable, returns [Agent_sdk.Error.Internal _] without calling the function.
    Catches [Eio.Time.Timeout] and [Eio.Cancel.Cancelled] to perform functional rollback.
    [caller] (#10094) labels the Otel_metric_store timeout counter so the
    operator can attribute timeouts to specific call sites.
    Raises [Invalid_argument] when [timeout_s] is not positive or is [nan].
    [Float.infinity] is accepted for advisory callers whose wrapper timeout is
    intentionally disabled by [Env_config_oas_bridge]. *)
val run_safe
  :  caller:string
  -> timeout_s:float
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result

(** Single entry point that resolves the per-caller timeout from
    [Env_config_oas_bridge] and labels the resulting Otel_metric_store
    counter.  Preferred over [run_safe] for new callers — the
    timeout is no longer a hardcoded literal but an
    env-overridable per-caller budget.  See [Env_config_oas_bridge]
    for the per-caller default table, env-var layout, and invalid-env fallback.

    Inherits the [Invalid_argument] contract from [run_safe]: if
    [Env_config_oas_bridge.timeout_sec] returns a non-positive or [nan] value
    (e.g. an env override of ["0"], ["-1"], or ["nan"]), the resulting [run_safe]
    call raises [Invalid_argument].
    The env parser already clamps in the documented range, so this only
    surfaces when an operator pins a misconfiguration that bypasses the
    parser. *)
val run_with_caller
  :  caller:Env_config_oas_bridge.caller
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
