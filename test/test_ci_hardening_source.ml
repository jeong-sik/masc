(** CI/dashboard hardening source guards. *)

open Alcotest

let file_contains_pattern file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        if String.length pattern = 0 then true
        else
          let re = Str.regexp_string pattern in
          (try ignore (Str.search_forward re content 0); true
           with Not_found -> false))

let file_not_contains_pattern file_rel pattern =
  not (file_contains_pattern file_rel pattern)

let file_pattern_position file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then None
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        let re = Str.regexp_string pattern in
        try Some (Str.search_forward re content 0) with Not_found -> None)

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let quote = Filename.quote

let run_agent_draft_policy env =
  let env_prefix =
    env
    |> List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v))
    |> String.concat " "
  in
  let script =
    Filename.concat (source_root ()) "scripts/ci/check-agent-draft-policy.sh"
  in
  let cmd =
    Printf.sprintf "cd %s && %s bash %s >/dev/null 2>&1"
      (quote (source_root ())) env_prefix (quote script)
  in
  Sys.command cmd

let test_ci_sync_and_asset_contracts () =
  check bool "pr sync script added" true
    (file_contains_pattern "scripts/check-pr-sync.sh" "workflow payload head");
  check bool "pr sync script falls back to pull ref" true
    (file_contains_pattern "scripts/check-pr-sync.sh" "refs/pull/${pr_number}/head");
  check bool "ci workflow verifies pr sync" true
    (file_contains_pattern ".github/workflows/ci.yml" "Verify PR sync");
  check bool "ci workflow passes pr number to sync check" true
    (file_contains_pattern ".github/workflows/ci.yml" "--pr-number \"$PR_NUMBER\"");
  check bool "ci gate enforces agent draft policy" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "Enforce agent draft policy on merge gate");
  check bool "ci gate uses agent draft policy script" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "scripts/ci/check-agent-draft-policy.sh");
  check bool "ci gate refreshes live draft state" true
    (file_contains_pattern ".github/workflows/ci.yml" "PR_LIVE_IS_DRAFT");
  check bool "ci gate refreshes live labels" true
    (file_contains_pattern ".github/workflows/ci.yml" "PR_LIVE_LABELS");
  (* #10192: ci gate must also pass live PR state to the
     policy script so already-merged PRs do not flip red. *)
  check bool "ci gate refreshes live PR state" true
    (file_contains_pattern ".github/workflows/ci.yml" "PR_LIVE_STATE");
  check bool "pr hygiene no longer checks dashboard assets (gitignored)" true
    (not (file_contains_pattern "scripts/check-pr-hygiene.sh" "dashboard source or Vite config changed but assets/dashboard was not updated"))

let test_agent_draft_policy_script () =
  let base =
    [
      ("GITHUB_EVENT_NAME", "pull_request");
      ("PR_TITLE", "fix: keep long turns visibly alive");
      ("PR_HEAD_REF", "codex/keeper-process-evidence");
      ("PR_LABELS", "");
    ]
  in
  check int "non pull_request events are ignored" 0
    (run_agent_draft_policy [ ("GITHUB_EVENT_NAME", "push") ]);
  check bool "draft agent PR without bypass fails closed" true
    (run_agent_draft_policy (("PR_IS_DRAFT", "true") :: base) <> 0);
  check bool "live draft state does not bypass approval gate" true
    (run_agent_draft_policy
       (("PR_LIVE_IS_DRAFT", "true") :: ("PR_IS_DRAFT", "false") :: base)
    <> 0);
  check bool "live ready state overrides stale draft event" true
    (run_agent_draft_policy
       (("PR_LIVE_IS_DRAFT", "false") :: ("PR_IS_DRAFT", "true") :: base)
    <> 0);
  check int "live bypass label overrides stale event labels" 0
    (run_agent_draft_policy
       (("PR_LIVE_IS_DRAFT", "false")
       :: ("PR_LIVE_LABELS", "enhancement,human-approved-ready")
       :: ("PR_IS_DRAFT", "true")
       :: base));
  check bool "ready agent PR without bypass fails" true
    (run_agent_draft_policy (("PR_IS_DRAFT", "false") :: base) <> 0);
  check bool "ready feature PR with agent-pr label fails" true
    (run_agent_draft_policy
       [
         ("GITHUB_EVENT_NAME", "pull_request");
         ("PR_IS_DRAFT", "false");
         ("PR_TITLE", "feat: ordinary feature title");
         ("PR_HEAD_REF", "feature/dashboard-fsm-audit-exposure");
         ("PR_LABELS", "enhancement,agent-pr");
       ]
    <> 0);
  check int "ready agent PR with bypass label passes" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false")
       :: ("PR_LABELS", "enhancement,human-approved-ready")
       :: List.remove_assoc "PR_LABELS" base));
  check int "draft agent PR with bypass label passes" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "true")
       :: ("PR_LABELS", "enhancement,human-approved-ready")
       :: List.remove_assoc "PR_LABELS" base));
  check int "ready non-agent PR passes" 0
    (run_agent_draft_policy
       [
         ("GITHUB_EVENT_NAME", "pull_request");
         ("PR_IS_DRAFT", "false");
         ("PR_TITLE", "fix: human authored branch");
         ("PR_HEAD_REF", "feature/human-branch");
         ("PR_LABELS", "enhancement");
       ]);
  (* #10192: post-merge gate race.  When the live PR state is
     MERGED or CLOSED, the policy is moot (the merge already
     happened) and a missing bypass label must NOT resurrect a
     red check on a shipped PR. *)
  check int "ready agent PR with live state MERGED is skipped" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false") :: ("PR_LIVE_STATE", "MERGED") :: base));
  check int "ready agent PR with live state CLOSED is skipped" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false") :: ("PR_LIVE_STATE", "CLOSED") :: base));
  check int "live state lower-case merged is also skipped" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false") :: ("PR_LIVE_STATE", "merged") :: base));
  check bool "live state OPEN does NOT bypass policy" true
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false") :: ("PR_LIVE_STATE", "OPEN") :: base)
     <> 0)

let test_pr_automation_draft_guard_contracts () =
  check bool "pr automation live query includes PR state" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "state\n                    merged");
  check bool "pr automation skips live merged PRs" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       {|current.state === "MERGED"|});
  check bool "pr automation skips live closed PRs" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       {|current.state === "CLOSED"|});
  check bool "pr automation skips when live merged flag is true" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "current.merged === true");
  let live_state_skip =
    file_pattern_position ".github/workflows/pr-automation.yml"
      {|current.state === "MERGED"|}
  in
  let draft_restore =
    file_pattern_position ".github/workflows/pr-automation.yml"
      "convertPullRequestToDraft"
  in
  check bool "post-merge skip runs before draft restore mutation" true
    (match live_state_skip, draft_restore with
     | Some skip_pos, Some restore_pos -> skip_pos < restore_pos
     | _ -> false);
  check bool "draft-only state does not suppress missing approval" true
    (file_not_contains_pattern ".github/workflows/pr-automation.yml"
       "verifiedBypassLabels.length === 0 &&\n              !safeDraftOnlyState")

let test_health_and_ci_runner_diagnostics () =
  check bool "health snapshot records baseline source" true
    (file_contains_pattern "scripts/health_snapshot.sh" "\"baseline\": {");
  check bool "health snapshot records regressions array" true
    (file_contains_pattern "scripts/health_snapshot.sh" "\"regressions\": ${regressions_json}");
  check bool "tests scrub inherited MASC_BASE_PATH overrides" true
    (file_contains_pattern "test/dune" "(MASC_BASE_PATH \"\")");
  check bool "ci runner captures log file" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "TEST_LOG_FILE=");
  check bool "ci runner prints failure markers" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "failure markers (latest 20)");
  check bool "ci runner records active command pid/pgid" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "active_cmd_pgid=");
  check bool "ci runner prints active command process tree snapshot" true
    (file_contains_pattern "scripts/ci-run-tests.sh"
       "active command process tree snapshot:");
  check bool "ci runner tails dune log on failure" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "tail -n 120 ${dune_log}");
  check bool "ci runner retries dune rpc lock failures in isolated build dir" true
    (file_contains_pattern "scripts/ci-run-tests.sh"
       "detected dune RPC/lock failure; retrying once with isolated build dir");
  check bool "ci runner detects native archive loss" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "Unbound module Llm_provider");
  check bool "ci runner detects disk full failures" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "No space left on device");
  check bool "ci runner prints disk hygiene repair guidance" true
    (file_contains_pattern "scripts/ci-run-tests.sh"
       "bash scripts/disk-hygiene.sh --fix");
  check bool "ci runner avoids recursive tmpdir du in diagnostics" true
    (file_not_contains_pattern "scripts/ci-run-tests.sh"
       "du -sh \"${TMPDIR:-/tmp}\"");
  check bool "ci runner avoids process substitution in clean retry" true
    (file_not_contains_pattern "scripts/ci-run-tests.sh" "> >(tee");
  check bool "ci runner tracks active build dir for diagnostics" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "ACTIVE_TEST_BUILD_DIR");
  check bool "quick suite excludes operator control from monolithic dune test" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "MASC_INCLUDE_OPERATOR_CONTROL: \"false\"");
  check bool "ci workflow runs operator control in dedicated step" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "dune exec ./test/test_operator_control.exe");
  check bool "operator control test is env-gated in dune" true
    (file_contains_pattern "test/dune"
       "(enabled_if (= %{env:MASC_INCLUDE_OPERATOR_CONTROL=true} \"true\"))")

let test_release_truth_contracts () =
  (* TODO: uncomment when Doc Truth CI job is wired (#9419 follow-up) *)
  (* check bool "ci workflow defines doc truth job" true
    (file_contains_pattern ".github/workflows/ci.yml" "name: Doc Truth");
  check bool "ci workflow exports doc truth scope output" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "doc_truth: ${{ steps.scope.outputs.doc_truth }}");
  check bool "ci gate aggregates doc truth" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "check \"doc-truth\"       \"$DOC_TRUTH_RESULT\"");
  check bool "ci gate aggregates oas pin check" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "check \"oas-pin-check\"   \"$OAS_PIN_RESULT\"");
  check bool "ci gate aggregates spec line refs" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "check \"spec-line-refs\"  \"$SPEC_REFS_RESULT\""); *)
  check bool "ci workflow removed odoc documentation lane" true
    (file_not_contains_pattern ".github/workflows/ci.yml" "name: Documentation");
  check bool "ci workflow no longer installs odoc" true
    (file_not_contains_pattern ".github/workflows/ci.yml" "Install odoc");
  check bool "release/doc truth changes trigger build scope" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "docs/|README\\.md$|ROADMAP\\.md$|CHANGELOG\\.md$");
  check bool "release evidence changes stay in build scope" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "scripts/release-evidence\\.sh$");
  check bool "health job reruns doc truth and OAS pin checks" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "scripts/check-doc-truth.sh\n          scripts/sync-oas-pin-docs.sh --check");
  check bool "doc truth script delegates version truth" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "scripts/check-version-truth.sh");
  check bool "release workflow checks version truth" true
    (file_contains_pattern ".github/workflows/release.yml"
       "scripts/check-version-truth.sh");
  (* TODO: uncomment when ci_core fanout comment is added (#9419 follow-up) *)
  (* check bool "ci core fanout intentionally excludes tla" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "Note: tla is intentionally NOT forced on by ci_core."); *)
  check bool "main build uploads release evidence" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "name: Upload main release evidence");
  check bool "release workflow generates evidence bundle" true
    (file_contains_pattern ".github/workflows/release.yml"
       "Generate release evidence bundle");
  check bool "release workflow ships evidence with artifacts" true
    (file_contains_pattern ".github/workflows/release.yml"
       "path: dist/*");
  check bool "make install deps skips with-doc" true
    (file_contains_pattern "mk/build.mk"
       "opam install . --deps-only --with-test -y");
  check bool "make release evidence target exists" true
    (file_contains_pattern "mk/release.mk" "release-evidence:")

let test_oas_pin_source_contracts () =
  check bool "external opam pins retry transient git fetch failures" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "OPAM_PIN_RETRIES");
  check bool "external opam pins use retry wrapper" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "opam_pin_add mcp_protocol");
  check bool "oas pin check parses local file pins from opam output" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "extract_opam_pin_source()");
  check bool "oas pin check accepts rsync-style file pins" true
    (file_contains_pattern "scripts/check-oas-pin.sh" "git+*|file://*)");
  check bool "oas pin check normalizes local pin path helper" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "local_pin_path_from_source()");
  check bool "oas pin check accepts both git file pins and plain file pins" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "git+file://*|file://*)");
  check bool "oas pin check validates findlib artifact directories" true
    (file_contains_pattern "scripts/check-oas-pin.sh" "ocamlfind query");
  check bool "oas pin check validates agent sdk native archive" true
    (file_contains_pattern "scripts/check-oas-pin.sh" "agent_sdk.cmxa");
  check bool "oas pin check validates llm provider native archive" true
    (file_contains_pattern "scripts/check-oas-pin.sh" "llm_provider.cmxa");
  check bool "oas pin check gives rebuild guidance" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "scripts/opam-pin-external-deps.sh --install")

let test_doc_truth_guard_contracts () =
  check bool "doc truth script protects spec index front door wording" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "Historical compatibility lane과 internal orchestration reference는 migration context로만 남긴다.");
  check bool "doc truth script protects command plane downgrade" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "| Status | Historical Reference |");
  check bool "doc truth script protects system overview front door wording" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "### 7.3 Dashboard and Operator Read Visibility");
  check bool "doc truth script forbids dead server_command_plane_http row" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "require_not_contains docs/spec/09-server-transport.md '| `server_command_plane_http.ml` |'");
  check bool "doc truth script forbids old dashboard command-plane type wording" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "command-plane.ts         -- Command plane types")

let test_contract_harness_contracts () =
  check bool "contract harness exposes extract_text helper" true
    (file_contains_pattern "scripts/harness/lib/test_framework.sh"
       "extract_text()");
  check bool "golden path harness uses extract_text helper" true
    (file_contains_pattern "scripts/harness/contract/golden_path_1_contract.sh"
       "| extract_text)")

let test_route_auth_contracts () =
  (* CP purge (phases 1-5): command-plane HTTP/H2 route modules deleted.
     Assertions on server_routes_http_routes_command_plane_*.ml and
     server_h2_gateway_routes_cp.ml removed with the source files. *)
  check bool "http keeper chat stream uses keeper tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_tool_auth ~tool_name:"masc_keeper_msg"|});
  check bool "dashboard runtime probe force refresh uses tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_tool_auth ~tool_name:"masc_runtime_ollama_probe"|});
  check bool "http keeper chat stream forces direct reply mode" true
    (file_contains_pattern "lib/server/server_routes_http_keeper_stream.ml"
       {|("direct_reply", `Bool true)|});
  check bool "channel gate message route uses tool auth" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|with_tool_auth ~tool_name:"channel_gate"|});
  check bool "channel gate message route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.post "/api/v1/gate/message"|});
  check bool "channel gate health route stays public read" true
    (file_contains_pattern
        "lib/server/server_routes_http_routes_channel_gate.ml"
        "with_public_read");
  check bool "channel gate events route stays public read" true
    (file_contains_pattern
       "lib/server/server_auth.ml"
       {|String.equal path "/api/v1/gate/events"|});
  check bool "channel gate connectors route stays public read" true
    (file_contains_pattern
       "lib/server/server_auth.ml"
       {|String.equal path "/api/v1/gate/connectors"|});
  check bool "generic connector status route stays public read" true
    (file_contains_pattern
       "lib/server/server_auth.ml"
       {|String.equal path "/api/v1/gate/connector/status"|});
  check bool "channel gate health route is registered" true
    (file_contains_pattern
        "lib/server/server_routes_http_routes_channel_gate.ml"
        {|Http.Router.get "/api/v1/gate/health"|});
  check bool "generic connector status route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.get "/api/v1/gate/connector/status"|});
  check bool "channel gate connectors route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.get "/api/v1/gate/connectors"|});
  check bool "generic connector bind route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.post "/api/v1/gate/connector/bind"|});
  check bool "generic connector unbind route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.post "/api/v1/gate/connector/unbind"|})

let test_http_write_auth_contracts () =
  check bool "server auth scopes query token fallback to observer SSE helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let observer_sse_query_token_from_request");
  check bool "observer SSE helper still gates query token on sse_kind" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|match query_param request "sse_kind" with|});
  check bool "observer SSE helper still reads token query param" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|trim_opt (query_param request "token")|});
  check bool "observer SSE auth error documents scoped query token contract" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|or 'token' query param for the observer/presence SSE stream.|});
  check bool "server auth keeps general MCP auth header-only" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|match auth_token_from_request request with|});
  check bool "observer SSE query token fallback stays scoped" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|let observer_sse_query_token_from_request request =|});
  check bool "observer SSE fallback reads token query param explicitly" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|query_param request "token"|});
  check bool "observer SSE auth has dedicated verifier" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|let verify_mcp_observer_stream_auth ~base_path request =|});
  check bool "server auth defines token-bound permission helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let authorize_token_bound_permission_request");
  check bool "server auth exposes token-bound route helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "and with_token_permission_auth");
  check bool "server auth defines same-origin browser guard" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let ensure_same_origin_browser_request");
  check bool "tool auth enforces same-origin when no bearer token" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "else ensure_same_origin_browser_request request");
  check bool "broadcast route requires token-bound broadcast permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_token_permission_auth ~permission:Types.CanBroadcast|});
  check bool "keeper config update requires admin permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_token_permission_auth ~permission:Types.CanAdmin|});
  check bool "board vote route requires board vote tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|with_tool_auth ~tool_name:"masc_board_vote"|});
  check bool "board vote route overwrites voter from auth identity" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|let voter = board_actor_author_for_write agent_name|});
  check bool "board vote route writes normalized voter" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|json_upsert_string_field "voter" voter|});
  check bool "board comment route overwrites author from auth identity" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|let author = board_actor_author_for_write agent_name|});
  check bool "board comment route writes normalized author" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|json_upsert_string_field "author" author|});
  check bool "tool-host-failures route requires tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_tool_auth ~tool_name:"masc_broadcast"|});
  check bool "provider runs post requires admin permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_provider_runs.ml"
       {|with_token_permission_auth ~permission:Types.CanAdmin|});
  check bool "dashboard delete actions require token-bound admin permission" true
    (file_contains_pattern "lib/server/server_dashboard_http_delete_actions.ml"
       {|with_token_permission_auth ~permission:Types.CanAdmin|});
  check bool "server auth defines public-read cors origin helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let public_read_cors_origin_opt");
  check bool "server auth exposes public-read json responder" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let respond_public_read_json");
  check bool "channel gate public reads use constrained cors responder" true
    (file_contains_pattern "lib/server/server_routes_http_routes_channel_gate.ml"
       "respond_public_read_json");
  check bool "artifacts endpoint uses constrained cors responder" true
    (file_contains_pattern "lib/server/server_routes_http_routes_artifacts.ml"
       "respond_public_read_json");
  check bool "provider runs route threads state net into dashboard single-run" true
    (file_contains_pattern "lib/server/server_routes_http_routes_provider_runs.ml"
       "~net:state.Mcp_server.net");
  check bool "loopback cross-port auth uses explicit dev origin allowlist" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "configured_loopback_dev_mutation_origins");
  check bool "loopback cross-port auth no longer trusts any loopback origin" true
    (not
       (file_contains_pattern "lib/server/server_auth.ml"
          "if is_loopback_host (normalize_loopback_host origin_host) then"))

let test_tool_admin_snapshot_auth_contracts () =
  check bool "tool admin snapshot metadata requires admin permission" true
    (file_contains_pattern "lib/tool_misc.ml"
       {|"masc_tool_admin_snapshot" | "masc_tool_admin_update" ->
      Some Types.CanAdmin|});
  check bool "tool admin snapshot legacy permission map requires admin" true
    (file_contains_pattern "lib/tool_permission_map.ml"
       {|("masc_tool_admin_snapshot", CanAdmin)|})

let test_keeper_direct_reply_contracts () =
  check bool "dashboard keeper direct messages request direct reply" true
    (file_contains_pattern "dashboard/src/api/keeper.ts"
       "direct_reply: true");
  check bool "operator keeper_message forwards direct reply flag" true
    (file_contains_pattern "lib/operator/operator_control.ml"
       {|("direct_reply", `Bool true)|});
  check bool "channel gate keeper bridge uses streaming reply path" true
    (file_contains_pattern "lib/gate_keeper_backend.ml"
       "Tool_keeper.dispatch_stream");
  check bool "keeper turn parses direct reply flag" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "get_bool args \"direct_reply\"");
  (* Historical: direct_reply once forked cascade name into
     "keeper_reply"/"keeper_turn", but neither was ever defined in
     cascade.json — the drift collapsed to the default cascade via
     Keeper_cascade_profile.canonicalize. The fork is gone; the
     direct_reply flag now only affects persona prompt + skill-route
     suppression (checked below). *)
  check bool "keeper manual turns resolve declared cascade through runtime catalog" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "Cascade_catalog_runtime.resolve_declared_name ~raw_name");
  check bool "keeper turn suppresses skill route headers for direct reply" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "let effective_no_skill_route = no_skill_route || direct_reply");
  check bool "keeper turn applies direct reply persona prompt" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "Keeper_prompt.append_direct_reply_mode_prompt")

let test_dashboard_warm_hydration_contracts () =
  check bool "execution default route hydrates cache on first success" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "cached_surface_or_first_success_json _execution_cache");
  check bool "mission default route serves cached surface immediately" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "cached_surface_or_first_success_json _mission_cache");
  check bool "namespace truth advertises initializing while execution warms" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth.ml"
       {|("status", `String "initializing")|});
  check bool "execution render timeout is a named constant" true
    (file_contains_pattern "lib/dashboard/dashboard_execution.ml"
       "let render_timeout_s");
  check bool "execution proactive refresh timeout is extended" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S");
  check bool "mission proactive refresh timeout is extended" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "let mission_refresh_timeout_s")

let test_http_read_surface_contracts () =
  check bool "room status route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/status" (fun request reqd ->
       with_read_auth|});
  check bool "room tasks route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/tasks" (fun request reqd ->
       with_read_auth|});
  check bool "room agents route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/agents" (fun request reqd ->
       with_read_auth|});
  check bool "room messages route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/messages" (fun request reqd ->
       with_read_auth|});
  check bool "room route delegates status reads to protocol boundary" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Room_protocol.status config");
  check bool "room route delegates task reads to protocol boundary" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Room_protocol.tasks ?status_filter");
  check bool "room route delegates agent reads to protocol boundary" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Room_protocol.agents ?status_filter config");
  check bool "room route delegates message reads to protocol boundary" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Room_protocol.messages ?agent_filter");
  check bool "room route does not read Coord directly" true
    (file_not_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Coord.");
  check bool "room route does not read Tempo directly" true
    (file_not_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Tempo.");
  check bool "room protocol owns the Coord read boundary" true
    (file_contains_pattern "lib/room_protocol.ml"
       "Coord.get_tasks_raw config");
  check bool "provider run status route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_provider_runs.ml"
       {|"/api/v1/agent-runs/" (fun request reqd ->
       with_read_auth|})

let test_operator_surface_route_contracts () =
  (* CP purge (phases 1-5): operator/command-plane HTTP+H2 surfaces deleted.
     All assertions in this test referenced source files that no longer exist. *)
  ()

let test_input_validation_contracts () =
  (* Bug #1602: broadcast must reject empty messages *)
  check bool "broadcast validates empty message" true
    (file_contains_pattern "lib/tool_inline_dispatch_comm.ml"
       {|"Broadcast message cannot be empty"|});
  check bool "broadcast trims whitespace before check" true
    (file_contains_pattern "lib/tool_inline_dispatch_comm.ml"
       {|String.trim message|});
  (* Bug #1609: cache must have automatic eviction *)
  check bool "cache has maybe_evict_expired function" true
    (file_contains_pattern "lib/cache_eio.ml"
       "let maybe_evict_expired config");
  check bool "cache get triggers batch eviction" true
    (file_contains_pattern "lib/cache_eio.ml"
       "maybe_evict_expired config")

let test_room_current_validation_contracts () =
  (* H2 gateway serves canonical namespace routes and keeps temporary room
     aliases so mixed dashboard/backend deployments do not break during rollout. *)
  check bool "h2 gateway serves project-snapshot endpoint" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/dashboard/project-snapshot"|});
  check bool "h2 gateway serves namespace-truth endpoint alias" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/dashboard/namespace-truth"|});
  check bool "h2 gateway keeps room-truth alias endpoint during rollout" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/dashboard/room-truth"|});
  check bool "h2 gateway serves namespace current endpoint" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/namespace/current"|});
  check bool "h2 gateway maps invalid namespace writes to 400" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|Invalid_argument msg|});
  check bool "h2 gateway keeps room current alias endpoint during rollout" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/room/current"|})

let test_root_redirect_contracts () =
  check bool "http root redirects to dashboard" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.get "/"|});
  check bool "http root keeps dashboard fallback redirect" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|redirect_to_dashboard reqd|});
  check bool "http redirect sets dashboard location" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|respond_redirect ~location:"/dashboard"|});
  check bool "h2 root responds with server identity" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|h2_respond_text h2_reqd "MASC MCP Server (HTTP/2)"|})


let test_dashboard_component_split_contracts () =
  check bool "harness health sections export verdict tone" true
    (file_contains_pattern "dashboard/src/components/harness-health-sections.ts"
       "export function verdictTone");
  check bool "harness health tests cover verdict tone" true
    (file_contains_pattern "dashboard/src/components/harness-health-sections.test.ts"
       "describe('verdictTone'");
  check bool "retired proof helpers module stays deleted" true
    (file_not_contains_pattern "dashboard/src/components/proof-helpers.ts"
       "export function");
  check bool "coord backend setup no longer references transaction companion after PG removal" true
    (file_not_contains_pattern "lib/coord/coord_utils_backend_setup.ml"
       "Transaction Pooler companion")

let test_mission_briefing_memory_guard_contracts () =
  check bool "mission briefing snapshot disables keeper payload" true
    (file_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       "~include_keepers:false");
  check bool "mission briefing snapshot no longer references command plane" true
    (file_not_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       "include_command_plane");
  check bool "mission briefing snapshot stays off command plane" true
    (file_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       "~include_summary_fields:false");
  check bool "mission briefing snapshot stays lightweight" true
    (file_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       "~lightweight_summary:true");
  check bool "mission briefing reuses mission keeper briefs" true
    (file_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       {|mission_json |> member_assoc "keeper_briefs"|});
  check bool "mission briefing card no longer forces eager operator snapshot" true
    (file_not_contains_pattern "dashboard/src/components/mission-briefing-card.ts"
       "refreshOperatorSnapshot({ force: true })")

let test_activity_surface_contracts () =
  check bool "observatory absorbs activity-derived panels" true
    (file_contains_pattern "dashboard/src/components/observatory/observatory.ts"
       "ObservatoryActivityPanels");
  check bool "dashboard fetches canonical activity graph route" true
    (file_contains_pattern "dashboard/src/api/actions.ts"
       "/api/v1/activity/graph");
  check bool "server exposes canonical activity events route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|"/api/v1/activity/events"|});
  check bool "server exposes canonical activity graph route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|"/api/v1/activity/graph"|});
  check bool "activity routes thread sw/clock instead of reading Eio_context directly" true
    (not
       (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
          "Eio_context.get_switch"));
  check bool "server drops legacy social graph alias" true
    (not
       (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
          {|"/api/v1/social-graph"|}));
  check bool "coord top-level module emits activity events" true
    (file_contains_pattern "lib/coord.ml"
       "Activity_graph.emit config");
  check bool "coord task lifecycle emits activity events via hook" true
    (file_contains_pattern "lib/coord/coord_task.ml"
       "emit_task_activity");
  check bool "coord broadcast emits activity events via hook" true
    (file_contains_pattern "lib/coord/coord_broadcast.ml"
       "(Atomic.get Coord_hooks.activity_emit_fn) config");
  check bool "board success paths emit activity events" true
    (file_contains_pattern "lib/tool_inline_dispatch_extra.ml"
       "Activity_graph.emit config")

let test_local_review_script_contracts () =
  check bool "local review script exists" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "#!/usr/bin/env bash");
  check bool "local review script caches under .masc review-cache" true
    (file_contains_pattern "scripts/review/local-review.sh"
       ".masc/review-cache/local-review");
  check bool "local review script resolves shared git common dir cache root" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--git-common-dir");
  check bool "local review script keeps pending registry" true
    (file_contains_pattern "scripts/review/local-review.sh"
       ".pending.json");
  check bool "local review script chunks large diffs" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "MASC_LOCAL_REVIEW_CHUNK_BYTES");
  check bool "local review script bounds reviewer request time" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--max-time");
  check bool "local review script exposes cache key print" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--print-cache-key")

let test_keeper_oas_cleanup_contracts () =
  check bool "keeper config no longer exposes stale unified turn flag" true
    (not
       (file_contains_pattern "lib/keeper/keeper_config.ml"
          "MASC_KEEPER_UNIFIED_TURN"));
  check bool "keeper turn comment no longer mentions context manager" true
    (not
       (file_contains_pattern "lib/keeper/keeper_turn.ml"
          "Context_manager"));
  check bool "tool compact comment now references OAS-backed pipeline" true
    (file_contains_pattern "lib/tool_compact.ml"
       "OAS-backed compaction pipeline")

let test_dashboard_executor_pool_contracts () =
  check bool "dashboard runtime support defines executor pool helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_runtime_support.ml"
       "let run_dashboard_compute");
  check bool "dashboard runtime support submits compute to executor pool" true
    (file_contains_pattern "lib/server/server_dashboard_http_runtime_support.ml"
       "Eio.Executor_pool.submit_exn");
  check bool "mission refresh loop uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw");
  check bool "mission actor path uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "run_dashboard_compute ~mode ?net ?mono_clock ~sw ~clock");
  check bool "execution refresh loop uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock ~net");
  check bool "server state captures mono_clock for threaded readonly compute" true
    (file_contains_pattern "lib/mcp_server.ml"
       "mono_clock: Eio.Time.Mono.ty Eio.Resource.t option");
  check bool "dashboard core threads state runtime caps into readonly compute" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "let net, mono_clock = state_dashboard_runtime_caps state");
  check bool "dashboard core no longer reads global eio net directly" true
    (file_not_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "Eio_context.get_net ()");
  check bool "dashboard core no longer reads global mono_clock directly" true
    (file_not_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "Eio_context.get_mono_clock ()");
  check bool "execution parameterized path uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw");
  check bool "server bootstrap wires executor pool into dashboard" true
    (file_contains_pattern "lib/server/server_runtime_bootstrap.ml"
       "Server_dashboard_http.set_executor_pool exec_pool")

(* pg schema init contracts removed: init_pg_schemas_sequential was deleted in #3218 *)

let test_transport_route_contracts () =
  let transport_delete_path_verifies_full_mcp_auth =
    file_contains_pattern "lib/server/server_mcp_transport_http.ml"
      {|let handle_delete_mcp ~deps ?(profile = Full) request reqd =|}
    && file_contains_pattern "lib/server/server_mcp_transport_http.ml"
         {|deps.verify_mcp_auth ~base_path request|}
  in
  let h2_delete_path_verifies_full_mcp_auth =
    file_contains_pattern "lib/server/server_h2_gateway.ml"
      {|`DELETE, "/mcp" | `DELETE, "/mcp/managed" ->|}
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         {|verify_mcp_auth ~base_path httpun_request|}
  in
  check bool "frontend exposes ws discovery route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.get "/ws" websocket_discovery_handler|});
  check bool "mcp http agent injection preserves explicit legacy agent_name" true
    (file_contains_pattern "lib/server/server_mcp_transport_http.ml"
       {|Option.is_none existing_agent
                    && Option.is_none existing_legacy_agent|});
  check bool "common http deps prefer runtime captured in server_state" true
    (file_contains_pattern "lib/server/server_routes_http_common.ml"
       "state.Mcp_server.sw");
  check bool "frontend exposes webrtc offer route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.post "/webrtc/offer"|});
  check bool "frontend exposes webrtc answer route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.post "/webrtc/answer"|});
  check bool "frontend webrtc routes require tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       "let webrtc_signaling_handler ~tool_name signaling_fn request reqd =\n  with_tool_auth ~tool_name");
  check bool "h2 gateway exposes webrtc offer route" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|`POST, "/webrtc/offer"|});
  check bool "h2 gateway exposes webrtc answer route" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|`POST, "/webrtc/answer"|});
  check bool "transport delete path verifies full mcp auth" true
    transport_delete_path_verifies_full_mcp_auth;
  check bool "h2 delete path verifies full mcp auth" true
    h2_delete_path_verifies_full_mcp_auth;
  check bool "h2 gateway webrtc routes enforce tool auth" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|authorize_tool_request|}
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         {|~base_path:state.Mcp_server.room_config.base_path|}
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         {|~tool_name:"masc_webrtc_offer"|}
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         {|~tool_name:"masc_webrtc_answer"|});
  check bool "h2 gateway respects webrtc disabled state" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|Server_webrtc_transport.is_enabled ()|})

let test_transport_health_contracts () =
  check bool "standalone ws updates transport metrics on connect" true
    (file_contains_pattern "lib/server/server_ws_standalone.ml"
       {|Transport_metrics.set_ws_sessions|});
  check bool "transport metrics ws env parse matches runtime server" true
    (file_contains_pattern "lib/config/env_config_core.ml"
       {| | "false" | "0" | "no" -> false|});
  check bool "standalone ws reuses transport metrics env parser" true
    (file_contains_pattern "lib/server/server_ws_standalone.ml"
       {|Transport_metrics.ws_enabled ()|});
  check bool "transport health avoids room message scans" true
    (not
       (file_contains_pattern "lib/transport_metrics.ml"
          {|Coord.get_messages_raw_in_room|}))
  (* command plane topology reads guard removed (CP purge: Command_plane_v2 deleted) *)

let test_worktree_list_contracts () =
  check bool "worktree list stays read-only" true
    (file_contains_pattern "lib/tool_worktree.ml"
       {|let _tool_spec_read_only = [ "masc_worktree_list" ]|});
  check bool "worker oas no longer reads global net directly" true
    (file_not_contains_pattern "lib/worker_oas.ml"
       "Eio_context.get_net_opt ()");
  (* research dispatch assertions removed — lib/research/ subsystem deleted (#4715) *)
  check bool "worktree create/remove still require join" true
    (file_contains_pattern "lib/tool_worktree.ml"
       {|let _tool_spec_requires_join = [ "masc_worktree_create"; "masc_worktree_remove" ]|});
  check bool "worktree list excluded from join-required list" true
    (file_not_contains_pattern "lib/tool_worktree.ml"
       {|_tool_spec_requires_join = [|} ||
     file_not_contains_pattern "lib/tool_worktree.ml"
       {|"masc_worktree_remove"; "masc_worktree_list"|})


let test_oas_worker_capability_threading_contracts () =
  check bool "oas worker model-by-label accepts threaded sw capability" true
    (file_contains_pattern "lib/oas_worker.mli"
       "?sw:Eio.Switch.t ->");
  check bool "oas worker model-by-label accepts threaded net capability" true
    (file_contains_pattern "lib/oas_worker.mli"
       "?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->")

let test_oas_capacity_restore_contracts () =
  check bool "operator judge backoff uses OAS local capacity" true
    (file_contains_pattern "lib/dashboard/dashboard_operator_judge.ml"
       "local_capacity_for_selections ~sw ~net");
  check bool "operator judge selection is explicit" true
    (file_contains_pattern "lib/dashboard/dashboard_operator_judge.ml"
       {|[ "operator_judge" ]|});
  check bool "governance judge backoff uses OAS local capacity" true
    (file_contains_pattern "lib/dashboard/dashboard_governance_judge.ml"
       "local_capacity_for_selections ~sw ~net");
  check bool "governance judge selection is explicit" true
    (file_contains_pattern "lib/dashboard/dashboard_governance_judge.ml"
       {|[ "governance_judge" ]|});
  check bool "autoresearch background gating restores OAS capacity query" true
    (file_contains_pattern "lib/autoresearch_codegen.ml"
       "local_capacity_for_selections ~sw ~net");
  check bool "autoresearch uses Eio context fallback for capacity probing" true
    (file_contains_pattern "lib/autoresearch_codegen.ml"
       "Eio_context.get_switch_opt (), Eio_context.get_net_opt ()")

let test_dashboard_timeout_guard_contracts () =
  check bool "http transport health route uses cached dashboard helper" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|let json = dashboard_transport_health_http_json ~state in|});
  check bool "dashboard shell helper accepts threaded clock capability" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "let dashboard_shell_http_json ?clock");
  check bool "http dashboard shell route threads state clock" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       "dashboard_shell_http_json ?clock:state.Mcp_server.clock");
  check bool "h2 dashboard shell route threads state clock" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "dashboard_shell_http_json ?clock:state.Mcp_server.clock");
  check bool "h2 transport health route uses cached dashboard helper" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "dashboard_transport_health_http_json ~state");
  check bool "server dashboard transport health helper uses cached surface" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       {|cached_surface_json _transport_health_cache|});
  check bool "shell timeout detector recognizes computation_timeout" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       {|Some (`String ("Compute timeout" | "computation_timeout"))|});
  check bool "shell meta cognition seeds stale fallback before refresh" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "Dashboard_cache.seed_stale_if_missing key");
  check bool "namespace-truth pending confirm seeds stale fallback" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth_support.ml"
       "Dashboard_cache.seed_stale_if_missing key");
  check bool "mission refresh dedupes inflight fetches" true
    (file_contains_pattern "dashboard/src/mission-actions.ts"
       "let inflightMissionSnapshotRefresh: Promise<void> | null = null");
  check bool "transport health panel dedupes inflight fetches" true
    (file_contains_pattern "dashboard/src/components/transport-health.ts"
       "let inflightTransportHealthRefresh: Promise<void> | null = null")

let test_namespace_truth_adaptive_timeout_contracts () =
  check bool "shell fiber uses adaptive timeout" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth.ml"
       "shell_timeout_s");
  check bool "namespace-truth warm timeout is a named constant" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth.ml"
       "let warm_timeout_s");
  check bool "namespace-truth cold timeout is a named constant" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth.ml"
       "let cold_timeout_s");
  check bool "shell_warmed tracking exists" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "_shell_warmed")

let test_http_client_fd_safety_contracts () =
  check bool "masc http client forbids direct Cohttp client construction in docs" true
    (file_contains_pattern "lib/masc_http_client/masc_http_client.ml"
       "instead of [Cohttp_eio.Client.make] directly");
  check bool "voice bridge builds clients through masc http client" true
    (file_contains_pattern "lib/voice/voice_bridge_core.ml"
       "Masc_http_client.make_closing_client");
  check bool "otel exporter builds clients through masc http client" true
    (file_contains_pattern "lib/opentelemetry_client_cohttp_eio.ml"
       "Masc_http_client.make_closing_client");
  ()

let test_runtime_precondition_contracts () =
  check bool "graphql routes expose result-based server state lookup" true
    (file_contains_pattern "lib/server/server_routes_http_pages.ml"
       "let get_server_state_result () =");
  (* with_server_state removed: h2 governance case routes retired,
     remaining routes do not need server state guard. *)
  ()

let file_uses_masc_dir_helper file =
  List.exists
    (fun pattern -> file_contains_pattern file pattern)
    [
      "Common.masc_dir_from_base_path";
      "Common.masc_dirname";
      "Masc_paths.masc_dir_from_base_path";
      "Masc_paths.masc_dirname";
    ]

(* #9571: MASC dirname SSOT — every runtime path that lives under
   [base_path/.masc/...] must go through [Common.masc_dir_from_base_path]
   instead of inlining the literal [".masc/<sub>"].  These contracts
   cover the first migration batch (issue triage 2026-04-25); a future
   PR can extend them as remaining call sites are migrated.

   Each entry asserts: the migrated file uses the helper AND no
   longer contains the inlined literal.  Either side regressing breaks
   the SSOT and this test catches it before merge. *)
let test_masc_dirname_ssot_contracts () =
  let migrated_files = [
    (* batch 1 (#10237) *)
    "lib/auth.ml";
    "lib/board_votes.ml";
    "lib/discovery_history.ml";
    "lib/handover_eio.ml";
    "lib/hebbian_eio.ml";
    "lib/institution_eio.ml";
    "lib/repo_synthesis_benchmark.ml";
    "lib/tool_blob_store/tool_blob_store.ml";
    (* batch 2 (#10249) *)
    "lib/config_dir_resolver.ml";
    "lib/mcp_server_eio_resource.ml";
    "lib/oas_worker_cascade.ml";
    "lib/procedural_memory.ml";
    (* batch 3 (#10257) *)
    "lib/tool_team_memory.ml";
    "lib/exec_core.ml";
    "lib/keeper/keeper_accountability.ml";
    (* batch 4 (#10262) *)
    "lib/server/server_routes_http_routes_dashboard.ml";
    "lib/keeper/keeper_approval_queue.ml";
    (* batch 5 (#10266) *)
    "lib/server/server_routes_http_routes_sidecar.ml";
    "lib/keeper/keeper_status_detail.ml";
    (* batch 6 (this PR — gate channel state legacy paths, relative-only) *)
    "lib/gate/channel_gate_discord_state.ml";
    "lib/gate/channel_gate_imessage_state.ml";
    "lib/gate/channel_gate_discord_names.ml";
  ] in
  (* Accepted SSOT helper references.  Listed explicitly rather than using
     a substring matcher so each form is auditable.  Add new references
     here when a future batch introduces a new alias or helper. *)
  let masc_dir_helper_patterns = [
    "Common.masc_dir_from_base_path";       (* base-rooted helper *)
    "Masc_paths.masc_dir_from_base_path";   (* alias re-export *)
    "Common.masc_dirname";                  (* relative-only constant *)
    "Common.auth_dir_from_base_path";       (* derived auth root helper *)
    "Common.agents_dir_from_base_path";     (* derived auth agents helper *)
  ] in
  let file_uses_masc_dir_helper file =
    List.exists (fun p -> file_contains_pattern file p)
      masc_dir_helper_patterns
  in
  List.iter
    (fun file ->
       check bool
         (Printf.sprintf "%s references an approved masc_dir SSOT helper" file)
         true
         (file_uses_masc_dir_helper file);
       check bool
         (Printf.sprintf "%s no longer inlines \".masc/\"" file)
         true
         (file_not_contains_pattern file "\".masc/");
       check bool
         (Printf.sprintf "%s no longer inlines standalone \".masc\"" file)
         true
         (file_not_contains_pattern file "\".masc\""))
    migrated_files

let () =
  run "ci_hardening_source"
    [
      ("source_guard", [
           test_case "sync and asset contracts" `Quick test_ci_sync_and_asset_contracts;
           test_case "agent draft policy script" `Quick
             test_agent_draft_policy_script;
           test_case "pr automation draft guard contracts" `Quick
             test_pr_automation_draft_guard_contracts;
           test_case "contract harness contracts" `Quick
             test_contract_harness_contracts;
           test_case "health and ci diagnostics" `Quick test_health_and_ci_runner_diagnostics;
           test_case "release truth contracts" `Quick test_release_truth_contracts;
           test_case "oas pin source contracts" `Quick test_oas_pin_source_contracts;
           test_case "doc truth guard contracts" `Quick test_doc_truth_guard_contracts;
           test_case "route auth contracts" `Quick test_route_auth_contracts;
           test_case "http write auth contracts" `Quick test_http_write_auth_contracts;
           test_case "tool admin snapshot auth contracts" `Quick
             test_tool_admin_snapshot_auth_contracts;
           test_case "keeper direct reply contracts" `Quick
             test_keeper_direct_reply_contracts;
           test_case "dashboard warm hydration contracts" `Quick
             test_dashboard_warm_hydration_contracts;
           test_case "http read surface contracts" `Quick test_http_read_surface_contracts;
           test_case "operator surface route contracts" `Quick
             test_operator_surface_route_contracts;
           test_case "input validation contracts" `Quick test_input_validation_contracts;
           test_case "room current validation contracts" `Quick
             test_room_current_validation_contracts;
           test_case "root redirect contracts" `Quick test_root_redirect_contracts;
           test_case "dashboard component split contracts" `Quick test_dashboard_component_split_contracts;
           test_case "mission briefing memory guard contracts" `Quick
             test_mission_briefing_memory_guard_contracts;
           test_case "activity surface contracts" `Quick test_activity_surface_contracts;
           test_case "local review script contracts" `Quick test_local_review_script_contracts;
           test_case "keeper oas cleanup contracts" `Quick test_keeper_oas_cleanup_contracts;
           test_case "dashboard executor pool contracts" `Quick
             test_dashboard_executor_pool_contracts;
           test_case "transport route contracts" `Quick
             test_transport_route_contracts;
           test_case "transport health contracts" `Quick
             test_transport_health_contracts;
           test_case "worktree list contracts" `Quick
             test_worktree_list_contracts;
           test_case "oas worker capability threading contracts" `Quick
             test_oas_worker_capability_threading_contracts;
           test_case "oas capacity restore contracts" `Quick
             test_oas_capacity_restore_contracts;
           test_case "dashboard timeout guard contracts" `Quick
             test_dashboard_timeout_guard_contracts;
           test_case "http client fd safety contracts" `Quick
             test_http_client_fd_safety_contracts;
           test_case "namespace-truth adaptive timeout contracts" `Quick
             test_namespace_truth_adaptive_timeout_contracts;
           test_case "runtime precondition contracts" `Quick
             test_runtime_precondition_contracts;
           test_case "masc_dirname SSOT contracts (#9571 batch 1)" `Quick
             test_masc_dirname_ssot_contracts;
         ]);
    ]
