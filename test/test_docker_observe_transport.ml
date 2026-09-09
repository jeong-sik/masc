(* Real Docker feature driver. Python owns container lifecycle and mounts. *)
open Alcotest
module Remote = Masc.Keeper_sandbox_remote
module Target = Masc.Keeper_sandbox_shell_ir_target
module Stage = Masc.Keeper_tool_execute_observe
module Gate = Masc.Keeper_gate
module AQ = Masc.Keeper_approval_queue

let run ~base_path ~container ~missing_container ~receipt_path =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.on_release sw (fun () ->
    Process_eio.reset_for_testing ();
    AQ.For_testing.reset_runtime_state ());
  (match AQ.install_persistence ~base_path with
   | Ok _ -> () | Error error -> fail (AQ.install_error_to_string error));
  let config = Masc.Workspace.default_config base_path in
  (match Masc.Keeper_gate_mode.set config ~actor:"test" Masc.Keeper_gate_mode.Auto_judge with
   | Ok _ -> () | Error error -> fail error);
  let make_endpoint container =
    Remote.of_docker_exec ~base_path ~keeper_name:"docker-probe"
      ~remote_root:"/workspace" ~gh_config_dir:"/workspace/.config/gh"
      ~injected_env:[] ~env_allowlist:[] ~connect_timeout_sec:10
      ~max_concurrent_sessions:1
      { prefix = ["docker"; "exec"; "-i"; container]
      ; probe_prefix = Some ["docker"; "exec"; container]
      ; container_name = container; shim_path = "/usr/local/bin/masc-exec-shim" }
  in
  let endpoint = make_endpoint container in
  check string "Docker identity" "docker_observe" (Remote.lane_prefix (Remote.transport endpoint));
  let rows = ref [] in
  let target_of_runner runner = Masc_exec.Sandbox_target.docker ~image:"fixture" ~runner () in
  let execute label argv =
    let receipts = ref [] in
    let dispatches = ref 0 in
    let dispatch sandbox =
      incr dispatches;
      let program, args = match argv with program :: args -> program, args | [] -> fail "argv" in
      let bin = match Masc_exec.Exec_program.of_string program with
        | Ok bin -> bin | Error _ -> fail "invalid scenario program" in
      let ir = Keeper_tooling.Execute_shell_ir.simple_bin
        ~cwd_raw:"/workspace" ~sandbox bin args in
      Keeper_tooling.Execute_shell_ir.dispatch ~workdir:"/workspace" ~sandbox ir
    in
    let stage = Stage.create ~execution_evidence:(fun () -> List.rev !receipts)
      ~route:(fun () -> Target.observe_route_for_endpoint
        ~on_receipt:(fun receipt -> receipts := receipt :: !receipts)
        ~run:Keeper_types_profile_sandbox.Observe ~timeout_sec:30.
        ~target_of_runner endpoint)
      ~dispatch in
    let request : Gate.request =
      { keeper_name = "docker-probe"; operation = "tool_execute"
      ; input = `Assoc ["input", `Assoc ["argv", `List (List.map (fun a -> `String a) argv)]]
      ; call_summary = None; base_path; causal_context = None; task_id = None
      ; continuation_channel = None
      ; sandbox_profile = Some Keeper_types_profile_sandbox.Docker }
    in
    let decision = Gate.decide ~keeper_always_allow:false ~observe:(Stage.observe stage) request in
    let source = match decision with
      | Gate.Allow { source = (Gate.Observed_in_box _ as source); _ } -> source
      | Gate.Allow _ -> fail (label ^ ": static classification replaced execution evidence")
      | Gate.Deferred _ -> fail (label ^ ": waited for Judge")
      | Gate.Unavailable _ -> fail (label ^ ": Gate unavailable") in
    let result = match Stage.dispatch_authorized ~source ~on_output_chunk:(fun _ -> ())
      ~dispatch:(fun () -> fail "observed result was replayed") with
      | Ok result -> result | Error _ -> fail "execution failed before payload" in
    check int (label ^ ": one payload dispatch") 1 !dispatches;
    check int (label ^ ": one actual receipt") 1 (List.length !receipts);
    (match !receipts with
     | [Remote.Execution_observed ({ mode = Exec_ssh_protocol.Observe;
           boundary = Exec_ssh_protocol.Sandbox_applied }, _)] -> ()
     | _ -> fail (label ^ ": Observe was not acknowledged by the child"));
    let pending = match AQ.pending_count_for_keeper_in_workspace ~base_path ~keeper_name:"docker-probe" with
      | Ok count -> count | Error _ -> fail "approval store unavailable" in
    check int (label ^ ": no Judge request") 0 pending;
    let status = match result.status with Unix.WEXITED code -> `Int code | _ -> `Null in
    rows := `Assoc ["scenario", `String label; "argv", `List (List.map (fun a -> `String a) argv);
      "payload_dispatches", `Int !dispatches; "pending_judgements", `Int pending;
      "exit_code", status; "stdout", `String result.stdout; "stderr", `String result.stderr;
      "receipts", `List (List.map Remote.execution_observation_to_yojson (List.rev !receipts))] :: !rows;
    result
  in
  (* Absolute program paths exercise Observe while name-based Static remains.
     Removing the external-command Static policy belongs to the later PR. *)
  let ls = execute "directory_read" ["/bin/ls"; "sentinel.txt"] in
  check string "ls output" "sentinel.txt\n" ls.stdout;
  let rg = execute "code_search" ["rg"; "-n"; "keep"; "sentinel.txt"] in
  check string "rg output" "1:keep\n" rg.stdout;
  let pwd = execute "guest_path_preserved" ["/bin/pwd"] in
  check string "Docker output remains a guest path" "/workspace\n" pwd.stdout;
  let compiled = execute "file_compile_write_denied" ["/usr/bin/file"; "-C"; "-m"; "probe.magic"] in
  check bool "file compile was denied" true (compiled.status <> Unix.WEXITED 0);
  let fsmonitor = execute "fsmonitor_write_denied" ["/usr/bin/git"; "status"; "--porcelain"] in
  check bool "repository helper actually ran" true
    (String_util.contains_substring fsmonitor.stderr "MASC_FSMONITOR_PROBE");
  (match Target.observe_route_for_endpoint ~run:Keeper_types_profile_sandbox.Guest_local
      ~timeout_sec:30. ~target_of_runner endpoint with
   | Target.No_box _ -> () | Target.Boxed _ -> fail "Docker Guest_local was allowed");
  List.iter (fun mode ->
    let receipts = ref [] in
    let outcome = Remote.runner ~mode ~on_receipt:(fun r -> receipts := r :: !receipts)
      ~timeout_sec:30. endpoint ~on_stdout_chunk:None ~on_stderr_chunk:None
      ~stdin_content:None ~argv:["touch"; "/workspace/forbidden-mode"] ~env:[||] ~cwd:(Some "/workspace") in
    (match outcome with
     | Masc_exec.Sandbox_target.Transport_failed _ -> ()
     | Masc_exec.Sandbox_target.Ran _ -> fail "Docker unboxed mode executed");
    check bool "rejected mode sends no payload" true
      (!receipts = [Remote.Execution_unavailable Remote.Request_not_sent]))
    [Exec_ssh_protocol.Effect; Exec_ssh_protocol.Guest_local];
  let unavailable = make_endpoint missing_container in
  let unsupported_receipts = ref [] in
  let stage = Stage.create ~execution_evidence:(fun () -> !unsupported_receipts)
    ~route:(fun () -> Target.observe_route_for_endpoint
      ~on_receipt:(fun receipt -> unsupported_receipts := receipt :: !unsupported_receipts)
      ~run:Keeper_types_profile_sandbox.Observe ~timeout_sec:30.
      ~target_of_runner unavailable)
    ~dispatch:(fun _ -> fail "missing shim dispatched a payload") in
  let request : Gate.request =
    { keeper_name = "docker-probe"; operation = "tool_execute"
    ; input = `Assoc ["input", `Assoc ["argv", `List [`String "/bin/ls"]]]
    ; call_summary = None; base_path; causal_context = None; task_id = None
    ; continuation_channel = None; sandbox_profile = Some Keeper_types_profile_sandbox.Docker } in
  (match Gate.decide ~keeper_always_allow:false ~observe:(Stage.observe stage) request with
   | Gate.Deferred _ -> ()
   | Gate.Allow _ | Gate.Unavailable _ -> fail "missing shim did not retain ordinary permission handling");
  check bool "no invented receipt for missing shim" true (!unsupported_receipts = []);
  rows := `Assoc ["scenario", `String "missing_shim"; "payload_dispatches", `Int 0;
    "outcome", `String "ordinary_gate_deferred"] :: !rows;
  let oc = open_out receipt_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc (Yojson.Safe.pretty_to_string (`List (List.rev !rows))));
  print_endline "PASS Docker Observe: real receipts, one dispatch, no Judge, no effect replay"

let () =
  if Array.length Sys.argv <> 5 then fail "expected base_path container missing_container receipt_path";
  run ~base_path:Sys.argv.(1) ~container:Sys.argv.(2) ~missing_container:Sys.argv.(3) ~receipt_path:Sys.argv.(4)
