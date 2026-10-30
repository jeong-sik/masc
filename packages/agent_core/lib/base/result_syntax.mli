(** Result monadic binding operators.

    Open this module in files that use [let*] and [let+] for
    {!Result}-based computation chains. Also provides {!Let_syntax}
    for [ppx_let] ([let%bind], [let%map]) support.

    {2 Usage}

    {[
    open Result_syntax

    let compute x =
      let* a = parse x in
      let* b = validate a in
      let+ c = transform b in
      Ok c
    ]}

    @since 0.187.7
    @stability Stable *)

(** Alias for {!Result.bind}. Sequential bind. *)
val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result

(** Alias for [Result.map f]. Sequential map. *)
val ( let+ ) : ('a, 'e) result -> ('a -> 'b) -> ('b, 'e) result

(** Parallel accumulate — both must succeed. *)
val ( and* ) : ('a, 'e) result -> ('b, 'e) result -> ('a * 'b, 'e) result

(** Parallel accumulate — both must succeed. *)
val ( and+ ) : ('a, 'e) result -> ('b, 'e) result -> ('a * 'b, 'e) result

(** ppx_let integration module.

    Provides [bind], [map], [return], and [both] for [let%bind] /
    [let%map] / [and%bind] expansion. *)
module Let_syntax : sig
  val return : 'a -> ('a, 'e) result
  val bind : ('a, 'e) result -> f:('a -> ('b, 'e) result) -> ('b, 'e) result
  val map : ('a, 'e) result -> f:('a -> 'b) -> ('b, 'e) result
  val both : ('a, 'e) result -> ('b, 'e) result -> ('a * 'b, 'e) result
end
