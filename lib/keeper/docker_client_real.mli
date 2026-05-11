(** RFC-0070 Phase 3b-iv.2.1 — Real {!Docker_client.S} ([rm] wired).

    Phase 3a's stub kept [Docker_client.S] as a *signature only*.
    Phase 3b-iv.1b added [Docker_client_mock] for tests. Phase 3b-iv.2.0
    added the *production* skeleton (placeholders). Phase 3b-iv.2.1
    (this) wires [rm] to [Process_eio.run_argv_with_status]; [exec],
    [run], [ps_query] remain placeholders pending 3b-iv.2.{2,3,4}.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2

    Implementation status per function:
    - [rm] — wired: spawns [docker rm -f <name>]; maps exit code →
      typed [sandbox_error] (0 → Ok, non-zero → Cleanup_failed, signal
      or Unix_error → Daemon_unreachable). No exception leak.
    - [exec], [run], [ps_query] — still [Error Cleanup_failed]
      placeholder pending 3b-iv.2.{2,3,4}. Each sub-phase replaces one
      body without changing the public surface — callers wiring Real
      today pick up real behaviour as each lands.

    **Why a placeholder skeleton and not [failwith]**: returning
    [Error Cleanup_failed] keeps the signature in {!result}; a caller
    that wires Real before Phase 3b-iv.2.{1,2,3,4} land will receive a
    typed failure they can pattern-match on, not an exception that
    surfaces as a crash. RFC-0070's "no silent failure, no exception
    leak" contract is preserved. *)

include Docker_client.S
