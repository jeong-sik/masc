(* RFC-0070 Phase 3b-iv.2.5 — Real Docker_client (parser extracted).

   Sub-phase 3b-iv.2.0 shipped placeholders for all four S functions.
   Sub-phases 3b-iv.2.{1,2,3,4} wired [rm] (#14844), [exec] (#14854),
   [run] (#14862), and [ps_query]+JSON parser (#14871). Sub-phase
   3b-iv.2.5 (this) extracts the JSON parser to {!Docker_ps_parser}
   so each silent-drop path is exercised by unit tests with
   synthetic JSON fixtures. *)

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
  | Unix.WEXITED 124 -> Error Docker_client.Exec_timeout
  | Unix.WEXITED 127 -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED _ -> Error Docker_client.Cleanup_failed
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Docker_client.Daemon_unreachable
;;

(* Docker CLI exit code semantics for [docker exec] AND [docker run]:
   both return the executed *command's* exit code on success; only
   daemon-level statuses (125, 127, signal) surface as
   [Error Daemon_unreachable]. A non-zero command exit is a *response*
   ([Ok exec_result]), not a daemon error. *)
let map_status_to_exec_result
      ((status, stdout, stderr) : Unix.process_status * string * string)
  =
  match status with
  | Unix.WEXITED 124 -> Error Docker_client.Exec_timeout
  | Unix.WEXITED 125 | Unix.WEXITED 127 -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED code -> Ok Docker_response.{ exit_code = code; stdout; stderr }
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Docker_client.Daemon_unreachable
;;

(* JSON parsing helpers extracted to {!Docker_ps_parser} so each
   silent-drop path is testable via synthetic JSON fixtures. See
   that module's .mli for the surface and trade-off rationale. *)

(* [labels_to_filter_args] folds each [(k, v)] into a [--filter
   label=k=v] pair on the argv, suitable for [docker ps]. *)
let labels_to_filter_args (labels : (string * string) list) : string list =
  List.concat_map (fun (k, v) -> [ "--filter"; Printf.sprintf "label=%s=%s" k v ]) labels
;;

(* ── Functions ───────────────────────────────────────────────── *)

let ps_query ~labels =
  let argv =
    [ "docker"; "ps"; "-a"; "--format"; "{{json .}}" ] @ labels_to_filter_args labels
  in
  let status, stdout, _stderr = Process_eio.run_argv_with_status_split argv in
  match status with
  | Unix.WEXITED 0 -> Ok (Docker_ps_parser.parse_output stdout)
  | Unix.WEXITED 124 -> Error Docker_client.Exec_timeout
  | Unix.WEXITED 125 | Unix.WEXITED 127 -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED _ -> Error Docker_client.Probe_format_drift
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Docker_client.Daemon_unreachable
;;

let exec ~container ~cmd =
  let argv =
    [ "docker"; "exec"; Keeper_container_name.to_string container; "sh"; "-lc"; cmd ]
  in
  map_status_to_exec_result (Process_eio.run_argv_with_status_split argv)
;;

let run plan =
  let container_name =
    Keeper_container_name.to_string (Keeper_sandbox_plan.container_name plan)
  in
  let image = Keeper_sandbox_plan.image plan in
  let command = Keeper_sandbox_plan.command plan in
  let timeout_sec = Keeper_sandbox_plan.timeout_budget_sec plan in
  let argv =
    [ "docker"; "run"; "--rm"; "--name"; container_name; image; "sh"; "-lc"; command ]
  in
  map_status_to_exec_result (Process_eio.run_argv_with_status_split ~timeout_sec argv)
;;

let rm container =
  let argv = [ "docker"; "rm"; "-f"; Keeper_container_name.to_string container ] in
  let status, _stdout = Process_eio.run_argv_with_status argv in
  map_exit_status_for_rm status
;;
