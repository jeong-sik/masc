(** The XML of the parts detection reads: [_rels/.rels],
    [[Content_Types].xml] and [META-INF/manifest.xml].

    xmlm reads it in one pass, in time linear in its length; the checks below
    run inside that pass. *)

type name = string * string
(** A namespace URI and a local name. *)

type element =
  { name : name
  ; attributes : (name * string) list
  ; depth : int  (** [0] for the root. *)
  }

val elements : string -> (element list, string) result
(** The elements of a document in document order, the root first.

    [Error] at the first of these: bytes that are not well-formed XML in
    UTF-8, UTF-16, ISO-8859-1 or US-ASCII; a document type declaration; an
    entity other than the five predefined ones; one element giving the same
    attribute twice; anything but comments, processing instructions or white
    space after the root. *)

val attribute : string -> element -> string option
(** The value of the attribute with this local name and no namespace. *)
