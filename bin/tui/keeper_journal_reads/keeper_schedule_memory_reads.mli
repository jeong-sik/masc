(** Keeper schedules, story turns, memory browser, and chat journal owed-read launchers. *)

val owe_keeper_schedules_read : Masc_tui_types.state -> unit
val owe_schedule_reads_for_queue_writes : Masc_tui_types.state -> keepers:string list -> unit

val settle_keeper_schedules_read
  :  Masc_tui_types.state
  -> keeper:string
  -> settles:bool
  -> ('a, 'b) result
  -> unit

val keeper_schedules_answer_current
  :  Masc_tui_types.state
  -> Masc_tui_types.keeper_schedule_page_request
  -> bool

val launch_owed_keeper_schedules
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_keeper_story_turns_read : Masc_tui_types.state -> unit
val owe_keeper_story_turns_read_for : Masc_tui_types.state -> keepers:string list -> unit

val launch_owed_keeper_story_turns
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_memory
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val chat_keeper_on_screen : Masc_tui_types.state -> string option

val owe_chat_journal_read
  :  Masc_tui_types.state
  -> keeper:string
  -> Masc_tui_observer.runtime_journal
  -> unit

val owe_chat_journal_reads : Masc_tui_types.state -> unit

val settle_chat_journal
  :  Masc_tui_types.chat_journal_owed option
  -> keeper:string
  -> succeeded:bool
  -> Masc_tui_types.chat_journal_owed option

val launch_owed_chat_journals
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
