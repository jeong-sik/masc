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
    context =
      obs
        (Wire_fleet.Context_measured
           {
             ratio = Some 0.25;
             tokens = 50_000;
             window = Some 200_000;
             absolute_turn = None;
             measured_at_unix = None;
           });
    total_turns = obs 10;
    last_turn_at_unix = Some 1_700_000_300.0;
    active_turn = None;
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
    |> Knowledge_store.set_keeper_memory_activity ~keeper
         (Observed.value ~observed_at:now0 (sample_activity ~keeper))
    |> Knowledge_store.set_keeper_memory_facts ~keeper
         (Observed.value ~observed_at:now0 (sample_facts ~keeper))
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
  let chart = Memory_lineage.Lineage chart in
  let narrow_rows, narrow_note =
    Memory_diagram.render_mermaid_fallback ~ko:false ~now:1_700_000_500.0
      ~max_width:14 ~kind:Knowledge_store.Diagram_pele_card chart
  in
  check bool "narrow Mermaid fallback produces lines" true
    (List.length narrow_rows > 0);
  check bool "narrow Mermaid produces diagnostic note when too wide" true
    (Option.is_some narrow_note);
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
  check (option (pair int int)) "truncated 32 bytes (missing CRC) -> None" None
    (Memory_diagram.parse_png_dimensions (String.sub valid 0 32));
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
  let long_ihdr_len =
    let b = Bytes.of_string valid in
    Bytes.set_int32_be b 8 14l;
    Bytes.to_string b
  in
  check (option (pair int int)) "IHDR len > 13 -> None" None
    (Memory_diagram.parse_png_dimensions long_ihdr_len);
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
      | Cmd.Http_delete _
      | Cmd.Http_post_stream _
      | Cmd.Sync_streams _
      | Cmd.Update_workspace_guard _
      | Cmd.Voice_cmd _
      | Cmd.Copy_clipboard _
      | Cmd.Cancel_memory_diagram
      | Cmd.Fetch_artifact_and_copy _
      | Cmd.Export_artifact _
      | Cmd.Open_dos_screen _
      | Cmd.Open_external_url _
      | Cmd.Open_editor_escape_hatch _ | Cmd.Open_terminal_program _
      | Cmd.Start_local_server
      | Cmd.Restart_tui
      | Cmd.Quit _ ->
          false)
    (Cmd.flatten cmds)

let has_cancel_diagram_cmd cmds =
  List.exists
    (function
      | Cmd.Cancel_memory_diagram -> true
      | Cmd.Batch _
      | Cmd.Http_get _
      | Cmd.Http_post _
      | Cmd.Http_put _
      | Cmd.Http_delete _
      | Cmd.Http_post_stream _
      | Cmd.Sync_streams _
      | Cmd.Update_workspace_guard _
      | Cmd.Voice_cmd _
      | Cmd.Copy_clipboard _
      | Cmd.Render_memory_diagram _
      | Cmd.Fetch_artifact_and_copy _
      | Cmd.Export_artifact _
      | Cmd.Open_dos_screen _
      | Cmd.Open_external_url _
      | Cmd.Open_editor_escape_hatch _ | Cmd.Open_terminal_program _
      | Cmd.Start_local_server
      | Cmd.Restart_tui
      | Cmd.Quit _ ->
          false)
    (Cmd.flatten cmds)

let has_substring s sub =
  let n = String.length s in
  let m = String.length sub in
  if m = 0 then true
  else
    let rec loop i =
      if i + m > n then false
      else if String.equal (String.sub s i m) sub then true
      else loop (i + 1)
    in
    loop 0

let parse_kitty_param s key =
  let needle = "," ^ key ^ "=" in
  let n = String.length s in
  let m = String.length needle in
  let rec find i =
    if i + m > n then None
    else if String.equal (String.sub s i m) needle then
      let start = i + m in
      let rec scan j =
        if j < n && s.[j] >= '0' && s.[j] <= '9' then scan (j + 1) else j
      in
      let stop = scan start in
      if stop > start then int_of_string_opt (String.sub s start (stop - start))
      else None
    else find (i + 1)
  in
  find 0

let test_store_diagram_keybindings_and_scope_safety () =
  let m0 = model_in_keeper_memory_dive ~keeper:"alpha" in
  (* Press '.' -> opens Diagram_pele_card in Auto mode & emits Render_memory_diagram *)
  let m1, cmds1 = Update.step ~now:now0 m0 (Msg.Key_event (key_char ".")) in
  let req_id1 =
    match m1.knowledge.memory_diagram with
    | Some d ->
        check string "keeper matches" "alpha" d.keeper;
        check string "event_identity matches first event" "ev-1"
          d.event_identity;
        check bool "kind is Diagram_pele_card" true
          (Knowledge_store.equal_memory_diagram_kind d.kind
             Knowledge_store.Diagram_pele_card);
        check bool "mode is Auto" true
          (Knowledge_store.equal_memory_diagram_mode d.mode
             Knowledge_store.Diagram_mode_auto);
        check bool "payload is Loading" true (Observed.is_loading d.payload);
        check bool "copy_source populated" true (String.length d.copy_source > 0);
        check bool "request_id is positive" true (d.request_id > 0);
        d.request_id
    | None -> fail "expected memory_diagram open after '.'"
  in
  check bool "emits Cmd.Render_memory_diagram" true
    (Option.is_some (find_render_cmd cmds1));

  (* Stale epoch reply dropped *)
  let long_lines = List.init 80 (fun i -> Printf.sprintf "line-%02d" i) in
  let stale_epoch_msg =
    Msg.Memory_diagram_rendered
      {
        epoch = Epoch.next m1.epoch;
        request_id = req_id1;
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

  (* Stale request_id reply with identical 5-tuple dropped *)
  let stale_req_msg =
    Msg.Memory_diagram_rendered
      {
        epoch = m1.epoch;
        request_id = req_id1 - 1;
        keeper = "alpha";
        event_identity = "ev-1";
        kind = Knowledge_store.Diagram_pele_card;
        mode = Knowledge_store.Diagram_mode_auto;
        result = Ok (Knowledge_store.Diagram_text { lines = long_lines; note = None });
      }
  in
  let m_stale_req, _ = Update.step ~now:now0 m1 stale_req_msg in
  check bool "stale request_id reply dropped" true
    (Observed.is_loading (Option.get m_stale_req.knowledge.memory_diagram).payload);

  (* Wrong keeper reply dropped *)
  let wrong_keeper_msg =
    Msg.Memory_diagram_rendered
      {
        epoch = m1.epoch;
        request_id = req_id1;
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
        request_id = req_id1;
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
        request_id = req_id1;
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
        | Cmd.Http_delete _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Render_memory_diagram _
        | Cmd.Cancel_memory_diagram
        | Cmd.Fetch_artifact_and_copy _
        | Cmd.Export_artifact _
        | Cmd.Open_dos_screen _
        | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _ | Cmd.Open_terminal_program _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            None)
      (Cmd.flatten copy_cmds)
  in
  check (option string) "y copies diagram copy_source" (Some expected_copy)
    copied;

  (* [v] cycles Auto -> Mermaid -> Tree -> Auto with strictly increasing request_id *)
  let m_v1, cmds_v1 = Update.step ~now:now0 m2 (Msg.Key_event (key_char "v")) in
  let d_v1 = Option.get m_v1.knowledge.memory_diagram in
  check bool "v #1 switches to Mermaid" true
    (Knowledge_store.equal_memory_diagram_mode d_v1.mode
       Knowledge_store.Diagram_mode_mermaid);
  check bool "v #1 increments request_id" true (d_v1.request_id > req_id1);
  check bool "v #1 re-dispatches Render_memory_diagram" true
    (Option.is_some (find_render_cmd cmds_v1));
  let m_v2, _ = Update.step ~now:now0 m_v1 (Msg.Key_event (key_char "v")) in
  let d_v2 = Option.get m_v2.knowledge.memory_diagram in
  check bool "v #2 switches to Tree" true
    (Knowledge_store.equal_memory_diagram_mode d_v2.mode
       Knowledge_store.Diagram_mode_tree);
  let m_v3, _ = Update.step ~now:now0 m_v2 (Msg.Key_event (key_char "v")) in
  let d_v3 = Option.get m_v3.knowledge.memory_diagram in
  check bool "v #3 wraps back to Auto" true
    (Knowledge_store.equal_memory_diagram_mode d_v3.mode
       Knowledge_store.Diagram_mode_auto);
  check bool "v #3 request_id strictly > initial Auto request_id" true
    (d_v3.request_id > req_id1);
  (* Late reply from initial Auto request_id MUST NOT overwrite v #3 Auto diagram *)
  let m_v3_after_stale, _ = Update.step ~now:now0 m_v3 ok_msg in
  check bool "late Auto reply with old request_id dropped after 3x v" true
    (Observed.is_loading
       (Option.get m_v3_after_stale.knowledge.memory_diagram).payload);

  (* Esc closes diagram without popping dive AND emits Cancel_memory_diagram *)
  let m_esc, esc_cmds =
    Update.step ~now:now0 m2 (Msg.Key_event (key_special Keymap.Input.Escape))
  in
  check bool "Esc closes memory_diagram" true
    (Option.is_none m_esc.knowledge.memory_diagram);
  check bool "Esc emits Cancel_memory_diagram" true
    (has_cancel_diagram_cmd esc_cmds);
  check bool "Esc preserves Dive_keeper" true
    (Option.is_some (Model.active_dive m_esc));

  (* Re-opening with '.' after Esc allocates strictly higher request_id *)
  let m_reopen, _ = Update.step ~now:now0 m_esc (Msg.Key_event (key_char ".")) in
  let d_reopen = Option.get m_reopen.knowledge.memory_diagram in
  check bool "reopen request_id strictly greater than closed diagram" true
    (d_reopen.request_id > req_id1);
  let m_reopen_stale, _ = Update.step ~now:now0 m_reopen ok_msg in
  check bool "reply from pre-Esc request_id dropped after reopen" true
    (Observed.is_loading
       (Option.get m_reopen_stale.knowledge.memory_diagram).payload);

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

  let m_chat, chat_cmds =
    Update.step ~now:now0 m_tree (Msg.Key_event (key_char "c"))
  in
  check bool "c chat hotkey closes diagram" true
    (Option.is_none m_chat.knowledge.memory_diagram);
  check bool "c chat hotkey closing diagram emits Cancel_memory_diagram" true
    (has_cancel_diagram_cmd chat_cmds);

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
    |> fun lineage -> Memory_lineage.Lineage lineage
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

  (* Auto + Kitty + missing terminal OSC 11 palette on SVG card -> falls back to active TUI Theme
     palette and STILL emits Diagram_pele_png! *)
  let no_pal_scene = ref None in
  let payload_no_pal =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun sc ->
        no_pal_scene := Some sc;
        Ok png)
      ~theme_preset:Theme.Paper_light
      ~probe:{ kitty_probe with palette = None }
      ~term_program:None ~palette:None ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_pele_card
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
  in
  (match payload_no_pal with
  | Knowledge_store.Diagram_pele_png
      { pixel_size = Some (1240, 540); format_label = "Pele SVG"; _ } ->
      ()
  | Knowledge_store.Diagram_pele_png _ | Knowledge_store.Diagram_text _ ->
      fail "expected Diagram_pele_png using Theme fallback palette when OSC 11 palette is None");
  let expected_paper_colors =
    Pele.colors_of_palette (Palette.of_theme (Theme.of_preset Theme.Paper_light))
  in
  (match !no_pal_scene with
  | Some sc ->
      check (option (pair string string))
        "Pele scene uses active Theme fallback colors"
        (Some expected_paper_colors) sc.colors
  | None -> fail "expected Pele scene to be invoked with fallback theme palette");

  (* Auto + Ghostty TERM_PROGRAM with probe.graphics=None -> Kitty_protocol -> Pele SVG PNG *)
  let ghostty_called = ref 0 in
  let payload_ghostty =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ ->
        incr ghostty_called;
        Ok png)
      ~probe:Probe.empty_observation ~term_program:(Some "ghostty")
      ~palette:None ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_pele_card
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
  in
  check int "Ghostty fallback invokes Pele without startup probe reply" 1
    !ghostty_called;
  (match payload_ghostty with
  | Knowledge_store.Diagram_pele_png { pixel_size = Some (1240, 540); _ } -> ()
  | Knowledge_store.Diagram_pele_png _ | Knowledge_store.Diagram_text _ ->
      fail "expected Diagram_pele_png on Ghostty when probe.graphics = None");

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

  (* Auto + Kitty + Pele returns corrupt/truncated PNG -> text fallback, NEVER Diagram_pele_png *)
  let payload_corrupt_svg =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ -> Ok (String.sub png 0 29))
      ~probe:kitty_probe ~term_program:None ~palette:(Some pal) ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_pele_card
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
  in
  (match payload_corrupt_svg with
  | Knowledge_store.Diagram_text { lines = _ :: _; note = Some _ } -> ()
  | Knowledge_store.Diagram_text _ | Knowledge_store.Diagram_pele_png _ ->
      fail "expected Diagram_text fallback when Pele returns truncated PNG");
  let payload_corrupt_tree =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ -> Ok "not-a-png")
      ~probe:kitty_probe ~term_program:None ~palette:(Some pal) ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_formation_tree
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:80 ~chart ()
  in
  (match payload_corrupt_tree with
  | Knowledge_store.Diagram_text { lines = _ :: _; note = Some _ } -> ()
  | Knowledge_store.Diagram_text _ | Knowledge_store.Diagram_pele_png _ ->
      fail
        "expected Formation tree text fallback when Pele returns invalid PNG");

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
  let png = sample_png ~w:1240 ~h:540 in
  let m_open, _ = Update.step ~now:now0 m0 (Msg.Key_event (key_char ".")) in
  let req_id = (Option.get m_open.knowledge.memory_diagram).request_id in
  let m_png, _ =
    Update.step ~now:now0 m_open
      (Msg.Memory_diagram_rendered
         {
           epoch = m_open.epoch;
           request_id = req_id;
           keeper = "alpha";
           event_identity = "ev-1";
           kind = Knowledge_store.Diagram_pele_card;
           mode = Knowledge_store.Diagram_mode_auto;
           result =
             Ok
               (Knowledge_store.Diagram_pele_png
                  {
                    png;
                    pixel_size = Some (1240, 540);
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
  let body_rect = Option.get (Memory_diagram.active_diagram_body_rect m_png) in

  (* Transition 1: None -> active PNG emits bounded Kitty replace_png once with Memory_diagram slot ID *)
  let s1 =
    App.step_memory_graphic ~active:None ~probe:kitty_probe ~term_program:None
      ~in_tmux:false ~model:m_png ~full_repaint:false
  in
  check string "no pre-clear on initial placement" "" s1.pre_present_bytes;
  check bool "emits Kitty placement bytes" true
    (String.length s1.post_present_bytes > 0);
  check bool "placement binds Memory_diagram slot id" true
    (String.contains s1.post_present_bytes '\x1b'
    && has_substring s1.post_present_bytes mem_id_token);
  (match
     parse_kitty_param s1.post_present_bytes "c",
     parse_kitty_param s1.post_present_bytes "r"
   with
  | Some c, Some r ->
      check bool "Kitty c= strictly within body_rect.w" true
        (c >= 1 && c <= body_rect.w);
      check bool "Kitty r= strictly within body_rect.h" true
        (r >= 1 && r <= body_rect.h)
  | (Some _ | None), (Some _ | None) ->
      fail "expected explicit c= and r= bounds on Kitty placement");
  check bool "tracks active graphic state" true (Option.is_some s1.next_state);

  (* Kitty with cell_pixels = None MUST still bound both c= and r= with 1:2 aspect ratio *)
  let cols_no_cp, rows_no_cp =
    Graphics.fit_cells ~cell_pixels:None ~image_pixels:(Some (1240, 540))
      ~columns:66 ~rows:30
  in
  check (pair int int) "1240x540 in 66x30 without cell_pixels -> (66, 14)"
    (66, 14) (cols_no_cp, rows_no_cp);
  let cols_banner, rows_banner =
    Graphics.fit_cells ~cell_pixels:(Some (10, 20))
      ~image_pixels:(Some (1240, 100)) ~columns:12 ~rows:10
  in
  check (pair int int) "wide banner in 12x10 bounds c=12, r=1" (12, 1)
    (cols_banner, rows_banner);
  let cols_no_img, rows_no_img =
    Graphics.fit_cells ~cell_pixels:None ~image_pixels:None ~columns:40 ~rows:20
  in
  check (pair int int) "missing image_pixels caps strictly to box" (40, 20)
    (cols_no_img, rows_no_img);
  let kitty_no_cell_pixels = { kitty_probe with cell_pixels = None } in
  let s_no_cp =
    App.step_memory_graphic ~active:None ~probe:kitty_no_cell_pixels
      ~term_program:None ~in_tmux:false ~model:m_png ~full_repaint:false
  in
  (match
     parse_kitty_param s_no_cp.post_present_bytes "c",
     parse_kitty_param s_no_cp.post_present_bytes "r"
   with
  | Some c, Some r ->
      check bool "cell_pixels=None c= bounded" true
        (c >= 1 && c <= body_rect.w);
      check bool "cell_pixels=None r= bounded" true
        (r >= 1 && r <= body_rect.h)
  | (Some _ | None), (Some _ | None) ->
      fail "expected explicit c= and r= when cell_pixels = None");

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

  (* Transition 2b: Composer '/' and '@' popups clear Kitty graphic + invalidate, then re-place on dismiss *)
  let m_focused, _ = Update.step ~now:now0 m_png (Msg.Key_event (key_char "i")) in
  let m_slash, _ =
    Update.step ~now:now0 m_focused (Msg.Key_event (key_char "/"))
  in
  check bool "composer slash popup active" true
    (match Update_nav.resolve_composer_popup m_slash with
    | Update_nav.Composer_popup_slash _ -> true
    | Update_nav.Composer_popup_none | Update_nav.Composer_popup_mention _ ->
        false);
  let s_popup =
    App.step_memory_graphic ~active:s2.next_state ~probe:kitty_probe
      ~term_program:None ~in_tmux:false ~model:m_slash ~full_repaint:false
  in
  check string "slash popup emits Kitty delete_image"
    (Graphics.delete_image ~image_id:(Graphics.image_id Graphics.Memory_diagram))
    s_popup.pre_present_bytes;
  check bool "slash popup invalidates presenter" true
    s_popup.invalidate_presenter;
  check string "slash popup suppresses placement" "" s_popup.post_present_bytes;
  check bool "slash popup clears active state" true
    (Option.is_none s_popup.next_state);
  let m_dismiss, _ =
    Update.step ~now:now0 m_slash (Msg.Key_event (key_special Keymap.Input.Escape))
  in
  let s_after_dismiss =
    App.step_memory_graphic ~active:s_popup.next_state ~probe:kitty_probe
      ~term_program:None ~in_tmux:false ~model:m_dismiss ~full_repaint:false
  in
  check bool "dismissing slash popup re-places Kitty graphic" true
    (String.length s_after_dismiss.post_present_bytes > 0
    && Option.is_some s_after_dismiss.next_state);

  let m_mention, _ =
    Update.step ~now:now0 m_focused (Msg.Key_event (key_char "@"))
  in
  check bool "composer mention popup active" true
    (match Update_nav.resolve_composer_popup m_mention with
    | Update_nav.Composer_popup_mention _ -> true
    | Update_nav.Composer_popup_none | Update_nav.Composer_popup_slash _ ->
        false);
  let s_mention =
    App.step_memory_graphic ~active:s2.next_state ~probe:kitty_probe
      ~term_program:None ~in_tmux:false ~model:m_mention ~full_repaint:false
  in
  check bool "mention popup clears graphic and invalidates" true
    (s_mention.invalidate_presenter && Option.is_none s_mention.next_state);

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

  (* Transition 5: iTerm2 protocol uses OSC 1337 placement, clears on popup & close, and re-places *)
  let s_it2 =
    App.step_memory_graphic ~active:None ~probe:Probe.empty_observation
      ~term_program:(Some "iTerm.app") ~in_tmux:false ~model:m_png
      ~full_repaint:false
  in
  check bool "iTerm2 emits OSC 1337 placement" true
    (String.length s_it2.post_present_bytes > 0);
  let s_it2_popup =
    App.step_memory_graphic ~active:s_it2.next_state
      ~probe:Probe.empty_observation ~term_program:(Some "iTerm.app")
      ~in_tmux:false ~model:m_slash ~full_repaint:false
  in
  check bool "iTerm2 slash popup invalidates presenter & clears active state"
    true
    (s_it2_popup.invalidate_presenter && Option.is_none s_it2_popup.next_state);
  let s_it2_after =
    App.step_memory_graphic ~active:s_it2_popup.next_state
      ~probe:Probe.empty_observation ~term_program:(Some "iTerm.app")
      ~in_tmux:false ~model:m_dismiss ~full_repaint:false
  in
  check bool "iTerm2 re-places image cleanly after popup dismiss" true
    (String.length s_it2_after.post_present_bytes > 0
    && Option.is_some s_it2_after.next_state);
  let s_it2_close =
    App.step_memory_graphic ~active:s_it2.next_state
      ~probe:Probe.empty_observation ~term_program:(Some "iTerm.app")
      ~in_tmux:false ~model:m_closed ~full_repaint:false
  in
  check string "iTerm2 close has no Kitty delete bytes" ""
    s_it2_close.pre_present_bytes;
  check bool "iTerm2 close still invalidates presenter to repaint cells" true
    s_it2_close.invalidate_presenter

(* 6. TERM=dumb + TERM_PROGRAM=iTerm.app masking *)

let test_term_dumb_masks_term_program () =
  let env_of pairs k = List.assoc_opt k pairs in
  check (option string) "TERM=dumb masks iTerm.app" None
    (Graphics.effective_term_program
       ~getenv:(env_of [ ("TERM", "dumb"); ("TERM_PROGRAM", "iTerm.app") ]));
  check (option string) "TERM=DUMB masks iTerm.app" None
    (Graphics.effective_term_program
       ~getenv:(env_of [ ("TERM", " DUMB "); ("TERM_PROGRAM", "iTerm.app") ]));
  check (option string) "empty TERM masks iTerm.app" None
    (Graphics.effective_term_program
       ~getenv:(env_of [ ("TERM", ""); ("TERM_PROGRAM", "iTerm.app") ]));
  check (option string) "missing TERM masks iTerm.app" None
    (Graphics.effective_term_program
       ~getenv:(env_of [ ("TERM_PROGRAM", "iTerm.app") ]));
  check (option string) "xterm-256color preserves iTerm.app" (Some "iTerm.app")
    (Graphics.effective_term_program
       ~getenv:
         (env_of [ ("TERM", "xterm-256color"); ("TERM_PROGRAM", "iTerm.app") ]));

  let term_program =
    Graphics.effective_term_program
      ~getenv:(env_of [ ("TERM", "dumb"); ("TERM_PROGRAM", "iTerm.app") ])
  in
  check bool "dumb terminal resolves to Unsupported_protocol" true
    (Graphics.equal_graphics_protocol
       (Graphics.protocol_of_probe ~graphics:None ~term_program)
       Graphics.Unsupported_protocol);
  let act = sample_activity ~keeper:"alpha" in
  let facts = sample_facts ~keeper:"alpha" in
  let chart =
    Memory_diagram.chart_of_activity ~keeper:"alpha" ~activity:act
      ~facts:(Some facts) ~selected:(List.hd act.events)
    |> Option.get
    |> fun lineage -> Memory_lineage.Lineage lineage
  in
  let pele_calls = ref 0 in
  let payload =
    Cmd_executor.render_memory_diagram_payload
      ~run_pele:(fun _ ->
        incr pele_calls;
        Ok (sample_png ~w:1240 ~h:540))
      ~probe:Probe.empty_observation ~term_program
      ~palette:(Some (sample_palette ())) ~keeper:"alpha"
      ~kind:Knowledge_store.Diagram_pele_card
      ~mode:Knowledge_store.Diagram_mode_auto ~ko:false ~tz_offset_sec:0
      ~now_unix:1_700_000_500.0 ~max_width:80 ~chart ()
  in
  check int "dumb + iTerm.app never calls Pele" 0 !pele_calls;
  (match payload with
  | Knowledge_store.Diagram_text { lines = _ :: _; note = Some _ } -> ()
  | Knowledge_store.Diagram_text _ | Knowledge_store.Diagram_pele_png _ ->
      fail "expected text fallback on TERM=dumb");
  let m0 = model_in_keeper_memory_dive ~keeper:"alpha" in
  let m_open, _ = Update.step ~now:now0 m0 (Msg.Key_event (key_char ".")) in
  let req_id = (Option.get m_open.knowledge.memory_diagram).request_id in
  let m_png, _ =
    Update.step ~now:now0 m_open
      (Msg.Memory_diagram_rendered
         {
           epoch = m_open.epoch;
           request_id = req_id;
           keeper = "alpha";
           event_identity = "ev-1";
           kind = Knowledge_store.Diagram_pele_card;
           mode = Knowledge_store.Diagram_mode_auto;
           result =
             Ok
               (Knowledge_store.Diagram_pele_png
                  {
                    png = sample_png ~w:1240 ~h:540;
                    pixel_size = Some (1240, 540);
                    format_label = "Pele SVG";
                    fallback_lines = [ "fallback" ];
                  });
         })
  in
  let step_dumb =
    App.step_memory_graphic ~active:None ~probe:Probe.empty_observation
      ~term_program ~in_tmux:false ~model:m_png ~full_repaint:false
  in
  check string "TERM=dumb emits zero OSC 1337 bytes" ""
    step_dumb.post_present_bytes;
  let step_tmux_ghostty =
    App.step_memory_graphic ~active:None ~probe:Probe.empty_observation
      ~term_program:(Some "ghostty") ~in_tmux:true ~model:m_png
      ~full_repaint:false
  in
  check string "tmux with graphics=None emits zero Kitty APC bytes even for ghostty"
    "" step_tmux_ghostty.post_present_bytes;
  let step_direct_ghostty =
    App.step_memory_graphic ~active:None ~probe:Probe.empty_observation
      ~term_program:(Some "ghostty") ~in_tmux:false ~model:m_png
      ~full_repaint:false
  in
  check bool "direct Ghostty with graphics=None emits Kitty APC bytes" true
    (String.length step_direct_ghostty.post_present_bytes > 0)

(* 7. Hidden diagram on narrow 4 Keepers / Micro does not hijack Esc/y/v,
      Enter is no-op in 3 -> Memory when diagram open,
      [r] retries failed diagram, Msg.Resize re-layouts open text diagram *)

let test_visibility_enter_refresh_and_resize () =
  (* 7a. Compact (< 104 cols) 4 Keepers > Memory renders open diagram in full body card;
         switching away from Keeper_memory tab (or Micro viewport) hides diagram without key hijack *)
  let m0 =
    Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko
      ~wall_unix:1_700_000_500.0 ()
  in
  let fleet =
    Fleet_store.empty
    |> Fleet_store.apply_keepers ~observed_at:now0
         [ sample_keeper "alpha"; sample_keeper "beta" ]
    |> Fleet_store.select_keeper "alpha"
    |> Fleet_store.set_keeper_dive_tab Nav.Keeper_memory
  in
  let knowledge =
    Knowledge_store.empty
    |> Knowledge_store.set_memory_diff_keeper (Some "alpha")
    |> Knowledge_store.set_keeper_memory_activity ~keeper:"alpha"
         (Observed.value ~observed_at:now0 (sample_activity ~keeper:"alpha"))
    |> Knowledge_store.set_keeper_memory_facts ~keeper:"alpha"
         (Observed.value ~observed_at:now0 (sample_facts ~keeper:"alpha"))
  in
  let m_kp0, _ = Update_nav.switch_workspace { m0 with fleet; knowledge } Nav.Keepers in
  (* Compact width (cols=80 < 104) on 4 Keepers > Memory opens diagram cleanly in full body card *)
  let m_compact0, _ =
    Update.step ~now:now0 m_kp0 (Msg.Resize { cols = 80; rows = 30 })
  in
  let m_compact_open, cmds_compact_open =
    Update.step ~now:now0 m_compact0 (Msg.Key_event (key_char "."))
  in
  check bool "diagram active on compact (< 104) 4 Keepers > Memory" true
    (Option.is_some (Memory_diagram.active_diagram m_compact_open));
  check bool "compact 4 Keepers > Memory dispatches Render_memory_diagram" true
    (Option.is_some (find_render_cmd cmds_compact_open));
  let m_compact_v, _ =
    Update.step ~now:now0 m_compact_open (Msg.Key_event (key_char "v"))
  in
  check bool "v cycles mode on compact 4 Keepers > Memory" true
    (Knowledge_store.equal_memory_diagram_mode
       (Option.get m_compact_v.knowledge.memory_diagram).mode
       Knowledge_store.Diagram_mode_mermaid);
  let m_compact_esc, _ =
    Update.step ~now:now0 m_compact_v (Msg.Key_event (key_special Keymap.Input.Escape))
  in
  check bool "Esc closes compact 4 Keepers > Memory diagram cleanly" true
    (Option.is_none m_compact_esc.knowledge.memory_diagram);

  (* Hidden diagram when tab is switched away from Keeper_memory does NOT hijack v / y / Esc *)
  let m_kp_open, _ = Update.step ~now:now0 m_kp0 (Msg.Key_event (key_char ".")) in
  check bool "diagram active on wide split 4 Keepers" true
    (Option.is_some (Memory_diagram.active_diagram m_kp_open));
  let m_hidden =
    {
      m_kp_open with
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_chat m_kp_open.fleet;
    }
  in
  check bool "non-Memory tab hides active_memory_keeper" true
    (Option.is_none (Memory_diagram.active_memory_keeper m_hidden));
  check bool "non-Memory tab hides active_diagram" true
    (Option.is_none (Memory_diagram.active_diagram m_hidden));
  let m_hidden_v, cmds_hidden_v =
    Update.step ~now:now0 m_hidden (Msg.Key_event (key_char "v"))
  in
  check bool "v does not re-render hidden diagram" true
    (Option.is_none (find_render_cmd cmds_hidden_v));
  check bool "hidden diagram mode unchanged by v" true
    (Knowledge_store.equal_memory_diagram_mode
       (Option.get m_hidden_v.knowledge.memory_diagram).mode
       Knowledge_store.Diagram_mode_auto);
  let _, cmds_hidden_y =
    Update.step ~now:now0 m_hidden (Msg.Key_event (key_char "y"))
  in
  let copied_hidden =
    List.exists
      (function
        | Cmd.Copy_clipboard s ->
            String.equal s
              (Option.get m_hidden.knowledge.memory_diagram).copy_source
        | Cmd.Batch _
        | Cmd.Http_get _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_delete _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Render_memory_diagram _
        | Cmd.Cancel_memory_diagram
        | Cmd.Fetch_artifact_and_copy _
        | Cmd.Export_artifact _
        | Cmd.Open_dos_screen _
        | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _ | Cmd.Open_terminal_program _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            false)
      (Cmd.flatten cmds_hidden_y)
  in
  check bool "y does not copy hidden diagram" false copied_hidden;
  let m_hidden_esc, _ =
    Update.step ~now:now0 m_hidden (Msg.Key_event (key_special Keymap.Input.Escape))
  in
  check bool "Esc does not hijack/close hidden diagram" true
    (Option.is_some m_hidden_esc.knowledge.memory_diagram);

  (* Micro viewport also hides active_diagram on Dive_keeper *)
  let m_dive = model_in_keeper_memory_dive ~keeper:"alpha" in
  let m_dive_open, _ = Update.step ~now:now0 m_dive (Msg.Key_event (key_char ".")) in
  let m_micro, _ =
    Update.step ~now:now0 m_dive_open (Msg.Resize { cols = 50; rows = 14 })
  in
  check bool "Micro viewport hides active_diagram" true
    (Option.is_none (Memory_diagram.active_diagram m_micro));

  (* 7b. Enter in 3 -> Memory with open diagram is a no-op (never pushes Memory_diff_dive) *)
  let diff_snap : Wire_knowledge.memory_diff =
    {
      scope = Wire_knowledge.Scope_keeper "alpha";
      range =
        {
          from_rev = Some 1;
          to_rev = Some 3;
          from_unix = Some 1_700_000_100.0;
          to_unix = Some 1_700_000_300.0;
          window = Some "24h";
        };
      retrieval_heat =
        {
          hot = 0;
          warm = 0;
          cold = 0;
          never_retrieved = 0;
          total_events = 0;
          unreadable_event_lines = 0;
        };
      body =
        Wire_knowledge.Keeper_diff
          {
            counts =
              {
                total_facts_now = 2;
                added = 0;
                updated = 0;
                retracted = 0;
                invalidated = 0;
                journal_failures_in_window = 0;
                journal_quarantines_in_window = 0;
                undecodable_journal_lines = 0;
                history_coverage = None;
              };
            revisions = [];
            added = [];
            updated = [];
            retracted = [];
            invalidated = [];
            writer_status = None;
          };
    }
  in
  let k_mem =
    knowledge
    |> Knowledge_store.set_tab Nav.Knowledge_memory
    |> Knowledge_store.set_memory_diff_keeper (Some "alpha")
    |> Knowledge_store.set_memory_diff ~keeper:(Some "alpha")
         ~window:Knowledge_store.Window_24h
         (Observed.value ~observed_at:now0 diff_snap)
  in
  let m_k3, _ =
    Update_nav.switch_workspace { m0 with fleet; knowledge = k_mem } Nav.Knowledge
  in
  let m_k3_open, _ = Update.step ~now:now0 m_k3 (Msg.Key_event (key_char ".")) in
  check bool "3 -> Memory opens diagram" true
    (Option.is_some (Memory_diagram.active_diagram m_k3_open));
  let m_k3_enter, _ =
    Update.step ~now:now0 m_k3_open (Msg.Key_event (key_special Keymap.Input.Enter))
  in
  check bool "Enter in 3 -> Memory does not push Memory_diff_dive" true
    (Option.is_none (Model.active_dive m_k3_enter));
  check bool "Enter in 3 -> Memory keeps diagram open" true
    (Option.is_some (Memory_diagram.active_diagram m_k3_enter));

  let missing_id = "m-retracted-outside-activity-window" in
  let selected_diff =
    match diff_snap.body with
    | Wire_knowledge.Keeper_diff body ->
        let retracted : Wire_knowledge.memory_retracted_fact =
          {
            event_order = None;
            memory_id = missing_id;
            category = "fact";
            text = "Retracted memory";
            removed_at_rev = Some 3;
            at_unix = Some 1_700_000_300.0;
            removed_by = None;
            drop_reason = None;
          }
        in
        { diff_snap with
          body = Wire_knowledge.Keeper_diff
            { body with counts = { body.counts with retracted = 1 };
              retracted = [ retracted ] } }
    | Wire_knowledge.World_diff _ -> fail "expected a keeper diff fixture"
  in
  let selection =
    m_k3.knowledge
    |> Knowledge_store.set_memory_view_mode Knowledge_store.View_diff
    |> Knowledge_store.set_memory_diff ~keeper:(Some "alpha")
         ~window:Knowledge_store.Window_24h
         (Observed.value ~observed_at:now0 selected_diff)
  in
  check bool "the retracted row is selected" true
    (match Knowledge_store.selected_memory_diff_item_for
       ~keeper_opt:(Some "alpha") selection with
    | Some (Knowledge_store.Keeper_retracted fact) -> String.equal fact.memory_id missing_id
    | _ -> false);
  let m_missing, missing_commands =
    Update.step ~now:now0 { m_k3 with knowledge = selection }
      (Msg.Key_event (key_char "."))
  in
  check bool "missing selected fact cannot open another memory diagram" true
    (Option.is_none m_missing.knowledge.memory_diagram);
  check bool "missing selected fact sends no renderer command" true
    (Option.is_none (find_render_cmd (Cmd.flatten missing_commands)));

  (* 7c. [r] retries a Failed diagram with incremented request_id *)
  let req_failed = (Option.get m_dive_open.knowledge.memory_diagram).request_id in
  let m_failed, _ =
    Update.step ~now:now0 m_dive_open
      (Msg.Memory_diagram_rendered
         {
           epoch = m_dive_open.epoch;
           request_id = req_failed;
           keeper = "alpha";
           event_identity = "ev-1";
           kind = Knowledge_store.Diagram_pele_card;
           mode = Knowledge_store.Diagram_mode_auto;
           result = Error "transient pele failure";
         })
  in
  check bool "diagram enters Failed state" true
    (match (Option.get m_failed.knowledge.memory_diagram).payload with
    | Observed.Failed { retryable = true; _ } -> true
    | Observed.Failed { retryable = false; _ }
    | Observed.Loading _
    | Observed.Value _
    | Observed.Absent
    | Observed.Unreported ->
        false);
  let m_retry, retry_cmds =
    Update.step ~now:now0 m_failed (Msg.Key_event (key_char "r"))
  in
  let d_retry = Option.get m_retry.knowledge.memory_diagram in
  check bool "[r] puts failed diagram back into Loading" true
    (Observed.is_loading d_retry.payload);
  check bool "[r] allocates fresh request_id" true
    (d_retry.request_id > req_failed);
  check bool "[r] emits Cmd.Render_memory_diagram" true
    (Option.is_some (find_render_cmd retry_cmds));

  (* 7d. Msg.Resize re-layouts open text/fallback diagram to new width,
         but avoids redundant Pele re-dispatch for active PNGs *)
  let m_text, _ =
    Update.step ~now:now0 m_retry
      (Msg.Memory_diagram_rendered
         {
           epoch = m_retry.epoch;
           request_id = d_retry.request_id;
           keeper = "alpha";
           event_identity = "ev-1";
           kind = Knowledge_store.Diagram_pele_card;
           mode = Knowledge_store.Diagram_mode_auto;
           result =
             Ok
               (Knowledge_store.Diagram_text
                  { lines = [ "wide-layout" ]; note = None });
         })
  in
  let m_resized_text, resize_text_cmds =
    Update.step ~now:now0 m_text (Msg.Resize { cols = 96; rows = 40 })
  in
  let d_resized = Option.get m_resized_text.knowledge.memory_diagram in
  check bool "Resize on text diagram increments request_id" true
    (d_resized.request_id > d_retry.request_id);
  (match find_render_cmd resize_text_cmds with
  | Some (Cmd.Render_memory_diagram { max_width; request_id; _ }) ->
      check int "Resize command carries new request_id" d_resized.request_id
        request_id;
      check bool "Resize command uses narrowed max_width (< 100)" true
        (max_width < 100)
  | Some _ | None ->
      fail "expected Cmd.Render_memory_diagram when resizing open text diagram");

  let m_png_live, _ =
    Update.step ~now:now0 m_resized_text
      (Msg.Memory_diagram_rendered
         {
           epoch = m_resized_text.epoch;
           request_id = d_resized.request_id;
           keeper = "alpha";
           event_identity = "ev-1";
           kind = Knowledge_store.Diagram_pele_card;
           mode = Knowledge_store.Diagram_mode_auto;
           result =
             Ok
               (Knowledge_store.Diagram_pele_png
                  {
                    png = sample_png ~w:1240 ~h:540;
                    pixel_size = Some (1240, 540);
                    format_label = "Pele SVG";
                    fallback_lines = [ "fallback" ];
                  });
         })
  in
  let _, resize_png_cmds =
    Update.step ~now:now0 m_png_live (Msg.Resize { cols = 120; rows = 40 })
  in
  check bool "Resize on visible PNG does not re-spawn Pele" true
    (Option.is_none (find_render_cmd resize_png_cmds))

(* 8. Cooperative Pele subprocess cancellation kills sleeping helper promptly *)

let test_pele_cooperative_cancellation () =
  let tmp_dir = Filename.temp_file "masc-pele-cancel-" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o700;
  let script = Filename.concat tmp_dir "slow-pele.sh" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove script with Sys_error _ -> ());
      try Unix.rmdir tmp_dir with Unix.Unix_error _ -> ())
    (fun () ->
      Out_channel.with_open_bin script (fun oc ->
          Out_channel.output_string oc "#!/bin/sh\nexec /bin/sleep 5\n");
      Unix.chmod script 0o700;
      let cancelled = Atomic.make false in
      let scene =
        Pele.scene ~format:Pele.Svg ~max_width:800 ~font_size:14 ~now_ms:0L
          ~colors:None "<svg/>"
      in
      let runner =
        Pele.process_runner ~executable:script ~timeout_s:5.0
          ~cancelled:(fun () -> Atomic.get cancelled)
          ()
      in
      let t0 = Clock.Mono.now () in
      let res = ref (Ok "") in
      Eio_main.run (fun env ->
          let clock = Eio.Stdenv.clock env in
          Eio.Fiber.both
            (fun () ->
              res :=
                Eio_unix.run_in_systhread (fun () ->
                    Pele.render ~cache_dir:tmp_dir ~timeout_s:5.0
                      ~cancelled:(fun () -> Atomic.get cancelled)
                      ~runner scene))
            (fun () ->
              Eio.Time.sleep clock 0.05;
              Atomic.set cancelled true));
      let elapsed = Clock.Mono.seconds_since (Clock.Mono.now ()) ~since:t0 in
      check (result string string) "cancelled Pele returns Error"
        (Error "Pele was cancelled") !res;
  check bool "Pele cooperative cancellation kills sleeping helper promptly" true
    (elapsed < 1.5);
  (* Keymap Help SSOT documents '.', 'Ctrl+O', and 'v' with zero collisions *)
  check int "keymap has zero collisions" 0 (List.length (Keymap.collisions ()));
  let help_groups =
    Keymap.help_entries ~scope_chain:Keymap.all_scopes ~lang:Say.Lang_en
  in
  let help_keys =
    List.concat_map
      (fun (g : Keymap.help_group) ->
        List.concat_map (fun (e : Keymap.help_entry) -> e.keys) g.entries)
      help_groups
  in
  check bool "Help SSOT lists '.'" true (List.mem "." help_keys);
  check bool "Help SSOT lists 'v'" true (List.mem "v" help_keys);
  check bool "Help SSOT lists 'Ctrl+O'" true (List.mem "Ctrl+O" help_keys);
  let md_ref = Keymap.render_markdown_reference ~lang:Say.Lang_en () in
  check bool "Markdown reference documents '.'" true
    (has_substring md_ref "`.`");
  check bool "Markdown reference documents 'v'" true
    (has_substring md_ref "`v`");
  check bool "Markdown reference documents Formation Tree on Ctrl+O" true
    (has_substring md_ref "Formation Tree"))

let test_all_subviews_and_orphan_fact_snapshot () =
  let m0 = model_in_keeper_memory_dive ~keeper:"alpha" in

  (* 1. All keeper-scoped subviews in Dive_keeper allow '.' and Ctrl+O,
        and Esc restores the exact prior subview *)
  let check_keeper_subview label subview =
    let m_sv =
      { m0 with knowledge = { m0.knowledge with keeper_memory_subview = subview } }
    in
    let m_open, cmds_open =
      Update.step ~now:now0 m_sv (Msg.Key_event (key_char "."))
    in
    check bool (label ^ ": '.' opens diagram") true
      (Option.is_some (Memory_diagram.active_diagram m_open));
    check bool (label ^ ": '.' dispatches Render_memory_diagram") true
      (Option.is_some (find_render_cmd cmds_open));
    let m_tree, _ =
      Update.step ~now:now0 m_open (Msg.Key_event (key_char ~ctrl:true "o"))
    in
    check bool (label ^ ": Ctrl+O switches to Formation Tree") true
      (Knowledge_store.equal_memory_diagram_kind
         (Option.get m_tree.knowledge.memory_diagram).kind
         Knowledge_store.Diagram_formation_tree);
    let m_esc, _ =
      Update.step ~now:now0 m_tree (Msg.Key_event (key_special Keymap.Input.Escape))
    in
    check bool (label ^ ": Esc closes diagram") true
      (Option.is_none m_esc.knowledge.memory_diagram);
    check bool (label ^ ": Esc preserves exact prior keeper_memory_subview") true
      (Knowledge_store.equal_keeper_memory_subview
         m_esc.knowledge.keeper_memory_subview subview)
  in
  check_keeper_subview "Kmem_facts_tree" Knowledge_store.Kmem_facts_tree;
  check_keeper_subview "Kmem_health" Knowledge_store.Kmem_health;
  check_keeper_subview "Kmem_journal" Knowledge_store.Kmem_journal;

  (* 2. Non-Diff_flow subviews in 3 Knowledge -> Memory (Mem_health_ledger, Mem_context)
        allow '.' and Ctrl+O when a keeper is selected *)
  let m_k_base =
    let m_init =
      Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_en
        ~wall_unix:1_700_000_500.0 ()
    in
    let knowledge =
      Knowledge_store.empty
      |> Knowledge_store.set_tab Nav.Knowledge_memory
      |> Knowledge_store.set_memory_diff_keeper (Some "alpha")
      |> Knowledge_store.set_keeper_memory_activity ~keeper:"alpha"
           (Observed.value ~observed_at:now0 (sample_activity ~keeper:"alpha"))
      |> Knowledge_store.set_keeper_memory_facts ~keeper:"alpha"
           (Observed.value ~observed_at:now0 (sample_facts ~keeper:"alpha"))
    in
    fst (Update_nav.switch_workspace { m_init with knowledge } Nav.Knowledge)
  in
  List.iter
    (fun (label, subview) ->
      let m_sv =
        { m_k_base with knowledge = { m_k_base.knowledge with memory_subview = subview } }
      in
      let m_open, cmds_open =
        Update.step ~now:now0 m_sv (Msg.Key_event (key_char "."))
      in
      check bool (label ^ ": '.' opens diagram") true
        (Option.is_some (Memory_diagram.active_diagram m_open));
      check bool (label ^ ": '.' emits Render_memory_diagram") true
        (Option.is_some (find_render_cmd cmds_open));
      let m_esc, _ =
        Update.step ~now:now0 m_open
          (Msg.Key_event (key_special Keymap.Input.Escape))
      in
      check bool (label ^ ": Esc closes diagram") true
        (Option.is_none m_esc.knowledge.memory_diagram);
      check bool (label ^ ": Esc preserves exact prior memory_subview") true
        (Knowledge_store.equal_memory_subview m_esc.knowledge.memory_subview
           subview))
    [
      ("Mem_health_ledger", Knowledge_store.Mem_health_ledger);
      ("Mem_context", Knowledge_store.Mem_context);
    ];

  (* 3. Ordinary fact absent from last 50 activity events (m-orphan) opens an honest
        single-fact current-snapshot chart instead of rejecting with a toast! *)
  let m_facts_en =
    let m_en =
      Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_en
        ~wall_unix:1_700_000_500.0 ()
    in
    let fleet = m0.fleet in
    let knowledge =
      m0.knowledge
      |> Knowledge_store.set_memory_view_mode Knowledge_store.View_facts
    in
    let m1, _ =
      Update_nav.push_dive { m_en with fleet; knowledge }
        (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory })
    in
    (* Move selection down twice to reach m-orphan (index 2: m-1, m-3, m-orphan) *)
    let m2, _ = Update.step ~now:now0 m1 (Msg.Key_event (key_char "j")) in
    let m3, _ = Update.step ~now:now0 m2 (Msg.Key_event (key_char "j")) in
    m3
  in
  let m_orphan_open, orphan_cmds =
    Update.step ~now:now0 m_facts_en (Msg.Key_event (key_char "."))
  in
  let d_orphan =
    match m_orphan_open.knowledge.memory_diagram with
    | Some d -> d
    | None ->
        fail
          "expected honest current-snapshot diagram for ordinary fact absent from activity"
  in
  check string "orphan fact snapshot event_identity" "snapshot:m-orphan"
    d_orphan.event_identity;
  check bool "orphan fact snapshot uses Diagram_source_fact_snapshot" true
    (match d_orphan.source with
    | Knowledge_store.Diagram_source_fact_snapshot id ->
        String.equal id "m-orphan"
    | Knowledge_store.Diagram_source_event _ -> false);
  (match find_render_cmd orphan_cmds with
  | Some (Cmd.Render_memory_diagram { chart = Current_snapshot snapshot; _ }) ->
      check string "current fact ID" "m-orphan" snapshot.fact.memory_id;
      check (option string) "current claim" (Some "Fact with no activity event")
        snapshot.fact.claim;
      check (option int) "actual number of returned events" (Some 3)
        snapshot.activity_entries;
      let chart = Memory_lineage.Current_snapshot snapshot in
      let probe = { Probe.empty_observation with graphics = Some Probe.Graphics_supported } in
      let render ~kind ~mode run_pele =
        Cmd_executor.render_memory_diagram_payload ~run_pele ~probe
          ~term_program:None ~palette:None ~keeper:"alpha" ~kind ~mode ~ko:false
          ~tz_offset_sec:0 ~now_unix:1_700_000_500.0 ~max_width:100 ~chart ()
      in
      let scene_for_snapshot (scene : Pele.scene) =
        check bool "single Mermaid fact scene" true
          (match scene.format with Pele.Mermaid -> true | Svg | Graph -> false);
        check string "Pele receives the same source as the clipboard"
          d_orphan.copy_source scene.source;
        check bool "snapshot has one fact node and no event or edge" true
          (match String.split_on_char '\n' scene.source with
          | [ "flowchart TD"; node; "" ] ->
              String.starts_with ~prefix:"Fact[" node
              && has_substring node "Current snapshot" && has_substring node "m-orphan"
          | _ -> false);
        Ok (sample_png ~w:640 ~h:480)
      in
      List.iter (fun kind ->
          match render ~kind ~mode:Knowledge_store.Diagram_mode_auto scene_for_snapshot with
          | Knowledge_store.Diagram_pele_png { format_label; _ } ->
              check string "snapshot graphics format" "Pele Mermaid" format_label
          | Diagram_text _ -> fail "expected a graphical snapshot")
        [ Knowledge_store.Diagram_pele_card; Diagram_formation_tree ];
      let narrow_lines, note =
        Memory_diagram.render_mermaid_fallback ~ko:false ~max_width:24
          ~kind:Knowledge_store.Diagram_pele_card chart
      in
      check bool "narrow Mermaid fallback displays the fact without source markup" true
        (Option.is_some note && List.mem "m-orphan" narrow_lines
         && List.for_all (fun line -> Grapheme.display_width line <= 24) narrow_lines);
      let no_pele _ = fail "forced text must not call Pele" in
      List.iter (fun mode ->
          match render ~kind:Knowledge_store.Diagram_formation_tree ~mode no_pele with
          | Knowledge_store.Diagram_text { lines; _ } ->
              let body = String.concat "\n" lines in
              check bool "text shows the selected fact as a snapshot" true
                (has_substring body "Current snapshot" && has_substring body "m-orphan");
              check bool "text invents no re-observation" false (has_substring body "Reobserved")
          | Diagram_pele_png _ -> fail "expected a text snapshot")
        [ Knowledge_store.Diagram_mode_mermaid; Diagram_mode_tree ]
  | Some _ | None -> fail "expected a snapshot render command for the selected fact");
  let unobserved =
    { m_facts_en with knowledge = Knowledge_store.set_keeper_memory_activity
        ~keeper:"alpha" Observed.Absent m_facts_en.knowledge }
  in
  let _, unobserved_cmds = Update.step ~now:now0 unobserved (Msg.Key_event (key_char ".")) in
  (match find_render_cmd unobserved_cmds with
   | Some (Cmd.Render_memory_diagram { chart = Current_snapshot snapshot; _ }) ->
       check (option int) "missing journal has no observed count" None snapshot.activity_entries;
       check bool "missing activity stays unobserved in the snapshot" true
         (List.mem "Activity unavailable"
            (Memory_lineage.snapshot_lines ~ko:false ~max_width:100 snapshot))
   | Some _ | None -> fail "expected the selected fact from the available snapshot");
  (* Cycling [v] on snapshot diagram works cleanly (Auto -> Mermaid -> Tree) *)
  let m_orphan_v1, cmds_v1 =
    Update.step ~now:now0 m_orphan_open (Msg.Key_event (key_char "v"))
  in
  check bool "v cycles snapshot diagram to Mermaid" true
    (Knowledge_store.equal_memory_diagram_mode
       (Option.get m_orphan_v1.knowledge.memory_diagram).mode
       Knowledge_store.Diagram_mode_mermaid);
  check bool "v re-dispatches Render_memory_diagram for snapshot" true
    (Option.is_some (find_render_cmd cmds_v1))

let test_dot_without_selected_event_opens_nothing () =
  (* Facts are stored but the journal holds no event to select. [.] then
     opens nothing and asks for nothing, instead of drawing the first
     stored fact. *)
  let no_events =
    obs { (sample_activity ~keeper:"alpha") with events = []; journal_lines = 0 }
  in
  let press_dot label m =
    let m_next, cmds = Update.step ~now:now0 m (Msg.Key_event (key_char ".")) in
    check bool (label ^ ": '.' opens no diagram") true
      (Option.is_none m_next.knowledge.memory_diagram);
    check bool (label ^ ": '.' sends no renderer or fetch command") true
      (Option.is_none (find_render_cmd cmds)
      && List.for_all
           (function Cmd.Http_get _ -> false | _ -> true)
           (Cmd.flatten cmds))
  in
  (* Keeper dive: Health and Journal carry no selection of their own. *)
  let m_dive = model_in_keeper_memory_dive ~keeper:"alpha" in
  let m_dive =
    {
      m_dive with
      knowledge =
        Knowledge_store.set_keeper_memory_activity ~keeper:"alpha" no_events
          m_dive.knowledge;
    }
  in
  List.iter
    (fun (label, subview) ->
      press_dot label
        {
          m_dive with
          knowledge = { m_dive.knowledge with keeper_memory_subview = subview };
        })
    [
      ("Kmem_health", Knowledge_store.Kmem_health);
      ("Kmem_journal", Knowledge_store.Kmem_journal);
    ];
  (* Diff/Flow in evolution mode has no event row to stand on. *)
  press_dot "View_evolution"
    {
      m_dive with
      knowledge =
        Knowledge_store.set_memory_view_mode Knowledge_store.View_evolution
          {
            m_dive.knowledge with
            keeper_memory_subview = Knowledge_store.Kmem_diff_flow;
          };
    };
  (* 3 Knowledge > Memory: Health & Ledger and Context. *)
  let m_init =
    Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko
      ~wall_unix:1_700_000_500.0 ()
  in
  let knowledge =
    Knowledge_store.empty
    |> Knowledge_store.set_tab Nav.Knowledge_memory
    |> Knowledge_store.set_memory_diff_keeper (Some "alpha")
    |> Knowledge_store.set_keeper_memory_activity ~keeper:"alpha" no_events
    |> Knowledge_store.set_keeper_memory_facts ~keeper:"alpha"
         (obs (sample_facts ~keeper:"alpha"))
  in
  let m_knowledge, _ =
    Update_nav.switch_workspace { m_init with knowledge } Nav.Knowledge
  in
  List.iter
    (fun (label, subview) ->
      press_dot label
        {
          m_knowledge with
          knowledge = { m_knowledge.knowledge with memory_subview = subview };
        })
    [
      ("Mem_health_ledger", Knowledge_store.Mem_health_ledger);
      ("Mem_context", Knowledge_store.Mem_context);
    ];
  (* With a selected journal event the same subview opens that event. *)
  let m_health = model_in_keeper_memory_dive ~keeper:"alpha" in
  let m_health =
    {
      m_health with
      knowledge =
        {
          m_health.knowledge with
          keeper_memory_subview = Knowledge_store.Kmem_health;
        };
    }
  in
  let m_opened, _ =
    Update.step ~now:now0 m_health (Msg.Key_event (key_char "."))
  in
  check bool "Kmem_health with a selected event opens that event" true
    (match m_opened.knowledge.memory_diagram with
     | Some { source = Knowledge_store.Diagram_source_event "ev-1"; _ } -> true
     | Some _ | None -> false)

let () =
  run "masc_tui_v2_memory_diagram_wiring"
    [
      ( "memory_diagram_wiring",
        [
          test_case "Wire_knowledge -> Memory_lineage adapter & fallbacks" `Quick
            test_wire_to_lineage_adapter;
          test_case "PNG IHDR parser validation" `Quick test_png_ihdr_parser;
          test_case
            "Store/Update keybindings, request_id gating, scope safety & scroll bounds"
            `Quick test_store_diagram_keybindings_and_scope_safety;
          test_case "Cmd_executor Auto/Mermaid/Tree & Pele fallback decisions"
            `Quick test_cmd_executor_render_decisions;
          test_case
            "Kitty/iTerm2 graphics bounds, composer popup clear & lifecycle"
            `Quick test_graphics_overlay_lifecycle;
          test_case "TERM=dumb masks TERM_PROGRAM=iTerm.app everywhere" `Quick
            test_term_dumb_masks_term_program;
          test_case
            "Compact 4 Keepers, hidden tab non-hijack, 3->Memory Enter no-op, [r] retry & Resize relayout"
            `Quick test_visibility_enter_refresh_and_resize;
          test_case
            "All keeper-scoped subviews & orphan ordinary fact current-snapshot chart"
            `Quick test_all_subviews_and_orphan_fact_snapshot;
          test_case
            "'.' without a selected journal event opens no diagram"
            `Quick test_dot_without_selected_event_opens_nothing;
          test_case "Pele cooperative cancellation kills sleeping helper promptly"
            `Quick test_pele_cooperative_cancellation;
        ] );
    ]
