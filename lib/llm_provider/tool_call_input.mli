(** Shared completed tool-call input boundary.

    Provider codecs may carry a completed tool input as JSON or JSON text. The
    SDK accepts only a JSON object; other JSON values are not executable tool
    arguments. Carrier-specific absence policy stays at each codec boundary. *)

type parse_error =
  | Invalid_json of string
  | Not_object

val validate_object : Yojson.Safe.t -> (Yojson.Safe.t, parse_error) result
val parse_object : string -> (Yojson.Safe.t, parse_error) result
