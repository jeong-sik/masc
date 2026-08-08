type error =
  | Unsupported_keyword of string
  | Unsupported_type of string
  | Invalid_schema

val validate : path:string -> Yojson.Safe.t -> (unit, error) result
