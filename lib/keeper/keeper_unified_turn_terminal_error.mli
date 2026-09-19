(** Terminal error side effects of a unified keeper cycle whose turn failed.

    Two paths based on [Keeper_error_classify.is_runtime_exhausted_error]:

    - [Runtime_exhausted] — calls [Keeper_registry.mark_turn_runtime_exhausted],
      increments the [kcl_to_ktc_exhaustion] FSM edge counter, logs a
      structured WARN naming the cycle's runtime, and increments
      the [agent_core_execution_errors] counter with phase [Runtime_exhausted].

    - Otherwise — sets the turn phase to [Turn_finalizing], increments
      the [agent_core_execution_errors] counter with phase
      [Terminal_non_exhaustion], and logs a structured WARN.

    Side effects only. [runtime_id] is the runtime or lane the cycle was
    assigned; the lane walk inside the turn records each candidate it tried
    in the runtime manifest. *)

val handle
  :  config:Workspace.config
  -> keeper_name:string
  -> runtime_id:string
  -> Agent_core.Error.t
  -> unit
