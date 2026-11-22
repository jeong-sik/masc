(** Explicit observation state for server-sourced values.

    Distinguishes loading, present values (fresh or stale), explicitly absent
    items, metrics unreported by the provider/backend, and structured fetch
    failures so missing data is never collapsed to [0] or [""]. *)

type 'a t =
  | Loading of { since_ns : Clock.Mono.t }
  | Value of { data : 'a; observed_at : Clock.Mono.t; stale : bool }
  | Absent
  | Unreported
  | Failed of { reason : string; retryable : bool; at : Clock.Mono.t }

val loading : since_ns:Clock.Mono.t -> 'a t
val value : observed_at:Clock.Mono.t -> ?stale:bool -> 'a -> 'a t
val absent : 'a t
val unreported : 'a t
val failed : reason:string -> retryable:bool -> at:Clock.Mono.t -> 'a t

val map : ('a -> 'b) -> 'a t -> 'b t
val bind : 'a t -> ('a -> 'b t) -> 'b t

val to_option : 'a t -> 'a option
(** [Some data] only for [Value _]; [None] for [Loading], [Absent],
    [Unreported], and [Failed]. *)

val is_loading : 'a t -> bool
val is_value : 'a t -> bool
val is_stale : 'a t -> bool
val mark_stale : 'a t -> 'a t

val observed_at : 'a t -> Clock.Mono.t option
(** [Some observed_at] for [Value _]; [None] for all other states. *)

val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool
