(** The rows the help overlay draws, and the height it draws them in.

    The overlay folds its lines into two columns once the terminal is wide
    enough, so what it draws is fewer rows than it was written as. The key
    handler bounded the scroll with the line count and no height at all, and
    the drawing clamped the result on the way past -- the shape
    {!Masc_tui_scroll} was written to end. On a wide terminal the sheet
    stopped at its last row while the state counted on to twice that, so
    scrolling back up paid off the surplus one press at a time before the
    reader saw anything move.

    Both sides ask this module now, so they answer with the same number. *)

val line_cells : cols:int -> int
(** The cells one sheet line has at this width: the frame's inner width while
    the sheet is one column, a column's width once it is two. Lines wider than
    this are cut where they are drawn, so the lines are wrapped to it first. *)

val two_column_minimum_cols : int
(** The terminal width where [sheet] folds to two columns; the frame folds
    at the same width so its height answer matches what it draws. *)

val column_width : cols:int -> int
(** The cells one column of the folded sheet has. The feature sheet folds to
    the same columns and draws its lines at the same width, so a reader sees
    one layout on both sheets. *)

(** One run of the sheet's rows that a column holds together. *)
type block =
  | Whole of string list
      (** A section with its heading, or a block such as the Candle details.
          A column sets a blank row ahead of it when another block is above. *)
  | Parted of { first : string list; rest : string list }
      (** One section whose keys {!one_section} parted: [first] is the heading
          and the keys before the cut, [rest] the keys after it. The two parts
          are one value, so the keys after a cut always follow their own
          heading. In one column [rest] runs straight on under [first]; when
          the columns are cut between them, [rest] opens the right column
          level with the first key of [first]. *)

val sheet : cols:int -> block list -> string list
(** The rows drawn at this width: the blocks down one column, or -- once a
    terminal is wide enough to hold two columns -- each block whole, the
    first ones down the left column and the rest down the right one, cut
    where the taller column is shortest. *)

val one_section : heading:string -> string list list -> block list
(** The blocks of a sheet that holds a single section. [entries] is each key's
    rows, a wrapped sentence kept with its key. {!sheet} sets whole blocks
    under its two columns, so one section alone would stand in the left
    column beside an empty right one; here the section's keys are parted at
    the key nearest the middle into one {!Parted} block. A sheet of one
    column draws the two parts as one section. A section whose keys do not
    part is {!Whole}. *)

val filter_sections :
  query:string ->
  heading:(string -> string) ->
  (string * (string * string) list) list ->
  (string * (string * string) list) list
(** The sections a typed query leaves, as (title, (key, action) entries). An
    entry stays when its key or its action holds [query], ignoring case. A
    section whose [heading title] holds [query] stays whole, and a section left
    with no entry goes. [heading] is the part of a title a reader would type: a
    title that carries a mark beside its name gives the name back, so the mark
    does not answer a query. An empty [query] leaves every section as it was. *)

(** {1 The [/] filter}

    The sheet filters its rows by a typed query. While the query is typed every
    printable key is text, so [h], [j], [g] and [?] reach the query and the
    sheet's own keys wait for Enter or Esc. *)

type filter =
  | Off
  | Typing of string
      (** The reader is typing the query; each printable key belongs to it. *)
  | Kept of string
      (** Enter settled the query; the sheet's own keys work again. *)

val filter_query : filter -> string
(** The query the filter holds; empty when it is [Off]. *)

(** {1 How much the sheet lists}

    The sheet opens on the keys of the screen it was opened from and nothing
    else. It listed every screen, the global keys and the slash commands
    behind that one section -- more than six hundred rows -- so a reader who
    paged past the end of their own screen's keys was among another screen's,
    with no line saying so. *)

type scope =
  | Here  (** The keys of the screen the sheet was opened from. *)
  | Everything
      (** Every screen's keys, the global keys and the slash commands. *)

val shows_everything : filter -> scope -> bool
(** Whether the sheet lists every section. A typed query always does: a
    reader looking for a key by name is not asking about one screen. *)

type step =
  | Set_filter of { filter : filter; scroll_to_top : bool }
      (** The filter becomes [filter]. A different query is a different sheet,
          so [scroll_to_top] is set when the query changed or cleared. *)
  | Widen  (** List every section; [?] pressed on the one-screen sheet. *)
  | Close  (** Close the sheet. *)
  | Toggle_hints  (** Show or hide the footer hints for this session. *)
  | Scroll of Masc_tui_scroll.key_move
      (** Move the sheet by what the key asks of every scrolled body: a row, a
          page, or the top or the end. While a query is typed the arrows and
          the page keys scroll; every other key is text or does nothing. *)
  | Ignore  (** The key does nothing in this state. *)

val step : filter -> scope:scope -> key:string -> step
(** What one key does to the open sheet. [?] widens the one-screen sheet and
    closes the sheet that already lists everything. Esc clears a kept query
    before it closes the sheet. A Hangul key typed into the query is read back as the
    letters that were pressed (see {!Masc_tui_key_ime.latin_text}); the sheet's
    keys and nearly all of its wording are English. Enter, or a line feed from
    a terminal that sends one for Return, settles a non-empty query and clears
    an empty one. *)
