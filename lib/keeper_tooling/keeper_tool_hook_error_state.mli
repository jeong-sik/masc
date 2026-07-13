(** Typed dedupe state for the [on_tool_error] hook ERROR log noise
    emitted by [Keeper_hooks_oas] at the single emit site
    (lib/keeper/keeper_hooks_oas.ml:720).

    Background
    ──────────
    [Keeper_hooks_oas] installs an [on_tool_error] hook that fires on
    every keeper tool error returned to the supervisor. The hook body
    emits

        "keeper:%s tool_error: %s — %s"

    at [Log.Error] level for the [(keeper_name, tool_name, error)]
    tuple. The hook fires *per failure*, not per retry, so unlike the
    retry-loop site this is not a 1→2→3 sliding count within a single
    cycle — instead the same fingerprint recurs across time as the
    same keeper hits the same tool error repeatedly.

    System_log inspection (1000-line sample, 2026-05-19) shows the
    pattern in production:
    - keeper:verifier × Bash × 2
    - keeper:lifecycle-worker-fast-1 × Execute × 2
    - keeper:lifecycle-reviewer-fast-1 × tool_execute × 2
    - keeper:analyst × masc_transition × 2

    That is 4 distinct (keeper, tool) pairs, each repeating twice with
    identical error payloads inside the same 1000-line window. Only
    the first occurrence carries operator-visible ERROR value;
    subsequent occurrences confirm "still happening" but add no new
    signal at ERROR level.

    Workaround posture
    ──────────────────
    [WORKAROUND-CARRYOVER]: this module is a noise-dedupe layer, not
    a structural fix. The root fix lives either upstream (reduce the
    rate of keeper-tool failures themselves) or in the hook chain
    redesign (one summary line per keeper per failure family,
    typed). Both are out of scope here. The [`Threshold_silence]
    outcome gives the operator a one-line ERROR after
    [default_silence_threshold] identical repetitions, plus a
    Otel_metric_store counter increment with site label
    [on_tool_error_threshold_silence] preserved at the call site.

    Closed sum type, no catch-all.

    Threading
    ─────────
    Backed by an in-memory [Hashtbl.t] under a [Mutex]. Process
    lifetime; not persisted. A server restart sees the first
    occurrence per fingerprint emit at ERROR again, which is the
    desired behaviour (operator-visible "this is still happening
    after restart"). *)

(** Outcome of a [record] call. The caller is the [on_tool_error]
    hook body at lib/keeper/keeper_hooks_oas.ml:720; the outcome
    dictates how that branch logs the event:

    - [`First] — first time this [(keeper_name, tool_name,
      error_signature)] triple has been recorded in this process
      lifetime. Emit at ERROR (preserve existing operator-visible
      signal).

    - [`Repeated n] — the same triple has been recorded before; [n]
      is the running occurrence count including this call (>=2) and
      is strictly less than [silence_threshold]. Demote to DEBUG.

    - [`Threshold_silence n] — the [silence_threshold]th identical
      repetition has just been observed for this triple; [n] is the
      running count at the moment the threshold tripped (>=
      [silence_threshold]). Emit one durable ERROR
      ("threshold-silence after N identical events") and bump the
      Otel_metric_store callback-failures counter with site label
      [on_tool_error_threshold_silence]. Subsequent occurrences for
      the same triple return [`Repeated] (no second
      [`Threshold_silence] fires within the same process lifetime
      until [reset_for_test] is called). *)
type outcome =
  [ `First
  | `Repeated of int
  | `Threshold_silence of int
  ]

(** Default silence threshold. Tuned against the 2026-05-19 1000-line
    system_log sample (4 distinct (keeper, tool) pairs × 2
    repetitions each). With the [on_tool_error] hook firing once per
    failure (no 1→3 retry ladder bundled inside one event), threshold
    5 means the operator sees the first ERROR plus four DEBUG-demoted
    intermediates before the durable [`Threshold_silence] ERROR
    fires. Tunable via [?silence_threshold] on [record]. *)
val default_silence_threshold : int

(** [normalize raw] projects [raw] to a stable fingerprint suffix.
    The pipeline is intentionally minimal and lossy-by-design:

    1. Trim leading and trailing whitespace.
    2. Collapse runs of ASCII whitespace (space, tab, CR, LF) to a
       single space character.
    3. Lowercase ASCII letters ([A]–[Z] → [a]–[z]; non-ASCII bytes
       pass through untouched).
    4. Truncate to at most [normalize_length_cap] bytes.

    The cap exists because keeper-tool error details routinely embed
    variable payloads (timestamps, paths, request IDs, PR numbers)
    that would otherwise prevent fingerprint convergence. The first
    80 bytes of a typical OAS tool error carry the error-class
    prefix and a short stable description, which is the high-signal
    portion. The normalize function is total and idempotent
    ([normalize (normalize x) = normalize x]). *)
val normalize : string -> string

(** Byte cap applied by [normalize]. Exposed for tests and for
    callers that need to predict the post-normalize length. *)
val normalize_length_cap : int

(** [record ~keeper_name ~tool_name ~error_signature] registers a
    hook tool_error event and returns the classification.

    The fingerprint is [(keeper_name, tool_name, error_signature)].
    The caller is responsible for passing an [error_signature] that
    has already been [normalize]d (the call site does this once and
    passes the result through). The triple is conservative on
    purpose: two different keepers hitting the same tool error from
    independent code paths are legitimately distinct ERROR events
    and must not collapse.

    The default silence threshold is [default_silence_threshold];
    callers that need a different threshold (e.g. tests) can
    override via [?silence_threshold]. *)
val record
  :  ?silence_threshold:int
  -> keeper_name:string
  -> tool_name:string
  -> error_signature:string
  -> unit
  -> outcome

(** Reset all internal state. Test-only entry point — do not call
    from production code. Exposed so unit tests can enforce
    isolation between cases. *)
val reset_for_test : unit -> unit

(** Current number of distinct [(keeper_name, tool_name,
    error_signature)] entries. Diagnostic only; never used for
    control flow. *)
val cardinality : unit -> int

(** [occurrence_count ~keeper_name ~tool_name ~error_signature]
    returns the current running occurrence count for the given
    fingerprint, or [0] when no state exists. Diagnostic /
    introspection only; never used for control flow inside the
    module. *)
val occurrence_count
  :  keeper_name:string
  -> tool_name:string
  -> error_signature:string
  -> int
