(** Signals the Keeper owner raises into a turn, readable by the runtime
    adapters that observe them.

    [Keeper_owner] calls the adapters, so the adapters cannot reference it back.
    That left them unable to tell a cancellation they caused from one they did
    not: every [Eio.Cancel.Cancelled] was recorded as [Transport_interrupted],
    which is [Ambiguous], which sends the official-client session to
    [Recovery_required] -- and that blocks every later turn for the keeper until
    an operator resolves it by hand (#28012).

    An exception carries no dependencies, so a module holding only this one can
    sit below both without inverting anything. The alternative was matching on
    [Printexc.to_string], which is the classifier shape #26770 removed. *)

(** The owner stopped a turn it had started. Not an ambiguity: the owner knows
    the turn did not complete and knows why, and classifies it as
    [Turn_cancelled] on the operation side. *)
exception Stop_active_child
