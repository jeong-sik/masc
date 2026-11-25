module Nav = Masc_tui_core.Nav
module Say = Masc_tui_core.Say
module Input = Masc_tui_term.Input_decoder
module Grapheme = Masc_tui_term.Grapheme

type move_dir =
  | Up
  | Down
  | Left
  | Right
  | Page_up
  | Page_down
  | Home
  | End

type cycle_dir =
  | Prev
  | Next

type action =
  | Switch_workspace of Nav.workspace
  | Toggle_sidebar
  | Sub_tab of cycle_dir
  | Cycle_focus_pane of cycle_dir
  | Focus_composer
  | Focus_filter
  | Dive_selected
  | Confirm_selected
  | Pop_back_or_close
  | Open_settings
  | Teleport_blocked
  | Open_incidents
  | Voice_ptt_toggle
  | Fast_approve_top
  | Fast_deny_top
  | Ask_select_choice of int
  | Open_help
  | Open_palette
  | Open_keeper_switcher
  | Open_model_switcher
  | Toggle_tool_details
  | Open_queue_context
  | Toggle_thinking
  | Cycle_origin_mode
  | Composer_kill_word
  | Composer_newline
  | Submit_steer
  | Submit_followup
  | Move of move_dir
  | Toggle_expand
  | Create_new
  | Refresh
  | Copy_selected
  | Open_external
  | Toggle_zoom
  | Cycle_memory_view
  | Toggle_memory_sort
  | Cycle_signal_or_source
  | Cycle_sort_or_speak
  | Cycle_hearth_or_overrule
  | Cycle_time_window
  | Cycle_view_mode
  | Context_primary_action
  | Toggle_artifact_share
  | Step_revision of cycle_dir
  | Step_context_item of cycle_dir
  | Launch_fusion
  | Toggle_unreported
  | Unbind_connector
  | Entity_approve_or_assign
  | Entity_reject_or_cancel
  | Edit_or_export
  | Configure_provider_key
  | Account_login
  | Poll_account_login
  | Copy_hash
  | Dismiss_errors
  | Board_vote of [ `Up | `Down ]
  | Toggle_memory_scope
  | Copy_public_url
  | Probe_sandbox
  | Refresh_browser_tabs
  | Open_memory_recovery
  | Search_prev_match
  | Toggle_memory_chart
  | Open_external_editor
  | Interrupt_turn
  | Delete_selected
  | Link_task_goal
  | Keeper_wake_or_online
  | Keeper_stop_armed
  | Quit_app

type scope =
  | Global
  | Unfocused_nav
  | Screen_context
  | Ask_choice_focused
  | Approval_strip_focused
  | Approval_strip_chords
  | Composer_focused
  | Overlay_focused

type tier =
  | Bare_unfocused
  | Universal_ctrl
  | Modern_accel

type help_category =
  | Cat_navigation
  | Cat_actions
  | Cat_overlays
  | Cat_composer
  | Cat_approval

type binding = {
  chord : Input.key_event;
  scope : scope;
  tier : tier;
  category : help_category;
  action : action;
  key_display : string;
  hint_label : Say.t;
  help_desc : Say.t;
  slash_twin : string option;
  footer_priority : int;
}

type collision = {
  scope : scope;
  chord : Input.key_event;
  first : action;
  second : action;
}

type footer_hint = {
  key_display : string;
  label : string;
  action : action;
  priority : int;
}

type help_entry = {
  keys : string list;
  desc : string;
  slash_twin : string option;
  action : action;
}

type help_group = {
  category : help_category;
  title : string;
  entries : help_entry list;
}

type palette_command = {
  action : action;
  title : string;
  shortcut : string;
  slash_twin : string option;
  category : help_category;
}

let move_dir_rank = function
  | Up -> 0
  | Down -> 1
  | Left -> 2
  | Right -> 3
  | Page_up -> 4
  | Page_down -> 5
  | Home -> 6
  | End -> 7

let equal_move_dir a b = Int.equal (move_dir_rank a) (move_dir_rank b)

let cycle_dir_rank = function
  | Prev -> 0
  | Next -> 1

let equal_cycle_dir a b = Int.equal (cycle_dir_rank a) (cycle_dir_rank b)

let action_tag = function
  | Switch_workspace _ -> 0
  | Sub_tab _ -> 1
  | Cycle_focus_pane _ -> 2
  | Toggle_sidebar -> 3
  | Focus_composer -> 4
  | Focus_filter -> 5
  | Dive_selected -> 6
  | Confirm_selected -> 7
  | Pop_back_or_close -> 8
  | Open_settings -> 9
  | Teleport_blocked -> 10
  | Open_incidents -> 11
  | Voice_ptt_toggle -> 12
  | Fast_approve_top -> 13
  | Fast_deny_top -> 14
  | Ask_select_choice _ -> 15
  | Open_help -> 16
  | Open_palette -> 17
  | Open_keeper_switcher -> 18
  | Open_model_switcher -> 19
  | Toggle_tool_details -> 20
  | Open_queue_context -> 21
  | Toggle_thinking -> 22
  | Cycle_origin_mode -> 23
  | Composer_kill_word -> 24
  | Composer_newline -> 25
  | Submit_steer -> 26
  | Submit_followup -> 27
  | Move _ -> 28
  | Toggle_expand -> 29
  | Create_new -> 30
  | Refresh -> 31
  | Copy_selected -> 32
  | Open_external -> 33
  | Toggle_zoom -> 34
  | Cycle_memory_view -> 35
  | Toggle_memory_sort -> 36
  | Cycle_signal_or_source -> 37
  | Cycle_sort_or_speak -> 38
  | Cycle_hearth_or_overrule -> 39
  | Cycle_time_window -> 40
  | Cycle_view_mode -> 41
  | Context_primary_action -> 42
  | Toggle_artifact_share -> 43
  | Step_revision _ -> 44
  | Step_context_item _ -> 45
  | Launch_fusion -> 46
  | Toggle_unreported -> 47
  | Unbind_connector -> 48
  | Entity_approve_or_assign -> 49
  | Entity_reject_or_cancel -> 50
  | Edit_or_export -> 51
  | Configure_provider_key -> 52
  | Account_login -> 53
  | Poll_account_login -> 54
  | Copy_hash -> 55
  | Dismiss_errors -> 56
  | Board_vote _ -> 57
  | Toggle_memory_scope -> 58
  | Copy_public_url -> 59
  | Probe_sandbox -> 60
  | Refresh_browser_tabs -> 61
  | Open_memory_recovery -> 62
  | Search_prev_match -> 64
  | Toggle_memory_chart -> 65
  | Open_external_editor -> 66
  | Interrupt_turn -> 67
  | Quit_app -> 68
  | Delete_selected -> 69
  | Link_task_goal -> 70
  | Keeper_wake_or_online -> 71
  | Keeper_stop_armed -> 72

let equal_action a b =
  if not (Int.equal (action_tag a) (action_tag b)) then false
  else
    match (a, b) with
    | Switch_workspace x, Switch_workspace y -> Nav.equal_workspace x y
    | Sub_tab x, Sub_tab y -> equal_cycle_dir x y
    | Cycle_focus_pane x, Cycle_focus_pane y -> equal_cycle_dir x y
    | Step_revision x, Step_revision y -> equal_cycle_dir x y
    | Step_context_item x, Step_context_item y -> equal_cycle_dir x y
    | Ask_select_choice x, Ask_select_choice y -> Int.equal x y
    | Move x, Move y -> equal_move_dir x y
    | Board_vote `Up, Board_vote `Up | Board_vote `Down, Board_vote `Down -> true
    | Board_vote `Up, Board_vote `Down | Board_vote `Down, Board_vote `Up -> false
    | Toggle_sidebar, Toggle_sidebar
    | Focus_composer, Focus_composer
    | Focus_filter, Focus_filter
    | Dive_selected, Dive_selected
    | Confirm_selected, Confirm_selected
    | Pop_back_or_close, Pop_back_or_close
    | Open_settings, Open_settings
    | Teleport_blocked, Teleport_blocked
    | Open_incidents, Open_incidents
    | Voice_ptt_toggle, Voice_ptt_toggle
    | Fast_approve_top, Fast_approve_top
    | Fast_deny_top, Fast_deny_top
    | Open_help, Open_help
    | Open_palette, Open_palette
    | Open_keeper_switcher, Open_keeper_switcher
    | Open_model_switcher, Open_model_switcher
    | Toggle_tool_details, Toggle_tool_details
    | Open_queue_context, Open_queue_context
    | Toggle_thinking, Toggle_thinking
    | Cycle_origin_mode, Cycle_origin_mode
    | Composer_kill_word, Composer_kill_word
    | Composer_newline, Composer_newline
    | Submit_steer, Submit_steer
    | Submit_followup, Submit_followup
    | Toggle_expand, Toggle_expand
    | Create_new, Create_new
    | Refresh, Refresh
    | Copy_selected, Copy_selected
    | Open_external, Open_external
    | Toggle_zoom, Toggle_zoom
    | Cycle_memory_view, Cycle_memory_view
    | Toggle_memory_sort, Toggle_memory_sort
    | Cycle_signal_or_source, Cycle_signal_or_source
    | Cycle_sort_or_speak, Cycle_sort_or_speak
    | Cycle_hearth_or_overrule, Cycle_hearth_or_overrule
    | Cycle_time_window, Cycle_time_window
    | Cycle_view_mode, Cycle_view_mode
    | Context_primary_action, Context_primary_action
    | Toggle_artifact_share, Toggle_artifact_share
    | Launch_fusion, Launch_fusion
    | Toggle_unreported, Toggle_unreported
    | Unbind_connector, Unbind_connector
    | Entity_approve_or_assign, Entity_approve_or_assign
    | Entity_reject_or_cancel, Entity_reject_or_cancel
    | Edit_or_export, Edit_or_export
    | Configure_provider_key, Configure_provider_key
    | Account_login, Account_login
    | Poll_account_login, Poll_account_login
    | Copy_hash, Copy_hash
    | Dismiss_errors, Dismiss_errors
    | Toggle_memory_scope, Toggle_memory_scope
    | Copy_public_url, Copy_public_url
    | Probe_sandbox, Probe_sandbox
    | Refresh_browser_tabs, Refresh_browser_tabs
    | Open_memory_recovery, Open_memory_recovery
    | Search_prev_match, Search_prev_match
    | Toggle_memory_chart, Toggle_memory_chart
    | Open_external_editor, Open_external_editor
    | Interrupt_turn, Interrupt_turn
    | Delete_selected, Delete_selected
    | Link_task_goal, Link_task_goal
    | Keeper_wake_or_online, Keeper_wake_or_online
    | Keeper_stop_armed, Keeper_stop_armed
    | Quit_app, Quit_app ->
        true
    | ( Switch_workspace _
      | Sub_tab _
      | Cycle_focus_pane _
      | Toggle_sidebar
      | Focus_composer
      | Focus_filter
      | Dive_selected
      | Confirm_selected
      | Pop_back_or_close
      | Open_settings
      | Teleport_blocked
      | Open_incidents
      | Voice_ptt_toggle
      | Fast_approve_top
      | Fast_deny_top
      | Ask_select_choice _
      | Open_help
      | Open_palette
      | Open_keeper_switcher
      | Open_model_switcher
      | Toggle_tool_details
      | Open_queue_context
      | Toggle_thinking
      | Cycle_origin_mode
      | Composer_kill_word
      | Composer_newline
      | Submit_steer
      | Submit_followup
      | Move _
      | Toggle_expand
      | Create_new
      | Refresh
      | Copy_selected
      | Open_external
      | Toggle_zoom
      | Cycle_memory_view
      | Toggle_memory_sort
      | Cycle_signal_or_source
      | Cycle_sort_or_speak
      | Cycle_hearth_or_overrule
      | Cycle_time_window
      | Cycle_view_mode
      | Context_primary_action
      | Toggle_artifact_share
      | Step_revision _
      | Step_context_item _
      | Launch_fusion
      | Toggle_unreported
      | Unbind_connector
      | Entity_approve_or_assign
      | Entity_reject_or_cancel
      | Edit_or_export
      | Configure_provider_key
      | Account_login
      | Poll_account_login
      | Copy_hash
      | Dismiss_errors
      | Board_vote _
      | Toggle_memory_scope
      | Copy_public_url
      | Probe_sandbox
      | Refresh_browser_tabs
      | Open_memory_recovery
      | Search_prev_match
      | Toggle_memory_chart
      | Open_external_editor
      | Interrupt_turn
      | Delete_selected
      | Link_task_goal
      | Keeper_wake_or_online
      | Keeper_stop_armed
      | Quit_app ),
      _ ->
        false

let scope_rank = function
  | Global -> 0
  | Unfocused_nav -> 1
  | Screen_context -> 2
  | Ask_choice_focused -> 3
  | Approval_strip_focused -> 4
  | Approval_strip_chords -> 5
  | Composer_focused -> 6
  | Overlay_focused -> 7

let equal_scope a b = Int.equal (scope_rank a) (scope_rank b)

let tier_rank = function
  | Bare_unfocused -> 0
  | Universal_ctrl -> 1
  | Modern_accel -> 2

let equal_tier a b = Int.equal (tier_rank a) (tier_rank b)

let category_rank = function
  | Cat_navigation -> 0
  | Cat_actions -> 1
  | Cat_overlays -> 2
  | Cat_composer -> 3
  | Cat_approval -> 4

let equal_help_category a b = Int.equal (category_rank a) (category_rank b)

let all_scopes =
  [
    Global;
    Unfocused_nav;
    Screen_context;
    Ask_choice_focused;
    Approval_strip_focused;
    Approval_strip_chords;
    Composer_focused;
    Overlay_focused;
  ]

let all_categories =
  [ Cat_navigation; Cat_actions; Cat_overlays; Cat_composer; Cat_approval ]

let category_title = function
  | Cat_navigation -> Say.make ~ko:"탐색" ~en:"Navigation"
  | Cat_actions -> Say.make ~ko:"작업 및 화면 단축키" ~en:"Actions & Screen Keys"
  | Cat_overlays -> Say.make ~ko:"오버레이 및 전환" ~en:"Overlays & Pickers"
  | Cat_composer -> Say.make ~ko:"컴포저" ~en:"Composer"
  | Cat_approval -> Say.make ~ko:"빠른 승인 및 질문" ~en:"Fast Approval & Ask"

let normalize_key_event (ev : Input.key_event) : Input.key_event =
  match ev.key with
  | Input.Char s when String.length s = 1 ->
      let ch = s.[0] in
      if ev.mods.ctrl || ev.mods.alt then
        let lower = Char.lowercase_ascii ch in
        {
          key = Input.Char (String.make 1 lower);
          mods = ev.mods;
        }
      else if ev.mods.shift && ch >= 'a' && ch <= 'z' then
        {
          key = Input.Char (String.make 1 (Char.uppercase_ascii ch));
          mods = Input.no_mods;
        }
      else { key = Input.Char s; mods = Input.no_mods }
  | Input.Char _
  | Input.Enter
  | Input.Tab
  | Input.Backspace
  | Input.Escape
  | Input.Delete
  | Input.Insert
  | Input.Up
  | Input.Down
  | Input.Left
  | Input.Right
  | Input.Home
  | Input.End
  | Input.Page_up
  | Input.Page_down
  | Input.Function _ ->
      ev

let ime_replay_opt (norm : Input.key_event) : Input.key_event option =
  if (not norm.mods.ctrl) && not norm.mods.alt then
    match norm.key with
    | Input.Char s when String.length s > 1 -> (
        match Input.Ime.single_latin_key s with
        | Some latin ->
            Some
              (normalize_key_event
                 {
                   key = Input.Char latin;
                   mods = { Input.no_mods with shift = norm.mods.shift };
                 })
        | None -> None)
    | Input.Char _
    | Input.Enter
    | Input.Tab
    | Input.Backspace
    | Input.Escape
    | Input.Delete
    | Input.Insert
    | Input.Up
    | Input.Down
    | Input.Left
    | Input.Right
    | Input.Home
    | Input.End
    | Input.Page_up
    | Input.Page_down
    | Input.Function _ ->
        None
  else None

let replay_ime_event (ev : Input.key_event) : Input.key_event =
  let norm = normalize_key_event ev in
  match ime_replay_opt norm with Some replayed -> replayed | None -> norm

let mk_chord ?(ctrl = false) ?(alt = false) ?(shift = false) key : Input.key_event =
  normalize_key_event { key; mods = { ctrl; alt; shift } }

let bare_char c = mk_chord (Input.Char (String.make 1 c))
let ctrl_char c = mk_chord ~ctrl:true (Input.Char (String.make 1 c))
let alt_char c = mk_chord ~alt:true (Input.Char (String.make 1 c))
let fn_key n = mk_chord (Input.Function n)

let bind ~scope ~tier ~category ~action ~key_display ~hint_label ~help_desc
    ?slash_twin ?(footer_priority = 0) chord =
  {
    chord;
    scope;
    tier;
    category;
    action;
    key_display;
    hint_label;
    help_desc;
    slash_twin;
    footer_priority;
  }

let workspace_slash = function
  | Nav.Pulse -> "/pulse"
  | Nav.Work -> "/work"
  | Nav.Knowledge -> "/knowledge"
  | Nav.Keepers -> "/keepers"
  | Nav.Runtime -> "/runtime"
  | Nav.Infra -> "/infra"

let workspace_bindings =
  List.concat_map
    (fun ws ->
      let idx = Nav.workspace_index ws in
      let digit = Char.chr (Char.code '0' + idx) in
      let label = Nav.workspace_label ws in
      let slash = workspace_slash ws in
      let desc =
        Say.make
          ~ko:(Printf.sprintf "%s 워크스페이스로 이동" (Say.resolve Say.Lang_ko label))
          ~en:(Printf.sprintf "Switch to %s workspace" (Say.resolve Say.Lang_en label))
      in
      [
        bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
          ~action:(Switch_workspace ws)
          ~key_display:(String.make 1 digit) ~hint_label:label ~help_desc:desc
          ~slash_twin:slash ~footer_priority:0 (bare_char digit);
        bind ~scope:Global ~tier:Modern_accel ~category:Cat_navigation
          ~action:(Switch_workspace ws)
          ~key_display:(Printf.sprintf "Ctrl+%d" idx) ~hint_label:label
          ~help_desc:desc ~slash_twin:slash ~footer_priority:0 (ctrl_char digit);
        bind ~scope:Global ~tier:Modern_accel ~category:Cat_navigation
          ~action:(Switch_workspace ws)
          ~key_display:(Printf.sprintf "Alt+%d" idx) ~hint_label:label
          ~help_desc:desc ~slash_twin:slash ~footer_priority:0 (alt_char digit);
        bind ~scope:Global ~tier:Modern_accel ~category:Cat_navigation
          ~action:(Switch_workspace ws)
          ~key_display:(Printf.sprintf "F%d" idx) ~hint_label:label
          ~help_desc:desc ~slash_twin:slash ~footer_priority:0 (fn_key idx);
      ])
    Nav.all_workspaces

let ask_choice_bindings =
  (* Bind Ask choices to bare a..d instead of 1..4 so 1..6 workspace navigation
     never accidentally answers a pending Keeper Ask on Work > Inbox. *)
  List.init 4 (fun i ->
      let n = i + 1 in
      let letter = Char.chr (Char.code 'a' + i) in
      let key_s = String.make 1 letter in
      bind ~scope:Ask_choice_focused ~tier:Bare_unfocused ~category:Cat_approval
        ~action:(Ask_select_choice n)
        ~key_display:key_s
        ~hint_label:(Say.make ~ko:(Printf.sprintf "선택 %c" letter) ~en:(Printf.sprintf "Choice %c" letter))
        ~help_desc:
          (Say.make
             ~ko:(Printf.sprintf "Ask 선택지 %c(%d) 응답" letter n)
             ~en:(Printf.sprintf "Select Ask choice %c (%d)" letter n))
        ~footer_priority:(if n = 1 then 1 else 0)
        (bare_char letter))

let say_dive = Say.make ~ko:"상세" ~en:"Dive"
let say_back = Say.make ~ko:"닫기/뒤로" ~en:"Back"
let say_settings = Say.make ~ko:"설정" ~en:"Settings"
let say_teleport = Say.make ~ko:"대기 이동" ~en:"Jump"
let say_incidents = Say.make ~ko:"이력" ~en:"Incidents"
let say_voice = Say.make ~ko:"음성" ~en:"Voice"
let say_approve = Say.make ~ko:"승인" ~en:"Approve"
let say_deny = Say.make ~ko:"거절" ~en:"Deny"
let say_palette = Say.make ~ko:"팔레트" ~en:"Palette"
let say_keeper = Say.make ~ko:"키퍼" ~en:"Keeper"
let say_model = Say.make ~ko:"모델" ~en:"Model"
let say_tools = Say.make ~ko:"도구" ~en:"Tools"
let say_queue = Say.make ~ko:"큐/컨텍스트" ~en:"Queue/Ctx"
let say_help = Say.make ~ko:"도움말" ~en:"Help"
let say_composer = Say.make ~ko:"입력" ~en:"Write"
let say_filter = Say.make ~ko:"검색" ~en:"Filter"
let say_sub_prev = Say.make ~ko:"이전 탭" ~en:"Prev Tab"
let say_sub_next = Say.make ~ko:"다음 탭" ~en:"Next Tab"
let say_menu = Say.make ~ko:"메뉴" ~en:"Menu"
let say_quit = Say.make ~ko:"종료" ~en:"Quit"

let bindings : binding list =
  workspace_bindings
  @ ask_choice_bindings
  @ [
      (* --- Approval Strip (ONLY when Approval Strip active) --- *)
      bind ~scope:Approval_strip_focused ~tier:Bare_unfocused
        ~category:Cat_approval ~action:Fast_approve_top ~key_display:"Y"
        ~hint_label:say_approve
        ~help_desc:(Say.make ~ko:"대기 승인 즉시 승인 / 질문 답변 모달 열기" ~en:"Fast-approve top item / open Ask answer modal")
        ~footer_priority:1 (bare_char 'Y');
      bind ~scope:Approval_strip_focused ~tier:Bare_unfocused
        ~category:Cat_approval ~action:Fast_deny_top ~key_display:"N"
        ~hint_label:say_deny
        ~help_desc:(Say.make ~ko:"대기 승인 거절 / 질문 건너뛰기" ~en:"Fast-deny top item / skip Ask")
        ~footer_priority:2 (bare_char 'N');
      bind ~scope:Approval_strip_chords ~tier:Modern_accel ~category:Cat_approval
        ~action:Fast_approve_top ~key_display:"Alt+Y" ~hint_label:say_approve
        ~help_desc:(Say.make ~ko:"대기 승인 즉시 승인 / 질문 답변 모달 열기" ~en:"Fast-approve top item / open Ask answer modal")
        ~footer_priority:1 (alt_char 'y');
      bind ~scope:Approval_strip_chords ~tier:Modern_accel ~category:Cat_approval
        ~action:Fast_deny_top ~key_display:"Alt+N" ~hint_label:say_deny
        ~help_desc:(Say.make ~ko:"대기 승인 거절 / 질문 건너뛰기" ~en:"Fast-deny top item / skip Ask")
        ~footer_priority:2 (alt_char 'n');
      (* --- Monitor-First Bare Keys (Composer unfocused; bare 'p' unbound here) --- *)
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Dive_selected ~key_display:"Enter" ~hint_label:say_dive
        ~help_desc:(Say.make ~ko:"선택 항목 1-Hop 상세 진입" ~en:"Dive into selected entity")
        ~footer_priority:1 (mk_chord Input.Enter);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Toggle_sidebar ~key_display:"b" ~hint_label:say_menu
        ~help_desc:(Say.make ~ko:"좌측 전체 메뉴 사이드바 열기/포커스/접기" ~en:"Open, focus, or collapse left navigation menu")
        ~footer_priority:2 (bare_char 'b');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Sub_tab Prev) ~key_display:"[" ~hint_label:say_sub_prev
        ~help_desc:(Say.make ~ko:"이전 하위 탭" ~en:"Previous sub-tab")
        ~footer_priority:3 (bare_char '[');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Sub_tab Next) ~key_display:"]" ~hint_label:say_sub_next
        ~help_desc:(Say.make ~ko:"다음 하위 탭" ~en:"Next sub-tab")
        ~footer_priority:4 (bare_char ']');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_composer
        ~action:Focus_composer ~key_display:"i" ~hint_label:say_composer
        ~help_desc:(Say.make ~ko:"하단 컴포저에 포커스" ~en:"Focus bottom composer")
        ~footer_priority:2 (bare_char 'i');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Focus_filter ~key_display:"/" ~hint_label:say_filter
        ~help_desc:(Say.make ~ko:"현재 목록 필터 또는 산출물 본문 검색" ~en:"Filter list or search artifact document")
        ~footer_priority:6 (bare_char '/');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_settings ~key_display:"7" ~hint_label:say_settings
        ~help_desc:(Say.make ~ko:"7-탭 설정 오버레이 열기" ~en:"Open 7-tab Settings overlay")
        ~slash_twin:"/config" ~footer_priority:0 (bare_char '7');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_settings ~key_display:"," ~hint_label:say_settings
        ~help_desc:(Say.make ~ko:"7-탭 설정 오버레이 열기" ~en:"Open 7-tab Settings overlay")
        ~slash_twin:"/config" ~footer_priority:6 (bare_char ',');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Teleport_blocked ~key_display:"J" ~hint_label:say_teleport
        ~help_desc:(Say.make ~ko:"가장 긴급한 대기/차단 키퍼로 점프" ~en:"Teleport to highest-priority blocked item")
        ~slash_twin:"/jump" ~footer_priority:8 (bare_char 'J');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_incidents ~key_display:"8" ~hint_label:say_incidents
        ~help_desc:(Say.make ~ko:"과거 장애·진단 이력 서랍 열기" ~en:"Open Historical Incidents drawer")
        ~slash_twin:"/incidents" ~footer_priority:0 (bare_char '8');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_incidents ~key_display:"I" ~hint_label:say_incidents
        ~help_desc:(Say.make ~ko:"과거 장애·진단 이력 서랍 열기" ~en:"Open Historical Incidents drawer")
        ~slash_twin:"/incidents" ~footer_priority:7 (bare_char 'I');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_queue_context ~key_display:"9" ~hint_label:say_queue
        ~help_desc:(Say.make ~ko:"키퍼 큐·컨텍스트·예약 서랍 열기" ~en:"Open Queue & Context drawer")
        ~slash_twin:"/queue" ~footer_priority:0 (bare_char '9');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Voice_ptt_toggle ~key_display:"V" ~hint_label:say_voice
        ~help_desc:(Say.make ~ko:"음성 입력(PTT) 시작/중지" ~en:"Toggle Voice Push-to-Talk")
        ~slash_twin:"/voice" ~footer_priority:9 (bare_char 'V');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_help ~key_display:"0" ~hint_label:say_help
        ~help_desc:(Say.make ~ko:"동적 단축키 도움말 열기" ~en:"Open dynamic keymap help")
        ~slash_twin:"/help" ~footer_priority:0 (bare_char '0');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_help ~key_display:"?" ~hint_label:say_help
        ~help_desc:(Say.make ~ko:"동적 단축키 도움말 열기" ~en:"Open dynamic keymap help")
        ~slash_twin:"/help" ~footer_priority:5 (bare_char '?');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Down) ~key_display:"j" ~hint_label:(Say.make ~ko:"아래" ~en:"Down")
        ~help_desc:(Say.make ~ko:"다음 항목으로 이동" ~en:"Move selection down")
        ~footer_priority:0 (bare_char 'j');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Up) ~key_display:"k" ~hint_label:(Say.make ~ko:"위" ~en:"Up")
        ~help_desc:(Say.make ~ko:"이전 항목으로 이동" ~en:"Move selection up")
        ~footer_priority:0 (bare_char 'k');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Down) ~key_display:"↓" ~hint_label:(Say.make ~ko:"아래" ~en:"Down")
        ~help_desc:(Say.make ~ko:"다음 항목으로 이동" ~en:"Move selection down")
        ~footer_priority:0 (mk_chord Input.Down);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Up) ~key_display:"↑" ~hint_label:(Say.make ~ko:"위" ~en:"Up")
        ~help_desc:(Say.make ~ko:"이전 항목으로 이동" ~en:"Move selection up")
        ~footer_priority:0 (mk_chord Input.Up);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Left) ~key_display:"←" ~hint_label:(Say.make ~ko:"왼쪽 패널" ~en:"Left Pane")
        ~help_desc:(Say.make ~ko:"왼쪽 패널/사이드바로 이동" ~en:"Move to left pane or sidebar")
        ~footer_priority:0 (mk_chord Input.Left);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Right) ~key_display:"→" ~hint_label:(Say.make ~ko:"오른쪽 패널" ~en:"Right Pane")
        ~help_desc:(Say.make ~ko:"오른쪽 패널로 이동" ~en:"Move to right pane")
        ~footer_priority:0 (mk_chord Input.Right);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Page_up) ~key_display:"PgUp" ~hint_label:(Say.make ~ko:"이전 페이지" ~en:"PgUp")
        ~help_desc:(Say.make ~ko:"한 페이지 위로 스크롤" ~en:"Scroll one page up")
        ~footer_priority:0 (mk_chord Input.Page_up);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Page_down) ~key_display:"PgDn" ~hint_label:(Say.make ~ko:"다음 페이지" ~en:"PgDn")
        ~help_desc:(Say.make ~ko:"한 페이지 아래로 스크롤" ~en:"Scroll one page down")
        ~footer_priority:0 (mk_chord Input.Page_down);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Home) ~key_display:"Home" ~hint_label:(Say.make ~ko:"처음" ~en:"Home")
        ~help_desc:(Say.make ~ko:"맨 위로 이동" ~en:"Jump to top")
        ~footer_priority:0 (mk_chord Input.Home);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Home) ~key_display:"g" ~hint_label:(Say.make ~ko:"처음" ~en:"Top")
        ~help_desc:(Say.make ~ko:"맨 위로 이동" ~en:"Jump to top")
        ~footer_priority:0 (bare_char 'g');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move End) ~key_display:"End" ~hint_label:(Say.make ~ko:"끝" ~en:"End")
        ~help_desc:(Say.make ~ko:"맨 아래로 이동" ~en:"Jump to bottom")
        ~footer_priority:0 (mk_chord Input.End);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move End) ~key_display:"G" ~hint_label:(Say.make ~ko:"끝" ~en:"Bottom")
        ~help_desc:(Say.make ~ko:"맨 아래로 이동" ~en:"Jump to bottom")
        ~footer_priority:0 (bare_char 'G');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Cycle_focus_pane Next) ~key_display:"Tab"
        ~hint_label:(Say.make ~ko:"패널" ~en:"Pane")
        ~help_desc:(Say.make ~ko:"다음 패널로 포커스 전환" ~en:"Focus next pane")
        ~footer_priority:2 (mk_chord Input.Tab);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Cycle_focus_pane Prev) ~key_display:"Shift+Tab"
        ~hint_label:(Say.make ~ko:"이전 패널" ~en:"Prev Pane")
        ~help_desc:(Say.make ~ko:"이전 패널로 포커스 전환" ~en:"Focus previous pane")
        ~footer_priority:0 (mk_chord ~shift:true Input.Tab);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Toggle_expand ~key_display:"Space"
        ~hint_label:(Say.make ~ko:"토글" ~en:"Toggle")
        ~help_desc:
          (Say.make
             ~ko:"로컬 토글 (접기·펼치기 · 필터 · 선택 · 턴 상세; 변경 전송 없음)"
             ~en:"Local toggle (expand/fold · filter · selection · view details; no POST)")
        ~footer_priority:0 (bare_char ' ');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Create_new ~key_display:"n"
        ~hint_label:(Say.make ~ko:"새로 만들기" ~en:"New")
        ~help_desc:(Say.make ~ko:"새 항목·레인 생성 / 하네스 거절 재정의 / 검색 다음 일치" ~en:"Create new item or lane / Harness reject overrule / Next match")
        ~footer_priority:0 (bare_char 'n');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Refresh ~key_display:"r"
        ~hint_label:(Say.make ~ko:"새로고침" ~en:"Refresh")
        ~help_desc:(Say.make ~ko:"서버 SSOT 스냅샷 즉시 새로고침 / OAuth 새로고침" ~en:"Force refresh live SSOT snapshot / OAuth identity refresh")
        ~footer_priority:0 (bare_char 'r');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Copy_selected ~key_display:"y"
        ~hint_label:(Say.make ~ko:"복사" ~en:"Copy")
        ~help_desc:(Say.make ~ko:"클립보드 복사(OSC 52) / 하네스 승인 재정의 / 코드·디바이스 코드 복사" ~en:"Copy via OSC 52 / Harness approve overrule / Copy path, code or device code")
        ~footer_priority:0 (bare_char 'y');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Open_external ~key_display:"o"
        ~hint_label:(Say.make ~ko:"열기" ~en:"Open")
        ~help_desc:(Say.make ~ko:"연결된 PR/문서/산출물을 외부 앱에서 열기" ~en:"Open linked PR/artifact/path externally")
        ~footer_priority:0 (bare_char 'o');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Toggle_zoom ~key_display:"z"
        ~hint_label:(Say.make ~ko:"확대" ~en:"Zoom")
        ~help_desc:(Say.make ~ko:"상세 패널 전체 폭 확대/복원" ~en:"Toggle detail pane zoom")
        ~footer_priority:0 (bare_char 'z');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Cycle_memory_view ~key_display:"t"
        ~hint_label:(Say.make ~ko:"섹션/기억" ~en:"Sec/Mem")
        ~help_desc:(Say.make ~ko:"트레이스 섹션 순환 (컨텍스트/도구/로그/런타임) · 기억 보기 모드 순환 (변천/전체/Diff)" ~en:"Cycle Trace section (Context/Tools/Logs/Runtime) or Memory view (Evolution/Facts/Diff)")
        ~footer_priority:0 (bare_char 't');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Toggle_memory_sort ~key_display:"s"
        ~hint_label:(Say.make ~ko:"기억 정렬" ~en:"Mem Sort")
        ~help_desc:(Say.make ~ko:"기억 목록 정렬 전환 (최근순/조회순)" ~en:"Toggle Memory facts sort (Recency/Retrieved)")
        ~footer_priority:0 (bare_char 's');
      (* --- Screen Hotkeys Registered in Single SSOT --- *)
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Cycle_sort_or_speak ~key_display:"S"
        ~hint_label:(Say.make ~ko:"정렬" ~en:"Sort")
        ~help_desc:
          (Say.make
             ~ko:"목표 정렬(단계/진행률/최신) / 보드 정렬(recent|hot|trending|updated|discussed)"
             ~en:"Cycle Goals sort (phase/progress/recent) or Board sort (recent|hot|trending|updated|discussed)")
        ~footer_priority:0 (bare_char 'S');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Cycle_hearth_or_overrule ~key_display:"h"
        ~hint_label:(Say.make ~ko:"서브보드/재정의" ~en:"Hearth/Overrule")
        ~help_desc:(Say.make ~ko:"보드 서브보드(hearth) 순환 / 하네스 판정 재정의" ~en:"Board hearth picker cycle / Harness overrule")
        ~footer_priority:0 (bare_char 'h');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Cycle_time_window ~key_display:"w"
        ~hint_label:(Say.make ~ko:"기간 창" ~en:"Window")
        ~help_desc:(Say.make ~ko:"기억 비교 창(24h|7d|30d) / 도구 호출 기간(24h|7d|14d)" ~en:"Memory diff window (24h|7d|30d) / Tools window (24h|7d|14d)")
        ~footer_priority:0 (bare_char 'w');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Cycle_view_mode ~key_display:"v"
        ~hint_label:(Say.make ~ko:"보기 전환" ~en:"View")
        ~help_desc:(Say.make ~ko:"산출물·도구·컨텍스트·검증증거·기억·키퍼로그·코드 Git 하위뷰 / 기억 다이어그램 모드 전환" ~en:"Cycle sub-view (Artifacts/Tools/Context/Verification/Memory/Keeper Logs/Code Git) or Memory diagram mode")
        ~footer_priority:0 (bare_char 'v');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Context_primary_action ~key_display:"c"
        ~hint_label:(Say.make ~ko:"확인/댓글/채팅" ~en:"Check/Reply/Chat")
        ~help_desc:(Say.make ~ko:"산출물 확인 체크 / 보드 댓글 작성 / 키퍼 빠른 채팅 / 목표 완료 요청" ~en:"Artifact check toggle / Board comment / Quick keeper chat / Goal complete")
        ~footer_priority:0 (bare_char 'c');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Toggle_artifact_share ~key_display:"P"
        ~hint_label:(Say.make ~ko:"외부 공유" ~en:"Share")
        ~help_desc:(Say.make ~ko:"산출물 CAS 외부 공유 켜기/끄기" ~en:"Toggle Published Artifact CAS external share")
        ~footer_priority:0 (bare_char 'P');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Step_revision Prev) ~key_display:"{"
        ~hint_label:(Say.make ~ko:"이전 섹션/리비전" ~en:"Prev Sec/Rev")
        ~help_desc:
          (Say.make ~ko:"트레이스 이전 섹션 / 산출물 이전 리비전으로 이동 (< 별칭)"
             ~en:"Previous Trace section / older artifact revision (alias of <)")
        ~footer_priority:0 (bare_char '{');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Step_revision Next) ~key_display:"}"
        ~hint_label:(Say.make ~ko:"다음 섹션/리비전" ~en:"Next Sec/Rev")
        ~help_desc:
          (Say.make ~ko:"트레이스 다음 섹션 / 산출물 다음 리비전으로 이동 (> 별칭)"
             ~en:"Next Trace section / newer artifact revision (alias of >)")
        ~footer_priority:0 (bare_char '}');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Step_context_item Prev) ~key_display:"<"
        ~hint_label:(Say.make ~ko:"이전 항목/이력" ~en:"Prev Item")
        ~help_desc:
          (Say.make
             ~ko:"이전 항목·이력·리비전 (턴 / 키퍼 / 섹션 / 댓글 / 산출물 리비전)"
             ~en:"Step older/previous item (turn / keeper / section / comment / artifact rev)")
        ~footer_priority:0 (bare_char '<');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Step_context_item Next) ~key_display:">"
        ~hint_label:(Say.make ~ko:"다음 항목/이력" ~en:"Next Item")
        ~help_desc:
          (Say.make
             ~ko:"다음 항목·이력·리비전 (턴 / 키퍼 / 섹션 / 댓글 / 산출물 리비전)"
             ~en:"Step newer/next item (turn / keeper / section / comment / artifact rev)")
        ~footer_priority:0 (bare_char '>');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Launch_fusion ~key_display:"f"
        ~hint_label:(Say.make ~ko:"퓨전/검색/사실" ~en:"Fusion/Find/Facts")
        ~help_desc:(Say.make ~ko:"Runtime 퓨전 실행 모달 / 코드 ripgrep 검색 / 기억 전체 사실 보기" ~en:"Open Runtime Fusion launch modal / Code ripgrep search / Memory Explorer Facts view")
        ~footer_priority:0 (bare_char 'f');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Toggle_unreported ~key_display:"u"
        ~hint_label:(Say.make ~ko:"미보고 계정" ~en:"Unreported")
        ~help_desc:(Say.make ~ko:"게시판 추천(Upvote) / Quotas 미보고 계정 섹션 펼치기·접기" ~en:"Upvote board post / Toggle unreported accounts in Quotas")
        ~footer_priority:0 (bare_char 'u');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Unbind_connector ~key_display:"U"
        ~hint_label:(Say.make ~ko:"연결 해제" ~en:"Unbind")
        ~help_desc:(Say.make ~ko:"커넥터 채널 바인딩 해제 / OAuth 공급자 연결 해제" ~en:"Unbind selected connector channel / Disconnect OAuth provider")
        ~footer_priority:0 (bare_char 'U');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Entity_approve_or_assign ~key_display:"a"
        ~hint_label:(Say.make ~ko:"승인/배정/전환" ~en:"Approve/Toggle")
        ~help_desc:(Say.make ~ko:"목표·검증 승인 / 런타임 배정 / OAuth 전환 / 활동 로그 Acting 레일 토글" ~en:"Approve goal/verification, assign runtime, toggle OAuth, or toggle Acting rail")
        ~footer_priority:0 (bare_char 'a');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Entity_reject_or_cancel ~key_display:"x"
        ~hint_label:(Say.make ~ko:"반려/취소" ~en:"Reject/Cancel")
        ~help_desc:(Say.make ~ko:"작업 취소 / 검증 반려 / 목표 일시중지" ~en:"Cancel task, reject verification, or pause goal")
        ~footer_priority:0 (bare_char 'x');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Edit_or_export ~key_display:"e"
        ~hint_label:(Say.make ~ko:"편집/증거" ~en:"Edit/Evidence")
        ~help_desc:(Say.make ~ko:"레인 후보 편집 / 위키 편집 / 산출물 내보내기 / 퓨전 보드 증거 / 키퍼 설정 / 기억 변천" ~en:"Edit lane candidates, wiki, or keeper config / export artifact / Fusion evidence / Memory Evolution")
        ~footer_priority:0 (bare_char 'e');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Delete_selected ~key_display:"d"
        ~hint_label:(Say.make ~ko:"삭제" ~en:"Delete")
        ~help_desc:(Say.make ~ko:"선택 항목 삭제·분리 확인(레인/게시글/애드온/키퍼) / 기억 Diff 보기 / 키퍼 설정 미리보기" ~en:"Delete or detach selected item (lane/post/addon/keeper) / Memory Diff view / Keeper config dry-run")
        ~footer_priority:0 (bare_char 'd');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Configure_provider_key ~key_display:"K"
        ~hint_label:(Say.make ~ko:"API/PAT 키" ~en:"API/PAT Key")
        ~help_desc:(Say.make ~ko:"프로바이더 API 키 / 키퍼 GitHub PAT 설정(마스킹)" ~en:"Configure provider API key / Keeper masked GitHub PAT")
        ~footer_priority:0 (bare_char 'K');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Account_login ~key_display:"l"
        ~hint_label:(Say.make ~ko:"로그인" ~en:"Login")
        ~help_desc:(Say.make ~ko:"프로바이더 계정 / 키퍼 OAuth·GitHub 디바이스 로그인 시작" ~en:"Start provider, OAuth, or GitHub device login")
        ~footer_priority:0 (bare_char 'l');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Poll_account_login ~key_display:"L"
        ~hint_label:(Say.make ~ko:"로그인 확인" ~en:"Poll Login")
        ~help_desc:(Say.make ~ko:"키퍼 생명주기 모달 / 진행 중인 계정·OAuth 로그인 상태 조회" ~en:"Keeper lifecycle modal / Poll in-flight account or OAuth login status")
        ~footer_priority:0 (bare_char 'L');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Copy_hash ~key_display:"H"
        ~hint_label:(Say.make ~ko:"SHA 복사" ~en:"Copy SHA")
        ~help_desc:(Say.make ~ko:"산출물 SHA-256 다이제스트 복사" ~en:"Copy artifact SHA-256 digest")
        ~footer_priority:0 (bare_char 'H');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Dismiss_errors ~key_display:"X"
        ~hint_label:(Say.make ~ko:"오류 닫기" ~en:"Dismiss")
        ~help_desc:(Say.make ~ko:"채팅 실패 알림 닫기 / 하네스 판정 재정의" ~en:"Dismiss chat failure notices / Harness overrule")
        ~footer_priority:0 (bare_char 'X');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Keeper_wake_or_online ~key_display:"W"
        ~hint_label:(Say.make ~ko:"깨우기/온라인" ~en:"Wake/Online")
        ~help_desc:
          (Say.make
             ~ko:"[키퍼] 깨우기/온라인/재개 (/up·/resume)"
             ~en:"[Keepers] Wake/online/resume Keeper (/up·/resume)")
        ~slash_twin:"/wake" ~footer_priority:0 (bare_char 'W');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Keeper_stop_armed ~key_display:"D"
        ~hint_label:(Say.make ~ko:"중지(2회)" ~en:"Stop (2x)")
        ~help_desc:
          (Say.make
             ~ko:"[키퍼] 중지·오프라인 (2회 확인, /pause 일시정지)"
             ~en:"[Keepers] Stop/shutdown Keeper (2x confirm, /pause)")
        ~slash_twin:"/down" ~footer_priority:0 (bare_char 'D');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:(Board_vote `Up) ~key_display:"+"
        ~hint_label:(Say.make ~ko:"추천" ~en:"Upvote")
        ~help_desc:(Say.make ~ko:"보드 글·댓글 추천 (2회 입력 확정)" ~en:"Board post/comment upvote (2-press armed)")
        ~footer_priority:0 (bare_char '+');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:(Board_vote `Down) ~key_display:"-"
        ~hint_label:(Say.make ~ko:"비추천" ~en:"Downvote")
        ~help_desc:(Say.make ~ko:"보드 글·댓글 비추천 (2회 입력 확정)" ~en:"Board post/comment downvote (2-press armed)")
        ~footer_priority:0 (bare_char '-');
      (* --- Screen-Context Specialized Hotkeys (Zero Collisions in Unfocused_nav) --- *)
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Cycle_signal_or_source ~key_display:"s"
        ~hint_label:(Say.make ~ko:"신호/소스" ~en:"Signal/Src")
        ~help_desc:(Say.make ~ko:"[보드/인프라] 보드 신호 필터 / 인프라 로그 소스 전환" ~en:"[Board/Infra] Board Signal-Only toggle / Infra log source cycle")
        ~footer_priority:0 (bare_char 's');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Toggle_memory_scope ~key_display:"m"
        ~hint_label:(Say.make ~ko:"월드/키퍼" ~en:"World/Keeper")
        ~help_desc:(Say.make ~ko:"[기억 탭] 월드 vs 선택 키퍼 범위 전환" ~en:"[Memory tab] Toggle World vs Keeper scope")
        ~footer_priority:0 (bare_char 'm');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Copy_public_url ~key_display:"Y"
        ~hint_label:(Say.make ~ko:"공유 URL" ~en:"Public URL")
        ~help_desc:(Say.make ~ko:"[산출물] 공개 공유 URL 복사" ~en:"[Artifacts] Copy public share URL")
        ~footer_priority:0 (bare_char 'Y');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Probe_sandbox ~key_display:"p"
        ~hint_label:(Say.make ~ko:"프로브/고정/파일" ~en:"Probe/Pin/Find")
        ~help_desc:(Say.make ~ko:"[보드] 고정 토글 / [샌드박스] 상태 프로브 / [코드] 퍼지 파일 찾기 / [애드온] 패키지 카탈로그" ~en:"[Board] Pin toggle / [Sandboxes] Probe health / [Code] Fuzzy file finder / [Addons] Package catalog")
        ~footer_priority:0 (bare_char 'p');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Link_task_goal ~key_display:"g"
        ~hint_label:(Say.make ~ko:"목표 연결" ~en:"Link Goal")
        ~help_desc:(Say.make ~ko:"[작업] 목표 미연결 작업을 목표에 연결 (1회)" ~en:"[Tasks] Link goalless task to a Goal (one-time)")
        ~footer_priority:0 (bare_char 'g');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Refresh_browser_tabs ~key_display:"t"
        ~hint_label:(Say.make ~ko:"탭 새로고침" ~en:"Tabs")
        ~help_desc:(Say.make ~ko:"[애드온·브라우저] 브라우저 탭 목록 새로고침" ~en:"[Addons & Browser] Refresh browser tabs")
        ~footer_priority:0 (bare_char 't');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Open_memory_recovery ~key_display:"A"
        ~hint_label:(Say.make ~ko:"기억 복구" ~en:"Recovery")
        ~help_desc:(Say.make ~ko:"[기억 탭] 사서 라이터 복구 모달 열기" ~en:"[Memory] Open librarian writer recovery modal")
        ~footer_priority:0 (bare_char 'A');
      bind ~scope:Screen_context ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Search_prev_match ~key_display:"N"
        ~hint_label:(Say.make ~ko:"이전 일치" ~en:"Prev match")
        ~help_desc:(Say.make ~ko:"[산출물 상세] 이전 검색 결과로 이동" ~en:"[Artifact Dive] Jump to previous search match")
        ~footer_priority:0 (bare_char 'N');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Toggle_memory_chart ~key_display:"M"
        ~hint_label:(Say.make ~ko:"그래프 모드" ~en:"Chart mode")
        ~help_desc:(Say.make ~ko:"[기억 탭] 기억 유입/순합 그래프 모드 전환" ~en:"[Memory] Toggle Flow I/O vs Net Total chart mode")
        ~footer_priority:0 (bare_char 'M');
      bind ~scope:Screen_context ~tier:Universal_ctrl ~category:Cat_actions
        ~action:Open_external_editor ~key_display:"Ctrl+E"
        ~hint_label:(Say.make ~ko:"외부 편집기" ~en:"$EDITOR")
        ~help_desc:(Say.make ~ko:"[위키/설정] 외부 $EDITOR 열기 · [컴포저] 줄 끝 이동" ~en:"[Wiki/Settings] Open $EDITOR · [Composer] End of line")
        ~footer_priority:0 (ctrl_char 'e');
      bind ~scope:Screen_context ~tier:Universal_ctrl ~category:Cat_actions
        ~action:Interrupt_turn ~key_display:"Ctrl+X"
        ~hint_label:(Say.make ~ko:"턴 중단" ~en:"Interrupt")
        ~help_desc:(Say.make ~ko:"진행 중인 키퍼 턴 중단 요청" ~en:"Interrupt active keeper turn")
        ~footer_priority:0 (ctrl_char 'x');
      (* --- Composer-Focused Bindings --- *)
      bind ~scope:Composer_focused ~tier:Bare_unfocused ~category:Cat_composer
        ~action:Submit_followup ~key_display:"Enter"
        ~hint_label:(Say.make ~ko:"전송" ~en:"Send")
        ~help_desc:(Say.make ~ko:"메시지 전송 (턴이 돌고 있으면 끝난 뒤 전송)" ~en:"Send message (waits for an active turn to finish)")
        ~footer_priority:1 (mk_chord Input.Enter);
      bind ~scope:Composer_focused ~tier:Modern_accel ~category:Cat_composer
        ~action:Composer_newline ~key_display:"Shift+Enter"
        ~hint_label:(Say.make ~ko:"줄바꿈" ~en:"Newline")
        ~help_desc:(Say.make ~ko:"컴포저에 줄바꿈 삽입" ~en:"Insert literal newline")
        ~footer_priority:0 (mk_chord ~shift:true Input.Enter);
      bind ~scope:Composer_focused ~tier:Modern_accel ~category:Cat_composer
        ~action:Submit_steer ~key_display:"Alt+Enter"
        ~hint_label:(Say.make ~ko:"Steer" ~en:"Steer")
        ~help_desc:(Say.make ~ko:"내 요청이 돌고 있으면 끊고 Steer (남의 턴이면 대기열로)" ~en:"Steer: cut your own running request (queues behind other turns)")
        ~footer_priority:3 (mk_chord ~alt:true Input.Enter);
      bind ~scope:Composer_focused ~tier:Modern_accel ~category:Cat_composer
        ~action:Submit_steer ~key_display:"Ctrl+Enter"
        ~hint_label:(Say.make ~ko:"Steer" ~en:"Steer")
        ~help_desc:(Say.make ~ko:"내 요청이 돌고 있으면 끊고 Steer (남의 턴이면 대기열로)" ~en:"Steer: cut your own running request (queues behind other turns)")
        ~footer_priority:0 (mk_chord ~ctrl:true Input.Enter);
      bind ~scope:Composer_focused ~tier:Universal_ctrl ~category:Cat_composer
        ~action:Composer_newline ~key_display:"Ctrl+J"
        ~hint_label:(Say.make ~ko:"줄바꿈" ~en:"Newline")
        ~help_desc:(Say.make ~ko:"컴포저에 줄바꿈 삽입" ~en:"Insert literal newline")
        ~footer_priority:2 (ctrl_char 'j');
      bind ~scope:Composer_focused ~tier:Universal_ctrl ~category:Cat_composer
        ~action:Composer_kill_word ~key_display:"Ctrl+W"
        ~hint_label:(Say.make ~ko:"단어 삭제" ~en:"Kill word")
        ~help_desc:(Say.make ~ko:"커서 앞 단어 삭제" ~en:"Delete previous word")
        ~footer_priority:5 (ctrl_char 'w');
      (* --- Overlay-Focused Bindings --- *)
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Confirm_selected ~key_display:"Enter"
        ~hint_label:(Say.make ~ko:"확인" ~en:"Confirm")
        ~help_desc:(Say.make ~ko:"선택 항목 실행/적용" ~en:"Confirm selected overlay item")
        ~footer_priority:1 (mk_chord Input.Enter);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Up) ~key_display:"↑" ~hint_label:(Say.make ~ko:"위" ~en:"Up")
        ~help_desc:(Say.make ~ko:"오버레이 이전 항목" ~en:"Previous overlay item")
        ~footer_priority:0 (mk_chord Input.Up);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Down) ~key_display:"↓" ~hint_label:(Say.make ~ko:"아래" ~en:"Down")
        ~help_desc:(Say.make ~ko:"오버레이 다음 항목" ~en:"Next overlay item")
        ~footer_priority:0 (mk_chord Input.Down);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Left) ~key_display:"←" ~hint_label:(Say.make ~ko:"왼쪽" ~en:"Left")
        ~help_desc:(Say.make ~ko:"왼쪽 이동 / 이전 값" ~en:"Move left / previous value")
        ~footer_priority:0 (mk_chord Input.Left);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Right) ~key_display:"→" ~hint_label:(Say.make ~ko:"오른쪽" ~en:"Right")
        ~help_desc:(Say.make ~ko:"오른쪽 이동 / 다음 값" ~en:"Move right / next value")
        ~footer_priority:0 (mk_chord Input.Right);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Page_up) ~key_display:"PgUp" ~hint_label:(Say.make ~ko:"이전 페이지" ~en:"PgUp")
        ~help_desc:(Say.make ~ko:"오버레이 위로 스크롤" ~en:"Scroll overlay up")
        ~footer_priority:0 (mk_chord Input.Page_up);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Page_down) ~key_display:"PgDn" ~hint_label:(Say.make ~ko:"다음 페이지" ~en:"PgDn")
        ~help_desc:(Say.make ~ko:"오버레이 아래로 스크롤" ~en:"Scroll overlay down")
        ~footer_priority:0 (mk_chord Input.Page_down);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Home) ~key_display:"Home" ~hint_label:(Say.make ~ko:"처음" ~en:"Home")
        ~help_desc:(Say.make ~ko:"오버레이 맨 위로" ~en:"Overlay top")
        ~footer_priority:0 (mk_chord Input.Home);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move End) ~key_display:"End" ~hint_label:(Say.make ~ko:"끝" ~en:"End")
        ~help_desc:(Say.make ~ko:"오버레이 맨 아래로" ~en:"Overlay bottom")
        ~footer_priority:0 (mk_chord Input.End);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Sub_tab Prev) ~key_display:"[" ~hint_label:say_sub_prev
        ~help_desc:(Say.make ~ko:"이전 하위 탭 / 이전 질문" ~en:"Previous sub-tab / question")
        ~footer_priority:0 (bare_char '[');
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Sub_tab Next) ~key_display:"]" ~hint_label:say_sub_next
        ~help_desc:(Say.make ~ko:"다음 하위 탭 / 다음 질문" ~en:"Next sub-tab / question")
        ~footer_priority:0 (bare_char ']');
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Cycle_focus_pane Next) ~key_display:"Tab"
        ~hint_label:(Say.make ~ko:"다음 필드" ~en:"Next")
        ~help_desc:(Say.make ~ko:"다음 필드 또는 탭으로 이동" ~en:"Focus next field")
        ~footer_priority:3 (mk_chord Input.Tab);
      bind ~scope:Overlay_focused ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Cycle_focus_pane Prev) ~key_display:"Shift+Tab"
        ~hint_label:(Say.make ~ko:"이전 필드" ~en:"Prev")
        ~help_desc:(Say.make ~ko:"이전 필드 또는 탭으로 이동" ~en:"Focus previous field")
        ~footer_priority:0 (mk_chord ~shift:true Input.Tab);
      (* --- Global Universal VT100-Safe Ctrl Chords + Esc (work inside Composer too) --- *)
      bind ~scope:Global ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Pop_back_or_close ~key_display:"Esc" ~hint_label:say_back
        ~help_desc:(Say.make ~ko:"오버레이 닫기 / 상세 복귀 / 레일·입력 포커스 해제 (종료 안 함)" ~en:"Close overlay / pop dive / blur rail or composer (never quits)")
        ~footer_priority:3 (mk_chord Input.Escape);
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_navigation
        ~action:Toggle_sidebar ~key_display:"Ctrl+B" ~hint_label:say_menu
        ~help_desc:(Say.make ~ko:"좌측 전체 메뉴 사이드바 열기/포커스/접기" ~en:"Open, focus, or collapse left navigation menu")
        ~footer_priority:0 (ctrl_char 'b');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_overlays
        ~action:Open_palette ~key_display:"Ctrl+K" ~hint_label:say_palette
        ~help_desc:(Say.make ~ko:"통합 명령·엔티티 팔레트 열기 (승인과 완전 분리)" ~en:"Open Universal Command & Entity Palette")
        ~footer_priority:5 (ctrl_char 'k');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_overlays
        ~action:Open_keeper_switcher ~key_display:"Ctrl+G" ~hint_label:say_keeper
        ~help_desc:(Say.make ~ko:"키퍼/채팅 빠른 전환기 열기" ~en:"Open Keeper/Chat switcher")
        ~slash_twin:"/keeper" ~footer_priority:8 (ctrl_char 'g');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_overlays
        ~action:Open_model_switcher ~key_display:"Ctrl+L" ~hint_label:say_model
        ~help_desc:(Say.make ~ko:"런타임/모델 전환기 열기" ~en:"Open Model/Runtime switcher")
        ~slash_twin:"/model" ~footer_priority:9 (ctrl_char 'l');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_actions
        ~action:Toggle_tool_details ~key_display:"Ctrl+O" ~hint_label:say_tools
        ~help_desc:
          (Say.make
             ~ko:"도구 호출 상세 펼치기/접기 · 기억 탐색기에서 형성 트리 열기"
             ~en:"Toggle tool call details · open Memory Formation Tree")
        ~slash_twin:"/tools" ~footer_priority:9 (ctrl_char 'o');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_overlays
        ~action:Open_queue_context ~key_display:"Ctrl+T" ~hint_label:say_queue
        ~help_desc:(Say.make ~ko:"키퍼 큐·컨텍스트·예약 서랍 열기" ~en:"Open Queue & Context drawer")
        ~slash_twin:"/queue" ~footer_priority:7 (ctrl_char 't');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_actions
        ~action:Cycle_origin_mode ~key_display:"Ctrl+F"
        ~hint_label:(Say.make ~ko:"표시 모드" ~en:"Origin")
        ~help_desc:(Say.make ~ko:"채팅 발신 표시 모드 순환 (bare/inline/row)" ~en:"Cycle chat origin mode")
        ~footer_priority:0 (ctrl_char 'f');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_actions
        ~action:Quit_app ~key_display:"Ctrl+Q" ~hint_label:say_quit
        ~help_desc:
          (Say.make ~ko:"MASC TUI 안전 종료 (2회 눌러 확인)"
             ~en:"Quit MASC TUI cleanly (press twice to confirm)")
        ~slash_twin:"/quit" ~footer_priority:0 (ctrl_char 'q');
      (* --- Modern Accelerators (CSI u / Alt+ / Function keys) --- *)
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_overlays
        ~action:Open_settings ~key_display:"Ctrl+," ~hint_label:say_settings
        ~help_desc:(Say.make ~ko:"7-탭 설정 오버레이 열기" ~en:"Open 7-tab Settings overlay")
        ~slash_twin:"/config" ~footer_priority:7 (ctrl_char ',');
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_overlays
        ~action:Open_settings ~key_display:"Alt+," ~hint_label:say_settings
        ~help_desc:(Say.make ~ko:"7-탭 설정 오버레이 열기" ~en:"Open 7-tab Settings overlay")
        ~slash_twin:"/config" ~footer_priority:0 (alt_char ',');
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_overlays
        ~action:Open_settings ~key_display:"F10" ~hint_label:say_settings
        ~help_desc:(Say.make ~ko:"7-탭 설정 오버레이 열기" ~en:"Open 7-tab Settings overlay")
        ~slash_twin:"/config" ~footer_priority:0 (fn_key 10);
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_actions
        ~action:Teleport_blocked ~key_display:"Alt+J" ~hint_label:say_teleport
        ~help_desc:(Say.make ~ko:"가장 긴급한 대기/차단 키퍼로 점프" ~en:"Teleport to highest-priority blocked item")
        ~slash_twin:"/jump" ~footer_priority:5 (alt_char 'j');
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_overlays
        ~action:Open_incidents ~key_display:"Alt+I" ~hint_label:say_incidents
        ~help_desc:(Say.make ~ko:"과거 장애·진단 이력 서랍 열기" ~en:"Open Historical Incidents drawer")
        ~slash_twin:"/incidents" ~footer_priority:8 (alt_char 'i');
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_actions
        ~action:Voice_ptt_toggle ~key_display:"Alt+V" ~hint_label:say_voice
        ~help_desc:(Say.make ~ko:"음성 입력(PTT) 시작/중지" ~en:"Toggle Voice Push-to-Talk")
        ~slash_twin:"/voice" ~footer_priority:8 (alt_char 'v');
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_actions
        ~action:Voice_ptt_toggle ~key_display:"F8" ~hint_label:say_voice
        ~help_desc:(Say.make ~ko:"음성 입력(PTT) 시작/중지" ~en:"Toggle Voice Push-to-Talk")
        ~slash_twin:"/voice" ~footer_priority:0 (fn_key 8);
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_actions
        ~action:Toggle_thinking ~key_display:"Alt+T"
        ~hint_label:(Say.make ~ko:"추론 보기" ~en:"Thinking")
        ~help_desc:(Say.make ~ko:"추론 블록 표시 순환 (접힘/전체/숨김)" ~en:"Cycle thinking display (folded/full/hidden)")
        ~footer_priority:0 (alt_char 't');
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_navigation
        ~action:Toggle_sidebar ~key_display:"Alt+B"
        ~hint_label:(Say.make ~ko:"메뉴" ~en:"Menu")
        ~help_desc:(Say.make ~ko:"좌측 전체 메뉴 사이드바 열기/포커스/접기" ~en:"Open, focus, or collapse left navigation menu")
        ~footer_priority:0 (alt_char 'b');
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_navigation
        ~action:(Sub_tab Prev) ~key_display:"Alt+[" ~hint_label:say_sub_prev
        ~help_desc:(Say.make ~ko:"이전 하위 탭으로 이동" ~en:"Previous sub-tab")
        ~footer_priority:0 (alt_char '[');
      bind ~scope:Global ~tier:Modern_accel ~category:Cat_navigation
        ~action:(Sub_tab Next) ~key_display:"Alt+]" ~hint_label:say_sub_next
        ~help_desc:(Say.make ~ko:"다음 하위 탭으로 이동" ~en:"Next sub-tab")
        ~footer_priority:0 (alt_char ']');
    ]

let scope_chain_of_focus ?(approval_strip_active = false)
    (focus : Nav.focus_scope) =
  let approval_unfocused =
    if approval_strip_active then
      [ Approval_strip_focused; Approval_strip_chords ]
    else []
  in
  let approval_chords_only =
    if approval_strip_active then [ Approval_strip_chords ] else []
  in
  match focus with
  | Nav.Global -> approval_chords_only @ [ Global ]
  | Nav.Workspace_focused _ ->
      approval_unfocused @ [ Unfocused_nav; Global ]
  | Nav.Dive_focused _ ->
      approval_unfocused @ [ Unfocused_nav; Global ]
  | Nav.Ask_choice_focused ->
      [ Ask_choice_focused ] @ approval_unfocused @ [ Unfocused_nav; Global ]
  | Nav.Approval_strip_focused ->
      [ Approval_strip_focused; Approval_strip_chords; Unfocused_nav; Global ]
  | Nav.Composer_focused ->
      [ Composer_focused ] @ approval_chords_only @ [ Global ]
  | Nav.Overlay_focused
      (Nav.System_gate (Nav.Micro_viewport | Nav.Auth_gate | Nav.Server_offline))
    ->
      [ Overlay_focused ]
  | Nav.Overlay_focused
      ( Nav.Palette
      | Nav.Settings _
      | Nav.Incidents
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate Nav.Media_viewer ) ->
      [ Overlay_focused; Global ]

let allows_ime_replay = function
  | Unfocused_nav
  | Screen_context
  | Ask_choice_focused
  | Approval_strip_focused ->
      true
  | Global | Approval_strip_chords | Composer_focused | Overlay_focused -> false

let find_in_scope scope chord =
  List.find_opt
    (fun (b : binding) ->
      equal_scope b.scope scope && Input.equal_key_event b.chord chord)
    bindings

let dispatch ~scope_chain ev =
  let norm = normalize_key_event ev in
  let ime_fallback = ime_replay_opt norm in
  let rec search = function
    | [] -> None
    | scope :: rest -> (
        match find_in_scope scope norm with
        | Some b -> Some b.action
        | None -> (
            match ime_fallback with
            | Some ime_chord when allows_ime_replay scope -> (
                match find_in_scope scope ime_chord with
                | Some b -> Some b.action
                | None -> search rest)
            | Some _ | None -> search rest))
  in
  search scope_chain

let collisions () =
  let found = ref [] in
  List.iter
    (fun scope ->
      let seen = ref [] in
      List.iter
        (fun (b : binding) ->
          if equal_scope b.scope scope then
            let norm = normalize_key_event b.chord in
            match
              List.find_opt
                (fun (prev_chord, _) -> Input.equal_key_event prev_chord norm)
                !seen
            with
            | Some (_, prev_action) ->
                found :=
                  { scope; chord = norm; first = prev_action; second = b.action }
                  :: !found
            | None -> seen := (norm, b.action) :: !seen)
        bindings)
    all_scopes;
  List.rev !found

let footer_separator = " · "
let footer_separator_width = Grapheme.display_width footer_separator

let hint_width (h : footer_hint) =
  Grapheme.display_width h.key_display + 1 + Grapheme.display_width h.label

let footer_hints ~scope_chain ~max_width ~lang =
  if max_width <= 0 then []
  else
    let seen_actions = ref [] in
    let candidates = ref [] in
    List.iter
      (fun scope ->
        List.iter
          (fun (b : binding) ->
            if equal_scope b.scope scope && b.footer_priority > 0 then
              if not (List.exists (equal_action b.action) !seen_actions) then begin
                seen_actions := b.action :: !seen_actions;
                candidates :=
                  {
                    key_display = b.key_display;
                    label = Say.resolve lang b.hint_label;
                    action = b.action;
                    priority = b.footer_priority;
                  }
                  :: !candidates
              end)
          bindings)
      scope_chain;
    let sorted =
      List.stable_sort
        (fun (a : footer_hint) (b : footer_hint) ->
          Int.compare a.priority b.priority)
        (List.rev !candidates)
    in
    let rec pack acc used = function
      | [] -> List.rev acc
      | hint :: rest ->
          let w = hint_width hint in
          let needed = if acc = [] then w else footer_separator_width + w in
          if used + needed <= max_width then pack (hint :: acc) (used + needed) rest
          else List.rev acc
    in
    pack [] 0 sorted

let format_footer_line hints =
  String.concat footer_separator
    (List.map (fun (h : footer_hint) -> h.key_display ^ " " ^ h.label) hints)

let contextual_memory_help_entries ~lang =
  [
    {
      keys = [ "." ];
      desc =
        Say.resolve lang
          (Say.make
             ~ko:"기억 탐색기: Pele 3-stage SVG 카드 / Mermaid 폴백 열기"
             ~en:"Memory Explorer: open Pele 3-stage SVG card / Mermaid fallback");
      slash_twin = None;
      action = Cycle_memory_view;
    };
    {
      keys = [ "v" ];
      desc =
        Say.resolve lang
          (Say.make
             ~ko:"기억 다이어그램 열림 시: Auto(Pele) / Mermaid / Tree 모드 순환"
             ~en:"Memory diagram open: cycle Auto (Pele) / Mermaid / Tree");
      slash_twin = None;
      action = Cycle_memory_view;
    };
  ]

let help_entries ~scope_chain ~lang =
  let effective_scopes =
    if List.exists (equal_scope Unfocused_nav) scope_chain then
      scope_chain @ [ Screen_context ]
    else scope_chain
  in
  let active_bindings =
    List.filter
      (fun (b : binding) -> List.exists (equal_scope b.scope) effective_scopes)
      bindings
  in
  let include_contextual_memory =
    List.exists (equal_scope Unfocused_nav) scope_chain
  in
  List.filter_map
    (fun category ->
      let cat_bindings =
        List.filter
          (fun (b : binding) -> equal_help_category b.category category)
          active_bindings
      in
      let entries =
        List.fold_left
          (fun acc (b : binding) ->
            match
              List.find_opt (fun (e : help_entry) -> equal_action e.action b.action) acc
            with
            | Some existing ->
                if List.exists (String.equal b.key_display) existing.keys then acc
                else
                  List.map
                    (fun (e : help_entry) ->
                      if equal_action e.action b.action then
                        { e with keys = e.keys @ [ b.key_display ] }
                      else e)
                    acc
            | None ->
                acc
                @ [
                    {
                      keys = [ b.key_display ];
                      desc = Say.resolve lang b.help_desc;
                      slash_twin = b.slash_twin;
                      action = b.action;
                    };
                  ])
          [] cat_bindings
      in
      let entries =
        if include_contextual_memory && equal_help_category category Cat_actions
        then entries @ contextual_memory_help_entries ~lang
        else entries
      in
      match entries with
      | [] -> None
      | entries ->
          Some
            {
              category;
              title = Say.resolve lang (category_title category);
              entries;
            })
    all_categories

let palette_commands ~lang =
  List.fold_left
    (fun acc (b : binding) ->
      if List.exists (fun (p : palette_command) -> equal_action p.action b.action) acc
      then acc
      else
        let is_palette_eligible =
          match b.action with
          | Move _
          | Ask_select_choice _
          | Confirm_selected
          | Submit_steer
          | Submit_followup
          | Composer_newline
          | Composer_kill_word
          | Open_palette
          | Pop_back_or_close
          | Keeper_wake_or_online
          | Keeper_stop_armed ->
              false
          | Switch_workspace _
          | Toggle_sidebar
          | Sub_tab _
          | Cycle_focus_pane _
          | Focus_composer
          | Focus_filter
          | Dive_selected
          | Open_settings
          | Teleport_blocked
          | Open_incidents
          | Voice_ptt_toggle
          | Fast_approve_top
          | Fast_deny_top
          | Open_help
          | Open_keeper_switcher
          | Open_model_switcher
          | Toggle_tool_details
          | Open_queue_context
          | Toggle_thinking
          | Cycle_origin_mode
          | Toggle_expand
          | Create_new
          | Refresh
          | Copy_selected
          | Open_external
          | Toggle_zoom
          | Cycle_memory_view
          | Toggle_memory_sort
          | Cycle_signal_or_source
          | Cycle_sort_or_speak
          | Cycle_hearth_or_overrule
          | Cycle_time_window
          | Cycle_view_mode
          | Context_primary_action
          | Toggle_artifact_share
          | Step_revision _
          | Step_context_item _
          | Launch_fusion
          | Toggle_unreported
          | Unbind_connector
          | Entity_approve_or_assign
          | Entity_reject_or_cancel
          | Edit_or_export
          | Configure_provider_key
          | Account_login
          | Poll_account_login
          | Copy_hash
          | Dismiss_errors
          | Board_vote _
          | Toggle_memory_scope
          | Copy_public_url
          | Probe_sandbox
          | Refresh_browser_tabs
          | Open_memory_recovery
          | Search_prev_match
          | Toggle_memory_chart
          | Open_external_editor
          | Interrupt_turn
          | Delete_selected
          | Link_task_goal
          | Quit_app ->
              true
        in
        if not is_palette_eligible then acc
        else
          acc
          @ [
              {
                action = b.action;
                title = Say.resolve lang b.help_desc;
                shortcut = b.key_display;
                slash_twin = b.slash_twin;
                category = b.category;
              };
            ])
    [] bindings

let scope_name = function
  | Global -> "Global"
  | Unfocused_nav -> "Unfocused"
  | Screen_context -> "Screen Context"
  | Ask_choice_focused -> "Ask Choice"
  | Approval_strip_focused -> "Approval Strip (Unfocused)"
  | Approval_strip_chords -> "Approval Strip (Chord)"
  | Composer_focused -> "Composer"
  | Overlay_focused -> "Overlay"

let tier_name = function
  | Bare_unfocused -> "Monitor-first bare"
  | Universal_ctrl -> "Universal VT100 Ctrl"
  | Modern_accel -> "Modern accelerator"

let render_markdown_reference ?(lang = Say.Lang_en) () =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf "# MASC TUI v2 Keymap Reference\n\n";
  Buffer.add_string buf
    "| Scope | Tier | Key | Slash | Description |\n| --- | --- | --- | --- | --- |\n";
  List.iter
    (fun (b : binding) ->
      let slash =
        match b.slash_twin with
        | Some s -> Printf.sprintf "`%s`" s
        | None -> "—"
      in
      Printf.bprintf buf "| %s | %s | `%s` | %s | %s |\n"
        (scope_name b.scope) (tier_name b.tier) b.key_display slash
        (Say.resolve lang b.help_desc))
    bindings;
  List.iter
    (fun (e : help_entry) ->
      let key_s = String.concat "/" e.keys in
      Printf.bprintf buf "| Memory Explorer (Contextual) | Monitor-first bare | `%s` | — | %s |\n"
        key_s e.desc)
    (contextual_memory_help_entries ~lang);
  Buffer.contents buf
