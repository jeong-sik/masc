(** The Keeper that made the tool call a dispatch observer is looking at.

    A dispatch observer receives only the outcome and the result.  The Keeper
    name is not in either, so a caller that knows it binds it for the span of
    the call and an observer reads it back.  The binding lives in the calling
    fiber and in every fiber forked inside it.

    A call made outside any binding has no Keeper.  {!current_keeper} then
    returns [None], and callers keep that as "not observed" instead of
    inventing a name. *)

(** [with_keeper name f] runs [f ()] with [name] as the calling Keeper. *)
val with_keeper : string -> (unit -> 'a) -> 'a

(** [current_keeper ()] is the Keeper bound by the nearest enclosing
    {!with_keeper}, or [None] when there is none.  It must run inside an Eio
    fiber. *)
val current_keeper : unit -> string option
