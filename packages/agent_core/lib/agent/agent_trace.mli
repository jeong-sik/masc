(** Raw-trace integration helpers for the Agent module.

    Wraps [Raw_trace] calls with lifecycle updates and hook invocation
    tracing.  These functions depend on [Agent_types.t] (mutable state).

    @stability Internal
    @since 0.93.1 *)

open Agent_types

(** {1 Hook recording} *)

(** Record a hook invocation in the active raw-trace run (no-op when
    [active_run] is [None]). *)
val record_hook_invocation
  :  Raw_trace.active_run option
  -> ?invocation:Tool_contract.Invocation.t
  -> hook_name:string
  -> decision:Hooks.hook_decision
  -> ?detail:string
  -> unit
  -> unit

(** Invoke a hook within a tracing span, recording the decision. *)
val invoke_hook_with_trace
  :  t
  -> ?raw_trace_run:Raw_trace.active_run
  -> turn:int
  -> hook_name:string
  -> (Hooks.hook_event -> Hooks.hook_decision) option
  -> Hooks.hook_event
  -> Hooks.hook_decision

(** {1 Tool execution with tracing} *)

(** Execute tool-use blocks with full raw-trace recording (started/finished
    events, lifecycle updates). Delegates to [Agent_tools.execute_tools],
    retaining completed results when a trace observer fails. *)
val execute_tools_with_trace
  :  t
  -> Raw_trace.active_run option
  -> turn:int
  -> ?before_tool_execution:(unit -> unit)
  -> Types.content_block list
  -> (Agent_tools.execution_report, Agent_tools.execution_failure) result

(** {1 Assistant block recording} *)

(** Record assistant content blocks in the active run. *)
val trace_assistant_blocks
  :  Raw_trace.active_run option
  -> Types.content_block list
  -> (unit, Error.sdk_error) result

(** {1 Response inspection} *)

(** The user-facing final text of a response, or [None] when the response
    carries no visible text (e.g. thinking-only or tool-only turns).  Thinking
    blocks are excluded; whitespace-only text is treated as absent. *)
val final_text_of_response : Types.api_response -> string option

(** {1 Run lifecycle} *)

type trace_success =
  | Run_completed of
      { final_text : string option
      ; stop_reason : string option
      }
  | Run_yielded of { stop_reason : string }

(** Outcome-aware form of {!with_raw_trace_run_result}.  [classify_success]
    distinguishes a terminal completion from a cooperative yield without
    encoding either as an error.  A yielded run segment is finalized with no
    raw-trace error, leaves the agent lifecycle [Ready], and does not invoke
    [on_run_complete]. *)
val with_raw_trace_run_classified_result
  :  of_sdk_error:(Error.sdk_error -> 'error)
  -> error_to_string:('error -> string)
  -> classify_success:('value -> trace_success)
  -> t
  -> string
  -> (Raw_trace.active_run option -> ('value, 'error) result)
  -> ('value, 'error) result

(** Execute [f] within a raw-trace run, handling start/finish recording
    and lifecycle status updates.  [f] receives [Some active_run] when
    raw-trace is configured, [None] otherwise. *)
val with_raw_trace_run
  :  t
  -> string
  -> (Raw_trace.active_run option -> (Types.api_response, Error.sdk_error) result)
  -> (Types.api_response, Error.sdk_error) result

(** Error-polymorphic form of {!with_raw_trace_run}.  [of_sdk_error] lifts
    trace-infrastructure failures into the caller's carrier, while
    [error_to_string] is used only for lifecycle/raw-trace diagnostics.

    If [f] raises, the original exception and raw backtrace are preserved.
    A secondary failure to finalize the raw trace is emitted as a structured
    error log before the original exception is re-raised. *)
val with_raw_trace_run_result
  :  of_sdk_error:(Error.sdk_error -> 'error)
  -> error_to_string:('error -> string)
  -> t
  -> string
  -> (Raw_trace.active_run option -> (Types.api_response, 'error) result)
  -> (Types.api_response, 'error) result
