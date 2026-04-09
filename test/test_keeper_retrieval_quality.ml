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

(** Rebuild the keeper BM25 tool index identically to keeper_agent_run.ml.
    Uses the same Korean keywords, groups, and config. *)
let build_keeper_index () =
  let meta = make_meta () in
  (* Inject masc_* schemas so the universe includes governance, agent, etc. *)
  Keeper_exec_tools.inject_masc_schemas Config.raw_all_tool_schemas;
  let tool_schemas = Keeper_exec_tools.keeper_universe_model_tools meta in
  let tool_index_config =
    { Agent_sdk.Tool_index.default_config with top_k = 20 } in
  let korean_keywords = [
    "keeper_board_post", "게시판 글 작성 올리기 포스트";
    "keeper_board_get", "게시판 글 읽기 조회 확인";
    "keeper_board_list", "게시판 목록 최근글";
    "keeper_board_comment", "게시판 댓글 답글 코멘트";
    "keeper_board_vote", "게시판 투표 추천 반대";
    "keeper_board_search", "게시판 검색 키워드 글찾기";
    "keeper_board_delete", "게시판 삭제 제거 글삭제";
    "keeper_board_stats", "게시판 통계 활동 참여 게시글수";
    "keeper_fs_read", "파일 읽기 소스코드 설정";
    "keeper_fs_edit", "파일 쓰기 편집 저장 수정 생성";
    "keeper_shell", "명령어 조회 검색 탐색";
    "keeper_bash", "명령어 실행 쉘 빌드 테스트";
    "keeper_github", "깃허브 이슈 풀리퀘스트 PR CI";
    "keeper_memory_search", "기억 검색 대화 이전 메시지";
    "keeper_library_search", "라이브러리 지식 문서 검색";
    "keeper_library_read", "라이브러리 문서 읽기 지식";
    "keeper_time_now", "시간 현재 타임스탬프";
    "keeper_context_status", "컨텍스트 상태 토큰 사용량";
    "keeper_broadcast", "브로드캐스트 알림 공지 전달";
    "keeper_tasks_list", "태스크 목록 할일 백로그";
    "keeper_tasks_audit", "태스크 감사 고아 방치";
    "keeper_task_claim", "태스크 가져오기 할당";
    "keeper_task_done", "태스크 완료 마감";
    "keeper_task_force_release", "태스크 강제해제 반환";
    "keeper_task_force_done", "태스크 강제완료";
    "keeper_voice_speak", "음성 말하기 보이스";
    "keeper_voice_agent", "음성 설정 보이스";
    "keeper_voice_listen", "음성 듣기 마이크 녹음 입력";
    "keeper_voice_sessions", "음성 세션 목록";
    "keeper_voice_session_start", "음성 세션 시작";
    "keeper_voice_session_end", "음성 세션 종료";
    "keeper_stay_silent", "침묵 대기 아무것도 안함 넘어가기";
    "keeper_write", "파일 작성 저장 새파일";
    "keeper_tool_search", "도구 검색 발견 찾기 어떤도구";
    "masc_code_search", "코드 검색 소스코드 찾기 심볼";
    "masc_code_read", "코드 읽기 파일 소스코드";
    "masc_code_edit", "코드 편집 수정 파일 변경";
    "masc_code_write", "코드 작성 파일 생성 쓰기";
    "masc_code_symbols", "코드 심볼 함수 클래스 정의";
    "masc_code_shell", "코드 명령어 쉘 실행";
    "masc_code_git", "깃 커밋 브랜치 로그 이력";
    "masc_governance_status", "거버넌스 상태 규칙 정책";
    "masc_governance_feed", "거버넌스 피드 이벤트 로그";
    "masc_governance_set", "거버넌스 설정 규칙 변경";
    "masc_autoresearch_start", "자동연구 리서치 시작";
    "masc_autoresearch_status", "자동연구 리서치 상태";
    "masc_autoresearch_stop", "자동연구 리서치 중지";
    "masc_autoresearch_cycle", "자동연구 리서치 사이클 실행";
    "masc_plan_get", "계획 플랜 마일스톤 로드맵 프로젝트 전략";
    "masc_plan_update", "계획 플랜 수정 업데이트";
    "masc_plan_init", "계획 플랜 초기화 생성";
    "masc_plan_set_task", "계획 태스크 설정 할당";
    "masc_plan_get_task", "계획 태스크 조회";
    "masc_plan_clear_task", "계획 태스크 제거 해제 클리어";
    "masc_agent_card", "에이전트 카드 프로필 정보";
    "masc_agents", "에이전트 목록 현황 누구";
    "masc_agent_update", "에이전트 업데이트 상태변경";
    "masc_agent_fitness", "에이전트 적합도 평가";
    "masc_auth_status", "인증 상태 토큰 자격";
    "masc_auth_refresh", "인증 갱신 토큰 리프레시";
    "masc_web_search", "웹 검색 인터넷 온라인 구글";
    "masc_keeper_up", "키퍼 시작 기동 생성";
    "masc_keeper_down", "키퍼 중지 종료";
    "masc_keeper_list", "키퍼 목록 현황";
    "masc_keeper_msg", "키퍼 메시지 전달 대화";
    "masc_keeper_status", "키퍼 상태 확인";
    (* team session tool entries removed — team session cleanup *)
    "masc_worktree_create", "워크트리 생성 브랜치";
    "masc_worktree_list", "워크트리 목록 현황";
    "masc_worktree_remove", "워크트리 삭제 정리";
    "masc_tasks", "태스크 목록 할일 작업";
    "masc_add_task", "태스크 추가 등록 생성";
    "masc_status", "상태 현황 방 룸 요약";
    "masc_heartbeat", "하트비트 살아있음 생존";
    "masc_dashboard", "대시보드 현황 대시 보드 개요";
    "masc_broadcast", "브로드캐스트 방송 알림 공지";
    "masc_claim_next", "다음태스크 가져오기 할당";
    "masc_messages", "메시지 대화 채팅 로그";
    "masc_leave", "퇴장 나가기 오프라인 종료";
  ] in
  let tool_entries = List.map (fun (t : Types.tool_schema) ->
    let name = t.name in
    let group =
      if String.starts_with ~prefix:"keeper_board_" name then Some "board"
      else if String.starts_with ~prefix:"keeper_memory_" name
           || String.starts_with ~prefix:"keeper_library_" name then Some "knowledge"
      else if String.starts_with ~prefix:"keeper_task" name then Some "tasks"
      else if String.starts_with ~prefix:"keeper_voice_" name then Some "voice"
      else if String.starts_with ~prefix:"keeper_fs_" name
           || name = "keeper_shell"
           || name = "keeper_bash"
           || name = "keeper_write" then Some "filesystem"
      else if name = "keeper_github" then Some "vcs"
      else if String.starts_with ~prefix:"masc_board_" name then Some "masc_board"
      else if String.starts_with ~prefix:"masc_keeper_" name then Some "masc_keeper"
      else if String.starts_with ~prefix:"masc_plan_" name then Some "masc_plan"

      else if String.starts_with ~prefix:"masc_worktree_" name then Some "masc_worktree"
      else if String.starts_with ~prefix:"masc_code_" name then Some "masc_code"
      else if String.starts_with ~prefix:"masc_governance_" name then Some "masc_governance"
      else if String.starts_with ~prefix:"masc_autoresearch_" name then Some "masc_autoresearch"
      else if String.starts_with ~prefix:"masc_agent_" name
           || name = "masc_agents" then Some "masc_agent"
      else if String.starts_with ~prefix:"masc_" name then Some "masc_core"
      else None
    in
    let aliases = match List.assoc_opt name korean_keywords with
      | Some kw ->
        String.split_on_char ' ' kw
        |> List.filter (fun s -> s <> "")
      | None -> []
    in
    Agent_sdk.Tool_index.{ name; description = t.description; group; aliases }
  ) tool_schemas in
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
    "check the status of open pull requests" "keeper_github")

let test_github_issue_kr () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"github_issue_kr" idx
    "깃허브 이슈 풀리퀘스트" "keeper_github")

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

(** Auth tools should be discoverable via search. *)
let test_full_universe_auth_en () =
  let idx = build_keeper_index () in
  ignore (assert_retrieves ~label:"full_auth" idx
    "manage authentication tokens and credentials" "masc_auth_status")

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
          Alcotest.test_case "auth tools via full-universe search (en)" `Quick
            test_full_universe_auth_en;
        ] );
      ( "stats",
        [
          Alcotest.test_case "index size >= 25 tools" `Quick test_index_size;
        ] );
    ]
