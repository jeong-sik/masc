(** Prompt catalog, preset CRUD/call launchers, chat command reads, and
    librarian input loading. *)

val launch_prompts_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_preset_call
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> call:(host:string -> port:int -> ('a, string) result)
  -> wrap:(('a, Masc_tui_types.request_failure) result -> Masc_tui_async_protocol.async_msg)
  -> unit

val launch_preset_save
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> sink:Masc_tui_async_protocol.preset_sink
  -> name:string
  -> description:string
  -> chat_input:string option
  -> also_pane:bool
  -> unit

val launch_chat_command_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> label:string
  -> call:(host:string -> port:int -> ('a, string) result)
  -> wrap:(('a, Masc_tui_types.request_failure) result -> Masc_tui_async_protocol.chat_command_read_outcome)
  -> unit

val settle_retired_chat_command_reads : Masc_tui_types.state -> unit

val forget_play_invite : Masc_tui_types.state -> name:string -> unit

val launch_presets_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val preset_rows_for_state
  :  Masc_tui_types.state
  -> Masc.Tui_decode.preset_manifest list

val selected_preset_for_state
  :  Masc_tui_types.state
  -> Masc.Tui_decode.preset_manifest option

val ensure_preset_detail
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val prompt_catalog_count_for_state : Masc_tui_types.state -> int

val selected_prompt_for_state
  :  Masc_tui_types.state
  -> Masc.Tui_decode.prompt_row option

val launch_librarian_input_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> prompt_key:string
  -> unit
