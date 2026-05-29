(** ISO-8601 timestamp helpers — canonical source is [Masc_domain]. *)

let iso8601_of_unix = Masc_domain.iso8601_of_unix_seconds

let parse_iso8601_opt = Masc_domain.parse_iso8601_opt
