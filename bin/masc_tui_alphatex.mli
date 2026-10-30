(** alphaTex → ASCII tablature.

    The TUI draws an [\`\`\`alphatex] or [\`\`\`atex] fence as a guitar tab when
    {!Masc_tui_alphatex_score.read} reads its text as a score. The tuning
    names the lines, the highest string first. A tied note shows the fret it
    holds in parentheses, [(7)]. A note that carried technique markup keeps
    its fret and gets a [*] after it.

    Repeat signs are barlines: a bar an [\ro] opened starts past [|:], one a
    [\rc N] closed ends in [:|xN|] with the count of total plays, and [\ae]
    numbers ride the left barline as [|1,3|]. The close edge ends at a
    barline so the next bar's marks join past one.

    A sixteenth note is one cell wide, or wider in a measure where a fret
    would otherwise touch the slot after it, so the frets of two beats never
    run together. Simultaneous notes share a column; its widest note decides
    the room they need. A tab wider than the pane breaks at bar lines into
    systems. A bar that cannot fit alone continues at beat boundaries, with
    [>] at the open edges and the same bar number followed by [+]. Repeat
    and ending signs remain at their original bar edges. No beat, chord or
    held note is divided, dropped or given a new musical bar.

    When the text is not a score, or one beat with its bar marks cannot fit, the
    result is an [Error]: the fence arm then shows the reason and the source,
    the way the mermaid arm falls back. *)

(** Why a fence is not drawn. *)
type tab_failure =
  | Unreadable of Masc_tui_alphatex_score.failure
  | Too_wide of { needed : int; available : int }
      (** one indivisible beat with its original edge marks cannot fit *)

val failure_text : tab_failure -> string
(** The failure worded for the fence's fallback line. *)

type boundary = Barline | Continuation

type fragment = private {
  bar : int;
  source : Masc_tui_alphatex_score.measure;
  beats : Masc_tui_alphatex_score.beat list;
  left : boundary;
  right : boundary;
}
(** A read-only span of an original physical bar. [source] and every beat
    retain their original objects, tick positions, durations and notes.
    [Barline] means the original edge, including its repeat/ending marks;
    [Continuation] means a display break within that same bar. *)

val layout : max_width:int -> Masc_tui_alphatex_score.t ->
  (fragment list list, tab_failure) result
(** The immutable reading plan consumed by [render_tab]. Every original beat
    occurs exactly once, in order and on its original physical bar. Only
    original bar edges carry repeat/ending signs. A beat too wide even on
    its own refuses the whole reading before drawing allocates any rows. *)

val render_tab :
  ?rhythm:bool -> max_width:int -> string -> (string list, tab_failure) result
(** [render_tab ~max_width source] is the score's tablature, system after
    system -- or why the fence should show the source instead. Each system
    is a row of measure numbers above the strings, then one line per string,
    highest string first; a blank line sits between systems. Ahead of the
    first system, one header line names what the directives said
    ([♩=96 · 4/4 · "Riff"]); a score whose directives said none draws no
    header line.

    [~rhythm:true] adds one more line under the lowest string, naming each
    beat's length at its first cell: [w h q e s] for the whole, half,
    quarter, eighth and sixteenth the reader's subset allows. The cells are
    the measures' own, the same columns the frets sit in, and the beat a
    subset later outgrows draws blank rather than a wrong letter. The
    default is [false]: a fence that never asks for the line draws the same
    tab as before, cell for cell. *)
