(** Entry-action dispatch observability helpers (RFC-0002).

    Pure side-effect wrappers (log + Prometheus) — no registry state
    read or written. *)

(** Emit the lifecycle log line for a [Publish_lifecycle] entry action;
    no-op for all other entry-action variants. *)
val execute_observability :
  name:string ->
  phase:Keeper_state_machine.phase ->
  ts_unix:float ->
  Keeper_state_machine.entry_action -> unit

(** Map a [(phase, action)] pair to the follow-up event the dispatcher
    should fire (currently only [Overflowed/Start_compaction] →
    [Auto_compact_triggered], with a [metric_keeper_fsm_edge_transitions]
    counter bump). [None] for all other pairs. *)
val followup_event_of_action :
  phase:Keeper_state_machine.phase ->
  Keeper_state_machine.entry_action -> Keeper_state_machine.event option

(** Bump [metric_keeper_lifecycle_dispatch_rejections] when a follow-up
    event is rejected by the state machine. *)
val record_dispatch_rejection : Keeper_state_machine.event -> unit
