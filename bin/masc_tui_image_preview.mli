(** Which image Ctrl-O shows.

    The key has two places to find a picture: a [.png] path the conversation
    named, and the images the composer is staging for the next message. When
    both exist the newer one wins: a screenshot Ctrl-V'd a keystroke ago is
    what the key was pressed to see, while a path named after that paste is
    what the operator just read. The choice is made here, away from the
    terminal, so each of the three answers can be checked without one. *)

type order =
  | Named_is_newer
      (** The message naming the path arrived after the attachment was
          staged: what the operator just read outranks what is still waiting
          to be sent. *)
  | Staged_is_newer
      (** The attachment entered the composer after the naming message. This
          is the keystroke the key exists for -- stage a screenshot, press
          Ctrl-O, see that screenshot. *)
  | Unordered
      (** Recency could not be established -- the history row that marked the
          staging has since been replaced by the transcript. The named path
          keeps the key, which is the answer it gave before staging order was
          tracked. *)

type preview =
  | Named_path of string
      (** A path the transcript named. It wins when its message is the newer
          one, and when neither can be shown to be: a named picture already
          arrived in the conversation, which is what the operator just read,
          while a staged one is still waiting to be sent. *)
  | Staged of Masc_tui_keeper_chat_projection.attachment
      (** Nothing was named, or the staging is the newer act. The newest
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
  -> order:order
  -> preview
(** [staged] is in staging order, oldest first, so the newest is the last.
    [order] is consulted only when a named path and a staged attachment both
    exist; with one candidate there is nothing to order. *)
