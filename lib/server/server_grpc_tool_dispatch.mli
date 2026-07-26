(** Private transport seam that rejects invalid gRPC tool arguments before
    invoking the production dispatcher. *)
val dispatch :
  dispatch:(Yojson.Safe.t -> ('a, string) result) ->
  string ->
  ('a, string) result
