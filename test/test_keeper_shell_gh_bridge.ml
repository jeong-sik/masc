open Alcotest
open Masc_mcp

module Json = Yojson.Safe.Util

let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_tool_policy.init_policy_config ~base_path))

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

let rec ensure_dir path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let make_meta ~sandbox : Keeper_types.keeper_meta =
  let json =
    `Assoc
      [ "name", `String "gh-bridge-test"
      ; "agent_name", `String "gh-bridge-test-agent"
      ; "trace_id", `String "gh-bridge-test-trace"
      ; "goal", `String "keeper gh bridge boundary"
      ; "allowed_paths", `List [ `String "*" ]
      ; ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) )
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

type runner_call =
  { host_argv : string list
  ; host_env_is_none : bool
  ; backend_command_text : string
  ; backend_git_creds_enabled : bool
  ; backend_network_mode : Keeper_types.network_mode
  ; backend_trust : Keeper_sandbox_runner.command_trust
  }

let call_testable =
  let pp fmt call =
    Format.fprintf
      fmt
      "{host_argv=[%s]; host_env_is_none=%b; backend_command_text=%S}"
      (String.concat "; " call.host_argv)
      call.host_env_is_none
      call.backend_command_text
  in
  testable pp ( = )

let with_fixture f =
  let base = temp_dir "keeper_shell_gh_bridge_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let config = Coord.default_config base in
       let meta = make_meta ~sandbox:Keeper_types.Docker in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       f ~config ~meta ~playground)

let make_runner ?backend_error ?(status = 0) ?(output = "mock gh output")
    calls =
  fun ~config:_ ~meta:_ ~timeout_sec:_
      ~(host : Keeper_sandbox_runner.host_command)
      ~(backend : Keeper_sandbox_runner.backend_command) ->
    calls :=
      { host_argv = host.Keeper_sandbox_runner.argv
      ; host_env_is_none = Option.is_none host.env
      ; backend_command_text = backend.command_text
      ; backend_git_creds_enabled = backend.git_creds_enabled
      ; backend_network_mode = backend.network_mode
      ; backend_trust = backend.trust
      }
      :: !calls;
    { Keeper_sandbox_runner.status = Unix.WEXITED status
    ; output
    ; via = "docker"
    ; backend_error
    }

let json_field raw field =
  Yojson.Safe.from_string raw |> Json.member field

let string_field raw field =
  json_field raw field |> Json.to_string_option

let bool_field raw field =
  json_field raw field |> Json.to_bool_option

let test_backend_route_uses_mock_runner_without_host_env () =
  with_fixture (fun ~config ~meta ~playground:_ ->
      let calls = ref [] in
      let raw =
        Keeper_shell_gh_bridge.handle_gh_op
          ~run_command_with_status:(make_runner calls)
          ~config
          ~meta
          ~args:(`Assoc [ "cmd", `String "pr list" ])
          ~repo_check:(fun _ -> Ok ())
          ()
      in
      check (option bool) "ok" (Some true) (bool_field raw "ok");
      check (option string) "via" (Some "docker") (string_field raw "via");
      check (option string) "output" (Some "mock gh output")
        (string_field raw "output");
      check (list call_testable) "runner calls"
        [ { host_argv = [ "gh"; "pr"; "list" ]
          ; host_env_is_none = true
          ; backend_command_text = "gh 'pr' 'list'"
          ; backend_git_creds_enabled = true
          ; backend_network_mode = Keeper_types.Network_inherit
          ; backend_trust = Keeper_sandbox_runner.User_shell
          }
        ]
        (List.rev !calls))

let test_backend_error_stays_structured () =
  with_fixture (fun ~config ~meta ~playground:_ ->
      let calls = ref [] in
      let raw =
        Keeper_shell_gh_bridge.handle_gh_op
          ~run_command_with_status:
            (make_runner
               ~backend_error:"docker_shell_failed: mock preflight"
               ~status:127
               ~output:"docker_shell_failed: mock preflight"
               calls)
          ~config
          ~meta
          ~args:(`Assoc [ "argv", `List [ `String "pr"; `String "view"; `String "1" ] ])
          ~repo_check:(fun _ -> Ok ())
          ()
      in
      check (option bool) "ok" (Some false) (bool_field raw "ok");
      check (option string) "error"
        (Some "docker_shell_failed: mock preflight")
        (string_field raw "error");
      check int "runner call count" 1 (List.length !calls))

let () =
  run
    "keeper_shell_gh_bridge"
    [ ( "mock-runner",
        [ test_case
            "backend route uses mock runner without host gh env"
            `Quick
            test_backend_route_uses_mock_runner_without_host_env
        ; test_case
            "backend errors stay structured"
            `Quick
            test_backend_error_stays_structured
        ] )
    ]
