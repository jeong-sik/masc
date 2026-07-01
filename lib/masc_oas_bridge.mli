(* lib/masc_oas_bridge.mli *)

(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces strict structural timeouts, cancellation safety, and type isolation.

    Migration and entrypoint requirements are documented in
    [docs/oas-bridge-clock-timeout-contract.md]. This is intentionally
    fail-closed: adding a default-off compatibility flag would restore the
    clockless path that silently ignored configured wall-clock budgets. *)

(** Safe execution of a generic OAS operation with a mandatory Eio clock.
    Catches [Eio.Time.Timeout] and [Eio.Cancel.Cancelled] to perform functional rollback.
    [caller] (#10094) labels the Otel_metric_store timeout counter so the
    operator can attribute timeouts to specific call sites.
    Raises [Invalid_argument] when [timeout_s] is not positive, finite, or is
    [NaN]. A missing Eio environment fails closed without running [fn]. *)
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

    Inherits the [Invalid_argument] contract from [run_safe]. The env parser
    accepts only positive finite values; invalid values such as ["0"], ["-1"],
    ["nan"], or ["infinity"] fall back before this boundary. *)
val run_with_caller
  :  caller:Env_config_oas_bridge.caller
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
