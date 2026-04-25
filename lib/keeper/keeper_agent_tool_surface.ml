(** Tool-surface gating, selection constants, and backlog task reconciliation. *)

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

type tool_surface_metrics =
  { turn_lane : string
  ; tool_surface_class : string
  ; tool_requirement : string
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  ; required_tool_names : string list
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
  ; deterministic_prefilter_count : int
  ; discovered_count : int
  ; llm_selected_count : int
  ; selection_mode : string
  ; is_last_turn : bool
  ; is_warning_zone : bool
  ; tool_surface_class : string
  ; tool_requirement : string
  ; tool_gate_requested : bool
  ; tool_surface_fallback_used : bool
  ; required_tool_names : string list
  ; missing_required_tool_names : string list
  ; lane : string
  ; query_text : string
  }

type turn_affordance =
  | Board_post_or_comment
  | Message_sweep
  | Reply_in_room
  | Task_claim
  | Task_audit
  | Task_verify
  | Work_discovery
  | Inspect_worktree_delta

let turn_affordance_of_string = function
  | "board_post_or_comment" -> Some Board_post_or_comment
  | "message_sweep" -> Some Message_sweep
  | "reply_in_room" -> Some Reply_in_room
  | "task_claim" -> Some Task_claim
  | "task_audit" -> Some Task_audit
  | "task_verify" -> Some Task_verify
  | "work_discovery" -> Some Work_discovery
  | "inspect_worktree_delta" -> Some Inspect_worktree_delta
  | _ -> None

let should_tool_gate_affordance = function
  | Board_post_or_comment
  | Message_sweep
  | Reply_in_room
  | Task_claim
  | Task_audit
  | Task_verify
  | Work_discovery
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
   contract for that affordance and must be allowed to respond with
   text instead. *)
let tools_for_gated_affordance = function
  | Board_post_or_comment ->
    [ "keeper_board_post"; "keeper_board_comment"; "masc_broadcast" ]
  | Message_sweep ->
    [ "keeper_messages_read"; "masc_messages"; "keeper_keeper_msg" ]
  | Reply_in_room ->
    [ "keeper_board_post"; "keeper_board_comment";
      "masc_keeper_msg"; "masc_broadcast" ]
  | Task_claim ->
    [ "keeper_task_claim"; "masc_claim_next"; "masc_claim_task" ]
  | Task_audit ->
    [ "keeper_tasks_audit"; "keeper_tasks_list"; "masc_tasks" ]
  | Task_verify ->
    [ "keeper_tasks_list"; "keeper_tasks_audit";
      "keeper_task_done"; "keeper_task_submit_for_verification";
      "masc_transition" ]
  | Work_discovery ->
    [ "keeper_task_claim"; "masc_claim_next";
      "keeper_board_post"; "masc_add_task";
      "keeper_tasks_audit" ]
  | Inspect_worktree_delta ->
    [ "keeper_shell"; "keeper_bash"; "masc_code_git";
      "keeper_fs_read" ]

(* Filtered variant of [turn_affordances_require_tool_gate]:  a gated
   affordance only counts when the keeper actually has a tool that can
   satisfy it.  Without this filter, presets such as [social] (which
   excludes claim/execution tools) get [Require_tool_use] forced on
   them whenever the board lists unclaimed tasks, leading to repeated
   [Failure_run_error] turns the keeper cannot resolve. *)
let turn_affordances_require_tool_gate_with_allowed
    ~(allowed_tool_names : string list) turn_affordances : bool =
  let has_matching_tool affordance =
    List.exists
      (fun tool -> List.mem tool allowed_tool_names)
      (tools_for_gated_affordance affordance)
  in
  List.exists
    (function
      | Some affordance ->
        should_tool_gate_affordance affordance
        && has_matching_tool affordance
      | None -> false)
    (List.map turn_affordance_of_string turn_affordances)

let should_require_tools_for_initial_turn ~(max_turns : int)
    ~(turn_affordances : string list) =
  let initial_per_call_turn = 1 in
  let initial_turn_is_last = initial_per_call_turn >= max_turns in
  max_turns > 1
  && not initial_turn_is_last
  && turn_affordances_require_tool_gate turn_affordances

let has_turn_affordance expected turn_affordances =
  List.exists
    (fun affordance ->
       match turn_affordance_of_string affordance with
       | Some affordance -> affordance = expected
       | None -> false)
    turn_affordances

let has_task_claim_affordance = has_turn_affordance Task_claim

let preferred_tool_choice_for_required_turn ~(has_current_task : bool)
    ~(turn_affordances : string list) ~(allowed_tool_names : string list) =
  if (not has_current_task)
     && has_task_claim_affordance turn_affordances
     && List.mem "keeper_task_claim" allowed_tool_names
  then Oas.Types.Tool "keeper_task_claim"
  else if has_turn_affordance Task_audit turn_affordances
          && List.mem "keeper_tasks_audit" allowed_tool_names
  then Oas.Types.Tool "keeper_tasks_audit"
  else if has_turn_affordance Task_verify turn_affordances
          && List.mem "keeper_tasks_list" allowed_tool_names
  then Oas.Types.Tool "keeper_tasks_list"
  else if not has_current_task then
    (* #10008: no active task and no applicable specific claim tool
       to force.  Fall back to [Auto] instead of [Any] so the model
       can respond with an honest refusal ("no eligible task to
       claim", "no matching affordance to exercise") without
       triggering the [Require_tool_use] contract violation.  The
       caller ([Keeper_agent_run]) reads [tool_choice = Auto] as
       "MASC dropped the specific-tool demand" and relaxes the
       completion contract to [Allow_text_or_tool].  Otherwise the
       affordance-driven gate would self-contradict — force a tool
       call when no applicable tool exists. *)
    Oas.Types.Auto
  else
    (* Active task in progress: keep the strict gate.  The keeper is
       expected to make progress via some tool call (board update,
       task_update, task_done, etc.). *)
    Oas.Types.Any

let owned_active_task_id_for_meta ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta) =
  match meta.current_task_id with
  | Some task_id -> Some task_id
  | None ->
    let actual_name =
      try Coord.resolve_agent_name config meta.agent_name
      with
      | Sys_error _ | Yojson.Json_error _ -> meta.agent_name
      | exn ->
        Log.Keeper.warn
          "keeper:%s resolve_agent_name failed while reconciling current task: %s"
          meta.name (Printexc.to_string exn);
        meta.agent_name
    in
    let matches assignee =
      String.equal assignee meta.agent_name || String.equal assignee actual_name
    in
    (try
       Coord.get_tasks_raw config
       |> List.find_map (fun (task : Types.task) ->
            match task.task_status with
            | Types.Claimed { assignee; _ }
            | Types.InProgress { assignee; _ }
            | Types.AwaitingVerification { assignee; _ }
              when matches assignee -> (
                match Keeper_id.Task_id.of_string task.id with
                | Ok task_id -> Some task_id
                | Error msg ->
                  Log.Keeper.warn
                    "keeper:%s owned task %s could not be parsed: %s"
                    meta.name task.id msg;
                  None)
            | Types.Claimed _
            | Types.InProgress _
            | Types.AwaitingVerification _
            | Types.Todo
            | Types.Done _
            | Types.Cancelled _ -> None)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn
         "keeper:%s owned task reconciliation failed: %s"
         meta.name (Printexc.to_string exn);
       None)
;;

let merge_current_task_id ~(latest : Keeper_types.keeper_meta)
    ~(caller : Keeper_types.keeper_meta) =
  {
    latest with
    current_task_id = caller.current_task_id;
    updated_at = caller.updated_at;
  }
;;

let sync_current_task_id_from_backlog ~(config : Coord.config)
    (meta : Keeper_types.keeper_meta) =
  match meta.current_task_id with
  | Some _ -> meta
  | None -> (
    match owned_active_task_id_for_meta ~config ~meta with
    | None -> meta
    | Some task_id ->
      let updated_meta =
        {
          meta with
          current_task_id = Some task_id;
          updated_at = Types.now_iso ();
        }
      in
      Keeper_registry.update_meta ~base_path:config.base_path meta.name updated_meta;
      (match
         Keeper_types.write_meta_with_merge
           ~merge:merge_current_task_id config updated_meta
       with
       | Ok () -> ()
       | Error msg ->
         Log.Keeper.warn
           "keeper:%s failed to persist reconciled current_task_id=%s: %s"
           meta.name (Keeper_id.Task_id.to_string task_id) msg);
      Log.Keeper.info
        "keeper:%s reconciled current_task_id=%s from backlog ownership"
        meta.name (Keeper_id.Task_id.to_string task_id);
      updated_meta)
;;

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
  tool_names Tool_name.[ Keeper Fs_read; Keeper Shell; Keeper Bash ]

let is_claim_tool_name name =
  Keeper_tool_disclosure.is_claim_tool_name name

let is_claim_context_tool_name name =
  Keeper_tool_disclosure.is_claim_context_tool_name name

(* Tool selection & disclosure — extracted to Keeper_tool_disclosure (#5732) *)

(* Deterministic selection floor size: keep the executable surface small
   enough for prompt budgets while still surfacing a handful of relevant
   tools even before any LLM hinting lands. *)
let keeper_selection_top_k = 10

(* BM25 candidate pool for TopK_llm: wide enough to give reranking room to
   improve results, but still bounded and deterministic. *)
let keeper_selection_bm25_prefilter_n = 30

(* Bilingual BM25 aliases for keeper tool search.  Keep this beside the
   production Tool_index entry builder so tests cannot drift by copying a
   second alias/group table. *)
let tool_search_alias_entries =
  [ "keeper_board_post", "게시판 글 작성 올리기 포스트"
  ; "keeper_board_get", "게시판 글 읽기 조회 확인"
  ; "keeper_board_list", "게시판 목록 최근글"
  ; "keeper_board_comment", "게시판 댓글 답글 코멘트"
  ; "keeper_board_vote", "게시판 투표 추천 반대"
  ; "keeper_board_search", "게시판 검색 키워드 글찾기"
  ; "keeper_board_delete", "게시판 삭제 제거 글삭제"
  ; "keeper_board_stats", "게시판 통계 활동 참여 게시글수"
  ; "keeper_stay_silent", "침묵 대기 아무것도 안함 넘어가기"
  ; "keeper_tool_search", "도구 검색 발견 찾기 어떤도구"
  ; "keeper_voice_listen", "음성 듣기 마이크 녹음 입력"
  ; "keeper_fs_read", "파일 읽기 소스코드 설정"
  ; "keeper_fs_edit", "파일 쓰기 편집 저장 수정 생성"
  ; "keeper_shell", "명령어 조회 검색 탐색 gh github pull request issue pr ci draft 생성 풀리퀘스트 이슈"
  ; "keeper_bash", "명령어 실행 쉘 빌드 테스트 git add commit push"
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
  ; "masc_code_search", "코드 검색 소스코드 찾기 심볼"
  ; "masc_code_read", "코드 읽기 파일 소스코드"
  ; "masc_code_edit", "코드 편집 수정 파일 변경"
  ; "masc_code_write", "코드 작성 파일 생성 쓰기"
  ; "masc_code_symbols", "코드 심볼 함수 클래스 정의"
  ; "masc_code_shell", "코드 명령어 쉘 실행"
  ; "masc_code_git", "깃 커밋 브랜치 로그 이력"
  ; "masc_autoresearch_start", "자동연구 리서치 시작"
  ; "masc_autoresearch_status", "자동연구 리서치 상태"
  ; "masc_autoresearch_stop", "자동연구 리서치 중지"
  ; "masc_autoresearch_cycle", "자동연구 리서치 사이클 실행"
  ; "masc_plan_get", "계획 플랜 마일스톤 로드맵 프로젝트 전략"
  ; "masc_plan_update", "계획 플랜 수정 업데이트"
  ; "masc_plan_init", "계획 플랜 초기화 생성"
  ; "masc_plan_set_task", "계획 태스크 설정 할당"
  ; "masc_plan_get_task", "계획 태스크 조회"
  ; "masc_agent_card", "에이전트 카드 프로필 정보"
  ; "masc_agents", "에이전트 목록 현황 누구"
  ; "masc_agent_update", "에이전트 업데이트 상태변경"
  ; "masc_keeper_list", "키퍼 목록 현황"
  ; "masc_keeper_msg", "키퍼 메시지 전달 대화"
  ; "masc_keeper_status", "키퍼 상태 확인"
  ; "masc_worktree_create", "워크트리 생성 브랜치 격리 작업공간"
  ; "masc_worktree_list", "워크트리 목록 현황"
  ; "masc_worktree_remove", "워크트리 삭제 정리"
  ; "masc_tasks", "태스크 목록 할일 작업"
  ; "masc_add_task", "태스크 추가 등록 생성"
  ; "masc_status", "상태 현황 방 룸 요약"
  ; "masc_dashboard", "대시보드 현황 대시 보드 개요"
  ; "masc_plan_clear_task", "계획 태스크 제거 해제 클리어"
  ; "masc_agent_fitness", "에이전트 평가 점수 피트니스"
  ; "masc_web_search", "웹 검색 인터넷 온라인 구글"
  ; "masc_claim_next", "다음태스크 가져오기 할당"
  ]

let tool_search_aliases name =
  match List.assoc_opt name tool_search_alias_entries with
  | Some aliases ->
      aliases
      |> String.split_on_char ' '
      |> List.filter (fun alias -> alias <> "")
  | None -> []

let tool_index_entry ~name ~description : Oas.Tool_index.entry =
  let group =
    Tool_catalog.tool_group name
    |> Option.map Tool_catalog.tool_group_to_string
  in
  let aliases = tool_search_aliases name in
  Oas.Tool_index.{ name; description; group; aliases }

let tool_index_entry_of_tool (t : Oas.Tool.t) : Oas.Tool_index.entry =
  tool_index_entry ~name:t.schema.name ~description:t.schema.description
