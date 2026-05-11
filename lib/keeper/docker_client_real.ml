(* RFC-0070 Phase 3b-iv.2.2 — Real Docker_client (rm + exec wired).

   Sub-phase 3b-iv.2.0 shipped placeholders for all four S functions.
   Sub-phase 3b-iv.2.1 wired [rm] (#14844). Sub-phase 3b-iv.2.2 (this)
   wires [exec]; [run] and [ps_query] remain placeholders pending
   3b-iv.2.{3,4}.

   The signature is unchanged across sub-phases — callers see a typed
   [(_, sandbox_error) result] regardless of which function bodies are
   real yet. *)

let placeholder = Error Docker_client.Cleanup_failed

(* ── Exit-status mapping helpers ─────────────────────────────── *)

(* Docker CLI exit code semantics for [docker rm]:
     0   — container removed successfully
     1   — container not found, or removal blocked (generic failure)
     125 — daemon error / docker CLI itself errored
     127 — synthesized by [Process_eio.run_argv_with_status] when the
           CLI binary cannot be spawned (missing executable / exec
           error). Functionally identical to "daemon unreachable" from
           the caller's POV. *)
let map_exit_status_for_rm (status : Unix.process_status) =
  match status with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED 127 -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED _ -> Error Docker_client.Cleanup_failed
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Docker_client.Daemon_unreachable

(* Docker CLI exit code semantics for [docker exec]:
     0       — command ran in container, exited zero
     non-zero (general) — command ran in container, exited non-zero;
                         this is a *response*, not a daemon error
     125     — daemon error (couldn't run docker exec itself)
     126     — command found in container but not executable
     127     — synthesized by [Process_eio.run_argv_with_status_split]
               for missing docker CLI; functionally Daemon_unreachable.

   exec's semantic distinction vs rm: a non-zero exit inside the
   container is the *command's* result, returned as
   [Ok exec_result { exit_code = non-zero; ... }]. Only daemon-level
   failures (125, 127, signal) surface as [Error Daemon_unreachable]. *)
let map_status_for_exec
    ((status, stdout, stderr) :
      Unix.process_status * string * string)
  =
  match status with
  | Unix.WEXITED 125 | Unix.WEXITED 127 ->
    Error Docker_client.Daemon_unreachable
  | Unix.WEXITED code ->
    Ok Docker_response.{ exit_code = code; stdout; stderr }
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error Docker_client.Daemon_unreachable

(* ── Functions ───────────────────────────────────────────────── *)

let run (_ : Keeper_sandbox_plan.t) = placeholder
let ps_query ~labels:_ = placeholder

let exec ~container ~cmd =
  let argv =
    [ "docker"
    ; "exec"
    ; Keeper_container_name.to_string container
    ; "sh"
    ; "-lc"
    ; cmd
    ]
  in
  (* [Process_eio.run_argv_with_status_split] returns
     [(status, stdout, stderr)]; on spawn failure the status is
     synthesized as [WEXITED 127] (see 3b-iv.2.1 commit on rm). *)
  map_status_for_exec (Process_eio.run_argv_with_status_split argv)

let rm container =
  let argv =
    [ "docker"; "rm"; "-f"; Keeper_container_name.to_string container ]
  in
  let status, _stdout = Process_eio.run_argv_with_status argv in
  map_exit_status_for_rm status
