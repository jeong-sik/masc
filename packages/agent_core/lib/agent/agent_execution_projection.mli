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
    [None] means no root terminal has been observed; it does not prove liveness. *)

type ownership_observation =
  | Owner_awaiting
  | Owner_lost of Execution_agent_scope.recovery_evidence
  | Terminal_observed of
      Execution_event.terminal * Execution_agent_scope.recovery_evidence

val observe_ownership : t -> (ownership_observation, error) result
(** Prefer canonical terminal evidence. If absent, observe the existing writer
    authority and refresh the same identity-bound projection while excluding
    new writers. Only a successful locked refresh with no terminal establishes
    [Owner_lost]. That read cannot join a refresh started before the lock.
    [Owner_lost] carries the recovery evidence of the tree read under that
    lock, derived as terminal settlement derives it.
    No journal bytes are recovered, appended or replayed. *)
