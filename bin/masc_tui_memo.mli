(** The memos in an open file, read off its rows in the file's own comment
    syntax.

    A row carries a memo when the whole row is one comment in the markers
    the writer ({!Lsp_process_manager.memo_line}) would use for that file,
    and the comment reads as {!Ide_memo}'s grammar. A comment after code on
    the same row is a comment about that code, in whatever words, and is
    left alone. The rows come from {!Masc_tui_code_lexer}, but the reader
    does not need the lexer to know the language: it joins each row's text
    back and looks for the markers, so a Lua or Markdown file reads the
    same as an OCaml one. *)

type found =
  | Memo_at of int * Ide_memo.t  (** 1-based line, the number the gutter draws *)
  | Broken_at of int * string
      (** A comment that starts as a memo and does not finish one, with
          the reason. Listed so the writer sees it. *)

val line_of : found -> int

val of_rows : markers:Ide_memo.markers -> Masc_tui_code_lexer.segment list list -> found list
(** In row order, reading only rows that open with [markers] (and, for a
    block marker, close on the same row). *)

val of_file : path:string -> Masc_tui_code_lexer.segment list list -> found list
(** {!of_rows} with the markers {!Lsp_process_manager.memo_markers_of_path}
    gives [path]. A file the writer would refuse -- an extension no language
    here covers, or JSON -- yields nothing, so the list is exactly what the
    writer could have put there. *)
