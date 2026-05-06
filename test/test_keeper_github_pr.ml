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

let run_ok ~cwd cmd =
  let wrapped =
    Printf.sprintf "cd %s && %s > /dev/null 2>&1" (Filename.quote cwd) cmd
  in
  let code = Sys.command wrapped in
  if code <> 0 then Alcotest.failf "command failed (%d): %s" code cmd

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

let with_fake_gh f =
  let dir = temp_dir () in
  let gh_path = Filename.concat dir "gh" in
  write_file gh_path fake_gh_echo_script;
  Unix.chmod gh_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "PATH" path f

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
  with_env "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "false" f

let setup_docker_pr_tool f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  ensure_dir (Filename.concat base Common.masc_dirname);
  run_ok ~cwd:base "git init -q";
  run_ok ~cwd:base
    "git remote add origin https://github.com/jeong-sik/masc-mcp.git";
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
  run_ok ~cwd:repo "git init -q";
  ensure_github_identity_bundle ~config
    Masc_mcp.Keeper_gh_env.root_github_identity;
  f ~config ~meta

let parse_string_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_string_option

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

let test_pr_create_argv_is_draft_only () =
  check (list string) "argv"
    [
      "gh";
      "pr";
      "create";
      "-R";
      "owner/repo";
      "--draft";
      "--title";
      "Title";
      "--body";
      "Body";
      "--base";
      "main";
      "--head";
      "feature";
    ]
    (K.For_testing.build_pr_create_argv ~repo:"owner/repo" ~title:"Title"
       ~body:"Body" ~base:(Some "main") ~head:(Some "feature"))

let test_draft_request_rejects_ready_prs () =
  check bool "omitted draft accepted" true
    (K.For_testing.draft_request_allowed (`Assoc []));
  check bool "draft true accepted" true
    (K.For_testing.draft_request_allowed
       (`Assoc [ ("draft", `Bool true) ]));
  check bool "draft false rejected" false
    (K.For_testing.draft_request_allowed
       (`Assoc [ ("draft", `Bool false) ]));
  check bool "ready true rejected" false
    (K.For_testing.draft_request_allowed
       (`Assoc [ ("ready", `Bool true) ]))

let test_pr_create_routes_through_docker () =
  with_fake_gh @@ fun () ->
  with_fake_docker @@ fun () ->
  setup_docker_pr_tool @@ fun ~config ~meta ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  let raw =
    K.handle_keeper_pr_create ~config ~meta
      ~args:
        (`Assoc
          [
            ("repo", `String "jeong-sik/masc-mcp");
            ("title", `String "docker draft PR");
            ("body", `String "docker draft PR body");
            ("base", `String "main");
            ("head", `String "feature/docker-pr");
            ("cwd", `String "repos/masc-mcp");
          ])
  in
  (match parse_string_field raw "via" with
   | Some via -> check string "pr create via docker" "docker" via
   | None -> Alcotest.failf "missing via in response: %s" raw);
  let log = read_file log_path in
  check bool "used docker run" true (contains_substring log "run --rm");
  check bool "uses gh pr create" true
    (contains_substring raw "gh"
    && contains_substring raw "pr"
    && contains_substring raw "create");
  check bool "keeps draft flag" true (contains_substring raw "--draft");
  check bool "passes repo flag" true
    (contains_substring raw "-R"
    && contains_substring raw "jeong-sik/masc-mcp");
  check bool "passes branch head" true
    (contains_substring raw "--head"
    && contains_substring raw "feature/docker-pr")

let test_pr_create_hard_mode_routes_through_broker () =
  with_fake_gh @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_HARD_MODE" "true" @@ fun () ->
  setup_docker_pr_tool @@ fun ~config ~meta ->
  let raw =
    K.handle_keeper_pr_create ~config ~meta
      ~args:
        (`Assoc
          [
            ("repo", `String "jeong-sik/masc-mcp");
            ("title", `String "brokered draft PR");
            ("body", `String "brokered draft PR body");
            ("base", `String "main");
            ("head", `String "feature/brokered-pr");
            ("cwd", `String "repos/masc-mcp");
          ])
  in
  check (option string) "pr create via broker" (Some "brokered")
    (parse_string_field raw "via");
  check bool "uses host gh pr create" true
    (contains_substring raw "gh:pr pr create"
    || contains_substring raw "gh:pr create");
  check bool "keeps draft flag" true (contains_substring raw "--draft")

(* Regression: any preset that grants the [github] group in
   config/tool_policy.toml must satisfy [mutation_preset_ok]. Without
   this, [keeper_pr_create] is visible in the keeper tool surface but
   fails at dispatch with [preset_insufficient] — a contract drift
   between the policy config and the runtime gate that previously
   surfaced as opaque tool failures (e.g. analyst keeper Docker PR
   lifecycle proofs returning [preset_insufficient] after the policy
   config explicitly granted Research the github group via "Step 9
   bloodflow restoration plan"). *)
let test_mutation_preset_matches_visible_surface () =
  let module KT = Keeper_types in
  let allowed = [ KT.Research; KT.Coding; KT.Delivery; KT.Full ] in
  let denied = [ KT.Minimal; KT.Social; KT.Messaging; KT.Dispatch ] in
  List.iter
    (fun preset ->
      check bool
        (Printf.sprintf "preset %s permits keeper_pr_create"
           (KT.tool_preset_to_string preset))
        true
        (K.For_testing.mutation_preset_ok (Some preset)))
    allowed;
  List.iter
    (fun preset ->
      check bool
        (Printf.sprintf "preset %s denies keeper_pr_create"
           (KT.tool_preset_to_string preset))
        false
        (K.For_testing.mutation_preset_ok (Some preset)))
    denied;
  check bool "no preset denies keeper_pr_create" false
    (K.For_testing.mutation_preset_ok None)

let () =
  run "keeper_github_pr"
    [
      ( "argv",
        [
          test_case "pr list argv" `Quick
            test_pr_list_argv_uses_repo_state_limit_json;
          test_case "pr status argv" `Quick
            test_pr_status_argv_accepts_number;
          test_case "pr create argv is draft" `Quick
            test_pr_create_argv_is_draft_only;
          test_case "draft request guard" `Quick
            test_draft_request_rejects_ready_prs;
        ] );
      ( "docker_route",
        [
          test_case "pr create routes through docker" `Quick
            test_pr_create_routes_through_docker;
          test_case "pr create hard mode routes through broker" `Quick
            test_pr_create_hard_mode_routes_through_broker;
        ] );
      ( "preset_gate",
        [
          test_case "mutation preset matches policy surface" `Quick
            test_mutation_preset_matches_visible_surface;
        ] );
    ]
