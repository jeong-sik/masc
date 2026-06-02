(** Per-gate attribution ring buffer backing the [/attribution] dashboard.

    In-process, mutex-protected FIFO keyed by the attribution [gate]. The
    buffer caps itself at a small bounded window per gate so recording is
    O(1) amortized and memory stays bounded regardless of emit volume.

    This is the *collector* side of the Layer 4 dashboard pipeline: producers
    call {!record} from their gate sites (after producing an [Attribution.t]
    via the gate's [to_attribution]), and the REST/SSE endpoints read from
    {!recent} and {!summary}.

    Cross-domain: guarded by [Stdlib.Mutex]. Eio fibers may call these
    functions directly; the critical section is short (queue push or fold).

    @since 2.264.0 *)

val record : Attribution.t -> unit
(** [record attr] appends [attr] to its gate's ring. Thread-safe. When the
    per-gate cap is reached, the oldest entry is dropped. *)

val recent :
  ?gate:string -> ?limit:int -> unit -> (Attribution.t * float) list
(** [recent ?gate ?limit ()] returns up to [limit] most recent events,
    newest first. Each tuple is [(attribution, recorded_at)] where
    [recorded_at] is [Unix.gettimeofday] at {!record} time.

    - Default [limit] is 50.
    - When [gate] is provided, only that gate's ring is scanned. Unknown
      gates return [[]].
    - When [gate] is absent, events are merged across gates and sorted by
      timestamp descending. *)

type gate_summary = {
  gate : string;
  passed : int;
  policy_failed : int;
  transition_blocked : int;
  partial_pass : int;
  total : int;
}

val summary : unit -> gate_summary list
(** [summary ()] returns per-gate outcome counts over the current ring
    window. Order is unspecified. *)

val reset : unit -> unit
(** Clear all rings. For tests only. *)

val per_gate_cap : int
(** The bounded window size per gate (exposed for tests). *)
