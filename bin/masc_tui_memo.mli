(** The memos in an open file, read off its rows.

    A row carries a memo when the whole row is one comment and that comment
    reads as {!Ide_memo}'s grammar. A comment after code on the same row is
    a comment about that code, in whatever words, and is left alone.

    Which rows count as a comment depends on what the TUI knows about the
    file. Where it has a lexer, the lexer's answer is the one to use: it
    carries the state a single row does not, so a marker-shaped line inside
    a string literal is a string and not a memo. Where it has none, the
    file's own comment markers decide, which is how a language the TUI does
    not colour -- Lua, Markdown -- still shows the memos a keeper wrote
    into it. *)

type found =
  | Memo_at of int * Ide_memo.t  (** 1-based line, the number the gutter draws *)
  | Broken_at of int * string
      (** A comment that starts as a memo and does not finish one, with
          the reason. Listed so the writer sees it. *)

val line_of : found -> int

type reader =
  | Lexed  (** the lexer marks this file's comments *)
  | By_markers of Ide_memo.markers  (** it does not, so the markers do *)

val of_rows : reader:reader -> Masc_tui_code_lexer.segment list list -> found list
(** In row order. A trailing carriage return, which the wire escapes rather
    than send to a terminal, is not part of the comment. *)

val of_file : path:string -> Masc_tui_code_lexer.segment list list -> found list
(** {!of_rows} with the reader [path] calls for. A file the TUI can neither
    lex nor spell a memo in yields nothing. *)
