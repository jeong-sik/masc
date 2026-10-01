(** Client catalog authority for a declared nominal context window. This is
    distinct from the smaller input window the client reserves for inference. *)
type admitted = { requested : int; maximum : int option; usable_input : int option }
type error =
  | Invalid_catalog of string
  | Requested_above_maximum of { model : string; requested : int; maximum : int }
(** [usable_input = None] means the catalog has no row for this provider model.
    The client supplies fallback metadata; absence is not a model refusal. *)
val resolve : model:string -> requested:int -> Yojson.Safe.t -> (admitted, error) result
val error_to_string : error -> string
