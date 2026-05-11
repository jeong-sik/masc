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
   We map 0 → Ok, any other WEXITED → Cleanup_failed, and signal /
   stopped statuses → Daemon_unreachable. *)
let map_exit_status_for_rm (status : Unix.process_status) =
  match status with
  | Unix.WEXITED 0 -> Ok ()
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
  match Process_eio.run_argv_with_status argv with
  | status, _stdout -> map_exit_status_for_rm status
  | exception Unix.Unix_error _ -> Error Docker_client.Daemon_unreachable
