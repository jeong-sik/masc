(** A name for the input mode the TUI is in.

    The dispatch in masc_tui.ml decides who sees a key with eight ad-hoc
    flags, each carrying its own guard, and the precedence between them
    exists only as the order of the match arms. This module gives that
    precedence a name and a single derivation, so a screen (a header chip),
    a projection (search), or a test can ask "who owns the keyboard right
    now" without re-reading the guards.

    The dispatch itself does not consume this yet, so this is a mirror and
    nothing holds it against what it mirrors. [test_tui_mode] checks the
    ladder here against itself; it does not read masc_tui.ml. Move an arm in
    the dispatch and this file goes wrong while every test stays green — the
    arm and the derivation have to move together, by hand, until the first
    consumer makes the dispatch read this instead of duplicating it.

    {!Ast_grep} can read masc_tui.ml directly, the way
    [test_tui_http_ast] pins wiring and [test_keeper_keepalive_launch_order_ast]
    pins an order. That is what would turn this into something the build
    checks rather than something a reader has to remember. *)

type t =
  | Image_overlay   (** an inline image is shown; any key closes it *)
  | Help            (** the [?] sheet; swallows everything *)
  | Palette         (** the [:] palette owns typed characters *)
  | Search          (** the [/] prompt owns typed characters *)
  | Board_compose   (** the Board post editor owns the keyboard *)
  | Message_edit    (** the chat pane; its composer reads every key *)
  | Composer        (** the one-line composer focused with [i] *)
  | Pending of string
      (** a two-press action is armed; the next key confirms or disarms.
          The payload names the armed action for display. *)
  | Normal

(** The flags as the dispatch reads them, one boolean per guard. The caller
    builds this from [state]; keeping the record plain lets tests enumerate
    combinations without a state value. *)
type flags = {
  image_open : bool;
  help_open : bool;
  palette_open : bool;
  search_active : bool;
  board_composing : bool;
  message_mode : bool;  (** the view is the chat pane *)
  composer_focused : bool;
  pending : string option;  (** an armed two-press action, by name *)
}

val no_flags : flags

val active : flags -> t
(** The mode whose dispatch arm would fire, in the match's order:
    image, help, palette, search, board compose, chat, composer, an armed
    two-press action, then [Normal]. *)

val label : t -> string option
(** Short text for a header chip; [None] for [Normal]. *)
