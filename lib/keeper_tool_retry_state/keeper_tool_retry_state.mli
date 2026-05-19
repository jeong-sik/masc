(** Typed dedupe state for the retry-loop ERROR log noise emitted by
    [Keeper_tools_oas] at the single retry-failure site
    (lib/keeper/keeper_tools_oas.ml:733).

    Background
    ──────────
    [Keeper_tools_oas] wraps keeper tools as OAS tools. When a tool
    call returns an error that is neither a deterministic-skip nor a
    workflow rejection, the dispatch loop emits
        "tool %s returned error result (%d/%d): %s"
    at [Log.Error] level on each attempt. The supervisor reissues the
    same tool call up to [max_consecutive_failures] (default 3) times,
    so a single transient failure produces three ERROR lines with
    identical [(tool_name, detail)] payload.

    System_log inspection (1000-line sample, 2026-05-19) shows the
    pattern in production:
    - keeper_bash ×4, masc_worktree_create ×2,
      keeper_pr_review_comment ×2, masc_transition ×2, Bash ×2 — 12+
      events from 5+ distinct tools in 1000 lines.
    - Each tuple recurs as the retry counter walks 1→2→3.

    Only the first attempt (count=1) of a given fingerprint carries
    operator-visible ERROR value. Attempts 2 and 3 within the same
    retry cycle are informational; they confirm the supervisor saw
    the same failure again, not that a new failure occurred.

    Workaround posture
    ──────────────────
    [WORKAROUND-CARRYOVER]: this module is a noise-dedupe layer, not
    a structural fix for the underlying retry pattern. The root fix
    lives upstream — either reduce the rate of tool-call failures
    themselves (client-side arg validation, container reuse RFC-0097,
    etc.) or change the retry loop to emit a single summary line per
    cycle. Both are out of scope for this PR.

    For now, the [`Threshold_silence] outcome gives the operator a
    one-line ERROR after [default_silence_threshold] identical
    (tool, signature) repetitions across cycles, and the existing
    Prometheus counter
    [Keeper_metrics.metric_keeper_tools_oas_failures] (with site label
    [retry_threshold_silence]) carries the durable signal.

    Closed sum type, no catch-all.

    Threading
    ─────────
    Backed by an in-memory [Hashtbl.t] under a [Mutex]. Process
    lifetime; not persisted. A server restart sees the first
    occurrence emit at ERROR again, which is the desired behaviour
    (operator-visible "this is still happening after restart"). *)

(** Outcome of a [record] call. The caller is the retry-loop branch
    at lib/keeper/keeper_tools_oas.ml:733; the outcome dictates how
    that branch logs the attempt:

    - [`First] — first time this [(tool_name, error_signature)] pair
      has been recorded in this process lifetime. Emit at ERROR
      (preserve existing operator-visible signal).

    - [`Repeated n] — the same pair has been recorded before; [n] is
      the running occurrence count including this call (>=2) and is
      strictly less than [silence_threshold]. Demote to DEBUG.

    - [`Threshold_silence n] — the [silence_threshold]th identical
      repetition has just been observed for this pair; [n] is the
      running count at the moment the threshold tripped (>=
      [silence_threshold]). Emit one durable ERROR
      ("threshold-silence after N identical retries") and bump the
      existing [metric_keeper_tools_oas_failures] counter with site
      label [retry_threshold_silence]. Subsequent occurrences for the
      same pair return [`Repeated] (no second [`Threshold_silence]
      fires within the same process lifetime until [reset_for_test]
      is called). *)
type outcome =
  [ `First
  | `Repeated of int
  | `Threshold_silence of int
  ]

(** Default silence threshold. Tuned against the 1000-line system_log
    sample (12+ events from 5+ tools): threshold 5 keeps the first
    ERROR plus four DEBUG-demoted intermediates visible to the
    operator before the durable [`Threshold_silence] ERROR fires;
    afterwards the log surface is silenced for that pair. With the
    default supervisor max_consecutive_failures of 3, one full retry
    cycle produces at most one [`First] plus two [`Repeated] outcomes,
    so the threshold is crossed only when the same failure recurs
    across multiple retry cycles — exactly the steady-state noise
    pattern the dedupe layer targets. *)
val default_silence_threshold : int

(** [normalize raw] projects [raw] to a stable fingerprint suffix.
    The pipeline is intentionally minimal and lossy-by-design:

    1. Trim leading and trailing whitespace.
    2. Collapse runs of ASCII whitespace (space, tab, CR, LF) to a
       single space character.
    3. Lowercase ASCII letters ([A]–[Z] → [a]–[z]; non-ASCII bytes
       pass through untouched).
    4. Truncate to at most [normalize_length_cap] bytes.

    The cap exists because tool error details routinely embed
    variable payloads (timestamps, paths, request IDs) that would
    otherwise prevent fingerprint convergence. The first 80 bytes
    of a typical OAS tool error carry the error-class prefix and a
    short stable description, which is the high-signal portion. The
    normalize function is total and idempotent
    ([normalize (normalize x) = normalize x]). *)
val normalize : string -> string

(** Byte cap applied by [normalize]. Exposed for tests and for
    callers that need to predict the post-normalize length. *)
val normalize_length_cap : int

(** [record ~tool_name ~error_signature ~attempt] registers a retry
    failure for the dispatched tool and returns the classification.

    The fingerprint is [(tool_name, error_signature)]; the [attempt]
    parameter (the supervisor's retry counter, typically 1..3) is
    accepted so the caller can log it but does *not* participate in
    the fingerprint — two attempts at the same retry cycle for the
    same failure should collapse, that is the whole point of the
    dedupe layer.

    The default silence threshold is [default_silence_threshold];
    callers that need a different threshold (e.g. tests) can override
    via [?silence_threshold]. *)
val record
  :  ?silence_threshold:int
  -> tool_name:string
  -> error_signature:string
  -> attempt:int
  -> unit
  -> outcome

(** Reset all internal state. Test-only entry point — do not call
    from production code. Exposed so unit tests can enforce
    isolation between cases. *)
val reset_for_test : unit -> unit

(** Current number of distinct [(tool_name, error_signature)] entries.
    Diagnostic only; never used for control flow. *)
val cardinality : unit -> int

(** [occurrence_count ~tool_name ~error_signature] returns the
    current running occurrence count for the given fingerprint, or
    [0] when no state exists. Diagnostic / introspection only; never
    used for control flow inside the module. *)
val occurrence_count
  :  tool_name:string
  -> error_signature:string
  -> int
