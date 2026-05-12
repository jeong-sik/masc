(** RFC-0070 Phase 3b-iv.2.4 — Real {!Docker_client.S} (all 4 functions wired).

    Phase 3a's stub kept [Docker_client.S] as a *signature only*. Phase
    3b-iv.1b added [Docker_client_mock] for tests. Phase 3b-iv.2.0 added
    the *production* skeleton. Phase 3b-iv.2.1 (#14844) wired [rm];
    3b-iv.2.2 (#14854) wired [exec]; 3b-iv.2.3 (#14862) wired [run];
    Phase 3b-iv.2.4 (this) wires [ps_query] + the JSON parser.

    **Phase 3b-iv.2 series closes here**: all four [S] functions are
    real spawns. Production callers parameterising on
    [(module Docker_client.S)] can now swap in this module without
    placeholder branches.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2

    Implementation status per function:
    - [rm] — wired: spawns [docker rm -f <name>] via
      [Process_eio.run_argv_with_status]. Exit-status mapping:
      {ul
        {- [WEXITED 0] → [Ok ()]}
        {- [WEXITED 124] (synthesised by [Process_eio] when
           [?timeout_sec] elapses before the child exits) →
           [Error Exec_timeout]}
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
      daemon error. Daemon-level statuses become
      [Error Daemon_unreachable]:
      {ul
        {- [WEXITED 125] (daemon error)}
        {- [WEXITED 127] (docker CLI missing / spawn failure)}
        {- [WSIGNALED _] / [WSTOPPED _]}}
      [WEXITED 124] (synthesised by [Process_eio] on timeout) surfaces
      as [Error Exec_timeout] — it would be misleading to return
      [Ok exec_result { exit_code = 124 }] for a request that never
      actually ran to completion inside the container.
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
    - [ps_query] — wired: spawns
      [docker ps -a --format '\{\{json .\}\}' --filter label=k=v ...]
      via [Process_eio.run_argv_with_status_split], then parses each
      stdout line as one {!Docker_response.ps_record}. Status mapping:
      {ul
        {- [WEXITED 0] → [Ok records] (records is a possibly-empty
           list — unparseable lines are dropped silently; see the
           [parse_ps_line] inline comment for the operational
           rationale)}
        {- [WEXITED 124] (Process_eio timeout) → [Error Exec_timeout]}
        {- [WEXITED 125] / [WEXITED 127] / signal / stopped →
           [Error Daemon_unreachable]}
        {- any other [WEXITED n] → [Error Probe_format_drift]
           (docker ps reported a non-zero exit without daemon signals
           — usually an argv-shape mismatch with the installed docker
           version)}}
      The unparseable-line silent drop is the documented compromise
      between RFC §3.3 "no permissive default" and operational
      reality: a single stray output line should NOT collapse fleet
      listing for the cleanup loop.

    **Why the original placeholder skeleton mattered**: returning
    [Error Cleanup_failed] kept the signature in {!result}; callers
    wiring Real *before* the impl sub-phases landed received a typed
    failure they could pattern-match on, not an exception that
    surfaces as a crash. RFC-0070's "no silent failure, no exception
    leak" contract preserved across the whole series. *)

include Docker_client.S
