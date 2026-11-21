(** Rows that only grow at their end, read by length.

    A writer appends to one {!t}. A reader holds a {!prefix}: the writer and
    the length it had then. A later append never changes the cells below a
    prefix's length, so a prefix taken on one frame reads the same on every
    later one. The writer's cells grow by doubling; the cells below a length
    are copied into the new array before it replaces the old one.

    One domain appends to a [t]. A prefix read on that domain sees its cells.
    *)

type 'a t

type 'a prefix

val create : unit -> 'a t

val append : 'a t -> 'a -> unit

val prefix : 'a t -> 'a prefix
(** The cells appended so far. *)

val of_array : 'a array -> 'a prefix
(** A prefix of all of [cells], which the caller does not change again. *)

val empty : unit -> 'a prefix

val length : 'a prefix -> int

val get : 'a prefix -> int -> 'a
(** [get prefix index] for [0 <= index < length prefix]; raises
    [Invalid_argument] otherwise. *)

val extends : 'a prefix -> kept:'a prefix -> bool
(** [prefix] comes from the same writer as [kept] and is at least as long, so
    its first [length kept] cells are [kept]'s. *)

val same : 'a prefix -> 'a prefix -> bool
(** The same writer and the same length. *)

val to_list : 'a prefix -> 'a list

val sub_list : 'a prefix -> start:int -> stop:int -> 'a list
(** The cells [start] to [stop - 1], clamped to the prefix. *)
