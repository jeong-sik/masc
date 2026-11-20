(** Runtime catalogue lane/slot editing and Keeper runtime assignment picker. *)

val launch_runtime_lane_write
  :  ?replacement_selection:
       (Masc_tui_types.slot_editor_target
       * Masc_tui_types.slot_editor_identity
       * Masc_tui_types.slot_editor_identity)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> written:Masc_tui_types.runtime_lane_list
  -> (host:string -> port:int -> (Masc_tui_runtime_config_receipt.t, string) result)
  -> unit

val runtime_picker_close_keys : string list

val launch_runtime_default_route
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val launch_runtime_lane_pick
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> pick:Masc_tui_types.runtime_lane_pick
  -> runtime:Masc.Tui_decode.runtime_option
  -> existing:string list
  -> unit

val handle_slot_edit
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.slot_edit
  -> unit

val handle_runtime_lane_edit
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.runtime_lane_edit
  -> unit

val keeper_runtime_picker_action
  :  Masc_tui_pick_list.t
  -> string
  -> Masc_tui_pick_list.action option

val close_keeper_runtime_pick : Masc_tui_types.state -> unit

val launch_runtime_assignment_set
  :  Masc_tui_types.state
  -> keeper_name:string
  -> runtime_id:string option
  -> bool

val keeper_runtime_pick_key
  :  Masc_tui_types.state
  -> terminal_rows:int
  -> string
  -> unit
