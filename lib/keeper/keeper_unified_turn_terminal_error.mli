(** RFC-0136 PR-4-b: terminal error side effects extracted from
    [keeper_unified_turn] retry loop.

    Two paths based on [Keeper_error_classify.is_runtime_exhausted_error]:

    - [Runtime_exhausted] — sets registry to [Turn_runtime_exhausted],
      increments the [kcl_to_ktc_exhaustion] FSM edge counter, logs a
      structured WARN listing the attempted runtimes, and increments
      the [oas_execution_errors] counter with phase [Runtime_exhausted].

    - Otherwise — sets the turn phase to [Turn_finalizing], increments
      the [oas_execution_errors] counter with phase
      [Terminal_non_exhaustion], and logs a structured WARN.

    Side effects only.  The function is unit-returning to keep the 9
    retry-loop call sites unchanged: they invoke a [mark_terminal_error]
    closure that adapts {!handle} to the loop-scoped [attempt] /
    [attempted_runtimes] values.  Cycle 52 narrative behavior preserved. *)

val handle
  :  config:Workspace.config
  -> keeper_name:string
  -> attempt:int
  -> attempted_runtimes:string list
  -> Agent_sdk.Error.sdk_error
  -> unit
