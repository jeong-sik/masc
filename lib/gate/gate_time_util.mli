(** ISO-8601 timestamp helpers local to [masc_gate].

    Kept here so the library does not depend on
    [lib/server/server_utils.ml] (HTTP types) nor on [lib/types/]
    (which would drag the whole [masc_types] surface in for a 17-line
    helper). When Gate moves out of the MASC monolith (Track B4), the
    remaining external deps reduce to yojson/eio/unix/fs_compat. *)

val iso8601_of_unix : float -> string
(** Format a Unix epoch timestamp as ["YYYY-MM-DDTHH:MM:SSZ"] (UTC). *)

val parse_iso8601_opt : string -> float option
(** Parse ["YYYY-MM-DDTHH:MM:SSZ"] back to a Unix epoch. Behavior is
    byte-identical to [Masc_domain.parse_iso8601_opt] (intentional fork to
    sever the [masc_types] dependency). *)
