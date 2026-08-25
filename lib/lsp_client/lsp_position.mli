(** Turning (file, 1-based line, symbol, occurrence) into the (line, column)
    a language server is asked at.

    One owner for the address arithmetic both askers share — the
    [keeper_code_query] tool and the REST question route. Positions are
    1-based at these seams, the way [Grep] and [Read] report them; the
    0-based conversion the protocol wants stays with the caller that built
    the request. *)

val line_of_file : path:string -> line_index:int -> (string, string) result
(** The line as the file holds it, so the column search is over the same
    bytes the language server will be given. [line_index] is 0-based. *)

val columns_of : line:string -> symbol:string -> int list
(** Every byte offset where [symbol] starts on [line]. Finding a column is
    not parsing — the language server still decides what the name means. *)

val column_of :
  line:string ->
  symbol:string ->
  occurrence:int ->
  line_number:int ->
  (int, string) result
(** The [occurrence]-th (1-based) start of [symbol] on [line]; the errors
    name what the line actually reads. [line_number] is only for the error
    text. *)

val language_of :
  path:string -> (Lsp_process_manager.language, string) result
(** The language a server covers for [path]'s extension, or which
    extensions are covered. *)

val project_root_of :
  language:Lsp_process_manager.language ->
  path:string ->
  boundary:string ->
  (string, string) result
(** The project root a server for [language] should be rooted at, kept
    inside [boundary]; the errors say why a root could not be chosen. *)
