(* Typed dedupe state for the Keeper_tools_oas retry-loop ERROR log noise.

   See the .mli for the rationale and the production system_log evidence
   that motivates this noise-dedupe layer. The module is intentionally
   backed by the stdlib-only [Bounded_event_dedupe] state machine, so
   it can be linked into both the main library and a standalone Alcotest
   executable without dragging Eio in.

   Threading: [Bounded_event_dedupe] guards the in-memory table with a
   single [Mutex.t]. All public entry points perform only key creation
   and integer state updates, so contention is bounded.

   Memory: there is no eviction policy. The set of distinct
   (tool_name, error_signature) fingerprints is bounded by
   (number of distinct keeper tools) × (number of distinct normalized
   error prefixes). At production scale (tens of tools, low tens of
   stable error families per tool) the cardinality is at most low
   hundreds — unbounded accumulation across process lifetime is
   acceptable. *)

type outcome =
  [ `First
  | `Repeated of int
  | `Threshold_silence of int
  ]

(* Threshold tuned against the 2026-05-19 1000-line system_log sample
   (12+ retry-error events from 5+ tools). With the default supervisor
   max_consecutive_failures of 3, one retry cycle produces at most
   three records for the same fingerprint, so threshold 5 means the
   silence outcome only fires once the same (tool, signature) recurs
   across multiple retry cycles. *)
let default_silence_threshold = 5

(* Byte cap on the normalized signature. The first 80 bytes of a
   typical OAS tool error carry the error-class prefix and a short
   stable description (the high-signal portion). Variable payloads
   (timestamps, paths, request IDs) that follow are deliberately
   dropped from the fingerprint so the dedupe layer can converge. *)
let normalize_length_cap = Bounded_event_dedupe.default_normalize_length_cap

let normalize (raw : string) : string =
  Bounded_event_dedupe.normalize_signature
    ~length_cap:normalize_length_cap
    raw
;;

(* Fingerprint key. [tool_name] and [error_signature] are concatenated
   with a null separator. The separator avoids the collision risk of
   [tool ^ signature] when a tool name happens to be a prefix of another
   tool name plus its signature. *)
let key ~tool_name ~error_signature =
  Bounded_event_dedupe.key [ tool_name; error_signature ]
;;

let state = Bounded_event_dedupe.create ()

let record
  ?(silence_threshold = default_silence_threshold)
  ~(tool_name : string)
  ~(error_signature : string)
  ~(attempt : int)
  ()
  : outcome
  =
  (* [attempt] is accepted so the call site can log it but does not
     participate in the fingerprint or in the dedupe decision — two
     attempts at the same retry cycle for the same failure must
     collapse, which is precisely what dedupe is for. The [ignore]
     here is intentional and documented. *)
  ignore attempt;
  let k = key ~tool_name ~error_signature in
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
  ~(tool_name : string)
  ~(error_signature : string)
  : int
  =
  let k = key ~tool_name ~error_signature in
  Bounded_event_dedupe.count state ~key:k
;;
