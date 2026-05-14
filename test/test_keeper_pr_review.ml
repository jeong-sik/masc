(** Unit tests for [Keeper_tool_pr_review] error-shape helpers.

    Focused on the [pr_not_found] detection that turns an opaque
    [HTTP 404] string into a structured error keepers can act on
    without retry loops.  Background:
    [memory/feedback_tool-error-messages-teach-llm.md]. *)

open Alcotest

module KTPR = Masc_mcp.Keeper_tool_pr_review
module Coord = Masc_mcp.Coord
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_types = Masc_mcp.Keeper_types
module Json = Yojson.Safe.Util

(* [Unix.unsetenv] is not portably available in OCaml's stdlib Unix module,
   so the repo convention is to clear via [Unix.putenv key ""]. See e.g.
   [test/test_board_vote_quarantine.ml] and [test/test_provider_kind_resolution.ml]. *)
let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_dir () =
  let dir = Filename.temp_file "keeper_pr_review_" "" in
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
  if code <> 0 then
    Alcotest.failf "command failed (%d): %s" code cmd

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
        ("goal", `String "pr review docker route test");
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
    \    oauth_token: ghp_fake_test_token_for_docker_route\n\
    \    user: test-user\n"

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
case \"$*\" in\n\
  *\"--json isDraft,headRefName,labels\"*)\n\
    if [ -n \"$KEEPER_FAKE_PR_VIEW_JSON\" ]; then\n\
      printf '%s\\n' \"$KEEPER_FAKE_PR_VIEW_JSON\"\n\
    else\n\
      printf '%s\\n' '{\"isDraft\":true,\"headRefName\":\"keeper/docker-approve-proof\",\"labels\":[{\"name\":\"agent-pr\"}]}'\n\
    fi\n\
    exit 0\n\
    ;;\n\
esac\n\
printf 'stdout:%s\\n' \"$*\"\n\
exit 0\n"

let with_fake_docker f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  let gh_path = Filename.concat dir "gh" in
  write_file docker_path fake_docker_echo_script;
  Unix.chmod docker_path 0o755;
  write_file gh_path
    "#!/bin/sh\n\
if [ \"$1\" = \"auth\" ] && [ \"$2\" = \"status\" ]; then\n\
  exit 0\n\
fi\n\
printf 'fake gh: %s\\n' \"$*\"\n\
exit 0\n";
  Unix.chmod gh_path 0o755;
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

let setup_docker_review f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  ensure_dir (Filename.concat base Common.masc_dirname);
  run_ok ~cwd:base "git init -q";
  run_ok ~cwd:base
    "git remote add origin https://github.com/jeong-sik/masc-mcp.git";
  let config = Coord.default_config base in
  let meta =
    make_meta ~name:"reviewer" ~sandbox:Keeper_types.Docker ()
  in
  ensure_dir (Keeper_sandbox.host_root_abs_of_meta ~config meta);
  ensure_github_identity_bundle ~config
    Masc_mcp.Keeper_gh_env.root_github_identity;
  f ~config ~meta

let parse_field raw field =
  Yojson.Safe.from_string raw |> Json.member field

let parse_string_field raw field =
  parse_field raw field |> Json.to_string_option

let parse_bool_field raw field =
  parse_field raw field |> Json.to_bool_option

let parse_nested_bool_field raw outer field =
  Yojson.Safe.from_string raw
  |> Json.member outer
  |> Json.member field
  |> Json.to_bool_option

let parse_nested_string_field raw outer field =
  Yojson.Safe.from_string raw
  |> Json.member outer
  |> Json.member field
  |> Json.to_string_option

(* OCaml stdlib's Unix module has no portable unsetenv, so the [with_env]
   helper clears via [Unix.putenv NAME ""]. This test verifies the helper's
   actual contract: the value is restored to empty after the scope (not to
   the literal "unset" state). See repo convention notes in
   test_board_vote_quarantine.ml and test_env_config_sandbox.ml. *)
let test_with_env_restores_cleared_variable () =
  let key = "MASC_KEEPER_PR_REVIEW_WITH_ENV_UNSET_TEST" in
  Unix.putenv key "";
  with_env key "temporary" (fun () ->
    check (option string) "env set inside scope" (Some "temporary")
      (Sys.getenv_opt key));
  check (option string) "env cleared after scope" (Some "")
    (Sys.getenv_opt key)

let test_research_preset_can_mutate_pr_reviews () =
  check bool "research can comment/approve through review tool" true
    (KTPR.pr_review_mutation_preset_ok
       (Some Masc_mcp.Keeper_types.Research))

let test_social_preset_cannot_mutate_pr_reviews () =
  check bool "social cannot mutate PR reviews" false
    (KTPR.pr_review_mutation_preset_ok
       (Some Masc_mcp.Keeper_types.Social))

let test_detects_rest_404 () =
  let sample =
    "failed to run git: HTTP 404: Not Found \
     (https://api.github.com/repos/jeong-sik/masc-mcp/pulls/8116)" in
  check bool "REST 404 detected" true
    (KTPR.pr_not_found_in_output sample)

let test_detects_graphql_could_not_resolve () =
  let sample =
    "GraphQL: Could not resolve to a PullRequest with the number of 9999." in
  check bool "GraphQL resolution failure detected" true
    (KTPR.pr_not_found_in_output sample)

let test_detects_no_pull_requests_found () =
  check bool "gh pr list empty wording detected" true
    (KTPR.pr_not_found_in_output "no pull requests found in this repo")

let test_passes_through_unrelated_errors () =
  check bool "rate limit not flagged" false
    (KTPR.pr_not_found_in_output
       "API rate limit exceeded for user (60 / 5000)");
  check bool "auth error not flagged" false
    (KTPR.pr_not_found_in_output
       "HTTP 401: Unauthorized");
  check bool "empty output not flagged" false
    (KTPR.pr_not_found_in_output "")

let test_read_routes_docker_and_injects_repo_flag () =
  with_fake_docker @@ fun () ->
  setup_docker_review @@ fun ~config ~meta ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  let raw =
    KTPR.handle_keeper_pr_review_read ~config ~meta
      ~args:(`Assoc [ ("pr_number", `Int 13510) ])
  in
  check (option string) "read via docker" (Some "docker")
    (parse_string_field raw "via");
  check (option string) "read route_via docker" (Some "docker")
    (parse_string_field raw "route_via");
  check (option string) "repo inferred from project remote"
    (Some "jeong-sik/masc-mcp")
    (parse_string_field raw "repo");
  check (option string) "read attests keeper"
    (Some "reviewer")
    (parse_nested_string_field raw "identity_attestation" "keeper");
  check (option string) "read attests effective identity"
    (Some "root")
    (parse_nested_string_field raw "identity_attestation" "effective_github_identity");
  check (option string) "read exposes credential identity"
    (Some "root")
    (parse_nested_string_field raw "credential" "effective_github_identity");
  check bool "read omits credential state to avoid duplicate gh auth status"
    true
    (parse_field raw "credential"
     |> Json.member "credential_state"
     |> (=) `Null);
  check bool "read attestation omits credential state"
    true
    (parse_field raw "identity_attestation"
     |> Json.member "credential_state"
     |> (=) `Null);
  let log = read_file log_path in
  check bool "read used docker run" true
    (contains_substring log "run --rm");
  check bool "metadata command used gh pr view" true
    (contains_substring log "gh pr view 13510");
  check bool "diff command used gh pr diff" true
    (contains_substring log "gh pr diff 13510");
  check bool "repo flag injected" true
    (contains_substring log "-R"
     && contains_substring log "jeong-sik/masc-mcp")

let test_comment_and_approve_route_through_docker () =
  with_fake_docker @@ fun () ->
  setup_docker_review @@ fun ~config ~meta ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  let raw =
    KTPR.handle_keeper_pr_review_comment ~config ~meta
      ~args:
        (`Assoc
          [ ("pr_number", `Int 13510)
          ; ("body", `String "docker comment evidence")
          ; ("event", `String "COMMENT")
          ])
  in
  check (option string) "comment via docker" (Some "docker")
    (parse_string_field raw "via");
  check (option string) "comment attests keeper"
    (Some "reviewer")
    (parse_nested_string_field raw "identity_attestation" "keeper");
  check (option string) "comment exposes credential identity"
    (Some "root")
    (parse_nested_string_field raw "credential" "effective_github_identity");
  let raw =
    KTPR.handle_keeper_pr_review_comment ~config ~meta
      ~args:
        (`Assoc
          [ ("pr_number", `Int 13510)
          ; ("body", `String "docker approve evidence")
          ; ("event", `String "APPROVE")
          ])
  in
  check (option string) "approve via docker" (Some "docker")
    (parse_string_field raw "via");
  check (option string) "approve route_via docker" (Some "docker")
    (parse_string_field raw "route_via");
  check (option bool) "approve preflight under unified key" (Some true)
    (parse_nested_bool_field raw "preflight" "ok");
  check bool "legacy approve_preflight key absent" true
    (match parse_field raw "approve_preflight" with
     | `Null -> true
     | _ -> false);
  let log = read_file log_path in
  check bool "review comment used gh pr review" true
    (contains_substring log "gh pr review 13510");
  check bool "comment event flag passed" true
    (contains_substring log "--comment");
  check bool "approve event flag passed" true
    (contains_substring log "--approve");
  check bool "approve preflight read PR metadata" true
    (contains_substring log "--json isDraft,headRefName,labels");
  check bool "repo flag injected for review mutation" true
    (contains_substring log "-R"
     && contains_substring log "jeong-sik/masc-mcp")

let test_approve_blocks_human_ready_pr_before_review () =
  with_fake_docker @@ fun () ->
  setup_docker_review @@ fun ~config ~meta ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  with_env "KEEPER_FAKE_PR_VIEW_JSON"
    "{\"isDraft\":false,\"headRefName\":\"fix/real-pr\",\"labels\":[{\"name\":\"human-approved-ready\"}]}"
  @@ fun () ->
  let raw =
    KTPR.handle_keeper_pr_review_comment ~config ~meta
      ~args:
        (`Assoc
          [ ("pr_number", `Int 13510)
          ; ("body", `String "unsafe approve should stop")
          ; ("event", `String "APPROVE")
          ])
  in
  check (option bool) "approval blocked" (Some false)
    (parse_bool_field raw "ok");
  check (option string) "structured block error"
    (Some "approve_event_blocked")
    (parse_string_field raw "error");
  check (option string) "block reason preserves human-ready gate"
    (Some "APPROVE is blocked once human-approved-ready is present")
    (parse_nested_string_field raw "preflight" "reason");
  let log = read_file log_path in
  check bool "preflight used gh pr view" true
    (contains_substring log "gh pr view 13510");
  check bool "blocked before gh pr review approve" false
    (contains_substring log "--approve")

let test_reply_routes_through_docker_and_infers_repo () =
  with_fake_docker @@ fun () ->
  setup_docker_review @@ fun ~config ~meta ->
  let log_path = Filename.concat config.Coord.base_path "docker.log" in
  with_env "KEEPER_DOCKER_LOG" log_path @@ fun () ->
  let raw =
    KTPR.handle_keeper_pr_review_reply ~config ~meta
      ~args:
        (`Assoc
          [ ("pr_number", `Int 13510)
          ; ("comment_id", `Int 3192459689)
          ; ("body", `String "docker reply evidence")
          ])
  in
  check (option string) "reply via docker" (Some "docker")
    (parse_string_field raw "via");
  check (option string) "reply route_via docker" (Some "docker")
    (parse_string_field raw "route_via");
  check (option string) "repo inferred for reply"
    (Some "jeong-sik/masc-mcp")
    (parse_string_field raw "repo");
  check (option string) "reply attests keeper"
    (Some "reviewer")
    (parse_nested_string_field raw "identity_attestation" "keeper");
  check (option string) "reply exposes credential identity"
    (Some "root")
    (parse_nested_string_field raw "credential" "effective_github_identity");
  let log = read_file log_path in
  check bool "reply used docker run" true
    (contains_substring log "run --rm");
  check bool "reply used gh api endpoint with inferred repo" true
    (contains_substring log
       "gh api repos/jeong-sik/masc-mcp/pulls/13510/comments/3192459689/replies");
  check bool "reply body passed to gh api" true
    (contains_substring log "docker reply evidence")

let () =
  Alcotest.run "Keeper PR review error UX" [
    "preset_gate", [
      test_case "research preset can mutate PR reviews" `Quick
        test_research_preset_can_mutate_pr_reviews;
      test_case "social preset cannot mutate PR reviews" `Quick
        test_social_preset_cannot_mutate_pr_reviews;
    ];
    "pr_not_found_in_output", [
      test_case "REST 404 (HTTP 404: Not Found)" `Quick test_detects_rest_404;
      test_case "GraphQL Could not resolve" `Quick
        test_detects_graphql_could_not_resolve;
      test_case "no pull requests found wording" `Quick
        test_detects_no_pull_requests_found;
      test_case "unrelated errors are not false positives" `Quick
        test_passes_through_unrelated_errors;
    ];
    "docker_route", [
      test_case "with_env restores cleared variables" `Quick
        test_with_env_restores_cleared_variable;
      test_case "read routes through docker and injects repo flag" `Quick
        test_read_routes_docker_and_injects_repo_flag;
      test_case "comment and approve route through docker" `Quick
        test_comment_and_approve_route_through_docker;
      test_case "approve blocks human-ready PR before review" `Quick
        test_approve_blocks_human_ready_pr_before_review;
      test_case "reply routes through docker and infers repo" `Quick
        test_reply_routes_through_docker_and_infers_repo;
    ]
  ]
