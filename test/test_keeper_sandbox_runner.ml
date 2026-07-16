open Alcotest
open Masc

external unsetenv : string -> unit = "masc_test_unsetenv"

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir path =
  let rec rm p =
    match Unix.lstat p with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter
        (fun name -> rm (Filename.concat p name))
        (Sys.readdir p);
      Unix.rmdir p
    | _ -> Unix.unlink p
    | exception Unix.Unix_error _ -> ()
  in
  rm path

let string_starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.sub value 0 prefix_len = prefix

let make_meta ~sandbox : Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [ "name", `String "runner-test"
      ; "agent_name", `String "runner-test-agent"
      ; "trace_id", `String "runner-test-trace"
      ; "allowed_paths", `List [ `String "*" ]
      ; ( "sandbox_profile",
          `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) )
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

module Fake_backend = struct
  let calls = ref []

  let record call =
    calls := call :: !calls

  let effective_sandbox_profile ~meta:_ =
    Keeper_types_profile_sandbox.Docker, Keeper_types_profile_sandbox.Network_none

  let ensure_runtime ~timeout_sec:_ =
    Ok [ "--fake-seccomp" ]

  let private_workspace_cwd ~config:_ ~meta:_ cwd =
    "/fake/container" ^ cwd

  let result ~status ~output ~network_mode ~cwd
      : Keeper_sandbox_runner.command_result =
    { status = Unix.WEXITED status
    ; output
    ; image = "fake-image"
    ; network_label = Keeper_types_profile_sandbox.network_mode_to_string network_mode
    ; cwd
    }

  let run_shell_command_with_status ~config:_ ~meta:_ ~cwd ~timeout_sec:_ ~cmd
      ~network_mode =
    record ("shell:" ^ cmd);
    Ok (result ~status:3 ~output:("shell:" ^ cmd) ~network_mode ~cwd)

  let run_trusted_shell_command_with_status ~config:_ ~meta:_ ~cwd
      ~timeout_sec:_ ~cmd ~network_mode =
    record ("trusted:" ^ cmd);
    Ok (result ~status:0 ~output:("trusted:" ^ cmd) ~network_mode ~cwd)

  let run_bash ~turn_sandbox_runtime:_ ~config:_ ~meta:_ ~cwd:_ ~timeout_sec:_
      ~cmd ~network_mode:_ =
    record ("bash:" ^ cmd);
    "bash:" ^ cmd
end

module Runner = Keeper_sandbox_runner.Make (Fake_backend)

let with_fixture f =
  let base = temp_dir "keeper_sandbox_runner_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let config = Workspace.default_config base in
       let meta = make_meta ~sandbox:Keeper_types_profile_sandbox.Docker in
       f ~config ~meta)

let test_functor_delegates_user_shell () =
  Fake_backend.calls := [];
  with_fixture (fun ~config ~meta ->
      match
        Runner.run_shell_command_with_status ~config ~meta ~cwd:"/work"
          ~timeout_sec:5.0 ~cmd:"git status"
          ~network_mode:Keeper_types_profile_sandbox.Network_none
      with
      | Error e -> Alcotest.fail e
      | Ok result ->
        check int "status" 3
          (match result.status with Unix.WEXITED n -> n | _ -> -1);
        check string "output" "shell:git status" result.output;
        check (list string) "calls"
          [ "shell:git status" ]
          (List.rev !Fake_backend.calls))

let test_functor_delegates_trusted_tool () =
  Fake_backend.calls := [];
  with_fixture (fun ~config ~meta ->
      match
        Runner.run_trusted_shell_command_with_status ~config ~meta ~cwd:"/work"
          ~timeout_sec:5.0 ~cmd:"gh pr view"
          ~network_mode:Keeper_types_profile_sandbox.Network_inherit
      with
      | Error e -> Alcotest.fail e
      | Ok result ->
        check int "status" 0
          (match result.status with Unix.WEXITED n -> n | _ -> -1);
        check string "output" "trusted:gh pr view" result.output;
        check string "network label" "inherit" result.network_label;
        check (list string) "calls"
          [ "trusted:gh pr view" ]
          (List.rev !Fake_backend.calls))

let test_uses_backend_respects_profile () =
  let base = temp_dir "keeper_sandbox_runner_route_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let config = Workspace.default_config base in
       let docker_meta = make_meta ~sandbox:Keeper_types_profile_sandbox.Docker in
       let local_meta = make_meta ~sandbox:Keeper_types_profile_sandbox.Local in
       let docker_cwd =
         Keeper_sandbox.host_root_abs_of_meta ~config docker_meta
       in
       let local_cwd =
         Keeper_sandbox.host_root_abs_of_meta ~config local_meta
       in
       check bool "docker profile uses backend" true
         (Keeper_sandbox_runner.uses_backend
            ~config ~meta:docker_meta ~cwd:docker_cwd);
       check bool "local profile uses host" false
         (Keeper_sandbox_runner.uses_backend
            ~config ~meta:local_meta ~cwd:local_cwd);
       check string "docker route label" "docker"
         (Keeper_sandbox_runner.route_via
            ~config ~meta:docker_meta ~cwd:docker_cwd);
       check string "local route label" "host"
         (Keeper_sandbox_runner.route_via
            ~config ~meta:local_meta ~cwd:local_cwd))

let test_playground_root_uses_config_base_path () =
  let config_base = temp_dir "keeper_sandbox_config_base_" in
  let env_base = temp_dir "keeper_sandbox_env_base_" in
  let previous_masc_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      (match previous_masc_base with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> unsetenv "MASC_BASE_PATH");
      cleanup_dir config_base;
      cleanup_dir env_base)
    (fun () ->
       Unix.putenv "MASC_BASE_PATH" env_base;
       let config = Workspace.default_config config_base in
       let meta = make_meta ~sandbox:Keeper_types_profile_sandbox.Local in
       let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       check bool "host root under config base_path" true
         (string_starts_with ~prefix:(config_base ^ "/") host_root);
       check bool "host root ignores ambient MASC_BASE_PATH" false
         (string_starts_with ~prefix:(env_base ^ "/") host_root);
       check string "host root suffix"
         (Filename.concat config_base ".masc/playground/runner-test")
         (Keeper_alerting_path.strip_trailing_slashes host_root))

let test_local_route_does_not_force_backend_cwd () =
  let base = temp_dir "keeper_sandbox_runner_lazy_cwd_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let config = Workspace.default_config base in
       let meta = make_meta ~sandbox:Keeper_types_profile_sandbox.Local in
       let cwd = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       let result =
         Keeper_sandbox_runner.run_command_with_status
           ~config ~meta ~timeout_sec:5.0
           ~host:
             { actor = Masc_exec.Agent_id.of_string "tool/execute"
             ; raw_source = "true"
             ; summary = "runner lazy cwd host smoke"
             ; env = None
             ; cwd = Some cwd
             ; argv = [ "true" ]
             }
           ~backend:
             { route_cwd = cwd
             ; cwd = (fun () -> failwith "backend cwd evaluated on host route")
             ; command_text = "true"
             ; network_mode = Keeper_types_profile_sandbox.Network_none
             ; trust = Keeper_sandbox_runner.User_shell
             }
       in
       check string "via" "host" result.via;
       check bool "no backend error" true (Option.is_none result.backend_error))

let () =
  Alcotest.run
    "keeper_sandbox_runner"
    [ ( "mock-backend",
        [ test_case "delegates user shell" `Quick test_functor_delegates_user_shell
        ; test_case "delegates trusted tool" `Quick test_functor_delegates_trusted_tool
        ] )
    ; ( "routing",
        [ test_case "profile selects backend" `Quick test_uses_backend_respects_profile
        ; test_case
            "playground root uses config base_path"
            `Quick
            test_playground_root_uses_config_base_path
        ; test_case
            "local route does not force backend cwd"
            `Quick
            test_local_route_does_not_force_backend_cwd
        ] )
    ]
