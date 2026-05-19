(* WORKAROUND-CARRYOVER: tracked by docs/rfc/RFC-0144-workaround-sunset-keeper-dedup-carryover.md.
   Removal: per-[error_kind] sunset criteria (§4). This layer demotes repeated
   ERROR lines to DEBUG; the root fix is reducing the underlying error rate
   (per-arm root-fix table in RFC §3). *)

(* Dedupe state for [Keeper_registry.record_error] noise.

   See [.mli] for the rationale. This module is intentionally stdlib-only
   (Digest + Hashtbl + Mutex + String) so it can be linked into both the
   main library and standalone unit tests without dragging Eio in.

   Threading: the in-memory [Hashtbl.t] is guarded by a [Mutex.t]. All
   public entry points take and release the lock; the lock is never held
   across allocations of caller-visible records, so contention is
   bounded.

   Memory: there is no eviction policy. The MASC server lifetime is in
   the hour-to-day range; the number of distinct [(keeper, error)]
   fingerprints over that window is empirically <1k from production
   logs (cf. system_log_2026-05-16.jsonl analysis), so unbounded
   accumulation is acceptable for this iteration. If a runaway-error
   producer is identified later, an LRU layer is the right
   addition — not a probabilistic filter. *)

type error_kind =
  | Sandbox_docker
  | Path_syntax_blocked
  | Stale_turn_timeout
  | Fiber_unresolved
  | Oas_timeout_budget
  | State_machine_guard
  | Expected_version_mismatch
  | Cascade_resolution_failure
  | Unknown_phase_transition
  | Auth_token_mismatch
  | Other

let error_kind_to_string = function
  | Sandbox_docker -> "sandbox_docker"
  | Path_syntax_blocked -> "path_syntax_blocked"
  | Stale_turn_timeout -> "stale_turn_timeout"
  | Fiber_unresolved -> "fiber_unresolved"
  | Oas_timeout_budget -> "oas_timeout_budget"
  | State_machine_guard -> "state_machine_guard"
  | Expected_version_mismatch -> "expected_version_mismatch"
  | Cascade_resolution_failure -> "cascade_resolution_failure"
  | Unknown_phase_transition -> "unknown_phase_transition"
  | Auth_token_mismatch -> "auth_token_mismatch"
  | Other -> "other"
;;

let error_kind_of_string = function
  | "sandbox_docker" -> Some Sandbox_docker
  | "path_syntax_blocked" -> Some Path_syntax_blocked
  | "stale_turn_timeout" -> Some Stale_turn_timeout
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "oas_timeout_budget" -> Some Oas_timeout_budget
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
  ; Path_syntax_blocked
  ; Stale_turn_timeout
  ; Fiber_unresolved
  ; Oas_timeout_budget
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
   Production samples (system_log_2026-05-16, 299 events) show the eight
   buckets above cover ~95% of traffic; the remaining ~5% land in [Other]
   and are good candidates for future arm promotion. *)
let classify_error (err : string) : error_kind =
  let contains needle = String.length err >= String.length needle
    && (
      let nlen = String.length needle in
      let elen = String.length err in
      let rec go i =
        if i + nlen > elen then false
        else if String.sub err i nlen = needle then true
        else go (i + 1)
      in
      go 0)
  in
  if contains "sandbox docker"
  then Sandbox_docker
  else if contains "Path syntax blocked"
  then Path_syntax_blocked
  else if contains "stale_turn_timeout"
  then Stale_turn_timeout
  else if contains "fiber_unresolved"
  then Fiber_unresolved
  else if contains "oas_timeout_budget"
  then Oas_timeout_budget
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
  keeper ^ "|" ^ Digest.to_hex (Digest.string error)
;;

let mu = Mutex.create ()
let counts : (string, int) Hashtbl.t = Hashtbl.create 256

let record ~keeper ~error =
  let key = fingerprint ~keeper ~error in
  Mutex.lock mu;
  let outcome =
    match Hashtbl.find_opt counts key with
    | None ->
      Hashtbl.add counts key 1;
      `First
    | Some n ->
      let n' = n + 1 in
      Hashtbl.replace counts key n';
      `Repeated n'
  in
  Mutex.unlock mu;
  outcome
;;

let classify_outcome ~keeper ~error =
  let kind = classify_error error in
  let outcome = record ~keeper ~error in
  kind, outcome
;;

let reset_for_test () =
  Mutex.lock mu;
  Hashtbl.reset counts;
  Mutex.unlock mu
;;

let cardinality () =
  Mutex.lock mu;
  let n = Hashtbl.length counts in
  Mutex.unlock mu;
  n
;;
