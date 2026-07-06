(** Tool selection constants and backlog task reconciliation. *)

module String_set = Set_util.StringSet

(* Closed sum type for turn_lane.  Two producers emit values:
   - keeper_run_tools.ml emits the per-turn lanes
     (text_only, tool_optional, tool_disabled, retry).
   - keeper_turn_helpers.pre_dispatch_tool_surface emits the
     [Lane_pre_dispatch] placeholder before the per-turn lane logic
     runs.
   No [@@deriving tla] because this is a small runtime-local lane
   label, not a spec catalog. *)
type turn_lane =
  | Lane_pre_dispatch
  | Lane_text_only
  | Lane_tool_optional
  | Lane_tool_disabled
  | Lane_retry

let turn_lane_to_string = function
  | Lane_pre_dispatch -> "pre_dispatch"
  | Lane_text_only -> "text_only"
  | Lane_tool_optional -> "tool_optional"
  | Lane_tool_disabled -> "tool_disabled"
  | Lane_retry -> "retry"

let turn_lane_of_string = function
  | "pre_dispatch" -> Some Lane_pre_dispatch
  | "text_only" -> Some Lane_text_only
  | "tool_optional" -> Some Lane_tool_optional
  | "tool_disabled" -> Some Lane_tool_disabled
  | "retry" -> Some Lane_retry
  | _ -> None

let turn_lane_to_yojson lane = `String (turn_lane_to_string lane)

type tool_surface_metrics =
  { turn_lane : turn_lane
  ; config_root : string
  ; runtime_config_path : string option
  }

type turn_affordance =
  | Board_curation
  | Board_post_or_comment
  | Message_sweep
  | Task_claim
  | Task_audit
  | Task_verify

let turn_affordance_of_string = function
  | "board_curation" -> Some Board_curation
  | "board_post_or_comment" -> Some Board_post_or_comment
  | "message_sweep" -> Some Message_sweep
  | "task_claim" -> Some Task_claim
  | "task_audit" -> Some Task_audit
  | "task_verify" -> Some Task_verify
  | _ -> None

let turn_affordance_to_string = function
  | Board_curation -> "board_curation"
  | Board_post_or_comment -> "board_post_or_comment"
  | Message_sweep -> "message_sweep"
  | Task_claim -> "task_claim"
  | Task_audit -> "task_audit"
  | Task_verify -> "task_verify"

(* Affordance -> tools worth keeping visible for that affordance.
   This is an advisory surface-shaping hint only. It must not force
   tool_choice, completion policy, or text rejection. *)
let tools_for_affordance = function
  | Board_curation ->
    [ "keeper_board_curation_submit" ]
  | Board_post_or_comment ->
    [ "keeper_board_post"; "keeper_board_comment"; "masc_broadcast" ]
  | Message_sweep -> [ "masc_messages"; "masc_keeper_msg" ]
  | Task_claim ->
    [ "keeper_task_claim" ]
  | Task_audit ->
    [ "keeper_tasks_audit"; "keeper_tasks_list"; "masc_tasks" ]
  | Task_verify ->
    [ "keeper_tasks_list"; "keeper_tasks_audit";
      "keeper_task_done"; "masc_transition" ]

(* RFC-keeper-proactive-wake-actionability-invariant: does this affordance grant the keeper a tool that can change
   task/world state (and thus clear the signal that surfaced it)?  Exhaustive
   match over the closed [turn_affordance] sum, so adding a new affordance
   forces a decision here at compile time.  [Task_audit] is the sole
   advisory-only affordance: its tools (keeper_tasks_audit/list, masc_tasks)
   are read-only, so a keeper woken by a [Task_audit]-only signal cannot clear
   that signal — driving a proactive turn on it produces an unbounded no-op
   livelock (the failed_task incident, 2026-06-21..24).

   Why an explicit match instead of deriving from [tools_for_affordance] via
   [Keeper_tool_progress.effect_domain_for_tool_name]: the task mutators
   (keeper_task_claim / keeper_task_done / masc_transition) are
   [effect_domain = Masc_workspace], which the durable-evidence oracle
   [is_mutating_tool] classifies as non-mutating — reusing it would
   misclassify Task_claim/Task_verify as advisory-only and kill legitimate
   wake drivers.  "task-state mutation" and "durable evidence" are different
   axes.  The consistency of this match with [tools_for_affordance] is pinned
   by test_advisory_only_affordance_never_drives_wake. *)
let affordance_can_mutate : turn_affordance -> bool = function
  | Board_curation | Board_post_or_comment | Message_sweep
  | Task_claim | Task_verify -> true
  | Task_audit -> false

let satisfying_tools_for_turn ~(turn_affordances : string list) ~(allowed_tool_names : string list)
  : string list
  =
  let canonicalize = Keeper_tool_resolution.canonical_tool_name in
  let allowed_set =
    List.fold_left
      (fun s n -> String_set.add (canonicalize n) s)
      String_set.empty
      allowed_tool_names
  in
  turn_affordances
  |> List.concat_map (fun aff ->
    match turn_affordance_of_string aff with
    | Some affordance ->
      tools_for_affordance affordance
      |> List.filter (fun n -> String_set.mem (canonicalize n) allowed_set)
    | None -> [])
  |> Keeper_types_profile_toml_normalizers.dedupe_keep_order

let preferred_tool_names_for_turn_affordances turn_affordances =
  turn_affordances
  |> List.filter_map turn_affordance_of_string
  |> List.concat_map (function
       | Board_curation ->
         [ "keeper_board_curation_submit" ]
       | Board_post_or_comment ->
         [ "keeper_board_comment"; "keeper_board_post" ]
       | Message_sweep ->
         [ "masc_keeper_msg"; "masc_broadcast" ]
       | Task_claim ->
         [ "keeper_task_claim" ]
       | Task_audit ->
         [ "keeper_tasks_audit" ]
       | Task_verify ->
         [ "keeper_task_done"; "masc_transition" ]
       )
  |> Keeper_types_profile_toml_normalizers.dedupe_keep_order

let has_turn_affordance expected turn_affordances =
  List.exists
    (fun affordance ->
       match turn_affordance_of_string affordance with
       | Some affordance -> affordance = expected
       | None -> false)
    turn_affordances

let has_task_claim_affordance = has_turn_affordance Task_claim

let owned_active_task_id_for_meta =
  Keeper_current_task_reconcile.owned_active_task_id_for_meta

let owned_active_task_id_result_for_meta =
  Keeper_current_task_reconcile.owned_active_task_id_result_for_meta

let merge_current_task_id =
  Keeper_current_task_reconcile.merge_current_task_id

let sync_current_task_id_from_backlog =
  Keeper_current_task_reconcile.sync_current_task_id_from_backlog

let sync_current_task_id_for_agent_name =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name

let tool_names =
  List.map Keeper_tool_name.to_string

let is_claim_tool_name name =
  Keeper_tool_progress.is_claim_tool_name name

let is_claim_context_tool_name name =
  Keeper_tool_progress.is_claim_context_tool_name name

(* Tool selection — extracted to Keeper_tool_selection (#5732) *)

(* Deterministic selection floor size: keep the executable surface small
   enough for prompt budgets while still surfacing a handful of relevant
   tools even before any LLM hinting lands. *)
let keeper_selection_top_k = 10

(* BM25 candidate pool for TopK_llm: wide enough to give reranking workspace to
   improve results, but still bounded and deterministic. *)
let keeper_selection_bm25_prefilter_n = 30

(* Bilingual BM25 aliases for keeper tool search.  Keep this beside the
   production Tool_index entry builder so tests cannot drift by copying a
   second alias/group table.

   Entries stay keyed by canonical handler names. Model-facing public aliases
   such as Execute/Grep project through Keeper_tool_descriptor_resolution
   below, so retrieval shares one public-alias axis instead of carrying duplicate
   Execute/Grep rows. *)
let tool_search_alias_entries =
  [ "keeper_board_post", "게시판 글 작성 올리기 포스트"
  ; "keeper_board_post_get", "게시판 글 상세 단건 본문 댓글 post_id 읽기 보기"
  ; "keeper_board_list", "게시판 목록 최근글 post_id 찾기 조회 나열"
  ; "keeper_board_comment", "게시판 댓글 답글 코멘트"
  ; "keeper_board_vote", "게시판 투표 추천 반대"
  ; "keeper_board_search", "게시판 검색 키워드 post_id 찾기 과거글"
  ; "keeper_board_stats", "게시판 통계 활동 참여 게시글수"
  ; "keeper_board_curation_read", "게시판 AI 큐레이션 추천순서 하이라이트"
  ; "keeper_board_curation_submit", "게시판 AI 큐레이션 요약 태그 답변매칭 건강도 제출"
  ; "keeper_tool_search", "도구 검색 발견 찾기 어떤도구"
  ; "keeper_voice_listen", "음성 듣기 마이크 녹음 입력"
  ; "tool_read_file", "파일 읽기 소스코드 설정"
  ; "tool_edit_file", "파일 편집 수정 패치"
  ; "tool_write_file", "파일 쓰기 저장 생성 덮어쓰기"
  ; "tool_search_files", "코드 검색 소스코드 grep rg 패턴 찾기 파일"
  ; ( "tool_execute"
    , "명령어 실행 쉘 빌드 테스트 run dune build check compile compiles code git github gh \
       status log diff 깃허브 이슈 풀리퀘스트 워크트리 브랜치" )
  ; ( "keeper_memory_search"
    , "기억 검색 대화 이전 메시지 memory previous earlier user said recall deployment" )
  ; "keeper_library_search", "라이브러리 지식 문서 검색"
  ; "keeper_library_read", "라이브러리 문서 읽기 지식"
  ; ( "keeper_surface_read"
    , "커넥터 대화 읽기 연결된 채널 현재 채널 화자 명부 로스터 서피스 \
       connected surface lane bound channel current lane participant roster" )
  ; "keeper_surface_post", "커넥터 발화 보내기 디스코드 채널 메시지 전송 서피스"
  ; "keeper_person_note_set", "사람 기억 노트 저장 화자 메모 명부 로스터"
  ; "keeper_time_now", "시간 현재 타임스탬프"
  ; "keeper_context_status", "컨텍스트 상태 토큰 사용량"
  ; "keeper_tools_list", "도구 목록 기능 할수있는것 능력 capability introspection"
  ; "keeper_broadcast", "브로드캐스트 알림 공지 전달"
  ; "keeper_tasks_list", "태스크 목록 할일 백로그"
  ; "keeper_tasks_audit", "태스크 감사 고아 방치"
  ; "keeper_task_claim", "태스크 가져오기 할당"
  ; "keeper_task_create", "태스크 생성 만들기 일감"
  ; "keeper_task_done", "태스크 완료 마감"
  ; "keeper_voice_speak", "음성 말하기 보이스"
  ; "keeper_voice_agent", "음성 설정 보이스"
  ; "keeper_voice_sessions", "음성 세션 목록"
  ; "keeper_voice_session_start", "음성 세션 시작"
  ; "keeper_voice_session_end", "음성 세션 종료"
  ; "masc_plan_get", "계획 플랜 마일스톤 로드맵 프로젝트 전략"
  ; "masc_plan_update", "계획 플랜 수정 업데이트"
  ; "masc_plan_init", "계획 플랜 초기화 생성"
  ; "masc_plan_set_task", "계획 태스크 설정 할당"
  ; "masc_plan_get_task", "계획 태스크 조회"
  ; "masc_keeper_list", "키퍼 목록 현황"
  ; "masc_keeper_msg", "키퍼 메시지 전달 대화"
  ; "masc_keeper_status", "키퍼 상태 확인"
  ; "masc_tasks", "태스크 목록 할일 작업"
  ; "masc_add_task", "태스크 추가 등록 생성"
  ; "masc_status", "상태 현황 방 룸 요약"
  ; "masc_dashboard", "대시보드 현황 대시 보드 개요"
  ; "masc_plan_clear_task", "계획 태스크 제거 해제 클리어"
  ; "masc_agent_fitness", "에이전트 평가 점수 피트니스"
  ; "masc_web_search", "웹 검색 인터넷 온라인 구글"
  ; "masc_web_fetch", "웹 페이지 가져오기 읽기 URL 페치"

  ]

let tool_search_aliases name =
  let aliases_for_descriptor descriptor =
    Keeper_tool_descriptor.internal_names descriptor
    |> List.find_map (fun internal_name -> List.assoc_opt internal_name tool_search_alias_entries)
  in
  let aliases =
    match List.assoc_opt name tool_search_alias_entries with
    | Some _ as found -> found
    | None ->
      (match Keeper_tool_descriptor_resolution.descriptor_for_tool_name name with
       | Some descriptor -> aliases_for_descriptor descriptor
       | None ->
         (match Keeper_tool_descriptor_resolution.canonical_internal_name_for_tool_name name with
          | Some canonical when not (String.equal canonical name) ->
            List.assoc_opt canonical tool_search_alias_entries
          | _ -> None))
  in
  match aliases with
  | Some aliases ->
      aliases
      |> String.split_on_char ' '
      |> List.filter (fun alias -> alias <> "")
  | None -> []

let tool_index_entry ~name ~description : Agent_sdk.Tool_index.entry =
  (* The typed [tool_group] display classifier was deleted in the surface-cut
     refactor; tool-index entries are ungrouped. *)
  let aliases = tool_search_aliases name in
  Agent_sdk.Tool_index.{ name; description; group = None; aliases }

let tool_index_entry_of_tool (t : Agent_sdk.Tool.t) : Agent_sdk.Tool_index.entry =
  tool_index_entry ~name:t.schema.name ~description:t.schema.description
