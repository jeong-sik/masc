(** Per-runtime-lane capacity gate — fail-fast admission.

    Limits concurrent keeper turns per runtime lane (provider+model binding).
    See {!Runtime_lane_capacity} for full documentation. *)

type rejection =
  { lane_key : string
  ; limit : int
  ; inflight : int
  }

type acquired = { release : unit -> unit }

(** Acquire a lane capacity permit.  Returns [Error rejection] immediately
    when the lane is at capacity; [Ok acquired] on admission.
    The caller must call [acquired.release] exactly once.

    No blocking, no timeout — OAS already enforces its own timeout on the
    provider call. *)
val acquire_lane_capacity :
  lane_key:string -> max_concurrent:int -> (acquired, rejection) result

(** Convenience wrapper: acquire, run [f], release in finally.
    On rejection, returns [Error rejection] without calling [f]. *)
val with_lane_capacity :
  lane_key:string -> max_concurrent:int -> (unit -> 'a) -> ('a, rejection) result

(** Current inflight count for a lane key (test access). *)
val inflight_for_test : string -> int

(** Clear all lane counters (test teardown). *)
val reset_for_test : unit -> unit
