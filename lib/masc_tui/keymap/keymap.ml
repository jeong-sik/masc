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
  | Quit_app

type scope =
  | Global
  | Unfocused_nav
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
  | Focus_composer -> 3
  | Focus_filter -> 4
  | Dive_selected -> 5
  | Confirm_selected -> 6
  | Pop_back_or_close -> 7
  | Open_settings -> 8
  | Teleport_blocked -> 9
  | Open_incidents -> 10
  | Voice_ptt_toggle -> 11
  | Fast_approve_top -> 12
  | Fast_deny_top -> 13
  | Ask_select_choice _ -> 14
  | Open_help -> 15
  | Open_palette -> 16
  | Open_keeper_switcher -> 17
  | Open_model_switcher -> 18
  | Toggle_tool_details -> 19
  | Open_queue_context -> 20
  | Toggle_thinking -> 21
  | Cycle_origin_mode -> 22
  | Composer_kill_word -> 23
  | Composer_newline -> 24
  | Submit_steer -> 25
  | Submit_followup -> 26
  | Move _ -> 27
  | Toggle_expand -> 28
  | Create_new -> 29
  | Refresh -> 30
  | Copy_selected -> 31
  | Open_external -> 32
  | Toggle_zoom -> 33
  | Cycle_memory_view -> 34
  | Toggle_memory_sort -> 35
  | Quit_app -> 36

let equal_action a b =
  if not (Int.equal (action_tag a) (action_tag b)) then false
  else
    match (a, b) with
    | Switch_workspace x, Switch_workspace y -> Nav.equal_workspace x y
    | Sub_tab x, Sub_tab y -> equal_cycle_dir x y
    | Cycle_focus_pane x, Cycle_focus_pane y -> equal_cycle_dir x y
    | Ask_select_choice x, Ask_select_choice y -> Int.equal x y
    | Move x, Move y -> equal_move_dir x y
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
    | Quit_app, Quit_app ->
        true
    | ( Switch_workspace _
      | Sub_tab _
      | Cycle_focus_pane _
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
      | Quit_app ),
      _ ->
        false

let scope_rank = function
  | Global -> 0
  | Unfocused_nav -> 1
  | Ask_choice_focused -> 2
  | Approval_strip_focused -> 3
  | Approval_strip_chords -> 4
  | Composer_focused -> 5
  | Overlay_focused -> 6

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
  | Cat_actions -> Say.make ~ko:"작업 및 실행" ~en:"Actions"
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

let replay_ime_event (ev : Input.key_event) : Input.key_event =
  let norm = normalize_key_event ev in
  if (not norm.mods.ctrl) && not norm.mods.alt then
    match norm.key with
    | Input.Char s when String.length s > 1 -> (
        match Input.Ime.single_latin_key s with
        | Some latin ->
            normalize_key_event
              { key = Input.Char latin; mods = Input.no_mods }
        | None -> norm)
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
        norm
  else norm

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
  List.init 4 (fun i ->
      let n = i + 1 in
      let digit = Char.chr (Char.code '0' + n) in
      bind ~scope:Ask_choice_focused ~tier:Bare_unfocused ~category:Cat_approval
        ~action:(Ask_select_choice n)
        ~key_display:(String.make 1 digit)
        ~hint_label:(Say.make ~ko:(Printf.sprintf "선택 %d" n) ~en:(Printf.sprintf "Choice %d" n))
        ~help_desc:
          (Say.make
             ~ko:(Printf.sprintf "Ask 선택지 %d 응답" n)
             ~en:(Printf.sprintf "Select Ask choice %d" n))
        ~footer_priority:(if n = 1 then 1 else 0)
        (bare_char digit))

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
let say_quit = Say.make ~ko:"종료" ~en:"Quit"

let bindings : binding list =
  workspace_bindings
  @ ask_choice_bindings
  @ [
      (* --- Approval Strip (ONLY when Approval Strip active) --- *)
      bind ~scope:Approval_strip_focused ~tier:Bare_unfocused
        ~category:Cat_approval ~action:Fast_approve_top ~key_display:"Y"
        ~hint_label:say_approve
        ~help_desc:(Say.make ~ko:"대기 중 승인 항목 즉시 승인" ~en:"Fast-approve top pending item")
        ~footer_priority:1 (bare_char 'Y');
      bind ~scope:Approval_strip_focused ~tier:Bare_unfocused
        ~category:Cat_approval ~action:Fast_deny_top ~key_display:"N"
        ~hint_label:say_deny
        ~help_desc:(Say.make ~ko:"대기 중 승인 항목 거절(인라인 사유)" ~en:"Fast-deny top pending item")
        ~footer_priority:2 (bare_char 'N');
      bind ~scope:Approval_strip_chords ~tier:Modern_accel ~category:Cat_approval
        ~action:Fast_approve_top ~key_display:"Alt+Y" ~hint_label:say_approve
        ~help_desc:(Say.make ~ko:"대기 중 승인 항목 즉시 승인" ~en:"Fast-approve top pending item")
        ~footer_priority:1 (alt_char 'y');
      bind ~scope:Approval_strip_chords ~tier:Modern_accel ~category:Cat_approval
        ~action:Fast_deny_top ~key_display:"Alt+N" ~hint_label:say_deny
        ~help_desc:(Say.make ~ko:"대기 중 승인 항목 거절(인라인 사유)" ~en:"Fast-deny top pending item")
        ~footer_priority:2 (alt_char 'n');
      (* --- Monitor-First Bare Keys (Composer unfocused; NO bare 'p' or 'v') --- *)
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Dive_selected ~key_display:"Enter" ~hint_label:say_dive
        ~help_desc:(Say.make ~ko:"선택 항목 1-Hop 상세 진입" ~en:"Dive into selected entity")
        ~footer_priority:1 (mk_chord Input.Enter);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Sub_tab Prev) ~key_display:"[" ~hint_label:say_sub_prev
        ~help_desc:(Say.make ~ko:"이전 하위 탭으로 이동" ~en:"Previous sub-tab")
        ~footer_priority:3 (bare_char '[');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Sub_tab Next) ~key_display:"]" ~hint_label:say_sub_next
        ~help_desc:(Say.make ~ko:"다음 하위 탭으로 이동" ~en:"Next sub-tab")
        ~footer_priority:4 (bare_char ']');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_composer
        ~action:Focus_composer ~key_display:"i" ~hint_label:say_composer
        ~help_desc:(Say.make ~ko:"하단 컴포저에 포커스" ~en:"Focus bottom composer")
        ~footer_priority:2 (bare_char 'i');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Focus_filter ~key_display:"/" ~hint_label:say_filter
        ~help_desc:(Say.make ~ko:"현재 목록 필터 또는 슬래시 명령" ~en:"Filter list or enter slash command")
        ~footer_priority:5 (bare_char '/');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_settings ~key_display:"," ~hint_label:say_settings
        ~help_desc:(Say.make ~ko:"7-탭 설정 오버레이 열기" ~en:"Open 7-tab Settings overlay")
        ~slash_twin:"/config" ~footer_priority:7 (bare_char ',');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Teleport_blocked ~key_display:"J" ~hint_label:say_teleport
        ~help_desc:(Say.make ~ko:"가장 긴급한 대기/차단 키퍼로 점프" ~en:"Teleport to highest-priority blocked item")
        ~slash_twin:"/jump" ~footer_priority:5 (bare_char 'J');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_incidents ~key_display:"I" ~hint_label:say_incidents
        ~help_desc:(Say.make ~ko:"과거 장애·진단 이력 서랍 열기" ~en:"Open Historical Incidents drawer")
        ~slash_twin:"/incidents" ~footer_priority:8 (bare_char 'I');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Voice_ptt_toggle ~key_display:"V" ~hint_label:say_voice
        ~help_desc:(Say.make ~ko:"음성 입력(PTT) 시작/중지" ~en:"Toggle Voice Push-to-Talk")
        ~slash_twin:"/voice" ~footer_priority:8 (bare_char 'V');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_overlays
        ~action:Open_help ~key_display:"?" ~hint_label:say_help
        ~help_desc:(Say.make ~ko:"동적 단축키 도움말 열기" ~en:"Open dynamic keymap help")
        ~slash_twin:"/help" ~footer_priority:9 (bare_char '?');
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
        ~action:(Move Left) ~key_display:"←" ~hint_label:(Say.make ~ko:"왼쪽" ~en:"Left")
        ~help_desc:(Say.make ~ko:"왼쪽으로 이동" ~en:"Move left")
        ~footer_priority:0 (mk_chord Input.Left);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Move Right) ~key_display:"→" ~hint_label:(Say.make ~ko:"오른쪽" ~en:"Right")
        ~help_desc:(Say.make ~ko:"오른쪽으로 이동" ~en:"Move right")
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
        ~footer_priority:6 (mk_chord Input.Tab);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:(Cycle_focus_pane Prev) ~key_display:"Shift+Tab"
        ~hint_label:(Say.make ~ko:"이전 패널" ~en:"Prev Pane")
        ~help_desc:(Say.make ~ko:"이전 패널로 포커스 전환" ~en:"Focus previous pane")
        ~footer_priority:0 (mk_chord ~shift:true Input.Tab);
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Toggle_expand ~key_display:"Space"
        ~hint_label:(Say.make ~ko:"접기/펼치기" ~en:"Toggle")
        ~help_desc:(Say.make ~ko:"선택 그룹 또는 카드 펼치기/접기" ~en:"Expand or collapse group")
        ~footer_priority:0 (bare_char ' ');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Create_new ~key_display:"n"
        ~hint_label:(Say.make ~ko:"새로 만들기" ~en:"New")
        ~help_desc:(Say.make ~ko:"현재 워크스페이스 새 항목 생성" ~en:"Create new item in workspace")
        ~footer_priority:0 (bare_char 'n');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Refresh ~key_display:"r"
        ~hint_label:(Say.make ~ko:"새로고침" ~en:"Refresh")
        ~help_desc:(Say.make ~ko:"서버 SSOT 스냅샷 즉시 새로고침" ~en:"Force refresh live SSOT snapshot")
        ~footer_priority:0 (bare_char 'r');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Copy_selected ~key_display:"y"
        ~hint_label:(Say.make ~ko:"복사" ~en:"Copy")
        ~help_desc:(Say.make ~ko:"선택 항목을 클립보드(OSC 52)로 복사" ~en:"Copy selection via OSC 52")
        ~footer_priority:0 (bare_char 'y');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Open_external ~key_display:"o"
        ~hint_label:(Say.make ~ko:"열기" ~en:"Open")
        ~help_desc:(Say.make ~ko:"연결된 PR/문서/경로를 외부 앱에서 열기" ~en:"Open linked PR/artifact/path externally")
        ~footer_priority:0 (bare_char 'o');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Toggle_zoom ~key_display:"z"
        ~hint_label:(Say.make ~ko:"확대" ~en:"Zoom")
        ~help_desc:(Say.make ~ko:"상세 패널 전체 폭 확대/복원" ~en:"Toggle detail pane zoom")
        ~footer_priority:0 (bare_char 'z');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_navigation
        ~action:Cycle_memory_view ~key_display:"t"
        ~hint_label:(Say.make ~ko:"기억 보기" ~en:"Mem View")
        ~help_desc:(Say.make ~ko:"기억 보기 모드 순환 (변천/전체/Diff)" ~en:"Cycle Memory view mode (Evolution/Facts/Diff)")
        ~footer_priority:0 (bare_char 't');
      bind ~scope:Unfocused_nav ~tier:Bare_unfocused ~category:Cat_actions
        ~action:Toggle_memory_sort ~key_display:"s"
        ~hint_label:(Say.make ~ko:"기억 정렬" ~en:"Mem Sort")
        ~help_desc:(Say.make ~ko:"기억 목록 정렬 전환 (최근순/조회순)" ~en:"Toggle Memory facts sort (Recency/Retrieved)")
        ~footer_priority:0 (bare_char 's');
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
        ~footer_priority:2 (mk_chord ~shift:true Input.Enter);
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
        ~footer_priority:0 (ctrl_char 'j');
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
        ~help_desc:(Say.make ~ko:"오버레이 닫기 / 상세 복귀 / 입력 포커스 해제 (종료 안 함)" ~en:"Close overlay / pop dive / blur composer (never quits)")
        ~footer_priority:3 (mk_chord Input.Escape);
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_overlays
        ~action:Open_palette ~key_display:"Ctrl+K" ~hint_label:say_palette
        ~help_desc:(Say.make ~ko:"통합 명령·엔티티 팔레트 열기 (승인과 완전 분리)" ~en:"Open Universal Command & Entity Palette")
        ~footer_priority:6 (ctrl_char 'k');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_overlays
        ~action:Open_keeper_switcher ~key_display:"Ctrl+G" ~hint_label:say_keeper
        ~help_desc:(Say.make ~ko:"키퍼/채팅 빠른 전환기 열기" ~en:"Open Keeper/Chat switcher")
        ~slash_twin:"/keeper" ~footer_priority:7 (ctrl_char 'g');
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
        ~slash_twin:"/queue" ~footer_priority:8 (ctrl_char 't');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_actions
        ~action:Voice_ptt_toggle ~key_display:"Ctrl+B" ~hint_label:say_voice
        ~help_desc:(Say.make ~ko:"음성 입력(PTT) 시작/중지" ~en:"Toggle Voice Push-to-Talk")
        ~slash_twin:"/voice" ~footer_priority:8 (ctrl_char 'b');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_actions
        ~action:Cycle_origin_mode ~key_display:"Ctrl+F"
        ~hint_label:(Say.make ~ko:"표시 모드" ~en:"Origin")
        ~help_desc:(Say.make ~ko:"채팅 발신 표시 모드 순환 (bare/inline/row)" ~en:"Cycle chat origin mode")
        ~footer_priority:0 (ctrl_char 'f');
      bind ~scope:Global ~tier:Universal_ctrl ~category:Cat_actions
        ~action:Quit_app ~key_display:"Ctrl+Q" ~hint_label:say_quit
        ~help_desc:(Say.make ~ko:"MASC TUI 안전 종료" ~en:"Quit MASC TUI cleanly")
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
        ~slash_twin:"/voice" ~footer_priority:0 (alt_char 'v');
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
      | Nav.Help
      | Nav.System_gate Nav.Media_viewer ) ->
      [ Overlay_focused; Global ]

let allows_ime_replay = function
  | Unfocused_nav | Ask_choice_focused | Approval_strip_focused -> true
  | Global | Approval_strip_chords | Composer_focused | Overlay_focused -> false

let find_in_scope scope chord =
  List.find_opt
    (fun (b : binding) ->
      equal_scope b.scope scope && Input.equal_key_event b.chord chord)
    bindings

let dispatch ~scope_chain ev =
  let norm = normalize_key_event ev in
  let ime_fallback =
    if (not norm.mods.ctrl) && not norm.mods.alt then
      match norm.key with
      | Input.Char s when String.length s > 1 -> (
          match Input.Ime.single_latin_key s with
          | Some latin ->
              Some
                (normalize_key_event
                   { key = Input.Char latin; mods = Input.no_mods })
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
  in
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
    (* Collect candidate bindings in scope_chain order so more local scopes win
       when deduplicating actions (e.g., ',' over 'Ctrl+,' when unfocused). *)
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
  let active_bindings =
    List.filter
      (fun (b : binding) -> List.exists (equal_scope b.scope) scope_chain)
      bindings
  in
  let include_contextual_memory =
    List.exists (equal_scope Unfocused_nav) scope_chain
  in
  List.filter_map
    (fun category ->
      let cat_bindings =
        List.filter (fun (b : binding) -> equal_help_category b.category category) active_bindings
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
          | Pop_back_or_close ->
              false
          | Switch_workspace _
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
