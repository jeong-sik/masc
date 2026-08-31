(** Tokenizers for source code — the chat's fenced blocks and the Code
    surface share them.

    The lexers are tokenizers, not parsers: a keyword is the identifier the
    OCaml manual reserves, a comment is the marker pair and everything it
    encloses, and nothing needs the grammar to be valid to be coloured. They
    read a whole body at once because the state that decides a token's kind
    — a comment opened three rows up, a string open across a line break —
    does not exist inside a single row. *)

type segment = string * string
(** One run of characters and the kind that colours it. Kinds are the strings
    the markdown palette already names. *)

val kind_code : string
val kind_keyword : string
val kind_string : string
val kind_comment : string
val kind_number : string
val kind_type : string

val kind_diff_added : string
(** A ["```diff"] line that adds. Whole-line rather than token-shaped: the
    first cell decides the line, and no run ends in the middle of one. *)

val kind_diff_removed : string
(** The same fence's removing line. *)

val ocaml_lexer : string -> segment list
val bash_lexer : string -> segment list
val c_like_lexer : string -> segment list
val python_lexer : string -> segment list

val lexer_of_language : string -> (string -> segment list) option
(** ["ocaml"|"ml"|"mli"], ["bash"|"sh"|"shell"|"zsh"], ["json"]. An unknown
    tag answers [None] and the caller keeps the plain span — a guess at the
    grammar is colouring as pretence. *)

val language_of_path : string -> string option
(** The language a file's extension names, for extensions whose language has
    a lexer here. Mirrors the server's [Lsp_process_manager.lang_of_path]. *)

val rows_of_segments : segment list -> segment list list
(** Segments cut into rows at the newlines the lexer carried as plain text.
    Piece order inside a row is the lexer's order. *)

val rows_of_source : language:string option -> string -> segment list list
(** A whole file, lexed once and split into rows. [None] or an unlexed
    language keeps every row a single plain-code segment. *)

val row_has_assignment : segment list -> bool
(** True when a lexed configuration row contains an equals sign in code,
    rather than inside a string or comment. This is a navigation fact; the
    server-side parser remains the write authority. *)
