(** RFC-0070 Phase 3b-iv.2.2 — Real {!Docker_client.S} ([rm] + [exec] wired).

    Phase 3a's stub kept [Docker_client.S] as a *signature only*. Phase
    3b-iv.1b added [Docker_client_mock] for tests. Phase 3b-iv.2.0
    added the *production* skeleton. Phase 3b-iv.2.1 (#14844) wired
    [rm]; Phase 3b-iv.2.2 (this) wires [exec]. [run] and [ps_query]
    remain placeholders pending 3b-iv.2.{3,4}.

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
    - [exec] — wired: spawns
      [docker exec <name> sh -lc <cmd>] via
      [Process_eio.run_argv_with_status_split]. The semantic
      distinction vs [rm] matters: a non-zero exit *inside the
      container* is the *command's* result, returned as
      [Ok exec_result { exit_code = n; stdout; stderr }] — not a
      daemon error. Only daemon-level statuses become
      [Error Daemon_unreachable]:
      {ul
        {- [WEXITED 125] (daemon error)}
        {- [WEXITED 127] (docker CLI missing / spawn failure)}
        {- [WSIGNALED _] / [WSTOPPED _]}}
      All other [WEXITED n] values surface as
      [Ok { exit_code = n; stdout; stderr }].
    - [run], [ps_query] — still [Error Cleanup_failed] placeholder
      pending 3b-iv.2.{3,4}. Each sub-phase replaces one body without
      changing the public surface.

    **Why a placeholder skeleton and not [failwith]**: returning
    [Error Cleanup_failed] keeps the signature in {!result}; a caller
    that wires Real before Phase 3b-iv.2.{1,2,3,4} land will receive a
    typed failure they can pattern-match on, not an exception that
    surfaces as a crash. RFC-0070's "no silent failure, no exception
    leak" contract is preserved. *)

include Docker_client.S
