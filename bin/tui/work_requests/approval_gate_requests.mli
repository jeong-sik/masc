(** Approval, Gate, and Keeper tool-approval mode requests and single-action
    flight coordination. *)

val supersede_home_decision_receipt : Masc_tui_types.state -> unit

val launch_surface_tool_approval
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> tool_call_id:string
  -> approval_id:string
  -> allow:bool
  -> unit

val launch_keeper_tool_approvals_load
  :  ?intent:Masc_tui_types.Snapshot_read.intent
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val retains_receipt_workspace
  :  Masc_tui_types.state
  -> Masc.Tui_decode.server_identity
  -> bool

val launch_gate_snapshot_load
  :  ?intent:Masc_tui_types.Snapshot_read.intent
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_gate_resolve
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> approval_id:string
  -> approve:bool
  -> reason:string option
  -> unit

val launch_gate_auto_judge_retry
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc.Tui_decode.gate_pending
  -> unit

val launch_gate_mode_set
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> lane:Masc_tui_palette.gate_lane
  -> mode:string
  -> unit

val launch_keeper_tool_modes_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_keeper_tool_mode_set
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> mode:Masc.Keeper_tool_approval_mode.mode
  -> unit

val launch_keeper_approval
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_keeper_chat_projection.request
  -> tool_call_id:string
  -> approval_id:string
  -> allow:bool
  -> unit
