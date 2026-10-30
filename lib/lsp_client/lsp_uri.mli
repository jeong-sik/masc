(** [file://] URIs, the only spelling LSP has for a path.

    Both directions go through [Uri] rather than through string surgery, so a
    path with a space or a [#] survives the round trip. *)

(** The path a [file://] URI names, percent-decoded. A URI with any other
    scheme, or with a host that is not this machine, is returned unchanged —
    callers decide what to do with a string that is not a local path, and
    containment checks reject it. *)
val path_of_file_uri : string -> string

(** The [file:///] URI for an absolute path, with an explicit empty authority. *)
val file_uri_of_path : string -> string

(** Whether [Uri]'s parsed local file values name the same decoded absolute path.
    Accepts omitted/empty/localhost authority and percent-encoding differences.
    Parsed remote hosts, other schemes, credentials, ports, queries and fragments
    do not match. This is notification correlation, not URI syntax validation or
    filesystem admission. Does not resolve symlinks or fold path case. *)
val same_local_document : string -> string -> bool
