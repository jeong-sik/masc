(** Keeper_delegate_completion_wake — hand a delegated turn's answer back to
    the Keeper that asked for it.

    [masc_keeper_delegate] returns an operation id and does not wait. Before
    this module the answer reached the asker only if it went back and read
    that id, and measured over 2026-08-17..24 none did: 4 delegations started,
    0 status reads, 10 cancels. The answer was written down where only a
    dashboard read it.

    The payload is committed through the same fail-closed durable path HITL
    and Fusion use, so a failed write is reported rather than swallowed. The
    live wake that follows is a hint: it only reaches a [Running] Keeper, and
    its failure is logged, because the committed stimulus is already in the
    queue the Keeper drains on its next admitted turn. *)

val deliver
  :  base_path:string
  -> asked_by:string
  -> operation_id:string
  -> delegate:string
  -> terminal:Keeper_event_queue.delegate_terminal
  -> (unit, string) result
