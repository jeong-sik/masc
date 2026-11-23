open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_store

let t0 = Clock.Mono.of_ns 1_000_000_000L
let t1 = Clock.Mono.of_ns 2_000_000_000L
let t2 = Clock.Mono.of_ns 3_000_000_000L

let key ?(ctrl = false) ?(alt = false) ?(shift = false) k :
    Keymap.Input.key_event =
  { key = k; mods = { ctrl; alt; shift } }

let char_key ?ctrl ?alt ?shift s = key ?ctrl ?alt ?shift (Keymap.Input.Char s)

let sample_keeper ?(health = Wire_fleet.Keeper_healthy) name :
    Wire_fleet.keeper_summary =
  {
    name;
    group = Some "core";
    company = "core";
    health;
    paused = false;
    keepalive_running = true;
    activation_mode = Wire_fleet.Activation_autonomous;
    runtime_id = "rt-1";
    model_id = Some "claude-opus";
    current_task_id = None;
    context =
      Observed.value ~observed_at:t0
        (Wire_fleet.Context_measured
           {
             ratio = Some 0.25;
             tokens = 50_000;
             window = Some 200_000;
             absolute_turn = Some 12;
             measured_at_unix = None;
           });
    total_turns = Observed.value ~observed_at:t0 12;
    last_turn_at_unix = Some 1_700_000_000.0;
    active_turn = None;
  }

let roster_of keepers : Wire_fleet.keepers_roster = { keepers; unreadable = [] }

let sample_health ?(instance = "inst-2") () : Wire_common.server_health =
  {
    ok = true;
    live = Some true;
    ready = Some true;
    phase = Some "ready";
    status = "ok";
    version = "0.77.1";
    binary_commit = Some "abc1234";
    uptime_display = Some "2h";
    uptime_sec = Some 7200.0;
    scope =
      Wire_common.Full_health
        {
          instance_id = Some instance;
          base_path = "/tmp/masc";
          masc_root = "/tmp/masc/.masc";
          workspace_sha256 = Some "sha-ws-2";
        };
    gc = None;
    active_keepers = Some 1;
  }

let sample_ask ?(id = "ask-1") ?(keeper = "alpha") () : Wire_work.ask_row =
  {
    ask_id = id;
    keeper;
    asked_at = 100.0;
    context = Some "Choose deployment lane";
    questions =
      [
        {
          question_id = "q1";
          header = "Lane";
          prompt = "Which lane?";
          mode = Wire_work.Ask_single;
          allow_free_text = false;
          free_text_hint = None;
          choices =
            [
              { choice_id = "c1"; label = "Fast"; description = None };
              { choice_id = "c2"; label = "Safe"; description = None };
            ];
        };
      ];
    resolution = Wire_work.Ask_open;
  }

let sample_tool_approval ?(id = "ap-1") ?(keeper = "alpha") () :
    Wire_work.held_tool_approval =
  {
    approval_id = id;
    tool_call_id = "tc-1";
    keeper;
    tool = "bash";
    args_preview = "rm -rf /tmp/scratch";
    question = "Allow bash?";
    because = None;
    asked_at = 90.0;
    timeout_sec = 300.0;
  }

let sample_goal ?(id = "g-1") ?(phase = Wire_work.Awaiting_confirmation) () :
    Wire_work.goal =
  {
    id;
    title = "Ship M2 Store";
    phase;
    priority = 1;
    due_date = None;
    measure = "All Alcotests pass";
    procedure = "Run dune exec";
    criterion_revision = Some "rev-1";
    criterion_verdict = Wire_work.Criterion_valid;
    last_review_note = None;
    last_review_at = None;
    created_at = None;
    updated_at = None;
    linked_task_count = Observed.value ~observed_at:t0 2;
  }

let has_get_health cmds =
  List.exists
    (function
      | Cmd.Http_get { req = Cmd.Get_health; _ } -> true
      | Cmd.Http_get
          {
            req =
              ( Cmd.Get_dashboard_shell
              | Cmd.Get_keepers_roster
              | Cmd.Get_keeper_turns
              | Cmd.Get_keeper_turn_records _
              | Cmd.Get_chat_history _
              | Cmd.Get_chat_operation_events _
              | Cmd.Get_planning
              | Cmd.Get_verifications _
              | Cmd.Get_schedules _
              | Cmd.Get_asks _
              | Cmd.Get_tool_approvals
              | Cmd.Get_gate_pending
              | Cmd.Get_candle_ledger _
              | Cmd.Get_board_feed _
              | Cmd.Get_board_hearths
              | Cmd.Get_board_thread _
              | Cmd.Get_wiki_index _
              | Cmd.Get_wiki_page _
              | Cmd.Get_wiki_log _
              | Cmd.Get_wiki_search _
              | Cmd.Get_wiki_lint
              | Cmd.Get_artifacts
              | Cmd.Get_artifact_detail _
              | Cmd.Get_artifact_checks
              | Cmd.Get_world_memory
              | Cmd.Get_memory_diff _
              | Cmd.Get_keeper_memory_os_internals _
              | Cmd.Get_keeper_memory_facts _
              | Cmd.Get_keeper_memory_activity _
              | Cmd.Get_keeper_memory_health
              | Cmd.Get_keeper_context_turn_records _
              | Cmd.Get_keeper_provider_input _
              | Cmd.Get_keeper_provider_input_part _
              | Cmd.Get_keeper_cache_outcome _
              | Cmd.Get_keeper_next_request _
              | Cmd.Get_keeper_turn_transcript _
              | Cmd.Get_keeper_tool_stats _
              | Cmd.Get_keeper_tool_calls _
              | Cmd.Get_keeper_tool_result _
              | Cmd.Get_provider_usage _
              | Cmd.Get_keeper_costs _
              | Cmd.Get_efficiency _
              | Cmd.Get_models_metrics _
              | Cmd.Get_runtime_metrics
              | Cmd.Get_runtime_resolved
              | Cmd.Get_runtime_config_raw
              | Cmd.Get_setup_inventory
              | Cmd.Get_setup_login_status _
              | Cmd.Get_runtime_probe _
              | Cmd.Get_exact_lane_runs _
              | Cmd.Get_fusion_runs
              | Cmd.Get_tool_series _
              | Cmd.Get_tool_series_filtered _
              | Cmd.Get_tools_catalog _
              | Cmd.Get_skills
              | Cmd.Get_connectors
              | Cmd.Get_browser_lane
              | Cmd.Get_lane_addons
              | Cmd.Get_mcp_clients
              | Cmd.Get_sandboxes
              | Cmd.Get_keeper_sandbox _
              | Cmd.Get_repositories
              | Cmd.Get_repository_activity _
              | Cmd.Get_system_logs _
              | Cmd.Get_tui_preferences
              | Cmd.Get_config_schema _ );
            _;
          }
      | Cmd.Batch _
      | Cmd.Http_post _
      | Cmd.Http_put _
      | Cmd.Http_post_stream _
      | Cmd.Sync_streams _
      | Cmd.Update_workspace_guard _
      | Cmd.Voice_cmd _
      | Cmd.Copy_clipboard _
      | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
      | Cmd.Open_editor_escape_hatch _
      | Cmd.Start_local_server
      | Cmd.Restart_tui
      | Cmd.Quit _ ->
          false)
    (Cmd.flatten cmds)

let has_sync_streams cmds =
  List.exists
    (function
      | Cmd.Sync_streams _ -> true
      | Cmd.Batch _
      | Cmd.Http_get _
      | Cmd.Http_post _
      | Cmd.Http_put _
      | Cmd.Http_post_stream _
      | Cmd.Update_workspace_guard _
      | Cmd.Voice_cmd _
      | Cmd.Copy_clipboard _
      | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
      | Cmd.Open_editor_escape_hatch _
      | Cmd.Start_local_server
      | Cmd.Restart_tui
      | Cmd.Quit _ ->
          false)
    (Cmd.flatten cmds)

let has_quit cmds =
  List.exists
    (function
      | Cmd.Quit _ -> true
      | Cmd.Batch _
      | Cmd.Http_get _
      | Cmd.Http_post _
      | Cmd.Http_put _
      | Cmd.Http_post_stream _
      | Cmd.Sync_streams _
      | Cmd.Update_workspace_guard _
      | Cmd.Voice_cmd _
      | Cmd.Copy_clipboard _
      | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
      | Cmd.Open_editor_escape_hatch _
      | Cmd.Start_local_server
      | Cmd.Restart_tui ->
          false)
    (Cmd.flatten cmds)

(* 1. Epoch stale-reply rejection *)
let test_epoch_stale_reply_rejection () =
  let m0 = Model.initial () in
  let old_epoch = m0.epoch in
  let new_epoch = Epoch.next old_epoch in
  let m1 = { m0 with epoch = new_epoch } in
  (* Late HTTP reply carrying old epoch must be dropped cleanly *)
  let m2, cmds2 =
    Update.step ~now:t1 m1
      (Msg.Http_reply
         {
           epoch = old_epoch;
           reply = Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "stale-k" ]));
         })
  in
  Alcotest.(check bool) "stale HTTP reply dropped" true
    (Option.is_none (Fleet_store.find_keeper ~name:"stale-k" m2.fleet));
  Alcotest.(check int) "stale HTTP emits 0 cmds" 0 (List.length cmds2);
  (* Late SSE delivery carrying old epoch must be dropped *)
  let m3, cmds3 =
    Update.step ~now:t1 m2
      (Msg.Sse_event
         {
           epoch = old_epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 77;
                 decoded = Wire_observer.Undecodable "late garbage";
               };
         })
  in
  Alcotest.(check int) "stale SSE creates 0 incidents" 0
    (Incidents.count m3.incidents);
  Alcotest.(check bool) "stale SSE keeps cursor None" true
    (Option.is_none m3.freshness.last_observer_cursor);
  Alcotest.(check int) "stale SSE emits 0 cmds" 0 (List.length cmds3);
  (* Current epoch reply is applied *)
  let m4, _ =
    Update.step ~now:t2 m3
      (Msg.Http_reply
         {
           epoch = new_epoch;
           reply = Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "live-k" ]));
         })
  in
  Alcotest.(check bool) "current epoch reply applied" true
    (Option.is_some (Fleet_store.find_keeper ~name:"live-k" m4.fleet))

(* 2. 3-channel state separation & Attention urgency/fast-path *)
let test_three_channel_separation () =
  let m0 = Model.initial () in
  let m1, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         {
           epoch = m0.epoch;
           reply =
             Msg.Reply_keepers_roster
               (Ok (roster_of [ sample_keeper ~health:Wire_fleet.Keeper_healthy "alpha" ]));
         })
  in
  (* Inject HTTP timeout, HTTP 500, Stream_gap, and historical Agent_failed *)
  let m2, _ =
    Update.step ~now:t1 m1
      (Msg.Http_reply
         {
           epoch = m1.epoch;
           reply =
             Msg.Reply_chat_history
               { keeper = "alpha"; result = Error (Msg.Transport Health.Timeout) };
         })
  in
  let m3, _ =
    Update.step ~now:t1 m2
      (Msg.Http_reply
         {
           epoch = m2.epoch;
           reply =
             Msg.Reply_dashboard_shell
               (Error
                  (Msg.Http_error
                     { status = 500; body = "boom"; api_error = None }));
         })
  in
  let m4, _ = Update.step ~now:t1 m3 (Msg.Stream_gap 5) in
  let m5, _ =
    Update.step ~now:t1 m4
      (Msg.Sse_event
         {
           epoch = m4.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 10;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Agent_core
                        {
                          kind =
                            Wire_observer.Agent_failed
                              {
                                elapsed_s = 1.2;
                                error_code = "rate_limit";
                                error = "429 retryable";
                              };
                          agent = Some "alpha";
                          tool = None;
                          task = None;
                          turn = Some 3;
                          tool_use_id = None;
                          at_unix = 100.0;
                          run_id = None;
                          execution_id = None;
                        });
               };
         })
  in
  (* Channel 3 captured all 4 historical incidents *)
  Alcotest.(check int) "4 incidents logged" 4 (Incidents.count m5.incidents);
  Alcotest.(check int) "stream gap counted in infra" 5 m5.infra.stream_gap_count;
  (* Channel 2 live health MUST remain Healthy! *)
  let alpha =
    match Fleet_store.find_keeper ~name:"alpha" m5.fleet with
    | Some k -> k
    | None -> Alcotest.fail "alpha missing"
  in
  Alcotest.(check bool) "live keeper stays Healthy" true
    (Health.equal_live_state (Fleet_store.keeper_live_state alpha) Health.Healthy);
  (* Bounded cap 200 on Channel 3 incidents *)
  let inc_capped =
    let rec push_n n st =
      if n <= 0 then st
      else
        let st', _ =
          Incidents.push ~occurred_at_unix:(float_of_int n)
            ~source:Health.Source_client_http
            ~summary:(Say.literal "err") ~detail:"d" ~status:Health.Resolved st
        in
        push_n (n - 1) st'
    in
    push_n 250 m5.incidents
  in
  Alcotest.(check int) "incidents bounded to 200" Incidents.max_entries
    (Incidents.count inc_capped);
  (* Channel 1 Attention urgency ordering & fast-path strip *)
  let m7, _ =
    Update.step ~now:t1 m5
      (Msg.Http_reply
         {
           epoch = m5.epoch;
           reply =
             Msg.Reply_planning
               (Ok { goals = [ sample_goal () ]; tasks = [] });
         })
  in
  let m8, _ =
    Update.step ~now:t1 m7
      (Msg.Http_reply
         { epoch = m7.epoch; reply = Msg.Reply_asks (Ok [ sample_ask () ]) })
  in
  let m9, _ =
    Update.step ~now:t1 m8
      (Msg.Http_reply
         {
           epoch = m8.epoch;
           reply = Msg.Reply_tool_approvals (Ok [ sample_tool_approval () ]);
         })
  in
  Alcotest.(check int) "3 attention items" 3 (Attention.count m9.attention);
  let top =
    match Model.fast_approval_strip_item m9 with
    | Some e -> e
    | None -> Alcotest.fail "expected top fast-path item"
  in
  Alcotest.(check string) "tool approval has highest urgency" "tool:ap-1" top.id;
  (* Fast-approve emits Post_tool_approval and advances strip to Ask *)
  let m10, cmds10 = Update.execute_action ~now:t2 m9 Keymap.Fast_approve_top in
  let approved_sent =
    List.exists
      (function
        | Cmd.Http_post { req; _ } ->
            String.equal (Cmd.post_request_path req)
              Wire_work.keeper_tool_approval_path
        | Cmd.Batch _
        | Cmd.Http_get _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            false)
      cmds10
  in
  Alcotest.(check bool) "fast approve sent Post_tool_approval" true approved_sent;
  let next_top =
    match Model.fast_approval_strip_item m10 with
    | Some e -> e.id
    | None -> ""
  in
  Alcotest.(check string) "next fast-path item is ask:ask-1" "ask:ask-1" next_top;
  (* Rapid 1-key Ask triage choice 1 *)
  let m11, cmds11 =
    Update.execute_action ~now:t2 m10 (Keymap.Ask_select_choice 1)
  in
  let ask_answered =
    List.exists
      (function
        | Cmd.Http_post { req; _ } ->
            String.equal (Cmd.post_request_path req)
              Wire_work.keeper_ask_answer_path
        | Cmd.Batch _
        | Cmd.Http_get _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            false)
      cmds11
  in
  Alcotest.(check bool) "1-key ask triage emits Post_ask_answer" true ask_answered;
  (* Honest in-flight: item remains in queue until server ack, while strip skips it *)
  Alcotest.(check bool) "ask marked in-flight before ack" true
    (Attention.is_in_flight ~id:"ask:ask-1" m11.attention);
  Alcotest.(check int) "ask not optimistically dropped" 3
    (Attention.count m11.attention);
  (* Failure restores actionable state without dropping item *)
  let m11_fail, _ =
    Update.step ~now:t2 m11
      (Msg.Http_reply
         {
           epoch = m11.epoch;
           reply =
             Msg.Reply_work_mutation
               {
                 label = Say.literal "Ask answer";
                 attention_id = Some "ask:ask-1";
                 decision_kind = Some Work_store.Decision_ask_answered;
                 target_id = Some "ask-1";
                 keeper = Some "alpha";
                 result = Error (Msg.Transport Health.Timeout);
               };
         })
  in
  Alcotest.(check bool) "failed ask answer clears in-flight" false
    (Attention.is_in_flight ~id:"ask:ask-1" m11_fail.attention);
  (* Server ack removes item and records recent 24h decision *)
  let m12, _ =
    Update.step ~now:t2 m11
      (Msg.Http_reply
         {
           epoch = m11.epoch;
           reply =
             Msg.Reply_work_mutation
               {
                 label = Say.literal "Ask answered";
                 attention_id = Some "ask:ask-1";
                 decision_kind = Some Work_store.Decision_ask_answered;
                 target_id = Some "ask-1";
                 keeper = Some "alpha";
                 result = Ok ();
               };
         })
  in
  Alcotest.(check int) "ask removed on server ack" 2
    (Attention.count m12.attention);
  Alcotest.(check int) "recent 24h decision recorded" 1
    (List.length m12.work.recent_decisions_24h);
  (* The fast approval of tool:ap-1 is still in flight. Its answer decides
     whether the item is resolved. *)
  let tool_reply outcome =
    Msg.Http_reply
      {
        epoch = m12.epoch;
        reply =
          Msg.Reply_tool_approval
            {
              keeper = "alpha";
              approval_id = "ap-1";
              attention_id = "tool:ap-1";
              decision = Wire_work.Tool_approve;
              result = Ok outcome;
            };
      }
  in
  let m_unclaimed, cmds_unclaimed =
    Update.step ~now:t2 m12 (tool_reply Wire_work.Tool_approval_no_waiting_call)
  in
  Alcotest.(check bool) "an approval no call took is no longer in flight" false
    (Attention.is_in_flight ~id:"tool:ap-1" m_unclaimed.attention);
  Alcotest.(check int) "an approval no call took keeps the item" 2
    (Attention.count m_unclaimed.attention);
  Alcotest.(check int) "an approval no call took records no decision" 1
    (List.length m_unclaimed.work.recent_decisions_24h);
  Alcotest.(check bool) "an approval no call took reads the held approvals again"
    true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_tool_approvals; _ } -> true
         | _ -> false)
       cmds_unclaimed);
  let m_settled, _ =
    Update.step ~now:t2 m12 (tool_reply Wire_work.Tool_approval_settled)
  in
  Alcotest.(check int) "a settled approval resolves the item" 1
    (Attention.count m_settled.attention);
  Alcotest.(check int) "a settled approval records the decision" 2
    (List.length m_settled.work.recent_decisions_24h);
  let m_remembered, _ =
    Update.step ~now:t2 m12 (tool_reply Wire_work.Tool_approval_remembered)
  in
  Alcotest.(check int) "a remembered approval resolves the item" 1
    (Attention.count m_remembered.attention);
  Alcotest.(check int) "a remembered approval records the decision" 2
    (List.length m_remembered.work.recent_decisions_24h)

(* 3. Compact composer auto-fold, draft preservation & transmission lifecycle *)
let test_compact_composer_and_drafts () =
  let m0 = Model.initial ~cols:90 ~rows:28 () in
  Alcotest.(check bool) "90x28 is Compact" true
    (Model.equal_breakpoint m0.breakpoint Model.Compact);
  Alcotest.(check bool) "Compact idle+empty folds" true
    (Model.equal_composer_mode (Model.composer_mode m0) Model.Auto_folded_pill);
  (* Focus composer -> expands *)
  let m1, _ = Update.execute_action ~now:t0 m0 Keymap.Focus_composer in
  Alcotest.(check bool) "focused composer expands" true
    (Model.equal_composer_mode (Model.composer_mode m1) Model.Expanded_multiline);
  (* Type draft then unfocus -> stays visible (Collapsed_bar) *)
  let m2 = { m1 with drafts = Drafts.set_active_keeper "alpha" m1.drafts } in
  let m3, _ = Update.step ~now:t0 m2 (Msg.Key_event (char_key "h")) in
  let m4, _ = Update.step ~now:t0 m3 (Msg.Key_event (char_key "i")) in
  let m5, _ = Update.execute_action ~now:t0 m4 Keymap.Pop_back_or_close in
  Alcotest.(check bool) "non-empty unfocused draft stays visible at 90x28" true
    (Model.equal_composer_mode (Model.composer_mode m5) Model.Collapsed_bar);
  (* Draft survives switching Pulse -> Work -> Keepers *)
  let m6, _ = Update.execute_action ~now:t0 m5 (Keymap.Switch_workspace Nav.Work) in
  let m7, _ =
    Update.execute_action ~now:t0 m6 (Keymap.Switch_workspace Nav.Keepers)
  in
  Alcotest.(check string) "draft survived Pulse -> Work -> Keepers" "hi"
    (Drafts.draft_for ~keeper:"alpha" m7.drafts).text;
  (* Clear draft -> folds again on Keepers fleet list *)
  let m8 = { m7 with drafts = Drafts.clear_current_draft m7.drafts } in
  Alcotest.(check bool) "cleared draft folds on Keepers roster" true
    (Model.equal_composer_mode (Model.composer_mode m8) Model.Auto_folded_pill);
  (* Active voice keeps composer visible *)
  let m9, _ = Update.step ~now:t0 m8 (Msg.Voice_event Msg.Voice_started) in
  Alcotest.(check bool) "active voice stays visible at 90x28" true
    (Model.equal_composer_mode (Model.composer_mode m9) Model.Expanded_multiline);
  let m10, _ = Update.step ~now:t0 m9 (Msg.Voice_event Msg.Voice_idle) in
  Alcotest.(check bool) "voice off folds again" true
    (Model.equal_composer_mode (Model.composer_mode m10) Model.Auto_folded_pill);
  (* Entering Keepers > Chat keeps composer visible even when idle+empty *)
  let m11, _ =
    Update.execute_slash ~now:t0 m10 (Slash.Keeper (Some "alpha"))
  in
  Alcotest.(check bool) "Keepers > Chat stays visible at 90x28" true
    (Model.equal_composer_mode (Model.composer_mode m11) Model.Collapsed_bar);
  (* Micro viewport protects hidden draft from typing & paste *)
  let m12 = { m11 with drafts = Drafts.insert_text "keep" m11.drafts } in
  let m13, _ = Update.step ~now:t0 m12 (Msg.Resize { cols = 30; rows = 10 }) in
  let m14, _ = Update.step ~now:t0 m13 (Msg.Key_event (char_key "x")) in
  let m15, _ = Update.step ~now:t0 m14 (Msg.Paste_text "pasted") in
  Alcotest.(check string) "micro viewport preserves draft untouched" "keep"
    (Drafts.draft_for ~keeper:"alpha" m15.drafts).text;
  (* Typing before any keeper selected cannot POST to synthetic _default *)
  let m_nokeep = Model.initial () in
  let m_nokeep = { m_nokeep with drafts = Drafts.insert_text "early" m_nokeep.drafts } in
  let m_nokeep2, cmds_nokeep =
    Update.execute_action ~now:t0 m_nokeep Keymap.Submit_followup
  in
  Alcotest.(check int) "no-keeper submit emits 0 cmds" 0
    (List.length cmds_nokeep);
  Alcotest.(check string) "draft preserved when no keeper selected" "early"
    (Drafts.current_draft m_nokeep2.drafts).text;
  (* Once roster loads, early draft migrates seamlessly to active keeper *)
  let m_migrated, _ =
    Update.step ~now:t0 m_nokeep2
      (Msg.Http_reply
         {
           epoch = m_nokeep2.epoch;
           reply = Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "alpha" ]));
         })
  in
  Alcotest.(check string) "early draft migrated to alpha" "early"
    (Drafts.draft_for ~keeper:"alpha" m_migrated.drafts).text;
  (* Honest pending transmission lifecycle: Sending -> Pending_processing -> Confirming -> Delivered *)
  let m16, _ = Update.step ~now:t0 m15 (Msg.Resize { cols = 90; rows = 28 }) in
  let m17, cmds17 = Update.execute_action ~now:t0 m16 Keymap.Submit_followup in
  Alcotest.(check int) "chat stream command emitted" 1 (List.length cmds17);
  let tx_id =
    match Drafts.active_tx_for_keeper ~keeper:"alpha" m17.drafts with
    | Some tx ->
        Alcotest.(check bool) "tx starts in Sending" true
          (Drafts.equal_tx_state tx.state Drafts.Sending);
        tx.request_id
    | None -> Alcotest.fail "missing active tx"
  in
  let m18, _ =
    Update.step ~now:t1 m17
      (Msg.Chat_stream_chunk
         {
           epoch = m17.epoch;
           keeper = "alpha";
           request_id = tx_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_accepted
               {
                 operation_id = "op-1";
                 queued_count = 0;
                 state = Wire_fleet.Accepted_running;
                 interactive_outcome = None;
                 control_token = None;
               };
         })
  in
  let st_after_accept =
    match Drafts.active_tx_for_keeper ~keeper:"alpha" m18.drafts with
    | Some tx -> tx.state
    | None -> Alcotest.fail "missing tx after accept"
  in
  Alcotest.(check bool) "accepted transitions to Pending_processing" true
    (Drafts.equal_tx_state st_after_accept Drafts.Pending_processing);
  let m19, _ =
    Update.step ~now:t1 m18
      (Msg.Chat_stream_chunk
         {
           epoch = m18.epoch;
           keeper = "alpha";
           request_id = tx_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_turn_done
               {
                 operation_id = Some "op-1";
                 turn_ref = Some "t-1";
                 reply = Some "ok";
               };
         })
  in
  let st_after_done =
    match Drafts.active_tx_for_keeper ~keeper:"alpha" m19.drafts with
    | Some tx -> tx.state
    | None -> Alcotest.fail "missing tx after turn done"
  in
  Alcotest.(check bool) "turn done transitions to Confirming_delivery" true
    (Drafts.equal_tx_state st_after_done Drafts.Confirming_delivery);
  let m20, _ =
    Update.step ~now:t2 m19
      (Msg.Http_reply
         {
           epoch = m19.epoch;
           reply =
             Msg.Reply_chat_history
               {
                 keeper = "alpha";
                 result =
                   Ok
                     {
                       messages =
                         [
                           {
                             id = "m-1";
                             role = Wire_fleet.Role_user;
                             content = "keep";
                             ts_unix = 100.0;
                             turn_ref = None;
                             model_used = None;
                             tool_call_id = None;
                             tool_call_name = None;
                             execution_id = None;
                             operation_id = None;
                             transcript_slot = None;
                             failure_kind = None;
                           };
                         ];
                       has_more = false;
                       next_cursor = None;
                     };
               };
         })
  in
  Alcotest.(check bool) "persisted history confirms delivery" false
    (Drafts.has_active_tx_for ~keeper:"alpha" m20.drafts)

(* A new epoch may face another server process, whose log seqs start from
   zero again; the next log stream must open without the old cursor. *)
let test_new_epoch_forgets_log_cursor () =
  let m0 = Model.initial () in
  let m1 =
    { m0 with infra = { m0.infra with Infra_store.last_log_seq = Some 50 } }
  in
  let m2, _ = Update.step ~now:t1 m1 (Msg.Tick { wall_unix = 2.0 }) in
  Alcotest.(check (option int)) "a step that keeps the epoch keeps the cursor"
    (Some 50) m2.infra.Infra_store.last_log_seq;
  let m3, _ = Update.step ~now:t2 m2 (Msg.Server_start_result (Ok ())) in
  Alcotest.(check bool) "starting the server moved the epoch" false
    (Epoch.equal m2.epoch m3.epoch);
  Alcotest.(check (option int)) "the new epoch drops the cursor" None
    m3.infra.Infra_store.last_log_seq

(* Chat stream frames carry the epoch they were sent in, so a new epoch drops
   them. Each open request then waits for the history, the way a stream that
   closed without a terminal does, and an unanswered /btw fails. *)
let test_new_epoch_detaches_chat_streams () =
  let m0 = Model.initial () in
  let typed =
    m0.drafts |> Drafts.set_active_keeper "alpha" |> Drafts.insert_text "hello"
  in
  let drafts, request_id =
    match
      Drafts.enqueue_submission ~now:t0 ~keeper:"alpha"
        ~mode:Drafts.Mode_follow_up typed
    with
    | Some (d, tx) ->
        ( d
          |> Drafts.mark_sending ~now:t0 ~request_id:tx.request_id
          |> Drafts.mark_accepted ~now:t0 ~request_id:tx.request_id
               ~operation_id:(Some "op-1")
        , tx.request_id )
    | None -> Alcotest.fail "expected a pending transmission"
  in
  let drafts, _btw_request =
    Drafts.start_btw ~now:t0 ~keeper:"alpha" ~prompt:"side question" drafts
  in
  let fleet = Fleet_store.start_chat_stream ~keeper:"alpha" ~request_id m0.fleet in
  let m1 = { m0 with drafts; fleet } in
  let m2, _ = Update.step ~now:t1 m1 (Msg.Tick { wall_unix = 2.0 }) in
  Alcotest.(check bool) "a step that keeps the epoch keeps the stream" true
    (Fleet_store.has_active_chat_stream ~keeper:"alpha" m2.fleet);
  let m3, _ = Update.step ~now:t2 m2 (Msg.Server_start_result (Ok ())) in
  Alcotest.(check bool) "the buffer stops streaming" false
    (Fleet_store.has_active_chat_stream ~keeper:"alpha" m3.fleet);
  Alcotest.(check bool) "the request waits for the history" true
    (match m3.drafts.Drafts.pending_txs with
    | [ { Drafts.state = Drafts.Confirming_delivery; _ } ] -> true
    | _ -> false);
  Alcotest.(check bool) "the unanswered /btw fails" true
    (match m3.drafts.Drafts.btw with Drafts.Btw_failed _ -> true | _ -> false)

(* A reattach POST that reaches a restarted server comes back 409. The old
   instance had accepted the request, so it waits for the history; a request
   refused on its first POST was never accepted and fails. *)
let test_chat_stream_409_from_another_instance () =
  let m0 = Model.initial () in
  let mismatch =
    Msg.Workspace_mismatch
      {
        expected_instance = Some "inst-1";
        observed_instance = Some "inst-2";
        observed_workspace_sha256 = Some "ws-sha";
        message = "server restarted";
      }
  in
  let submitted ~accepted =
    let typed =
      m0.drafts |> Drafts.set_active_keeper "alpha" |> Drafts.insert_text "hello"
    in
    match
      Drafts.enqueue_submission ~now:t0 ~keeper:"alpha"
        ~mode:Drafts.Mode_follow_up typed
    with
    | Some (d, tx) ->
        let sent = Drafts.mark_sending ~now:t0 ~request_id:tx.request_id d in
        let drafts =
          if accepted then
            Drafts.mark_accepted ~now:t0 ~request_id:tx.request_id
              ~operation_id:(Some "op-1") sent
          else sent
        in
        let fleet =
          Fleet_store.start_chat_stream ~keeper:"alpha"
            ~request_id:tx.request_id m0.fleet
        in
        let m, _ =
          Update.step ~now:t1
            { m0 with drafts; fleet }
            (Msg.Chat_stream_done
               {
                 epoch = m0.epoch;
                 keeper = "alpha";
                 request_id = tx.request_id;
                 is_btw = false;
                 result = Error mismatch;
               })
        in
        m
    | None -> Alcotest.fail "expected a pending transmission"
  in
  let m1 = submitted ~accepted:true in
  Alcotest.(check bool) "the 409 moves the epoch" false
    (Epoch.equal m0.epoch m1.epoch);
  Alcotest.(check bool) "the buffer stops streaming" false
    (Fleet_store.has_active_chat_stream ~keeper:"alpha" m1.fleet);
  Alcotest.(check bool) "the accepted request waits for the history" true
    (match m1.drafts.Drafts.pending_txs with
    | [ { Drafts.state = Drafts.Confirming_delivery; _ } ] -> true
    | _ -> false);
  let m2 = submitted ~accepted:false in
  Alcotest.(check bool) "a request refused on its first POST fails" true
    (match m2.drafts.Drafts.pending_txs with
    | [ { Drafts.state = Drafts.Failed_retryable _; _ } ] -> true
    | _ -> false)

(* 4. 409 workspace_mismatch recovery without loop *)
let test_workspace_mismatch_recovery () =
  let m0 = Model.initial () in
  let e1 = m0.epoch in
  let mismatch =
    Msg.Workspace_mismatch
      {
        expected_instance = Some "inst-1";
        observed_instance = Some "inst-2";
        observed_workspace_sha256 = Some "sha-2";
        message = "server restarted on another workspace";
      }
  in
  let m1, cmds1 =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         { epoch = e1; reply = Msg.Reply_dashboard_shell (Error mismatch) })
  in
  let e2 = m1.epoch in
  Alcotest.(check bool) "epoch bumped on 409" true (not (Epoch.equal e1 e2));
  Alcotest.(check bool) "mismatch_state is Mismatch_recovering" true
    (Model.equal_mismatch_state m1.server_identity.mismatch_state
       Model.Mismatch_recovering);
  Alcotest.(check bool) "re-handshake Get_health emitted" true
    (has_get_health cmds1);
  (* Parallel stale 409 from old epoch e1 is ignored cleanly *)
  let m2, cmds2 =
    Update.step ~now:t0 m1
      (Msg.Http_reply
         { epoch = e1; reply = Msg.Reply_keepers_roster (Error mismatch) })
  in
  Alcotest.(check bool) "stale parallel 409 did not bump epoch" true
    (Epoch.equal m2.epoch e2);
  Alcotest.(check int) "stale parallel 409 emitted 0 cmds" 0 (List.length cmds2);
  (* Repeated 409 on the re-handshake itself must halt cleanly with 0 streams *)
  let m_loop, cmds_loop =
    Update.step ~now:t1 m2
      (Msg.Server_health_result { epoch = e2; result = Error mismatch })
  in
  Alcotest.(check bool) "anti-loop stops further Get_health" false
    (has_get_health cmds_loop);
  Alcotest.(check bool) "anti-loop does not reconnect streams" false
    (has_sync_streams cmds_loop);
  Alcotest.(check int) "halted mismatch plan is empty" 0
    (List.length (Subscriptions.plan m_loop));
  Alcotest.(check bool) "mismatch_state is Mismatch_halted" true
    (Model.equal_mismatch_state m_loop.server_identity.mismatch_state
       Model.Mismatch_halted);
  (* Operator Refresh (r) from Mismatch_halted bumps epoch and retries Get_health *)
  let m_retry, cmds_retry =
    Update.execute_action ~now:t2 m_loop Keymap.Refresh
  in
  Alcotest.(check bool) "Refresh while halted bumps epoch" true
    (not (Epoch.equal m_loop.epoch m_retry.epoch));
  Alcotest.(check bool) "Refresh while halted emits Get_health" true
    (has_get_health cmds_retry);
  Alcotest.(check bool) "Refresh while halted enters Mismatch_recovering" true
    (Model.equal_mismatch_state m_retry.server_identity.mismatch_state
       Model.Mismatch_recovering);
  (* Normal recovery from m2 via healthy /health reply *)
  let m3, cmds3 =
    Update.step ~now:t1 m2
      (Msg.Server_health_result { epoch = e2; result = Ok (sample_health ()) })
  in
  Alcotest.(check bool) "mismatch_state cleared to Mismatch_none" true
    (Model.equal_mismatch_state m3.server_identity.mismatch_state
       Model.Mismatch_none);
  Alcotest.(check bool) "Sync_streams emitted on recovery" true
    (has_sync_streams cmds3);
  let guard_updated =
    List.exists
      (function
        | Cmd.Update_workspace_guard { instance_id = Some "inst-2"; _ } -> true
        | Cmd.Update_workspace_guard { instance_id = Some _ | None; _ }
        | Cmd.Batch _
        | Cmd.Http_get _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            false)
      cmds3
  in
  Alcotest.(check bool) "workspace guard updated" true guard_updated

(* 5. Subscriptions.plan bounded across all 6 workspaces + zero idle polling *)
let test_subscriptions_bounded_and_zero_polling () =
  let base = Model.initial () in
  let check_plan label m ~expected_view =
    let plan = Subscriptions.plan m in
    let persistent = List.filter Subscriptions.is_persistent plan in
    let view_scoped =
      List.filter (fun s -> not (Subscriptions.is_persistent s)) plan
    in
    Alcotest.(check bool) (label ^ ": total <= 3") true
      (List.length plan <= Subscriptions.max_streams);
    Alcotest.(check int) (label ^ ": 2 persistent") 2 (List.length persistent);
    Alcotest.(check int) (label ^ ": expected view-scoped count") expected_view
      (List.length view_scoped)
  in
  check_plan "Pulse" base ~expected_view:0;
  List.iter
    (fun tab ->
      let m =
        {
          base with
          nav = { base.nav with workspace = Nav.Work };
          work = Work_store.set_tab tab base.work;
        }
      in
      check_plan "Work" m ~expected_view:0)
    Nav.all_work_tabs;
  List.iter
    (fun tab ->
      let m =
        {
          base with
          nav = { base.nav with workspace = Nav.Knowledge };
          knowledge = Knowledge_store.set_tab tab base.knowledge;
        }
      in
      check_plan "Knowledge" m ~expected_view:0)
    Nav.all_knowledge_tabs;
  List.iter
    (fun mode ->
      let m =
        {
          base with
          nav = { base.nav with workspace = Nav.Keepers };
          fleet = Fleet_store.set_fleet_mode mode base.fleet;
        }
      in
      check_plan "Keepers" m ~expected_view:0)
    Nav.all_keepers_fleet_modes;
  List.iter
    (fun tab ->
      let m =
        {
          base with
          nav = { base.nav with workspace = Nav.Runtime };
          runtime = Runtime_store.set_tab tab base.runtime;
        }
      in
      let expected_view =
        match tab with
        | Nav.Runtime_quotas_credits
        | Nav.Runtime_failover_lanes
        | Nav.Runtime_fusion
        | Nav.Runtime_connectors
        | Nav.Runtime_addons_browser ->
            0
        | Nav.Runtime_efficiency_spend | Nav.Runtime_tools_usage -> 1
      in
      check_plan "Runtime" m ~expected_view)
    Nav.all_runtime_tabs;
  List.iter
    (fun tab ->
      let m =
        {
          base with
          nav = { base.nav with workspace = Nav.Infra };
          infra = Infra_store.set_tab tab base.infra;
        }
      in
      let expected_view =
        match tab with
        | Nav.Infra_sandboxes | Nav.Infra_repos_changes -> 0
        | Nav.Infra_activity_logs -> 1
      in
      check_plan "Infra" m ~expected_view)
    Nav.all_infra_tabs;
  (* Tick emits ZERO commands (no idle polling) *)
  let _, tick_cmds = Update.step ~now:t2 base (Msg.Tick { wall_unix = 200.0 }) in
  Alcotest.(check int) "Tick emits 0 commands" 0 (List.length tick_cmds);
  (* A log frame on Infra_activity_logs emits 0 commands (no reconnect storm) *)
  let m_logs =
    {
      base with
      nav = { base.nav with workspace = Nav.Infra };
      infra = Infra_store.set_tab Nav.Infra_activity_logs base.infra;
    }
  in
  let log_entry : Wire_infra.system_log_entry =
    {
      seq = 42;
      ts = "2026-11-22T04:00:00Z";
      level = Wire_infra.Log_info;
      source = "server";
      module_name = "keeper";
      message = "heartbeat ok";
      keeper = Some "alpha";
      turn_id = Some 1;
      category = None;
      details = `Null;
    }
  in
  let m_logs2, log_cmds =
    Update.step ~now:t2 m_logs
      (Msg.Sse_event
         {
           epoch = m_logs.epoch;
           event = Msg.Sse_log_frame { reset = false; entries = [ log_entry ] };
         })
  in
  Alcotest.(check (option int)) "last_log_seq advanced" (Some 42)
    m_logs2.infra.last_log_seq;
  Alcotest.(check int) "log frame emits 0 commands (no Sync_streams storm)" 0
    (List.length log_cmds);
  (* After a server restart the ring numbers from zero again. The stream's
     reset frame replaces the list and the cursor; a new line whose seq an
     old line had is kept. *)
  let restarted_entry = { log_entry with seq = 1; message = "server started" } in
  let m_logs3, _ =
    Update.step ~now:t2 m_logs2
      (Msg.Sse_event
         {
           epoch = m_logs2.epoch;
           event = Msg.Sse_log_frame { reset = true; entries = [ restarted_entry ] };
         })
  in
  Alcotest.(check (option int)) "reset frame replaces the cursor" (Some 1)
    m_logs3.infra.last_log_seq;
  Alcotest.(check (list int)) "reset frame replaces the list" [ 1 ]
    (List.map (fun (e : Wire_infra.system_log_entry) -> e.seq) m_logs3.infra.logs);
  let m_logs4, _ =
    Update.step ~now:t2 m_logs3
      (Msg.Sse_event
         {
           epoch = m_logs3.epoch;
           event =
             Msg.Sse_log_frame
               { reset = false; entries = [ { log_entry with seq = 2 } ] };
         })
  in
  Alcotest.(check (list int)) "next frame appends after the reset" [ 2; 1 ]
    (List.map (fun (e : Wire_infra.system_log_entry) -> e.seq) m_logs4.infra.logs)

(* 6. Keymap actions & all 22 Slash commands *)
let test_keymap_and_slash_commands () =
  let m0 = Model.initial () in
  (* 1..6 switch workspaces *)
  let m_work, _ = Update.step ~now:t0 m0 (Msg.Key_event (char_key "2")) in
  Alcotest.(check bool) "'2' switches to Work" true
    (Nav.equal_workspace m_work.nav.workspace Nav.Work);
  (* ] and [ cycle sub-tabs *)
  let m_tab2, _ = Update.step ~now:t0 m_work (Msg.Key_event (char_key "]")) in
  Alcotest.(check bool) "']' advances Work tab" true
    (Nav.equal_work_tab m_tab2.work.active_tab Nav.Work_tasks);
  let m_tab1, _ = Update.step ~now:t0 m_tab2 (Msg.Key_event (char_key "[")) in
  Alcotest.(check bool) "'[' goes back to Pipeline" true
    (Nav.equal_work_tab m_tab1.work.active_tab Nav.Work_pipeline);
  (* Switching into Infra > Activity & Logs emits Sync_streams *)
  let m_infra, _ = Update.step ~now:t0 m_tab1 (Msg.Key_event (char_key "6")) in
  let m_infra2, _ = Update.step ~now:t0 m_infra (Msg.Key_event (char_key "]")) in
  let m_logs, cmds_logs =
    Update.step ~now:t0 m_infra2 (Msg.Key_event (char_key "]"))
  in
  Alcotest.(check bool) "Infra > Logs emits Sync_streams" true
    (has_sync_streams cmds_logs);
  (* Ctrl+K opens Palette, Esc closes it *)
  let m_pal, _ =
    Update.step ~now:t0 m_logs (Msg.Key_event (char_key ~ctrl:true "k"))
  in
  Alcotest.(check bool) "Ctrl+K opens Palette" true
    (Option.equal Nav.equal_overlay m_pal.nav.overlay (Some Nav.Palette));
  let m_closed, cmds_esc =
    Update.step ~now:t0 m_pal (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc closes Palette" true
    (Option.is_none m_closed.nav.overlay);
  Alcotest.(check bool) "Esc never quits" false (has_quit cmds_esc);
  (* ',' opens Settings *)
  let m_set, _ = Update.step ~now:t0 m_closed (Msg.Key_event (char_key ",")) in
  Alcotest.(check bool) "',' opens Settings" true
    (Option.equal Nav.equal_overlay m_set.nav.overlay
       (Some (Nav.Settings Nav.Settings_general_ui)));
  let m_set_closed, _ =
    Update.step ~now:t0 m_set (Msg.Key_event (key Keymap.Input.Escape))
  in
  (* 'I' opens Incidents *)
  let m_inc, _ =
    Update.step ~now:t0 m_set_closed (Msg.Key_event (char_key ~shift:true "I"))
  in
  Alcotest.(check bool) "'I' opens Incidents" true
    (Option.equal Nav.equal_overlay m_inc.nav.overlay (Some Nav.Incidents));
  let m_inc_closed, _ =
    Update.step ~now:t0 m_inc (Msg.Key_event (key Keymap.Input.Escape))
  in
  (* Enter dives into Keeper and Esc pops back *)
  let m_k, _ =
    Update.step ~now:t0 m_inc_closed
      (Msg.Http_reply
         {
           epoch = m_inc_closed.epoch;
           reply = Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "alpha" ]));
         })
  in
  let m_k4, _ = Update.step ~now:t0 m_k (Msg.Key_event (char_key "4")) in
  let m_dive, _ =
    Update.step ~now:t0 m_k4 (Msg.Key_event (key Keymap.Input.Enter))
  in
  Alcotest.(check bool) "Enter pushed Dive_keeper" true
    (Option.is_some (Model.active_dive m_dive));
  let m_popped, _ =
    Update.step ~now:t0 m_dive (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc popped Dive_keeper" true
    (Option.is_none (Model.active_dive m_popped));
  (* Slash commands: exercise all 22 *)
  let slash_cases =
    [
      "/pulse";
      "/work";
      "/knowledge";
      "/keepers";
      "/runtime";
      "/infra";
      "/keeper alpha";
      "/model";
      "/config timeout";
      "/incidents";
      "/jump";
      "/voice";
      "/btw quick check";
      "/queue";
      "/context";
      "/tools full";
      "/clear";
      "/theme mono";
      "/lang en";
      "/help";
      "/restart";
      "/quit";
    ]
  in
  List.iter
    (fun raw ->
      match Slash.parse raw with
      | Error _ -> Alcotest.fail ("failed to parse slash command: " ^ raw)
      | Ok parsed ->
          let m_after, cmds = Update.execute_slash ~now:t1 m_popped parsed in
          if String.equal raw "/quit" then
            Alcotest.(check bool) "/quit emits Quit" true (has_quit cmds);
          if String.equal raw "/lang en" then
            Alcotest.(check bool) "/lang en sets Lang_en" true
              (Say.equal_lang m_after.lang Say.Lang_en);
          if String.equal raw "/theme mono" then
            Alcotest.(check bool) "/theme mono sets Mono" true
              (Theme.equal_preset m_after.theme_preset Theme.Mono);
          if String.equal raw "/tools full" then
            Alcotest.(check bool) "/tools full sets Tools_full" true
              (Slash.equal_tools_mode m_after.fleet.chat_tools_mode
                 Slash.Tools_full))
    slash_cases

(* 7. Knowledge defaults & Config strict inline editing *)
let test_knowledge_and_config_store () =
  let m0 = Model.initial () in
  Alcotest.(check bool) "Board defaults to signal_only=true" true
    m0.knowledge.board_signal_only;
  let schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "abcsha";
      sections =
        [
          {
            id = "providers";
            category = Wire_config.Cat_providers_models;
            title = "Providers";
            fields =
              [
                {
                  table = "providers";
                  key = "timeout_sec";
                  full_key = "providers.timeout_sec";
                  label = "Timeout (s)";
                  env = None;
                  description = Some "HTTP timeout";
                  kind = Wire_config.Field_int { min = Some 1; max = Some 600 };
                  value = Wire_config.Val_int 30;
                  default_value = Some (Wire_config.Val_int 30);
                  provenance = Wire_config.Prov_default;
                  reload_scope = Wire_config.Hot_reload;
                  secret = false;
                  writable = true;
                };
              ];
          };
        ];
    }
  in
  let cfg =
    Config_store.empty
    |> Config_store.set_tab Nav.Settings_providers_models
    |> Config_store.apply_schema ~observed_at:t0 schema
  in
  let cfg_ed =
    match Config_store.begin_edit_selected cfg with
    | Ok c -> c
    | Error e -> Alcotest.fail e
  in
  (* Strict parse rejects non-integer and out-of-range *)
  let bad1 = Config_store.update_edit_buffer "not-an-int" cfg_ed in
  Alcotest.(check bool) "non-int rejected" true
    (Result.is_error (Config_store.commit_edit_field bad1));
  let bad2 = Config_store.update_edit_buffer "9999" cfg_ed in
  Alcotest.(check bool) "above max rejected" true
    (Result.is_error (Config_store.commit_edit_field bad2));
  (* Valid int stages cleanly and produces CAS patch request *)
  let good = Config_store.update_edit_buffer "120" cfg_ed in
  let staged =
    match Config_store.commit_edit_field good with
    | Ok c -> c
    | Error e -> Alcotest.fail e
  in
  Alcotest.(check int) "1 dirty field staged" 1 (Config_store.dirty_count staged);
  match Config_store.build_patch_request ~dry_run:true staged with
  | Error e -> Alcotest.fail e
  | Ok req ->
      Alcotest.(check bool) "dry_run flag true" true req.dry_run;
      Alcotest.(check (option string)) "expected_sha256 carried" (Some "abcsha")
        req.expected_sha256

(* 8. Verifier regressions: P1-3 asks scope, P1-4 tx guards & /btw EOF,
      P1-5 routes & goal confirmation dive, P1-6 overlay keys & blocking gates,
      P2-1 config target isolation & bool toggle, P2-2 mixed-tab selection *)
let test_verifier_regressions () =
  (* P1-3: Keeper_asks_changed and Agent_input_required emit single global Get_asks *)
  let m0 = Model.initial () in
  let _, cmds_ask1 =
    Update.step ~now:t0 m0
      (Msg.Sse_event
         {
           epoch = m0.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 1;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Approval_changed
                        (Wire_observer.Keeper_asks_changed { keeper = "alpha" }));
               };
         })
  in
  Alcotest.(check int) "Keeper_asks_changed emits 1 global Get_asks" 1
    (List.length cmds_ask1);
  let check_global_asks_cmd label cmds =
    match cmds with
    | [ Cmd.Http_get { req; _ } ]
      when String.equal (Cmd.get_request_path req)
             (Wire_work.keeper_asks_path ~include_resolved:false ()) ->
        ()
    | [ Cmd.Http_get _ ]
    | [
        ( Cmd.Batch _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ );
      ]
    | []
    | _ :: _ :: _ ->
        Alcotest.fail (label ^ ": expected single global Get_asks")
  in
  check_global_asks_cmd "Keeper_asks_changed" cmds_ask1;
  let _, cmds_ask2 =
    Update.step ~now:t0 m0
      (Msg.Sse_event
         {
           epoch = m0.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 2;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Agent_core
                        {
                          kind =
                            Wire_observer.Agent_input_required
                              {
                                elapsed_s = 0.5;
                                request_id = "r1";
                                question = "Proceed?";
                              };
                          agent = Some "beta";
                          tool = None;
                          task = None;
                          turn = None;
                          tool_use_id = None;
                          at_unix = 100.0;
                          run_id = None;
                          execution_id = None;
                        });
               };
         })
  in
  check_global_asks_cmd "Agent_input_required" cmds_ask2;

  (* P1-4: Failed_retryable not overwritten by clean EOF; duplicate prompt not
     falsely confirmed by pre-existing history; /btw finalizes cleanly on EOF *)
  let old_user_msg : Wire_fleet.chat_message =
    {
      id = "old-u1";
      role = Wire_fleet.Role_user;
      content = "continue";
      ts_unix = 10.0;
      turn_ref = None;
      model_used = None;
      tool_call_id = None;
      tool_call_name = None;
      execution_id = None;
      operation_id = None;
      transcript_slot = None;
      failure_kind = None;
    }
  in
  let m_hist, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         {
           epoch = m0.epoch;
           reply = Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "alpha" ]));
         })
  in
  let m_hist, _ =
    Update.step ~now:t0 m_hist
      (Msg.Http_reply
         {
           epoch = m_hist.epoch;
           reply =
             Msg.Reply_chat_history
               {
                 keeper = "alpha";
                 result =
                   Ok
                     {
                       messages = [ old_user_msg ];
                       has_more = false;
                       next_cursor = None;
                     };
               };
         })
  in
  let m_dup =
    { m_hist with drafts = Drafts.insert_text "continue" m_hist.drafts }
  in
  let m_dup, _ = Update.execute_action ~now:t0 m_dup Keymap.Submit_followup in
  let dup_tx_id =
    match Drafts.active_tx_for_keeper ~keeper:"alpha" m_dup.drafts with
    | Some tx -> tx.request_id
    | None -> Alcotest.fail "missing dup tx"
  in
  let m_dup, _ =
    Update.step ~now:t1 m_dup
      (Msg.Chat_stream_chunk
         {
           epoch = m_dup.epoch;
           keeper = "alpha";
           request_id = dup_tx_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_accepted
               {
                 operation_id = "op-dup";
                 queued_count = 0;
                 state = Wire_fleet.Accepted_running;
                 interactive_outcome = None;
                 control_token = None;
               };
         })
  in
  (* Re-reading history containing ONLY old-u1 must NOT confirm new "continue" *)
  let m_dup_stale, _ =
    Update.step ~now:t1 m_dup
      (Msg.Http_reply
         {
           epoch = m_dup.epoch;
           reply =
             Msg.Reply_chat_history
               {
                 keeper = "alpha";
                 result =
                   Ok
                     {
                       messages = [ old_user_msg ];
                       has_more = false;
                       next_cursor = None;
                     };
               };
         })
  in
  Alcotest.(check bool) "old identical message does not falsely confirm new tx"
    true (Drafts.has_active_tx_for ~keeper:"alpha" m_dup_stale.drafts);
  (* Chunk_error followed by Chat_stream_done (Ok ()) keeps Failed_retryable *)
  let m_err, _ =
    Update.step ~now:t1 m_dup_stale
      (Msg.Chat_stream_chunk
         {
           epoch = m_dup_stale.epoch;
           keeper = "alpha";
           request_id = dup_tx_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_error
               { operation_id = Some "op-dup"; code = Some "503"; message = "busy" };
         })
  in
  let m_err_eof, _ =
    Update.step ~now:t2 m_err
      (Msg.Chat_stream_done
         {
           epoch = m_err.epoch;
           keeper = "alpha";
           request_id = dup_tx_id;
           is_btw = false;
           result = Ok ();
         })
  in
  let final_state =
    match
      List.find_opt
        (fun (tx : Drafts.pending_message) -> String.equal tx.request_id dup_tx_id)
        m_err_eof.drafts.pending_txs
    with
    | Some tx -> tx.state
    | None -> Alcotest.fail "missing dup tx after error EOF"
  in
  Alcotest.(check bool) "EOF does not overwrite Failed_retryable" true
    (Drafts.equal_tx_state final_state (Drafts.Failed_retryable { reason = "busy" }));
  (* /btw EOF without Chunk_turn_done finalizes cleanly *)
  let m_btw, _ = Update.execute_slash ~now:t0 m_hist (Slash.Btw "ping") in
  let btw_id =
    match m_btw.drafts.btw with
    | Drafts.Btw_sending { request_id; _ } -> request_id
    | Drafts.Btw_idle
    | Drafts.Btw_streaming _
    | Drafts.Btw_answered _
    | Drafts.Btw_failed _ ->
        Alcotest.fail "expected Btw_sending"
  in
  let m_btw2, _ =
    Update.step ~now:t1 m_btw
      (Msg.Chat_stream_chunk
         {
           epoch = m_btw.epoch;
           keeper = "alpha";
           request_id = btw_id;
           is_btw = true;
           chunk =
             Wire_fleet.Chunk_text_delta
               {
                 operation_id = Some "op-b";
                 delta = "pong";
                 owner = Wire_chat_journal.Unobserved_scope None;
               };
         })
  in
  let m_btw3, _ =
    Update.step ~now:t2 m_btw2
      (Msg.Chat_stream_done
         {
           epoch = m_btw2.epoch;
           keeper = "alpha";
           request_id = btw_id;
           is_btw = true;
           result = Ok ();
         })
  in
  (match m_btw3.drafts.btw with
  | Drafts.Btw_answered { reply; _ } when String.equal reply "pong" -> ()
  | Drafts.Btw_answered _
  | Drafts.Btw_idle
  | Drafts.Btw_sending _
  | Drafts.Btw_streaming _
  | Drafts.Btw_failed _ ->
      Alcotest.fail "expected /btw finalized to Btw_answered on EOF");

  (* P1-5: Live server routes + Goal confirmation strip dives instead of fabricating *)
  Alcotest.(check string) "Get_artifacts path" "/api/v1/published-artifacts"
    (Cmd.get_request_path Cmd.Get_artifacts);
  Alcotest.(check string) "Post_gate_resolution path"
    "/api/v1/dashboard/gate/resolve"
    (Cmd.post_request_path
       (Cmd.Post_gate_resolution { id = "g1"; approved = true; reason = None }));
  Alcotest.(check string) "Post_board_create path"
    "/api/v1/tools/masc_board_post"
    (Cmd.post_request_path
       (Cmd.Post_board_create { title = "t"; body = "b"; hearth = None }));
  Alcotest.(check string) "Post_task_cancel path"
    "/api/v1/dashboard/tasks/cancel"
    (Cmd.post_request_path
       (Cmd.Post_task_cancel
          {
            task_id = "t1";
            reason = None;
            expected_workspace =
              ({ base_path = "/repo"; masc_root = "/repo/.masc" }
                : Wire_work.expected_workspace);
          }));
  let m_goal, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         {
           epoch = m0.epoch;
           reply =
             Msg.Reply_planning (Ok { goals = [ sample_goal () ]; tasks = [] });
         })
  in
  let m_goal_dived, cmds_goal =
    Update.execute_action ~now:t1 m_goal Keymap.Fast_approve_top
  in
  Alcotest.(check bool) "Goal fast-approve dives instead of posting fake tokens"
    true
    (Option.equal Nav.equal_dive (Model.active_dive m_goal_dived)
       (Some (Nav.Dive_work (Nav.Goal_dive "g-1"))));
  let is_http_post = function
    | Cmd.Http_post _ -> true
    | Cmd.Batch _
    | Cmd.Http_get _
    | Cmd.Http_put _
    | Cmd.Http_post_stream _
    | Cmd.Sync_streams _
    | Cmd.Update_workspace_guard _
    | Cmd.Voice_cmd _
    | Cmd.Copy_clipboard _
    | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
    | Cmd.Open_editor_escape_hatch _
    | Cmd.Start_local_server
    | Cmd.Restart_tui
    | Cmd.Quit _ ->
        false
  in
  let posted_fake = List.exists is_http_post (Cmd.flatten cmds_goal) in
  Alcotest.(check bool) "Goal fast-approve emits 0 POSTs" false posted_fake;

  (* P1-6: Settings keyboard actions (Space/Ctrl+S/Ctrl+E) & blocking System_gate *)
  let schema_bool : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha-rt";
      sections =
        [
          {
            id = "providers";
            category = Wire_config.Cat_providers_models;
            title = "Providers";
            fields =
              [
                {
                  table = "providers";
                  key = "enabled";
                  full_key = "providers.enabled";
                  label = "Enabled";
                  env = None;
                  description = None;
                  kind = Wire_config.Field_bool;
                  value = Wire_config.Val_bool false;
                  default_value = Some (Wire_config.Val_bool false);
                  provenance = Wire_config.Prov_default;
                  reload_scope = Wire_config.Hot_reload;
                  secret = false;
                  writable = true;
                };
              ];
          };
        ];
    }
  in
  let m_set0 =
    let config =
      Config_store.empty
      |> Config_store.set_tab Nav.Settings_providers_models
      |> Config_store.apply_schema ~observed_at:t0 schema_bool
    in
    {
      m0 with
      config;
      nav = { m0.nav with overlay = Some (Nav.Settings Nav.Settings_providers_models) };
    }
  in
  (* Toggle bool once -> dirty=1; toggle again -> unstages back to dirty=0 (P2-1) *)
  let m_set1, _ =
    Update.step ~now:t0 m_set0 (Msg.Key_event (key Keymap.Input.Enter))
  in
  Alcotest.(check int) "bool toggle 1 stages dirty=1" 1
    (Config_store.dirty_count m_set1.config);
  let m_set_back, _ =
    Update.step ~now:t0 m_set1 (Msg.Key_event (key Keymap.Input.Enter))
  in
  Alcotest.(check int) "bool toggle 2 unstages back to dirty=0" 0
    (Config_store.dirty_count m_set_back.config);
  (* From dirty=1, Space triggers dry_run preview & Ctrl+S triggers atomic save *)
  let is_patch_post ~want_dry_run = function
    | Cmd.Http_post { req; _ } -> (
        match req with
        | Cmd.Post_config_patch { dry_run; _ } -> Bool.equal dry_run want_dry_run
        | Cmd.Post_ask_answer _
        | Cmd.Post_tool_approval _
        | Cmd.Post_gate_resolution _
        | Cmd.Post_goal_transition _
        | Cmd.Post_goal_confirmation _
        | Cmd.Post_verification_verdict _
        | Cmd.Post_memory_act _
        | Cmd.Post_fusion_launch _
        | Cmd.Post_runtime_assignment _
        | Cmd.Post_runtime_default_route _
        | Cmd.Post_setup_account_key _
        | Cmd.Post_setup_login_start _
        | Cmd.Post_sandbox_probe _
        | Cmd.Post_tui_preference _
        | Cmd.Post_keeper_turn_interrupt _
        | Cmd.Post_board_create _
        | Cmd.Post_schedule_create _
        | Cmd.Post_connector_bind _
        | Cmd.Post_repo_add _
        | Cmd.Post_task_cancel _
        | Cmd.Post_harness_overrule _
        | Cmd.Post_board_comment _
        | Cmd.Post_board_vote _
        | Cmd.Post_board_comment_vote _
        | Cmd.Post_artifact_check _
        | Cmd.Post_artifact_share _
        | Cmd.Post_connector_unbind _
        | Cmd.Post_browser_tabs _ ->
            false)
    | Cmd.Batch _
    | Cmd.Http_get _
    | Cmd.Http_put _
    | Cmd.Http_post_stream _
    | Cmd.Sync_streams _
    | Cmd.Update_workspace_guard _
    | Cmd.Voice_cmd _
    | Cmd.Copy_clipboard _
    | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
    | Cmd.Open_editor_escape_hatch _
    | Cmd.Start_local_server
    | Cmd.Restart_tui
    | Cmd.Quit _ ->
        false
  in
  let _, cmds_dry =
    Update.step ~now:t0 m_set1 (Msg.Key_event (char_key " "))
  in
  let has_dry_run =
    List.exists (is_patch_post ~want_dry_run:true) (Cmd.flatten cmds_dry)
  in
  Alcotest.(check bool) "Space in Settings triggers dry_run patch" true
    has_dry_run;
  let _, cmds_save =
    Update.step ~now:t0 m_set1 (Msg.Key_event (char_key ~ctrl:true "s"))
  in
  let has_save =
    List.exists (is_patch_post ~want_dry_run:false) (Cmd.flatten cmds_save)
  in
  Alcotest.(check bool) "Ctrl+S in Settings triggers atomic save" true has_save;
  (* Shrink to 30x10 and regrow preserves Settings overlay (non-destructive) *)
  let m_tiny, _ =
    Update.step ~now:t0 m_set1 (Msg.Resize { cols = 30; rows = 10 })
  in
  let m_grown, _ =
    Update.step ~now:t0 m_tiny (Msg.Resize { cols = 140; rows = 40 })
  in
  Alcotest.(check bool) "Resize shrink+grow preserves Settings overlay" true
    (Option.equal Nav.equal_overlay m_grown.nav.overlay
       (Some (Nav.Settings Nav.Settings_providers_models)));
  (* Esc cannot close Auth_gate, CAN close Media_viewer *)
  let m_auth =
    { m0 with nav = { m0.nav with overlay = Some (Nav.System_gate Nav.Auth_gate) } }
  in
  let m_auth_after, _ =
    Update.step ~now:t0 m_auth (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc does not dismiss Auth_gate" true
    (Option.equal Nav.equal_overlay m_auth_after.nav.overlay
       (Some (Nav.System_gate Nav.Auth_gate)));
  (* P2-1: Config target switch drops old schema & rejects stale target reply *)
  let cfg_sw =
    Config_store.set_target (Wire_config.Target_keeper "alpha") m_set1.config
  in
  Alcotest.(check int) "target switch clears old visible_fields" 0
    (List.length (Config_store.visible_fields cfg_sw));
  let cfg_stale = Config_store.apply_schema ~observed_at:t1 schema_bool cfg_sw in
  Alcotest.(check int) "stale runtime schema ignored after target switch" 0
    (List.length (Config_store.visible_fields cfg_stale));
  (* Keeper Dive > Config tab switches target & accepts keeper schema reply *)
  let m_with_rt =
    {
      m_hist with
      config =
        Config_store.empty |> Config_store.apply_schema ~observed_at:t0 schema_bool;
    }
  in
  let m_kchat, _ =
    Update.execute_slash ~now:t0 m_with_rt (Slash.Keeper (Some "alpha"))
  in
  (* Cycle prev tab from Keeper_chat wraps directly to Keeper_config *)
  let m_kcfg, cmds_kcfg =
    Update.execute_action ~now:t0 m_kchat (Keymap.Sub_tab Keymap.Prev)
  in
  Alcotest.(check bool) "Keeper_config switched target to Target_keeper alpha"
    true
    (Config_store.equal_config_target m_kcfg.config.target
       (Wire_config.Target_keeper "alpha"));
  let fetched_keeper_schema =
    List.exists
      (function
        | Cmd.Http_get { req; _ } ->
            String.equal (Cmd.get_request_path req)
              (Wire_config.config_schema_path (Wire_config.Target_keeper "alpha"))
        | Cmd.Batch _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            false)
      (Cmd.flatten cmds_kcfg)
  in
  Alcotest.(check bool) "Keeper_config fetches keeper schema even with fresh runtime schema"
    true fetched_keeper_schema;
  let keeper_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_keeper "alpha";
      keeper = Some "alpha";
      file_exists = true;
      file_sha256 = "sha-alpha";
      sections =
        [
          {
            id = "keeper";
            category = Wire_config.Cat_keepers_companies;
            title = "Keeper";
            fields =
              [
                {
                  table = "keeper";
                  key = "model";
                  full_key = "keeper.model";
                  label = "Model";
                  env = None;
                  description = None;
                  kind = Wire_config.Field_string;
                  value = Wire_config.Val_string "claude-opus";
                  default_value = None;
                  provenance = Wire_config.Prov_keeper;
                  reload_scope = Wire_config.Next_turn;
                  secret = false;
                  writable = true;
                };
              ];
          };
        ];
    }
  in
  let m_kcfg_loaded, _ =
    Update.step ~now:t1 m_kcfg
      (Msg.Http_reply
         { epoch = m_kcfg.epoch; reply = Msg.Reply_config_schema (Ok keeper_schema) })
  in
  Alcotest.(check int) "Keeper_config visible_fields populated after reply" 1
    (List.length (Config_store.visible_fields m_kcfg_loaded.config));
  (* P2-2: Scrolling Work_inbox past asks onto tool approval clears selected_open_ask *)
  let w_mix =
    Work_store.empty
    |> Work_store.set_tab Nav.Work_inbox
    |> Work_store.apply_asks ~observed_at:t0 [ sample_ask () ]
    |> Work_store.apply_tool_approvals ~observed_at:t0 [ sample_tool_approval () ]
  in
  Alcotest.(check bool) "index 0 selects open ask" true
    (Option.is_some (Work_store.selected_open_ask w_mix));
  let w_mix1 = Work_store.move_selection ~delta:1 w_mix in
  Alcotest.(check bool) "index 1 (on tool approval) has selected_open_ask=None"
    true (Option.is_none (Work_store.selected_open_ask w_mix1))

let test_round1_settings_and_overlay_transitions () =
  let m0 = Model.initial () in
  (* P1-5: I -> Esc -> Ctrl+K -> Esc -> ? -> Esc *)
  let m_inc, _ = Update.step ~now:t0 m0 (Msg.Key_event (char_key "I")) in
  Alcotest.(check bool) "I opens Incidents" true
    (Option.equal Nav.equal_overlay m_inc.nav.overlay (Some Nav.Incidents));
  let m_after_inc, _ =
    Update.step ~now:t0 m_inc (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc closes Incidents to None" true
    (Option.is_none m_after_inc.nav.overlay);
  Alcotest.(check bool) "Unfocused_nav restored after Incidents Esc" true
    (List.exists
       (fun s -> match s with Keymap.Unfocused_nav -> true | _ -> false)
       (Model.focus_scope_chain m_after_inc));
  let m_pal, _ =
    Update.step ~now:t0 m_after_inc
      (Msg.Key_event (char_key ~ctrl:true "k"))
  in
  Alcotest.(check bool) "Ctrl+K opens Palette after Incidents Esc" true
    (Option.equal Nav.equal_overlay m_pal.nav.overlay (Some Nav.Palette));
  let m_after_pal, _ =
    Update.step ~now:t0 m_pal (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc closes Palette" true
    (Option.is_none m_after_pal.nav.overlay);
  let m_help, _ =
    Update.step ~now:t0 m_after_pal (Msg.Key_event (char_key "?"))
  in
  Alcotest.(check bool) "? opens Help after Esc" true
    (Option.equal Nav.equal_overlay m_help.nav.overlay (Some Nav.Help));
  let m_after_help, _ =
    Update.step ~now:t0 m_help (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc closes Help" true
    (Option.is_none m_after_help.nav.overlay);

  (* P1-4: Keeper Dive > Config must NOT leak Target_keeper into global Settings *)
  let m_kcfg =
    {
      m0 with
      config =
        Config_store.set_target (Wire_config.Target_keeper "code-reviewer")
          m0.config;
      nav = { m0.nav with workspace = Nav.Infra };
    }
  in
  let m_set, cmds_set =
    Update.step ~now:t0 m_kcfg (Msg.Key_event (char_key ","))
  in
  Alcotest.(check bool) "global Settings resets target to Target_runtime" true
    (Config_store.equal_config_target m_set.config.target
       Wire_config.Target_runtime);
  let fetches_runtime_schema =
    List.exists
      (function
        | Cmd.Http_get { req; _ } ->
            String.equal (Cmd.get_request_path req)
              (Wire_config.config_schema_path Wire_config.Target_runtime)
        | Cmd.Batch _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            false)
      (Cmd.flatten cmds_set)
  in
  Alcotest.(check bool) "global Settings fetches runtime schema" true
    fetches_runtime_schema;
  (* Slash /config also resets target *)
  let m_slash_set, _ =
    Update.execute_slash ~now:t0 m_kcfg (Slash.Config None)
  in
  Alcotest.(check bool) "/config resets target to Target_runtime" true
    (Config_store.equal_config_target m_slash_set.config.target
       Wire_config.Target_runtime);

  (* P1-4: Settings tab cycling via ], [, Alt+], Alt+[ and direct 1..7 *)
  let m_s1, _ = Update.step ~now:t0 m_set (Msg.Key_event (char_key "]")) in
  Alcotest.(check bool) "] advances to Settings_providers_models" true
    (Option.equal Nav.equal_overlay m_s1.nav.overlay
       (Some (Nav.Settings Nav.Settings_providers_models)));
  let m_s2, _ =
    Update.step ~now:t0 m_s1 (Msg.Key_event (char_key ~alt:true "]"))
  in
  Alcotest.(check bool) "Alt+] advances to Settings_routing_failover" true
    (Option.equal Nav.equal_overlay m_s2.nav.overlay
       (Some (Nav.Settings Nav.Settings_routing_failover)));
  let m_s1_back, _ =
    Update.step ~now:t0 m_s2 (Msg.Key_event (char_key ~alt:true "["))
  in
  Alcotest.(check bool) "Alt+[ returns to Settings_providers_models" true
    (Option.equal Nav.equal_overlay m_s1_back.nav.overlay
       (Some (Nav.Settings Nav.Settings_providers_models)));
  let m_s5, _ = Update.step ~now:t0 m_s1_back (Msg.Key_event (char_key "5")) in
  Alcotest.(check bool) "key 5 jumps directly to Settings_sandbox_ssh" true
    (Option.equal Nav.equal_overlay m_s5.nav.overlay
       (Some (Nav.Settings Nav.Settings_sandbox_ssh)));
  let m_s7, _ = Update.step ~now:t0 m_s5 (Msg.Key_event (char_key "7")) in
  Alcotest.(check bool) "key 7 jumps directly to Settings_board_memory_candle" true
    (Option.equal Nav.equal_overlay m_s7.nav.overlay
       (Some (Nav.Settings Nav.Settings_board_memory_candle)));
  let m_s_wrap, _ = Update.step ~now:t0 m_s7 (Msg.Key_event (char_key "]")) in
  Alcotest.(check bool) "] wraps from tab 7 back to Settings_general_ui" true
    (Option.equal Nav.equal_overlay m_s_wrap.nav.overlay
       (Some (Nav.Settings Nav.Settings_general_ui)))

let test_round2_store_regressions () =
  (* R2-P1-1: open_global_settings resets BOTH target AND active_tab to Settings_general_ui *)
  let m0 = Model.initial () in
  let m_stale_tab =
    {
      m0 with
      config =
        Config_store.set_target (Wire_config.Target_keeper "alpha") m0.config
        |> Config_store.set_tab Nav.Settings_keepers_companies;
    }
  in
  let m_set, _ =
    Update.step ~now:t0 m_stale_tab (Msg.Key_event (char_key ","))
  in
  Alcotest.(check bool) "R2-P1-1 global Settings resets config.target" true
    (Config_store.equal_config_target m_set.config.target
       Wire_config.Target_runtime);
  Alcotest.(check bool) "R2-P1-1 global Settings resets config.active_tab to Tab 1"
    true
    (Nav.equal_settings_tab m_set.config.active_tab Nav.Settings_general_ui);
  Alcotest.(check bool) "R2-P1-1 overlay opens on Settings_general_ui" true
    (Option.equal Nav.equal_overlay m_set.nav.overlay
       (Some (Nav.Settings Nav.Settings_general_ui)));

  (* R2-P1-2: Model.initial ?wall_unix seeds last_wall_unix immediately on frame 1 *)
  let m_wall = Model.initial ~wall_unix:1_795_252_092.0 () in
  Alcotest.(check (float 0.001)) "Model.initial seeds last_wall_unix"
    1_795_252_092.0 m_wall.freshness.last_wall_unix;
  let m_bad_wall = Model.initial ~wall_unix:(-5.0) () in
  Alcotest.(check (float 0.001)) "Model.initial clamps negative wall_unix to 0.0"
    0.0 m_bad_wall.freshness.last_wall_unix;

  (* R2-P1-5: [4] Keepers auto-fetches Get_chat_history for selected keeper + Get_sandboxes,
     and moving selection with j fetches Get_chat_history for the newly selected keeper. *)
  let m_fleet, _ =
    Update.step ~now:t0 m_wall
      (Msg.Http_reply
         {
           epoch = m_wall.epoch;
           reply =
             Msg.Reply_keepers_roster
               (Ok (roster_of [ sample_keeper "alpha"; sample_keeper "beta" ]));
         })
  in
  let has_get pred cmds =
    List.exists
      (function
        | Cmd.Http_get { req; _ } -> pred req
        | Cmd.Batch _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            false)
      (Cmd.flatten cmds)
  in
  let is_chat_for name = function
    | Cmd.Get_chat_history { keeper; _ } -> String.equal keeper name
    | _ -> false
  in
  let is_sandboxes = function Cmd.Get_sandboxes -> true | _ -> false in
  let m_k, cmds_k = Update.step ~now:t1 m_fleet (Msg.Key_event (char_key "4")) in
  Alcotest.(check bool) "R2-P1-5 [4] Keepers auto-fetches Get_chat_history(alpha)"
    true (has_get (is_chat_for "alpha") cmds_k);
  Alcotest.(check bool) "R2-P1-5 [4] Keepers auto-fetches Get_sandboxes"
    true (has_get is_sandboxes cmds_k);
  let m_k2, cmds_k2 = Update.step ~now:t2 m_k (Msg.Key_event (char_key "j")) in
  Alcotest.(check (option string)) "R2-P1-5 j moves selected keeper to beta"
    (Some "beta")
    (Option.map (fun (k : Wire_fleet.keeper_summary) -> k.name)
       (Fleet_store.selected_keeper_summary m_k2.fleet));
  Alcotest.(check bool) "R2-P1-5 j on Keepers auto-fetches Get_chat_history(beta)"
    true (has_get (is_chat_for "beta") cmds_k2);

  (* Verifier-2 P1: Embedded [4] Keepers dive tabs (Keeper_memory, Keeper_sandbox,
     Keeper_config) must re-fetch on keeper switch and sync config.target so
     Reply_config_schema lands in model.config.schema instead of being dropped. *)
  let is_mem_diff_for name = function
    | Cmd.Get_memory_diff { keeper = Some k; _ } -> String.equal k name
    | _ -> false
  in
  let is_sandbox_for name = function
    | Cmd.Get_keeper_sandbox { keeper; _ } -> String.equal keeper name
    | _ -> false
  in
  let is_schema_for name = function
    | Cmd.Get_config_schema (Wire_config.Target_keeper k) ->
        String.equal k name
    | _ -> false
  in
  let alpha_mem_diff : Wire_knowledge.memory_diff =
    {
      scope = Wire_knowledge.Scope_keeper "alpha";
      range =
        {
          window = Some "24h";
          from_rev = None;
          to_rev = None;
          from_unix = None;
          to_unix = None;
        };
      retrieval_heat =
        {
          hot = 1;
          warm = 0;
          cold = 0;
          never_retrieved = 0;
          total_events = 1;
          unreadable_event_lines = 0;
        };
      body =
        Wire_knowledge.Keeper_diff
          {
            counts =
              {
                total_facts_now = 1;
                added = 0;
                updated = 0;
                retracted = 0;
                invalidated = 0;
                journal_failures_in_window = 0;
                journal_quarantines_in_window = 0;
                undecodable_journal_lines = 0;
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
  let alpha_sandbox : Wire_infra.keeper_sandbox_response =
    {
      keeper = "alpha";
      probe_state = None;
      sandbox =
        Wire_infra.Sandbox_docker
          {
            keeper = "alpha";
            backend = "docker";
            network_mode = Wire_infra.Net_none;
            metrics_24h =
              {
                calls = 0;
                failures = 0;
                failure_unclassified = 0;
                p50_ms = Observed.unreported;
                p95_ms = Observed.unreported;
                max_ms = Observed.unreported;
                failure_classes =
                  {
                    dependency_unavailable = 0;
                    runtime_failure = 0;
                    policy_rejection = 0;
                    workflow_rejection = 0;
                    operator_cancelled = 0;
                  };
              };
          };
    }
  in
  (* 1. Keeper_memory: loaded fresh for alpha, pressing j -> beta fetches beta's memory diff *)
  let m_kmem_alpha =
    {
      m_k with
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_memory m_k.fleet;
      knowledge =
        Knowledge_store.set_memory_diff ~keeper:(Some "alpha")
          ~window:Knowledge_store.Window_24h
          (Observed.value ~observed_at:t1 alpha_mem_diff)
          m_k.knowledge;
    }
  in
  let m_kmem_beta, cmds_kmem_beta =
    Update.step ~now:t2 m_kmem_alpha (Msg.Key_event (char_key "j"))
  in
  Alcotest.(check bool)
    "Keeper_memory move alpha->beta fetches Get_memory_diff(beta)" true
    (has_get (is_mem_diff_for "beta") cmds_kmem_beta);
  (* beta's diff lands; k returns to alpha, whose diff is still fresh *)
  let m_kmem_beta_loaded, _ =
    Update.step ~now:t2 m_kmem_beta
      (Msg.Http_reply
         {
           epoch = m_kmem_beta.epoch;
           reply =
             Msg.Reply_memory_diff
               {
                 keeper = Some "beta";
                 window = Knowledge_store.Window_24h;
                 result =
                   Ok
                     {
                       alpha_mem_diff with
                       scope = Wire_knowledge.Scope_keeper "beta";
                     };
               };
         })
  in
  let _, cmds_kmem_back =
    Update.step ~now:t2 m_kmem_beta_loaded (Msg.Key_event (char_key "k"))
  in
  Alcotest.(check bool)
    "Keeper_memory back to alpha does not ask alpha's fresh diff again" false
    (has_get (is_mem_diff_for "alpha") cmds_kmem_back);

  (* 2. Keeper_sandbox: loaded fresh for alpha, pressing j -> beta fetches beta's sandbox *)
  let m_ksb_alpha =
    {
      m_k with
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_sandbox m_k.fleet;
      infra =
        Infra_store.set_keeper_sandbox ~keeper:"alpha"
          (Observed.value ~observed_at:t1 alpha_sandbox)
          m_k.infra;
    }
  in
  let _, cmds_ksb_beta =
    Update.step ~now:t2 m_ksb_alpha (Msg.Key_event (char_key "j"))
  in
  Alcotest.(check bool)
    "Keeper_sandbox move alpha->beta fetches Get_keeper_sandbox(beta)" true
    (has_get (is_sandbox_for "beta") cmds_ksb_beta);

  (* 3. Keeper_config: switching to Keepers + moving alpha->beta syncs config.target
     and accepts Reply_config_schema into model.config.schema *)
  let m_kcfg_pulse =
    {
      m_fleet with
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_config m_fleet.fleet;
    }
  in
  let m_kcfg_alpha, cmds_kcfg_alpha =
    Update.step ~now:t1 m_kcfg_pulse (Msg.Key_event (char_key "4"))
  in
  Alcotest.(check bool) "switch to Keepers on Keeper_config syncs target=alpha"
    true
    (Config_store.equal_config_target m_kcfg_alpha.config.target
       (Wire_config.Target_keeper "alpha"));
  Alcotest.(check bool) "switch to Keepers on Keeper_config fetches schema(alpha)"
    true (has_get (is_schema_for "alpha") cmds_kcfg_alpha);
  let m_kcfg_beta, cmds_kcfg_beta =
    Update.step ~now:t2 m_kcfg_alpha (Msg.Key_event (char_key "j"))
  in
  Alcotest.(check bool) "move alpha->beta on Keeper_config syncs target=beta"
    true
    (Config_store.equal_config_target m_kcfg_beta.config.target
       (Wire_config.Target_keeper "beta"));
  Alcotest.(check bool) "move alpha->beta on Keeper_config fetches schema(beta)"
    true (has_get (is_schema_for "beta") cmds_kcfg_beta);
  let beta_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_keeper "beta";
      keeper = Some "beta";
      file_exists = true;
      file_sha256 = "sha-beta";
      sections =
        [
          {
            id = "keeper";
            category = Wire_config.Cat_keepers_companies;
            title = "Keeper";
            fields =
              [
                {
                  table = "keeper";
                  key = "model";
                  full_key = "keeper.model";
                  label = "Model";
                  env = None;
                  description = None;
                  kind = Wire_config.Field_string;
                  value = Wire_config.Val_string "claude-sonnet";
                  default_value = None;
                  provenance = Wire_config.Prov_keeper;
                  reload_scope = Wire_config.Next_turn;
                  secret = false;
                  writable = true;
                };
              ];
          };
        ];
    }
  in
  let m_kcfg_beta_loaded, _ =
    Update.step ~now:t2 m_kcfg_beta
      (Msg.Http_reply
         {
           epoch = m_kcfg_beta.epoch;
           reply = Msg.Reply_config_schema (Ok beta_schema);
         })
  in
  Alcotest.(check bool)
    "Reply_config_schema(beta) lands in model.config.schema (not dropped)" true
    (match Observed.to_option m_kcfg_beta_loaded.config.schema with
     | Some s ->
         Config_store.equal_config_target s.target
           (Wire_config.Target_keeper "beta")
     | None -> false);
  (* 4. Reply_keepers_roster arriving while on Nav.Keepers + Keeper_config syncs target *)
  let m_empty_kcfg =
    {
      m_wall with
      nav = { m_wall.nav with workspace = Nav.Keepers };
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_config m_wall.fleet;
    }
  in
  let m_roster_synced, cmds_roster_synced =
    Update.step ~now:t1 m_empty_kcfg
      (Msg.Http_reply
         {
           epoch = m_empty_kcfg.epoch;
           reply = Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "alpha" ]));
         })
  in
  Alcotest.(check bool) "Reply_keepers_roster on Keepers+Keeper_config syncs target=alpha"
    true
    (Config_store.equal_config_target m_roster_synced.config.target
       (Wire_config.Target_keeper "alpha"));
  Alcotest.(check bool) "Reply_keepers_roster on Keepers+Keeper_config fetches schema(alpha)"
    true (has_get (is_schema_for "alpha") cmds_roster_synced)

let test_v25_data_pipeline_and_settings_2pane () =
  (* 1. HTTP 400 fix: Get_verifications `Pending maps to view=awaiting *)
  Alcotest.(check string) "Get_verifications Pending -> view=awaiting"
    "/api/v1/verification/requests?view=awaiting&limit=50&offset=0"
    (Cmd.get_request_path
       (Cmd.Get_verifications { view = `Pending; limit = 50; offset = 0 }));
  (* 2. View_fetches on Pulse fetches telemetry + scorecard sources *)
  let wall_slot = 1_795_251_600 in
  let m0 =
    Model.initial ~cols:140 ~rows:40 ~wall_unix:(Float.of_int (wall_slot + 300)) ()
  in
  let pulse_cmds = Cmd.flatten (View_fetches.fetches_for_current_view ~force:true m0) in
  let has_path expected =
    List.exists
      (function
        | Cmd.Http_get { req; _ } ->
            String.equal (Cmd.get_request_path req) expected
        | Cmd.Batch _ | Cmd.Http_post _ | Cmd.Http_put _
        | Cmd.Http_post_stream _ | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _ | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _ | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _ | Cmd.Start_local_server
        | Cmd.Restart_tui | Cmd.Quit _ ->
            false)
      pulse_cmds
  in
  Alcotest.(check bool) "Pulse fetches models/metrics(1440, 60)" true
    (has_path "/api/v1/models/metrics?window=1440&bucket_min=60");
  Alcotest.(check bool) "Pulse fetches runtime/metrics" true
    (has_path "/api/v1/runtime/metrics");
  Alcotest.(check bool) "Pulse fetches tool-metrics/series" true
    (has_path "/api/v1/tool-metrics/series?bucket=hour&since_hours=24");
  Alcotest.(check bool) "Pulse fetches candle/ledger" true
    (has_path "/api/v1/candle/ledger?limit=50");
  (* 3. Graceful 404 fallbacks for sandboxes, candle/ledger & 401 runtime/metrics *)
  let k_masc =
    {
      (sample_keeper "alpha-builder") with
      group = Some "Platform Core";
      company = "Platform Core";
    }
  in
  let m1, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         { epoch = m0.epoch; reply = Msg.Reply_keepers_roster (Ok (roster_of [ k_masc ])) })
  in
  let extras : Wire_fleet.keeper_roster_extras =
    {
      sandbox_profiles = [ ("alpha-builder", Wire_fleet.Profile_microvm) ];
      candle_balances_milli = [ ("alpha-builder", 5000) ];
      candle_summary =
        Some
          (Wire_fleet.Candle_ready
             {
               issued_milli = "10000";
               burned_milli = "2500";
               circulating_milli = "7500";
             });
      turn_pulses =
        [
          ( "alpha-builder"
          , {
              Wire_fleet.known_since = Float.of_int (wall_slot - 3600);
              slots =
                [
                  {
                    starts_at = wall_slot - 3600;
                    ok = 2;
                    rested = 0;
                    failed = 0;
                    scheduled = 0;
                    reacted = 0;
                    chat = 0;
                    own = 2;
                    unknown = 0;
                  };
                  {
                    starts_at = wall_slot - 1800;
                    ok = 5;
                    rested = 0;
                    failed = 0;
                    scheduled = 0;
                    reacted = 0;
                    chat = 0;
                    own = 5;
                    unknown = 0;
                  };
                  {
                    starts_at = wall_slot;
                    ok = 3;
                    rested = 0;
                    failed = 0;
                    scheduled = 0;
                    reacted = 0;
                    chat = 0;
                    own = 3;
                    unknown = 0;
                  };
                ];
            } );
        ];
    }
  in
  let m2, _ =
    Update.step ~now:t0 m1
      (Msg.Http_reply
         { epoch = m1.epoch; reply = Msg.Reply_keepers_roster_extras extras })
  in
  let ts : Wire_runtime.tool_series =
    {
      generated_at_unix = 1795254000.0;
      bucket_width = `Hour;
      utc_offset_min = 540;
      buckets =
        [
          {
            start_unix = 1795250000.0;
            activity =
              Wire_runtime.Series_active
                { calls = 120; failures = 3; deferred = 0; p95_ms = 640.0 };
          };
        ];
    }
  in
  let m3, _ =
    Update.step ~now:t0 m2
      (Msg.Http_reply
         { epoch = m2.epoch; reply = Msg.Reply_tool_series (Ok ts) })
  in
  let err_404 =
    Msg.Http_error { status = 404; body = "not found"; api_error = None }
  in
  let err_401 =
    Msg.Http_error { status = 401; body = "unauthorized"; api_error = None }
  in
  let m4, _ =
    Update.step ~now:t1 m3
      (Msg.Http_reply
         { epoch = m3.epoch; reply = Msg.Reply_sandboxes (Error err_404) })
  in
  let m5, _ =
    Update.step ~now:t1 m4
      (Msg.Http_reply
         { epoch = m4.epoch; reply = Msg.Reply_candle_ledger (Error err_404) })
  in
  let m6, _ =
    Update.step ~now:t1 m5
      (Msg.Http_reply
         { epoch = m5.epoch; reply = Msg.Reply_runtime_metrics (Error err_401) })
  in
  Alcotest.(check int) "zero incident spam on 404/401 fallbacks" 0
    (Incidents.count m6.incidents);
  (match Observed.to_option m6.infra.sandboxes with
  | Some sb ->
      Alcotest.(check int) "fallback microvm_declared = 1" 1 sb.microvm_declared;
      Alcotest.(check int) "fallback fleet_metrics_24h.calls = 120" 120
        sb.fleet_metrics_24h.calls
  | None -> Alcotest.fail "expected fallback sandboxes snapshot");
  (match Observed.to_option m6.work.candle_ledger with
  | Some cl ->
      Alcotest.(check string) "fallback candle circulating" "7500"
        cl.circulating_milli
  | None -> Alcotest.fail "expected fallback candle ledger");
  let mm : Wire_runtime.models_metrics_snapshot =
    {
      window_minutes = 1440;
      bucket_minutes = 60;
      total_entries = 40;
      total_error_entries = 1;
      models = [];
      hourly_buckets =
        [
          {
            ts_start = 1795250000.0;
            entry_count = 40;
            success_count = 39;
            error_count = 1;
            total_cost_usd = 2.40;
            p95_latency_ms = Some 950.0;
            cache_hit_pct = Some 94.5;
            input_tokens = Some 50000;
            output_tokens = Some 4000;
            cache_read_tokens = Some 47250;
          };
        ];
      fleet_cache_hit_pct = Observed.value ~observed_at:t1 94.5;
      fleet_cost_usd = Observed.value ~observed_at:t1 2.40;
      fleet_input_tokens = 50000;
      fleet_output_tokens = 4000;
      fleet_cache_read_tokens = 47250;
      fleet_cache_creation_tokens = 0;
      fleet_tool_calls = 120;
      fleet_p95_latency_ms = Some 950.0;
    }
  in
  let m7, _ =
    Update.step ~now:t1 m6
      (Msg.Http_reply
         { epoch = m6.epoch; reply = Msg.Reply_models_metrics (Ok mm) })
  in
  let hero = Model.pulse_hero_metrics m7 in
  Alcotest.(check (option int)) "hero turns_24h = 10" (Some 10)
    (Observed.to_option hero.turns_24h);
  Alcotest.(check (option int)) "hero tool_calls_24h = 120" (Some 120)
    (Observed.to_option hero.tool_calls_24h);
  Alcotest.(check (option (float 0.1))) "hero cache_hit_pct = 94.5" (Some 94.5)
    (Observed.to_option hero.cache_hit_pct);
  Alcotest.(check (option (float 0.01))) "hero spend_24h_usd = 2.40" (Some 2.40)
    (Observed.to_option hero.spend_24h_usd);
  Alcotest.(check int) "hero microvm_count = 1" 1 hero.microvm_count;
  Alcotest.(check (option string)) "hero candle circulating" (Some "7500")
    hero.candle_circulating_milli;
  Alcotest.(check int) "cache_hit_series_24h has 1 bucket" 1
    (List.length (Runtime_store.cache_hit_series_24h m7.runtime));
  Alcotest.(check bool) "velocity_series_24h uses Velocity_tokens" true
    (match Runtime_store.velocity_series_24h m7.runtime with
    | Runtime_store.Velocity_tokens [ _ ] -> true
    | Runtime_store.Velocity_tokens _
    | Runtime_store.Velocity_calls_and_spend _
    | Runtime_store.Velocity_tool_calls_and_p95 _
    | Runtime_store.Velocity_empty ->
        false);
  (* 4. Quotas & Credits partition + unreported collapse + 'u' toggle *)
  let mk_acc scope_id cost_state state : Wire_runtime.account_usage =
    {
      scope = "provider:" ^ scope_id;
      scope_id;
      providers = [ { id = scope_id; display_name = scope_id } ];
      state;
      cost_state;
    }
  in
  let usage : Wire_runtime.provider_usage_windows =
    {
      since_unix = 1795250000.0;
      accounts =
        [
          mk_acc "unrep-a" Format_val.Unreported
            Wire_runtime.Account_not_reported_since_start;
          mk_acc "openrouter" (Format_val.Amount 12.5)
            (Wire_runtime.Account_reported
               [
                 {
                   limit_id = None;
                   kind = Wire_runtime.Window_provider_label "credits";
                   role = Wire_runtime.Role_gates_model_calls;
                   utilization =
                     Wire_runtime.Util_credit_balance
                       { currency = "USD"; total = Some 50.0; remaining = 12.5 };
                   resets_at_unix = None;
                   observed_at_unix = 1795250000.0;
                 };
               ]);
          mk_acc "claude_code_a1b2c3d4" Format_val.Subscription_zero
            (Wire_runtime.Account_reported
               [
                 {
                   limit_id = None;
                   kind = Wire_runtime.Window_five_hour;
                   role = Wire_runtime.Role_gates_model_calls;
                   utilization = Wire_runtime.Util_percent 64;
                   resets_at_unix = None;
                   observed_at_unix = 1795250000.0;
                 };
               ]);
        ];
    }
  in
  let m_rt =
    {
      m7 with
      nav = { m7.nav with workspace = Nav.Runtime };
      runtime =
        Runtime_store.apply_usage_windows ~observed_at:t1 usage
          (Runtime_store.set_tab Nav.Runtime_quotas_credits m7.runtime);
    }
  in
  Alcotest.(check bool) "show_unreported_accounts defaults false" false
    m_rt.runtime.show_unreported_accounts;
  Alcotest.(check int) "visible_credit_accounts hides unreported (2)" 2
    (List.length (Runtime_store.visible_credit_accounts m_rt.runtime));
  let m_rt_u, _ =
    Update.step ~now:t2 m_rt (Msg.Key_event (char_key "u"))
  in
  Alcotest.(check bool) "'u' expands unreported accounts" true
    m_rt_u.runtime.show_unreported_accounts;
  Alcotest.(check int) "visible_credit_accounts includes unreported (3)" 3
    (List.length (Runtime_store.visible_credit_accounts m_rt_u.runtime));
  (* 5. Settings 2-Pane Tree -> Inspector + merged provider + Models Catalog + '/' search *)
  let mk_field table key value : Wire_config.schema_field =
    {
      table;
      key;
      full_key = table ^ "." ^ key;
      label = key;
      env = None;
      description = None;
      kind = Wire_config.Field_string;
      value;
      default_value = None;
      provenance = Wire_config.Prov_project;
      reload_scope = Wire_config.Hot_reload;
      secret = false;
      writable = true;
    }
  in
  let rt_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha-rt";
      sections =
        [
          {
            id = "runtime_providers";
            category = Wire_config.Cat_providers_models;
            title = "Providers";
            fields =
              [
                mk_field "providers.openrouter" "display-name"
                  (Wire_config.Val_string "OpenRouter");
                mk_field "providers.openrouter" "base-url"
                  (Wire_config.Val_string "https://openrouter.ai/api/v1");
                mk_field "openrouter.sonnet" "model"
                  (Wire_config.Val_string "anthropic/claude-sonnet-4.6");
                mk_field "models.opus" "max_context"
                  (Wire_config.Val_int 200000);
                mk_field "models.sonnet" "max_context"
                  (Wire_config.Val_int 200000);
              ];
          };
        ];
    }
  in
  let cfg0 =
    Config_store.apply_schema ~observed_at:t1 rt_schema
      (Config_store.set_tab Nav.Settings_providers_models Config_store.empty)
  in
  let sections = Config_store.tree_sections cfg0 in
  let openrouter_sec =
    List.find_opt
      (fun (s : Config_store.settings_tree_section) ->
        String.equal s.section_id "provider:openrouter")
      sections
  in
  (match openrouter_sec with
  | Some s ->
      Alcotest.(check string) "merged provider title" "OpenRouter" s.title;
      Alcotest.(check int) "merged provider + binding field count = 3" 3
        s.badge_count
  | None -> Alcotest.fail "expected merged provider:openrouter section");
  let rows_collapsed = Config_store.visible_tree_rows cfg0 in
  let has_catalog_toggle =
    List.exists
      (function
        | Config_store.Tree_models_catalog_toggle { expanded = false; model_count = 2; _ } ->
            true
        | Config_store.Tree_models_catalog_toggle _
        | Config_store.Tree_category _
        | Config_store.Tree_section _ ->
            false)
      rows_collapsed
  in
  Alcotest.(check bool) "models.* collapsed into 1 Models Catalog toggle (2)" true
    has_catalog_toggle;
  let cfg_searched = Config_store.set_search_query "최대 컨텍스트" cfg0 in
  Alcotest.(check bool) "global '/' search matches KO leaf label inside models.*" true
    (List.length (Config_store.tree_sections cfg_searched) = 2);
  let m_set =
    {
      m7 with
      nav =
        {
          m7.nav with
          overlay = Some (Nav.Settings Nav.Settings_providers_models);
        };
      config = cfg0;
    }
  in
  Alcotest.(check bool) "default settings_pane = Pane_inspector" true
    (Config_store.equal_settings_pane m_set.config.settings_pane
       Config_store.Pane_inspector);
  let m_tree, _ =
    Update.step ~now:t2 m_set (Msg.Key_event (key Keymap.Input.Tab))
  in
  Alcotest.(check bool) "Tab toggles Pane_inspector -> Pane_tree" true
    (Config_store.equal_settings_pane m_tree.config.settings_pane
       Config_store.Pane_tree);
  let m_back, _ =
    Update.step ~now:t2 m_tree (Msg.Key_event (key Keymap.Input.Enter))
  in
  Alcotest.(check bool) "Enter on tree section enters Pane_inspector" true
    (Config_store.equal_settings_pane m_back.config.settings_pane
       Config_store.Pane_inspector);
  (* #143 P1-1: non-retryable 401/403/404 failure does NOT loop in View_fetches when force=false *)
  let cmds_after_401 =
    Cmd.flatten (View_fetches.fetches_for_current_view ~force:false m6)
  in
  let has_runtime_metrics cmds =
    List.exists
      (function
        | Cmd.Http_get { req; _ } ->
            String.equal (Cmd.get_request_path req) "/api/v1/runtime/metrics"
        | Cmd.Batch _ | Cmd.Http_post _ | Cmd.Http_put _
        | Cmd.Http_post_stream _ | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _ | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _ | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _ | Cmd.Start_local_server
        | Cmd.Restart_tui | Cmd.Quit _ ->
            false)
      cmds
  in
  Alcotest.(check bool) "non-retryable 401 skips runtime/metrics when force=false"
    false (has_runtime_metrics cmds_after_401);
  let cmds_forced =
    Cmd.flatten (View_fetches.fetches_for_current_view ~force:true m6)
  in
  Alcotest.(check bool) "explicit force=true still retries runtime/metrics"
    true (has_runtime_metrics cmds_forced);
  (* #143 P1-2: sync_effective_scorecard never latches stale derived cost over fresher models_metrics *)
  let empty_shell : Wire_fleet.dashboard_shell =
    {
      generated_at_unix = Some 1795250000.0;
      project = Some "masc";
      version = Some "0.1.0";
      counts =
        {
          agents = 1;
          tasks = 1;
          tasks_done_24h = 0;
          keepers = 1;
          persisted_keepers = Observed.unreported;
          configured_keepers = Observed.unreported;
          total_runtimes = 1;
        };
      scorecard_24h =
        {
          tasks_done_24h = Observed.unreported;
          tasks_done_total = Observed.unreported;
          tasks_in_progress = Observed.unreported;
          tasks_claimed = Observed.unreported;
          tasks_awaiting_verification = Observed.unreported;
          tasks_todo = Observed.unreported;
          tasks_cancelled = Observed.unreported;
          goals_completed_24h = Observed.unreported;
          verifications_passed_24h = Observed.unreported;
          verifications_rejected_24h = Observed.unreported;
          board_posts_24h = Observed.unreported;
          turns_24h = Observed.unreported;
          cost_24h_usd = Observed.unreported;
        };
      groups = [];
    }
  in
  let kc_initial : Wire_runtime.keeper_costs_window =
    {
      generated_at_unix = 1795250000.0;
      window_minutes = 1440;
      rows =
        [
          {
            keeper_name = "alpha-builder";
            sample_count = 5;
            total_tokens = Observed.value ~observed_at:t0 10000;
            total_cost_usd = Observed.value ~observed_at:t0 0.75;
            tokens_reported_samples = 5;
            tokens_missing_samples = 0;
            cost_reported_samples = 5;
            cost_missing_samples = 0;
          };
        ];
    }
  in
  let m_sh, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         { epoch = m0.epoch; reply = Msg.Reply_dashboard_shell (Ok empty_shell) })
  in
  let m_kc, _ =
    Update.step ~now:t0 m_sh
      (Msg.Http_reply
         { epoch = m_sh.epoch; reply = Msg.Reply_keeper_costs (Ok kc_initial) })
  in
  Alcotest.(check (option (float 0.01))) "initial cost from keeper_costs = 0.75"
    (Some 0.75) (Observed.to_option (Model.effective_scorecard m_kc).cost_24h_usd);
  let m_mm_fresh, _ =
    Update.step ~now:t1 m_kc
      (Msg.Http_reply
         { epoch = m_kc.epoch; reply = Msg.Reply_models_metrics (Ok mm) })
  in
  Alcotest.(check (option (float 0.01)))
    "fresher models_metrics updates cost to 2.40 (no stale latching)"
    (Some 2.40)
    (Observed.to_option (Model.effective_scorecard m_mm_fresh).cost_24h_usd);
  (* #143 P2-5: per-keeper fallback never stamps fleet-wide cache_hit_pct onto individual keepers *)
  let rows_fb = Runtime_store.keeper_spend_rows m_mm_fresh.runtime in
  Alcotest.(check int) "1 fallback keeper spend row" 1 (List.length rows_fb);
  Alcotest.(check (option (float 0.1)))
    "per-keeper fallback cache_hit_pct stays Unreported (not fleet 94.5%)"
    None (Observed.to_option (List.hd rows_fb).cache_hit_pct);
  (* #143 P2-4: collapsing unreported accounts clamps selected_index & scroll_offset to footer row *)
  let m_rt_tail =
    {
      m_rt_u with
      runtime = { m_rt_u.runtime with selected_index = 3; scroll_offset = 3 };
    }
  in
  let m_rt_collapsed, _ =
    Update.step ~now:t2 m_rt_tail (Msg.Key_event (char_key "u"))
  in
  Alcotest.(check int) "selected_index clamped to unreported footer row (2)" 2
    m_rt_collapsed.runtime.selected_index;
  Alcotest.(check int) "scroll_offset pulled up to <= selected_index" 2
    m_rt_collapsed.runtime.scroll_offset;
  Alcotest.(check bool) "footer row still selected for Enter re-expand" true
    (Runtime_store.is_unreported_toggle_row_selected m_rt_collapsed.runtime);
  (* #143 P1-3 & P3: quoted dotted models stay distinct + collapse_or_leave pulls tree_scroll_offset up *)
  let quoted_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha-q";
      sections =
        [
          {
            id = "runtime_providers";
            category = Wire_config.Cat_providers_models;
            title = "Providers";
            fields =
              [
                mk_field {|models."gpt-5.6"|} "max_context"
                  (Wire_config.Val_int 256000);
                mk_field {|models."gpt-5.5"|} "max_context"
                  (Wire_config.Val_int 200000);
                mk_field {|models."gemini-2.5-pro"|} "max_context"
                  (Wire_config.Val_int 1000000);
              ];
          };
        ];
    }
  in
  let cfg_q =
    Config_store.apply_schema ~observed_at:t1 quoted_schema
      (Config_store.set_tab Nav.Settings_providers_models Config_store.empty)
  in
  let q_titles =
    List.map
      (fun (s : Config_store.settings_tree_section) -> s.title)
      (Config_store.tree_sections cfg_q)
  in
  Alcotest.(check (list string))
    "quoted dotted models produce 3 distinct unquoted sections"
    [ "gpt-5.6"; "gpt-5.5"; "gemini-2.5-pro" ]
    q_titles;
  let cfg_scrolled =
    {
      cfg0 with
      settings_pane = Config_store.Pane_tree;
      tree_scroll_offset = 5;
    }
  in
  let cfg_collapsed = Config_store.collapse_or_leave cfg_scrolled in
  Alcotest.(check bool) "collapse_or_leave pulls tree_scroll_offset <= selected_section_idx"
    true (cfg_collapsed.tree_scroll_offset <= cfg_collapsed.selected_section_idx);
  (* Round 5.5: human provider titles when display-name is absent/raw/server-titlecased
     and per-model binding sub_group refinement even over server "model_bindings" meta *)
  let f_cc1_proto =
    mk_field "providers.claude_code_a1b2c3d4" "protocol"
      (Wire_config.Val_string "claude-code")
  in
  let f_cc1_bind1 =
    mk_field "claude_code_a1b2c3d4.claude-sonnet-5-5" "max-context"
      (Wire_config.Val_int 1000000)
  in
  let f_cc1_bind2 =
    mk_field "claude_code_a1b2c3d4.claude-opus-5-5" "max-concurrent"
      (Wire_config.Val_int 4)
  in
  let f_cc2_raw =
    mk_field "providers.claude_code_b2c3d4e5" "display-name"
      (Wire_config.Val_string "claude_code_b2c3d4e5")
  in
  let f_agy_proto =
    mk_field "providers.antigravity_e5f60718" "protocol"
      (Wire_config.Val_string "antigravity")
  in
  let f_custom_dn =
    mk_field "providers.claude_code_c3d4e5f6" "display-name"
      (Wire_config.Val_string "Anthropic Work")
  in
  let hashed_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha-hashed";
      sections =
        [
          {
            id = "runtime_providers";
            category = Wire_config.Cat_providers_models;
            title = "Providers";
            fields =
              [
                f_cc1_proto;
                f_cc1_bind1;
                f_cc1_bind2;
                f_cc2_raw;
                f_agy_proto;
                f_custom_dn;
              ];
          };
        ];
    }
  in
  let server_meta : (string * Wire_config.field_entity_meta) list =
    [
      ( f_cc1_proto.full_key,
        {
          entity_group = Some "provider:claude_code_a1b2c3d4";
          entity_title = Some "Claude Code A1b2c3d4";
          sub_group = None;
        } );
      ( f_cc1_bind1.full_key,
        {
          entity_group = Some "provider:claude_code_a1b2c3d4";
          entity_title = Some "Claude Code A1b2c3d4";
          sub_group = Some "model_bindings";
        } );
      ( f_cc1_bind2.full_key,
        {
          entity_group = Some "provider:claude_code_a1b2c3d4";
          entity_title = Some "Claude Code A1b2c3d4";
          sub_group = Some "model_bindings";
        } );
      ( f_cc2_raw.full_key,
        {
          entity_group = Some "provider:claude_code_b2c3d4e5";
          entity_title = Some "claude_code_b2c3d4e5";
          sub_group = None;
        } );
      ( f_agy_proto.full_key,
        {
          entity_group = Some "provider:antigravity_e5f60718";
          entity_title = Some "Antigravity E5f60718";
          sub_group = None;
        } );
      ( f_custom_dn.full_key,
        {
          entity_group = Some "provider:claude_code_c3d4e5f6";
          entity_title = Some "Anthropic Work";
          sub_group = None;
        } );
    ]
  in
  let cfg_hashed =
    Config_store.apply_schema ~field_meta:server_meta ~observed_at:t1
      hashed_schema
      (Config_store.set_tab Nav.Settings_providers_models Config_store.empty)
  in
  let hashed_titles =
    List.map
      (fun (s : Config_store.settings_tree_section) -> (s.section_id, s.title))
      (Config_store.tree_sections cfg_hashed)
  in
  Alcotest.(check (option string)) "server titlecased hex8 -> Claude Code #a1b2"
    (Some "Claude Code #a1b2")
    (List.assoc_opt "provider:claude_code_a1b2c3d4" hashed_titles);
  Alcotest.(check (option string)) "raw slug display-name -> Claude Code #b2c3"
    (Some "Claude Code #b2c3")
    (List.assoc_opt "provider:claude_code_b2c3d4e5" hashed_titles);
  Alcotest.(check (option string)) "antigravity hex8 -> Antigravity CLI"
    (Some "Antigravity CLI")
    (List.assoc_opt "provider:antigravity_e5f60718" hashed_titles);
  Alcotest.(check (option string)) "explicit custom display-name preserved"
    (Some "Anthropic Work")
    (List.assoc_opt "provider:claude_code_c3d4e5f6" hashed_titles);
  Alcotest.(check (option string)) "server model_bindings refined to binding:claude-sonnet-5-5"
    (Some "binding:claude-sonnet-5-5")
    (Config_store.field_sub_group cfg_hashed f_cc1_bind1);
  Alcotest.(check (option string)) "server model_bindings refined to binding:claude-opus-5-5"
    (Some "binding:claude-opus-5-5")
    (Config_store.field_sub_group cfg_hashed f_cc1_bind2)

let test_p0_actions_settings_safety_and_wired_cmds () =
  let m0 = Model.initial () in
  let step m ev = Update.step ~now:t0 m (Msg.Key_event ev) in
  let has_cmd pred cmds = List.exists pred (Cmd.flatten cmds) in

  (* 1. P1-11: Settings [n] NEVER triggers Save; Target_keeper_create edits name; Delete stages Remove_key *)
  let schema_edit : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha-rt-1";
      sections =
        [
          {
            id = "gen";
            category = Wire_config.Cat_general_ui;
            title = "General";
            fields =
              [
                {
                  table = "runtime";
                  key = "default_route";
                  full_key = "runtime.default_route";
                  label = "Default Route";
                  env = None;
                  description = None;
                  kind = Wire_config.Field_string;
                  value = Wire_config.Val_string "sonnet";
                  default_value = None;
                  provenance = Wire_config.Prov_global;
                  reload_scope = Wire_config.Hot_reload;
                  secret = false;
                  writable = true;
                };
              ];
          };
        ];
    }
  in
  let cfg_dirty =
    Config_store.empty
    |> Config_store.set_tab Nav.Settings_general_ui
    |> Config_store.apply_schema ~observed_at:t0 schema_edit
    |> Config_store.stage_patch ~full_key:"runtime.default_route"
         (Wire_config.Set_scalar
            { table = "runtime"; key = "default_route"; value = "opus" })
  in
  let m_set =
    {
      m0 with
      nav = { m0.nav with overlay = Some (Nav.Settings Nav.Settings_general_ui) };
      config = cfg_dirty;
    }
  in
  let _, cmds_n = step m_set (char_key "n") in
  let is_any_patch = function
    | Cmd.Http_post { req = Cmd.Post_config_patch _; _ } -> true
    | _ -> false
  in
  Alcotest.(check bool) "bare [n] in Settings NEVER saves" false
    (has_cmd is_any_patch cmds_n);
  let _, cmds_ctrl_s = step m_set (char_key ~ctrl:true "s") in
  Alcotest.(check bool) "Ctrl+S in Settings triggers dry_run=false save" true
    (has_cmd
       (function
         | Cmd.Http_post
             { req = Cmd.Post_config_patch { dry_run = false; _ }; _ } ->
             true
         | _ -> false)
       cmds_ctrl_s);

  (* Delete in Settings Inspector toggles Wire_config.Remove_key *)
  let m_clean_insp =
    {
      m_set with
      config =
        Config_store.empty
        |> Config_store.set_tab Nav.Settings_general_ui
        |> Config_store.apply_schema ~observed_at:t0 schema_edit
        |> Config_store.set_pane Config_store.Pane_inspector;
    }
  in
  let m_after_del, _ = step m_clean_insp (key Keymap.Input.Delete) in
  Alcotest.(check bool) "Delete stages Remove_key on writable field" true
    (match
       Config_store.String_map.find_opt "runtime.default_route"
         m_after_del.config.dirty_fields
     with
    | Some (Wire_config.Remove_key { table = "runtime"; key = "default_route" }) ->
        true
    | _ -> false);

  (* Target_keeper_create: [n] on Tab 4 enters keeper-name edit, typing + Enter calls set_new_keeper_name *)
  let m_tab4 =
    {
      m0 with
      nav =
        {
          m0.nav with
          overlay = Some (Nav.Settings Nav.Settings_keepers_companies);
        };
      config =
        Config_store.empty
        |> Config_store.set_tab Nav.Settings_keepers_companies;
    }
  in
  let m_nk0, cmds_nk0 = step m_tab4 (char_key "n") in
  Alcotest.(check bool) "[n] on Settings tab 4 never saves" false
    (has_cmd is_any_patch cmds_nk0);
  Alcotest.(check bool) "[n] on Settings tab 4 fetches Target_keeper_create schema"
    true
    (has_cmd
       (function
         | Cmd.Http_get
             { req = Cmd.Get_config_schema Wire_config.Target_keeper_create; _ } ->
             true
         | _ -> false)
       cmds_nk0);
  Alcotest.(check bool) "[n] on Settings tab 4 enters new_keeper_name edit" true
    (Config_store.is_editing_new_keeper_name m_nk0.config);
  let m_nk1 =
    List.fold_left
      (fun acc ch -> fst (step acc (char_key (String.make 1 ch))))
      m_nk0
      [ 'a'; 'l'; 'p'; 'h'; 'a'; '-'; '2' ]
  in
  let m_nk2, _ = step m_nk1 (key Keymap.Input.Enter) in
  Alcotest.(check string) "new_keeper_name committed via set_new_keeper_name"
    "alpha-2" m_nk2.config.new_keeper_name;
  let create_schema =
    { schema_edit with target = Wire_config.Target_keeper_create }
  in
  let cfg_create_ready =
    m_nk2.config
    |> Config_store.apply_schema ~observed_at:t0 create_schema
    |> Config_store.stage_patch ~full_key:"runtime.default_route"
         (Wire_config.Set_scalar
            { table = "runtime"; key = "default_route"; value = "opus" })
  in
  (match Config_store.build_patch_request ~dry_run:false cfg_create_ready with
  | Ok req ->
      Alcotest.(check (option string)) "Target_keeper_create patch carries keeper_name"
        (Some "alpha-2") req.keeper_name
  | Error err -> Alcotest.fail ("Expected Target_keeper_create patch Ok: " ^ err));

  (* 2. P0-3 & P0-4: Work Goal/Task/Verification modals & wired Cmds *)
  let ver1 : Wire_work.verification_request =
    {
      request_id = "ver-100";
      task_id = "task-100";
      task_title = "Verify patch";
      submitted_by = "alpha";
      created_at_unix = None;
      completion_contract = [];
      required_artifacts = [];
      submitted_evidence = [];
      evidence_projection_error = None;
      review_observation = None;
    }
  in
  let task1 : Wire_work.task =
    {
      id = "task-100";
      title = "Task 100";
      description = Some "See https://example.com/pr/100";
      priority = 1;
      status = Wire_work.Todo;
      goal_link = Wire_work.Linked "goal-100";
      created_at = None;
      updated_at = None;
    }
  in
  let goal_confirm : Wire_work.goal =
    {
      id = "goal-100";
      title = "Ship v2.5";
      phase = Wire_work.Awaiting_confirmation;
      priority = 1;
      due_date = None;
      measure = "All checks pass";
      procedure = "Verify";
      criterion_revision = Some "rev-7";
      criterion_verdict = Wire_work.Criterion_valid;
      last_review_note = None;
      last_review_at = None;
      created_at = None;
      updated_at = None;
      linked_task_count = Observed.value ~observed_at:t0 1;
    }
  in
  let goal_exec = { goal_confirm with id = "goal-101"; phase = Wire_work.Executing } in
  let ws_id : Wire_common.workspace_identity =
    {
      instance_id = Some "inst-9";
      base_path = "/repo";
      masc_root = "/repo/.masc";
      workspace_sha256 = Some "ws-sha";
    }
  in
  let m_work =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Work };
      server_identity =
        {
          m0.server_identity with
          workspace = Some ws_id;
          observer_instance_id = Some "inst-9";
        };
      work =
        Work_store.empty
        |> Work_store.apply_planning ~observed_at:t0
             { goals = [ goal_confirm; goal_exec ]; tasks = [ task1 ] }
        |> Work_store.apply_verifications ~observed_at:t0 [ ver1 ];
    }
  in
  (* [n] on Work_pipeline opens honest #goals proposal modal (not Schedule); on Work_tasks_schedules opens Schedule *)
  let m_goal_modal, _ = step m_work (char_key "n") in
  Alcotest.(check bool) "[n] on Work_pipeline opens #goals Board proposal modal" true
    (match m_goal_modal.inline_modal with
    | Some md ->
        List.exists
          (fun (f : Model.modal_form_field) ->
            String.equal f.key "proposal_title")
          md.fields
    | None -> false);
  (* Work_pipeline pane_index=1 reaches Verification hotkeys & dive even when Goals exist *)
  let m_work_vp = { m_work with nav = { m_work.nav with pane_index = 1 } } in
  let _, cmds_wp_vapp = step m_work_vp (char_key "a") in
  Alcotest.(check bool) "Work_pipeline pane 1 [a] approves verification" true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_verification_verdict
                   {
                     verification_id = "ver-100";
                     verdict = Wire_work.Verdict_approve;
                     _;
                   };
               _;
             } ->
             true
         | _ -> false)
       cmds_wp_vapp);
  let m_wp_vdive, _ = step m_work_vp (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Work_pipeline pane 1 Enter dives into Verification_dive"
    true
    (match Model.active_dive m_wp_vdive with
    | Some (Nav.Dive_work (Nav.Verification_dive "ver-100")) -> true
    | _ -> false);
  let m_sched_tab =
    { m_work with work = Work_store.set_tab Nav.Work_schedules m_work.work }
  in
  let m_sched_modal, _ = step m_sched_tab (char_key "n") in
  Alcotest.(check bool) "[n] on Work_schedules opens Schedule_form" true
    (Option.equal Nav.equal_overlay m_sched_modal.nav.overlay
       (Some (Nav.Inline_action Nav.Schedule_form)));

  (* Verification_dive: [a] approve, [x] -> Verification_reject modal -> submit, [Space] JSON *)
  let m_vdive =
    {
      m_work with
      nav = { m_work.nav with dive_stack = [ Nav.Dive_work (Nav.Verification_dive "ver-100") ] };
    }
  in
  let _, cmds_vapp = step m_vdive (char_key "a") in
  Alcotest.(check bool) "Verification_dive [a] emits Verdict_approve" true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_verification_verdict
                   {
                     verification_id = "ver-100";
                     verdict = Wire_work.Verdict_approve;
                     _;
                   };
               _;
             } ->
             true
         | _ -> false)
       cmds_vapp);
  let m_vrej, _ = step m_vdive (char_key "x") in
  Alcotest.(check bool) "Verification_dive [x] opens Verification_reject modal" true
    (Option.equal Nav.equal_overlay m_vrej.nav.overlay
       (Some (Nav.Inline_action (Nav.Verification_reject "ver-100"))));
  let m_vrej_typed, _ = step m_vrej (char_key "b") in
  let m_vrej_done, cmds_vrej = step m_vrej_typed (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Verification_reject submit emits Verdict_reject" true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_verification_verdict
                   {
                     verification_id = "ver-100";
                     verdict = Wire_work.Verdict_reject _;
                     _;
                   };
               _;
             } ->
             true
         | _ -> false)
       cmds_vrej);
  Alcotest.(check bool) "Verification_reject closes modal cleanly on submit (no hang)"
    true
    (Option.is_none m_vrej_done.inline_modal
     && Option.is_none m_vrej_done.nav.overlay);
  let m_hov, _ = step m_vdive (char_key "h") in
  Alcotest.(check bool) "Verification_dive [h] opens Harness_overrule modal with empty hash" true
    (Option.equal Nav.equal_overlay m_hov.nav.overlay
       (Some (Nav.Inline_action (Nav.Harness_overrule ""))));
  let valid_hash64 =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  in
  let m_hov_hash =
    String.fold_left
      (fun acc ch -> fst (step acc (char_key (String.make 1 ch))))
      m_hov valid_hash64
  in
  let m_hov_f1, _ = step m_hov_hash (key Keymap.Input.Down) in
  let m_hov_f2, _ = step m_hov_f1 (key Keymap.Input.Down) in
  let m_hov_typed, _ = step m_hov_f2 (char_key "r") in
  let _, cmds_hov = step m_hov_typed (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Harness_overrule submit emits Post_harness_overrule" true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_harness_overrule
                   {
                     notes_hash;
                     verdict = `Approve;
                     reason = "r";
                   };
               _;
             }
           when String.equal notes_hash valid_hash64 ->
             true
         | _ -> false)
       cmds_hov);
  let m_vjson, _ = step m_vdive (char_key " ") in
  Alcotest.(check bool) "Work_dive [Space] toggles show_raw_json" true
    m_vjson.infra.show_raw_json;

  (* Task_dive [x] -> Task_cancel modal -> submit *)
  let m_tdive =
    {
      m_work with
      nav = { m_work.nav with dive_stack = [ Nav.Dive_work (Nav.Task_dive "task-100") ] };
    }
  in
  let m_tc, _ = step m_tdive (char_key "x") in
  Alcotest.(check bool) "Task_dive [x] opens Task_cancel modal" true
    (Option.equal Nav.equal_overlay m_tc.nav.overlay
       (Some (Nav.Inline_action (Nav.Task_cancel "task-100"))));
  let _, cmds_tc = step m_tc (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Task_cancel submit emits Post_task_cancel" true
    (has_cmd
       (function
         | Cmd.Http_post
             { req = Cmd.Post_task_cancel { task_id = "task-100"; _ }; _ } ->
             true
         | _ -> false)
       cmds_tc);
  (* What goes on the wire: the cancel and Goal routes refuse a body that does
     not name the workspace [/health] reported. *)
  let posted_requests cmds =
    List.filter_map
      (function
        | Cmd.Http_post { req; _ } -> Some req
        | Cmd.Batch _ | Cmd.Http_get _ | Cmd.Http_put _
        | Cmd.Http_post_stream _ | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _ | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _ | Cmd.Render_memory_diagram _
        | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _
        | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _ | Cmd.Start_local_server
        | Cmd.Restart_tui | Cmd.Quit _ ->
            None)
      (Cmd.flatten cmds)
  in
  let posted_bodies cmds =
    List.map Cmd.post_request_body (posted_requests cmds)
  in
  let posted_field key cmds =
    List.map
      (fun body -> Yojson.Safe.to_string (Yojson.Safe.Util.member key body))
      (posted_bodies cmds)
  in
  let health_workspace_json =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("base_path", `String ws_id.base_path);
           ("masc_root", `String ws_id.masc_root);
         ])
  in
  Alcotest.(check (list string))
    "Task_cancel body names the workspace /health reported"
    [ health_workspace_json ]
    (posted_field "expected_workspace" cmds_tc);
  let without_workspace (m : Model.t) =
    { m with server_identity = { m.server_identity with workspace = None } }
  in
  let m_tc_unknown, cmds_tc_unknown =
    step (without_workspace m_tc) (key Keymap.Input.Enter)
  in
  Alcotest.(check int) "Task_cancel posts nothing before /health names the workspace"
    0
    (List.length (posted_bodies cmds_tc_unknown));
  Alcotest.(check bool) "Task_cancel keeps its modal open with an error" true
    (match m_tc_unknown.inline_modal with
    | Some md -> Option.is_some md.error
    | None -> false);

  (* Schedule form -> the masc_schedule_create fields: a Keeper wake, one
     delay as its due input, and the repeat it reads. *)
  let fill_modal values (m : Model.t) =
    match m.inline_modal with
    | None -> Alcotest.fail "expected an open modal"
    | Some md ->
        let fields =
          List.map
            (fun (f : Model.modal_form_field) ->
              match List.assoc_opt f.key values with
              | Some value -> { f with value }
              | None -> f)
            md.fields
        in
        { m with inline_modal = Some { md with fields } }
  in
  let _, cmds_sched =
    step
      (fill_modal
         [
           ("keeper", "alpha");
           ("first_run_in", "10m");
           ("prompt", "Check the queue");
         ]
         m_sched_modal)
      (key Keymap.Input.Enter)
  in
  Alcotest.(check bool) "Schedule form posts keeper_name, message, delay and repeat"
    true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_schedule_create
                   {
                     keeper_name = "alpha";
                     message = "Check the queue";
                     first_due_in_sec = 600;
                     repeat = Wire_work.Repeat_every { interval_sec = 3600 };
                   };
               _;
             } ->
             true
         | _ -> false)
       cmds_sched);
  let m_sched_bad, cmds_sched_bad =
    step
      (fill_modal
         [
           ("keeper", "alpha");
           ("recurrence", "hourly");
           ("first_run_in", "10m");
           ("prompt", "Check the queue");
         ]
         m_sched_modal)
      (key Keymap.Input.Enter)
  in
  Alcotest.(check int) "Schedule form posts nothing for a repeat it cannot read" 0
    (List.length (posted_bodies cmds_sched_bad));
  Alcotest.(check bool) "Schedule form stays open with an error" true
    (match m_sched_bad.inline_modal with
    | Some md -> Option.is_some md.error
    | None -> false);

  (* Connector form -> the bind route's only inputs: the connector as the
     [name] query parameter, and channel_id and keeper_name in the body. *)
  let m_conn_modal, _ = Update_nav.open_inline_modal m_work Nav.Connector_form in
  let _, cmds_conn =
    step
      (fill_modal
         [ ("connector", "discord"); ("channel", "1234"); ("keeper", "alpha") ]
         m_conn_modal)
      (key Keymap.Input.Enter)
  in
  Alcotest.(check (list string)) "Connector form names the connector in the query"
    [ "/api/v1/gate/connector/bind?name=discord" ]
    (List.map Cmd.post_request_path (posted_requests cmds_conn));
  Alcotest.(check (list string)) "Connector form posts channel_id and keeper_name"
    [ {|{"channel_id":"1234","keeper_name":"alpha"}|} ]
    (List.map Yojson.Safe.to_string (posted_bodies cmds_conn));

  (* Goal_dive: Awaiting_confirmation [a] NEVER fabricates proof — opens explicit server-proof modal *)
  let m_gdive_conf =
    {
      m_work with
      nav = { m_work.nav with dive_stack = [ Nav.Dive_work (Nav.Goal_dive "goal-100") ] };
    }
  in
  let m_gconf_mod, cmds_gconf0 = step m_gdive_conf (char_key "a") in
  Alcotest.(check bool) "Goal_dive [a] never fires fabricated Post_goal_confirmation directly"
    false
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_goal_confirmation _; _ } -> true
         | _ -> false)
       cmds_gconf0);
  Alcotest.(check bool) "Goal_dive [a] opens explicit proof modal with empty server-issued fields"
    true
    (match m_gconf_mod.inline_modal with
    | Some md ->
        String.equal (Model.modal_field_value ~key:"confirm_request_id" md) ""
        && String.equal
             (Model.modal_field_value ~key:"confirm_verification_run_id" md)
             ""
        && String.equal (Model.modal_field_value ~key:"confirm_operator_id" md) ""
    | None -> false);
  (* Empty proof submit is rejected without POST *)
  let m_gconf_err, cmds_gconf_empty = step m_gconf_mod (key Keymap.Input.Enter) in
  Alcotest.(check int) "empty proof modal emits 0 cmds" 0
    (List.length (Cmd.flatten cmds_gconf_empty));
  Alcotest.(check bool) "empty proof modal sets validation error" true
    (match m_gconf_err.inline_modal with
    | Some { error = Some _; _ } -> true
    | _ -> false);
  (* Operator supplies genuine server-issued proof fields -> submits & closes modal *)
  let m_gconf_filled =
    match m_gconf_mod.inline_modal with
    | None -> Alcotest.fail "expected proof modal"
    | Some md ->
        let fields =
          List.map
            (fun (f : Model.modal_form_field) ->
              match f.key with
              | "confirm_request_id" -> { f with value = "srv-req-42" }
              | "confirm_verification_run_id" -> { f with value = "srv-run-99" }
              | "confirm_operator_id" -> { f with value = "op-admin" }
              | _ -> f)
            md.fields
        in
        { m_gconf_mod with inline_modal = Some { md with fields } }
  in
  let m_gconf_done, cmds_gconf = step m_gconf_filled (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Goal confirmation modal with operator proof emits Post_goal_confirmation"
    true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_goal_confirmation
                   {
                     goal_id = "goal-100";
                     criterion_revision = "rev-7";
                     request_id = "srv-req-42";
                     verification_run_id = "srv-run-99";
                     expected_operator_id = "op-admin";
                     expected_runtime_instance_id = "inst-9";
                     _;
                   };
               _;
             } ->
             true
         | _ -> false)
       cmds_gconf);
  Alcotest.(check bool) "Goal confirmation modal closes on submit" true
    (Option.is_none m_gconf_done.inline_modal
     && Option.is_none m_gconf_done.nav.overlay);
  let m_gdive_exec =
    {
      m_work with
      nav = { m_work.nav with dive_stack = [ Nav.Dive_work (Nav.Goal_dive "goal-101") ] };
    }
  in
  let _, cmds_greq = step m_gdive_exec (char_key "a") in
  Alcotest.(check bool) "Goal_dive Executing [a] emits Request_complete" true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_goal_transition
                   { goal_id = "goal-101"; action = Wire_work.Request_complete; _ };
               _;
             } ->
             true
         | _ -> false)
       cmds_greq);
  Alcotest.(check (list string))
    "Goal transition body names the workspace /health reported"
    [ health_workspace_json ]
    (posted_field "expected_workspace" cmds_greq);
  let _, cmds_greq_unknown = step (without_workspace m_gdive_exec) (char_key "a") in
  Alcotest.(check int)
    "Goal transition posts nothing before /health names the workspace" 0
    (List.length (posted_bodies cmds_greq_unknown));
  let _, cmds_gpause = step m_gdive_exec (char_key "x") in
  Alcotest.(check bool) "Goal_dive Executing [x] emits Pause" true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_goal_transition
                   { goal_id = "goal-101"; action = Wire_work.Pause; _ };
               _;
             } ->
             true
         | _ -> false)
       cmds_gpause);

  (* 3. Knowledge: Memory [a] -> Post_memory_act, Wiki [e]/[Ctrl+E] -> Put_wiki_page / Edit_wiki_page *)
  let m_kmem =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Knowledge };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.set_tab Nav.Knowledge_memory
        |> Knowledge_store.set_memory_diff_keeper (Some "alpha");
    }
  in
  let _, cmds_mact = step m_kmem (char_key "a") in
  Alcotest.(check bool) "Knowledge/Memory [a] emits Post_memory_act" true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_memory_act
                   { keeper = "alpha"; act = Wire_knowledge.Act_resume };
               _;
             } ->
             true
         | _ -> false)
       cmds_mact);
  let wiki_page : Wire_knowledge.wiki_page_detail =
    {
      page = "guide";
      slug = "guide";
      file = "guide.md";
      frontmatter =
        {
          title = "Guide";
          summary = "Summary";
          source = Wire_knowledge.Source_observation;
          author = "alpha";
          created = "2026-11-20";
          updated = "2026-11-22";
          revision = 3;
          tags = [ "ops" ];
        };
      sha256 = "sha-w3";
      body_markdown = "# Guide\nBody text";
      outgoing_links = [];
      backlinks = [];
      lint_findings = [];
    }
  in
  let m_wiki =
    {
      m0 with
      nav =
        {
          m0.nav with
          workspace = Nav.Knowledge;
          dive_stack = [ Nav.Dive_knowledge (Nav.Wiki_dive "guide") ];
        };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.set_wiki_page ~slug:wiki_page.slug
             (Observed.value ~observed_at:t0 wiki_page);
    }
  in
  let m_wedit, _ = step m_wiki (char_key "e") in
  let m_wedit_done, cmds_wput = step m_wedit (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Wiki [e] inline modal submit emits Put_wiki_page" true
    (has_cmd
       (function
         | Cmd.Http_put
             {
               req =
                 Cmd.Put_wiki_page
                   { page = "guide"; request = { expected_revision = Some 3; _ } };
               _;
             } ->
             true
         | _ -> false)
       cmds_wput);
  Alcotest.(check bool) "Wiki [e] modal closes on submit (no hang)" true
    (Option.is_none m_wedit_done.inline_modal
     && Option.is_none m_wedit_done.nav.overlay);
  (* The PUT answer names the revision written but no page, so the stored
     page is stale and the Wiki dive reads it again. *)
  let saved : Wire_knowledge.wiki_put_result =
    { action = Wire_knowledge.Wiki_page_updated; revision = 4; warnings = [] }
  in
  let m_wsaved, cmds_wsaved =
    Update.step ~now:t1 m_wedit_done
      (Msg.Http_reply
         {
           epoch = m_wedit_done.epoch;
           reply = Msg.Reply_wiki_put { page = "guide"; result = Ok saved };
         })
  in
  Alcotest.(check bool) "a saved wiki page is stale until it is read again" true
    (Observed.is_stale
       (Knowledge_store.wiki_page_for ~slug:"guide" m_wsaved.knowledge));
  Alcotest.(check bool) "the Wiki dive reads the saved page again" true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_wiki_page { page = "guide" }; _ } -> true
         | _ -> false)
       cmds_wsaved);
  (* Until that read lands the slot holds revision 3, so [e] waits for the
     page instead of opening a form on the text the save replaced, remembers
     the pending edit intent, and opens the modal automatically once rev 4
     arrives while still viewing the page (Issue #54490). *)
  let m_wagain, cmds_wagain = step m_wsaved (char_key "e") in
  Alcotest.(check bool) "[e] right after a save opens no form yet" true
    (Option.is_none m_wagain.inline_modal);
  Alcotest.(check (option string)) "[e] right after a save remembers pending slug"
    (Some "guide") m_wagain.knowledge.pending_wiki_edit_slug;
  Alcotest.(check bool) "[e] right after a save asks for the page" true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_wiki_page { page = "guide" }; _ } -> true
         | _ -> false)
       cmds_wagain);
  let page_r4 =
    {
      wiki_page with
      frontmatter = { wiki_page.frontmatter with revision = 4 };
      sha256 = "sha-w4";
      body_markdown = "# Guide\n\nRevision 4 body.";
    }
  in
  let m_wauto, _ =
    Update.step ~now:t1 m_wagain
      (Msg.Http_reply
         {
           epoch = m_wagain.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  Alcotest.(check (option string)) "pending wiki edit slug cleared on auto-open"
    None m_wauto.knowledge.pending_wiki_edit_slug;
  (match m_wauto.inline_modal, m_wauto.knowledge.wiki_edit_base with
  | Some modal, Some base ->
      Alcotest.(check int) "auto-opened modal uses fresh revision 4" 4
        base.revision;
      Alcotest.(check string) "auto-opened modal body uses fresh page"
        "# Guide\n\nRevision 4 body."
        (Model.modal_field_value ~key:"wiki_body" modal)
  | _ -> Alcotest.fail "expected edit modal to auto-open on Reply_wiki_page");
  (* Navigating away before the reply arrives clears pending without hijacking. *)
  let m_waway =
    { m_wagain with nav = { m_wagain.nav with workspace = Nav.Pulse; dive_stack = [] } }
  in
  let m_waway_replied, _ =
    Update.step ~now:t1 m_waway
      (Msg.Http_reply
         {
           epoch = m_waway.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  Alcotest.(check bool) "navigating away suppresses auto-open" true
    (Option.is_none m_waway_replied.inline_modal
     && Option.is_none m_waway_replied.knowledge.pending_wiki_edit_slug);
  (* Fetch error clears pending so a later background reply does not pop open. *)
  let m_werr, _ =
    Update.step ~now:t1 m_wagain
      (Msg.Http_reply
         {
           epoch = m_wagain.epoch;
           reply =
             Msg.Reply_wiki_page
               {
                 page = "guide";
                 result =
                   Error
                     (Msg.Http_error
                        { status = 503; body = "unavailable"; api_error = None });
               };
         })
  in
  Alcotest.(check (option string)) "fetch error clears pending wiki edit slug"
    None m_werr.knowledge.pending_wiki_edit_slug;
  let m_werr_later, _ =
    Update.step ~now:t1 m_werr
      (Msg.Http_reply
         {
           epoch = m_werr.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  Alcotest.(check bool) "reply after fetch error does not surprise-open modal"
    true (Option.is_none m_werr_later.inline_modal);
  (* Wiki tab (not dive) also auto-opens on first load when [e] is pressed. *)
  let wiki_summary : Wire_knowledge.wiki_page_summary =
    {
      slug = "guide";
      file = "guide.md";
      title = "Guide";
      summary = "Operator guide";
      source = Wire_knowledge.Source_observation;
      author = "operator";
      created = "2026-11-24T00:00:00Z";
      updated = "2026-11-24T00:00:00Z";
      revision = 4;
      tags = [ "ops" ];
      backlink_count = 0;
      outgoing_link_count = 0;
      sources_count = 0;
      hearsay_count = 0;
      sha256 = "sha-w4";
    }
  in
  let wiki_idx : Wire_knowledge.wiki_index =
    {
      pages_total = 1;
      pages_readable = 1;
      pages_unreadable = 0;
      pages = [ wiki_summary ];
      unreadable_pages = [];
      lint =
        {
          total_findings = 0;
          counts =
            {
              broken_link = 0;
              unsupported_link = 0;
              orphan = 0;
              orphan_unconfirmed = 0;
              missing_sources = 0;
              hearsay_only = 0;
              unreadable_page = 0;
              revision_log_gap = 0;
              revision_log_hole = 0;
              duplicate_title_candidates = 0;
            };
          log_hole_suppressed = false;
          orphans = [];
          duplicate_title_candidates = [];
          findings = [];
        };
    }
  in
  let m_wtab =
    {
      m_wiki with
      nav = { m_wiki.nav with workspace = Nav.Knowledge; dive_stack = [] };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.set_tab Nav.Knowledge_wiki
        |> Knowledge_store.apply_wiki_index ~observed_at:t1 wiki_idx;
    }
  in
  let m_wtab_req, cmds_wtab_req = step m_wtab (char_key "e") in
  Alcotest.(check (option string)) "Wiki tab [e] before load records pending slug"
    (Some "guide") m_wtab_req.knowledge.pending_wiki_edit_slug;
  Alcotest.(check bool) "Wiki tab [e] before load requests page" true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_wiki_page { page = "guide" }; _ } -> true
         | _ -> false)
       cmds_wtab_req);
  let m_wtab_open, _ =
    Update.step ~now:t1 m_wtab_req
      (Msg.Http_reply
         {
           epoch = m_wtab_req.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  Alcotest.(check bool) "Wiki tab auto-opens edit modal on Reply_wiki_page" true
    (Option.is_some m_wtab_open.inline_modal
     && Option.is_none m_wtab_open.knowledge.pending_wiki_edit_slug);
  (* Opening an overlay before Reply_wiki_page arrives suppresses auto-open. *)
  let m_wtab_help =
    { m_wtab_req with nav = { m_wtab_req.nav with overlay = Some Nav.Help } }
  in
  let m_wtab_help_replied, _ =
    Update.step ~now:t1 m_wtab_help
      (Msg.Http_reply
         {
           epoch = m_wtab_help.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  Alcotest.(check bool) "active overlay suppresses wiki edit auto-open" true
    (Option.is_none m_wtab_help_replied.inline_modal
     && Option.equal Nav.equal_overlay m_wtab_help_replied.nav.overlay
          (Some Nav.Help)
     && Option.is_none m_wtab_help_replied.knowledge.pending_wiki_edit_slug);
  (* P2 #1a: Esc popping Wiki_dive clears pending so returning to same slug on
     Wiki tab does not auto-open the modal when Reply_wiki_page arrives. *)
  let m_dive_esc, _ = step m_wagain (key Keymap.Input.Escape) in
  Alcotest.(check (option string)) "Esc popping Wiki_dive clears pending slug"
    None m_dive_esc.knowledge.pending_wiki_edit_slug;
  (* P2 #1b: Esc on Knowledge_wiki tab cancels pending edit intent. *)
  let m_tab_esc, _ = step m_wtab_req (key Keymap.Input.Escape) in
  Alcotest.(check (option string)) "Esc on Wiki tab cancels pending slug"
    None m_tab_esc.knowledge.pending_wiki_edit_slug;
  (* P2 #2: Moving focus to sidebar, filter bar, or composer suppresses auto-open. *)
  let m_tab_sidebar =
    {
      m_wtab_req with
      nav = { m_wtab_req.nav with sidebar_focused = true; sidebar_open = Some true };
    }
  in
  let m_tab_sidebar_replied, _ =
    Update.step ~now:t1 m_tab_sidebar
      (Msg.Http_reply
         {
           epoch = m_tab_sidebar.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  Alcotest.(check bool) "sidebar focus suppresses wiki edit auto-open" true
    (Option.is_none m_tab_sidebar_replied.inline_modal
     && Option.is_none m_tab_sidebar_replied.knowledge.pending_wiki_edit_slug);
  let m_tab_filter =
    { m_wtab_req with nav = { m_wtab_req.nav with filter_focused = true } }
  in
  let m_tab_filter_replied, _ =
    Update.step ~now:t1 m_tab_filter
      (Msg.Http_reply
         {
           epoch = m_tab_filter.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  Alcotest.(check bool) "filter focus suppresses wiki edit auto-open" true
    (Option.is_none m_tab_filter_replied.inline_modal
     && Option.is_none m_tab_filter_replied.knowledge.pending_wiki_edit_slug);
  let m_tab_composer =
    { m_wtab_req with drafts = Drafts.set_focus true m_wtab_req.drafts }
  in
  let m_tab_composer_replied, _ =
    Update.step ~now:t1 m_tab_composer
      (Msg.Http_reply
         {
           epoch = m_tab_composer.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  Alcotest.(check bool) "composer focus suppresses wiki edit auto-open" true
    (Option.is_none m_tab_composer_replied.inline_modal
     && Option.is_none m_tab_composer_replied.knowledge.pending_wiki_edit_slug);
  (* A form opened on revision 3 saves against revision 3 even when
     revision 4 lands while it is open: the server then refuses the save
     instead of writing the old text over revision 4. *)
  let m_wopen, _ = step m_wiki (char_key "e") in
  let m_wr4, _ =
    Update.step ~now:t1 m_wopen
      (Msg.Http_reply
         {
           epoch = m_wopen.epoch;
           reply =
             Msg.Reply_wiki_page { page = page_r4.slug; result = Ok page_r4 };
         })
  in
  let _, cmds_wbase = step m_wr4 (key Keymap.Input.Enter) in
  Alcotest.(check bool) "the save names the revision the form opened on" true
    (has_cmd
       (function
         | Cmd.Http_put
             {
               req =
                 Cmd.Put_wiki_page
                   {
                     page = "guide";
                     request =
                       {
                         expected_revision = Some 3;
                         expected_sha256 = Some "sha-w3";
                         _;
                       };
                   };
               _;
             } ->
             true
         | _ -> false)
       cmds_wbase);
  let m_mact_mod, _ = step m_kmem (char_key "A") in
  let m_mact_done, cmds_mact_mod = step m_mact_mod (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Memory [A] modal closes on submit and emits Post_memory_act"
    true
    (Option.is_none m_mact_done.inline_modal
     && Option.is_none m_mact_done.nav.overlay
     && has_cmd
          (function
            | Cmd.Http_post { req = Cmd.Post_memory_act { keeper = "alpha"; _ }; _ } ->
                true
            | _ -> false)
          cmds_mact_mod);
  let _, cmds_wext = step m_wiki (char_key ~ctrl:true "e") in
  Alcotest.(check bool) "Wiki [Ctrl+E] emits Edit_wiki_page" true
    (has_cmd
       (function
         | Cmd.Open_editor_escape_hatch (Cmd.Edit_wiki_page "guide") -> true
         | _ -> false)
       cmds_wext);

  (* 4. Infra [p] -> Post_sandbox_probe; Runtime [f] -> Post_fusion_launch & [r] Quotas force=true *)
  let m_infra =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Infra };
      infra = Infra_store.set_tab Nav.Infra_sandboxes Infra_store.empty;
    }
  in
  let _, cmds_probe = step m_infra (char_key "p") in
  Alcotest.(check bool) "Infra Sandboxes [p] emits Post_sandbox_probe" true
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_sandbox_probe _; _ } -> true
         | _ -> false)
       cmds_probe);
  let m_rt =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Runtime };
      runtime =
        Runtime_store.empty
        |> Runtime_store.set_tab Nav.Runtime_quotas_credits
        |> Runtime_store.set_fusion_keeper (Some "alpha")
        |> Runtime_store.set_fusion_prompt "Investigate latency";
    }
  in
  let _, cmds_qref = step m_rt (char_key "r") in
  Alcotest.(check bool) "Runtime Quotas [r] emits Get_runtime_probe force=true" true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_runtime_probe { force = true }; _ } ->
             true
         | _ -> false)
       cmds_qref);
  let m_q_f, _ = step m_rt (char_key "f") in
  Alcotest.(check bool) "Runtime Quotas [f] does NOT bleed Fusion modal" true
    (Option.is_none m_q_f.inline_modal);
  let m_rt_failover =
    {
      m_rt with
      runtime = Runtime_store.set_tab Nav.Runtime_failover_lanes m_rt.runtime;
    }
  in
  let m_fmod, _ = step m_rt_failover (char_key "f") in
  let m_fmod_done, cmds_flaunch = step m_fmod (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Runtime Failover [f] modal submit emits Post_fusion_launch" true
    (has_cmd
       (function
         | Cmd.Http_post
             { req = Cmd.Post_fusion_launch { keeper = "alpha"; _ }; _ } ->
             true
         | _ -> false)
       cmds_flaunch);
  Alcotest.(check bool) "Fusion modal closes cleanly on submit (no hang)" true
    (Option.is_none m_fmod_done.inline_modal
     && Option.is_none m_fmod_done.nav.overlay);
  (* Runtime Failover Enter with non-empty fusion_launch_draft dives into Lane_dive, NEVER fires Post_fusion_launch *)
  let rt_with_lane =
    m_rt_failover.runtime
    |> Runtime_store.apply_runtime_resolved ~observed_at:t0
         {
           generated_at_iso = "2026-11-22T00:00:00Z";
           config_path = None;
           default_route = Some "lane-default";
           lanes = [ { id = "lane-default"; declared = true; runtime_ids = [ "sonnet-4" ] } ];
           runtimes = [];
           usage_windows = None;
         }
  in
  let m_rt_quotas_with_lane =
    {
      m_rt with
      runtime = Runtime_store.set_tab Nav.Runtime_quotas_credits rt_with_lane;
    }
  in
  let m_rt_q_enter, _ = step m_rt_quotas_with_lane (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Runtime Quotas Enter does NOT dive stale Lane_dive" true
    (Option.is_none (Model.active_dive m_rt_q_enter));
  let m_rt_lane = { m_rt_failover with runtime = rt_with_lane } in
  let m_rt_enter, cmds_rt_enter = step m_rt_lane (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Runtime Enter does NOT hijack with Post_fusion_launch" false
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_fusion_launch _; _ } -> true
         | _ -> false)
       cmds_rt_enter);
  Alcotest.(check bool) "Runtime Failover Enter dives into Lane_dive" true
    (match Model.active_dive m_rt_enter with
    | Some (Nav.Dive_infra (Nav.Lane_dive "lane-default")) -> true
    | _ -> false);

  (* 5. Keepers: active turn interrupt (Esc & Ctrl+X), Copy ([y]), [c] quick chat, Server_offline [s], /model *)
  let chat_page : Wire_fleet.chat_history_page =
    {
      messages =
        [
          {
            id = "m1";
            role = Wire_fleet.Role_assistant;
            content = "Latest assistant answer for clipboard";
            ts_unix = 100.0;
            turn_ref = None;
            model_used = None;
            tool_call_id = None;
            tool_call_name = None;
            execution_id = None;
            operation_id = None;
            transcript_slot = None;
            failure_kind = None;
          };
        ];
      has_more = false;
      next_cursor = None;
    }
  in
  let m_kchat =
    {
      m0 with
      nav =
        {
          m0.nav with
          workspace = Nav.Keepers;
          dive_stack = [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat } ];
        };
      fleet =
        Fleet_store.empty
        |> Fleet_store.apply_chat_history ~observed_at:t0 ~keeper:"alpha" chat_page
        |> Fleet_store.apply_turns ~observed_at:t0
             [
               {
                 keeper_name = "alpha";
                 chat_control_token = Some "ctrl-1";
                 state =
                   Wire_fleet.Turn_active
                     {
                       lane = Wire_fleet.Lane_chat;
                       started_at_unix = 100.0;
                       interrupt_token = "int-tok-7";
                       phase = Some "thinking";
                       tool_in_flight = None;
                       elapsed_ms = Some 500.0;
                     };
               };
             ];
    }
  in
  let _, cmds_int_esc = step m_kchat (key Keymap.Input.Escape) in
  Alcotest.(check bool) "Keeper_chat active turn Esc emits Post_keeper_turn_interrupt"
    true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_keeper_turn_interrupt
                   { keeper = "alpha"; target = `Turn_token "int-tok-7" };
               _;
             } ->
             true
         | _ -> false)
       cmds_int_esc);
  let _, cmds_int_cx = step m_kchat (char_key ~ctrl:true "x") in
  Alcotest.(check bool) "Ctrl+X emits Post_keeper_turn_interrupt" true
    (has_cmd
       (function
         | Cmd.Http_post
             { req = Cmd.Post_keeper_turn_interrupt { keeper = "alpha"; _ }; _ } ->
             true
         | _ -> false)
       cmds_int_cx);
  let _, cmds_copy = step m_kchat (char_key "y") in
  Alcotest.(check bool) "Keeper_chat [y] copies latest assistant reply" true
    (has_cmd
       (function
         | Cmd.Copy_clipboard "Latest assistant answer for clipboard" ->
             true
         | _ -> false)
       cmds_copy);
  (* P2-7a: Finished (active=false) chat_streams MUST NOT shadow newer chat_histories *)
  let m_kchat_stale_stream =
    let fleet =
      m_kchat.fleet
      |> Fleet_store.start_chat_stream ~keeper:"alpha" ~request_id:"old-req"
      |> Fleet_store.apply_chat_stream_chunk ~keeper:"alpha" ~request_id:"old-req"
           (Wire_fleet.Chunk_text_delta
              {
                operation_id = Some "op-old";
                delta = "Stale previous stream text";
                owner = Wire_chat_journal.Unobserved_scope None;
              })
      |> Fleet_store.finish_chat_stream ~keeper:"alpha" ~request_id:"old-req"
           ~error:None
    in
    { m_kchat with fleet }
  in
  let _, cmds_copy_fresh = step m_kchat_stale_stream (char_key "y") in
  Alcotest.(check bool) "finished stream does NOT shadow newer history on [y]" true
    (has_cmd
       (function
         | Cmd.Copy_clipboard "Latest assistant answer for clipboard" ->
             true
         | _ -> false)
       cmds_copy_fresh);
  (* P2-7b: Media_viewer [y] copies raw body (or fetches & copies), [H] copies SHA256 *)
  let art1 : Wire_knowledge.artifact_entry =
    {
      id = "artifact-0123456789abcdef0123456789abcdef";
      revision = 1;
      title = "Report";
      summary = "Daily report";
      author = "alpha";
      created_at_unix = 1700000000.0;
      body = { sha256 = "deadbeef0123456789"; bytes = 1024; mime = "text/html" };
    }
  in
  let m_mv =
    {
      m0 with
      nav = { m0.nav with overlay = Some (Nav.System_gate Nav.Media_viewer) };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.apply_artifacts ~observed_at:t0 [ art1 ];
    }
  in
  let _, cmds_mv_y = step m_mv (char_key "y") in
  Alcotest.(check bool) "Media_viewer [y] fetches full body when detail absent"
    true
    (has_cmd
       (function
         | Cmd.Fetch_artifact_and_copy { id; _ } when String.equal id art1.id ->
             true
         | _ -> false)
       cmds_mv_y);
  let _, cmds_mv_h = step m_mv (char_key "H") in
  Alcotest.(check bool) "Media_viewer [H] copies artifact SHA256" true
    (has_cmd
       (function
         | Cmd.Copy_clipboard "deadbeef0123456789" -> true
         | _ -> false)
       cmds_mv_h);
  let art1_detail : Wire_knowledge.published_artifact_detail =
    {
      artifact = art1;
      content = "<!doctype html><h1>Full Report</h1>";
      revisions = [];
      shared = false;
      share_version = 0;
    }
  in
  let m_mv_loaded =
    {
      m_mv with
      knowledge =
        Knowledge_store.apply_artifact_detail ~observed_at:t0 art1_detail
          m_mv.knowledge;
    }
  in
  let _, cmds_mv_y2 = step m_mv_loaded (char_key "y") in
  Alcotest.(check bool) "Media_viewer [y] copies loaded HTML content directly"
    true
    (has_cmd
       (function
         | Cmd.Copy_clipboard "<!doctype html><h1>Full Report</h1>" -> true
         | _ -> false)
       cmds_mv_y2);
  let m_offline =
    {
      m0 with
      nav =
        {
          m0.nav with
          overlay = Some (Nav.System_gate Nav.Server_offline);
        };
    }
  in
  let _, cmds_start = step m_offline (char_key "s") in
  Alcotest.(check bool) "Server_offline [s] emits Start_local_server" true
    (has_cmd (function Cmd.Start_local_server -> true | _ -> false) cmds_start);
  let m_mod, cmds_mod =
    Update.execute_slash ~now:t0 m0 (Slash.Model (Some "sonnet-4"))
  in
  Alcotest.(check bool) "/model opens Settings on Providers/Models" true
    (Option.equal Nav.equal_overlay m_mod.nav.overlay
       (Some (Nav.Settings Nav.Settings_providers_models)));
  Alcotest.(check string) "/model pre-fills Settings search query" "sonnet-4"
    m_mod.config.search_query;
  Alcotest.(check bool) "/model emits real cmds (never fake empty toast)" true
    (Cmd.flatten cmds_mod <> [])

(* --- Comprehensive Arrow Navigation, Display Order & Symmetric Scroll Regression Suite --- *)

let grouped_keeper ?(health = Wire_fleet.Keeper_healthy) ~group name :
    Wire_fleet.keeper_summary =
  {
    (sample_keeper ~health name) with
    group = Some group;
    company = group;
  }

let pulse_at ~starts_at turns : Wire_fleet.turn_pulse =
  {
    known_since = Float.of_int starts_at;
    slots =
      [
        {
          starts_at;
          ok = turns;
          rested = 0;
          failed = 0;
          scheduled = 0;
          reacted = 0;
          chat = 0;
          own = turns;
          unknown = 0;
        };
      ];
  }

let test_nav_fix1_keepers_grouped_order_collapse_and_resync () =
  let wall_slot = 1_795_251_600 in
  let wall_unix = Float.of_int (wall_slot + 60) in
  (* Scrambled raw order across 4 generic groups *)
  let raw_ks =
    [
      grouped_keeper ~group:"org-zeta" "zeta-1";
      grouped_keeper ~group:"org-alpha" "alpha-2";
      grouped_keeper ~group:"org-mid" "mid-1";
      grouped_keeper ~group:"org-beta" "beta-2";
      grouped_keeper ~group:"org-alpha" "alpha-1";
      grouped_keeper ~group:"org-beta" "beta-1";
    ]
  in
  let expected_grouped =
    [ "alpha-1"; "alpha-2"; "beta-1"; "beta-2"; "mid-1"; "zeta-1" ]
  in
  let f0 =
    Fleet_store.empty
    |> Fleet_store.set_wall_unix wall_unix
    |> Fleet_store.apply_keepers ~observed_at:t0 raw_ks
    |> Fleet_store.apply_roster_extras
         {
           sandbox_profiles = [];
           candle_balances_milli = [];
           candle_summary = None;
           turn_pulses =
             [
               ("zeta-1", pulse_at ~starts_at:wall_slot 5);
               ("alpha-2", pulse_at ~starts_at:wall_slot 1);
               ("mid-1", pulse_at ~starts_at:wall_slot 9);
               ("beta-2", pulse_at ~starts_at:wall_slot 3);
               ("alpha-1", pulse_at ~starts_at:wall_slot 2);
               ("beta-1", pulse_at ~starts_at:wall_slot 8);
             ];
         }
  in
  let names_of ks =
    List.map (fun (k : Wire_fleet.keeper_summary) -> k.name) ks
  in
  Alcotest.(check (list string))
    "Fleet_companies filtered_keepers matches exact Wire_fleet.group_by_company order"
    expected_grouped
    (names_of (Fleet_store.filtered_keepers f0));
  let flattened_groups =
    Fleet_store.company_groups f0
    |> List.concat_map (fun (g : Wire_fleet.company_group) -> g.keepers)
    |> names_of
  in
  Alcotest.(check (list string))
    "filtered_keepers equals flattened company_groups"
    flattened_groups
    (names_of (Fleet_store.filtered_keepers f0));
  Alcotest.(check (option string))
    "initial selection is first visual keeper (alpha-1)" (Some "alpha-1")
    f0.selected_keeper;
  Alcotest.(check int) "initial selected_index = 0" 0 f0.selected_index;
  (* Sequential Down presses walk strictly 0..5, then Up reverses cleanly *)
  let rec step_down f n acc =
    if n = 0 then List.rev acc
    else
      let f' = Fleet_store.move_selection ~viewport_rows:20 ~delta:1 f in
      step_down f' (n - 1) ((f'.selected_index, f'.selected_keeper) :: acc)
  in
  let down_trace = step_down f0 5 [ (f0.selected_index, f0.selected_keeper) ] in
  Alcotest.(check (list (pair int (option string))))
    "sequential Down walks strictly through grouped order"
    [
      (0, Some "alpha-1");
      (1, Some "alpha-2");
      (2, Some "beta-1");
      (3, Some "beta-2");
      (4, Some "mid-1");
      (5, Some "zeta-1");
    ]
    down_trace;
  (* Poll re-ordering preserves selected_keeper and syncs selected_index so next Down advances *)
  let f_mid = Fleet_store.select_keeper "mid-1" f0 in
  let f_reordered =
    Fleet_store.apply_keepers ~observed_at:t1 (List.rev raw_ks) f_mid
  in
  Alcotest.(check (option string))
    "poll reorder preserves selected_keeper=mid-1" (Some "mid-1")
    f_reordered.selected_keeper;
  Alcotest.(check int) "poll reorder keeps selected_index=4" 4
    f_reordered.selected_index;
  let f_after_down = Fleet_store.move_selection ~delta:1 f_reordered in
  Alcotest.(check (option string))
    "Down after poll reorder advances forward to zeta-1" (Some "zeta-1")
    f_after_down.selected_keeper;
  (* Collapsing org-beta skips beta-1/beta-2 cleanly; if selected was inside beta, snaps to nearest visible *)
  let f_on_beta = Fleet_store.select_keeper "beta-1" f0 in
  let f_collapsed = Fleet_store.toggle_company_collapsed "org-beta" f_on_beta in
  Alcotest.(check (list string))
    "collapsed org-beta skipped from filtered_keepers"
    [ "alpha-1"; "alpha-2"; "mid-1"; "zeta-1" ]
    (names_of (Fleet_store.filtered_keepers f_collapsed));
  Alcotest.(check (option string))
    "collapsing active group snaps to nearest visible (mid-1)" (Some "mid-1")
    f_collapsed.selected_keeper;
  Alcotest.(check int) "selected_index re-synced after collapse" 2
    f_collapsed.selected_index;
  let f_a2 = Fleet_store.select_keeper "alpha-2" f_collapsed in
  let f_skip = Fleet_store.move_selection ~delta:1 f_a2 in
  Alcotest.(check (option string))
    "Down from alpha-2 skips collapsed org-beta to mid-1" (Some "mid-1")
    f_skip.selected_keeper;
  (* Collapsing ALL companies falls back safely to all grouped keepers *)
  let f_all_collapsed =
    f0
    |> Fleet_store.toggle_company_collapsed "org-alpha"
    |> Fleet_store.toggle_company_collapsed "org-beta"
    |> Fleet_store.toggle_company_collapsed "org-mid"
    |> Fleet_store.toggle_company_collapsed "org-zeta"
  in
  Alcotest.(check (list string))
    "all-collapsed fallback preserves all grouped keepers"
    expected_grouped
    (names_of (Fleet_store.filtered_keepers f_all_collapsed));
  (* set_fleet_mode re-syncs selected_index to selected_keeper in new sort order *)
  let f_wall = Fleet_store.set_fleet_mode Nav.Fleet_pulse_wall f_mid in
  Alcotest.(check (option string))
    "set_fleet_mode preserves selected_keeper=mid-1" (Some "mid-1")
    f_wall.selected_keeper;
  Alcotest.(check int)
    "set_fleet_mode re-syncs selected_index=0 (highest 24h pulse)" 0
    f_wall.selected_index;
  (* set_filter hides selected keeper -> picks nearest visible cleanly *)
  let f_filt = Fleet_store.set_filter "alpha" f_mid in
  Alcotest.(check (option string))
    "set_filter hiding selected keeper picks nearest visible" (Some "alpha-1")
    f_filt.selected_keeper;
  Alcotest.(check int) "set_filter syncs selected_index=0" 0
    f_filt.selected_index

let test_nav_fix2_pulse_company_row_stepping () =
  let ks =
    [
      grouped_keeper ~group:"org-alpha" "alpha-1";
      grouped_keeper ~group:"org-alpha" "alpha-2";
      grouped_keeper ~group:"org-alpha" "alpha-3";
      grouped_keeper ~group:"org-beta" "beta-1";
      grouped_keeper ~group:"org-beta" "beta-2";
      grouped_keeper ~group:"org-gamma" "gamma-1";
      grouped_keeper ~group:"org-gamma" "gamma-2";
    ]
  in
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let m1, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         { epoch = m0.epoch; reply = Msg.Reply_keepers_roster (Ok (roster_of ks)) })
  in
  (* Select 3rd keeper inside org-alpha, switch to Pulse, press Down -> must land on org-beta lead *)
  let m_pulse =
    {
      m1 with
      nav = { m1.nav with workspace = Nav.Pulse };
      fleet = Fleet_store.select_keeper "alpha-3" m1.fleet;
    }
  in
  let m_d1, _ =
    Update.step ~now:t1 m_pulse (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check (option string))
    "Pulse Down from org-alpha member jumps strictly 1 company to beta-1"
    (Some "beta-1") m_d1.fleet.selected_keeper;
  let m_d2, _ =
    Update.step ~now:t1 m_d1 (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check (option string))
    "Pulse second Down jumps strictly 1 company to gamma-1" (Some "gamma-1")
    m_d2.fleet.selected_keeper;
  let m_u1, _ =
    Update.step ~now:t2 m_d2 (Msg.Key_event (key Keymap.Input.Up))
  in
  Alcotest.(check (option string))
    "Pulse Up jumps strictly 1 company back to beta-1" (Some "beta-1")
    m_u1.fleet.selected_keeper;
  let m_u2, _ =
    Update.step ~now:t2 m_u1 (Msg.Key_event (key Keymap.Input.Up))
  in
  Alcotest.(check (option string))
    "Pulse second Up jumps strictly 1 company back to alpha-1" (Some "alpha-1")
    m_u2.fleet.selected_keeper

let test_nav_fix3_runtime_efficiency_company_grouped_display_order () =
  let ks =
    [
      grouped_keeper ~group:"co-high" "high-1";
      grouped_keeper ~group:"co-high" "high-2";
      grouped_keeper ~group:"co-mid" "mid-1";
      grouped_keeper ~group:"co-mid" "mid-2";
      grouped_keeper ~group:"co-tie" "tie-1";
    ]
  in
  let mk_eff keeper cost_usd calls : Wire_runtime.keeper_efficiency_row =
    {
      keeper;
      turns = 10;
      input_tokens = 10000;
      cache_read_tokens = Observed.value ~observed_at:t0 8000;
      cache_creation_tokens = Observed.value ~observed_at:t0 0;
      output_tokens = 500;
      cache_hit_pct = Observed.value ~observed_at:t0 80.0;
      cost_usd;
      calls;
      failed = 0;
      deferred = 0;
      tool_ms = 120.0;
    }
  in
  (* Global USD sort would interleave companies: high-1(10), mid-1(8), tie-1(5), high-2(2), mid-2(1).
     Canonical grouped sort MUST order companies by total USD desc:
       co-high ($12): high-1, high-2
       co-mid  ($9):  mid-1, mid-2
       co-tie  ($5):  tie-1 *)
  let eff : Wire_runtime.efficiency_month =
    {
      month = "2026-11";
      window_kind = Some Wire_runtime.Efficiency_month_mtd;
      generated_at_unix = 1_795_200_000.0;
      days_covered = 22;
      keepers =
        [
          mk_eff "mid-2" 1.0 10;
          mk_eff "tie-1" 5.0 30;
          mk_eff "high-2" 2.0 20;
          mk_eff "mid-1" 8.0 40;
          mk_eff "high-1" 10.0 50;
        ];
      fleet =
        {
          turns_total = 50;
          calls_per_turn = 3.0;
          tool_s_per_turn = 1.2;
          output_tokens_per_turn = 50.0;
          input_tokens_per_turn = 1000.0;
          cost_usd_per_turn = 0.52;
          fleet_cache_hit_pct = Observed.value ~observed_at:t0 80.0;
        };
      velocity = [];
    }
  in
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let m1, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         { epoch = m0.epoch; reply = Msg.Reply_keepers_roster (Ok (roster_of ks)) })
  in
  let m2, _ =
    Update.step ~now:t0 m1
      (Msg.Http_reply
         { epoch = m1.epoch; reply = Msg.Reply_efficiency (Ok eff) })
  in
  let m_rt =
    {
      m2 with
      nav = { m2.nav with workspace = Nav.Runtime };
      runtime =
        Runtime_store.set_tab Nav.Runtime_efficiency_spend m2.runtime;
    }
  in
  let display_names =
    Runtime_store.keeper_spend_display_rows m_rt.runtime
    |> List.map (fun (r : Runtime_store.keeper_spend_row) -> r.keeper)
  in
  Alcotest.(check (list string))
    "keeper_spend_display_rows follows company total USD desc then member USD desc"
    [ "high-1"; "high-2"; "mid-1"; "mid-2"; "tie-1" ]
    display_names;
  let rec walk_down m steps acc =
    if steps = 0 then List.rev acc
    else
      let m', _ =
        Update.step ~now:t1 m (Msg.Key_event (key Keymap.Input.Down))
      in
      let sel =
        Option.map (fun (r : Runtime_store.keeper_spend_row) -> r.keeper)
          (Runtime_store.selected_keeper_spend_row m'.runtime)
      in
      walk_down m' (steps - 1) (sel :: acc)
  in
  let initial_sel =
    Option.map (fun (r : Runtime_store.keeper_spend_row) -> r.keeper)
      (Runtime_store.selected_keeper_spend_row m_rt.runtime)
  in
  let trace = walk_down m_rt 4 [ initial_sel ] in
  Alcotest.(check (list (option string)))
    "Down on Runtime Efficiency steps monotonically through company-grouped rows"
    [ Some "high-1"; Some "high-2"; Some "mid-1"; Some "mid-2"; Some "tie-1" ]
    trace

let test_nav_fix4_knowledge_board_chains_and_wiki_clusters () =
  let mk_post ?chain id title ts : Wire_knowledge.board_post =
    {
      id;
      title;
      body = "body " ^ id;
      author = "alpha-1";
      hearth = Some "ops";
      post_kind = Some Wire_knowledge.Human_post;
      visibility = Some Wire_knowledge.Vis_public;
      created_at_unix = ts;
      updated_at_unix = None;
      score = 1;
      comment_count = 0;
      author_karma = Observed.value ~observed_at:t0 10;
      succession_chain_root_id = chain;
      chain_depth = None;
      is_signal = true;
    }
  in
  let posts =
    [
      mk_post ~chain:"root-a" "a-1" "Chain A lead" 300.0;
      mk_post ~chain:"root-a" "a-2" "Chain A child 1" 290.0;
      mk_post ~chain:"root-a" "a-3" "Chain A child 2" 280.0;
      mk_post "b-1" "Singleton B" 250.0;
      mk_post ~chain:"root-c" "c-1" "Chain C lead" 200.0;
      mk_post ~chain:"root-c" "c-2" "Chain C child" 190.0;
    ]
  in
  let feed : Wire_knowledge.board_feed =
    { posts; count = List.length posts; sort_by = "recent"; signal_only = true }
  in
  let k0 = Knowledge_store.apply_board ~observed_at:t0 feed Knowledge_store.empty in
  let post_ids ks = List.map (fun (p : Wire_knowledge.board_post) -> p.id) ks in
  Alcotest.(check (list string))
    "collapsed board_display_posts shows leads + singletons only"
    [ "a-1"; "b-1"; "c-1" ]
    (post_ids (Knowledge_store.board_display_posts k0));
  let k1 = Knowledge_store.move_selection ~delta:1 k0 in
  Alcotest.(check (option string))
    "Down on collapsed board steps a-1 -> b-1" (Some "b-1")
    (Option.map (fun (p : Wire_knowledge.board_post) -> p.id)
       (Knowledge_store.selected_post k1));
  let space_chain_root k =
    match Knowledge_store.board_space_effect k with
    | Knowledge_store.Board_space_toggle_chain root_id -> Some root_id
    | Knowledge_store.Board_space_toggle_signal_only -> None
  in
  Alcotest.(check (option string))
    "Space on a chained post folds its chain" (Some "root-a")
    (space_chain_root k0);
  Alcotest.(check (option string))
    "Space on a singleton post flips the signal-only filter" None
    (space_chain_root k1);
  (* Expand root-a while b-1 is selected -> preserves b-1 and re-syncs index to 3 *)
  let k_exp = Knowledge_store.toggle_succession_chain ~root_id:"root-a" k1 in
  Alcotest.(check (list string))
    "expanded root-a exposes chain members inline"
    [ "a-1"; "a-2"; "a-3"; "b-1"; "c-1" ]
    (post_ids (Knowledge_store.board_display_posts k_exp));
  Alcotest.(check (option string))
    "expanding chain preserves selected post b-1" (Some "b-1")
    (Option.map (fun (p : Wire_knowledge.board_post) -> p.id)
       (Knowledge_store.selected_post k_exp));
  Alcotest.(check int) "selected_index synced to 3 after expand" 3
    k_exp.selected_index;
  (* Move up into a-2, then collapse root-a -> snaps cleanly to a-1 (index 0) *)
  let k_a2 = Knowledge_store.move_selection ~delta:(-2) k_exp in
  Alcotest.(check (option string))
    "Up twice lands on a-2" (Some "a-2")
    (Option.map (fun (p : Wire_knowledge.board_post) -> p.id)
       (Knowledge_store.selected_post k_a2));
  let k_col = Knowledge_store.toggle_succession_chain ~root_id:"root-a" k_a2 in
  Alcotest.(check (option string))
    "collapsing active chain snaps selection to lead a-1" (Some "a-1")
    (Option.map (fun (p : Wire_knowledge.board_post) -> p.id)
       (Knowledge_store.selected_post k_col));
  Alcotest.(check int) "selected_index synced to 0 after collapse" 0
    k_col.selected_index;
  let k_next = Knowledge_store.move_selection ~delta:1 k_col in
  Alcotest.(check (option string))
    "Down after collapse advances cleanly to b-1" (Some "b-1")
    (Option.map (fun (p : Wire_knowledge.board_post) -> p.id)
       (Knowledge_store.selected_post k_next));
  (* Wiki topic clustering (language-neutral string option topic key) *)
  let mk_wiki slug tags : Wire_knowledge.wiki_page_summary =
    {
      slug;
      file = slug ^ ".md";
      title = "Title " ^ slug;
      summary = "Summary " ^ slug;
      source = Wire_knowledge.Source_research;
      author = "alpha-1";
      created = "2026-11-01";
      updated = "2026-11-22";
      revision = 1;
      tags;
      backlink_count = 0;
      outgoing_link_count = 0;
      sources_count = 1;
      hearsay_count = 0;
      sha256 = "sha-" ^ slug;
    }
  in
  let empty_lint : Wire_knowledge.wiki_index_lint =
    {
      total_findings = 0;
      counts =
        {
          broken_link = 0;
          unsupported_link = 0;
          orphan = 0;
          orphan_unconfirmed = 0;
          missing_sources = 0;
          hearsay_only = 0;
          unreadable_page = 0;
          revision_log_gap = 0;
          revision_log_hole = 0;
          duplicate_title_candidates = 0;
        };
      log_hole_suppressed = false;
      orphans = [];
      duplicate_title_candidates = [];
      findings = [];
    }
  in
  let wiki_pages =
    [
      mk_wiki "page-untagged" [];
      mk_wiki "page-ops-1" [ "ops" ];
      mk_wiki "page-arch-1" [ "arch" ];
      mk_wiki "page-ops-2" [ "ops" ];
    ]
  in
  let idx : Wire_knowledge.wiki_index =
    {
      pages_total = 4;
      pages_readable = 4;
      pages_unreadable = 0;
      pages = wiki_pages;
      unreadable_pages = [];
      lint = empty_lint;
    }
  in
  let clusters = Knowledge_store.cluster_wiki_pages wiki_pages in
  Alcotest.(check (list (option string)))
    "cluster_wiki_pages uses language-neutral string option keys (None for untagged)"
    [ None; Some "ops"; Some "arch" ]
    (List.map fst clusters);
  let kw0 =
    Knowledge_store.empty
    |> Knowledge_store.set_tab Nav.Knowledge_wiki
    |> Knowledge_store.apply_wiki_index ~observed_at:t0 idx
  in
  let disp_slugs =
    Knowledge_store.wiki_display_pages kw0
    |> List.map (fun (p : Wire_knowledge.wiki_page_summary) -> p.slug)
  in
  Alcotest.(check (list string))
    "wiki_display_pages matches flattened cluster order"
    [ "page-untagged"; "page-ops-1"; "page-ops-2"; "page-arch-1" ]
    disp_slugs;
  let kw1 = Knowledge_store.move_selection ~delta:3 kw0 in
  Alcotest.(check (option string))
    "selected_wiki_page after 3 Down steps is page-arch-1" (Some "page-arch-1")
    (Option.map (fun (p : Wire_knowledge.wiki_page_summary) -> p.slug)
       (Knowledge_store.selected_wiki_page kw1));
  (* Re-applying wiki index with reordered pages preserves slug page-arch-1 *)
  let kw_re =
    Knowledge_store.apply_wiki_index ~observed_at:t1
      { idx with pages = List.rev wiki_pages }
      kw1
  in
  Alcotest.(check (option string))
    "apply_wiki_index preserves selected slug across refresh" (Some "page-arch-1")
    (Option.map (fun (p : Wire_knowledge.wiki_page_summary) -> p.slug)
       (Knowledge_store.selected_wiki_page kw_re))

let test_nav_fix5_keeper_chat_scroll_direction_and_home_bound () =
  let msgs =
    List.init 40 (fun i : Wire_fleet.chat_message ->
        {
          id = Printf.sprintf "m-%d" i;
          role =
            (if i mod 2 = 0 then Wire_fleet.Role_user
             else Wire_fleet.Role_assistant);
          content = Printf.sprintf "Message line %d with enough detail" i;
          ts_unix = 1_700_000_000.0 +. float_of_int i;
          turn_ref = None;
          model_used = None;
          tool_call_id = None;
          tool_call_name = None;
          execution_id = None;
          operation_id = None;
          transcript_slot = None;
          failure_kind = None;
        })
  in
  let m0 = Model.initial ~cols:120 ~rows:30 () in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_keepers ~observed_at:t0 [ sample_keeper "alpha-1" ]
    |> Fleet_store.apply_chat_history ~observed_at:t0 ~keeper:"alpha-1"
         { messages = msgs; has_more = false; next_cursor = None }
  in
  let m_chat =
    {
      m0 with
      fleet;
      nav =
        {
          m0.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha-1"; tab = Nav.Keeper_chat } ];
        };
    }
  in
  Alcotest.(check int) "chat scroll starts at bottom (0)" 0
    m_chat.fleet.chat_scroll_offset;
  let m_up, _ =
    Update.step ~now:t0 m_chat (Msg.Key_event (key Keymap.Input.Up))
  in
  Alcotest.(check int) "Up scrolls UP to older messages (+1)" 1
    m_up.fleet.chat_scroll_offset;
  let m_pgup, _ =
    Update.step ~now:t0 m_up (Msg.Key_event (key Keymap.Input.Page_up))
  in
  Alcotest.(check int) "Page_up scrolls UP by +10" 11
    m_pgup.fleet.chat_scroll_offset;
  let m_wup, _ =
    Update.step ~now:t0 m_pgup
      (Msg.Mouse_event
         (Keymap.Input.Wheel { dir = Keymap.Input.Wheel_up; col = 10; row = 10 }))
  in
  Alcotest.(check int) "Wheel_up scrolls UP (+1)" 12
    m_wup.fleet.chat_scroll_offset;
  let m_dn, _ =
    Update.step ~now:t0 m_wup (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check int) "Down scrolls DOWN toward latest (-1)" 11
    m_dn.fleet.chat_scroll_offset;
  let m_wdn, _ =
    Update.step ~now:t0 m_dn
      (Msg.Mouse_event
         (Keymap.Input.Wheel
            { dir = Keymap.Input.Wheel_down; col = 10; row = 10 }))
  in
  Alcotest.(check int) "Wheel_down scrolls DOWN (-1)" 10
    m_wdn.fleet.chat_scroll_offset;
  let m_end, _ =
    Update.step ~now:t0 m_wdn (Msg.Key_event (key Keymap.Input.End))
  in
  Alcotest.(check int) "End jumps straight to bottom (0)" 0
    m_end.fleet.chat_scroll_offset;
  let m_home, _ =
    Update.step ~now:t0 m_end (Msg.Key_event (key Keymap.Input.Home))
  in
  let bound = Chat_transcript.max_scroll_for_model ~model:m_chat ~keeper:"alpha-1" in
  Alcotest.(check bool) "Home bound is tight (>0 and <1000)" true
    (bound > 0 && bound < 1000);
  Alcotest.(check int) "Home clamps to tight upper bound (no 100000 overshoot)"
    bound m_home.fleet.chat_scroll_offset;
  let m_home_dn, _ =
    Update.step ~now:t1 m_home (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check int) "Single Down right after Home decrements immediately"
    (bound - 1) m_home_dn.fleet.chat_scroll_offset

let test_nav_fix6_work_inbox_filter_and_split_pane_clamping () =
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  (* 1. Work_inbox with 3 Attention items moves attention.triage_index *)
  let work_inbox =
    m0.work
    |> Work_store.set_tab Nav.Work_inbox
    |> Work_store.apply_asks ~observed_at:t0
         [
           sample_ask ~id:"ask-1" ~keeper:"alpha-1" ();
           sample_ask ~id:"ask-2" ~keeper:"alpha-2" ();
         ]
    |> Work_store.apply_tool_approvals ~observed_at:t0
         [ sample_tool_approval ~id:"ap-1" ~keeper:"alpha-1" () ]
  in
  let m_inbox =
    { m0 with nav = { m0.nav with workspace = Nav.Work }; work = work_inbox }
    |> Model.rebuild_attention
  in
  Alcotest.(check int) "Inbox attention count = 3" 3
    (Attention.count m_inbox.attention);
  let m_i1, _ =
    Update.step ~now:t0 m_inbox (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check int) "Work_inbox Down advances triage_index 0 -> 1" 1
    m_i1.attention.triage_index;
  let m_i2, _ =
    Update.step ~now:t0 m_i1 (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check int) "Work_inbox second Down advances triage_index 1 -> 2" 2
    m_i2.attention.triage_index;
  let m_iu, _ =
    Update.step ~now:t0 m_i2 (Msg.Key_event (key Keymap.Input.Up))
  in
  Alcotest.(check int) "Work_inbox Up moves triage_index 2 -> 1" 1
    m_iu.attention.triage_index;

  (* 2. Work_store.filtered_tasks unified active/done/sched filters *)
  let mk_task id status : Wire_work.task =
    {
      id;
      title = "Task " ^ id;
      description = None;
      priority = 1;
      status;
      goal_link = Wire_work.Unlinked;
      created_at = None;
      updated_at = None;
    }
  in
  let tasks =
    [
      mk_task "t-todo" Wire_work.Todo;
      mk_task "t-prog"
        (Wire_work.InProgress { assignee = "alpha-1"; started_at = "now" });
      mk_task "t-done"
        (Wire_work.Done
           { assignee = "alpha-1"; completed_at = "now"; notes = None });
    ]
  in
  let mk_sched id : Wire_work.schedule_row =
    {
      schedule_instance_id = "si-" ^ id;
      schedule_id = id;
      status = Wire_work.Sched_scheduled;
      source = "keeper.toml";
      due_at_unix = 1_800_000_000.0;
      next_due_at_unix = None;
      recurrence_kind = "cron";
      recurrence_summary = "0 * * * *";
      payload_kind = None;
      payload_support = "prompt";
      payload_target = None;
      payload_keeper_name = Some "alpha-1";
      payload_summary = None;
      last_wake_unix = None;
      last_disposition = Wire_work.Wake_never;
    }
  in
  let w_ts =
    Work_store.empty
    |> Work_store.set_tab Nav.Work_tasks
    |> Work_store.apply_planning ~observed_at:t0 { goals = []; tasks }
    |> Work_store.apply_schedules ~observed_at:t0
         ([ mk_sched "s-1"; mk_sched "s-2" ], None)
  in
  let with_status st = Work_store.set_task_status_filter st w_ts in
  Alcotest.(check int) "Active chip returns 1 claimed/in-progress task" 1
    (List.length (Work_store.filtered_tasks (with_status Work_store.Status_active)));
  Alcotest.(check int) "Todo chip returns 1 todo task" 1
    (List.length (Work_store.filtered_tasks (with_status Work_store.Status_todo)));
  Alcotest.(check int) "Done chip returns 1 done task" 1
    (List.length (Work_store.filtered_tasks (with_status Work_store.Status_done)));
  Alcotest.(check int) "text 'active' is a plain search, not a status chip" 0
    (List.length (Work_store.filtered_tasks (Work_store.set_filter "active" w_ts)));
  let w_sched = Work_store.set_tab Nav.Work_schedules w_ts in
  Alcotest.(check int) "Schedules 1st-class tab has 2 schedules" 2
    (List.length (Work_store.filtered_schedules w_sched));
  let w_cycled =
    List.fold_left
      (fun w _ -> Work_store.cycle_task_status_filter w)
      w_ts Work_store.all_task_status_filters
  in
  Alcotest.(check bool) "cycling every chip wraps back to All" true
    (Work_store.equal_task_status_filter Work_store.Status_all
       w_cycled.task_status_filter);
  let m_tasks =
    let m = Model.initial ~cols:140 ~rows:40 () in
    { m with nav = { m.nav with workspace = Nav.Work }; work = w_ts }
  in
  let m_space, _ =
    Update.step ~now:t0 m_tasks (Msg.Key_event (char_key " "))
  in
  Alcotest.(check bool) "Space on Work_tasks selects the Active chip" true
    (Work_store.equal_task_status_filter Work_store.Status_active
       m_space.work.task_status_filter);
  let m_chip_esc, _ =
    Update.step ~now:t0 m_space (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc on a non-All chip returns it to All" true
    (Work_store.equal_task_status_filter Work_store.Status_all
       m_chip_esc.work.task_status_filter);
  let w_sched_clamped = Work_store.move_selection ~delta:99 w_sched in
  Alcotest.(check int) "Schedules tab clamps cleanly at 1 (no dead zone)" 1
    w_sched_clamped.selected_index;

  (* 3. Split-pane dead-zone clamping on Tab (Work_pipeline, Runtime_tools_connectors, Knowledge_memory) *)
  let goals5 = List.init 5 (fun i -> sample_goal ~id:(Printf.sprintf "g-%d" i) ()) in
  let verifs2 =
    List.init 2 (fun i : Wire_work.verification_request ->
        {
          request_id = Printf.sprintf "v-%d" i;
          task_id = Printf.sprintf "t-%d" i;
          task_title = "Verify";
          submitted_by = "alpha-1";
          created_at_unix = None;
          completion_contract = [];
          required_artifacts = [];
          submitted_evidence = [];
          evidence_projection_error = None;
          review_observation = None;
        })
  in
  let m_pipe =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Work; pane_index = 0 };
      work =
        Work_store.empty
        |> Work_store.set_tab Nav.Work_pipeline
        |> Work_store.apply_planning ~observed_at:t0 { goals = goals5; tasks = [] }
        |> Work_store.apply_verifications ~observed_at:t0 verifs2;
    }
  in
  let m_pipe_end, _ =
    Update.step ~now:t0 m_pipe (Msg.Key_event (key Keymap.Input.End))
  in
  Alcotest.(check int) "Work_pipeline pane 0 End lands on goal index 4" 4
    m_pipe_end.work.selected_index;
  let m_pipe_tab, _ =
    Update.step ~now:t0 m_pipe_end (Msg.Key_event (key Keymap.Input.Tab))
  in
  Alcotest.(check int) "Tab switches pane_index 0 -> 1" 1
    m_pipe_tab.nav.pane_index;
  Alcotest.(check int) "Tab preserves Goals selected_index (4)" 4
    m_pipe_tab.work.selected_index;
  Alcotest.(check int) "Tab keeps verif_selected_index clamped (0)" 0
    m_pipe_tab.work.verif_selected_index;
  let m_pipe_dn, _ =
    Update.step ~now:t0 m_pipe_tab (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check int) "Down on pane 1 moves verif_selected_index to 1" 1
    m_pipe_dn.work.verif_selected_index;
  Alcotest.(check int) "Down on pane 1 preserves Goals selected_index (4)" 4
    m_pipe_dn.work.selected_index;

  (* Runtime_connectors: 6 connectors on pane 0, 2 MCP clients on pane 1 *)
  let conns6 =
    List.init 6 (fun i : Wire_runtime.connector_row ->
        {
          connector_id = Printf.sprintf "conn-%d" i;
          display_name = Printf.sprintf "Conn %d" i;
          connection = Wire_runtime.Connector_connected;
          channel = None;
          error = None;
          binding_count = 1;
          configured_bindings = [];
        })
  in
  let mcps2 =
    List.init 2 (fun i : Wire_runtime.mcp_client_row ->
        {
          name = Printf.sprintf "mcp-%d" i;
          agent_type = "mcp";
          keeper_name = None;
          keeper_id = None;
          status = "active";
          current_task = None;
          session_bound_at_unix = Some 90.0;
          last_seen_unix = Some 100.0;
          capabilities = [];
        })
  in
  let m_tc =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Runtime; pane_index = 0 };
      runtime =
        Runtime_store.empty
        |> Runtime_store.set_tab Nav.Runtime_connectors
        |> Runtime_store.apply_connectors ~observed_at:t0 conns6
        |> Runtime_store.apply_mcp_clients ~observed_at:t0 mcps2;
    }
  in
  let m_tc_end, _ =
    Update.step ~now:t0 m_tc (Msg.Key_event (key Keymap.Input.End))
  in
  Alcotest.(check int) "Runtime connectors pane 0 End lands on index 5" 5
    m_tc_end.runtime.connector_selected_index;
  let m_tc_tab, _ =
    Update.step ~now:t0 m_tc_end (Msg.Key_event (key Keymap.Input.Tab))
  in
  Alcotest.(check int) "Tab preserves Connectors selected_index (5)" 5
    m_tc_tab.runtime.connector_selected_index;
  Alcotest.(check int) "Tab keeps MCP Clients index clamped (0)" 0
    m_tc_tab.runtime.mcp_client_selected_index;
  let m_tc_dn, _ =
    Update.step ~now:t0 m_tc_tab (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check int) "Down on pane 1 moves mcp_client_selected_index to 1" 1
    m_tc_dn.runtime.mcp_client_selected_index;
  Alcotest.(check int) "Down on pane 1 preserves Connectors index (5)" 5
    m_tc_dn.runtime.connector_selected_index;

  (* Knowledge_memory: 4 conflicts on pane 0, 1 diff entry on pane 1 *)
  let conflicts4 =
    List.init 4 (fun i : Wire_knowledge.memory_conflict ->
        {
          conflict_id = Printf.sprintf "cf-%d" i;
          description = "Conflict";
          member_count = 2;
          competing_claims = [];
        })
  in
  let world_mem : Wire_knowledge.world_memory =
    {
      ledger_state = Wire_knowledge.World_ledger_available;
      ledger_sha256 = None;
      claims_count = 0;
      facts_count = 0;
      conflicts_count = 4;
      excluded_count = 0;
      claims = [];
      active_conflicts = conflicts4;
      briefing =
        {
          status = Wire_knowledge.Briefing_current;
          text = None;
          source_ids_count = 0;
          error = None;
          building_pass = None;
        };
      librarian_writers = Wire_knowledge.Writers_none_in_process;
      ordinary_absence_detail = None;
    }
  in
  let diff1 : Wire_knowledge.memory_diff =
    {
      scope = Wire_knowledge.Scope_world;
      range =
        {
          window = Some "24h";
          from_rev = None;
          to_rev = None;
          from_unix = None;
          to_unix = None;
        };
      retrieval_heat =
        {
          hot = 1;
          warm = 0;
          cold = 0;
          never_retrieved = 0;
          total_events = 1;
          unreadable_event_lines = 0;
        };
      body =
        Wire_knowledge.Keeper_diff
          {
            counts =
              {
                total_facts_now = 1;
                added = 1;
                updated = 0;
                retracted = 0;
                invalidated = 0;
                journal_failures_in_window = 0;
                journal_quarantines_in_window = 0;
                undecodable_journal_lines = 0;
              };
            revisions = [];
            added =
              [
                {
                  added_at_rev = Some 1;
                  memory_id = "mem-1";
                  category = "fact";
                  origin = "keeper";
                  text = "One diff entry";
                  first_seen_unix = 100.0;
                  last_seen_unix = None;
                  retrieval_count = 1;
                  last_retrieved_at_unix = None;
                  heat = Wire_knowledge.Heat_hot;
                };
              ];
            updated = [];
            retracted = [];
            invalidated = [];
            writer_status = None;
          };
    }
  in
  let m_km =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Knowledge; pane_index = 0 };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.set_tab Nav.Knowledge_memory
        |> Knowledge_store.apply_world_memory ~observed_at:t0 world_mem
        |> Knowledge_store.set_memory_diff ~keeper:None
             ~window:Knowledge_store.Window_24h
             (Observed.value ~observed_at:t0 diff1);
    }
  in
  let m_km_end, _ =
    Update.step ~now:t0 m_km (Msg.Key_event (key Keymap.Input.End))
  in
  Alcotest.(check int) "Knowledge_memory pane 0 End lands on conflict index 3" 3
    m_km_end.knowledge.selected_index;
  let m_km_tab, _ =
    Update.step ~now:t0 m_km_end (Msg.Key_event (key Keymap.Input.Tab))
  in
  Alcotest.(check int) "Tab preserves Knowledge_memory conflict selected_index (3)"
    3 m_km_tab.knowledge.selected_index;
  Alcotest.(check int) "Tab keeps Knowledge_memory diff_scroll_offset clamped (0)"
    0 m_km_tab.knowledge.diff_scroll_offset

let test_nav_fix7_symmetric_viewport_scrolling_all_stores () =
  (* Verify smooth symmetric scroll with explicit ?viewport_rows:5:
     scrolling down pushes window forward, then pressing Up inside window keeps
     scroll_offset constant until cursor hits top edge! *)
  let vr = 5 in
  (* 1. Fleet_store (grouped Fleet_companies with headers + flat Fleet_attention) *)
  let fleet_ks =
    List.init 12 (fun i ->
        let grp = Printf.sprintf "org-%02d" (i / 3) in
        grouped_keeper ~group:grp (Printf.sprintf "k-%02d" i))
  in
  let f0 = Fleet_store.apply_keepers ~observed_at:t0 fleet_ks Fleet_store.empty in
  let f_deep =
    List.fold_left
      (fun acc _ -> Fleet_store.move_selection ~viewport_rows:vr ~delta:1 acc)
      f0 (List.init 8 Fun.id)
  in
  (* Index 8 in 4 groups of 3 = group 2 member 2 -> visual row = 2*(1+3) + 1 + 2 = 11 *)
  Alcotest.(check int) "Fleet grouped scroll_offset tracks visual row (11 - 5 + 1 = 7)"
    7 f_deep.scroll_offset;
  let f_up1 = Fleet_store.move_selection ~viewport_rows:vr ~delta:(-1) f_deep in
  Alcotest.(check int) "Fleet grouped Up inside window keeps scroll_offset=7"
    7 f_up1.scroll_offset;
  let f_up2 = Fleet_store.move_selection ~viewport_rows:vr ~delta:(-1) f_up1 in
  Alcotest.(check int) "Fleet grouped second Up inside window keeps scroll_offset=7"
    7 f_up2.scroll_offset;
  let f_up_past =
    Fleet_store.move_selection ~viewport_rows:vr ~delta:(-4) f_up2
  in
  Alcotest.(check bool) "Fleet grouped Up past top edge pulls scroll_offset down"
    true (f_up_past.scroll_offset < 7);

  (* 2. Work_store *)
  let goals15 = List.init 15 (fun i -> sample_goal ~id:(Printf.sprintf "g-%02d" i) ()) in
  let w0 =
    Work_store.empty
    |> Work_store.apply_planning ~observed_at:t0 { goals = goals15; tasks = [] }
  in
  let w_deep = Work_store.move_selection ~viewport_rows:vr ~delta:10 w0 in
  Alcotest.(check int) "Work scroll_offset = 10 - 5 + 1 = 6" 6 w_deep.scroll_offset;
  let w_up1 = Work_store.move_selection ~viewport_rows:vr ~delta:(-1) w_deep in
  Alcotest.(check int) "Work Up inside window keeps scroll_offset = 6" 6
    w_up1.scroll_offset;
  let w_up_edge = Work_store.move_selection ~viewport_rows:vr ~delta:(-4) w_up1 in
  Alcotest.(check int) "Work Up past top edge pulls scroll_offset = 5" 5
    w_up_edge.scroll_offset;

  (* 3. Knowledge_store *)
  let mk_post i : Wire_knowledge.board_post =
    {
      id = Printf.sprintf "p-%02d" i;
      title = "Post";
      body = "Body";
      author = "alpha-1";
      hearth = None;
      post_kind = Some Wire_knowledge.Human_post;
      visibility = Some Wire_knowledge.Vis_public;
      created_at_unix = float_of_int (1000 - i);
      updated_at_unix = None;
      score = 0;
      comment_count = 0;
      author_karma = Observed.unreported;
      succession_chain_root_id = None;
      chain_depth = None;
      is_signal = true;
    }
  in
  let k0 =
    Knowledge_store.empty
    |> Knowledge_store.apply_board ~observed_at:t0
         {
           posts = List.init 15 mk_post;
           count = 15;
           sort_by = "recent";
           signal_only = true;
         }
  in
  let k_deep = Knowledge_store.move_selection ~viewport_rows:vr ~delta:10 k0 in
  Alcotest.(check int) "Knowledge scroll_offset = 6" 6 k_deep.scroll_offset;
  let k_up1 = Knowledge_store.move_selection ~viewport_rows:vr ~delta:(-1) k_deep in
  Alcotest.(check int) "Knowledge Up inside window keeps scroll_offset = 6" 6
    k_up1.scroll_offset;

  (* 4. Infra_store *)
  let repos15 =
    List.init 15 (fun i : Wire_infra.repository ->
        {
          id = Printf.sprintf "r-%02d" i;
          name = Printf.sprintf "repo-%02d" i;
          codebase = None;
          url = "https://example.invalid/repo";
          resolved_local_path = "/tmp/repo";
          default_branch = "main";
          status = Wire_infra.Repo_active;
          keepers = [];
          auto_sync = false;
        })
  in
  let inf0 =
    Infra_store.empty
    |> Infra_store.set_tab Nav.Infra_repos_changes
    |> Infra_store.apply_repositories ~observed_at:t0 repos15
  in
  let inf_deep = Infra_store.move_selection ~viewport_rows:vr ~delta:10 inf0 in
  Alcotest.(check int) "Infra scroll_offset = 6" 6 inf_deep.scroll_offset;
  let inf_up1 = Infra_store.move_selection ~viewport_rows:vr ~delta:(-1) inf_deep in
  Alcotest.(check int) "Infra Up inside window keeps scroll_offset = 6" 6
    inf_up1.scroll_offset;

  (* 5. Incidents *)
  let inc0 =
    List.fold_left
      (fun acc i ->
        let acc', _ =
          Incidents.push ~occurred_at_unix:(float_of_int i)
            ~source:(Health.Source_keeper "alpha-1")
            ~summary:(Say.make ~ko:"경고" ~en:"Warn")
            ~detail:"detail" ~status:Health.Resolved acc
        in
        acc')
      Incidents.empty (List.init 15 Fun.id)
  in
  let inc_deep = Incidents.move_selection ~viewport_rows:vr ~delta:10 inc0 in
  Alcotest.(check int) "Incidents scroll_offset = 6" 6 inc_deep.scroll_offset;
  let inc_up1 = Incidents.move_selection ~viewport_rows:vr ~delta:(-1) inc_deep in
  Alcotest.(check int) "Incidents Up inside window keeps scroll_offset = 6" 6
    inc_up1.scroll_offset

let test_nav_left_right_subtab_cycling_and_guards () =
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let step m ev = Update.step ~now:t0 m (Msg.Key_event ev) in
  (* 1. Keepers: Right cycles Companies -> Attention -> Pulse_wall; Left reverses *)
  let m_k = { m0 with nav = { m0.nav with workspace = Nav.Keepers } } in
  let m_k1, _ = step m_k (key Keymap.Input.Right) in
  Alcotest.(check bool) "Keepers Right -> Fleet_attention" true
    (Nav.equal_keepers_fleet_mode m_k1.fleet.fleet_mode Nav.Fleet_attention);
  let m_k2, _ = step m_k1 (key Keymap.Input.Right) in
  Alcotest.(check bool) "Keepers second Right -> Fleet_pulse_wall" true
    (Nav.equal_keepers_fleet_mode m_k2.fleet.fleet_mode Nav.Fleet_pulse_wall);
  let m_k3, _ = step m_k2 (key Keymap.Input.Left) in
  Alcotest.(check bool) "Keepers Left -> Fleet_attention" true
    (Nav.equal_keepers_fleet_mode m_k3.fleet.fleet_mode Nav.Fleet_attention);

  (* 2. Work, Knowledge, Runtime, Infra cycle sub-tabs on Right/Left *)
  let m_w = { m0 with nav = { m0.nav with workspace = Nav.Work } } in
  let m_w1, _ = step m_w (key Keymap.Input.Right) in
  Alcotest.(check bool) "Work Right -> Work_tasks" true
    (Nav.equal_work_tab m_w1.work.active_tab Nav.Work_tasks);
  let m_w2, _ = step m_w1 (key Keymap.Input.Right) in
  Alcotest.(check bool) "Work second Right -> Work_schedules" true
    (Nav.equal_work_tab m_w2.work.active_tab Nav.Work_schedules);
  let m_w0, _ = step m_w1 (key Keymap.Input.Left) in
  Alcotest.(check bool) "Work Left -> Work_pipeline" true
    (Nav.equal_work_tab m_w0.work.active_tab Nav.Work_pipeline);

  let m_kn = { m0 with nav = { m0.nav with workspace = Nav.Knowledge } } in
  let m_kn1, _ = step m_kn (key Keymap.Input.Right) in
  Alcotest.(check bool) "Knowledge Right -> Knowledge_wiki" true
    (Nav.equal_knowledge_tab m_kn1.knowledge.active_tab Nav.Knowledge_wiki);
  let m_kn2, _ = step m_kn1 (key Keymap.Input.Right) in
  Alcotest.(check bool) "Knowledge second Right -> Knowledge_artifacts" true
    (Nav.equal_knowledge_tab m_kn2.knowledge.active_tab Nav.Knowledge_artifacts);

  let m_rt = { m0 with nav = { m0.nav with workspace = Nav.Runtime } } in
  let m_rt1, _ = step m_rt (key Keymap.Input.Right) in
  Alcotest.(check bool) "Runtime Right -> Runtime_efficiency_spend" true
    (Nav.equal_runtime_tab m_rt1.runtime.active_tab
       Nav.Runtime_efficiency_spend);

  let m_in = { m0 with nav = { m0.nav with workspace = Nav.Infra } } in
  let m_in1, _ = step m_in (key Keymap.Input.Right) in
  Alcotest.(check bool) "Infra Right -> Infra_repos_changes" true
    (Nav.equal_infra_tab m_in1.infra.active_tab Nav.Infra_repos_changes);

  (* 3. Dive_keeper unfocused: Right cycles Chat -> Context -> Tool_calls -> Memory; Left reverses *)
  let m_dive =
    {
      m0 with
      nav =
        {
          m0.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha-1"; tab = Nav.Keeper_chat } ];
        };
    }
  in
  let m_d1, _ = step m_dive (key Keymap.Input.Right) in
  Alcotest.(check bool) "Dive_keeper Right -> Keeper_context" true
    (Nav.equal_keeper_tab m_d1.fleet.keeper_dive_tab Nav.Keeper_context);
  let m_d2, _ = step m_d1 (key Keymap.Input.Right) in
  Alcotest.(check bool) "Dive_keeper second Right -> Keeper_tool_calls" true
    (Nav.equal_keeper_tab m_d2.fleet.keeper_dive_tab Nav.Keeper_tool_calls);
  let m_d0, _ = step m_d1 (key Keymap.Input.Left) in
  Alcotest.(check bool) "Dive_keeper Left -> Keeper_chat" true
    (Nav.equal_keeper_tab m_d0.fleet.keeper_dive_tab Nav.Keeper_chat);

  (* 4. Queue_context overlay cycles tabs on Right/Left *)
  let m_qc =
    {
      m0 with
      nav = { m0.nav with overlay = Some (Nav.Queue_context Nav.Drawer_queue) };
    }
  in
  let m_qc1, _ = step m_qc (key Keymap.Input.Right) in
  Alcotest.(check bool) "Queue_context Right -> Drawer_context" true
    (Option.equal Nav.equal_overlay m_qc1.nav.overlay
       (Some (Nav.Queue_context Nav.Drawer_context)));
  let m_qc0, _ = step m_qc1 (key Keymap.Input.Left) in
  Alcotest.(check bool) "Queue_context Left -> Drawer_queue" true
    (Option.equal Nav.equal_overlay m_qc0.nav.overlay
       (Some (Nav.Queue_context Nav.Drawer_queue)));

  (* 5. Focused composer guard: Left/Right moves text cursor, NEVER switches tab *)
  let m_comp =
    {
      m_dive with
      drafts =
        m_dive.drafts
        |> Drafts.set_active_keeper "alpha-1"
        |> Drafts.set_focus true
        |> Drafts.insert_text "hello";
    }
  in
  let m_comp_l, _ = step m_comp (key Keymap.Input.Left) in
  Alcotest.(check bool) "Focused composer Left does NOT switch Keeper Dive tab"
    true (Nav.equal_keeper_tab m_comp_l.fleet.keeper_dive_tab Nav.Keeper_chat);
  Alcotest.(check int) "Focused composer Left moves cursor 5 -> 4" 4
    (Drafts.current_draft m_comp_l.drafts).cursor;

  (* 6. Settings overlay guard: Left/Right stays on same Settings tab (tree expand/collapse) *)
  let m_set =
    {
      m0 with
      nav =
        {
          m0.nav with
          overlay = Some (Nav.Settings Nav.Settings_general_ui);
        };
      config = Config_store.set_tab Nav.Settings_general_ui m0.config;
    }
  in
  let m_set_r, _ = step m_set (key Keymap.Input.Right) in
  Alcotest.(check bool) "Settings Right does NOT cycle settings tab" true
    (Option.equal Nav.equal_overlay m_set_r.nav.overlay
       (Some (Nav.Settings Nav.Settings_general_ui)))

let test_p1_chat_transcript_ssot_exact_bounds () =
  let mk_msg ~id ~role ~content ?tool_call_name ts : Wire_fleet.chat_message =
    {
      id;
      role;
      content;
      ts_unix = ts;
      turn_ref = None;
      model_used = None;
      tool_call_id = None;
      tool_call_name;
      execution_id = None;
      operation_id = None;
      transcript_slot = None;
      failure_kind = None;
    }
  in
  let json_1line =
    "{\"k1\":1,\"k2\":2,\"k3\":3,\"k4\":4,\"k5\":5,\"k6\":6,\"k7\":7,\"k8\":8,\"k9\":9,\"k10\":10}"
  in
  let md_msgs =
    [
      mk_msg ~id:"m-1" ~role:Wire_fleet.Role_user
        ~content:"TOP_MARKER_001 Please inspect board:p-1234567890 and https://example.invalid/very/long/path/for/word/wrapping/check"
        1_700_000_001.0;
      mk_msg ~id:"m-2" ~role:Wire_fleet.Role_assistant
        ~content:"# Release Audit\n\n- First bullet with enough words to wrap across multiple narrow lines at eighty columns\n- Second bullet with `inline_code` and **bold text** for markdown expansion\n- Third bullet closing the check"
        1_700_000_002.0;
      mk_msg ~id:"m-3" ~role:Wire_fleet.Role_tool ~tool_call_name:"inspect_json"
        ~content:json_1line 1_700_000_003.0;
    ]
    @ List.init 10 (fun i ->
          mk_msg
            ~id:(Printf.sprintf "m-tail-%d" i)
            ~role:
              (if i mod 2 = 0 then Wire_fleet.Role_user
               else Wire_fleet.Role_assistant)
            ~content:
              (Printf.sprintf
                 "Follow-up turn %d with long descriptive prose that definitely wraps when the viewport is narrow eighty columns wide."
                 i)
            (1_700_000_010.0 +. float_of_int i))
    @ [
        mk_msg ~id:"m-last" ~role:Wire_fleet.Role_assistant
          ~content:"Final persisted assistant reply." 1_700_000_099.0;
      ]
  in
  let m0 = Model.initial ~cols:80 ~rows:24 () in
  let base_fleet =
    m0.fleet
    |> Fleet_store.apply_keepers ~observed_at:t0 [ sample_keeper "alpha-1" ]
    |> Fleet_store.apply_chat_history ~observed_at:t0 ~keeper:"alpha-1"
         { messages = md_msgs; has_more = false; next_cursor = None }
  in
  let make_chat_model fleet drafts =
    {
      m0 with
      fleet;
      drafts;
      nav =
        {
          m0.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha-1"; tab = Nav.Keeper_chat } ];
        };
    }
  in
  (* (a) Compact vs Tools_results (8+1 JSON rows) vs Tools_full (11 JSON rows) *)
  let m_compact = make_chat_model base_fleet m0.drafts in
  let g_compact = Chat_transcript.chat_viewport_geometry ~model:m_compact in
  let rows_compact =
    Chat_transcript.count_transcript_rows ~model:m_compact ~keeper:"alpha-1"
      ~width:g_compact.prose_w
  in
  let m_results =
    make_chat_model
      (Fleet_store.set_tools_mode Slash.Tools_results base_fleet)
      m0.drafts
  in
  let rows_results =
    Chat_transcript.count_transcript_rows ~model:m_results ~keeper:"alpha-1"
      ~width:g_compact.prose_w
  in
  Alcotest.(check int)
    "Tools_results expands 1-line JSON via Json_tree.flatten (+8 shown +1 hidden = +9)"
    (rows_compact + 9) rows_results;
  let m_full =
    make_chat_model
      (Fleet_store.set_tools_mode Slash.Tools_full base_fleet)
      m0.drafts
  in
  let rows_full =
    Chat_transcript.count_transcript_rows ~model:m_full ~keeper:"alpha-1"
      ~width:g_compact.prose_w
  in
  Alcotest.(check int)
    "Tools_full expands all 11 Json_tree lines (+11)" (rows_compact + 11)
    rows_full;

  (* (b) Persisted finished stream is deduped (adds 0 rows) so Home+Down has 0 dead presses *)
  let fleet_persisted =
    m0.fleet
    |> Fleet_store.apply_keepers ~observed_at:t0 [ sample_keeper "alpha-1" ]
    |> Fleet_store.start_chat_stream ~keeper:"alpha-1" ~request_id:"r-dup"
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"alpha-1" ~request_id:"r-dup"
         (Wire_fleet.Chunk_turn_done
            {
              operation_id = Some "op-dup";
              turn_ref = Some "t-dup";
              reply = Some "Final persisted assistant reply.";
            })
    |> Fleet_store.apply_chat_history ~observed_at:t0 ~keeper:"alpha-1"
         { messages = md_msgs; has_more = false; next_cursor = None }
  in
  let m_persisted = make_chat_model fleet_persisted m0.drafts in
  let rows_persisted =
    Chat_transcript.count_transcript_rows ~model:m_persisted ~keeper:"alpha-1"
      ~width:g_compact.prose_w
  in
  Alcotest.(check int) "persisted finished stream adds 0 duplicate rows"
    rows_compact rows_persisted;
  let max_s =
    Chat_transcript.max_scroll_for_model ~model:m_persisted ~keeper:"alpha-1"
  in
  let m_home, _ =
    Update.step ~now:t0 m_persisted (Msg.Key_event (key Keymap.Input.Home))
  in
  Alcotest.(check int) "Home lands on exact SSOT max_scroll" max_s
    m_home.fleet.chat_scroll_offset;
  let m_home_dn, _ =
    Update.step ~now:t1 m_home (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check int) "Single Down after Home steps off top immediately"
    (max_s - 1) m_home_dn.fleet.chat_scroll_offset;

  (* (c) Pending tx adds blank separator + 1 row (+2) *)
  let drafts_tx =
    let d1 =
      m0.drafts
      |> Drafts.set_active_keeper "alpha-1"
      |> Drafts.insert_text "Pending steer message"
    in
    match
      Drafts.enqueue_submission ~now:t0 ~keeper:"alpha-1"
        ~mode:Drafts.Mode_steer d1
    with
    | Some (d2, tx) -> Drafts.mark_sending ~now:t0 ~request_id:tx.request_id d2
    | None -> Alcotest.fail "expected pending tx"
  in
  let m_pending = make_chat_model base_fleet drafts_tx in
  let rows_pending =
    Chat_transcript.count_transcript_rows ~model:m_pending ~keeper:"alpha-1"
      ~width:g_compact.prose_w
  in
  Alcotest.(check int) "pending tx adds 1 separator + 1 row (+2)"
    (rows_compact + 2) rows_pending;

  (* (d) Multiline draft expands composer and shrinks chat body_h *)
  let drafts_multi =
    m0.drafts
    |> Drafts.set_active_keeper "alpha-1"
    |> Drafts.insert_text "line1\nline2\nline3\nline4"
  in
  let m_multi = make_chat_model base_fleet drafts_multi in
  let g_multi = Chat_transcript.chat_viewport_geometry ~model:m_multi in
  Alcotest.(check bool) "multiline composer shrinks chat body_h" true
    (g_multi.body_h < g_compact.body_h);

  (* (e) Display_origin_inline removes separate header rows at wide width *)
  let m_wide = Model.initial ~cols:140 ~rows:40 () in
  let f_wide =
    m_wide.fleet
    |> Fleet_store.apply_keepers ~observed_at:t0 [ sample_keeper "alpha-1" ]
    |> Fleet_store.apply_chat_history ~observed_at:t0 ~keeper:"alpha-1"
         { messages = md_msgs; has_more = false; next_cursor = None }
  in
  let m_bare =
    {
      m_wide with
      fleet = f_wide;
      nav =
        {
          m_wide.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha-1"; tab = Nav.Keeper_chat } ];
        };
    }
  in
  let m_inline =
    { m_bare with fleet = Fleet_store.cycle_origin_mode f_wide }
  in
  let gw = Chat_transcript.chat_viewport_geometry ~model:m_bare in
  let r_bare =
    Chat_transcript.count_transcript_rows ~model:m_bare ~keeper:"alpha-1"
      ~width:gw.prose_w
  in
  let r_inline =
    Chat_transcript.count_transcript_rows ~model:m_inline ~keeper:"alpha-1"
      ~width:gw.prose_w
  in
  Alcotest.(check bool) "Display_origin_inline uses fewer rows than Bare at wide width"
    true (r_inline < r_bare)

let test_p1_work_inbox_ask_approval_sync () =
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let work_inbox =
    m0.work
    |> Work_store.set_tab Nav.Work_inbox
    |> Work_store.apply_asks ~observed_at:t0
         [
           sample_ask ~id:"ask-1" ~keeper:"alpha-1" ();
           sample_ask ~id:"ask-2" ~keeper:"alpha-2" ();
         ]
    |> Work_store.apply_tool_approvals ~observed_at:t0
         [ sample_tool_approval ~id:"ap-1" ~keeper:"alpha-1" () ]
  in
  let m_inbox =
    { m0 with nav = { m0.nav with workspace = Nav.Work }; work = work_inbox }
    |> Model.rebuild_attention
  in
  (* Index 0 is Held_tool_approval (urgency 400): MUST NOT focus Ask_choice_focused *)
  Alcotest.(check bool)
    "triage_index=0 (tool approval) is Workspace_focused, not Ask_choice_focused"
    true
    (Nav.equal_focus_scope
       (Model.active_focus_scope m_inbox)
       (Nav.Workspace_focused Nav.Work));
  let m_press1_on_ap, cmds_press1_ap =
    Update.step ~now:t0 m_inbox (Msg.Key_event (char_key "1"))
  in
  Alcotest.(check bool)
    "pressing '1' on tool approval switches workspace to Pulse (not answering ask-1)"
    true
    (Nav.equal_workspace m_press1_on_ap.nav.workspace Nav.Pulse);
  let has_ask_post cmds =
    List.find_map
      (function
        | Cmd.Http_post { req = Cmd.Post_ask_answer { ask_id; _ }; _ } ->
            Some ask_id
        | Cmd.Batch _
        | Cmd.Http_get _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            None)
      (Cmd.flatten cmds)
  in
  Alcotest.(check (option string))
    "pressing '1' on tool approval emits 0 Post_ask_answer" None
    (has_ask_post cmds_press1_ap);

  (* Step Down -> index 1 (ask-1) -> Down -> index 2 (ask-2) *)
  let m_i1, _ =
    Update.step ~now:t0 m_inbox (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check bool) "triage_index=1 (ask-1) enters Ask_choice_focused" true
    (Nav.equal_focus_scope
       (Model.active_focus_scope m_i1)
       Nav.Ask_choice_focused);
  let m_i2, _ =
    Update.step ~now:t0 m_i1 (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check bool) "triage_index=2 (ask-2) enters Ask_choice_focused" true
    (Nav.equal_focus_scope
       (Model.active_focus_scope m_i2)
       Nav.Ask_choice_focused);
  (* Copy_selected ('y') copies ask-2, NOT ask-1 *)
  let _, cmds_copy = Update.step ~now:t0 m_i2 (Msg.Key_event (char_key "y")) in
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
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            None)
      (Cmd.flatten cmds_copy)
  in
  Alcotest.(check (option string))
    "Work_inbox 'y' on triage_index=2 copies ask-2" (Some "ask-2") copied;
  (* Pressing 'a' answers ask-2, NOT ask-1; bare '1' stays workspace switch! *)
  let _, cmds_ans = Update.step ~now:t0 m_i2 (Msg.Key_event (char_key "a")) in
  Alcotest.(check (option string))
    "Work_inbox 'a' on triage_index=2 submits Post_ask_answer for ask-2"
    (Some "ask-2") (has_ask_post cmds_ans)

let test_p1_pulse_collapsed_company_dive_and_scroll () =
  let ks =
    [
      grouped_keeper ~group:"org-alpha" "alpha-1";
      grouped_keeper ~group:"org-alpha" "alpha-2";
      grouped_keeper ~group:"org-beta" "beta-1";
      grouped_keeper ~group:"org-beta" "beta-2";
      grouped_keeper ~group:"org-mid" "mid-1";
      grouped_keeper ~group:"org-zeta" "zeta-1";
    ]
  in
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let m1, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         { epoch = m0.epoch; reply = Msg.Reply_keepers_roster (Ok (roster_of ks)) })
  in
  (* Collapse org-beta in Keepers, then navigate Pulse onto org-beta *)
  let m_col =
    {
      m1 with
      nav = { m1.nav with workspace = Nav.Pulse };
      fleet = Fleet_store.toggle_company_collapsed "org-beta" m1.fleet;
    }
  in
  let m_on_beta, _ =
    Update.step ~now:t0 m_col (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check (option string))
    "Pulse Down lands on collapsed org-beta lead beta-1" (Some "beta-1")
    m_on_beta.fleet.selected_keeper;
  Alcotest.(check (option string))
    "selected_company_keeper resolves beta-1 even when org-beta is collapsed"
    (Some "beta-1")
    (Option.map
       (fun (k : Wire_fleet.keeper_summary) -> k.name)
       (Fleet_store.selected_company_keeper m_on_beta.fleet));
  let m_dived, _ =
    Update.step ~now:t0 m_on_beta (Msg.Key_event (key Keymap.Input.Enter))
  in
  Alcotest.(check bool)
    "Enter on Pulse collapsed org-beta dives into beta-1 (not alpha-1)" true
    (Option.equal Nav.equal_dive
       (Model.active_dive m_dived)
       (Some (Nav.Dive_keeper { name = "beta-1"; tab = Nav.Keeper_chat })));
  let m_popped, _ =
    Update.step ~now:t0 m_dived (Msg.Key_event (key Keymap.Input.Escape))
  in
  let m_on_mid, _ =
    Update.step ~now:t0 m_popped (Msg.Key_event (key Keymap.Input.Down))
  in
  Alcotest.(check (option string))
    "Next Pulse Down advances cleanly to org-mid (mid-1)" (Some "mid-1")
    m_on_mid.fleet.selected_keeper;

  (* Independent pulse_scroll_offset with 10 companies & viewport_rows=4 *)
  let ks10 =
    List.init 10 (fun i ->
        grouped_keeper
          ~group:(Printf.sprintf "org-%02d" i)
          (Printf.sprintf "k-%02d" i))
  in
  let f10 = Fleet_store.apply_keepers ~observed_at:t0 ks10 Fleet_store.empty in
  let f10_deep =
    List.fold_left
      (fun acc _ ->
        Fleet_store.move_company_selection ~viewport_rows:4 ~delta:1 acc)
      f10 (List.init 7 Fun.id)
  in
  Alcotest.(check int) "pulse_scroll_offset advances symmetrically (7 - 4 + 1 = 4)"
    4 f10_deep.pulse_scroll_offset;
  let f10_up1 =
    Fleet_store.move_company_selection ~viewport_rows:4 ~delta:(-1) f10_deep
  in
  Alcotest.(check int)
    "Pulse Up inside window keeps pulse_scroll_offset = 4" 4
    f10_up1.pulse_scroll_offset

let test_p2_grouped_top_header_row0_restoration () =
  let vr = 5 in
  (* 1. Fleet_store Fleet_companies *)
  let fleet_ks =
    List.init 12 (fun i ->
        grouped_keeper
          ~group:(Printf.sprintf "org-%02d" (i / 3))
          (Printf.sprintf "k-%02d" i))
  in
  let f0 = Fleet_store.apply_keepers ~observed_at:t0 fleet_ks Fleet_store.empty in
  let f_deep =
    List.fold_left
      (fun acc _ -> Fleet_store.move_selection ~viewport_rows:vr ~delta:1 acc)
      f0 (List.init 8 Fun.id)
  in
  Alcotest.(check bool) "Fleet scrolled down past row 0" true
    (f_deep.scroll_offset > 1);
  let f_back_step =
    List.fold_left
      (fun acc _ -> Fleet_store.move_selection ~viewport_rows:vr ~delta:(-1) acc)
      f_deep (List.init 8 Fun.id)
  in
  Alcotest.(check int) "Fleet stepping Up to index 0 restores scroll_offset=0 (header visible)"
    0 f_back_step.scroll_offset;
  let f_home = Fleet_store.move_selection ~viewport_rows:vr ~delta:(-100000) f_deep in
  Alcotest.(check int) "Fleet Home restores scroll_offset=0" 0
    f_home.scroll_offset;

  (* 2. Runtime_store Runtime_efficiency_spend *)
  let mk_eff i : Wire_runtime.keeper_efficiency_row =
    {
      keeper = Printf.sprintf "k-%02d" i;
      turns = 10;
      input_tokens = 1000;
      cache_read_tokens = Observed.value ~observed_at:t0 500;
      cache_creation_tokens = Observed.value ~observed_at:t0 0;
      output_tokens = 100;
      cache_hit_pct = Observed.value ~observed_at:t0 50.0;
      cost_usd = float_of_int (20 - i);
      calls = 10;
      failed = 0;
      deferred = 0;
      tool_ms = 50.0;
    }
  in
  let eff : Wire_runtime.efficiency_month =
    {
      month = "2026-11";
      window_kind = Some Wire_runtime.Efficiency_month_mtd;
      generated_at_unix = 1_795_200_000.0;
      days_covered = 22;
      keepers = List.init 12 mk_eff;
      fleet =
        {
          turns_total = 120;
          calls_per_turn = 1.0;
          tool_s_per_turn = 0.5;
          output_tokens_per_turn = 100.0;
          input_tokens_per_turn = 1000.0;
          cost_usd_per_turn = 1.0;
          fleet_cache_hit_pct = Observed.value ~observed_at:t0 50.0;
        };
      velocity = [];
    }
  in
  let rt0 =
    Runtime_store.empty
    |> Runtime_store.sync_keeper_companies fleet_ks
    |> Runtime_store.set_tab Nav.Runtime_efficiency_spend
    |> Runtime_store.apply_efficiency ~observed_at:t0 eff
  in
  let rt_deep =
    List.fold_left
      (fun acc _ -> Runtime_store.move_selection ~viewport_rows:vr ~delta:1 acc)
      rt0 (List.init 8 Fun.id)
  in
  Alcotest.(check bool) "Runtime efficiency scrolled down past row 0" true
    (rt_deep.scroll_offset > 1);
  let rt_back_step =
    List.fold_left
      (fun acc _ ->
        Runtime_store.move_selection ~viewport_rows:vr ~delta:(-1) acc)
      rt_deep (List.init 8 Fun.id)
  in
  Alcotest.(check int)
    "Runtime efficiency stepping Up to index 0 restores scroll_offset=0" 0
    rt_back_step.scroll_offset;
  let rt_home =
    Runtime_store.move_selection ~viewport_rows:vr ~delta:(-100000) rt_deep
  in
  Alcotest.(check int) "Runtime efficiency Home restores scroll_offset=0" 0
    rt_home.scroll_offset;

  (* 3. Knowledge_store Wiki clusters *)
  let empty_lint : Wire_knowledge.wiki_index_lint =
    {
      total_findings = 0;
      counts =
        {
          broken_link = 0;
          unsupported_link = 0;
          orphan = 0;
          orphan_unconfirmed = 0;
          missing_sources = 0;
          hearsay_only = 0;
          unreadable_page = 0;
          revision_log_gap = 0;
          revision_log_hole = 0;
          duplicate_title_candidates = 0;
        };
      log_hole_suppressed = false;
      orphans = [];
      duplicate_title_candidates = [];
      findings = [];
    }
  in
  let wiki12 =
    List.init 12 (fun i : Wire_knowledge.wiki_page_summary ->
        {
          slug = Printf.sprintf "page-%02d" i;
          file = Printf.sprintf "page-%02d.md" i;
          title = Printf.sprintf "Page %02d" i;
          summary = "s";
          source = Wire_knowledge.Source_research;
          author = "alpha-1";
          created = "2026-11-01";
          updated = "2026-11-22";
          revision = 1;
          tags = [ Printf.sprintf "topic-%02d" (i / 3) ];
          backlink_count = 0;
          outgoing_link_count = 0;
          sources_count = 1;
          hearsay_count = 0;
          sha256 = "sha";
        })
  in
  let kw0 =
    Knowledge_store.empty
    |> Knowledge_store.set_tab Nav.Knowledge_wiki
    |> Knowledge_store.apply_wiki_index ~observed_at:t0
         {
           pages_total = 12;
           pages_readable = 12;
           pages_unreadable = 0;
           pages = wiki12;
           unreadable_pages = [];
           lint = empty_lint;
         }
  in
  let kw_deep =
    List.fold_left
      (fun acc _ -> Knowledge_store.move_selection ~viewport_rows:vr ~delta:1 acc)
      kw0 (List.init 8 Fun.id)
  in
  Alcotest.(check bool) "Wiki scrolled down past row 0" true
    (kw_deep.scroll_offset > 1);
  let kw_back =
    List.fold_left
      (fun acc _ ->
        Knowledge_store.move_selection ~viewport_rows:vr ~delta:(-1) acc)
      kw_deep (List.init 8 Fun.id)
  in
  Alcotest.(check int) "Wiki stepping Up to index 0 restores scroll_offset=0" 0
    kw_back.scroll_offset;
  let kw_home =
    Knowledge_store.move_selection ~viewport_rows:vr ~delta:(-100000) kw_deep
  in
  Alcotest.(check int) "Wiki Home restores scroll_offset=0" 0
    kw_home.scroll_offset;

  (* 4. Knowledge_store Board with expanded first succession chain *)
  let mk_bpost ?chain_root ?depth i : Wire_knowledge.board_post =
    {
      id = Printf.sprintf "bp-%02d" i;
      title = Printf.sprintf "Post %02d" i;
      body = "Body";
      author = "alpha-1";
      hearth = None;
      post_kind = Some Wire_knowledge.Human_post;
      visibility = Some Wire_knowledge.Vis_public;
      created_at_unix = float_of_int (2000 - i);
      updated_at_unix = None;
      score = 0;
      comment_count = 0;
      author_karma = Observed.unreported;
      succession_chain_root_id = chain_root;
      chain_depth = depth;
      is_signal = true;
    }
  in
  let board_posts =
    [
      mk_bpost ~chain_root:"root-0" ~depth:1 0;
      mk_bpost ~chain_root:"root-0" ~depth:2 1;
    ]
    @ List.init 8 (fun i -> mk_bpost (i + 2))
  in
  let kb0 =
    Knowledge_store.empty
    |> Knowledge_store.apply_board ~observed_at:t0
         {
           posts = board_posts;
           count = List.length board_posts;
           sort_by = "recent";
           signal_only = true;
         }
    |> Knowledge_store.toggle_succession_chain ~root_id:"root-0"
  in
  let kb_deep =
    List.fold_left
      (fun acc _ -> Knowledge_store.move_selection ~viewport_rows:vr ~delta:1 acc)
      kb0 (List.init 8 Fun.id)
  in
  Alcotest.(check bool) "Board expanded chain scrolled past row 0" true
    (kb_deep.scroll_offset > 1);
  let kb_back =
    List.fold_left
      (fun acc _ ->
        Knowledge_store.move_selection ~viewport_rows:vr ~delta:(-1) acc)
      kb_deep (List.init kb_deep.selected_index Fun.id)
  in
  Alcotest.(check int)
    "Board expanded chain stepping Up reaches index 0" 0
    kb_back.selected_index;
  Alcotest.(check int)
    "Board expanded chain stepping Up to index 0 restores scroll_offset=0" 0
    kb_back.scroll_offset;
  let kb_home =
    Knowledge_store.move_selection ~viewport_rows:vr ~delta:(-100000) kb_deep
  in
  Alcotest.(check int) "Board expanded chain Home restores scroll_offset=0" 0
    kb_home.scroll_offset

let test_p2_schedules_attention_scroll_and_filter_guard () =
  (* 1. Work_tasks_schedules: independent schedules_scroll_offset *)
  let mk_task i : Wire_work.task =
    {
      id = Printf.sprintf "t-%02d" i;
      title = Printf.sprintf "Task %02d" i;
      description = None;
      priority = 1;
      status = Wire_work.Todo;
      goal_link = Wire_work.Unlinked;
      created_at = None;
      updated_at = None;
    }
  in
  let mk_sched i : Wire_work.schedule_row =
    {
      schedule_instance_id = Printf.sprintf "si-%02d" i;
      schedule_id = Printf.sprintf "s-%02d" i;
      status = Wire_work.Sched_scheduled;
      source = "keeper.toml";
      due_at_unix = 1_800_000_000.0;
      next_due_at_unix = None;
      recurrence_kind = "cron";
      recurrence_summary = "0 * * * *";
      payload_kind = None;
      payload_support = "prompt";
      payload_target = None;
      payload_keeper_name = Some "alpha-1";
      payload_summary = None;
      last_wake_unix = None;
      last_disposition = Wire_work.Wake_never;
    }
  in
  let w0 =
    Work_store.empty
    |> Work_store.set_tab Nav.Work_tasks
    |> Work_store.apply_planning ~observed_at:t0
         { goals = []; tasks = List.init 10 mk_task }
    |> Work_store.apply_schedules ~observed_at:t0
         (List.init 10 mk_sched, None)
  in
  let w_tasks = Work_store.move_selection ~viewport_rows:5 ~delta:9 w0 in
  Alcotest.(check int) "Tasks scroll_offset = 5" 5 w_tasks.scroll_offset;
  let w_sched0 = Work_store.set_tab Nav.Work_schedules w0 in
  let w_scheds = Work_store.move_selection ~viewport_rows:5 ~delta:8 w_sched0 in
  Alcotest.(check int)
    "Schedules tab scroll_offset scrolls symmetrically (8 - 5 + 1 = 4)" 4
    w_scheds.schedules_scroll_offset;
  let w_scheds_up1 = Work_store.move_selection ~viewport_rows:5 ~delta:(-1) w_scheds in
  Alcotest.(check int) "Schedules Up inside window keeps scroll_offset=4" 4
    w_scheds_up1.schedules_scroll_offset;

  (* 2. Attention.move_triage symmetric triage_scroll_offset *)
  let asks10 =
    List.init 10 (fun i ->
        sample_ask ~id:(Printf.sprintf "ask-%02d" i) ~keeper:"alpha-1" ())
  in
  let att0 =
    Attention.rebuild ~asks:asks10 ~tool_approvals:[] ~gate_pending:[]
      ~goals:[] Attention.empty
  in
  let att_deep = Attention.move_triage ~viewport_rows:5 ~delta:8 att0 in
  Alcotest.(check int) "Attention triage_scroll_offset = 8 - 5 + 1 = 4" 4
    att_deep.triage_scroll_offset;
  let att_up1 = Attention.move_triage ~viewport_rows:5 ~delta:(-1) att_deep in
  Alcotest.(check int) "Attention Up inside window keeps triage_scroll_offset=4"
    4 att_up1.triage_scroll_offset;
  let att_up_past =
    Attention.move_triage ~viewport_rows:5 ~delta:(-4) att_up1
  in
  Alcotest.(check int) "Attention Up past top edge pulls triage_scroll_offset=3"
    3 att_up_past.triage_scroll_offset;

  (* 3. Update_nav.apply_move allows live Up/Down while filter_focused = true,
     and blocks Left/Right so cursor/tab cycling never hijacks filter typing *)
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let m_filt =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Work; filter_focused = true };
      work = w0;
    }
  in
  let m_after_dn, _ = Update_nav.apply_move m_filt Keymap.Down in
  Alcotest.(check int) "apply_move Down moves live when filter_focused=true" 1
    m_after_dn.work.selected_index;
  let m_after_r, _ = Update_nav.apply_move m_filt Keymap.Right in
  Alcotest.(check bool) "apply_move Right does not cycle tab when filter_focused=true"
    true
    (Nav.equal_work_tab m_after_r.work.active_tab Nav.Work_tasks)

(* The Keepers list and a keeper's work tab read the active schedules: the
   list's next-due column and the tab's schedule rows depend on them. The tab
   is opened from Pulse, whose own fetches never ask for schedules, so the
   request comes from the tab. A schedule change refetches them there too. *)
let test_keepers_views_request_active_schedules () =
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let is_active_schedules = function
    | Cmd.Http_get { req = Cmd.Get_schedules { cursor = None } as req; _ } ->
        String.equal (Cmd.get_request_path req)
          "/api/v1/dashboard/scheduled-automation?active_only=true"
    | _ -> false
  in
  let requests_active_schedules m =
    List.exists is_active_schedules
      (Cmd.flatten (View_fetches.fetches_for_current_view ~force:false m))
  in
  let keepers = { m0 with nav = { m0.nav with workspace = Nav.Keepers } } in
  Alcotest.(check bool) "Keepers requests active schedules" true
    (requests_active_schedules keepers);
  let pulse = { m0 with nav = { m0.nav with workspace = Nav.Pulse } } in
  Alcotest.(check bool) "Pulse alone does not request schedules" false
    (requests_active_schedules pulse);
  let work_tab =
    {
      pulse with
      nav =
        {
          pulse.nav with
          dive_stack = [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_work_candle } ];
        };
    }
  in
  Alcotest.(check bool) "Keeper work tab over Pulse requests active schedules" true
    (requests_active_schedules work_tab);
  let _, cmds =
    Update.step ~now:t0 work_tab
      (Msg.Sse_event
         {
           epoch = work_tab.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 1;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Dataset_changed
                        Wire_observer.Dataset_scheduled_automation);
               };
         })
  in
  Alcotest.(check bool) "a schedule change refetches them for the work tab" true
    (List.exists is_active_schedules (Cmd.flatten cmds))

let test_tui_memory_os_internals_fetch_and_runtime_assignment_setup_cmds () =
  let t0 = Clock.Mono.of_ns 10_000_000_000L in
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  (* 1. Keeper_memory dive triggers Get_keeper_memory_os_internals *)
  let m_kmem =
    {
      m0 with
      nav =
        {
          m0.nav with
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory } ];
        };
    }
  in
  let kmem_cmds = Cmd.flatten (View_fetches.fetches_for_current_view ~force:false m_kmem) in
  Alcotest.(check bool) "Keeper_memory fetches Get_keeper_memory_os_internals" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_keeper_memory_os_internals { keeper = "alpha" }; _ } -> true
         | _ -> false)
       kmem_cmds);
  (* 2. Nav.Runtime triggers Get_runtime_config_raw and Get_setup_inventory *)
  let m_rt =
    { m0 with nav = { m0.nav with workspace = Nav.Runtime } }
  in
  let rt_cmds = Cmd.flatten (View_fetches.fetches_for_current_view ~force:false m_rt) in
  Alcotest.(check bool) "Runtime workspace fetches Get_runtime_config_raw" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_runtime_config_raw; _ } -> true
         | _ -> false)
       rt_cmds);
  Alcotest.(check bool) "Runtime workspace fetches Get_setup_inventory" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_setup_inventory; _ } -> true
         | _ -> false)
       rt_cmds);
  (* 3. Runtime assignment modal [a], API key modal [k], Login start [l] + status poll [L] *)
  let m_raw, _ =
    Update.step ~now:t0 m_rt
      (Msg.Http_reply
         {
           epoch = m_rt.epoch;
           reply =
             Msg.Reply_runtime_config_raw
               (Ok
                  {
                    Wire_runtime.source_revision = "rev-cas-42";
                    assignments = [ "alpha", "old.slot" ];
                  });
         })
  in
  let m_assign_modal, _ =
    Update.step ~now:t0 m_raw (Msg.Key_event (key (Keymap.Input.Char "a")))
  in
  (match m_assign_modal.nav.overlay with
  | Some (Nav.Inline_action _) -> ()
  | _ -> Alcotest.fail "Runtime [a] must open inline assignment modal");
  (* Fill keeper="" and runtime="primary" -> Post_runtime_default_route *)
  let m_assign_filled =
    match m_assign_modal.inline_modal with
    | None -> Alcotest.fail "inline_modal missing"
    | Some st ->
        let fields =
          List.map
            (fun (f : Model.modal_form_field) ->
              if String.equal f.key "assign_keeper" then { f with value = "alpha" }
              else if String.equal f.key "assign_runtime_id" then
                { f with value = "vibe_acp.devstral-2" }
              else f)
            st.fields
        in
        { m_assign_modal with inline_modal = Some { st with fields } }
  in
  let _, assign_cmds =
    Update.step ~now:t0 m_assign_filled (Msg.Key_event (key Keymap.Input.Enter))
  in
  Alcotest.(check bool) "Submitting [a] modal emits Post_runtime_assignment with CAS" true
    (List.exists
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_runtime_assignment
                   {
                     keeper_name = "alpha";
                     runtime_id = Some "vibe_acp.devstral-2";
                     source_revision = Some "rev-cas-42";
                     previous_runtime_id = Some "old.slot";
                   };
               _;
             } ->
             true
         | _ -> false)
       (Cmd.flatten assign_cmds));
  (* [K] API key modal: secret field masked + submits to /api/v1/setup/credential with source_revision *)
  let m_key_modal, _ =
    Update.step ~now:t0 m_raw (Msg.Key_event (key (Keymap.Input.Char "K")))
  in
  let m_key_filled =
    match m_key_modal.inline_modal with
    | None -> Alcotest.fail "key inline_modal missing"
    | Some st ->
        let secret_field =
          List.find (fun (f : Model.modal_form_field) -> String.equal f.key "setup_key_secret")
            st.fields
        in
        Alcotest.(check bool) "setup_key_secret marked secret=true for masking" true
          secret_field.secret;
        let fields =
          List.map
            (fun (f : Model.modal_form_field) ->
              if String.equal f.key "setup_key_integration" then
                { f with value = "gemini" }
              else if String.equal f.key "setup_key_secret" then
                { f with value = "test-api-key-value" }
              else f)
            st.fields
        in
        { m_key_modal with inline_modal = Some { st with fields } }
  in
  let _, key_cmds =
    Update.step ~now:t0 m_key_filled (Msg.Key_event (key Keymap.Input.Enter))
  in
  let expected_key_req =
    Cmd.Post_setup_account_key
      {
        integration_id = "gemini";
        key = "test-api-key-value";
        source_revision = "rev-cas-42";
      }
  in
  Alcotest.(check bool) "Submitting [K] modal emits Post_setup_account_key with source_revision" true
    (List.exists
       (function
         | Cmd.Http_post { req; _ } when req = expected_key_req -> true
         | _ -> false)
       (Cmd.flatten key_cmds));
  Alcotest.(check string) "Post_setup_account_key targets operator /api/v1/setup/credential"
    "/api/v1/setup/credential" (Cmd.post_request_path expected_key_req);
  Alcotest.(check string) "Post_setup_account_key encodes exact 3-field operator payload"
    {|{"provider_id":"gemini","secret":"test-api-key-value","source_revision":"rev-cas-42"}|}
    (Yojson.Safe.to_string (Cmd.post_request_body expected_key_req));
  (* Without loaded runtime_config_raw, [K] blocks submission with modal error instead of posting *)
  let m_key_no_rev =
    {
      m_key_filled with
      runtime = { m_key_filled.runtime with runtime_config_raw = Observed.unreported };
    }
  in
  let m_key_blocked, blocked_cmds =
    Update.step ~now:t0 m_key_no_rev (Msg.Key_event (key Keymap.Input.Enter))
  in
  Alcotest.(check int) "Missing source_revision emits zero HTTP commands" 0
    (List.length (Cmd.flatten blocked_cmds));
  Alcotest.(check bool) "Missing source_revision keeps inline modal open with error" true
    (match m_key_blocked.inline_modal with
     | Some st -> Option.is_some st.error
     | None -> false);
  let _, key_ok_cmds =
    Update.step ~now:t0 m_raw
      (Msg.Http_reply
         {
           epoch = m_raw.epoch;
           reply = Msg.Reply_setup_account_key { integration_id = "gemini"; result = Ok () };
         })
  in
  Alcotest.(check bool) "Successful [K] reply refetches runtime_config_raw for fresh CAS revision"
    true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_runtime_config_raw; _ } -> true
         | _ -> false)
       (Cmd.flatten key_ok_cmds));
  (* [l] Login start modal + Reply_setup_login_receipt + [L] poll *)
  let m_login_modal, _ =
    Update.step ~now:t0 m_raw (Msg.Key_event (key (Keymap.Input.Char "l")))
  in
  let m_login_filled =
    match m_login_modal.inline_modal with
    | None -> Alcotest.fail "login inline_modal missing"
    | Some st ->
        let fields =
          List.map
            (fun (f : Model.modal_form_field) ->
              if String.equal f.key "setup_login_integration" then
                { f with value = "vibe_acp" }
              else f)
            st.fields
        in
        { m_login_modal with inline_modal = Some { st with fields } }
  in
  let m_after_login, login_cmds =
    Update.step ~now:t0 m_login_filled (Msg.Key_event (key Keymap.Input.Enter))
  in
  Alcotest.(check bool) "Submitting [l] modal emits Post_setup_login_start" true
    (List.exists
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_setup_login_start
                   { integration_id = "vibe_acp"; account_ref = None };
               _;
             } ->
             true
         | _ -> false)
       (Cmd.flatten login_cmds));
  let m_with_recp, _ =
    Update.step ~now:t0 m_after_login
      (Msg.Http_reply
         {
           epoch = m_after_login.epoch;
           reply =
             Msg.Reply_setup_login_receipt
               (Ok
                  {
                    Wire_runtime.login_id = "login-99";
                    integration_id = "vibe_acp";
                    status = "running";
                    account = Some "keyring_host";
                    account_ref = None;
                    authentication = None;
                  });
         })
  in
  let _, poll_cmds =
    Update.step ~now:t0 m_with_recp (Msg.Key_event (key (Keymap.Input.Char "L")))
  in
  Alcotest.(check bool) "[L] polls Get_setup_login_status for active login_id" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_setup_login_status { login_id = "login-99" }; _ } ->
             true
         | _ -> false)
       (Cmd.flatten poll_cmds))

let test_agui_chat_stream_lifecycle_15_bugs () =
  let mk_msg ~id ~role ~content ?operation_id ?transcript_slot ?failure_kind
      ?turn_ref ts : Wire_fleet.chat_message =
    {
      id;
      role;
      content;
      ts_unix = ts;
      turn_ref;
      model_used = None;
      tool_call_id = None;
      tool_call_name = None;
      execution_id = None;
      operation_id;
      transcript_slot;
      failure_kind;
    }
  in
  let m0 = Model.initial ~cols:120 ~rows:36 () in
  let m0 =
    {
      m0 with
      fleet =
        m0.fleet
        |> Fleet_store.apply_keepers ~observed_at:t0 [ sample_keeper "alpha-leader" ]
        |> Fleet_store.apply_chat_history ~observed_at:t0 ~keeper:"alpha-leader"
             {
               messages =
                 [
                   mk_msg ~id:"old-1" ~role:Wire_fleet.Role_user ~content:"이전 질문" 10.0;
                   mk_msg ~id:"old-2" ~role:Wire_fleet.Role_assistant ~content:"OK" 11.0;
                 ];
               has_more = false;
               next_cursor = None;
             }
        |> Fleet_store.move_chat_scroll ~max_scroll:10 ~delta:5;
      drafts = Drafts.set_active_keeper "alpha-leader" m0.drafts;
      nav =
        {
          m0.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha-leader"; tab = Nav.Keeper_chat } ];
        };
    }
  in
  (* BUG-12: Keeper_chat dive fetches Get_keeper_turns + Get_chat_history *)
  let dive_cmds = View_fetches.fetches_for_current_view m0 in
  Alcotest.(check bool) "Keeper_chat dive fetches Get_keeper_turns" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_keeper_turns; _ } -> true
         | _ -> false)
       (Cmd.flatten dive_cmds));

  (* BUG-3, BUG-11, BUG-14: Idle submit gets Mode_direct, session-unique request_id, resets scroll *)
  let m1 = { m0 with drafts = Drafts.insert_text "음" m0.drafts } in
  let m2, _ = Update.execute_action ~now:t0 m1 Keymap.Submit_steer in
  Alcotest.(check int) "submit_composer resets chat_scroll_offset to 0" 0
    m2.fleet.chat_scroll_offset;
  let tx_a =
    match Drafts.active_tx_for_keeper ~keeper:"alpha-leader" m2.drafts with
    | Some tx -> tx
    | None -> Alcotest.fail "missing tx_a"
  in
  Alcotest.(check bool) "request_id is session-unique (not chat-1)" true
    ((not (String.equal tx_a.request_id "chat-1"))
    && String.starts_with ~prefix:"tui-" tx_a.request_id
    && String.length tx_a.request_id <= 128);
  Alcotest.(check bool) "idle send uses honest Mode_direct (no 조향)" true
    (Drafts.equal_delivery_mode tx_a.mode Drafts.Mode_direct);
  Alcotest.(check bool) "phase is Phase_sending" true
    (Chat_transcript.equal_live_chat_phase
       (Chat_transcript.live_chat_phase ~model:m2 ~keeper:"alpha-leader")
       Chat_transcript.Phase_sending);

  (* BUG-12: Chunk_accepted updates chat_control_token & transitions to Pending_processing *)
  let m3, _ =
    Update.step ~now:t1 m2
      (Msg.Chat_stream_chunk
         {
           epoch = m2.epoch;
           keeper = "alpha-leader";
           request_id = tx_a.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_accepted
               {
                 operation_id = tx_a.request_id;
                 queued_count = 0;
                 state = Wire_fleet.Accepted_running;
                 interactive_outcome = Some Wire_fleet.Interactive_applied;
                 control_token = Some "ctrl-tok-fresh";
               };
         })
  in
  Alcotest.(check (option string)) "Chunk_accepted updates chat_control_token"
    (Some "ctrl-tok-fresh")
    (Fleet_store.chat_control_token_for ~keeper:"alpha-leader" m3.fleet);

  (* Live streaming phases: Thinking -> Tool_running -> Streaming *)
  let m4, _ =
    Update.step ~now:t1 m3
      (Msg.Chat_stream_chunk
         {
           epoch = m3.epoch;
           keeper = "alpha-leader";
           request_id = tx_a.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_thinking_delta
               { operation_id = None; delta = "reasoning..." };
         })
  in
  Alcotest.(check bool) "phase -> Phase_thinking" true
    (Chat_transcript.equal_live_chat_phase
       (Chat_transcript.live_chat_phase ~model:m4 ~keeper:"alpha-leader")
       Chat_transcript.Phase_thinking);
  let m5, _ =
    Update.step ~now:t1 m4
      (Msg.Chat_stream_chunk
         {
           epoch = m4.epoch;
           keeper = "alpha-leader";
           request_id = tx_a.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_tool_start
               {
                 operation_id = None;
                 tool_use_id = "scope-1-block-0";
                 tool_name = "masc_status";
                 args_preview = None;
               };
         })
  in
  Alcotest.(check bool) "phase -> Phase_tool_running" true
    (Chat_transcript.equal_live_chat_phase
       (Chat_transcript.live_chat_phase ~model:m5 ~keeper:"alpha-leader")
       (Chat_transcript.Phase_tool_running "masc_status"));
  let m6, _ =
    Update.step ~now:t1 m5
      (Msg.Chat_stream_chunk
         {
           epoch = m5.epoch;
           keeper = "alpha-leader";
           request_id = tx_a.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_tool_end
               {
                 operation_id = None;
                 tool_use_id = "scope-1-block-0";
                 tool_name = None;
                 ok = None;
                 output_preview = None;
               };
         })
  in
  let m7, _ =
    Update.step ~now:t1 m6
      (Msg.Chat_stream_chunk
         {
           epoch = m6.epoch;
           keeper = "alpha-leader";
           request_id = tx_a.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_text_delta
               {
                 operation_id = None;
                 delta = "OK";
                 owner = Wire_chat_journal.Unobserved_scope None;
               };
         })
  in
  Alcotest.(check bool) "phase -> Phase_streaming" true
    (Chat_transcript.equal_live_chat_phase
       (Chat_transcript.live_chat_phase ~model:m7 ~keeper:"alpha-leader")
       Chat_transcript.Phase_streaming);

  (* BUG-9 & BUG-4: Submitting Follow_up B while A is streaming does NOT wipe A's stream,
     pending_txs_for_keeper is chronological [A; B], and active_tx_for_keeper stays A *)
  let m8 = { m7 with drafts = Drafts.insert_text "..?" m7.drafts } in
  let m9, _ = Update.execute_action ~now:t1 m8 Keymap.Submit_followup in
  let keeper_txs = Drafts.pending_txs_for_keeper ~keeper:"alpha-leader" m9.drafts in
  Alcotest.(check (list string)) "pending_txs_for_keeper is chronological (oldest-first)"
    [ "음"; "..?" ]
    (List.map (fun (tx : Drafts.pending_message) -> tx.body) keeper_txs);
  let tx_b = List.nth keeper_txs 1 in
  Alcotest.(check bool) "active_tx_for_keeper keeps oldest executing tx A (not newest B)"
    true
    (match Drafts.active_tx_for_keeper ~keeper:"alpha-leader" m9.drafts with
    | Some tx -> String.equal tx.request_id tx_a.request_id
    | None -> false);
  let buf_after_followup =
    Fleet_store.String_map.find "alpha-leader" m9.fleet.chat_streams
  in
  Alcotest.(check string) "Follow_up submit does NOT wipe active stream A"
    tx_a.request_id buf_after_followup.request_id;
  Alcotest.(check string) "Stream A text preserved" "OK" buf_after_followup.text;
  let m10, _ =
    Update.step ~now:t1 m9
      (Msg.Chat_stream_chunk
         {
           epoch = m9.epoch;
           keeper = "alpha-leader";
           request_id = tx_b.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_accepted
               {
                 operation_id = tx_b.request_id;
                 queued_count = 1;
                 state = Wire_fleet.Accepted_queued;
                 interactive_outcome = None;
                 control_token = None;
               };
         })
  in
  Alcotest.(check string) "Queued acceptance for B does NOT hijack active stream A"
    tx_a.request_id
    (Fleet_store.String_map.find "alpha-leader" m10.fleet.chat_streams).request_id;

  (* BUG-5: Chat_transcript.project_transcript orders History -> Active User A -> Stream A -> Queued B *)
  let sections = Chat_transcript.project_transcript ~model:m10 ~keeper:"alpha-leader" in
  Alcotest.(check int) "4 chronological sections (hist, active user A, stream A, queued B)"
    4 (List.length sections);
  (match sections with
  | [
      Chat_transcript.Section_history _;
      Chat_transcript.Section_pending [ { tx = pa; _ } ];
      Chat_transcript.Section_stream sp;
      Chat_transcript.Section_pending [ { tx = pb; _ } ];
    ] ->
      Alcotest.(check string) "pre-stream pending is A" tx_a.request_id pa.request_id;
      Alcotest.(check string) "stream belongs to A" tx_a.request_id sp.buf.request_id;
      Alcotest.(check string) "post-stream pending is queued B" tx_b.request_id pb.request_id
  | _ -> Alcotest.fail "unexpected transcript section projection order");

  (* BUG-13: Interrupt without active_turn sends request_id (NOT interrupt_token) and sets Interrupting *)
  let m_int, cmds_int =
    Update.step ~now:t1 m10 (Msg.Key_event (key Keymap.Input.Escape))
  in
  let int_body_opt =
    List.find_map
      (function
        | Cmd.Http_post { req = Cmd.Post_keeper_turn_interrupt _ as req; _ } ->
            Some (Cmd.post_request_body req)
        | _ -> None)
      (Cmd.flatten cmds_int)
  in
  (match int_body_opt with
  | Some (`Assoc fields) ->
      Alcotest.(check bool) "interrupt without UUID turn sends request_id" true
        (List.assoc_opt "request_id" fields = Some (`String tx_a.request_id));
      Alcotest.(check bool) "interrupt without UUID turn omits interrupt_token" true
        (Option.is_none (List.assoc_opt "interrupt_token" fields))
  | _ -> Alcotest.fail "expected Post_keeper_turn_interrupt with request_id");
  Alcotest.(check bool) "interrupt sets Phase_interrupting (not premature stream error)" true
    (Chat_transcript.equal_live_chat_phase
       (Chat_transcript.live_chat_phase ~model:m_int ~keeper:"alpha-leader")
       Chat_transcript.Phase_interrupting);
  Alcotest.(check (option string)) "no premature last_error before server ack" None
    (Fleet_store.String_map.find "alpha-leader" m_int.fleet.chat_streams).last_error;

  (* BUG-10: Short repeated reply "OK" (already in prior_msg_ids) does NOT prematurely vanish! *)
  let m_done_a, _ =
    Update.step ~now:t2 m10
      (Msg.Chat_stream_chunk
         {
           epoch = m10.epoch;
           keeper = "alpha-leader";
           request_id = tx_a.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_turn_done
               { operation_id = Some tx_a.request_id; turn_ref = None; reply = None };
         })
  in
  let buf_done_a =
    Fleet_store.String_map.find "alpha-leader" m_done_a.fleet.chat_streams
  in
  let hist_old =
    match Observed.to_option (Fleet_store.String_map.find "alpha-leader" m_done_a.fleet.chat_histories) with
    | Some p -> p.messages
    | None -> []
  in
  Alcotest.(check bool) "short repeated reply 'OK' in prior_msg_ids does NOT prematurely vanish"
    false (Chat_transcript.stream_reply_already_persisted hist_old buf_done_a);

  (* Finding #2: Back-to-back "OK" replies with distinct operation_ids do NOT cross-dedup
     even when Turn 1's persisted row is NOT in Turn 2's prior_msg_ids *)
  let buf_turn2_ok : Fleet_store.chat_stream_buffer =
    {
      buf_done_a with
      request_id = "op-ok-2";
      operation_id = Some "op-ok-2";
      turn_ref = None;
      text = "OK";
      prior_msg_ids = Fleet_store.String_set.empty;
    }
  in
  let hist_turn1_ok =
    [
      mk_msg ~id:"hist-ok-1" ~role:Wire_fleet.Role_assistant ~content:"OK"
        ~operation_id:"op-ok-1" ~transcript_slot:"terminal_result" 30.0;
    ]
  in
  Alcotest.(check bool)
    "back-to-back 'OK' with different operation_id does NOT prematurely vanish"
    false (Chat_transcript.stream_reply_already_persisted hist_turn1_ok buf_turn2_ok);
  let hist_turn2_ok =
    hist_turn1_ok
    @ [
        mk_msg ~id:"hist-ok-2" ~role:Wire_fleet.Role_assistant ~content:"OK"
          ~operation_id:"op-ok-2" ~transcript_slot:"terminal_result" 31.0;
      ]
  in
  Alcotest.(check bool)
    "matching operation_id persists Turn 2's 'OK' cleanly"
    true (Chat_transcript.stream_reply_already_persisted hist_turn2_ok buf_turn2_ok);

  (* BUG-8: Now B starts executing (RUN_STARTED) and takes over chat_streams;
     a late RUN_ERROR from older A MUST NOT clobber B's active stream! *)
  let m_b_run, _ =
    Update.step ~now:t2 m_done_a
      (Msg.Chat_stream_chunk
         {
           epoch = m_done_a.epoch;
           keeper = "alpha-leader";
           request_id = tx_b.request_id;
           is_btw = false;
           chunk = Wire_fleet.Chunk_run_started { operation_id = Some tx_b.request_id };
         })
  in
  let m_b_delta, _ =
    Update.step ~now:t2 m_b_run
      (Msg.Chat_stream_chunk
         {
           epoch = m_b_run.epoch;
           keeper = "alpha-leader";
           request_id = tx_b.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_text_delta
               {
                 operation_id = None;
                 delta = "응답 B";
                 owner = Wire_chat_journal.Unobserved_scope None;
               };
         })
  in
  let m_late_err, cmds_late_err =
    Update.step ~now:t2 m_b_delta
      (Msg.Chat_stream_chunk
         {
           epoch = m_b_delta.epoch;
           keeper = "alpha-leader";
           request_id = tx_a.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_error
               {
                 operation_id = Some tx_a.request_id;
                 code = Some "turn_failed";
                 message = "stale error from A";
               };
         })
  in
  let buf_after_late_err =
    Fleet_store.String_map.find "alpha-leader" m_late_err.fleet.chat_streams
  in
  Alcotest.(check string) "Late RUN_ERROR from older A does NOT clobber active stream B"
    tx_b.request_id buf_after_late_err.request_id;
  Alcotest.(check string) "Active stream B text intact" "응답 B" buf_after_late_err.text;
  Alcotest.(check (option string)) "Active stream B has no stale error" None
    buf_after_late_err.last_error;
  (* BUG-6 & BUG-14: Chunk_error triggers Get_chat_history *)
  Alcotest.(check bool) "Chunk_error triggers Get_chat_history" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_chat_history { keeper = "alpha-leader"; _ }; _ } ->
             true
         | _ -> false)
       (Cmd.flatten cmds_late_err));

  (* BUG-6 & BUG-7: Persisted Role_user + Role_request_failure for A removes Failed_retryable A completely *)
  let m_reconciled, _ =
    Update.step ~now:t2 m_late_err
      (Msg.Http_reply
         {
           epoch = m_late_err.epoch;
           reply =
             Msg.Reply_chat_history
               {
                 keeper = "alpha-leader";
                 result =
                   Ok
                     {
                       messages =
                         [
                           mk_msg ~id:"old-1" ~role:Wire_fleet.Role_user ~content:"이전 질문" 10.0;
                           mk_msg ~id:"old-2" ~role:Wire_fleet.Role_assistant ~content:"OK" 11.0;
                           mk_msg ~id:"srv-u-a" ~role:Wire_fleet.Role_user ~content:"음"
                             ~operation_id:tx_a.request_id ~transcript_slot:"accepted_user" 20.0;
                           mk_msg ~id:"srv-f-a" ~role:Wire_fleet.Role_request_failure
                             ~content:"stale error from A" ~operation_id:tx_a.request_id
                             ~transcript_slot:"settled_failure" ~failure_kind:"turn_exception" 21.0;
                         ];
                       has_more = false;
                       next_cursor = None;
                     };
               };
         })
  in
  Alcotest.(check (list string)) "Persisted Role_request_failure removes Failed_retryable tx A"
    [ tx_b.request_id ]
    (List.map
       (fun (tx : Drafts.pending_message) -> tx.request_id)
       (Drafts.pending_txs_for_keeper ~keeper:"alpha-leader" m_reconciled.drafts));

  (* BUG-14: Embedded Keepers split-pane Keeper_chat receives SSE refresh on Chat_operation *)
  let m_embedded =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Keepers; dive_stack = [] };
      fleet =
        m0.fleet
        |> Fleet_store.select_keeper "alpha-leader"
        |> Fleet_store.set_keeper_dive_tab Nav.Keeper_chat;
    }
  in
  let _, emb_cmds =
    Update.step ~now:t1 m_embedded
      (Msg.Sse_event
         {
           epoch = m_embedded.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 1;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Keeper_chat_appended
                        {
                          keeper = "alpha-leader";
                          connector = None;
                          at_unix = 101.0;
                        });
               };
         })
  in
  Alcotest.(check bool) "Embedded Keepers chat preview refreshes on Keeper_chat_appended" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_chat_history { keeper = "alpha-leader"; _ }; _ } ->
             true
         | _ -> false)
       (Cmd.flatten emb_cmds));

  (* BUG-14: Confirming_delivery bounded retries on Tick settle cleanly; idle Tick emits 0 cmds *)
  let _, idle_tick_cmds =
    Update.step ~now:(Clock.Mono.after_s t0 5.0) m0 (Msg.Tick { wall_unix = 200.0 })
  in
  Alcotest.(check int) "Idle Tick emits 0 HTTP cmds" 0 (List.length idle_tick_cmds);
  let m_conf =
    let d =
      m0.drafts
      |> Drafts.insert_text "confirm me"
      |> fun d0 ->
      match
        Drafts.enqueue_submission ~now:t0 ~keeper:"alpha-leader"
          ~mode:Drafts.Mode_direct d0
      with
      | Some (d1, tx) -> Drafts.mark_confirming ~now:t0 ~request_id:tx.request_id d1
      | None -> Alcotest.fail "enqueue failed"
    in
    { m0 with drafts = d }
  in
  (* Finding #1: Esc and Ctrl+X during Confirming_delivery pop cleanly & never corrupt tx state *)
  let m_conf_esc, cmds_conf_esc =
    Update.step ~now:t0 m_conf (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc during Confirming_delivery pops Dive_keeper" true
    (Option.is_none (Model.active_dive m_conf_esc));
  Alcotest.(check bool) "Esc during Confirming_delivery emits 0 interrupt POSTs" false
    (List.exists
       (function
         | Cmd.Http_post { req = Cmd.Post_keeper_turn_interrupt _; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_conf_esc));
  Alcotest.(check bool) "Confirming_delivery tx state remains intact after Esc" true
    (match Drafts.active_tx_for_keeper ~keeper:"alpha-leader" m_conf_esc.drafts with
    | Some { state = Drafts.Confirming_delivery; _ } -> true
    | _ -> false);
  let m_conf_ctrlx, cmds_conf_ctrlx =
    Update.step ~now:t0 m_conf
      (Msg.Key_event (key ~ctrl:true (Keymap.Input.Char "x")))
  in
  Alcotest.(check bool) "Ctrl+X during Confirming_delivery emits 0 interrupt POSTs" false
    (List.exists
       (function
         | Cmd.Http_post { req = Cmd.Post_keeper_turn_interrupt _; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_conf_ctrlx));
  Alcotest.(check bool) "Confirming_delivery tx state remains intact after Ctrl+X" true
    (match Drafts.active_tx_for_keeper ~keeper:"alpha-leader" m_conf_ctrlx.drafts with
    | Some { state = Drafts.Confirming_delivery; _ } -> true
    | _ -> false);

  (* Finding #4 & #1: Accepted_queued keeps has_active_chat_stream = false;
     Esc during Queued pops Dive_keeper cleanly without corrupting Queued state *)
  let m_q_submit, _ =
    Update.execute_action ~now:t0
      { m0 with drafts = Drafts.insert_text "wait behind autonomous" m0.drafts }
      Keymap.Submit_steer
  in
  let tx_q =
    match Drafts.active_tx_for_keeper ~keeper:"alpha-leader" m_q_submit.drafts with
    | Some tx -> tx
    | None -> Alcotest.fail "missing queued tx"
  in
  let m_q_acc, _ =
    Update.step ~now:t0 m_q_submit
      (Msg.Chat_stream_chunk
         {
           epoch = m_q_submit.epoch;
           keeper = "alpha-leader";
           request_id = tx_q.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_accepted
               {
                 operation_id = tx_q.request_id;
                 queued_count = 1;
                 state = Wire_fleet.Accepted_queued;
                 interactive_outcome = None;
                 control_token = None;
               };
         })
  in
  Alcotest.(check bool) "Accepted_queued sets has_active_chat_stream = false" false
    (Fleet_store.has_active_chat_stream ~keeper:"alpha-leader" m_q_acc.fleet);
  Alcotest.(check bool) "Accepted_queued phase is Phase_queued 1" true
    (Chat_transcript.equal_live_chat_phase
       (Chat_transcript.live_chat_phase ~model:m_q_acc ~keeper:"alpha-leader")
       (Chat_transcript.Phase_queued 1));
  let m_q_esc, cmds_q_esc =
    Update.step ~now:t0 m_q_acc (Msg.Key_event (key Keymap.Input.Escape))
  in
  Alcotest.(check bool) "Esc during Queued pops Dive_keeper cleanly" true
    (Option.is_none (Model.active_dive m_q_esc));
  Alcotest.(check bool) "Esc during Queued emits 0 interrupt POSTs" false
    (List.exists
       (function
         | Cmd.Http_post { req = Cmd.Post_keeper_turn_interrupt _; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_q_esc));
  Alcotest.(check bool) "Queued tx state stays Queued after Esc" true
    (match Drafts.active_tx_for_keeper ~keeper:"alpha-leader" m_q_esc.drafts with
    | Some { state = Drafts.Queued; _ } -> true
    | _ -> false);
  (* Finding #4: Terminal Accepted_succeeded keeps active=false, enters Confirming_delivery & fetches history *)
  let m_acc_done, cmds_acc_done =
    Update.step ~now:t0 m_q_submit
      (Msg.Chat_stream_chunk
         {
           epoch = m_q_submit.epoch;
           keeper = "alpha-leader";
           request_id = tx_q.request_id;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_accepted
               {
                 operation_id = tx_q.request_id;
                 queued_count = 0;
                 state = Wire_fleet.Accepted_succeeded;
                 interactive_outcome = Some Wire_fleet.Interactive_replayed;
                 control_token = None;
               };
         })
  in
  Alcotest.(check bool) "Accepted_succeeded sets has_active_chat_stream = false" false
    (Fleet_store.has_active_chat_stream ~keeper:"alpha-leader" m_acc_done.fleet);
  Alcotest.(check bool) "Accepted_succeeded moves tx to Confirming_delivery (not Pending_processing)" true
    (match Drafts.active_tx_for_keeper ~keeper:"alpha-leader" m_acc_done.drafts with
    | Some { state = Drafts.Confirming_delivery; _ } -> true
    | _ -> false);
  Alcotest.(check bool) "Accepted_succeeded triggers Get_chat_history" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_chat_history { keeper = "alpha-leader"; _ }; _ } ->
             true
         | _ -> false)
       (Cmd.flatten cmds_acc_done));

  let t_p3 = Clock.Mono.after_s t0 3.0 in
  let m_c1, cmds_c1 = Update.step ~now:t_p3 m_conf (Msg.Tick { wall_unix = 203.0 }) in
  Alcotest.(check int) "Confirming_delivery tick recheck emits 1 Get_chat_history"
    1 (List.length cmds_c1);
  let t_p6 = Clock.Mono.after_s t_p3 3.0 in
  let m_c2, _ = Update.step ~now:t_p6 m_c1 (Msg.Tick { wall_unix = 206.0 }) in
  let t_p9 = Clock.Mono.after_s t_p6 3.0 in
  let m_c3, cmds_c3 = Update.step ~now:t_p9 m_c2 (Msg.Tick { wall_unix = 209.0 }) in
  Alcotest.(check int) "Bounded Confirming_delivery settles after 3 rechecks (0 further polls)"
    0 (List.length cmds_c3);
  Alcotest.(check bool) "Settled unconfirmed tx is no longer stuck in Confirming_delivery"
    false (Drafts.has_active_tx_for ~keeper:"alpha-leader" m_c3.drafts);
  (* [X] dismisses failed pending txs cleanly in Dive Keeper_chat *)
  let m_dismissed, _ =
    Update.step ~now:t_p9 m_c3 (Msg.Key_event (char_key "X"))
  in
  Alcotest.(check int) "[X] dismisses failed pending txs in Keeper_chat" 0
    (List.length (Drafts.pending_txs_for_keeper ~keeper:"alpha-leader" m_dismissed.drafts));
  (* Finding #3: [X] also dismisses failed pending txs in Nav.Keepers embedded Keeper_chat *)
  let m_emb_fail =
    {
      m_c3 with
      nav = { m_c3.nav with workspace = Nav.Keepers; dive_stack = [] };
      fleet =
        m_c3.fleet
        |> Fleet_store.select_keeper "alpha-leader"
        |> Fleet_store.set_keeper_dive_tab Nav.Keeper_chat;
    }
  in
  let m_emb_dismissed, _ =
    Update.step ~now:t_p9 m_emb_fail (Msg.Key_event (char_key "X"))
  in
  Alcotest.(check int) "[X] dismisses failed pending txs in embedded Keepers Keeper_chat" 0
    (List.length (Drafts.pending_txs_for_keeper ~keeper:"alpha-leader" m_emb_dismissed.drafts));
  let m_emb_mem =
    {
      m_emb_fail with
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_memory m_emb_fail.fleet;
    }
  in
  let m_emb_mem_x, _ =
    Update.step ~now:t_p9 m_emb_mem (Msg.Key_event (char_key "X"))
  in
  Alcotest.(check int) "[X] does NOT dismiss chat errors when embedded tab is Keeper_memory" 1
    (List.length (Drafts.pending_txs_for_keeper ~keeper:"alpha-leader" m_emb_mem_x.drafts))

let test_memory_explorer_store_fetches_reading_and_sse () =
  let t0 = Clock.Mono.of_ns 5_000_000_000L in
  let get_paths cmds =
    List.filter_map
      (function
        | Cmd.Http_get { req; _ } -> Some (Cmd.get_request_path req)
        | Cmd.Batch _
        | Cmd.Http_post _
        | Cmd.Http_put _
        | Cmd.Http_post_stream _
        | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _
        | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _
        | Cmd.Render_memory_diagram _ | Cmd.Cancel_memory_diagram
        | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _
        | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _
        | Cmd.Start_local_server
        | Cmd.Restart_tui
        | Cmd.Quit _ ->
            None)
      (Cmd.flatten cmds)
  in
  let has_path p paths = List.exists (String.equal p) paths in
  (* 1. Fix 3 -> 기억 dead set_memory_diff_keeper bug: selecting writer in pane 0 scopes + fetches all 5 endpoints *)
  let wm : Wire_knowledge.world_memory =
    {
      ledger_state = Wire_knowledge.World_ledger_available;
      ledger_sha256 = Some "sha-wm";
      claims_count = 3;
      facts_count = 10;
      conflicts_count = 0;
      excluded_count = 0;
      claims = [];
      active_conflicts = [];
      briefing =
        {
          status = Wire_knowledge.Briefing_current;
          text = Some "world ok";
          source_ids_count = 1;
          error = None;
          building_pass = None;
        };
      librarian_writers =
        Wire_knowledge.Writers_running
          {
            error_count = 0;
            warn_count = 0;
            keepers =
              [
                {
                  keeper = "alpha";
                  state = Wire_knowledge.Writer_idle;
                  available_act_tokens = [];
                  snapshot_file = None;
                };
                {
                  keeper = "beta";
                  state = Wire_knowledge.Writer_open;
                  available_act_tokens = [ "resume" ];
                  snapshot_file = None;
                };
              ];
          };
      ordinary_absence_detail = None;
    }
  in
  let m0 =
    let base = Model.initial ~cols:140 ~rows:40 () in
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge; pane_index = 0 };
      knowledge =
        base.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_memory
        |> Knowledge_store.apply_world_memory ~observed_at:t0 wm;
    }
  in
  Alcotest.(check (option string)) "initial scope is World (None)" None
    m0.knowledge.memory_diff_keeper;
  (* Move Down from World Memory (idx 0) -> writer alpha (idx 1) *)
  let m1, cmds1 = Update.step ~now:t0 m0 (Msg.Key_event (char_key "j")) in
  Alcotest.(check (option string)) "Down onto alpha sets memory_diff_keeper"
    (Some "alpha") m1.knowledge.memory_diff_keeper;
  let paths1 = get_paths cmds1 in
  Alcotest.(check bool) "fetches alpha memory-facts" true
    (has_path "/api/v1/keepers/alpha/memory-facts" paths1);
  Alcotest.(check bool) "fetches alpha memory-journal?activity=1&limit=50" true
    (has_path "/api/v1/keepers/alpha/memory-journal?activity=1&limit=50" paths1);
  Alcotest.(check bool) "fetches alpha memory-diff" true
    (has_path "/api/v1/memory/diff?scope=keeper&keeper=alpha&window=24h" paths1);
  Alcotest.(check bool) "fetches alpha memory-os-internals" true
    (has_path "/api/v1/keepers/alpha/memory-os-internals" paths1);
  Alcotest.(check bool) "fetches fleet keeper-memory-health" true
    (has_path "/api/v1/dashboard/keeper-memory-health" paths1);
  (* Move Up back to World Memory (idx 0) resets memory_diff_keeper to None *)
  let m_world, cmds_w = Update.step ~now:t0 m1 (Msg.Key_event (char_key "k")) in
  Alcotest.(check (option string)) "Up back to idx 0 restores World scope" None
    m_world.knowledge.memory_diff_keeper;
  Alcotest.(check bool) "fetches world memory diff" true
    (has_path "/api/v1/memory/diff?scope=world&window=24h" (get_paths cmds_w));
  (* Move Down onto alpha and press Enter -> scopes + focuses pane 1 *)
  let m_enter_pane, _ =
    Update.step ~now:t0 m1
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check int) "Enter on writer row focuses pane 1" 1
    m_enter_pane.nav.pane_index;
  Alcotest.(check (option string)) "Enter keeps alpha scope" (Some "alpha")
    m_enter_pane.knowledge.memory_diff_keeper;

  (* 2. Populate activity + facts + health; verify PR 2 selected_activity_event hook, modes, sort, and reading *)
  let ev1 : Wire_knowledge.memory_activity_event =
    {
      identity = "ev-1";
      recorded_at_unix = 1795252001.0;
      revision = 4;
      kind = Wire_knowledge.Activity_created;
      before = [];
      after = [ { memory_id = "m-1"; claim = Some "First claim" } ];
      reason = None;
    }
  in
  let ev2 : Wire_knowledge.memory_activity_event =
    {
      identity = "ev-2";
      recorded_at_unix = 1795252002.0;
      revision = 5;
      kind = Wire_knowledge.Activity_revised;
      before = [ { memory_id = "m-1"; claim = Some "First claim" } ];
      after = [ { memory_id = "m-2"; claim = Some "Revised claim" } ];
      reason = Some "Updated after test";
    }
  in
  let act_data : Wire_knowledge.keeper_memory_activity =
    {
      keeper = "alpha";
      limit = 50;
      journal_lines = 2;
      undecodable_lines = 0;
      events = [ ev1; ev2 ];
      notes = [];
    }
  in
  let f_recent_low : Wire_knowledge.keeper_ordinary_fact =
    {
      memory_id = "f-rec";
      claim = "Recent but unretrieved";
      category = Wire_knowledge.Cat_fact;
      origin = Wire_knowledge.Origin_authored;
      basis = Wire_knowledge.Basis_observed;
      first_seen_unix = 1795251000.0;
      last_seen_unix = 1795252000.0;
      events = { retrieval = Wire_knowledge.Never_retrieved; retracted_count = 0; revised_from = [] };
    }
  in
  let f_older_hot : Wire_knowledge.keeper_ordinary_fact =
    {
      memory_id = "f-hot";
      claim = "Older but retrieved 9x";
      category = Wire_knowledge.Cat_lesson;
      origin = Wire_knowledge.Origin_authored;
      basis = Wire_knowledge.Basis_observed;
      first_seen_unix = 1795200000.0;
      last_seen_unix = 1795210000.0;
      events =
        {
          retrieval =
            Wire_knowledge.Retrieved
              { count = 9; distinct_days = 4; last_at_unix = 1795251900.0 };
          retracted_count = 0;
          revised_from = [ "f-old" ];
        };
    }
  in
  let facts_data : Wire_knowledge.keeper_memory_facts =
    {
      keeper = "alpha";
      ordinary =
        Wire_knowledge.Memory_store_present
          {
            revision = 5;
            snapshot_sha256 = "sha5";
            updated_at_unix = 1795252000.0;
            facts = [ f_recent_low; f_older_hot ];
            support_invalidations = [];
          };
      source_bound = Wire_knowledge.Memory_store_absent;
      events_unreadable_lines = 0;
      events_read_error = None;
    }
  in
  let m_loaded, _ =
    Update.step ~now:t0 m_enter_pane
      (Msg.Http_reply
         {
           epoch = m_enter_pane.epoch;
           reply =
             Msg.Reply_keeper_memory_activity
               { keeper = "alpha"; result = Ok act_data };
         })
  in
  let m_loaded, _ =
    Update.step ~now:t0 m_loaded
      (Msg.Http_reply
         {
           epoch = m_loaded.epoch;
           reply =
             Msg.Reply_keeper_memory_facts
               { keeper = "alpha"; result = Ok facts_data };
         })
  in
  (* PR 2 hook selected_activity_event tracks j/k in pane 1 Evolution *)
  Alcotest.(check (option string)) "selected_activity_event initially ev-1"
    (Some "ev-1")
    (Option.map (fun (e : Wire_knowledge.memory_activity_event) -> e.identity)
       (Knowledge_store.selected_activity_event m_loaded.knowledge));
  let m_ev2, _ = Update.step ~now:t0 m_loaded (Msg.Key_event (char_key "j")) in
  Alcotest.(check (option string)) "selected_activity_event moves to ev-2"
    (Some "ev-2")
    (Option.map (fun (e : Wire_knowledge.memory_activity_event) -> e.identity)
       (Knowledge_store.selected_activity_event m_ev2.knowledge));
  (* Enter opens full reading without pushing dive_stack; Esc closes reading *)
  let m_read, _ =
    Update.step ~now:t0 m_ev2
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Enter opens Reading_activity" true
    (match m_read.knowledge.memory_reading with
    | Some (Knowledge_store.Reading_activity { event; _ }) ->
        String.equal event.identity "ev-2"
    | _ -> false);
  Alcotest.(check int) "dive_stack not deepened" 0 (List.length m_read.nav.dive_stack);
  (* Short entry does NOT overshoot scroll past its exact projected line bound;
     long multi-line entry scrolls cleanly up to exact projected max_scroll (< 200) and stops. *)
  let m_read_short_scr, _ = Update.step ~now:t0 m_read (Msg.Key_event (char_key "j")) in
  Alcotest.(check int) "short reading clamps at exact max_scroll (0)" 0
    m_read_short_scr.knowledge.memory_reading_scroll;
  let long_claim =
    String.concat "\n" (List.init 45 (fun i -> Printf.sprintf "Long reading paragraph line %02d" i))
  in
  let long_entry =
    Knowledge_store.Reading_ordinary_fact
      {
        keeper = "alpha";
        revision = 5;
        fact = { f_recent_low with claim = long_claim };
      }
  in
  let m_read_long =
    { m_read with knowledge = Knowledge_store.open_memory_reading long_entry m_read.knowledge }
  in
  let m_read_scr, _ = Update.step ~now:t0 m_read_long (Msg.Key_event (char_key "j")) in
  Alcotest.(check int) "j scrolls memory_reading_scroll on overflowing entry" 1
    m_read_scr.knowledge.memory_reading_scroll;
  let m_read_end, _ =
    Update.step ~now:t0 m_read_scr
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.End; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "End lands on positive exact bound (< 200)" true
    (m_read_end.knowledge.memory_reading_scroll > 5
     && m_read_end.knowledge.memory_reading_scroll < 100);
  let m_read_end_dn, _ = Update.step ~now:t0 m_read_end (Msg.Key_event (char_key "j")) in
  Alcotest.(check int) "j at End does not overshoot exact max_scroll"
    m_read_end.knowledge.memory_reading_scroll
    m_read_end_dn.knowledge.memory_reading_scroll;
  let m_closed, _ =
    Update.step ~now:t0 m_read_scr
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Escape; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Esc closes memory_reading" true
    (Option.is_none m_closed.knowledge.memory_reading);

  (* Mode switch (t, f, d, e) & Facts sort toggle (s) *)
  let m_facts, _ = Update.step ~now:t0 m_closed (Msg.Key_event (char_key "f")) in
  Alcotest.(check bool) "f switches to View_facts" true
    (Knowledge_store.equal_memory_view_mode m_facts.knowledge.memory_view_mode
       Knowledge_store.View_facts);
  let first_id st =
    match Knowledge_store.filtered_memory_fact_rows ~keeper:"alpha" st with
    | Knowledge_store.Fact_ordinary { fact; _ } :: _ -> Some fact.memory_id
    | _ -> None
  in
  Alcotest.(check (option string)) "Recency sort puts f-rec first" (Some "f-rec")
    (first_id m_facts.knowledge);
  let m_facts_sorted, _ = Update.step ~now:t0 m_facts (Msg.Key_event (char_key "s")) in
  Alcotest.(check (option string)) "s toggles Retrieved sort putting f-hot first"
    (Some "f-hot") (first_id m_facts_sorted.knowledge);
  let m_diff_mode, _ = Update.step ~now:t0 m_facts_sorted (Msg.Key_event (char_key "t")) in
  Alcotest.(check bool) "t cycles Facts -> Diff" true
    (Knowledge_store.equal_memory_view_mode m_diff_mode.knowledge.memory_view_mode
       Knowledge_store.View_diff);

  (* 3. Separate Observed.t isolation: failed health fetch NEVER overwrites facts/activity *)
  let m_health_err, _ =
    Update.step ~now:t0 m_loaded
      (Msg.Http_reply
         {
           epoch = m_loaded.epoch;
           reply =
             Msg.Reply_keeper_memory_health
               (Error (Msg.Transport Health.Timeout));
         })
  in
  Alcotest.(check bool) "health becomes Failed" true
    (match m_health_err.knowledge.keeper_memory_health with
    | Observed.Failed { retryable = true; _ } -> true
    | _ -> false);
  Alcotest.(check bool) "facts stay Value" true
    (Observed.is_value
       (Knowledge_store.keeper_memory_facts_for ~keeper:"alpha"
          m_health_err.knowledge));
  Alcotest.(check bool) "activity stays Value" true
    (Observed.is_value
       (Knowledge_store.keeper_memory_activity_for ~keeper:"alpha"
          m_health_err.knowledge));

  (* 4. SSE invalidation: Keeper_memory_journal_appended & Dataset_memory_health refetch scoped keeper *)
  let m_sse1, cmds_sse1 =
    Update.step ~now:t0 m_loaded
      (Msg.Sse_event
         {
           epoch = m_loaded.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 10;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Keeper_memory_journal_appended
                        { keeper = "alpha"; at_unix = 1795252050.0 });
               };
         })
  in
  Alcotest.(check bool) "activity marked stale on journal append" true
    (Observed.is_stale
       (Knowledge_store.keeper_memory_activity_for ~keeper:"alpha"
          m_sse1.knowledge));
  let sse_paths = get_paths cmds_sse1 in
  Alcotest.(check bool) "journal append refetches activity" true
    (has_path "/api/v1/keepers/alpha/memory-journal?activity=1&limit=50" sse_paths);
  Alcotest.(check bool) "journal append refetches facts" true
    (has_path "/api/v1/keepers/alpha/memory-facts" sse_paths);
  Alcotest.(check bool) "journal append refetches health" true
    (has_path "/api/v1/dashboard/keeper-memory-health" sse_paths);

  (* 5. Dive_keeper Keeper_memory: Enter opens reading without deepening dive_stack; Esc closes reading first *)
  let m_dive =
    {
      m_loaded with
      nav =
        {
          m_loaded.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory } ];
        };
    }
  in
  let m_dive_read, _ =
    Update.step ~now:t0 m_dive
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check int) "Enter in Keeper_memory dive keeps dive_stack depth=1" 1
    (List.length m_dive_read.nav.dive_stack);
  Alcotest.(check bool) "Enter in Keeper_memory dive opens full reading" true
    (Option.is_some m_dive_read.knowledge.memory_reading);
  let m_dive_esc1, _ =
    Update.step ~now:t0 m_dive_read
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Escape; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "First Esc closes reading" true
    (Option.is_none m_dive_esc1.knowledge.memory_reading);
  Alcotest.(check int) "First Esc keeps dive_stack depth=1" 1
    (List.length m_dive_esc1.nav.dive_stack);
  let m_dive_esc2, _ =
    Update.step ~now:t0 m_dive_esc1
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Escape; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check int) "Second Esc pops dive_stack" 0
    (List.length m_dive_esc2.nav.dive_stack);

  (* 6. Issue #54520: Per-keeper facts/activity maps isolate each keeper's values,
        404s, and errors: late replies for alpha land on alpha's own slot without
        touching beta, non-retryable failures on beta stay on beta's slot without
        poisoning alpha or gamma, and switching alpha -> beta -> alpha preserves
        alpha's cached facts & activity without unnecessary refetching. *)
  let m_beta =
    {
      m_loaded with
      knowledge = Knowledge_store.set_memory_diff_keeper (Some "beta") m_loaded.knowledge;
    }
  in
  let late_alpha_404 =
    Msg.Http_reply
      {
        epoch = m_beta.epoch;
        reply =
          Msg.Reply_keeper_memory_facts
            {
              keeper = "alpha";
              result =
                Error
                  (Msg.Http_error
                     { status = 404; body = "not found"; api_error = None });
            };
      }
  in
  let m_after_late_404, _ = Update.step ~now:t0 m_beta late_alpha_404 in
  Alcotest.(check bool) "late alpha 404 lands on alpha slot only" true
    (match
       Knowledge_store.keeper_memory_facts_for ~keeper:"alpha"
         m_after_late_404.knowledge
     with
    | Observed.Absent -> true
    | _ -> false);
  Alcotest.(check bool) "late alpha 404 leaves beta slot Unreported" true
    (match
       Knowledge_store.keeper_memory_facts_for ~keeper:"beta"
         m_after_late_404.knowledge
     with
    | Observed.Unreported -> true
    | _ -> false);
  let late_alpha_err =
    Msg.Http_reply
      {
        epoch = m_beta.epoch;
        reply =
          Msg.Reply_keeper_memory_activity
            {
              keeper = "alpha";
              result = Error (Msg.Decode_error "stale decode failure");
            };
      }
  in
  let m_after_late_err, _ = Update.step ~now:t0 m_after_late_404 late_alpha_err in
  Alcotest.(check bool) "late alpha decode error keeps alpha's previous value stale (not wiped)" true
    (Observed.is_value
       (Knowledge_store.keeper_memory_activity_for ~keeper:"alpha"
          m_after_late_err.knowledge)
     && Observed.is_stale
          (Knowledge_store.keeper_memory_activity_for ~keeper:"alpha"
             m_after_late_err.knowledge));
  Alcotest.(check bool) "late alpha decode error records incident even while viewing beta" true
    (Incidents.count m_after_late_err.incidents > Incidents.count m_after_late_404.incidents);
  Alcotest.(check bool) "late alpha decode error leaves beta activity Unreported" true
    (match
       Knowledge_store.keeper_memory_activity_for ~keeper:"beta"
         m_after_late_err.knowledge
     with
    | Observed.Unreported -> true
    | _ -> false);
  (* Non-retryable Failed on beta stays strictly on beta's slot; switching to
     gamma still fetches gamma, and returning to alpha keeps alpha's cached value. *)
  let m_beta_failed, _ =
    Update.step ~now:t0 m_beta
      (Msg.Http_reply
         {
           epoch = m_beta.epoch;
           reply =
             Msg.Reply_keeper_memory_facts
               { keeper = "beta"; result = Error (Msg.Decode_error "bad beta json") };
         })
  in
  Alcotest.(check bool) "beta facts marked Failed(retryable=false)" true
    (match
       Knowledge_store.keeper_memory_facts_for ~keeper:"beta"
         m_beta_failed.knowledge
     with
    | Observed.Failed { retryable = false; _ } -> true
    | _ -> false);
  let m_gamma =
    {
      m_beta_failed with
      knowledge =
        Knowledge_store.set_memory_diff_keeper (Some "gamma")
          m_beta_failed.knowledge;
    }
  in
  Alcotest.(check bool) "gamma slot stays Unreported despite beta non-retryable failure" true
    (match
       Knowledge_store.keeper_memory_facts_for ~keeper:"gamma" m_gamma.knowledge
     with
    | Observed.Unreported -> true
    | _ -> false);
  let gamma_fetch_paths = get_paths (View_fetches.fetches_for_current_view m_gamma) in
  Alcotest.(check bool) "gamma facts fetched cleanly after beta non-retryable failure" true
    (has_path "/api/v1/keepers/gamma/memory-facts" gamma_fetch_paths);
  let m_back_alpha =
    {
      m_beta_failed with
      knowledge =
        Knowledge_store.set_memory_diff_keeper (Some "alpha")
          m_beta_failed.knowledge;
    }
  in
  Alcotest.(check bool) "switching alpha -> beta -> alpha preserves alpha's cached facts" true
    (Observed.is_value
       (Knowledge_store.keeper_memory_facts_for ~keeper:"alpha"
          m_back_alpha.knowledge)
     && not
          (Observed.is_stale
             (Knowledge_store.keeper_memory_facts_for ~keeper:"alpha"
                m_back_alpha.knowledge)));
  let alpha_refetch_paths = get_paths (View_fetches.fetches_for_current_view m_back_alpha) in
  Alcotest.(check bool) "returning to cached alpha does not needlessly refetch facts" false
    (has_path "/api/v1/keepers/alpha/memory-facts" alpha_refetch_paths);
  (* World scope ignores stale keeper diff & returns None for selected_activity_event *)
  let keeper_diff : Wire_knowledge.memory_diff =
    {
      scope = Wire_knowledge.Scope_keeper "alpha";
      range =
        {
          window = Some "24h";
          from_rev = Some 1;
          to_rev = Some 5;
          from_unix = None;
          to_unix = None;
        };
      retrieval_heat =
        {
          hot = 1;
          warm = 0;
          cold = 0;
          never_retrieved = 0;
          total_events = 1;
          unreadable_event_lines = 0;
        };
      body =
        Wire_knowledge.Keeper_diff
          {
            counts =
              {
                total_facts_now = 1;
                added = 1;
                updated = 0;
                retracted = 0;
                invalidated = 0;
                journal_failures_in_window = 0;
                journal_quarantines_in_window = 0;
                undecodable_journal_lines = 0;
              };
            revisions = [];
            added =
              [
                {
                  added_at_rev = Some 5;
                  memory_id = "md-1";
                  category = "fact";
                  origin = "authored";
                  text = "Alpha diff entry";
                  first_seen_unix = 1795252000.0;
                  last_seen_unix = Some 1795252000.0;
                  retrieval_count = 1;
                  last_retrieved_at_unix = Some 1795252000.0;
                  heat = Wire_knowledge.Heat_hot;
                };
              ];
            updated = [];
            retracted = [];
            invalidated = [];
            writer_status = None;
          };
    }
  in
  let m_with_kdiff =
    {
      m_loaded with
      knowledge =
        Knowledge_store.set_memory_diff ~keeper:(Some "alpha")
          ~window:Knowledge_store.Window_24h
          (Observed.value ~observed_at:t0 keeper_diff)
          m_loaded.knowledge;
    }
  in
  let k_world = Knowledge_store.set_memory_diff_keeper None m_with_kdiff.knowledge in
  Alcotest.(check int) "World scope filtered_memory_diff_items ignores stale keeper diff" 0
    (List.length (Knowledge_store.filtered_memory_diff_items k_world));
  Alcotest.(check bool) "World scope selected_activity_event is None" true
    (Option.is_none (Knowledge_store.selected_activity_event k_world));

  (* 7. P1 #2: memory_reading closes on workspace switch, Dive_keeper c hotkey, set_filter;
        stale reading never hijacks Esc outside Memory view *)
  let m_ws_switched, _ = Update.step ~now:t0 m_read (Msg.Key_event (char_key "1")) in
  Alcotest.(check bool) "switch_workspace closes memory_reading" true
    (Option.is_none m_ws_switched.knowledge.memory_reading);
  let m_filtered =
    { m_read with knowledge = Knowledge_store.set_filter "foo" m_read.knowledge }
  in
  Alcotest.(check bool) "set_filter closes memory_reading" true
    (Option.is_none m_filtered.knowledge.memory_reading);
  let m_dive_c, _ = Update.step ~now:t0 m_dive_read (Msg.Key_event (char_key "c")) in
  Alcotest.(check bool) "Dive_keeper c hotkey closes memory_reading" true
    (Option.is_none m_dive_c.knowledge.memory_reading);
  (* Even if a reading remained set on a non-memory workspace, Esc pops dive / does NOT hijack *)
  let m_stale_on_other_dive =
    {
      m_dive_read with
      nav =
        {
          m_dive_read.nav with
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_sandbox } ];
        };
    }
  in
  let m_esc_other, _ =
    Update.step ~now:t0 m_stale_on_other_dive
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Escape; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check int) "Esc on Keeper_sandbox pops dive instead of hijacking stale reading" 0
    (List.length m_esc_other.nav.dive_stack);

  (* 8. P1 #4: Zoomed (z) 3->기억 scrolls right pane (not hidden left pane);
        Zoomed 4->Keepers->기억 accepts e/f/d mode hotkeys *)
  let m_zoomed_mem =
    {
      m_loaded with
      nav = { m_loaded.nav with pane_index = 0; zoomed = true };
    }
  in
  let m_zoomed_j, _ = Update.step ~now:t0 m_zoomed_mem (Msg.Key_event (char_key "j")) in
  Alcotest.(check (option string)) "zoomed 3->기억 j keeps alpha scope" (Some "alpha")
    m_zoomed_j.knowledge.memory_diff_keeper;
  Alcotest.(check int) "zoomed 3->기억 j advances right-pane activity cursor" 1
    m_zoomed_j.knowledge.selected_activity_index;
  let m_keepers_zoomed =
    let base = Model.initial ~cols:140 ~rows:40 () in
    let fleet =
      base.fleet
      |> Fleet_store.apply_keepers ~observed_at:t0
           [ sample_keeper "alpha"; sample_keeper "beta" ]
      |> Fleet_store.select_keeper "alpha"
      |> Fleet_store.set_keeper_dive_tab Nav.Keeper_memory
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Keepers; pane_index = 0; zoomed = true };
      fleet;
      knowledge = Knowledge_store.set_memory_diff_keeper (Some "alpha") base.knowledge;
    }
  in
  let m_kz_f, _ = Update.step ~now:t0 m_keepers_zoomed (Msg.Key_event (char_key "f")) in
  Alcotest.(check bool) "zoomed 4->Keepers->기억 f switches to View_facts" true
    (Knowledge_store.equal_memory_view_mode m_kz_f.knowledge.memory_view_mode
       Knowledge_store.View_facts);
  (* Embedded 4->Keepers pane-0 keeper switch closes memory_reading & syncs memory_diff_keeper *)
  let m_emb_read =
    {
      m_keepers_zoomed with
      nav = { m_keepers_zoomed.nav with zoomed = false; pane_index = 0 };
      knowledge =
        Knowledge_store.open_memory_reading
          (Knowledge_store.Reading_activity { keeper = "alpha"; event = ev1; notes = [] })
          m_keepers_zoomed.knowledge;
    }
  in
  let m_emb_switched, _ = Update.step ~now:t0 m_emb_read (Msg.Key_event (char_key "j")) in
  Alcotest.(check (option string)) "embedded Keepers pane-0 j syncs memory_diff_keeper to beta"
    (Some "beta") m_emb_switched.knowledge.memory_diff_keeper;
  Alcotest.(check bool) "embedded Keepers pane-0 j closes alpha memory_reading" true
    (Option.is_none m_emb_switched.knowledge.memory_reading);
  (* Embedded 4->Keepers sub-tab cycle away from Keeper_memory closes memory_reading *)
  let m_emb_tab_read =
    {
      m_emb_read with
      nav = { m_emb_read.nav with pane_index = 1 };
    }
  in
  let m_emb_tab_away, _ =
    Update.step ~now:t0 m_emb_tab_read
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Right; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "embedded Keepers sub-tab cycle closes memory_reading" true
    (Option.is_none m_emb_tab_away.knowledge.memory_reading);

  (* 9. P2 #5: Memory_diff_dive Enter always opens Reading_diff_item even in View_evolution.
     The dive fetches into the Window_revs slot of its own range; the Memory
     tab's Window_24h slot is empty here, so Enter must read the dive's slot. *)
  let dive_window = Knowledge_store.Window_revs { from_rev = 1; to_rev = 5 } in
  let m_diff_dive =
    {
      m_loaded with
      nav =
        {
          m_loaded.nav with
          dive_stack =
            [
              Nav.Dive_knowledge
                (Nav.Memory_diff_dive
                   { keeper = Some "alpha"; from_rev = 1; to_rev = 5 });
            ];
        };
      knowledge =
        {
          (Knowledge_store.set_memory_diff ~keeper:(Some "alpha")
             ~window:dive_window
             (Observed.value ~observed_at:t0 keeper_diff)
             m_loaded.knowledge)
          with
          memory_view_mode = Knowledge_store.View_evolution;
        };
    }
  in
  let m_dd_enter, _ =
    Update.step ~now:t0 m_diff_dive
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Memory_diff_dive Enter opens Reading_diff_item regardless of view mode" true
    (match m_dd_enter.knowledge.memory_reading with
    | Some (Knowledge_store.Reading_diff_item { keeper = Some "alpha"; item = Knowledge_store.Keeper_added f }) ->
        String.equal f.memory_id "md-1"
    | _ -> false);

  (* 9b. Memory_diff_dive Down moves the cursor over the dive's own slot, keeps
     the Memory tab's window and keeper, and Enter then opens the second item. *)
  let keeper_diff_two : Wire_knowledge.memory_diff =
    {
      scope = Wire_knowledge.Scope_keeper "alpha";
      range =
        {
          window = Some "24h";
          from_rev = Some 1;
          to_rev = Some 5;
          from_unix = None;
          to_unix = None;
        };
      retrieval_heat =
        {
          hot = 2;
          warm = 0;
          cold = 0;
          never_retrieved = 0;
          total_events = 2;
          unreadable_event_lines = 0;
        };
      body =
        Wire_knowledge.Keeper_diff
          {
            counts =
              {
                total_facts_now = 2;
                added = 2;
                updated = 0;
                retracted = 0;
                invalidated = 0;
                journal_failures_in_window = 0;
                journal_quarantines_in_window = 0;
                undecodable_journal_lines = 0;
              };
            revisions = [];
            added =
              [
                {
                  added_at_rev = Some 4;
                  memory_id = "md-1";
                  category = "fact";
                  origin = "authored";
                  text = "Alpha diff entry";
                  first_seen_unix = 1795252000.0;
                  last_seen_unix = Some 1795252000.0;
                  retrieval_count = 1;
                  last_retrieved_at_unix = Some 1795252000.0;
                  heat = Wire_knowledge.Heat_hot;
                };
                {
                  added_at_rev = Some 5;
                  memory_id = "md-2";
                  category = "fact";
                  origin = "authored";
                  text = "Alpha second diff entry";
                  first_seen_unix = 1795252100.0;
                  last_seen_unix = Some 1795252100.0;
                  retrieval_count = 1;
                  last_retrieved_at_unix = Some 1795252100.0;
                  heat = Wire_knowledge.Heat_hot;
                };
              ];
            updated = [];
            retracted = [];
            invalidated = [];
            writer_status = None;
          };
    }
  in
  let m_diff_dive_two =
    {
      m_diff_dive with
      knowledge =
        Knowledge_store.set_memory_diff ~keeper:(Some "alpha")
          ~window:dive_window
          (Observed.value ~observed_at:t0 keeper_diff_two)
          m_diff_dive.knowledge;
    }
  in
  let m_dd_down, _ =
    Update.step ~now:t0 m_diff_dive_two
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Down; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check int) "Memory_diff_dive Down moves the cursor over the dive's own slot" 1
    m_dd_down.knowledge.selected_diff_index;
  Alcotest.(check bool) "Memory_diff_dive Down keeps the Memory tab's window and keeper" true
    (Knowledge_store.equal_memory_diff_window
       m_dd_down.knowledge.memory_diff_window
       m_diff_dive_two.knowledge.memory_diff_window
    && Option.equal String.equal m_dd_down.knowledge.memory_diff_keeper
         m_diff_dive_two.knowledge.memory_diff_keeper);
  let m_dd_down_enter, _ =
    Update.step ~now:t0 m_dd_down
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Memory_diff_dive Enter opens the item under the cursor" true
    (match m_dd_down_enter.knowledge.memory_reading with
    | Some (Knowledge_store.Reading_diff_item { keeper = Some "alpha"; item = Knowledge_store.Keeper_added f }) ->
        String.equal f.memory_id "md-2"
    | _ -> false);

  (* 10. P2 #6: Cross-keeper SSE events do NOT mark alpha's loaded slots stale *)
  let m_sse_other_health, _ =
    Update.step ~now:t0 m_loaded
      (Msg.Sse_event
         {
           epoch = m_loaded.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 11;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Dataset_changed
                        (Wire_observer.Dataset_memory_health (Some "other")));
               };
         })
  in
  Alcotest.(check bool) "other-keeper Dataset_memory_health keeps alpha facts fresh" false
    (Observed.is_stale
       (Knowledge_store.keeper_memory_facts_for ~keeper:"alpha"
          m_sse_other_health.knowledge));
  let m_sse_other_journal, _ =
    Update.step ~now:t0 m_loaded
      (Msg.Sse_event
         {
           epoch = m_loaded.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 12;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Keeper_memory_journal_appended
                        { keeper = "other"; at_unix = 1795252060.0 });
               };
         })
  in
  Alcotest.(check bool) "other-keeper journal append keeps alpha activity fresh" false
    (Observed.is_stale
       (Knowledge_store.keeper_memory_activity_for ~keeper:"alpha"
          m_sse_other_journal.knowledge));
  Alcotest.(check bool) "other-keeper journal append keeps alpha facts fresh" false
    (Observed.is_stale
       (Knowledge_store.keeper_memory_facts_for ~keeper:"alpha"
          m_sse_other_journal.knowledge))

(* Agent-core lifecycle events land in Infra activity as [CORE] rows;
   provider streaming telemetry does not. *)
let test_agent_core_activity_skips_only_telemetry () =
  let deliver kind (m : Model.t) =
    let ev : Wire_observer.agent_core_event =
      {
        kind;
        agent = Some "alpha";
        tool = None;
        task = None;
        turn = None;
        tool_use_id = None;
        at_unix = 1795252090.0;
        run_id = None;
        execution_id = None;
      }
    in
    fst
      (Update.step ~now:t0 m
         (Msg.Sse_event
            {
              epoch = m.epoch;
              event =
                Msg.Sse_observer_delivery
                  {
                    cursor = Some 1;
                    decoded = Wire_observer.Event (Wire_observer.Agent_core ev);
                  };
            }))
  in
  let core_rows (m : Model.t) =
    List.length
      (List.filter
         (fun (row : Infra_store.activity_row) ->
           match row.kind with
           | Infra_store.Activity_agent_core -> true
           | _ -> false)
         m.infra.activity_events)
  in
  let m0 = Model.initial () in
  let m1 = deliver Wire_observer.Telemetry m0 in
  Alcotest.(check int) "telemetry adds no activity row" (core_rows m0)
    (core_rows m1);
  let m2 = deliver (Wire_observer.Agent_completed { elapsed_s = 3.5 }) m1 in
  Alcotest.(check int) "agent_completed adds one [CORE] row" (core_rows m1 + 1)
    (core_rows m2);
  let m3 = deliver Wire_observer.Turn_started m2 in
  Alcotest.(check int) "turn_started adds one [CORE] row" (core_rows m2 + 1)
    (core_rows m3)

let test_fetch_failure_lands_on_panel_slot () =
  let step_reply r (m : Model.t) =
    fst (Update.step ~now:t1 m (Msg.Http_reply { epoch = m.epoch; reply = r }))
  in
  let m0 = Model.initial () in
  let m1 =
    step_reply (Msg.Reply_asks (Error (Msg.Decode_error "asks[0]: drift"))) m0
  in
  (match m1.work.asks with
  | Observed.Failed { retryable; _ } ->
      Alcotest.(check bool) "a decode failure is not retryable" false retryable
  | Observed.Loading _ | Observed.Value _ | Observed.Absent
  | Observed.Unreported ->
      Alcotest.fail "a panel that never loaded shows the fetch failure");
  let m2 = step_reply (Msg.Reply_asks (Ok [])) m1 in
  let m3 =
    step_reply (Msg.Reply_asks (Error (Msg.Transport Health.Timeout))) m2
  in
  match m3.work.asks with
  | Observed.Value { data; stale; _ } ->
      Alcotest.(check int) "a failed refetch keeps the last rows" 0
        (List.length data);
      Alcotest.(check bool) "a failed refetch marks the rows stale" true stale
  | Observed.Loading _ | Observed.Failed _ | Observed.Absent
  | Observed.Unreported ->
      Alcotest.fail "a failed refetch keeps the last good value"

(* A failure that is not retryable is asked again once the question changes.
   New parameters mark it stale, and another keeper has its own slot. *)
let test_failure_is_asked_again_for_a_new_question () =
  (match
     Observed.mark_stale
       (Observed.fetch_failed ~reason:"board[0]: drift" ~retryable:false
          ~at:t0 Observed.unreported)
   with
  | Observed.Failed { retryable; reason; _ } ->
      Alcotest.(check bool) "new parameters make the failure retryable" true
        retryable;
      Alcotest.(check string) "the panel keeps the reason" "board[0]: drift"
        reason
  | Observed.Loading _ | Observed.Value _ | Observed.Absent
  | Observed.Unreported ->
      Alcotest.fail "a stale failure stays a failure");
  let m0 = Model.initial () in
  let failed, _ =
    Update.step ~now:t1 m0
      (Msg.Http_reply
         {
           epoch = m0.epoch;
           reply =
             Msg.Reply_keeper_sandbox
               {
                 keeper = "alpha";
                 result =
                   Error
                     (Msg.Http_error
                        { status = 400; body = "bad keeper"; api_error = None });
               };
         })
  in
  let beta =
    {
      failed with
      nav =
        {
          failed.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "beta"; tab = Nav.Keeper_sandbox } ];
        };
    }
  in
  let asks_beta =
    List.exists
      (function
        | Cmd.Http_get { req = Cmd.Get_keeper_sandbox { keeper }; _ } ->
            String.equal keeper "beta"
        | Cmd.Http_get _ | Cmd.Batch _ | Cmd.Http_post _ | Cmd.Http_put _
        | Cmd.Http_post_stream _ | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _ | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _ | Cmd.Render_memory_diagram _
        | Cmd.Cancel_memory_diagram | Cmd.Fetch_artifact_and_copy _
        | Cmd.Export_artifact _ | Cmd.Open_external_url _
        | Cmd.Open_editor_escape_hatch _ | Cmd.Start_local_server
        | Cmd.Restart_tui | Cmd.Quit _ ->
            false)
      (Cmd.flatten (View_fetches.fetches_for_current_view beta))
  in
  Alcotest.(check bool) "a keeper's sandbox is asked after another 400" true
    asks_beta

(* Each answer lands in its own target's slot: one keeper's failure or 404
   does not touch another keeper's slot. *)
let test_answers_land_on_their_own_target () =
  let m0 = Model.initial () in
  let reply (m : Model.t) r =
    fst (Update.step ~now:t1 m (Msg.Http_reply { epoch = m.epoch; reply = r }))
  in
  let http status = Msg.Http_error { status; body = "x"; api_error = None } in
  let retryable_failure = function
    | Observed.Failed { retryable; _ } -> Some retryable
    | Observed.Value _ | Observed.Loading _ | Observed.Absent
    | Observed.Unreported ->
        None
  in
  let sandbox_error keeper status =
    Msg.Reply_keeper_sandbox { keeper; result = Error (http status) }
  in
  let m1 =
    reply (reply m0 (sandbox_error "alpha" 503)) (sandbox_error "beta" 400)
  in
  Alcotest.(check (option bool)) "alpha keeps its own retryable failure"
    (Some true)
    (retryable_failure
       (Infra_store.keeper_sandbox_for ~keeper:"alpha" m1.infra));
  Alcotest.(check (option bool)) "beta's 400 lands on beta" (Some false)
    (retryable_failure (Infra_store.keeper_sandbox_for ~keeper:"beta" m1.infra));
  let on_beta_sandbox =
    {
      m1 with
      nav =
        {
          m1.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "beta"; tab = Nav.Keeper_sandbox } ];
        };
    }
  in
  let asks_sandbox_of keeper =
    List.exists
      (function
        | Cmd.Http_get { req = Cmd.Get_keeper_sandbox { keeper = k }; _ } ->
            String.equal k keeper
        | _ -> false)
      (Cmd.flatten (View_fetches.fetches_for_current_view on_beta_sandbox))
  in
  Alcotest.(check bool) "beta's 400 is not asked again on the next plan" false
    (asks_sandbox_of "beta");
  let internals_error keeper status =
    Msg.Reply_keeper_memory_os_internals { keeper; result = Error (http status) }
  in
  let m2 =
    reply (reply m0 (internals_error "alpha" 503)) (internals_error "beta" 404)
  in
  Alcotest.(check (option bool)) "beta's 404 leaves alpha's internals alone"
    (Some true)
    (retryable_failure
       (Knowledge_store.memory_os_internals_for ~keeper:"alpha" m2.knowledge));
  Alcotest.(check bool) "beta's 404 is Absent on beta" true
    (match
       Knowledge_store.memory_os_internals_for ~keeper:"beta" m2.knowledge
     with
     | Observed.Absent -> true
     | Observed.Value _ | Observed.Loading _ | Observed.Unreported
     | Observed.Failed _ ->
         false)

(* On a first visit to the Wiki tab the fetch list is built before the index
   lands, so it names no page. The index reply asks for the page it selects. *)
let test_wiki_index_reply_requests_selected_page () =
  let summary : Wire_knowledge.wiki_page_summary =
    {
      slug = "guide";
      file = "guide.md";
      title = "Guide";
      summary = "Summary";
      source = Wire_knowledge.Source_observation;
      author = "alpha";
      created = "2026-11-20";
      updated = "2026-11-22";
      revision = 3;
      tags = [ "ops" ];
      backlink_count = 0;
      outgoing_link_count = 0;
      sources_count = 1;
      hearsay_count = 0;
      sha256 = "sha-w3";
    }
  in
  let lint : Wire_knowledge.wiki_index_lint =
    {
      total_findings = 0;
      counts =
        {
          broken_link = 0;
          unsupported_link = 0;
          orphan = 0;
          orphan_unconfirmed = 0;
          missing_sources = 0;
          hearsay_only = 0;
          unreadable_page = 0;
          revision_log_gap = 0;
          revision_log_hole = 0;
          duplicate_title_candidates = 0;
        };
      log_hole_suppressed = false;
      orphans = [];
      duplicate_title_candidates = [];
      findings = [];
    }
  in
  let index : Wire_knowledge.wiki_index =
    {
      pages_total = 1;
      pages_readable = 1;
      pages_unreadable = 0;
      pages = [ summary ];
      unreadable_pages = [];
      lint;
    }
  in
  let detail : Wire_knowledge.wiki_page_detail =
    {
      page = "guide";
      slug = "guide";
      file = "guide.md";
      frontmatter =
        {
          title = "Guide";
          summary = "Summary";
          source = Wire_knowledge.Source_observation;
          author = "alpha";
          created = "2026-11-20";
          updated = "2026-11-22";
          revision = 3;
          tags = [ "ops" ];
        };
      sha256 = "sha-w3";
      body_markdown = "# Guide\nBody text";
      outgoing_links = [];
      backlinks = [];
      lint_findings = [];
    }
  in
  let wiki_page_gets cmds =
    List.filter_map
      (function
        | Cmd.Http_get { req = Cmd.Get_wiki_page { page }; _ } -> Some page
        | _ -> None)
      (Cmd.flatten cmds)
  in
  let index_reply (m : Model.t) =
    snd
      (Update.step ~now:t1 m
         (Msg.Http_reply
            { epoch = m.epoch; reply = Msg.Reply_wiki_index (Ok index) }))
  in
  let m0 = Model.initial () in
  let on_wiki_tab =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Knowledge; dive_stack = [] };
      knowledge =
        Knowledge_store.set_tab Nav.Knowledge_wiki m0.knowledge;
    }
  in
  Alcotest.(check (list string))
    "the index reply asks for the page it selects" [ "guide" ]
    (wiki_page_gets (index_reply on_wiki_tab));
  let page_loaded =
    {
      on_wiki_tab with
      knowledge =
        Knowledge_store.set_wiki_page ~slug:detail.slug
          (Observed.value ~observed_at:t0 detail)
          on_wiki_tab.knowledge;
    }
  in
  Alcotest.(check (list string))
    "a page already held fresh is not asked for again" []
    (wiki_page_gets (index_reply page_loaded));
  let on_artifacts =
    {
      on_wiki_tab with
      knowledge =
        Knowledge_store.set_tab Nav.Knowledge_artifacts on_wiki_tab.knowledge;
    }
  in
  Alcotest.(check (list string))
    "the Artifacts view shows no page body, so none is asked for" []
    (wiki_page_gets (index_reply on_artifacts));
  let in_wiki_dive =
    {
      on_wiki_tab with
      nav =
        {
          on_wiki_tab.nav with
          dive_stack = [ Nav.Dive_knowledge (Nav.Wiki_dive "other-page") ];
        };
    }
  in
  Alcotest.(check (list string))
    "an open dive keeps its own page in the slot" []
    (wiki_page_gets (index_reply in_wiki_dive));
  let dive_with_index, _ =
    Update.step ~now:t1 in_wiki_dive
      (Msg.Http_reply
         { epoch = in_wiki_dive.epoch; reply = Msg.Reply_wiki_index (Ok index) })
  in
  Alcotest.(check (list string))
    "a refresh under a Wiki dive asks only for the dive's page"
    [ "other-page" ]
    (wiki_page_gets (View_fetches.fetches_for_current_view dive_with_index))

(* Infra > Repos lists the selected repository's activity and nothing else:
   an answer or a failure for another repository is dropped, and moving the
   cursor to another repository waits for that repository's own answer. *)
let test_infra_changes_follow_the_selected_repository () =
  let repo id ~keepers : Wire_infra.repository =
    {
      id;
      name = id;
      codebase = None;
      url = "https://example.invalid/" ^ id;
      resolved_local_path = "/srv/repos/" ^ id;
      default_branch = "main";
      status = Wire_infra.Repo_active;
      keepers;
      auto_sync = false;
    }
  in
  let change ~path ~keeper : Wire_infra.file_change =
    {
      path;
      keeper;
      change =
        Wire_infra.Change_edit
          { before = "a\nb"; after = "a\nc"; replace_all = false };
      line_evidence =
        Some
          (Wire_infra.Edit_ranges
             [
               {
                 old_range = { start_line = 7; end_line = 8 };
                 new_range = Some { start_line = 7; end_line = 8 };
               };
             ]);
      succeeded = true;
    }
  in
  let activity changes : Wire_infra.repository_activity =
    { window_hours = 24.0; changes; incomplete = 0; unattributed = 0 }
  in
  let paths inf =
    List.map
      (fun (fc : Wire_infra.file_change) -> fc.path)
      (Infra_store.repo_changes inf)
  in
  let is_waiting inf =
    match Infra_store.selected_repo_activity inf with
    | Some (_, Observed.Loading _) -> true
    | Some
        ( _,
          ( Observed.Value _ | Observed.Absent | Observed.Unreported
          | Observed.Failed _ ) )
    | None ->
        false
  in
  let masc_answer =
    activity
      [ change ~path:"lib/a.ml" ~keeper:"alpha"; change ~path:"lib/b.ml" ~keeper:"beta" ]
  in
  let docs_answer = activity [ change ~path:"README.md" ~keeper:"gamma" ] in
  let inf0 =
    Infra_store.empty
    |> Infra_store.set_tab Nav.Infra_repos_changes
    |> Infra_store.apply_repositories ~observed_at:t0
         [ repo "masc" ~keepers:[ "alpha"; "beta" ]; repo "docs" ~keepers:[] ]
  in
  let inf_other =
    Infra_store.apply_repo_activity ~repo_id:"docs" ~observed_at:t0 docs_answer
      inf0
  in
  Alcotest.(check (list string))
    "an answer for a repository that is not selected is dropped" []
    (paths inf_other);
  let inf1 =
    Infra_store.apply_repo_activity ~repo_id:"masc" ~observed_at:t0 masc_answer
      inf_other
  in
  Alcotest.(check (list string)) "the selected repository's answer is listed"
    [ "lib/a.ml"; "lib/b.ml" ] (paths inf1);
  Alcotest.(check (list string)) "the filter narrows by keeper"
    [ "lib/b.ml" ]
    (paths (Infra_store.set_filter "beta" inf1));
  Alcotest.(check (list string))
    "filtering by repository URL keeps all changes of the matched repo visible"
    [ "lib/a.ml"; "lib/b.ml" ]
    (paths (Infra_store.set_filter "example.invalid" inf1));
  Alcotest.(check (list string))
    "filtering by repository name keeps all changes of the matched repo visible"
    [ "lib/a.ml"; "lib/b.ml" ]
    (paths (Infra_store.set_filter "masc" inf1));
  Alcotest.(check (list string))
    "filtering by changed file path keeps the repo selected and narrows changes"
    [ "lib/a.ml" ]
    (paths (Infra_store.set_filter "lib/a.ml" inf1));
  let inf_with_idle =
    Infra_store.apply_repositories ~observed_at:t0
      [ repo "masc" ~keepers:[ "alpha"; "beta"; "idle" ] ]
      inf1
  in
  Alcotest.(check (list string))
    "filtering by an idle keeper in repo.keepers reports no matching changes"
    []
    (paths (Infra_store.set_filter "idle" inf_with_idle));
  Alcotest.(check (list (pair (option int) (option int))))
    "the preview is numbered from the recorded range"
    [ (Some 7, Some 7); (Some 8, None); (None, Some 8) ]
    (match Infra_store.selected_change inf1 with
     | Some fc ->
         List.map
           (fun (n : Masc_tui_ui.Diff.numbered) -> (n.old_line, n.new_line))
           (Infra_store.change_preview_rows fc)
     | None -> []);
  let inf2 = Infra_store.move_selection ~pane_index:0 ~delta:1 inf1 in
  Alcotest.(check (option string)) "the cursor is on docs" (Some "docs")
    (Option.map
       (fun (r : Wire_infra.repository) -> r.id)
       (Infra_store.selected_repository inf2));
  Alcotest.(check (list string))
    "moving to another repository hides the previous answer" []
    (paths inf2);
  Alcotest.(check bool) "the moved-to repository waits for its own answer" true
    (is_waiting inf2);
  let inf3 =
    Infra_store.request_repo_activity ~repo_id:"docs" inf2
    |> Infra_store.apply_repo_activity ~repo_id:"masc" ~observed_at:t1
         masc_answer
    |> Infra_store.fail_repo_activity ~repo_id:"masc"
         (Observed.fetch_failed ~reason:"HTTP 503" ~retryable:true ~at:t1)
  in
  Alcotest.(check (list string))
    "a late answer for the previous repository is dropped" [] (paths inf3);
  Alcotest.(check bool) "a failure for the previous repository is dropped"
    true (is_waiting inf3);
  let inf4 =
    Infra_store.apply_repo_activity ~repo_id:"docs" ~observed_at:t1 docs_answer
      inf3
  in
  Alcotest.(check (list string)) "the moved-to repository's answer is listed"
    [ "README.md" ] (paths inf4);
  (* Typing into the Repos filter can move the cursor too. *)
  let m0 = Model.initial () in
  let on_repos =
    { m0 with nav = { m0.nav with workspace = Nav.Infra }; infra = inf1 }
  in
  let activity_gets cmds =
    List.filter_map
      (function
        | Cmd.Http_get { req = Cmd.Get_repository_activity { repo_id }; _ } ->
            Some repo_id
        | _ -> None)
      cmds
  in
  let m_docs, cmds_docs = Update_nav.set_active_filter_query "docs" on_repos in
  Alcotest.(check (list string))
    "a filter that moves the cursor asks for that repository's activity"
    [ "docs" ] (activity_gets cmds_docs);
  Alcotest.(check bool) "the changes panel waits for docs" true
    (is_waiting m_docs.infra);
  let _, cmds_doc = Update_nav.set_active_filter_query "doc" m_docs in
  Alcotest.(check (list string))
    "a filter edit that keeps the cursor asks for nothing" []
    (activity_gets cmds_doc)

(* ---------- Keepers roster, Ctrl+T Context tab and keeper-costs reads ---------- *)

let sent_get req cmds =
  List.exists
    (function
      | Cmd.Http_get { req = sent; _ } -> sent = req
      | Cmd.Batch _
      | Cmd.Http_post _
      | Cmd.Http_put _
      | Cmd.Http_post_stream _
      | Cmd.Sync_streams _
      | Cmd.Update_workspace_guard _
      | Cmd.Voice_cmd _
      | Cmd.Copy_clipboard _
      | Cmd.Render_memory_diagram _
      | Cmd.Cancel_memory_diagram
      | Cmd.Fetch_artifact_and_copy _
      | Cmd.Export_artifact _
      | Cmd.Open_external_url _
      | Cmd.Open_editor_escape_hatch _
      | Cmd.Start_local_server
      | Cmd.Restart_tui
      | Cmd.Quit _ ->
          false)
    (Cmd.flatten cmds)

let keeper_costs_req = Cmd.Get_keeper_costs { window_minutes = 1440 }

let test_roster_keeps_unreadable_keepers_apart () =
  let m0 = Model.initial () in
  let roster : Wire_fleet.keepers_roster =
    {
      keepers = [ sample_keeper "alpha" ];
      unreadable = [ { name = "broken"; reason = "keeper.toml: unknown field" } ];
    }
  in
  let m1, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         { epoch = m0.epoch; reply = Msg.Reply_keepers_roster (Ok roster) })
  in
  Alcotest.(check (list string)) "readable rows become keepers" [ "alpha" ]
    (match Observed.to_option m1.fleet.keepers with
    | Some ks -> List.map (fun (k : Wire_fleet.keeper_summary) -> k.name) ks
    | None -> []);
  Alcotest.(check (list (pair string string)))
    "unreadable rows keep their name and reason"
    [ ("broken", "keeper.toml: unknown field") ]
    (List.map
       (fun (u : Wire_fleet.unreadable_keeper) -> (u.name, u.reason))
       m1.fleet.unreadable_keepers);
  let m2, _ =
    Update.step ~now:t1 m1
      (Msg.Http_reply
         {
           epoch = m1.epoch;
           reply = Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "alpha" ]));
         })
  in
  Alcotest.(check int) "the next roster replaces the unreadable rows" 0
    (List.length m2.fleet.unreadable_keepers)

let test_context_tab_reads_turn_records_and_costs () =
  let m0 = Model.initial () in
  let m1, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         {
           epoch = m0.epoch;
           reply = Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "alpha" ]));
         })
  in
  Alcotest.(check (option string)) "the drawer addresses the selected keeper"
    (Some "alpha") (Model.target_keeper m1);
  let turn_records = Cmd.Get_keeper_turn_records { keeper = "alpha"; limit = 60 } in
  Alcotest.(check string) "the request asks the server for 60 turns"
    "/api/v1/keepers/alpha/turn-records?limit=60"
    (Cmd.get_request_path turn_records);
  Alcotest.(check string) "a limit above the server's 500 is clamped"
    "/api/v1/keepers/alpha/turn-records?limit=500"
    (Cmd.get_request_path
       (Cmd.Get_keeper_turn_records { keeper = "alpha"; limit = 900 }));
  let m_queue, queue_cmds =
    Update_nav.open_overlay m1 (Nav.Queue_context Nav.Drawer_queue)
  in
  Alcotest.(check bool) "the Queue tab reads no turn records" false
    (sent_get turn_records queue_cmds);
  let m_ctx, ctx_cmds = Update_nav.cycle_sub_tab m_queue Keymap.Next in
  Alcotest.(check bool) "Tab moves to the Context tab" true
    (m_ctx.nav.overlay = Some (Nav.Queue_context Nav.Drawer_context));
  Alcotest.(check bool) "the Context tab reads alpha's turn records" true
    (sent_get turn_records ctx_cmds);
  Alcotest.(check bool) "the Context tab reads keeper-costs" true
    (sent_get keeper_costs_req ctx_cmds);
  Alcotest.(check bool) "the Context tab reads alpha's compaction facts" true
    (sent_get (Cmd.Get_keeper_memory_os_internals { keeper = "alpha" }) ctx_cmds);
  let _, opened_cmds =
    Update_nav.open_overlay m1 (Nav.Queue_context Nav.Drawer_context)
  in
  Alcotest.(check bool) "opening straight on the Context tab reads them too" true
    (sent_get turn_records opened_cmds);
  let records : Wire_fleet.keeper_turn_records =
    {
      keeper = "alpha";
      skipped_rows = 0;
      rows =
        [
          {
            absolute_turn = 3;
            input_tokens = Some 50_000;
            usage_scope = Wire_fleet.Usage_per_request;
            input_provenance = Some Wire_fleet.Input_measured_request;
            context_window = Some 200_000;
            provider_context_window = None;
          };
        ];
    }
  in
  let m_ok, _ =
    Update.step ~now:t1 m_ctx
      (Msg.Http_reply
         {
           epoch = m_ctx.epoch;
           reply =
             Msg.Reply_keeper_turn_records { keeper = "alpha"; result = Ok records };
         })
  in
  Alcotest.(check (option (list int))) "the reply fills alpha's slot" (Some [ 3 ])
    (Option.map
       (fun (r : Wire_fleet.keeper_turn_records) ->
         List.map (fun (row : Wire_fleet.turn_record_row) -> row.absolute_turn) r.rows)
       (Observed.to_option (Fleet_store.turn_records_for ~keeper:"alpha" m_ok.fleet)));
  Alcotest.(check bool) "a fresh slot is not read again" false
    (sent_get turn_records (View_fetches.fetches_for_current_view m_ok));
  (* Opened over alpha's chat, the drawer reads the turns alpha finishes:
     the roster the finished turn brings leaves the records stale. *)
  let in_chat =
    {
      m_ok with
      nav =
        {
          m_ok.nav with
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat } ];
        };
      fleet = Fleet_store.mark_keepers_stale m_ok.fleet;
    }
  in
  let _, roster_cmds =
    Update.step ~now:t1 in_chat
      (Msg.Http_reply
         {
           epoch = in_chat.epoch;
           reply =
             Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "alpha" ]));
         })
  in
  Alcotest.(check bool)
    "a roster reply under a chat dive reads the stale turn records" true
    (sent_get turn_records roster_cmds);
  let m_err, _ =
    Update.step ~now:t1 m_ctx
      (Msg.Http_reply
         {
           epoch = m_ctx.epoch;
           reply =
             Msg.Reply_keeper_turn_records
               {
                 keeper = "alpha";
                 result =
                   Error
                     (Msg.Http_error
                        { status = 500; body = "boom"; api_error = None });
               };
         })
  in
  Alcotest.(check bool) "a failed read lands on alpha's slot" true
    (match Fleet_store.turn_records_for ~keeper:"alpha" m_err.fleet with
    | Observed.Failed _ -> true
    | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Unreported ->
        false)

let test_keepers_view_reads_keeper_costs () =
  let m0 = Model.initial () in
  let m_k = { m0 with nav = { m0.nav with workspace = Nav.Keepers } } in
  Alcotest.(check bool) "the Keepers table reads cost and tokens from keeper-costs"
    true
    (sent_get keeper_costs_req (View_fetches.fetches_for_current_view m_k))

let test_context_display_keeps_estimates_and_reasons_apart () =
  Alcotest.(check bool) "a measured ratio is a fill" true
    (Fleet_store.context_display
       (Wire_fleet.Context_measured
          {
            ratio = Some 0.42;
            tokens = 84_000;
            window = Some 200_000;
            absolute_turn = None;
            measured_at_unix = None;
          })
    = Fleet_store.Context_fill { ratio = 0.42; estimated = false });
  Alcotest.(check bool) "the server's estimate is a fill marked as an estimate" true
    (Fleet_store.context_display
       (Wire_fleet.Context_not_measured
          { reason = Wire_fleet.Context_input_estimate; estimated_ratio = Some 0.3 })
    = Fleet_store.Context_fill { ratio = 0.3; estimated = true });
  Alcotest.(check bool) "tokens without a window stay tokens" true
    (Fleet_store.context_display
       (Wire_fleet.Context_measured
          {
            ratio = None;
            tokens = 84_000;
            window = None;
            absolute_turn = None;
            measured_at_unix = None;
          })
    = Fleet_store.Context_tokens_only 84_000);
  Alcotest.(check bool) "no measurement and no estimate keeps the reason" true
    (Fleet_store.context_display
       (Wire_fleet.Context_not_measured
          { reason = Wire_fleet.Context_cumulative_usage; estimated_ratio = None })
    = Fleet_store.Context_unavailable Wire_fleet.Context_cumulative_usage)

let test_candle_fallback_never_makes_a_zero_ledger () =
  let w0 = (Model.initial ()).work in
  let ledger summary =
    (Work_store.apply_candle_ledger_fallback ~observed_at:t0 ~summary
       ~balances:[ ("alpha", 5000) ] w0)
      .candle_ledger
  in
  Alcotest.(check (option string)) "a ready Candle yields its supply"
    (Some "7500")
    (Option.map
       (fun (l : Wire_work.candle_ledger) -> l.circulating_milli)
       (Observed.to_option
          (ledger
             (Some
                (Wire_fleet.Candle_ready
                   {
                     issued_milli = "10000";
                     burned_milli = "2500";
                     circulating_milli = "7500";
                   })))));
  Alcotest.(check bool) "an off Candle has no ledger" true
    (match ledger (Some Wire_fleet.Candle_off) with
    | Observed.Absent -> true
    | Observed.Value _ | Observed.Loading _ | Observed.Unreported | Observed.Failed _ ->
        false);
  Alcotest.(check bool) "a disabled Candle is a failed read with its reason" true
    (match ledger (Some (Wire_fleet.Candle_disabled { reason = "candle.toml unreadable" })) with
    | Observed.Failed { reason; retryable = false; _ } ->
        String.equal reason "Candle disabled: candle.toml unreadable"
    | Observed.Failed { retryable = true; _ }
    | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Unreported ->
        false);
  Alcotest.(check bool) "no summary yet is unreported" true
    (match ledger None with
    | Observed.Unreported -> true
    | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Failed _ ->
        false);
  (* A token that gets no Candle summary stays Unreported after the 404, and
     the Candle tab does not ask the route that answered 404 again. *)
  let m0 = Model.initial () in
  let on_candle =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Work };
      work = Work_store.set_tab Nav.Work_candle_scorecard m0.work;
    }
  in
  let ledger_gets cmds =
    List.length
      (List.filter
         (function
           | Cmd.Http_get { req = Cmd.Get_candle_ledger _; _ } -> true
           | _ -> false)
         cmds)
  in
  Alcotest.(check int) "the Candle tab asks for the ledger" 1
    (ledger_gets (View_fetches.fetches_for_current_view on_candle));
  let after_404, _ =
    Update.step ~now:t1 on_candle
      (Msg.Http_reply
         {
           epoch = on_candle.epoch;
           reply =
             Msg.Reply_candle_ledger
               (Error
                  (Msg.Http_error
                     { status = 404; body = "not found"; api_error = None }));
         })
  in
  Alcotest.(check int) "a ledger route that answered 404 is not asked again" 0
    (ledger_gets (View_fetches.fetches_for_current_view after_404));
  Alcotest.(check int) "an explicit refresh asks it again" 1
    (ledger_gets (View_fetches.fetches_for_current_view ~force:true after_404))

(* "대화는 자꾸 끊기고": a plain Enter on a busy Keeper used to steer, and the
   steer named the turn row's interrupt token, so it cut whichever turn held
   the Keeper, another Keeper's delegated reply included. Enter now queues,
   and the steer chord cuts only a request this TUI is streaming. *)
let test_busy_enter_queues_and_steer_cuts_only_own_request () =
  let keeper = "alpha" in
  let turn_row ~interrupt_token : Wire_fleet.keeper_turn_row =
    {
      keeper_name = keeper;
      chat_control_token = Some "ctrl-1";
      state =
        Wire_fleet.Turn_active
          {
            lane = Wire_fleet.Lane_chat;
            started_at_unix = 100.0;
            interrupt_token;
            phase = Some "thinking";
            tool_in_flight = None;
            elapsed_ms = Some 500.0;
          };
    }
  in
  let with_turn ~interrupt_token (m : Model.t) =
    {
      m with
      fleet =
        Fleet_store.apply_turns ~observed_at:t0
          [ turn_row ~interrupt_token ]
          m.fleet;
    }
  in
  let m0 = Model.initial ~cols:120 ~rows:36 () in
  let m0 =
    {
      m0 with
      fleet =
        Fleet_store.apply_keepers ~observed_at:t0 [ sample_keeper keeper ]
          m0.fleet;
      drafts = Drafts.set_active_keeper keeper m0.drafts;
      nav =
        {
          m0.nav with
          workspace = Nav.Keepers;
          dive_stack = [ Nav.Dive_keeper { name = keeper; tab = Nav.Keeper_chat } ];
        };
    }
  in
  let press ?alt text (m : Model.t) =
    let typed =
      {
        m with
        drafts = m.drafts |> Drafts.set_focus true |> Drafts.insert_text text;
      }
    in
    Update.step ~now:t0 typed (Msg.Key_event (key ?alt Keymap.Input.Enter))
  in
  let one_request label cmds : Wire_fleet.chat_submit_request =
    match
      List.filter_map
        (function
          | Cmd.Http_post_stream
              { req = Cmd.Stream_keeper_chat { request; is_btw = false }; _ } ->
              Some request
          | _ -> None)
        (Cmd.flatten cmds)
    with
    | [ request ] -> request
    | requests ->
        Alcotest.failf "%s: expected one chat submit, got %d" label
          (List.length requests)
  in
  let queued (request : Wire_fleet.chat_submit_request) =
    match request.mode with
    | Wire_fleet.Follow_up -> true
    | Wire_fleet.Steer _ -> false
  in
  let warned (m : Model.t) =
    match m.toast with
    | Some { level = Model.Toast_warning; _ } -> true
    | Some
        { level = Model.Toast_info | Model.Toast_success | Model.Toast_error; _ }
    | None ->
        false
  in
  let tx_mode request_id (m : Model.t) =
    match
      List.find_opt
        (fun (tx : Drafts.pending_message) ->
          String.equal tx.request_id request_id)
        m.drafts.pending_txs
    with
    | Some tx -> tx.mode
    | None -> Alcotest.failf "no pending tx %s" request_id
  in
  let feed (m : Model.t) ~request_id chunk =
    Update.step ~now:t0 m
      (Msg.Chat_stream_chunk
         { epoch = m.epoch; keeper; request_id; is_btw = false; chunk })
  in
  (* Idle: Enter sends request A, and A streams a partial reply. *)
  let m1, cmds1 = press "first" m0 in
  let a = one_request "idle Enter" cmds1 in
  Alcotest.(check bool) "idle Enter sends with no interrupt" true (queued a);
  let m2, _ =
    feed m1 ~request_id:a.request_id
      (Wire_fleet.Chunk_text_delta
         {
           operation_id = Some a.request_id;
           delta = "partial reply";
           owner = Wire_chat_journal.Unobserved_scope None;
         })
  in
  let m2 = with_turn ~interrupt_token:"turn-of-a" m2 in
  (* Busy with A: Enter queues B behind A and keeps A streaming. *)
  let m3, cmds3 = press "second" m2 in
  let b = one_request "busy Enter" cmds3 in
  Alcotest.(check bool) "busy Enter sends no admission intent" true (queued b);
  Alcotest.(check bool) "busy Enter records a follow-up" true
    (Drafts.equal_delivery_mode (tx_mode b.request_id m3) Drafts.Mode_follow_up);
  Alcotest.(check (option string)) "busy Enter keeps A's live buffer"
    (Some a.request_id)
    (Option.map
       (fun (s : Fleet_store.chat_stream_buffer) -> s.request_id)
       (Fleet_store.String_map.find_opt keeper m3.fleet.chat_streams));
  Alcotest.(check bool) "busy Enter raises no warning" false (warned m3);
  (* The steer chord cuts A, the request this TUI is streaming. *)
  let m4, cmds4 = press ~alt:true "third" m3 in
  (match (one_request "own steer" cmds4).mode with
  | Wire_fleet.Steer { control_token; operation_id } ->
      Alcotest.(check string) "steer carries the Keeper's control token"
        "ctrl-1" control_token;
      Alcotest.(check string) "steer names A, this TUI's own request"
        a.request_id operation_id
  | Wire_fleet.Follow_up ->
      Alcotest.fail "the steer chord must cut this TUI's own streaming request");
  Alcotest.(check bool) "own steer raises no fallback warning" false (warned m4);
  (* Another sender's turn holds the Keeper; this TUI streams nothing. *)
  let foreign = with_turn ~interrupt_token:"delegated-turn" m0 in
  let f1, cmds_f1 = press ~alt:true "steer attempt" foreign in
  Alcotest.(check bool) "steer on a foreign turn queues instead" true
    (queued (one_request "foreign steer" cmds_f1));
  Alcotest.(check bool) "the queue fallback raises a warning toast" true
    (warned f1);
  let f2, cmds_f2 = press "plain send" foreign in
  Alcotest.(check bool) "Enter on a foreign turn queues" true
    (queued (one_request "foreign Enter" cmds_f2));
  Alcotest.(check bool) "a queued Enter raises no warning" false (warned f2);
  (* A finished and the turn row already shows the next turn, which is not
     A. The steer must not reach that turn through its token. *)
  let done_m, _ =
    feed m2 ~request_id:a.request_id
      (Wire_fleet.Chunk_turn_done
         {
           operation_id = Some a.request_id;
           turn_ref = None;
           reply = Some "partial reply";
         })
  in
  let after = with_turn ~interrupt_token:"next-turn" done_m in
  let g1, cmds_g1 = press ~alt:true "late steer" after in
  Alcotest.(check bool) "a steer after A finished queues" true
    (queued (one_request "late steer" cmds_g1));
  Alcotest.(check bool) "the late steer fallback warns" true (warned g1)

let test_feature_wave1_store_and_polish_nits () =
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let has_cmd pred cmds = List.exists pred (Cmd.flatten cmds) in

  (* === Feature 1: Artifacts auto-detail fetch, stale guard, [y]/[H]/[e]/[o] === *)
  let art_a : Wire_knowledge.artifact_entry =
    {
      id = "art-alpha";
      revision = 2;
      title = "Alpha Brief";
      summary = "Alpha HTML";
      author = "alpha";
      created_at_unix = 1795254000.0;
      body = { sha256 = "sha-alpha-111"; bytes = 128; mime = "text/html" };
    }
  in
  let art_b : Wire_knowledge.artifact_entry =
    {
      art_a with
      id = "art-beta";
      title = "Beta Note";
      body = { sha256 = "sha-beta-222"; bytes = 128; mime = "text/markdown" };
    }
  in
  let m_art =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Knowledge };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.set_tab Nav.Knowledge_artifacts
        |> Knowledge_store.apply_artifacts ~observed_at:t0 [ art_a; art_b ];
    }
  in
  let m_art2, cmds_move =
    Update.step ~now:t1 m_art (Msg.Key_event (char_key "j"))
  in
  Alcotest.(check bool) "moving artifact selection fetches Get_artifact_detail(art-beta)"
    true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_artifact_detail { id = "art-beta"; _ }; _ } ->
             true
         | _ -> false)
       cmds_move);
  (* Stale detail for art-alpha must be ignored while art-beta is selected *)
  let stale_detail : Wire_knowledge.published_artifact_detail =
    {
      artifact = art_a;
      content = "<h1>STALE ALPHA</h1>";
      revisions = [];
      shared = false;
      share_version = 0;
    }
  in
  let m_art_after_stale, _ =
    Update.step ~now:t1 m_art2
      (Msg.Http_reply
         {
           epoch = m_art2.epoch;
           reply = Msg.Reply_artifact_detail { id = "art-alpha"; result = Ok stale_detail };
         })
  in
  Alcotest.(check bool) "stale Reply_artifact_detail ignored" true
    (Option.is_none (Observed.to_option m_art_after_stale.knowledge.active_artifact_detail));
  let _, cmds_e =
    Update.step ~now:t1 m_art (Msg.Key_event (char_key "e"))
  in
  Alcotest.(check bool) "Artifacts [e] emits Export_artifact(open_after=false, .html)"
    true
    (has_cmd
       (function
         | Cmd.Export_artifact { id = "art-alpha"; ext = ".html"; open_after = false; _ } ->
             true
         | _ -> false)
       cmds_e);
  let _, cmds_o =
    Update.step ~now:t1 m_art (Msg.Key_event (char_key "o"))
  in
  Alcotest.(check bool) "Artifacts [o] emits Export_artifact(open_after=true, .html)"
    true
    (has_cmd
       (function
         | Cmd.Export_artifact { id = "art-alpha"; ext = ".html"; open_after = true; _ } ->
             true
         | _ -> false)
       cmds_o);
  let _, cmds_h =
    Update.step ~now:t1 m_art (Msg.Key_event (char_key "H"))
  in
  Alcotest.(check bool) "Artifacts [H] copies SHA-256" true
    (has_cmd
       (function Cmd.Copy_clipboard "sha-alpha-111" -> true | _ -> false)
       cmds_h);

  (* === Feature 2: Runtime_addons_browser, stale tab guard, Space/t/y/o, SSE invalidation === *)
  let client_1 : Wire_runtime.browser_client_row =
    {
      client_id = "ego-1";
      browser = "Ego Browser";
      version = "131.0";
      engine_version = "131.0";
      transport = "ego";
      space = Some { space_id = 1; space_name = "research" };
      ownership = Some "agent";
      presence_state = Some "live";
      presence_reason = None;
      interactions = [];
      last_activities = [];
    }
  in
  let tab_1 : Wire_runtime.browser_tab_row =
    {
      id = 7;
      title = "Docs";
      url = "https://example.com/docs";
      active = true;
      window_id = Some 1;
      opened_by = Some Wire_runtime.Tab_origin_agent;
      label = None;
      dialog_present = false;
      dialog_kind = None;
    }
  in
  let m_ab =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Runtime; pane_index = 1 };
      runtime =
        Runtime_store.empty
        |> Runtime_store.set_tab Nav.Runtime_addons_browser
        |> Runtime_store.apply_browser_lane ~observed_at:t0
             {
               ok = true;
               available = true;
               inventory_complete = true;
               client_count = 1;
               issue_count = 0;
               automatic_browse_ok = true;
               detail = None;
               clients = [ client_1 ];
               issues = [];
             };
    }
  in
  Alcotest.(check int) "Runtime_addons_browser has 2 focusable panes" 2
    (Model.focusable_pane_count m_ab);
  let _, cmds_t = Update.step ~now:t1 m_ab (Msg.Key_event (char_key "t")) in
  Alcotest.(check bool) "[t] emits Post_browser_tabs for selected client" true
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_browser_tabs { client_id = "ego-1" }; _ } ->
             true
         | _ -> false)
       cmds_t);
  (* Stale Reply_browser_tabs for wrong client_id must be ignored *)
  let m_ab_stale, _ =
    Update.step ~now:t1 m_ab
      (Msg.Http_reply
         {
           epoch = m_ab.epoch;
           reply =
             Msg.Reply_browser_tabs
               {
                 client_id = "other-client";
                 result =
                   Ok
                     {
                       client_id = Some "other-client";
                       tabs = [ tab_1 ];
                       complete = true;
                       unavailable_count = 0;
                       error = None;
                     };
               };
         })
  in
  Alcotest.(check bool) "stale Reply_browser_tabs ignored" true
    (Option.is_none
       (Observed.to_option
          (Runtime_store.browser_tabs_for ~client_id:"ego-other"
             m_ab_stale.runtime)));
  let m_ab_tabs, _ =
    Update.step ~now:t1 m_ab
      (Msg.Http_reply
         {
           epoch = m_ab.epoch;
           reply =
             Msg.Reply_browser_tabs
               {
                 client_id = "ego-1";
                 result =
                   Ok
                     {
                       client_id = Some "ego-1";
                       tabs = [ tab_1 ];
                       complete = true;
                       unavailable_count = 0;
                       error = None;
                     };
               };
         })
  in
  (* Space switches browser_right_focus Clients -> Tabs; y copies URL; o opens URL *)
  let m_ab_tab_focus, _ =
    Update.step ~now:t1 m_ab_tabs (Msg.Key_event (char_key " "))
  in
  Alcotest.(check bool) "[Space] toggles right focus to `Tabs" true
    (m_ab_tab_focus.runtime.browser_right_focus = `Tabs);
  let _, cmds_tab_y =
    Update.step ~now:t1 m_ab_tab_focus (Msg.Key_event (char_key "y"))
  in
  Alcotest.(check bool) "[y] on tab copies tab URL" true
    (has_cmd
       (function Cmd.Copy_clipboard "https://example.com/docs" -> true | _ -> false)
       cmds_tab_y);
  let _, cmds_tab_o =
    Update.step ~now:t1 m_ab_tab_focus (Msg.Key_event (char_key "o"))
  in
  Alcotest.(check bool) "[o] on tab emits Open_external_url" true
    (has_cmd
       (function Cmd.Open_external_url "https://example.com/docs" -> true | _ -> false)
       cmds_tab_o);
  (* SSE Dataset_lane_addons triggers Get_lane_addons refetch when viewing Runtime *)
  let _, cmds_sse_addon =
    Update.step ~now:t1 m_ab
      (Msg.Sse_event
         {
           epoch = m_ab.epoch;
           event =
             Msg.Sse_observer_delivery
               {
                 cursor = Some 10;
                 decoded =
                   Wire_observer.Event
                     (Wire_observer.Dataset_changed Wire_observer.Dataset_lane_addons);
               };
         })
  in
  Alcotest.(check bool) "SSE Dataset_lane_addons refetches Get_lane_addons on Runtime"
    true
    (has_cmd
       (function Cmd.Http_get { req = Cmd.Get_lane_addons; _ } -> true | _ -> false)
       cmds_sse_addon);

  (* === Feature 3: [g] toggles Memory Flow mode on Knowledge > Memory & Keeper_memory === *)
  let m_mem =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Knowledge };
      knowledge = Knowledge_store.set_tab Nav.Knowledge_memory Knowledge_store.empty;
    }
  in
  let mode0 = m_mem.knowledge.memory_flow_mode in
  let m_mem_g, _ = Update.step ~now:t1 m_mem (Msg.Key_event (char_key "g")) in
  Alcotest.(check bool) "[g] toggles memory_flow_mode Flow_io -> Net_total" true
    (m_mem_g.knowledge.memory_flow_mode <> mode0);
  let m_mem_g2, _ = Update.step ~now:t1 m_mem_g (Msg.Key_event (char_key "g")) in
  Alcotest.(check bool) "[g] twice toggles back to Flow_io" true
    (m_mem_g2.knowledge.memory_flow_mode = mode0);

  (* === Feature 4: Honest Per-View SSOT mode + Unified Infra timeline [s] === *)
  let live_fr =
    {
      m0.freshness with
      observer = Health.Live { last_event_ns = t0; revision = 1 };
      fleet = Health.Live { last_event_ns = t0; revision = 1 };
      view_stream = Some (Health.Live { last_event_ns = t0; revision = 1 });
    }
  in
  let m_live = { m0 with freshness = live_fr } in
  (match Model.active_view_ssot_mode m_live with
  | Model.Live_sse _ -> ()
  | Model.Synced_snapshot _ | Model.Snapshot_only _ ->
      Alcotest.fail "Pulse should be Live_sse");
  let m_work = { m_live with nav = { m_live.nav with workspace = Nav.Work } } in
  (match Model.active_view_ssot_mode m_work with
  | Model.Synced_snapshot _ -> ()
  | Model.Live_sse _ | Model.Snapshot_only _ ->
      Alcotest.fail "Work should be Synced_snapshot");
  let m_repos =
    {
      m_live with
      nav = { m_live.nav with workspace = Nav.Infra };
      infra = Infra_store.set_tab Nav.Infra_repos_changes m_live.infra;
    }
  in
  (match Model.active_view_ssot_mode m_repos with
  | Model.Snapshot_only _ -> ()
  | Model.Live_sse _ | Model.Synced_snapshot _ ->
      Alcotest.fail "Infra > Repos & Changes should be Snapshot_only");
  let log_row : Wire_infra.system_log_entry =
    {
      seq = 1;
      ts = "2026-11-23T01:00:00Z";
      level = Wire_infra.Log_info;
      source = "server";
      module_name = "server";
      message = "server boot log";
      keeper = Some "alpha";
      turn_id = None;
      category = None;
      details = `Assoc [];
    }
  in
  let m_logs =
    {
      m_live with
      nav = { m_live.nav with workspace = Nav.Infra };
      infra =
        Infra_store.empty
        |> Infra_store.set_tab Nav.Infra_activity_logs
        |> Infra_store.apply_log_snapshot [ log_row ]
        |> Infra_store.push_activity
             {
               Infra_store.at_unix = 1795400000.0;
               kind = Infra_store.Activity_tool_call;
               keeper = Some "beta";
               summary = "tool_done";
               detail = Some "ran cargo test";
             };
    }
  in
  Alcotest.(check int) "Source_all merges 1 log + 1 event = 2" 2
    (List.length (Infra_store.visible_timeline m_logs.infra));
  let _, cmds_evt_y = Update.step ~now:t1 m_logs (Msg.Key_event (char_key "y")) in
  Alcotest.(check bool) "[y] on newest Entry_event copies event detail" true
    (has_cmd
       (function
         | Cmd.Copy_clipboard s ->
             Store_scroll.contains_ci ~needle:"ran cargo test" s
         | _ -> false)
       cmds_evt_y);
  let m_logs_s1, _ = Update.step ~now:t1 m_logs (Msg.Key_event (char_key "s")) in
  Alcotest.(check bool) "[s] 1st press -> Source_logs" true
    (m_logs_s1.infra.source_filter = Infra_store.Source_logs);
  Alcotest.(check int) "Source_logs has 1 item" 1
    (List.length (Infra_store.visible_timeline m_logs_s1.infra));
  let m_logs_s2, _ = Update.step ~now:t1 m_logs_s1 (Msg.Key_event (char_key "s")) in
  Alcotest.(check bool) "[s] 2nd press -> Source_events" true
    (m_logs_s2.infra.source_filter = Infra_store.Source_events);
  Alcotest.(check int) "Source_events has 1 item" 1
    (List.length (Infra_store.visible_timeline m_logs_s2.infra));

  (* === 4 Polish Nits (#373/#374) === *)
  (* Nit 2: Left_press in apply_mouse does NOT cancel editing_field_key; Wheel DOES *)
  let edit_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha-edit";
      sections =
        [
          {
            id = "tui";
            category = Wire_config.Cat_general_ui;
            title = "TUI";
            fields =
              [
                {
                  table = "tui";
                  key = "theme";
                  full_key = "tui.theme";
                  label = "Theme";
                  env = None;
                  description = None;
                  kind = Wire_config.Field_string;
                  value = Wire_config.Val_string "midnight";
                  default_value = None;
                  provenance = Wire_config.Prov_project;
                  reload_scope = Wire_config.Hot_reload;
                  secret = false;
                  writable = true;
                };
              ];
          };
        ];
    }
  in
  let m_edit =
    let cfg =
      match
        Config_store.empty
        |> Config_store.set_tab Nav.Settings_general_ui
        |> Config_store.apply_schema ~observed_at:t0 edit_schema
        |> Config_store.begin_edit_selected
      with
      | Ok c -> c
      | Error msg -> Alcotest.fail ("begin_edit_selected failed: " ^ msg)
    in
    {
      m0 with
      config = cfg;
      nav = { m0.nav with overlay = Some (Nav.Settings Nav.Settings_general_ui) };
    }
  in
  Alcotest.(check bool) "editing started" true
    (Config_store.is_editing_field m_edit.config);
  let m_after_click, _ =
    Update.step ~now:t1 m_edit
      (Msg.Mouse_event (Keymap.Input.Left_press { col = 10; row = 5 }))
  in
  Alcotest.(check bool) "Nit 2: Left_press preserves editing_field_key" true
    (Config_store.is_editing_field m_after_click.config);
  let m_after_wheel, _ =
    Update.step ~now:t1 m_after_click
      (Msg.Mouse_event
         (Keymap.Input.Wheel { col = 10; row = 5; dir = Keymap.Input.Wheel_down }))
  in
  Alcotest.(check bool) "Nit 2: Wheel_down cancels editing_field_key" false
    (Config_store.is_editing_field m_after_wheel.config);
  (* Nit 4: Incidents [J] scrolls bracket-prefixed embedded JSON via Json_tree line count *)
  let big_json =
    "[HTTP 500] {"
    ^ String.concat ","
        (List.init 30 (fun i -> Printf.sprintf "\"k%02d\":\"val-%02d\"" i i))
    ^ "}"
  in
  let incidents_with_json, _ =
    Incidents.push ~occurred_at_unix:1795254000.0
      ~source:Health.Source_client_http ~summary:(Say.literal "HTTP fail")
      ~detail:big_json ~status:Health.Resolved Incidents.empty
  in
  let m_inc =
    {
      m0 with
      nav = { m0.nav with overlay = Some Nav.Incidents };
      incidents = incidents_with_json;
    }
  in
  let m_inc_j, _ = Update.step ~now:t1 m_inc (Msg.Key_event (char_key "J")) in
  Alcotest.(check bool) "Nit 4: Incidents [J] scrolls bracket-prefixed embedded JSON"
    true (m_inc_j.incidents.detail_scroll_offset > 0);

  (* === Review #389 Regressions (Items 6, 9, 13) === *)
  (* Item 9: view_stream cleared on tab change, stale freshness ignored, Dive_keeper SSOT *)
  let m_eff_live =
    {
      m_live with
      nav = { m_live.nav with workspace = Nav.Runtime };
      runtime = Runtime_store.set_tab Nav.Runtime_efficiency_spend m_live.runtime;
      freshness =
        {
          m_live.freshness with
          view_stream = Some (Health.Live { last_event_ns = t0; revision = 1 });
        };
    }
  in
  (match Model.active_view_ssot_mode m_eff_live with
  | Model.Live_sse { live_count = 3; planned_count = 3; _ } -> ()
  | _ -> Alcotest.fail "expected Live_sse 3/3 on Runtime_efficiency_spend");
  let m_failover, _ =
    Update.step ~now:t1 m_eff_live (Msg.Key_event (char_key "]"))
  in
  Alcotest.(check bool) "Item 9: switching away from view-stream tab clears view_stream"
    true (Option.is_none m_failover.freshness.view_stream);
  let m_after_stale_sse, _ =
    Update.step ~now:t1 m_failover
      (Msg.Sse_freshness
         {
           epoch = m_failover.epoch;
           stream = Subscriptions.Stream_model_metrics;
           freshness =
             Health.Disconnected { since_ns = t1; reason = Health.Stream_eof };
         })
  in
  Alcotest.(check bool) "Item 9: stale view_stream Disconnected ignored after tab switch"
    true (Option.is_none m_after_stale_sse.freshness.view_stream);
  let m_dive_mem =
    {
      m_eff_live with
      nav =
        {
          m_eff_live.nav with
          dive_stack = [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory } ];
        };
    }
  in
  Alcotest.(check int) "Item 9: Dive_keeper drops view-scoped stream from Subscriptions.plan"
    2 (List.length (Subscriptions.plan m_dive_mem));
  (match Model.active_view_ssot_mode m_dive_mem with
  | Model.Synced_snapshot _ -> ()
  | _ -> Alcotest.fail "Item 9: Dive_keeper Keeper_memory must report Synced_snapshot");
  let m_dive_chat =
    {
      m_eff_live with
      nav =
        {
          m_eff_live.nav with
          dive_stack = [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat } ];
        };
    }
  in
  (match Model.active_view_ssot_mode m_dive_chat with
  | Model.Live_sse { stream_name = "fleet/stream"; live_count = 2; planned_count = 2; _ } -> ()
  | _ -> Alcotest.fail "Item 9: Dive_keeper Keeper_chat must report Live_sse 2/2 (not inherited 3/3)");

  (* Item 13: Runtime_addons_browser pane 1 [y] respects browser_right_focus *)
  let bl_snap : Wire_runtime.browser_lane_status =
    {
      ok = true;
      available = true;
      inventory_complete = true;
      client_count = 1;
      issue_count = 0;
      automatic_browse_ok = true;
      detail = None;
      clients =
        [
          {
            client_id = "ego-client-focus-1";
            browser = "Ego";
            version = "131";
            engine_version = "131";
            transport = "ego";
            space = None;
            ownership = Some "agent";
            presence_state = Some "present";
            presence_reason = None;
            interactions = [];
            last_activities = [];
          };
        ];
      issues = [];
    }
  in
  let tabs_snap : Wire_runtime.browser_tabs_response =
    {
      client_id = Some "ego-client-focus-1";
      tabs =
        [
          {
            id = 7;
            title = "Focus Tab";
            url = "https://example.com/focus-tab";
            active = true;
            window_id = Some 1;
            opened_by = Some Wire_runtime.Tab_origin_agent;
            label = None;
            dialog_present = false;
            dialog_kind = None;
          };
        ];
      complete = true;
      unavailable_count = 0;
      error = None;
    }
  in
  let m_ab_p1 =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Runtime; pane_index = 1 };
      runtime =
        Runtime_store.empty
        |> Runtime_store.set_tab Nav.Runtime_addons_browser
        |> Runtime_store.apply_browser_lane ~observed_at:t0 bl_snap
        |> Runtime_store.apply_browser_tabs ~observed_at:t0
             ~client_id:"ego-client-focus-1" tabs_snap;
    }
  in
  let _, cmds_cl_y = Update.step ~now:t1 m_ab_p1 (Msg.Key_event (char_key "y")) in
  Alcotest.(check bool) "Item 13: Clients focus [y] copies client_id" true
    (has_cmd
       (function Cmd.Copy_clipboard s -> String.equal s "ego-client-focus-1" | _ -> false)
       cmds_cl_y);
  let m_ab_tabs, _ = Update.step ~now:t1 m_ab_p1 (Msg.Key_event (char_key " ")) in
  let _, cmds_tb_y = Update.step ~now:t1 m_ab_tabs (Msg.Key_event (char_key "y")) in
  Alcotest.(check bool) "Item 13: Tabs focus [y] copies tab URL" true
    (has_cmd
       (function Cmd.Copy_clipboard s -> String.equal s "https://example.com/focus-tab" | _ -> false)
       cmds_tb_y);

  (* Item 6: Reply_artifact_detail Error on SHA-targeted Artifact_dive marks detail failed *)
  let sha_art : Wire_knowledge.artifact_entry =
    {
      id = "artifact-aabbccdd11223344";
      revision = 1;
      title = "SHA Doc";
      summary = "";
      author = "alpha";
      created_at_unix = 1795254000.0;
      body = { sha256 = "sha-target-999"; bytes = 128; mime = "text/html" };
    }
  in
  let m_sha_dive =
    {
      m0 with
      nav =
        {
          m0.nav with
          workspace = Nav.Knowledge;
          dive_stack = [ Nav.Dive_knowledge (Nav.Artifact_dive "sha-target-999") ];
        };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.apply_artifacts ~observed_at:t0 [ sha_art ];
    }
  in
  let m_sha_err, _ =
    Update.step ~now:t1 m_sha_dive
      (Msg.Http_reply
         {
           epoch = m_sha_dive.epoch;
           reply =
             Msg.Reply_artifact_detail
               {
                 id = "artifact-aabbccdd11223344";
                 result =
                   Error (Msg.Http_error { status = 404; body = "gone"; api_error = None });
               };
         })
  in
  (match m_sha_err.knowledge.active_artifact_detail with
  | Observed.Failed _ -> ()
  | _ -> Alcotest.fail "Item 6: expected active_artifact_detail = Observed.Failed on SHA-targeted dive")

let test_pr54465_p2_fixes () =
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_en () in
  let t0 = Clock.Mono.of_ns 1_000_000_000L in
  let t1 = Clock.Mono.of_ns 2_000_000_000L in
  let has_cmd pred cmds = List.exists pred (Cmd.flatten cmds) in

  (* P2-1: Browser tabs keyed per client_id — client A failure never leaks to client B *)
  let mk_client cid : Wire_runtime.browser_client_row =
    {
      client_id = cid;
      browser = "Ego Browser";
      version = "131.0";
      engine_version = "131.0";
      transport = "ego";
      space = Some { space_id = 1; space_name = cid };
      ownership = Some "agent";
      presence_state = Some "present";
      presence_reason = None;
      interactions = [];
      last_activities = [];
    }
  in
  let bl : Wire_runtime.browser_lane_status =
    {
      ok = true;
      available = true;
      inventory_complete = true;
      client_count = 2;
      issue_count = 0;
      automatic_browse_ok = true;
      detail = None;
      clients = [ mk_client "ego-a"; mk_client "ego-b" ];
      issues = [];
    }
  in
  let m_bl =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Runtime; pane_index = 1 };
      runtime =
        Runtime_store.empty
        |> Runtime_store.set_tab Nav.Runtime_addons_browser
        |> Runtime_store.apply_browser_lane ~observed_at:t0 bl;
    }
  in
  let m_bl_err, _ =
    Update.step ~now:t1 m_bl
      (Msg.Http_reply
         {
           epoch = m_bl.epoch;
           reply =
             Msg.Reply_browser_tabs
               {
                 client_id = "ego-a";
                 result =
                   Error
                     (Msg.Http_error
                        { status = 500; body = "ego-a boom"; api_error = None });
               };
         })
  in
  (match Runtime_store.browser_tabs_for ~client_id:"ego-a" m_bl_err.runtime with
  | Observed.Failed _ -> ()
  | _ -> Alcotest.fail "P2-1: expected ego-a browser_tabs slot to be Failed");
  (match Runtime_store.browser_tabs_for ~client_id:"ego-b" m_bl_err.runtime with
  | Observed.Absent -> ()
  | _ -> Alcotest.fail "P2-1: expected ego-b browser_tabs slot to stay Absent");

  (* P2-2: Artifact_dive unmatched target must NOT fall back to selected_artifact *)
  let art_a : Wire_knowledge.artifact_entry =
    {
      id = "art-existing";
      revision = 1;
      title = "Existing Artifact";
      summary = "Real";
      author = "alpha";
      created_at_unix = 1795254000.0;
      body = { sha256 = "sha-existing"; bytes = 64; mime = "text/html" };
    }
  in
  let m_missing_dive =
    {
      m0 with
      nav =
        {
          m0.nav with
          workspace = Nav.Knowledge;
          dive_stack =
            [ Nav.Dive_knowledge (Nav.Artifact_dive "art-nonexistent") ];
        };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.apply_artifacts ~observed_at:t0 [ art_a ];
    }
  in
  List.iter
    (fun key ->
      let m_after, cmds =
        Update.step ~now:t1 m_missing_dive (Msg.Key_event (char_key key))
      in
      Alcotest.(check int)
        (Printf.sprintf "P2-2: Artifact_dive [%s] emits 0 cmds on unmatched target"
           key)
        0 (List.length (Cmd.flatten cmds));
      Alcotest.(check bool)
        (Printf.sprintf "P2-2: Artifact_dive [%s] shows warning toast" key)
        true (Option.is_some m_after.toast))
    [ "y"; "o"; "e"; "H" ];

  (* P2-3 & P3-1: Artifact detail failure is target-scoped and non-retryable skips refire *)
  let art_b : Wire_knowledge.artifact_entry =
    {
      art_a with
      id = "art-other";
      title = "Other Artifact";
      body = { sha256 = "sha-other"; bytes = 32; mime = "text/markdown" };
    }
  in
  let k_fail =
    Knowledge_store.empty
    |> Knowledge_store.set_tab Nav.Knowledge_artifacts
    |> Knowledge_store.apply_artifacts ~observed_at:t0 [ art_a; art_b ]
    |> Knowledge_store.mark_artifact_detail_failed ~target:"art-existing" ~at:t1
         ~reason:"HTTP 404: not found" ~retryable:false
  in
  Alcotest.(check bool) "P2-3: failure surfaces for matching artifact" true
    (Option.is_some (Knowledge_store.artifact_detail_failure_for_entry art_a k_fail));
  Alcotest.(check bool) "P2-3: failure does not bleed to other artifact" false
    (Option.is_some (Knowledge_store.artifact_detail_failure_for_entry art_b k_fail));
  let m_fail = { m0 with nav = { m0.nav with workspace = Nav.Knowledge }; knowledge = k_fail } in
  let reqs_no_force = View_fetches.fetches_for_current_view ~force:false m_fail in
  Alcotest.(check bool) "P3-1: non-retryable artifact detail failure does not refire"
    false
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_artifact_detail { id = "art-existing"; _ }; _ } ->
             true
         | _ -> false)
       reqs_no_force);
  let reqs_force = View_fetches.fetches_for_current_view ~force:true m_fail in
  Alcotest.(check bool) "P3-1: force refresh DOES refire failed artifact detail"
    true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_artifact_detail { id = "art-existing"; _ }; _ } ->
             true
         | _ -> false)
       reqs_force);

  (* P2-4: Reply_lane_addons 5xx marks lane_addons slot as Observed.Failed(retryable=true) *)
  let m_addons_err, _ =
    Update.step ~now:t1 m_bl
      (Msg.Http_reply
         {
           epoch = m_bl.epoch;
           reply =
             Msg.Reply_lane_addons
               (Error
                  (Msg.Http_error
                     { status = 502; body = "bad gateway"; api_error = None }));
         })
  in
  (match m_addons_err.runtime.lane_addons with
  | Observed.Failed { retryable = true; _ } -> ()
  | _ ->
      Alcotest.fail
        "P2-4: expected Reply_lane_addons 502 to mark lane_addons Failed(retryable=true)");
  Alcotest.(check bool) "P2-4: Reply_lane_addons 502 records HTTP incident" true
    (Incidents.count m_addons_err.incidents > Incidents.count m_bl.incidents)

let test_pr54538_reply_artifacts_dive_target_and_p3_guards () =
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_en () in
  let t0 = Clock.Mono.of_ns 1_000_000_000L in
  let t1 = Clock.Mono.of_ns 2_000_000_000L in
  let has_cmd pred cmds = List.exists pred (Cmd.flatten cmds) in
  let art_a : Wire_knowledge.artifact_entry =
    {
      id = "art-alpha";
      revision = 1;
      title = "Alpha";
      summary = "First";
      author = "alpha";
      created_at_unix = 1795254000.0;
      body = { sha256 = "sha-alpha"; bytes = 64; mime = "text/html" };
    }
  in
  let art_b : Wire_knowledge.artifact_entry =
    {
      art_a with
      id = "art-beta";
      revision = 3;
      title = "Beta";
      body = { sha256 = "sha-beta"; bytes = 128; mime = "text/markdown" };
    }
  in
  (* P2 #2a: Artifact_dive target != selected_artifact fetches target, not selected_artifact *)
  let m_dive_b =
    {
      m0 with
      nav =
        {
          m0.nav with
          workspace = Nav.Knowledge;
          dive_stack = [ Nav.Dive_knowledge (Nav.Artifact_dive "art-beta") ];
        };
      knowledge = Knowledge_store.empty;
    }
  in
  let _, cmds_dive_b =
    Update.step ~now:t1 m_dive_b
      (Msg.Http_reply
         {
           epoch = m_dive_b.epoch;
           reply = Msg.Reply_artifacts (Ok [ art_a; art_b ]);
         })
  in
  Alcotest.(check bool)
    "P2 #2: Reply_artifacts in Artifact_dive(art-beta) fetches art-beta" true
    (has_cmd
       (function
         | Cmd.Http_get
             { req = Cmd.Get_artifact_detail { id = "art-beta"; revision = Some 3 }; _ } ->
             true
         | _ -> false)
       cmds_dive_b);
  Alcotest.(check bool)
    "P2 #2: Reply_artifacts in Artifact_dive(art-beta) never fetches selected art-alpha"
    false
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_artifact_detail { id = "art-alpha"; _ }; _ } ->
             true
         | _ -> false)
       cmds_dive_b);
  (* P2 #2b: Artifact_dive missing target emits 0 cmds (no silent fallback to selected_artifact) *)
  let m_dive_missing =
    {
      m_dive_b with
      nav =
        {
          m_dive_b.nav with
          dive_stack = [ Nav.Dive_knowledge (Nav.Artifact_dive "art-missing") ];
        };
    }
  in
  let _, cmds_dive_missing =
    Update.step ~now:t1 m_dive_missing
      (Msg.Http_reply
         {
           epoch = m_dive_missing.epoch;
           reply = Msg.Reply_artifacts (Ok [ art_a; art_b ]);
         })
  in
  Alcotest.(check int)
    "P2 #2: Reply_artifacts in Artifact_dive(missing) emits 0 cmds" 0
    (List.length (Cmd.flatten cmds_dive_missing));
  (* P3-1: Reply_artifacts does not refire non-retryable failed artifact detail *)
  let m_non_retry =
    {
      m_dive_b with
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.mark_artifact_detail_failed ~target:"art-beta" ~at:t0
             ~reason:"HTTP 404: not found" ~retryable:false;
    }
  in
  let _, cmds_non_retry =
    Update.step ~now:t1 m_non_retry
      (Msg.Http_reply
         {
           epoch = m_non_retry.epoch;
           reply = Msg.Reply_artifacts (Ok [ art_a; art_b ]);
         })
  in
  Alcotest.(check int)
    "P3-1: Reply_artifacts skips refire on non-retryable detail failure" 0
    (List.length (Cmd.flatten cmds_non_retry));
  (* P3-2: Moving browser client cursor to client with fresh/non-retryable tabs emits 0 cmds *)
  let mk_client cid : Wire_runtime.browser_client_row =
    {
      client_id = cid;
      browser = "Ego";
      version = "131.0";
      engine_version = "131.0";
      transport = "ego";
      space = None;
      ownership = Some "agent";
      presence_state = Some "present";
      presence_reason = None;
      interactions = [];
      last_activities = [];
    }
  in
  let bl : Wire_runtime.browser_lane_status =
    {
      ok = true;
      available = true;
      inventory_complete = true;
      client_count = 2;
      issue_count = 0;
      automatic_browse_ok = true;
      detail = None;
      clients = [ mk_client "ego-1"; mk_client "ego-2" ];
      issues = [];
    }
  in
  let m_bl_fresh =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Runtime; pane_index = 1 };
      runtime =
        Runtime_store.empty
        |> Runtime_store.set_tab Nav.Runtime_addons_browser
        |> Runtime_store.apply_browser_lane ~observed_at:t0 bl
        |> Runtime_store.mark_browser_tabs_failed ~at:t0 ~client_id:"ego-2"
             ~reason:"HTTP 403" ~retryable:false;
    }
  in
  let _, cmds_move_bl =
    Update.step ~now:t1 m_bl_fresh (Msg.Key_event (char_key "j"))
  in
  Alcotest.(check int)
    "P3-2: cursor move to client with non-retryable tab error emits 0 cmds" 0
    (List.length (Cmd.flatten cmds_move_bl))

let test_unified_navigation_sidebar_focus_ring_and_mouse () =
  let t0 = Clock.Mono.of_ns 1_000_000_000L in
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko () in
  let step m msg = Update.step ~now:t0 m msg in
  let press_key m k = step m (Msg.Key_event (key k)) in
  let press_shift_tab m =
    step m
      (Msg.Key_event
         { key = Keymap.Input.Tab; mods = { ctrl = false; alt = false; shift = true } })
  in
  let press_char m c = press_key m (Keymap.Input.Char c) in
  (* 1. Wide docks sidebar automatically; Shift+Tab from pane 0 jumps straight left into Menu *)
  Alcotest.(check bool) "Wide auto-docks left sidebar" true
    (Model.sidebar_docked m0);
  Alcotest.(check bool) "Body owns initial focus" true (Model.body_has_focus m0);
  let m_sb, _ = press_shift_tab m0 in
  Alcotest.(check bool) "Shift+Tab from pane 0 enters sidebar" true
    m_sb.nav.sidebar_focused;
  Alcotest.(check bool) "Body yields focus when sidebar focused" false
    (Model.body_has_focus m_sb);
  (* 2. Down in sidebar live-previews Work > Goals while keeping focus in sidebar *)
  let m_goals, cmds_goals = press_key m_sb Keymap.Input.Down in
  Alcotest.(check bool) "Live preview switches to Work workspace" true
    (Nav.equal_workspace m_goals.nav.workspace Nav.Work);
  Alcotest.(check bool) "Live preview lands on Goals tab" true
    (Nav.equal_work_tab m_goals.work.active_tab Nav.Work_pipeline);
  Alcotest.(check bool) "Focus remains in sidebar during arrow preview" true
    m_goals.nav.sidebar_focused;
  Alcotest.(check bool) "Live preview issues view fetches" true
    (cmds_goals <> []);
  (* 3. Enter in sidebar hands focus cleanly into Body pane 0 *)
  let m_body, _ = press_key m_goals Keymap.Input.Enter in
  Alcotest.(check bool) "Enter transfers focus to body" false
    m_body.nav.sidebar_focused;
  Alcotest.(check bool) "Body has focus after Enter" true
    (Model.body_has_focus m_body);
  Alcotest.(check int) "Body enters at pane 0" 0 m_body.nav.pane_index;
  (* 4. System overlay item (Settings) does NOT pop modal on arrow hover; opens on Enter *)
  let settings_idx = Nav.menu_item_index Nav.Menu_settings in
  let m_before_sys =
    {
      m_sb with
      nav = { m_sb.nav with sidebar_cursor = settings_idx - 1 };
    }
  in
  let m_hover_sys, _ = press_key m_before_sys Keymap.Input.Down in
  Alcotest.(check int) "Cursor lands on Settings item" settings_idx
    m_hover_sys.nav.sidebar_cursor;
  Alcotest.(check bool) "Hovering Settings does not pop modal" true
    (Option.is_none m_hover_sys.nav.overlay);
  let m_open_sys, _ = press_key m_hover_sys Keymap.Input.Enter in
  Alcotest.(check bool) "Enter on Settings opens Settings overlay" true
    (match m_open_sys.nav.overlay with Some (Nav.Settings _) -> true | _ -> false);
  (* 5. 'b' focuses docked sidebar, 2nd 'b' collapses it; compact opens floating drawer *)
  let m_b1, _ = press_char m0 "b" in
  Alcotest.(check bool) "First 'b' focuses docked sidebar" true
    m_b1.nav.sidebar_focused;
  let m_b2, _ = press_char m_b1 "b" in
  Alcotest.(check bool) "Second 'b' collapses docked sidebar" false
    (Model.sidebar_visible m_b2);
  let m_narrow = Model.initial ~cols:96 ~rows:28 () in
  Alcotest.(check bool) "Narrow hides sidebar by default" false
    (Model.sidebar_visible m_narrow);
  let m_drawer, _ = press_char m_narrow "b" in
  Alcotest.(check bool) "Narrow 'b' opens floating drawer" true
    (Model.sidebar_drawer_open m_drawer && m_drawer.nav.sidebar_focused);
  let m_esc_drawer, _ = press_key m_drawer Keymap.Input.Escape in
  Alcotest.(check bool) "Esc closes compact floating drawer" false
    (Model.sidebar_drawer_open m_esc_drawer || m_esc_drawer.nav.sidebar_focused);
  (* 6. Ctrl+K Palette indexes all 21 screens including Artifacts and Goals *)
  let m_pal =
    {
      m0 with
      nav = { m0.nav with overlay = Some Nav.Palette };
      palette = { mode = Model.Palette_commands; query = "Artifacts"; selected = 0 };
    }
  in
  let pal_entries = Update_nav.palette_entries m_pal in
  Alcotest.(check bool) "Ctrl+K finds first-class Artifacts route" true
    (List.exists
       (fun (e : Update_nav.palette_entry) ->
         match e.action with
         | Update_nav.Pal_menu_target (Nav.Menu_knowledge Nav.Knowledge_artifacts) -> true
         | _ -> false)
       pal_entries);
  (* 7. Mouse click on Sidebar item navigates directly to Artifacts; clicking right pane focuses pane 1 *)
  let sr = Option.get (Model.sidebar_rect m0) in
  let art_idx = Nav.menu_item_index (Nav.Menu_knowledge Nav.Knowledge_artifacts) in
  let art_vis_row = Model.sidebar_cursor_visual_row ~cursor:art_idx in
  let click_x_1based = sr.x + 3 + 1 in
  let click_y_1based = sr.y + 1 + art_vis_row + 1 in
  let m_clicked_art, cmds_art =
    step m0
      (Msg.Mouse_event
         (Keymap.Input.Left_press { col = click_x_1based; row = click_y_1based }))
  in
  Alcotest.(check bool) "Mouse click on Artifacts opens Knowledge > Artifacts" true
    (Nav.equal_workspace m_clicked_art.nav.workspace Nav.Knowledge
     && Nav.equal_knowledge_tab m_clicked_art.knowledge.active_tab
          Nav.Knowledge_artifacts);
  Alcotest.(check bool) "Mouse click hands focus to body" false
    m_clicked_art.nav.sidebar_focused;
  Alcotest.(check bool) "Mouse click triggers view fetches" true (cmds_art <> []);
  let body_r = Model.body_rect m_clicked_art in
  let right_col_1based = body_r.x + (body_r.w * 3 / 4) + 1 in
  let body_row_1based = body_r.y + 4 + 1 in
  let m_clicked_p1, _ =
    step m_clicked_art
      (Msg.Mouse_event
         (Keymap.Input.Left_press
            { col = right_col_1based; row = body_row_1based }))
  in
  Alcotest.(check int) "Clicking right half of 2-pane body focuses pane 1" 1
    m_clicked_p1.nav.pane_index;
  (* Clicking top-left [b] button toggles/focuses sidebar *)
  let m_clicked_b, _ =
    step m_clicked_p1
      (Msg.Mouse_event (Keymap.Input.Left_press { col = 3; row = 1 }))
  in
  Alcotest.(check bool) "Clicking top-left [b] focuses sidebar" true
    m_clicked_b.nav.sidebar_focused;
  (* Review regression 1: resizing narrower while docked sidebar is focused
     clears sidebar_focused and returns focus to body without trapping keys *)
  let m_shrunk, _ = step m_clicked_b (Msg.Resize { cols = 100; rows = 30 }) in
  Alcotest.(check bool) "Shrink <132 hides auto-docked sidebar" false
    (Model.sidebar_visible m_shrunk);
  Alcotest.(check bool) "Shrink <132 clears sidebar_focused" false
    m_shrunk.nav.sidebar_focused;
  Alcotest.(check bool) "Shrink <132 clears sidebar_has_focus" false
    (Model.sidebar_has_focus m_shrunk);
  Alcotest.(check bool) "Shrink <132 restores body_has_focus" true
    (Model.body_has_focus m_shrunk);
  let m_shrunk_right, _ =
    step m_shrunk (Msg.Key_event (key Keymap.Input.Right))
  in
  Alcotest.(check bool) "After shrink, Right cycles Knowledge sub-tab normally" true
    (Nav.equal_knowledge_tab m_shrunk_right.knowledge.active_tab
       Nav.Knowledge_memory);
  (* Review regression 2: Mouse Wheel over unfocused docked sidebar focuses it
     and scrolls cleanly onto System overlay items (Settings) without snapping back *)
  let m_infra_logs, _ =
    Update_nav.navigate_menu_target m0 (Nav.Menu_infra Nav.Infra_activity_logs)
  in
  Alcotest.(check bool) "Unfocused docked sidebar on Infra > Logs" false
    (Model.sidebar_has_focus m_infra_logs);
  let sr_logs =
    match Model.sidebar_rect m_infra_logs with
    | Some r -> r
    | None -> Alcotest.fail "expected docked sidebar rect on 140x40"
  in
  let m_wheel_settings, _ =
    step m_infra_logs
      (Msg.Mouse_event
         (Keymap.Input.Wheel
            {
              dir = Keymap.Input.Wheel_down;
              col = sr_logs.x + 3 + 1;
              row = sr_logs.y + 3 + 1;
            }))
  in
  Alcotest.(check bool) "Wheel over unfocused sidebar focuses sidebar" true
    (Model.sidebar_has_focus m_wheel_settings);
  Alcotest.(check int) "Wheel down from Infra Logs lands on Settings"
    (Nav.menu_item_index Nav.Menu_settings)
    m_wheel_settings.nav.sidebar_cursor;
  Alcotest.(check bool) "Wheel onto Settings does not auto-pop modal" true
    (Option.is_none m_wheel_settings.nav.overlay);
  (* Review regression 3: Compact Auto_folded_pill click above footer does NOT
     falsely focus composer when Model.composer_rect is None *)
  let m_compact = Model.initial ~cols:85 ~rows:26 ~lang:Say.Lang_ko () in
  Alcotest.(check bool) "Compact Pulse idle has no composer_rect" true
    (Option.is_none (Model.composer_rect m_compact));
  let m_compact_click, _ =
    step m_compact
      (Msg.Mouse_event (Keymap.Input.Left_press { col = 10; row = 24 }))
  in
  Alcotest.(check bool) "Click when composer auto-folded leaves composer unfocused"
    false (Drafts.is_focused m_compact_click.drafts)

(* ---------- Cut reply rebuilt from the operation journal ---------- *)

let unowned text =
  Wire_chat_journal.Text_delta
    { text; owner = Wire_chat_journal.Unobserved_scope None }

let owned ~generation ~scope text =
  Wire_chat_journal.Text_delta
    {
      text;
      owner =
        Wire_chat_journal.Observed_response
          { content_generation = generation; stream_scope = scope };
    }

let journal_page ?next events : Wire_chat_journal.page = { events; next }

let rebuilt events =
  Cut_reply.text (Cut_reply.apply_page (journal_page events) Cut_reply.start)

let from_label = function
  | Wire_chat_journal.From_start -> "start"
  | Wire_chat_journal.After { last_seq; next_offset } ->
      Printf.sprintf "after seq %d at %d" last_seq next_offset

let test_cut_reply_follows_the_connector_fold () =
  let open Wire_chat_journal in
  Alcotest.(check (option string))
    "an attempt boundary drops the earlier attempt and its late bytes"
    (Some "second")
    (rebuilt
       [
         Run_started;
         owned ~generation:1 ~scope:0 "first";
         Runtime_attempt_started;
         owned ~generation:1 ~scope:0 "late";
         owned ~generation:2 ~scope:0 "second";
         Event_error;
       ]);
  Alcotest.(check (option string)) "a new run starts the text over" (Some "b")
    (rebuilt [ Run_started; unowned "a"; Run_started; Other; unowned "b" ]);
  Alcotest.(check (option string))
    "an older response of the admitted generation is dropped" (Some "AC")
    (rebuilt
       [
         owned ~generation:1 ~scope:4 "A";
         owned ~generation:1 ~scope:3 "B";
         owned ~generation:1 ~scope:5 "C";
       ]);
  Alcotest.(check (option string))
    "a bare scope ahead of the admitted response drops older scopes"
    (Some "AUC")
    (rebuilt
       [
         owned ~generation:1 ~scope:4 "A";
         Text_delta { text = "U"; owner = Unobserved_scope (Some 6) };
         owned ~generation:1 ~scope:5 "B";
         owned ~generation:1 ~scope:6 "C";
       ]);
  Alcotest.(check (option string)) "the first terminal event ends the reply"
    (Some "kept")
    (rebuilt [ unowned "kept"; Run_finished; unowned "after" ]);
  Alcotest.(check (option string)) "a cut with no text draws nothing" None
    (rebuilt [ Run_started; Event_error ]);
  let cursor = { last_seq = 2; next_offset = 300 } in
  let first =
    Cut_reply.apply_page
      (journal_page ~next:cursor [ unowned "Hel" ])
      Cut_reply.start
  in
  Alcotest.(check (option string)) "a page with more asks for the next one"
    (Some "after seq 2 at 300")
    (Option.map from_label (Cut_reply.next_page first));
  Alcotest.(check (option string)) "nothing is drawn before the last page" None
    (Cut_reply.text first);
  let last = Cut_reply.apply_page (journal_page [ unowned "lo" ]) first in
  Alcotest.(check (option string)) "the pages join into one reply"
    (Some "Hello") (Cut_reply.text last);
  Alcotest.(check (option string)) "the last page ends reading" None
    (Option.map from_label (Cut_reply.next_page last));
  let ended =
    Cut_reply.apply_page
      (journal_page ~next:cursor [ unowned "x"; Event_error; unowned "y" ])
      Cut_reply.start
  in
  Alcotest.(check (option string))
    "a terminal event ends reading though the server has more" None
    (Option.map from_label (Cut_reply.next_page ended));
  Alcotest.(check (option string)) "a page after the end changes nothing"
    (Some "x")
    (Cut_reply.text (Cut_reply.apply_page (journal_page [ unowned "z" ]) ended));
  Alcotest.(check (option string)) "no journal asks nothing" None
    (Option.map from_label (Cut_reply.next_page Cut_reply.no_journal));
  Alcotest.(check (option string)) "no journal draws nothing" None
    (Cut_reply.text Cut_reply.no_journal)

let chat_row ~id ~role ?operation_id content : Wire_fleet.chat_message =
  {
    id;
    role;
    content;
    ts_unix = 1_700_000_000.0;
    turn_ref = None;
    model_used = None;
    tool_call_id = None;
    tool_call_name = None;
    execution_id = None;
    operation_id;
    transcript_slot = None;
    failure_kind = None;
  }

let failure_row ~id ~operation_id =
  chat_row ~id ~role:Wire_fleet.Role_request_failure ~operation_id
    "Keeper request failed: cancelled"

let journal_gets cmds =
  List.filter_map
    (function
      | Cmd.Http_get
          { req = Cmd.Get_chat_operation_events { operation_id; from; _ }; _ }
        ->
          Some (operation_id, from_label from)
      | _ -> None)
    (Cmd.flatten cmds)

let history_reply ~keeper messages (m : Model.t) =
  Update.step ~now:t1 m
    (Msg.Http_reply
       {
         epoch = m.epoch;
         reply =
           Msg.Reply_chat_history
             {
               keeper;
               result = Ok { messages; has_more = false; next_cursor = None };
             };
       })

let journal_reply ~operation_id ~from result (m : Model.t) =
  Update.step ~now:t2 m
    (Msg.Http_reply
       {
         epoch = m.epoch;
         reply =
           Msg.Reply_chat_operation_events
             { keeper = "alpha"; operation_id; from; result };
       })

let in_alpha_chat (m : Model.t) =
  {
    m with
    nav =
      {
        m.nav with
        dive_stack = [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat } ];
      };
  }

let test_cut_reply_reads_the_operation_journal () =
  let m0 = in_alpha_chat (Model.initial ()) in
  let history =
    [
      chat_row ~id:"u-cut" ~role:Wire_fleet.Role_user ~operation_id:"op-cut"
        "question";
      failure_row ~id:"f-cut" ~operation_id:"op-cut";
      (* The same operation's settled failure: the reply is drawn once. *)
      failure_row ~id:"f-cut-settled" ~operation_id:"op-cut";
      chat_row ~id:"a-done" ~role:Wire_fleet.Role_assistant
        ~operation_id:"op-done" "delivered reply";
      (* A failure settled after a delivered reply is not a cut. *)
      failure_row ~id:"f-done" ~operation_id:"op-done";
    ]
  in
  let m1, cmds1 = history_reply ~keeper:"alpha" history m0 in
  Alcotest.(check (list (pair string string)))
    "the history reply asks the cut operation's journal from its start"
    [ ("op-cut", "start") ] (journal_gets cmds1);
  Alcotest.(check (list (pair string string)))
    "only the first failure row of the cut operation stands for it"
    [ ("f-cut", "op-cut") ]
    (Fleet_store.cut_reply_rows ~keeper:"alpha" m1.fleet);
  Alcotest.(check string) "the request names the operation and the page size"
    "/api/v1/keepers/alpha/chat/events?operation_id=op-cut&limit=2000"
    (Cmd.get_request_path
       (Cmd.Get_chat_operation_events
          {
            keeper = "alpha";
            operation_id = "op-cut";
            from = Wire_chat_journal.From_start;
          }));
  Alcotest.(check (list (pair string string)))
    "the planner asks the same page while no answer is held"
    [ ("op-cut", "start") ]
    (journal_gets (View_fetches.fetches_for_current_view m1));
  let cursor : Wire_chat_journal.cursor = { last_seq = 1; next_offset = 240 } in
  let m2, cmds2 =
    journal_reply ~operation_id:"op-cut" ~from:Wire_chat_journal.From_start
      (Ok (journal_page ~next:cursor [ unowned "cut " ]))
      m1
  in
  Alcotest.(check (list (pair string string)))
    "a page with more asks for the next page"
    [ ("op-cut", "after seq 1 at 240") ] (journal_gets cmds2);
  Alcotest.(check string) "the next page sends both cursors back"
    "/api/v1/keepers/alpha/chat/events?operation_id=op-cut&since_seq=1&since_offset=240&limit=2000"
    (Cmd.get_request_path
       (Cmd.Get_chat_operation_events
          {
            keeper = "alpha";
            operation_id = "op-cut";
            from = Wire_chat_journal.After cursor;
          }));
  Alcotest.(check (list (pair string string)))
    "nothing is drawn before the last page" []
    (Fleet_store.String_map.bindings
       (Fleet_store.cut_replies_by_row ~keeper:"alpha" m2.fleet));
  let m2_dup, cmds2_dup =
    journal_reply ~operation_id:"op-cut" ~from:Wire_chat_journal.From_start
      (Ok (journal_page ~next:cursor [ unowned "cut " ]))
      m2
  in
  Alcotest.(check (list (pair string string)))
    "a second answer to the first page asks nothing" []
    (journal_gets cmds2_dup);
  let m3, cmds3 =
    journal_reply ~operation_id:"op-cut" ~from:(Wire_chat_journal.After cursor)
      (Ok (journal_page [ unowned "reply"; Wire_chat_journal.Event_error ]))
      m2_dup
  in
  Alcotest.(check (list (pair string string)))
    "the reply is drawn once, under the first failure row"
    [ ("f-cut", "cut reply") ]
    (Fleet_store.String_map.bindings
       (Fleet_store.cut_replies_by_row ~keeper:"alpha" m3.fleet));
  Alcotest.(check (list (pair string string))) "the last page asks nothing more"
    [] (journal_gets cmds3);
  Alcotest.(check (list (pair string string)))
    "a rebuilt reply is not asked again" []
    (journal_gets (View_fetches.fetches_for_current_view m3));
  Alcotest.(check bool) "the answer lands on its own keeper's key" true
    (match Fleet_store.cut_reply_for ~keeper:"beta" ~operation_id:"op-cut" m3.fleet with
    | Observed.Unreported -> true
    | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Failed _ ->
        false);
  (* Not on screen: the Memory tab does not read journals. *)
  let on_memory =
    {
      m0 with
      nav =
        {
          m0.nav with
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory } ];
        };
    }
  in
  let _, memory_cmds = history_reply ~keeper:"alpha" history on_memory in
  Alcotest.(check (list (pair string string)))
    "a history reply under another tab reads no journal" []
    (journal_gets memory_cmds);
  (* The Keepers split shows the selected keeper's Chat pane. *)
  let base = Model.initial () in
  let with_roster, _ =
    Update.step ~now:t1 base
      (Msg.Http_reply
         {
           epoch = base.epoch;
           reply =
             Msg.Reply_keepers_roster (Ok (roster_of [ sample_keeper "alpha" ]));
         })
  in
  let split =
    {
      with_roster with
      nav = { with_roster.nav with workspace = Nav.Keepers; dive_stack = [] };
      fleet = { with_roster.fleet with keeper_dive_tab = Nav.Keeper_chat };
    }
  in
  let _, split_cmds = history_reply ~keeper:"alpha" history split in
  Alcotest.(check (list (pair string string)))
    "the Keepers split's Chat pane reads the journal too"
    [ ("op-cut", "start") ] (journal_gets split_cmds)

let test_cut_reply_journal_failures () =
  let history =
    [
      failure_row ~id:"f-gone" ~operation_id:"op-gone";
      failure_row ~id:"f-broken" ~operation_id:"op-broken";
    ]
  in
  let m1, _ = history_reply ~keeper:"alpha" history (in_alpha_chat (Model.initial ())) in
  let incidents_before = Incidents.count m1.incidents in
  let gone, _ =
    journal_reply ~operation_id:"op-gone" ~from:Wire_chat_journal.From_start
      (Error (Msg.Http_error { status = 410; body = ""; api_error = None }))
      m1
  in
  Alcotest.(check int) "a pruned journal is not an incident" incidents_before
    (Incidents.count gone.incidents);
  Alcotest.(check (list (pair string string)))
    "a pruned journal is not asked again, only the broken one is"
    [ ("op-broken", "start") ]
    (journal_gets (View_fetches.fetches_for_current_view gone));
  let broken, _ =
    journal_reply ~operation_id:"op-broken" ~from:Wire_chat_journal.From_start
      (Error (Msg.Http_error { status = 503; body = "journal unreadable"; api_error = None }))
      gone
  in
  Alcotest.(check int) "a failed read records an incident"
    (incidents_before + 1)
    (Incidents.count broken.incidents);
  Alcotest.(check bool) "the failure lands on the operation's slot" true
    (match
       Fleet_store.cut_reply_for ~keeper:"alpha" ~operation_id:"op-broken"
         broken.fleet
     with
    | Observed.Failed { retryable = true; _ } -> true
    | Observed.Failed { retryable = false; _ }
    | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Unreported ->
        false);
  Alcotest.(check (list (pair string string)))
    "a retryable failure is asked again from the start"
    [ ("op-broken", "start") ]
    (journal_gets (View_fetches.fetches_for_current_view broken));
  Alcotest.(check (list (pair string string))) "neither draws anything" []
    (Fleet_store.String_map.bindings
       (Fleet_store.cut_replies_by_row ~keeper:"alpha" broken.fleet))

(* The first page of a long journal landed and a later page fails. The partial
   read draws nothing, so the failure replaces it. A stale partial read would
   be asked for the same page again at every trigger. *)
let test_cut_reply_failure_after_the_first_page () =
  let history = [ failure_row ~id:"f-long" ~operation_id:"op-long" ] in
  let m0, _ =
    history_reply ~keeper:"alpha" history (in_alpha_chat (Model.initial ()))
  in
  let cursor : Wire_chat_journal.cursor = { last_seq = 1; next_offset = 240 } in
  let page2 = Wire_chat_journal.After cursor in
  let after_first, _ =
    journal_reply ~operation_id:"op-long" ~from:Wire_chat_journal.From_start
      (Ok (journal_page ~next:cursor [ unowned "cut " ]))
      m0
  in
  let slot_failure (m : Model.t) =
    match
      Fleet_store.cut_reply_for ~keeper:"alpha" ~operation_id:"op-long" m.fleet
    with
    | Observed.Failed { retryable; _ } -> Some retryable
    | Observed.Value _ | Observed.Loading _ | Observed.Absent
    | Observed.Unreported ->
        None
  in
  let not_found =
    Error (Msg.Http_error { status = 404; body = "no such page"; api_error = None })
  in
  let incidents_before = Incidents.count after_first.incidents in
  let gone, gone_cmds =
    journal_reply ~operation_id:"op-long" ~from:page2 not_found after_first
  in
  Alcotest.(check (option bool))
    "a non-retryable failure replaces the partial read" (Some false)
    (slot_failure gone);
  Alcotest.(check int) "the failure records one incident"
    (incidents_before + 1)
    (Incidents.count gone.incidents);
  Alcotest.(check (list (pair string string))) "the failed reply asks nothing"
    [] (journal_gets gone_cmds);
  Alcotest.(check (list (pair string string)))
    "the planner does not ask the failed page again" []
    (journal_gets (View_fetches.fetches_for_current_view gone));
  Alcotest.(check (list (pair string string)))
    "a chat history landing does not ask it again" []
    (journal_gets (snd (history_reply ~keeper:"alpha" history gone)));
  let duplicate, duplicate_cmds =
    journal_reply ~operation_id:"op-long" ~from:page2 not_found gone
  in
  Alcotest.(check int) "a second failure of the same page records nothing"
    (Incidents.count gone.incidents)
    (Incidents.count duplicate.incidents);
  Alcotest.(check (list (pair string string)))
    "a second failure of the same page asks nothing" []
    (journal_gets duplicate_cmds);
  let down, _ =
    journal_reply ~operation_id:"op-long" ~from:page2
      (Error
         (Msg.Http_error
            { status = 503; body = "journal unreadable"; api_error = None }))
      after_first
  in
  Alcotest.(check (option bool)) "a retryable failure replaces the partial read"
    (Some true) (slot_failure down);
  Alcotest.(check (list (pair string string)))
    "a retryable failure asks again from the start"
    [ ("op-long", "start") ]
    (journal_gets (View_fetches.fetches_for_current_view down))

let test_live_chat_runtime_attempt_and_text_ownership () =
  let keeper = "alpha" in
  let req = "req-retry-1" in
  let obs gen scope =
    Wire_chat_journal.Observed_response
      { content_generation = gen; stream_scope = scope }
  in
  let delta ~owner text =
    Wire_fleet.Chunk_text_delta { operation_id = Some req; delta = text; owner }
  in
  let f0 =
    Fleet_store.empty
    |> Fleet_store.start_chat_stream ~keeper ~request_id:req
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (Wire_fleet.Chunk_run_started { operation_id = Some req })
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (Wire_fleet.Chunk_thinking_delta
            { operation_id = Some req; delta = "attempt 1 thought" })
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (Wire_fleet.Chunk_tool_start
            {
              operation_id = Some req;
              tool_use_id = "tu-1";
              tool_name = "read_file";
              args_preview = Some "a.ml";
            })
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (Wire_fleet.Chunk_tool_end
            {
              operation_id = Some req;
              tool_use_id = "tu-1";
              tool_name = Some "read_file";
              ok = Some true;
              output_preview = Some "ok";
            })
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (delta ~owner:(obs 1 0) "Attempt 1 partial ")
  in
  let f1 =
    Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
      (Wire_fleet.Chunk_runtime_attempt_started { operation_id = Some req })
      f0
  in
  let buf1 = Fleet_store.String_map.find keeper f1.chat_streams in
  Alcotest.(check string) "attempt boundary discards unfinished text" "" buf1.text;
  Alcotest.(check string) "attempt boundary discards unfinished thinking" ""
    buf1.thinking;
  Alcotest.(check int) "attempt boundary preserves completed tools" 1
    (List.length buf1.tools);
  (* Late delta from retired attempt 1 is dropped; attempt 2 text is accepted. *)
  let f2 =
    f1
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (delta ~owner:(obs 1 0) "STALE_LATE_TEXT")
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (delta ~owner:(obs 2 0) "Attempt 2 ")
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (delta ~owner:(Wire_chat_journal.Unobserved_scope (Some 2)) "scope ")
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (delta ~owner:(obs 2 1) "PRECEDING_SCOPE_DROPPED")
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (delta ~owner:(obs 2 2) "final.")
  in
  let buf2 = Fleet_store.String_map.find keeper f2.chat_streams in
  Alcotest.(check string)
    "stale retired and out-of-scope deltas dropped while attempt 2 accepted"
    "Attempt 2 scope final." buf2.text;
  (* Post-RUN_FINISHED late delta is ignored and does not resurrect buffer. *)
  let f3 =
    f2
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (Wire_fleet.Chunk_turn_done
            { operation_id = Some req; turn_ref = None; reply = None })
    |> Fleet_store.apply_chat_stream_chunk ~keeper ~request_id:req
         (delta ~owner:(obs 3 0) "LATE_AFTER_DONE")
  in
  let buf3 = Fleet_store.String_map.find keeper f3.chat_streams in
  Alcotest.(check string) "late delta after RUN_FINISHED ignored"
    "Attempt 2 scope final." buf3.text;
  Alcotest.(check bool) "buffer stays inactive after late delta" false buf3.active;
  Alcotest.(check bool) "buffer stays ended after late delta" true buf3.ended;
  (* /btw side-query also honors runtime attempt retry and response ownership. *)
  let t0 = Clock.Mono.zero in
  let drafts0, btw_id =
    Drafts.start_btw ~now:t0 ~keeper ~prompt:"status?" Drafts.empty
  in
  let m0 = { (Model.initial ()) with drafts = drafts0 } in
  let feed_btw m chunk =
    fst
      (Update.step ~now:t0 m
         (Msg.Chat_stream_chunk
            { epoch = m.epoch; keeper; request_id = btw_id; is_btw = true; chunk }))
  in
  let m_btw =
    m0
    |> (fun m -> feed_btw m (Wire_fleet.Chunk_run_started { operation_id = Some btw_id }))
    |> (fun m -> feed_btw m (delta ~owner:(obs 1 0) "btw attempt 1"))
    |> (fun m ->
         feed_btw m (Wire_fleet.Chunk_runtime_attempt_started { operation_id = Some btw_id }))
    |> (fun m -> feed_btw m (delta ~owner:(obs 1 0) "stale btw"))
    |> (fun m -> feed_btw m (delta ~owner:(obs 2 0) "btw clean"))
    |> (fun m ->
         feed_btw m
           (Wire_fleet.Chunk_turn_done
              { operation_id = Some btw_id; turn_ref = None; reply = None }))
  in
  match m_btw.drafts.btw with
  | Drafts.Btw_answered { reply; _ } ->
      Alcotest.(check string) "/btw retires attempt 1 and keeps attempt 2"
        "btw clean" reply
  | Drafts.Btw_idle | Drafts.Btw_sending _ | Drafts.Btw_streaming _
  | Drafts.Btw_failed _ ->
      Alcotest.fail "expected Btw_answered"

let test_24h_pulse_sparkline_and_sums_use_now_unix () =
  let slot_now = 1_795_251_600 in
  let now_unix = Float.of_int (slot_now + 300) in
  let slot_expired_edge = slot_now - (48 * Wire_fleet.turn_slot_seconds) in
  let slot_oldest_included = slot_now - (47 * Wire_fleet.turn_slot_seconds) in
  let slot_future = slot_now + Wire_fleet.turn_slot_seconds in
  let slot_recent = slot_now - (2 * Wire_fleet.turn_slot_seconds) in
  let mk_slot starts_at ok failed : Wire_fleet.turn_slot =
    {
      starts_at;
      ok;
      rested = 1;
      failed;
      scheduled = ok;
      reacted = failed;
      chat = 0;
      own = 1;
      unknown = 0;
    }
  in
  let stale_pulse : Wire_fleet.turn_pulse =
    {
      known_since = Float.of_int slot_expired_edge;
      slots = [ mk_slot slot_expired_edge 10 2; mk_slot slot_future 7 0 ];
    }
  in
  let recent_pulse : Wire_fleet.turn_pulse =
    {
      known_since = Float.of_int slot_expired_edge;
      slots =
        [
          mk_slot slot_expired_edge 20 0;
          mk_slot slot_oldest_included 1 0;
          mk_slot slot_recent 2 1;
          mk_slot slot_future 9 0;
        ];
    }
  in
  let ks =
    [
      grouped_keeper ~group:"org-a" "stale-keeper";
      grouped_keeper ~group:"org-a" "active-keeper";
      grouped_keeper ~group:"org-b" "no-pulse-keeper";
    ]
  in
  let m0 = Model.initial ~cols:140 ~rows:40 ~wall_unix:now_unix () in
  let shell_stub : Wire_fleet.dashboard_shell =
    {
      generated_at_unix = Some now_unix;
      project = Some "test";
      version = Some "0.1";
      counts =
        {
          agents = 0;
          tasks = 0;
          tasks_done_24h = 0;
          keepers = 3;
          persisted_keepers = Observed.unreported;
          configured_keepers = Observed.unreported;
          total_runtimes = 1;
        };
      scorecard_24h =
        {
          tasks_done_24h = Observed.unreported;
          tasks_done_total = Observed.unreported;
          tasks_in_progress = Observed.unreported;
          tasks_claimed = Observed.unreported;
          tasks_awaiting_verification = Observed.unreported;
          tasks_todo = Observed.unreported;
          tasks_cancelled = Observed.unreported;
          goals_completed_24h = Observed.unreported;
          verifications_passed_24h = Observed.unreported;
          verifications_rejected_24h = Observed.unreported;
          board_posts_24h = Observed.unreported;
          turns_24h = Observed.unreported;
          cost_24h_usd = Observed.unreported;
        };
      groups = [];
    }
  in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_shell ~observed_at:t0 shell_stub
    |> Fleet_store.apply_keepers ~observed_at:t0 ks
    |> Fleet_store.apply_roster_extras
         {
           sandbox_profiles = [];
           candle_balances_milli = [];
           candle_summary = None;
           turn_pulses =
             [ ("stale-keeper", stale_pulse); ("active-keeper", recent_pulse) ];
         }
  in
  (* Stale keeper has only the 48-slots-ago expired boundary slot and a future
     slot: 0 turns in 24h window and 48 zero slots. *)
  Alcotest.(check (option int)) "stale keeper excludes 48-slots-ago and future slots"
    (Some 0)
    (Fleet_store.keeper_turns_24h ~now_unix ~keeper:"stale-keeper" fleet);
  Alcotest.(check bool) "stale keeper sparkline is 48 zeros" true
    (let sp = Fleet_store.sparkline_24h ~now_unix ~keeper:"stale-keeper" fleet in
     List.length sp = 48 && List.for_all (fun v -> Float.equal v 0.0) sp);
  (* Active keeper counts 47-slots-ago boundary (1) + recent slot (2 ok + 1 failed = 3) = 4;
     excludes 48-slots-ago (20), future (9), and rested. *)
  Alcotest.(check (option int))
    "active keeper includes 47-slots-ago & recent, excludes 48-slots-ago & future"
    (Some 4)
    (Fleet_store.keeper_turns_24h ~now_unix ~keeper:"active-keeper" fleet);
  let active_spark =
    Fleet_store.sparkline_24h ~now_unix ~keeper:"active-keeper" fleet
  in
  Alcotest.(check int) "active sparkline length is 48" 48
    (List.length active_spark);
  Alcotest.(check (float 0.01))
    "oldest in-window slot (47 slots ago) lands at sparkline index 0" 1.0
    (List.hd active_spark);
  Alcotest.(check (list (float 0.01)))
    "quiet trailing slots after recent turn appear as zeros"
    [ 3.0; 0.0; 0.0 ]
    (List.filteri (fun i _ -> i >= 45) active_spark);
  (* Keeper without pulse returns None / []. *)
  Alcotest.(check (option int)) "no-pulse keeper returns None" None
    (Fleet_store.keeper_turns_24h ~now_unix ~keeper:"no-pulse-keeper" fleet);
  Alcotest.(check int) "no-pulse keeper sparkline is empty" 0
    (List.length
       (Fleet_store.sparkline_24h ~now_unix ~keeper:"no-pulse-keeper" fleet));
  (* Fleet total_turns_24h and company_groups sum only in-window turns. *)
  Alcotest.(check (option int)) "fleet total_turns_24h sums in-window turns only"
    (Some 4) (Fleet_store.total_turns_24h ~now_unix fleet);
  let org_a =
    List.find
      (fun (g : Wire_fleet.company_group) -> String.equal g.company "org-a")
      (Fleet_store.company_groups ~now_unix fleet)
  in
  Alcotest.(check int) "company turns_24h excludes >24h slots" 4 org_a.turns_24h;
  Alcotest.(check int) "company sparkline has 48 aligned slots" 48
    (List.length org_a.sparkline_24h);
  (* Fleet_pulse_wall sorts active-keeper ahead of stale-keeper even though stale
     keeper has more expired turns in its pulse buffer. *)
  let f_wall = Fleet_store.set_fleet_mode Nav.Fleet_pulse_wall fleet in
  let ordered_names =
    List.map
      (fun (k : Wire_fleet.keeper_summary) -> k.name)
      (Fleet_store.filtered_keepers f_wall)
  in
  Alcotest.(check (list string))
    "Fleet_pulse_wall ranks in-window active keeper first"
    [ "active-keeper"; "no-pulse-keeper"; "stale-keeper" ]
    ordered_names;
  (* Advancing wall clock via Msg.Tick past 24h refreshes BOTH Fleet_store.total_turns_24h
     AND the cached scorecard (m.fleet.shell.scorecard_24h.turns_24h). *)
  let m1 =
    { m0 with fleet = f_wall } |> Model.sync_effective_scorecard ~now:t0
  in
  let scorecard_turns (m : Model.t) =
    match Observed.to_option m.fleet.shell with
    | Some sh -> Observed.to_option sh.scorecard_24h.turns_24h
    | None -> None
  in
  Alcotest.(check (option int))
    "scorecard turns_24h starts at 4 before idle Tick" (Some 4)
    (scorecard_turns m1);
  let future_unix = now_unix +. (25.0 *. 3600.0) in
  let m2, _ = Update.step ~now:t1 m1 (Msg.Tick { wall_unix = future_unix }) in
  Alcotest.(check (option int))
    "Tick advancing >24h drops fleet total_turns_24h to 0" (Some 0)
    (Fleet_store.total_turns_24h ~now_unix:m2.freshness.last_wall_unix m2.fleet);
  Alcotest.(check (option int))
    "Tick advancing >24h refreshes cached scorecard turns_24h to 0" (Some 0)
    (scorecard_turns m2)

let test_media_viewer_follows_artifact_dive_target () =
  let art_list : Wire_knowledge.artifact_entry =
    {
      id = "artifact-list-001";
      revision = 1;
      title = "List Selected";
      summary = "";
      author = "alpha";
      created_at_unix = 1_795_254_000.0;
      body = { sha256 = "sha-list-001"; bytes = 64; mime = "text/markdown" };
    }
  in
  let art_dive : Wire_knowledge.artifact_entry =
    {
      id = "artifact-dive-002";
      revision = 2;
      title = "Dive Target";
      summary = "";
      author = "beta";
      created_at_unix = 1_795_254_100.0;
      body = { sha256 = "sha-dive-002"; bytes = 128; mime = "text/html" };
    }
  in
  let knowledge =
    Knowledge_store.empty
    |> Knowledge_store.apply_artifacts ~observed_at:t0 [ art_list; art_dive ]
  in
  let m0 =
    let base = Model.initial () in
    {
      base with
      knowledge;
      nav =
        {
          base.nav with
          workspace = Nav.Knowledge;
          dive_stack = [ Nav.Dive_knowledge (Nav.Artifact_dive art_dive.id) ];
          overlay = Some (Nav.System_gate Nav.Media_viewer);
        };
    }
  in
  Alcotest.(check (option string))
    "focused_artifact resolves Artifact_dive target instead of list selection"
    (Some art_dive.id)
    (Option.map (fun (a : Wire_knowledge.artifact_entry) -> a.id)
       (Model.focused_artifact m0));
  let step_char ch m =
    Update.step ~now:t1 m
      (Msg.Key_event
         { key = Keymap.Input.Char ch; mods = Keymap.Input.no_mods })
  in
  let _, cmds_h = step_char "H" m0 in
  Alcotest.(check bool) "Media_viewer [H] copies dive artifact SHA-256" true
    (List.exists
       (function
         | Cmd.Copy_clipboard s -> String.equal s art_dive.body.sha256
         | _ -> false)
       (Cmd.flatten cmds_h));
  let _, cmds_e = step_char "e" m0 in
  Alcotest.(check bool) "Media_viewer [e] exports dive artifact" true
    (List.exists
       (function
         | Cmd.Export_artifact { id; open_after = false; _ } ->
             String.equal id art_dive.id
         | _ -> false)
       (Cmd.flatten cmds_e));
  let _, cmds_o = step_char "o" m0 in
  Alcotest.(check bool) "Media_viewer [o] opens dive artifact" true
    (List.exists
       (function
         | Cmd.Export_artifact { id; open_after = true; _ } ->
             String.equal id art_dive.id
         | _ -> false)
       (Cmd.flatten cmds_o));
  let _, cmds_y = step_char "y" m0 in
  Alcotest.(check bool) "Media_viewer [y] fetches/copies dive artifact" true
    (List.exists
       (function
         | Cmd.Fetch_artifact_and_copy { id; _ } -> String.equal id art_dive.id
         | _ -> false)
       (Cmd.flatten cmds_y));
  (* Missing dive target never falls back to the unrelated list selection. *)
  let m_missing =
    {
      m0 with
      nav =
        {
          m0.nav with
          dive_stack = [ Nav.Dive_knowledge (Nav.Artifact_dive "missing-art") ];
        };
    }
  in
  Alcotest.(check bool)
    "missing Artifact_dive target returns None instead of list selection" true
    (Option.is_none (Model.focused_artifact m_missing));
  let m_y_miss, cmds_y_miss = step_char "y" m_missing in
  Alcotest.(check int) "missing dive [y] emits no copy command" 0
    (List.length (Cmd.flatten cmds_y_miss));
  Alcotest.(check bool) "missing dive [y] emits warning toast" true
    (Option.is_some m_y_miss.toast);
  let m_o_miss, cmds_o_miss = step_char "o" m_missing in
  Alcotest.(check int) "missing dive [o] emits no export command" 0
    (List.length (Cmd.flatten cmds_o_miss));
  Alcotest.(check bool) "missing dive [o] emits warning toast" true
    (Option.is_some m_o_miss.toast);
  (* active_artifact_target under Media_viewer:
     (a) list filter hiding selected_artifact still lets [v] and share/copy act on Artifact_dive;
     (b) missing Artifact_dive target never falls back to selected list item. *)
  let ws_id : Wire_common.workspace_identity =
    {
      instance_id = Some "inst-media-test";
      base_path = "/tmp/test-ws";
      masc_root = "/tmp/test-ws/.masc";
      workspace_sha256 = None;
    }
  in
  let dive_detail : Wire_knowledge.published_artifact_detail =
    {
      artifact = art_dive;
      content = "<h1>Dive</h1>";
      revisions = [];
      shared = false;
      share_version = 1;
    }
  in
  let list_detail : Wire_knowledge.published_artifact_detail =
    {
      artifact = art_list;
      content = "# List";
      revisions = [];
      shared = false;
      share_version = 1;
    }
  in
  let m_filtered =
    let k_filtered =
      m0.knowledge
      |> Knowledge_store.apply_artifact_detail ~observed_at:t0 dive_detail
      |> Knowledge_store.set_filter "unmatched-filter-xyz"
    in
    {
      m0 with
      knowledge = k_filtered;
      server_identity = { m0.server_identity with workspace = Some ws_id };
    }
  in
  Alcotest.(check bool) "filtered artifact list has selected_artifact = None" true
    (Option.is_none (Knowledge_store.selected_artifact m_filtered.knowledge));
  let m_v_filt, _ = step_char "v" m_filtered in
  Alcotest.(check bool)
    "Media_viewer [v] toggles view mode for Artifact_dive even when list filter empties selected_artifact"
    true
    (m_v_filt.knowledge.artifact_view_mode = `Raw_source);
  let _, cmds_hash_filt =
    Update_actions.execute_action ~now:t1 m_filtered Keymap.Copy_hash
  in
  Alcotest.(check bool)
    "Copy_hash under Media_viewer + filtered list copies Artifact_dive SHA-256"
    true
    (List.exists
       (function
         | Cmd.Copy_clipboard s -> String.equal s art_dive.body.sha256
         | _ -> false)
       (Cmd.flatten cmds_hash_filt));
  let _, cmds_url_filt =
    Update_actions.execute_action ~now:t1 m_filtered Keymap.Copy_public_url
  in
  Alcotest.(check bool)
    "Copy_public_url under Media_viewer + filtered list copies Artifact_dive URL"
    true
    (List.exists
       (function
         | Cmd.Copy_clipboard s ->
             String.equal s ("/published-artifacts/" ^ art_dive.id)
         | _ -> false)
       (Cmd.flatten cmds_url_filt));
  let _, cmds_share_filt =
    Update_actions.execute_action ~now:t1 m_filtered Keymap.Toggle_artifact_share
  in
  Alcotest.(check bool)
    "Toggle_artifact_share under Media_viewer + filtered list targets Artifact_dive"
    true
    (List.exists
       (function
         | Cmd.Http_post { req = Cmd.Post_artifact_share { id; _ }; _ } ->
             String.equal id art_dive.id
         | _ -> false)
       (Cmd.flatten cmds_share_filt));
  let m_missing_with_list =
    let k_list_detail =
      Knowledge_store.apply_artifact_detail ~observed_at:t0 list_detail
        m_missing.knowledge
    in
    {
      m_missing with
      knowledge = k_list_detail;
      server_identity = { m_missing.server_identity with workspace = Some ws_id };
    }
  in
  Alcotest.(check (option string))
    "unrelated list artifact is selected while Artifact_dive target is missing"
    (Some art_list.id)
    (Option.map (fun (a : Wire_knowledge.artifact_entry) -> a.id)
       (Knowledge_store.selected_artifact m_missing_with_list.knowledge));
  let m_v_miss, cmds_v_miss = step_char "v" m_missing_with_list in
  Alcotest.(check bool)
    "missing Artifact_dive [v] does not toggle artifact_view_mode" true
    (m_v_miss.knowledge.artifact_view_mode = `Document);
  Alcotest.(check int) "missing Artifact_dive [v] emits 0 cmds" 0
    (List.length (Cmd.flatten cmds_v_miss));
  let _, cmds_share_miss =
    Update_actions.execute_action ~now:t1 m_missing_with_list
      Keymap.Toggle_artifact_share
  in
  Alcotest.(check int)
    "missing Artifact_dive Toggle_artifact_share does not touch list artifact" 0
    (List.length (Cmd.flatten cmds_share_miss));
  let _, cmds_hash_miss =
    Update_actions.execute_action ~now:t1 m_missing_with_list Keymap.Copy_hash
  in
  Alcotest.(check int)
    "missing Artifact_dive Copy_hash does not touch list artifact" 0
    (List.length (Cmd.flatten cmds_hash_miss));
  let _, cmds_url_miss =
    Update_actions.execute_action ~now:t1 m_missing_with_list
      Keymap.Copy_public_url
  in
  Alcotest.(check int)
    "missing Artifact_dive Copy_public_url does not touch list artifact" 0
    (List.length (Cmd.flatten cmds_url_miss))

let () =
  Alcotest.run "masc_tui_store"
    [
      ( "epoch"
      , [
          Alcotest.test_case "stale reply rejection" `Quick
            test_epoch_stale_reply_rejection;
        ] );
      ( "three_channel"
      , [
          Alcotest.test_case "health/attention/incident isolation" `Quick
            test_three_channel_separation;
        ] );
      ( "composer_drafts"
      , [
          Alcotest.test_case "compact auto-fold, drafts & tx lifecycle" `Quick
            test_compact_composer_and_drafts;
        ] );
      ( "workspace_mismatch"
      , [
          Alcotest.test_case "409 epoch bump and anti-loop recovery" `Quick
            test_workspace_mismatch_recovery;
          Alcotest.test_case "a new epoch drops the log cursor" `Quick
            test_new_epoch_forgets_log_cursor;
          Alcotest.test_case "a new epoch detaches open chat streams" `Quick
            test_new_epoch_detaches_chat_streams;
          Alcotest.test_case "a chat stream 409 from another instance" `Quick
            test_chat_stream_409_from_another_instance;
        ] );
      ( "subscriptions"
      , [
          Alcotest.test_case "bounded streams & zero idle polling" `Quick
            test_subscriptions_bounded_and_zero_polling;
        ] );
      ( "input"
      , [
          Alcotest.test_case "keymap actions & all 22 slash commands" `Quick
            test_keymap_and_slash_commands;
        ] );
      ( "domains"
      , [
          Alcotest.test_case "knowledge defaults & config strict patch" `Quick
            test_knowledge_and_config_store;
        ] );
      ( "regressions"
      , [
          Alcotest.test_case "verifier P1-1..P1-6 & P2-1..P2-2" `Quick
            test_verifier_regressions;
          Alcotest.test_case "round1 Settings tabs/target reset & I->Esc->Ctrl+K/?"
            `Quick test_round1_settings_and_overlay_transitions;
          Alcotest.test_case "round2 Settings tab reset, wall_unix init & Keepers chat autofetch"
            `Quick test_round2_store_regressions;
          Alcotest.test_case "v2.5 data pipeline, 404 fallbacks, unreported toggle & 2-pane Settings"
            `Quick test_v25_data_pipeline_and_settings_2pane;
          Alcotest.test_case "P0-3/P0-4/P1-11 Settings safety & all wired Cmd mutations"
            `Quick test_p0_actions_settings_safety_and_wired_cmds;
          Alcotest.test_case "Memory OS internals fetch + Runtime assignment/key/login setup cmds"
            `Quick test_tui_memory_os_internals_fetch_and_runtime_assignment_setup_cmds;
          Alcotest.test_case "Keepers views request active schedules" `Quick
            test_keepers_views_request_active_schedules;
        ] );
      ( "arrow_nav_display_order"
      , [
          Alcotest.test_case "Fix 1: Keepers grouped visual order, collapse & poll/mode re-sync"
            `Quick test_nav_fix1_keepers_grouped_order_collapse_and_resync;
          Alcotest.test_case "Fix 2: Pulse strict 1-company-row Up/Down stepping"
            `Quick test_nav_fix2_pulse_company_row_stepping;
          Alcotest.test_case "Fix 3: Runtime Efficiency SSOT company-grouped display order"
            `Quick test_nav_fix3_runtime_efficiency_company_grouped_display_order;
          Alcotest.test_case "Fix 4: Knowledge Board succession chains & language-neutral Wiki clusters"
            `Quick test_nav_fix4_knowledge_board_chains_and_wiki_clusters;
          Alcotest.test_case "Fix 5: Keeper Dive Chat Up/Down/Wheel/Home/End scroll direction & tight bound"
            `Quick test_nav_fix5_keeper_chat_scroll_direction_and_home_bound;
          Alcotest.test_case "Fix 6: Work Inbox triage, unified task filters & split-pane Tab clamping"
            `Quick test_nav_fix6_work_inbox_filter_and_split_pane_clamping;
          Alcotest.test_case "Fix 7: Smooth symmetric viewport scrolling across all stores"
            `Quick test_nav_fix7_symmetric_viewport_scrolling_all_stores;
          Alcotest.test_case "Left/Right sub-tab cycling & composer/Settings guards"
            `Quick test_nav_left_right_subtab_cycling_and_guards;
          Alcotest.test_case "P1 #1: Chat_transcript SSOT exact bounds (Markdown/JSON/dedup/pending/composer)"
            `Quick test_p1_chat_transcript_ssot_exact_bounds;
          Alcotest.test_case "P1 #2: Work_inbox Ask/Approval focus, choice & copy sync"
            `Quick test_p1_work_inbox_ask_approval_sync;
          Alcotest.test_case "P1 #3: Pulse collapsed-company dive & independent pulse_scroll_offset"
            `Quick test_p1_pulse_collapsed_company_dive_and_scroll;
          Alcotest.test_case "P2 #4: Grouped views restore header row 0 on return to index 0 / Home"
            `Quick test_p2_grouped_top_header_row0_restoration;
          Alcotest.test_case "P2 #5: Schedules/Attention independent symmetric scroll & filter_focused guard"
            `Quick test_p2_schedules_attention_scroll_and_filter_guard;
          Alcotest.test_case "AG-UI chat stream lifecycle, ownership, provenance dedup & SSOT phase (15 bugs)"
            `Quick test_agui_chat_stream_lifecycle_15_bugs;
          Alcotest.test_case "Memory explorer: set_memory_diff_keeper, 5 fetches, modes/sort, reading, Observed isolation & SSE"
            `Quick test_memory_explorer_store_fetches_reading_and_sse;
          Alcotest.test_case "Agent-core activity skips only telemetry" `Quick
            test_agent_core_activity_skips_only_telemetry;
          Alcotest.test_case "A failed fetch lands on the panel slot, keeping the last value"
            `Quick test_fetch_failure_lands_on_panel_slot;
          Alcotest.test_case "A failure is asked again for new parameters or another keeper"
            `Quick test_failure_is_asked_again_for_a_new_question;
          Alcotest.test_case "An answer lands on its own target's slot"
            `Quick test_answers_land_on_their_own_target;
          Alcotest.test_case "The wiki index reply asks for the page it selects"
            `Quick test_wiki_index_reply_requests_selected_page;
          Alcotest.test_case "Infra changes follow the selected repository"
            `Quick test_infra_changes_follow_the_selected_repository;
          Alcotest.test_case "Unified navigation: Left Sidebar, Tab focus ring, live preview, Palette & mouse"
            `Quick test_unified_navigation_sidebar_focus_ring_and_mouse;
        ] );
      ( "keeper_context_and_cost"
      , [
          Alcotest.test_case "A roster keeps unreadable keepers apart from the rest"
            `Quick test_roster_keeps_unreadable_keepers_apart;
          Alcotest.test_case "The Ctrl+T Context tab reads turn records, costs and compaction"
            `Quick test_context_tab_reads_turn_records_and_costs;
          Alcotest.test_case "The Keepers view reads keeper-costs"
            `Quick test_keepers_view_reads_keeper_costs;
          Alcotest.test_case "Context display keeps estimates and reasons apart"
            `Quick test_context_display_keeps_estimates_and_reasons_apart;
          Alcotest.test_case "The Candle fallback never makes a 0/0/0 ledger"
            `Quick test_candle_fallback_never_makes_a_zero_ledger;
        ] );
      ( "chat_submit"
      , [
          Alcotest.test_case
            "Busy Enter queues; steer cuts only this TUI's own request"
            `Quick test_busy_enter_queues_and_steer_cuts_only_own_request;
          Alcotest.test_case "Feature Wave 1: Artifacts, Addons/Browser, Memory Flow, SSOT/Logs & 4 Polish Nits"
            `Quick test_feature_wave1_store_and_polish_nits;
          Alcotest.test_case "PR #54465 P2-1..4 & P3-1 regressions" `Quick
            test_pr54465_p2_fixes;
          Alcotest.test_case
            "PR #54538 P2 #2 Reply_artifacts dive target & P3 refire guards"
            `Quick test_pr54538_reply_artifacts_dive_target_and_p3_guards;
        ] );
      ( "chat_cut_reply"
      , [
          Alcotest.test_case "The cut reply follows the connectors' fold"
            `Quick test_cut_reply_follows_the_connector_fold;
          Alcotest.test_case
            "A cut reply reads its operation's journal once per page"
            `Quick test_cut_reply_reads_the_operation_journal;
          Alcotest.test_case
            "A pruned journal draws nothing; a failed read is an incident"
            `Quick test_cut_reply_journal_failures;
          Alcotest.test_case
            "A failure after the first page replaces the partial read"
            `Quick test_cut_reply_failure_after_the_first_page;
          Alcotest.test_case
            "Live chat and /btw honor runtime attempt boundary and text ownership"
            `Quick test_live_chat_runtime_attempt_and_text_ownership;
          Alcotest.test_case
            "24h pulse sparkline, sums, company rollup & wall sort anchor to now_unix"
            `Quick test_24h_pulse_sparkline_and_sums_use_now_unix;
          Alcotest.test_case
            "Media_viewer honors Artifact_dive target across actions without list fallback"
            `Quick test_media_viewer_follows_artifact_dive_target;
        ] );
    ]
