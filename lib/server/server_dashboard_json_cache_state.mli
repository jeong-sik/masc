(** Immutable entry state for the dashboard provider-run caches. The caller
    owns the bounded table, lock, clock, computation and response projection. *)

type t
type owner
(** Exact identity of one admitted refresh. Identity is allocated by [start]
    and never mutated; callers cannot manufacture or reuse an idle entry as
    refresh authority. *)

type view =
  | Fresh of { json : Yojson.Safe.t; age_s : float }
  | Stale of
      { json : Yojson.Safe.t
      ; age_s : float
      ; last_error : string option
      }
  | Warming of { last_error : string option }
(** [last_error = None] means no ordinary refresh failure is retained.
    Cancellation does not create an error or change the measurement age. *)

type start_plan

type admission =
  | Reuse of view
  | Refresh of view * start_plan

val empty : t
val updated_at : t -> float
(** The last successful refresh timestamp; [0.] before the first success.
    This preserves the existing least-recently-refreshed eviction policy. *)

val admit : now:float -> ttl_s:float -> t -> admission
(** Pure read and admission decision. Fresh values are reused, including when
    a refresh is already active. Stale or cold entries with an active owner
    are also reused; an idle stale/cold entry yields a start plan.

    The caller keeps admission, [start] and table replacement under one lock. *)

val start : start_plan -> t * owner
(** Allocate one exact refresh identity and return its immutable entry state.
    This identity allocation is the only generative operation in this module;
    there is no clock, I/O, lock or computation here. *)

val settle :
  owner:owner -> now:float -> (Yojson.Safe.t, string) result -> t -> t option
(** [Some state] settles only the entry's current exact owner. Success replaces
    the payload and freshness time and clears the last error. Failure retains
    the payload/time and records the supplied error. [None] means the entry is
    idle or belongs to another refresh and must remain unchanged. *)

val cancel : owner:owner -> t -> t option
(** Release only the matching owner, preserving payload, successful-refresh
    time and prior failure evidence. [None] has the same meaning as [settle].
    An evicted key is never restored: the caller first looks up the current
    table entry and applies this transition only if that entry still exists. *)
