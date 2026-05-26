(** Keeper_agent_tool_surface_types — tool surface types, enums,
    serialization, tool constants, and search index extracted from
    [Keeper_agent_tool_surface] (787 LoC).  Tool selection logic
    and backlog reconciliation remain in the parent.
    @since Keeper 500-line decomposition *)

module String_set = Set_util.StringSet

let unexpected_tool_partial_warned : (string, unit) Hashtbl.t =
  Hashtbl.create 32

let unexpected_tool_partial_warn_mu = Eio.Mutex.create ()

let should_log_unexpected_tool_partial_once ~keeper_name ~unexpected_tool_names =
  let key =
    String.concat "\000" (keeper_name :: List.sort String.compare unexpected_tool_names)
  in
  Eio_guard.with_mutex unexpected_tool_partial_warn_mu (fun () ->
      if Hashtbl.mem unexpected_tool_partial_warned key then
        false
      else (
        Hashtbl.replace unexpected_tool_partial_warned key ();
        true))

type tool_requirement =
  | Required
  | Optional
  | No_tools

let tool_requirement_to_string = function
  | Required -> "required"
  | Optional -> "optional"
  | No_tools -> "none"

let tool_requirement_of_string = function
  | "required" -> Some Required
  | "optional" -> Some Optional
  | "none" -> Some No_tools
  | _ -> None

let tool_requirement_to_yojson = function
  | Required -> `String "required"
  | Optional -> `String "optional"
  | No_tools -> `String "none"

(* Closed sum type for turn_lane.  Two producers emit values:
   - keeper_run_tools.ml:963-973 emits the five per-turn lanes
     (text_only, tool_required, tool_optional, tool_disabled, retry).
   - keeper_turn_helpers.pre_dispatch_tool_surface emits the
     [Lane_pre_dispatch] placeholder before the per-turn lane logic
     runs.
   No [@@deriving tla] because the module-level all_symbols binding
   is reserved for tool_surface_class (a future RFC spec extension
   can add TurnLaneSet and lift this). *)
type turn_lane =
  | Lane_pre_dispatch
  | Lane_text_only
  | Lane_tool_required
  | Lane_tool_optional
  | Lane_tool_disabled
  | Lane_retry

let turn_lane_to_string = function
  | Lane_pre_dispatch -> "pre_dispatch"
  | Lane_text_only -> "text_only"
  | Lane_tool_required -> "tool_required"
  | Lane_tool_optional -> "tool_optional"
  | Lane_tool_disabled -> "tool_disabled"
  | Lane_retry -> "retry"

let turn_lane_of_string = function
  | "pre_dispatch" -> Some Lane_pre_dispatch
  | "text_only" -> Some Lane_text_only
  | "tool_required" -> Some Lane_tool_required
  | "tool_optional" -> Some Lane_tool_optional
  | "tool_disabled" -> Some Lane_tool_disabled
  | "retry" -> Some Lane_retry
  | _ -> None

let turn_lane_to_yojson lane = `String (turn_lane_to_string lane)

(* Closed sum type for tool-surface selection mode.  See .mli for
   rationale (avoids name collision with Keeper_skill_routing and
   Keeper_alerting, each of which owns its own selection_mode). *)
type tool_selection_mode =
  | Selection_deterministic_plus_llm_hint
  | Selection_core_plus_prefilter_plus_discovered

let tool_selection_mode_to_string = function
  | Selection_deterministic_plus_llm_hint -> "deterministic_plus_llm_hint"
  | Selection_core_plus_prefilter_plus_discovered ->
    "core_plus_prefilter_plus_discovered"

let tool_selection_mode_of_string = function
  | "deterministic_plus_llm_hint" -> Some Selection_deterministic_plus_llm_hint
  | "core_plus_prefilter_plus_discovered" ->
    Some Selection_core_plus_prefilter_plus_discovered
  | _ -> None

let tool_selection_mode_to_yojson m =
  `String (tool_selection_mode_to_string m)


(* Closed sum type for tool_surface_class.  Mirrors RFC-0065 §3.2.2
   KeeperToolSurface SurfaceClassSet so the correspondence harness can
   drop the hand-pinned label list.  [@tla.symbol "…"] fixes the wire
   representation across JSON, Prometheus labels, dashboard surface,
   and the .tla catalog. *)
type tool_surface_class =
  | Surface_none [@tla.symbol "none"]
  | Surface_public_only [@tla.symbol "public_only"]
  | Surface_mixed [@tla.symbol "mixed"]
[@@deriving tla]

(* [@tla.symbol] is the single source of truth for the wire form:
   - to_tla_symbol (ppx-generated) emits the symbol attached per variant
   - all_symbols / all_states (ppx-generated) enumerate the type
   Defining the JSON/Prometheus surface in terms of [to_tla_symbol]
   guarantees JSON ↔ spec parity cannot drift even if a variant or its
   symbol changes.  Addresses the SSOT concern in PR #14647 review. *)
let tool_surface_class_to_string = to_tla_symbol

let tool_surface_class_of_string raw =
  List.find_opt
    (fun cls -> String.equal (to_tla_symbol cls) raw)
    all_states

let tool_surface_class_to_yojson cls =
  `String (tool_surface_class_to_string cls)

type tool_surface_metrics =
  { turn_lane : turn_lane
  ; tool_surface_class : tool_surface_class
  ; tool_requirement : tool_requirement
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  ; required_tool_names : string list
  ; required_tool_candidate_names : string list
  ; missing_required_tool_names : string list
  ; config_root : string
  ; cascade_config_path : string option
  ; gemini_mcp_disabled : bool
  ; approval_mode_effective : string option
  ; approval_mode_derived : bool
  }

type computed_tool_surface =
  { all_allowed : string list
  ; absolute_turn : int
  ; checkpoint_start_turn : int
  ; per_call_turn : int
  ; per_call_max_turns : int
  ; core_count : int
  ; deterministic_prefilter : string list
  ; deterministic_prefilter_count : int
  ; discovered_count : int
  ; llm_selected_count : int
  ; selection_mode : tool_selection_mode
  ; is_last_turn : bool
  ; is_warning_zone : bool
  ; tool_surface_class : tool_surface_class
  ; tool_requirement : tool_requirement
  ; tool_gate_requested : bool
  ; tool_surface_fallback_used : bool
  ; required_tool_names : string list
  ; required_tool_candidate_names : string list
  ; missing_required_tool_names : string list
  ; lane : turn_lane
  ; query_text : string
  }

type turn_affordance =
  | Board_curation
  | Board_post_or_comment
  | Message_sweep
  | Reply_in_room
  | Task_claim
  | Task_audit
  | Task_verify
  | Work_discovery
  | Inspect_worktree_delta

let turn_affordance_of_string = function
  | "board_curation" -> Some Board_curation
  | "board_post_or_comment" -> Some Board_post_or_comment
  | "message_sweep" -> Some Message_sweep
  | "reply_in_room" -> Some Reply_in_room
  | "task_claim" -> Some Task_claim
  | "task_audit" -> Some Task_audit
  | "task_verify" -> Some Task_verify
  | "work_discovery" -> Some Work_discovery
  | "inspect_worktree_delta" -> Some Inspect_worktree_delta
  | _ -> None

let turn_affordance_to_string = function
  | Board_curation -> "board_curation"
  | Board_post_or_comment -> "board_post_or_comment"
  | Message_sweep -> "message_sweep"
  | Reply_in_room -> "reply_in_room"
  | Task_claim -> "task_claim"
  | Task_audit -> "task_audit"
  | Task_verify -> "task_verify"
  | Work_discovery -> "work_discovery"
  | Inspect_worktree_delta -> "inspect_worktree_delta"

let should_tool_gate_affordance = function
  | Work_discovery -> false
  | Board_curation
  | Board_post_or_comment
  | Message_sweep
  | Reply_in_room
  | Task_claim
  | Task_audit
  | Task_verify
  | Inspect_worktree_delta -> true

let turn_affordances_require_tool_gate turn_affordances =
  List.exists
    (function
      | Some affordance -> should_tool_gate_affordance affordance
      | None -> false)
    (List.map turn_affordance_of_string turn_affordances)

(* Affordance -> minimum viable tools that can satisfy that affordance.
   The list is intentionally narrow ("at least one of these is enough").
   Keepers without any matching tool cannot satisfy a [Require_tool_use]
   contract for that affordance and must be allowed to respond with text
   instead. [Work_discovery] remains listed for routing/search guidance, but it
   does not hard-gate by itself; the concrete signals inside a discovery turn
   (claimable tasks, board activity, worktree delta) own the strict contract. *)
let tools_for_gated_affordance = function
  | Board_curation ->
    [ "keeper_board_curation_submit"; "keeper_board_cleanup" ]
  | Board_post_or_comment ->
    [ "keeper_board_post"; "keeper_board_comment"; "masc_broadcast" ]
  | Message_sweep -> [ "masc_messages"; "masc_keeper_msg" ]
  | Reply_in_room ->
    [ "keeper_board_post"; "keeper_board_comment";
      "masc_keeper_msg"; "masc_broadcast" ]
  | Task_claim ->
    [ "keeper_task_claim"; "masc_claim_next" ]
  | Task_audit ->
    [ "keeper_tasks_audit"; "keeper_tasks_list"; "masc_tasks" ]
  | Task_verify ->
    [ "keeper_tasks_list"; "keeper_tasks_audit";
      "keeper_task_done"; "keeper_task_submit_for_verification";
      "masc_transition" ]
  | Work_discovery ->
    Keeper_tool_capability_axis.work_discovery_routing_tool_names
  | Inspect_worktree_delta ->
    Keeper_tool_capability_axis.inspect_worktree_delta_tool_names

(* --- Tool constants, search aliases, and index entries --- *)

let owned_active_task_id_for_meta =
  Keeper_current_task_reconcile.owned_active_task_id_for_meta

let merge_current_task_id =
  Keeper_current_task_reconcile.merge_current_task_id

let sync_current_task_id_from_backlog =
  Keeper_current_task_reconcile.sync_current_task_id_from_backlog

let sync_current_task_id_for_agent_name =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name

let tool_names =
  List.map Tool_name.to_string

let fallback_floor_tool_names =
  tool_names
    Tool_name.[
      Keeper Context_status;
      Keeper Task_claim;
      Keeper Tasks_list;
      Keeper Board_list;
      Keeper Board_get;
    ]

let fallback_repo_probe_tool_names =
  tool_names Tool_name.[ Keeper Fs_read; Keeper Shell; Keeper Execute ]

let is_claim_tool_name name =
  Keeper_tool_progress.is_claim_tool_name name

let is_claim_context_tool_name name =
  Keeper_tool_progress.is_claim_context_tool_name name

(* Tool selection — extracted to Keeper_tool_selection (#5732) *)

(* Deterministic selection floor size: keep the executable surface small
   enough for prompt budgets while still surfacing a handful of relevant
   tools even before any LLM hinting lands. *)
let keeper_selection_top_k = 10

(* BM25 candidate pool for TopK_llm: wide enough to give reranking room to
   improve results, but still bounded and deterministic. *)
let keeper_selection_bm25_prefilter_n = 30

(* Bilingual BM25 aliases for keeper tool search.  Keep this beside the
   production Tool_index entry builder so tests cannot drift by copying a
   second alias/group table.

   Entries stay keyed by canonical handler names. LLM-visible public aliases
   such as Execute/SearchFiles project through Keeper_tool_alias below, so retrieval
   shares one public-alias axis instead of carrying duplicate Execute/Shell rows. *)
let tool_search_alias_entries =
  [ "keeper_board_post", "게시판 글 작성 올리기 포스트"
  ; "keeper_board_get", "게시판 글 읽기 조회 확인"
  ; "keeper_board_list", "게시판 목록 최근글"
  ; "keeper_board_comment", "게시판 댓글 답글 코멘트"
  ; "keeper_board_vote", "게시판 투표 추천 반대"
  ; "keeper_board_search", "게시판 검색 키워드 글찾기"
  ; "keeper_board_stats", "게시판 통계 활동 참여 게시글수"
  ; "keeper_board_curation_read", "게시판 AI 큐레이션 추천순서 하이라이트"
  ; "keeper_board_curation_submit", "게시판 AI 큐레이션 요약 태그 답변매칭 건강도 제출"
  ; "keeper_stay_silent", "침묵 대기 아무것도 안함 넘어가기"
  ; "keeper_tool_search", "도구 검색 발견 찾기 어떤도구"
  ; "keeper_voice_listen", "음성 듣기 마이크 녹음 입력"
  ; "tool_read_file", "파일 읽기 소스코드 설정"
  ; "tool_edit_file", "파일 편집 수정 패치"
  ; "tool_write_file", "파일 쓰기 저장 생성 덮어쓰기"
  ; "tool_search_files", "명령어 조회 검색 탐색 파일 git status diff log"
  ; ( "tool_execute"
    , "명령어 실행 쉘 빌드 테스트 run dune build check compile compiles code git gh \
       add commit push pr pull request draft 생성 풀리퀘스트" )
  ; "keeper_memory_search", "기억 검색 대화 이전 메시지"
  ; "keeper_library_search", "라이브러리 지식 문서 검색"
  ; "keeper_library_read", "라이브러리 문서 읽기 지식"
  ; "keeper_time_now", "시간 현재 타임스탬프"
  ; "keeper_context_status", "컨텍스트 상태 토큰 사용량"
  ; "keeper_tools_list", "도구 목록 기능 할수있는것 능력"
  ; "keeper_broadcast", "브로드캐스트 알림 공지 전달"
  ; "keeper_tasks_list", "태스크 목록 할일 백로그"
  ; "keeper_tasks_audit", "태스크 감사 고아 방치"
  ; "keeper_task_claim", "태스크 가져오기 할당"
  ; "keeper_task_create", "태스크 생성 만들기 일감"
  ; "keeper_task_done", "태스크 완료 마감"
  ; "keeper_task_submit_for_verification", "태스크 검증제출 리뷰요청 PR검토"
  ; "keeper_task_force_release", "태스크 강제해제 반환"
  ; "keeper_task_force_done", "태스크 강제완료"
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
  ; "masc_agents", "에이전트 목록 현황 누구"
  ; "masc_agent_update", "에이전트 업데이트 상태변경"
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
  ; "masc_claim_next", "다음태스크 가져오기 할당"
  ]

let tool_search_aliases name =
  let aliases =
    match List.assoc_opt name tool_search_alias_entries with
    | Some _ as found -> found
    | None ->
        (match Keeper_tool_alias.canonical_internal_name name with
         | Some canonical when not (String.equal canonical name) ->
             List.assoc_opt canonical tool_search_alias_entries
         | _ -> None)
  in
  match aliases with
  | Some aliases ->
      aliases
      |> String.split_on_char ' '
      |> List.filter (fun alias -> alias <> "")
  | None -> []

let tool_index_entry ~name ~description : Agent_sdk.Tool_index.entry =
  let group =
    Tool_catalog.tool_group name
    |> Option.map Tool_catalog.tool_group_to_string
  in
  let aliases = tool_search_aliases name in
  Agent_sdk.Tool_index.{ name; description; group; aliases }

let tool_index_entry_of_tool (t : Agent_sdk.Tool.t) : Agent_sdk.Tool_index.entry =
  tool_index_entry ~name:t.schema.name ~description:t.schema.description
