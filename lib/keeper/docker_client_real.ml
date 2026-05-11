(* RFC-0070 Phase 3b-iv.2.1 — Real Docker_client (rm wired).

   Sub-phase 3b-iv.2.0 shipped placeholders for all four S functions.
   Sub-phase 3b-iv.2.1 (this) wires [rm] to the real
   [Process_eio.run_argv_with_status] spawn; the other three remain
   placeholders pending 3b-iv.2.{2,3,4}.

   The signature is unchanged across sub-phases — callers see a
   typed [(_, sandbox_error) result] regardless of which function
   bodies are real yet. *)

let placeholder = Error Docker_client.Cleanup_failed

(* ── Exit-status mapping ─────────────────────────────────────── *)

(* Docker CLI exit code semantics for [docker rm]:
     0   — container removed successfully
     1   — container not found, or removal blocked (generic failure)
     125 — daemon error / docker CLI itself errored
     127 — synthesized by [Process_eio.run_argv_with_status] when the
           CLI binary cannot be spawned (missing executable / exec
           error). Functionally identical to "daemon unreachable" from
           the caller's POV.
   Mapping: 0 → Ok, 127 → Daemon_unreachable, any other WEXITED →
   Cleanup_failed, and signal / stopped statuses → Daemon_unreachable. *)
let map_exit_status_for_rm (status : Unix.process_status) =
  match status with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED 127 -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED _ -> Error Docker_client.Cleanup_failed
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Docker_client.Daemon_unreachable

(* ── Functions ───────────────────────────────────────────────── *)

let run (_ : Keeper_sandbox_plan.t) = placeholder
let exec ~container:_ ~cmd:_ = placeholder
let ps_query ~labels:_ = placeholder

let rm container =
  let argv =
    [ "docker"; "rm"; "-f"; Keeper_container_name.to_string container ]
  in
  (* [Process_eio.run_argv_with_status] swallows [Unix.Unix_error] from
     spawn and surfaces it as [WEXITED 127] (see
     [test/test_process_eio_coverage.ml]: "missing command exit code"
     = 127), so the previous [exception Unix.Unix_error _] branch was
     dead. The 127 mapping in [map_exit_status_for_rm] now picks up
     missing-CLI / exec-failure as [Daemon_unreachable]. Eio-level
     cancellation ([Eio.Cancel.Cancelled]) is still propagated to the
     caller intentionally — RFC-0070 requires cancellation to remain
     observable. *)
  let status, _stdout = Process_eio.run_argv_with_status argv in
  map_exit_status_for_rm status
