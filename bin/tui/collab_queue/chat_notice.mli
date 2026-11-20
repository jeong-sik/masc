(** Local chat/system/error notices and synthetic local transcript rows. *)

(** What the pane says back to something the operator did.

    A reply is a row in the conversation, drawn into the pane the operator
    typed in: the command list, a queue snapshot, what a preset restore
    applied and skipped. The session log lives on Metrics, and a [/help]
    answered there is a [/help] that looks ignored. When the pane has no keeper
    to file the row under, it goes to the footer and the session log, the way
    a failure does.

    A failure is the operator's own step that did not work -- the clipboard
    held no image, a command was missing its argument, an image would not
    open. The conversation with the keeper is not where that belongs: it
    says so in the footer of the pane they are standing on for
    [last_action_window_s], and in the event log. *)
type notice_kind =
  | Notice_reply
  | Notice_failure

val append_chat_local_message
  :  Masc_tui_types.state
  -> keeper:string
  -> string
  -> unit

val chat_notice
  :  Masc_tui_types.state
  -> keeper_name:string option
  -> kind:notice_kind
  -> string
  -> unit
