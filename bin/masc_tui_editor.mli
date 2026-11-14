(** $EDITOR round-trip for exact source text or a JSON settings payload. See the implementation
    for the terminal-handshake contract. *)

val editor_command : unit -> string option
(** The operator's editor: [$EDITOR] first, [$VISUAL] as fallback, [None]
    when neither is set to a non-empty value — the caller reports that no
    editor is configured rather than guessing one. *)

type unavailable =
  | Unset
  | Command_not_found of string
  | Stopped_by_signal of { editor : string; signal : int }
(** Why the editor did not run: neither [$EDITOR] nor [$VISUAL] is set, the
    shell could not find the command, or a signal stopped it. *)

type abort =
  | Cancelled
  | Editor_unavailable of unavailable
  | Form_unreadable of string
(** Why the form came back empty. All three used to be [None], so every
    caller could say only "cancelled" -- and an [$EDITOR] naming a binary
    that is not installed read to the operator as a decision they had made.
    [Cancelled] is the editor exiting non-zero, which is the operator saying
    no; [Editor_unavailable] is the command not running at all; and
    [Form_unreadable] is the temp file, which is neither of them. *)

val abort_detail : ko:bool -> abort -> string
(** The reason, without a subject, in the screen's language: callers name
    their own action. A file that could not be read keeps the system's
    words. *)

val roundtrip :
  restore:(unit -> unit) ->
  reenter:(unit -> unit) ->
  ?suffix:string ->
  string ->
  (string, abort) result
(** [roundtrip ~restore ~reenter ?suffix content] hands [content] to the editor
    and returns [Ok edited] on exit code 0. [restore] runs before the child
    (leave raw mode), [reenter] after it (raw mode back, full repaint
    requested). [suffix] defaults to [.json] so existing settings forms keep
    editor syntax detection; Skill sources pass [.md]. *)
