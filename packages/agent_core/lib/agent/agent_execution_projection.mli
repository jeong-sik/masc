(** Read-only implementation of one canonical durable Agent execution.

    The public surface is owned solely by {!Agent_execution_projection_intf.S}.
    The constructor below remains private to the wrapped AGENT_CORE implementation. *)

include Agent_execution_projection_intf.S

val open_durable
  :  codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> locator_run_id:Execution_event.Run_id.t
  -> unit
  -> (t, error) result

val terminal_recovery :
  t ->
  ((Execution_event.terminal * Execution_agent_scope.recovery_evidence) option, error) result
(** Inspect one refreshed, validated reducer snapshot without writer admission.
    [None] means the top-level run is still running. *)
