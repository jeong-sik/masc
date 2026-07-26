(** Private transport seam that rejects invalid gRPC tool arguments before
    invoking the production dispatcher. *)
type error

val error_code : error -> Mcp_error_code.t
val error_message : error -> string

val dispatch :
  dispatch:(Yojson.Safe.t -> ('a, string) result) ->
  string ->
  ('a, error) result
