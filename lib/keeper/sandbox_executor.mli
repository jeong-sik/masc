(** RFC-0070 Phase 3c.0 — Sandbox_executor (scaffold).

    Functor on {!Docker_client.S}. Composes a pure
    {!Keeper_sandbox_plan.t} with a daemon client to execute one
    sandbox call end-to-end. Both Mock (Phase 3b-iv.1b) and the
    upcoming Real (Phase 3b-iv.2) satisfy [S], so this functor is
    interchangeable across them.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2

    Phase 3c.0 scope: minimal scaffold — [execute_plan] is a thin pass
    through [D.run]. The added value at this phase is *type composition*:
    Plan → daemon client → typed response, end-to-end. Retry policy
    (Phase 3c.1) and quarantine state machine (Phase 3c.2, depends on
    RFC-0036 §3.1 cleanup_hook) follow in separate PRs.

    Determinism contract: deterministic plan + deterministic client ⇒
    deterministic response. Phase 3c.0 has no clock, no retry, no
    backoff — execute_plan is a single forward call. *)

module Make : functor (D : Docker_client.S) -> sig
  (** [execute_plan plan] runs [plan] through [D.run] and returns the
      typed daemon response.

      Phase 3c.0: 1:1 forwarding. Phase 3c.1 adds retry policy on
      [Daemon_unreachable] / [Image_pull_failed]; other
      [sandbox_error] arms remain immediate (caller-classified
      retryable-ness lands with the retry policy). *)
  val execute_plan
    :  Keeper_sandbox_plan.t
    -> (Docker_response.exec_result, Docker_client.sandbox_error) result
end
