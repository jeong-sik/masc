(** Close a run whose writer exited while its provider attempt was open and
    before the host collected the response.

    The journal allows one provider attempt per turn, so such a turn cannot be
    resumed: the attempt may already have reached the provider. Resuming it
    fails on the collected-turn counter (#52341). The host closes it here and
    continues the work from the checkpoint it saved before the call.

    Everything runs under the scope's writer lock, taken without waiting: a
    live writer, or another observation holding the claim, is an [Error]. The
    tree is read again under the lock before anything is written. *)

type retirement =
  | Not_uncollected
      (** The run is not that shape: its root is finished, its open turn is not
          the one the checkpoint precedes, no provider attempt is open, the
          attempt has Tool invocations, or the resume functions refuse the
          topology. Nothing is committed. *)
  | Retired of Execution_event.terminal * Execution_agent_scope.recovery_evidence
      (** The provider attempt, the turn and the root were closed [Cancelled]
          in one abort; the evidence is read back from the closed tree. *)

type error =
  | Writer_failed of Execution_lane_writer.scope_failure
      (** The lock was not taken, the journal could not be opened or read, or
          the writer failed to close. A failed close can follow a committed
          abort: the host reads the terminal again before it decides. *)
  | Scope_failed of Execution_agent_scope.error
      (** The locator names no run, the Agent name differs from the run's, or
          a read or the abort failed. *)
  | Raised of exn
      (** The writer raised something other than cancellation or a reserved
          exception. *)

val error_to_string : error -> string

(** [checkpoint_turn_count] is the turn count of the newest checkpoint the host
    saved for this run. A provider attempt of turn [k] opens only after the
    checkpoint with turn count [k]; a collected response moves it to [k + 1].
    A run whose single open turn has ordinal [checkpoint_turn_count], whose
    provider attempt of that turn is open, and which has no Tool invocation
    under that attempt is [Retired]. Whether the response was recorded does not
    matter: a recorded response alone cannot rebuild the collected message.

    Cancellation and reserved exceptions are re-raised; every other failure is
    an [Error] value. *)
val retire
  :  codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> Execution_agent_scope.scope_locator
  -> agent_name:string
  -> checkpoint_turn_count:int
  -> (retirement, error) result
