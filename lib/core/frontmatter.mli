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

type block =
  | Absent  (** The first line is not a delimiter. *)
  | Unclosed  (** An opening delimiter with no closing one after it. *)
  | Closed of t

val read : string -> block
(** Delimiter lines are compared after trimming, so CRLF and trailing spaces
    read the same as a bare [---]. *)

val parse : string -> t
(** {!read} for a caller that does not need to tell the cases apart: [Absent]
    and [Unclosed] both answer empty [fields] with the whole input as [body]. *)

val list_value : string -> string list
(** A field value read as a list: [\[a, b, c\]] and [a, b, c] both split and
    trim to the same list, and [""] and [\[\]] both answer [[]]. It takes the
    value, not the field name: the caller has already looked the field up
    in [fields] and decides what an absent field means. *)
