(** Gate timestamp adapters over the shared RFC 3339 codec. *)

let iso8601_of_unix = Time_codec.rfc3339_of_unix

let parse_iso8601_opt value = Time_codec.parse_rfc3339_opt value
