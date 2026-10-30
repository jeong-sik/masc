(** Result monadic binding operators for the llm_provider library. *)

val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
val ( let+ ) : ('a, 'e) result -> ('a -> 'b) -> ('b, 'e) result
val both : ('a, 'e) result -> ('b, 'e) result -> ('a * 'b, 'e) result
val ( and* ) : ('a, 'e) result -> ('b, 'e) result -> ('a * 'b, 'e) result
val ( and+ ) : ('a, 'e) result -> ('b, 'e) result -> ('a * 'b, 'e) result
