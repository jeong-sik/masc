(* The words more than one screen says, in both languages, in one table
   (RFC-tui-one-screen-grammar section 7.1: one concept is one word). It
   depends on nothing, so every renderer can say them; [Masc_tui_types]
   includes it. *)

(* What a title says where its counts would go. A read nobody has asked for and a
   read that failed both leave the snapshot empty, and the title is the row on
   top, so it is the answer that gets read: "not loaded" after a failure sends
   the operator to [r] while the server's reason sits in red two rows below.

   The same distinction the body makes with
   [Masc_tui_types.page_unread_note] and [Masc_tui_types.page_failed_note],
   in the words a title has room for. The Memory header was
   taught it in #35457; every other surface still said "not loaded" for both. *)
(* A title has no label to hang the words on, so it brackets them: the
   parentheses are what says "this is the state of the reading, not a count".
   A labelled field already says that with its label, and the brackets inside
   one cost two cells on the keeper chat header -- the narrowest row the TUI
   draws, which at 120 columns beside the roster has none to spare. Both
   spellings come from here so the words stay one. *)
let field_unread ~ko = if ko then "미조회" else "not loaded"
let title_unread ~ko = "(" ^ field_unread ~ko ^ ")"
(* The same pair one layer down. A title brackets its words because it has no
   label to hang them on; a labelled field does not, and said so already for
   the unread half. The failed half had no name here, so the Memory header
   spelled the title's words itself, minus the brackets -- the one place in
   the TUI that decided what a field says after a failed read. *)
let field_failed ~ko = if ko then "조회 실패" else "load failed"
let title_failed ~ko = "(" ^ field_failed ~ko ^ ")"

(* A reading kept from before a refresh that failed.
   The Runtime probe column and the Metrics Memory and Gate rows draw
   it; the fleet line still spells the same pair itself. *)
let field_stale ~ko = if ko then "이전 관측" else "stale"

(* A span that has passed, after its value: "3m 전", "3m ago" (RFC section
   6.2). *)
let span_ago ~ko span = span ^ if ko then " 전" else " ago"

(* The workspace the server serves, named where the TUI cannot confirm it:
   the identity was not read, the latest read did not match again, or the
   server is not ready to say ([server_authority_ready]). A request that
   needs it is kept back, and rows read before it say so, in these words.
   They are lower case for the middle of a row; a row that starts with one
   capitalises it in English, as its neighbours do. *)
let workspace_name ~ko = if ko then "워크스페이스" else "workspace"
let field_unconfirmed ~ko = if ko then "확인 안 됨" else "unconfirmed"
let workspace_identity_name ~ko = workspace_name ~ko ^ if ko then " 식별" else " identity"
let workspace_identity_unconfirmed ~ko =
  workspace_identity_name ~ko ^ " " ^ field_unconfirmed ~ko
let workspace_identity_unread ~ko = workspace_identity_name ~ko ^ " " ^ field_unread ~ko

(* The workspace the TUI resolved is not the one the server serves. *)
let field_mismatch ~ko = if ko then "불일치" else "mismatch"
let workspace_mismatch ~ko = workspace_name ~ko ^ " " ^ field_mismatch ~ko

(* What a send the TUI kept back did not do, and what stayed where it was. A
   refusal reads reason · not sent · what was kept, in these words on every
   screen that refuses one. *)
let not_sent ~ko = if ko then "보내지 않음" else "not sent"
let draft_retained ~ko = if ko then "초안 남아 있음" else "draft retained"
let queued_input_retained ~ko = if ko then "대기 입력 남아 있음" else "queued input retained"

(* What stays when a request is kept back: a message, a post, a comment or a
   Keeper declaration keeps its draft, a queued run keeps its input, and a
   decision or a vote has nothing to keep. *)
type kept = Draft_kept | Queued_input_kept | Nothing_kept

(* Which request a kept-back notice is about, so several notices in "show all
   notices" say which is which (RFC section 2). A chat command is named as
   the operator typed it. *)
module Kept_request = struct
  type t =
    | Command of string
    | Message
    | Board_post
    | Board_comment
    | Board_vote
    | Tool_approval
    | Gate_decision
    | Auto_judge_retry
    | Approval_decision
    | Ask_answer
    | Ask_source
    | Task_cancel
    | Keeper_action
    | Keeper_creation
    | Keeper_deletion
    | Account_login
    | Goal_transition
    | Schedule_cancel
    | Schedule_change
    | Skill_evidence
    | Report_check
    | Addon_request
    | Volume_report
    | Volume_reclaim
    | Original_save
    | Report_open
    | Msx_screen_read
    | Dos_screen_read
    | Runtime_config_read
    | Runtime_params_read
    | Preset_list_read
    | Preset_read
    | Preset_restore
    | Preset_delete
    | Play_invite_list_read
    | Play_invite_issue
    | Play_invite_revoke
    | Play_room_read
    | Play_room_message
    | Play_room_leave
    | Addon_read
    | Runtime_surface_read
    | Lanes_read
    | Memory_input_read
    | Keeper_turns_read
    | Memory_health_read
    | Machine_activity_read
    | Machine_activity_save
    | Exact_activity_read
    | Exact_activity_save
    | Fusion_launch
    | Board_post_read
    | Verification_read
    | Evidence_export
    | Lane_write
    | Goal_confirmation_read
    | Runtime_param_write
    | Task_creation
    | Task_creation_read
    | Native_tasks_read
    | Child_content_read
    | Keeper_history_read
    | Keeper_memory_read
    | Keeper_older_read
    | Keeper_reply_read
    | Connector_unbind
    | Keeper_settings_read
    | Preset_save
    | Runtime_config_save
    | Keeper_settings_save
    | Keeper_deletions_read
    | Msx_load
    | Msx_disk_change
    | Msx_control
    | Msx_checkpoint
    | Msx_restore
    | Msx_key
    | Resource_list_read
    | Resource_read
    | Resource_share
    | Voice_probe
    | Voice_setup_save
    | Agent_voice_save
    | Keeper_operation_read
    | Keeper_journal_read
    | Msx_carts_read
    | Verification_verdict
    | Connector_bind
    | Connector_binding_edit
    | Harness_label
    | Skill_sources_read
    | Skill_creation
    | Skill_read
    | Skill_preview
    | Skill_save
    | Skill_delete
    | Prompt_save
    | Prompt_clear
    | Repository_add
    | Github_token_save
    | Github_login
    | Confirmations_read
    | Questions_read
    | Report_checks_read
    | Preparation_read
    | Waiting_list_read
    | Turn_observation_read
    | Tool_inventory_read
    | Skill_catalog_read
    | Skill_activations_read
    | Skill_usage_read
    | Async_requests_read
    | Async_request_read
    | Original_task_read
    | Task_history_read
    | Schedule_read
    | Wake_history_read
    | Call_log_read
    | Call_read
    | Attachment_read
    | Goal_candle_read
    | Goal_timeline_read
    | Efficiency_read
    | Connector_list_read
    | Browser_history_read
    | Memory_activity_read
    | Memory_facts_read
    | File_changes_read
    | Fusion_read
    | Memory_world_read
    | Verification_evidence_read
    | Sandbox_read
    | Keeper_relationship_read
    | Image_read
    | Gate_mode_change
    | Tool_modes_read
    | Tool_mode_change
    | Board_requeue
    | Service_switch
    | Service_app_save
    | Service_login
    | Service_refresh
    | Service_disconnect
    | File_save
    | Keeper_interrupt
    | Run_next
    | Surface_read
    | Keeper_reply_follow
    | Keeper_action_step
    | Unchecked_report_move

  let name ~ko request =
    let text korean english = if ko then korean else english in
    match request with
    | Command typed -> typed
    | Message -> text "메시지" "message"
    | Board_post -> text "게시글" "post"
    | Board_comment -> text "댓글" "comment"
    | Board_vote -> text "투표" "vote"
    | Tool_approval -> text "도구 승인" "tool approval"
    | Gate_decision -> text "게이트 판정" "gate decision"
    | Auto_judge_retry -> text "Auto Judge 재시도" "Auto Judge retry"
    | Approval_decision -> text "승인 판정" "approval decision"
    | Ask_answer -> text "질문 답" "answer"
    | Ask_source -> text "질문 출처 읽기" "question source read"
    | Task_cancel -> text "작업 취소" "Task cancellation"
    | Keeper_action -> text "키퍼 동작" "Keeper action"
    | Keeper_creation -> text "키퍼 만들기" "Keeper creation"
    | Keeper_deletion -> text "키퍼 삭제" "Keeper deletion"
    | Account_login -> text "계정 로그인" "account login"
    | Goal_transition -> text "목표 상태 변경" "Goal transition"
    | Schedule_cancel -> text "일정 취소" "schedule cancellation"
    | Schedule_change -> text "일정 변경" "schedule change"
    | Skill_evidence -> text "스킬 증거 읽기" "Skill evidence read"
    | Report_check -> text "보고서 확인 표시" "report check"
    | Addon_request -> text "기능 요청" "add-on request"
    | Volume_report -> text "볼륨 보고" "volume report"
    | Volume_reclaim -> text "볼륨 회수" "volume reclaim"
    | Original_save -> text "원본 저장" "original save"
    | Report_open -> text "보고서 열기" "report open"
    | Msx_screen_read -> text "MSX 화면 읽기" "MSX screen read"
    | Dos_screen_read -> text "DOS 화면 읽기" "DOS screen read"
    | Runtime_config_read -> text "runtime.toml 읽기" "runtime.toml read"
    | Runtime_params_read -> text "파라미터 읽기" "parameters read"
    | Preset_list_read -> text "프리셋 목록 읽기" "preset list read"
    | Preset_read -> text "프리셋 읽기" "preset read"
    | Preset_restore -> text "프리셋 복원" "preset restore"
    | Preset_delete -> text "프리셋 삭제" "preset delete"
    | Play_invite_list_read -> text "플레이 초대 목록 읽기" "play invite list read"
    | Play_invite_issue -> text "플레이 초대" "play invite"
    | Play_invite_revoke -> text "플레이 초대 취소" "play revoke"
    | Play_room_read -> text "공용 대화 읽기" "shared chat read"
    | Play_room_message -> text "공용 대화 메시지" "shared chat message"
    | Play_room_leave -> text "공용 대화 나가기" "shared chat leave"
    | Addon_read -> text "기능 읽기" "add-on read"
    | Runtime_surface_read -> text "런타임 읽기" "runtime read"
    | Lanes_read -> text "레인 목록 읽기" "lane list read"
    | Memory_input_read -> text "입력 크기 읽기" "input size read"
    | Keeper_turns_read -> text "턴 기록 읽기" "turn records read"
    | Memory_health_read -> text "기억 상태 읽기" "memory health read"
    | Machine_activity_read -> text "머신 활동 읽기" "machine activity read"
    | Machine_activity_save -> text "머신 활동 저장" "machine activity save"
    | Exact_activity_read -> text "Exact 레인 활동 읽기" "Exact lane activity read"
    | Exact_activity_save -> text "Exact 레인 활동 저장" "Exact lane activity save"
    | Fusion_launch -> text "퓨전 실행" "Fusion launch"
    | Board_post_read -> text "게시글 읽기" "Board post read"
    | Verification_read -> text "검증 목록 읽기" "verification list read"
    | Evidence_export -> text "증거 사본 저장" "evidence copy save"
    | Lane_write -> text "레인 쓰기" "lane write"
    | Goal_confirmation_read -> text "목표 확인 증거 읽기" "goal confirmation read"
    | Runtime_param_write -> text "파라미터 저장" "parameter save"
    | Task_creation -> text "작업 만들기" "Task creation"
    | Task_creation_read -> text "작업 만들기 기록 읽기" "Task creation read"
    | Native_tasks_read -> text "네이티브 작업 읽기" "native task read"
    | Child_content_read -> text "Child 내용 읽기" "Child content read"
    | Keeper_history_read -> text "대화 기록 읽기" "chat history read"
    | Keeper_memory_read -> text "기억 기록 읽기" "memory journal read"
    | Keeper_older_read -> text "이전 메시지 읽기" "older messages read"
    | Keeper_reply_read -> text "최근 답 읽기" "latest reply read"
    | Connector_unbind -> text "채널 연결 해제" "channel unbind"
    | Keeper_settings_read -> text "키퍼 설정 읽기" "Keeper settings read"
    | Preset_save -> text "프리셋 저장" "preset save"
    | Runtime_config_save -> text "runtime.toml 저장" "runtime.toml save"
    | Keeper_settings_save -> text "키퍼 설정 저장" "Keeper settings save"
    | Keeper_deletions_read -> text "키퍼 삭제 기록 읽기" "Keeper deletion records read"
    | Msx_load -> text "MSX 카트리지 불러오기" "MSX cartridge load"
    | Msx_disk_change -> text "MSX 디스크 교체" "MSX disk change"
    | Msx_control -> text "MSX 조작 시작" "MSX control"
    | Msx_checkpoint -> text "MSX 체크포인트 저장" "MSX checkpoint save"
    | Msx_restore -> text "MSX 체크포인트 복원" "MSX checkpoint restore"
    | Msx_key -> text "MSX 키 입력" "MSX key press"
    | Resource_list_read -> text "리소스 목록 읽기" "resource list read"
    | Resource_read -> text "리소스 읽기" "resource read"
    | Resource_share -> text "외부 공유 변경" "external share change"
    | Voice_probe -> text "음성 엔드포인트 확인" "voice endpoint probe"
    | Voice_setup_save -> text "음성 설정 저장" "voice setup save"
    | Agent_voice_save -> text "키퍼 음성 지정 저장" "Keeper voice assignment save"
    | Keeper_operation_read -> text "실행 상태 읽기" "operation state read"
    | Keeper_journal_read -> text "실행 기록 읽기" "journal read"
    | Msx_carts_read -> text "MSX 카트리지 목록 읽기" "MSX cartridge list read"
    | Verification_verdict -> text "검증 판정" "verification verdict"
    | Connector_bind -> text "채널 연결" "channel bind"
    | Connector_binding_edit -> text "채널 연결 편집" "channel binding edit"
    | Harness_label -> text "하네스 라벨" "Harness label"
    | Skill_sources_read -> text "스킬 소스 목록 읽기" "Skill source list read"
    | Skill_creation -> text "스킬 만들기" "Skill creation"
    | Skill_read -> text "스킬 읽기" "Skill read"
    | Skill_preview -> text "스킬 미리보기" "Skill preview"
    | Skill_save -> text "스킬 저장" "Skill save"
    | Skill_delete -> text "스킬 삭제" "Skill delete"
    | Prompt_save -> text "프롬프트 저장" "prompt save"
    | Prompt_clear -> text "프롬프트 덮어쓰기 해제" "prompt override clear"
    | Repository_add -> text "저장소 등록" "repository add"
    | Github_token_save -> text "GitHub 토큰 저장" "GitHub token save"
    | Github_login -> text "GitHub 로그인" "GitHub login"
    | Confirmations_read -> text "운영자 승인 목록 읽기" "confirmation list read"
    | Questions_read -> text "질문 목록 읽기" "question list read"
    | Report_checks_read -> text "보고서 확인 표시 읽기" "report check read"
    | Preparation_read -> text "준비 기록 읽기" "preparation record read"
    | Waiting_list_read -> text "대기 목록 읽기" "waiting list read"
    | Turn_observation_read -> text "턴 관측 읽기" "turn observation read"
    | Tool_inventory_read -> text "도구 목록 읽기" "tool inventory read"
    | Skill_catalog_read -> text "스킬 목록 읽기" "Skill catalog read"
    | Skill_activations_read -> text "스킬 활성화 기록 읽기" "Skill activations read"
    | Skill_usage_read -> text "스킬 사용량 읽기" "Skill usage read"
    | Async_requests_read -> text "별도 실행 목록 읽기" "async request list read"
    | Async_request_read -> text "별도 실행 읽기" "async request read"
    | Original_task_read -> text "원본 작업 읽기" "original Task read"
    | Task_history_read -> text "작업 기록 읽기" "Task history read"
    | Schedule_read -> text "일정 읽기" "schedule read"
    | Wake_history_read -> text "실행 이력 읽기" "wake history read"
    | Call_log_read -> text "호출 기록 읽기" "call log read"
    | Call_read -> text "호출 읽기" "call read"
    | Attachment_read -> text "첨부 읽기" "attachment read"
    | Goal_candle_read -> text "Candle 지급 기록 읽기" "Candle payout record read"
    | Goal_timeline_read -> text "목표 기록 읽기" "Goal timeline read"
    | Efficiency_read -> text "효율 읽기" "efficiency read"
    | Connector_list_read -> text "채널 연결 목록 읽기" "channel list read"
    | Browser_history_read -> text "브라우저 기록 읽기" "browser history read"
    | Memory_activity_read -> text "기억 활동 읽기" "memory activity read"
    | Memory_facts_read -> text "기억 사실 읽기" "memory facts read"
    | File_changes_read -> text "파일 변경 읽기" "file changes read"
    | Fusion_read -> text "퓨전 읽기" "Fusion read"
    | Memory_world_read -> text "기억 목록 읽기" "memory inventory read"
    | Verification_evidence_read -> text "검증 증거 읽기" "verification evidence read"
    | Sandbox_read -> text "샌드박스 읽기" "sandbox read"
    | Keeper_relationship_read -> text "키퍼 관계 읽기" "Keeper relationship read"
    | Image_read -> text "그림 읽기" "image read"
    | Gate_mode_change -> text "게이트 모드 변경" "Gate mode change"
    | Tool_modes_read -> text "도구 승인 모드 읽기" "tool approval modes read"
    | Tool_mode_change -> text "도구 승인 모드 변경" "tool approval mode change"
    | Board_requeue -> text "게시판 다시 넣기" "Board requeue"
    | Service_switch -> text "서비스 켜고 끄기" "service switch"
    | Service_app_save -> text "서비스 앱 저장" "service app save"
    | Service_login -> text "서비스 로그인" "service login"
    | Service_refresh -> text "서비스 도구 새로 읽기" "service tool refresh"
    | Service_disconnect -> text "서비스 연결 해제" "service disconnect"
    | File_save -> text "파일 저장" "file save"
    | Keeper_interrupt -> text "키퍼 턴 중단" "Keeper turn interrupt"
    | Run_next -> text "다음 순서 요청" "run-next request"
    | Surface_read -> text "화면 읽기" "screen read"
    | Keeper_reply_follow -> text "키퍼 답 이어 받기" "Keeper reply follow-up"
    | Keeper_action_step -> text "키퍼 동작 다음 단계" "next Keeper action step"
    | Unchecked_report_move -> text "다음 확인 안 한 보고서로 이동" "move to next unchecked report"
end

(* reason · <request> not sent · what stayed. The reason leads, so a cut row
   keeps it. *)
let kept_back ~ko ~request reason kept =
  let kept = match kept with
    | Draft_kept -> [ draft_retained ~ko ]
    | Queued_input_kept -> [ queued_input_retained ~ko ]
    | Nothing_kept -> [] in
  let not_sent = Kept_request.name ~ko request ^ " " ^ not_sent ~ko in
  String.concat " · " (String.capitalize_ascii reason :: not_sent :: kept)
