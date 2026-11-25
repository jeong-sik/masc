module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme

type command_id =
  | Cmd_pulse
  | Cmd_work
  | Cmd_knowledge
  | Cmd_keepers
  | Cmd_runtime
  | Cmd_infra
  | Cmd_keeper
  | Cmd_model
  | Cmd_config
  | Cmd_incidents
  | Cmd_jump
  | Cmd_voice
  | Cmd_btw
  | Cmd_wake
  | Cmd_up
  | Cmd_resume
  | Cmd_pause
  | Cmd_down
  | Cmd_queue
  | Cmd_context
  | Cmd_ctl
  | Cmd_gate
  | Cmd_exec
  | Cmd_skill
  | Cmd_prompt
  | Cmd_preset
  | Cmd_lane
  | Cmd_addon
  | Cmd_browser
  | Cmd_tools
  | Cmd_clear
  | Cmd_theme
  | Cmd_lang
  | Cmd_help
  | Cmd_restart
  | Cmd_quit

type category =
  | Slash_navigation
  | Slash_pickers
  | Slash_interaction
  | Slash_display
  | Slash_session

type tools_mode =
  | Tools_compact
  | Tools_results
  | Tools_full

type keeper_ctl_action =
  | Ctl_boot
  | Ctl_up
  | Ctl_shutdown
  | Ctl_pause
  | Ctl_resume
  | Ctl_wakeup
  | Ctl_reset
  | Ctl_clear
  | Ctl_checkpoints
  | Ctl_purge_preview
  | Ctl_purge_apply
  | Ctl_delete_history
  | Ctl_note
  | Ctl_run_next

type gate_action =
  | Gate_mode_set of string
  | Gate_external_mode_set of string
  | Gate_rule_delete of string
  | Gate_approve_always of string
  | Gate_retry of string
  | Gate_keeper_mode_set of { keeper : string; mode : string }
  | Gate_ack_uncertain of { keeper : string; consume_id : string }
  | Gate_restore_late

type skill_action =
  | Skill_refresh
  | Skill_new
  | Skill_read of string
  | Skill_edit of string
  | Skill_delete of string

type prompt_action =
  | Prompt_set of { key : string; value : string option }
  | Prompt_clear of string
  | Param_set of { key : string; value_raw : string option }
  | Param_clear of string

type preset_action =
  | Preset_list
  | Preset_show of string
  | Preset_save of { name : string; description : string }
  | Preset_create of { name : string option; description : string }
  | Preset_restore of string
  | Preset_delete of string

type lane_action =
  | Lane_create of { lane : string; runtime_ids : string list }
  | Lane_remove of string
  | Lane_rename of { lane : string; to_lane : string }
  | Lane_set of { lane : string; runtime_ids : string list }
  | Lane_exact_append of { lane_id : string; runtime_id : string }
  | Lane_exact_drop of { lane_id : string; runtime_id : string }
  | Lane_exact_move of {
      lane_id : string;
      runtime_id : string;
      direction : [ `Up | `Down | `First ];
    }
  | Lane_exact_replace of {
      lane_id : string;
      runtime_id : string;
      replacement : string;
    }
  | Lane_run_inspect of string
  | Lane_quarantines of string
  | Lane_quarantine_recover of {
      keeper : string;
      partition_id : string;
      candidate_id : string;
      quarantine_id : string;
    }
  | Lane_raw_preview

type addon_action =
  | Addon_attach of {
      manifest_path : string;
      run_id : string;
      binding_json : string option;
    }
  | Addon_detach of string
  | Addon_observe of string
  | Addon_retain of string
  | Addon_act of { instance_id : string; action_json : string option }
  | Addon_evidence of {
      instance_id : string;
      row_ids : string list;
      keeper_name : string option;
    }
  | Addon_decl_read of string
  | Addon_decl_new of string
  | Addon_slice of { run_id : string option; lane_id : string option }
  | Addon_asks of { include_resolved : bool }
  | Addon_ask_answer of {
      declaration_id : string;
      ask_id : string;
      answers_json : string;
    }
  | Addon_operator of { instance_id : string; args_json : string option }

type browser_action =
  | Browser_scene of {
      client_id : string option;
      tab_id : int option;
      view : [ `Content | `Regions ];
    }
  | Browser_screenshot of { client_id : string option; tab_id : int option }
  | Browser_interact of {
      client_id : string option;
      tab_id : int option;
      action : string option;
      selector : string option;
      text : string option;
    }
  | Browser_command of string

(* Commands that [parse] accepts and [all] does not list, so the slash popup
   and the help overlay never show them. *)
type music_action =
  | Music_workbench
  | Music_import_midi of string

type parsed =
  | Pulse
  | Work
  | Knowledge
  | Keepers
  | Runtime
  | Infra
  | Keeper of string option
  | Model of string option
  | Config of string option
  | Incidents
  | Jump
  | Voice
  | Btw of string
  | Wake of string option
  | Up of string option
  | Resume of string option
  | Pause of string option
  | Down of string option
  | Queue
  | Context
  | Ctl of { action : keeper_ctl_action; target : string option }
  | Gate of gate_action
  | Exec of { tool_name : string; args_json : string option }
  | Skill of skill_action
  | Prompt of prompt_action
  | Preset of preset_action
  | Lane of lane_action
  | Addon of addon_action
  | Browser of browser_action
  | Tools of tools_mode option
  | Clear
  | Theme of Theme.preset option
  | Lang of Say.lang option
  | Help
  | Restart
  | Quit
  | Music of music_action

type parse_error =
  | Not_a_slash_command
  | Empty_command
  | Unknown_command of string
  | Unexpected_argument of { command : string; arg : string }
  | Invalid_argument of { command : string; expected : Say.t; got : string }

type spec = {
  id : command_id;
  name : string;
  arg_hint : Say.t option;
  description : Say.t;
  category : category;
}

let command_id_rank = function
  | Cmd_pulse -> 0
  | Cmd_work -> 1
  | Cmd_knowledge -> 2
  | Cmd_keepers -> 3
  | Cmd_runtime -> 4
  | Cmd_infra -> 5
  | Cmd_keeper -> 6
  | Cmd_model -> 7
  | Cmd_config -> 8
  | Cmd_incidents -> 9
  | Cmd_jump -> 10
  | Cmd_voice -> 11
  | Cmd_btw -> 12
  | Cmd_wake -> 13
  | Cmd_up -> 14
  | Cmd_resume -> 15
  | Cmd_pause -> 16
  | Cmd_down -> 17
  | Cmd_queue -> 18
  | Cmd_context -> 19
  | Cmd_ctl -> 20
  | Cmd_gate -> 21
  | Cmd_exec -> 22
  | Cmd_skill -> 23
  | Cmd_prompt -> 24
  | Cmd_preset -> 25
  | Cmd_lane -> 26
  | Cmd_addon -> 27
  | Cmd_browser -> 28
  | Cmd_tools -> 29
  | Cmd_clear -> 30
  | Cmd_theme -> 31
  | Cmd_lang -> 32
  | Cmd_help -> 33
  | Cmd_restart -> 34
  | Cmd_quit -> 35

let equal_command_id a b = Int.equal (command_id_rank a) (command_id_rank b)

let category_rank = function
  | Slash_navigation -> 0
  | Slash_pickers -> 1
  | Slash_interaction -> 2
  | Slash_display -> 3
  | Slash_session -> 4

let equal_category a b = Int.equal (category_rank a) (category_rank b)

let tools_mode_rank = function
  | Tools_compact -> 0
  | Tools_results -> 1
  | Tools_full -> 2

let equal_tools_mode a b = Int.equal (tools_mode_rank a) (tools_mode_rank b)

let keeper_ctl_action_rank = function
  | Ctl_boot -> 0
  | Ctl_up -> 1
  | Ctl_shutdown -> 2
  | Ctl_pause -> 3
  | Ctl_resume -> 4
  | Ctl_wakeup -> 5
  | Ctl_reset -> 6
  | Ctl_clear -> 7
  | Ctl_checkpoints -> 8
  | Ctl_purge_preview -> 9
  | Ctl_purge_apply -> 10
  | Ctl_delete_history -> 11
  | Ctl_note -> 12
  | Ctl_run_next -> 13

let equal_keeper_ctl_action a b =
  Int.equal (keeper_ctl_action_rank a) (keeper_ctl_action_rank b)

let gate_action_rank = function
  | Gate_mode_set _ -> 0
  | Gate_external_mode_set _ -> 1
  | Gate_rule_delete _ -> 2
  | Gate_approve_always _ -> 3
  | Gate_retry _ -> 4
  | Gate_keeper_mode_set _ -> 5
  | Gate_ack_uncertain _ -> 6
  | Gate_restore_late -> 7

let equal_gate_action a b =
  if not (Int.equal (gate_action_rank a) (gate_action_rank b)) then false
  else
    match (a, b) with
    | Gate_mode_set x, Gate_mode_set y
    | Gate_external_mode_set x, Gate_external_mode_set y
    | Gate_rule_delete x, Gate_rule_delete y
    | Gate_approve_always x, Gate_approve_always y
    | Gate_retry x, Gate_retry y ->
        String.equal x y
    | Gate_keeper_mode_set x, Gate_keeper_mode_set y ->
        String.equal x.keeper y.keeper && String.equal x.mode y.mode
    | Gate_ack_uncertain x, Gate_ack_uncertain y ->
        String.equal x.keeper y.keeper && String.equal x.consume_id y.consume_id
    | Gate_restore_late, Gate_restore_late -> true
    | ( Gate_mode_set _
      | Gate_external_mode_set _
      | Gate_rule_delete _
      | Gate_approve_always _
      | Gate_retry _
      | Gate_keeper_mode_set _
      | Gate_ack_uncertain _
      | Gate_restore_late ),
      _ ->
        false

let skill_action_rank = function
  | Skill_refresh -> 0
  | Skill_new -> 1
  | Skill_read _ -> 2
  | Skill_edit _ -> 3
  | Skill_delete _ -> 4

let equal_skill_action a b =
  if not (Int.equal (skill_action_rank a) (skill_action_rank b)) then false
  else
    match (a, b) with
    | Skill_refresh, Skill_refresh | Skill_new, Skill_new -> true
    | Skill_read x, Skill_read y
    | Skill_edit x, Skill_edit y
    | Skill_delete x, Skill_delete y ->
        String.equal x y
    | (Skill_refresh | Skill_new | Skill_read _ | Skill_edit _ | Skill_delete _),
      _ ->
        false

let prompt_action_rank = function
  | Prompt_set _ -> 0
  | Prompt_clear _ -> 1
  | Param_set _ -> 2
  | Param_clear _ -> 3

let equal_prompt_action a b =
  if not (Int.equal (prompt_action_rank a) (prompt_action_rank b)) then false
  else
    match (a, b) with
    | Prompt_set x, Prompt_set y ->
        String.equal x.key y.key && Option.equal String.equal x.value y.value
    | Prompt_clear x, Prompt_clear y | Param_clear x, Param_clear y ->
        String.equal x y
    | Param_set x, Param_set y ->
        String.equal x.key y.key
        && Option.equal String.equal x.value_raw y.value_raw
    | (Prompt_set _ | Prompt_clear _ | Param_set _ | Param_clear _), _ -> false

let preset_action_rank = function
  | Preset_list -> 0
  | Preset_show _ -> 1
  | Preset_save _ -> 2
  | Preset_create _ -> 3
  | Preset_restore _ -> 4
  | Preset_delete _ -> 5

let equal_preset_action a b =
  if not (Int.equal (preset_action_rank a) (preset_action_rank b)) then false
  else
    match (a, b) with
    | Preset_list, Preset_list -> true
    | Preset_show x, Preset_show y
    | Preset_restore x, Preset_restore y
    | Preset_delete x, Preset_delete y ->
        String.equal x y
    | Preset_save x, Preset_save y ->
        String.equal x.name y.name && String.equal x.description y.description
    | Preset_create x, Preset_create y ->
        Option.equal String.equal x.name y.name
        && String.equal x.description y.description
    | ( Preset_list
      | Preset_show _
      | Preset_save _
      | Preset_create _
      | Preset_restore _
      | Preset_delete _ ),
      _ ->
        false

let lane_action_rank = function
  | Lane_create _ -> 0
  | Lane_remove _ -> 1
  | Lane_rename _ -> 2
  | Lane_set _ -> 3
  | Lane_exact_append _ -> 4
  | Lane_exact_drop _ -> 5
  | Lane_exact_move _ -> 6
  | Lane_exact_replace _ -> 7
  | Lane_run_inspect _ -> 8
  | Lane_quarantines _ -> 9
  | Lane_quarantine_recover _ -> 10
  | Lane_raw_preview -> 11

let equal_move_dir a b =
  match (a, b) with
  | `Up, `Up | `Down, `Down | `First, `First -> true
  | `Up, (`Down | `First) | `Down, (`Up | `First) | `First, (`Up | `Down) ->
      false

let equal_lane_action a b =
  if not (Int.equal (lane_action_rank a) (lane_action_rank b)) then false
  else
    match (a, b) with
    | Lane_create x, Lane_create y ->
        String.equal x.lane y.lane
        && List.equal String.equal x.runtime_ids y.runtime_ids
    | Lane_set x, Lane_set y ->
        String.equal x.lane y.lane
        && List.equal String.equal x.runtime_ids y.runtime_ids
    | Lane_remove x, Lane_remove y
    | Lane_run_inspect x, Lane_run_inspect y
    | Lane_quarantines x, Lane_quarantines y ->
        String.equal x y
    | Lane_rename x, Lane_rename y ->
        String.equal x.lane y.lane && String.equal x.to_lane y.to_lane
    | Lane_exact_append x, Lane_exact_append y ->
        String.equal x.lane_id y.lane_id
        && String.equal x.runtime_id y.runtime_id
    | Lane_exact_drop x, Lane_exact_drop y ->
        String.equal x.lane_id y.lane_id
        && String.equal x.runtime_id y.runtime_id
    | Lane_exact_move x, Lane_exact_move y ->
        String.equal x.lane_id y.lane_id
        && String.equal x.runtime_id y.runtime_id
        && equal_move_dir x.direction y.direction
    | Lane_exact_replace x, Lane_exact_replace y ->
        String.equal x.lane_id y.lane_id
        && String.equal x.runtime_id y.runtime_id
        && String.equal x.replacement y.replacement
    | Lane_quarantine_recover x, Lane_quarantine_recover y ->
        String.equal x.keeper y.keeper
        && String.equal x.partition_id y.partition_id
        && String.equal x.candidate_id y.candidate_id
        && String.equal x.quarantine_id y.quarantine_id
    | Lane_raw_preview, Lane_raw_preview -> true
    | ( Lane_create _
      | Lane_remove _
      | Lane_rename _
      | Lane_set _
      | Lane_exact_append _
      | Lane_exact_drop _
      | Lane_exact_move _
      | Lane_exact_replace _
      | Lane_run_inspect _
      | Lane_quarantines _
      | Lane_quarantine_recover _
      | Lane_raw_preview ),
      _ ->
        false

let addon_action_rank = function
  | Addon_attach _ -> 0
  | Addon_detach _ -> 1
  | Addon_observe _ -> 2
  | Addon_retain _ -> 3
  | Addon_act _ -> 4
  | Addon_evidence _ -> 5
  | Addon_decl_read _ -> 6
  | Addon_decl_new _ -> 7
  | Addon_slice _ -> 8
  | Addon_asks _ -> 9
  | Addon_ask_answer _ -> 10
  | Addon_operator _ -> 11

let equal_addon_action a b =
  if not (Int.equal (addon_action_rank a) (addon_action_rank b)) then false
  else
    match (a, b) with
    | Addon_attach x, Addon_attach y ->
        String.equal x.manifest_path y.manifest_path
        && String.equal x.run_id y.run_id
        && Option.equal String.equal x.binding_json y.binding_json
    | Addon_detach x, Addon_detach y
    | Addon_observe x, Addon_observe y
    | Addon_retain x, Addon_retain y
    | Addon_decl_read x, Addon_decl_read y
    | Addon_decl_new x, Addon_decl_new y ->
        String.equal x y
    | Addon_act x, Addon_act y ->
        String.equal x.instance_id y.instance_id
        && Option.equal String.equal x.action_json y.action_json
    | Addon_evidence x, Addon_evidence y ->
        String.equal x.instance_id y.instance_id
        && List.equal String.equal x.row_ids y.row_ids
        && Option.equal String.equal x.keeper_name y.keeper_name
    | Addon_slice x, Addon_slice y ->
        Option.equal String.equal x.run_id y.run_id
        && Option.equal String.equal x.lane_id y.lane_id
    | Addon_asks x, Addon_asks y ->
        Bool.equal x.include_resolved y.include_resolved
    | Addon_ask_answer x, Addon_ask_answer y ->
        String.equal x.declaration_id y.declaration_id
        && String.equal x.ask_id y.ask_id
        && String.equal x.answers_json y.answers_json
    | Addon_operator x, Addon_operator y ->
        String.equal x.instance_id y.instance_id
        && Option.equal String.equal x.args_json y.args_json
    | ( Addon_attach _
      | Addon_detach _
      | Addon_observe _
      | Addon_retain _
      | Addon_act _
      | Addon_evidence _
      | Addon_decl_read _
      | Addon_decl_new _
      | Addon_slice _
      | Addon_asks _
      | Addon_ask_answer _
      | Addon_operator _ ),
      _ ->
        false

let browser_action_rank = function
  | Browser_scene _ -> 0
  | Browser_screenshot _ -> 1
  | Browser_interact _ -> 2
  | Browser_command _ -> 3

let equal_browser_action a b =
  if not (Int.equal (browser_action_rank a) (browser_action_rank b)) then false
  else
    match (a, b) with
    | Browser_scene x, Browser_scene y ->
        Option.equal String.equal x.client_id y.client_id
        && Option.equal Int.equal x.tab_id y.tab_id
        && (match (x.view, y.view) with
           | `Content, `Content | `Regions, `Regions -> true
           | `Content, `Regions | `Regions, `Content -> false)
    | Browser_screenshot x, Browser_screenshot y ->
        Option.equal String.equal x.client_id y.client_id
        && Option.equal Int.equal x.tab_id y.tab_id
    | Browser_interact x, Browser_interact y ->
        Option.equal String.equal x.client_id y.client_id
        && Option.equal Int.equal x.tab_id y.tab_id
        && Option.equal String.equal x.action y.action
        && Option.equal String.equal x.selector y.selector
        && Option.equal String.equal x.text y.text
    | Browser_command x, Browser_command y -> String.equal x y
    | ( Browser_scene _
      | Browser_screenshot _
      | Browser_interact _
      | Browser_command _ ),
      _ ->
        false

let equal_music_action a b =
  match (a, b) with
  | Music_workbench, Music_workbench -> true
  | Music_import_midi x, Music_import_midi y -> String.equal x y
  | (Music_workbench | Music_import_midi _), _ -> false

let parsed_tag = function
  | Pulse -> 0
  | Work -> 1
  | Knowledge -> 2
  | Keepers -> 3
  | Runtime -> 4
  | Infra -> 5
  | Keeper _ -> 6
  | Model _ -> 7
  | Config _ -> 8
  | Incidents -> 9
  | Jump -> 10
  | Voice -> 11
  | Btw _ -> 12
  | Wake _ -> 13
  | Up _ -> 14
  | Resume _ -> 15
  | Pause _ -> 16
  | Down _ -> 17
  | Queue -> 18
  | Context -> 19
  | Ctl _ -> 20
  | Gate _ -> 21
  | Exec _ -> 22
  | Skill _ -> 23
  | Prompt _ -> 24
  | Preset _ -> 25
  | Lane _ -> 26
  | Addon _ -> 27
  | Browser _ -> 28
  | Tools _ -> 29
  | Clear -> 30
  | Theme _ -> 31
  | Lang _ -> 32
  | Help -> 33
  | Restart -> 34
  | Quit -> 35
  | Music _ -> 36

let equal_parsed a b =
  if not (Int.equal (parsed_tag a) (parsed_tag b)) then false
  else
    match (a, b) with
    | Keeper x, Keeper y -> Option.equal String.equal x y
    | Model x, Model y -> Option.equal String.equal x y
    | Config x, Config y -> Option.equal String.equal x y
    | Btw x, Btw y -> String.equal x y
    | Wake x, Wake y -> Option.equal String.equal x y
    | Up x, Up y -> Option.equal String.equal x y
    | Resume x, Resume y -> Option.equal String.equal x y
    | Pause x, Pause y -> Option.equal String.equal x y
    | Down x, Down y -> Option.equal String.equal x y
    | Ctl x, Ctl y ->
        equal_keeper_ctl_action x.action y.action
        && Option.equal String.equal x.target y.target
    | Gate x, Gate y -> equal_gate_action x y
    | Exec x, Exec y ->
        String.equal x.tool_name y.tool_name
        && Option.equal String.equal x.args_json y.args_json
    | Skill x, Skill y -> equal_skill_action x y
    | Prompt x, Prompt y -> equal_prompt_action x y
    | Preset x, Preset y -> equal_preset_action x y
    | Lane x, Lane y -> equal_lane_action x y
    | Addon x, Addon y -> equal_addon_action x y
    | Browser x, Browser y -> equal_browser_action x y
    | Tools x, Tools y -> Option.equal equal_tools_mode x y
    | Theme x, Theme y -> Option.equal Theme.equal_preset x y
    | Lang x, Lang y -> Option.equal Say.equal_lang x y
    | Music x, Music y -> equal_music_action x y
    | Pulse, Pulse
    | Work, Work
    | Knowledge, Knowledge
    | Keepers, Keepers
    | Runtime, Runtime
    | Infra, Infra
    | Incidents, Incidents
    | Jump, Jump
    | Voice, Voice
    | Queue, Queue
    | Context, Context
    | Clear, Clear
    | Help, Help
    | Restart, Restart
    | Quit, Quit ->
        true
    | ( Pulse
      | Work
      | Knowledge
      | Keepers
      | Runtime
      | Infra
      | Keeper _
      | Model _
      | Config _
      | Incidents
      | Jump
      | Voice
      | Btw _
      | Wake _
      | Up _
      | Resume _
      | Pause _
      | Down _
      | Queue
      | Context
      | Ctl _
      | Gate _
      | Exec _
      | Skill _
      | Prompt _
      | Preset _
      | Lane _
      | Addon _
      | Browser _
      | Tools _
      | Clear
      | Theme _
      | Lang _
      | Help
      | Restart
      | Quit
      | Music _ ),
      _ ->
        false

let equal_parse_error a b =
  match (a, b) with
  | Not_a_slash_command, Not_a_slash_command -> true
  | Empty_command, Empty_command -> true
  | Unknown_command x, Unknown_command y -> String.equal x y
  | Unexpected_argument x, Unexpected_argument y ->
      String.equal x.command y.command && String.equal x.arg y.arg
  | Invalid_argument x, Invalid_argument y ->
      String.equal x.command y.command
      && Say.equal x.expected y.expected
      && String.equal x.got y.got
  | ( Not_a_slash_command
    | Empty_command
    | Unknown_command _
    | Unexpected_argument _
    | Invalid_argument _ ),
    _ ->
      false

let mk id name ?arg_hint ~ko ~en category =
  { id; name; arg_hint; description = Say.make ~ko ~en; category }

let all : spec list =
  [
    mk Cmd_pulse "/pulse" ~ko:"펄스 대시보드 열기" ~en:"Jump to Pulse cockpit"
      Slash_navigation;
    mk Cmd_work "/work" ~ko:"작업(목표·태스크·승인·Candle) 열기"
      ~en:"Jump to Work workspace" Slash_navigation;
    mk Cmd_knowledge "/knowledge" ~ko:"지식(보드·위키·기억 Diff) 열기"
      ~en:"Jump to Knowledge workspace" Slash_navigation;
    mk Cmd_keepers "/keepers" ~ko:"키퍼 플릿 및 라이브 채팅 열기"
      ~en:"Jump to Keepers workspace" Slash_navigation;
    mk Cmd_runtime "/runtime" ~ko:"런타임(한도·효율·페일오버·도구) 열기"
      ~en:"Jump to Runtime workspace" Slash_navigation;
    mk Cmd_infra "/infra" ~ko:"인프라(샌드박스·리포·로그) 열기"
      ~en:"Jump to Infra workspace" Slash_navigation;
    mk Cmd_keeper "/keeper"
      ~arg_hint:(Say.make ~ko:"[이름]" ~en:"[name]")
      ~ko:"키퍼 전환기 열기 또는 지정 키퍼로 바로 진입"
      ~en:"Open Keeper switcher or jump to named keeper" Slash_pickers;
    mk Cmd_model "/model"
      ~arg_hint:(Say.make ~ko:"[레인]" ~en:"[lane]")
      ~ko:"런타임/모델 전환기 열기"
      ~en:"Open Model/Runtime switcher" Slash_pickers;
    mk Cmd_config "/config"
      ~arg_hint:(Say.make ~ko:"[검색어]" ~en:"[query]")
      ~ko:"7-탭 설정 오버레이 열기"
      ~en:"Open 7-tab Settings overlay" Slash_pickers;
    mk Cmd_incidents "/incidents" ~ko:"과거 장애·진단 이력 서랍 열기"
      ~en:"Open Historical Incidents drawer" Slash_pickers;
    mk Cmd_jump "/jump" ~ko:"가장 긴급한 대기/차단 항목으로 점프"
      ~en:"Teleport to highest-priority blocked item" Slash_interaction;
    mk Cmd_voice "/voice" ~ko:"음성 입력(PTT) 토글"
      ~en:"Toggle Voice Push-to-Talk" Slash_interaction;
    mk Cmd_btw "/btw"
      ~arg_hint:(Say.make ~ko:"<질문>" ~en:"<question>")
      ~ko:"현재 대화 흐름을 깨지 않는 일회성 사이드 질문"
      ~en:"Ask an ephemeral side-query without polluting thread" Slash_interaction;
    mk Cmd_wake "/wake"
      ~arg_hint:(Say.make ~ko:"[이름]" ~en:"[name]")
      ~ko:"키퍼 깨우기 · 온라인 전환 · 일시정지 해제"
      ~en:"Wake, bring online, or resume a keeper" Slash_interaction;
    mk Cmd_up "/up"
      ~arg_hint:(Say.make ~ko:"[이름]" ~en:"[name]")
      ~ko:"키퍼 온라인 부팅 (/boot 별칭 · 일시정지 시 자동 재개)"
      ~en:"Bring keeper online (alias /boot; auto-resumes if paused)"
      Slash_interaction;
    mk Cmd_resume "/resume"
      ~arg_hint:(Say.make ~ko:"[이름]" ~en:"[name]")
      ~ko:"일시정지·중지된 키퍼 재개"
      ~en:"Resume a paused or stopped keeper" Slash_interaction;
    mk Cmd_pause "/pause"
      ~arg_hint:(Say.make ~ko:"[이름]" ~en:"[name]")
      ~ko:"키퍼 일시정지"
      ~en:"Pause a keeper" Slash_interaction;
    mk Cmd_down "/down"
      ~arg_hint:(Say.make ~ko:"[이름]" ~en:"[name]")
      ~ko:"키퍼 중지 (오프라인)"
      ~en:"Shut down a keeper (offline)" Slash_interaction;
    mk Cmd_queue "/queue" ~ko:"키퍼 큐 서랍 열기"
      ~en:"Open Keeper Queue drawer" Slash_interaction;
    mk Cmd_context "/context" ~ko:"키퍼 컨텍스트 윈도우 및 캐시 서랍 열기"
      ~en:"Open Keeper Context & Cache drawer" Slash_display;
    mk Cmd_ctl "/ctl"
      ~arg_hint:
        (Say.make
           ~ko:"<boot|up|shutdown|pause|resume|wakeup|reset|clear|checkpoints|purge-preview|purge-apply|delete-history|note|run-next> [대상]"
           ~en:"<boot|up|shutdown|pause|resume|wakeup|reset|clear|checkpoints|purge-preview|purge-apply|delete-history|note|run-next> [target]")
      ~ko:"키퍼 수명주기·체크포인트·운영자 노트·우선실행 제어"
      ~en:"Keeper lifecycle, checkpoints, operator note, and run-next control"
      Slash_interaction;
    mk Cmd_gate "/gate"
      ~arg_hint:
        (Say.make
           ~ko:"<mode|external-mode|del-rule|approve-always|retry|keeper-mode|ack-uncertain|restore-late> ..."
           ~en:"<mode|external-mode|del-rule|approve-always|retry|keeper-mode|ack-uncertain|restore-late> ...")
      ~ko:"HITL 게이트 모드·규칙·재시도·키퍼 승인모드·지연승인 복구"
      ~en:"HITL gate mode, always-approve rules, retry, keeper approval mode & recovery"
      Slash_interaction;
    mk Cmd_exec "/exec"
      ~arg_hint:
        (Say.make ~ko:"<tool_name> [json_args]" ~en:"<tool_name> [json_args]")
      ~ko:"MCP 도구 대화형 실행 (POST /mcp tools/call)"
      ~en:"Execute MCP tool interactively via POST /mcp tools/call"
      Slash_interaction;
    mk Cmd_skill "/skill"
      ~arg_hint:
        (Say.make ~ko:"<refresh|new|read|edit|delete> [ref]"
           ~en:"<refresh|new|read|edit|delete> [ref]")
      ~ko:"스킬 카탈로그 새로고침 · 생성 · 열람 · 편집 · 삭제"
      ~en:"Refresh, create, read, edit, or delete Skill packages"
      Slash_interaction;
    mk Cmd_prompt "/prompt"
      ~arg_hint:
        (Say.make ~ko:"<set|clear|param-set|param-clear> <key> [value]"
           ~en:"<set|clear|param-set|param-clear> <key> [value]")
      ~ko:"프롬프트 오버라이드 및 런타임 파라미터 설정/해제"
      ~en:"Override/clear prompts and set/clear runtime parameters"
      Slash_interaction;
    mk Cmd_preset "/preset"
      ~arg_hint:
        (Say.make ~ko:"<list|show|save|create|restore|delete> [name]"
           ~en:"<list|show|save|create|restore|delete> [name]")
      ~ko:"프롬프트 프리셋 조회 · 저장 · 생성 · 복원 · 삭제"
      ~en:"List, inspect, save, create, restore, or delete prompt presets"
      Slash_interaction;
    mk Cmd_lane "/lane"
      ~arg_hint:
        (Say.make
           ~ko:"<create|remove|rename|set|exact-append|exact-drop|exact-move|exact-replace|run|quarantines|recover|raw-preview> ..."
           ~en:"<create|remove|rename|set|exact-append|exact-drop|exact-move|exact-replace|run|quarantines|recover|raw-preview> ...")
      ~ko:"런타임 페일오버·Exact 레인 CRUD/재정렬, 실행 드릴다운, 격리 복구"
      ~en:"Failover/Exact lane CRUD & reorder, run drill-down, quarantine recovery"
      Slash_interaction;
    mk Cmd_addon "/addon"
      ~arg_hint:
        (Say.make
           ~ko:"<attach|detach|observe|retain|act|evidence|decl-read|decl-new|slice|asks|answer|operator> ..."
           ~en:"<attach|detach|observe|retain|act|evidence|decl-read|decl-new|slice|asks|answer|operator> ...")
      ~ko:"레인 애드온 운영 제어 (attach/detach/observe/act/선언/질문 응답)"
      ~en:"Lane Add-ons operator control (attach, detach, observe, act, decl, asks)"
      Slash_interaction;
    mk Cmd_browser "/browser"
      ~arg_hint:
        (Say.make ~ko:"<scene|screenshot|interact|command> ..."
           ~en:"<scene|screenshot|interact|command> ...")
      ~ko:"브라우저 레인 제어 (장면 조회 · 스크린샷 · 인터랙션 · 명령)"
      ~en:"Browser lane control (scene, screenshot, interact, command)"
      Slash_interaction;
    mk Cmd_tools "/tools"
      ~arg_hint:(Say.make ~ko:"[compact|results|full]" ~en:"[compact|results|full]")
      ~ko:"도구 상세 표시 모드 전환"
      ~en:"Toggle or set tool call detail mode" Slash_display;
    mk Cmd_clear "/clear" ~ko:"현재 컴포저 초안 또는 화면 필터 초기화"
      ~en:"Clear active composer draft or filter" Slash_display;
    mk Cmd_theme "/theme"
      ~arg_hint:(Say.make ~ko:"[midnight|arcade_hi|paper_light|mono]" ~en:"[midnight|arcade_hi|paper_light|mono]")
      ~ko:"테마 프리셋 변경"
      ~en:"Switch color theme preset" Slash_display;
    mk Cmd_lang "/lang"
      ~arg_hint:(Say.make ~ko:"[ko|en]" ~en:"[ko|en]")
      ~ko:"UI 언어 전환 (한국어/English)"
      ~en:"Switch UI language (ko/en)" Slash_display;
    mk Cmd_help "/help" ~ko:"동적 단축키 및 명령 도움말 열기"
      ~en:"Open dynamic keymap & command help" Slash_session;
    mk Cmd_restart "/restart" ~ko:"TUI 세션 안전 재시작 요청"
      ~en:"Request graceful TUI restart" Slash_session;
    mk Cmd_quit "/quit" ~ko:"MASC TUI 안전 종료"
      ~en:"Quit MASC TUI cleanly" Slash_session;
  ]

let tools_mode_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "compact" -> Some Tools_compact
  | "results" -> Some Tools_results
  | "full" -> Some Tools_full
  | _ -> None

let keeper_ctl_action_names =
  [
    "boot";
    "up";
    "shutdown";
    "pause";
    "resume";
    "wakeup";
    "reset";
    "clear";
    "checkpoints";
    "purge-preview";
    "purge-apply";
    "delete-history";
    "note";
    "run-next";
  ]

let keeper_ctl_action_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "boot" -> Some Ctl_boot
  | "up" -> Some Ctl_up
  | "shutdown" -> Some Ctl_shutdown
  | "pause" -> Some Ctl_pause
  | "resume" -> Some Ctl_resume
  | "wakeup" -> Some Ctl_wakeup
  | "reset" -> Some Ctl_reset
  | "clear" -> Some Ctl_clear
  | "checkpoints" -> Some Ctl_checkpoints
  | "purge-preview" -> Some Ctl_purge_preview
  | "purge-apply" -> Some Ctl_purge_apply
  | "delete-history" -> Some Ctl_delete_history
  | "note" -> Some Ctl_note
  | "run-next" -> Some Ctl_run_next
  | _ -> None

let no_arg cmd value rest =
  match rest with
  | None -> Ok value
  | Some arg -> Error (Unexpected_argument { command = cmd; arg })

let split_command_and_arg trimmed =
  let len = String.length trimmed in
  let rec find_ws i =
    if i >= len then len
    else
      match trimmed.[i] with
      | ' ' | '\t' | '\n' | '\r' -> i
      | _ -> find_ws (i + 1)
  in
  let ws = find_ws 0 in
  let cmd = String.lowercase_ascii (String.sub trimmed 0 ws) in
  let arg =
    if ws >= len then None
    else
      let rest = String.trim (String.sub trimmed ws (len - ws)) in
      if String.length rest = 0 then None else Some rest
  in
  (cmd, arg)

(* The commands [parse] accepts and [all] does not list. This is the one place
   that names them; [parse] and [filter] both go through it. *)
type unlisted_word = Music_word

let unlisted_word_of_command = function
  | "/music" -> Some Music_word
  | _ -> None

let parse_music ~cmd arg =
  match arg with
  | None -> Ok (Music Music_workbench)
  | Some raw_arg -> (
      match split_command_and_arg raw_arg with
      | "midi", Some path -> Ok (Music (Music_import_midi path))
      | _ ->
          Error
            (Invalid_argument
               {
                 command = cmd;
                 expected =
                   Say.make ~ko:"인자 없음 | midi <파일 경로>"
                     ~en:"no argument | midi <file path>";
                 got = raw_arg;
               }))

let parse raw =
  let trimmed = String.trim raw in
  if String.length trimmed = 0 || not (Char.equal trimmed.[0] '/') then
    Error Not_a_slash_command
  else if String.length trimmed = 1 then Error Empty_command
  else
    let cmd, arg = split_command_and_arg trimmed in
    match cmd with
    | "/pulse" -> no_arg cmd Pulse arg
    | "/work" -> no_arg cmd Work arg
    | "/knowledge" -> no_arg cmd Knowledge arg
    | "/keepers" -> no_arg cmd Keepers arg
    | "/runtime" -> no_arg cmd Runtime arg
    | "/infra" -> no_arg cmd Infra arg
    | "/keeper" -> Ok (Keeper arg)
    | "/model" -> Ok (Model arg)
    | "/config" -> Ok (Config arg)
    | "/incidents" -> no_arg cmd Incidents arg
    | "/jump" -> no_arg cmd Jump arg
    | "/voice" -> no_arg cmd Voice arg
    | "/btw" -> (
        match arg with
        | Some q -> Ok (Btw q)
        | None ->
            Error
              (Invalid_argument
                 {
                   command = cmd;
                   expected = Say.make ~ko:"비어 있지 않은 질문" ~en:"non-empty question";
                   got = "";
                 }))
    | "/wake" -> Ok (Wake arg)
    | "/up" | "/boot" -> Ok (Up arg)
    | "/resume" -> Ok (Resume arg)
    | "/pause" -> Ok (Pause arg)
    | "/down" -> Ok (Down arg)
    | "/queue" -> no_arg cmd Queue arg
    | "/context" -> no_arg cmd Context arg
    | "/ctl" -> (
        match arg with
        | None ->
            Error
              (Invalid_argument
                 {
                   command = cmd;
                   expected =
                     Say.make
                       ~ko:"boot|up|shutdown|pause|resume|wakeup|reset|clear|checkpoints|purge-preview|purge-apply|delete-history|note|run-next"
                       ~en:"boot|up|shutdown|pause|resume|wakeup|reset|clear|checkpoints|purge-preview|purge-apply|delete-history|note|run-next";
                   got = "";
                 })
        | Some raw_arg -> (
            let act_raw, target = split_command_and_arg raw_arg in
            match keeper_ctl_action_of_string act_raw with
            | Some action -> Ok (Ctl { action; target })
            | None ->
                Error
                  (Invalid_argument
                     {
                       command = cmd;
                       expected =
                         Say.make
                           ~ko:"boot|up|shutdown|pause|resume|wakeup|reset|clear|checkpoints|purge-preview|purge-apply|delete-history|note|run-next"
                           ~en:"boot|up|shutdown|pause|resume|wakeup|reset|clear|checkpoints|purge-preview|purge-apply|delete-history|note|run-next";
                       got = act_raw;
                     })))
    | "/gate" -> (
        let valid_gate_mode s =
          match String.lowercase_ascii (String.trim s) with
          | ("manual" | "auto_judge" | "always_allow") as m -> Some m
          | _ -> None
        in
        let valid_keeper_mode s =
          match String.lowercase_ascii (String.trim s) with
          | ("auto" | "yolo") as m -> Some m
          | _ -> None
        in
        let invalid ~expected got =
          Error (Invalid_argument { command = cmd; expected; got })
        in
        match arg with
        | None ->
            invalid
              ~expected:
                (Say.literal
                   "mode|external-mode|del-rule|approve-always|retry|keeper-mode|ack-uncertain|restore-late")
              ""
        | Some raw_arg -> (
            let sub_raw, rest = split_command_and_arg raw_arg in
            let sub = String.lowercase_ascii sub_raw in
            let require_single_token ~cmd_label value =
              let first, extra = split_command_and_arg value in
              match extra with
              | None -> Ok first
              | Some tok ->
                  Error (Unexpected_argument { command = cmd_label; arg = tok })
            in
            match (sub, rest) with
            | "mode", Some m -> (
                match valid_gate_mode m with
                | Some mode -> Ok (Gate (Gate_mode_set mode))
                | None ->
                    invalid
                      ~expected:(Say.literal "manual | auto_judge | always_allow")
                      m)
            | "mode", None ->
                invalid
                  ~expected:(Say.literal "manual | auto_judge | always_allow")
                  ""
            | "external-mode", Some m -> (
                match valid_gate_mode m with
                | Some mode -> Ok (Gate (Gate_external_mode_set mode))
                | None ->
                    invalid
                      ~expected:(Say.literal "manual | auto_judge | always_allow")
                      m)
            | "external-mode", None ->
                invalid
                  ~expected:(Say.literal "manual | auto_judge | always_allow")
                  ""
            | "del-rule", Some rid_raw -> (
                match require_single_token ~cmd_label:"/gate del-rule" rid_raw with
                | Ok rid -> Ok (Gate (Gate_rule_delete rid))
                | Error _ as err -> err)
            | "del-rule", None ->
                invalid ~expected:(Say.literal "<rule_id>") ""
            | "approve-always", Some aid_raw -> (
                match
                  require_single_token ~cmd_label:"/gate approve-always" aid_raw
                with
                | Ok aid -> Ok (Gate (Gate_approve_always aid))
                | Error _ as err -> err)
            | "approve-always", None ->
                invalid ~expected:(Say.literal "<approval_id>") ""
            | "retry", Some aid_raw -> (
                match require_single_token ~cmd_label:"/gate retry" aid_raw with
                | Ok aid -> Ok (Gate (Gate_retry aid))
                | Error _ as err -> err)
            | "retry", None ->
                invalid ~expected:(Say.literal "<approval_id>") ""
            | "keeper-mode", Some km_arg -> (
                let k, m_opt = split_command_and_arg km_arg in
                match m_opt with
                | Some m -> (
                    match valid_keeper_mode m with
                    | Some mode ->
                        Ok (Gate (Gate_keeper_mode_set { keeper = k; mode }))
                    | None ->
                        invalid ~expected:(Say.literal "auto | yolo") m)
                | None ->
                    invalid ~expected:(Say.literal "<keeper> <auto|yolo>") km_arg)
            | "keeper-mode", None ->
                invalid ~expected:(Say.literal "<keeper> <auto|yolo>") ""
            | "ack-uncertain", Some ack_arg -> (
                let k, cid_opt = split_command_and_arg ack_arg in
                match cid_opt with
                | Some cid_raw -> (
                    match
                      require_single_token ~cmd_label:"/gate ack-uncertain"
                        cid_raw
                    with
                    | Ok cid ->
                        Ok
                          (Gate
                             (Gate_ack_uncertain { keeper = k; consume_id = cid }))
                    | Error _ as err -> err)
                | None ->
                    invalid ~expected:(Say.literal "<keeper> <consume_id>")
                      ack_arg)
            | "ack-uncertain", None ->
                invalid ~expected:(Say.literal "<keeper> <consume_id>") ""
            | "restore-late", None -> Ok (Gate Gate_restore_late)
            | "restore-late", Some extra ->
                Error (Unexpected_argument { command = "/gate restore-late"; arg = extra })
            | other, _ ->
                invalid
                  ~expected:
                    (Say.literal
                       "mode|external-mode|del-rule|approve-always|retry|keeper-mode|ack-uncertain|restore-late")
                  other))
    | "/exec" -> (
        match arg with
        | None ->
            Error
              (Invalid_argument
                 {
                   command = cmd;
                   expected = Say.literal "<tool_name> [json_args]";
                   got = "";
                 })
        | Some raw_arg ->
            let tool_name, args_json = split_command_and_arg raw_arg in
            Ok (Exec { tool_name; args_json }))
    | "/skill" -> (
        let invalid ~expected got =
          Error (Invalid_argument { command = cmd; expected; got })
        in
        match arg with
        | None ->
            invalid ~expected:(Say.literal "refresh|new|read|edit|delete") ""
        | Some raw_arg -> (
            let sub_raw, rest = split_command_and_arg raw_arg in
            let sub = String.lowercase_ascii sub_raw in
            match (sub, rest) with
            | "refresh", None -> Ok (Skill Skill_refresh)
            | "refresh", Some extra ->
                Error
                  (Unexpected_argument { command = "/skill refresh"; arg = extra })
            | "new", None -> Ok (Skill Skill_new)
            | "new", Some extra ->
                Error (Unexpected_argument { command = "/skill new"; arg = extra })
            | "read", Some r -> Ok (Skill (Skill_read r))
            | "read", None -> invalid ~expected:(Say.literal "<skill_ref>") ""
            | "edit", Some r -> Ok (Skill (Skill_edit r))
            | "edit", None -> invalid ~expected:(Say.literal "<skill_ref>") ""
            | "delete", Some r -> Ok (Skill (Skill_delete r))
            | "delete", None -> invalid ~expected:(Say.literal "<skill_ref>") ""
            | other, _ ->
                invalid ~expected:(Say.literal "refresh|new|read|edit|delete")
                  other))
    | "/prompt" -> (
        let invalid ~expected got =
          Error (Invalid_argument { command = cmd; expected; got })
        in
        match arg with
        | None ->
            invalid ~expected:(Say.literal "set|clear|param-set|param-clear") ""
        | Some raw_arg -> (
            let sub_raw, rest = split_command_and_arg raw_arg in
            let sub = String.lowercase_ascii sub_raw in
            match (sub, rest) with
            | "set", Some a ->
                let k, v = split_command_and_arg a in
                Ok (Prompt (Prompt_set { key = k; value = v }))
            | "set", None ->
                invalid ~expected:(Say.literal "<key> [value]") ""
            | "clear", Some a -> (
                let k, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Prompt (Prompt_clear k))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/prompt clear"; arg = tok }))
            | "clear", None -> invalid ~expected:(Say.literal "<key>") ""
            | "param-set", Some a ->
                let k, v = split_command_and_arg a in
                Ok (Prompt (Param_set { key = k; value_raw = v }))
            | "param-set", None ->
                invalid ~expected:(Say.literal "<param_key> [json_or_value]") ""
            | "param-clear", Some a -> (
                let k, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Prompt (Param_clear k))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/prompt param-clear"; arg = tok }))
            | "param-clear", None ->
                invalid ~expected:(Say.literal "<param_key>") ""
            | other, _ ->
                invalid
                  ~expected:(Say.literal "set|clear|param-set|param-clear")
                  other))
    | "/preset" -> (
        let invalid ~expected got =
          Error (Invalid_argument { command = cmd; expected; got })
        in
        match arg with
        | None -> Ok (Preset Preset_list)
        | Some raw_arg -> (
            let sub_raw, rest = split_command_and_arg raw_arg in
            let sub = String.lowercase_ascii sub_raw in
            match (sub, rest) with
            | "list", None -> Ok (Preset Preset_list)
            | "list", Some extra ->
                Error
                  (Unexpected_argument { command = "/preset list"; arg = extra })
            | "show", Some a -> (
                let name, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Preset (Preset_show name))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/preset show"; arg = tok }))
            | "show", None -> invalid ~expected:(Say.literal "<name>") ""
            | "save", Some a ->
                let name, desc_opt = split_command_and_arg a in
                Ok
                  (Preset
                     (Preset_save
                        { name; description = Option.value desc_opt ~default:"" }))
            | "save", None ->
                invalid ~expected:(Say.literal "<name> [description]") ""
            | "create", None ->
                Ok (Preset (Preset_create { name = None; description = "" }))
            | "create", Some a ->
                let name, desc_opt = split_command_and_arg a in
                Ok
                  (Preset
                     (Preset_create
                        {
                          name = Some name;
                          description = Option.value desc_opt ~default:"";
                        }))
            | "restore", Some a -> (
                let name, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Preset (Preset_restore name))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/preset restore"; arg = tok }))
            | "restore", None -> invalid ~expected:(Say.literal "<name>") ""
            | "delete", Some a -> (
                let name, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Preset (Preset_delete name))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/preset delete"; arg = tok }))
            | "delete", None -> invalid ~expected:(Say.literal "<name>") ""
            | other, _ ->
                invalid
                  ~expected:(Say.literal "list|show|save|create|restore|delete")
                  other))
    | "/lane" -> (
        let invalid ~expected got =
          Error (Invalid_argument { command = cmd; expected; got })
        in
        let split_csv s =
          String.split_on_char ',' s
          |> List.map String.trim
          |> List.filter (fun x -> not (String.equal x ""))
        in
        match arg with
        | None ->
            invalid
              ~expected:
                (Say.literal
                   "create|remove|rename|set|exact-append|exact-drop|exact-move|exact-replace|run|quarantines|recover|raw-preview")
              ""
        | Some raw_arg -> (
            let sub_raw, rest = split_command_and_arg raw_arg in
            let sub = String.lowercase_ascii sub_raw in
            match (sub, rest) with
            | "create", Some a -> (
                let lane, rids_opt = split_command_and_arg a in
                match rids_opt with
                | Some rids_s ->
                    let runtime_ids = split_csv rids_s in
                    if runtime_ids = [] then
                      invalid ~expected:(Say.literal "<lane> <r1,r2,...>") a
                    else Ok (Lane (Lane_create { lane; runtime_ids }))
                | None -> invalid ~expected:(Say.literal "<lane> <r1,r2,...>") a)
            | "create", None ->
                invalid ~expected:(Say.literal "<lane> <r1,r2,...>") ""
            | "remove", Some a -> (
                let lane, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Lane (Lane_remove lane))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/lane remove"; arg = tok }))
            | "remove", None -> invalid ~expected:(Say.literal "<lane>") ""
            | "rename", Some a -> (
                let lane, to_opt = split_command_and_arg a in
                match to_opt with
                | Some to_raw -> (
                    let to_lane, extra = split_command_and_arg to_raw in
                    match extra with
                    | None -> Ok (Lane (Lane_rename { lane; to_lane }))
                    | Some tok ->
                        Error
                          (Unexpected_argument
                             { command = "/lane rename"; arg = tok }))
                | None -> invalid ~expected:(Say.literal "<lane> <new_name>") a)
            | "rename", None ->
                invalid ~expected:(Say.literal "<lane> <new_name>") ""
            | "set", Some a -> (
                let lane, rids_opt = split_command_and_arg a in
                match rids_opt with
                | Some rids_s ->
                    let runtime_ids = split_csv rids_s in
                    if runtime_ids = [] then
                      invalid ~expected:(Say.literal "<lane> <r1,r2,...>") a
                    else Ok (Lane (Lane_set { lane; runtime_ids }))
                | None -> invalid ~expected:(Say.literal "<lane> <r1,r2,...>") a)
            | "set", None ->
                invalid ~expected:(Say.literal "<lane> <r1,r2,...>") ""
            | "exact-append", Some a -> (
                let lane_id, rid_opt = split_command_and_arg a in
                match rid_opt with
                | Some rid_raw -> (
                    let runtime_id, extra = split_command_and_arg rid_raw in
                    match extra with
                    | None ->
                        Ok (Lane (Lane_exact_append { lane_id; runtime_id }))
                    | Some tok ->
                        Error
                          (Unexpected_argument
                             { command = "/lane exact-append"; arg = tok }))
                | None ->
                    invalid ~expected:(Say.literal "<lane_id> <runtime_id>") a)
            | "exact-append", None ->
                invalid ~expected:(Say.literal "<lane_id> <runtime_id>") ""
            | "exact-drop", Some a -> (
                let lane_id, rid_opt = split_command_and_arg a in
                match rid_opt with
                | Some rid_raw -> (
                    let runtime_id, extra = split_command_and_arg rid_raw in
                    match extra with
                    | None ->
                        Ok (Lane (Lane_exact_drop { lane_id; runtime_id }))
                    | Some tok ->
                        Error
                          (Unexpected_argument
                             { command = "/lane exact-drop"; arg = tok }))
                | None ->
                    invalid ~expected:(Say.literal "<lane_id> <runtime_id>") a)
            | "exact-drop", None ->
                invalid ~expected:(Say.literal "<lane_id> <runtime_id>") ""
            | "exact-move", Some a -> (
                let lane_id, r1 = split_command_and_arg a in
                match r1 with
                | Some s1 -> (
                    let runtime_id, r2 = split_command_and_arg s1 in
                    match r2 with
                    | Some s2 -> (
                        let dir_raw, extra = split_command_and_arg s2 in
                        match extra with
                        | Some tok ->
                            Error
                              (Unexpected_argument
                                 { command = "/lane exact-move"; arg = tok })
                        | None -> (
                            match String.lowercase_ascii dir_raw with
                            | "up" ->
                                Ok
                                  (Lane
                                     (Lane_exact_move
                                        { lane_id; runtime_id; direction = `Up }))
                            | "down" ->
                                Ok
                                  (Lane
                                     (Lane_exact_move
                                        {
                                          lane_id;
                                          runtime_id;
                                          direction = `Down;
                                        }))
                            | "first" ->
                                Ok
                                  (Lane
                                     (Lane_exact_move
                                        {
                                          lane_id;
                                          runtime_id;
                                          direction = `First;
                                        }))
                            | other ->
                                invalid ~expected:(Say.literal "up|down|first")
                                  other))
                    | None ->
                        invalid
                          ~expected:
                            (Say.literal "<lane_id> <runtime_id> <up|down|first>")
                          a)
                | None ->
                    invalid
                      ~expected:
                        (Say.literal "<lane_id> <runtime_id> <up|down|first>")
                      a)
            | "exact-move", None ->
                invalid
                  ~expected:
                    (Say.literal "<lane_id> <runtime_id> <up|down|first>")
                  ""
            | "exact-replace", Some a -> (
                let lane_id, r1 = split_command_and_arg a in
                match r1 with
                | Some s1 -> (
                    let runtime_id, r2 = split_command_and_arg s1 in
                    match r2 with
                    | Some s2 -> (
                        let replacement, extra = split_command_and_arg s2 in
                        match extra with
                        | None ->
                            Ok
                              (Lane
                                 (Lane_exact_replace
                                    { lane_id; runtime_id; replacement }))
                        | Some tok ->
                            Error
                              (Unexpected_argument
                                 { command = "/lane exact-replace"; arg = tok }))
                    | None ->
                        invalid
                          ~expected:
                            (Say.literal
                               "<lane_id> <runtime_id> <replacement_id>")
                          a)
                | None ->
                    invalid
                      ~expected:
                        (Say.literal "<lane_id> <runtime_id> <replacement_id>")
                      a)
            | "exact-replace", None ->
                invalid
                  ~expected:
                    (Say.literal "<lane_id> <runtime_id> <replacement_id>")
                  ""
            | "run", Some a -> (
                let run_id, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Lane (Lane_run_inspect run_id))
                | Some tok ->
                    Error
                      (Unexpected_argument { command = "/lane run"; arg = tok }))
            | "run", None -> invalid ~expected:(Say.literal "<run_id>") ""
            | "quarantines", Some a -> (
                let keeper, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Lane (Lane_quarantines keeper))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/lane quarantines"; arg = tok }))
            | "quarantines", None ->
                invalid ~expected:(Say.literal "<keeper>") ""
            | "recover", Some a -> (
                let keeper, r1 = split_command_and_arg a in
                match r1 with
                | Some s1 -> (
                    let partition_id, r2 = split_command_and_arg s1 in
                    match r2 with
                    | Some s2 -> (
                        let candidate_id, r3 = split_command_and_arg s2 in
                        match r3 with
                        | Some s3 -> (
                            let quarantine_id, extra =
                              split_command_and_arg s3
                            in
                            match extra with
                            | None ->
                                Ok
                                  (Lane
                                     (Lane_quarantine_recover
                                        {
                                          keeper;
                                          partition_id;
                                          candidate_id;
                                          quarantine_id;
                                        }))
                            | Some tok ->
                                Error
                                  (Unexpected_argument
                                     { command = "/lane recover"; arg = tok }))
                        | None ->
                            invalid
                              ~expected:
                                (Say.literal
                                   "<keeper> <partition_id> <candidate_id> <quarantine_id>")
                              a)
                    | None ->
                        invalid
                          ~expected:
                            (Say.literal
                               "<keeper> <partition_id> <candidate_id> <quarantine_id>")
                          a)
                | None ->
                    invalid
                      ~expected:
                        (Say.literal
                           "<keeper> <partition_id> <candidate_id> <quarantine_id>")
                      a)
            | "recover", None ->
                invalid
                  ~expected:
                    (Say.literal
                       "<keeper> <partition_id> <candidate_id> <quarantine_id>")
                  ""
            | "raw-preview", None -> Ok (Lane Lane_raw_preview)
            | "raw-preview", Some extra ->
                Error
                  (Unexpected_argument
                     { command = "/lane raw-preview"; arg = extra })
            | other, _ ->
                invalid
                  ~expected:
                    (Say.literal
                       "create|remove|rename|set|exact-append|exact-drop|exact-move|exact-replace|run|quarantines|recover|raw-preview")
                  other))
    | "/addon" -> (
        let invalid ~expected got =
          Error (Invalid_argument { command = cmd; expected; got })
        in
        let split_csv s =
          String.split_on_char ',' s
          |> List.map String.trim
          |> List.filter (fun x -> not (String.equal x ""))
        in
        match arg with
        | None ->
            invalid
              ~expected:
                (Say.literal
                   "attach|detach|observe|retain|act|evidence|decl-read|decl-new|slice|asks|answer|operator")
              ""
        | Some raw_arg -> (
            let sub_raw, rest = split_command_and_arg raw_arg in
            let sub = String.lowercase_ascii sub_raw in
            match (sub, rest) with
            | "attach", Some a ->
                let manifest_path, r1 = split_command_and_arg a in
                let run_id, binding_json =
                  match r1 with
                  | None -> ("operator-run", None)
                  | Some s1 -> split_command_and_arg s1
                in
                Ok
                  (Addon
                     (Addon_attach { manifest_path; run_id; binding_json }))
            | "attach", None ->
                invalid
                  ~expected:
                    (Say.literal "<manifest_path> [run_id] [binding_json]")
                  ""
            | "detach", Some a -> (
                let id, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Addon (Addon_detach id))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/addon detach"; arg = tok }))
            | "detach", None -> invalid ~expected:(Say.literal "<instance_id>") ""
            | "observe", Some a -> (
                let id, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Addon (Addon_observe id))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/addon observe"; arg = tok }))
            | "observe", None ->
                invalid ~expected:(Say.literal "<instance_id>") ""
            | "retain", Some a -> (
                let id, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Addon (Addon_retain id))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/addon retain"; arg = tok }))
            | "retain", None -> invalid ~expected:(Say.literal "<instance_id>") ""
            | "act", Some a ->
                let instance_id, action_json = split_command_and_arg a in
                Ok (Addon (Addon_act { instance_id; action_json }))
            | "act", None ->
                invalid ~expected:(Say.literal "<instance_id> [action_json]") ""
            | "evidence", Some a -> (
                let instance_id, r1 = split_command_and_arg a in
                match r1 with
                | Some s1 ->
                    let rows_s, keeper_raw = split_command_and_arg s1 in
                    let row_ids = split_csv rows_s in
                    if row_ids = [] then
                      invalid
                        ~expected:
                          (Say.literal "<instance_id> <row1,row2> [keeper]")
                        a
                    else (
                      match keeper_raw with
                      | None ->
                          Ok
                            (Addon
                               (Addon_evidence
                                  { instance_id; row_ids; keeper_name = None }))
                      | Some kr -> (
                          let kp, extra = split_command_and_arg kr in
                          match extra with
                          | None ->
                              Ok
                                (Addon
                                   (Addon_evidence
                                      {
                                        instance_id;
                                        row_ids;
                                        keeper_name = Some kp;
                                      }))
                          | Some tok ->
                              Error
                                (Unexpected_argument
                                   { command = "/addon evidence"; arg = tok })))
                | None ->
                    invalid
                      ~expected:
                        (Say.literal "<instance_id> <row1,row2> [keeper]")
                      a)
            | "evidence", None ->
                invalid
                  ~expected:(Say.literal "<instance_id> <row1,row2> [keeper]")
                  ""
            | "decl-read", Some a -> Ok (Addon (Addon_decl_read a))
            | "decl-read", None ->
                invalid ~expected:(Say.literal "<source_path>") ""
            | "decl-new", Some a -> (
                let fn, extra = split_command_and_arg a in
                match extra with
                | None -> Ok (Addon (Addon_decl_new fn))
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/addon decl-new"; arg = tok }))
            | "decl-new", None ->
                invalid ~expected:(Say.literal "<file_name.toml>") ""
            | "slice", None ->
                Ok (Addon (Addon_slice { run_id = None; lane_id = None }))
            | "slice", Some a -> (
                let lane_id, run_raw = split_command_and_arg a in
                match run_raw with
                | None ->
                    Ok
                      (Addon
                         (Addon_slice
                            { run_id = None; lane_id = Some lane_id }))
                | Some rr -> (
                    let rid, extra = split_command_and_arg rr in
                    match extra with
                    | None ->
                        Ok
                          (Addon
                             (Addon_slice
                                { run_id = Some rid; lane_id = Some lane_id }))
                    | Some tok ->
                        Error
                          (Unexpected_argument
                             { command = "/addon slice"; arg = tok })))
            | "asks", None -> Ok (Addon (Addon_asks { include_resolved = false }))
            | "asks", Some a -> (
                match String.lowercase_ascii (String.trim a) with
                | "all" | "true" ->
                    Ok (Addon (Addon_asks { include_resolved = true }))
                | "open" | "false" ->
                    Ok (Addon (Addon_asks { include_resolved = false }))
                | other -> invalid ~expected:(Say.literal "open|all") other)
            | "answer", Some a -> (
                let declaration_id, r1 = split_command_and_arg a in
                match r1 with
                | Some s1 -> (
                    let ask_id, r2 = split_command_and_arg s1 in
                    match r2 with
                    | Some answers_json ->
                        Ok
                          (Addon
                             (Addon_ask_answer
                                { declaration_id; ask_id; answers_json }))
                    | None ->
                        invalid
                          ~expected:
                            (Say.literal
                               "<declaration_id> <ask_id> <answers_json>")
                          a)
                | None ->
                    invalid
                      ~expected:
                        (Say.literal "<declaration_id> <ask_id> <answers_json>")
                      a)
            | "answer", None ->
                invalid
                  ~expected:
                    (Say.literal "<declaration_id> <ask_id> <answers_json>")
                  ""
            | "operator", Some a ->
                let instance_id, args_json = split_command_and_arg a in
                Ok (Addon (Addon_operator { instance_id; args_json }))
            | "operator", None ->
                invalid ~expected:(Say.literal "<instance_id> [args_json]") ""
            | other, _ ->
                invalid
                  ~expected:
                    (Say.literal
                       "attach|detach|observe|retain|act|evidence|decl-read|decl-new|slice|asks|answer|operator")
                  other))
    | "/browser" -> (
        let invalid ~expected got =
          Error (Invalid_argument { command = cmd; expected; got })
        in
        match arg with
        | None ->
            invalid ~expected:(Say.literal "scene|screenshot|interact|command")
              ""
        | Some raw_arg -> (
            let sub_raw, rest = split_command_and_arg raw_arg in
            let sub = String.lowercase_ascii sub_raw in
            match (sub, rest) with
            | "scene", None ->
                Ok
                  (Browser
                     (Browser_scene
                        { client_id = None; tab_id = None; view = `Content }))
            | "scene", Some a -> (
                let first, second = split_command_and_arg a in
                match String.lowercase_ascii first with
                | "content" -> (
                    match second with
                    | None ->
                        Ok
                          (Browser
                             (Browser_scene
                                {
                                  client_id = None;
                                  tab_id = None;
                                  view = `Content;
                                }))
                    | Some tok ->
                        Error
                          (Unexpected_argument
                             { command = "/browser scene"; arg = tok }))
                | "regions" -> (
                    match second with
                    | None ->
                        Ok
                          (Browser
                             (Browser_scene
                                {
                                  client_id = None;
                                  tab_id = None;
                                  view = `Regions;
                                }))
                    | Some tok ->
                        Error
                          (Unexpected_argument
                             { command = "/browser scene"; arg = tok }))
                | _ -> (
                    match int_of_string_opt first with
                    | Some tid -> (
                        match second with
                        | None ->
                            Ok
                              (Browser
                                 (Browser_scene
                                    {
                                      client_id = None;
                                      tab_id = Some tid;
                                      view = `Content;
                                    }))
                        | Some v -> (
                            let v_tok, extra = split_command_and_arg v in
                            match extra with
                            | Some tok ->
                                Error
                                  (Unexpected_argument
                                     { command = "/browser scene"; arg = tok })
                            | None -> (
                                match String.lowercase_ascii v_tok with
                                | "content" ->
                                    Ok
                                      (Browser
                                         (Browser_scene
                                            {
                                              client_id = None;
                                              tab_id = Some tid;
                                              view = `Content;
                                            }))
                                | "regions" ->
                                    Ok
                                      (Browser
                                         (Browser_scene
                                            {
                                              client_id = None;
                                              tab_id = Some tid;
                                              view = `Regions;
                                            }))
                                | other ->
                                    invalid
                                      ~expected:(Say.literal "content|regions")
                                      other)))
                    | None ->
                        invalid
                          ~expected:
                            (Say.literal "[tab_id] [content|regions]")
                          first))
            | "screenshot", None ->
                Ok
                  (Browser
                     (Browser_screenshot { client_id = None; tab_id = None }))
            | "screenshot", Some a -> (
                let tid_s, extra = split_command_and_arg a in
                match extra with
                | Some tok ->
                    Error
                      (Unexpected_argument
                         { command = "/browser screenshot"; arg = tok })
                | None -> (
                    match int_of_string_opt tid_s with
                    | Some tid ->
                        Ok
                          (Browser
                             (Browser_screenshot
                                { client_id = None; tab_id = Some tid }))
                    | None -> invalid ~expected:(Say.literal "<tab_id>") tid_s))
            | "interact", None ->
                Ok
                  (Browser
                     (Browser_interact
                        {
                          client_id = None;
                          tab_id = None;
                          action = None;
                          selector = None;
                          text = None;
                        }))
            | "interact", Some a ->
                let act, r1 = split_command_and_arg a in
                let selector, text =
                  match r1 with
                  | None -> (None, None)
                  | Some s1 ->
                      let sel, txt = split_command_and_arg s1 in
                      (Some sel, txt)
                in
                Ok
                  (Browser
                     (Browser_interact
                        {
                          client_id = None;
                          tab_id = None;
                          action = Some (String.lowercase_ascii act);
                          selector;
                          text;
                        }))
            | "command", Some a -> Ok (Browser (Browser_command a))
            | "command", None ->
                invalid ~expected:(Say.literal "<json_object>") ""
            | other, _ ->
                invalid
                  ~expected:(Say.literal "scene|screenshot|interact|command")
                  other))
    | "/tools" -> (
        match arg with
        | None -> Ok (Tools None)
        | Some raw_mode -> (
            match tools_mode_of_string raw_mode with
            | Some mode -> Ok (Tools (Some mode))
            | None ->
                Error
                  (Invalid_argument
                     {
                       command = cmd;
                       expected =
                         Say.make ~ko:"compact | results | full"
                           ~en:"compact | results | full";
                       got = raw_mode;
                     })))
    | "/clear" -> no_arg cmd Clear arg
    | "/theme" -> (
        match arg with
        | None -> Ok (Theme None)
        | Some raw_theme -> (
            match Theme.preset_of_name raw_theme with
            | Some preset -> Ok (Theme (Some preset))
            | None ->
                Error
                  (Invalid_argument
                     {
                       command = cmd;
                       expected =
                         Say.make
                           ~ko:"midnight | arcade_hi | paper_light | mono"
                           ~en:"midnight | arcade_hi | paper_light | mono";
                       got = raw_theme;
                     })))
    | "/lang" -> (
        match arg with
        | None -> Ok (Lang None)
        | Some raw_lang -> (
            match Say.lang_of_code raw_lang with
            | Some lang -> Ok (Lang (Some lang))
            | None ->
                Error
                  (Invalid_argument
                     {
                       command = cmd;
                       expected = Say.make ~ko:"ko | en" ~en:"ko | en";
                       got = raw_lang;
                     })))
    | "/help" -> no_arg cmd Help arg
    | "/restart" -> no_arg cmd Restart arg
    | "/quit" -> no_arg cmd Quit arg
    | other -> (
        match unlisted_word_of_command other with
        | Some Music_word -> parse_music ~cmd arg
        | None -> Error (Unknown_command other))

(* UTF-8 Unicode scalar decomposition with ASCII case-folding so multi-byte
   Hangul/CJK syllables never produce byte-prefix false positives. *)
let utf8_scalars_lower s =
  let len = String.length s in
  let acc = ref [] in
  let i = ref 0 in
  while !i < len do
    let d = String.get_utf_8_uchar s !i in
    let step = Uchar.utf_decode_length d in
    let u = Uchar.utf_decode_uchar d in
    let code = Uchar.to_int u in
    let folded =
      if code >= 65 && code <= 90 then code + 32 else code
    in
    acc := folded :: !acc;
    i := !i + Int.max 1 step
  done;
  Array.of_list (List.rev !acc)

(* Deterministic Unicode-scalar subsequence score: lower is better; [None] means no match. *)
let fuzzy_score ~needle ~haystack =
  let n_arr = utf8_scalars_lower needle in
  let h_arr = utf8_scalars_lower haystack in
  let n_len = Array.length n_arr in
  let h_len = Array.length h_arr in
  if n_len = 0 then Some 0
  else if n_len > h_len then None
  else
    let starts =
      let rec chk i =
        if i >= n_len then true
        else if Int.equal n_arr.(i) h_arr.(i) then chk (i + 1)
        else false
      in
      chk 0
    in
    if starts then Some (h_len - n_len)
    else
      let rec walk ni hi score last_match =
        if ni >= n_len then Some (100 + score + (h_len - hi))
        else if hi >= h_len then None
        else if Int.equal n_arr.(ni) h_arr.(hi) then
          let gap = if last_match < 0 then hi else hi - last_match - 1 in
          walk (ni + 1) (hi + 1) (score + (gap * 3)) hi
        else walk ni (hi + 1) score last_match
      in
      walk 0 0 0 (-1)

let strip_leading_slash s =
  let trimmed = String.trim s in
  if String.length trimmed > 0 && Char.equal trimmed.[0] '/' then
    String.sub trimmed 1 (String.length trimmed - 1)
  else trimmed

(* An exactly typed unlisted command must not fuzzy-match a listed one. In the
   English UI "music" is a subsequence of the description "Open Model/Runtime
   switcher", and Enter on that popup would run /model instead. [needle] is
   the typed text without its slash; only its first word names the command. *)
let is_unlisted_word needle =
  let command, _ = split_command_and_arg ("/" ^ needle) in
  Option.is_some (unlisted_word_of_command command)

let filter ~query ~lang =
  let needle = String.lowercase_ascii (strip_leading_slash query) in
  if String.length needle = 0 then all
  else if is_unlisted_word needle then []
  else
    let scored =
      List.filter_map
        (fun spec ->
          let cmd_body =
            String.lowercase_ascii (strip_leading_slash spec.name)
          in
          let desc_lower =
            String.lowercase_ascii (Say.resolve lang spec.description)
          in
          let name_score = fuzzy_score ~needle ~haystack:cmd_body in
          let desc_score =
            Option.map (fun s -> s + 500)
              (fuzzy_score ~needle ~haystack:desc_lower)
          in
          match (name_score, desc_score) with
          | Some a, Some b -> Some (Int.min a b, spec)
          | Some a, None -> Some (a, spec)
          | None, Some b -> Some (b, spec)
          | None, None -> None)
        all
    in
    scored
    |> List.stable_sort (fun (sa, _) (sb, _) -> Int.compare sa sb)
    |> List.map snd

let complete_args ~cmd ~arg_prefix candidates =
  let needle = String.lowercase_ascii (String.trim arg_prefix) in
  candidates
  |> List.filter (fun cand -> String.starts_with ~prefix:needle cand)
  |> List.map (fun cand -> cmd ^ " " ^ cand)

let trim_leading s =
  let len = String.length s in
  let rec skip i =
    if i >= len then len
    else
      match s.[i] with
      | ' ' | '\t' | '\n' | '\r' -> skip (i + 1)
      | _ -> i
  in
  let start = skip 0 in
  String.sub s start (len - start)

let complete ~prefix =
  let lead_trimmed = trim_leading prefix in
  let has_space =
    String.contains lead_trimmed ' ' || String.contains lead_trimmed '\t'
  in
  if has_space then
    let cmd, arg_opt = split_command_and_arg lead_trimmed in
    let arg_prefix = match arg_opt with Some a -> a | None -> "" in
    match cmd with
    | "/theme" ->
        complete_args ~cmd ~arg_prefix
          (List.map Theme.preset_name Theme.all_presets)
    | "/lang" -> complete_args ~cmd ~arg_prefix [ "ko"; "en" ]
    | "/ctl" -> complete_args ~cmd ~arg_prefix keeper_ctl_action_names
    | "/gate" ->
        complete_args ~cmd ~arg_prefix
          [
            "mode";
            "external-mode";
            "del-rule";
            "approve-always";
            "retry";
            "keeper-mode";
            "ack-uncertain";
            "restore-late";
          ]
    | "/skill" ->
        complete_args ~cmd ~arg_prefix
          [ "refresh"; "new"; "read"; "edit"; "delete" ]
    | "/prompt" ->
        complete_args ~cmd ~arg_prefix
          [ "set"; "clear"; "param-set"; "param-clear" ]
    | "/preset" ->
        complete_args ~cmd ~arg_prefix
          [ "list"; "show"; "save"; "create"; "restore"; "delete" ]
    | "/lane" ->
        complete_args ~cmd ~arg_prefix
          [
            "create";
            "remove";
            "rename";
            "set";
            "exact-append";
            "exact-drop";
            "exact-move";
            "exact-replace";
            "run";
            "quarantines";
            "recover";
            "raw-preview";
          ]
    | "/addon" ->
        complete_args ~cmd ~arg_prefix
          [
            "attach";
            "detach";
            "observe";
            "retain";
            "act";
            "evidence";
            "decl-read";
            "decl-new";
            "slice";
            "asks";
            "answer";
            "operator";
          ]
    | "/browser" ->
        complete_args ~cmd ~arg_prefix
          [ "scene"; "screenshot"; "interact"; "command" ]
    | "/tools" ->
        complete_args ~cmd ~arg_prefix [ "compact"; "results"; "full" ]
    | _ -> []
  else
    let lower = String.lowercase_ascii (String.trim lead_trimmed) in
    let needle =
      if String.length lower > 0 && Char.equal lower.[0] '/' then lower
      else "/" ^ lower
    in
    all
    |> List.filter (fun spec -> String.starts_with ~prefix:needle spec.name)
    |> List.map (fun spec -> spec.name)
