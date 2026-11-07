(** Gate timestamp adapters over the shared RFC 3339 codec. *)

val iso8601_of_unix : float -> string
(** Format a Unix epoch timestamp as ["YYYY-MM-DDTHH:MM:SSZ"] (UTC). *)
