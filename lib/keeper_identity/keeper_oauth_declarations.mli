(** Every provider declared under [config/identity/].

    One reader, because two would drift: an operator screen and a Keeper's
    turn have to agree about what is on offer, and they cannot if each walks
    the directory its own way.

    A file that cannot be read is carried rather than dropped. A shorter list
    with no reason for it is how an operator ends up reading code to find out
    why the provider they declared is not there. *)

type declaration =
  | Declared of Keeper_oauth_provider.t
  | Unreadable of { id : string; problem : string }

val id_of : declaration -> string

val all : unit -> declaration list
(** Sorted by id, so two screens list them the same way. *)

val find : string -> declaration option
