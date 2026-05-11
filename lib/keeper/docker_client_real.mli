(** RFC-0070 Phase 3b-iv.2.1 — Real {!Docker_client.S} ([rm] wired).

    Phase 3a's stub kept [Docker_client.S] as a *signature only*.
    Phase 3b-iv.1b added [Docker_client_mock] for tests. Phase 3b-iv.2.0
    added the *production* skeleton (placeholders). Phase 3b-iv.2.1
    (this) wires [rm] to [Process_eio.run_argv_with_status]; [exec],
    [run], [ps_query] remain placeholders pending 3b-iv.2.{2,3,4}.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2

    Implementation status per function:
    - [rm] — wired: spawns [docker rm -f <name>] via
      [Process_eio.run_argv_with_status]. Exit-status mapping:
      {ul
        {- [WEXITED 0] → [Ok ()]}
        {- [WEXITED 127] (spawn failure: docker CLI missing or exec
           error) → [Error Daemon_unreachable]}
        {- any other [WEXITED n] → [Error Cleanup_failed]}
        {- [WSIGNALED _] / [WSTOPPED _] → [Error Daemon_unreachable]}}
      No [Unix.Unix_error] leak (Process_eio internalises spawn errors
      to [WEXITED 127]). [Eio.Cancel.Cancelled] still propagates to the
      caller by design — RFC-0070 requires cancellation to remain
      observable rather than being absorbed into a typed error.
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
