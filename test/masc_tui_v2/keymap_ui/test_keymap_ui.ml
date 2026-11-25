module Nav = Masc_tui_core.Nav
module Observed = Masc_tui_core.Observed
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Clock = Masc_tui_core.Clock
module Format_val = Masc_tui_core.Format_val
module Glyph = Masc_tui_core.Glyph
module Attr = Masc_tui_term.Attr
module Cell_grid = Masc_tui_term.Cell_grid
module Color = Masc_tui_term.Color
module Grapheme = Masc_tui_term.Grapheme
module Input = Masc_tui_term.Input_decoder
module Presenter = Masc_tui_term.Presenter
module Keymap = Masc_tui_keymap.Keymap
module Slash = Masc_tui_keymap.Slash
module Layout = Masc_tui_ui.Layout
module Typography = Masc_tui_ui.Typography
module Card = Masc_tui_ui.Card
module Chart = Masc_tui_ui.Chart
module Memory_charts = Masc_tui_ui.Memory_charts
module Memory_flow = Masc_tui_ui.Memory_flow
module Table = Masc_tui_ui.Table
module Code_lexer = Masc_tui_ui.Code_lexer
module Diff = Masc_tui_ui.Diff
module Json_tree = Masc_tui_ui.Json_tree
module Markdown = Masc_tui_ui.Markdown
module Form = Masc_tui_ui.Form
module Composer = Masc_tui_ui.Composer

let key_ev ?(ctrl = false) ?(alt = false) ?(shift = false) key : Input.key_event =
  { key; mods = { ctrl; alt; shift } }

let char_ev ?(ctrl = false) ?(alt = false) ?(shift = false) c =
  key_ev ~ctrl ~alt ~shift (Input.Char (String.make 1 c))

let grid_row_text (grid : Cell_grid.t) ~y =
  let buf = Buffer.create (Cell_grid.cols grid) in
  for x = 0 to Cell_grid.cols grid - 1 do
    let cell = Cell_grid.get grid ~x ~y in
    match cell.glyph with
    | Cell_grid.Empty -> Buffer.add_char buf ' '
    | Cell_grid.Ascii ch -> Buffer.add_char buf ch
    | Cell_grid.Braille mask -> Buffer.add_string buf (Cell_grid.braille_utf8 mask)
    | Cell_grid.Utf8 s -> Buffer.add_string buf s
    | Cell_grid.Continuation -> ()
  done;
  Buffer.contents buf

let contains_sub ~needle ~haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else
    let rec loop i =
      if i + n > h then false
      else if String.equal (String.sub haystack i n) needle then true
      else loop (i + 1)
    in
    loop 0

(* --- 1. Keymap Tests --- *)

let test_keymap_no_collisions () =
  let cols = Keymap.collisions () in
  Alcotest.(check int) "zero collisions across all scopes" 0 (List.length cols)

let test_keymap_ctrl_k_never_approves () =
  let all_focuses =
    [
      Nav.Global;
      Nav.Workspace_focused Nav.Pulse;
      Nav.Workspace_focused Nav.Work;
      Nav.Inspector_focused (Nav.Verification_inspector "v-1");
      Nav.Composer_focused;
      Nav.Ask_choice_focused;
      Nav.Approval_strip_focused;
      Nav.Overlay_focused Nav.Palette;
    ]
  in
  let ctrl_k = char_ev ~ctrl:true 'k' in
  List.iter
    (fun focus ->
      List.iter
        (fun approval_strip_active ->
          let scope_chain =
            Keymap.scope_chain_of_focus ~approval_strip_active focus
          in
          match Keymap.dispatch ~scope_chain ctrl_k with
          | Some Keymap.Open_palette -> ()
          | Some Keymap.Fast_approve_top ->
              Alcotest.fail "Ctrl+K must NEVER dispatch Fast_approve_top"
          | Some _ | None ->
              Alcotest.fail "Ctrl+K must dispatch Open_palette everywhere")
        [ false; true ])
    all_focuses

let test_keymap_retired_p_v_and_vt100_safety () =
  let all_focuses =
    [
      Nav.Global;
      Nav.Workspace_focused Nav.Pulse;
      Nav.Workspace_focused Nav.Keepers;
      Nav.Ask_choice_focused;
      Nav.Approval_strip_focused;
      Nav.Composer_focused;
      Nav.Overlay_focused Nav.Help;
    ]
  in
  List.iter
    (fun focus ->
      let scope_chain =
        Keymap.scope_chain_of_focus ~approval_strip_active:true focus
      in
      Alcotest.(check bool) "bare p never triggers legacy Palette" true
        (not
           (Option.equal Keymap.equal_action (Some Keymap.Open_palette)
              (Keymap.dispatch ~scope_chain (char_ev 'p'))));
      Alcotest.(check bool) "bare v never triggers legacy Voice PTT" true
        (not
           (Option.equal Keymap.equal_action (Some Keymap.Voice_ptt_toggle)
              (Keymap.dispatch ~scope_chain (char_ev 'v'))));
      Alcotest.(check bool) "Ctrl+I unbound (VT100 Tab)" true
        (Option.is_none (Keymap.dispatch ~scope_chain (char_ev ~ctrl:true 'i')));
      Alcotest.(check bool) "Ctrl+M unbound (VT100 Enter)" true
        (Option.is_none (Keymap.dispatch ~scope_chain (char_ev ~ctrl:true 'm')));
      Alcotest.(check bool) "Ctrl+H unbound (VT100 Backspace)" true
        (Option.is_none (Keymap.dispatch ~scope_chain (char_ev ~ctrl:true 'h'))))
    all_focuses

let test_keymap_scopes_and_3_tiers () =
  (* Bare 1..6 ALWAYS switches workspaces (even in Ask_choice_focused), while
     a..d answers Ask choices without hijacking workspace navigation. *)
  let ws_chain = Keymap.scope_chain_of_focus (Nav.Workspace_focused Nav.Pulse) in
  Alcotest.(check bool) "bare 4 -> Keepers" true
    (Option.equal Keymap.equal_action
       (Some (Keymap.Switch_workspace Nav.Keepers))
       (Keymap.dispatch ~scope_chain:ws_chain (char_ev '4')));
  let ask_chain = Keymap.scope_chain_of_focus Nav.Ask_choice_focused in
  Alcotest.(check bool) "bare b in Ask_choice -> Ask_select_choice 2" true
    (Option.equal Keymap.equal_action
       (Some (Keymap.Ask_select_choice 2))
       (Keymap.dispatch ~scope_chain:ask_chain (char_ev 'b')));
  Alcotest.(check bool) "Alt+b in Ask_choice -> Toggle_sidebar (escape hatch)" true
    (Option.equal Keymap.equal_action
       (Some Keymap.Toggle_sidebar)
       (Keymap.dispatch ~scope_chain:ask_chain (char_ev ~alt:true 'b')));
  Alcotest.(check bool) "bare 2 in Ask_choice -> Work workspace (no hijack)" true
    (Option.equal Keymap.equal_action
       (Some (Keymap.Switch_workspace Nav.Work))
       (Keymap.dispatch ~scope_chain:ask_chain (char_ev '2')));
  Alcotest.(check bool) "Ctrl+2 in Ask_choice -> Work workspace" true
    (Option.equal Keymap.equal_action
       (Some (Keymap.Switch_workspace Nav.Work))
       (Keymap.dispatch ~scope_chain:ask_chain (char_ev ~ctrl:true '2')));
  Alcotest.(check bool) "F6 -> Infra" true
    (Option.equal Keymap.equal_action
       (Some (Keymap.Switch_workspace Nav.Infra))
       (Keymap.dispatch ~scope_chain:ask_chain (key_ev (Input.Function 6))));
  (* Y/N only active when approval strip active; Composer does not hijack bare Y/N *)
  Alcotest.(check bool) "Y inactive without strip" true
    (Option.is_none (Keymap.dispatch ~scope_chain:ws_chain (char_ev 'Y')));
  let strip_ws_chain =
    Keymap.scope_chain_of_focus ~approval_strip_active:true
      (Nav.Workspace_focused Nav.Pulse)
  in
  Alcotest.(check bool) "Y approves with strip" true
    (Option.equal Keymap.equal_action (Some Keymap.Fast_approve_top)
       (Keymap.dispatch ~scope_chain:strip_ws_chain (char_ev 'Y')));
  Alcotest.(check bool) "N denies with strip" true
    (Option.equal Keymap.equal_action (Some Keymap.Fast_deny_top)
       (Keymap.dispatch ~scope_chain:strip_ws_chain (char_ev 'N')));
  let comp_strip_chain =
    Keymap.scope_chain_of_focus ~approval_strip_active:true Nav.Composer_focused
  in
  Alcotest.(check bool) "bare Y types in Composer" true
    (Option.is_none (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev 'Y')));
  Alcotest.(check bool) "Alt+Y approves in Composer when strip active" true
    (Option.equal Keymap.equal_action (Some Keymap.Fast_approve_top)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev ~alt:true 'y')));
  (* Universal Ctrl chords & Composer chords & Esc never quits *)
  Alcotest.(check bool) "Ctrl+G in Composer" true
    (Option.equal Keymap.equal_action (Some Keymap.Open_keeper_switcher)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev ~ctrl:true 'g')));
  Alcotest.(check bool) "Ctrl+W kill word in Composer" true
    (Option.equal Keymap.equal_action (Some Keymap.Composer_kill_word)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev ~ctrl:true 'w')));
  Alcotest.(check bool) "Ctrl+J newline in Composer" true
    (Option.equal Keymap.equal_action (Some Keymap.Composer_newline)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev ~ctrl:true 'j')));
  Alcotest.(check bool) "Shift+Enter newline in Composer" true
    (Option.equal Keymap.equal_action (Some Keymap.Composer_newline)
       (Keymap.dispatch ~scope_chain:comp_strip_chain
          (key_ev ~shift:true Input.Enter)));
  Alcotest.(check bool) "Enter queues a follow-up in Composer (never steers)"
    true
    (Option.equal Keymap.equal_action (Some Keymap.Submit_followup)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (key_ev Input.Enter)));
  Alcotest.(check bool) "Ctrl+Enter steers in Composer" true
    (Option.equal Keymap.equal_action (Some Keymap.Submit_steer)
       (Keymap.dispatch ~scope_chain:comp_strip_chain
          (key_ev ~ctrl:true Input.Enter)));
  Alcotest.(check bool) "Alt+Enter steers in Composer" true
    (Option.equal Keymap.equal_action (Some Keymap.Submit_steer)
       (Keymap.dispatch ~scope_chain:comp_strip_chain
          (key_ev ~alt:true Input.Enter)));
  Alcotest.(check bool) "Esc pops, never quits" true
    (Option.equal Keymap.equal_action (Some Keymap.Pop_back_or_close)
       (Keymap.dispatch ~scope_chain:ws_chain (key_ev Input.Escape)));
  Alcotest.(check bool) "Ctrl+Q quits" true
    (Option.equal Keymap.equal_action (Some Keymap.Quit_app)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev ~ctrl:true 'q')));
  Alcotest.(check bool) "Ctrl+Shift+Q does NOT quit" true
    (Option.is_none
       (Keymap.dispatch ~scope_chain:comp_strip_chain
          (char_ev ~ctrl:true ~shift:true 'q')));
  (* Modern accelerators *)
  Alcotest.(check bool) "Ctrl+, settings" true
    (Option.equal Keymap.equal_action (Some Keymap.Open_settings)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev ~ctrl:true ',')));
  Alcotest.(check bool) "F10 settings" true
    (Option.equal Keymap.equal_action (Some Keymap.Open_settings)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (key_ev (Input.Function 10))));
  Alcotest.(check bool) "F8 voice" true
    (Option.equal Keymap.equal_action (Some Keymap.Voice_ptt_toggle)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (key_ev (Input.Function 8))));
  Alcotest.(check bool) "Alt+V voice" true
    (Option.equal Keymap.equal_action (Some Keymap.Voice_ptt_toggle)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev ~alt:true 'v')));
  Alcotest.(check bool) "Ctrl+B toggles Left Navigation Sidebar" true
    (Option.equal Keymap.equal_action (Some Keymap.Toggle_sidebar)
       (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev ~ctrl:true 'b')));
  (* Keeper lifecycle W / D bindings: active in Screen_context, never hijack Composer or other screens *)
  let keeper_ctx_chain = Keymap.Screen_context :: ws_chain in
  Alcotest.(check bool) "W -> Keeper_wake_or_online in Screen_context" true
    (Option.equal Keymap.equal_action (Some Keymap.Keeper_wake_or_online)
       (Keymap.dispatch ~scope_chain:keeper_ctx_chain (char_ev 'W')));
  Alcotest.(check bool) "D -> Keeper_stop_armed in Screen_context" true
    (Option.equal Keymap.equal_action (Some Keymap.Keeper_stop_armed)
       (Keymap.dispatch ~scope_chain:keeper_ctx_chain (char_ev 'D')));
  Alcotest.(check bool) "W types in Composer (never triggers lifecycle)" true
    (Option.is_none (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev 'W')));
  Alcotest.(check bool) "D types in Composer (never triggers lifecycle)" true
    (Option.is_none (Keymap.dispatch ~scope_chain:comp_strip_chain (char_ev 'D')))

let test_keymap_footer_width_budget () =
  let scopes =
    [
      Keymap.scope_chain_of_focus ~approval_strip_active:false
        (Nav.Workspace_focused Nav.Pulse);
      Keymap.scope_chain_of_focus ~approval_strip_active:true
        (Nav.Workspace_focused Nav.Work);
      Keymap.scope_chain_of_focus ~approval_strip_active:false
        Nav.Composer_focused;
    ]
  in
  List.iter
    (fun scope_chain ->
      List.iter
        (fun lang ->
          List.iter
            (fun max_width ->
              let hints = Keymap.footer_hints ~scope_chain ~max_width ~lang in
              let rendered = Keymap.format_footer_line hints in
              let w = Grapheme.display_width rendered in
              Alcotest.(check bool)
                (Printf.sprintf "footer fits within %d (actual %d)" max_width w)
                true (w <= max_width);
              Alcotest.(check bool) "no ...? overflow" false
                (contains_sub ~needle:"...?" ~haystack:rendered);
              Alcotest.(check bool) "at least one hint at >= 80" true
                (List.length hints > 0))
            [ 80; 90; 140 ])
        [ Say.Lang_ko; Say.Lang_en ])
    scopes;
  let help = Keymap.help_entries ~scope_chain:(List.hd scopes) ~lang:Say.Lang_en in
  Alcotest.(check bool) "help groups non-empty" true (List.length help >= 3);
  let palette = Keymap.palette_commands ~lang:Say.Lang_ko in
  Alcotest.(check bool) "palette commands non-empty" true
    (List.length palette >= 15);
  let md = Keymap.render_markdown_reference ~lang:Say.Lang_en () in
  Alcotest.(check bool) "markdown reference includes Ctrl+K" true
    (contains_sub ~needle:"`Ctrl+K`" ~haystack:md)

(* --- 2. Slash Commands Tests --- *)

let test_slash_36_commands () =
  Alcotest.(check int) "exactly 36 slash commands" 36 (List.length Slash.all);
  let cases =
    [
      ("/pulse", Slash.Pulse);
      ("/work", Slash.Work);
      ("/knowledge", Slash.Knowledge);
      ("/keepers", Slash.Keepers);
      ("/runtime", Slash.Runtime);
      ("/infra", Slash.Infra);
      ("/keeper alpha", Slash.Keeper (Some "alpha"));
      ("/model sonnet", Slash.Model (Some "sonnet"));
      ("/config cache_ttl", Slash.Config (Some "cache_ttl"));
      ("/incidents", Slash.Incidents);
      ("/jump", Slash.Jump);
      ("/voice", Slash.Voice);
      ("/btw what failed?", Slash.Btw "what failed?");
      ("/wake", Slash.Wake None);
      ("/wake alpha", Slash.Wake (Some "alpha"));
      ("/up", Slash.Up None);
      ("/up alpha", Slash.Up (Some "alpha"));
      ("/boot alpha", Slash.Up (Some "alpha"));
      ("/resume alpha", Slash.Resume (Some "alpha"));
      ("/pause alpha", Slash.Pause (Some "alpha"));
      ("/down alpha", Slash.Down (Some "alpha"));
      ("/queue", Slash.Queue);
      ("/context", Slash.Context);
      ( "/ctl resume alpha",
        Slash.Ctl { action = Slash.Ctl_resume; target = Some "alpha" } );
      ("/ctl checkpoints", Slash.Ctl { action = Slash.Ctl_checkpoints; target = None });
      ("/gate mode manual", Slash.Gate (Slash.Gate_mode_set "manual"));
      ( "/gate external-mode auto_judge",
        Slash.Gate (Slash.Gate_external_mode_set "auto_judge") );
      ("/gate del-rule rule-1", Slash.Gate (Slash.Gate_rule_delete "rule-1"));
      ( "/gate approve-always appr-1",
        Slash.Gate (Slash.Gate_approve_always "appr-1") );
      ("/gate retry appr-1", Slash.Gate (Slash.Gate_retry "appr-1"));
      ( "/gate keeper-mode alpha yolo",
        Slash.Gate (Slash.Gate_keeper_mode_set { keeper = "alpha"; mode = "yolo" }) );
      ( "/gate ack-uncertain alpha cons-1",
        Slash.Gate
          (Slash.Gate_ack_uncertain { keeper = "alpha"; consume_id = "cons-1" }) );
      ("/gate restore-late", Slash.Gate Slash.Gate_restore_late);
      ("/exec masc_status", Slash.Exec { tool_name = "masc_status"; args_json = None });
      ( "/exec masc_board_list {\"limit\":5}",
        Slash.Exec
          { tool_name = "masc_board_list"; args_json = Some "{\"limit\":5}" } );
      ("/skill refresh", Slash.Skill Slash.Skill_refresh);
      ("/skill new", Slash.Skill Slash.Skill_new);
      ("/skill read ocaml-coding", Slash.Skill (Slash.Skill_read "ocaml-coding"));
      ("/skill edit ocaml-coding", Slash.Skill (Slash.Skill_edit "ocaml-coding"));
      ( "/skill delete ocaml-coding",
        Slash.Skill (Slash.Skill_delete "ocaml-coding") );
      ( "/prompt set system.greeting hello world",
        Slash.Prompt
          (Slash.Prompt_set
             { key = "system.greeting"; value = Some "hello world" }) );
      ( "/prompt clear system.greeting",
        Slash.Prompt (Slash.Prompt_clear "system.greeting") );
      ( "/prompt param-set keeper.max_turns 12",
        Slash.Prompt
          (Slash.Param_set { key = "keeper.max_turns"; value_raw = Some "12" }) );
      ( "/prompt param-clear keeper.max_turns",
        Slash.Prompt (Slash.Param_clear "keeper.max_turns") );
      ("/preset", Slash.Preset Slash.Preset_list);
      ("/preset list", Slash.Preset Slash.Preset_list);
      ("/preset show baseline", Slash.Preset (Slash.Preset_show "baseline"));
      ( "/preset save baseline prod snap",
        Slash.Preset
          (Slash.Preset_save { name = "baseline"; description = "prod snap" }) );
      ( "/preset create v2",
        Slash.Preset (Slash.Preset_create { name = Some "v2"; description = "" })
      );
      ("/preset restore baseline", Slash.Preset (Slash.Preset_restore "baseline"));
      ("/preset delete old", Slash.Preset (Slash.Preset_delete "old"));
      ( "/lane create fast slot-a,slot-b",
        Slash.Lane
          (Slash.Lane_create { lane = "fast"; runtime_ids = [ "slot-a"; "slot-b" ] }) );
      ("/lane remove fast", Slash.Lane (Slash.Lane_remove "fast"));
      ( "/lane rename fast turbo",
        Slash.Lane (Slash.Lane_rename { lane = "fast"; to_lane = "turbo" }) );
      ( "/lane exact-move verifier slot-b first",
        Slash.Lane
          (Slash.Lane_exact_move
             { lane_id = "verifier"; runtime_id = "slot-b"; direction = `First }) );
      ("/lane run run-42", Slash.Lane (Slash.Lane_run_inspect "run-42"));
      ("/lane raw-preview", Slash.Lane Slash.Lane_raw_preview);
      ( "/lane quarantines alpha",
        Slash.Lane (Slash.Lane_quarantines "alpha") );
      ( "/lane recover alpha part-1 cand-1 q-1",
        Slash.Lane
          (Slash.Lane_quarantine_recover
             {
               keeper = "alpha";
               partition_id = "part-1";
               candidate_id = "cand-1";
               quarantine_id = "q-1";
             }) );
      ( "/addon attach /tmp/manifest.toml run-1 {\"k\":1}",
        Slash.Addon
          (Slash.Addon_attach
             {
               manifest_path = "/tmp/manifest.toml";
               run_id = "run-1";
               binding_json = Some "{\"k\":1}";
             }) );
      ("/addon detach inst-1", Slash.Addon (Slash.Addon_detach "inst-1"));
      ("/addon observe inst-1", Slash.Addon (Slash.Addon_observe "inst-1"));
      ( "/addon act inst-1 {\"op\":\"ping\"}",
        Slash.Addon
          (Slash.Addon_act
             { instance_id = "inst-1"; action_json = Some "{\"op\":\"ping\"}" }) );
      ("/addon asks all", Slash.Addon (Slash.Addon_asks { include_resolved = true }));
      ( "/browser scene 7 regions",
        Slash.Browser
          (Slash.Browser_scene
             { client_id = None; tab_id = Some 7; view = `Regions }) );
      ( "/browser screenshot 7",
        Slash.Browser
          (Slash.Browser_screenshot { client_id = None; tab_id = Some 7 }) );
      ( "/browser interact click #go",
        Slash.Browser
          (Slash.Browser_interact
             {
               client_id = None;
               tab_id = None;
               action = Some "click";
               selector = Some "#go";
               text = None;
             }) );
      ( "/browser command {\"action\":\"reload\"}",
        Slash.Browser (Slash.Browser_command "{\"action\":\"reload\"}") );
      ("/tools full", Slash.Tools (Some Slash.Tools_full));
      ("/clear", Slash.Clear);
      ("/theme arcade_hi", Slash.Theme (Some Theme.Arcade_hi));
      ("/theme muted", Slash.Theme (Some Theme.Muted));
      ("/lang ko", Slash.Lang (Some Say.Lang_ko));
      ("/help", Slash.Help);
      ("/restart", Slash.Restart);
      ("/quit", Slash.Quit);
    ]
  in
  Alcotest.(check bool) "/gate strict invalid subcommand rejected" true
    (match Slash.parse "/gate bogus" with
    | Error (Slash.Invalid_argument _) -> true
    | Ok _ | Error _ -> false);
  Alcotest.(check bool) "/exec missing tool name rejected" true
    (match Slash.parse "/exec" with
    | Error (Slash.Invalid_argument _) -> true
    | Ok _ | Error _ -> false);
  Alcotest.(check bool) "/gate completion lists mode" true
    (List.mem "/gate mode" (Slash.complete ~prefix:"/gate m"));
  Alcotest.(check bool) "/skill completion lists refresh" true
    (List.mem "/skill refresh" (Slash.complete ~prefix:"/skill r"));
  Alcotest.(check bool) "/prompt completion lists param-set" true
    (List.mem "/prompt param-set" (Slash.complete ~prefix:"/prompt p"));
  Alcotest.(check bool) "/preset completion lists restore" true
    (List.mem "/preset restore" (Slash.complete ~prefix:"/preset r"));
  Alcotest.(check bool) "/lane completion lists exact-move" true
    (List.mem "/lane exact-move" (Slash.complete ~prefix:"/lane exact-m"));
  Alcotest.(check bool) "/addon completion lists attach" true
    (List.mem "/addon attach" (Slash.complete ~prefix:"/addon at"));
  Alcotest.(check bool) "/browser completion lists interact" true
    (List.mem "/browser interact" (Slash.complete ~prefix:"/browser in"));
  Alcotest.(check bool) "/lane bogus rejected" true
    (match Slash.parse "/lane bogus" with
    | Error (Slash.Invalid_argument _) -> true
    | Ok _ | Error _ -> false);
  Alcotest.(check bool) "/addon bogus rejected" true
    (match Slash.parse "/addon bogus" with
    | Error (Slash.Invalid_argument _) -> true
    | Ok _ | Error _ -> false);
  Alcotest.(check bool) "/browser bogus rejected" true
    (match Slash.parse "/browser bogus" with
    | Error (Slash.Invalid_argument _) -> true
    | Ok _ | Error _ -> false);
  Alcotest.(check bool) "/skill unknown subcommand rejected" true
    (match Slash.parse "/skill bogus" with
    | Error (Slash.Invalid_argument _) -> true
    | Ok _ | Error _ -> false);
  Alcotest.(check bool) "/preset show missing name rejected" true
    (match Slash.parse "/preset show" with
    | Error (Slash.Invalid_argument _) -> true
    | Ok _ | Error _ -> false);
  List.iter
    (fun (input, expected) ->
      match Slash.parse input with
      | Ok actual ->
          Alcotest.(check bool)
            ("parse " ^ input) true
            (Slash.equal_parsed expected actual)
      | Error _ -> Alcotest.fail ("expected Ok for " ^ input))
    cases;
  (* Strict errors: unknown command, invalid enum, missing /btw question *)
  Alcotest.(check bool) "unknown command rejected" true
    (match Slash.parse "/play" with
     | Error (Slash.Unknown_command "/play") -> true
     | Ok _
     | Error
         ( Slash.Not_a_slash_command
         | Slash.Empty_command
         | Slash.Unknown_command _
         | Slash.Unexpected_argument _
         | Slash.Invalid_argument _ ) ->
         false);
  Alcotest.(check bool) "invalid theme rejected" true
    (match Slash.parse "/theme neon_legacy" with
     | Error (Slash.Invalid_argument _) -> true
     | Ok _
     | Error
         ( Slash.Not_a_slash_command
         | Slash.Empty_command
         | Slash.Unknown_command _
         | Slash.Unexpected_argument _ ) ->
         false);
  Alcotest.(check bool) "invalid lang rejected" true
    (match Slash.parse "/lang jp" with
     | Error (Slash.Invalid_argument _) -> true
     | Ok _
     | Error
         ( Slash.Not_a_slash_command
         | Slash.Empty_command
         | Slash.Unknown_command _
         | Slash.Unexpected_argument _ ) ->
         false);
  Alcotest.(check bool) "fuzzy filter matches" true
    (List.exists (fun (s : Slash.spec) -> String.equal s.name "/knowledge")
       (Slash.filter ~query:"knw" ~lang:Say.Lang_en));
  Alcotest.(check (list string)) "theme arg completion lists the muted family"
    [
      "/theme muted";
      "/theme muted_warm";
      "/theme muted_green";
      "/theme muted_dusk";
      "/theme muted_graphite";
    ]
    (Slash.complete ~prefix:"/theme mu");
  Alcotest.(check (list string)) "theme arg completion narrows by prefix"
    [ "/theme muted_warm" ]
    (Slash.complete ~prefix:"/theme muted_w");
  List.iter
    (fun (typed, full) ->
      Alcotest.(check (list string)) ("theme arg completion for " ^ typed)
        [ "/theme " ^ full ]
        (Slash.complete ~prefix:("/theme " ^ typed)))
    [
      ("so", "solarized_dark");
      ("no", "nord");
      ("dr", "dracula");
      ("gr", "gruvbox_dark");
      ("ca", "catppuccin_mocha");
    ];
  (* Every name the picker lists is a name /theme accepts. *)
  List.iter
    (fun preset ->
      let input = "/theme " ^ Theme.preset_name preset in
      match Slash.parse input with
      | Ok actual ->
          Alcotest.(check bool) ("parse " ^ input) true
            (Slash.equal_parsed (Slash.Theme (Some preset)) actual)
      | Error _ -> Alcotest.fail ("expected Ok for " ^ input))
    Theme.all_presets

(* --- 3. Layout & Breakpoints Tests --- *)

let test_layout_breakpoints_and_collapse () =
  let check_bp name cols rows expected =
    Alcotest.(check bool) name true
      (Layout.equal_breakpoint expected (Layout.classify_viewport ~cols ~rows))
  in
  check_bp "140x36 Wide" 140 36 Layout.Wide;
  check_bp "140x40 Wide" 140 40 Layout.Wide;
  check_bp "139x35 Standard" 139 35 Layout.Standard;
  check_bp "100x28 Standard" 100 28 Layout.Standard;
  check_bp "150x30 Standard (height < 36)" 150 30 Layout.Standard;
  check_bp "99x27 Compact" 99 27 Layout.Compact;
  check_bp "90x28 Compact" 90 28 Layout.Compact;
  check_bp "80x24 Compact" 80 24 Layout.Compact;
  check_bp "79x30 Micro" 79 30 Layout.Micro;
  check_bp "120x23 Micro" 120 23 Layout.Micro;
  Alcotest.(check int) "Compact idle chrome = 3" 3
    (Layout.chrome_rows Layout.Compact ~composer_expanded:false ~approval_strip:false);
  Alcotest.(check int) "Compact active chrome = 4" 4
    (Layout.chrome_rows Layout.Compact ~composer_expanded:true ~approval_strip:false);
  (* Constraint allocation & empty-card collapse *)
  let area = Rect.make ~x:0 ~y:0 ~w:100 ~h:30 in
  let slots : string Layout.card_slot list =
    [
      { id = "attention"; is_empty = true; constraint_ = Layout.Fixed 5 };
      { id = "companies"; is_empty = false; constraint_ = Layout.Flex 2 };
      { id = "world"; is_empty = false; constraint_ = Layout.Flex 1 };
    ]
  in
  let assigned, collapsed = Layout.collapse_empty_cards area slots in
  Alcotest.(check (list string)) "empty card collapsed" [ "attention" ] collapsed;
  let total_h = List.fold_left (fun acc (_, (r : Rect.t)) -> acc + r.h) 0 assigned in
  Alcotest.(check int) "active cards claim 100% height" 30 total_h

(* --- 4. Card LRU Cache Test --- *)

let test_card_lru_cache () =
  let grid = Cell_grid.create ~cols:50 ~rows:10 in
  let theme = Theme.default in
  let cache = Card.Cache.create ~capacity:4 () in
  let rect = Rect.make ~x:0 ~y:0 ~w:40 ~h:6 in
  let spec =
    {
      (Card.default_spec ~title:"Pulse") with
      hotkey = Some "[Alt+J] Jump";
      focused = false;
    }
  in
  let inner = Card.draw ~cache grid ~rect ~theme spec in
  Alcotest.(check int) "inner width" 38 inner.w;
  Alcotest.(check int) "inner height" 4 inner.h;
  (* Focus toggle reuses cached geometry -> cache hit! *)
  ignore (Card.draw ~cache grid ~rect ~theme { spec with focused = true });
  let s1 = Card.Cache.stats cache in
  Alcotest.(check int) "1 miss" 1 s1.misses;
  Alcotest.(check int) "1 hit on focus flip" 1 s1.hits;
  (* Exceed capacity=4 -> bounded evictions *)
  for i = 1 to 6 do
    ignore
      (Card.draw ~cache grid ~rect ~theme
         (Card.default_spec ~title:(Printf.sprintf "Card %d" i)))
  done;
  let s2 = Card.Cache.stats cache in
  Alcotest.(check int) "bounded at capacity 4" 4 s2.entries;
  Alcotest.(check bool) "evictions occurred" true (s2.evictions >= 3)

(* --- 5. Chart Adaptive Mode Degradation & Unread/Absent Semantics --- *)

let sample_ts_spec () =
  let samples =
    [|
      Chart.Series.Unread;
      Chart.Series.Absent;
      Chart.Series.Zero;
      Chart.Series.Value 12.0;
      Chart.Series.Value 45.0;
      Chart.Series.Value 90.0;
    |]
  in
  let series : Chart.Series.t =
    {
      label = Say.make ~ko:"토큰" ~en:"Tokens";
      unit = Format_val.Rate_per_sec;
      gradient = Chart.Gradient.Cool_flow;
      samples;
      current = Observed.value ~observed_at:Clock.Mono.zero 90.0;
      peak = Observed.value ~observed_at:Clock.Mono.zero 90.0;
      avg = Observed.value ~observed_at:Clock.Mono.zero 36.7;
      delta_pct = Some 12.4;
    }
  in
  {
    Chart.Spec.title = Say.make ~ko:"토큰 처리량" ~en:"Token Velocity";
    kind =
      Chart.Spec.Time_series
        {
          series;
          scale = Chart.Scale.Auto_ceil { floor = 0.0; nice_step = true };
          window = Chart.Time_window.Last_24h;
        };
    hotkey_hint = Some "[w] 24h";
  }

let test_chart_degradation_and_tiers () =
  let spec = sample_ts_spec () in
  let braille_caps = Presenter.default_capabilities in
  let block_caps = { braille_caps with braille_safe = false; unicode_blocks = true } in
  let ascii_caps = { braille_caps with braille_safe = false; unicode_blocks = false } in
  (* 5 exact geometry checks *)
  (match Chart.Render_mode.resolve ~avail_w:140 ~avail_h:12 ~caps:braille_caps spec with
   | Chart.Render_mode.Full_area_chart { glyphs = Braille_2x4; show_y_axis = true; show_x_ticks = true; _ } -> ()
   | Chart.Render_mode.Full_area_chart _
   | Chart.Render_mode.Dual_mirror_chart _
   | Chart.Render_mode.Half_block_gauge _
   | Chart.Render_mode.Inline_sparkline _
   | Chart.Render_mode.Numeric_delta_pill ->
       Alcotest.fail "140x12 should resolve Full_area_chart Braille_2x4 with axes");
  (match Chart.Render_mode.resolve ~avail_w:90 ~avail_h:6 ~caps:braille_caps spec with
   | Chart.Render_mode.Full_area_chart { glyphs = Braille_2x4; show_y_axis = true; show_x_ticks = true; _ } -> ()
   | Chart.Render_mode.Full_area_chart _
   | Chart.Render_mode.Dual_mirror_chart _
   | Chart.Render_mode.Half_block_gauge _
   | Chart.Render_mode.Inline_sparkline _
   | Chart.Render_mode.Numeric_delta_pill ->
       Alcotest.fail "90x6 should resolve Full_area_chart Braille_2x4");
  (match Chart.Render_mode.resolve ~avail_w:60 ~avail_h:3 ~caps:braille_caps spec with
   | Chart.Render_mode.Full_area_chart { glyphs = Braille_2x4; show_x_ticks = false; _ } -> ()
   | Chart.Render_mode.Full_area_chart _
   | Chart.Render_mode.Dual_mirror_chart _
   | Chart.Render_mode.Half_block_gauge _
   | Chart.Render_mode.Inline_sparkline _
   | Chart.Render_mode.Numeric_delta_pill ->
       Alcotest.fail "60x3 should resolve compact Full_area_chart without x-ticks");
  (match Chart.Render_mode.resolve ~avail_w:24 ~avail_h:2 ~caps:braille_caps spec with
   | Chart.Render_mode.Inline_sparkline { glyphs = Spark_eighth_block; _ } -> ()
   | Chart.Render_mode.Full_area_chart _
   | Chart.Render_mode.Dual_mirror_chart _
   | Chart.Render_mode.Half_block_gauge _
   | Chart.Render_mode.Inline_sparkline _
   | Chart.Render_mode.Numeric_delta_pill ->
       Alcotest.fail "24x2 should resolve Inline_sparkline");
  (match Chart.Render_mode.resolve ~avail_w:10 ~avail_h:1 ~caps:braille_caps spec with
   | Chart.Render_mode.Numeric_delta_pill -> ()
   | Chart.Render_mode.Full_area_chart _
   | Chart.Render_mode.Dual_mirror_chart _
   | Chart.Render_mode.Half_block_gauge _
   | Chart.Render_mode.Inline_sparkline _ ->
       Alcotest.fail "10x1 should resolve Numeric_delta_pill");
  (* Glyph tier fallback *)
  Alcotest.(check bool) "Braille_2x4" true
    (Chart.Render_mode.equal_glyph_tier Braille_2x4
       (Chart.Render_mode.select_glyph_tier ~caps:braille_caps));
  Alcotest.(check bool) "Block_vertical" true
    (Chart.Render_mode.equal_glyph_tier Block_vertical
       (Chart.Render_mode.select_glyph_tier ~caps:block_caps));
  Alcotest.(check bool) "Ascii_tty" true
    (Chart.Render_mode.equal_glyph_tier Ascii_tty
       (Chart.Render_mode.select_glyph_tier ~caps:ascii_caps));
  (* Unread and Absent NEVER plotted as 0 *)
  Alcotest.(check int) "Unread -> 0 dots (blank)" 0
    (Chart.Series.sample_dot_level ~dots:16 ~floor:0.0 ~ceiling:100.0 Chart.Series.Unread);
  Alcotest.(check int) "Absent -> 0 dots (blank)" 0
    (Chart.Series.sample_dot_level ~dots:16 ~floor:0.0 ~ceiling:100.0 Chart.Series.Absent);
  Alcotest.(check int) "Zero -> 1 dot (baseline)" 1
    (Chart.Series.sample_dot_level ~dots:16 ~floor:0.0 ~ceiling:100.0 Chart.Series.Zero);
  Alcotest.(check bool) "tiny positive Value >= 2 dots (above baseline)" true
    (Chart.Series.sample_dot_level ~dots:16 ~floor:0.0 ~ceiling:1000.0 (Chart.Series.Value 0.1) >= 2);
  (* Verify direct Cell_grid.Braille rendering (zero string alloc path) *)
  let grid = Cell_grid.create ~cols:60 ~rows:8 in
  let _mode =
    Chart.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h:8) ~theme:Theme.default
      ~caps:braille_caps ~lang:Say.Lang_en spec
  in
  let braille_cells = ref 0 in
  for y = 0 to 7 do
    for x = 0 to 59 do
      match (Cell_grid.get grid ~x ~y).glyph with
      | Cell_grid.Braille _ -> incr braille_cells
      | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Utf8 _ | Cell_grid.Continuation -> ()
    done
  done;
  Alcotest.(check bool) "direct Braille cells painted" true (!braille_cells > 0);
  (* Verify Absent-only series leaves plot area blank (no baseline dots) *)
  let absent_spec =
    match spec.kind with
    | Chart.Spec.Time_series ts ->
        {
          spec with
          kind =
            Chart.Spec.Time_series
              { ts with series = { ts.series with samples = Array.make 20 Chart.Series.Absent } };
        }
    | Chart.Spec.Dual_inverted _
    | Chart.Spec.Ratio_gauge _
    | Chart.Spec.Stacked_bar _ ->
        spec
  in
  let grid2 = Cell_grid.create ~cols:40 ~rows:6 in
  ignore
    (Chart.draw grid2 ~rect:(Rect.make ~x:0 ~y:0 ~w:40 ~h:6) ~theme:Theme.default
       ~caps:braille_caps ~lang:Say.Lang_en absent_spec);
  let absent_braille = ref 0 in
  for y = 1 to 4 do
    for x = 8 to 39 do
      match (Cell_grid.get grid2 ~x ~y).glyph with
      | Cell_grid.Braille _ -> incr absent_braille
      | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Utf8 _ | Cell_grid.Continuation -> ()
    done
  done;
  Alcotest.(check int) "Absent samples draw 0 Braille dots" 0 !absent_braille;
  (* Dual_inverted, Ratio_gauge never-floor, and Stacked_bar coverage *)
  let dual_spec : Chart.Spec.t =
    match spec.kind with
    | Chart.Spec.Time_series { series; window; _ } ->
        {
          title = Say.make ~ko:"입출력 토큰" ~en:"In/Out Tokens";
          kind =
            Chart.Spec.Dual_inverted
              { upper = series; lower = series; scale = Chart.Scale.Synced_pair; window };
          hotkey_hint = None;
        }
    | Chart.Spec.Dual_inverted _
    | Chart.Spec.Ratio_gauge _
    | Chart.Spec.Stacked_bar _ ->
        spec
  in
  let dual_grid = Cell_grid.create ~cols:60 ~rows:8 in
  let dual_mode =
    Chart.draw dual_grid ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h:8)
      ~theme:Theme.default ~caps:braille_caps ~lang:Say.Lang_en dual_spec
  in
  (match dual_mode with
   | Chart.Render_mode.Dual_mirror_chart { half_rows; _ } ->
       Alcotest.(check bool) "dual half_rows >= 2" true (half_rows >= 2)
   | Chart.Render_mode.Full_area_chart _
   | Chart.Render_mode.Half_block_gauge _
   | Chart.Render_mode.Inline_sparkline _
   | Chart.Render_mode.Numeric_delta_pill ->
       Alcotest.fail "60x8 Dual_inverted should resolve Dual_mirror_chart");
  let gauge_spec : Chart.Spec.t =
    {
      title = Say.make ~ko:"한도" ~en:"Quota";
      kind =
        Chart.Spec.Ratio_gauge
          {
            used = Observed.value ~observed_at:Clock.Mono.zero 0.01;
            limit = Observed.value ~observed_at:Clock.Mono.zero 100.0;
            unit = Format_val.Usd;
            gradient = Chart.Gradient.Thermal;
            reset_hint = Some (Say.make ~ko:"1h 후 초기화" ~en:"reset 1h");
          };
      hotkey_hint = None;
    }
  in
  let gauge_grid = Cell_grid.create ~cols:40 ~rows:2 in
  ignore
    (Chart.draw gauge_grid ~rect:(Rect.make ~x:0 ~y:0 ~w:40 ~h:2)
       ~theme:Theme.default ~caps:braille_caps ~lang:Say.Lang_en gauge_spec);
  let gauge_row = grid_row_text gauge_grid ~y:0 in
  Alcotest.(check bool) "tiny positive Ratio_gauge never floors to blank (draws ▏)"
    true (contains_sub ~needle:"\xe2\x96\x8f" ~haystack:gauge_row)

(* --- 6. Table Responsive Column Priority & CJK Safety --- *)

let test_table_priority_and_cjk () =
  let cols : Table.column list =
    [
      {
        id = "name";
        header = Say.make ~ko:"키퍼" ~en:"Keeper";
        priority = 0;
        min_width = 16;
        max_width = Some 24;
        weight = 2;
        align = Table.Left;
      };
      {
        id = "status";
        header = Say.make ~ko:"상태" ~en:"Status";
        priority = 1;
        min_width = 10;
        max_width = Some 14;
        weight = 1;
        align = Table.Left;
      };
      {
        id = "spark";
        header = Say.make ~ko:"24h 추이" ~en:"24h Pulse";
        priority = 2;
        min_width = 12;
        max_width = Some 16;
        weight = 1;
        align = Table.Left;
      };
      {
        id = "notes";
        header = Say.make ~ko:"메모" ~en:"Notes";
        priority = 3;
        min_width = 18;
        max_width = None;
        weight = 2;
        align = Table.Left;
      };
    ]
  in
  let rows : Table.row list =
    [
      {
        id = "r1";
        cells =
          [
            ("name", Table.text_cell "한글키퍼-알파");
            ("status", Table.Badge { glyph = Some Glyph.Live_healthy; text = "정상"; tone = Theme.Status_ok });
            ("spark", Table.Sparkline { samples = [| Chart.Series.Value 1.0; Chart.Series.Value 4.0 |]; gradient = Chart.Gradient.Cool_flow });
            ("notes", Table.text_cell "보조 메모 문자열");
          ];
      };
    ]
  in
  let grid = Cell_grid.create ~cols:34 ~rows:6 in
  let res =
    Table.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:34 ~h:6) ~theme:Theme.default
      ~caps:Presenter.default_capabilities ~lang:Say.Lang_ko ~selected:0
      ~columns:cols rows
  in
  (* Primary 'name' (priority 0) must stay visible; lowest priority 'notes' (3) and 'spark' (2) dropped first *)
  let vis_ids = List.map (fun ((c : Table.column), _) -> c.id) res.visible_columns in
  let drop_ids = List.map (fun (c : Table.column) -> c.id) res.dropped_columns in
  Alcotest.(check bool) "primary column retained" true (List.mem "name" vis_ids);
  Alcotest.(check bool) "lowest priority dropped" true (List.mem "notes" drop_ids);
  let footer_line = grid_row_text grid ~y:5 in
  Alcotest.(check bool) "hidden column notice surfaced" true
    (contains_sub ~needle:"숨김" ~haystack:footer_line);
  (* Verify CJK wide-cell Continuation integrity across entire grid *)
  for y = 0 to 5 do
    for x = 0 to 33 do
      let c = Cell_grid.get grid ~x ~y in
      if c.width = 2 then begin
        Alcotest.(check bool) "wide glyph not at last col" true (x + 1 < 34);
        let next = Cell_grid.get grid ~x:(x + 1) ~y in
        Alcotest.(check bool) "wide glyph paired with Continuation" true
          (Cell_grid.glyph_equal next.glyph Cell_grid.Continuation)
      end
    done
  done

(* --- 7. Json_tree Coloring, Folding & Secret Redaction --- *)

let test_json_tree_structured () =
  let json : Yojson.Safe.t =
    `Assoc
      [
        ("keeper", `String "e-masc-the-leader");
        ("active", `Bool true);
        ("calls", `Int 38700);
        ("api_key", `String ("sk-" ^ "super-secret-value-999"));
        ("nested", `Assoc [ ("a", `Int 1); ("b", `Int 2) ]);
      ]
  in
  let expanded = Json_tree.flatten json in
  Alcotest.(check bool) "expanded has nested children" true
    (List.exists (fun (l : Json_tree.line) -> String.equal l.path "$.nested.a") expanded);
  (* Secret redaction *)
  let secret_line =
    List.find (fun (l : Json_tree.line) -> String.equal l.path "$.api_key") expanded
  in
  Alcotest.(check bool) "api_key redacted" true
    (Json_tree.equal_value_display Json_tree.Redacted_secret secret_line.value);
  (* Folding hides children *)
  let collapsed_paths = Json_tree.toggle_path "$.nested" ~collapsed:[] in
  let folded = Json_tree.flatten ~collapsed:collapsed_paths json in
  Alcotest.(check bool) "folded hides nested children" false
    (List.exists (fun (l : Json_tree.line) -> String.equal l.path "$.nested.a") folded);
  (* Draw onto Cell_grid and verify structured coloring (key fg != string fg) and no raw secret leak *)
  let grid = Cell_grid.create ~cols:60 ~rows:10 in
  ignore
    (Json_tree.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h:10)
       ~theme:Theme.default expanded);
  let all_text =
    String.concat "\n" (List.init 10 (fun y -> grid_row_text grid ~y))
  in
  Alcotest.(check bool) "no secret leaked to grid" false
    (contains_sub ~needle:"sk-super-secret" ~haystack:all_text);
  Alcotest.(check bool) "redacted marker shown" true
    (contains_sub ~needle:"[redacted]" ~haystack:all_text);
  (* Row 1 is keeper: "e-masc-the-leader" -> key fg (status_active) != value fg (status_ok) *)
  let row1_colors = ref [] in
  for x = 0 to 59 do
    let cell = Cell_grid.get grid ~x ~y:1 in
    match cell.glyph with
    | Cell_grid.Ascii _ | Cell_grid.Utf8 _ ->
        if not (List.exists (Color.equal cell.style.fg) !row1_colors) then
          row1_colors := cell.style.fg :: !row1_colors
    | Cell_grid.Empty | Cell_grid.Braille _ | Cell_grid.Continuation -> ()
  done;
  Alcotest.(check bool) "structured multi-color rendering (>= 3 distinct fg)" true
    (List.length !row1_colors >= 3)

(* --- 8. Markdown OSC 8 Links & Code Highlighting --- *)

let test_markdown_osc8_and_fence () =
  let md =
    "# Heading\nSee [MASC Repo](https://github.com/jeong-sik/masc) now.\n\n```ocaml\nlet x = 42\n```"
  in
  let grid = Cell_grid.create ~cols:60 ~rows:10 in
  let total =
    Markdown.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h:10) ~theme:Theme.default
      ~osc8:true md
  in
  Alcotest.(check bool) "rendered multiple lines" true (total >= 5);
  let found_link = ref None in
  for y = 0 to 9 do
    for x = 0 to 59 do
      let id = (Cell_grid.get grid ~x ~y).style.hyperlink_id in
      if id > 0 then found_link := Cell_grid.hyperlink_uri grid id
    done
  done;
  Alcotest.(check (option string)) "OSC 8 URI interned"
    (Some "https://github.com/jeong-sik/masc") !found_link;
  (* Code_lexer + Diff direct draw *)
  Alcotest.(check bool) "diff:ocaml tag parsed" true
    (Option.equal Code_lexer.equal_language
       (Some (Code_lexer.Diff (Some Code_lexer.Ocaml)))
       (Code_lexer.language_of_tag "diff:ocaml"));
  Alcotest.(check bool) "unknown tag returns None" true
    (Option.is_none (Code_lexer.language_of_tag "not_a_real_lang"));
  let diff_rows =
    Diff.rows ~before:"let a = 1\nlet b = 2\n" ~after:"let a = 1\nlet b = 3\n"
  in
  let rem, add = Diff.counts diff_rows in
  Alcotest.(check int) "1 removed" 1 rem;
  Alcotest.(check int) "1 added" 1 add;
  let diff_grid = Cell_grid.create ~cols:50 ~rows:5 in
  let drawn_n =
    Diff.draw diff_grid ~rect:(Rect.make ~x:0 ~y:0 ~w:50 ~h:5)
      ~theme:Theme.default ~language:Code_lexer.Ocaml
      (Diff.number ~old_start:1 ~new_start:(Some 1) diff_rows)
  in
  Alcotest.(check int) "3 diff rows drawn" 3 drawn_n

(* --- 9. Form Secret Masking, Typed Validation & Inline Diff --- *)

let test_form_secret_and_validation () =
  let f_port =
    Form.make_field ~key:"server.port"
      ~label:(Say.make ~ko:"포트" ~en:"Port")
      ~provenance:Form.Prov_global_toml
      ~reload_scope:Form.Restart_required
      ~validators:[ Form.Int_range { min = Some 1024; max = Some 65535 } ]
      (Form.int_val 8935)
  in
  let f_secret =
    Form.make_field ~key:"voice.api_key"
      ~label:(Say.make ~ko:"API 키" ~en:"API Key")
      ~provenance:(Form.Prov_env "ELEVENLABS_API_KEY")
      ~reload_scope:Form.Hot_reload
      ~validators:[ Form.Required; Form.Min_length 8 ]
      (Form.secret_val "secret-token-xyz")
  in
  let f_bool =
    Form.make_field ~key:"ui.compact"
      ~label:(Say.make ~ko:"컴팩트" ~en:"Compact")
      (Form.Bool_val false)
  in
  let st0 = Form.create [ f_port; f_secret; f_bool ] in
  (* Draw masked secret -> raw secret bytes MUST NOT appear on Cell_grid *)
  let grid = Cell_grid.create ~cols:80 ~rows:12 in
  ignore
    (Form.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:80 ~h:12) ~theme:Theme.default
       ~lang:Say.Lang_en st0);
  let screen = String.concat "\n" (List.init 12 (fun y -> grid_row_text grid ~y)) in
  Alcotest.(check bool) "secret masked on grid" false
    (contains_sub ~needle:"secret-token-xyz" ~haystack:screen);
  (* Out-of-range port fails typed validation *)
  let st_bad = Form.set_value ~key:"server.port" (Form.int_val 80) st0 in
  let _, ok_bad = Form.validate_all st_bad in
  Alcotest.(check bool) "port 80 rejected by Int_range" false ok_bad;
  (* Valid update + secret update -> diff preview redacts secret *)
  let st_good =
    st0
    |> Form.set_value ~key:"server.port" (Form.int_val 9000)
    |> Form.set_value ~key:"voice.api_key" (Form.secret_val "new-secret-99999")
  in
  let _, ok_good = Form.validate_all st_good in
  Alcotest.(check bool) "valid changes pass" true ok_good;
  Alcotest.(check bool) "form is dirty" true (Form.is_dirty st_good);
  let diff = Form.diff_preview st_good in
  let diff_text =
    diff
    |> List.map (fun (n : Diff.numbered) ->
           match n.nrow with
           | Diff.Context s | Diff.Removed s | Diff.Added s -> s)
    |> String.concat "\n"
  in
  Alcotest.(check bool) "diff shows new port" true
    (contains_sub ~needle:"9000" ~haystack:diff_text);
  Alcotest.(check bool) "diff redacts secret" false
    (contains_sub ~needle:"new-secret-99999" ~haystack:diff_text);
  Alcotest.(check bool) "diff contains [redacted]" true
    (contains_sub ~needle:"[redacted]" ~haystack:diff_text);
  (* Interactive key editing: focus move, secret reveal toggle, bool toggle *)
  let st_rev =
    st0
    |> Form.handle_key (key_ev Input.Down)
    |> Form.handle_key (char_ev ' ')
  in
  (match st_rev.fields.(1).value with
   | Form.Secret_val { revealed = true; _ } -> ()
   | Form.Secret_val { revealed = false; _ }
   | Form.Text_val _
   | Form.Multiline_val _
   | Form.Int_val _
   | Form.Float_val _
   | Form.Bool_val _
   | Form.Enum_val _ ->
       Alcotest.fail "Space on secret field should toggle reveal");
  let st_bool =
    st_rev
    |> Form.handle_key (key_ev Input.Down)
    |> Form.handle_key (char_ev ' ')
  in
  (match st_bool.fields.(2).value with
   | Form.Bool_val true -> ()
   | Form.Bool_val false
   | Form.Text_val _
   | Form.Multiline_val _
   | Form.Int_val _
   | Form.Float_val _
   | Form.Enum_val _
   | Form.Secret_val _ ->
       Alcotest.fail "Space on bool field should toggle true")

(* --- 10. Composer Auto-Fold, Pending Tx Pills & Voice Braille Waveform --- *)

let test_composer_modes_and_voice () =
  let st0 = Composer.empty ~target_keeper:"wkbl-growth" in
  Alcotest.(check bool) "Compact idle empty auto-folds" true
    (Composer.equal_mode Composer.Auto_folded_pill
       (Composer.resolve_mode ~breakpoint:Layout.Compact st0));
  Alcotest.(check int) "Auto-folded height is 0" 0
    (Composer.desired_height ~breakpoint:Layout.Compact ~max_height:6 st0);
  (* Pending transmission keeps composer visible on Compact *)
  let st_tx = { st0 with pending_tx = Composer.Tx_sending } in
  Alcotest.(check bool) "Compact with pending tx stays visible" false
    (Composer.equal_mode Composer.Auto_folded_pill
       (Composer.resolve_mode ~breakpoint:Layout.Compact st_tx));
  (* UTF-8 editing + kill_word *)
  let st_edit =
    { st0 with focused = true }
    |> Composer.insert_text "hello 한글 world"
    |> Composer.kill_word
  in
  Alcotest.(check string) "kill_word deletes last word cleanly" "hello 한글 "
    st_edit.draft;
  (* Voice PTT Braille waveform draws Braille cells directly *)
  let st_voice =
    {
      st_edit with
      voice = Composer.Voice_recording { levels = [| 0.2; 0.8; 0.5; 1.0 |]; elapsed_s = 1.5 };
      pending_tx = Composer.Tx_awaiting_turn;
    }
  in
  let grid = Cell_grid.create ~cols:80 ~rows:4 in
  let cursor =
    Composer.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:80 ~h:4) ~theme:Theme.default
      ~lang:Say.Lang_ko ~breakpoint:Layout.Wide st_voice
  in
  Alcotest.(check bool) "focused cursor visible" true cursor.visible;
  let hdr = grid_row_text grid ~y:0 in
  Alcotest.(check bool) "honest pending tx pill shown" true
    (contains_sub ~needle:"응답 대기" ~haystack:hdr);
  let braille_count = ref 0 in
  for x = 0 to 79 do
    match (Cell_grid.get grid ~x ~y:3).glyph with
    | Cell_grid.Braille _ -> incr braille_count
    | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Utf8 _ | Cell_grid.Continuation -> ()
  done;
  Alcotest.(check bool) "voice waveform uses Cell_grid.Braille" true
    (!braille_count > 0);
  (* Slash popup draws cleanly above anchor *)
  let pop_grid = Cell_grid.create ~cols:60 ~rows:12 in
  let popup =
    Composer.Popup_slash
      {
        query = "pu";
        items = [ { trigger = "/pulse"; label = "Jump to Pulse"; detail = None } ];
        selected = 0;
      }
  in
  let pop_rect =
    Composer.draw_popup pop_grid ~anchor:(Rect.make ~x:0 ~y:10 ~w:60 ~h:2)
      ~theme:Theme.default ~lang:Say.Lang_en popup
  in
  Alcotest.(check bool) "popup rendered above composer anchor" true
    (Option.is_some pop_rect)

(* --- 11. Verifier Regression Suite (P1-1..P1-3, P2-1..P2-2) --- *)

let test_json_tree_telemetry_vs_secrets () =
  let json : Yojson.Safe.t =
    `Assoc
      [
        ("input_tokens", `Int 18810000);
        ("output_tokens", `Int 420000);
        ("cache_read_tokens", `Int 18000000);
        ("max_tokens", `Int 200000);
        ("tokens_per_sec", `Float 142.5);
        ("api_key_env", `String "OPENAI_API_KEY");
        ("file_path", `String "/tmp/demo.toml");
        ( "token_usage",
          `Assoc [ ("prompt_tokens", `Int 1000); ("completion_tokens", `Int 250) ] );
        ("x-api-key", `String "raw-header-secret");
        ("credential", `String "cred-val");
        ("passphrase", `String "my-passphrase");
        ("access_key", `String "my-access-key");
        ("bearer", `String "my-bearer-val");
        ("github_pat", `String "my-pat-val");
        ("pat", `String "short-pat");
        ("bot_token", `String "bot-secret-value");
        ("note_sk", `String ("sk-proj-" ^ "1234567890abcdef"));
        ("note_ghp", `String ("ghp_" ^ "1234567890abcdef"));
        ("note_ghpat", `String ("github_pat_" ^ "11AAABBBCCC"));
        ("note_aws", `String ("AKIA" ^ "IOSFODNN7EXAMPLE"));
        ("note_dsn", `String ("postgres://" ^ "admin:supersecret" ^ "@db.local:5432/masc"));
      ]
  in
  let lines = Json_tree.flatten json in
  let value_of path =
    (List.find (fun (l : Json_tree.line) -> String.equal l.path path) lines).value
  in
  (* Telemetry & metadata keys MUST NOT be redacted *)
  Alcotest.(check bool) "input_tokens preserved" true
    (Json_tree.equal_value_display (Json_tree.Int_val 18810000)
       (value_of "$.input_tokens"));
  Alcotest.(check bool) "output_tokens preserved" true
    (Json_tree.equal_value_display (Json_tree.Int_val 420000)
       (value_of "$.output_tokens"));
  Alcotest.(check bool) "cache_read_tokens preserved" true
    (Json_tree.equal_value_display (Json_tree.Int_val 18000000)
       (value_of "$.cache_read_tokens"));
  Alcotest.(check bool) "max_tokens preserved" true
    (Json_tree.equal_value_display (Json_tree.Int_val 200000)
       (value_of "$.max_tokens"));
  Alcotest.(check bool) "tokens_per_sec preserved" true
    (Json_tree.equal_value_display (Json_tree.Float_val 142.5)
       (value_of "$.tokens_per_sec"));
  Alcotest.(check bool) "api_key_env preserved" true
    (Json_tree.equal_value_display (Json_tree.String_val "OPENAI_API_KEY")
       (value_of "$.api_key_env"));
  Alcotest.(check bool) "file_path preserved (pat substring does not false-positive)" true
    (Json_tree.equal_value_display (Json_tree.String_val "/tmp/demo.toml")
       (value_of "$.file_path"));
  Alcotest.(check bool) "token_usage.prompt_tokens preserved" true
    (Json_tree.equal_value_display (Json_tree.Int_val 1000)
       (value_of "$.token_usage.prompt_tokens"));
  (* Credential keys & structural secret values MUST be redacted *)
  List.iter
    (fun path ->
      Alcotest.(check bool) (path ^ " redacted") true
        (Json_tree.equal_value_display Json_tree.Redacted_secret (value_of path)))
    [
      "$.x-api-key";
      "$.credential";
      "$.passphrase";
      "$.access_key";
      "$.bearer";
      "$.github_pat";
      "$.pat";
      "$.bot_token";
      "$.note_sk";
      "$.note_ghp";
      "$.note_ghpat";
      "$.note_aws";
      "$.note_dsn";
    ]

let test_form_secret_diff_scroll_filter_bounds () =
  (* 1. Secret-only edit produces non-zero (-1/+1) diff without leaking raw bytes *)
  let f_sec =
    Form.make_field ~key:"voice.api_key"
      ~label:(Say.make ~ko:"API 키" ~en:"API Key")
      (Form.secret_val "old-secret-1111")
  in
  let st_sec =
    Form.create [ f_sec ]
    |> Form.set_value ~key:"voice.api_key" (Form.secret_val "new-secret-2222")
  in
  let sec_diff = Form.diff_preview st_sec in
  let rem, add =
    Diff.counts (List.map (fun (n : Diff.numbered) -> n.nrow) sec_diff)
  in
  Alcotest.(check int) "secret-only diff removed = 1" 1 rem;
  Alcotest.(check int) "secret-only diff added = 1" 1 add;
  let sec_diff_text =
    sec_diff
    |> List.map (fun (n : Diff.numbered) ->
           match n.nrow with
           | Diff.Context s | Diff.Removed s | Diff.Added s -> s)
    |> String.concat "\n"
  in
  Alcotest.(check bool) "old secret not leaked" false
    (contains_sub ~needle:"old-secret-1111" ~haystack:sec_diff_text);
  Alcotest.(check bool) "new secret not leaked" false
    (contains_sub ~needle:"new-secret-2222" ~haystack:sec_diff_text);
  (* 2. Filter-aware focus & bounds clamping in handle_key *)
  let fields =
    List.init 10 (fun i ->
        Form.make_field
          ~key:(Printf.sprintf "section.field_%02d" i)
          ~label:(Say.make ~ko:(Printf.sprintf "항목 %02d" i) ~en:(Printf.sprintf "Field %02d" i))
          (Form.Bool_val false))
  in
  let st_many = Form.create fields in
  let st_filtered = Form.set_filter "field_07" st_many in
  Alcotest.(check (list int)) "only field_07 visible" [ 7 ]
    (Form.visible_indices st_filtered);
  Alcotest.(check int) "focus re-anchored to visible index 7" 7
    st_filtered.focused;
  (* Moving focus wraps within visible fields only, never touching hidden field 0 *)
  let st_after_nav =
    st_filtered
    |> Form.handle_key (key_ev Input.Down)
    |> Form.handle_key (char_ev ' ')
  in
  Alcotest.(check int) "still focused on 7" 7 st_after_nav.focused;
  Alcotest.(check bool) "hidden field 0 untouched" true
    (Form.equal_field_value (Form.Bool_val false) st_after_nav.fields.(0).value);
  Alcotest.(check bool) "visible field 7 toggled" true
    (Form.equal_field_value (Form.Bool_val true) st_after_nav.fields.(7).value);
  (* Out-of-bounds st.focused never raises *)
  let st_oob_hi = Form.handle_key (char_ev ' ') { st_many with focused = 999 } in
  let st_oob_lo = Form.handle_key (key_ev Input.Down) { st_many with focused = -5 } in
  Alcotest.(check bool) "oob high clamped safely" true
    (st_oob_hi.focused >= 0 && st_oob_hi.focused < 10);
  Alcotest.(check bool) "oob low clamped safely" true
    (st_oob_lo.focused >= 0 && st_oob_lo.focused < 10);
  (* 3. Vertical scroll in Form.draw keeps focused field 8 visible in h=4 viewport *)
  let st_focus8 = { st_many with focused = 8 } in
  let grid = Cell_grid.create ~cols:60 ~rows:4 in
  ignore
    (Form.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h:4) ~theme:Theme.default
       ~lang:Say.Lang_en st_focus8);
  let viewport_text =
    String.concat "\n" (List.init 4 (fun y -> grid_row_text grid ~y))
  in
  Alcotest.(check bool) "focused field 08 scrolled into 4-row viewport" true
    (contains_sub ~needle:"Field 08" ~haystack:viewport_text)

let test_slash_trailing_space_completion () =
  Alcotest.(check (list string)) "/theme <space> lists all presets"
    (List.map (fun p -> "/theme " ^ Theme.preset_name p) Theme.all_presets)
    (Slash.complete ~prefix:"/theme ");
  Alcotest.(check (list string)) "/lang <space> lists ko and en"
    [ "/lang ko"; "/lang en" ]
    (Slash.complete ~prefix:"/lang ");
  Alcotest.(check (list string)) "/tools <space> lists all modes"
    [ "/tools compact"; "/tools results"; "/tools full" ]
    (Slash.complete ~prefix:"/tools ")

let test_composer_voice_h2_narrow_and_panning () =
  (* 1. At rect.h = 2 with Voice_recording, row 1 preserves Braille waveform *)
  let st_h2 =
    {
      (Composer.empty ~target_keeper:"wkbl") with
      focused = true;
      draft = "draft text should not overwrite voice bar";
      cursor = 41;
      voice = Composer.Voice_recording { levels = [| 0.4; 0.9; 0.7; 1.0 |]; elapsed_s = 2.0 };
    }
  in
  let g_h2 = Cell_grid.create ~cols:60 ~rows:2 in
  ignore
    (Composer.draw g_h2 ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h:2) ~theme:Theme.default
       ~lang:Say.Lang_en ~breakpoint:Layout.Wide st_h2);
  let row1_braille = ref 0 in
  for x = 0 to 59 do
    match (Cell_grid.get g_h2 ~x ~y:1).glyph with
    | Cell_grid.Braille _ -> incr row1_braille
    | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Utf8 _ | Cell_grid.Continuation -> ()
  done;
  Alcotest.(check bool) "h=2 preserves voice waveform on row 1" true
    (!row1_braille > 0);
  (* 2. Narrow Collapsed_bar where right pills don't fit still displays draft *)
  let st_narrow =
    {
      (Composer.empty ~target_keeper:"k") with
      focused = false;
      draft = "visible-draft";
      cursor = 13;
      pending_tx = Composer.Tx_sending;
      draft_count_other_keepers = 2;
    }
  in
  let g_narrow = Cell_grid.create ~cols:24 ~rows:1 in
  ignore
    (Composer.draw g_narrow ~rect:(Rect.make ~x:0 ~y:0 ~w:24 ~h:1)
       ~theme:Theme.default ~lang:Say.Lang_en ~breakpoint:Layout.Wide st_narrow);
  let narrow_row = grid_row_text g_narrow ~y:0 in
  Alcotest.(check bool) "narrow collapsed bar shows draft when right pills skipped"
    true (contains_sub ~needle:"visible-draft" ~haystack:narrow_row);
  (* 3. Horizontal panning keeps typed tail visible on both Expanded and Collapsed *)
  let long_draft = "0123456789abcdefghijklmnopqrstuvwxyz" in
  let st_pan =
    {
      (Composer.empty ~target_keeper:"k") with
      focused = true;
      draft = long_draft;
      cursor = String.length long_draft;
    }
  in
  let g_exp = Cell_grid.create ~cols:16 ~rows:3 in
  let cur_exp =
    Composer.draw g_exp ~rect:(Rect.make ~x:0 ~y:0 ~w:16 ~h:3) ~theme:Theme.default
      ~lang:Say.Lang_en ~breakpoint:Layout.Wide st_pan
  in
  let body_row = grid_row_text g_exp ~y:1 in
  Alcotest.(check bool) "expanded composer pans to show tail xyz" true
    (contains_sub ~needle:"xyz" ~haystack:body_row);
  Alcotest.(check bool) "expanded cursor stays in bounds" true
    (cur_exp.visible && cur_exp.x >= 2 && cur_exp.x < 16);
  let g_col = Cell_grid.create ~cols:24 ~rows:1 in
  let cur_col =
    Composer.draw g_col ~rect:(Rect.make ~x:0 ~y:0 ~w:24 ~h:1) ~theme:Theme.default
      ~lang:Say.Lang_en ~breakpoint:Layout.Micro st_pan
  in
  let col_row = grid_row_text g_col ~y:0 in
  Alcotest.(check bool) "collapsed composer pans to show tail xyz" true
    (contains_sub ~needle:"xyz" ~haystack:col_row);
  Alcotest.(check bool) "collapsed cursor stays in bounds" true
    (cur_col.visible && cur_col.x >= 0 && cur_col.x < 24);
  (* 4. Mixed Hangul+ASCII horizontal panning must NEVER splice chars after a skipped wide glyph *)
  let mixed_draft = "12345abc가def" in
  (* Cursor sits right before '가' (byte 8, col 8); rect w=6 -> content_w=4 -> target_start = 8 - 3 = 5 ('a').
     Visible slice should be "abc" (3 cols), stopping when 2-cell '가' overflows 4 cols — NEVER "abcd"! *)
  let st_mixed =
    {
      (Composer.empty ~target_keeper:"k") with
      focused = true;
      draft = mixed_draft;
      cursor = 8;
    }
  in
  let g_mix = Cell_grid.create ~cols:6 ~rows:3 in
  ignore
    (Composer.draw g_mix ~rect:(Rect.make ~x:0 ~y:0 ~w:6 ~h:3) ~theme:Theme.default
       ~lang:Say.Lang_en ~breakpoint:Layout.Wide st_mixed);
  let mix_row = grid_row_text g_mix ~y:1 in
  Alcotest.(check bool) "mixed Hangul+ASCII pan shows abc" true
    (contains_sub ~needle:"abc" ~haystack:mix_row);
  Alcotest.(check bool) "mixed Hangul+ASCII pan does not splice trailing 'd' across skipped '가'" false
    (contains_sub ~needle:"abcd" ~haystack:mix_row)

(* --- 12. v2.5 Visual Design System & Core UI Foundation --- *)

let test_v25_typography_layout_and_card () =
  let theme = Theme.default in
  (* 4-tier Typography invariants *)
  let s1 = Typography.anchor theme in
  let s2 = Typography.primary theme in
  let s3 = Typography.structure theme in
  let s4 = Typography.whisper theme in
  Alcotest.(check bool) "Tier 1 Anchor is bold text_bright" true
    (Color.equal s1.fg (Color.of_rgb theme.text_bright) && Attr.has s1.attrs Attr.bold);
  Alcotest.(check bool) "Tier 2 Primary is regular text_primary" true
    (Color.equal s2.fg (Color.of_rgb theme.text_primary) && Attr.equal s2.attrs Attr.none);
  Alcotest.(check bool) "Tier 3 Structure is text_secondary" true
    (Color.equal s3.fg (Color.of_rgb theme.text_secondary));
  Alcotest.(check bool) "Tier 4 Whisper uses Attr.italic on text_muted" true
    (Color.equal s4.fg (Color.of_rgb theme.text_muted) && Attr.has s4.attrs Attr.italic);
  let s_ai = Typography.ai theme in
  Alcotest.(check bool) "Violet AI token uses status_ai" true
    (Color.equal s_ai.fg (Color.of_rgb theme.status_ai));

  (* Layout spacing & anti-void helpers *)
  Alcotest.(check int) "Wide outer_margin = 1" 1 (Layout.outer_margin Layout.Wide);
  Alcotest.(check int) "Compact outer_margin = 0" 0 (Layout.outer_margin Layout.Compact);
  Alcotest.(check int) "Wide card_gap_x = 2" 2 (Layout.card_gap_x Layout.Wide);
  Alcotest.(check int) "Standard card_gap_x = 1" 1 (Layout.card_gap_x Layout.Standard);
  Alcotest.(check int) "Wide card_gap_y = 1" 1 (Layout.card_gap_y Layout.Wide);
  Alcotest.(check int) "Compact card_gap_y = 0" 0 (Layout.card_gap_y Layout.Compact);
  Alcotest.(check int) "Wide card_pad_x = 2" 2 (Layout.card_pad_x Layout.Wide);
  Alcotest.(check int) "Compact card_pad_x = 1" 1 (Layout.card_pad_x Layout.Compact);
  Alcotest.(check int) "adaptive_list_height 5 goals -> 9" 9
    (Layout.adaptive_list_height ~items:5 ~min_h:6 ~max_h:12 ());
  Alcotest.(check int) "adaptive_list_height clamps min" 6
    (Layout.adaptive_list_height ~items:0 ~min_h:6 ~max_h:12 ());
  Alcotest.(check int) "adaptive_list_height clamps max" 12
    (Layout.adaptive_list_height ~items:40 ~min_h:6 ~max_h:12 ());
  let wide_body = Layout.inset_body Layout.Wide (Rect.make ~x:0 ~y:2 ~w:140 ~h:34) in
  Alcotest.(check int) "inset_body x = 1" 1 wide_body.x;
  Alcotest.(check int) "inset_body w = 138" 138 wide_body.w;
  let l_pane, r_pane = Layout.adaptive_split_2 Layout.Wide wide_body in
  Alcotest.(check bool) "Wide splits horizontally with gap 2" true
    (r_pane.x = Rect.right l_pane + 2 && l_pane.h = r_pane.h);
  let top_p, bot_p =
    Layout.adaptive_split_2 Layout.Compact (Rect.make ~x:0 ~y:2 ~w:90 ~h:24)
  in
  Alcotest.(check bool) "Compact stacks vertically" true
    (bot_p.y = Rect.bottom top_p && top_p.w = bot_p.w);

  (* Card content_rect, hairline, left_rail, section_band *)
  let outer = Rect.make ~x:0 ~y:0 ~w:44 ~h:10 in
  let content = Card.content_rect ~pad_x:2 outer in
  Alcotest.(check int) "content_rect x = 3 (border 1 + pad 2)" 3 content.x;
  Alcotest.(check int) "content_rect w = 38 (44 - 2 - 4)" 38 content.w;
  let grid = Cell_grid.create ~cols:44 ~rows:10 in
  let inner =
    Card.draw grid ~rect:outer ~theme
      {
        (Card.default_spec ~title:"Pulse") with
        badge = Some { glyph = Some Glyph.Live_healthy; text = "LIVE"; tone = Some Theme.Status_ok };
        hotkey = Some "[1]";
        focused = true;
      }
  in
  (* Top border contains italic hotkey & right-aligned badge *)
  let top_row = grid_row_text grid ~y:0 in
  Alcotest.(check bool) "card top border shows badge" true
    (contains_sub ~needle:"LIVE" ~haystack:top_row);
  Alcotest.(check bool) "card top border shows hotkey" true
    (contains_sub ~needle:"[1]" ~haystack:top_row);
  Card.draw_section_band grid ~rect:inner ~theme ~left_title:"Section"
    ~right_meta:"providers.main" ~subtitle:"Source: Global TOML" ();
  Alcotest.(check bool) "section band paints surface_2" true
    (Color.equal (Cell_grid.get grid ~x:inner.x ~y:inner.y).style.bg
       (Color.of_rgb theme.surface_2));
  Card.draw_hairline ~pad_x:2 ~label:"Details" grid ~rect:inner ~y:(inner.y + 3) ~theme;
  Alcotest.(check bool) "hairline paints border_subtle" true
    (Color.equal (Cell_grid.get grid ~x:(inner.x + 2) ~y:(inner.y + 3)).style.fg
       (Color.of_rgb theme.border_subtle));
  Card.draw_left_rail ~tone:Theme.Status_ai grid ~x:(inner.x + 2) ~y:(inner.y + 5) ~h:2 ~theme;
  let rail_cell = Cell_grid.get grid ~x:(inner.x + 2) ~y:(inner.y + 5) in
  Alcotest.(check bool) "left_rail uses Glyph.Left_rail in Violet" true
    (Cell_grid.glyph_equal rail_cell.glyph (Cell_grid.Utf8 "▎")
     && Color.equal rail_cell.style.fg (Color.of_rgb theme.status_ai))

let test_v25_table_calm_selection_and_chart_violet () =
  let theme = Theme.default in
  let cols : Table.column list =
    [
      { id = "name"; header = Say.literal "Goal"; priority = 0; min_width = 14; max_width = Some 20; weight = 2; align = Table.Left };
      { id = "status"; header = Say.literal "State"; priority = 1; min_width = 10; max_width = Some 12; weight = 1; align = Table.Left };
      { id = "prog"; header = Say.literal "Progress"; priority = 1; min_width = 16; max_width = Some 20; weight = 1; align = Table.Left };
    ]
  in
  let rows : Table.row list =
    [
      {
        id = "g1";
        cells =
          [
            ("name", Table.text_cell "MASC Core");
            ("status", Table.Badge { glyph = Some Glyph.Live_healthy; text = "LIVE"; tone = Theme.Status_ok });
            ("prog", Table.Gauge { ratio = 0.5; gradient = Chart.Gradient.Efficiency; label = Some "2/4" });
          ];
      };
    ]
  in
  let grid = Cell_grid.create ~cols:64 ~rows:6 in
  let res =
    Table.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:64 ~h:6) ~theme
      ~caps:Presenter.default_capabilities ~lang:Say.Lang_en ~selected:0
      ~columns:cols rows
  in
  Alcotest.(check int) "header + hairline + 4 viewport rows" 4 res.viewport_rows;
  (* Row 1 is the border_subtle hairline separator *)
  Alcotest.(check bool) "row 1 hairline uses border_subtle" true
    (Color.equal (Cell_grid.get grid ~x:0 ~y:1).style.fg
       (Color.of_rgb theme.border_subtle));
  (* Row 2 is selected row: calm selection_bg + Left_rail in accent + preserved Emerald Badge *)
  let rail = Cell_grid.get grid ~x:0 ~y:2 in
  Alcotest.(check bool) "selected row paints Left_rail in accent on selection_bg" true
    (Cell_grid.glyph_equal rail.glyph (Cell_grid.Utf8 "▎")
     && Color.equal rail.style.fg (Color.of_rgb theme.accent)
     && Color.equal rail.style.bg (Color.of_rgb theme.selection_bg));
  let primary_cell = Cell_grid.get grid ~x:2 ~y:2 in
  Alcotest.(check bool) "selected primary col promoted to text_bright Bold" true
    (Color.equal primary_cell.style.fg (Color.of_rgb theme.text_bright)
     && Attr.has primary_cell.style.attrs Attr.bold);
  let badge_preserved = ref false in
  for x = 0 to 63 do
    let c = Cell_grid.get grid ~x ~y:2 in
    if Color.equal c.style.fg (Color.of_rgb theme.status_ok)
       && Color.equal c.style.bg (Color.of_rgb theme.selection_bg)
    then badge_preserved := true
  done;
  Alcotest.(check bool) "semantic Emerald Badge preserved on selected row" true
    !badge_preserved;

  (* Chart Ai_flow Violet gradient + ~show_title:false + italic X ticks *)
  let ts = sample_ts_spec () in
  let ai_spec =
    match ts.kind with
    | Chart.Spec.Time_series t ->
        {
          ts with
          kind =
            Chart.Spec.Time_series
              { t with series = { t.series with gradient = Chart.Gradient.violet } };
        }
    | Chart.Spec.Dual_inverted _ | Chart.Spec.Ratio_gauge _ | Chart.Spec.Stacked_bar _ -> ts
  in
  let cg = Cell_grid.create ~cols:60 ~rows:8 in
  ignore
    (Chart.draw cg ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h:8) ~theme
       ~caps:Presenter.default_capabilities ~lang:Say.Lang_en ~show_title:false
       ai_spec);
  let hdr_text = grid_row_text cg ~y:0 in
  Alcotest.(check bool) "show_title:false omits duplicate card title" false
    (contains_sub ~needle:"Token Velocity" ~haystack:hdr_text);
  Alcotest.(check bool) "show_title:false keeps Now KPI" true
    (contains_sub ~needle:"Now" ~haystack:hdr_text);
  (* X-axis footer uses Attr.italic *)
  let x_cell = Cell_grid.get cg ~x:8 ~y:7 in
  Alcotest.(check bool) "X-axis tick uses Attr.italic" true
    (Attr.has x_cell.style.attrs Attr.italic);
  (* Empty Absent-only chart omits stray X-axis ticks *)
  let empty_spec =
    match ts.kind with
    | Chart.Spec.Time_series t ->
        {
          ts with
          kind =
            Chart.Spec.Time_series
              { t with series = { t.series with samples = Array.make 12 Chart.Series.Absent } };
        }
    | Chart.Spec.Dual_inverted _ | Chart.Spec.Ratio_gauge _ | Chart.Spec.Stacked_bar _ -> ts
  in
  let eg = Cell_grid.create ~cols:60 ~rows:8 in
  ignore
    (Chart.draw eg ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h:8) ~theme
       ~caps:Presenter.default_capabilities ~lang:Say.Lang_en empty_spec);
  let empty_bottom = grid_row_text eg ~y:7 in
  Alcotest.(check bool) "empty chart omits stray X-axis ticks" false
    (contains_sub ~needle:"-24h" ~haystack:empty_bottom);
  (* Dual_mirror_chart renders zero-axis hairline + X-axis ticks on both even (8) & odd (9) heights *)
  let dual_spec : Chart.Spec.t =
    match ts.kind with
    | Chart.Spec.Time_series { series; window; _ } ->
        {
          title = Say.literal "Dual";
          kind =
            Chart.Spec.Dual_inverted
              { upper = series; lower = series; scale = Chart.Scale.Synced_pair; window };
          hotkey_hint = None;
        }
    | Chart.Spec.Dual_inverted _ | Chart.Spec.Ratio_gauge _ | Chart.Spec.Stacked_bar _ -> ts
  in
  List.iter
    (fun h ->
      let dg = Cell_grid.create ~cols:60 ~rows:h in
      ignore
        (Chart.draw dg ~rect:(Rect.make ~x:0 ~y:0 ~w:60 ~h) ~theme
           ~caps:Presenter.default_capabilities ~lang:Say.Lang_en dual_spec);
      let all_rows =
        String.concat "\n" (List.init h (fun y -> grid_row_text dg ~y))
      in
      Alcotest.(check bool) (Printf.sprintf "dual h=%d shows X ticks" h) true
        (contains_sub ~needle:"-24h" ~haystack:all_rows
         && contains_sub ~needle:"now" ~haystack:all_rows);
      Alcotest.(check bool) (Printf.sprintf "dual h=%d shows zero hairline" h) true
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Box_h) ~haystack:all_rows))
    [ 8; 9 ]

let test_v25_markdown_form_inspector_and_composer () =
  let theme = Theme.default in
  (* Markdown: H1 hairline, italic blockquote with Left_rail, surface_2 inline code, surface_0 fenced code *)
  let md = "# Title\n> A calm quote\nUse `foo` here\n\n```ocaml\nlet a = 1\n```" in
  let mg = Cell_grid.create ~cols:50 ~rows:10 in
  ignore (Markdown.draw mg ~rect:(Rect.make ~x:0 ~y:0 ~w:50 ~h:10) ~theme md);
  Alcotest.(check bool) "H1 bold text_bright" true
    (Color.equal (Cell_grid.get mg ~x:0 ~y:0).style.fg (Color.of_rgb theme.text_bright)
     && Attr.has (Cell_grid.get mg ~x:0 ~y:0).style.attrs Attr.bold);
  Alcotest.(check bool) "H1 hairline row beneath heading" true
    (Color.equal (Cell_grid.get mg ~x:0 ~y:1).style.fg (Color.of_rgb theme.border_subtle));
  Alcotest.(check bool) "blockquote uses Left_rail + italic text" true
    (Cell_grid.glyph_equal (Cell_grid.get mg ~x:0 ~y:2).glyph (Cell_grid.Utf8 "▎")
     && Attr.has (Cell_grid.get mg ~x:2 ~y:2).style.attrs Attr.italic);
  let has_inline_s2 = ref false in
  for x = 0 to 49 do
    if Color.equal (Cell_grid.get mg ~x ~y:3).style.bg (Color.of_rgb theme.surface_2)
    then has_inline_s2 := true
  done;
  Alcotest.(check bool) "inline code uses surface_2 background" true !has_inline_s2;

  (* Form Section Property Inspector mode *)
  Alcotest.(check string) "strip_key_prefix removes dotted prefix" "endpoint_url"
    (Form.strip_key_prefix ~prefix:"providers.acme_api"
       "providers.acme_api.endpoint_url");
  let f1 =
    Form.make_field ~key:"providers.acme_api.endpoint_url"
      ~label:(Say.make ~ko:"엔드포인트" ~en:"Endpoint")
      ~help:(Say.make ~ko:"API 기본 엔드포인트" ~en:"Base API endpoint URL")
      ~provenance:Form.Prov_global_toml ~reload_scope:Form.Restart_required
      (Form.Text_val "https://api.anthropic.com")
  in
  let f2 =
    Form.make_field ~key:"providers.acme_api.api_key_env"
      ~label:(Say.make ~ko:"API 키 환경변수" ~en:"API Key Env")
      ~provenance:(Form.Prov_env "ANTHROPIC_API_KEY")
      ~reload_scope:Form.Restart_required
      (Form.Text_val "ANTHROPIC_API_KEY")
  in
  let st = Form.create [ f1; f2 ] in
  let hdr : Form.section_header =
    {
      title = Say.literal "Acme API";
      canonical_prefix = Some "providers.acme_api";
      provenance = Form.Prov_global_toml;
      reload_scope = Form.Restart_required;
    }
  in
  let fg = Cell_grid.create ~cols:80 ~rows:14 in
  ignore
    (Form.draw fg ~rect:(Rect.make ~x:0 ~y:0 ~w:80 ~h:14) ~theme ~lang:Say.Lang_ko
       ~section_header:hdr st);
  let band0 = grid_row_text fg ~y:0 in
  let band1 = grid_row_text fg ~y:1 in
  Alcotest.(check bool) "section band row 0 has title + prefix" true
    (contains_sub ~needle:"Acme API" ~haystack:band0
     && contains_sub ~needle:"providers.acme_api" ~haystack:band0);
  Alcotest.(check bool) "section band row 1 has consolidated provenance" true
    (contains_sub ~needle:"전역 TOML" ~haystack:band1
     && contains_sub ~needle:"재시작 필요" ~haystack:band1);
  let row_f1 = grid_row_text fg ~y:3 in
  let row_f2 = grid_row_text fg ~y:4 in
  Alcotest.(check bool) "row 1 uses Left_rail focus & suppresses repeated provenance badge" true
    (contains_sub ~needle:"▎" ~haystack:row_f1
     && not (contains_sub ~needle:"[전역 TOML]" ~haystack:row_f1));
  Alcotest.(check bool) "row 2 surfaces exception-only [환경변수] chip" true
    (contains_sub ~needle:"[환경변수]" ~haystack:row_f2);
  let help_row = grid_row_text fg ~y:12 in
  Alcotest.(check bool) "bottom help footer shows focused field description" true
    (contains_sub ~needle:"API 기본 엔드포인트" ~haystack:help_row);

  (* Composer: italic placeholder when unfocused, Left_rail when focused *)
  let cg_unfoc = Cell_grid.create ~cols:80 ~rows:1 in
  ignore
    (Composer.draw cg_unfoc ~rect:(Rect.make ~x:0 ~y:0 ~w:80 ~h:1) ~theme
       ~lang:Say.Lang_en ~breakpoint:Layout.Wide
       (Composer.empty ~target_keeper:"leader"));
  let has_italic_ph = ref false in
  for x = 0 to 79 do
    if Attr.has (Cell_grid.get cg_unfoc ~x ~y:0).style.attrs Attr.italic then
      has_italic_ph := true
  done;
  Alcotest.(check bool) "composer unfocused placeholder uses Attr.italic" true
    !has_italic_ph;
  let cg_foc = Cell_grid.create ~cols:80 ~rows:2 in
  ignore
    (Composer.draw cg_foc ~rect:(Rect.make ~x:0 ~y:0 ~w:80 ~h:2) ~theme
       ~lang:Say.Lang_en ~breakpoint:Layout.Wide
       { (Composer.empty ~target_keeper:"leader") with focused = true });
  Alcotest.(check bool) "focused composer paints Left_rail on row 0" true
    (Cell_grid.glyph_equal (Cell_grid.get cg_foc ~x:0 ~y:0).glyph (Cell_grid.Utf8 "▎"))

let test_v25_chart_full_width_braille_stretch () =
  let theme = Theme.default in
  let caps = Presenter.default_capabilities in
  let count_braille grid ~x0 ~x1 ~y0 ~y1 =
    let n = ref 0 in
    for y = y0 to y1 do
      for x = x0 to x1 do
        match (Cell_grid.get grid ~x ~y).glyph with
        | Cell_grid.Braille mask when mask <> 0 -> incr n
        | Cell_grid.Braille _
        | Cell_grid.Empty
        | Cell_grid.Ascii _
        | Cell_grid.Utf8 _
        | Cell_grid.Continuation ->
            ()
      done
    done;
    !n
  in
  let mk_series ?(label = Say.literal "") samples : Chart.Series.t =
    {
      label;
      unit = Format_val.Percent;
      gradient = Chart.Gradient.Efficiency;
      samples;
      current = Observed.value ~observed_at:Clock.Mono.zero 96.0;
      peak = Observed.value ~observed_at:Clock.Mono.zero 98.0;
      avg = Observed.value ~observed_at:Clock.Mono.zero 92.5;
      delta_pct = None;
    }
  in
  (* 1. 24-point series on 68-col (plot_cols=60, 120 sub-cols) Full_area_chart spans left/mid/right thirds *)
  let samples_24 =
    Array.init 24 (fun i ->
        Chart.Series.Value (55.0 +. (float_of_int ((i * 7) mod 11) *. 3.5)))
  in
  let full_spec : Chart.Spec.t =
    {
      title = Say.literal "Cache Hit";
      hotkey_hint = None;
      kind =
        Chart.Spec.Time_series
          {
            series = mk_series samples_24;
            scale = Chart.Scale.Fixed_bounds { floor = 0.0; ceiling = 100.0 };
            window = Chart.Time_window.Last_24h;
          };
    }
  in
  let g_full = Cell_grid.create ~cols:68 ~rows:8 in
  ignore
    (Chart.draw g_full ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:8) ~theme ~caps
       ~lang:Say.Lang_en ~show_title:false full_spec);
  let left_b = count_braille g_full ~x0:8 ~x1:27 ~y0:1 ~y1:6 in
  let mid_b = count_braille g_full ~x0:28 ~x1:47 ~y0:1 ~y1:6 in
  let right_b = count_braille g_full ~x0:48 ~x1:67 ~y0:1 ~y1:6 in
  Alcotest.(check bool)
    (Printf.sprintf "Full_area_chart left third (-24h) populated (got %d)" left_b)
    true (left_b >= 20);
  Alcotest.(check bool)
    (Printf.sprintf "Full_area_chart mid third (-12h) populated (got %d)" mid_b)
    true (mid_b >= 20);
  Alcotest.(check bool)
    (Printf.sprintf "Full_area_chart right third (now) populated (got %d)" right_b)
    true (right_b >= 20);
  (* Empty series.label with ~show_title:false omits redundant left label & window prefix *)
  let full_hdr = grid_row_text g_full ~y:0 in
  Alcotest.(check bool) "empty label + show_title:false omits 24h left prefix" false
    (contains_sub ~needle:"24h" ~haystack:full_hdr);
  Alcotest.(check bool) "empty label + show_title:false keeps Now/Peak/Avg strip" true
    (contains_sub ~needle:"Now" ~haystack:full_hdr
     && contains_sub ~needle:"Peak" ~haystack:full_hdr
     && contains_sub ~needle:"Avg" ~haystack:full_hdr);
  (* 2. 24-point Dual_mirror_chart spans left/mid/right thirds on BOTH upper & lower halves *)
  let lower_24 =
    Array.init 24 (fun i ->
        Chart.Series.Value (40.0 +. (float_of_int ((i * 5) mod 9) *. 5.0)))
  in
  let dual_spec : Chart.Spec.t =
    {
      title = Say.literal "Dual 24h";
      hotkey_hint = None;
      kind =
        Chart.Spec.Dual_inverted
          {
            upper = mk_series ~label:(Say.literal "Up") samples_24;
            lower = mk_series ~label:(Say.literal "Dn") lower_24;
            scale = Chart.Scale.Synced_pair;
            window = Chart.Time_window.Last_24h;
          };
    }
  in
  let g_dual = Cell_grid.create ~cols:68 ~rows:10 in
  ignore
    (Chart.draw g_dual ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:10) ~theme ~caps
       ~lang:Say.Lang_en ~show_title:false dual_spec);
  let up_l = count_braille g_dual ~x0:8 ~x1:27 ~y0:1 ~y1:3 in
  let up_m = count_braille g_dual ~x0:28 ~x1:47 ~y0:1 ~y1:3 in
  let up_r = count_braille g_dual ~x0:48 ~x1:67 ~y0:1 ~y1:3 in
  let dn_l = count_braille g_dual ~x0:8 ~x1:27 ~y0:5 ~y1:7 in
  let dn_m = count_braille g_dual ~x0:28 ~x1:47 ~y0:5 ~y1:7 in
  let dn_r = count_braille g_dual ~x0:48 ~x1:67 ~y0:5 ~y1:7 in
  Alcotest.(check bool) "Dual_mirror upper spans left/mid/right thirds" true
    (up_l >= 10 && up_m >= 10 && up_r >= 10);
  Alcotest.(check bool) "Dual_mirror lower spans left/mid/right thirds" true
    (dn_l >= 10 && dn_m >= 10 && dn_r >= 10);
  (* 3. Absent/Unread interior gap is preserved (never interpolated across missing values) *)
  let gapped_24 =
    Array.init 24 (fun i ->
        if i = 10 || i = 11 then Chart.Series.Absent
        else if i = 12 || i = 13 then Chart.Series.Unread
        else Chart.Series.Value 80.0)
  in
  let gap_spec : Chart.Spec.t =
    {
      full_spec with
      kind =
        Chart.Spec.Time_series
          {
            series = mk_series gapped_24;
            scale = Chart.Scale.Fixed_bounds { floor = 0.0; ceiling = 100.0 };
            window = Chart.Time_window.Last_24h;
          };
    }
  in
  let g_gap = Cell_grid.create ~cols:68 ~rows:8 in
  ignore
    (Chart.draw g_gap ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:8) ~theme ~caps
       ~lang:Say.Lang_en ~show_title:false gap_spec);
  let gap_mid = count_braille g_gap ~x0:35 ~x1:41 ~y0:1 ~y1:6 in
  let gap_left = count_braille g_gap ~x0:8 ~x1:27 ~y0:1 ~y1:6 in
  let gap_right = count_braille g_gap ~x0:48 ~x1:67 ~y0:1 ~y1:6 in
  Alcotest.(check int) "interior Absent/Unread gap has 0 Braille dots" 0 gap_mid;
  Alcotest.(check bool) "data flanking gap still fills left & right" true
    (gap_left >= 20 && gap_right >= 20);
  (* 4. Single-point series (n = 1) stays right-aligned without stretching into a flat wall *)
  let single_spec : Chart.Spec.t =
    {
      full_spec with
      kind =
        Chart.Spec.Time_series
          {
            series = mk_series [| Chart.Series.Value 85.0 |];
            scale = Chart.Scale.Fixed_bounds { floor = 0.0; ceiling = 100.0 };
            window = Chart.Time_window.Last_24h;
          };
    }
  in
  let g_one = Cell_grid.create ~cols:68 ~rows:8 in
  ignore
    (Chart.draw g_one ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:8) ~theme ~caps
       ~lang:Say.Lang_en ~show_title:false single_spec);
  let one_left_mid = count_braille g_one ~x0:8 ~x1:65 ~y0:1 ~y1:6 in
  let one_right_edge = count_braille g_one ~x0:66 ~x1:67 ~y0:1 ~y1:6 in
  Alcotest.(check int) "single-point series leaves cols 8..65 blank (no flat wall)" 0
    one_left_mid;
  Alcotest.(check bool) "single-point series renders at right edge" true
    (one_right_edge > 0)

let test_p0_2_dual_independent_usd_axis () =
  let theme = Theme.default in
  let caps = Presenter.default_capabilities in
  let calls_24 =
    Array.init 24 (fun i ->
        Chart.Series.Value (800.0 +. (float_of_int ((i * 5) mod 13) *. 280.0)))
  in
  let spend_24 =
    Array.init 24 (fun i ->
        Chart.Series.Value (0.45 +. (float_of_int ((i * 7) mod 11) *. 0.567)))
  in
  let upper : Chart.Series.t =
    {
      label = Say.make ~ko:"호출" ~en:"Calls";
      unit = Format_val.Count;
      gradient = Chart.Gradient.Cool_flow;
      samples = calls_24;
      current = Observed.value ~observed_at:Clock.Mono.zero 1840.0;
      peak = Observed.value ~observed_at:Clock.Mono.zero 4160.0;
      avg = Observed.value ~observed_at:Clock.Mono.zero 2100.0;
      delta_pct = None;
    }
  in
  let lower : Chart.Series.t =
    {
      label = Say.make ~ko:"지출" ~en:"Spend";
      unit = Format_val.Usd;
      gradient = Chart.Gradient.Thermal;
      samples = spend_24;
      current = Observed.value ~observed_at:Clock.Mono.zero 2.34;
      peak = Observed.value ~observed_at:Clock.Mono.zero 6.12;
      avg = Observed.value ~observed_at:Clock.Mono.zero 3.15;
      delta_pct = None;
    }
  in
  let spec : Chart.Spec.t =
    {
      title = Say.make ~ko:"24h 처리량 · 비용" ~en:"24h Volume & Cost";
      hotkey_hint = None;
      kind =
        Chart.Spec.Dual_inverted
          {
            upper;
            lower;
            scale =
              Chart.Scale.Dual_independent
                {
                  top_min = 0.0;
                  top_max = 5000.0;
                  bot_min = 0.0;
                  bot_max = 6.12;
                };
            window = Chart.Time_window.Last_24h;
          };
    }
  in
  List.iter
    (fun lang ->
      let grid = Cell_grid.create ~cols:68 ~rows:10 in
      let mode =
        Chart.draw grid ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:10) ~theme ~caps
          ~lang ~show_title:false spec
      in
      (match mode with
      | Chart.Render_mode.Dual_mirror_chart _ -> ()
      | Chart.Render_mode.Full_area_chart _
      | Chart.Render_mode.Half_block_gauge _
      | Chart.Render_mode.Inline_sparkline _
      | Chart.Render_mode.Numeric_delta_pill ->
          Alcotest.fail "expected Dual_mirror_chart for 68x10");
      let upper_axis_row = grid_row_text grid ~y:1 in
      let lower_axis_row = grid_row_text grid ~y:7 in
      let all_rows =
        String.concat "\n" (List.init 10 (fun y -> grid_row_text grid ~y))
      in
      let hdr_row = grid_row_text grid ~y:0 in
      Alcotest.(check bool) "upper Calls axis formats as 5.0k" true
        (contains_sub ~needle:"5.0k" ~haystack:upper_axis_row);
      Alcotest.(check bool) "lower Spend axis formats independently as $6.12"
        true
        (contains_sub ~needle:"$6.12" ~haystack:lower_axis_row);
      Alcotest.(check bool) "lower Spend axis NEVER prints ▼5.0k (1000x lie)"
        false
        (contains_sub ~needle:"▼5.0k" ~haystack:all_rows
        || contains_sub ~needle:"▼200" ~haystack:all_rows);
      Alcotest.(check bool)
        "Dual_mirror with show_title:false omits redundant 24h window suffix"
        false
        (contains_sub ~needle:"24h" ~haystack:hdr_row);
      let count_b ~y0 ~y1 =
        let n = ref 0 in
        for y = y0 to y1 do
          for x = 8 to 67 do
            match (Cell_grid.get grid ~x ~y).glyph with
            | Cell_grid.Braille m when m <> 0 -> incr n
            | Cell_grid.Braille _
            | Cell_grid.Empty
            | Cell_grid.Ascii _
            | Cell_grid.Utf8 _
            | Cell_grid.Continuation ->
                ()
          done
        done;
        !n
      in
      Alcotest.(check bool) "upper half renders Braille samples" true
        (count_b ~y0:1 ~y1:3 >= 20);
      Alcotest.(check bool) "lower USD half renders Braille samples independently"
        true
        (count_b ~y0:5 ~y1:7 >= 20))
    [ Say.Lang_ko; Say.Lang_en ]

let test_memory_age_ladder_math_and_keymap_bindings () =
  (* 1. Age Ladder responsive merge_of_width *)
  Alcotest.(check (option int)) "width 24 -> merge 1" (Some 1)
    (Memory_charts.merge_of_width 24);
  Alcotest.(check (option int)) "width 30 -> merge 1" (Some 1)
    (Memory_charts.merge_of_width 30);
  Alcotest.(check (option int)) "width 12 -> merge 2" (Some 2)
    (Memory_charts.merge_of_width 12);
  Alcotest.(check (option int)) "width 23 -> merge 2" (Some 2)
    (Memory_charts.merge_of_width 23);
  Alcotest.(check (option int)) "width 6 -> merge 4" (Some 4)
    (Memory_charts.merge_of_width 6);
  Alcotest.(check (option int)) "width 5 -> None" None
    (Memory_charts.merge_of_width 5);

  (* 2. Exact boundary indices & tier counts *)
  Alcotest.(check int) "1h edge bin" 1 (Memory_charts.edge_bin Memory_charts.Edge_hour);
  Alcotest.(check int) "1d edge bin" 9 (Memory_charts.edge_bin Memory_charts.Edge_day);
  Alcotest.(check int) "7d edge bin" 17 (Memory_charts.edge_bin Memory_charts.Edge_week);
  Alcotest.(check int) "30d edge bin" 23 (Memory_charts.edge_bin Memory_charts.Edge_month);
  let bins = Array.init 24 (fun i -> i + 1) in
  (match Memory_charts.tier_counts bins with
  | Ok (d, w, p) ->
      (* bins 0..8 -> 1+..+9 = 45; bins 9..16 -> 10+..+17 = 108; bins 17..23 -> 18+..+24 = 147 *)
      Alcotest.(check int) "<1d sum" 45 d;
      Alcotest.(check int) "1-7d sum" 108 w;
      Alcotest.(check int) ">7d sum" 147 p
  | Error msg -> Alcotest.fail msg);

  (* 3. Folding oldest-left to newest-right + newest-bin tier inheritance *)
  (match Memory_charts.fold_bins ~merge:1 bins with
  | Ok cells ->
      Alcotest.(check int) "24 cells" 24 (List.length cells);
      let first = List.nth cells 0 in
      let last = List.nth cells 23 in
      Alcotest.(check int) "leftmost cell is oldest bin 23 (count 24)" 24 first.count;
      Alcotest.(check bool) "leftmost tier >7d" true
        (Memory_charts.equal_age_tier first.tier Memory_charts.Tier_past_week);
      Alcotest.(check int) "rightmost cell is newest bin 0 (count 1)" 1 last.count;
      Alcotest.(check bool) "rightmost tier <1d" true
        (Memory_charts.equal_age_tier last.tier Memory_charts.Tier_within_day)
  | Error msg -> Alcotest.fail msg);
  (match Memory_charts.fold_bins ~merge:2 bins with
  | Ok cells ->
      Alcotest.(check int) "12 cells" 12 (List.length cells);
      (* cell 0 merges bin 23 (24) + bin 22 (23) = 47 *)
      Alcotest.(check int) "merged pair 0 sum" 47 (List.nth cells 0).count;
      (* cell 7 merges bin 9 (10) + bin 8 (9) -> newest bin is 8 (<1d) *)
      let boundary_cell = List.nth cells 7 in
      Alcotest.(check int) "boundary cell newest_bin = 8" 8 boundary_cell.newest_bin;
      Alcotest.(check bool) "boundary cell inherits newest bin tier (<1d)" true
        (Memory_charts.equal_age_tier boundary_cell.tier Memory_charts.Tier_within_day)
  | Error msg -> Alcotest.fail msg);
  (match Memory_charts.fold_bins ~merge:4 bins with
  | Ok cells -> Alcotest.(check int) "6 cells" 6 (List.length cells)
  | Error msg -> Alcotest.fail msg);
  Alcotest.(check bool) "reject wrong array length" true
    (Result.is_error (Memory_charts.fold_bins ~merge:1 [| 1; 2; 3 |]));
  Alcotest.(check bool) "reject invalid merge factor" true
    (Result.is_error (Memory_charts.fold_bins ~merge:3 bins));

  (* 4. Level glyphs never floor positive counts to empty & tick header exact width *)
  Alcotest.(check string) "0 -> dot" "·"
    (Memory_charts.level_glyph ~unicode:true ~count:0 ~max_count:100);
  Alcotest.(check bool) "positive count never floors to dot" false
    (String.equal "·" (Memory_charts.level_glyph ~unicode:true ~count:1 ~max_count:10000));
  Alcotest.(check string) "max count -> full block" "█"
    (Memory_charts.level_glyph ~unicode:true ~count:100 ~max_count:100);
  let hdr24 = Memory_charts.tick_header ~width:24 in
  Alcotest.(check int) "tick_header exact width 24" 24 (String.length hdr24);
  Alcotest.(check bool) "tick_header 24 has 1h/1d/7d/30d" true
    (contains_sub ~needle:"1h" ~haystack:hdr24
     && contains_sub ~needle:"1d" ~haystack:hdr24
     && contains_sub ~needle:"7d" ~haystack:hdr24
     && contains_sub ~needle:"30d" ~haystack:hdr24);
  Alcotest.(check int) "tick_header exact width 12" 12
    (String.length (Memory_charts.tick_header ~width:12));

  (* 5. Fleet age bin aggregation *)
  Alcotest.(check bool) "empty fleet -> None" true
    (Option.is_none (Memory_charts.aggregate_fleet_age_bins []));
  (match Memory_charts.aggregate_fleet_age_bins [ bins; bins ] with
  | Some sum -> Alcotest.(check int) "doubled bin 0" 2 sum.(0)
  | None -> Alcotest.fail "expected aggregated fleet bins");

  (* 6. Keymap zero collisions + new t/s bindings + PR 2 reserved keys untouched *)
  Alcotest.(check int) "zero keymap collisions" 0 (List.length (Keymap.collisions ()));
  let nav_chain = Keymap.scope_chain_of_focus (Nav.Workspace_focused Nav.Knowledge) in
  let ev_char c =
    { Keymap.Input.key = Keymap.Input.Char c; mods = Keymap.Input.no_mods }
  in
  Alcotest.(check bool) "t -> Cycle_memory_view" true
    (Option.equal Keymap.equal_action
       (Keymap.dispatch ~scope_chain:nav_chain (ev_char "t"))
       (Some Keymap.Cycle_memory_view));
  Alcotest.(check bool) "s -> Toggle_memory_sort" true
    (Option.equal Keymap.equal_action
       (Keymap.dispatch ~scope_chain:nav_chain (ev_char "s"))
       (Some Keymap.Toggle_memory_sort));
  Alcotest.(check bool) ". stays unbound for PR 2 Pele Card" true
    (Option.is_none (Keymap.dispatch ~scope_chain:nav_chain (ev_char ".")));
  let ctrl_o =
    {
      Keymap.Input.key = Keymap.Input.Char "o";
      mods = { ctrl = true; alt = false; shift = false };
    }
  in
  Alcotest.(check bool) "Ctrl+O stays Toggle_tool_details (PR 2 hook)" true
    (Option.equal Keymap.equal_action
       (Keymap.dispatch ~scope_chain:nav_chain ctrl_o)
       (Some Keymap.Toggle_tool_details))

let test_memory_flow_braille_chart () =
  let theme = Theme.default in
  let caps = Presenter.default_capabilities in
  let count_braille grid =
    let n = ref 0 in
    for y = 0 to Cell_grid.rows grid - 1 do
      for x = 0 to Cell_grid.cols grid - 1 do
        match (Cell_grid.get grid ~x ~y).glyph with
        | Cell_grid.Braille mask when mask <> 0 -> incr n
        | Cell_grid.Braille _
        | Cell_grid.Empty
        | Cell_grid.Ascii _
        | Cell_grid.Utf8 _
        | Cell_grid.Continuation ->
            ()
      done
    done;
    !n
  in
  (* Time_window labels for Last_30d & Rev_span *)
  Alcotest.(check string) "Last_30d label" "30d"
    (Chart.Time_window.label Chart.Time_window.Last_30d);
  Alcotest.(check string) "Rev_span label" "r12..r48"
    (Chart.Time_window.label (Chart.Time_window.Rev_span { from_rev = 12; to_rev = 48 }));
  (* chart_height_for adaptive breakpoints *)
  Alcotest.(check int) "chart_height_for 20 = 7" 7 (Memory_flow.chart_height_for ~avail_h:20);
  Alcotest.(check int) "chart_height_for 8 = 2" 2 (Memory_flow.chart_height_for ~avail_h:8);
  Alcotest.(check int) "chart_height_for 4 = 0" 0 (Memory_flow.chart_height_for ~avail_h:4);
  (* Honest empty state -> ZERO Braille dots *)
  let empty_in : Memory_flow.input =
    {
      revisions = [];
      from_unix = Some 1795167600.0;
      to_unix = Some 1795254000.0;
      total_now = 100;
      is_world = false;
      window = Memory_flow.Window_24h;
    }
  in
  let g_empty = Cell_grid.create ~cols:68 ~rows:7 in
  Memory_flow.draw g_empty ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:7) ~theme ~caps
    ~lang:Say.Lang_en ~now_unix:1795254000.0 ~mode:Memory_flow.Flow_io empty_in;
  Alcotest.(check int) "empty Memory_flow draws 0 Braille cells" 0 (count_braille g_empty);
  let txt_empty =
    String.concat "\n" (List.init 7 (fun y -> grid_row_text g_empty ~y))
  in
  Alcotest.(check bool) "empty notice honest" true
    (contains_sub ~needle:"No observed revisions" ~haystack:txt_empty);
  (* Honest single-point state -> mentions r42 *)
  let single_in =
    {
      empty_in with
      revisions =
        [ { Memory_flow.rev = 42; at_unix = 1795250000.0; added = 5; removed = 1 } ];
    }
  in
  let g_single = Cell_grid.create ~cols:68 ~rows:7 in
  Memory_flow.draw g_single ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:7) ~theme ~caps
    ~lang:Say.Lang_en ~now_unix:1795254000.0 ~mode:Memory_flow.Flow_io single_in;
  let txt_single =
    String.concat "\n" (List.init 7 (fun y -> grid_row_text g_single ~y))
  in
  Alcotest.(check bool) "single-point notice shows r42" true
    (contains_sub ~needle:"r42" ~haystack:txt_single);
  (* Real multi-revision series -> Flow_io & Net_total draw non-zero Braille *)
  let real_revs =
    List.init 8 (fun i ->
        {
          Memory_flow.rev = 10 + i;
          at_unix = 1795170000.0 +. (float_of_int i *. 10800.0);
          added = 2 + (i mod 4);
          removed = if i mod 2 = 0 then 1 else 0;
        })
  in
  let real_in = { empty_in with revisions = real_revs; total_now = 140 } in
  let g_flow = Cell_grid.create ~cols:68 ~rows:7 in
  Memory_flow.draw g_flow ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:7) ~theme ~caps
    ~lang:Say.Lang_en ~now_unix:1795254000.0 ~mode:Memory_flow.Flow_io real_in;
  Alcotest.(check bool) "Flow_io draws Braille cells" true (count_braille g_flow > 0);
  let g_net = Cell_grid.create ~cols:68 ~rows:7 in
  Memory_flow.draw g_net ~rect:(Rect.make ~x:0 ~y:0 ~w:68 ~h:7) ~theme ~caps
    ~lang:Say.Lang_en ~now_unix:1795254000.0 ~mode:Memory_flow.Net_total real_in;
  Alcotest.(check bool) "Net_total draws Braille cells" true (count_braille g_net > 0);
  let txt_net =
    String.concat "\n" (List.init 7 (fun y -> grid_row_text g_net ~y))
  in
  Alcotest.(check bool) "Net_total renders mode label" true
    (contains_sub ~needle:"Net Total" ~haystack:txt_net)

let test_wave2_html_doc_renderer () =
  let theme = Theme.of_preset Theme.Midnight in
  let html =
    {|<!doctype html>
    <html>
      <head><title>Ignored Head</title><style>.x{color:red}</style></head>
      <body>
        <script>alert("XSS_SECRET_SCRIPT");</script>
        <div hidden>HIDDEN_SECRET</div>
        <span aria-hidden="true">ARIA_HIDDEN_SECRET</span>
        <h1>Wave 2 Report</h1>
        <p>한글과 English가 섞인 문단입니다. See <a href="https://example.invalid/docs">Docs</a>.</p>
        <table>
          <thead><tr><th>Metric</th><th>Value</th></tr></thead>
          <tbody>
            <tr><td>Cache Hit</td><td>95.2%</td></tr>
            <tr><td>Latency p95</td><td>42ms</td></tr>
          </tbody>
        </table>
        <ul><li>First bullet</li><li>Second bullet</li></ul>
        <pre>let ok = true</pre>
        <img alt="Chart" src="data:image/png;base64,AAAA" />
      </body>
    </html>|}
  in
  let lines =
    Masc_tui_ui.Html_doc.render_lines ~theme ~width:60 ~lang:Say.Lang_en
      ~search_query:"95.2%" html
  in
  let joined =
    lines
    |> List.map (fun (l : Masc_tui_ui.Html_doc.rendered_line) -> l.text)
    |> String.concat "\n"
  in
  let contains ~needle hay =
    let nlen = String.length needle and hlen = String.length hay in
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub hay i nlen = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  Alcotest.(check bool) "strips <script>" false
    (contains ~needle:"XSS_SECRET_SCRIPT" joined);
  Alcotest.(check bool) "strips <style>" false
    (contains ~needle:"color:red" joined);
  Alcotest.(check bool) "strips hidden" false
    (contains ~needle:"HIDDEN_SECRET" joined);
  Alcotest.(check bool) "strips aria-hidden" false
    (contains ~needle:"ARIA_HIDDEN_SECRET" joined);
  Alcotest.(check bool) "renders H1 heading" true
    (contains ~needle:"Wave 2 Report" joined);
  Alcotest.(check bool) "renders aligned table cells" true
    (contains ~needle:"Cache Hit" joined && contains ~needle:"95.2%" joined);
  Alcotest.(check bool) "renders link URL" true
    (contains ~needle:"https://example.invalid/docs" joined);
  Alcotest.(check bool) "renders <pre> block" true
    (contains ~needle:"let ok = true" joined);
  Alcotest.(check bool) "renders embedded image badge" true
    (contains ~needle:"Chart" joined);
  let matches =
    Masc_tui_ui.Html_doc.search_match_lines ~theme ~width:60 ~lang:Say.Lang_en
      ~query:"95.2%" html
  in
  Alcotest.(check bool) "search_match_lines finds 95.2% row" true
    (List.length matches >= 1);
  let g = Cell_grid.create ~cols:64 ~rows:24 in
  let total =
    Masc_tui_ui.Html_doc.draw g ~rect:(Rect.make ~x:0 ~y:0 ~w:64 ~h:24) ~theme
      ~lang:Say.Lang_en ~search_query:"95.2%"
      ~active_match_line:(List.hd matches) html
  in
  Alcotest.(check bool) "Html_doc.draw renders >= 8 lines" true (total >= 8);

  (* Long CJK + long ASCII word wrapping must preserve 100% of bytes with zero mid-UTF-8 corruption *)
  let long_cjk = "가나다라마바사아자차카타파하가나다라마바사아자차카타파하" in
  let long_ascii = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" in
  let wrap_html = Printf.sprintf "<p>%s %s</p>" long_cjk long_ascii in
  let wrap_lines =
    Masc_tui_ui.Html_doc.render_lines ~theme ~width:16 ~lang:Say.Lang_ko wrap_html
  in
  let wrap_concat =
    wrap_lines
    |> List.map (fun (l : Masc_tui_ui.Html_doc.rendered_line) -> String.trim l.text)
    |> String.concat ""
  in
  let expected_no_spaces = long_cjk ^ long_ascii in
  let actual_no_spaces =
    String.split_on_char ' ' wrap_concat |> String.concat ""
  in
  Alcotest.(check string) "Html_doc wraps CJK + long ASCII with zero dropped bytes"
    expected_no_spaces actual_no_spaces;
  List.iter
    (fun (l : Masc_tui_ui.Html_doc.rendered_line) ->
      Alcotest.(check bool)
        (Printf.sprintf "wrapped line fits <= 16 cols (got %d: %s)"
           (Grapheme.display_width l.text) l.text)
        true (Grapheme.display_width l.text <= 16))
    wrap_lines;

  (* Script/style-only HTML must NEVER leak raw script tags or tokens *)
  let script_only = "<script>LEAK_ME_NEVER();</script><style>body{color:red}</style>" in
  let empty_lines =
    Masc_tui_ui.Html_doc.render_lines ~theme ~width:40 ~lang:Say.Lang_en script_only
  in
  let empty_joined =
    empty_lines
    |> List.map (fun (l : Masc_tui_ui.Html_doc.rendered_line) -> l.text)
    |> String.concat "\n"
  in
  Alcotest.(check bool) "script-only HTML does not leak script content" false
    (contains ~needle:"LEAK_ME_NEVER" empty_joined);
  Alcotest.(check bool) "script-only HTML renders honest empty notice" true
    (contains ~needle:"No visible HTML content" empty_joined)

let test_markdown_parse_inline_linear_unmatched_delimiters () =
  let theme = Theme.default in
  let sample =
    "**bold** *em* __strong__ _ital_ ~~gone~~ `code` [site](https://example.com)"
  in
  let rendered = Markdown.render_lines ~theme ~width:120 ~osc8:true sample in
  let spans =
    List.concat_map (fun (l : Markdown.rendered_line) -> l.spans) rendered
  in
  Alcotest.(check bool) "bold span rendered" true
    (List.exists
       (fun (s : Markdown.styled_span) ->
         String.equal s.text "bold" && Attr.has s.style.attrs Attr.bold)
       spans);
  Alcotest.(check bool) "italic span rendered" true
    (List.exists
       (fun (s : Markdown.styled_span) ->
         String.equal s.text "ital" && Attr.has s.style.attrs Attr.italic)
       spans);
  Alcotest.(check bool) "link hyperlink attached" true
    (List.exists
       (fun (s : Markdown.styled_span) ->
         String.equal s.text "site"
         && Option.equal String.equal s.hyperlink (Some "https://example.com"))
       spans);
  let targets =
    List.init 12 (fun index -> Printf.sprintf "https://example.com/files/%d" index)
  in
  let code_links =
    List.mapi
      (fun index target -> Printf.sprintf "[``file[`%d]``](%s)" index target)
      targets
  in
  let rows prefix suffix =
    List.map (fun link -> prefix ^ link ^ suffix) code_links |> String.concat "\r\n"
  in
  List.iter
    (fun (context, source) ->
      let linked_spans =
        Markdown.render_lines ~theme ~width:120 ~osc8:true source
        |> List.concat_map (fun (l : Markdown.rendered_line) -> l.spans)
      in
      List.iter
        (fun target ->
          Alcotest.(check bool) (context ^ " keeps the OSC 8 link " ^ target) true
            (List.exists
               (fun (span : Markdown.styled_span) ->
                 Option.equal String.equal span.hyperlink (Some target))
               linked_spans))
        targets)
    [ ("tight list", rows "- " "");
      ("ordered list", rows "1. " "");
      ("nested list in quote", "> - Files\r\n" ^ rows ">   - " "");
      ("table", "| File |\r\n| --- |\r\n" ^ rows "| " " |");
      ("paragraph", String.concat " " code_links) ];
  let nested = "- " ^ String.make 20 '[' ^ "[site](https://example.com)" in
  let fallback =
    Markdown.render_lines ~theme ~width:120 ~osc8:true nested
    |> List.concat_map (fun (l : Markdown.rendered_line) -> l.spans)
  in
  Alcotest.(check bool) "over-deep labels inside one bullet keep literal source" true
    (List.for_all (fun (span : Markdown.styled_span) -> Option.is_none span.hyperlink) fallback);
  let pathological =
    [
      String.concat " " (List.init 10_000 (fun _ -> "_a"));
      String.concat " " (List.init 10_000 (fun _ -> "__a"));
      String.make 10_000 '[' ^ "]";
      String.make 10_000 '[' ^ "](";
      String.make 10_000 '[' ^ "](   )";
      String.make 10_000 '*';
    ]
  in
  let t0 = Masc_tui_core.Clock.Mono.now () in
  List.iter
    (fun line ->
      let out = Markdown.render_lines ~theme ~width:80 ~osc8:true line in
      Alcotest.(check bool) "rendered non-empty lines" true (out <> []))
    pathological;
  let elapsed_s =
    Masc_tui_core.Clock.Mono.seconds_since (Masc_tui_core.Clock.Mono.now ())
      ~since:t0
  in
  Alcotest.(check bool)
    (Printf.sprintf "10k unmatched delimiters parsed linearly (%.3fs < 2.0s)"
       elapsed_s)
    true (elapsed_s < 2.0)

let test_markdown_inline_mermaid_blocks () =
  let theme = Theme.default in
  let has_sub s sub =
    let n = String.length s and m = String.length sub in
    let rec go i =
      if i + m > n then false
      else if String.equal (String.sub s i m) sub then true
      else go (i + 1)
    in
    m = 0 || go 0
  in
  let line_text (l : Markdown.rendered_line) =
    String.concat "" (List.map (fun (sp : Markdown.styled_span) -> sp.text) l.spans)
  in
  (* draw reports the line count that render_lines produced. *)
  let check_parity ~width md =
    let lines = Markdown.render_lines ~theme ~width ~osc8:true md in
    let total = List.length lines in
    let grid = Cell_grid.create ~cols:width ~rows:(max 4 (total + 2)) in
    let drawn =
      Markdown.draw grid
        ~rect:(Rect.make ~x:0 ~y:0 ~w:width ~h:(max 4 (total + 2)))
        ~theme ~osc8:true md
    in
    Alcotest.(check int)
      (Printf.sprintf "draw total == render_lines length at w=%d" width)
      total drawn;
    List.iter
      (fun l ->
        Alcotest.(check bool) "rendered line width <= width" true
          (Grapheme.display_width (line_text l) <= width))
      lines;
    lines
  in

  (* 1. Horizontal LR flowchart inside ```Mermaid renders as real Unicode box-and-arrow diagram
        with automatic TD reflow at narrow width=48 *)
  let md_lr =
    "Intro paragraph.\n\n```Mermaid\nflowchart LR\n  A[\"Alpha Stage\"] --> B[\"Beta Review\"]\n  B --> C[\"Final Land\"]\n```\n\nAfter."
  in
  let lines_48 = check_parity ~width:48 md_lr in
  let joined_48 = String.concat "\n" (List.map line_text lines_48) in
  Alcotest.(check bool) "renders Unicode box border (not raw flowchart LR)" true
    (has_sub joined_48 "\xe2\x94\x8c" && has_sub joined_48 "\xe2\x94\x82");
  Alcotest.(check bool) "preserves diagram labels" true
    (has_sub joined_48 "Alpha Stage" && has_sub joined_48 "Final Land");
  Alcotest.(check bool) "replaces raw mermaid syntax with drawing" false
    (has_sub joined_48 "flowchart LR");
  ignore (check_parity ~width:80 md_lr);

  (* 2. Unsupported mermaid kind falls back cleanly to raw fenced code lines with exact parity *)
  let md_unsupported = "```mermaid\npie title Tasks\n  \"Done\" : 70\n  \"Open\" : 30\n```" in
  let lines_unsup = check_parity ~width:60 md_unsupported in
  let joined_unsup = String.concat "\n" (List.map line_text lines_unsup) in
  Alcotest.(check bool) "unsupported mermaid keeps raw source fallback" true
    (has_sub joined_unsup "pie title Tasks");

  (* 3. Oversized > 80 lines and > 8192 bytes blocks skip Mermaid layout and fall back safely *)
  let many_lines =
    "```mermaid\nflowchart TD\n"
    ^ String.concat "\n" (List.init 85 (fun i -> Printf.sprintf "N%d --> N%d" i (i + 1)))
    ^ "\n```"
  in
  let lines_many = check_parity ~width:60 many_lines in
  Alcotest.(check bool) "over-80-line mermaid falls back to source lines" true
    (has_sub (String.concat "\n" (List.map line_text lines_many)) "N0 --> N1");

  let huge_bytes =
    "```mermaid\nflowchart TD\nA[\"" ^ String.make 8300 'x' ^ "\"] --> B[end]\n```"
  in
  let lines_huge = check_parity ~width:60 huge_bytes in
  Alcotest.(check bool) "over-8192-byte mermaid falls back safely" true
    (List.length lines_huge > 10);

  (* 4. An empty rect draws nothing; tiny width = 4 falls back with parity *)
  let empty_grid = Cell_grid.create ~cols:10 ~rows:5 in
  Alcotest.(check int) "draw empty rect == 0" 0
    (Markdown.draw empty_grid ~rect:(Rect.make ~x:0 ~y:0 ~w:0 ~h:5) ~theme
       ~osc8:true md_lr);
  (* render_lines raises a tiny width to its floor, so only the line count
     is compared here. *)
  let total_w4 =
    List.length (Markdown.render_lines ~theme ~width:4 ~osc8:true md_lr)
  in
  let grid_w4 = Cell_grid.create ~cols:4 ~rows:(max 4 (total_w4 + 2)) in
  Alcotest.(check int) "width=4 draw == render_lines length" total_w4
    (Markdown.draw grid_w4
       ~rect:(Rect.make ~x:0 ~y:0 ~w:4 ~h:(max 4 (total_w4 + 2)))
       ~theme ~osc8:true md_lr);

  (* 5. Parse-error mermaid falls back cleanly to raw source lines with exact parity *)
  let md_parse_err = "```mermaid\nflowchart TD\nA[\"bad\"]::: --> B\n```" in
  let lines_perr = check_parity ~width:60 md_parse_err in
  Alcotest.(check bool) "parse-error mermaid keeps raw source fallback" true
    (has_sub (String.concat "\n" (List.map line_text lines_perr)) "A[\"bad\"]::: --> B");

  (* 6. Korean/CJK labels inside ```mermaid render cleanly without width overflow *)
  let md_cjk =
    "```mermaid\nflowchart LR\n  A[기억 스냅샷] -->|검증| B[최종 반영]\n```"
  in
  let lines_cjk = check_parity ~width:36 md_cjk in
  let joined_cjk = String.concat "\n" (List.map line_text lines_cjk) in
  Alcotest.(check bool) "CJK inline mermaid draws box borders" true
    (has_sub joined_cjk "\xe2\x94\x8c" && has_sub joined_cjk "\xe2\x94\x82");
  Alcotest.(check bool) "CJK inline mermaid preserves Korean labels" true
    (has_sub joined_cjk "기억 스냅샷" && has_sub joined_cjk "최종 반영")

let () =
  Alcotest.run "masc_tui_keymap_ui"
    [
      ( "keymap",
        [
          Alcotest.test_case "zero collisions per scope" `Quick
            test_keymap_no_collisions;
          Alcotest.test_case "Ctrl+K never triggers approve" `Quick
            test_keymap_ctrl_k_never_approves;
          Alcotest.test_case "bare p/v retired and VT100 safe" `Quick
            test_keymap_retired_p_v_and_vt100_safety;
          Alcotest.test_case "3-tier scopes and dispatch" `Quick
            test_keymap_scopes_and_3_tiers;
          Alcotest.test_case "footer hints width budget (80/90/140)" `Quick
            test_keymap_footer_width_budget;
        ] );
      ( "slash",
        [
          Alcotest.test_case "all 36 slash commands (+ /boot alias) parse, reject invalid, filter & complete"
            `Quick test_slash_36_commands;
          Alcotest.test_case "trailing-space argument completion (/theme /lang /tools)"
            `Quick test_slash_trailing_space_completion;
        ] );
      ( "layout_and_card",
        [
          Alcotest.test_case "4 breakpoints, splits & empty-card collapse" `Quick
            test_layout_breakpoints_and_collapse;
          Alcotest.test_case "Card rounded borders & 64-entry LRU cache" `Quick
            test_card_lru_cache;
        ] );
      ( "chart",
        [
          Alcotest.test_case "adaptive mode degradation, tiers & Unread/Absent semantics"
            `Quick test_chart_degradation_and_tiers;
          Alcotest.test_case "P0-2 Dual_independent upper Calls + lower USD axis honesty"
            `Quick test_p0_2_dual_independent_usd_axis;
          Alcotest.test_case "Memory_flow pure bucketing, Flow_io/Net_total & honest empty/n=1"
            `Quick test_memory_flow_braille_chart;
        ] );
      ( "table",
        [
          Alcotest.test_case "column priority dropping & CJK width safety" `Quick
            test_table_priority_and_cjk;
        ] );
      ( "rich_content",
        [
          Alcotest.test_case "Json_tree structured coloring, folding & redaction"
            `Quick test_json_tree_structured;
          Alcotest.test_case "Json_tree preserves LLM token telemetry & masks value secrets"
            `Quick test_json_tree_telemetry_vs_secrets;
          Alcotest.test_case "Markdown OSC 8 links & fenced code" `Quick
            test_markdown_osc8_and_fence;
          Alcotest.test_case
            "Markdown inline ```mermaid blocks (adaptive LR->TD, parity & guards)"
            `Quick test_markdown_inline_mermaid_blocks;
          Alcotest.test_case "Markdown O(N) parse_inline on 10k unmatched delimiters"
            `Quick test_markdown_parse_inline_linear_unmatched_delimiters;
          Alcotest.test_case "Wave 2: Html_doc strips script/style/hidden, aligns tables & search highlights"
            `Quick test_wave2_html_doc_renderer;
        ] );
      ( "form_and_composer",
        [
          Alcotest.test_case "Form secret masking, validation & diff preview"
            `Quick test_form_secret_and_validation;
          Alcotest.test_case "Form secret-only diff, scroll, filter focus & bounds safety"
            `Quick test_form_secret_diff_scroll_filter_bounds;
          Alcotest.test_case "Composer auto-fold, pending tx & voice waveform"
            `Quick test_composer_modes_and_voice;
          Alcotest.test_case "Composer h=2 voice safety, narrow bar & horizontal panning"
            `Quick test_composer_voice_h2_narrow_and_panning;
        ] );
      ( "v25_design_system",
        [
          Alcotest.test_case "4-tier Typography, Layout spatial rhythm & Card primitives"
            `Quick test_v25_typography_layout_and_card;
          Alcotest.test_case "Table calm selection preserving semantic colors & Chart Violet/no-dup"
            `Quick test_v25_table_calm_selection_and_chart_violet;
          Alcotest.test_case "Markdown hierarchy, Form Section Property Inspector & Composer polish"
            `Quick test_v25_markdown_form_inspector_and_composer;
          Alcotest.test_case "Full-width 24h Braille curve stretch (Full & Dual), gap preservation & n=1"
            `Quick test_v25_chart_full_width_braille_stretch;
          Alcotest.test_case "24-bin Age Ladder folding/tiers/ticks & Memory keymap invariants"
            `Quick test_memory_age_ladder_math_and_keymap_bindings;
        ] );
    ]
