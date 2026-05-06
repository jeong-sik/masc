(* lib/masc_oas_bridge.mli *)

(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces strict structural timeouts, cancellation safety, and type isolation. *)

(** Safe execution of a generic OAS operation with a mandatory timeout.
    Catches [Eio.Time.Timeout] and [Eio.Cancel.Cancelled] to perform functional rollback.
    [caller] (#10094) labels the Prometheus timeout counter so the
    operator can attribute timeouts to specific call sites; defaults
    to ["unknown"] for backwards compatibility with legacy callers.
    Raises [Invalid_argument] when [timeout_s] is not positive and finite. *)
val run_safe :
  ?caller:string ->
  timeout_s:float ->
  (unit -> ('a, Agent_sdk.Error.sdk_error) result) ->
  ('a, Agent_sdk.Error.sdk_error) result

(** Single entry point that resolves the per-caller timeout from
    [Env_config_oas_bridge] and labels the resulting Prometheus
    counter.  Preferred over [run_safe] for new callers — the
    timeout is no longer a hardcoded literal but an
    env-overridable per-caller budget.  See [Env_config_oas_bridge]
    for the per-caller default table and env-var layout. *)
val run_with_caller :
  caller:Env_config_oas_bridge.caller ->
  (unit -> ('a, Agent_sdk.Error.sdk_error) result) ->
  ('a, Agent_sdk.Error.sdk_error) result
