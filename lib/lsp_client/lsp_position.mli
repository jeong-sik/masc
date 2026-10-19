(** Turning (file, 1-based line, symbol, occurrence) into the (line, column)
    a language server is asked at.

    One owner for the address arithmetic both askers share — the
    [keeper_code_query] tool and the REST question route. Requested lines and
    occurrences are 1-based, the way [Grep] and [Read] report them. Callers
    convert the line to zero-based; {!column_of} already returns the
    zero-based UTF-16 character offset used by the protocol. *)

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
(** The [occurrence]-th (1-based) start of [symbol] on [line], expressed as a
    zero-based UTF-16 code-unit offset for the question pool's LSP requests.
    Unlike {!columns_of}, this is not a byte offset or terminal-cell column.
    Invalid UTF-8 in the line or symbol is refused before dispatch. The errors
    name what the line actually reads. [line_number] is only for error text. *)

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
