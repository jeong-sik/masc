(** Typed run lifecycle events.

    Envelope identity joins the surrounding event stream:
    [correlation_id] is the raw-trace session id when present (same source
    as turn-level events, see [Pipeline_common.event_envelope]);
    [AgentStarted] opens a fresh run id; the outcome event reuses the
    lifecycle [current_run_id] (raw-trace run id) when one is active; and
    [caused_by] points at the started event's run id (#877).
    [task_id] carries the started run id so subscribers can group one run
    invocation.

    @stability Internal
    @since 0.217.2 *)

(** Validate that [on_yield]/[on_resume] are supplied together or both
    omitted.  Returns [Error] with an [InvalidConfig] payload otherwise. *)
val validate_run_callbacks
  :  on_yield:'a option
  -> on_resume:'b option
  -> (unit, Error.t) result

type outcome =
  | Completed of Types.api_response
  | Yielded of { turn : int }
  | Input_required of Error.input_required
  | Failed of Error.t

(** Wrap a run with [AgentStarted] and exactly one typed invocation outcome.

    Successful runs publish [AgentCompleted]. Failed runs and synchronous
    exceptions publish [AgentFailed]. A run never publishes both terminal
    variants.

    [current_run_id] is queried lazily so the outcome event reflects the
    raw-trace run id active when the call returns. [classify] maps the concrete
    run API result to the shared lifecycle vocabulary.

    If [f] raises, [AgentFailed] is still published with an [Error.Internal]
    projection of the exception; the original exception is then re-raised
    with its backtrace intact. *)
val with_run_lifecycle_events
  :  event_bus:Event_bus.t option
  -> agent_name:string
  -> raw_trace:Raw_trace.t option
  -> current_run_id:(unit -> string option)
  -> classify:(('a, 'error) result -> outcome)
  -> (unit -> ('a, 'error) result)
  -> ('a, 'error) result
