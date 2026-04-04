(** Keeper_agent_run — Run a single keeper turn via OAS Agent.run().

    Owns the full context lifecycle: checkpoint loading, context creation,
    base system prompt application, and message persistence.
    Callers provide domain-specific system prompt logic via
    [build_turn_prompt] callback.

    Uses {!Keeper_tools_oas} for tool wrapping and
    {!Keeper_hooks_oas} for lifecycle hooks (checkpoint, metrics, social).

    @since Phase 5 — Keeper Agent.run encapsulation *)

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] contains hard constraints (identity, policy guards,
    tool guidance, direct-reply mode) that must stay in the system prompt.
    [dynamic_context] contains soft context (continuity, skill route,
    worktree changes, turn instructions) injected via OAS
    [extra_system_context] — prepended as a User message after reduction. *)
type turn_prompt = {
  system_prompt : string;
  dynamic_context : string;
}

(** Result of a single Agent.run() keeper turn. *)
type run_result = {
  response_text : string;
  model_used : string;
  cascade_observation : Oas_worker.cascade_observation option;
  turn_count : int;
  tool_calls_made : int;
  usage : Agent_sdk.Types.api_usage;
  tools_used : string list;
  checkpoint : Agent_sdk.Checkpoint.t option;
  proof : Agent_sdk.Cdal_proof.t option;
  stop_reason : Oas_worker.stop_reason;
}

let keeper_tool_usage_snapshot ~base_path ~keeper_name : (string * int) list =
  Keeper_registry.tool_usage_of ~base_path keeper_name
  |> List.map (fun (tool_name, entry) -> (tool_name, entry.Keeper_types.count))
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)

let tool_usage_delta
    ~(before : (string * int) list)
    ~(after : (string * int) list) : string list =
  let before_counts = Hashtbl.create 16 in
  List.iter
    (fun (tool_name, count) -> Hashtbl.replace before_counts tool_name count)
    before;
  after
  |> List.concat_map (fun (tool_name, after_count) ->
         let before_count =
           Option.value ~default:0 (Hashtbl.find_opt before_counts tool_name)
         in
         List.init (max 0 (after_count - before_count)) (fun _ -> tool_name))

let merge_reported_and_observed_tool_names
    ~(reported_tool_names : string list)
    ~(observed_tool_names : string list) : string list =
  match observed_tool_names with
  | [] -> reported_tool_names
  | _ ->
      let observed = Hashtbl.create 16 in
      List.iter (fun tool_name -> Hashtbl.replace observed tool_name ()) observed_tool_names;
      observed_tool_names
      @ List.filter
          (fun tool_name -> not (Hashtbl.mem observed tool_name))
          reported_tool_names

let normalize_response_text
    ~(text : string)
    ~(tool_names : string list)
    () :
    (string, string) result =
  let trimmed = String.trim text in
  if trimmed <> "" then Ok text
  else
    match tool_names with
    | [] -> Error "keeper turn completed with no textual reply"
    | _ ->
        Ok
          (Printf.sprintf "Completed without a textual reply. Tools used: %s."
             (String.concat ", " tool_names))

let take n items =
  if n <= 0 then
    []
  else
    List.filteri (fun i _ -> i < n) items

let prioritized_disclosed_tool_names
    ~(max_tools : int)
    ~(always_include_tools : string list)
    ~(retrieved_names : string list)
    ~(fallback_tools : string list)
    ~(use_fallback : bool) : string list =
  let always_include_tools =
    Keeper_exec_tools.dedupe_tool_names always_include_tools
  in
  let retrieved_names =
    Keeper_exec_tools.dedupe_tool_names retrieved_names
  in
  let fallback_tools =
    Keeper_exec_tools.dedupe_tool_names fallback_tools
  in
  let seen = Hashtbl.create (max 16 max_tools) in
  let add_with_budget acc names =
    let remaining = max_tools - List.length acc in
    if remaining <= 0 then
      acc
    else
      let remaining = ref remaining in
      let added_rev = ref [] in
      List.iter (fun name ->
        if !remaining > 0 && not (Hashtbl.mem seen name) then begin
          Hashtbl.replace seen name ();
          decr remaining;
          added_rev := name :: !added_rev
        end
      ) names;
      acc @ List.rev !added_rev
  in
  let acc = add_with_budget [] always_include_tools in
  let acc = add_with_budget acc retrieved_names in
  if use_fallback then
    add_with_budget acc fallback_tools
  else
    acc

let log_keeper_proof ~(keeper_name : string) (proof : Agent_sdk.Cdal_proof.t) =
  let status_string =
    Agent_sdk.Cdal_proof.show_result_status proof.result_status
    |> fun raw ->
    match String.rindex_opt raw '.' with
    | Some idx when idx + 1 < String.length raw ->
        String.sub raw (idx + 1) (String.length raw - idx - 1)
    | _ -> raw
    |> String.lowercase_ascii
  in
  match proof.result_status with
  | Agent_sdk.Cdal_proof.Completed ->
      if Keeper_types_profile.keeper_debug then
        Log.Keeper.debug "keeper:%s proof: run_id=%s mode=%s status=%s evidence_refs=%d"
          keeper_name proof.run_id
          (Agent_sdk.Execution_mode.to_string proof.effective_execution_mode)
          status_string
          (List.length proof.raw_evidence_refs)
  | _ ->
      Log.Keeper.warn "keeper:%s proof: run_id=%s mode=%s status=%s evidence_refs=%d"
        keeper_name proof.run_id
        (Agent_sdk.Execution_mode.to_string proof.effective_execution_mode)
        status_string
        (List.length proof.raw_evidence_refs)

let log_keeper_contract_verdict
    ~(keeper_name : string)
    (verdict : Cdal_types.contract_verdict) =
  match verdict.status with
  | Cdal_types.Satisfied ->
      if Keeper_types_profile.keeper_debug then
        Log.Keeper.debug "keeper:%s contract_verdict: status=%s scope=%s hash=%s"
          keeper_name
          (Cdal_types.contract_status_to_string verdict.status)
          verdict.claim_scope
          verdict.judgment_hash
  | Cdal_types.Violated | Cdal_types.Inconclusive ->
      Log.Keeper.warn "keeper:%s contract_verdict: status=%s scope=%s hash=%s"
        keeper_name
        (Cdal_types.contract_status_to_string verdict.status)
        verdict.claim_scope
        verdict.judgment_hash

let log_keeper_friction
    ~(keeper_name : string)
    (fp : Cdal_friction_projection.friction_projection) =
  let blocked = fp.blocked_attempt_count in
  let groups = List.length fp.blocked_attempt_groups in
  let tripwires = List.length fp.review_tripwires in
  if tripwires > 0 then
    Log.Keeper.warn "keeper:%s friction: blocked=%d groups=%d tripwires=%d"
      keeper_name blocked groups tripwires
  else if blocked > 0 || groups > 0 then
    Log.Keeper.debug "keeper:%s friction: blocked=%d groups=%d tripwires=%d"
      keeper_name blocked groups tripwires
  else if Keeper_types_profile.keeper_debug then
    Log.Keeper.debug "keeper:%s friction: blocked=%d groups=%d tripwires=%d"
      keeper_name blocked groups tripwires

let log_keeper_memory_write
    ~(keeper_name : string)
    ~(notes_written : int)
    ~(kinds_written : string list) =
  if notes_written >= 10 then
    Log.Keeper.info "keeper:%s memory_write: %d notes, kinds=[%s]"
      keeper_name notes_written (String.concat "," kinds_written)
  else if Keeper_types_profile.keeper_debug then
    Log.Keeper.debug "keeper:%s memory_write: %d notes, kinds=[%s]"
      keeper_name notes_written (String.concat "," kinds_written)

(** Run a single keeper turn via OAS Agent.run().

    Loads checkpoint, creates working context with the base keeper system
    prompt, then calls [build_turn_prompt] with the base prompt and message
    history so the caller can layer skill routing, continuity context,
    policy guards, and turn-specific instructions on top.

    After the callback returns the final system prompt, appends the user
    message, builds OAS tools + hooks, and delegates to
    [Oas_worker.run_named] which internally calls Agent.run().

    @param config Room configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
    @param build_turn_prompt Callback: receives the base keeper system prompt
           and checkpoint message history, returns the final turn system prompt
    @param user_message The user's message to the keeper
    @param cascade_name Cascade profile name for model selection
    @param generation Current generation counter
    @param max_turns Maximum agent turns (default 50)
    @param guardrails Optional OAS guardrails for tool safety gates
    @param temperature MODEL temperature override; when omitted, resolved
           from [Cascade_inference] with a 0.3 fallback
    @param max_tokens Maximum output tokens override; when omitted, resolved
           from [Cascade_inference] with a 2048 fallback
    @param is_retry When [true], replays the current user message into the
           working context without persisting it again, so transient retry
           attempts do not duplicate the user entry in session history *)
let run_turn
    ~(config : Room.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(base_dir : string)
    ~(max_context : int)
    ~(build_turn_prompt :
        base_system_prompt:string ->
        messages:Agent_sdk.Types.message list ->
        turn_prompt)
    ~(user_message : string)
    ~(cascade_name : string)
    ~(generation : int)
    ?(max_turns : int = 50)
    ?(history_user_source = "direct_user")
    ?(history_assistant_source = "direct_assistant")
    ?guardrails
    ?temperature
    ?max_tokens
    ?max_cost_usd
    ?on_event
    ?(trajectory_acc : Trajectory.accumulator option)
    ?(tool_overlay : Agent_sdk.Tool_op.t ref option)
    ?_priority
    ?(is_retry = false)
    ()
  : (run_result, string) result =
  (* 0. Resolve inference parameters via Cascade_inference *)
  let temperature = match temperature with
    | Some t -> t
    | None ->
      Cascade_inference.resolve_temperature
        ~cascade_name
        ~fallback:(fun () -> 0.3)
  in
  let max_tokens = match max_tokens with
    | Some t -> t
    | None ->
      Cascade_inference.resolve_max_tokens
        ~cascade_name
        (* Keep under Cloudflare tunnel 100s timeout: 2048 / 35 tok/s ~ 59s *)
        ~fallback:(fun () -> 2048)
  in
  (* 1. Ensure session directory tree exists.
     Both the base traces dir AND the trace-specific session dir must
     exist before any file I/O (checkpoint load, history persist).
     In filesystem fallback mode (PG unavailable), these directories may
     not have been created by keeper_up if it only registered in-memory. *)
  let session_dir = Filename.concat base_dir meta.runtime.trace_id in
  Keeper_types.mkdir_p session_dir;
  (* 2. Load checkpoint *)
  let (session, ctx_opt) =
    Keeper_exec_context.load_context_from_checkpoint
      ~trace_id:meta.runtime.trace_id
      ~primary_model_max_tokens:max_context
      ~base_dir
  in
  (* 3. Build base system prompt from meta *)
  let persona_extended =
    Keeper_types_profile.load_persona_extended meta.name
    |> Option.value ~default:""
  in
  let base_system_prompt =
    Keeper_prompt.build_keeper_system_prompt
      ~goal:meta.goal
      ~short_goal:meta.short_goal
      ~mid_goal:meta.mid_goal
      ~long_goal:meta.long_goal
      ~soul_profile:meta.soul_profile
      ~will:meta.will
      ~needs:meta.needs
      ~desires:meta.desires
      ~instructions:meta.instructions
      ~persona_extended
      ()
  in
  (* 4. Create or restore working context, re-apply current prompt *)
  let base_ctx =
    match ctx_opt with
    | Some c -> c
    | None ->
      Keeper_exec_context.create
        ~system_prompt:base_system_prompt
        ~max_tokens:max_context
  in
  let ctx_work =
    Keeper_exec_context.set_system_prompt base_ctx
      ~system_prompt:base_system_prompt
  in
  (* 5. Build final turn system prompt via caller callback.
     Hard constraints stay in system_prompt; soft context is injected
     via OAS extra_system_context (prepended as User message after reduction). *)
  let { system_prompt = turn_system_prompt; dynamic_context } =
    build_turn_prompt
      ~base_system_prompt
      ~messages:ctx_work.messages
  in
  (* Defense in depth: unified prompt builders sanitize their own output,
     but run_turn is shared by other callers and is the final boundary before
     handing prompts/history to OAS. Keep this sanitization here even when
     upstream builders already cleaned their strings. *)
  let turn_system_prompt =
    Inference_utils.sanitize_text_utf8 turn_system_prompt
  in
  let user_message = Inference_utils.sanitize_text_utf8 user_message in
  (* 6. Append user message and persist.
     On retry (is_retry=true), the user message was already persisted by the
     first attempt.  Checkpoint reload does not include it (checkpoint is
     written only on success), so we still append to ctx — but skip persist
     to avoid duplicate entries in the session history file. *)
  let user_msg = Agent_sdk.Types.user_msg user_message in
  (* Capture history BEFORE appending the current user_msg.
     OAS Agent.run appends user_msg from ~goal internally, so passing it
     in initial_messages would cause duplication. *)
  let history_messages =
    Inference_utils.sanitize_messages_utf8 ctx_work.messages
  in
  let ctx_work = Keeper_exec_context.append ctx_work user_msg in
  if not is_retry then
    Keeper_exec_context.persist_message ~source:history_user_source session user_msg;
  (* 7. Set up agent *)
  let ctx_ref = ref ctx_work in
  let agent_name = Printf.sprintf "keeper-%s" meta.name in
  let meta_ref = ref meta in
  let agent_ref : Agent_sdk.Agent.t option ref = ref None in
  let keeper_tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_ref () in
  let extend_turns_tool = Keeper_extend_turns.make ~agent_ref ~max_turns () in
  let tools = extend_turns_tool :: keeper_tools in
  let tool_usage_before =
    keeper_tool_usage_snapshot ~base_path:config.base_path ~keeper_name:meta.name
  in
  (* Build BM25 tool index for progressive disclosure.
     Index uses **preset-scoped** universe (not the full 244+ universe)
     so BM25 searches a smaller, relevant candidate pool per preset.
     A Minimal keeper indexes ~30 tools instead of 244+, giving 66.7%
     visibility at top_k=20 instead of 8.2%.  See #4637.

     The dispatch-time tool set (keeper_tools / all_tool_names) still
     covers the full universe so externally-granted tools remain callable.

     top_k=20 (up from default 10) for better coverage.
     Group by prefix so co-retrieval pulls related tools together
     (e.g. matching keeper_board_post also retrieves keeper_board_comment).
     OAS Tool_index.build already supports group co-retrieval. *)
  let tool_index_config =
    { Agent_sdk.Tool_index.default_config with top_k = 20 } in
  (* Korean keyword aliases for bilingual BM25 matching.
     Tool descriptions are English; Korean users issue Korean queries.
     Appending Korean keywords gives BM25 term overlap across languages.
     Keys must match actual tool names from keeper_tools. *)
  let korean_keywords = [
    "keeper_board_post", "게시판 글 작성 올리기 포스트";
    "keeper_board_get", "게시판 글 읽기 조회 확인";
    "keeper_board_list", "게시판 목록 최근글";
    "keeper_board_comment", "게시판 댓글 답글 코멘트";
    "keeper_board_vote", "게시판 투표 추천 반대";
    "keeper_fs_read", "파일 읽기 소스코드 설정";
    "keeper_fs_edit", "파일 쓰기 편집 저장 수정 생성";
    "keeper_shell_readonly", "명령어 조회 검색 탐색";
    "keeper_bash", "명령어 실행 쉘 빌드 테스트";
    "keeper_github", "깃허브 이슈 풀리퀘스트 PR CI";
    "keeper_memory_search", "기억 검색 대화 이전 메시지";
    "keeper_library_search", "라이브러리 지식 문서 검색";
    "keeper_library_read", "라이브러리 문서 읽기 지식";
    "keeper_time_now", "시간 현재 타임스탬프";
    "keeper_context_status", "컨텍스트 상태 토큰 사용량";
    "keeper_tools_list", "도구 목록 기능 할수있는것 능력";
    "keeper_broadcast", "브로드캐스트 알림 공지 전달";
    "keeper_tasks_list", "태스크 목록 할일 백로그";
    "keeper_tasks_audit", "태스크 감사 고아 방치";
    "keeper_task_claim", "태스크 가져오기 할당";
    "keeper_task_done", "태스크 완료 마감";
    "keeper_task_force_release", "태스크 강제해제 반환";
    "keeper_task_force_done", "태스크 강제완료";
    "keeper_voice_speak", "음성 말하기 보이스";
    "keeper_voice_agent", "음성 설정 보이스";
    "keeper_voice_sessions", "음성 세션 목록";
    "keeper_voice_session_start", "음성 세션 시작";
    "keeper_voice_session_end", "음성 세션 종료";
    (* masc_* tools: Korean keywords for cross-language BM25 retrieval.
       Without these, Korean queries like "코드 검색" only match keeper_*
       tools that have Korean aliases, systematically deprioritizing
       masc_* tools.  See #4520. *)
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
    "masc_agent_card", "에이전트 카드 프로필 정보";
    "masc_agents", "에이전트 목록 현황 누구";
    "masc_agent_update", "에이전트 업데이트 상태변경";
    "masc_keeper_up", "키퍼 시작 기동 생성";
    "masc_keeper_down", "키퍼 중지 종료";
    "masc_keeper_list", "키퍼 목록 현황";
    "masc_keeper_msg", "키퍼 메시지 전달 대화";
    "masc_keeper_status", "키퍼 상태 확인";
    "masc_team_session_start", "팀 세션 병렬 작업 스웜 멀티 에이전트 시작";
    "masc_team_session_status", "팀세션 상태 현황";
    "masc_team_session_stop", "팀세션 중지 종료";
    "masc_team_session_step", "팀세션 단계 스텝 실행";
    "masc_worktree_create", "워크트리 생성 브랜치";
    "masc_worktree_list", "워크트리 목록 현황";
    "masc_worktree_remove", "워크트리 삭제 정리";
    "masc_tasks", "태스크 목록 할일 작업";
    "masc_add_task", "태스크 추가 등록 생성";
    "masc_status", "상태 현황 방 룸 요약";
    "masc_heartbeat", "하트비트 살아있음 생존";
    (* masc_broadcast, masc_who, masc_messages require MCP session context
       and fail in keeper. Use keeper_broadcast instead. (#4694) *)
  ] in
  let tool_entries = List.map (fun (t : Agent_sdk.Tool.t) ->
    let name = t.schema.name in
    let group =
      if String.starts_with ~prefix:"keeper_board_" name then Some "board"
      else if String.starts_with ~prefix:"keeper_memory_" name
           || String.starts_with ~prefix:"keeper_library_" name then Some "knowledge"
      else if String.starts_with ~prefix:"keeper_task" name then Some "tasks"
      else if String.starts_with ~prefix:"keeper_voice_" name then Some "voice"
      else if String.starts_with ~prefix:"keeper_fs_" name
           || name = "keeper_shell_readonly"
           || name = "keeper_bash"
           || name = "keeper_write" then Some "filesystem"
      else if name = "keeper_github" then Some "vcs"
      else if String.starts_with ~prefix:"masc_board_" name then Some "masc_board"
      else if String.starts_with ~prefix:"masc_keeper_" name then Some "masc_keeper"
      else if String.starts_with ~prefix:"masc_plan_" name then Some "masc_plan"
      else if String.starts_with ~prefix:"masc_team_session_" name then Some "masc_session"
      else if String.starts_with ~prefix:"masc_worktree_" name then Some "masc_worktree"
      else if String.starts_with ~prefix:"masc_code_" name then Some "masc_code"
      else if String.starts_with ~prefix:"masc_governance_" name then Some "masc_governance"
      else if String.starts_with ~prefix:"masc_autoresearch_" name then Some "masc_autoresearch"
      else if String.starts_with ~prefix:"masc_agent_" name
           || name = "masc_agents" then Some "masc_agent"
      else if String.starts_with ~prefix:"masc_" name then Some "masc_core"
      else None
    in
    let kr_kw = match List.assoc_opt name korean_keywords with
      | Some kw -> " " ^ kw
      | None -> ""
    in
    Agent_sdk.Tool_index.{ name; description = t.schema.description ^ kr_kw; group }
  ) keeper_tools in
  (* Preset-scoped BM25 index: only index tools within the keeper's preset
     universe, not the full 244+ universe.  This reduces noise and improves
     BM25 ranking quality.  See #4637. *)
  let preset_scoped_names =
    Keeper_exec_tools.keeper_preset_universe_tool_names meta
  in
  let scoped_tool_entries =
    List.filter (fun (e : Agent_sdk.Tool_index.entry) ->
      List.mem e.name preset_scoped_names
    ) tool_entries
  in
  let tool_index = Agent_sdk.Tool_index.build ~config:tool_index_config scoped_tool_entries in
  (* Visibility measurement (#4961): log universe size vs BM25 scope *)
  if Keeper_types_profile.keeper_debug then
    Log.Keeper.debug "keeper:%s tool visibility: total=%d preset_scoped=%d bm25_indexed=%d"
      meta.name
      (List.length tool_entries)
      (List.length preset_scoped_names)
      (List.length scoped_tool_entries);
  (* Layer 0: Core tools — always visible to the LLM regardless of preset.
     Kept to 5 survival-critical tools (#4961).  Other coordination tools
     (keeper_broadcast, keeper_task_claim, keeper_task_done, keeper_tasks_list,
     keeper_time_now, masc_tool_help) are now BM25-retrievable, freeing
     ranking budget for context-relevant tools. *)
  let always_include_tools = Keeper_exec_tools.core_always_tools in
  (* Layer 2: Universe — all tool names that the dispatch can handle.
     keeper_tools is now built from the universe (not just policy), so
     this includes all candidate tools minus denied.  BM25 retrieval
     and Tool_op.Add operate within this scope. *)
  let all_tool_names =
    "extend_turns"
    :: List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) keeper_tools
  in
  (* Layer 1: Policy fallback — when BM25 confidence is low, fall back
     to a capped subset of the preset-allowed tools.
     Full-preset keepers can have 300+ policy-allowed tools; sending all
     of them as fallback produces ~39K tokens which exceeds 8K model
     context windows.  Cap to max_fallback_tools, prioritizing keeper_*
     tools (preset-scoped, always relevant) then standard-tier MASC
     tools (coordination essentials).  See #4592. *)
  let policy_allowed =
    Keeper_exec_tools.keeper_allowed_tool_names !meta_ref
  in
  let max_tools_per_turn =
    if is_retry then Keeper_config.keeper_retry_max_tools_per_turn ()
    else Keeper_config.keeper_max_tools_per_turn ()
  in
  let max_fallback_tools = min 30 max_tools_per_turn in
  let fallback_tools =
    let candidates =
      List.filter (fun name ->
        not (List.mem name always_include_tools)
        && List.mem name policy_allowed
      ) all_tool_names
    in
    if List.length candidates <= max_fallback_tools then
      candidates
    else
      let keeper = List.filter (fun n ->
        String.starts_with ~prefix:"keeper_" n) candidates in
      let masc_std = List.filter (fun n ->
        String.starts_with ~prefix:"masc_" n
        && Tool_catalog_tiers.is_in_tier Extended n
      ) candidates in
      let merged = keeper @ masc_std in
      if List.length merged > max_fallback_tools then
        List.filteri (fun i _ -> i < max_fallback_tools) merged
      else merged
  in
  let confidence_threshold = 0.5 in
  (* Runtime tool overlay: external callers (masc_tool_grant/revoke)
     push Tool_op.t values here. The hook applies them each turn.
     If caller provides one, use it; otherwise create a local one. *)
  let tool_overlay_ref = match tool_overlay with
    | Some r -> r
    | None -> ref Agent_sdk.Tool_op.Keep_all
  in
  let base_hooks = Keeper_hooks_oas.make_hooks
    ~config ~meta_ref ~session ~ctx_ref ~generation ?max_cost_usd
    ?trajectory_acc
    () in
  (* Compose dynamic_context injection + progressive tool disclosure
     in a single before_turn_params hook.

     Both modifications return AdjustParams, so they must be in the
     same hook to avoid compose's outer-bypasses-inner semantics.

     Progressive disclosure uses BM25 retrieval: each turn selects
     the top-k tools most relevant to the current goal + context,
     plus always_include essentials. This keeps the LLM focused. *)
  let before_turn_hook : Agent_sdk.Hooks.hooks = {
    Agent_sdk.Hooks.empty with
    before_turn_params = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.BeforeTurnParams { turn; current_params; messages; _ } ->
        (* 1. Dynamic context injection *)
        let ctx =
          if String.trim dynamic_context = "" then
            current_params.extra_system_context
          else
            match current_params.extra_system_context with
            | None -> Some dynamic_context
            | Some existing -> Some (existing ^ "\n\n" ^ dynamic_context)
        in
        (* 2. Progressive tool disclosure via BM25 retrieval.
           Extract context from last user message for relevance scoring. *)
        let last_user_text =
          List.fold_left (fun acc (m : Agent_sdk.Types.message) ->
            match m.role with
            | Agent_sdk.Types.User ->
              Agent_sdk.Types.text_of_content m.content
            | _ -> acc
          ) "" messages
        in
        let query_text =
          if String.trim last_user_text <> "" then last_user_text
          else user_message
        in
        (* Confidence-gated union: always retrieve, but union fallback
           when BM25 confidence is low (e.g. Korean query vs English docs).
           Partial retrieval results are always kept — never discarded. *)
        let retrieved = Agent_sdk.Tool_index.retrieve tool_index query_text in
        let top_score = match retrieved with
          | (_, s) :: _ -> s
          | [] -> 0.0
        in
        let use_fallback = top_score < confidence_threshold in
        let max_tools = max_tools_per_turn in
        (* Tool_portal pruned — no visibility filtering *)
        let visible_always_include_tools = always_include_tools in
        let retrieved_names = List.map fst retrieved in
        let selected_tools =
          prioritized_disclosed_tool_names
            ~max_tools
            ~always_include_tools:visible_always_include_tools
            ~retrieved_names
            ~fallback_tools
            ~use_fallback
        in
        let all_allowed =
          Agent_sdk.Tool_op.apply
            (Agent_sdk.Tool_op.compose [
              Agent_sdk.Tool_op.Replace_with selected_tools;
              !tool_overlay_ref;
            ])
            all_tool_names
        in
        if Keeper_types_profile.keeper_debug then
          Log.Keeper.info
            "tool_disclosure keeper=%s top_score=%.3f retrieved=%d allowed=%d fallback=%b query_len=%d"
            meta.name top_score (List.length retrieved_names)
            (List.length all_allowed) use_fallback (String.length query_text);
        (* 3. Graceful last-turn: inject budget warnings and restrict
           tools when approaching the turn limit.
           - Warning zone (2 turns before limit): inject budget warning
           - Last turn (1 turn before limit): restrict to safe tools + force [STATE]
           The keeper can still call extend_turns to escape the limit. *)
        let is_last_turn = turn >= max_turns - 1 in
        let is_warning_zone = turn >= max_turns - 2 in
        let ctx =
          if is_last_turn then
            let warning =
              Printf.sprintf
                "[LAST TURN] Turn %d/%d. This is your final turn. \
                 You MUST emit a [STATE]...[/STATE] block now summarizing \
                 what you accomplished and what the next generation should do. \
                 Do NOT start new tool work. If you need more turns, call extend_turns."
                turn max_turns
            in
            (match ctx with
             | None -> Some warning
             | Some existing -> Some (existing ^ "\n\n" ^ warning))
          else if is_retry then
            let warning =
              Printf.sprintf
                "[RETRY] The previous attempt overflowed the model context. \
                 Stay concise, prefer already-loaded context, and only use the \
                 smallest essential tool set if a tool call is strictly necessary. \
                 Current tool budget: %d."
                max_tools
            in
            (match ctx with
             | None -> Some warning
             | Some existing -> Some (existing ^ "\n\n" ^ warning))
          else if is_warning_zone then
            let warning =
              Printf.sprintf
                "[BUDGET] %d/%d turns used. Wrap up current work and emit \
                 a [STATE] block. Call extend_turns if you need more time."
                turn max_turns
            in
            (match ctx with
             | None -> Some warning
             | Some existing -> Some (existing ^ "\n\n" ^ warning))
          else ctx
        in
        let safe_last_turn_tools =
          [ "keeper_board_post"; "keeper_board_comment";
            "keeper_context_status"; "extend_turns";
            "keeper_time_now"; "keeper_broadcast" ]
        in
        let all_allowed =
          if is_last_turn then
            Agent_sdk.Tool_op.apply
              (Agent_sdk.Tool_op.Intersect_with safe_last_turn_tools)
              all_allowed
          else all_allowed
        in
        if is_warning_zone then
          Log.Keeper.info
            "keeper:%s turn_budget turn=%d/%d last_turn=%b"
            meta.name turn max_turns is_last_turn;
        (* Context overflow guard: tool disclosure is first budgeted via
           prioritized_disclosed_tool_names, then overlays can still grow the
           visible set. Cap the post-overlay set to stay inside small-model
           context windows. Configurable via MASC_KEEPER_MAX_TOOLS_PER_TURN. *)
        let all_allowed =
          if List.length all_allowed > max_tools then begin
            Log.Keeper.info
              "context overflow guard: %d tools > max %d, truncating"
              (List.length all_allowed) max_tools;
            let essential = List.filter
              (fun name -> List.mem name visible_always_include_tools) all_allowed in
            let non_essential = List.filter
              (fun name -> not (List.mem name visible_always_include_tools)) all_allowed in
            let budget = max_tools - List.length essential in
            (* Sort non-essential by BM25 score descending so the most
               relevant tools survive truncation.  Tools not in the
               retrieved set (e.g. fallback) get score 0.0. *)
            let score_of name =
              match List.assoc_opt name retrieved with
              | Some s -> s
              | None -> 0.0
            in
            let sorted = List.stable_sort
              (fun a b -> compare (score_of b) (score_of a))
              non_essential in
            essential @ (List.filteri (fun i _ -> i < budget) sorted)
          end else
            all_allowed
        in
        let tool_filter = Agent_sdk.Guardrails.AllowList all_allowed in
        (* Yield after CPU-bound tool filtering to let HTTP handlers run.
           Without this, N concurrent keeper fibers starve the Eio scheduler
           during turn setup (tool list construction + prompt building). *)
        Eio.Fiber.yield ();
        Agent_sdk.Hooks.AdjustParams
          { current_params with
            extra_system_context = ctx;
            tool_filter_override = Some tool_filter }
      | _ -> Agent_sdk.Hooks.Continue)
  } in
  let hooks =
    Agent_sdk.Hooks.compose ~outer:before_turn_hook ~inner:base_hooks
  in
  let base_dir = Filename.concat config.base_path ".masc" in
  let memory =
    Memory_oas_bridge.create_memory_full
      ~agent_name
      ~base_dir
      ~session_id:meta.runtime.trace_id
      ~config
      ~episode_limit:30
      ~procedure_limit:10
      ~global_procedure_limit:5
      ()
  in
  let reducer = Agent_sdk.Context_reducer.compose [
    Agent_sdk.Context_reducer.keep_last 30;
    Agent_sdk.Context_reducer.clear_tool_results ~keep_recent:2;
    Agent_sdk.Context_reducer.merge_contiguous;
    (* max_context = model's input context window (e.g., 8192 for 8K models).
       max_tokens = output generation limit (e.g., 2048).
       The reducer needs the context window, not the output budget. *)
    Agent_sdk.Context_reducer.from_context_config ~max_tokens:max_context ();
  ] in
  (* 8. Run Agent *)
  let contract =
    if Env_config.Cdal.enabled ()
    then Keeper_cdal_contract.of_keeper_meta meta
    else None
  in
  let yield_on_tool = Env_config.Slot.yield_enabled () in
  let on_yield = if yield_on_tool then Some (fun () ->
    Log.Misc.debug "keeper %s: slot yielded (tool execution)" meta.name
  ) else None in
  let on_resume = if yield_on_tool then Some (fun () ->
    Log.Misc.debug "keeper %s: slot resumed (next LLM turn)" meta.name
  ) else None in
  match
        Oas_worker.run_named
          ~cascade_name
          ~goal:user_message
          ~session_id:meta.runtime.trace_id
          ~system_prompt:turn_system_prompt
          ~tools
          ~initial_messages:history_messages
          ~hooks
          ~context_reducer:reducer
          ~memory
          ~tool_retry_policy:Oas.Tool_retry_policy.default_internal
          ~max_turns
          ~max_idle_turns:5
          ~temperature
          ~max_tokens
          ?guardrails
          ?on_event
          ?on_yield
          ?on_resume
          ~agent_ref
          ?contract
          ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta)
          ~cache_system_prompt:true
          ~yield_on_tool
          ()
      with
      | Error e -> Error e
      | Ok result ->
        (match result.checkpoint with
         | Some checkpoint -> (
             try
               (* Unify session_id to trace_id so load_oas can find this
                  checkpoint on the next turn. oas_worker generates a per-turn
                  session_id that differs from trace_id, causing a load miss. *)
               let checkpoint =
                 { checkpoint with Agent_sdk.Checkpoint.session_id = meta.runtime.trace_id }
               in
               Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir
                 checkpoint
             with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
                 Log.Keeper.error "keeper:%s OAS checkpoint save failed: %s"
                   meta.name (Printexc.to_string exn))
         | None ->
             Log.Keeper.warn "keeper:%s missing OAS checkpoint after run"
               meta.name);
        let _flushed = Memory_oas_bridge.flush_all ~memory ~agent_name in
        let text = Agent_sdk.Types.text_of_content result.response.content in
        let model = result.response.model in
        let reported_tool_names =
          List.filter_map (function
            | Agent_sdk.Types.ToolUse { name; _ } -> Some name | _ -> None)
            result.response.content
        in
        let tool_usage_after =
          keeper_tool_usage_snapshot ~base_path:config.base_path
            ~keeper_name:meta.name
        in
        let observed_tool_names =
          tool_usage_delta ~before:tool_usage_before ~after:tool_usage_after
        in
        let tool_names =
          merge_reported_and_observed_tool_names
            ~reported_tool_names ~observed_tool_names
        in
        let usage = Keeper_exec_context.usage_of_response result.response in
        (match normalize_response_text ~text ~tool_names () with
         | Error e -> Error e
         | Ok response_text ->
             (* Ensure every generation has a [STATE] block for continuity.
                If the model omitted it, synthesize one deterministically
                from tool usage and stop reason. *)
             let response_text =
               match Keeper_memory_policy.find_state_block response_text with
               | Some _ -> response_text
               | None ->
                 let stop_reason_str =
                   match result.stop_reason with
                   | Oas_worker.Completed -> "completed"
                   | Oas_worker.TurnBudgetExhausted _ -> "budget_exhausted"
                 in
                 let synth =
                   Keeper_memory_policy.synthesize_state_from_run_result
                     ~goal:meta.goal
                     ~tools_used:tool_names
                     ~stop_reason:stop_reason_str
                     ~response_text
                 in
                 let block = Keeper_memory_policy.render_state_block synth in
                 Log.Keeper.info
                   "keeper:%s [STATE] missing, synthesized from %d tools (stop=%s)"
                   meta.name (List.length tool_names) stop_reason_str;
                 response_text ^ "\n" ^ block
             in
             let assistant_msg = Agent_sdk.Types.assistant_msg response_text in
             Keeper_exec_context.persist_message
               ~source:history_assistant_source
               session assistant_msg;
             ctx_ref := Keeper_exec_context.append !ctx_ref assistant_msg;
             (match result.proof with
             | Some p ->
                log_keeper_proof ~keeper_name:meta.name p;
                let store = Agent_sdk.Proof_store.default_config in
                let outcome = Cdal_eval_v1.evaluate ~store p in
                let verdict = Cdal_eval_v1.verdict_of_outcome outcome in
                Cdal_eval_v1.persist verdict;
                log_keeper_contract_verdict ~keeper_name:meta.name verdict;
                (match outcome with
                 | Cdal_eval_v1.Load_failure (err, _) ->
                   Log.Keeper.warn "keeper:%s contract_verdict load failure: %s"
                     meta.name (Cdal_loader.load_error_to_string err)
             | Cdal_eval_v1.Verdict (_, _) -> ());
            (match Cdal_eval_v1.friction_of_outcome outcome with
             | Some fp ->
               log_keeper_friction ~keeper_name:meta.name fp
             | None -> ())
          | None -> ());
         (* Post-turn deterministic memory write.
            Uses meta-based fallback when [STATE] parsing fails.
            See RFC #3646 Section 3: Det/NonDet boundary. *)
         (try
           let (notes_written, kinds_written) =
             Keeper_memory_bank.append_memory_notes_from_reply
               config meta ~turn:result.turns ~reply:response_text
           in
           if notes_written > 0 then
             log_keeper_memory_write
               ~keeper_name:meta.name
               ~notes_written
               ~kinds_written
         with
         | exn ->
           Log.Keeper.warn "keeper:%s memory_write failed: %s"
             meta.name (Printexc.to_string exn));
         Ok {
           response_text;
           model_used = model;
           cascade_observation = result.cascade_observation;
           turn_count = result.turns;
           tool_calls_made = List.length tool_names;
           usage;
           tools_used = tool_names;
           checkpoint = result.checkpoint;
           proof = result.proof;
           stop_reason = result.stop_reason;
         })
