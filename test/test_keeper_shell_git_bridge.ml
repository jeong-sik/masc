open Alcotest
open Masc_mcp

module Json = Yojson.Safe.Util

let project_root = Masc_test_deps.find_project_root ()

let () =
  match Keeper_tool_policy.init_policy_config ~base_path:project_root with
  | Ok _ -> ()
  | Error e -> Alcotest.fail e

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

let copy_file ~src ~dst =
  let ic = open_in_bin src in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let content = really_input_string ic (in_channel_length ic) in
       ensure_dir (Filename.dirname dst);
       let oc = open_out_bin dst in
       Fun.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () -> output_string oc content))

let install_tool_policy base =
  copy_file
    ~src:(Filename.concat project_root "config/tool_policy.toml")
    ~dst:(Filename.concat base "config/tool_policy.toml")

let make_meta ~sandbox : Keeper_types.keeper_meta =
  let json =
    `Assoc
      [ "name", `String "git-bridge-test"
      ; "agent_name", `String "git-bridge-test-agent"
      ; "trace_id", `String "git-bridge-test-trace"
      ; "goal", `String "keeper git bridge boundary"
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
  ; backend_route_cwd : string
  ; backend_command_text : string
  ; backend_git_creds_enabled : bool
  ; backend_network_mode : Keeper_types.network_mode
  ; backend_trust : Keeper_sandbox_runner.command_trust
  }

let call_testable =
  let pp fmt call =
    Format.fprintf
      fmt
      "{host_argv=[%s]; backend_route_cwd=%S; backend_command_text=%S}"
      (String.concat "; " call.host_argv)
      call.backend_route_cwd
      call.backend_command_text
  in
  testable pp ( = )

let with_fixture ?(sandbox = Keeper_types.Docker) f =
  let base = temp_dir "keeper_shell_git_bridge_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       install_tool_policy base;
       let config = Coord.default_config base in
       let meta = make_meta ~sandbox in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       f ~config ~meta ~playground)

let make_runner ?(status = 1) ?(output = "mock git clone failed")
    ?(via = "docker") calls =
  fun ~config:_ ~meta:_ ~timeout_sec:_
      ~(host : Keeper_sandbox_runner.host_command)
      ~(backend : Keeper_sandbox_runner.backend_command) ->
    calls :=
      { host_argv = host.Keeper_sandbox_runner.argv
      ; backend_route_cwd = backend.route_cwd
      ; backend_command_text = backend.command_text
      ; backend_git_creds_enabled = backend.git_creds_enabled
      ; backend_network_mode = backend.network_mode
      ; backend_trust = backend.trust
      }
      :: !calls;
    { Keeper_sandbox_runner.status = Unix.WEXITED status
    ; output
    ; via
    ; backend_error = None
    }

let json_field raw field =
  Yojson.Safe.from_string raw |> Json.member field

let string_field raw field =
  json_field raw field |> Json.to_string_option

let bool_field raw field =
  json_field raw field |> Json.to_bool_option

let test_clone_route_uses_mock_runner () =
  with_fixture (fun ~config ~meta ~playground ->
      let calls = ref [] in
      let raw =
        Keeper_shell_git_bridge.handle_git_clone
          ~run_command_with_status:(make_runner calls)
          ~config
          ~meta
          ~args:
            (`Assoc
              [ "url", `String "https://github.com/jeong-sik/masc-mcp" ])
          ()
      in
      let repos_dir = Filename.concat playground "repos" in
      let clone_path = Filename.concat repos_dir "masc-mcp" in
      check (option bool) "ok" (Some false) (bool_field raw "ok");
      check (option string) "op" (Some "git_clone") (string_field raw "op");
      check (option string) "action" (Some "clone") (string_field raw "action");
      check (option string) "via" (Some "docker") (string_field raw "via");
      check (option string) "path" (Some clone_path) (string_field raw "path");
      check (option string) "output" (Some "mock git clone failed")
        (string_field raw "output");
      check (list call_testable) "runner calls"
        [ { host_argv =
              [ "git"
              ; "clone"
              ; "https://github.com/jeong-sik/masc-mcp.git"
              ; clone_path
              ]
          ; backend_route_cwd = repos_dir
          ; backend_command_text =
              "'git' 'clone' 'https://github.com/jeong-sik/masc-mcp.git' \
               'masc-mcp'"
          ; backend_git_creds_enabled = true
          ; backend_network_mode = Keeper_types.Network_inherit
          ; backend_trust = Keeper_sandbox_runner.Trusted_tool
          }
        ]
        (List.rev !calls))

let test_clone_policy_rejects_before_runner () =
  with_fixture (fun ~config ~meta ~playground:_ ->
      let calls = ref [] in
      let raw =
        Keeper_shell_git_bridge.handle_git_clone
          ~run_command_with_status:(make_runner calls)
          ~config
          ~meta
          ~args:(`Assoc [ "url", `String "not-a-github-url" ])
          ()
      in
      check (option bool) "ok" (Some false) (bool_field raw "ok");
      check (option string) "error" (Some "clone_blocked")
        (string_field raw "error");
      check int "runner not called" 0 (List.length !calls))

let test_local_clone_shape_uses_host_route_label () =
  with_fixture ~sandbox:Keeper_types.Local (fun ~config ~meta ~playground ->
      let calls = ref [] in
      let raw =
        Keeper_shell_git_bridge.handle_git_clone
          ~run_command_with_status:
            (make_runner ~status:0 ~output:"mock git clone ok" ~via:"host" calls)
          ~config
          ~meta
          ~args:
            (`Assoc
              [ "url", `String "https://github.com/jeong-sik/masc-mcp" ])
          ()
      in
      let repos_dir = Filename.concat playground "repos" in
      let clone_path = Filename.concat repos_dir "masc-mcp" in
      check (option bool) "ok" (Some true) (bool_field raw "ok");
      check (option string) "via" (Some "host") (string_field raw "via");
      check (option string) "path" (Some clone_path) (string_field raw "path");
      check (list call_testable) "runner calls"
        [ { host_argv =
              [ "git"
              ; "clone"
              ; "https://github.com/jeong-sik/masc-mcp.git"
              ; clone_path
              ]
          ; backend_route_cwd = repos_dir
          ; backend_command_text =
              "'git' 'clone' 'https://github.com/jeong-sik/masc-mcp.git' \
               'masc-mcp'"
          ; backend_git_creds_enabled = true
          ; backend_network_mode = Keeper_types.Network_inherit
          ; backend_trust = Keeper_sandbox_runner.Trusted_tool
          }
        ]
        (List.rev !calls))

let () =
  run
    "keeper_shell_git_bridge"
    [ ( "mock-runner",
        [ test_case
            "clone route uses mock runner"
            `Quick
            test_clone_route_uses_mock_runner
        ; test_case
            "clone policy rejects before runner"
            `Quick
            test_clone_policy_rejects_before_runner
        ; test_case
            "local clone shape uses host route label"
            `Quick
            test_local_clone_shape_uses_host_route_label
        ] )
    ]
