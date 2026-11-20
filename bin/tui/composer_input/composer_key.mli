(** Keystroke dispatch for the TUI message composer row. *)

val handle_composer_key
  :  terminal_size:(unit -> int * int)
  -> wheel_notch_rows:int
  -> withdraw_resource_diagram_pending:(unit -> unit)
  -> launch_keeper_history_load:(keeper_name:string -> unit)
  -> send_operator_text:(keeper_name:string -> Masc_tui_message_input.snapshot -> unit)
  -> paste_clipboard_image:(unit -> unit)
  -> open_named_image:(unit -> unit)
  -> launch_keeper_chat_tool_details_load:(keeper_name:string -> unit)
  -> Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> bool
