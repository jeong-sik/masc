(** Masc_error_recovery — pattern-match an error message and
    surface a one-line recovery hint to help an agent
    self-correct without human intervention.

    Called by [mcp_server_eio_call_tool] on tool failure: the
    hint is appended to the error envelope so the agent can pick
    the suggested follow-up tool ([masc_init], [masc_status],
    [masc_claim_next], …) without round-tripping through the
    operator.

    Internal helper [contains] (byte-wise substring scan,
    deliberately replacing a per-call [Re.t] compile that
    accumulated 10–30 [Re.compile] per tool failure) is hidden —
    callers consume only {!recovery_hint}.

    Note: the matcher is structural-signal-debt (memory tag
    [feedback_no-string-matching-classification]) — it
    classifies on substrings of human-readable error text. The
    .mli pins the current behaviour so a future move to
    structural error variants is an intentional contract change,
    not a silent drift. *)

val recovery_hint : string -> string option
(** Inspect [message] (lowercased internally) for known error
    fingerprints and return [Some hint] when one matches:

    - "not initialized" / "no .masc/" → [masc_init] /
      [masc_start(path=…)]
    - "not joined" / "join the room" → [masc_join] /
      [masc_start]
    - "task not found" / ("not found" ∧ "task") → [masc_status]
    - "already claimed" → [masc_status] / [masc_claim_next]
    - "no unclaimed tasks" → [masc_add_task]
    - "rate limit" / "too many" → wait + retry (transient)
    - "room" ∧ "set" → [masc_start(path=…)]
    - "current_task" / "no current task" →
      [masc_plan_set_task(task_id=…)]
    - "path is required" → [masc_start(path="~/my-project")]

    Returns [None] when no fingerprint matches; callers should
    surface the original error verbatim in that case. *)
