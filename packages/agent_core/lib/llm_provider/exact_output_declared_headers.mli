(** The fixed non-auth headers a deployment binding sends with every request
    ([providers.<id>.headers] plus the wire defaults the binding was built
    with). An exact-output request on that binding sends them as the binding's
    ordinary requests do.

    The exact plan writes the body bytes, so it writes [Content-Type] and
    [Content-Length] itself; a binding's entries under those two names are not
    carried. Credentials never appear here: they travel in the binding's key and
    are added by the plan as auth headers. *)
type t = private (string * string) list

(** A catalog-wire target has no binding, so it declares nothing. *)
val empty : t

(** The binding's [Provider_config.headers] in their declared order, without
    the entries the plan writes itself. *)
val of_binding_headers : (string * string) list -> t

val to_list : t -> (string * string) list

(** The header list of one exact-output request that carries [body]: the auth
    headers, then the binding's declared headers, then the [Content-Type] and
    [Content-Length] of [body]. An Anthropic request also gets the beta
    headers its body requires.

    The generation request and the count-tokens request sent before it are
    both written here, so they differ only in what follows from their bodies. *)
val request_headers
  :  kind:Provider_config.provider_kind
  -> auth_headers:(string * string) list
  -> body:string
  -> t
  -> (string * string) list
