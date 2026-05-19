(** Dedupe state for [Keeper_registry.record_error] log noise.

    Background
    ──────────
    [Keeper_registry.record_error] previously emitted the raw [err] string
    at [Log.Error] level on every call. In production system_log
    inspection (2026-05-16 sample, 299 events/day) the same
    [(keeper_name, error)] pair fired up to 96 times in a 30-minute
    slice; the verifier keeper's [sandbox docker exec failed] surface
    accounted for ~48% of the volume on its own.

    This is the *MASC/OAS Error-Warn Reduction Goal §P6 noise class*:
    retry-loop without dedupe. The fix preserves behaviour — no log
    line is dropped — but only the *first* occurrence of a given
    [(keeper, error)] fingerprint emits at ERROR. Subsequent
    occurrences within the process lifetime emit at DEBUG and bump a
    Prometheus counter so the dashboard still shows the repetition
    rate.

    Closed sum type, no catch-all. The classifier [classify_error] is
    bounded; an unrecognised error text falls into the explicit
    [`Other] constructor (not a silent default — callers can still
    distinguish "saw something new" from "saw a known bucket").

    Workaround posture
    ──────────────────
    This is a *symptom suppression* layer. The root fix is to repair
    the underlying error source (verifier sandbox docker, path-syntax
    blocking, stale-turn timeouts, etc.). Once those are addressed,
    [`First] outcomes alone should drop to baseline. The dedupe layer
    intentionally records first-emit at ERROR so a *new* category
    surfacing is not muffled. See [WORKAROUND-CARRYOVER] note in the
    PR body.

    Threading
    ─────────
    Backed by an in-memory [Hashtbl.t] under a [Mutex]. Process
    lifetime; not persisted. A keeper restart will see the first
    occurrence emit at ERROR again, which is the desired behaviour
    (operator-visible "this is still happening after restart").
*)

(** Closed-enum classification of the raw [err] string passed to
    [Keeper_registry.record_error]. Used both for the dedupe fingerprint
    and for Prometheus metric labels.

    Add a new constructor (and a new arm in [classify_error]) when a
    new error family stabilises in production logs. Do not collapse
    new error texts into [`Other] — that defeats the per-family
    visibility this module is designed to give. *)
type error_kind =
  | Sandbox_docker (** ["sandbox docker exec failed ..."] family. *)
  | Path_syntax_blocked
      (** ["Path syntax blocked: ..."] keeper shell guard. *)
  | Stale_turn_timeout (** ["stale_turn_timeout(...)"] supervisor guard. *)
  | Fiber_unresolved (** ["fiber_unresolved"] sentinel from turn lifecycle. *)
  | Oas_timeout_budget (** ["oas_timeout_budget_loop(...)"] from OAS bridge. *)
  | State_machine_guard
      (** ["state machine guard violation"] / FSM transition rejected. *)
  | Expected_version_mismatch (** CAS expected_version mismatch. *)
  | Cascade_resolution_failure (** Cascade tier/strategy resolution failure. *)
  | Unknown_phase_transition (** FSM unknown phase transition. *)
  | Auth_token_mismatch (** Auth/token mismatch family. *)
  | Other (** Anything not yet promoted to its own arm. *)

(** Stable label used in Prometheus dimensions and log dedupe keys.
    Round-trips with [error_kind_of_string]. *)
val error_kind_to_string : error_kind -> string

(** Inverse of [error_kind_to_string]. Returns [None] for unrecognised
    labels rather than collapsing to [Other], so callers can detect
    contract drift. *)
val error_kind_of_string : string -> error_kind option

(** All [error_kind] inhabitants in declaration order. Used by
    exhaustiveness tests. *)
val all_error_kinds : error_kind list

(** Classify a raw error string to its [error_kind]. The classifier is
    substring-based on a closed set of literal prefixes; unmatched
    inputs map to [Other]. *)
val classify_error : string -> error_kind

(** Outcome of a [record] call.

    [`First] — this [(keeper, fingerprint)] has not been seen before
    in this process lifetime. The caller should emit at ERROR (preserve
    existing behaviour).

    [`Repeated count] — this exact pair has been recorded before;
    [count] is the total occurrence count *including* this call (>=2).
    The caller should demote the log line to DEBUG and bump the
    [recording_error_dedup] counter. *)
type record_outcome =
  [ `First
  | `Repeated of int
  ]

(** Record an occurrence of [(keeper, error)]. The fingerprint is
    composed of the keeper name and a digest of the raw error string —
    so two textually different error strings with the same classifier
    bucket are still considered distinct (e.g. two different docker
    exec failures with different stderr).

    Returns [`First] on the first occurrence and [`Repeated n] on
    subsequent ones. *)
val record : keeper:string -> error:string -> record_outcome

(** [classify_outcome ~keeper ~error] is [record ~keeper ~error]
    bundled with the [error_kind] classification, for callers that
    want both in one call. *)
val classify_outcome
  :  keeper:string
  -> error:string
  -> error_kind * record_outcome

(** Reset internal state. Test-only entry point — do not call from
    production code. The function is exposed so unit tests can
    enforce isolation between cases. *)
val reset_for_test : unit -> unit

(** Current number of distinct [(keeper, fingerprint)] entries.
    Diagnostic only; never used for control flow. *)
val cardinality : unit -> int
