(** Work/Harness/Fusion/System-log detail view launchers and shared detail cursor
    stepping. *)

val launch_fusion_detail_load
  :  ?demand:Masc_tui_fusion_updates.demand
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> run_id:string
  -> unit

val launch_fusion_historical_detail_load
  :  ?demand:Masc_tui_fusion_updates.demand
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> reference:Masc.Tui_decode_fusion.fusion_historical_evidence
  -> unit

val open_planning_detail
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_schedule_detail
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_verification_detail
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_harness_detail : Masc_tui_types.state -> unit

val open_fusion_detail
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_selected_system_log : Masc_tui_types.state -> unit

val step_detail_cursor
  :  count:int
  -> cursor:int
  -> delta:int
  -> set_cursor:(int -> unit)
  -> reopen:(unit -> unit)
  -> unit
