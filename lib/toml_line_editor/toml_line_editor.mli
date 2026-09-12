(** Comment-preserving, line-based TOML editing.

    The editor updates selected table keys without parsing and re-emitting the
    whole file, so comments, blank lines, and unrelated table content remain
    byte-for-byte stable. *)

val escape_string : string -> string
(** Escape a TOML basic string payload. *)

val scalar_line : key:string -> value:string -> string
(** Render [key = "value"]. *)

val string_array_line : key:string -> values:string list -> string
(** Render [key = ["a", "b"]] on one line. *)

val split_lines : string -> string list * bool
(** Split content into lines and whether it ended with a trailing newline. *)

val join_lines : string list -> trailing_newline:bool -> string
(** Join lines, optionally restoring a final newline. *)

type header =
  | Table of string list
  | Table_array of string list
(** A table header by the key path the TOML grammar reads out of it: [Table]
    for [[a.b]], [Table_array] for [[[a.b]]]. Keys are unescaped. *)

val header_of_line : string -> header option
(** The header [line] opens, when the line parses on its own as one empty
    table and nothing else. Whitespace, quoting and a trailing comment are
    the grammar's to read; a line that does not parse alone is [None]. *)

val is_table_header : string -> bool
(** Return [true] when [header_of_line line] is a header of either kind. *)

val is_table : path:string -> string -> bool
(** Return [true] when [line] opens the standard table [[path]], compared by
    the key path the grammar reads from each. *)

val split_at : int -> 'a list -> 'a list * 'a list
(** Split a list at [n], returning [(prefix, suffix)]. *)

val find_index : ('a -> bool) -> 'a list -> int option
(** Return the zero-based index of the first matching element. *)

val key_of_line : string -> string option
(** Return the assignment key in a [key = value] line, if present. *)

val edit_table_scalar :
  string -> path:string -> key:string -> value:string option -> string
(** Set or remove a scalar key inside [[path]]. [key] is the raw literal name;
    rendering quotes punctuation such as dots, while lookup compares that name. *)

val edit_table_multiline_array :
  string -> path:string -> key:string -> values:string list -> string
(** Set a multi-line string array key inside [[path]]. *)

val edit_table_int : string -> path:string -> key:string -> value:int -> string
(** Set a typed integer while retaining unrelated lines and comments. *)

val edit_table_bool : string -> path:string -> key:string -> value:bool -> string
(** Set a typed boolean while retaining unrelated lines and comments. Bare
    [true]/[false], not a quoted string: a reader that expects a boolean
    refuses ["true"]. *)

(** {1 Array-of-tables entries} *)

type value =
  | String of string
  | Int of int
  | Float of float
  | Bool of bool
(** A typed entry field. One [\[\[a.b\]\]] entry mixes types — a voice endpoint
    carries [id] and [kind] strings, an [enabled] bool and a [timeout_seconds]
    float in the same table — so a writer that rendered every field as a string
    would quote the bool and the loader would refuse it by type. *)

val value_line : key:string -> value:value -> string
(** Render [key = value] in TOML's spelling for the type. A [Float] always keeps
    a point or an exponent, so it does not read back as an integer. *)

type entry_error =
  | Inline_key_at_path of string
      (** The parent table already assigns this path as a key. An empty endpoint
          list is spelled [endpoints = []] today, and opening
          [[[...endpoints]]] beside it makes the file refuse to load: a table
          duplicated by an array of tables. *)
  | Standard_table_at_path of string
      (** The path already exists as a standard table [[a.b]]. One path cannot
          be both spellings, and a line editor cannot merge them. *)

val entry_error_message : entry_error -> string

val is_table_array : path:string -> string -> bool
(** Return [true] when [line] opens the array-of-tables [\[\[path\]\]], compared
    by the key path the grammar reads from each. The array-of-tables counterpart
    of {!is_table}, which answers [false] for the same path. *)

val table_array_entry_ids : string -> path:string -> id_key:string -> string list
(** The [id_key] value of every [\[\[path\]\]] entry, in file order. An entry
    carrying no [id_key] line, or one whose value is not a string, is skipped:
    {!upsert_table_array_entry} cannot address it either. *)

val upsert_table_array_entry
  :  string
  -> path:string
  -> id_key:string
  -> id:string
  -> fields:(string * value option) list
  -> (string, entry_error) result
(** Set [fields] on the [\[\[path\]\]] entry whose [id_key] is [id], appending a
    new entry after the last existing one when no entry carries that id.

    Only the lines named in [fields] are written. Every other line in the entry —
    comments, blanks, fields not named — passes through unchanged, and a named
    field the entry does not have yet is appended to the end of its body.

    A field whose value is [None] is dropped from the entry, the way
    {!edit_table_scalar} removes a key. Switching an endpoint from a hosted
    provider to a local one has to drop [api_key_env]: left behind, it would
    send an Authorization header the local server never asked for, and the
    endpoint would answer 401 rather than fall through the chain.

    [id_key] is skipped if it also appears in [fields]: [id] is the one source of
    the entry's identity, and writing a second spelling of it from the field list
    would let the two disagree.

    Refused, writing nothing, when the path already exists in another shape --
    see {!entry_error}. A line editor can add an entry beside other entries; it
    cannot reconcile an array-of-tables with a key or a standard table of the
    same path, and producing a file the loader rejects is worse than saying so.

    Every entry carrying [id] is addressed, not only the first. Two entries
    claiming one id is already a configuration this editor cannot choose
    between, and applying to each keeps the call meaning what it says rather
    than picking one silently and leaving the other to be found later. *)

val remove_table_array_entry
  :  string
  -> path:string
  -> id_key:string
  -> id:string
  -> string
(** Drop the [\[\[path\]\]] entry whose [id_key] is [id]: its header, its body,
    and any table named under its path, which is that entry's own.

    Two things are left where they are. Comments above the header: an operator
    wrote them about the endpoint, nothing in the text says where that block
    begins, and the whisper endpoint in a live runtime.toml carries twelve lines
    of measured notes above its header -- a rule that swallowed them would
    delete the reason the setting exists. And a comment block sitting just above
    the NEXT header, with the blank lines separating it: that block documents
    the header below it, not this entry.

    Every entry carrying [id] is dropped, not only the first. *)
