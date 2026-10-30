(** Traced sections ([Eio.Private.Trace.with_span]) and the time their fibers
    run and wait. masc names every pool job this way (RFC-0474 L4c).

    A section counts the time of every fiber that runs inside it, including
    fibers created inside it. Sections nest: the time spent in a section is
    also spent in each section that encloses it, so a section's [run_ns] and
    [waits] never leave out the part spent in an inner section.

    Both are sums over the fibers of the section, not a split of its wall
    time. Fibers that run at the same time, or a parent that waits while a
    child waits on something else, count the same stretch of wall time more
    than once. *)

type span =
  { span_name : string
  ; span_domain : int
  ; enter_ns : int64
  ; mutable exit_ns : int64 option
  ; mutable run_ns : int64
        (** Time the section's fibers ran on their domain. *)
  ; waits : (string, int64) Hashtbl.t
        (** Time the section's fibers spent between suspending and running
            again, by suspend reason. *)
  ; parent : span option
        (** The section that was active when this one began. *)
  }

type book
(** The open sections of every fiber. *)

val create : unit -> book

val active : book -> int -> span option
(** The innermost open section of a fiber: its own, else the one it was
    created inside. *)

val inherit_from : book -> creator:int -> child:int -> unit
(** [child] was created while [creator] ran; it belongs to the section
    [creator] is in, if any. *)

val enter :
  book -> fiber:int -> domain:int -> name:string -> ts:int64 -> segment_start:int64 -> unit
(** A section begins on [fiber], which has been running since [segment_start].
    Only the part of that run after [ts] counts. *)

val leave : book -> fiber:int -> ts:int64 -> segment_start:int64 -> span option
(** The innermost own section of [fiber] ends at [ts]; the run it is in began
    at [segment_start]. Returns the finished section, or [None] when the fiber
    has none open. *)

val ran : book -> fiber:int -> dur:int64 -> unit
(** [fiber] ran for [dur] and stopped. Every open section around it counts the
    whole of [dur]. *)

val waited : book -> fiber:int -> reason:string -> dur:int64 -> unit
(** [fiber] waited [dur] on [reason] and runs again. Every open section around
    it counts the whole of [dur]. *)
