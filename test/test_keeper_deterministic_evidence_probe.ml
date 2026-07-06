open Alcotest

module Probe = Masc.Keeper_deterministic_evidence_probe
module Workspace = Masc.Workspace
module Keeper_registry = Masc.Keeper_registry

let temp_dir () =
  let d = Filename.temp_file "keeper_evidence_probe_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  rm dir

let make_meta ?(sandbox = Keeper_types_profile_sandbox.Local) name =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("agent-" ^ name)
      ; "trace_id", `String ("trace-" ^ name)
      ; "goal", `String "deterministic evidence probe"
      ; "allowed_paths", `List [ `String "*" ]
      ; ( "sandbox_profile"
        , `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) )
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let with_eio_runtime f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()

let with_fixture ?sandbox f =
  with_eio_runtime @@ fun () ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
      Keeper_registry.clear ();
      let config = Workspace.default_config base_path in
      let meta = make_meta ?sandbox "probe-keeper" in
      ignore (Keeper_registry.register ~base_path meta.name meta);
      f ~config ~meta)

let tests_pass command =
  Evidence_claim.Tests_pass { command; expected_exit = 0 }

let test_local_tests_pass_runs_in_local_target () =
  with_fixture @@ fun ~config ~meta ->
  check bool
    "local command evidence satisfied"
    true
    (Probe.all_satisfied ~config ~meta [ tests_pass "test 1 = 1" ])

let test_docker_without_factory_does_not_fall_back_to_host () =
  with_fixture ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ->
  (match Probe.evaluate ~config ~meta [ tests_pass "test 1 = 1" ] with
   | Deterministic_evidence_evaluator.Indeterminate reason ->
     check bool "indeterminate reason populated" true (String.length reason > 0)
   | Deterministic_evidence_evaluator.Satisfied ->
     fail "docker evidence without factory must not be satisfied"
   | Deterministic_evidence_evaluator.Unsatisfied reason ->
     fail ("expected indeterminate, got unsatisfied: " ^ reason));
  check bool
    "docker command evidence without factory stays indeterminate"
    false
    (Probe.all_satisfied ~config ~meta [ tests_pass "test 1 = 1" ])

let () =
  run
    "keeper_deterministic_evidence_probe"
    [ ( "command evidence sandbox"
      , [ test_case
            "local Tests_pass command runs"
            `Quick
            test_local_tests_pass_runs_in_local_target
        ; test_case
            "docker Tests_pass without factory does not host fallback"
            `Quick
            test_docker_without_factory_does_not_fall_back_to_host
        ] )
    ]
