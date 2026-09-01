(** Serving-runtime attribution for the canary harness (#28913).

    A canary receipt claims "runtime X served N turns with recall intact",
    but the recall signal alone cannot see who served: when the lane walk
    fails the head candidate, degraded retry serves every turn from another
    runtime and the transcript still reads 9/9. The M3 sweep shipped eight
    antigravity canaries whose every turn was actually served by
    ollama_cloud this way (#28912) — the substitution was invisible in the
    evidence. This module decides, from the same runtime-manifest attempts
    the failover verdict uses, which candidate completed each measured
    turn, so the receipt carries the X of its own claim.

    Turn identity: the check matches harness turn indices against
    [keeper_turn_id], which only lines up on a fresh keeper (turn 1 of the
    run is turn 1 of the keeper). bin rejects [--expect-runtime] combined
    with [--allow-reused-keeper] for exactly this reason. *)

type check = {
  expected_runtime : string;  (** The runtime id the run claims to measure. *)
  served : (int * string) list;
      (** Every windowed [Completed] attempt as (keeper_turn_id,
          candidate runtime id), in row order — the full serving record
          the verdict was computed from, including rows for turns the
          harness did not send. *)
  mismatched : (int * string) list;
      (** Measured turns whose completing candidate differs from
          [expected_runtime]. *)
  unattributed : int list;
      (** Measured turns with no windowed [Completed] row at all —
          either the trace window missed them or the turn never
          completed; both void the attribution claim. *)
}

val check :
  expected_runtime:string ->
  window_start:string ->
  turn_ids:int list ->
  attempts:Keeper_canary_failover.attempt list ->
  check
(** [turn_ids] are the keeper turn ids the harness measured (fresh keeper:
    [1..n]). Attempts before [window_start] are ignored (ISO8601 strings
    compare chronologically, same convention as
    {!Keeper_canary_failover.classify}). When one turn carries several
    [Completed] rows the chronologically last one wins — its reply is the
    one the transcript kept, and the wire does not guarantee list order
    (same lesson classify already carries); a ts tie falls to the later
    row. *)

val all_as_expected : check -> bool
(** True iff [mismatched] and [unattributed] are both empty. Derived, not
    stored: the JSON carries the two lists and readers re-derive. *)

val to_yojson : check -> Yojson.Safe.t
