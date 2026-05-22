(* WORKAROUND-CARRYOVER: tracked by docs/rfc/RFC-0144-workaround-sunset-keeper-dedup-carryover.md.
   Removal: per-[error_kind] sunset criteria (§4). This layer demotes repeated
   ERROR lines to DEBUG; the root fix is reducing the underlying error rate
   (per-arm root-fix table in RFC §3). *)

(* Dedupe state for [Keeper_registry.record_error] noise.

   See [.mli] for the rationale. This module is intentionally stdlib-only
   (Digest + [Bounded_event_dedupe]) so it can be linked into both the
   main library and standalone unit tests without dragging Eio in.

   Threading: [Bounded_event_dedupe] guards the in-memory table with a
   [Mutex.t]. Public entry points perform only key creation and integer
   state updates, so contention is bounded.

   Memory: there is no eviction policy. The MASC server lifetime is in
   the hour-to-day range; the number of distinct [(keeper, error)]
   fingerprints over that window is empirically <1k from production
   logs (cf. system_log_2026-05-16.jsonl analysis), so unbounded
   accumulation is acceptable for this iteration. If a runaway-error
   producer is identified later, an LRU layer is the right
   addition — not a probabilistic filter. *)

type error_kind =
  | Sandbox_docker
  | Stale_turn_timeout
  | Fiber_unresolved
  | Provider_timeout
  | State_machine_guard
  | Expected_version_mismatch
  | Cascade_resolution_failure
  | Unknown_phase_transition
  | Auth_token_mismatch
  | Other

let error_kind_to_string = function
  | Sandbox_docker -> "sandbox_docker"
  | Stale_turn_timeout -> "stale_turn_timeout"
  | Fiber_unresolved -> "fiber_unresolved"
  | Provider_timeout -> "provider_timeout"
  | State_machine_guard -> "state_machine_guard"
  | Expected_version_mismatch -> "expected_version_mismatch"
  | Cascade_resolution_failure -> "cascade_resolution_failure"
  | Unknown_phase_transition -> "unknown_phase_transition"
  | Auth_token_mismatch -> "auth_token_mismatch"
  | Other -> "other"
;;

let canonical_error_kind_label = function
  | "oas_timeout_budget" -> "provider_timeout"
  | value -> value

let error_kind_of_string raw =
  match canonical_error_kind_label raw with
  | "sandbox_docker" -> Some Sandbox_docker
  | "stale_turn_timeout" -> Some Stale_turn_timeout
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "provider_timeout" -> Some Provider_timeout
  | "state_machine_guard" -> Some State_machine_guard
  | "expected_version_mismatch" -> Some Expected_version_mismatch
  | "cascade_resolution_failure" -> Some Cascade_resolution_failure
  | "unknown_phase_transition" -> Some Unknown_phase_transition
  | "auth_token_mismatch" -> Some Auth_token_mismatch
  | "other" -> Some Other
  | _ -> None
;;

let all_error_kinds =
  [ Sandbox_docker
  ; Stale_turn_timeout
  ; Fiber_unresolved
  ; Provider_timeout
  ; State_machine_guard
  ; Expected_version_mismatch
  ; Cascade_resolution_failure
  ; Unknown_phase_transition
  ; Auth_token_mismatch
  ; Other
  ]
;;

(* Substring-based classifier. Order matters: longer / more specific
   markers come first so a "state machine guard violation: expected_version
   mismatch" string is not silently re-classified as the second bucket.
   Production samples (system_log_2026-05-16, 299 events) showed the
   promoted buckets covered ~95% of traffic before the legacy path-tokenizer
   bucket was retired; remaining unmatched text lands in [Other] and is a
   candidate for future arm promotion. *)
let classify_error (err : string) : error_kind =
  let contains_in haystack needle = String.length haystack >= String.length needle
    && (
      let nlen = String.length needle in
      let elen = String.length haystack in
      let rec go i =
        if i + nlen > elen then false
        else if String.sub haystack i nlen = needle then true
        else go (i + 1)
      in
      go 0)
  in
  let contains needle = contains_in err needle in
  if contains "sandbox docker"
  then Sandbox_docker
  else if contains "stale_turn_timeout"
  then Stale_turn_timeout
  else if contains "fiber_unresolved"
  then Fiber_unresolved
  else if contains "provider_timeout" || contains "oas_timeout_budget"
  then Provider_timeout
  else if contains "state machine guard" || contains "guard violation"
  then State_machine_guard
  else if contains "expected_version" && contains "mismatch"
  then Expected_version_mismatch
  else if contains "cascade" && contains "resolution"
  then Cascade_resolution_failure
  else if contains "unknown phase"
  then Unknown_phase_transition
  else if contains "auth" && contains "token" && contains "mismatch"
  then Auth_token_mismatch
  else Other
;;

type record_outcome =
  [ `First
  | `Repeated of int
  ]

(* Fingerprint: keeper name + MD5 digest of the raw error string.
   MD5 is intentional — cryptographic strength is irrelevant; we want
   a short, stable identifier with negligible collision risk across
   <1k cardinality. *)
let fingerprint ~keeper ~error =
  Bounded_event_dedupe.key [ keeper; Digest.to_hex (Digest.string error) ]
;;

let state = Bounded_event_dedupe.create ~initial_capacity:256 ()

let record ~keeper ~error =
  let key = fingerprint ~keeper ~error in
  match Bounded_event_dedupe.record state ~key with
  | Bounded_event_dedupe.First -> `First
  | Bounded_event_dedupe.Repeated count -> `Repeated count
;;

let classify_outcome ~keeper ~error =
  let kind = classify_error error in
  let outcome = record ~keeper ~error in
  kind, outcome
;;

let reset_for_test () =
  Bounded_event_dedupe.reset state
;;

let cardinality () =
  Bounded_event_dedupe.cardinality state
;;
