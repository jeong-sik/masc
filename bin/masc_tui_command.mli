(** What the operator typed into the composer: a message for the keeper, or
    a command for the TUI.

    The composer is the one input row every surface shows, addressed to the
    keeper the roster cursor points at. Most of what is typed there is a
    message. A line that starts with a slash is a command this module names,
    and a command this build does not know is reported as such rather than
    sent to the keeper as text - a mistyped command should not become an
    instruction the keeper acts on.

    The grammar is closed: one leading slash, one word, the rest of the
    first line, then any further lines. No prefix matching, no aliases. *)

type t =
  | Say of string  (** Plain text for the keeper, unchanged. *)
  | Task_for_keeper of {
      title : string;  (** The rest of the first line after [/task]. *)
      body : string;  (** Every line after the first, as typed. *)
    }
  | Task_missing_title  (** [/task] with nothing after it on the line. *)
  | Help  (** [/help] — draw the command list into the pane. *)
  | Switch_keeper of string
      (** [/keeper <name>] — point this pane at another keeper. *)
  | Switch_keeper_missing_name  (** [/keeper] with no name on the line. *)
  | Interrupt_turn
      (** [/interrupt] — the composer form of the interrupt keybinding, for
          an operator mid-sentence whose hands are already on letters. *)
  | Toggle_thinking
      (** [/thinking] — fold or unfold reasoning blocks in this pane. *)
  | View_image of string
      (** [/image <path>] — draw an image file on the terminal, if it can
          hold one. The path is the rest of the first line, untrimmed of
          nothing but the space after the word: a path may contain spaces,
          and quoting it would be a second grammar. *)
  | View_image_missing_path  (** [/image] with no path on the line. *)
  | Unknown of string  (** A slash word this build does not know, by name. *)

val help_lines : string list
(** One line per command, the list [/help] draws. Kept beside the parser so a
    new command cannot ship without its line. *)

(** How [/keeper <name>] resolved against the roster. *)
type keeper_match =
  | Keeper_found of string
  | Keeper_ambiguous of string list
      (** More than one roster name starts with what was typed; the
          candidates are reported rather than guessed between. *)
  | Keeper_unknown

val resolve_keeper_name : names:string list -> string -> keeper_match
(** Exact name first — a keeper whose full name prefixes another's stays
    reachable — then a unique prefix. Command words stay closed; only the
    name argument matches by prefix. *)

val parse : string -> t
(** Read the composer's text. Leading blanks are not stripped before the
    slash is looked for: an operator who types a space first meant text. *)

val task_message : task_id:string -> title:string -> body:string -> string
(** The message handed to the keeper once its task exists: the task id in
    front of what the operator wrote, so the keeper can claim the exact task
    and the operator's own words carry the request. *)
