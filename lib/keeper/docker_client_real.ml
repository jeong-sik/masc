(* RFC-0070 Phase 3b-iv.2.3 — Real Docker_client (rm + exec + run wired).

   Sub-phase 3b-iv.2.0 shipped placeholders for all four S functions.
   Sub-phase 3b-iv.2.1 wired [rm] (#14844); 3b-iv.2.2 wired [exec]
   (#14854); 3b-iv.2.3 (this) wires [run]. Only [ps_query] remains a
   placeholder pending 3b-iv.2.4.

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
;;

(* Docker CLI exit code semantics for [docker exec] AND [docker run]:
   both return the executed *command's* exit code on success; only
   daemon-level statuses (125, 127, signal) surface as
   [Error Daemon_unreachable]. A non-zero command exit is a *response*
   ([Ok exec_result]), not a daemon error.

   Shared between [exec] and [run] because both produce
   {!Docker_response.exec_result} on success; the host process IS the
   docker CLI, and its [WEXITED n] reflects what docker reported about
   the containerized command. *)
let map_status_to_exec_result
      ((status, stdout, stderr) : Unix.process_status * string * string)
  =
  match status with
  | Unix.WEXITED 125 | Unix.WEXITED 127 -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED code -> Ok Docker_response.{ exit_code = code; stdout; stderr }
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Docker_client.Daemon_unreachable
;;

(* ── Functions ───────────────────────────────────────────────── *)

let ps_query ~labels:_ = placeholder

(* Pure: builds the [docker exec] argv. Separated from {!exec} so the
   argv shape is unit-testable without a daemon (RFC-0070's pure/edge
   split — deterministic argv construction here, daemon spawn in
   {!exec}). [--user] precedes [-w] to match the order
   [keeper_turn_sandbox_runtime] currently emits. *)
let exec_argv ?user ?workdir ~container ~cmd () =
  let user_args =
    match user with
    | None -> []
    | Some (uid, gid) -> [ "--user"; Printf.sprintf "%d:%d" uid gid ]
  in
  let workdir_args =
    match workdir with
    | None -> []
    | Some w -> [ "-w"; w ]
  in
  [ "docker"; "exec" ]
  @ user_args
  @ workdir_args
  @ [ Keeper_container_name.to_string container; "sh"; "-lc"; cmd ]
;;

let exec ?user ?workdir ~container ~cmd () =
  let argv = exec_argv ?user ?workdir ~container ~cmd () in
  (* [Process_eio.run_argv_with_status_split] returns
     [(status, stdout, stderr)]; on spawn failure the status is
     synthesized as [WEXITED 127] (see 3b-iv.2.1 commit on rm). *)
  map_status_to_exec_result (Process_eio.run_argv_with_status_split argv)
;;

let run plan =
  let container_name =
    Keeper_container_name.to_string (Keeper_sandbox_oneshot_plan.container_name plan)
  in
  let image = Keeper_sandbox_oneshot_plan.image plan in
  let command = Keeper_sandbox_oneshot_plan.command plan in
  let timeout_sec = Keeper_sandbox_oneshot_plan.timeout_budget_sec plan in
  (* [docker run --rm --name <name> <image> sh -lc <cmd>].
     [--rm] removes the container after exit (Phase 3b-iii default
     cleanup strategy — RFC §3.1's spec deferred a typed cleanup
     policy to a follow-up RFC). [sh -lc] mirrors [exec]'s wrapping
     so caller-passed [cmd] strings work identically across both
     functions. *)
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

(* Pure: parses the stdout of [docker info --format
   '{{json .SecurityOptions}}'] — a JSON array of strings (or [null] /
   [] when the daemon reports none). Items are lowercased so callers
   can match case-insensitively against tokens like ["seccomp"] /
   ["apparmor"] / ["no-new-privileges"]. Non-string array elements are
   dropped (they cannot be a security option). Anything that is
   neither a JSON array nor [null], or that fails to parse, is
   [Probe_format_drift] — a docker-version output change must surface,
   not be silently treated as "no options". *)
let parse_security_options (raw : string)
  : (string list, Docker_client.sandbox_error) result
  =
  match Yojson.Safe.from_string (String.trim raw) with
  | `List items ->
    Ok
      (List.filter_map (function `String s -> Some s | _ -> None) items
       |> List.map String.lowercase_ascii)
  | `Null -> Ok []
  | _ -> Error Docker_client.Probe_format_drift
  | exception Yojson.Json_error _ -> Error Docker_client.Probe_format_drift
;;

let info_security_options () =
  let argv = [ "docker"; "info"; "--format"; "{{json .SecurityOptions}}" ] in
  match Process_eio.run_argv_with_status_split argv with
  | Unix.WEXITED 0, out, _ -> parse_security_options out
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _ ->
    (* Any non-zero exit means the daemon could not answer (not
       running, permission denied, CLI missing → synthesized
       WEXITED 127). The probe itself is a preflight, not a
       container command, so there is no in-container exit code to
       surface as [Ok]. *)
    Error Docker_client.Daemon_unreachable
;;

let image_present ~image =
  (* [docker image inspect <image>] — exit 0 ⇒ present locally. A
     non-zero exit conflates "image not found locally" (exit 1 — the
     common case, the caller may then pull) with "daemon down" (also
     exit 1, with a connection-error message). The shipped
     [keeper_sandbox_runtime.docker_image_present] makes the same
     conflation. We surface [Image_pull_failed] as the single "image
     is not available for this run" signal, except a synthesized
     [WEXITED 127] (docker CLI itself missing), which is unambiguously
     [Daemon_unreachable]. A future RFC could split this into
     [Image_not_found | Daemon_unreachable] if the preflight needs to
     distinguish. [image] is assumed non-empty — the plan layer
     validates that, not this daemon-level call. *)
  let argv = [ "docker"; "image"; "inspect"; image ] in
  match Process_eio.run_argv_with_status argv with
  | Unix.WEXITED 0, _ -> Ok ()
  | Unix.WEXITED 127, _ -> Error Docker_client.Daemon_unreachable
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ ->
    Error Docker_client.Image_pull_failed
;;
