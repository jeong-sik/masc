(** SSE observer recovery/stream orchestration and the fleet stream
    reconnection loop. *)

val stream_reconnect_s : float
(** Reconnect backoff interval in seconds shared by SSE streams and failed
    owed-read retries. *)

val stop_observer_recovery : Masc_tui_types.state -> unit

val reconcile_observer_recovery
  :  Masc_tui_types.state
  -> refresh_inflight:bool
  -> mailbox:Workspace_admission.mailbox
  -> unit

val open_observer_if_due
  :  browser_scope:(Masc_tui_types.state -> Masc.Workspace_dataset_event.browser_scope option)
  -> Masc_tui_types.state
  -> retry_closed:bool
  -> host:string
  -> port:int
  -> mailbox:Workspace_admission.mailbox
  -> unit

val reconcile_observer_machine
  :  browser_scope:(Masc_tui_types.state -> Masc.Workspace_dataset_event.browser_scope option)
  -> Masc_tui_types.state
  -> host:string
  -> port:int
  -> mailbox:Workspace_admission.mailbox
  -> unit

val schedule_observer_retry
  :  Masc_tui_types.state
  -> mailbox:Workspace_admission.mailbox
  -> unit ref
  -> unit

val open_fleet_stream_if_due
  :  Masc_tui_types.state
  -> host:string
  -> port:int
  -> mailbox:Workspace_admission.mailbox
  -> unit
