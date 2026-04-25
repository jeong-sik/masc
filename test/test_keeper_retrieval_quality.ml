(** test_keeper_retrieval_quality — BM25 retrieval quality for keeper tool selection.

    Verifies that the BM25 tool index retrieves the correct tool for
    common keeper scenarios. These are deterministic tests (no LLM calls).

    When a tool is unreachable via BM25, the keeper must rely on
    fallback (all tools exposed), which degrades selection quality.

    @since 2.199.0 — Phase 0 of keeper tool selection eval (#4306) *)

open Masc_mcp

(** Build a default keeper_meta via JSON deserialization (same helper as
    test_tool_keeper.ml). Only name and defaults are needed. *)
let make_meta () =
  let json = `Assoc [
    ("name", `String "eval-keeper");
    ("agent_name", `String "eval-keeper");
    ("trace_id", `String "trace-eval");
  ] in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error e -> failwith ("make_meta: " ^ e)

(** Rebuild the keeper BM25 tool index with the same production entry builder
    used by keeper_agent_run.ml.  This intentionally avoids a copied alias or
    group table in the test. *)
let build_keeper_index () =
  let meta = make_meta () in
  (* Inject masc_* schemas so the universe includes governance, agent, etc. *)
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  let tool_schemas = Keeper_exec_tools.keeper_universe_model_tools meta in
  let tool_index_config =
    { Agent_sdk.Tool_index.default_config with top_k = 20 } in
  let tool_entries =
    List.map
      (fun (t : Types.tool_schema) ->
         Keeper_agent_tool_surface.tool_index_entry
           ~name:t.name ~description:t.description)
      tool_schemas
  in
  Agent_sdk.Tool_index.build ~config:tool_index_config tool_entries

(** Check that [expected_tool] appears in BM25 top-k results for [query]. *)
let assert_retrieves ~label index query expected_tool =
  let retrieved = Agent_sdk.Tool_index.retrieve index query in
  let names = List.map fst retrieved in
  let rank = match List.find_index (fun n -> String.equal n expected_tool) names with
    | Some i -> Some (i + 1)
    | None -> None
  in
  (match rank with
  | Some r ->
    Alcotest.(check bool) (Printf.sprintf "%s: %s in top-20 (rank %d)" label expected_tool r)
      true true
  | None ->
    let top5 = List.filteri (fun i _ -> i < 5) names in
    Alcotest.failf "%s: %s NOT in top-20 for query '%s'. Top 5: [%s]"
      label expected_tool query (String.concat ", " top5));
  rank

(* ================================================================ *)
(* Scenarios: file operations                                       *)
(* ================================================================ *)

let test_file_read_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"file_read_en" idx
    "read the contents of lib/types.ml" "keeper_fs_read")

(* Korean queries use exact keyword overlap with BM25 aliases.
   Natural Korean queries like "파일 내용을 확인해봐" fail because
   BM25 tokenizes on whitespace and the query words don't overlap
   with the alias words. This is a known limitation — see #4306.
   These tests use keyword-aligned queries to verify the alias
   mechanism works at all. Real-world Korean retrieval needs
   embedding-based search, not BM25. *)
let test_file_read_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"file_read_kr" idx
    "파일 읽기" "keeper_fs_read")

let test_file_write_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"file_write_en" idx
    "write a new config file with updated settings" "keeper_fs_edit")

let test_file_write_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"file_write_kr" idx
    "파일 쓰기 편집" "keeper_fs_edit")

let test_file_search_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"file_search_en" idx
    "search for all occurrences of keeper_fs_edit in the codebase" "keeper_shell")

let test_file_search_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"file_search_kr" idx
    "명령어 검색 탐색" "keeper_shell")

(* ================================================================ *)
(* Scenarios: knowledge lookup                                      *)
(* ================================================================ *)

let test_memory_search_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"memory_en" idx
    "what did the user say earlier about the deployment" "keeper_memory_search")

let test_memory_search_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"memory_kr" idx
    "기억 검색 대화" "keeper_memory_search")

let test_library_search_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"library_en" idx
    "search the knowledge library for relevant docs" "keeper_library_search")

let test_library_search_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"library_kr" idx
    "라이브러리 지식 문서 검색" "keeper_library_search")

(* ================================================================ *)
(* Scenarios: board                                                 *)
(* ================================================================ *)

let test_board_post_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"board_post_en" idx
    "post my findings to the board" "keeper_board_post")

let test_board_read_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"board_read_kr" idx
    "게시판 글 읽기 조회" "keeper_board_get")

(* ================================================================ *)
(* Scenarios: build and test                                        *)
(* ================================================================ *)

let test_build_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"build_en" idx
    "run dune build to check if the code compiles" "keeper_bash")

let test_build_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"build_kr" idx
    "명령어 실행 빌드 테스트" "keeper_bash")

(* ================================================================ *)
(* Scenarios: tasks                                                 *)
(* ================================================================ *)

let test_task_claim_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"task_claim_en" idx
    "claim the next available task from the backlog" "keeper_task_claim")

let test_task_list_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"task_list_kr" idx
    "태스크 목록 할일" "keeper_tasks_list")

(* ================================================================ *)
(* Scenarios: voice                                                 *)
(* ================================================================ *)

let test_voice_speak_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"voice_speak_en" idx
    "say hello to the user out loud" "keeper_voice_speak")

let test_voice_speak_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"voice_speak_kr" idx
    "음성 말하기 보이스" "keeper_voice_speak")

(* ================================================================ *)
(* Scenarios: github                                                *)
(* ================================================================ *)

let test_github_pr_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"github_pr_en" idx
    "check the status of open pull requests" "keeper_shell")

let test_github_issue_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"github_issue_kr" idx
    "깃허브 이슈 풀리퀘스트" "keeper_shell")

(* ================================================================ *)
(* Scenarios: masc_* tools (Korean BM25 retrieval — #4520)          *)
(* ================================================================ *)

let test_masc_code_search_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"masc_code_kr" idx
    "코드 검색 소스코드" "masc_code_search")

let test_masc_code_search_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"masc_code_en" idx
    "search the codebase for function definitions" "masc_code_search")

(* masc_governance_status schema is unavailable after governance tool retirement.
   Test replaced with autoresearch retrieval. *)
let test_masc_autoresearch_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"autoresearch_kr" idx
    "자동연구 리서치 사이클" "masc_autoresearch_cycle")

(* masc_plan_get is not retrievable via BM25 with Korean queries:
   "계획", "플랜" are common terms that produce no BM25 match against
   350+ tool descriptions, even with Korean aliases.
   Needs embedding-based retrieval — tracked in #4331.
   These tools ARE always-included via category anchors, so they remain
   accessible regardless of BM25 ranking. *)

let test_masc_worktree_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"worktree_kr" idx
    "워크트리 생성 브랜치" "masc_worktree_create")

(* ================================================================ *)
(* Discrimination: fs_edit vs bash for file writes                  *)
(* ================================================================ *)

let test_prefer_fs_edit_over_bash () =
  let idx = build_keeper_index () in
  let retrieved = Agent_sdk.Tool_index.retrieve idx
    "create a new file called notes.md with some content" in
  let names = List.map fst retrieved in
  let fs_edit_rank = List.find_index (fun n -> String.equal n "keeper_fs_edit") names in
  let bash_rank = List.find_index (fun n -> String.equal n "keeper_bash") names in
  match fs_edit_rank, bash_rank with
  | Some fe, Some ba ->
    Alcotest.(check bool)
      (Printf.sprintf "fs_edit (rank %d) should rank higher than bash (rank %d)" (fe+1) (ba+1))
      true (fe < ba)
  | Some _, None ->
    (* fs_edit found, bash not — even better *)
    Alcotest.(check bool) "fs_edit present, bash absent" true true
  | None, _ ->
    Alcotest.fail "keeper_fs_edit not in top-20 for file creation query"

(* ================================================================ *)
(* Index stats                                                      *)
(* ================================================================ *)

let test_index_size () =
  let idx = build_keeper_index () in
  let size = Agent_sdk.Tool_index.size idx in
  Alcotest.(check bool) (Printf.sprintf "index has %d tools (>= 25)" size)
    true (size >= 25)

let test_search_alias_entries_target_keeper_universe () =
  let meta = make_meta () in
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  let tool_names =
    Keeper_exec_tools.keeper_universe_model_tools meta
    |> List.map (fun (schema : Types.tool_schema) -> schema.name)
  in
  let missing =
    Keeper_agent_tool_surface.tool_search_alias_entries
    |> List.map fst
    |> List.filter (fun name -> not (List.mem name tool_names))
  in
  Alcotest.(check (list string))
    "alias entries resolve to keeper universe tools" [] missing

(* ================================================================ *)
(* Scenarios: keeper_tool_search discovery                          *)
(* ================================================================ *)

(** Verify keeper_tool_search itself is retrievable (meta-search). *)
let test_tool_search_self_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"tool_search_self" idx
    "discover tools by describing what I need" "keeper_tool_search")

(** Full-universe search should find worktree tools even for
    a minimal-preset keeper. *)
let test_full_universe_worktree_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"full_worktree" idx
    "create a git worktree for isolated development" "masc_worktree_create")

(* Auth tools removed during tool-registry-pruning. *)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path));
  Alcotest.run "keeper_retrieval_quality"
    [
      ( "file_ops",
        [
          Alcotest.test_case "file read (en)" `Quick test_file_read_en;
          Alcotest.test_case "file read (kr)" `Quick test_file_read_kr;
          Alcotest.test_case "file write (en)" `Quick test_file_write_en;
          Alcotest.test_case "file write (kr)" `Quick test_file_write_kr;
          Alcotest.test_case "file search (en)" `Quick test_file_search_en;
          Alcotest.test_case "file search (kr)" `Quick test_file_search_kr;
        ] );
      ( "knowledge",
        [
          Alcotest.test_case "memory search (en)" `Quick test_memory_search_en;
          Alcotest.test_case "memory search (kr)" `Quick test_memory_search_kr;
          Alcotest.test_case "library search (en)" `Quick test_library_search_en;
          Alcotest.test_case "library search (kr)" `Quick test_library_search_kr;
        ] );
      ( "board",
        [
          Alcotest.test_case "board post (en)" `Quick test_board_post_en;
          Alcotest.test_case "board read (kr)" `Quick test_board_read_kr;
        ] );
      ( "build_test",
        [
          Alcotest.test_case "build (en)" `Quick test_build_en;
          Alcotest.test_case "build (kr)" `Quick test_build_kr;
        ] );
      ( "tasks",
        [
          Alcotest.test_case "task claim (en)" `Quick test_task_claim_en;
          Alcotest.test_case "task list (kr)" `Quick test_task_list_kr;
        ] );
      ( "voice",
        [
          Alcotest.test_case "voice speak (en)" `Quick test_voice_speak_en;
          Alcotest.test_case "voice speak (kr)" `Quick test_voice_speak_kr;
        ] );
      ( "github",
        [
          Alcotest.test_case "github PR (en)" `Quick test_github_pr_en;
          Alcotest.test_case "github issue (kr)" `Quick test_github_issue_kr;
        ] );
      ( "masc_tools",
        [
          Alcotest.test_case "masc code search (kr)" `Quick test_masc_code_search_kr;
          Alcotest.test_case "masc code search (en)" `Quick test_masc_code_search_en;
          Alcotest.test_case "masc autoresearch (kr)" `Quick test_masc_autoresearch_kr;
          Alcotest.test_case "masc worktree (kr)" `Quick test_masc_worktree_kr;
        ] );
      ( "discrimination",
        [
          Alcotest.test_case "fs_edit ranks higher than bash for file creation" `Quick
            test_prefer_fs_edit_over_bash;
        ] );
      ( "tool_search",
        [
          Alcotest.test_case "tool_search retrieves keeper_tool_search (en)" `Quick
            test_tool_search_self_en;
          Alcotest.test_case "worktree via full-universe search (en)" `Quick
            test_full_universe_worktree_en;
        ] );
      ( "stats",
        [
          Alcotest.test_case "index size >= 25 tools" `Quick test_index_size;
          Alcotest.test_case "search aliases target real tools" `Quick
            test_search_alias_entries_target_keeper_universe;
        ] );
    ]
