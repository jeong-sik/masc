(** alphaTex → ASCII tablature.

    The TUI draws a [\`\`\`alphatex] fence as a guitar tab when
    {!Masc_tui_alphatex_score.read} reads its text as a score. The tuning
    names the lines, the highest string first. A note that carried technique
    markup keeps its fret and gets a [*] after it.

    Repeat signs are barlines: a bar an [\ro] opened starts past [|:], one a
    [\rc N] closed ends in [:|xN] with the count of total plays, and [\ae]
    numbers ride the left barline as [|1,3|].

    A sixteenth note is one cell wide, or wider in a measure where a fret
    would otherwise touch the slot after it, so the frets of two beats never
    run together. A tab wider than the pane breaks at bar lines into systems,
    top to bottom with a blank line between them, the way printed tablature
    does. A measure is never split.

    When the text is not a score, or one measure is wider than the pane, the
    result is an [Error]: the fence arm then shows the reason and the source,
    the way the mermaid arm falls back. *)

(** Why a fence is not drawn. *)
type tab_failure =
  | Unreadable of Masc_tui_alphatex_score.failure
  | Too_wide of { needed : int; available : int }
      (** one measure is wider than the pane *)

val failure_text : tab_failure -> string
(** The failure worded for the fence's fallback line. *)

val render_tab : max_width:int -> string -> (string list, tab_failure) result
(** [render_tab ~max_width source] is the score's tablature, one line per
    string, highest string first, system after system -- or why the fence
    should show the source instead. *)
