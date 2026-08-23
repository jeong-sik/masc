(** The `---` block at the top of a markdown file, read one way.

    Consumers used to carry their own copy of this and disagreed about the
    delimiter: an exact [ "---" ] match sees no frontmatter in a CRLF file,
    a trimmed one does. Same file, different metadata, depending on who read
    it. *)

type t =
  { fields : (string * string) list
        (** Keys and values in the order they appeared. A line without [:] is
            skipped; a key trims to empty is skipped. *)
  ; body : string  (** Everything after the closing delimiter. *)
  }

val parse : string -> t
(** No opening delimiter means no frontmatter: [fields] is empty and [body] is
    the whole input. A missing closing delimiter consumes the rest as fields
    and leaves [body] empty. Delimiter lines are compared after trimming, so
    CRLF and trailing spaces read the same as a bare [---]. *)

val has_frontmatter : string -> bool
(** Whether the first line is a delimiter, without parsing the rest. *)

val field : t -> string -> string
(** The value for [name], or [""] when absent. *)

val list_field : t -> string -> string list
(** [name: \[a, b, c\]] and [name: a, b, c] both split and trim to the same
    list. An absent or empty value answers [[]]. *)
