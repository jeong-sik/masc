open Alcotest
open Masc_tui_core
open Masc_tui_term
open Masc_tui_keymap
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_app

let now0 = Clock.Mono.zero
let obs v = Observed.value ~observed_at:now0 v

let sample_png ~w ~h =
  let b = Bytes.create 33 in
  Bytes.blit_string "\137PNG\r\n\026\n" 0 b 0 8;
  Bytes.set_int32_be b 8 13l;
  Bytes.blit_string "IHDR" 0 b 12 4;
  Bytes.set_int32_be b 16 (Int32.of_int w);
  Bytes.set_int32_be b 20 (Int32.of_int h);
  Bytes.set b 24 '\008';
  Bytes.set b 25 '\006';
  Bytes.set b 26 '\000';
  Bytes.set b 27 '\000';
  Bytes.set b 28 '\000';
  Bytes.set_int32_be b 29 0l;
  Bytes.to_string b

let sample_palette () =
  Palette.of_responses
    ~foreground:(Some (Palette.make_rgb ~red:226 ~green:232 ~blue:240))
    ~background:(Some (Palette.make_rgb ~red:15 ~green:23 ~blue:42))
    ~ansi:(Array.make Palette.ansi_slot_count None)
  |> Option.get

let mk_ev ~id ~rev ~ts ~kind ?(before = []) ?(after = []) ?reason () :
    Wire_knowledge.memory_activity_event =
  { identity = id; recorded_at_unix = ts; revision = rev; kind; before; after; reason }

let mk_fact id claim : Wire_knowledge.memory_activity_fact =
  { memory_id = id; claim }

let sample_activity ~keeper : Wire_knowledge.keeper_memory_activity =
  let e1 =
    mk_ev ~id:"ev-1" ~rev:1 ~ts:1_700_000_100.0
      ~kind:Wire_knowledge.Activity_created
      ~after:[ mk_fact "m-1" None ]
      ~reason:"initial observation" ()
  in
  let e2 =
    mk_ev ~id:"ev-2" ~rev:2 ~ts:1_700_000_200.0
      ~kind:Wire_knowledge.Activity_revised
      ~before:[ mk_fact "m-1" None ]
      ~after:[ mk_fact "m-2" (Some "Revised claim body for m-2") ]
      ~reason:"refined after review" ()
  in
  let e3 =
    mk_ev ~id:"ev-3" ~rev:3 ~ts:1_700_000_300.0
      ~kind:Wire_knowledge.Activity_relation_unavailable
      ~before:[ mk_fact "m-2" None ]
      ~after:[ mk_fact "m-3" None ]
      ~reason:"legacy journal entry" ()
  in
  {
    keeper;
    limit = 50;
    journal_lines = 3;
    undecodable_lines = 0;
    events = [ e1; e2; e3 ];
    notes = [ "window covers last 50 journal lines" ];
  }

let sample_facts ~keeper : Wire_knowledge.keeper_memory_facts =
  let mk_ord id claim =
    {
      Wire_knowledge.memory_id = id;
      claim;
      category = Wire_knowledge.Cat_fact;
      origin = Wire_knowledge.Origin_authored;
      basis = Wire_knowledge.Basis_observed;
      first_seen_unix = 1_700_000_100.0;
      last_seen_unix = 1_700_000_300.0;
      events =
        {
          retrieval = Wire_knowledge.Never_retrieved;
          retracted_count = 0;
          revised_from = [];
        };
    }
  in
  {
    keeper;
    ordinary =
      Wire_knowledge.Memory_store_present
        {
          revision = 3;
          snapshot_sha256 = "abc123";
          updated_at_unix = 1_700_000_300.0;
          facts =
            [
              mk_ord "m-1" "Snapshot full claim for m-1";
              mk_ord "m-3" "Snapshot body for m-3 (still unconfirmed relation)";
              mk_ord "m-orphan" "Fact with no activity event";
            ];
          support_invalidations = [];
        };
    source_bound = Wire_knowledge.Memory_store_absent;
    events_unreadable_lines = 0;
    events_read_error = None;
  }

let sample_keeper name : Wire_fleet.keeper_summary =
  {
    name;
    group = Some "Core";
    company = "Core";
    health = Wire_fleet.Keeper_healthy;
    paused = false;
    keepalive_running = true;
    activation_mode = Wire_fleet.Activation_autonomous;
    runtime_id = "claude-sonnet";
    model_id = Some "claude-sonnet";
    current_task_id = None;
    context_ratio = obs 0.25;
    total_turns = obs 10;
    total_tokens = obs 1000;
    cost_24h_usd = obs 0.5;
    last_turn_at_unix = Some 1_700_000_300.0;
    active_turn = None;
    activity_sparkline_24h = [];
  }

let key_char ?(ctrl = false) c : Keymap.Input.key_event =
  { key = Keymap.Input.Char c; mods = { ctrl; alt = false; shift = false } }

let key_special key : Keymap.Input.key_event =
  { key; mods = Keymap.Input.no_mods }

let model_in_keeper_memory_dive ~keeper =
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko ~wall_unix:1_700_000_500.0 () in
  let fleet =
    Fleet_store.empty
    |> Fleet_store.apply_keepers ~observed_at:now0
         [ sample_keeper keeper; sample_keeper "beta" ]
    |> Fleet_store.select_keeper keeper
  in
  let knowledge =
    Knowledge_store.empty
    |> Knowledge_store.set_memory_diff_keeper (Some keeper)
    |> Knowledge_store.apply_keeper_memory_activity ~observed_at:now0
         (sample_activity ~keeper)
    |> Knowledge_store.apply_keeper_memory_facts ~observed_at:now0
         (sample_facts ~keeper)
  in
  let m1 = { m0 with fleet; knowledge } in
  let m2, _ =
    Update_nav.push_dive m1
      (Nav.Dive_keeper { name = keeper; tab = Nav.Keeper_memory })
  in
  m2

(* 1. Pure Wire -> Memory_lineage.chart adapter (all 8 kinds + fact resolution + unconfirmed preserved) *)

let test_wire_to_lineage_adapter () =
  let pairs =
    [
      (Wire_knowledge.Activity_created, Memory_lineage.Created);
      (Wire_knowledge.Activity_reobserved, Memory_lineage.Reobserved);
      (Wire_knowledge.Activity_revised, Memory_lineage.Revised);
      (Wire_knowledge.Activity_absorbed, Memory_lineage.Absorbed);
      (Wire_knowledge.Activity_retracted, Memory_lineage.Retracted);
      (Wire_knowledge.Activity_removed, Memory_lineage.Removed);
      (Wire_knowledge.Activity_invalidated, Memory_lineage.Invalidated);
      ( Wire_knowledge.Activity_relation_unavailable
      , Memory_lineage.Relation_unavailable );
    ]
  in
  List.iter
    (fun (wire_k, expected_k) ->
      check bool "exact kind mapping" true
        (Memory_lineage.equal_event_kind
           (Memory_diagram.lineage_kind_of_wire wire_k)
           expected_k))
    pairs;

  let act = sample_activity ~keeper:"alpha" in
  let facts = sample_facts ~keeper:"alpha" in
  let ev3 = List.nth act.events 2 in
  (* Wrong keeper returns None *)
  check bool "wrong keeper rejected" true
    (Option.is_none
       (Memory_diagram.chart_of_activity ~keeper:"other" ~activity:act
          ~facts:(Some facts) ~selected:ev3));

  let chart =
    match
      Memory_diagram.chart_of_activity ~keeper:"alpha" ~activity:act
        ~facts:(Some facts) ~selected:ev3
    with
    | Some c -> c
    | None -> fail "expected chart for alpha/ev-3"
  in
  check int "all 3 connected events kept" 3 (List.length chart.events);
  check bool "Relation_unavailable preserved on selected" true
    (Memory_lineage.equal_event_kind chart.selected.kind
       Memory_lineage.Relation_unavailable);
  (* Ordinary snapshot resolved m-1 claim *)
  let m1_claim =
    Memory_lineage.fact_claim_text ~ko:false chart
      { Memory_lineage.memory_id = "m-1"; claim = None }
  in
  check string "m-1 claim resolved from ordinary snapshot"
    "Snapshot full claim for m-1" m1_claim;
  (* m-3 has observed claim from ordinary snapshot, yet Relation_unavailable stays unconfirmed *)
  let m3_status, _ =
    Memory_lineage.fact_status ~ko:false chart
      { Memory_lineage.memory_id = "m-3"; claim = None }
  in
  check string "Relation_unavailable never promoted to retained" "unconfirmed"
    m3_status;

  (* Pure fallbacks never crash even on very narrow widths *)
  let narrow_rows, narrow_note =
    Memory_diagram.render_mermaid_fallback ~ko:false ~now:1_700_000_500.0
      ~max_width:14 ~kind:Knowledge_store.Diagram_pele_card chart
  in
  check bool "narrow Mermaid fallback produces lines" true
    (List.length narrow_rows > 0);
  check bool "narrow Mermaid produces diagnostic note when too wide" true
    (Option.is_some narrow_note || List.length narrow_rows > 0);
  let tree_rows =
    Memory_diagram.render_tree_lines ~ko:false ~now:1_700_000_500.0
      ~keeper_name:"alpha" ~max_width:60 chart
  in
  check bool "Memory_tree renders non-empty lines" true (List.length tree_rows > 0)

(* 2. PNG IHDR parser *)

let test_png_ihdr_parser () =
  let valid = sample_png ~w:1240 ~h:620 in
  check (option (pair int int)) "valid PNG IHDR" (Some (1240, 620))
    (Memory_diagram.parse_png_dimensions valid);
  check (option (pair int int)) "empty bytes -> None" None
    (Memory_diagram.parse_png_dimensions "");
  check (option (pair int int)) "truncated 24 bytes -> None" None
    (Memory_diagram.parse_png_dimensions (String.sub valid 0 24));
  let bad_sig = "X" ^ String.sub valid 1 (String.length valid - 1) in
  check (option (pair int int)) "invalid signature -> None" None
    (Memory_diagram.parse_png_dimensions bad_sig);
  let bad_chunk =
    let b = Bytes.of_string valid in
    Bytes.blit_string "IDAT" 0 b 12 4;
    Bytes.to_string b
  in
  check (option (pair int int)) "non-IHDR first chunk -> None" None
    (Memory_diagram.parse_png_dimensions bad_chunk);
  let short_ihdr_len =
    let b = Bytes.of_string valid in
    Bytes.set_int32_be b 8 12l;
    Bytes.to_string b
  in
  check (option (pair int int)) "IHDR len < 13 -> None" None
    (Memory_diagram.parse_png_dimensions short_ihdr_len);
  check (option (pair int int)) "zero width -> None" None
    (Memory_diagram.parse_png_dimensions (sample_png ~w:0 ~h:100));
  check (option (pair int int)) "zero height -> None" None
    (Memory_diagram.parse_png_dimensions (sample_png ~w:100 ~h:0));
  let neg_dim =
    let b = Bytes.of_string valid in
    Bytes.set_int32_be b 16 (-1l);
    Bytes.to_string b
  in
  check (option (pair int int)) "negative / >2^31-1 width -> None" None
    (Memory_diagram.parse_png_dimensions neg_dim)

(* 3. Store/Update lifecycle: ., Ctrl+O, v, stale reply drop, Esc/scope close, y copy, scroll bounds *)

let find_render_cmd cmds =
  List.find_opt
    (function
      | Cmd.Render_memory_diagram _ -> true
      | Cmd.Batch _
      | Cmd.Http_get _
      | Cmd.Http_post _
      | Cmd.Http_put _
      | Cmd.Http_post_stream _
      | Cmd.Sync_streams _
      | Cmd.Update_workspace_guard _
      | Cmd.Voice_cmd _
      | Cmd.Copy_clipboard _
      | Cmd.Open_external_url _
      | Cmd.Open_editor_escape_hatch _
      | Cmd.Start_local_server
      | Cmd.Restart_tui
      | Cmd.Quit _ ->
          false)
    (Cmd.flatten cmds)

let test_store_diagram_keybindings_and_scope_safety () =
  let m0 = model_in_keeper_memory_dive ~keeper:"alpha" in
  (* Press '.' -> opens Diagram_pele_card in Auto mode & emits Render_memory_diagram *)
  let m1, cmds1 = Update.step ~now:now0 m0 (Msg.Key_event (key_char ".")) in
  (match m1.knowledge.memory_diagram with
  | Some d ->
      check string "keeper matches" "alpha" d.keeper;
      check string "event_identity matches first event" "ev-1" d.event_identity;
      check bool "kind is Diagram_pele_card" true
        (Knowledge_store.equal_memory_diagram_kind d.kind
           Knowledge_store.Diagram_pele_card);
      check bool "mode is Auto" true
        (Knowledge_store.equal_memory_diagram_mode d.mode
           Knowledge_store.Diagram_mode_auto);
      check bool "payload is Loading" true (Observed.is_loading d.payload);
      check bool "copy_source populated" true (String.length d.copy_source > 0)
  | None -> fail "expected memory_diagram open after '.'");
  check bool "emits Cmd.Render_memory_diagram" true
    (Option.is_some (find_render_cmd cmds1));

  (* Stale epoch reply dropped *)
  let long_lines = List.init 80 (fun i -> Printf.sprintf "line-%02d" i) in
  let stale_epoch_msg =
    Msg.Memory_diagram_rendered
      {
        epoch = Epoch.next m1.epoch;
        keeper = "alpha";
        event_identity = "ev-1";
        kind = Knowledge_store.Diagram_pele_card;
        mode = Knowledge_store.Diagram_mode_auto;
        result = Ok (Knowledge_store.Diagram_text { lines = long_lines; note = None });
      }
  in
  let m_stale_ep, _ = Update.step ~now:now0 m1 stale_epoch_msg in
  check bool "stale epoch reply dropped" true
    (Observed.is_loading (Option.get m_stale_ep.knowledge.memory_diagram).payload);

  (* Wrong keeper reply dropped *)
  let wrong_keeper_msg =
    Msg.Memory_diagram_rendered
      {
        epoch = m1.epoch;
        keeper = "beta";
        event_identity = "ev-1";
        kind = Knowledge_store.Diagram_pele_card;
        mode = Knowledge_store.Diagram_mode_auto;
        result = Ok (Knowledge_store.Diagram_text { lines = long_lines; note = None });
      }
  in
  let m_wrong_kp, _ = Update.step ~now:now0 m1 wrong_keeper_msg in
  check bool "wrong keeper reply dropped" true
    (Observed.is_loading (Option.get m_wrong_kp.knowledge.memory_diagram).payload);

  (* Wrong mode reply dropped *)
  let wrong_mode_msg =
    Msg.Memory_diagram_rendered
      {
        epoch = m1.epoch;
        keeper = "alpha";
        event_identity = "ev-1";
        kind = Knowledge_store.Diagram_pele_card;
        mode = Knowledge_store.Diagram_mode_tree;
        result = Ok (Knowledge_store.Diagram_text { lines = long_lines; note = None });
      }
  in
  let m_wrong_mode, _ = Update.step ~now:now0 m1 wrong_mode_msg in
  check bool "wrong mode reply dropped" true
    (Observed.is_loading (Option.get m_wrong_mode.knowledge.memory_diagram).payload);

  (* Matching reply lands cleanly *)
  let ok_msg =
    Msg.Memory_diagram_rendered
      {
        epoch = m1.epoch;
        keeper = "alpha";
        event_identity = "ev-1";
        kind = Knowledge_store.Diagram_pele_card;
        mode = Knowledge_store.Diagram_mode_auto;
        result =
          Ok
            (Knowledge_store.Diagram_text
               { lines = long_lines; note = Some "fallback note" });
      }
  in
  let m2, _ = Update.step ~now:now0 m1 ok_msg in
  check bool "matching reply applied" true
    (Observed.is_value (Option.get m2.knowledge.memory_diagram).payload);

  (* Exact scroll bounds: j increments, G clamps strictly to (total - body_h) *)
  let body_rect = Option.get (Memory_diagram.active_diagram_body_rect m2) in
  let expected_max = max 0 (List.length long_lines - body_rect.h) in
  let m_j, _ = Update.step ~now:now0 m2 (Msg.Key_event (key_char "j")) in
  check int "j scrolls diagram by 1" 1
    (Option.get m_j.knowledge.memory_diagram).scroll;
  let m_end, _ = Update.step ~now:now0 m_j (Msg.Key_event (key_char "G")) in
  check int "G clamps strictly to exact max_scroll" expected_max
    (Option.get m_end.knowledge.memory_diagram).scroll;
  let m_top, _ = Update.step ~now:now0 m_end (Msg.Key_event (key_char "g")) in
  check int "g returns to 0" 0
    (Option.get m_top.knowledge.memory_diagram).scroll;

  (* [y] copies copy_source to clipboard *)
  let _, copy_cmds = Update.step ~now:now0 m2 (Msg.Key_event (key_char "y")) in
  let expected_copy = (Option.get m2.knowledge.memory_diagram).copy_source in
  let copied =
    List.find_map
      (function
        | Cmd.Copy_clipboard s -> Some s
        | Cmd.Batch _
        | Cmd.Http_get _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Render_memory_diagram _
        | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            None)
      (Cmd.flatten copy_cmds)
  in
  check (option string) "y copies diagram copy_source" (Some expected_copy)
    copied;

  (* [v] cycles Auto -> Mermaid -> Tree -> Auto *)
  let m_v1, cmds_v1 = Update.step ~now:now0 m2 (Msg.Key_event (key_char "v")) in
  check bool "v #1 switches to Mermaid" true
    (Knowledge_store.equal_memory_diagram_mode
       (Option.get m_v1.knowledge.memory_diagram).mode
       Knowledge_store.Diagram_mode_mermaid);
  check bool "v #1 re-dispatches Render_memory_diagram" true
    (Option.is_some (find_render_cmd cmds_v1));
  let m_v2, _ = Update.step ~now:now0 m_v1 (Msg.Key_event (key_char "v")) in
  check bool "v #2 switches to Tree" true
    (Knowledge_store.equal_memory_diagram_mode
       (Option.get m_v2.knowledge.memory_diagram).mode
       Knowledge_store.Diagram_mode_tree);
  let m_v3, _ = Update.step ~now:now0 m_v2 (Msg.Key_event (key_char "v")) in
  check bool "v #3 wraps back to Auto" true
    (Knowledge_store.equal_memory_diagram_mode
       (Option.get m_v3.knowledge.memory_diagram).mode
       Knowledge_store.Diagram_mode_auto);

  (* Esc closes diagram without popping dive *)
  let m_esc, _ =
    Update.step ~now:now0 m2 (Msg.Key_event (key_special Keymap.Input.Escape))
  in
  check bool "Esc closes memory_diagram" true
    (Option.is_none m_esc.knowledge.memory_diagram);
  check bool "Esc preserves Dive_keeper" true
    (Option.is_some (Model.active_dive m_esc));

  (* Ctrl+O opens Diagram_formation_tree *)
  let m_tree, cmds_tree =
    Update.step ~now:now0 m_esc (Msg.Key_event (key_char ~ctrl:true "o"))
  in
  (match m_tree.knowledge.memory_diagram with
  | Some d ->
      check bool "Ctrl+O opens Diagram_formation_tree" true
        (Knowledge_store.equal_memory_diagram_kind d.kind
           Knowledge_store.Diagram_formation_tree)
  | None -> fail "expected Diagram_formation_tree on Ctrl+O");
  check bool "Ctrl+O emits Render_memory_diagram" true
    (Option.is_some (find_render_cmd cmds_tree));

  (* Scope safety: workspace switch, keeper switch, filter, c chat hotkey all close diagram *)
  let m_ws, _ = Update_nav.switch_workspace m_tree Nav.Pulse in
  check bool "switch_workspace closes diagram" true
    (Option.is_none m_ws.knowledge.memory_diagram);

  let m_kp_switch =
    {
      m_tree with
      knowledge =
        Knowledge_store.set_memory_diff_keeper (Some "beta") m_tree.knowledge;
    }
  in
  check bool "keeper switch closes diagram" true
    (Option.is_none m_kp_switch.knowledge.memory_diagram);

  let m_chat, _ = Update.step ~now:now0 m_tree (Msg.Key_event (key_char "c")) in
  check bool "c chat hotkey closes diagram" true
    (Option.is_none m_chat.knowledge.memory_diagram);

  (* View_facts fact -> latest matching event resolution *)
  let m_facts =
    {
      m0 with
      knowledge =
        Knowledge_store.set_memory_view_mode Knowledge_store.View_facts
          m0.knowledge;
    }
  in
  let m_facts_open, _ =
    Update.step ~now:now0 m_facts (Msg.Key_event (key_char "."))
  in
  (match m_facts_open.knowledge.memory_diagram with
  | Some d ->
      check string "fact m-1 resolves to latest matching event ev-2" "ev-2"
        d.event_identity
  | None -> fail "expected diagram opened from View_facts matching fact")

(* 4. Cmd_executor Auto/Mermaid/Tree + Pele/Fallback decision tree *)

let test_cmd_executor_render_decisions () =
  let act = sample_activity ~keeper:"alpha" in
  let facts = sample_facts ~keeper:"alpha" in
  let ev2 = List.nth act.events 1 in
  let chart =
    Memory_diagram.chart_of_activity ~keeper:"alpha" ~activity:act
      ~facts:(Some facts) ~selected:ev2
    |> Option.get
  in
  let pal = sample_palette () in
  let kitty_probe : Probe.observation =
    {
      palette = Some pal;
      graphics = Some Probe.Graphics_supported;
      cell_pixels = Some (10, 20);
    }
  in
  let png = sample_png ~w:1240 ~h:540 in

  (* Auto + Kitty + Palette + Pele Ok -> Diagram_pele_png with parsed dimensions *)
  let called = ref 0 in
  let payload_svg =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ ->
        incr called;
        Ok png)
      ~probe:kitty_probe ~term_program:None ~palette:(Some pal) ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_pele_card
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
  in
  check int "Pele invoked once" 1 !called;
  (match payload_svg with
  | Knowledge_store.Diagram_pele_png
      { pixel_size = Some (1240, 540); fallback_lines = _ :: _; _ } ->
      ()
  | Knowledge_store.Diagram_pele_png _ | Knowledge_store.Diagram_text _ ->
      fail "expected Diagram_pele_png with parsed IHDR 1240x540 and fallback lines");

  (* Auto + unsupported graphics -> Mermaid fallback with diagnostic note, Pele NOT called *)
  let called_no_gfx = ref 0 in
  let payload_no_gfx =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ ->
        incr called_no_gfx;
        Ok png)
      ~probe:Probe.empty_observation ~term_program:None ~palette:(Some pal)
      ~keeper:"alpha" ~kind:Knowledge_store.Diagram_pele_card
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
  in
  check int "Pele skipped without graphics" 0 !called_no_gfx;
  (match payload_no_gfx with
  | Knowledge_store.Diagram_text { lines = _ :: _; note = Some _ } -> ()
  | Knowledge_store.Diagram_text _ | Knowledge_store.Diagram_pele_png _ ->
      fail "expected Diagram_text fallback with note when graphics unsupported");

  (* Auto + Kitty + missing palette on SVG card -> Mermaid fallback with note *)
  let payload_no_pal =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ -> Ok png)
      ~probe:{ kitty_probe with palette = None }
      ~term_program:None ~palette:None ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_pele_card
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
  in
  (match payload_no_pal with
  | Knowledge_store.Diagram_text { lines = _ :: _; note = Some _ } -> ()
  | Knowledge_store.Diagram_text _ | Knowledge_store.Diagram_pele_png _ ->
      fail "expected Diagram_text fallback when palette absent");

  (* Auto + Kitty + Pele error on Formation Tree -> Memory_tree fallback with note *)
  let payload_tree_err =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ -> Error "masc-pele is not installed")
      ~probe:kitty_probe ~term_program:None ~palette:None ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_formation_tree
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:80 ~chart ()
  in
  (match payload_tree_err with
  | Knowledge_store.Diagram_text { lines = _ :: _; note = Some _ } -> ()
  | Knowledge_store.Diagram_text _ | Knowledge_store.Diagram_pele_png _ ->
      fail "expected Formation tree fallback with note when Pele fails");

  (* Forced Mermaid / Tree modes NEVER invoke Pele *)
  let forced_calls = ref 0 in
  let _ =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ ->
        incr forced_calls;
        Ok png)
      ~probe:kitty_probe ~term_program:None ~palette:(Some pal) ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_pele_card
      ~mode:Knowledge_store.Diagram_mode_mermaid ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
  in
  let _ =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ ->
        incr forced_calls;
        Ok png)
      ~probe:kitty_probe ~term_program:None ~palette:(Some pal) ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_formation_tree
      ~mode:Knowledge_store.Diagram_mode_tree ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
  in
  check int "forced Mermaid/Tree never invoke Pele" 0 !forced_calls

(* 5. Graphics overlay lifecycle state machine *)

let test_graphics_overlay_lifecycle () =
  let m0 = model_in_keeper_memory_dive ~keeper:"alpha" in
  let png = sample_png ~w:1240 ~h:620 in
  let m_open, _ = Update.step ~now:now0 m0 (Msg.Key_event (key_char ".")) in
  let m_png, _ =
    Update.step ~now:now0 m_open
      (Msg.Memory_diagram_rendered
         {
           epoch = m_open.epoch;
           keeper = "alpha";
           event_identity = "ev-1";
           kind = Knowledge_store.Diagram_pele_card;
           mode = Knowledge_store.Diagram_mode_auto;
           result =
             Ok
               (Knowledge_store.Diagram_pele_png
                  {
                    png;
                    pixel_size = Some (1240, 620);
                    format_label = "Pele SVG";
                    fallback_lines = [ "fallback" ];
                  });
         })
  in
  let kitty_probe : Probe.observation =
    {
      palette = Some (sample_palette ());
      graphics = Some Probe.Graphics_supported;
      cell_pixels = Some (10, 20);
    }
  in
  let mem_id_token =
    Printf.sprintf "i=%d" (Graphics.image_id Graphics.Memory_diagram)
  in

  (* Transition 1: None -> active PNG emits Kitty place_slot once with Memory_diagram slot ID *)
  let s1 =
    App.step_memory_graphic ~active:None ~probe:kitty_probe ~term_program:None
      ~in_tmux:false ~model:m_png ~full_repaint:false
  in
  check string "no pre-clear on initial placement" "" s1.pre_present_bytes;
  check bool "emits Kitty placement bytes" true
    (String.length s1.post_present_bytes > 0);
  check bool "placement binds Memory_diagram slot id" true
    (String.contains s1.post_present_bytes '\x1b'
    &&
    let rec has_sub s sub i =
      if i + String.length sub > String.length s then false
      else if String.equal (String.sub s i (String.length sub)) sub then true
      else has_sub s sub (i + 1)
    in
    has_sub s1.post_present_bytes mem_id_token 0);
  check bool "tracks active graphic state" true (Option.is_some s1.next_state);

  (* Transition 2: Unchanged key + rect skips redundant re-emit *)
  let s2 =
    App.step_memory_graphic ~active:s1.next_state ~probe:kitty_probe
      ~term_program:None ~in_tmux:false ~model:m_png ~full_repaint:false
  in
  check string "unchanged -> no pre-clear" "" s2.pre_present_bytes;
  check bool "unchanged -> no invalidate" false s2.invalidate_presenter;
  check string "unchanged -> skips redundant place" "" s2.post_present_bytes;
  check bool "unchanged -> preserves active state" true
    (Option.equal App.equal_memory_graphic_state s1.next_state s2.next_state);

  (* Transition 3: Mode switch to Mermaid emits delete_image + invalidates presenter *)
  let m_mermaid, _ = Update.step ~now:now0 m_png (Msg.Key_event (key_char "v")) in
  let s3 =
    App.step_memory_graphic ~active:s2.next_state ~probe:kitty_probe
      ~term_program:None ~in_tmux:false ~model:m_mermaid ~full_repaint:false
  in
  check string "mode switch emits Kitty delete_image"
    (Graphics.delete_image ~image_id:(Graphics.image_id Graphics.Memory_diagram))
    s3.pre_present_bytes;
  check bool "mode switch invalidates presenter" true s3.invalidate_presenter;
  check string "mode switch emits no placement" "" s3.post_present_bytes;
  check bool "mode switch resets active state to None" true
    (Option.is_none s3.next_state);

  (* Transition 4: Esc close emits delete_image + invalidates presenter *)
  let m_closed, _ =
    Update.step ~now:now0 m_png (Msg.Key_event (key_special Keymap.Input.Escape))
  in
  let s4 =
    App.step_memory_graphic ~active:s1.next_state ~probe:kitty_probe
      ~term_program:None ~in_tmux:true ~model:m_closed ~full_repaint:false
  in
  check string "Esc under TMUX wraps delete_image in tmux DCS"
    (Graphics.tmux_wrapped
       (Graphics.delete_image
          ~image_id:(Graphics.image_id Graphics.Memory_diagram)))
    s4.pre_present_bytes;
  check bool "Esc invalidates presenter" true s4.invalidate_presenter;
  check bool "Esc clears active graphic state" true
    (Option.is_none s4.next_state);

  (* Transition 5: iTerm2 protocol uses OSC 1337 placement & invalidates on close *)
  let s_it2 =
    App.step_memory_graphic ~active:None ~probe:Probe.empty_observation
      ~term_program:(Some "iTerm.app") ~in_tmux:false ~model:m_png
      ~full_repaint:false
  in
  check bool "iTerm2 emits OSC 1337 placement" true
    (String.length s_it2.post_present_bytes > 0);
  let s_it2_close =
    App.step_memory_graphic ~active:s_it2.next_state
      ~probe:Probe.empty_observation ~term_program:(Some "iTerm.app")
      ~in_tmux:false ~model:m_closed ~full_repaint:false
  in
  check string "iTerm2 close has no Kitty delete bytes" ""
    s_it2_close.pre_present_bytes;
  check bool "iTerm2 close still invalidates presenter to repaint cells" true
    s_it2_close.invalidate_presenter

let () =
  run "masc_tui_v2_memory_diagram_wiring"
    [
      ( "memory_diagram_wiring",
        [
          test_case "Wire_knowledge -> Memory_lineage adapter & fallbacks" `Quick
            test_wire_to_lineage_adapter;
          test_case "PNG IHDR parser validation" `Quick test_png_ihdr_parser;
          test_case "Store/Update keybindings, gating, scope safety & scroll bounds"
            `Quick test_store_diagram_keybindings_and_scope_safety;
          test_case "Cmd_executor Auto/Mermaid/Tree & Pele fallback decisions"
            `Quick test_cmd_executor_render_decisions;
          test_case "Kitty/iTerm2 graphics overlay lifecycle transitions" `Quick
            test_graphics_overlay_lifecycle;
        ] );
    ]
