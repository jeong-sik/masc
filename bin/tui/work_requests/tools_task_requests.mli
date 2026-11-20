(** Tools inventory/activations/usage/async broker requests, Task document
    preparation, Goal timeline/Candle observations, and Task history/cancel. *)

val close_tools_async_task : Masc_tui_types.state -> unit

val reconcile_task_documents
  :  terminal_size:(unit -> int * int)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> bool

val close_tools_async_detail : Masc_tui_types.state -> unit

val launch_tools_async_detail
  :  ?force:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_tools_async_task_history
  :  ?force:bool
  -> ?older:bool
  -> terminal_size:(unit -> int * int)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_tools_async_task
  :  ?force:bool
  -> terminal_size:(unit -> int * int)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_tools_async_source_task
  :  terminal_size:(unit -> int * int)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_tools_async_observation_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_tools_parts
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.tools_read_part list
  -> unit

val launch_tools_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val settle_tools_skill_read
  :  Masc_tui_types.state
  -> generation:int
  -> Masc_tui_types.tools_read_part
  -> unit

val settle_tools_read
  :  Masc_tui_types.state
  -> generation:int
  -> Masc_tui_types.tools_read_part
  -> bool

val normalize_tools_skill_cursor : Masc_tui_types.state -> unit

val cycle_tools_keeper
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> delta:int
  -> unit

val launch_goal_candle_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val launch_goal_timeline_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val launch_task_history_load
  :  ?older:bool
  -> ?limit:int
  -> terminal_size:(unit -> int * int)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val launch_task_cancel
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> authority:Masc_tui_types.workspace_authority
  -> identity:Masc.Tui_decode.server_identity option
  -> task_id:string
  -> reason:string
  -> unit
