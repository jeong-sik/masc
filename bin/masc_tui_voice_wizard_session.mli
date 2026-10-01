(** Terminal voice setup state and pure transitions.
    Replies for an unowned request return [None]; an unanswered save retains
    its original revision until the read establishes whether retry is possible. *)

type voice_wizard_save =
  | Save_not_sent
  | Save_sending of int
  | Save_probing of int
      (** Written. The endpoints are being asked, and their answer carries this
          number. *)
  | Save_settled
  | Save_unanswered of { request : int; revision : string }
      (** Sent against [revision], and nothing came back that says whether it
          was written: the connection dropped or the deadline passed. The
          session reads runtime.toml again before it lets the draft be sent
          twice. *)
  | Save_needs_reopen of string
      (** The read after an unanswered save could not rule the write out. A
          retry would carry a revision this session no longer knows is
          current, so it waits for esc and a fresh read. The string says why. *)

type voice_wizard_session =
  { vws_draft : Voice_wizard.draft
  ; vws_step : Voice_wizard.step
  ; vws_input : string
  ; vws_replace_on_type : bool
        (** The first keystroke replaces a prefilled value rather than appending
            to it, the way the configuration editor does: the prefill is a
            suggestion, and typing over it is what an operator means. *)
  ; vws_revision : string
        (** What the configuration read as when this session opened. The save
            carries it, so a session left open while something else wrote is
            told rather than overwriting it. *)
  ; vws_status : string option
  ; vws_save : voice_wizard_save
  ; vws_probe : string list
        (** What each endpoint answered after the save, one line each. The
            wizard writes a configuration; whether anything on the other end
            responds is measured, not inferred from the write succeeding. *)
  }

type voice_wizard_save_reply =
  | Save_written of string
  | Save_refused of string
  | Save_unanswered_reply of string

val voice_wizard_open : section:Voice_setup.section -> provider:Voice_wizard.provider -> revision:string -> voice_wizard_session
val voice_wizard_is_sending : voice_wizard_session -> bool
val voice_wizard_append : voice_wizard_session -> string -> voice_wizard_session
val voice_wizard_backspace : voice_wizard_session -> voice_wizard_session
val voice_wizard_clear : voice_wizard_session -> voice_wizard_session
val voice_wizard_save_held : voice_wizard_session -> string option
val voice_wizard_sending : voice_wizard_session -> request:int -> voice_wizard_session
val voice_wizard_after_save : voice_wizard_session -> request:int -> voice_wizard_save_reply -> voice_wizard_session option
val voice_wizard_after_probe : voice_wizard_session -> request:int -> (string list, string) result -> voice_wizard_session option
val voice_wizard_after_reread : voice_wizard_session -> request:int -> (string, string) result -> voice_wizard_session option
val voice_wizard_commit : voice_wizard_session -> voice_wizard_session
val voice_wizard_go : voice_wizard_session -> Voice_wizard.step -> voice_wizard_session
val voice_wizard_next : voice_wizard_session -> voice_wizard_session
val voice_wizard_previous : voice_wizard_session -> voice_wizard_session
val voice_wizard_cycle_provider : voice_wizard_session -> voice_wizard_session
val voice_wizard_cycle_section : voice_wizard_session -> voice_wizard_session
