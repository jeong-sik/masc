open Alcotest

module K = Masc_mcp.Keeper_tool_github_pr
module Coord = Masc_mcp.Coord
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_types = Masc_mcp.Keeper_types
module Json = Yojson.Safe.Util

external unsetenv : string -> unit = "masc_test_unsetenv"

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> unsetenv key)
    f

let temp_dir () =
  let dir = Filename.temp_file "keeper_github_pr_" "" in
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

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let write_file path content =
  ensure_dir (Filename.dirname path);
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

let run_process_ok ~cwd prog argv =
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o600 in
  let original_cwd = Sys.getcwd () in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir original_cwd;
        Unix.close dev_null)
      (fun () ->
        Sys.chdir cwd;
        Unix.create_process prog argv Unix.stdin dev_null dev_null)
  in
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
  if code <> 0 then Alcotest.failf "command failed (%d): %s" code prog

let git_ok ~cwd args =
  run_process_ok ~cwd "git" (Array.of_list ("git" :: args))

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let make_meta ?(preset = Keeper_types.Coding) ~name ~sandbox () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "github pr docker route test");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
        ( "tool_access",
          Keeper_types.tool_access_to_json
            (Keeper_types.Preset { preset; also_allow = [] }) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

let ensure_github_identity_bundle ~config github_identity =
  let masc_dir = Filename.concat config.Coord.base_path Common.masc_dirname in
  let gh_dir =
    Filename.concat
      (Filename.concat
         (Filename.concat masc_dir "github-identities")
         github_identity)
      "gh"
  in
  ensure_dir gh_dir;
  write_file
    (Filename.concat gh_dir "hosts.yml")
    "github.com:\n\
    \    oauth_token: ghp_fake_test_token_for_pr_route\n\
    \    user: test-user\n"

let fake_docker_echo_script =
  "#!/bin/sh\n\
   log_file=${KEEPER_DOCKER_LOG:-}\n\
   if [ -n \"$log_file\" ]; then\n\
   \  printf '%s\\n' \"$*\" >> \"$log_file\"\n\
   fi\n\
	   if [ \"$1\" = \"info\" ]; then\n\
	   \  printf '[]\\n'\n\
	   \  exit 0\n\
	   fi\n\
	   if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"alpine:test\" ]; then\n\
	   \  printf '[]\\n'\n\
	   \  exit 0\n\
	   fi\n\
	   if [ \"$1\" != \"run\" ]; then\n\
	   \  printf 'unexpected docker invocation: %s\\n' \"$1\" >&2\n\
   \  exit 2\n\
   fi\n\
   shift\n\
   while [ \"$#\" -gt 0 ]; do\n\
   \  if [ \"$1\" = \"alpine:test\" ]; then\n\
   \    shift\n\
   \    break\n\
   \  fi\n\
   \  shift\n\
   done\n\
   printf 'stdout:%s\\n' \"$*\"\n\
   exit 0\n"

let fake_gh_echo_script =
  "#!/bin/sh\n\
   printf 'gh:%s\\n' \"$*\"\n\
   exit 0\n"

let fake_gh_pr_create_504_then_view_script =
  "#!/bin/sh\n\
   if [ \"$1\" = \"auth\" ] && [ \"$2\" = \"status\" ]; then\n\
   \  printf 'github.com\\n'\n\
   \  exit 0\n\
   fi\n\
   if [ \"$1\" = \"api\" ] && [ \"$2\" = \"graphql\" ]; then\n\
   \  printf 'test-user\\n'\n\
   \  exit 0\n\
   fi\n\
   if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"create\" ]; then\n\
   \  printf 'pull request create failed: HTTP 504: 504 Gateway Timeout (https://api.github.com/graphql)\\n' >&2\n\
   \  exit 1\n\
   fi\n\
   if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"view\" ]; then\n\
   \  printf '{\"number\":13799,\"url\":\"https://github.com/jeong-sik/masc-mcp/pull/13799\",\"headRefName\":\"feature/recovered\",\"state\":\"OPEN\",\"isDraft\":true}\\n'\n\
   \  exit 0\n\
   fi\n\
   printf 'unexpected gh invocation: %s\\n' \"$*\" >&2\n\
   exit 2\n"

let with_fake_gh_script script f =
  let dir = temp_dir () in
  let gh_path = Filename.concat dir "gh" in
  write_file gh_path script;
  Unix.chmod gh_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "PATH" path f

let with_fake_gh f = with_fake_gh_script fake_gh_echo_script f

let with_fake_docker f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  write_file docker_path fake_docker_echo_script;
  Unix.chmod docker_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "MASC_TEST_FAKE_DOCKER_PATH" docker_path @@ fun () ->
  with_env "PATH" path @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" f

let setup_docker_pr_tool f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  ensure_dir (Filename.concat base Common.masc_dirname);
  git_ok ~cwd:base [ "init"; "-q" ];
  git_ok ~cwd:base
    [ "remote"; "add"; "origin"; "https://github.com/jeong-sik/masc-mcp.git" ];
  let config = Coord.default_config base in
  let meta = make_meta ~name:"pr-maker" ~sandbox:Keeper_types.Docker () in
  let repo =
    Filename.concat
      (Filename.concat
         (Keeper_sandbox.host_root_abs_of_meta ~config meta)
         "repos")
      "masc-mcp"
  in
  ensure_dir repo;
  git_ok ~cwd:repo [ "init"; "-q" ];
  ensure_github_identity_bundle ~config
    Masc_mcp.Keeper_gh_env.root_github_identity;
  f ~config ~meta

let parse_string_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_string_option

let parse_bool_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_bool_option

let parse_nested_string_field raw outer field =
  Yojson.Safe.from_string raw
  |> Json.member outer
  |> Json.member field
  |> Json.to_string_option

let test_pr_list_argv_uses_repo_state_limit_json () =
  check (list string) "argv"
    [
      "gh";
      "pr";
      "list";
      "-R";
      "owner/repo";
      "--state";
      "open";
      "--limit";
      "20";
      "--json";
      "number,title,state,isDraft,headRefName,baseRefName,mergeable,reviewDecision,url,updatedAt";
    ]
    (K.For_testing.build_pr_list_argv ~repo:"owner/repo" ~state:"open" ~limit:20)

let test_effective_repo_arg_expands_current_project_name () =
  setup_docker_pr_tool @@ fun ~config ~meta:_ ->
  match K.For_testing.effective_repo_arg ~config "masc-mcp" with
  | Ok repo -> check string "expanded repo" "jeong-sik/masc-mcp" repo
  | Error reason -> Alcotest.fail reason

let test_effective_repo_arg_rejects_ambiguous_bare_repo () =
  setup_docker_pr_tool @@ fun ~config ~meta:_ ->
  match K.For_testing.effective_repo_arg ~config "not-this-repo" with
  | Ok repo -> Alcotest.failf "unexpected repo: %s" repo
  | Error reason ->
      check bool "mentions current project slug" true
        (contains_substring reason "jeong-sik/masc-mcp")

let test_pr_status_argv_accepts_number () =
  let argv =
    K.For_testing.build_pr_status_argv ~repo:"owner/repo" ~pr_number:42
  in
  check bool "uses gh pr view" true
    (List.exists (String.equal "view") argv);
  check bool "contains number" true
    (List.exists (String.equal "42") argv);
  check bool "contains json fields" true
    (List.exists
       (fun s -> String.starts_with ~prefix:"number,title,state" s)
       argv)

let () =
  run "keeper_github_pr"
    [
      ( "argv",
        [
          test_case "pr list argv" `Quick
            test_pr_list_argv_uses_repo_state_limit_json;
          test_case "bare repo expands to current project slug" `Quick
            test_effective_repo_arg_expands_current_project_name;
          test_case "ambiguous bare repo rejects before gh" `Quick
            test_effective_repo_arg_rejects_ambiguous_bare_repo;
          test_case "pr status argv" `Quick
            test_pr_status_argv_accepts_number;
        ] );
    ]
