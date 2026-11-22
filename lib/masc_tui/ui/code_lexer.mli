(** Pure syntax tokenizers for source code, diffs, JSON, TOML, YAML, SQL, and
    Markdown — painting directly onto {!Masc_tui_term.Cell_grid.t} using an
    explicit {!Masc_tui_core.Theme.t} (zero global refs, closed sum types). *)

module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Cell_grid = Masc_tui_term.Cell_grid

type token_kind =
  | Plain
  | Keyword
  | String
  | Comment
  | Number
  | Type_or_ctor
  | Json_key
  | Json_number
  | Json_literal
  | Json_punctuation
  | Diff_added
  | Diff_removed
  | Diff_hunk

type segment = {
  text : string;
  kind : token_kind;
}

type language =
  | Ocaml
  | Bash
  | Json
  | Diff of language option
  | Yaml
  | Toml
  | Sql
  | C_like
  | Python
  | Markdown

val equal_token_kind : token_kind -> token_kind -> bool
val equal_language : language -> language -> bool

val language_of_tag : string -> language option
(** Strict parser for fence info tags (e.g. ["ocaml"], ["diff:ocaml"], ["toml"],
    ["json"], ["ts"], ["py"]). Returns [None] for unknown tags. *)

val language_of_path : string -> language option
(** Strict language lookup from a file path extension. Returns [None] for
    unrecognized extensions. *)

val lex : language -> string -> segment list
(** Tokenize a full document preserving multi-line string/comment state. *)

val rows_of_segments : segment list -> segment list list
(** Split token segments into logical rows on ['\n'] while preserving order. *)

val rows_of_source : language:language option -> string -> segment list list
(** Normalize CRLF to LF, tokenize with [language] (or emit plain text when
    [None]), and split into rows. *)

val row_has_assignment : segment list -> bool
(** [true] when a lexed row contains ['='] outside strings and comments. *)

val style_of_token : theme:Theme.t -> bg:Color.t -> token_kind -> Style.t
(** Map a {!token_kind} to a WCAG AA compliant {!Style.t} from [theme]. *)

val draw_row :
  ?clip:Rect.t ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  max_w:int ->
  theme:Theme.t ->
  bg:Color.t ->
  segment list ->
  int
(** Paint one lexed row onto [Cell_grid.t] clipped to [max_w] columns. Returns
    columns advanced. *)
