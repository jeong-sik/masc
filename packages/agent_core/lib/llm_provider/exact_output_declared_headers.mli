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
