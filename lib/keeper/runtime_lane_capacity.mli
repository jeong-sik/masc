(** Per-runtime-lane capacity gate.

    Limits concurrent keeper turns per runtime lane (provider+model binding).
    See {!Runtime_lane_capacity} for full documentation. *)

type rejection =
  { lane_key : string
  ; limit : int
  ; inflight : int
  ; waited_ms : int
  }

type acquired =
  { release : unit -> unit
  ; wait_ms : int
  }

(** Acquire a lane capacity permit, blocking up to [timeout_s] if full.
    Returns [Error rejection] on timeout, [Ok acquired] on admission.
    The caller must call [acquired.release] exactly once. *)
val acquire_lane_capacity :
  lane_key:string -> max_concurrent:int -> timeout_s:float ->
  (acquired, rejection) result

(** Convenience wrapper: acquire, run [f], release in finally.
    On admission, [f] receives [~capacity_wait_ms] for observability.
    On rejection, returns [Error rejection] without calling [f]. *)
val with_lane_capacity :
  ?timeout_s:float ->
  lane_key:string ->
  max_concurrent:int ->
  (capacity_wait_ms:int -> 'a) ->
  ('a, rejection) result

(** Current inflight count for a lane key (test access). *)
val inflight_for_test : string -> int

(** Clear all lane counters (test teardown). *)
val reset_for_test : unit -> unit
