(** Run lifecycle events (AgentStarted/AgentCompleted/AgentFailed).

    The run-level lifecycle triple lost its only producer when the legacy
    orchestrator was removed (#1755); the variants and downstream subscribers
    stayed behind.  Envelope identity follows the removed producer's
    derivation so the triple joins the surrounding event stream:
    [correlation_id] is the raw-trace session id when present (same source
    as turn-level events, see [Pipeline_common.event_envelope]);
    [AgentStarted] opens a fresh run id; the terminal events reuse the
    lifecycle [current_run_id] (raw-trace run id) when one is active; and
    terminal [caused_by] points at the started event's run id (#877).
    [task_id] carries the started run id — the only run-scoped identifier
    available without an orchestrator task — so subscribers can group the
    triple of one run invocation.

    @stability Internal
    @since 0.217.2 *)

(** Validate that [on_yield]/[on_resume] are supplied together or both
    omitted.  Returns [Error] with an [InvalidConfig] payload otherwise. *)
val validate_run_callbacks
  :  on_yield:'a option
  -> on_resume:'b option
  -> (unit, Error.sdk_error) result

(** Wrap a run with the [AgentStarted] -> [AgentCompleted] (and companion
    [AgentFailed] on error) lifecycle triple.

    [current_run_id] is queried lazily so the terminal events reflect the
    raw-trace run id active at completion time.  [project] collapses the
    detailed-error channel ([Provider_failure_attribution.detailed_error])
    into the legacy [Error.sdk_error] carried by the event payload.

    If [f] raises, the terminal events are still published (with an
    [Error.Internal] projection of the exception) so subscribers always
    observe [AgentStarted] closed by a terminal event; the original
    exception is then re-raised with its backtrace intact. *)
val with_run_lifecycle_events
  :  event_bus:Event_bus.t option
  -> agent_name:string
  -> raw_trace:Raw_trace.t option
  -> current_run_id:(unit -> string option)
  -> project:(Provider_failure_attribution.detailed_error -> Error.sdk_error)
  -> (unit -> (Types.api_response, Provider_failure_attribution.detailed_error) result)
  -> (Types.api_response, Provider_failure_attribution.detailed_error) result
