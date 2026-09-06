(** Keeper-side shim over the pure Turn FSM ([Turn_fsm], library masc_turn).

    Re-exports the pure FSM surface (states, reasons, [classify_transition],
    labels, TLA symbols) via [include module type of Turn_fsm], and adds the
    keeper-coupled tail: [require_active_state] (its [@@fsm_guard] expansion
    references [Keeper_fsm_guard_runtime]) and [emit_transition] (telemetry /
    audit / metrics). Dependency direction is Keeper -> Turn.

    Formal contract for the pure core: [specs/keeper-turn-fsm/KeeperTurnFSM.tla]
    (verified by [test_keeper_turn_fsm_tla_parity]). *)

include module type of Turn_fsm

val emit_transition :
  ?ctx:transition_context ->
  keeper_name:string ->
  turn_id:int ->
  ?prev:_ turn_state ->
  _ turn_state ->
  unit
(** Build one structured FSM transition record and send that value to the log
    details, [Keeper_transition_audit] WAL, and Otel_metric_store boundary. A
    missing [?prev] records ["-"]. Pinned by [test_keeper_turn_fsm_emit]. *)
