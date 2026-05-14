(** RFC-0070 Phase 3b-iv.2.0 — tests for [Docker_client_real] skeleton.

    Pins the typed-placeholder contract: every function returns
    [Error Cleanup_failed]. Critically, this includes a compile-time
    witness that [Docker_client_real] satisfies [Docker_client.S],
    so the [Sandbox_executor.Make] functor accepts both Mock and
    Real interchangeably.

    Sub-phases 3b-iv.2.{1,2,3,4} replace each placeholder one at a
    time; the corresponding test cases below will be retargeted to
    cover the new behaviour as each sub-phase lands. *)

open Alcotest
open Masc_mcp

(* Compile-time witness: Real satisfies S. *)
let (_ : (module Docker_client.S)) = (module Docker_client_real)

(* And it composes with the executor functor (along with Mock from
   Phase 3b-iv.1b). *)
module Real_executor = Sandbox_executor.Make (Docker_client_real)

let sample_plan () =
  match
    Keeper_sandbox_oneshot_plan.of_request ~turn_id:1 ~attempt:0 ~meta_name:"alice" ~cmd:"echo hi"
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture"
;;

(* Container-name derivation is deterministic in [(turn_id, attempt,
   suffix)], so a literal suffix like ["alice"] could collide with a
   real keeper-derived container on a developer machine and have the
   subsequent [docker rm -f] silently destroy it. Inject PID + a
   nonce into the suffix so the derived SHA-256 is effectively unique
   per test invocation. *)
let () = Random.self_init ()

let sample_container () =
  let pid = Unix.getpid () in
  let nonce = Random.bits () in
  Keeper_container_name.derive
    ~algo:Keeper_hash_algo.SHA_256
    ~turn_id:1
    ~attempt:0
    ~suffix:(Printf.sprintf "test-pid%d-%d" pid nonce)
;;

(* A session plan with a per-invocation-unique meta_name so the derived
   container name cannot collide with a real keeper's. *)
let sample_session_plan () =
  let suffix = Printf.sprintf "test-pid%d-%d" (Unix.getpid ()) (Random.bits ()) in
  match
    Keeper_sandbox_session_plan.of_request
      ~turn_id:3
      ~attempt:0
      ~meta_name:suffix
      ~image:"ubuntu:22.04"
      ~container_root:"/keeper/sess"
      ~base_path:"/srv/masc"
      ~container_kind:"turn"
      ~network_mode:Keeper_types.Network_none
      ~host_root:"/var/masc/sess"
      ~uid:4321
      ~gid:8765
      ()
  with
  | Ok p -> p
  | Error _ -> failwith "test fixture: session of_request failed"
;;

(* ── Each S function returns the typed placeholder ──────────── *)

(* Phase 3b-iv.2.3 — run is no longer a placeholder. It spawns
   [docker run --rm --name <name> <image> sh -lc <cmd>]. Same typed
   contract as [exec]: either [Ok exec_result] (daemon present) or
   [Error Daemon_unreachable] (daemon / CLI missing). No other
   [sandbox_error] variant is semantically valid for [run]. *)
let test_run_returns_typed_result () =
  match Docker_client_real.run (sample_plan ()) with
  | Ok _ -> () (* daemon present *)
  | Error Docker_client.Daemon_unreachable -> () (* daemon / CLI missing *)
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Exec_timeout
  | Error Docker_client.Probe_format_drift ->
    fail "run should only surface Ok exec_result or Error Daemon_unreachable"
;;

(* Phase 3b-iv.2.2 — exec is no longer a placeholder. It spawns
   [docker exec <container> sh -lc <cmd>]. The test environment may
   or may not have a docker daemon, so we only assert the *typed*
   contract: either [Ok exec_result] (daemon present, command ran
   inside container even if it failed) or [Error Daemon_unreachable]
   (no daemon / CLI missing). Other [sandbox_error] variants are
   semantically out of scope for [exec] and must NOT surface. *)
let test_exec_returns_typed_result () =
  match Docker_client_real.exec ~container:(sample_container ()) ~cmd:"echo hi" () with
  | Ok _ -> () (* daemon present *)
  | Error Docker_client.Daemon_unreachable -> () (* daemon / CLI missing *)
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Exec_timeout
  | Error Docker_client.Probe_format_drift ->
    fail "exec should only surface Ok exec_result or Error Daemon_unreachable"
;;

(* Phase 3e (b) — [exec_argv] is the pure argv builder behind [exec].
   Deterministic (no daemon needed): assert option presence and the
   [--user]-before-[-w] ordering. The container suffix is PID+nonce so
   its string form is unique per invocation; the test only checks it
   lands in the right position. *)
let test_exec_argv_plain () =
  let c = sample_container () in
  check
    (list string)
    "no user, no workdir"
    [ "docker"; "exec"; Keeper_container_name.to_string c; "sh"; "-lc"; "ls -la" ]
    (Docker_client_real.exec_argv ~container:c ~cmd:"ls -la" ())
;;

let test_exec_argv_user_only () =
  let c = sample_container () in
  check
    (list string)
    "user only → --user uid:gid"
    [ "docker"
    ; "exec"
    ; "--user"
    ; "1000:1000"
    ; Keeper_container_name.to_string c
    ; "sh"
    ; "-lc"
    ; "id"
    ]
    (Docker_client_real.exec_argv ~user:(1000, 1000) ~container:c ~cmd:"id" ())
;;

let test_exec_argv_workdir_only () =
  let c = sample_container () in
  check
    (list string)
    "workdir only → -w <dir>"
    [ "docker"; "exec"; "-w"; "/work"; Keeper_container_name.to_string c; "sh"; "-lc"; "pwd" ]
    (Docker_client_real.exec_argv ~workdir:"/work" ~container:c ~cmd:"pwd" ())
;;

let test_exec_argv_user_and_workdir () =
  let c = sample_container () in
  check
    (list string)
    "user + workdir → --user before -w"
    [ "docker"
    ; "exec"
    ; "--user"
    ; "1000:1000"
    ; "-w"
    ; "/work"
    ; Keeper_container_name.to_string c
    ; "sh"
    ; "-lc"
    ; "whoami"
    ]
    (Docker_client_real.exec_argv
       ~user:(1000, 1000)
       ~workdir:"/work"
       ~container:c
       ~cmd:"whoami"
       ())
;;

(* Phase 4.1-h — [?stdin] is the third optional. When true, the argv
   gains [-i] after [-w] (and after [--user]); the content itself is
   never in the argv. Default is [false] (no [-i]). *)
let test_exec_argv_stdin_only_emits_dash_i () =
  let c = sample_container () in
  check
    (list string)
    "stdin=true → -i after the keyless slot"
    [ "docker"
    ; "exec"
    ; "-i"
    ; Keeper_container_name.to_string c
    ; "sh"
    ; "-lc"
    ; "cat > /tmp/x"
    ]
    (Docker_client_real.exec_argv ~stdin:true ~container:c ~cmd:"cat > /tmp/x" ())
;;

let test_exec_argv_stdin_false_omits_dash_i () =
  let c = sample_container () in
  let argv =
    Docker_client_real.exec_argv ~stdin:false ~container:c ~cmd:"echo hi" ()
  in
  check bool "stdin=false ⇒ no -i" false (List.mem "-i" argv);
  check
    (list string)
    "stdin=false matches the plain shape"
    [ "docker"; "exec"; Keeper_container_name.to_string c; "sh"; "-lc"; "echo hi" ]
    argv
;;

let test_exec_argv_user_workdir_stdin_full_order () =
  let c = sample_container () in
  check
    (list string)
    "user + workdir + stdin → --user before -w before -i"
    [ "docker"
    ; "exec"
    ; "--user"
    ; "1000:1000"
    ; "-w"
    ; "/work"
    ; "-i"
    ; Keeper_container_name.to_string c
    ; "sh"
    ; "-lc"
    ; "tee /tmp/x"
    ]
    (Docker_client_real.exec_argv
       ~user:(1000, 1000)
       ~workdir:"/work"
       ~stdin:true
       ~container:c
       ~cmd:"tee /tmp/x"
       ())
;;

let test_exec_argv_stdin_default_is_false () =
  (* Omitting [?stdin] altogether is the same as [~stdin:false]: the
     default is "no -i", because most exec calls don't pipe stdin. *)
  let c = sample_container () in
  let argv = Docker_client_real.exec_argv ~container:c ~cmd:"echo hi" () in
  check bool "no ?stdin ⇒ no -i" false (List.mem "-i" argv)
;;

let test_ps_query_placeholder () =
  match Docker_client_real.ps_query ~labels:[] with
  | Error Docker_client.Cleanup_failed -> ()
  | _ -> fail "expected Cleanup_failed placeholder"
;;

(* Phase 3b-iv.2.1 — rm is no longer a placeholder; it spawns
   [docker rm -f <name>]. The test environment may or may not have a
   docker daemon, so we only assert that the *typed* error variants
   are surfaced (no exception leakage, no silent success). *)
let test_rm_returns_typed_error () =
  match Docker_client_real.rm (sample_container ()) with
  | Error Docker_client.Daemon_unreachable | Error Docker_client.Cleanup_failed ->
    () (* env-dependent path *)
  | Ok () -> fail "unexpected Ok — derived container name should not exist on host"
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Exec_timeout
  | Error Docker_client.Probe_format_drift ->
    fail "rm should only surface Daemon_unreachable or Cleanup_failed"
;;

(* Phase 3e (c) — [parse_security_options] is the pure parser behind
   [info_security_options]. Deterministic (no daemon): assert array
   handling, lowercasing, non-string drop, and that a format drift
   surfaces as [Probe_format_drift] rather than [Ok []]. *)
let security_options_result : (string list, Docker_client.sandbox_error) result testable =
  let pp ppf = function
    | Ok xs -> Format.fprintf ppf "Ok [%s]" (String.concat "; " xs)
    | Error e -> Format.fprintf ppf "Error %s" (match e with
        | Docker_client.Daemon_unreachable -> "Daemon_unreachable"
        | Docker_client.Image_pull_failed -> "Image_pull_failed"
        | Docker_client.Container_oom -> "Container_oom"
        | Docker_client.Exec_timeout -> "Exec_timeout"
        | Docker_client.Probe_format_drift -> "Probe_format_drift"
        | Docker_client.Cleanup_failed -> "Cleanup_failed")
  in
  testable pp ( = )
;;

let test_parse_security_options_array () =
  check
    security_options_result
    "array of strings, preserved order"
    (Ok [ "name=seccomp,profile=builtin"; "name=cgroupns" ])
    (Docker_client_real.parse_security_options
       {|["name=seccomp,profile=builtin","name=cgroupns"]|})
;;

let test_parse_security_options_lowercases () =
  check
    security_options_result
    "items lowercased"
    (Ok [ "name=apparmor" ])
    (Docker_client_real.parse_security_options {|["name=AppArmor"]|})
;;

let test_parse_security_options_null () =
  check
    security_options_result
    "null → Ok []"
    (Ok [])
    (Docker_client_real.parse_security_options "null")
;;

let test_parse_security_options_empty_array () =
  check
    security_options_result
    "[] → Ok []"
    (Ok [])
    (Docker_client_real.parse_security_options "[]")
;;

let test_parse_security_options_drops_non_strings () =
  check
    security_options_result
    "non-string elements dropped"
    (Ok [ "name=seccomp" ])
    (Docker_client_real.parse_security_options {|["name=seccomp", 1, true, null]|})
;;

let test_parse_security_options_bad_json () =
  check
    security_options_result
    "malformed JSON → Probe_format_drift (not silent Ok [])"
    (Error Docker_client.Probe_format_drift)
    (Docker_client_real.parse_security_options "not valid json {")
;;

let test_parse_security_options_object () =
  check
    security_options_result
    "JSON object (not array/null) → Probe_format_drift"
    (Error Docker_client.Probe_format_drift)
    (Docker_client_real.parse_security_options {|{"x":1}|})
;;

(* The edge call: env may or may not have a docker daemon, so only
   the typed contract is asserted. *)
let test_info_security_options_returns_typed () =
  match Docker_client_real.info_security_options () with
  | Ok _ -> () (* daemon present *)
  | Error Docker_client.Daemon_unreachable -> () (* no daemon / CLI missing *)
  | Error Docker_client.Probe_format_drift ->
    () (* daemon present but unexpected SecurityOptions payload *)
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Exec_timeout ->
    fail
      "info_security_options should only surface Ok | Daemon_unreachable | \
       Probe_format_drift"
;;

(* Phase 3e (d) — [image_present] runs [docker image inspect <image>].
   Env-dependent: a present image ⇒ [Ok ()], an absent one ⇒
   [Image_pull_failed] (or [Daemon_unreachable] if docker is missing).
   Only the typed contract is asserted; a random-looking image name
   means [Ok] is unlikely on a clean host but not impossible, so it is
   accepted. The forbidden variants would indicate a mapping bug. *)
let test_image_present_returns_typed () =
  match Docker_client_real.image_present ~image:"definitely-not-a-real-image:0xnope" with
  | Ok () -> () (* extremely unlikely, but a real local image with this name is legal *)
  | Error Docker_client.Image_pull_failed -> () (* not present locally / daemon down *)
  | Error Docker_client.Daemon_unreachable -> () (* docker CLI missing *)
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Exec_timeout
  | Error Docker_client.Probe_format_drift ->
    fail "image_present should only surface Ok | Image_pull_failed | Daemon_unreachable"
;;

(* Phase 3e-a — [run_detached_argv] is the pure argv builder behind
   [run_detached]. Deterministic given (plan, seccomp_args, owner_pid,
   started_at): assert the structural shape — the [run -d --rm --name]
   prefix, the two spawn-time labels carrying the passed pid/clock, the
   passed seccomp args, the plan's mounts as [-v], the hardening flags,
   and the trailing [image; sh; -lc; startup]. Config-driven values
   (ulimits/pids/memory/tmpfs) are not asserted byte-for-byte — that
   would just re-read the config the impl reads. *)
let rec ends_with suffix lst =
  let ln = List.length lst and sn = List.length suffix in
  if sn > ln then false
  else if sn = ln then List.equal String.equal suffix lst
  else (match lst with _ :: tl -> ends_with suffix tl | [] -> false)
;;

let test_run_detached_argv_shape () =
  let plan = sample_session_plan () in
  let argv =
    Docker_client_real.run_detached_argv
      plan
      ~seccomp_args:[ "--security-opt"; "seccomp=/tmp/test-profile.json" ]
      ~owner_pid:424242
      ~started_at:1234.5
  in
  let name = Keeper_container_name.to_string (Keeper_sandbox_session_plan.container_name plan) in
  (* prefix: ...; "run"; "-d"; "--rm"; "--name"; <name>; ... *)
  let rec has_run_prefix = function
    | "run" :: "-d" :: "--rm" :: "--name" :: n :: _ -> String.equal n name
    | _ :: tl -> has_run_prefix tl
    | [] -> false
  in
  check bool "argv has `run -d --rm --name <derived>`" true (has_run_prefix argv);
  check bool "owner_pid label = passed pid" true
    (List.mem "masc.mcp.owner_pid=424242" argv);
  check bool "started_at label = %.3f of passed clock" true
    (List.mem "masc.mcp.started_at=1234.500" argv);
  check bool "the 7 deterministic labels are present (component)" true
    (List.mem "masc.mcp.component=keeper-sandbox" argv);
  check bool "passed seccomp args spliced in" true
    (List.mem "seccomp=/tmp/test-profile.json" argv);
  check bool "hardening: --cap-drop=ALL" true (List.mem "--cap-drop=ALL" argv);
  check bool "hardening: no-new-privileges" true (List.mem "no-new-privileges" argv);
  List.iter
    (fun m -> check bool (Printf.sprintf "mount %S present as -v arg" m) true (List.mem m argv))
    (Keeper_sandbox_session_plan.mounts plan);
  check bool "ends with [image; sh; -lc; startup_command]" true
    (ends_with
       [ Keeper_sandbox_session_plan.image plan
       ; "sh"
       ; "-lc"
       ; Keeper_sandbox_session_plan.startup_command plan
       ]
       argv)
;;

let test_run_detached_returns_typed () =
  (* Env may or may not have a docker daemon; the identity-file write
     targets a real path under /var/masc/sess which likely does not
     exist or is not writable on a CI box → Daemon_unreachable. With a
     daemon + writable host_root the spawn could succeed → Ok name. Only
     the typed contract is asserted. *)
  match Docker_client_real.run_detached (sample_session_plan ()) with
  | Ok _ -> () (* daemon present + identity files written + spawn ok *)
  | Error Docker_client.Daemon_unreachable -> () (* identity-write failure / no daemon / spawn failure *)
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Exec_timeout
  | Error Docker_client.Probe_format_drift
  | Error Docker_client.Cleanup_failed ->
    fail "run_detached should only surface Ok <name> | Daemon_unreachable"
;;

(* ── Functor instantiation works with Real ───────────────────── *)

(* Phase 3b-iv.2.3 — executor.execute_plan calls Real.run, which is
   now wired. Same typed contract as test_run_returns_typed_result. *)
let test_executor_with_real_returns_typed_result () =
  match Real_executor.execute_plan (sample_plan ()) with
  | Ok _ -> ()
  | Error Docker_client.Daemon_unreachable -> ()
  | Error Docker_client.Cleanup_failed
  | Error Docker_client.Image_pull_failed
  | Error Docker_client.Container_oom
  | Error Docker_client.Exec_timeout
  | Error Docker_client.Probe_format_drift ->
    fail "executor with Real should only surface Ok or Daemon_unreachable"
;;

(* ── is_eintr_127 (pure, Phase 4.1-g) ─────────────────────────── *)

let test_is_eintr_127_true_on_127_with_marker () =
  (* The marker is matched case-insensitively and as a substring of the
     combined stdout/stderr the spawn produced. *)
  check
    bool
    "WEXITED 127 + \"interrupted system call\" ⇒ retry"
    true
    (Docker_client_real.is_eintr_127
       (Unix.WEXITED 127)
       "docker: fork/exec /usr/bin/docker: interrupted system call");
  check
    bool
    "marker is case-insensitive"
    true
    (Docker_client_real.is_eintr_127 (Unix.WEXITED 127) "Interrupted System Call")
;;

let test_is_eintr_127_false_on_127_without_marker () =
  check
    bool
    "WEXITED 127 without the marker (genuine missing CLI) ⇒ no retry"
    false
    (Docker_client_real.is_eintr_127
       (Unix.WEXITED 127)
       "docker: command not found")
;;

let test_is_eintr_127_false_on_other_exit_codes () =
  (* Only 127 — a 125 ("daemon error") that happens to mention the
     phrase is still a daemon error, not an EINTR. *)
  check
    bool
    "WEXITED 125 + marker ⇒ no retry (only 127 is the EINTR sentinel)"
    false
    (Docker_client_real.is_eintr_127 (Unix.WEXITED 125) "interrupted system call");
  check
    bool
    "WEXITED 0 ⇒ no retry"
    false
    (Docker_client_real.is_eintr_127 (Unix.WEXITED 0) "interrupted system call")
;;

let test_is_eintr_127_false_on_signal () =
  check
    bool
    "WSIGNALED ⇒ no retry"
    false
    (Docker_client_real.is_eintr_127 (Unix.WSIGNALED 9) "interrupted system call")
;;

let test_exec_gate_blocked_detects_126_sentinel () =
  check
    bool
    "blocked"
    true
    (Docker_client_real.is_exec_gate_blocked
       (Unix.WEXITED 126)
       "exec_gate_blocked: policy denied")
;;

let test_exec_gate_blocked_rejects_plain_126 () =
  check
    bool
    "plain 126"
    false
    (Docker_client_real.is_exec_gate_blocked (Unix.WEXITED 126) "permission denied")
;;

let test_docker_real_timeout_budgets_are_separated () =
  (* Pin env vars to sentinels so assertions are deterministic regardless
     of the host environment. Restore originals on exit. *)
  let pin key value = Unix.putenv key (string_of_float value) in
  let snap key = try Some (key, Unix.getenv key) with Not_found -> None in
  let saved =
    List.filter_map snap
      [ "MASC_EXEC_TIMEOUT_SHELL_SEC"
      ; "MASC_EXEC_TIMEOUT_SANDBOX_SEC"
      ; "MASC_EXEC_TIMEOUT_TURN_UP_SEC"
      ; "MASC_EXEC_TIMEOUT_TURN_SANDBOX_SEC"
      ]
  in
  pin "MASC_EXEC_TIMEOUT_SHELL_SEC" 60.0;
  pin "MASC_EXEC_TIMEOUT_SANDBOX_SEC" 10.0;
  pin "MASC_EXEC_TIMEOUT_TURN_UP_SEC" 15.0;
  pin "MASC_EXEC_TIMEOUT_TURN_SANDBOX_SEC" 2.0;
  Fun.protect
    ~finally:(fun () ->
      List.iter (function k, v -> Unix.putenv k v) saved)
    (fun () ->
      check
        (float 0.001)
        "exec keeps shell budget"
        60.0
        (Docker_client_real.session_exec_timeout_sec ());
      check
        (float 0.001)
        "probe keeps sandbox budget"
        10.0
        (Docker_client_real.docker_probe_timeout_sec ());
      check
        (float 0.001)
        "start keeps turn-up budget"
        15.0
        (Docker_client_real.session_start_timeout_sec ());
      check
        (float 0.001)
        "preflight keeps short turn-sandbox budget"
        2.0
        (Docker_client_real.session_preflight_timeout_sec ()))
;;

let () =
  run
    "Docker_client_real (Phase 3b-iv.2.3)"
    [ ( "S placeholder"
      , [ test_case
            "run → Ok exec_result | Error Daemon_unreachable"
            `Quick
            test_run_returns_typed_result
        ; test_case
            "exec → Ok exec_result | Error Daemon_unreachable"
            `Quick
            test_exec_returns_typed_result
        ; test_case "ps_query → Cleanup_failed" `Quick test_ps_query_placeholder
        ; test_case
            "rm → typed error (Daemon_unreachable | Cleanup_failed)"
            `Quick
            test_rm_returns_typed_error
        ] )
    ; ( "exec_argv (pure, Phase 3e b)"
      , [ test_case "plain (no user/workdir)" `Quick test_exec_argv_plain
        ; test_case "user only" `Quick test_exec_argv_user_only
        ; test_case "workdir only" `Quick test_exec_argv_workdir_only
        ; test_case
            "user + workdir (--user before -w)"
            `Quick
            test_exec_argv_user_and_workdir
        ] )
    ; ( "exec_argv ?stdin (pure, Phase 4.1-h)"
      , [ test_case "stdin=true ⇒ -i present" `Quick test_exec_argv_stdin_only_emits_dash_i
        ; test_case
            "stdin=false ⇒ no -i + plain shape"
            `Quick
            test_exec_argv_stdin_false_omits_dash_i
        ; test_case
            "user + workdir + stdin: --user before -w before -i"
            `Quick
            test_exec_argv_user_workdir_stdin_full_order
        ; test_case "?stdin default is false" `Quick test_exec_argv_stdin_default_is_false
        ] )
    ; ( "parse_security_options (pure, Phase 3e c)"
      , [ test_case "array of strings" `Quick test_parse_security_options_array
        ; test_case "lowercases items" `Quick test_parse_security_options_lowercases
        ; test_case "null → Ok []" `Quick test_parse_security_options_null
        ; test_case "[] → Ok []" `Quick test_parse_security_options_empty_array
        ; test_case
            "drops non-string elements"
            `Quick
            test_parse_security_options_drops_non_strings
        ; test_case
            "malformed JSON → Probe_format_drift"
            `Quick
            test_parse_security_options_bad_json
        ; test_case
            "object (not array/null) → Probe_format_drift"
            `Quick
            test_parse_security_options_object
        ; test_case
            "info_security_options → Ok | Daemon_unreachable | Probe_format_drift"
            `Quick
            test_info_security_options_returns_typed
        ] )
    ; ( "image_present (Phase 3e d)"
      , [ test_case
            "image_present → Ok | Image_pull_failed | Daemon_unreachable"
            `Quick
            test_image_present_returns_typed
        ] )
    ; ( "run_detached (Phase 3e a)"
      , [ test_case "run_detached_argv: structural shape" `Quick test_run_detached_argv_shape
        ; test_case
            "run_detached → Ok <name> | Daemon_unreachable"
            `Quick
            test_run_detached_returns_typed
        ] )
    ; ( "Functor composition"
      , [ test_case
            "Sandbox_executor.Make (Real) instantiates + forwards placeholder"
            `Quick
            test_executor_with_real_returns_typed_result
        ] )
    ; ( "is_eintr_127 (pure, Phase 4.1-g)"
      , [ test_case
            "127 + marker (any case) ⇒ true"
            `Quick
            test_is_eintr_127_true_on_127_with_marker
        ; test_case
            "127 without marker ⇒ false"
            `Quick
            test_is_eintr_127_false_on_127_without_marker
        ; test_case
            "non-127 exit codes ⇒ false"
            `Quick
            test_is_eintr_127_false_on_other_exit_codes
        ; test_case "signal ⇒ false" `Quick test_is_eintr_127_false_on_signal
        ] )
    ; ( "exec gate / timeout policy (pure, Phase 4.1-g)"
      , [ test_case
            "126 + exec_gate_blocked marker ⇒ true"
            `Quick
            test_exec_gate_blocked_detects_126_sentinel
        ; test_case
            "plain 126 ⇒ false"
            `Quick
            test_exec_gate_blocked_rejects_plain_126
        ; test_case
            "Docker real timeout callers stay separated"
            `Quick
            test_docker_real_timeout_budgets_are_separated
        ] )
    ]
;;
