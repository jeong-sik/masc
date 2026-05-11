(** RFC-0070 Phase 3b-iv.2.3 — Real {!Docker_client.S}
    ([rm] + [exec] + [run] wired).

    Phase 3a's stub kept [Docker_client.S] as a *signature only*. Phase
    3b-iv.1b added [Docker_client_mock] for tests. Phase 3b-iv.2.0
    added the *production* skeleton. Phase 3b-iv.2.1 (#14844) wired
    [rm]; 3b-iv.2.2 (#14854) wired [exec]; 3b-iv.2.3 (this) wires
    [run]. Only [ps_query] remains a placeholder pending 3b-iv.2.4.

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
    - [run] — wired: spawns
      [docker run --rm --name <name> <image> sh -lc <cmd>] via
      [Process_eio.run_argv_with_status_split], passing
      [Keeper_sandbox_plan.timeout_budget_sec] as the
      [?timeout_sec] parameter. Status mapping is the same as [exec]
      ({!Docker_response.exec_result} on container-command exit;
      [Error Daemon_unreachable] on daemon-level status). [--rm]
      flag removes the container after exit (RFC §3.1's interim
      default cleanup; a typed cleanup-policy field on
      {!Keeper_sandbox_plan.t} is deferred to a follow-up RFC).
    - [ps_query] — still [Error Cleanup_failed] placeholder pending
      3b-iv.2.4 (JSON parser for
      [docker ps --format '\{\{json .\}\}']).

    **Why a placeholder skeleton and not [failwith]**: returning
    [Error Cleanup_failed] keeps the signature in {!result}; a caller
    that wires Real before Phase 3b-iv.2.{1,2,3,4} land will receive a
    typed failure they can pattern-match on, not an exception that
    surfaces as a crash. RFC-0070's "no silent failure, no exception
    leak" contract is preserved. *)

include Docker_client.S
