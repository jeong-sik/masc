(** Bounded ring buffer of [Cascade_client_capacity] acquire / release /
    rejected-when-full events, for dashboard observability.

    Phase A ({!Cascade_client_capacity}) introduced the process-local
    semaphore.  Phase D ({!Dashboard_cascade.client_capacity_json})
    exposed the *current* snapshot.  Operators still could not answer
    "how often was the ollama slot full in the last hour?" — this
    module fills that gap by recording every transition and surfacing
    recent events via {!snapshot}.

    Contracts:
    - Size is fixed at init, read from [MASC_CAPACITY_HISTORY_SIZE]
      (default 1024, clamped to [[16, 65536]]).  Changing the env after
      first use has no effect; the ring is lazily initialised once.
    - Drop-oldest on overflow: recording into a full ring overwrites
      the oldest slot in place, no allocation on steady state.
    - [record] and [snapshot] are thread-safe via a plain stdlib
      [Mutex] (matches {!Cascade_client_capacity}'s locking style; see
      memory/feedback_ocaml5-mutex-selection for the same-domain Eio.Mutex
      deadlock risk that pushed us to stdlib Mutex here).
    - [snapshot] returns events newest-first so the dashboard can
      render without a reverse pass.

    @since 0.9.9 *)

(** Event kind surfaced to the dashboard.  [Acquired] / [Released] are
    self-explanatory; [Rejected_full] captures the "slot full, caller
    moved on to the next candidate" case that operators use as the
    saturation signal. *)
type event_kind = Acquired | Released | Rejected_full

(** One transition in the capacity semaphore.

    [ts] is a Unix timestamp (seconds).
    [key] is the registry key (URL or CLI sentinel) as accepted by
    {!Cascade_client_capacity.register}.
    [active_after] is the value of the atomic counter *after* the
    event took effect:
    - [Acquired]: counter after the successful CAS ([old + 1]).
    - [Released]: counter after [Atomic.fetch_and_add ... (-1)]
      completes ([old - 1]).
    - [Rejected_full]: counter at the moment of rejection (unchanged
      — the caller did not touch the counter). *)
type event = {
  ts : float;
  key : string;
  kind : event_kind;
  active_after : int;
}

val record : event -> unit
(** Append [event] to the ring.  Drops the oldest entry if the ring
    is full.  Safe to call from multiple fibers/domains; serialised
    via a stdlib [Mutex]. *)

val snapshot : ?limit:int -> ?kind:string -> ?since_ts:float -> unit -> event list
(** Newest-first snapshot of recorded events.

    @param limit  maximum number of events returned (default 100,
           clamped to the ring's current count).
    @param kind   filter by dashboard classification — one of
           ["cli"], ["ollama"], ["other"].  Unknown values return
           [[]]; omitting the argument returns every kind.  The
           classifier matches {!Dashboard_cascade}'s [classify_capacity_key]
           (copy-paste rather than a shared helper — both are ~12
           lines and we did not want the new module to depend on
           [Dashboard_cascade]).
    @param since_ts  keep only events with [ts >= since_ts].
           Omitting returns every timestamp.

    The three filters compose: if all three are given, the result
    is the intersection.  Events are returned newest-first after
    filtering; the [limit] is applied last. *)

val clear : unit -> unit
(** Test helper: drop every recorded event and reset the write head. *)

val size : unit -> int
(** Test helper: current number of recorded events (≤ ring capacity). *)

val capacity : unit -> int
(** Test helper: the ring's fixed capacity as resolved from
    [MASC_CAPACITY_HISTORY_SIZE].  Useful for tests that want to
    overflow the ring without hardcoding the default. *)

val classify_key : string -> string
(** Same classification as {!Dashboard_cascade.classify_capacity_key}.
    Exposed for tests that want to assert ["cli"]/["ollama"]/["other"]
    labels without pulling in the dashboard module. *)
