(* Typed escalation state for the [Keeper_turn_livelock] dispatch guard.

   See [.mli] for the rationale and the production system_log evidence
   that motivates the noise-dedupe layer. This module is intentionally
   backed by the stdlib-only [Bounded_event_dedupe] state machine, so it
   can be linked into both the main library and a standalone Alcotest
   executable without dragging Eio in.

   Threading: [Bounded_event_dedupe] guards the in-memory table with a
   single [Mutex.t]. All public entry points perform only key creation
   and integer state updates, so contention is bounded.

   Memory: there is no eviction policy. The set of distinct
   [(keeper, gate_kind)] fingerprints is bounded by
   (number of keepers) × |gate_kind|, i.e. O(keepers × 2). At
   production scale (~10–50 keepers) the cardinality is at most low
   hundreds — unbounded accumulation is acceptable. *)

(* Closed sum type. Mirrors the constructors of
   [Keeper_turn_livelock.gate_reason] one-for-one. If a new gate
   reason is added upstream, the [gate_kind_of_string] arm above
   will fail to round-trip and the corresponding test will catch
   the drift. *)
type gate_kind =
  | Attempts_exhausted
  | Stuck_age_exceeded

let gate_kind_to_string = function
  | Attempts_exhausted -> "attempts_exhausted"
  | Stuck_age_exceeded -> "stuck_age_exceeded"
;;

let gate_kind_of_string = function
  | "attempts_exhausted" -> Some Attempts_exhausted
  | "stuck_age_exceeded" -> Some Stuck_age_exceeded
  | _ -> None
;;

let all_gate_kinds = [ Attempts_exhausted; Stuck_age_exceeded ]

(* Threshold tuned against the production sample (system_log
   2026-05-19): 4 keepers × ~30 s dispatch interval = ~80 blocks per
   keeper per hour. Threshold 5 keeps the first ERROR plus four
   intermediates visible to the operator before [Threshold_park]
   fires; afterwards the log surface is parked. *)
let default_park_threshold = 5

type threshold_park_payload =
  { count : int
  ; park_threshold : int
  }

type record_outcome =
  [ `First
  | `Repeated of int
  | `Threshold_park of threshold_park_payload
  ]

(* Fingerprint key. [gate_kind] is small and total, so we project it
   to its string label and concat with the keeper name and a null
   separator. The separator avoids the collision risk of
   [keeper ^ kind] when a keeper name happens to be a prefix of
   another keeper name plus the kind label. *)
let key ~keeper ~gate_kind =
  Bounded_event_dedupe.key [ keeper; gate_kind_to_string gate_kind ]
;;

let state = Bounded_event_dedupe.create ()

let record_block
  ?(park_threshold = default_park_threshold)
  ~(keeper : string)
  ~(gate_kind : gate_kind)
  ()
  : record_outcome
  =
  let k = key ~keeper ~gate_kind in
  match Bounded_event_dedupe.record_threshold state ~key:k ~threshold:park_threshold with
  | Bounded_event_dedupe.First_threshold -> `First
  | Bounded_event_dedupe.Repeated_threshold count -> `Repeated count
  | Bounded_event_dedupe.Threshold { count; threshold } ->
    `Threshold_park { count; park_threshold = threshold }
;;

let reset_for_keeper ~(keeper : string) : unit =
  List.iter
    (fun gk ->
      let k = key ~keeper ~gate_kind:gk in
      Bounded_event_dedupe.remove state ~key:k)
    all_gate_kinds
;;

let reset_for_test () : unit = Bounded_event_dedupe.reset state

let cardinality () : int =
  Bounded_event_dedupe.cardinality state
;;

let block_count ~(keeper : string) ~(gate_kind : gate_kind) : int =
  let k = key ~keeper ~gate_kind in
  Bounded_event_dedupe.count state ~key:k
;;
