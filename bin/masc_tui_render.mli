(** Rendering surface of the TUI.

    이 모듈은 16,743 줄에 최상위 정의가 337 개다. 그중 실제로 밖에서 쓰이는 것은
    아래 23 개뿐이고, 나머지 314 개는 내부 함수인데 인터페이스가 없어 전부 공개
    상태였다. 그래서 이 파일을 여는 사람은 매번 337 개를 다 마주쳤다.

    이 인터페이스는 손으로 고른 목록이 아니다. dune 이 이 모듈에 쓰는 ocamlc
    명령을 그대로 잡아 [-i] 로 추론 시그니처 876 줄을 받은 뒤, 소비자
    (bin/masc_tui.ml, test/test_tui_agenda.ml)가 실제로 참조하는 이름만 남겼다.
    [open Masc_tui_render] 때문에 한정 없이 쓰는 것도 있어서, 한정 참조 11 개와
    한정 없는 참조 13 개의 합집합(중복 1)으로 잡았다.

    숨긴 314 개 중 하나라도 밖에서 쓰였다면 [dune build @check] 가 깨진다. 즉 이
    목록은 추정이 아니라 컴파일러가 검증한 값이다.

    이 파일은 동작을 바꾸지 않는다. 다음 단계인 도메인 단위 분할(fusion 16,
    planning 13, board 10 ...)의 지도로 쓰려고 먼저 둔다 — 314 개는 어디로 옮겨도
    외부 계약이 깨지지 않는다. *)

module Frame_presenter = Masc_tui_frame_presenter
module Ask_projection = Masc_tui_ask_projection
module Ask_layout = Masc_tui_ask_layout
module Board_detail = Masc_tui_board_detail
module Magnitude = Masc_tui_magnitude
module Board_comment_thread = Masc_tui_board_comment_thread
module Message_layout = Masc_tui_message_layout
module Tool_detail = Masc_tui_tool_detail
module Retained_view = Masc_tui_retained_view
module Metrics_tail = Masc_tui_metrics_tail
module Observation_layout = Masc_tui_observation_layout
module Context_state = Masc_tui_context_state
module Keeper_activity = Masc_tui_keeper_activity
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_diff = Masc_tui_keeper_chat_diff
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Render_schedule = Masc_tui_render_schedule
module Agenda = Masc_tui_agenda
module Markdown = Masc_tui_markdown
module Markdown_cache = Masc_tui_markdown_render_cache
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection
module Keeper_control = Masc_tui_keeper_control
module Task_selection = Masc_tui_task_selection
module Tool_tree = Masc_tui_tool_tree
module Theme_choice = Masc_tui_theme_choice
module File_icon = Masc_tui_file_icon
module Approval_detail = Masc_tui_approval_detail
module Planning_detail = Masc_tui_planning_detail
module Link = Masc_tui_link
module Status = Masc.Keeper_status_runtime
module Render_tools = Masc_tui_render_tools
val json_assoc_member_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option

val set_table_frame : bool -> unit

(** The Activity pane as the last frame drew it, for the input layer: how
    many columns it held on the right (zero when none was drawn), what a
    press on one of its rows acts on, and how far its list can scroll. A
    press or a wheel notch between frames is answered from what was on
    screen, which is this, not from what the next frame would draw. *)
val acting_pane_drawn_cols : unit -> int

val acting_pane_target_at : line:int -> Masc_tui_acting_pane.row_target

val acting_pane_scroll_limit : unit -> int

(** What a press on this terminal row opens in the chat history the last frame
    drew, and {!Masc_tui_message_layout.Action_none} for any row outside it.

    Absolute terminal rows: the two-pane split places the chat beside the
    roster rather than below it, so a line keeps the vertical position its
    buffer gave it. Answers {!Action_none} until a frame has drawn a history,
    so a press cannot be served by a row that is no longer on screen. *)
val keeper_roster_marquee_target :
  Masc_tui_types.state -> cols:int -> string option

val overview_layout :
  Masc_tui_types.state ->
  terminal_rows:int ->
  Masc_tui_types.attention_item list * string option *
  Render_schedule.overview_allocation
type lane_run_tool_counts = {
  completed : int;
  deferred : int;
  failed : int;
  other : int;
}

type memory_state =
    Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error
module Span = Masc_tui_span
module Diff = Masc_tui_diff
val tools_scrolled : Masc_tui_types.state -> Masc_tui_types.scrolled
val render_tools :
  Masc_tui_types.state ->
  Frame_presenter.frame * Masc_tui_types.clamped_scroll option
val code_pane_content_height : Masc_tui_types.state -> int
val config_content_height : Masc_tui_types.state -> int
val context_inspector_viewport : Masc_tui_types.state -> int * int
val context_inspector_detail_viewport : Masc_tui_types.state -> int * int
val keeper_deletions_viewport : Masc_tui_types.state -> int * int
val help_viewport : Masc_tui_types.state -> int * int
val agenda_viewport : Masc_tui_types.state -> int * int
val answering_viewport : Masc_tui_types.state -> int * int
(** Pure projection for the visible Recent pane, or [None] when it will not
    consume chunks. Dimensions are the raw terminal measurement. The loop
    stores this result inside frame Build timing; rendering never stores it. *)
val acting_pane_chunk_projection :
  Masc_tui_types.state -> terminal_rows:int -> terminal_cols:int ->
  Masc_tui_acting.chunk_projection option

val render :
  Masc_tui_types.state ->
  Frame_presenter.frame * Masc_tui_types.clamped_scroll option *
  Masc_tui_types.approval_row option

val browser_lane_scroll_limit :
  Masc_tui_types.state -> terminal_rows:int -> cols:int ->
  Masc_tui_types.Browser_lane_view.t -> int

val browser_lane_selection_scroll :
  Masc_tui_types.state -> terminal_rows:int -> cols:int ->
  Masc_tui_types.Browser_lane_view.t -> int
(** Reveal the selected node's first wrapped row after explicit selection. *)

val ask_question_scroll_limit : Masc_tui_types.state -> int
val ask_question_page_size : Masc_tui_types.state -> int

val runtime_config_status_scroll_limit :
  Masc_tui_types.state -> terminal_rows:int -> cols:int -> int
