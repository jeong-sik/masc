(** RFC-0070 Phase 3b-iv.2.0 — Real {!Docker_client.S} (skeleton).

    Phase 3a's stub kept [Docker_client.S] as a *signature only*.
    Phase 3b-iv.1b added [Docker_client_mock] for tests. Phase
    3b-iv.2.0 adds the *production* implementation skeleton, satisfying
    [S] so callers parameterising on [(module Docker_client.S)] can
    swap it in alongside the mock at compile time.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2

    Phase 3b-iv.2 skeleton scope: every function in [S] is implemented
    but returns [Error Cleanup_failed] — a typed placeholder that
    *cannot* silently succeed. Phase 3b-iv.2.1 wires [rm] to
    [Process_eio.run_argv_with_status]; subsequent sub-phases wire
    [exec], [run], [ps_query] in their own PRs. Each sub-phase replaces
    the placeholder with a real spawn while preserving the typed
    [sandbox_error] surface — no caller code changes between
    sub-phases.

    **Why a placeholder skeleton and not [failwith]**: returning
    [Error Cleanup_failed] keeps the signature in {!result}; a caller
    that wires Real before Phase 3b-iv.2.{1,2,3,4} land will receive a
    typed failure they can pattern-match on, not an exception that
    surfaces as a crash. RFC-0070's "no silent failure, no exception
    leak" contract is preserved. *)

include Docker_client.S
