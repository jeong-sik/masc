(** Tests for tool_search_files docker routing (RFC-0006 Phase B-3b+).

    Verifies that Docker keepers route SearchFiles ops through
    docker. The docker process itself is not invoked because the test
    environment sets
    [MASC_KEEPER_SANDBOX_DOCKER_IMAGE=""], so the response must
    surface the structured "docker image is not configured" error from
    [Keeper_sandbox_read_backend] — proof that control reached the docker
    route. *)

module Workspace = Masc.Workspace
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_tool_command_runtime = Masc.Keeper_tool_command_runtime
module Keeper_tool_dispatch_runtime = Masc.Keeper_tool_dispatch_runtime
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_exec_failure = Masc.Keeper_sandbox_exec_failure
module Keeper_sandbox_factory = Masc.Keeper_sandbox_factory
module Keeper_sandbox_runtime = Masc.Keeper_sandbox_runtime
module Keeper_turn_sandbox_runtime = Masc.Keeper_turn_sandbox_runtime
module Keeper_tool_execute_command_semantics = Masc.Keeper_tool_execute_command_semantics
module Keeper_sandbox_docker = Masc.Keeper_sandbox_docker
module Keeper_types = Keeper_types
module Keeper_alerting_path = Masc.Keeper_alerting_path
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

(* ── Helpers ─────────────────────────────────────────────────────── *)

let resolve_sandbox_root_git_cwd_string ~config ~meta ~cwd ~cmd =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed ir ->
    Keeper_tool_execute_command_semantics.resolve_sandbox_root_git_cwd
      ~config ~meta ~cwd ~cmd ir
  | _ -> cwd, None

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let with_config_dir config_dir f =
  let prior = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match prior with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f ())

let temp_dir () =
  let dir = Filename.temp_file "keeper_sandbox_docker_route_" "" in
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

let docker_log_has_container_execution log =
  contains_substring ("\n" ^ log) "\nrun "
  || contains_substring ("\n" ^ log) "\nexec "

let env_file_path_from_docker_line line =
  let rec loop = function
    | "--env-file" :: path :: _ -> Some path
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop (String.split_on_char ' ' line)

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let process_exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255

let rec waitpid_nointr pid =
  try Unix.waitpid [] pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid

let run_process_ok ~cwd prog argv =
  let original_cwd = Sys.getcwd () in
  let dev_null = Unix.openfile Filename.null [ Unix.O_WRONLY ] 0o600 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close dev_null;
      Sys.chdir original_cwd)
    (fun () ->
      Sys.chdir cwd;
      let pid =
        Unix.create_process_env prog argv (Unix.environment ()) Unix.stdin
          dev_null dev_null
      in
      let _, status = waitpid_nointr pid in
      let code = process_exit_code status in
      if code <> 0 then
        Alcotest.failf "command failed (%d): %s" code
          (String.concat " " (Array.to_list argv)))

let git_ok ~cwd args =
  run_process_ok ~cwd "git" (Array.of_list ("git" :: args))

let write_repositories_toml ~base_path ~repo_name ~url =
  let config_dir =
    Filename.concat (Filename.concat base_path Common.masc_dirname) "config"
  in
  ensure_dir config_dir;
  write_file
    (Filename.concat config_dir "repositories.toml")
    (Printf.sprintf
       "[repository.%s]\nname = \"%s\"\nurl = \"%s\"\n"
       repo_name
       repo_name
       (String.escaped url))

let setup_ready_repo_with_origin ~config ~repo_name ~repo =
  let base_path = config.Workspace.base_path in
  let remote = Filename.concat base_path (Printf.sprintf ".remote-%s.git" repo_name) in
  let seed = Filename.concat base_path (Printf.sprintf "seed-%s" repo_name) in
  git_ok ~cwd:base_path
    [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; seed ];
  git_ok ~cwd:seed [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:seed [ "config"; "user.name"; "Test" ];
  write_file (Filename.concat seed "README.md") "v1\n";
  git_ok ~cwd:seed [ "add"; "README.md" ];
  git_ok ~cwd:seed [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:seed [ "push"; "-q"; "origin"; "main" ];
  ensure_dir (Filename.dirname repo);
  git_ok ~cwd:(Filename.dirname repo) [ "clone"; "-q"; remote; repo ];
  write_repositories_toml ~base_path ~repo_name ~url:remote

let ensure_git_repo repo =
  ensure_dir repo;
  if not (Sys.file_exists (Filename.concat repo ".git")) then
    git_ok ~cwd:repo [ "init"; "-q" ]

let docker_image_available image =
  let cmd =
    Printf.sprintf "docker image inspect %s > /dev/null 2>&1" (Filename.quote image)
  in
  Sys.command cmd = 0

let make_meta ?tool_access ~name ~sandbox () =
  let fields =
    [
      ("name", `String name);
      ("agent_name", `String ("agent-" ^ name));
      ("trace_id", `String ("trace-" ^ name));
    ]
  in
  let fields =
    match tool_access with
    | None -> fields
    | Some tool_access ->
      fields
      @ [ ( "tool_access",
            Json_util.json_string_list tool_access ) ]
  in
  let json =
    `Assoc fields
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with
      goal = "shell docker route test"
    ; allowed_paths = ["*"]
    ; sandbox_profile = sandbox
    }
  | Error e -> Alcotest.fail e

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f

let setup ?tool_access ~sandbox f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  let config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir config_dir;
  let config = Workspace.default_config base in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_meta ?tool_access ~name:"minjae" ~sandbox () in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  let repos_toml = Filename.concat config_dir "repositories.toml" in
  write_file repos_toml
    (Printf.sprintf
       "[repository.masc]\n\
        name = \"masc\"\n\
        url = \"%s\"\n\
        local_path = \"repos/masc\"\n\
        status = \"Active\"\n\
        keepers = [\"minjae\"]\n"
       playground);
  f ~config ~meta ~playground

let setup_with_tool_access ~sandbox f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  let config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir config_dir;
  let config = Workspace.default_config base in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let meta =
    make_meta
      ~name:"minjae"
      ~sandbox
      ~tool_access:
        [ "tool_execute"; "tool_read_file"; "tool_search_files"; "tool_edit_file"; "tool_write_file" ]
      ()
  in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  let repos_toml = Filename.concat config_dir "repositories.toml" in
  write_file repos_toml
    (Printf.sprintf
       "[repository.masc]\n\
        name = \"masc\"\n\
        url = \"%s\"\n\
        local_path = \"repos/masc\"\n\
        status = \"Active\"\n\
        keepers = [\"minjae\"]\n"
       playground);
  f ~config ~meta ~playground

let with_turn_sandbox_factory ~config ~meta f =
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory) @@ fun () ->
  f factory

let test_turn_sandbox_factory_uses_refreshed_registry_meta () =
  setup ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~config ~meta ~playground:_ ->
  let docker_meta =
    { meta with
      Keeper_meta_contract.sandbox_profile = Keeper_types_profile_sandbox.Docker
    }
  in
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  ignore (Keeper_registry.register ~base_path:config.Workspace.base_path meta.name docker_meta);
  Fun.protect
    ~finally:(fun () ->
      Keeper_sandbox_factory.cleanup factory;
      Keeper_registry.unregister ~base_path:config.Workspace.base_path meta.name)
  @@ fun () ->
  let docker_playground = Keeper_sandbox.host_root_abs_of_meta ~config docker_meta in
  match Keeper_sandbox_factory.resolve factory ~cwd:docker_playground with
  | Runtime runtime ->
    Alcotest.(check string)
      "runtime host root follows refreshed Docker meta"
      (Keeper_alerting_path.normalize_path_for_check_stripped docker_playground)
      (Keeper_turn_sandbox_runtime.host_root runtime)
  | No_factory | Local_profile ->
    Alcotest.fail "expected refreshed registry Docker meta to resolve a turn runtime"

let with_fake_docker script f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  let gh_path = Filename.concat dir "gh" in
  let fake_gh_auth_status_ok =
    "#!/bin/sh\n\
     if [ \"$1\" = \"auth\" ] && [ \"$2\" = \"status\" ]; then\n\
       exit 0\n\
     fi\n\
     printf 'gh:%s\\n' \"$*\"\n\
     exit 0\n";
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
  with_env "PATH" path @@ fun () ->
  with_env "MASC_KEEPER_SYSTEM_FD_HEADROOM" "0" @@ fun () ->
  with_env "MASC_KEEPER_HOST_FD_HOTSPOT_HEADROOM" "0" f

let with_tool_policy_config f = f ()

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
  let rel_dir = "mind" in
  let rel_path = Filename.concat rel_dir "demo.txt" in
  let host_path = Filename.concat playground rel_path in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "alpha\nbeta\ngamma\n");
  let cases =
    [
      ( "rg",
        `Assoc
          [
            ("op", `String "rg");
            ("pattern", `String "alpha");
            ("path", `String rel_dir);
          ] );
    ]
  in
  List.iter
    (fun (op, args) ->
      let raw =
        Keeper_tool_command_runtime.handle_tool_search_files ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta ~args
      in
      if not (response_mentions raw "error" "docker image") then
        Alcotest.failf "unexpected %s docker-route response: %s" op raw)
    cases

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_readonly_ops_route_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  assert_docker_route_fires ~config ~meta ~playground

let test_cat_legacy_keeper_skips_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~config ~meta ~playground ->
  let host_path = Filename.concat playground "mind/x" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "matrix");
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
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
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"inspect\" ]; then\n\
  printf 'fake-container-id\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"ps\" ]; then\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"exec\" ]; then\n\
  shift\n\
  while [ \"$#\" -gt 0 ]; do\n\
    case \"$1\" in\n\
      -i|--interactive) shift ;;\n\
      -w|--workdir|-e|--env|-u|--user) shift 2 ;;\n\
      --) shift; break ;;\n\
      *) shift; break ;;\n\
    esac\n\
  done\n\
  if [ \"$1\" = \"rg\" ]; then\n\
    exit 1\n\
  fi\n\
  cat >/dev/null\n\
  printf 'stdout:%s\\n' \"$*\"\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"rm\" ]; then\n\
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
script=$(cat)\n\
case \"$script\" in\n\
  *rg*) exit 1 ;;\n\
esac\n\
if [ \"$1\" = \"rg\" ]; then\n\
  exit 1\n\
fi\n\
printf '%s\\n' \"$*\"\n\
exit 0\n"

let fake_docker_bash_rg_no_match_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ]; then\n\
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
if [ \"$1\" = \"bash\" ] && [ \"$2\" = \"-l\" ] && [ \"$3\" = \"-s\" ]; then\n\
  script=$(cat)\n\
  case \"$script\" in\n\
    *rg*) exit 1 ;;\n\
  esac\n\
fi\n\
if [ \"$1\" = \"rg\" ]; then\n\
  exit 1\n\
fi\n\
printf 'stdout:%s\\n' \"$*\"\n\
exit 0\n"

let test_rg_no_match_remains_successful_in_docker_route () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_rg_no_match_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let host_path = Filename.concat playground "mind/demo.txt" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "alpha\nbeta\ngamma\n");
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
            [
              ("op", `String "rg");
              ("pattern", `String "missing");
              ("path", `String "mind");
            ])
  in
  Alcotest.(check (option bool)) "rg no-match stays ok" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check int) "rg keeps exit=1 status" 1
    (parse_status_exit_code raw);
  Alcotest.(check int) "rg no-match returns empty matches" 0
    (parse_field raw "matches" |> Json.to_list |> List.length)

let test_unknown_workspace_op_is_unsupported_before_docker () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground:_ ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:None
      ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "future_repo_op");
            ("url", `String "https://github.com/jeong-sik/masc.git");
          ])
  in
  (match parse_bool_field raw "ok" with
   | Some true -> Alcotest.failf "unknown op unexpectedly succeeded: %s" raw
   | Some false | None -> ());
  Alcotest.(check bool)
    "non-rg op fails closed with unsupported-op error"
    true
    (response_mentions raw "error" "does not support op");
  Alcotest.(check (option string))
    "handler preserves requested op, not rewritten to rg"
    (Some "future_repo_op")
    (parse_string_field raw "op")

let test_turn_sandbox_file_write_uses_host_bind_mount () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let runtime = Keeper_turn_sandbox_runtime.create ~config ~meta ~turn_id:1 () in
  let target = Filename.concat playground "nested/result.txt" in
  (match
     Keeper_turn_sandbox_runtime.overwrite_file
       runtime
       ~timeout_sec:30.0
       ~host_path:target
       ~content:"alpha\n"
       ()
   with
   | Error msg -> Alcotest.fail msg
   | Ok () -> ());
  (match
     Keeper_turn_sandbox_runtime.append_file
       runtime
       ~timeout_sec:30.0
       ~host_path:target
       ~content:"beta\n"
       ()
   with
   | Error msg -> Alcotest.fail msg
   | Ok () -> ());
  Alcotest.(check string) "content written via bind-mounted host path"
    "alpha\nbeta\n"
    (Fs_compat.load_file target)

let tool_execute_typed_pipeline_args ~cwd =
  `Assoc
    [
      ( "pipeline",
        `List
          [
            `Assoc
              [
                ("executable", `String "printf");
                ("argv", `List [ `String "typed" ]);
              ];
            `Assoc
              [
                ("executable", `String "wc");
                ("argv", `List [ `String "-c" ]);
              ];
          ] );
      ("cwd", `String cwd);
      ("timeout_sec", `Float 5.0);
    ]

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let tool_execute_typed_exec_args ?(argv = []) ~cwd executable =
  `Assoc
    [
      ("executable", `String executable);
      ("argv", json_string_list argv);
      ("cwd", `String cwd);
      ("timeout_sec", `Float 5.0);
    ]

let tool_execute_typed_pipeline_args_of ~cwd stages =
  `Assoc
    [
      ( "pipeline",
        `List
          (List.map
             (fun (executable, argv) ->
               `Assoc
                 [
                   ("executable", `String executable);
                   ("argv", json_string_list argv);
                 ])
             stages) );
      ("cwd", `String cwd);
      ("timeout_sec", `Float 5.0);
    ]

let tool_execute_typed_single_stage_pipeline_args ~cwd =
  `Assoc
    [
      ( "pipeline",
        `List
          [
            `Assoc
              [
                ("executable", `String "printf");
                ("argv", `List [ `String "typed" ]);
              ];
          ] );
      ("cwd", `String cwd);
      ("timeout_sec", `Float 5.0);
    ]

let tool_execute_typed_env_wrapper_args ~cwd =
  `Assoc
    [
      ("executable", `String "env");
      ("argv", `List [ `String "id" ]);
      ("cwd", `String cwd);
      ("timeout_sec", `Float 5.0);
    ]

let check_typed_pipeline_response raw =
  (match parse_bool_field raw "ok" with
   | Some true -> ()
   | Some false -> Alcotest.failf "typed pipeline succeeds: got false in %s" raw
   | None -> Alcotest.failf "typed pipeline succeeds: missing ok in %s" raw);
  Alcotest.(check (option bool)) "typed response" (Some true)
    (parse_bool_field raw "typed");
  Alcotest.(check int) "typed pipeline exit status" 0
    (parse_status_exit_code raw);
  Alcotest.(check bool) "pipeline output propagated" true
    (response_mentions raw "output" "5")

let check_typed_validation_error needle raw =
  (match parse_bool_field raw "ok" with
   | Some true -> Alcotest.failf "typed command unexpectedly succeeded: %s" raw
   | Some false | None -> ());
  Alcotest.(check (option bool)) "typed response" (Some true)
    (parse_bool_field raw "typed");
  Alcotest.(check bool) "validation error surfaced" true
    (response_mentions raw "error" needle);
  let deterministic_retry = parse_field raw "deterministic_retry" in
  Alcotest.(check (option string)) "deterministic reason"
    (Some "command_shape_blocked")
    (Json.member "reason" deterministic_retry |> Json.to_string_option);
  Alcotest.(check (option bool)) "same args retry disabled"
    (Some false)
    (Json.member "retry_same_args" deterministic_retry |> Json.to_bool_option)

let test_execute_typed_env_wrapper_target_allowed () =
  setup ~tool_access:[] ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:(tool_execute_typed_env_wrapper_args ~cwd:playground)
      ()
  in
  Alcotest.(check (option bool)) "typed env wrapper succeeds" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option bool)) "typed response" (Some true)
    (parse_bool_field raw "typed");
  Alcotest.(check int) "env wrapper exit status" 0 (parse_status_exit_code raw)

let test_execute_typed_single_stage_pipeline_rejected () =
  setup ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~config ~meta ~playground ->
  Keeper_tool_command_runtime.handle_tool_execute
    ~turn_sandbox_factory:None
    ~exec_cache:None
    ~config
    ~meta
    ~args:(tool_execute_typed_single_stage_pipeline_args ~cwd:playground)
    ()
  |> check_typed_validation_error "pipeline requires at least two stages"

let test_execute_typed_repeated_executable_is_autocorrected () =
  setup ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (tool_execute_typed_exec_args
           ~cwd:playground
           ~argv:[ "find"; "."; "-name"; "*.ml" ]
           "find")
      ()
  in
  Alcotest.(check (option bool)) "autocorrected repeated argv[0] succeeds" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option bool)) "typed response" (Some true)
    (parse_bool_field raw "typed");
  Alcotest.(check int) "find exit status" 0 (parse_status_exit_code raw)

let test_execute_typed_pipeline_falls_back_to_local_playground () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "missing:test" @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:(tool_execute_typed_pipeline_args ~cwd:playground)
      ()
  in
  check_typed_pipeline_response raw;
  Alcotest.(check (option string)) "requested docker" (Some "docker")
    (parse_string_field raw "requested_sandbox");
  Alcotest.(check (option string)) "fallback local playground"
    (Some "local_playground")
    (parse_string_field raw "sandbox_fallback")

let test_execute_typed_pipeline_uses_local_shell_ir_dispatch () =
  setup ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~config ~meta ~playground ->
  Keeper_tool_command_runtime.handle_tool_execute
    ~turn_sandbox_factory:None
    ~exec_cache:None
    ~config
    ~meta
    ~args:(tool_execute_typed_pipeline_args ~cwd:playground)
    ()
  |> check_typed_pipeline_response

let test_execute_typed_pipeline_uses_turn_sandbox_docker_runner () =
  let image = "masc-keeper-sandbox:local" in
  if not (docker_image_available image)
  then Alcotest.skip ()
  else
    with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" image
    @@ fun () ->
    setup ~sandbox:Keeper_types_profile_sandbox.Docker
    @@ fun ~config ~meta ~playground ->
    let factory = Keeper_sandbox_factory.create ~config ~meta () in
    Fun.protect
      ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
    @@ fun () ->
    let raw =
      Keeper_tool_command_runtime.handle_tool_execute
        ~turn_sandbox_factory:(Some factory)
        ~exec_cache:None
        ~config
        ~meta
        ~args:(tool_execute_typed_pipeline_args ~cwd:playground)
        ()
    in
    check_typed_pipeline_response raw;
    Alcotest.(check (option string)) "no local fallback when docker works" None
      (parse_string_field raw "sandbox_fallback")

let test_execute_routes_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:(tool_execute_typed_exec_args ~cwd:playground "echo" ~argv:[ "hello" ])
      ()
  in
  Alcotest.(check (option bool)) "typed Execute succeeds via local fallback" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "requested docker" (Some "docker")
    (parse_string_field raw "requested_sandbox");
  Alcotest.(check (option string)) "fallback local playground"
    (Some "local_playground")
    (parse_string_field raw "sandbox_fallback")

let test_execute_legacy_skips_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~config ~meta ~playground ->
  let outside_cwd = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir outside_cwd) @@ fun () ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "echo hello"); ("cwd", `String outside_cwd) ])
      ()
  in
  Alcotest.(check bool)
    "legacy Execute does not surface docker image error"
    false
    (response_mentions raw "error" "docker image")

let fake_docker_echo_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"inspect\" ]; then\n\
  printf 'fake-container-id\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"ps\" ]; then\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"exec\" ]; then\n\
  shift\n\
  while [ \"$#\" -gt 0 ]; do\n\
    case \"$1\" in\n\
      -i|--interactive) shift ;;\n\
      -w|--workdir|-e|--env|-u|--user) shift 2 ;;\n\
      --) shift; break ;;\n\
      *) shift; break ;;\n\
    esac\n\
  done\n\
  cat >/dev/null\n\
  printf 'stdout:%s\\n' \"$*\"\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"rm\" ]; then\n\
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
cat >/dev/null\n\
printf 'stdout:%s\\n' \"$*\"\n\
exit 0\n"

let fake_docker_missing_image_script =
  "#!/bin/sh\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
fi\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ]; then\n\
  printf 'Error: No such image: %s\\n' \"$3\" >&2\n\
  exit 1\n\
fi\n\
if [ \"$1\" = \"run\" ]; then\n\
  printf 'docker run should not execute when image inspect fails\\n' >&2\n\
  exit 2\n\
fi\n\
printf 'unexpected docker invocation: %s\\n' \"$1\" >&2\n\
exit 2\n"

let fake_docker_timeout_then_ok_script =
  "#!/bin/sh\n\
state_dir=$(dirname \"$0\")\n\
run_count_file=\"$state_dir/timeout-run.count\"\n\
log_file=${MASC_KEEPER_TEST_DOCKER_LOG:-}\n\
if [ -n \"$log_file\" ]; then\n\
  printf '%s\n' \"$*\" >> \"$log_file\"\n\
fi\n\
read_count() { if [ -f \"$1\" ]; then cat \"$1\"; else printf '0'; fi }\n\
write_count() { printf '%s' \"$2\" > \"$1\"; }\n\
if [ \"$1\" = \"info\" ]; then printf '[]\n'; exit 0; fi\n\
if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ]; then printf '[]\n'; exit 0; fi\n\
if [ \"$1\" = \"rm\" ]; then exit 0; fi\n\
if [ \"$1\" != \"run\" ]; then\n\
  printf 'unexpected docker invocation: %s\n' \"$1\" >&2\n\
  exit 2\n\
fi\n\
count=$(read_count \"$run_count_file\")\n\
count=$((count + 1))\n\
write_count \"$run_count_file\" \"$count\"\n\
if [ \"$count\" = \"1\" ]; then\n\
  printf 'process error: timeout after 5s\n' >&2\n\
  exit 124\n\
fi\n\
shift\n\
while [ \"$#\" -gt 0 ]; do\n\
  if [ \"$1\" = \"alpine:test\" ]; then shift; break; fi\n\
  shift\n\
done\n\
printf 'retry-ok\n'\n\
exit 0\n"

let test_docker_run_retries_on_daemon_timeout () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_timeout_then_ok_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  match
    Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config
      ~meta
      ~cwd:playground
      ~timeout_sec:5.0
      ~cmd:"echo hi"
      ~network_mode:Keeper_types_profile_sandbox.Network_none
  with
  | Error msg -> Alcotest.failf "unexpected error after daemon-timeout retry: %s" msg
  | Ok result ->
    Alcotest.(check int) "retry succeeds exit 0" 0
      (match result.status with
       | Unix.WEXITED n -> n
       | _ -> -1);
    Alcotest.(check bool) "output from second run" true
      (contains_substring result.output "retry-ok")

let test_execute_git_routes_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  setup_ready_repo_with_origin ~config ~repo_name:"masc" ~repo;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:(tool_execute_typed_exec_args ~cwd:repo "git" ~argv:[ "status" ])
      ()
  in
  Alcotest.(check (option bool)) "typed git bash uses local fallback" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "requested docker" (Some "docker")
    (parse_string_field raw "requested_sandbox");
  Alcotest.(check (option string)) "fallback local playground"
    (Some "local_playground")
    (parse_string_field raw "sandbox_fallback")

let test_execute_git_uses_turn_runtime () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  setup_ready_repo_with_origin ~config ~repo_name:"masc" ~repo;
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:(tool_execute_typed_exec_args ~cwd:repo "git" ~argv:[ "status" ])
      ()
  in
  (match parse_bool_field raw "ok" with
   | Some true -> ()
   | other ->
     Alcotest.failf
       "git bash succeeds through turn docker: ok=%s raw=%s"
       (match other with
        | Some true -> "Some true"
        | Some false -> "Some false"
        | None -> "None")
       raw);
  let log = read_file log_path in
  Alcotest.(check bool) "git started docker session" true
    (contains_substring log "run -d");
  Alcotest.(check bool) "git used docker exec" true
    (contains_substring log "\nexec ")

let test_execute_git_without_github_bundle_succeeds () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  setup_ready_repo_with_origin ~config ~repo_name:"masc" ~repo;
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None
      ~config
      ~meta
      ~args:(tool_execute_typed_exec_args ~cwd:repo "git" ~argv:[ "status" ])
      ()
  in
  Alcotest.(check (option bool)) "typed git succeeds without GH bundle" (Some true)
    (parse_bool_field raw "ok");
  let log = if Sys.file_exists log_path then read_file log_path else "" in
  Alcotest.(check bool) "typed git uses docker exec" true
    (contains_substring log "\nexec ");
  Alcotest.(check bool) "typed git has no failure class" true
    (match
       Keeper_tool_dispatch_runtime.failure_class_of_tool_result_payload raw
     with
     | None -> true
     | Some _ -> false)

let test_execute_git_c_option_missing_dir_blocks_before_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_exec_args ~cwd:playground "git"
           ~argv:[ "-C"; "repos/masc/.worktrees/missing"; "status" ])
      ()
  in
  Alcotest.(check bool) "typed cwd error" true
    (response_mentions raw "error" "cwd_not_directory");
  Alcotest.(check bool) "docker runtime was touched before cwd validation" true
    (Sys.file_exists log_path)

let test_execute_missing_playground_blocks_before_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  let mount_source =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.normalize_path_for_check
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  cleanup_dir playground;
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  let err =
    match
      Keeper_sandbox_docker.run_trusted_docker_shell_command_with_status
      ~config
      ~meta
      ~cwd:playground
      ~timeout_sec:5.0
      ~cmd:"pwd"
      ~network_mode:Keeper_types_profile_sandbox.Network_inherit
    with
    | Ok _ -> Alcotest.fail "expected missing playground to block before docker"
    | Error err -> err
  in
  Alcotest.(check bool)
    "missing bind source is typed"
    true
    (contains_substring err "mount_source_not_found");
  Alcotest.(check bool)
    "full mount path is surfaced"
    true
    (contains_substring err mount_source);
  Alcotest.(check bool)
    "base path hash is surfaced"
    true
    (contains_substring err "base_path_hash=");
  Alcotest.(check bool) "docker was not invoked" false (Sys.file_exists log_path)

let test_execute_git_c_bare_worktrees_from_root_blocks_typed_argv () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  let worktree = Filename.concat repo ".worktrees/task-229" in
  ensure_dir worktree;
  git_ok ~cwd:repo [ "init"; "-q" ];
  git_ok ~cwd:worktree [ "init"; "-q" ];
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_exec_args ~cwd:playground "git"
           ~argv:[ "-C"; ".worktrees/task-229"; "status"; "-sb" ])
      ()
  in
  (match parse_bool_field raw "ok" with
   | Some true -> Alcotest.failf "bare .worktrees unexpectedly succeeded: %s" raw
   | Some false | None -> ());
  Alcotest.(check bool)
    "typed argv does not infer repo for bare .worktrees"
    true
    (response_mentions raw "error" "cwd_not_directory")

let test_execute_git_status_readonly_without_write_tool_access () =
  setup ~tool_access:[] ~sandbox:Keeper_types_profile_sandbox.Local
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  setup_ready_repo_with_origin ~config ~repo_name:"masc" ~repo;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:(tool_execute_typed_exec_args ~cwd:repo "git" ~argv:[ "status"; "--short" ])
      ()
  in
  Alcotest.(check (option bool)) "git status succeeds without write access"
    (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option bool)) "typed response" (Some true)
    (parse_bool_field raw "typed")

let test_execute_git_push_without_write_tool_access_routes_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~tool_access:[] ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  ensure_dir repo;
  git_ok ~cwd:playground [ "init"; "-q" ];
  git_ok ~cwd:playground [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:playground [ "config"; "user.name"; "test" ];
  git_ok ~cwd:playground [ "commit"; "--allow-empty"; "-m"; "initial"; "-q" ];
  git_ok ~cwd:playground [ "branch"; "-m"; "main" ];
  git_ok ~cwd:repo [ "init"; "-q" ];
  git_ok ~cwd:repo [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:repo [ "config"; "user.name"; "test" ];
  git_ok ~cwd:repo [ "remote"; "add"; "origin"; playground ];
  git_ok ~cwd:repo [ "fetch"; "origin"; "-q" ];
  git_ok ~cwd:repo [ "branch"; "-m"; "main" ];
  git_ok ~cwd:repo [ "reset"; "--hard"; "origin/main" ];
  git_ok ~cwd:repo [ "branch"; "--set-upstream-to=origin/main"; "main" ];
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_exec_args ~cwd:repo "git"
           ~argv:[ "push"; "origin"; "feature/proof" ])
      ()
  in
  Alcotest.(check (option bool)) "git push succeeds even without write access"
    (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "git push routes through docker" (Some "docker")
    (parse_string_field raw "via");
  let log = if Sys.file_exists log_path then read_file log_path else "" in
  Alcotest.(check bool) "docker container was invoked" true
    (docker_log_has_container_execution log)

let test_execute_git_push_routes_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  setup_ready_repo_with_origin ~config ~repo_name:"masc" ~repo;
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_exec_args ~cwd:repo "git"
           ~argv:[ "push"; "origin"; "feature/proof" ])
      ()
  in
  Alcotest.(check (option bool)) "push succeeds via fake docker" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "push via docker" (Some "docker")
    (parse_string_field raw "via");
  let log = read_file log_path in
  Alcotest.(check bool) "git push started docker session" true
    (contains_substring log "run -d");
  Alcotest.(check bool) "git push used typed docker exec argv" true
    (contains_substring log "\nexec ")

let test_tool_search_files_repo_review_is_unsupported () =
  with_tool_policy_config @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
           [ ("op", `String "gh")
           ; ("cmd", `String "pr review 123 --approve --body ok")
           ; ("cwd", `String playground)
           ])
  in
  (match parse_bool_field raw "ok" with
   | Some true -> Alcotest.failf "repo action unexpectedly succeeded: %s" raw
   | Some false | None -> ());
  Alcotest.(check bool)
    "repo action op fails closed with unsupported-op error"
    true
    (response_mentions raw "error" "does not support op");
  Alcotest.(check (option string))
    "handler preserves requested op, not rewritten to rg"
    (Some "gh")
    (parse_string_field raw "op")

let docker_run_line log_path =
  read_file log_path
  |> String.split_on_char '\n'
  |> List.find_opt (String.starts_with ~prefix:"run ")
  |> function
  | Some line -> line
  | None -> Alcotest.fail "expected docker run log line"

let test_docker_shell_missing_image_fails_before_run () =
  with_fake_docker fake_docker_missing_image_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "missing:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  match
    Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config
      ~meta
      ~cwd:playground
      ~timeout_sec:5.0
      ~cmd:"pwd"
      ~network_mode:Keeper_types_profile_sandbox.Network_none
  with
  | Ok _ -> Alcotest.fail "expected missing image preflight error"
  | Error msg ->
    Alcotest.(check bool) "structured missing image error" true
      (contains_substring msg "image_not_found");
    Alcotest.(check bool) "next action mentions build script" true
      (contains_substring msg "scripts/build-keeper-sandbox-image.sh");
    let log = read_file log_path in
    Alcotest.(check bool) "image inspect attempted" true
      (contains_substring log "image inspect missing:test");
    Alcotest.(check bool) "docker run skipped" false
      (contains_substring log "\nrun ")

let test_docker_shell_ir_parse_failure_blocks_before_run () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  match
    Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config
      ~meta
      ~cwd:playground
      ~timeout_sec:5.0
      ~cmd:"echo \"unterminated"
      ~network_mode:Keeper_types_profile_sandbox.Network_none
  with
  | Ok _ -> Alcotest.fail "expected unsupported shell syntax to block before docker"
  | Error msg ->
    Alcotest.(check bool)
      "parse failure is explicit"
      true
      (contains_substring msg "unsupported shell command shape");
    Alcotest.(check bool)
      "blocked command is attached"
      true
      (contains_substring msg "[blocked_cmd=echo \"unterminated]");
    Alcotest.(check bool)
      "docker preflight not reached"
      false
      (Sys.file_exists log_path)

let test_execute_missing_image_falls_back_to_local_playground () =
  with_fake_docker fake_docker_missing_image_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "missing:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:(tool_execute_typed_pipeline_args ~cwd:playground)
      ()
  in
  check_typed_pipeline_response raw;
  Alcotest.(check (option string)) "requested docker" (Some "docker")
    (parse_string_field raw "requested_sandbox");
  Alcotest.(check (option string)) "fallback local playground"
    (Some "local_playground")
    (parse_string_field raw "sandbox_fallback");
  let log = read_file log_path in
  Alcotest.(check bool) "image inspect attempted" true
    (contains_substring log "image inspect missing:test");
  Alcotest.(check bool) "docker run skipped" false
    (contains_substring log "\nrun ")

let test_execute_outside_playground_rejects_before_image_preflight () =
  with_fake_docker fake_docker_missing_image_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground:_ ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  let cwd = Filename.concat config.Workspace.base_path "outside-playground" in
  ensure_dir cwd;
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "missing:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None
      ~config
      ~meta
      ~args:(tool_execute_typed_pipeline_args ~cwd)
      ()
  in
  Alcotest.(check (option bool)) "legacy ok omitted" None
    (parse_bool_field raw "ok");
  Alcotest.(check bool) "path rejection" true
    (response_mentions raw "error" "path_outside_sandbox");
  Alcotest.(check (option string)) "docker not requested" None
    (parse_string_field raw "requested_sandbox");
  let log = if Sys.file_exists log_path then read_file log_path else "" in
  Alcotest.(check bool) "image inspect skipped" false
    (contains_substring log "image inspect missing:test");
  Alcotest.(check bool) "docker run skipped" false
    (contains_substring log "\nrun ")

let test_docker_shell_mounts_masc_config_runtime_paths () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let masc_root =
    Filename.concat config.Workspace.base_path Common.masc_dirname
  in
  let tasks_host = Filename.concat masc_root "tasks" in
  ensure_dir tasks_host;
  write_file (Filename.concat tasks_host "backlog.json") "{}";
  write_file (Filename.concat masc_root "board_posts.jsonl") "";
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  match
    Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config
      ~meta
      ~cwd:playground
      ~timeout_sec:5.0
      ~cmd:"pwd"
      ~network_mode:Keeper_types_profile_sandbox.Network_none
  with
  | Error msg -> Alcotest.failf "expected fake docker run, got %s" msg
  | Ok result ->
    (match result.Keeper_sandbox_docker.status with
     | Unix.WEXITED 0 -> ()
     | Unix.WEXITED code -> Alcotest.failf "expected exit 0, got %d" code
     | Unix.WSIGNALED code -> Alcotest.failf "expected exit 0, signaled %d" code
     | Unix.WSTOPPED code -> Alcotest.failf "expected exit 0, stopped %d" code);
    let line = docker_run_line log_path in
    let log = read_file log_path in
    let container_root = Keeper_sandbox.container_root meta.name in
    let host_config_dir =
      Filename.concat (Filename.concat config.Workspace.base_path Common.masc_dirname) "config"
    in
    let container_config_dir =
      Masc.Keeper_sandbox_runtime.container_masc_config_dir ~container_root
    in
    Alcotest.(check bool) "MASC config mounted read-only" true
      (contains_substring
         line
         (host_config_dir ^ ":" ^ container_config_dir ^ ":ro"));
    Alcotest.(check bool) "container MASC_BASE_PATH pinned" true
      (contains_substring line "MASC_BASE_PATH=/tmp/masc-runtime");
    Alcotest.(check bool) "container MASC_CONFIG_DIR pinned" true
      (contains_substring line ("MASC_CONFIG_DIR=" ^ container_config_dir));
    Alcotest.(check bool) "oneshot container has ttl label" true
      (contains_substring line "masc.mcp.ttl_sec=");
    Alcotest.(check bool) "oneshot cleanup attempts docker rm" true
      (contains_substring log "\nrm -f masc-keeper-");
    Alcotest.(check bool) "tasks mounted under runtime root" true
      (contains_substring
         line
         (tasks_host ^ ":/tmp/masc-runtime/.masc/tasks:ro"));
    Alcotest.(check bool) "tasks not nested under playground bind mount" false
      (contains_substring
         line
         (tasks_host ^ ":" ^ container_root ^ "/.masc/tasks:ro"));
    Alcotest.(check bool) "tasks not mounted at host absolute target" false
      (contains_substring
         line
         (tasks_host ^ ":" ^ tasks_host ^ ":ro"));
    Alcotest.(check bool) "auth state not mounted" false
      (contains_substring line "/.masc/auth/")

let run_docker_shell_command ~config ~(meta : Keeper_meta_contract.keeper_meta) ~playground
    ~log_path =
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  ensure_dir repo;
  if not (Sys.file_exists (Filename.concat repo ".git")) then
    git_ok ~cwd:repo [ "init"; "-q" ];
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  (match Sys.getenv_opt "MASC_TEST_FAKE_DOCKER_PATH" with
   | Some expected ->
       Alcotest.(check string) "fake docker command selected" expected
         (Masc.Keeper_sandbox_runtime.docker_command ())
   | None -> ());
  match
    Keeper_sandbox_docker.run_docker_shell_command_with_status
      ~config ~meta ~cwd:playground ~timeout_sec:5.0
      ~cmd:"git status"
      ~network_mode:Keeper_types_profile_sandbox.Network_inherit
  with
  | Error msg ->
      Alcotest.failf "expected fake docker shell run, got %s" msg
  | Ok result ->
      let observed =
        match result.Keeper_sandbox_docker.status with
        | Unix.WEXITED code -> ("exit", code)
        | Unix.WSIGNALED code -> ("signaled", code)
        | Unix.WSTOPPED code -> ("stopped", code)
      in
      if observed <> ("exit", 0) then
        Alcotest.failf "expected fake docker exit 0, got %s %d; log=%S; output=%S"
          (fst observed) (snd observed) (read_file log_path)
          result.Keeper_sandbox_docker.output;
      docker_run_line log_path

let test_sandbox_root_git_cwd_zero_repo_allows_exec () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let cwd, error =
    resolve_sandbox_root_git_cwd_string ~config ~meta
      ~cwd:playground ~cmd:"git status"
  in
  Alcotest.(check string) "cwd remains sandbox root" playground cwd;
  Alcotest.(check (option string)) "no artificial repo guidance" None error

let test_sandbox_root_git_explicit_repos_target_keeps_cwd () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let cwd, error =
    resolve_sandbox_root_git_cwd_string ~config ~meta
      ~cwd:playground ~cmd:"git clone https://github.com/example/repo.git repos/repo"
  in
  Alcotest.(check (option string))
    "no error when git command names explicit repos target"
    None
    error;
  Alcotest.(check string) "cwd stays sandbox root" playground cwd

let test_sandbox_root_git_arbitrary_target_allowed () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let assert_allows cmd =
    let cwd, error =
      resolve_sandbox_root_git_cwd_string ~config ~meta ~cwd:playground ~cmd
    in
    Alcotest.(check string) "cwd remains sandbox root" playground cwd;
    Alcotest.(check (option string)) "no artificial guidance" None error
  in
  assert_allows "git clone https://github.com/example/repo.git repos/valid/../../escape";
  assert_allows "git clone https://github.com/example/repo.git repos/valid/../..";
  assert_allows "git clone https://github.com/example/repo.git repos/..";
  assert_allows "git clone https://github.com/example/repo.git repos/../escape";
  assert_allows "git clone https://github.com/example/repo.git repos/valid/subdir";
  assert_allows "git status repos/valid/subdir/../file";
  assert_allows "git log ./repos/valid"

let test_sandbox_root_git_cwd_single_repo_does_not_auto_chdir () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  ensure_dir repo;
  git_ok ~cwd:repo [ "init"; "-q" ];
  let cwd, error =
    resolve_sandbox_root_git_cwd_string ~config ~meta
      ~cwd:playground ~cmd:"git status"
  in
  Alcotest.(check (option string)) "no error" None error;
  Alcotest.(check string) "cwd stays sandbox root" playground cwd

let test_sandbox_root_git_c_container_path_preflight_uses_host_path () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  ensure_dir repo;
  git_ok ~cwd:repo [ "init"; "-q" ];
  let container_repo =
    Filename.concat (Filename.concat (Keeper_sandbox.container_root meta.name) "repos") "masc"
  in
  let cwd, error =
    resolve_sandbox_root_git_cwd_string ~config ~meta
      ~cwd:playground
      ~cmd:(Printf.sprintf "git -C %s status" container_repo)
  in
  Alcotest.(check (option string)) "no error" None error;
  Alcotest.(check string) "explicit -C keeps sandbox-root cwd" playground cwd

let test_sandbox_root_git_c_missing_target_keeps_execution_cwd () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let missing = "repos/masc/.worktrees/missing" in
  let cwd, error =
    resolve_sandbox_root_git_cwd_string ~config ~meta
      ~cwd:playground
      ~cmd:(Printf.sprintf "git -C %s status" missing)
  in
  Alcotest.(check string) "execution cwd remains sandbox root" playground cwd;
  match error with
  | None -> Alcotest.fail "expected missing git -C target error"
  | Some msg ->
    Alcotest.(check bool)
      "error identifies missing git -C target"
      true
      (contains_substring msg "git -C target must be an existing directory")

let test_sandbox_root_git_c_repeated_missing_final_target () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  ensure_dir repo;
  git_ok ~cwd:repo [ "init"; "-q" ];
  let cwd, error =
    resolve_sandbox_root_git_cwd_string
      ~config
      ~meta
      ~cwd:playground
      ~cmd:"git -C repos/masc -C .worktrees/missing status"
  in
  Alcotest.(check string) "execution cwd remains sandbox root" playground cwd;
  match error with
  | None -> Alcotest.fail "expected repeated git -C final target error"
  | Some msg ->
    Alcotest.(check bool)
      "error identifies repeated git -C final target"
      true
      (contains_substring msg "repos/masc/.worktrees/missing")

let test_sandbox_root_git_c_pipeline_missing_later_target () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  ensure_dir repo;
  git_ok ~cwd:repo [ "init"; "-q" ];
  let cwd, error =
    resolve_sandbox_root_git_cwd_string
      ~config
      ~meta
      ~cwd:playground
      ~cmd:"git -C repos/masc status | git -C repos/missing status"
  in
  Alcotest.(check string) "execution cwd remains sandbox root" playground cwd;
  match error with
  | None -> Alcotest.fail "expected later git stage -C target error"
  | Some msg ->
    Alcotest.(check bool)
      "error identifies later git stage missing target"
      true
      (contains_substring msg "repos/missing")

let test_sandbox_root_git_c_bare_worktree_missing_target () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  ensure_dir repo;
  git_ok ~cwd:repo [ "init"; "-q" ];
  let cwd, error =
    resolve_sandbox_root_git_cwd_string
      ~config
      ~meta
      ~cwd:playground
      ~cmd:"git -C .worktrees/missing status"
  in
  Alcotest.(check string) "execution cwd remains sandbox root" playground cwd;
  match error with
  | None -> Alcotest.fail "expected bare worktree git -C target error"
  | Some msg ->
    Alcotest.(check bool)
      "error identifies bare worktree under sole repo"
      true
      (contains_substring msg "repos/masc/.worktrees/missing")

let test_sandbox_root_git_subcommand_c_is_not_cwd () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repo = Filename.concat (Filename.concat playground "repos") "masc" in
  ensure_dir repo;
  git_ok ~cwd:repo [ "init"; "-q" ];
  let cwd, error =
    resolve_sandbox_root_git_cwd_string
      ~config
      ~meta
      ~cwd:playground
      ~cmd:"git commit -C HEAD"
  in
  Alcotest.(check string) "subcommand -C keeps sandbox-root cwd" playground cwd;
  Alcotest.(check (option string)) "subcommand -C is not a cwd preflight" None error

let test_sandbox_root_git_cwd_multi_repo_allows_exec () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repos = Filename.concat playground "repos" in
  let repo_a = Filename.concat repos "alpha" in
  let repo_b = Filename.concat repos "beta" in
  ensure_dir repo_a;
  ensure_dir repo_b;
  git_ok ~cwd:repo_a [ "init"; "-q" ];
  git_ok ~cwd:repo_b [ "init"; "-q" ];
  let cwd, error =
    resolve_sandbox_root_git_cwd_string ~config ~meta
      ~cwd:playground ~cmd:"gh pr list"
  in
  Alcotest.(check string) "cwd remains sandbox root" playground cwd;
  Alcotest.(check (option string)) "no artificial multi-repo guidance" None error

let test_sandbox_root_git_cwd_cd_chain_is_not_interpreted () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let repos = Filename.concat playground "repos" in
  let repo_a = Filename.concat repos "grpc-direct" in
  let repo_b = Filename.concat repos "masc" in
  let worktree = Filename.concat repo_b ".worktrees/keeper-nick0cave-agent-task-236" in
  ensure_dir repo_a;
  ensure_dir worktree;
  git_ok ~cwd:repo_a [ "init"; "-q" ];
  git_ok ~cwd:repo_b [ "init"; "-q" ];
  let cwd, error =
    resolve_sandbox_root_git_cwd_string ~config ~meta
      ~cwd:playground
      ~cmd:"cd repos/masc/.worktrees/keeper-nick0cave-agent-task-236 && git status"
  in
  Alcotest.(check string) "cwd remains sandbox root" playground cwd;
  Alcotest.(check (option string))
    "unsupported logic chain is not interpreted as git cwd policy"
    None
    error

let test_cmd_prefix_uses_shell_command_words () =
  let check label expected cmd =
    Alcotest.(check string)
      label
      expected
      (Keeper_tool_command_words.cmd_prefix cmd)
  in
  check "plain command" "git" "git status";
  check "env wrapper" "env" "env GH_TOKEN=redacted gh pr list";
  check "opam wrapper" "opam" "opam exec -- dune runtest";
  check
    "unsupported shell shape reports leading command"
    "cd"
    "cd repos/masc && git status"

let detect_repo_hosting_cli_repo_api_misuse_of_string cmd =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed ir ->
    Keeper_tool_execute_command_semantics.repo_hosting_cli_repo_flag_api_misuse ir
  | _ -> None

let test_repo_hosting_cli_repo_api_misuse_uses_shell_semantics () =
  let check label expected cmd =
    Alcotest.(check (option (pair string string)))
      label
      expected
      (detect_repo_hosting_cli_repo_api_misuse_of_string cmd)
  in
  check
    "quoted repo arg"
    (Some ("jeong-sik/masc", "repos/jeong-sik/masc/actions/runs"))
    "gh --repo 'jeong-sik/masc' api repos/jeong-sik/masc/actions/runs";
  check
    "repo equals form"
    (Some ("jeong-sik/masc", "repos/jeong-sik/masc/pulls"))
    "gh --repo=jeong-sik/masc api repos/jeong-sik/masc/pulls";
  check
    "env prefix"
    (Some ("jeong-sik/masc", "repos/jeong-sik/masc/issues"))
    "env GH_TOKEN=redacted gh --repo jeong-sik/masc api repos/jeong-sik/masc/issues";
  check
    "subcommand repo flag is fine"
    None
    "gh pr view --repo jeong-sik/masc 17214"

let detect_gh_pr_diff_misuse_of_string cmd =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed ir ->
    Keeper_tool_execute_command_semantics.gh_pr_diff_misuse ir
  | _ -> None

let test_gh_pr_diff_misuse_uses_shell_semantics () =
  let check label expected cmd =
    Alcotest.(check (option (list string)))
      label
      expected
      (detect_gh_pr_diff_misuse_of_string cmd)
  in
  check
    "standard pr diff call with file filter"
    (Some [ "20107"; "--"; "**/*.ml"; "**/*.mli" ])
    "gh pr diff --repo jeong-sik/masc-mcp 20107 -- **/*.ml **/*.mli";
  check
    "pr diff call with multiple positional args without --"
    (Some [ "20107"; "extra_arg" ])
    "gh pr diff 20107 extra_arg";
  check
    "pr diff call with flags only is fine"
    None
    "gh pr diff 20107 --patch --name-only";
  check
    "pr diff call without args is fine"
    None
    "gh pr diff";
  check
    "pr diff call with repo and pr is fine"
    None
    "gh pr diff -R jeong-sik/masc-mcp 20107"


let test_docker_shell_skips_missing_ssh_auth_sock () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  Config_dir_resolver.reset ();
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  let missing_sock =
    Filename.concat config.Workspace.base_path "missing-agent.sock"
  in
  with_env "SSH_AUTH_SOCK" missing_sock @@ fun () ->
  let line =
    run_docker_shell_command ~config ~meta ~playground ~log_path
  in
  Alcotest.(check bool) "missing ssh-agent socket is not mounted" false
    (contains_substring line missing_sock);
  Alcotest.(check bool) "missing ssh-agent env is not forwarded" false
    (contains_substring line "SSH_AUTH_SOCK=")

let test_docker_shell_inherit_network_omits_invalid_network_flag () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  let line =
    run_docker_shell_command ~config ~meta ~playground ~log_path
  in
  Alcotest.(check bool) "network inherit never uses invalid flag value" false
    (contains_substring line "--network inherit")

let test_docker_shell_mounts_numeric_user_identity () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  let line =
    with_env "GH_TOKEN" "host-token" @@ fun () ->
    with_env "GITHUB_TOKEN" "github-token" @@ fun () ->
    run_docker_shell_command ~config ~meta ~playground ~log_path
  in
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

let test_docker_shell_projects_keeper_secret_dir () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let secret_root =
    Filename.concat
      (Filename.concat (Filename.concat config.Workspace.base_path Common.masc_dirname) "secrets")
      (Workspace_utils.safe_filename meta.name)
  in
  let token_path = Filename.concat (Filename.concat secret_root "env") "GH_TOKEN" in
  let ssh_path =
    Filename.concat
      (Filename.concat secret_root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  ensure_dir (Filename.dirname token_path);
  ensure_dir (Filename.dirname ssh_path);
  write_file token_path "projected-token\n";
  write_file ssh_path "PRIVATE KEY";
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  let line = run_docker_shell_command ~config ~meta ~playground ~log_path in
  Alcotest.(check bool) "projected raw token not in docker argv" false
    (contains_substring line "projected-token");
  Alcotest.(check bool) "projected env uses env-file" true
    (contains_substring line "--env-file ");
  Alcotest.(check bool) "projected file mounted read-only" true
    (contains_substring line (ssh_path ^ ":/home/keeper/.ssh/id_ed25519:ro"));
  (match env_file_path_from_docker_line line with
   | None -> Alcotest.fail "missing --env-file path in docker log"
   | Some env_file ->
     Alcotest.(check bool) "env-file cleaned after docker run" false
       (Sys.file_exists env_file))

let test_docker_shell_does_not_synthesize_git_author_identity () =
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  let line =
    run_docker_shell_command ~config ~meta ~playground ~log_path
  in
  Alcotest.(check bool) "does not synthesize git author name" false
    (contains_substring line "GIT_AUTHOR_NAME=");
  Alcotest.(check bool) "does not synthesize git author email" false
    (contains_substring line "GIT_AUTHOR_EMAIL=");
  Alcotest.(check bool) "does not synthesize git committer name" false
    (contains_substring line "GIT_COMMITTER_NAME=");
  Alcotest.(check bool) "does not synthesize git committer email" false
    (contains_substring line "GIT_COMMITTER_EMAIL=")

let test_execute_fake_docker_executes () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:(tool_execute_typed_exec_args ~cwd:playground "echo" ~argv:[ "hello" ])
      ()
  in
  Alcotest.(check (option bool)) "bash via fake docker is ok" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string)) "bash via=docker" (Some "docker")
    (parse_string_field raw "via");
  Alcotest.(check bool) "bash output includes fake docker stdout" true
    (response_mentions raw "output" "stdout:")

let test_turn_runtime_projects_keeper_secret_dir () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let secret_root =
    Filename.concat
      (Filename.concat (Filename.concat config.Workspace.base_path Common.masc_dirname) "secrets")
      (Workspace_utils.safe_filename meta.name)
  in
  let token_path = Filename.concat (Filename.concat secret_root "env") "GH_TOKEN" in
  let ssh_path =
    Filename.concat
      (Filename.concat secret_root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  ensure_dir (Filename.dirname token_path);
  ensure_dir (Filename.dirname ssh_path);
  write_file token_path "projected-token\n";
  write_file ssh_path "PRIVATE KEY";
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None
      ~config
      ~meta
      ~args:(tool_execute_typed_exec_args ~cwd:playground "echo" ~argv:[ "hello" ])
      ()
  in
  Alcotest.(check (option bool)) "bash via fake docker is ok" (Some true)
    (parse_bool_field raw "ok");
  let log = read_file log_path in
  Alcotest.(check bool) "projected raw token not in docker argv" false
    (contains_substring log "projected-token");
  Alcotest.(check bool) "turn container uses env-file" true
    (contains_substring log "--env-file ");
  Alcotest.(check bool) "turn container mounts file read-only" true
    (contains_substring log (ssh_path ^ ":/home/keeper/.ssh/id_ed25519:ro"));
  (match env_file_path_from_docker_line log with
   | None -> Alcotest.fail "missing --env-file path in docker log"
   | Some env_file ->
     Alcotest.(check bool) "env-file cleaned after container start" false
       (Sys.file_exists env_file))

let test_execute_allows_validator_safe_pipe_redirect_in_docker_route () =
  with_tool_policy_config @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_pipeline_args_of ~cwd:playground
           [ "ls", [ "lib/" ]; "head", [ "-20" ] ])
      ()
  in
  Alcotest.(check (option bool)) "safe pipeline is allowed" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string))
    "safe pipeline routes through docker"
    (Some "docker")
    (parse_string_field raw "via");
  Alcotest.(check bool) "bash output includes fake docker stdout" true
    (response_mentions raw "output" "stdout:");
  Alcotest.(check bool) "docker was invoked" true
    (Sys.file_exists log_path)

let test_execute_rg_no_match_remains_successful_in_docker_route () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_bash_rg_no_match_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let lib =
    Filename.concat
      (Filename.concat (Filename.concat playground "repos") "masc")
      "lib"
  in
  ensure_git_repo (Filename.dirname lib);
  ensure_dir lib;
  ignore (Fs_compat.save_file_atomic (Filename.concat lib "sample.ml") "alpha\n");
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_exec_args ~cwd:playground "rg"
           ~argv:[ "missing_one|missing_two"; "repos/masc/lib" ])
      ()
  in
  Alcotest.(check (option bool)) "rg no-match succeeds semantically"
    (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check int) "rg keeps exit=1 status" 1
    (parse_status_exit_code raw);
  Alcotest.(check (option string)) "semantic_status=no_match"
    (Some "no_match")
    (parse_string_field raw "semantic_status");
  Alcotest.(check bool) "docker was invoked" true
    (Sys.file_exists log_path)

let test_execute_blocks_file_redirect_before_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("cmd", `String "echo hello > out.txt");
            ("cwd", `String playground);
          ])
      ()
  in
  (match parse_bool_field raw "ok" with
   | Some true -> Alcotest.failf "legacy cmd unexpectedly succeeded: %s" raw
   | Some false | None -> ());
  Alcotest.(check (option string))
    "typed boundary error"
    (Some "Typed Shell IR input is required. Provide executable/argv or pipeline.")
    (parse_string_field raw "error");
  Alcotest.(check bool) "docker was not invoked" false
    (Sys.file_exists log_path)

let test_execute_repo_checks_routes_through_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_exec_args ~cwd:playground "gh"
           ~argv:[ "pr"; "checks"; "15659"; "--repo"; "jeong-sik/masc" ])
      ()
  in
  Alcotest.(check (option bool)) "typed gh succeeds" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string))
    "typed gh routes through docker"
    (Some "docker")
    (parse_string_field raw "via");
  Alcotest.(check (option string))
    "no legacy shell next-tool bridge"
    None
    (parse_string_field raw "required_next_tool");
  let log = if Sys.file_exists log_path then read_file log_path else "" in
  Alcotest.(check bool) "docker container was invoked" true
    (docker_log_has_container_execution log)

let test_execute_search_pipeline_exposes_structured_recovery_plan () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup_with_tool_access ~sandbox:Keeper_types_profile_sandbox.Docker @@ fun ~config ~meta ~playground ->
  let log_path = Filename.concat config.Workspace.base_path "docker.log" in
  with_env "MASC_KEEPER_TEST_DOCKER_LOG" log_path @@ fun () ->
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_pipeline_args_of ~cwd:playground
           [ "rg", [ "TODO"; "repos" ]; "head", [ "-20" ] ])
      ()
  in
  Alcotest.(check (option bool)) "typed pipeline is allowed" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check (option string))
    "typed pipeline routes through docker"
    (Some "docker")
    (parse_string_field raw "via");
  Alcotest.(check bool) "docker was invoked" true
    (Sys.file_exists log_path)

let test_execute_rewrites_host_path_command_for_docker () =
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_echo_script @@ fun () ->
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let container_root = Keeper_sandbox.container_root meta.name in
  ensure_git_repo (Filename.concat (Filename.concat playground "repos") "masc");
  with_turn_sandbox_factory ~config ~meta @@ fun factory ->
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute ~turn_sandbox_factory:(Some factory) ~exec_cache:None ~config ~meta
      ~args:
        (tool_execute_typed_exec_args ~cwd:playground "ls"
           ~argv:
             [
               Printf.sprintf "%s/repos/masc"
                 (Keeper_alerting_path.strip_trailing_slashes playground);
             ])
      ()
  in
  Alcotest.(check (option bool)) "bash via fake docker is ok" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check bool) "command uses container path" true
    (response_mentions raw "output"
       (Filename.concat container_root "repos/masc"));
  Alcotest.(check bool) "command no longer leaks host playground path" false
    (response_mentions raw "output" playground)

let test_docker_mount_failure_message_preserves_path () =
  let mount_path =
    "/host_mnt/Users/dancer/me/.masc/playground/docker/repos/masc/.worktrees/"
    ^ String.make 320 'a'
    ^ "/repo"
  in
  let output =
    "docker: Error response from daemon: failed to create task for container: "
    ^ "failed to create shim task: OCI runtime create failed: "
    ^ "runc create failed: unable to start container process: "
    ^ "error during container init: error mounting \""
    ^ mount_path
    ^ "\" to rootfs at \"/workspace\": stat "
    ^ mount_path
    ^ ": no such file or directory"
  in
  let message =
    Keeper_sandbox_exec_failure.docker_failure_message
      ~image:"masc-keeper-sandbox:local"
      ~status:(Unix.WEXITED 125)
      ~output
  in
  Alcotest.(check bool) "full mount path preserved" true
    (contains_substring message mount_path);
  Alcotest.(check bool) "mount marker emitted" true
    (contains_substring message "docker_mount_failure=true");
  Alcotest.(check bool) "status emitted" true
    (contains_substring message "status=\"exit=125\"")

let test_docker_mount_failure_structured_details () =
  let mount_path =
    "/host_mnt/Users/dancer/me/.masc/playground/docker/repos/oas/.worktrees/"
    ^ String.make 280 'b'
  in
  let output =
    "OCI runtime create failed: runc create failed: error during container init: "
    ^ "error mounting \""
    ^ mount_path
    ^ "\" to rootfs"
  in
  match
    Keeper_sandbox_runtime.docker_mount_failure_details
      ~base_path_hash:"hash456"
      ~keeper_name:"ramarama"
      ~image:"masc-keeper-sandbox:local"
      ~status_label:"exit=125"
      ~container_kind:"turn"
      ~network_label:"none"
      ~output
      ()
  with
  | None -> Alcotest.fail "expected structured docker mount failure details"
  | Some json ->
    let field name = Json.member name json |> Json.to_string in
    Alcotest.(check string) "event" "keeper_docker_mount_failure" (field "event");
    Alcotest.(check string) "mount_path" mount_path (field "mount_path");
    Alcotest.(check string) "base_path_hash" "hash456" (field "base_path_hash");
    Alcotest.(check string) "keeper" "ramarama" (field "keeper");
    Alcotest.(check string) "container_kind" "turn" (field "container_kind");
    Alcotest.(check string) "network" "none" (field "network")

let test_docker_mount_failure_path_is_bounded () =
  let mount_path = "/host_mnt/" ^ String.make 5000 'x' in
  let output =
    "OCI runtime create failed: error during container init: error mounting \""
    ^ mount_path
    ^ "\""
  in
  match Keeper_sandbox_runtime.docker_mount_failure_path output with
  | None -> Alcotest.fail "expected bounded mount path"
  | Some path ->
    Alcotest.(check int) "bounded mount path length" 4096 (String.length path);
    Alcotest.(check bool) "bounded path remains prefix" true
      (String.starts_with ~prefix:path mount_path)

let test_docker_mount_failure_requires_path () =
  let output =
    "OCI runtime create failed: error during container init: error mounting without quoted path"
  in
  Alcotest.(check (option string)) "missing path is not a mount diagnostic" None
    (Keeper_sandbox_runtime.docker_mount_failure_path output);
  Alcotest.(check string) "missing path has no mount context" ""
    (Keeper_sandbox_runtime.docker_mount_failure_context_suffix output)

let test_docker_mount_failure_requires_daemon_origin () =
  let app_output = {|application stderr: error mounting "./fixtures" failed|} in
  Alcotest.(check (option string)) "app output is not a mount diagnostic" None
    (Keeper_sandbox_runtime.docker_mount_failure_path app_output);
  Alcotest.(check string) "app output has no mount context" ""
    (Keeper_sandbox_runtime.docker_mount_failure_context_suffix app_output);
  let marker_output = {|mount_path="/tmp/user-output"|} in
  Alcotest.(check (option string)) "marker-only output is not daemon-originated" None
    (Keeper_sandbox_runtime.docker_mount_failure_path marker_output)
  ;
  let app_oci_output =
    {|application stderr: OCI runtime create failed: error mounting "./fixtures"|}
  in
  Alcotest.(check (option string)) "runtime-like app output lacks init origin" None
    (Keeper_sandbox_runtime.docker_mount_failure_path app_oci_output)

let () =
  Alcotest.run "Keeper_sandbox_docker_route"
    [
      ( "docker_route_fires",
        [
          Alcotest.test_case
            "docker tool execute ops route through docker"
            `Quick test_readonly_ops_route_through_docker;
          Alcotest.test_case
            "docker Execute routes through docker"
            `Quick test_execute_routes_through_docker;
          Alcotest.test_case
            "docker Execute git cmd routes through docker"
            `Quick test_execute_git_routes_through_docker;
          Alcotest.test_case
            "docker Execute git uses turn runtime"
            `Quick test_execute_git_uses_turn_runtime;
          Alcotest.test_case
            "docker Execute git works without credential bundle"
            `Quick test_execute_git_without_github_bundle_succeeds;
          Alcotest.test_case
            "docker keeper git -C missing dir blocks before docker"
            `Quick test_execute_git_c_option_missing_dir_blocks_before_docker;
          Alcotest.test_case
            "docker keeper typed git -C bare worktree blocks"
            `Quick test_execute_git_c_bare_worktrees_from_root_blocks_typed_argv;
          Alcotest.test_case
            "readonly keeper git status works without write tool_access"
            `Quick test_execute_git_status_readonly_without_write_tool_access;
          Alcotest.test_case
            "docker keeper git push without write tool_access"
            `Quick test_execute_git_push_without_write_tool_access_routes_docker;
          Alcotest.test_case
            "docker keeper git push routes through docker"
            `Quick test_execute_git_push_routes_through_docker;
          Alcotest.test_case
            "tool_search_files repo review is unsupported"
            `Quick test_tool_search_files_repo_review_is_unsupported;
          Alcotest.test_case
            "docker Execute executes through fake docker"
            `Quick test_execute_fake_docker_executes;
          Alcotest.test_case
            "docker Execute safe pipe redirect routes through docker"
            `Quick test_execute_allows_validator_safe_pipe_redirect_in_docker_route;
          Alcotest.test_case
            "docker Execute rg no-match remains successful"
            `Quick test_execute_rg_no_match_remains_successful_in_docker_route;
          Alcotest.test_case
            "docker Execute blocks file redirects before docker"
            `Quick test_execute_blocks_file_redirect_before_docker;
          Alcotest.test_case
            "docker Execute routes repo checks through docker"
            `Quick test_execute_repo_checks_routes_through_docker;
          Alcotest.test_case
            "docker Execute shape block exposes structured recovery plan"
            `Quick test_execute_search_pipeline_exposes_structured_recovery_plan;
          Alcotest.test_case
            "docker Execute rewrites host paths before exec"
            `Quick test_execute_rewrites_host_path_command_for_docker;
          Alcotest.test_case
            "docker mount failure preserves full path"
            `Quick test_docker_mount_failure_message_preserves_path;
          Alcotest.test_case
            "docker mount failure emits structured details"
            `Quick test_docker_mount_failure_structured_details;
          Alcotest.test_case
            "docker mount failure path is bounded"
            `Quick test_docker_mount_failure_path_is_bounded;
          Alcotest.test_case
            "docker mount failure requires extracted path"
            `Quick test_docker_mount_failure_requires_path;
          Alcotest.test_case
            "docker mount failure requires daemon origin"
            `Quick test_docker_mount_failure_requires_daemon_origin;
        ] );
      ( "docker_route_skipped",
        [
          Alcotest.test_case "legacy keeper skips docker route" `Quick
            test_cat_legacy_keeper_skips_docker;
          Alcotest.test_case "legacy Execute skips docker route" `Quick
            test_execute_legacy_skips_docker;
        ] );
      ( "docker_route_contract",
        [
          Alcotest.test_case "rg no-match remains successful" `Quick
            test_rg_no_match_remains_successful_in_docker_route;
          Alcotest.test_case "unknown workspace op is unsupported before docker" `Quick
            test_unknown_workspace_op_is_unsupported_before_docker;
          Alcotest.test_case
            "turn sandbox file writes use bind-mounted host path"
            `Quick test_turn_sandbox_file_write_uses_host_bind_mount;
          Alcotest.test_case
            "turn sandbox factory uses refreshed registry meta"
            `Quick test_turn_sandbox_factory_uses_refreshed_registry_meta;
          Alcotest.test_case
            "tool_execute typed pipeline uses local shell ir dispatch"
            `Quick test_execute_typed_pipeline_uses_local_shell_ir_dispatch;
          Alcotest.test_case
            "tool_execute typed env wrapper target executes"
            `Quick test_execute_typed_env_wrapper_target_allowed;
          Alcotest.test_case
            "tool_execute typed single-stage pipeline is rejected"
            `Quick test_execute_typed_single_stage_pipeline_rejected;
          Alcotest.test_case
            "tool_execute typed repeated executable is autocorrected"
            `Quick test_execute_typed_repeated_executable_is_autocorrected;
          Alcotest.test_case
            "tool_execute typed pipeline falls back to local playground"
            `Quick test_execute_typed_pipeline_falls_back_to_local_playground;
          Alcotest.test_case
            "tool_execute typed pipeline uses turn sandbox docker runner"
            `Quick test_execute_typed_pipeline_uses_turn_sandbox_docker_runner;
          Alcotest.test_case
            "docker shell skips missing SSH_AUTH_SOCK"
            `Quick test_docker_shell_skips_missing_ssh_auth_sock;
          Alcotest.test_case
            "docker shell inherit network omits invalid docker flag"
            `Quick test_docker_shell_inherit_network_omits_invalid_network_flag;
          Alcotest.test_case
            "docker shell mounts MASC config runtime paths"
            `Quick test_docker_shell_mounts_masc_config_runtime_paths;
          Alcotest.test_case "docker shell missing image fails before run" `Quick
            test_docker_shell_missing_image_fails_before_run;
          Alcotest.test_case
            "docker shell parse failure blocks before run"
            `Quick
            test_docker_shell_ir_parse_failure_blocks_before_run;
          Alcotest.test_case "tool_execute missing image falls back locally" `Quick
            test_execute_missing_image_falls_back_to_local_playground;
          Alcotest.test_case
            "tool_execute outside playground rejects before image preflight"
            `Quick
            test_execute_outside_playground_rejects_before_image_preflight;
          Alcotest.test_case
            "missing playground bind source blocks before docker"
            `Quick test_execute_missing_playground_blocks_before_docker;
          Alcotest.test_case
            "docker shell mounts passwd entry for numeric uid"
            `Quick test_docker_shell_mounts_numeric_user_identity;
          Alcotest.test_case
            "docker shell projects keeper secret directory"
            `Quick test_docker_shell_projects_keeper_secret_dir;
          Alcotest.test_case
            "docker shell does not synthesize git author identity"
            `Quick test_docker_shell_does_not_synthesize_git_author_identity;
          Alcotest.test_case
            "turn runtime projects keeper secret directory"
            `Quick test_turn_runtime_projects_keeper_secret_dir;
          Alcotest.test_case
            "sandbox-root git with no repo allows docker exec"
            `Quick test_sandbox_root_git_cwd_zero_repo_allows_exec;
          Alcotest.test_case
            "sandbox-root git with explicit repos target keeps cwd"
            `Quick test_sandbox_root_git_explicit_repos_target_keeps_cwd;
          Alcotest.test_case
            "sandbox-root git arbitrary target is allowed"
            `Quick test_sandbox_root_git_arbitrary_target_allowed;
          Alcotest.test_case
            "sandbox-root git with one repo does not auto-select cwd"
            `Quick test_sandbox_root_git_cwd_single_repo_does_not_auto_chdir;
          Alcotest.test_case
            "sandbox-root git -C container path checks host path"
            `Quick
            test_sandbox_root_git_c_container_path_preflight_uses_host_path;
          Alcotest.test_case
            "sandbox-root git -C missing target keeps execution cwd"
            `Quick
            test_sandbox_root_git_c_missing_target_keeps_execution_cwd;
          Alcotest.test_case
            "sandbox-root repeated git -C validates final target"
            `Quick
            test_sandbox_root_git_c_repeated_missing_final_target;
          Alcotest.test_case
            "sandbox-root git pipeline validates every -C target"
            `Quick
            test_sandbox_root_git_c_pipeline_missing_later_target;
          Alcotest.test_case
            "sandbox-root bare worktree git -C validates target"
            `Quick
            test_sandbox_root_git_c_bare_worktree_missing_target;
          Alcotest.test_case
            "sandbox-root git subcommand -C is not cwd"
            `Quick
            test_sandbox_root_git_subcommand_c_is_not_cwd;
          Alcotest.test_case
            "sandbox-root git with multiple repos allows docker exec"
            `Quick test_sandbox_root_git_cwd_multi_repo_allows_exec;
          Alcotest.test_case
            "sandbox-root git cd-chain is not interpreted by cwd policy"
            `Quick
            test_sandbox_root_git_cwd_cd_chain_is_not_interpreted;
          Alcotest.test_case
            "GitHub CLI --repo api misuse uses shell semantics"
            `Quick
            test_repo_hosting_cli_repo_api_misuse_uses_shell_semantics;
          Alcotest.test_case
            "GitHub CLI pr diff misuse uses shell semantics"
            `Quick
            test_gh_pr_diff_misuse_uses_shell_semantics;
          Alcotest.test_case
            "history cmd_prefix uses shell command words"
            `Quick
            test_cmd_prefix_uses_shell_command_words;
          Alcotest.test_case
            "docker run retries once on daemon timeout/back-pressure"
            `Quick
            test_docker_run_retries_on_daemon_timeout;
        ] );
    ]
