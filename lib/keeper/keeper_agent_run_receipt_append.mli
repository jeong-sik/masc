(** RFC-0145 PR-6: extract receipt-append safety escalation from
    [keeper_agent_run.run_turn] Step 8 body (L1942-L1999).

    Cycle 5 [EveryTurnHasTerminalReceipt] safety invariant
    (KeeperTurnFSM / KeeperOutcomesConservation specs): a turn whose
    authoritative receipt is silently dropped cannot be reported as
    Ok.  Pre-Cycle 5 the catch arm logged a WARN, recorded a
    coverage-gap and let [turn_result] fall through unchanged.  This
    wrapper preserves the Cycle 5 escalation: the caller observes a
    typed [(unit, string) result], and an [Ok _] turn_result combined
    with an [Error _] receipt outcome surfaces a structured internal
    error to the caller's [match turn_result with Ok _ | Error _].

    Side effects:
    - on success: append receipt + invoke [on_appended] for
      [Keeper_runtime_manifest.Receipt_appended] manifest log
    - on exn: increment failure counter, log warn, record
      coverage-gap, return [Error err_msg]

    [Eio.Cancel.Cancelled] re-raised on both the append and the
    coverage-gap try-with blocks. *)
val append_with_coverage_gap
  :  config:Coord.config
  -> receipt:Keeper_execution_receipt.t
  -> keeper_name:string
  -> trace_id:string
  -> on_appended:(unit -> unit)
  -> (unit, string) result
