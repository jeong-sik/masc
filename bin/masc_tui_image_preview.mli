(** Which image Ctrl-O shows.

    The key has two places to find a picture: a [.png] path the conversation
    named, and the images the composer is staging for the next message. The
    choice is made here, away from the terminal, so each of the three answers
    can be checked without one. *)

type preview =
  | Named_path of string
      (** A path the transcript named. It wins over anything staged: a named
          picture already arrived in the conversation, which is what the
          operator just read, while a staged one is still waiting to be
          sent. *)
  | Staged of Masc_tui_keeper_chat_projection.attachment
      (** Nothing was named, but the composer is holding images. The newest
          staged is the answer: staging is why the key is pressed -- a
          screenshot Ctrl-V'd a moment ago never enters the transcript, so
          without this door the key reported nothing with a picture sitting
          right there. *)
  | No_image
      (** Neither. One answer for the two empties, so the refusal can say
          both facts at once instead of naming one and hiding the other. *)

val choose_preview
  :  named:string option
  -> staged:Masc_tui_keeper_chat_projection.attachment list
  -> preview
(** [staged] is in staging order, oldest first, so the newest is the last. *)
