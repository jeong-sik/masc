(* Typed dedupe state for the Keeper_hooks_oas on_tool_error ERROR log noise.

   See the .mli for the rationale and the production system_log evidence
   that motivates this noise-dedupe layer. The module is intentionally
   backed by the stdlib-only [Bounded_event_dedupe] state machine, so
   it can be linked into both the main library and a standalone Alcotest
   executable without dragging Eio in.

   The key includes [(keeper, tool, signature)] because the hook fires
   per-keeper and two different keepers seeing the same tool error are
   legitimately distinct events.

   Threading: [Bounded_event_dedupe] guards the in-memory table with a
   single [Mutex.t]. All public entry points perform only key creation
   and integer state updates, so contention is bounded.

   Memory: there is no eviction policy. The set of distinct
   (keeper_name, tool_name, error_signature) fingerprints is bounded by
   (number of distinct keepers) × (number of distinct tools each
   exercises) × (number of distinct normalized error families per
   tool). At production scale (~tens of keepers, low tens of tools per
   keeper, low tens of stable error families per tool) the cardinality
   is at most low thousands — unbounded accumulation across process
   lifetime is acceptable. *)

type outcome =
  [ `First
  | `Repeated of int
  | `Threshold_silence of int
  ]

(* Threshold tuned against the 2026-05-19 1000-line system_log sample
   (4 distinct (keeper, tool) pairs × 2 repetitions each). With the
   on_tool_error hook firing once per failure (no 1→3 retry ladder
   bundled inside one event), threshold 5 means the operator sees the
   first ERROR plus four DEBUG-demoted intermediates before the durable
   Threshold_silence ERROR fires. *)
let default_silence_threshold = 5

(* Byte cap on the normalized signature. The first 80 bytes of a
   typical OAS tool error carry the error-class prefix and a short
   stable description (the high-signal portion). Variable payloads
   (timestamps, paths, request IDs, PR numbers) that follow are
   deliberately dropped from the fingerprint so the dedupe layer can
   converge. *)
let normalize_length_cap = Bounded_event_dedupe.default_normalize_length_cap

let normalize (raw : string) : string =
  Bounded_event_dedupe.normalize_signature
    ~length_cap:normalize_length_cap
    raw
;;

(* Fingerprint key. [keeper_name], [tool_name], and [error_signature]
   are concatenated with a null separator. The separator avoids the
   collision risk of straight concatenation when one component happens
   to be a prefix of another component's neighbour (e.g. tool name
   "ab" + signature "cd" vs tool name "a" + signature "bcd"). *)
let key ~keeper_name ~tool_name ~error_signature =
  Bounded_event_dedupe.key [ keeper_name; tool_name; error_signature ]
;;

let state = Bounded_event_dedupe.create ()

let record
  ?(silence_threshold = default_silence_threshold)
  ~(keeper_name : string)
  ~(tool_name : string)
  ~(error_signature : string)
  ()
  : outcome
  =
  let k = key ~keeper_name ~tool_name ~error_signature in
  match Bounded_event_dedupe.record_threshold state ~key:k ~threshold:silence_threshold with
  | Bounded_event_dedupe.First_threshold -> `First
  | Bounded_event_dedupe.Repeated_threshold count -> `Repeated count
  | Bounded_event_dedupe.Threshold { count; threshold = _ } ->
    `Threshold_silence count
;;

let reset_for_test () : unit = Bounded_event_dedupe.reset state

let cardinality () : int =
  Bounded_event_dedupe.cardinality state
;;

let occurrence_count
  ~(keeper_name : string)
  ~(tool_name : string)
  ~(error_signature : string)
  : int
  =
  let k = key ~keeper_name ~tool_name ~error_signature in
  Bounded_event_dedupe.count state ~key:k
;;
