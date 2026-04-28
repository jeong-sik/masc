(** Tests for keeper_shell docker routing (RFC-0006 Phase B-3b+).

    Verifies that Docker keepers route structured shell ops through
    docker. The docker process itself is not invoked because the test
    environment sets
    [MASC_KEEPER_SANDBOX_DOCKER_IMAGE=""], so the response must
    surface the structured "docker image is not configured" error from
    [Keeper_docker_read] — proof that control reached the docker
    route. *)

module Coord = Masc_mcp.Coord
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_shell_docker = Masc_mcp.Keeper_shell_docker
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_alerting_path = Masc_mcp.Keeper_alerting_path
module Tool_code_write = Masc_mcp.Tool_code_write
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

(* ── Helpers ─────────────────────────────────────────────────────── *)

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_dir () =
  let dir = Filename.temp_file "keeper_shell_docker_route_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter
          (fun name -> rm (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let contains_substring haystack needle =
  let len = String.length needle in
  let n = String.length haystack in
  let rec loop i =
    if i + len > n then false
    else if String.sub haystack i len = needle then true
    else loop (i + 1)
  in
  loop 0

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let run_ok ~cwd cmd =
  let wrapped =
    Printf.sprintf "cd %s && %s > /dev/null 2>&1" (Filename.quote cwd) cmd
  in
  let code = Sys.command wrapped in
  if code <> 0 then
    Alcotest.failf "command failed (%d): %s" code cmd

let clear_checkout_but_keep_git_dir root =
  Sys.readdir root
  |> Array.iter (fun name ->
    if name <> ".git" then cleanup_dir (Filename.concat root name))

let make_meta ~name ~sandbox =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "shell docker route test");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let setup ~sandbox f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  let config = Coord.default_config base in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_meta ~name:"minjae" ~sandbox in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  f ~config ~meta ~playground

let with_fake_docker script f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  write_file docker_path script;
  Unix.chmod docker_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "MASC_TEST_FAKE_DOCKER_PATH" docker_path @@ fun () ->
  with_env "PATH" path f

let with_tool_policy_config f =
  let config_dir =
    Filename.concat (Masc_test_deps.find_project_root ()) "config"
  in
  Tool_code_write.reset_policy_config_cache ();
  with_env "MASC_CONFIG_DIR" config_dir @@ fun () ->
  Fun.protect ~finally:Tool_code_write.reset_policy_config_cache f

let with_config_dir config_dir f =
  let prior = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match prior with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Masc_mcp.Config_dir_resolver.reset ();
      f ())

let with_keeper_identity_toml ~config ~keeper_name ~github_identity
    ~git_identity_mode f =
  let masc_dir = Filename.concat config.Coord.base_path Common.masc_dirname in
  let config_dir = Filename.concat masc_dir "config" in
  let keepers_dir = Filename.concat config_dir "keepers" in
  let gh_dir =
    Filename.concat
      (Filename.concat
         (Filename.concat masc_dir "github-identities")
         github_identity)
      "gh"
  in
  ensure_dir keepers_dir;
  ensure_dir gh_dir;
  write_file
    (Filename.concat keepers_dir (keeper_name ^ ".toml"))
    (Printf.sprintf
       "[keeper]\ngithub_identity = %S\ngit_identity_mode = %S\n"
       github_identity git_identity_mode);
  with_config_dir config_dir f

let parse_field raw field =
  Yojson.Safe.from_string raw |> Json.member field

let parse_string_field raw field =
  parse_field raw field |> Json.to_string_option

let response_mentions raw field needle =
  match parse_string_field raw field with
  | None -> false
  | Some s ->
      let len = String.length needle in
      let n = String.length s in
      let rec loop i =
        if i + len > n then false
        else if String.sub s i len = needle then true
        else loop (i + 1)
      in
      loop 0

let parse_bool_field raw field =
  parse_field raw field |> Json.to_bool_option

let parse_status_exit_code raw =
  match parse_field raw "status" |> Json.member "code" |> Json.to_int_option with
  | Some code -> code
  | None -> Alcotest.failf "missing status.code in %s" raw

let assert_docker_route_fires ~config ~meta ~playground =
  let host_path = Filename.concat playground "mind/demo.txt" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "alpha\nbeta\ngamma\n");
  let cases =
    [
      ("cat", `Assoc [ ("op", `String "cat"); ("path", `String host_path) ]);
      ("ls", `Assoc [ ("op", `String "ls"); ("path", `String playground) ]);
      ( "rg",
        `Assoc
          [
            ("op", `String "rg");
            ("pattern", `String "alpha");
            ("path", `String playground);
          ] );
      ( "find",
        `Assoc
          [
            ("op", `String "find");
            ("pattern", `String "*.txt");
            ("path", `String playground);
          ] );
      ( "head",
        `Assoc
          [
            ("op", `String "head");
            ("lines", `Int 1);
            ("path", `String host_path);
          ] );
      ( "tail",
        `Assoc
          [
            ("op", `String "tail");
            ("lines", `Int 1);
            ("path", `String host_path);
          ] );
      ("wc", `Assoc [ ("op", `String "wc"); ("path", `String host_path) ]);
      ("tree", `Assoc [ ("op", `String "tree"); ("path", `String playground) ]);
      ("pwd", `Assoc [ ("op", `String "pwd"); ("cwd", `String playground) ]);
      ( "git_status",
        `Assoc [ ("op", `String "git_status"); ("cwd", `String playground) ] );
      ( "git_log",
        `Assoc
          [
            ("op", `String "git_log");
            ("cwd", `String playground);
            ("count", `Int 1);
          ] );
    ]
  in
  List.iter
    (fun (op, args) ->
      let raw =
        Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_runtime:None ~exec_cache:None ~config ~meta ~args
      in
      Alcotest.(check bool)
        (Printf.sprintf "%s surfaces docker image config error (docker route fired)" op)
        true
        (response_mentions raw "error" "docker image"))
    cases

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_readonly_ops_route_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  assert_docker_route_fires ~config ~meta ~playground

let test_cat_legacy_keeper_skips_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Local
  @@ fun ~config ~meta ~playground ->
  let host_path = Filename.concat playground "mind/x" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "matrix");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_runtime:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String host_path) ])
  in
  Alcotest.(check bool)
    "legacy keeper does not surface docker image error"
    false
    (response_mentions raw "error" "docker image")

let fake_docker_rg_no_match_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" != \"run\" ]; then\n\
  printf 'unexpected docker invocation\\n' >&2\n\
  exit 2\n\
fi\n\
shift\n\
while [ \"$#\" -gt 0 ]; do\n\
  if [ \"$1\" = \"alpine:test\" ]; then\n\
    shift\n\
    break\n\
  fi\n\
  shift\n\
done\n\
if [ \"$1\" = \"rg\" ]; then\n\
  exit 1\n\
fi\n\
printf '%s\\n' \"$*\"\n\
exit 0\n"

let test_rg_no_match_remains_successful_in_docker_route () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_rg_no_match_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let host_path = Filename.concat playground "mind/demo.txt" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "alpha\nbeta\ngamma\n");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_runtime:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
            [
              ("op", `String "rg");
              ("pattern", `String "missing");
              ("path", `String playground);
            ])
  in
  Alcotest.(check (option bool)) "rg no-match stays ok" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check int) "rg keeps exit=1 status" 1
    (parse_status_exit_code raw);
  Alcotest.(check int) "rg no-match returns empty matches" 0
    (parse_field raw "matches" |> Json.to_list |> List.length)

let test_git_clone_routes_through_docker () =
  with_tool_policy_config @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_runtime:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "git_clone");
            ("url", `String "https://github.com/jeong-sik/masc-mcp.git");
          ])
  in
  Alcotest.(check (option bool)) "git_clone fails through docker route" (Some false)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "via=docker" (Some "docker")
    (parse_string_field raw "via");
  Alcotest.(check bool) "output includes docker image error" true
    (response_mentions raw "output" "docker image");
  Alcotest.(check bool) "clone stays inside keeper repos" true
    (response_mentions raw "path"
       (Filename.concat playground "repos/masc-mcp"))

let test_hard_mode_git_clone_uses_brokered_route () =
  with_tool_policy_config @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_RELAX_FS" "false" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_runtime:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "git_clone");
            ("url", `String "https://github.com/jeong-sik/masc-mcp.git");
          ])
  in
  Alcotest.(check (option bool)) "git_clone fails before host git without identity"
    (Some false)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "via=brokered" (Some "brokered")
    (parse_string_field raw "via");
  Alcotest.(check bool) "output mentions missing github_identity" true
    (response_mentions raw "output" "github_identity");
  Alcotest.(check bool) "clone path stays inside keeper repos" true
    (response_mentions raw "path"
       (Filename.concat playground "repos/masc-mcp"))

let test_bash_routes_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_runtime:None
      ~turn_sandbox_runtime_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "echo hello"); ("cwd", `String playground) ])
      ()
  in
  Alcotest.(check bool)
    "bash surfaces docker image config error (docker route fired)"
    true
    (response_mentions raw "error" "docker image")

let test_bash_legacy_skips_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Local
  @@ fun ~config ~meta ~playground ->
  let outside_cwd = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir outside_cwd) @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_runtime:None
      ~turn_sandbox_runtime_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "echo hello"); ("cwd", `String outside_cwd) ])
      ()
  in
  Alcotest.(check bool)
    "legacy keeper bash does not surface docker image error"
    false
    (response_mentions raw "error" "docker image")

let test_bash_git_creds_routes_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_runtime:None
      ~turn_sandbox_runtime_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "git status"); ("cwd", `String playground) ])
      ()
  in
  Alcotest.(check bool)
    "bash git cmd surfaces docker image config error (git-creds route fired)"
    true
    (response_mentions raw "error" "docker image")

let test_hard_mode_blocks_raw_gh_bash () =
  with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "true" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground:_ ->
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_runtime:None
      ~turn_sandbox_runtime_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "gh pr list") ])
      ()
  in
  Alcotest.(check (option string)) "raw gh hard-mode error"
    (Some "gh_requires_brokered_structured_tool")
    (parse_string_field raw "error");
  Alcotest.(check bool) "hint mentions structured op=gh" true
    (response_mentions raw "hint" "keeper_shell op=gh")

let fake_docker_echo_script =
  "#!/bin/sh\n\
log_file=${KEEPER_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" != \"run\" ]; then\n\
  printf 'unexpected docker invocation: %s\\n' \"$1\" >&2\n\
  exit 2\n\
fi\n\
shift\n\
while [ \"$#\" -gt 0 ]; do\n\
  if [ \"$1\" = \"alpine:test\" ]; then\n\
    shift\n\
    break\n\
  fi\n\
  shift\n\
done\n\
printf 'stdout:%s\\n' \"$*\"\n\
exit 0\n"

let docker_run_line log_path =
  read_file log_path
  |> String.split_on_char '\n'
  |> List.find_opt (String.starts_with ~prefix:"run ")
  |> function
  | Some line -> line
  | None -> Alcotest.fail "expected docker run log line"

let run_git_creds_docker_shell ~config ~meta ~playground ~log_path =
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  (match Sys.getenv_opt "MASC_TEST_FAKE_DOCKER_PATH" with
   | Some expected ->
       Alcotest.(check string) "fake docker command selected" expected
         (Masc_mcp.Keeper_sandbox_runtime.docker_command ())
   | None -> ());
  match
    Keeper_shell_docker.run_docker_shell_command_with_status
      ~config ~meta ~cwd:playground ~timeout_sec:5.0
      ~cmd:"git status" ~git_creds_enabled:true
      ~network_mode:Keeper_types.Network_inherit
  with
  | Error msg ->
      Alcotest.failf "expected fake docker git-creds run, got %s" msg
  | Ok result ->
      let observed =
        match result.Keeper_shell_docker.status with
        | Unix.WEXITED code -> ("exit", code)
        | Unix.WSIGNALED code -> ("signaled", code)
        | Unix.WSTOPPED code -> ("stopped", code)
      in
      if observed <> ("exit", 0) then
        Alcotest.failf "expected fake docker exit 0, got %s %d; log=%S; output=%S"
          (fst observed) (snd observed) (read_file log_path)
          result.Keeper_shell_docker.output;
      docker_run_line log_path

let test_git_creds_skips_missing_ssh_auth_sock () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  Masc_mcp.Config_dir_resolver.reset ();
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  let missing_sock =
    Filename.concat config.Coord.base_path "missing-agent.sock"
  in
  with_env "SSH_AUTH_SOCK" missing_sock @@ fun () ->
  let line =
    run_git_creds_docker_shell ~config ~meta ~playground ~log_path
  in
  Alcotest.(check bool) "missing ssh-agent socket is not mounted" false
    (contains_substring line missing_sock);
  Alcotest.(check bool) "missing ssh-agent env is not forwarded" false
    (contains_substring line "SSH_AUTH_SOCK=/tmp/keeper-creds/ssh-agent.sock")

let test_git_creds_inherit_network_omits_invalid_network_flag () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  let line =
    run_git_creds_docker_shell ~config ~meta ~playground ~log_path
  in
  Alcotest.(check bool) "network inherit never uses invalid flag value" false
    (contains_substring line "--network inherit")

let test_git_creds_respects_keeper_alias_identity_mode () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  with_keeper_identity_toml ~config ~keeper_name:meta.name
    ~github_identity:"anyang-keepers" ~git_identity_mode:"keeper_alias"
  @@ fun () ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  let line =
    run_git_creds_docker_shell ~config ~meta ~playground ~log_path
  in
  Alcotest.(check bool) "keeper_alias keeps keeper author" true
    (contains_substring line "GIT_AUTHOR_NAME=minjae (MASC Keeper)");
  Alcotest.(check bool) "keeper_alias does not force GitHub identity author" false
    (contains_substring line "GIT_AUTHOR_NAME=anyang-keepers")

let test_git_creds_uses_github_identity_mode () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  with_keeper_identity_toml ~config ~keeper_name:meta.name
    ~github_identity:"anyang-keepers" ~git_identity_mode:"github_identity"
  @@ fun () ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  let line =
    run_git_creds_docker_shell ~config ~meta ~playground ~log_path
  in
  Alcotest.(check bool) "github_identity mode uses GitHub author" true
    (contains_substring line "GIT_AUTHOR_NAME=anyang-keepers");
  Alcotest.(check bool) "github_identity mode uses noreply email" true
    (contains_substring line
       "GIT_AUTHOR_EMAIL=anyang-keepers@users.noreply.github.com")

let test_git_clone_repairs_existing_docker_clone_checkout () =
  with_tool_policy_config @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let source_repo = Filename.concat playground "source-masc-mcp" in
  ensure_dir source_repo;
  run_ok ~cwd:source_repo "git init -q -b main";
  run_ok ~cwd:source_repo "git config user.email test@example.com";
  run_ok ~cwd:source_repo "git config user.name Test";
  let source_readme = Filename.concat source_repo "README.md" in
  write_file source_readme "# sandbox clone\n";
  run_ok ~cwd:source_repo "git add README.md";
  run_ok ~cwd:source_repo "git commit -q -m init";
  let repos_dir = Filename.concat playground "repos" in
  ensure_dir repos_dir;
  let clone_path = Filename.concat repos_dir "masc-mcp" in
  run_ok ~cwd:repos_dir
    (Printf.sprintf "git clone -q %s masc-mcp" (Filename.quote source_repo));
  let restored_readme = Filename.concat clone_path "README.md" in
  clear_checkout_but_keep_git_dir clone_path;
  Alcotest.(check bool) "checkout file removed before repair" false
    (Sys.file_exists restored_readme);
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_runtime:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "git_clone");
            ("url", `String "https://github.com/jeong-sik/masc-mcp.git");
          ])
  in
  Alcotest.(check (option bool)) "git_clone succeeds after checkout repair"
    (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "via=docker" (Some "docker")
    (parse_string_field raw "via");
  Alcotest.(check bool) "checkout restored" true
    (Sys.file_exists restored_readme);
  Alcotest.(check bool) "repair note surfaced" true
    (response_mentions raw "repair_note" "checkout was restored")

let test_bash_fake_docker_executes () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_runtime:None
      ~turn_sandbox_runtime_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "echo hello"); ("cwd", `String playground) ])
      ()
  in
  Alcotest.(check (option bool)) "bash via fake docker is ok" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "bash via=docker" (Some "docker")
    (parse_string_field raw "via");
  Alcotest.(check bool) "bash output includes fake docker stdout" true
    (response_mentions raw "output" "stdout:")

let () =
  Alcotest.run "Keeper_shell_docker_route"
    [
      ( "docker_route_fires",
        [
          Alcotest.test_case
            "docker keeper shell ops route through docker"
            `Quick test_readonly_ops_route_through_docker;
          Alcotest.test_case
            "docker keeper bash routes through docker"
            `Quick test_bash_routes_through_docker;
          Alcotest.test_case
            "docker keeper bash git cmd routes through git-creds docker"
            `Quick test_bash_git_creds_routes_through_docker;
          Alcotest.test_case
            "hard mode blocks raw gh keeper_bash"
            `Quick test_hard_mode_blocks_raw_gh_bash;
          Alcotest.test_case
            "docker keeper bash executes through fake docker"
            `Quick test_bash_fake_docker_executes;
        ] );
      ( "docker_route_skipped",
        [
          Alcotest.test_case "legacy keeper skips docker route" `Quick
            test_cat_legacy_keeper_skips_docker;
          Alcotest.test_case "legacy keeper bash skips docker route" `Quick
            test_bash_legacy_skips_docker;
        ] );
      ( "docker_route_contract",
        [
          Alcotest.test_case "rg no-match remains successful" `Quick
            test_rg_no_match_remains_successful_in_docker_route;
          Alcotest.test_case "git_clone routes through docker" `Quick
            test_git_clone_routes_through_docker;
          Alcotest.test_case
            "git-creds skips missing SSH_AUTH_SOCK"
            `Quick test_git_creds_skips_missing_ssh_auth_sock;
          Alcotest.test_case
            "git-creds inherit network omits invalid docker flag"
            `Quick test_git_creds_inherit_network_omits_invalid_network_flag;
          Alcotest.test_case
            "git-creds respects keeper_alias git identity mode"
            `Quick test_git_creds_respects_keeper_alias_identity_mode;
          Alcotest.test_case
            "git-creds uses GitHub author only in github_identity mode"
            `Quick test_git_creds_uses_github_identity_mode;
          Alcotest.test_case "hard mode git_clone uses brokered route" `Quick
            test_hard_mode_git_clone_uses_brokered_route;
          Alcotest.test_case "git_clone repairs existing docker clone checkout"
            `Quick test_git_clone_repairs_existing_docker_clone_checkout;
        ] );
    ]
