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
    context_ratio = Observed.value ~observed_at:t0 0.25;
    total_turns = Observed.value ~observed_at:t0 12;
    total_tokens = Observed.value ~observed_at:t0 12_000;
    cost_24h_usd = Observed.value ~observed_at:t0 0.0;
    last_turn_at_unix = Some 1_700_000_000.0;
    active_turn = None;
    activity_sparkline_24h = [ 1.0; 2.0; 3.0 ];
  }

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

let sample_quarantine ?(id = "q-1") ?(keeper = "alpha") () :
    Wire_knowledge.quarantine_candidate =
  {
    partition_id = "p-1";
    quarantine_id = id;
    keeper;
    post_id = "post-99";
    status = "quarantined";
    failure_reason = "delivery timeout";
    quarantined_at_unix = Some 80.0;
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
              | Cmd.Get_chat_history _
              | Cmd.Get_planning
              | Cmd.Get_verifications _
              | Cmd.Get_schedules _
              | Cmd.Get_asks _
              | Cmd.Get_tool_approvals
              | Cmd.Get_gate_pending
              | Cmd.Get_candle_ledger _
              | Cmd.Get_board_feed _
              | Cmd.Get_board_thread _
              | Cmd.Get_quarantines _
              | Cmd.Get_wiki_index _
              | Cmd.Get_wiki_page _
              | Cmd.Get_wiki_log _
              | Cmd.Get_wiki_search _
              | Cmd.Get_wiki_lint
              | Cmd.Get_artifacts
              | Cmd.Get_world_memory
              | Cmd.Get_memory_diff _
              | Cmd.Get_provider_usage _
              | Cmd.Get_keeper_costs _
              | Cmd.Get_efficiency _
              | Cmd.Get_models_metrics _
              | Cmd.Get_runtime_metrics
              | Cmd.Get_runtime_resolved
              | Cmd.Get_runtime_probe _
              | Cmd.Get_exact_lane_runs _
              | Cmd.Get_fusion_runs
              | Cmd.Get_tool_series _
              | Cmd.Get_tools_catalog _
              | Cmd.Get_connectors
              | Cmd.Get_browser_lane
              | Cmd.Get_mcp_clients
              | Cmd.Get_sandboxes
              | Cmd.Get_keeper_sandbox _
              | Cmd.Get_repositories
              | Cmd.Get_file_changes _
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
      | Cmd.Open_external_url _
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
      | Cmd.Open_external_url _
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
      | Cmd.Open_external_url _
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
           reply = Msg.Reply_keepers_roster (Ok [ sample_keeper "stale-k" ]);
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
           reply = Msg.Reply_keepers_roster (Ok [ sample_keeper "live-k" ]);
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
               (Ok [ sample_keeper ~health:Wire_fleet.Keeper_healthy "alpha" ]);
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
  let m6, _ =
    Update.step ~now:t1 m5
      (Msg.Http_reply
         {
           epoch = m5.epoch;
           reply = Msg.Reply_quarantines (Ok [ sample_quarantine () ]);
         })
  in
  let m7, _ =
    Update.step ~now:t1 m6
      (Msg.Http_reply
         {
           epoch = m6.epoch;
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
  Alcotest.(check int) "4 attention items" 4 (Attention.count m9.attention);
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
        | Cmd.Open_external_url _
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
        | Cmd.Open_external_url _
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
  Alcotest.(check int) "ask not optimistically dropped" 4
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
  Alcotest.(check int) "ask removed on server ack" 3
    (Attention.count m12.attention);
  Alcotest.(check int) "recent 24h decision recorded" 1
    (List.length m12.work.recent_decisions_24h)

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
           reply = Msg.Reply_keepers_roster (Ok [ sample_keeper "alpha" ]);
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
               { operation_id = "op-1"; queued_count = 0; state = "accepted" };
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
               { operation_id = "op-1"; turn_ref = "t-1"; reply = "ok" };
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
        | Cmd.Open_external_url _
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
        | Nav.Runtime_quotas_credits | Nav.Runtime_failover_lanes -> 0
        | Nav.Runtime_efficiency_spend | Nav.Runtime_tools_connectors -> 1
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
  (* P1-1: Sse_log_entry on Infra_activity_logs emits 0 commands (no reconnect storm) *)
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
         { epoch = m_logs.epoch; event = Msg.Sse_log_entry log_entry })
  in
  Alcotest.(check (option int)) "last_log_seq advanced" (Some 42)
    m_logs2.infra.last_log_seq;
  Alcotest.(check int) "Sse_log_entry emits 0 commands (no Sync_streams storm)" 0
    (List.length log_cmds)

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
    (Nav.equal_work_tab m_tab2.work.active_tab Nav.Work_tasks_schedules);
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
           reply = Msg.Reply_keepers_roster (Ok [ sample_keeper "alpha" ]);
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
        | Cmd.Open_external_url _
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
    }
  in
  let m_hist, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         {
           epoch = m0.epoch;
           reply = Msg.Reply_keepers_roster (Ok [ sample_keeper "alpha" ]);
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
               { operation_id = "op-dup"; queued_count = 0; state = "accepted" };
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
               { operation_id = "op-b"; delta = "pong" };
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
       (Cmd.Post_task_cancel { task_id = "t1"; reason = None }));
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
    | Cmd.Open_external_url _
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
        | Cmd.Post_quarantine_requeue _
        | Cmd.Post_memory_act _
        | Cmd.Post_fusion_launch _
        | Cmd.Post_sandbox_probe _
        | Cmd.Post_tui_preference _
        | Cmd.Post_keeper_turn_interrupt _
        | Cmd.Post_board_create _
        | Cmd.Post_schedule_create _
        | Cmd.Post_connector_create _
        | Cmd.Post_repo_add _
        | Cmd.Post_task_cancel _
        | Cmd.Post_harness_overrule _ ->
            false)
    | Cmd.Batch _
    | Cmd.Http_get _
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
        | Cmd.Open_external_url _
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
        | Cmd.Open_external_url _
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
               (Ok [ sample_keeper "alpha"; sample_keeper "beta" ]);
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
        | Cmd.Open_external_url _
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
        Knowledge_store.apply_memory_diff ~observed_at:t1 alpha_mem_diff
          m_k.knowledge;
    }
  in
  let _, cmds_kmem_beta =
    Update.step ~now:t2 m_kmem_alpha (Msg.Key_event (char_key "j"))
  in
  Alcotest.(check bool)
    "Keeper_memory move alpha->beta fetches Get_memory_diff(beta)" true
    (has_get (is_mem_diff_for "beta") cmds_kmem_beta);

  (* 2. Keeper_sandbox: loaded fresh for alpha, pressing j -> beta fetches beta's sandbox *)
  let m_ksb_alpha =
    {
      m_k with
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_sandbox m_k.fleet;
      infra =
        Infra_store.apply_keeper_sandbox ~observed_at:t1 alpha_sandbox m_k.infra;
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
           reply = Msg.Reply_keepers_roster (Ok [ sample_keeper "alpha" ]);
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
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  let pulse_cmds = Cmd.flatten (View_fetches.fetches_for_current_view ~force:true m0) in
  let has_path expected =
    List.exists
      (function
        | Cmd.Http_get { req; _ } ->
            String.equal (Cmd.get_request_path req) expected
        | Cmd.Batch _ | Cmd.Http_post _ | Cmd.Http_put _
        | Cmd.Http_post_stream _ | Cmd.Sync_streams _
        | Cmd.Update_workspace_guard _ | Cmd.Voice_cmd _
        | Cmd.Copy_clipboard _ | Cmd.Open_external_url _
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
      activity_sparkline_24h = [ 2.0; 5.0; 3.0 ];
    }
  in
  let m1, _ =
    Update.step ~now:t0 m0
      (Msg.Http_reply
         { epoch = m0.epoch; reply = Msg.Reply_keepers_roster (Ok [ k_masc ]) })
  in
  let extras : Wire_fleet.keeper_roster_extras =
    {
      sandbox_profiles = [ ("alpha-builder", Wire_fleet.Profile_microvm) ];
      candle_balances_milli = [ ("alpha-builder", 5000) ];
      candle_summary =
        Some
          {
            issued_milli = "10000";
            burned_milli = "2500";
            circulating_milli = "7500";
          };
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
        | Cmd.Copy_clipboard _ | Cmd.Open_external_url _
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
          prs_reviewed_24h = Observed.unreported;
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
  (* [n] on Work_pipeline opens Goal modal (not Schedule); on Work_tasks_schedules opens Schedule *)
  let m_goal_modal, _ = step m_work (char_key "n") in
  Alcotest.(check bool) "[n] on Work_pipeline opens Goal modal" true
    (match m_goal_modal.inline_modal with
    | Some md ->
        List.exists
          (fun (f : Model.modal_form_field) -> String.equal f.key "goal_title")
          md.fields
    | None -> false);
  let m_sched_tab =
    { m_work with work = Work_store.set_tab Nav.Work_tasks_schedules m_work.work }
  in
  let m_sched_modal, _ = step m_sched_tab (char_key "n") in
  Alcotest.(check bool) "[n] on Work_tasks_schedules opens Schedule_form" true
    (Option.equal Nav.equal_overlay m_sched_modal.nav.overlay
       (Some (Nav.Inline_action Nav.Schedule_form)));

  (* Verification_dive: [a] approve, [x] -> Verification_reject modal -> submit, [h] -> Harness_overrule modal -> submit, [Space] JSON *)
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
  let _, cmds_vrej = step m_vrej_typed (key Keymap.Input.Enter) in
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
  let m_hov, _ = step m_vdive (char_key "h") in
  Alcotest.(check bool) "Verification_dive [h] opens Harness_overrule modal" true
    (Option.equal Nav.equal_overlay m_hov.nav.overlay
       (Some (Nav.Inline_action (Nav.Harness_overrule "task-100"))));
  let m_hov_typed, _ = step m_hov (char_key "r") in
  let _, cmds_hov = step m_hov_typed (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Harness_overrule submit emits Post_harness_overrule" true
    (has_cmd
       (function
         | Cmd.Http_post
             { req = Cmd.Post_harness_overrule { target_id = "task-100"; _ }; _ } ->
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

  (* Goal_dive: Awaiting_confirmation [a] -> Post_goal_confirmation; Executing [a]/[x] -> Post_goal_transition *)
  let m_gdive_conf =
    {
      m_work with
      nav = { m_work.nav with dive_stack = [ Nav.Dive_work (Nav.Goal_dive "goal-100") ] };
    }
  in
  let _, cmds_gconf = step m_gdive_conf (char_key "a") in
  Alcotest.(check bool) "Goal_dive [a] with server proof emits Post_goal_confirmation"
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
                     verification_run_id = "ver-100";
                     _;
                   };
               _;
             } ->
             true
         | _ -> false)
       cmds_gconf);
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

  (* 3. Knowledge: Memory [a] -> Post_memory_act, Wiki [e]/[Ctrl+E] -> Put_wiki_page / Edit_wiki_page, Board [R] -> Post_quarantine_requeue *)
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
        |> Knowledge_store.apply_wiki_page ~observed_at:t0 wiki_page;
    }
  in
  let m_wedit, _ = step m_wiki (char_key "e") in
  let _, cmds_wput = step m_wedit (key Keymap.Input.Enter) in
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
  let m_fmod, _ = step m_rt (char_key "f") in
  let _, cmds_flaunch = step m_fmod (key Keymap.Input.Enter) in
  Alcotest.(check bool) "Runtime [f] modal submit emits Post_fusion_launch" true
    (has_cmd
       (function
         | Cmd.Http_post
             { req = Cmd.Post_fusion_launch { keeper = "alpha"; _ }; _ } ->
             true
         | _ -> false)
       cmds_flaunch);

  (* 5. Keepers: active turn interrupt (Esc & Ctrl+X), Speak ([S]), Copy ([y]), [c] quick chat, Server_offline [s], /model *)
  let chat_page : Wire_fleet.chat_history_page =
    {
      messages =
        [
          {
            id = "m1";
            role = Wire_fleet.Role_assistant;
            content = "Latest assistant answer for clipboard and TTS";
            ts_unix = 100.0;
            turn_ref = None;
            model_used = None;
            tool_call_id = None;
            tool_call_name = None;
            execution_id = None;
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
                   { keeper = "alpha"; interrupt_token = "int-tok-7" };
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
         | Cmd.Copy_clipboard "Latest assistant answer for clipboard and TTS" ->
             true
         | _ -> false)
       cmds_copy);
  let _, cmds_speak = step m_kchat (char_key "S") in
  Alcotest.(check bool) "Keeper_chat [S] emits Voice_cmd Speak" true
    (has_cmd
       (function
         | Cmd.Voice_cmd
             (Cmd.Speak
                { text = "Latest assistant answer for clipboard and TTS"; _ }) ->
             true
         | _ -> false)
       cmds_speak);
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
        ] );
    ]
