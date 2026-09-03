(** Shared completed tool-call input boundary.

    Provider codecs may carry a completed tool input as JSON or JSON text. The
    Agent Core accepts only a JSON object; other JSON values are not executable
    tool arguments. Carrier-specific absence policy stays at each codec
    boundary.

    A repeated object key is resolved here rather than carried inward: the
    first binding wins -- the one [Yojson.Safe.Util.member] already reads, so
    the executed arguments do not change -- and every later binding of that
    name is dropped. Downstream then holds an input the checkpoint encoder can
    store, instead of one it refuses after the tool has run (#31677). *)

type parse_error =
  | Invalid_json of string
  | Not_object

val validate_object
  :  Yojson.Safe.t
  -> (Yojson.Safe.t * string list, parse_error) result
(** [validate_object json] accepts a JSON object and returns it with repeated
    keys resolved, together with the names that were dropped (in the order the
    provider sent them, nested occurrences included). An empty list means the
    provider bound every key once. *)

val parse_object : string -> (Yojson.Safe.t * string list, parse_error) result
(** [parse_object raw] parses [raw] and applies [validate_object]. *)
