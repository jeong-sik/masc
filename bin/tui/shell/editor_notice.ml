type connector_change =
  | Channel_bind
  | Channel_unbind
  | Channel_binding_edit

type editor_form =
  | Board_draft
  | Code_draft
  | Gate_rejection
  | Connector_form of connector_change
  | Harness_overrule
  | Verification_rejection
  | Task_cancellation
  | Runtime_config_text
  | Skill_creation
  | Original_request_lookup
  | Skill_source of string
  | Prompt_text of string
  | Keeper_settings of string
  | Keeper_creation
  | Repository_addition
  | Schedule_form of Masc_tui_types.schedule_change

let form_name ~ko = function
  | Board_draft -> if ko then "글쓰기" else "Board compose"
  | Code_draft -> if ko then "코드 초안" else "Code draft"
  | Gate_rejection -> if ko then "Gate 거절" else "Gate rejection"
  | Connector_form Channel_bind -> if ko then "채널 연결" else "bind"
  | Connector_form Channel_unbind -> if ko then "채널 연결 해제" else "unbind"
  | Connector_form Channel_binding_edit -> if ko then "채널 연결 편집" else "edit binding"
  | Harness_overrule -> if ko then "판정 뒤집기" else "overrule"
  | Verification_rejection -> if ko then "검증 거절" else "reject"
  | Task_cancellation -> if ko then "작업 취소" else "cancel"
  | Runtime_config_text -> "runtime.toml"
  | Skill_creation -> if ko then "Skill 만들기" else "Skill creation"
  | Original_request_lookup ->
      if ko then "원래 비동기 요청 찾기" else "Original async request lookup"
  | Skill_source name -> name ^ (if ko then " 편집" else " edit")
  | Prompt_text key -> key ^ (if ko then " 프롬프트" else " prompt")
  | Keeper_settings keeper -> keeper ^ (if ko then " 설정" else " settings")
  | Keeper_creation -> if ko then "Keeper 만들기" else "create"
  | Repository_addition -> if ko then "저장소 등록" else "add"
  | Schedule_form change -> Masc_tui_types.schedule_change_name ~ko change

(* What quitting the editor leaves. Four forms say what stayed as it was; the
   rest name themselves as called off. The task cancel form says the task
   stays, because "작업 취소 취소" reads as undoing itself. *)
let form_left_alone ~ko form =
  match form with
  | Board_draft -> if ko then "초안 그대로" else "Board draft unchanged"
  | Runtime_config_text ->
      if ko then "runtime.toml 그대로 · 앞서 쓴 초안 남아 있음"
      else "runtime.toml unchanged · any earlier draft is retained"
  | Prompt_text key -> key ^ (if ko then ": 프롬프트 그대로" else ": prompt unchanged")
  | Keeper_settings keeper ->
      keeper ^ (if ko then ": 설정 그대로" else ": settings unchanged")
  | Task_cancellation -> if ko then "작업 취소 안 함" else "task not cancelled"
  | Code_draft | Gate_rejection | Connector_form _ | Harness_overrule
  | Verification_rejection | Skill_creation | Original_request_lookup
  | Skill_source _ | Keeper_creation | Repository_addition | Schedule_form _ ->
      form_name ~ko form ^ (if ko then " 취소" else " cancelled")

let report_abort state ~form (abort : Masc_tui_editor.abort) =
  let ko = state.Masc_tui_types.ui_language = Masc_tui_types.Lang_ko in
  match abort with
  | Masc_tui_editor.Cancelled ->
      Masc_tui_loader.report_action state "system" (form_left_alone ~ko form)
  | Masc_tui_editor.Editor_unavailable _ | Masc_tui_editor.Form_unreadable _ ->
      Masc_tui_loader.report_action state "error"
        (form_name ~ko form ^ ": " ^ Masc_tui_editor.abort_detail ~ko abort)

let report_unset state ~form =
  report_abort state ~form
    (Masc_tui_editor.Editor_unavailable Masc_tui_editor.Unset)

let editor_jump_unset state =
  Masc_tui_types.ui_text state
    ~ko:"편집기 없음 · Neovim 안에서 실행하거나 $EDITOR 를 설정하세요"
    ~en:"no editor · run this inside Neovim, or set $EDITOR"
