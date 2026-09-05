(** The memos in an open file, read off the rows the code lexer cut.

    A row carries a memo when its only non-blank segment is one comment
    token and that token reads as {!Ide_memo}'s grammar. A comment after
    code on the same row is a comment about that code, in whatever words,
    and is left alone. *)

type found =
  | Memo_at of int * Ide_memo.t  (** 1-based line, the number the gutter draws *)
  | Broken_at of int * string
      (** A comment that starts as a memo and does not finish one, with
          the reason. Listed so the writer sees it. *)

val line_of : found -> int

val of_rows : Masc_tui_code_lexer.segment list list -> found list
(** In row order. A file whose language has no lexer here yields nothing:
    without comment tokens there is no comment to read. *)
