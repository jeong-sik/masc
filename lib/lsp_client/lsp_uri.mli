(** [file://] URIs, the only spelling LSP has for a path.

    Both directions go through [Uri] rather than through string surgery, so a
    path with a space or a [#] survives the round trip. *)

(** The path a [file://] URI names, percent-decoded. A URI with any other
    scheme, or with a host that is not this machine, is returned unchanged —
    callers decide what to do with a string that is not a local path, and
    containment checks reject it. *)
val path_of_file_uri : string -> string

(** The [file://] URI for an absolute path. *)
val file_uri_of_path : string -> string
