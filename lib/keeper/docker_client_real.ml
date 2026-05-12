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
  | Unix.WEXITED 126
    when String_util.contains_substring_ci (stdout ^ "\n" ^ stderr) "exec_gate_blocked:"
    -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED 125 | Unix.WEXITED 127 -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED code -> Ok Docker_response.{ exit_code = code; stdout; stderr }
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Docker_client.Daemon_unreachable
;;

(* ── Gated spawn (RFC-0070 Phase 4.1-g) ──────────────────────────
   All docker spawns go through {!Masc_exec.Exec_gate} with
   [~actor:`System_task_sandbox], the same actor the keeper sandbox
   subsystem already uses ([keeper_sandbox_runtime], [keeper_docker_read],
   [keeper_turn_sandbox_runtime]). Before this phase the [Real] client
   called [Process_eio.run_argv_with_status*] directly, bypassing the
   gate's actor accounting / approval-policy hook — a regression once a
   caller like [keeper_turn_sandbox_runtime] (which today gates its own
   spawns) is cut over to this client. Routing through [Exec_gate] keeps
   that behaviour; the gate itself delegates to [Process_eio], so the
   spawn semantics (synthesized [WEXITED 127] on exec failure, etc.) are
   unchanged.

   EINTR-retry: a [WEXITED 127] whose output mentions "interrupted
   system call" is a transient EINTR on spawn, not a missing CLI —
   retry up to [max_eintr_retries] times before letting it fall through
   to the [WEXITED 127] → [Daemon_unreachable] mapping. Mirrors
   [keeper_turn_sandbox_runtime.run_argv_with_status_retry_eintr]; the
   Phase 4.1 cutover deletes that copy in favour of this one. *)

let max_eintr_retries = 8

let is_eintr_127 (status : Unix.process_status) (out : string) =
  match status with
  | Unix.WEXITED 127 -> String_util.contains_substring_ci out "interrupted system call"
  | _ -> false
;;

let is_exec_gate_blocked (status : Unix.process_status) (out : string) =
  match status with
  | Unix.WEXITED 126 -> String_util.contains_substring_ci out "exec_gate_blocked:"
  | _ -> false
;;

let docker_probe_timeout_sec () =
  Env_config_exec_timeout.timeout_sec ~caller:Env_config_exec_timeout.Sandbox ()
;;

let session_exec_timeout_sec () =
  Env_config_exec_timeout.timeout_sec ~caller:Env_config_exec_timeout.Shell ()
;;

let session_start_timeout_sec () =
  Env_config_exec_timeout.timeout_sec ~caller:Env_config_exec_timeout.Turn_up ()
;;

let session_preflight_timeout_sec () =
  Env_config_exec_timeout.timeout_sec ~caller:Env_config_exec_timeout.Turn_sandbox ()
;;

(* Docker probe timeout default.  [Exec_gate.run_argv_with_status*]
   all carry a hard-coded [?(timeout_sec = 60.0)] default that bypasses
   the per-caller env override ([MASC_EXEC_TIMEOUT_SANDBOX_SEC]); routing
   through [Env_config_exec_timeout] keeps the SSOT live for short
   daemon probes that omit a caller-specific timeout. *)
let default_timeout_sec () =
  docker_probe_timeout_sec ()
;;

let gated_argv_with_status ?timeout_sec ~(summary : string) argv =
  let timeout_sec =
    match timeout_sec with
    | Some t -> t
    | None -> default_timeout_sec ()
  in
  let rec loop attempts_left =
    let status, out =
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:`System_task_sandbox
        ~raw_source:(String.concat " " argv)
        ~summary
        ~timeout_sec
        argv
    in
    if attempts_left > 0 && is_eintr_127 status out
    then loop (attempts_left - 1)
    else status, out
  in
  loop max_eintr_retries
;;

let gated_argv_with_status_split ?timeout_sec ~(summary : string) argv =
  let timeout_sec =
    match timeout_sec with
    | Some t -> t
    | None -> default_timeout_sec ()
  in
  let rec loop attempts_left =
    let status, stdout, stderr =
      Masc_exec.Exec_gate.run_argv_with_status_split
        ~actor:`System_task_sandbox
        ~raw_source:(String.concat " " argv)
        ~summary
        ~timeout_sec
        argv
    in
    (* Join with a newline so a marker spanning the stream boundary
       (stdout ends with "interrupted", stderr begins with "system
       call") still matches [is_eintr_127]. *)
    if attempts_left > 0 && is_eintr_127 status (stdout ^ "\n" ^ stderr)
    then loop (attempts_left - 1)
    else status, stdout, stderr
  in
  loop max_eintr_retries
;;

(* Mirror of {!gated_argv_with_status_split} for the stdin-piped case
   (RFC-0070 Phase 4.1-h). Wraps
   [Masc_exec.Exec_gate.run_argv_with_stdin_and_status_split] and reuses
   the same EINTR-retry contract — a [WEXITED 127] whose combined
   stdout/stderr mentions the EINTR marker is retried up to
   [max_eintr_retries] times. Used by {!exec} when [?stdin] is
   [Some _]. *)
let gated_argv_with_stdin_and_status_split
      ?timeout_sec
      ~(summary : string)
      ~(stdin_content : string)
      argv
  =
  let timeout_sec =
    match timeout_sec with
    | Some t -> t
    | None -> default_timeout_sec ()
  in
  let rec loop attempts_left =
    let status, stdout, stderr =
      Masc_exec.Exec_gate.run_argv_with_stdin_and_status_split
        ~actor:`System_task_sandbox
        ~raw_source:(String.concat " " argv)
        ~summary
        ~timeout_sec
        ~stdin_content
        argv
    in
    if attempts_left > 0 && is_eintr_127 status (stdout ^ "\n" ^ stderr)
    then loop (attempts_left - 1)
    else status, stdout, stderr
  in
  loop max_eintr_retries
;;

(* ── Functions ───────────────────────────────────────────────── *)

let ps_query ~labels:_ = placeholder

(* Pure: builds the [docker exec] argv. Separated from {!exec} so the
   argv shape is unit-testable without a daemon (RFC-0070's pure/edge
   split — deterministic argv construction here, daemon spawn in
   {!exec}). [--user] precedes [-w] to match the order
   [keeper_turn_sandbox_runtime] currently emits.

   [?stdin] is a [bool], not the content itself — the *content* is
   never part of the argv (it is piped on stdin by {!exec}), so the
   pure builder only needs to know whether to emit the [-i] flag. *)
let exec_argv ?user ?workdir ?(stdin = false) ~container ~cmd () =
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
  let stdin_args = if stdin then [ "-i" ] else [] in
  [ "docker"; "exec" ]
  @ user_args
  @ workdir_args
  @ stdin_args
  @ [ Keeper_container_name.to_string container; "sh"; "-lc"; cmd ]
;;

let exec ?user ?workdir ?stdin ~container ~cmd () =
  let argv =
    exec_argv ?user ?workdir ~stdin:(Option.is_some stdin) ~container ~cmd ()
  in
  (* Gated spawn returns [(status, stdout, stderr)]; on spawn failure
     the status is synthesized as [WEXITED 127] (see 3b-iv.2.1 commit
     on rm). [?stdin] toggles between the no-stdin gate
     ({!gated_argv_with_status_split}) and the stdin-piped gate
     ({!gated_argv_with_stdin_and_status_split}) — both share the same
     EINTR-retry contract. *)
  match stdin with
  | None ->
    map_status_to_exec_result
      (gated_argv_with_status_split
         ~timeout_sec:(session_exec_timeout_sec ())
         ~summary:"keeper docker exec"
         argv)
  | Some stdin_content ->
    map_status_to_exec_result
      (gated_argv_with_stdin_and_status_split
         ~timeout_sec:(session_exec_timeout_sec ())
         ~summary:"keeper docker exec (stdin-piped)"
         ~stdin_content
         argv)
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
  map_status_to_exec_result
    (gated_argv_with_status_split ~timeout_sec ~summary:"keeper docker run (oneshot)" argv)
;;

let rm container =
  let argv = [ "docker"; "rm"; "-f"; Keeper_container_name.to_string container ] in
  let status, combined_out = gated_argv_with_status ~summary:"keeper docker rm" argv in
  if is_exec_gate_blocked status combined_out
  then Error Docker_client.Daemon_unreachable
  else map_exit_status_for_rm status
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
  match
    gated_argv_with_status_split ~summary:"keeper docker info security-options" argv
  with
  | Unix.WEXITED 0, out, _ -> parse_security_options out
  | status, out, err when is_exec_gate_blocked status (out ^ "\n" ^ err) ->
    Error Docker_client.Daemon_unreachable
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
  match gated_argv_with_status ~summary:"keeper docker image inspect" argv with
  | Unix.WEXITED 0, _ -> Ok ()
  | status, out when is_exec_gate_blocked status out ->
    Error Docker_client.Daemon_unreachable
  | Unix.WEXITED 127, _ -> Error Docker_client.Daemon_unreachable
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ ->
    Error Docker_client.Image_pull_failed
;;

(* ── run_detached (Phase 3e-a) ──────────────────────────────────
   The session-spawn edge: writes the plan's identity_files, resolves
   the seccomp choice (a daemon probe), appends the spawn-time
   owner_pid / started_at labels, prepends docker_command_argv (), and
   spawns [docker run -d --rm --name <derived> ...]. Returns the
   plan's Container_name.t (deterministic — we already know the name;
   no [docker inspect] round-trip needed for the name). *)

let label_arg (k, v) = [ "--label"; k ^ "=" ^ v ]
let env_arg (k, v) = [ "--env"; k ^ "=" ^ v ]

let ulimit_arg (u : Keeper_sandbox_session_plan.ulimit) =
  [ "--ulimit"; Printf.sprintf "%s=%d:%d" u.name u.soft u.hard ]
;;

let user_args = function
  | None -> []
  | Some (uid, gid) -> [ "--user"; Printf.sprintf "%d:%d" uid gid ]
;;

let workdir_args = function
  | None -> []
  | Some w -> [ "--workdir"; w ]
;;

(* Pure: assembles the [docker run -d] argv from the plan plus the
   spawn-time bits the plan deliberately omits (resolved [seccomp_args],
   [owner_pid], [started_at]). Separated from {!run_detached} so the argv
   shape is unit-testable without writing files / probing a daemon /
   reading the clock. Flag ordering follows
   [keeper_turn_sandbox_runtime.start_container] closely; where it
   differs it is only [-v]/[--workdir] interleaving, which docker treats
   order-independently. *)
let run_detached_argv
      (plan : Keeper_sandbox_session_plan.t)
      ~(seccomp_args : string list)
      ~(owner_pid : int)
      ~(started_at : float)
  =
  let module P = Keeper_sandbox_session_plan in
  let edge_labels =
    [ Keeper_sandbox_runtime.sandbox_owner_pid_label_key, string_of_int owner_pid
    ; ( Keeper_sandbox_runtime.sandbox_started_at_label_key
      , Printf.sprintf "%.3f" started_at )
    ]
  in
  let read_only = if P.read_only_rootfs plan then [ "--read-only" ] else [] in
  let network_args, _network_label =
    Keeper_sandbox_runtime.docker_network_args (P.network_mode plan)
  in
  Keeper_sandbox_runtime.docker_command_argv ()
  @ [ "run"; "-d"; "--rm"; "--name"; Keeper_container_name.to_string (P.container_name plan) ]
  @ List.concat_map label_arg (P.labels plan @ edge_labels)
  @ user_args (P.user plan)
  @ List.concat_map env_arg (P.env_overrides plan)
  @ List.concat_map ulimit_arg (P.ulimits plan)
  @ read_only
  @ [ "--tmpfs"; P.tmpfs_mount plan; "--cap-drop=ALL"; "--security-opt"; "no-new-privileges" ]
  @ seccomp_args
  @ [ "--pids-limit"; string_of_int (P.pids_limit plan); "--memory"; P.memory_limit plan ]
  @ List.concat_map (fun v -> [ "-v"; v ]) (P.mounts plan)
  @ workdir_args (P.workdir plan)
  @ network_args
  @ [ P.image plan; "sh"; "-lc"; P.startup_command plan ]
;;

let write_identity_files (plan : Keeper_sandbox_session_plan.t) =
  (* Each (path, content): mkdir_p the parent then atomic-write. Any
     failure means the identity mounts won't be valid, so the spawn
     would produce a broken container — surface it as a typed error
     rather than spawning anyway. [Daemon_unreachable] is the closest
     existing variant ("cannot stand up a container"); a future RFC
     could add a dedicated [Identity_setup_failed]. *)
  let rec go = function
    | [] -> Ok ()
    | (path, content) :: rest ->
      (match
         (try
            Fs_compat.mkdir_p (Filename.dirname path);
            Fs_compat.save_file_atomic path content
          with
          | Sys_error msg | Unix.Unix_error (_, _, msg) -> Error msg)
       with
       | Ok () -> go rest
       | Error _ -> Error Docker_client.Daemon_unreachable)
  in
  go (Keeper_sandbox_session_plan.identity_files plan)
;;

let run_detached (plan : Keeper_sandbox_session_plan.t) =
  match write_identity_files plan with
  | Error _ as err -> err
  | Ok () ->
    let ensure_timeout = session_preflight_timeout_sec () in
    let start_timeout = session_start_timeout_sec () in
    (match Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec:ensure_timeout with
     | Error _ ->
       (* docker runtime could not be ensured — daemon-level. *)
       Error Docker_client.Daemon_unreachable
     | Ok seccomp_args ->
       let argv =
         run_detached_argv
           plan
           ~seccomp_args
           ~owner_pid:(Unix.getpid ())
           ~started_at:(Unix.gettimeofday ())
       in
       (match
         gated_argv_with_status_split
            ~timeout_sec:start_timeout
            ~summary:"keeper docker run -d (session)"
            argv
        with
        | Unix.WEXITED 0, _, _ -> Ok (Keeper_sandbox_session_plan.container_name plan)
        | Unix.WEXITED 125, _, _ ->
          (* [docker run] itself failed — bad flag, image not pullable,
             daemon error. The keeper preflight ([image_present]) runs
             before this, so a missing image is unlikely here. Surface
             as [Daemon_unreachable] (the "cannot run a container"
             class); a future RFC could distinguish. *)
          Error Docker_client.Daemon_unreachable
        | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _ ->
          Error Docker_client.Daemon_unreachable))
;;
