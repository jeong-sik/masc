(** Entry-action dispatch observability helpers (RFC-0002).

    Pure side-effect wrappers (log + Otel_metric_store) — no registry state
    read or written. *)

(** Emit the lifecycle log line for a [Publish_lifecycle] entry action;
    no-op for all other entry-action variants. *)
val execute_observability :
  name:string ->
  phase:Keeper_state_machine.phase ->
  ts_unix:float ->
  Keeper_state_machine.entry_action -> unit

(** Durable activities never synthesize a follow-up lifecycle event here. *)
val followup_event_of_action :
  phase:Keeper_state_machine.phase ->
  Keeper_state_machine.entry_action -> Keeper_state_machine.event option

(** Bump [metric_keeper_lifecycle_dispatch_rejections] when a follow-up
    event is rejected by the state machine. *)
val record_dispatch_rejection : Keeper_state_machine.event -> unit
