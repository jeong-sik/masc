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
module Keeper_sandbox_factory = Masc_mcp.Keeper_sandbox_factory
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

let setup_two_docker_keepers f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  let config = Coord.default_config base in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let meta_a = make_meta ~name:"keeper-a" ~sandbox:Keeper_types.Docker in
  let meta_b = make_meta ~name:"keeper-b" ~sandbox:Keeper_types.Docker in
  let playground_a = Keeper_sandbox.host_root_abs_of_meta ~config meta_a in
  let playground_b = Keeper_sandbox.host_root_abs_of_meta ~config meta_b in
  ensure_dir playground_a;
  ensure_dir playground_b;
  f ~config ~meta_a ~playground_a ~meta_b ~playground_b

let with_fake_docker script f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  let gh_path = Filename.concat dir "gh" in
  let fake_gh_auth_status_ok =
    "#!/bin/sh\n\
     if [ \"$1\" = \"auth\" ] && [ \"$2\" = \"status\" ]; then\n\
     \  exit 0\n\
     fi\n\
     printf 'unexpected gh invocation: %s\\n' \"$*\" >&2\n\
     exit 2\n"
  in
  write_file docker_path script;
  write_file gh_path fake_gh_auth_status_ok;
  Unix.chmod docker_path 0o755;
  Unix.chmod gh_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "MASC_TEST_FAKE_DOCKER_PATH" docker_path @@ fun () ->
  with_env "PATH" path f

let with_tool_policy_config f =
  let project_root = Masc_test_deps.find_project_root () in
  let config_dir = Filename.concat project_root "config" in
  let reset () =
    Masc_mcp.Config_dir_resolver.reset ();
    Tool_code_write.reset_policy_config_cache ();
    Masc_mcp.Keeper_tool_policy.reset_policy_config_for_test ()
  in
  reset ();
  with_env "MASC_CONFIG_DIR" config_dir @@ fun () ->
  reset ();
  Fun.protect ~finally:reset @@ fun () ->
  match Masc_mcp.Keeper_tool_policy.init_policy_config ~base_path:project_root with
  | Ok () -> f ()
  | Error msg -> Alcotest.failf "init_policy_config failed: %s" msg

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

let ensure_github_identity_bundle ~config github_identity =
  let masc_dir = Filename.concat config.Coord.base_path Common.masc_dirname in
  let gh_dir =
    Filename.concat
      (Filename.concat
         (Filename.concat masc_dir "github-identities")
         github_identity)
      "gh"
  in
  ensure_dir gh_dir

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
        Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta ~args
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
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
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
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
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
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
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
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
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
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None ~config ~meta
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
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "echo hello"); ("cwd", `String outside_cwd) ])
      ()
  in
  Alcotest.(check bool)
    "legacy keeper bash does not surface docker image error"
    false
    (response_mentions raw "error" "docker image")

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

let test_bash_git_creds_routes_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "git status"); ("cwd", `String playground) ])
      ()
  in
  Alcotest.(check bool)
    "bash git cmd surfaces docker image config error (git-creds route fired)"
    true
    (response_mentions raw "error" "docker image")

let test_bash_git_creds_uses_oneshot_with_turn_runtime () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  ensure_github_identity_bundle ~config Masc_mcp.Keeper_gh_env.root_github_identity;
  let repo = Filename.concat (Filename.concat playground "repos") "masc-mcp" in
  ensure_dir repo;
  run_ok ~cwd:repo "git init -q";
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:(Some factory) ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "git status"); ("cwd", `String playground) ])
      ()
  in
  Alcotest.(check (option bool)) "git bash succeeds through one-shot docker"
    (Some true)
    (parse_bool_field raw "ok");
  let log = read_file log_path in
  Alcotest.(check bool) "credentialed git used docker run" true
    (contains_substring log "run --rm");
  Alcotest.(check bool) "credentialed git did not use docker exec" false
    (contains_substring log "\nexec ");
  let root_gh_dir =
    Masc_mcp.Keeper_gh_env.root_gh_config_dir config
  in
  Alcotest.(check bool) "one-shot run mounted GH identity bundle" true
    (contains_substring log (root_gh_dir ^ ":/tmp/keeper-creds/.config/gh:ro"))

let test_repair_container_worktree_gitdirs () =
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config:_ ~meta ~playground ->
  let container_root = Keeper_sandbox.container_root meta.name in
  let repo = Filename.concat (Filename.concat playground "repos") "masc-mcp" in
  let wt = Filename.concat (Filename.concat repo ".worktrees") "task-044" in
  let admin = Filename.concat (Filename.concat repo ".git") "worktrees/task-044" in
  ensure_dir wt;
  ensure_dir admin;
  let wt_git = Filename.concat wt ".git" in
  let admin_gitdir = Filename.concat admin "gitdir" in
  write_file wt_git
    (Printf.sprintf "gitdir: %s/repos/masc-mcp/.git/worktrees/task-044\n"
       container_root);
  write_file admin_gitdir
    (Printf.sprintf "%s/repos/masc-mcp/.worktrees/task-044/.git\n"
       container_root);
  let repaired =
    Keeper_shell_docker.repair_container_worktree_gitdirs
      ~host_root:playground ~container_root
  in
  Alcotest.(check int) "repaired both gitdir pointer files" 2 repaired;
  Alcotest.(check bool) "worktree .git uses host path" true
    (contains_substring (read_file wt_git) playground);
  Alcotest.(check bool) "admin gitdir uses host path" true
    (contains_substring (read_file admin_gitdir) playground);
  Alcotest.(check bool) "container path removed from worktree .git" false
    (contains_substring (read_file wt_git) container_root)

let test_git_worktree_add_uses_host_git_metadata () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc-mcp" in
  ensure_dir repo;
  run_ok ~cwd:repo "git init -q -b main";
  run_ok ~cwd:repo "git config user.email test@example.com";
  run_ok ~cwd:repo "git config user.name Test";
  write_file (Filename.concat repo "README.md") "# wt\n";
  run_ok ~cwd:repo "git add README.md";
  run_ok ~cwd:repo "git commit -q -m init";
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "git_worktree");
            ("action", `String "add");
            ("branch", `String "feature/docker-wt");
            ("base", `String "HEAD");
            ("cwd", `String repo);
          ])
  in
  Alcotest.(check (option bool)) "git_worktree add succeeds on host"
    (Some true)
    (parse_bool_field raw "ok");
  let wt_git =
    Filename.concat
      (Filename.concat repo ".worktrees/feature-docker-wt")
      ".git"
  in
  let git_marker = read_file wt_git in
  Alcotest.(check bool) "worktree gitdir uses host repo path" true
    (contains_substring git_marker repo);
  Alcotest.(check bool) "worktree gitdir does not use container root" false
    (contains_substring git_marker (Keeper_sandbox.container_root meta.name))

let test_hard_mode_blocks_raw_gh_bash () =
  with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "true" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground:_ ->
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "gh pr list") ])
      ()
  in
  Alcotest.(check (option string)) "raw gh hard-mode error"
    (Some "gh_requires_brokered_structured_tool")
    (parse_string_field raw "error");
  Alcotest.(check bool) "hint mentions structured op=gh" true
    (response_mentions raw "hint" "keeper_shell op=gh")

let docker_run_line log_path =
  read_file log_path
  |> String.split_on_char '\n'
  |> List.find_opt (String.starts_with ~prefix:"run ")
  |> function
  | Some line -> line
  | None -> Alcotest.fail "expected docker run log line"

let run_git_creds_docker_shell ~config ~meta ~playground ~log_path =
  ensure_github_identity_bundle ~config Masc_mcp.Keeper_gh_env.root_github_identity;
  let repo = Filename.concat (Filename.concat playground "repos") "masc-mcp" in
  ensure_dir repo;
  if not (Sys.file_exists (Filename.concat repo ".git")) then
    run_ok ~cwd:repo "git init -q";
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

let test_sandbox_root_git_cwd_zero_repo_blocks_before_exec () =
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let cwd, error =
    Keeper_shell_docker.resolve_sandbox_root_git_cwd ~config ~meta
      ~cwd:playground ~cmd:"git status"
  in
  Alcotest.(check string) "cwd remains sandbox root" playground cwd;
  match error with
  | None -> Alcotest.fail "expected missing repo guidance"
  | Some msg ->
    Alcotest.(check bool) "mentions no sandbox clones" true
      (contains_substring msg "no sandbox git clones");
    Alcotest.(check bool) "mentions git_clone recovery" true
      (contains_substring msg "keeper_shell op=git_clone");
    Alcotest.(check bool) "mentions cwd recovery" true
      (contains_substring msg "cwd=\"repos/<repo>\"")

let test_sandbox_root_git_cwd_single_repo_auto_chdir () =
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc-mcp" in
  ensure_dir repo;
  run_ok ~cwd:repo "git init -q";
  let cwd, error =
    Keeper_shell_docker.resolve_sandbox_root_git_cwd ~config ~meta
      ~cwd:playground ~cmd:"git status"
  in
  let repo =
    Keeper_alerting_path.normalize_path_for_check repo
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  Alcotest.(check (option string)) "no error" None error;
  Alcotest.(check string) "auto cwd selects the only repo" repo cwd

let test_sandbox_root_git_cwd_multi_repo_blocks_before_exec () =
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let repos = Filename.concat playground "repos" in
  let repo_a = Filename.concat repos "alpha" in
  let repo_b = Filename.concat repos "beta" in
  ensure_dir repo_a;
  ensure_dir repo_b;
  run_ok ~cwd:repo_a "git init -q";
  run_ok ~cwd:repo_b "git init -q";
  let cwd, error =
    Keeper_shell_docker.resolve_sandbox_root_git_cwd ~config ~meta
      ~cwd:playground ~cmd:"gh pr list"
  in
  Alcotest.(check string) "cwd remains sandbox root" playground cwd;
  match error with
  | None -> Alcotest.fail "expected multi repo cwd guidance"
  | Some msg ->
    Alcotest.(check bool) "mentions multiple repos" true
      (contains_substring msg "multiple sandbox repos");
    Alcotest.(check bool) "mentions concrete cwd" true
      (contains_substring msg "\"cwd\": \"repos/alpha\"");
    Alcotest.(check bool) "lists beta too" true
      (contains_substring msg "alpha, beta")

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

let test_git_creds_mounts_numeric_user_identity () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  let line =
    with_env "GH_TOKEN" "host-token" @@ fun () ->
    with_env "GITHUB_TOKEN" "github-token" @@ fun () ->
    run_git_creds_docker_shell ~config ~meta ~playground ~log_path
  in
  let root_gh_dir =
    Masc_mcp.Keeper_gh_env.root_gh_config_dir config
  in
  Alcotest.(check bool) "root GH identity bundle mounted" true
    (contains_substring line (root_gh_dir ^ ":/tmp/keeper-creds/.config/gh:ro"));
  Alcotest.(check bool) "ambient GH_TOKEN not forwarded" false
    (contains_substring line "GH_TOKEN=");
  Alcotest.(check bool) "ambient GITHUB_TOKEN not forwarded" false
    (contains_substring line "GITHUB_TOKEN=");
  let identity_dir = Filename.concat playground ".docker-identity" in
  let passwd_path = Filename.concat identity_dir "passwd" in
  let group_path = Filename.concat identity_dir "group" in
  Alcotest.(check bool) "passwd file mounted" true
    (contains_substring line (passwd_path ^ ":/etc/passwd:ro"));
  Alcotest.(check bool) "group file mounted" true
    (contains_substring line (group_path ^ ":/etc/group:ro"));
  Alcotest.(check bool) "USER env forwarded" true
    (contains_substring line "USER=keeper");
  Alcotest.(check bool) "passwd maps host uid" true
    (contains_substring (read_file passwd_path)
       (Printf.sprintf "keeper:x:%d:%d:" (Unix.getuid ()) (Unix.getgid ())));
  Alcotest.(check bool) "group maps host gid" true
    (contains_substring (read_file group_path)
       (Printf.sprintf "keeper:x:%d:" (Unix.getgid ())))

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

let test_git_creds_mounts_only_selected_keeper_identity () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_two_docker_keepers
  @@ fun ~config ~meta_a ~playground_a ~meta_b ~playground_b ->
  let identity_a = "keeper-a-gh" in
  let identity_b = "keeper-b-gh" in
  ensure_github_identity_bundle ~config
    Masc_mcp.Keeper_gh_env.root_github_identity;
  ensure_github_identity_bundle ~config identity_a;
  ensure_github_identity_bundle ~config identity_b;
  let root_gh_dir = Masc_mcp.Keeper_gh_env.root_gh_config_dir config in
  let gh_dir id =
    Masc_mcp.Keeper_gh_env.gh_config_dir_of_bundle
      (Masc_mcp.Keeper_gh_env.bundle_root config ~github_identity:id)
  in
  let run_for ~(meta : Keeper_types.keeper_meta) ~playground ~github_identity
      ~other_identity ~log_name =
    with_keeper_identity_toml ~config ~keeper_name:meta.name
      ~github_identity ~git_identity_mode:"github_identity"
    @@ fun () ->
    let log_path = Filename.concat config.Coord.base_path log_name in
    let line =
      run_git_creds_docker_shell ~config ~meta ~playground ~log_path
    in
    let selected_gh = gh_dir github_identity in
    let other_gh = gh_dir other_identity in
    let mounted_playground =
      Keeper_alerting_path.normalize_path_for_check playground
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    Alcotest.(check bool)
      (github_identity ^ " selected GH bundle mounted read-only")
      true
      (contains_substring line
         (selected_gh ^ ":/tmp/keeper-creds/.config/gh:ro"));
    Alcotest.(check bool)
      (github_identity ^ " root fallback bundle not mounted")
      false
      (contains_substring line
         (root_gh_dir ^ ":/tmp/keeper-creds/.config/gh:ro"));
    Alcotest.(check bool)
      (github_identity ^ " sibling keeper bundle not mounted")
      false
      (contains_substring line
         (other_gh ^ ":/tmp/keeper-creds/.config/gh:ro"));
    Alcotest.(check bool)
      (github_identity ^ " own playground mounted")
      true
      (contains_substring line
         (mounted_playground ^ ":"
          ^ Keeper_sandbox.container_root meta.name
          ^ ":rw"));
    line
  in
  let mounted_playground_a =
    Keeper_alerting_path.normalize_path_for_check playground_a
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let mounted_playground_b =
    Keeper_alerting_path.normalize_path_for_check playground_b
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let line_a =
    run_for ~meta:meta_a ~playground:playground_a
      ~github_identity:identity_a ~other_identity:identity_b
      ~log_name:"docker-a.log"
  in
  let line_b =
    run_for ~meta:meta_b ~playground:playground_b
      ~github_identity:identity_b ~other_identity:identity_a
      ~log_name:"docker-b.log"
  in
  Alcotest.(check bool) "keeper A docker run does not mount keeper B playground"
    false
    (contains_substring line_a mounted_playground_b);
  Alcotest.(check bool) "keeper B docker run does not mount keeper A playground"
    false
    (contains_substring line_b mounted_playground_a)

let test_git_clone_repairs_existing_docker_clone_checkout () =
  with_tool_policy_config @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  ensure_github_identity_bundle ~config Masc_mcp.Keeper_gh_env.root_github_identity;
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
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
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
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "echo hello"); ("cwd", `String playground) ])
      ()
  in
  Alcotest.(check (option bool)) "bash via fake docker is ok" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "bash via=docker" (Some "docker")
    (parse_string_field raw "via");
  Alcotest.(check bool) "bash output includes fake docker stdout" true
    (response_mentions raw "output" "stdout:")

let test_bash_rewrites_host_path_command_for_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let container_root = Keeper_sandbox.container_root meta.name in
  let raw =
    Keeper_exec_shell.handle_keeper_bash ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ( "cmd",
              `String
                (Printf.sprintf "cd %s/repos/masc-mcp && pwd"
                   (Keeper_alerting_path.strip_trailing_slashes playground)) );
            ("cwd", `String playground);
          ])
      ()
  in
  Alcotest.(check (option bool)) "bash via fake docker is ok" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check bool) "command uses container path" true
    (response_mentions raw "output"
       (Filename.concat container_root "repos/masc-mcp"));
  Alcotest.(check bool) "command no longer leaks host playground path" false
    (response_mentions raw "output" playground)

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
	            "docker keeper bash git creds bypass warm turn runtime"
	            `Quick test_bash_git_creds_uses_oneshot_with_turn_runtime;
	          Alcotest.test_case
	            "hard mode blocks raw gh keeper_bash"
	            `Quick test_hard_mode_blocks_raw_gh_bash;
          Alcotest.test_case
            "docker keeper bash executes through fake docker"
            `Quick test_bash_fake_docker_executes;
          Alcotest.test_case
            "docker keeper bash rewrites host paths before exec"
            `Quick test_bash_rewrites_host_path_command_for_docker;
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
            "git-creds mounts passwd entry for numeric uid"
            `Quick test_git_creds_mounts_numeric_user_identity;
          Alcotest.test_case
            "git-creds respects keeper_alias git identity mode"
            `Quick test_git_creds_respects_keeper_alias_identity_mode;
          Alcotest.test_case
            "git-creds uses GitHub author only in github_identity mode"
            `Quick test_git_creds_uses_github_identity_mode;
          Alcotest.test_case
            "git-creds mounts only the selected keeper identity"
            `Quick test_git_creds_mounts_only_selected_keeper_identity;
          Alcotest.test_case "hard mode git_clone uses brokered route" `Quick
            test_hard_mode_git_clone_uses_brokered_route;
	          Alcotest.test_case "git_clone repairs existing docker clone checkout"
	            `Quick test_git_clone_repairs_existing_docker_clone_checkout;
	          Alcotest.test_case "docker worktree gitdir paths are host-repaired"
	            `Quick test_repair_container_worktree_gitdirs;
	          Alcotest.test_case
	            "git_worktree add keeps host-readable metadata"
	            `Quick test_git_worktree_add_uses_host_git_metadata;
	          Alcotest.test_case
	            "sandbox-root git with no repo blocks before docker exec"
            `Quick test_sandbox_root_git_cwd_zero_repo_blocks_before_exec;
          Alcotest.test_case
            "sandbox-root git with one repo auto-selects cwd"
            `Quick test_sandbox_root_git_cwd_single_repo_auto_chdir;
          Alcotest.test_case
            "sandbox-root git with multiple repos gives cwd correction"
            `Quick test_sandbox_root_git_cwd_multi_repo_blocks_before_exec;
        ] );
    ]
