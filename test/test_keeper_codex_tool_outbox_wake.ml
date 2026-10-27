open Alcotest
open Masc

let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "result-owner"

let with_workspace f =
  let base_path = Filename.temp_file "masc_tool_result_wake_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  let config = Workspace.default_config base_path in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  let path = Filename.concat base_path "runtime.toml" in
  let toml = {|[providers.codex]
protocol = "codex-app-server"
command = "/bin/false"
is-non-interactive = true
[models.codex]
api-name = "gpt-fixture"
max-context = 400000
[codex.codex]
[runtime]
default = "codex.codex"
|} in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      (match catalog_snapshot with None -> Llm_provider.Model_catalog.clear_global ()
       | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
      Keeper_registry.For_testing.unregister ~base_path keeper_name;
      ignore (Workspace.reset config))
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
        Fs_compat.save_file path toml;
        get (Runtime.init_default ~config_path:path);
        Masc_test_deps.declare_fixture_keeper ~base_path ~sandbox_image:"base"
          ~sandbox_profile:(Some Keeper_types_profile.Docker) keeper_name;
        let meta = get (Masc_test_deps.meta_of_json_fixture
          (`Assoc ["name",`String keeper_name])) in
        let meta = get (Keeper_meta_contract.effective_meta_result ~base_path meta) in
        ignore (get (Keeper_meta_store.replace_snapshot config meta));
        ignore (Keeper_registry.register_offline ~base_path keeper_name meta);
        f config meta env)))

let receipt turn_id : Keeper_client_tool_outbox.receipt =
  {thread_id="thread-original";turn_id;call_id="call-original";
   tool_name="Execute";arguments=`Assoc ["command",`String "effect-already-completed"];
   response=`String "private-completed-result"}

let retain config result =
  get (Keeper_client_tool_outbox.retain ~base_path:config.Workspace.base_path ~keeper_name result)
let snapshot config =
  get (Keeper_client_tool_outbox.load ~base_path:config.Workspace.base_path ~keeper_name)
let pending config =
  get (Keeper_registry_event_queue.pending_selections_result
    ~base_path:config.Workspace.base_path keeper_name)
let only_selection config =
  match pending config with [selection] -> selection | _ -> fail "expected one pending receipt hint"
let notify config =
  get (Keeper_client_tool_outbox_wake.notify ~base_path:config.Workspace.base_path ~keeper_name)
let pulse config =
  Eio.Switch.run (fun sw ->
    let recovery = Keeper_client_tool_outbox_wake.create ~config in
    Keeper_client_tool_outbox_wake.pulse ~sw recovery;
    Keeper_client_tool_outbox_wake.pulse ~sw recovery)

let test_restart_discovers_and_deduplicates () =
  with_workspace (fun config _ _ ->
    retain config (receipt "turn-1");
    check int "persisting a result is not notification" 0 (List.length (pending config));
    pulse config;
    let selection = only_selection config in
    let receipt_id = match Keeper_client_tool_outbox.receipt_ids (snapshot config) with
      | [id] -> id | _ -> fail "expected one durable result" in
    (match selection.source.payload with
     | Keeper_event_queue.Tool_result_ready id -> check string "exact pointer" receipt_id id
     | Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _
     | Schedule_due _ | Connector_attention _ | Hitl_resolved _ | Ask_answered _
     | Completion_authority_rejected _ | Task_cancelled _ | Workspace_message _
     | Delegate_completed _ | Composition_completed _ | Owned_job_completed _
     | Task_outcome _ | Addon_operation_changed _ -> fail "recovery must enqueue a typed result pointer");
    let encoded = Keeper_event_queue.stimulus_to_yojson selection.source in
    let decoded = get (Keeper_event_queue.stimulus_of_yojson encoded) in
    check bool "typed pointer survives durable queue wire format" true
      (Keeper_event_queue.stimulus_identity_equal selection.source decoded);
    let public = Yojson.Safe.to_string encoded in
    check bool "result body is not copied to the queue" false
      (String_util.contains_substring public "private-completed-result");
    notify config;
    pulse config;
    check int "fresh supervisor and repeated notify share one pending event" 1
      (List.length (pending config));
    check int "notification is not receipt ACK" 1
      (List.length (Keeper_client_tool_outbox.receipt_ids (snapshot config))))

let test_failed_turn_can_be_notified_again () =
  with_workspace (fun config _ _ ->
    retain config (receipt "turn-1");
    notify config;
    let selection = only_selection config in
    (* Starting/consuming the queue signal is weaker than actual client ACK.
       This is the state left by a refused provider turn with unread receipts. *)
    Keeper_reaction_ledger.record_event_queue_turn_started
      ~base_path:config.Workspace.base_path ~keeper_name selection.source;
    get (Keeper_registry_event_queue.ack_pending_result
      ~base_path:config.Workspace.base_path keeper_name ~selection);
    check int "first queue hint consumed" 0 (List.length (pending config));
    pulse config;
    let repeated = only_selection config in
    check bool "same durable receipt may be delivered after a failed turn" true
      (Keeper_event_queue.stimulus_identity_equal selection.source repeated.source);
    check int "failed delivery retains the result" 1
      (List.length (Keeper_client_tool_outbox.receipt_ids (snapshot config)));
    let loaded = snapshot config in
    retain config (receipt "turn-2");
    get (Keeper_client_tool_outbox.acknowledge loaded);
    (match get (Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config ~keeper_name repeated) with
     | Keeper_heartbeat_stimulus_intake.Tool_result_hint_retired -> ()
     | Selection_actionable | Spent_grant_replay_acknowledged | Absent_grant_retired _ ->
       fail "delivered hint must retire before another model turn");
    pulse config;
    let remaining = only_selection config in
    check bool "a newer unread receipt remains independently recoverable" false
      (Keeper_event_queue.stimulus_identity_equal repeated.source remaining.source);
    check int "exact snapshot ACK retains newer result" 1
      (List.length (Keeper_client_tool_outbox.receipt_ids (snapshot config)));
    get (Keeper_client_tool_outbox.acknowledge (snapshot config));
    ignore (get (Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
      ~config ~keeper_name remaining));
    pulse config;
    check int "receipt ACK ends automatic recovery" 0 (List.length (pending config)))

let test_paused_owner_keeps_its_result () =
  with_workspace (fun config meta _ ->
    let paused = {meta with Keeper_meta_contract.paused=true} in
    ignore (get (Keeper_meta_store.replace_snapshot config paused));
    let entry = Keeper_registry.register_offline
      ~base_path:config.Workspace.base_path keeper_name paused in
    retain config (receipt "turn-paused");
    pulse config;
    check bool "recovery does not unpause" true entry.meta.paused;
    check bool "recovery does not start an owner fiber" false (Atomic.get entry.fiber_wakeup);
    check int "paused owner keeps its unread receipt" 1
      (List.length (Keeper_client_tool_outbox.receipt_ids (snapshot config)));
    check int "one durable notification waits for normal admission" 1 (List.length (pending config)))

let test_unreadable_result_is_not_consumed () =
  with_workspace (fun config _ _ ->
    let result = receipt "turn-corrupt" in
    retain config result;
    let receipt_id = match Keeper_client_tool_outbox.receipt_ids (snapshot config) with
      | [id] -> id | _ -> fail "expected one receipt" in
    let session_path = get (Keeper_official_client_session_store.path
      ~base_path:config.Workspace.base_path ~keeper_name) in
    let receipt_path = Filename.concat (Filename.concat (Filename.dirname session_path)
      "undelivered-tools") (receipt_id ^ ".json") in
    Fs_compat.save_file receipt_path "{unreadable";
    (match Keeper_client_tool_outbox_wake.notify
       ~base_path:config.Workspace.base_path ~keeper_name with
     | Error _ -> ()
     | Ok () -> fail "unreadable receipt must remain an explicit recovery failure");
    check int "no hint is committed from unreadable state" 0 (List.length (pending config));
    check string "bad evidence remains available for diagnosis" "{unreadable"
      (Fs_compat.load_file receipt_path);
    (* Repairing the fixture's original owner permits the existing pulse to
       recover; no new operator message is needed. *)
    retain config result;
    pulse config;
    check int "original result is discovered after storage repair" 1 (List.length (pending config)))

let test_route_change_preserves_unrelated_work_and_receipt ?(corrupt=false) () =
  with_workspace (fun config meta env ->
    let result = receipt "turn-route-change" in
    retain config result;
    notify config;
    let original = only_selection config in
    let receipt_id = match original.source.payload with
      | Keeper_event_queue.Tool_result_ready id -> id
      | Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _
      | Schedule_due _ | Connector_attention _ | Hitl_resolved _ | Ask_answered _
      | Completion_authority_rejected _ | Task_cancelled _ | Workspace_message _
      | Delegate_completed _ | Composition_completed _ | Owned_job_completed _
      | Task_outcome _ | Addon_operation_changed _ -> fail "expected original result pointer" in
    let session_path = get (Keeper_official_client_session_store.path
      ~base_path:config.Workspace.base_path ~keeper_name) in
    let receipt_path = Filename.concat (Filename.concat (Filename.dirname session_path)
      "undelivered-tools") (receipt_id ^ ".json") in
    if corrupt then Fs_compat.save_file receipt_path "{unreadable";
    let path = Filename.concat config.Workspace.base_path "runtime.toml" in
    let codex_config = Fs_compat.load_file path in
    let alternate_config = codex_config ^ {|[providers.http]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[models.http]
api-name = "unavailable-result-fixture"
max-context = 400000
[http.http]
[runtime.assignments]
result-owner = "http.http"
|} in
    let catalog = get (Llm_provider.Model_catalog.of_toml_string ~source:"outbox-unavailable-route"
      "[[models]]\nmodel_id = \"unrelated-fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\n") in
    Llm_provider.Model_catalog.set_global catalog;
    Fs_compat.save_file path alternate_config;
    (match Runtime.init_default_degraded_report ~config_path:path with
     | Ok (Runtime.Initialized_degraded _) -> ()
     | Ok Runtime.Initialized -> fail "missing catalog binding must remain unavailable"
     | Error error -> fail (Runtime.strict_init_error_to_string error));
    (match Runtime.resolve_assignment "http.http" with
     | `Unavailable _ -> ()
     | `Missing | `Lane _ -> fail "fixture requires a real unavailable assignment");
    check bool "every reachable client must consume the receipt" false
      (Keeper_client_tool_outbox_wake.route_can_consume meta);
    let unrelated : Keeper_event_queue.stimulus =
      {post_id="independent-bootstrap";urgency=Normal;
       arrived_at=Time_compat.now ();payload=Bootstrap} in
    get (Keeper_registry_event_queue.enqueue_durable_result
      ~base_path:config.base_path keeper_name unrelated);
    let intake = Eio.Switch.run (fun sw ->
      let ctx : _ Keeper_types_profile.context =
        {config;agent_name="tool-result-route-test";sw;
         clock=Eio.Stdenv.clock env;proc_mgr=None;net=None;
         publication_recovery_provider=Masc_test_deps.non_runtime_publication_recovery_provider} in
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx ~meta_after_triage:meta ~pending_board_events:[]) in
    check bool "unavailable receipt does not poison actual intake" true
      (Option.is_none intake.event_queue_intake_error);
    (match Keeper_heartbeat_source_batch.stimuli intake.source_batch with
     | [source] -> check string "actual intake advances to unrelated work"
         unrelated.post_id source.post_id
     | _ -> fail "exactly the unrelated source must be admitted");
    let next = only_selection config in
    check string "unrelated work can be selected" unrelated.post_id next.source.post_id;
    pulse config;
    check int "unavailable client is not woken for unread Codex data" 1 (List.length (pending config));
    if corrupt then
      check string "unavailable route preserves unreadable evidence" "{unreadable"
        (Fs_compat.load_file receipt_path)
    else
      check int "receipt still belongs to its durable owner" 1
        (List.length (Keeper_client_tool_outbox.receipt_ids (snapshot config)));
    get (Keeper_registry_event_queue.ack_pending_result
      ~base_path:config.base_path keeper_name ~selection:next);
    Fs_compat.save_file path codex_config;
    get (Runtime.init_default ~config_path:path);
    if corrupt then retain config result;
    pulse config;
    let resumed = only_selection config in
    check bool "Codex return recovers the same original result" true
      (Keeper_event_queue.stimulus_identity_equal original.source resumed.source))

let test_multiple_codex_candidates_remain_recoverable () =
  with_workspace (fun config meta _ ->
    let path = Filename.concat config.Workspace.base_path "runtime.toml" in
    Fs_compat.save_file path (Fs_compat.load_file path ^ {|[providers.backup]
protocol = "codex-app-server"
command = "/bin/false"
is-non-interactive = true
[backup.codex]
[runtime.lanes.recovery]
candidates = ["codex.codex", "backup.codex"]
[runtime.assignments]
result-owner = "recovery"
|});
    get (Runtime.init_default ~config_path:path);
    check bool "all-Codex fallback preserves automatic recovery" true
      (Keeper_client_tool_outbox_wake.route_can_consume meta);
    retain config (receipt "turn-codex-fallback");
    pulse config;
    check int "Codex-only fallback route receives its unread result" 1
      (List.length (pending config)))

let test_mixed_route_changes_can_consume_the_original_receipt () =
  with_workspace (fun config meta _ ->
    let catalog = get (Llm_provider.Model_catalog.of_toml_string ~source:"outbox-mixed-runtime-route"
      "[[models]]\nmodel_id = \"gpt-fixture\"\nprovider_name = \"http\"\nbase = \"openai_chat\"\nmax_context_tokens = 400000\nmax_output_tokens = 128\nsupports_native_streaming = false\n") in
    Llm_provider.Model_catalog.set_global catalog;
    let path = Filename.concat config.Workspace.base_path "runtime.toml" in
    let original_config = Fs_compat.load_file path in
    let oauth_path = Filename.concat config.base_path "synthetic-antigravity-oauth" in
    let muse_account_home = Filename.concat config.base_path "muse-account-home" in
    Fs_compat.save_file oauth_path (Masc_test_deps.antigravity_oauth_fixture "outbox-route-fixture");
    let additional =
      Printf.sprintf {|[providers.http]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[providers.claude]
protocol = "claude-code"
command = "/bin/false"
is-non-interactive = true
[providers.antigravity]
protocol = "antigravity-cli"
timeout-s = 60.0
command = "/bin/false"
is-non-interactive = true
[providers.antigravity.credentials]
type = "file"
path = %S
[providers.muse]
protocol = "muse-serve"
command = "/bin/false"
account-home = %S
is-non-interactive = true
[http.codex]
[claude.codex]
[antigravity.codex]
[muse.codex]
[runtime.lanes.recovery]
candidates = ["codex.codex", "http.codex", "claude.codex", "antigravity.codex", "muse.codex"]
[runtime.assignments]
result-owner = "recovery"
|} oauth_path muse_account_home in
    Fs_compat.save_file path (original_config ^ additional);
    get (Runtime.init_default ~config_path:path);
    check bool "every declared runtime candidate has original result delivery" true
      (Keeper_client_tool_outbox_wake.route_can_consume meta);
    retain config (receipt "original-codex-result");
    pulse config;
    let selection = only_selection config in
    (match get (Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config ~keeper_name selection) with
     | Selection_actionable -> ()
     | Tool_result_hint_retired | Spent_grant_replay_acknowledged | Absent_grant_retired _ ->
       fail "a mixed-runtime fallback must keep the original receipt actionable"))

let test_receipt_carrier_has_independent_held_identity () =
  with_workspace (fun config _ _ ->
    retain config (receipt "original-result");
    let original = snapshot config in
    let carried = match Keeper_client_tool_outbox.context_message original with
      | Some message -> message | None -> fail "retained original has no context message" in
    let ordinary : Agent_core.Types.message =
      {origin=System_context;role=System;content=[Text "ordinary world state"];
       name=None;tool_call_id=None;metadata=[]} in
    let module Host = Keeper_official_client_host in
    let held = Host.start_held_context [ordinary;carried] in
    check int "receipt and ordinary carrier have separate held identities" 2 (List.length held);
    check bool "receipt uses the closed result context identity" true
      (List.exists (fun (item : Keeper_official_client_session_store.held_context) ->
         item.context=Tool_result_receipts) held);
    let fresh = Host.resume_prompt ~goal:"continue original work" ~held:[] [ordinary;carried] in
    List.iter (fun text -> check bool "a replacement session receives original receipt bytes" true
      (String_util.contains_substring fresh.prompt text))
      ["effect-already-completed";"private-completed-result"];
    let changed = {ordinary with content=[Text "revised world state"]} in
    let resumed = Host.resume_prompt ~goal:"continue original work" ~held [changed;carried] in
    check bool "an independent context update remains deliverable" true
      (String_util.contains_substring resumed.prompt "revised world state");
    check bool "already-held receipt is not duplicated on resume" false
      (String_util.contains_substring resumed.prompt "private-completed-result");
    get (Keeper_client_tool_outbox.settle_after_turn original
      ~stop_reason:(Yielded_to_durable_stimulus {turns_used=1;provider_turn_ordinal=1}));
    check int "context carriage alone does not consume the receipt" 1
      (List.length (Keeper_client_tool_outbox.receipt_ids (snapshot config)));
    retain config (receipt "newer-result");
    get (Keeper_client_tool_outbox.settle_after_turn original
      ~stop_reason:(Completed {provider_turn_ordinal=2}));
    check int "completed original consumption preserves a newer result" 1
      (List.length (Keeper_client_tool_outbox.receipt_ids (snapshot config))))

let test_quiet_result_enters_the_actual_cycle_decision () =
  with_workspace (fun config meta env ->
    let meta = {meta with Keeper_meta_contract.activation_mode=Keeper_activation_mode.Autonomous} in
    retain config (receipt "turn-quiet-owner");
    notify config;
    Eio.Switch.run (fun sw ->
      let ctx : _ Keeper_types_profile.context =
        {config;agent_name="tool-result-recovery-test";sw;
         clock=Eio.Stdenv.clock env;proc_mgr=None;net=None;
         publication_recovery_provider=Masc_test_deps.non_runtime_publication_recovery_provider} in
      let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
      check int "the real intake admits exactly the result pointer" 1
        (Keeper_heartbeat_source_batch.count intake.source_batch);
      check int "receipt continuation does not fabricate Board activity" 0
        (List.length intake.pending_board_events);
      check bool "source authority is available" true
        (Option.is_none intake.event_queue_intake_error);
      let observation : Keeper_world_observation.world_observation =
        {pending_messages=[];pending_board_events=[];idle_seconds=0;active_goals=Ok [];
         unclaimed_task_count=0;claimable_tasks=[];held_task_skills=[];failed_task_count=0;
         scheduled_automation=Keeper_world_observation.empty_scheduled_automation_observation;
         approval_authority={revision=1;state=Keeper_world_observation.Approval_authority_complete;pending=[]};
         backlog_revision=Some 1;running_keeper_fiber_count=1;connected_surfaces=[];
         connected_surface_failures=[];own_recent_board_posts=[];fleet_messages=[];
         own_recent_actions=Ok []} in
      let scheduling = Keeper_heartbeat_loop.decide_keepalive_scheduling
        ~wake:Keeper_world_observation.Attention_wake
        ~event_queue_triggers:intake.event_queue_triggers
        ~stop:(Atomic.make false) ~meta observation in
      check bool "a quiet owner actually reaches a model turn" true scheduling.should_run_turn;
      check bool "cycle decision itself authorizes the continuation" true
        scheduling.turn_decision.should_run;
      check string "result delivery uses the reactive channel" "turn" scheduling.channel;
      check (list string) "the original result owns the turn reason"
        ["tool_result_ready_pending"] scheduling.verdict_reasons;
      check bool "no downstream intake error suppresses the model turn" true
        (Keeper_heartbeat_loop.should_run_turn_after_event_intake
          ~scheduled:scheduling.should_run_turn
          ~event_queue_intake_error:intake.event_queue_intake_error)))

let () =
  run "Keeper unread tool result recovery"
    ["durable continuation",[
      test_case "mixed Agent Core and official fallback keeps original receipt actionable" `Quick
        test_mixed_route_changes_can_consume_the_original_receipt;
      test_case "result data is independent from the ordinary held carrier" `Quick
        test_receipt_carrier_has_independent_held_identity;
      test_case "restart discovery is durable and deduplicated" `Quick test_restart_discovers_and_deduplicates;
      test_case "provider failure retries result delivery until exact ACK" `Quick test_failed_turn_can_be_notified_again;
      test_case "paused owner is preserved" `Quick test_paused_owner_keeps_its_result;
      test_case "unreadable result remains pending until owner repair" `Quick test_unreadable_result_is_not_consumed;
      test_case "route change preserves other work and later result recovery" `Quick
        (test_route_change_preserves_unrelated_work_and_receipt ~corrupt:false);
      test_case "corrupt receipt cannot block an unavailable route" `Quick
        (test_route_change_preserves_unrelated_work_and_receipt ~corrupt:true);
      test_case "multiple Codex candidates remain recoverable" `Quick
        test_multiple_codex_candidates_remain_recoverable;
      test_case "quiet owner consumes result through actual heartbeat scheduling" `Quick
        test_quiet_result_enters_the_actual_cycle_decision]]
