(** RFC-0070 Phase 3c.1 — Sandbox_executor (scaffold + retry).

    Functor on {!Docker_client.S}. Composes a pure
    {!Keeper_sandbox_plan.t} with a daemon client to execute one
    sandbox call end-to-end. Both Mock (Phase 3b-iv.1b) and the
    upcoming Real (Phase 3b-iv.2) satisfy [S], so this functor is
    interchangeable across them.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2, §3.4

    Phase 3c.0 added [execute_plan] (1:1 forwarding). Phase 3c.1 adds
    [execute_plan_with_retry] driven by a typed
    {!Keeper_backoff_policy.t}; no sleep is performed at this phase
    (count-based only), so determinism is preserved.

    Phase 3c.2 (depends on RFC-0036 §3.1 cleanup_hook) adds the
    quarantine state machine that replaces the historical counter-as-
    fix telemetry.

    Determinism contract: deterministic plan + deterministic client +
    pure policy value ⇒ deterministic response sequence. *)

module Make : functor (D : Docker_client.S) -> sig
  (** [execute_plan plan] runs [plan] through [D.run] once. *)
  val execute_plan
    :  Keeper_sandbox_plan.t
    -> (Docker_response.exec_result, Docker_client.sandbox_error) result

  (** [execute_plan_with_retry ~retry plan] calls [D.run plan] up to
      [Keeper_backoff_policy.max_attempts retry] times *in total*
      (one initial call plus up to [max_attempts - 1] retries on
      retryable errors). Concretely: with [max_attempts = 3] the
      callee may run at most three times — initial + 2 retries.

      Returns the first [Ok], or the last [Error] after exhausting
      the call budget. Non-retryable errors return immediately
      regardless of remaining budget.

      Phase 3c.1 has *no sleep* between attempts — the budget is
      strictly call-count based. Phase 3c.2 introduces an
      Eio.Time-backed delay parameter when the cleanup quarantine
      lands; until then, callers are expected to retry only on
      *transient* errors (Daemon_unreachable, Image_pull_failed) where
      back-to-back retries are acceptable. *)
  val execute_plan_with_retry
    :  retry:Keeper_backoff_policy.t
    -> Keeper_sandbox_plan.t
    -> (Docker_response.exec_result, Docker_client.sandbox_error) result
end
