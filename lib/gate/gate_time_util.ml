(** Gate timestamp adapters over the shared RFC 3339 codec. *)

let iso8601_of_unix = Time_codec.rfc3339_of_unix
