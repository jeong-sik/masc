open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_screens_core
open Masc_tui_screens_ops
open Masc_tui_screens_domain

let t0 = Clock.Mono.of_ns 1_000_000_000L
let obs v = Observed.value ~observed_at:t0 v

let mk_key ?(ctrl = false) ?(alt = false) ?(shift = false) key :
    Keymap.Input.key_event =
  { key; mods = { Keymap.Input.ctrl; alt; shift } }

let char_key ?ctrl ?alt ?shift s = mk_key ?ctrl ?alt ?shift (Keymap.Input.Char s)
let step m ev = Update.step ~now:t0 m (Msg.Key_event ev)

let step_keys m keys =
  List.fold_left
    (fun (acc_m, acc_cmds) ev ->
      let next_m, cmds = step acc_m ev in
      (next_m, acc_cmds @ cmds))
    (m, []) keys

let type_str m s =
  let n = String.length s in
  let keys = List.init n (fun i -> char_key (String.make 1 s.[i])) in
  step_keys m keys

let has_cmd pred cmds = List.exists pred (Cmd.flatten cmds)

let matrix_case_count = ref 0
let record_case () = incr matrix_case_count

(* ---------- Grid Rendering Helper (Full Chrome + Body + Overlay) ---------- *)

let grid_row_text (grid : Cell_grid.t) y =
  let cols = Cell_grid.cols grid in
  let buf = Buffer.create cols in
  for x = 0 to cols - 1 do
    let cell = Cell_grid.get grid ~x ~y in
    match cell.glyph with
    | Cell_grid.Empty -> Buffer.add_char buf ' '
    | Cell_grid.Ascii c -> Buffer.add_char buf c
    | Cell_grid.Braille mask -> Buffer.add_string buf (Cell_grid.braille_utf8 mask)
    | Cell_grid.Utf8 s -> Buffer.add_string buf s
    | Cell_grid.Continuation -> ()
  done;
  Buffer.contents buf

let grid_all_text (grid : Cell_grid.t) =
  List.init (Cell_grid.rows grid) (grid_row_text grid) |> String.concat "\n"

let render_full ~(model : Model.t) =
  let cols = model.viewport.cols in
  let rows = model.viewport.rows in
  let grid = Cell_grid.create ~cols ~rows in
  let cache = Card.Cache.create () in
  let render_body rect g =
    match Model.active_dive model with
    | Some (Nav.Dive_keeper { name; tab }) ->
        Screen_keepers.render_dive ~name ~tab ~model ~cache ~rect g
    | Some (Nav.Dive_work target) ->
        Screen_work.render_dive ~target ~model ~cache ~rect g
    | Some (Nav.Dive_knowledge target) ->
        Screen_knowledge.render_dive ~target ~model ~cache ~rect g
    | Some (Nav.Dive_infra target) ->
        Screen_infra.render_dive ~target ~model ~cache ~rect g
    | None -> (
        match model.nav.workspace with
        | Nav.Pulse -> Screen_pulse.render ~model ~cache ~rect g
        | Nav.Work -> Screen_work.render ~model ~cache ~rect g
        | Nav.Knowledge -> Screen_knowledge.render ~model ~cache ~rect g
        | Nav.Keepers -> Screen_keepers.render ~model ~cache ~rect g
        | Nav.Runtime -> Screen_runtime.render ~model ~cache ~rect g
        | Nav.Infra -> Screen_infra.render ~model ~cache ~rect g)
  in
  let render_overlay rect g = Overlays.render ~model ~cache ~rect g in
  ignore (Chrome.render_frame ~model ~cache ~render_body ~render_overlay grid);
  grid

(* ---------- Rich Populated Model Fixture ---------- *)

let mk_keeper ~name ~company ~health : Wire_fleet.keeper_summary =
  {
    name;
    group = Some company;
    company;
    health;
    paused = (match health with Wire_fleet.Keeper_paused -> true | _ -> false);
    keepalive_running = true;
    activation_mode = Wire_fleet.Activation_autonomous;
    runtime_id = "lane-primary";
    model_id = Some "claude-sonnet-4";
    current_task_id = Some "task-1";
    context_ratio = obs 0.45;
    total_turns = obs 84;
    total_tokens = obs 120_000;
    cost_24h_usd = obs 1.25;
    last_turn_at_unix = Some 1700000000.0;
    active_turn = None;
    activity_sparkline_24h = [ 1.0; 2.0; 4.0; 3.0 ];
  }

let mk_goal ~id ~title ~phase : Wire_work.goal =
  {
    id;
    title;
    phase;
    priority = 1;
    due_date = Some "2026-12-01";
    measure = "100% matrix pass";
    procedure = "Run dune runtest";
    criterion_revision = Some "rev-1";
    criterion_verdict = Wire_work.Criterion_valid;
    last_review_note = None;
    last_review_at = None;
    created_at = Some "2026-11-20T00:00:00Z";
    updated_at = Some "2026-11-22T00:00:00Z";
    linked_task_count = obs 1;
  }

let mk_task ~id ~title ~goal_id : Wire_work.task =
  {
    id;
    title;
    description = Some ("Description for " ^ title);
    priority = 1;
    status =
      Wire_work.InProgress
        { assignee = "alpha"; started_at = "2026-11-22T00:00:00Z" };
    goal_link =
      (match goal_id with
       | Some g -> Wire_work.Linked g
       | None -> Wire_work.Unlinked);
    created_at = Some "2026-11-22T00:00:00Z";
    updated_at = Some "2026-11-22T01:00:00Z";
  }

let mk_verif ~req_id ~task_id ~title : Wire_work.verification_request =
  {
    request_id = req_id;
    task_id;
    task_title = title;
    submitted_by = "alpha";
    created_at_unix = Some 1700000000.0;
    completion_contract = [ "dune runtest passes" ];
    required_artifacts = [ "report.md" ];
    submitted_evidence = [ "all green" ];
    evidence_projection_error = None;
    review_observation = None;
  }

let mk_schedule ~id ~name ~keeper : Wire_work.schedule_row =
  {
    schedule_instance_id = id;
    schedule_id = name;
    status = Wire_work.Sched_scheduled;
    source = "toml";
    due_at_unix = 1700003600.0;
    next_due_at_unix = Some 1700007200.0;
    recurrence_kind = "cron";
    recurrence_summary = "*/15 * * * *";
    payload_kind = Some "keeper_prompt";
    payload_support = "supported";
    payload_target = Some keeper;
    payload_keeper_name = Some keeper;
    payload_summary = Some ("Check health for " ^ name);
    last_wake_unix = Some 1700000000.0;
    last_disposition = Wire_work.Wake_succeeded;
  }

let mk_post ~id ~title ~author ~signal : Wire_knowledge.board_post =
  {
    id;
    title;
    body =
      "Body line 1\nBody line 2\nBody line 3\nBody line 4\nBody line 5\nBody \
       line 6\nBody line 7\nBody line 8";
    author;
    hearth = Some "engineering";
    post_kind = Some Wire_knowledge.Human_post;
    visibility = Some Wire_knowledge.Vis_public;
    created_at_unix = 1700000000.0;
    updated_at_unix = Some 1700000100.0;
    score = 5;
    comment_count = 2;
    author_karma = obs 42;
    succession_chain_root_id = None;
    chain_depth = None;
    is_signal = signal;
  }

let mk_wiki_summary ~slug ~title : Wire_knowledge.wiki_page_summary =
  {
    slug;
    file = slug ^ ".md";
    title;
    summary = "Summary of " ^ title;
    source = Wire_knowledge.Source_direct_experience;
    author = "alpha";
    created = "2026-11-20";
    updated = "2026-11-22";
    revision = 3;
    tags = [ "architecture" ];
    backlink_count = 2;
    outgoing_link_count = 1;
    sources_count = 2;
    hearsay_count = 0;
    sha256 = "sha-" ^ slug;
  }

let mk_wiki_detail ~slug ~title : Wire_knowledge.wiki_page_detail =
  {
    page = slug;
    slug;
    file = "wiki/" ^ slug ^ ".md";
    frontmatter =
      {
        title;
        summary = "Summary of " ^ title;
        source = Wire_knowledge.Source_direct_experience;
        author = "alpha";
        created = "2026-11-20";
        updated = "2026-11-22";
        revision = 3;
        tags = [ "architecture" ];
      };
    sha256 = "sha-" ^ slug;
    body_markdown =
      "# " ^ title
      ^ "\n\nLine 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine \
         8\nLine 9\nLine 10";
    backlinks = [ "runbook" ];
    outgoing_links = [];
    lint_findings = [];
  }

let empty_wiki_lint : Wire_knowledge.wiki_index_lint =
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

let populated_model ?(cols = 140) ?(rows = 40) ?(lang = Say.Lang_en)
    ?(with_attention = true) () : Model.t =
  let m0 = Model.initial ~cols ~rows ~lang () in
  let keepers =
    [
      mk_keeper ~name:"alpha" ~company:"platform"
        ~health:Wire_fleet.Keeper_working;
      mk_keeper ~name:"beta" ~company:"platform"
        ~health:Wire_fleet.Keeper_healthy;
      mk_keeper ~name:"gamma" ~company:"ops" ~health:Wire_fleet.Keeper_idle;
    ]
  in
  let chat_page : Wire_fleet.chat_history_page =
    {
      messages =
        List.init 32 (fun i : Wire_fleet.chat_message ->
            {
              id = Printf.sprintf "msg-%d" i;
              role =
                (if i mod 2 = 0 then Wire_fleet.Role_user
                 else Wire_fleet.Role_assistant);
              content =
                Printf.sprintf
                  "Message content line %d for alpha with enough detail to \
                   verify chat transcript scrolling"
                  i;
              ts_unix = 1700000000.0 +. float_of_int (i * 10);
              turn_ref = None;
              model_used = Some "claude-sonnet-4";
              tool_call_id = None;
              tool_call_name = None;
              execution_id = None;
            });
      has_more = false;
      next_cursor = None;
    }
  in
  let fleet =
    Fleet_store.empty
    |> Fleet_store.apply_keepers ~observed_at:t0 keepers
    |> Fleet_store.apply_chat_history ~observed_at:t0 ~keeper:"alpha" chat_page
  in
  let asks : Wire_work.ask_row list =
    if not with_attention then []
    else
      [
        {
          ask_id = "ask-1";
          keeper = "alpha";
          asked_at = 1700000010.0;
          context = Some "Plan A details";
          questions =
            [
              {
                question_id = "q-1";
                header = "Plan A";
                prompt = "Approve plan A?";
                mode = Wire_work.Ask_single;
                allow_free_text = false;
                free_text_hint = None;
                choices =
                  [
                    { choice_id = "yes"; label = "Yes"; description = None };
                    { choice_id = "no"; label = "No"; description = None };
                  ];
              };
            ];
          resolution = Wire_work.Ask_open;
        };
        {
          ask_id = "ask-2";
          keeper = "beta";
          asked_at = 1700000020.0;
          context = Some "Plan B details";
          questions =
            [
              {
                question_id = "q-2";
                header = "Plan B";
                prompt = "Approve plan B?";
                mode = Wire_work.Ask_single;
                allow_free_text = false;
                free_text_hint = None;
                choices =
                  [
                    { choice_id = "ship"; label = "Ship"; description = None };
                    { choice_id = "hold"; label = "Hold"; description = None };
                  ];
              };
            ];
          resolution = Wire_work.Ask_open;
        };
      ]
  in
  let tool_approvals : Wire_work.held_tool_approval list =
    if not with_attention then []
    else
      [
        {
          approval_id = "appr-1";
          tool_call_id = "tc-1";
          keeper = "alpha";
          tool = "bash";
          args_preview = "dune runtest";
          question = "Allow bash tool?";
          because = Some "verification";
          asked_at = 1700000005.0;
          timeout_sec = 300.0;
        };
      ]
  in
  let gate_pending : Wire_work.gate_pending list =
    if not with_attention then []
    else
      [
        {
          id = "gate-1";
          keeper = "gamma";
          tool_name = "deploy";
          input_preview = Some "staging";
          waiting_s = Some 12.0;
          phase = "pending";
        };
      ]
  in
  let goals =
    [
      mk_goal ~id:"goal-1" ~title:"Harden TUI Matrix" ~phase:Wire_work.Executing;
      mk_goal ~id:"goal-2" ~title:"Confirm Deployment"
        ~phase:Wire_work.Awaiting_confirmation;
      mk_goal ~id:"goal-3" ~title:"Paused Migration"
        ~phase:(Wire_work.Paused Wire_work.Resume_executing);
      mk_goal ~id:"goal-4" ~title:"Shipped Cleanup" ~phase:Wire_work.Completed;
    ]
  in
  let tasks =
    [
      mk_task ~id:"task-1" ~title:"Build slash popup" ~goal_id:(Some "goal-1");
      mk_task ~id:"task-2" ~title:"Fix Tab focus" ~goal_id:(Some "goal-1");
      mk_task ~id:"task-3" ~title:"Unlinked audit" ~goal_id:None;
    ]
  in
  let verifs =
    [
      mk_verif ~req_id:"verif-1" ~task_id:"task-1" ~title:"Build slash popup";
      mk_verif ~req_id:"verif-2" ~task_id:"task-2" ~title:"Fix Tab focus";
      mk_verif ~req_id:"verif-3" ~task_id:"task-3" ~title:"Unlinked audit";
    ]
  in
  let schedules =
    [
      mk_schedule ~id:"sched-1" ~name:"nightly-check" ~keeper:"alpha";
      mk_schedule ~id:"sched-2" ~name:"hourly-sync" ~keeper:"beta";
    ]
  in
  let candle_ledger : Wire_work.candle_ledger =
    {
      ledger_state = Wire_work.Ledger_present;
      total_events = 2;
      balance_error = None;
      policy_configuration = "default";
      pricing_mode = "standard";
      disabled_reason = None;
      half_life_sec = Some 86400.0;
      issued_milli = "200000";
      burned_milli = "12500";
      circulating_milli = "187500";
      total_supply_milli = "200000";
      active_keepers = 2;
      diagnostics =
        {
          unattributed_count = 0;
          backlog_fenced_count = 0;
          zero_linked_tasks_goals = 0;
          held_windows_count = 0;
        };
      balances =
        [
          {
            keeper = "alpha";
            balance_milli = 120500;
            decayed_milli = "500";
            last_event_unix = Some 1700000000.0;
            owned_items = [];
          };
          {
            keeper = "beta";
            balance_milli = 80000;
            decayed_milli = "200";
            last_event_unix = Some 1700000000.0;
            owned_items = [];
          };
        ];
      recent_events = [];
    }
  in
  let work =
    Work_store.empty
    |> Work_store.apply_planning ~observed_at:t0 { goals; tasks }
    |> Work_store.apply_verifications ~observed_at:t0 verifs
    |> Work_store.apply_schedules ~observed_at:t0 (schedules, None)
    |> Work_store.apply_asks ~observed_at:t0 asks
    |> Work_store.apply_tool_approvals ~observed_at:t0 tool_approvals
    |> Work_store.apply_gate_pending ~observed_at:t0 gate_pending
    |> Work_store.apply_candle_ledger ~observed_at:t0 candle_ledger
  in
  let posts =
    [
      mk_post ~id:"post-1" ~title:"Signal Thread Alpha" ~author:"alpha"
        ~signal:true;
      mk_post ~id:"post-2" ~title:"Signal Thread Beta" ~author:"beta"
        ~signal:true;
      mk_post ~id:"post-3" ~title:"Routine Heartbeat" ~author:"gamma"
        ~signal:false;
    ]
  in
  let wiki_pages =
    [
      mk_wiki_summary ~slug:"arch-overview" ~title:"Architecture Overview";
      mk_wiki_summary ~slug:"runbook" ~title:"Operations Runbook";
    ]
  in
  let artifacts : Wire_knowledge.artifact_entry list =
    [
      {
        sha256 = "aaaa1111bbbb2222";
        name = "matrix-report.md";
        mime_type = "text/markdown";
        bytes = 4096;
        created_at_unix = Some 1700000000.0;
        producer = Some "alpha";
        title = Some "Matrix Report";
      };
      {
        sha256 = "cccc3333dddd4444";
        name = "perf-trace.json";
        mime_type = "application/json";
        bytes = 8192;
        created_at_unix = Some 1700000100.0;
        producer = Some "beta";
        title = Some "Perf Trace";
      };
    ]
  in
  let conflicts : Wire_knowledge.memory_conflict list =
    [
      {
        conflict_id = "conf-1";
        description = "Cache TTL disagreement";
        member_count = 2;
        competing_claims = [];
      };
      {
        conflict_id = "conf-2";
        description = "Port binding preference";
        member_count = 2;
        competing_claims = [];
      };
    ]
  in
  let world_memory : Wire_knowledge.world_memory =
    {
      ledger_state = Wire_knowledge.World_ledger_available;
      ledger_sha256 = Some "deadbeef";
      claims_count = 2;
      facts_count = 10;
      conflicts_count = 2;
      excluded_count = 0;
      claims =
        [
          {
            claim_id = "cl-1";
            claim = "Cache TTL is 60s";
            stage = "accepted";
            supporting_keepers = [ "alpha" ];
            support_count = 1;
            has_source_bound = true;
          };
        ];
      active_conflicts = conflicts;
      briefing =
        {
          status = Wire_knowledge.Briefing_current;
          text = Some "All systems nominal";
          source_ids_count = 3;
          error = None;
          building_pass = None;
        };
      librarian_writers = Wire_knowledge.Writers_none_in_process;
      ordinary_absence_detail = None;
    }
  in
  let memory_diff : Wire_knowledge.memory_diff =
    {
      scope = Wire_knowledge.Scope_world;
      range =
        {
          window = Some "24h";
          from_rev = Some 1;
          to_rev = Some 3;
          from_unix = None;
          to_unix = None;
        };
      retrieval_heat =
        {
          hot = 3;
          warm = 2;
          cold = 1;
          never_retrieved = 0;
          total_events = 6;
          unreadable_event_lines = 0;
        };
      body =
        Wire_knowledge.World_diff
          {
            counts =
              {
                total_claims_now = 5;
                added = 2;
                updated = 0;
                retracted = 0;
                incomplete_batches = 0;
                aborted_batches = 0;
              };
            unparseable_timestamps = 0;
            revisions = [];
            added =
              [
                {
                  seq = 1;
                  batch_id = "b-1";
                  fact_id = "f-1";
                  summary = "Added cache policy";
                  recorded_at = "2026-11-22T10:00:00Z";
                  payload = `Null;
                };
                {
                  seq = 2;
                  batch_id = "b-2";
                  fact_id = "f-2";
                  summary = "Added failover route";
                  recorded_at = "2026-11-22T10:05:00Z";
                  payload = `Null;
                };
              ];
            updated = [];
            retracted = [];
          };
    }
  in
  let knowledge =
    Knowledge_store.empty
    |> Knowledge_store.apply_board ~observed_at:t0
         {
           posts;
           count = List.length posts;
           sort_by = "recent";
           signal_only = true;
         }
    |> Knowledge_store.apply_wiki_index ~observed_at:t0
         {
           pages_total = 2;
           pages_readable = 2;
           pages_unreadable = 0;
           pages = wiki_pages;
           unreadable_pages = [];
           lint = empty_wiki_lint;
         }
    |> Knowledge_store.apply_artifacts ~observed_at:t0 artifacts
    |> Knowledge_store.apply_world_memory ~observed_at:t0 world_memory
    |> Knowledge_store.apply_memory_diff ~observed_at:t0 memory_diff
  in
  let usage_windows : Wire_runtime.provider_usage_windows =
    {
      since_unix = 1700000000.0;
      accounts =
        [
          {
            scope = "anthropic";
            scope_id = "anth-main";
            providers = [ { id = "anthropic"; display_name = "Anthropic" } ];
            state =
              Wire_runtime.Account_reported
                [
                  {
                    limit_id = Some "5h";
                    kind = Wire_runtime.Window_five_hour;
                    role = Wire_runtime.Role_gates_model_calls;
                    utilization = Wire_runtime.Util_percent 35;
                    resets_at_unix = Some 1700018000.0;
                    observed_at_unix = 1700000000.0;
                  };
                  {
                    limit_id = Some "7d";
                    kind = Wire_runtime.Window_seven_day;
                    role = Wire_runtime.Role_gates_model_calls;
                    utilization = Wire_runtime.Util_percent 55;
                    resets_at_unix = Some 1700600000.0;
                    observed_at_unix = 1700000000.0;
                  };
                ];
            cost_state = Format_val.Subscription_zero;
          };
          {
            scope = "openai";
            scope_id = "oai-credits";
            providers = [ { id = "openai"; display_name = "OpenAI" } ];
            state =
              Wire_runtime.Account_reported
                [
                  {
                    limit_id = Some "credits";
                    kind = Wire_runtime.Window_provider_label "Credits";
                    role = Wire_runtime.Role_gates_model_calls;
                    utilization =
                      Wire_runtime.Util_credit_balance
                        { currency = "USD"; total = Some 100.0; remaining = 42.0 };
                    resets_at_unix = None;
                    observed_at_unix = 1700000000.0;
                  };
                ];
            cost_state = Format_val.Amount 42.0;
          };
        ];
    }
  in
  let runtime_resolved : Wire_runtime.runtime_resolved_snapshot =
    {
      generated_at_iso = "2026-11-22T00:00:00Z";
      config_path = Some "config/runtime.toml";
      default_route = Some "lane-primary";
      lanes =
        [
          {
            id = "lane-primary";
            declared = true;
            runtime_ids = [ "claude-sonnet-4"; "gpt-5" ];
          };
          {
            id = "lane-fallback";
            declared = true;
            runtime_ids = [ "gpt-5" ];
          };
        ];
      runtimes =
        [
          {
            id = "claude-sonnet-4";
            provider_id = "anthropic";
            provider = "anthropic";
            model = Some "claude-sonnet-4";
            declared_reasoning_effort = None;
            transport = Some "https";
            is_default = true;
          };
          {
            id = "gpt-5";
            provider_id = "openai";
            provider = "openai";
            model = Some "gpt-5";
            declared_reasoning_effort = None;
            transport = Some "https";
            is_default = false;
          };
        ];
      usage_windows = Some usage_windows;
    }
  in
  let tools : Wire_runtime.tool_summary list =
    [
      {
        name = "read_file";
        description = Some "Read file";
        calls_24h = obs 120;
        failure_rate_pct = obs 0.0;
      };
      {
        name = "edit_file";
        description = Some "Edit file";
        calls_24h = obs 45;
        failure_rate_pct = obs 2.0;
      };
      {
        name = "run_command";
        description = Some "Shell exec";
        calls_24h = obs 30;
        failure_rate_pct = obs 5.0;
      };
    ]
  in
  let connectors : Wire_runtime.connector_row list =
    [
      {
        connector_id = "slack-eng";
        display_name = "Slack #eng";
        connection = Wire_runtime.Connector_connected;
        channel = Some "eng";
        error = None;
        binding_count = 2;
      };
      {
        connector_id = "discord-ops";
        display_name = "Discord #ops";
        connection = Wire_runtime.Connector_connected;
        channel = Some "ops";
        error = None;
        binding_count = 1;
      };
      {
        connector_id = "github-webhook";
        display_name = "GitHub Hooks";
        connection = Wire_runtime.Connector_stale;
        channel = None;
        error = Some "slow poll";
        binding_count = 3;
      };
    ]
  in
  let runtime =
    Runtime_store.empty
    |> Runtime_store.apply_runtime_resolved ~observed_at:t0 runtime_resolved
    |> Runtime_store.apply_tools_catalog ~observed_at:t0 tools
    |> Runtime_store.apply_connectors ~observed_at:t0 connectors
  in
  let zero_metrics : Wire_infra.tool_metrics_24h =
    {
      calls = 10;
      failures = 0;
      failure_unclassified = 0;
      p50_ms = obs 12.0;
      p95_ms = obs 25.0;
      max_ms = obs 40.0;
      failure_classes =
        {
          dependency_unavailable = 0;
          runtime_failure = 0;
          policy_rejection = 0;
          workflow_rejection = 0;
          operator_cancelled = 0;
        };
    }
  in
  let sandboxes : Wire_infra.sandboxes_snapshot =
    {
      probe_state = Wire_infra.Probe_fresh 1700000000.0;
      microvm_declared = 1;
      microvm_running = 1;
      microvm_sockets_present = 1;
      microvm_shim_mismatch = 0;
      ssh_pools_count = 1;
      ssh_keepers_count = 1;
      ssh_unbound_keepers_count = 0;
      ssh_active_sessions = obs 1;
      ssh_max_sessions = 4;
      docker_keepers_count = 1;
      microvm_guests =
        [
          {
            keeper = "alpha";
            backend = "apple_container";
            guest_name = "vm-alpha";
            presence = "running";
            agent_socket =
              Wire_infra.Socket_present { path_basename = Some "agent.sock" };
            shim_parity = Wire_infra.Shim_matched "aaa";
            network_mode = Wire_infra.Net_inherit;
            cpus = obs 2;
            memory_mib = obs 2048;
            volume = Wire_infra.Volume_declared "/workspace";
            metrics_24h = zero_metrics;
          };
        ];
      ssh_pools =
        [
          {
            pool_name = "gpu-pool";
            host = "10.0.0.5";
            port = 22;
            unix_user = "keeper";
            remote_root = "/srv";
            private_home = true;
            max_sessions = 4;
            active_sessions = obs 1;
            reachability =
              Wire_infra.Ssh_reachable
                { rtt_ms = 4.2; measured_at_unix = 1700000000.0 };
            accounts =
              [
                {
                  unix_user = "keeper";
                  active_sessions = obs 1;
                  max_sessions = 4;
                  keepers = [ "beta" ];
                };
              ];
            keeper_sessions =
              [
                {
                  keeper = "beta";
                  last_dispatch = `Assoc [ ("status", `String "ok") ];
                  metrics_24h = zero_metrics;
                };
              ];
            metrics_24h = zero_metrics;
          };
        ];
      ssh_unbound_keepers = [];
      docker_keepers =
        [
          {
            keeper = "gamma";
            backend = "docker";
            network_mode = Wire_infra.Net_none;
            metrics_24h = zero_metrics;
          };
        ];
      fleet_metrics_24h = zero_metrics;
      volume_gc_report = None;
      host_storage = None;
      unobserved_reasons = [];
    }
  in
  let repos : Wire_infra.repository list =
    [
      {
        id = "repo-masc";
        name = "masc";
        codebase = None;
        url = "https://example.invalid/masc";
        local_path = "/workspace/masc";
        default_branch = "main";
        auto_sync = true;
        status = Wire_infra.Repo_synced;
        keepers = [ "alpha"; "beta" ];
      };
      {
        id = "repo-docs";
        name = "masc-docs";
        codebase = None;
        url = "https://example.invalid/masc-docs";
        local_path = "/workspace/masc-docs";
        default_branch = "main";
        auto_sync = false;
        status = Wire_infra.Repo_dirty;
        keepers = [ "gamma" ];
      };
    ]
  in
  let file_changes : Wire_infra.file_change list =
    [
      {
        path = "lib/masc_tui/keymap/keymap.ml";
        kind = Wire_infra.File_modified;
        additions = obs 12;
        deletions = obs 3;
        keeper = Some "alpha";
        diff_preview =
          Some
            "@@ -1,3 +1,5 @@\n let x = 1\n+let y = 2\n+let z = 3\n let a = 4\n \
             let b = 5\n let c = 6";
      };
      {
        path = "lib/masc_tui/store/update_nav.ml";
        kind = Wire_infra.File_modified;
        additions = obs 20;
        deletions = obs 4;
        keeper = Some "beta";
        diff_preview = Some "@@ -10,2 +10,3 @@\n let f = 1\n+let g = 2";
      };
      {
        path = "docs/TUI-GUIDE.md";
        kind = Wire_infra.File_added;
        additions = obs 30;
        deletions = obs 0;
        keeper = Some "gamma";
        diff_preview = Some "@@ -0,0 +1,2 @@\n+# Guide\n+Updated";
      };
    ]
  in
  let logs : Wire_infra.system_log_entry list =
    [
      {
        seq = 1;
        ts = "2026-11-22T10:00:00Z";
        level = Wire_infra.Log_info;
        source = "server";
        module_name = "http";
        message = "Started server";
        keeper = Some "alpha";
        turn_id = Some 1;
        category = Some "boot";
        details = `Assoc [ ("port", `Int 8935); ("host", `String "127.0.0.1") ];
      };
      {
        seq = 2;
        ts = "2026-11-22T10:01:00Z";
        level = Wire_infra.Log_warn;
        source = "sandbox";
        module_name = "vm";
        message = "High memory usage";
        keeper = Some "beta";
        turn_id = Some 2;
        category = Some "perf";
        details = `Assoc [ ("rss_mb", `Int 512) ];
      };
    ]
  in
  let infra =
    Infra_store.empty
    |> Infra_store.apply_sandboxes ~observed_at:t0 sandboxes
    |> Infra_store.apply_repositories ~observed_at:t0 repos
    |> Infra_store.apply_file_changes ~observed_at:t0 file_changes
    |> Infra_store.apply_log_snapshot logs
  in
  let incidents, _ =
    let inc1, _ =
      Incidents.push ~occurred_at_unix:1700000000.0
        ~source:(Health.Source_keeper "alpha") ~status:Health.Resolved
        ~summary:(Say.literal "Timeout recovered")
        ~detail:"Recovered after retry" Incidents.empty
    in
    Incidents.push ~occurred_at_unix:1700000100.0
      ~source:(Health.Source_runtime "anthropic") ~status:Health.Retried
      ~summary:(Say.literal "429 backoff") ~detail:"Retried after 2s" inc1
  in
  let attention =
    if not with_attention then Attention.empty
    else
      Attention.rebuild ~asks ~tool_approvals ~gate_pending ~goals
        ~quarantines:[] Attention.empty
  in
  let cfg_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "snap-1";
      sections =
        [
          {
            id = "models";
            category = Wire_config.Cat_providers_models;
            title = "Models";
            fields =
              [
                {
                  table = "models";
                  key = "default_lane";
                  full_key = "models.default_lane";
                  label = "Default Lane";
                  env = None;
                  description = Some "Primary runtime lane";
                  kind = Wire_config.Field_string;
                  value = Wire_config.Val_string "lane-primary";
                  default_value = Some (Wire_config.Val_string "lane-primary");
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
  let config =
    Config_store.empty
    |> Config_store.apply_schema ~observed_at:t0 cfg_schema
  in
  {
    m0 with
    fleet;
    work;
    knowledge;
    runtime;
    infra;
    incidents;
    attention;
    config;
    drafts = Drafts.set_active_keeper "alpha" m0.drafts;
  }

(* ---------- 1. Axis A x C: 34 Screen/Dive Contexts x 20 Keys = 680 Cases ---------- *)

let test_axis_a_screen_dive_matrix () =
  let base = populated_model ~cols:140 ~rows:40 () in
  let base_no_attn =
    populated_model ~cols:140 ~rows:40 ~with_attention:false ()
  in
  let base_compact = populated_model ~cols:90 ~rows:28 () in
  let base_micro = populated_model ~cols:60 ~rows:18 () in
  let with_ws ?(zoomed = false) ws (m : Model.t) =
    {
      m with
      nav =
        {
          m.nav with
          workspace = ws;
          dive_stack = [];
          overlay = None;
          pane_index = 0;
          zoomed;
        };
    }
  in
  let with_dive d (m : Model.t) =
    {
      m with
      nav = { m.nav with dive_stack = [ d ]; overlay = None; pane_index = 0 };
    }
  in
  let contexts : (string * Model.t) list =
    [
      ("Pulse/Wide+Attn", with_ws Nav.Pulse base);
      ("Pulse/Wide-NoAttn", with_ws Nav.Pulse base_no_attn);
      ("Pulse/Compact", with_ws Nav.Pulse base_compact);
      ("Pulse/Micro", with_ws Nav.Pulse base_micro);
      ( "Work/Pipeline/Wide"
      , {
          (with_ws Nav.Work base) with
          work = Work_store.set_tab Nav.Work_pipeline base.work;
        } );
      ( "Work/Pipeline/Zoom"
      , {
          (with_ws ~zoomed:true Nav.Work base) with
          work = Work_store.set_tab Nav.Work_pipeline base.work;
        } );
      ( "Work/Tasks/Wide"
      , {
          (with_ws Nav.Work base) with
          work = Work_store.set_tab Nav.Work_tasks_schedules base.work;
        } );
      ( "Work/Inbox/Wide"
      , {
          (with_ws Nav.Work base) with
          work = Work_store.set_tab Nav.Work_inbox base.work;
        } );
      ( "Work/Candle/Wide"
      , {
          (with_ws Nav.Work base) with
          work = Work_store.set_tab Nav.Work_candle_scorecard base.work;
        } );
      ( "Knowledge/Board/Wide"
      , {
          (with_ws Nav.Knowledge base) with
          knowledge = Knowledge_store.set_tab Nav.Knowledge_board base.knowledge;
        } );
      ( "Knowledge/Wiki/Wide"
      , {
          (with_ws Nav.Knowledge base) with
          knowledge =
            Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts base.knowledge;
        } );
      ( "Knowledge/Artifacts/Wide"
      , {
          (with_ws Nav.Knowledge base) with
          knowledge =
            base.knowledge
            |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts
            |> Knowledge_store.toggle_wiki_artifacts_submode;
        } );
      ( "Knowledge/Memory/Wide"
      , {
          (with_ws Nav.Knowledge base) with
          knowledge =
            Knowledge_store.set_tab Nav.Knowledge_memory base.knowledge;
        } );
      ("Keepers/WideSplit", with_ws Nav.Keepers base);
      ("Keepers/Compact", with_ws Nav.Keepers base_compact);
      ("Keepers/Zoomed", with_ws ~zoomed:true Nav.Keepers base);
      ( "Runtime/Quotas/Wide"
      , {
          (with_ws Nav.Runtime base) with
          runtime =
            Runtime_store.set_tab Nav.Runtime_quotas_credits base.runtime;
        } );
      ( "Runtime/Efficiency/Wide"
      , {
          (with_ws Nav.Runtime base) with
          runtime =
            Runtime_store.set_tab Nav.Runtime_efficiency_spend base.runtime;
        } );
      ( "Runtime/Failover/Wide"
      , {
          (with_ws Nav.Runtime base) with
          runtime =
            Runtime_store.set_tab Nav.Runtime_failover_lanes base.runtime;
        } );
      ( "Runtime/Tools/Wide"
      , {
          (with_ws Nav.Runtime base) with
          runtime =
            Runtime_store.set_tab Nav.Runtime_tools_connectors base.runtime;
        } );
      ( "Infra/Sandboxes/Wide"
      , {
          (with_ws Nav.Infra base) with
          infra = Infra_store.set_tab Nav.Infra_sandboxes base.infra;
        } );
      ( "Infra/Sandboxes/Compact"
      , {
          (with_ws Nav.Infra base_compact) with
          infra = Infra_store.set_tab Nav.Infra_sandboxes base_compact.infra;
        } );
      ( "Infra/Repos/Wide"
      , {
          (with_ws Nav.Infra base) with
          infra = Infra_store.set_tab Nav.Infra_repos_changes base.infra;
        } );
      ( "Infra/Logs/Wide"
      , {
          (with_ws Nav.Infra base) with
          infra = Infra_store.set_tab Nav.Infra_activity_logs base.infra;
        } );
      ( "Dive/Keeper/Chat"
      , with_dive
          (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat })
          (with_ws Nav.Keepers base) );
      ( "Dive/Keeper/Memory"
      , with_dive
          (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory })
          (with_ws Nav.Keepers base) );
      ( "Dive/Keeper/Work"
      , with_dive
          (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_work_candle })
          (with_ws Nav.Keepers base) );
      ( "Dive/Keeper/Sandbox"
      , with_dive
          (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_sandbox })
          (with_ws Nav.Keepers base) );
      ( "Dive/Keeper/Config"
      , with_dive
          (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_config })
          (with_ws Nav.Keepers base) );
      ( "Dive/Work/Goal"
      , with_dive
          (Nav.Dive_work (Nav.Goal_dive "goal-1"))
          (with_ws Nav.Work base) );
      ( "Dive/Work/Task"
      , with_dive
          (Nav.Dive_work (Nav.Task_dive "task-1"))
          (with_ws Nav.Work base) );
      ( "Dive/Knowledge/Thread"
      , with_dive
          (Nav.Dive_knowledge (Nav.Thread_dive "post-1"))
          (with_ws Nav.Knowledge base) );
      ( "Dive/Knowledge/Wiki"
      , with_dive
          (Nav.Dive_knowledge (Nav.Wiki_dive "arch-overview"))
          (with_ws Nav.Knowledge base) );
      ( "Dive/Infra/Sandbox"
      , with_dive
          (Nav.Dive_infra (Nav.Sandbox_dive "alpha"))
          (with_ws Nav.Infra base) );
    ]
  in
  let keys : (string * Keymap.Input.key_event) list =
    [
      ("Tab", mk_key Keymap.Input.Tab);
      ("Shift+Tab", mk_key ~shift:true Keymap.Input.Tab);
      ("Up", mk_key Keymap.Input.Up);
      ("Down", mk_key Keymap.Input.Down);
      ("Left", mk_key Keymap.Input.Left);
      ("Right", mk_key Keymap.Input.Right);
      ("PgUp", mk_key Keymap.Input.Page_up);
      ("PgDn", mk_key Keymap.Input.Page_down);
      ("Home", mk_key Keymap.Input.Home);
      ("End", mk_key Keymap.Input.End);
      ("Enter", mk_key Keymap.Input.Enter);
      ("Esc", mk_key Keymap.Input.Escape);
      ("/", char_key "/");
      ("Space", char_key " ");
      ("n", char_key "n");
      ("f", char_key "f");
      ("o", char_key "o");
      ("y", char_key "y");
      ("a", char_key "a");
      ("x", char_key "x");
    ]
  in
  Alcotest.(check int) "Axis A contexts" 34 (List.length contexts);
  Alcotest.(check int) "Axis C keys" 20 (List.length keys);
  List.iter
    (fun (ctx_name, (m : Model.t)) ->
      let panes_before = Model.focusable_pane_count m in
      let dive_before = Model.active_dive m in
      let depth_before = List.length m.nav.dive_stack in
      let is_micro = Model.equal_breakpoint m.breakpoint Model.Micro in
      List.iter
        (fun (kname, ev) ->
          record_case ();
          let tag = Printf.sprintf "[%s x %s]" ctx_name kname in
          let m', cmds = step m ev in
          (* Invariant 1: pane_index strictly within focusable_pane_count *)
          let panes_after = Int.max 1 (Model.focusable_pane_count m') in
          Alcotest.(check bool)
            (tag ^ " pane_index in bounds")
            true
            (m'.nav.pane_index >= 0 && m'.nav.pane_index < panes_after);
          (* Invariant 2: Tab / Shift+Tab exact cycling vs no-op *)
          if String.equal kname "Tab" then begin
            let expected =
              if panes_before <= 1 then 0
              else (m.nav.pane_index + 1) mod panes_before
            in
            Alcotest.(check int) (tag ^ " Tab pane_index") expected
              m'.nav.pane_index
          end;
          if String.equal kname "Shift+Tab" then begin
            let expected =
              if panes_before <= 1 then 0
              else (m.nav.pane_index - 1 + panes_before) mod panes_before
            in
            Alcotest.(check int)
              (tag ^ " Shift+Tab pane_index")
              expected m'.nav.pane_index
          end;
          (* Invariant 3: Enter inside any Dive never pushes duplicate/nested dive *)
          if String.equal kname "Enter" && Option.is_some dive_before then
            Alcotest.(check bool)
              (tag ^ " Dive Enter never deepens dive_stack")
              true
              (List.length m'.nav.dive_stack <= depth_before);
          (* Invariant 4: Zero invisible filter traps on '/' *)
          if String.equal kname "/" then begin
            if is_micro then
              Alcotest.(check bool) (tag ^ " Micro '/' never focuses filter")
                false m'.nav.filter_focused
            else
              match dive_before with
              | Some (Nav.Dive_keeper { tab = Nav.Keeper_config; _ }) ->
                  Alcotest.(check bool)
                    (tag ^ " Keeper_config '/' focuses filter")
                    true m'.nav.filter_focused
              | Some _ ->
                  Alcotest.(check bool)
                    (tag ^ " Non-config dive '/' never traps filter")
                    false m'.nav.filter_focused;
                  Alcotest.(check bool)
                    (tag ^ " Non-config dive '/' focuses composer with '/'")
                    true
                    (Drafts.is_focused m'.drafts
                     && String.equal (Drafts.current_draft m'.drafts).text "/")
              | None when Nav.equal_workspace m.nav.workspace Nav.Pulse ->
                  Alcotest.(check bool)
                    (tag ^ " Pulse '/' never traps invisible filter")
                    false m'.nav.filter_focused;
                  Alcotest.(check bool)
                    (tag ^ " Pulse '/' focuses composer with '/'")
                    true
                    (Drafts.is_focused m'.drafts
                     && String.equal (Drafts.current_draft m'.drafts).text "/")
              | None ->
                  Alcotest.(check bool)
                    (tag ^ " List workspace '/' focuses filter")
                    true m'.nav.filter_focused
          end;
          (* Invariant 5: Zero Space cross-tab bleed *)
          if String.equal kname "Space" then begin
            let is_infra_logs =
              Option.is_none dive_before
              && Nav.equal_workspace m.nav.workspace Nav.Infra
              && Nav.equal_infra_tab m.infra.active_tab Nav.Infra_activity_logs
            in
            if not is_infra_logs then
              Alcotest.(check bool)
                (tag ^ " Space never bleeds infra.log_level_filter")
                true
                (m'.infra.log_level_filter = m.infra.log_level_filter);
            let is_work_pipe =
              Option.is_none dive_before
              && Nav.equal_workspace m.nav.workspace Nav.Work
              && Nav.equal_work_tab m.work.active_tab Nav.Work_pipeline
            in
            if not is_work_pipe then
              Alcotest.(check bool)
                (tag ^ " Space never bleeds work.verification_view")
                true
                (m'.work.verification_view = m.work.verification_view)
          end;
          (* Invariant 6: Zero 'f' Fusion bleed outside Runtime_failover_lanes *)
          if String.equal kname "f" then begin
            let is_failover =
              Option.is_none dive_before
              && Nav.equal_workspace m.nav.workspace Nav.Runtime
              && Nav.equal_runtime_tab m.runtime.active_tab
                   Nav.Runtime_failover_lanes
            in
            if not is_failover then
              Alcotest.(check bool) (tag ^ " 'f' never bleeds Fusion modal") true
                (Option.is_none m'.inline_modal)
          end;
          (* Invariant 7: Zero 'n' modal bleed onto invalid tabs *)
          if String.equal kname "n" then begin
            let is_valid_n =
              Option.is_none dive_before
              &&
              match m.nav.workspace with
              | Nav.Pulse | Nav.Keepers -> true
              | Nav.Work ->
                  Nav.equal_work_tab m.work.active_tab Nav.Work_pipeline
                  || Nav.equal_work_tab m.work.active_tab
                       Nav.Work_tasks_schedules
              | Nav.Knowledge ->
                  Nav.equal_knowledge_tab m.knowledge.active_tab
                    Nav.Knowledge_board
              | Nav.Runtime ->
                  Nav.equal_runtime_tab m.runtime.active_tab
                    Nav.Runtime_tools_connectors
              | Nav.Infra ->
                  Nav.equal_infra_tab m.infra.active_tab
                    Nav.Infra_repos_changes
            in
            if not is_valid_n then
              Alcotest.(check bool) (tag ^ " 'n' never bleeds modal/overlay") true
                (Option.is_none m'.inline_modal && Option.is_none m'.nav.overlay)
          end;
          (* Invariant 8: Zero 'o' Open_external_url bleed outside Repos/Artifacts/Dives *)
          if String.equal kname "o" then begin
            let is_valid_o =
              match dive_before with
              | Some (Nav.Dive_knowledge (Nav.Artifact_dive _)) -> true
              | Some _ -> false
              | None ->
                  (Nav.equal_workspace m.nav.workspace Nav.Infra
                   && Nav.equal_infra_tab m.infra.active_tab
                        Nav.Infra_repos_changes)
                  || (Nav.equal_workspace m.nav.workspace Nav.Knowledge
                      && Nav.equal_knowledge_tab m.knowledge.active_tab
                           Nav.Knowledge_wiki_artifacts)
            in
            if not is_valid_o then
              Alcotest.(check bool) (tag ^ " 'o' never emits Open_external_url")
                false
                (has_cmd
                   (function Cmd.Open_external_url _ -> true | _ -> false)
                   cmds)
          end)
        keys)
    contexts

(* ---------- 2. Axis B x C: 33 Overlay/Focus States x 14 Isolation Keys = 462 Cases ---------- *)

let test_axis_b_overlay_isolation_matrix () =
  let base = populated_model ~cols:140 ~rows:40 () in
  let bg =
    {
      base with
      nav = { base.nav with workspace = Nav.Work; pane_index = 1 };
      work = Work_store.set_tab Nav.Work_pipeline base.work;
    }
  in
  let bg_narrow =
    { bg with viewport = { cols = 68; rows = 28 }; breakpoint = Model.Compact }
  in
  let with_overlay ov (m : Model.t) =
    { m with nav = { m.nav with overlay = Some ov; filter_focused = false } }
  in
  let with_modal ?(submitting = false) ?btw kind =
    let modal = { (Model.inline_modal_for kind) with submitting } in
    let drafts = match btw with Some d -> d | None -> bg.drafts in
    {
      (with_overlay (Nav.Inline_action kind) bg) with
      inline_modal = Some modal;
      drafts;
    }
  in
  let btw_answered_drafts =
    let d1, rid = Drafts.start_btw ~now:t0 ~keeper:"alpha" ~prompt:"hi" bg.drafts in
    Drafts.finish_btw ~request_id:rid ~reply:"hello" d1
  in
  let composer_with txt =
    let d = bg.drafts |> Drafts.set_focus true |> Drafts.set_current_text txt in
    { bg with nav = { bg.nav with overlay = None }; drafts = d }
  in
  let editing_config =
    let c0 = Config_store.enter_inspector bg.config in
    match Config_store.begin_edit_selected c0 with
    | Ok c -> c
    | Error _ -> c0
  in
  let states : (string * Model.t) list =
    [
      ( "Overlay/Palette/Commands"
      , {
          (with_overlay Nav.Palette bg) with
          palette = { mode = Model.Palette_commands; query = ""; selected = 0 };
        } );
      ( "Overlay/Palette/Keepers"
      , {
          (with_overlay Nav.Palette bg) with
          palette = { mode = Model.Palette_keepers; query = ""; selected = 0 };
        } );
      ( "Overlay/Palette/Models"
      , {
          (with_overlay Nav.Palette bg) with
          palette = { mode = Model.Palette_models; query = ""; selected = 0 };
        } );
      ( "Overlay/Settings/WideTree"
      , {
          (with_overlay (Nav.Settings Nav.Settings_general_ui) bg) with
          config = Config_store.set_pane Config_store.Pane_tree bg.config;
        } );
      ( "Overlay/Settings/WideInsp"
      , {
          (with_overlay (Nav.Settings Nav.Settings_general_ui) bg) with
          config = Config_store.set_pane Config_store.Pane_inspector bg.config;
        } );
      ( "Overlay/Settings/Narrow68"
      , {
          (with_overlay (Nav.Settings Nav.Settings_general_ui) bg_narrow) with
          config = Config_store.set_pane Config_store.Pane_tree bg_narrow.config;
        } );
      ( "Overlay/Settings/Editing"
      , {
          (with_overlay (Nav.Settings Nav.Settings_general_ui) bg) with
          config = editing_config;
        } );
      ( "Overlay/Settings/SearchFocused"
      , {
          (with_overlay (Nav.Settings Nav.Settings_general_ui) bg) with
          nav =
            {
              bg.nav with
              overlay = Some (Nav.Settings Nav.Settings_general_ui);
              filter_focused = true;
            };
        } );
      ("Overlay/Incidents/Idle", with_overlay Nav.Incidents bg);
      ( "Overlay/Incidents/FilterFocused"
      , {
          (with_overlay Nav.Incidents bg) with
          nav =
            { bg.nav with overlay = Some Nav.Incidents; filter_focused = true };
        } );
      ( "Overlay/QueueContext/Queue"
      , with_overlay (Nav.Queue_context Nav.Drawer_queue) bg );
      ( "Overlay/QueueContext/Context"
      , with_overlay (Nav.Queue_context Nav.Drawer_context) bg );
      ( "Overlay/QueueContext/Schedules"
      , with_overlay (Nav.Queue_context Nav.Drawer_schedules) bg );
      ("Overlay/Help", with_overlay Nav.Help bg);
      ("Overlay/Modal/BtwIdle", with_modal Nav.Btw_query);
      ( "Overlay/Modal/BtwAnswered"
      , with_modal ~btw:btw_answered_drafts Nav.Btw_query );
      ("Overlay/Modal/BtwSubmitting", with_modal ~submitting:true Nav.Btw_query);
      ("Overlay/Modal/GateReject", with_modal (Nav.Gate_reject "gate-1"));
      ( "Overlay/Modal/VerifReject"
      , with_modal (Nav.Verification_reject "task-1") );
      ( "Overlay/Modal/HarnessOverrule"
      , with_modal (Nav.Harness_overrule "task-1") );
      ("Overlay/Modal/TaskCancel", with_modal (Nav.Task_cancel "task-1"));
      ("Overlay/Modal/ScheduleForm", with_modal Nav.Schedule_form);
      ("Overlay/Modal/ConnectorForm", with_modal Nav.Connector_form);
      ("Overlay/Modal/RepoAddForm", with_modal Nav.Repo_add_form);
      ("Overlay/Modal/BoardNewPost", with_modal Nav.Board_new_post);
      ("Overlay/Gate/Auth", with_overlay (Nav.System_gate Nav.Auth_gate) bg);
      ( "Overlay/Gate/Offline"
      , with_overlay (Nav.System_gate Nav.Server_offline) bg );
      ( "Overlay/Gate/Micro"
      , with_overlay (Nav.System_gate Nav.Micro_viewport) bg );
      ("Overlay/Gate/Media", with_overlay (Nav.System_gate Nav.Media_viewer) bg);
      ("Focus/Composer/Plain", composer_with "hello world");
      ("Focus/Composer/SlashPopup", composer_with "/");
      ("Focus/Composer/SlashArgPopup", composer_with "/theme ");
      ("Focus/Composer/MentionPopup", composer_with "@a");
    ]
  in
  let iso_keys : (string * Keymap.Input.key_event) list =
    [
      ("Tab", mk_key Keymap.Input.Tab);
      ("Shift+Tab", mk_key ~shift:true Keymap.Input.Tab);
      ("Ctrl+K", char_key ~ctrl:true "k");
      ("Ctrl+,", char_key ~ctrl:true ",");
      ("Alt+1", char_key ~alt:true "1");
      ("Up", mk_key Keymap.Input.Up);
      ("Down", mk_key Keymap.Input.Down);
      ("Home", mk_key Keymap.Input.Home);
      ("End", mk_key Keymap.Input.End);
      ("Enter", mk_key Keymap.Input.Enter);
      ("Esc", mk_key Keymap.Input.Escape);
      ("Ctrl+Q", char_key ~ctrl:true "q");
      ("Ctrl+Shift+Q", char_key ~ctrl:true ~shift:true "q");
      ("Ctrl+A", char_key ~ctrl:true "a");
    ]
  in
  Alcotest.(check int) "Axis B states" 33 (List.length states);
  Alcotest.(check int) "Axis B isolation keys" 14 (List.length iso_keys);
  List.iter
    (fun (sname, (m : Model.t)) ->
      let has_overlay = Option.is_some m.nav.overlay in
      let is_blocking_gate =
        match m.nav.overlay with
        | Some
            (Nav.System_gate
              (Nav.Auth_gate | Nav.Server_offline | Nav.Micro_viewport)) ->
            true
        | _ -> false
      in
      let draft_before = Drafts.current_draft m.drafts in
      List.iter
        (fun (kname, ev) ->
          record_case ();
          let tag = Printf.sprintf "[%s x %s]" sname kname in
          let m', cmds = step m ev in
          (* Invariant 1: Ctrl+Shift+Q NEVER emits Quit *)
          if String.equal kname "Ctrl+Shift+Q" then
            Alcotest.(check bool) (tag ^ " Ctrl+Shift+Q never quits") false
              (has_cmd (function Cmd.Quit _ -> true | _ -> false) cmds);
          (* Invariant 2: Ctrl+Q ALWAYS emits Quit *)
          if String.equal kname "Ctrl+Q" then
            Alcotest.(check bool) (tag ^ " Ctrl+Q always quits") true
              (has_cmd (function Cmd.Quit _ -> true | _ -> false) cmds);
          (* Invariant 3: Tab / Shift+Tab NEVER leaks to background pane_index *)
          if
            (String.equal kname "Tab" || String.equal kname "Shift+Tab")
            && (has_overlay
                || String.starts_with ~prefix:"Focus/Composer/Slash" sname
                || String.starts_with ~prefix:"Focus/Composer/Mention" sname)
          then
            Alcotest.(check int)
              (tag ^ " Tab never leaks to background pane_index")
              m.nav.pane_index m'.nav.pane_index;
          (* Invariant 4: Blocking System_gate blocks Global chords *)
          if
            is_blocking_gate
            && (String.equal kname "Ctrl+K"
                || String.equal kname "Ctrl+,"
                || String.equal kname "Alt+1")
          then begin
            Alcotest.(check bool)
              (tag ^ " blocking gate preserves overlay")
              true (m'.nav.overlay = m.nav.overlay);
            Alcotest.(check bool)
              (tag ^ " blocking gate preserves workspace")
              true
              (Nav.equal_workspace m'.nav.workspace m.nav.workspace)
          end;
          (* Invariant 5: Composer raw keys NEVER leak when any overlay is open *)
          if has_overlay && String.equal kname "Ctrl+A" then begin
            let d' = Drafts.current_draft m'.drafts in
            Alcotest.(check int)
              (tag ^ " Ctrl+A never mutates hidden composer cursor")
              draft_before.cursor d'.cursor
          end;
          (* Invariant 6: Narrow Settings (<72 cols) Tab stays Pane_tree *)
          if
            String.equal sname "Overlay/Settings/Narrow68"
            && String.equal kname "Tab"
          then
            Alcotest.(check bool)
              (tag ^ " narrow Settings Tab keeps Pane_tree")
              true
              (Config_store.equal_settings_pane m'.config.settings_pane
                 Config_store.Pane_tree);
          (* Invariant 7: Queue_context Tab cycles drawer tab *)
          if
            String.equal sname "Overlay/QueueContext/Queue"
            && String.equal kname "Tab"
          then
            Alcotest.(check bool)
              (tag ^ " Queue_context Tab advances Queue -> Context")
              true
              (m'.nav.overlay = Some (Nav.Queue_context Nav.Drawer_context));
          (* Invariant 8: Palette Tab moves palette selection *)
          if
            String.equal sname "Overlay/Palette/Commands"
            && String.equal kname "Tab"
          then
            Alcotest.(check int)
              (tag ^ " Palette Tab advances selection 0 -> 1")
              1 m'.palette.selected;
          (* Invariant 9: Guarded modal blocks Tab/Down *)
          if
            (String.equal sname "Overlay/Modal/BtwSubmitting"
             || String.equal sname "Overlay/Modal/BtwAnswered")
            && (String.equal kname "Tab" || String.equal kname "Down")
          then
            Alcotest.(check bool)
              (tag ^ " non-editable modal ignores Tab/Down")
              true (m'.inline_modal = m.inline_modal))
        iso_keys)
    states

(* ---------- 3. Dynamic Rendered-Hint Contract Test (KO & EN) ---------- *)

let assert_has ~label ~needle text =
  if not (Render_util.contains_ci ~needle text) then
    Alcotest.fail
      (Printf.sprintf "%s: expected %S in rendered text" label needle)

let assert_no ~label ~needle text =
  if Render_util.contains_ci ~needle text then
    Alcotest.fail
      (Printf.sprintf "%s: forbidden dead hint %S found in rendered text" label
         needle)

let test_dynamic_rendered_hint_contracts () =
  List.iter
    (fun lang ->
      let m_base = populated_model ~cols:140 ~rows:40 ~lang () in
      let lang_s = match lang with Say.Lang_ko -> "KO" | Say.Lang_en -> "EN" in
      let views : (string * Model.t) list =
        [
          ("Pulse", { m_base with nav = { m_base.nav with workspace = Nav.Pulse } });
          ( "Work/Pipeline"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Work };
              work = Work_store.set_tab Nav.Work_pipeline m_base.work;
            } );
          ( "Work/Tasks"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Work };
              work = Work_store.set_tab Nav.Work_tasks_schedules m_base.work;
            } );
          ( "Work/Inbox"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Work };
              work = Work_store.set_tab Nav.Work_inbox m_base.work;
            } );
          ( "Work/Candle"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Work };
              work = Work_store.set_tab Nav.Work_candle_scorecard m_base.work;
            } );
          ( "Knowledge/Board"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Knowledge };
              knowledge =
                Knowledge_store.set_tab Nav.Knowledge_board m_base.knowledge;
            } );
          ( "Knowledge/Wiki"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Knowledge };
              knowledge =
                Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts
                  m_base.knowledge;
            } );
          ( "Knowledge/Memory"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Knowledge };
              knowledge =
                Knowledge_store.set_tab Nav.Knowledge_memory m_base.knowledge;
            } );
          ( "Keepers"
          , { m_base with nav = { m_base.nav with workspace = Nav.Keepers } } );
          ( "Runtime/Quotas"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Runtime };
              runtime =
                Runtime_store.set_tab Nav.Runtime_quotas_credits m_base.runtime;
            } );
          ( "Runtime/Failover"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Runtime };
              runtime =
                Runtime_store.set_tab Nav.Runtime_failover_lanes m_base.runtime;
            } );
          ( "Runtime/Tools"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Runtime };
              runtime =
                Runtime_store.set_tab Nav.Runtime_tools_connectors
                  m_base.runtime;
            } );
          ( "Infra/Sandboxes"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Infra };
              infra = Infra_store.set_tab Nav.Infra_sandboxes m_base.infra;
            } );
          ( "Infra/Repos"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Infra };
              infra = Infra_store.set_tab Nav.Infra_repos_changes m_base.infra;
            } );
          ( "Infra/Logs"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Infra };
              infra = Infra_store.set_tab Nav.Infra_activity_logs m_base.infra;
            } );
          ( "Dive/Keeper/ChatEmpty"
          , {
              m_base with
              nav =
                {
                  m_base.nav with
                  workspace = Nav.Keepers;
                  dive_stack =
                    [
                      Nav.Dive_keeper { name = "gamma"; tab = Nav.Keeper_chat };
                    ];
                };
            } );
          ( "Dive/Keeper/Config"
          , {
              m_base with
              nav =
                {
                  m_base.nav with
                  workspace = Nav.Keepers;
                  dive_stack =
                    [
                      Nav.Dive_keeper
                        { name = "alpha"; tab = Nav.Keeper_config };
                    ];
                };
            } );
        ]
      in
      let globally_dead =
        [
          "[L] Link";
          "[ ] 탭";
          "[ ] Tab";
          "[ ] 모드";
          "[ ] Mode";
          "[o] Open IDE";
          "[o] IDE 열기";
        ]
      in
      List.iter
        (fun (vname, m) ->
          record_case ();
          let label = Printf.sprintf "%s/%s" lang_s vname in
          let txt = grid_all_text (render_full ~model:m) in
          List.iter (fun bad -> assert_no ~label ~needle:bad txt) globally_dead;
          if String.equal vname "Infra/Sandboxes" then
            assert_no ~label ~needle:"Json_tree" txt;
          if String.equal vname "Dive/Keeper/ChatEmpty" then
            assert_no ~label ~needle:"/status" txt;
          if String.equal vname "Dive/Keeper/Config" then
            assert_no ~label ~needle:"Ctrl+S" txt)
        views;
      (* Specific truthful positive hint checks *)
      record_case ();
      let help_txt =
        grid_all_text
          (render_full
             ~model:
               { m_base with nav = { m_base.nav with overlay = Some Nav.Help } })
      in
      assert_has ~label:(lang_s ^ "/Help/S-Enter") ~needle:"S-Enter" help_txt;
      assert_has ~label:(lang_s ^ "/Help/Alt-Enter") ~needle:"Alt+" help_txt;
      record_case ();
      let inc_txt =
        grid_all_text
          (render_full
             ~model:
               {
                 m_base with
                 nav = { m_base.nav with overlay = Some Nav.Incidents };
               })
      in
      assert_has ~label:(lang_s ^ "/Incidents/FilterBar") ~needle:"/" inc_txt;
      record_case ();
      let set_txt =
        grid_all_text
          (render_full
             ~model:
               {
                 m_base with
                 nav =
                   {
                     m_base.nav with
                     overlay = Some (Nav.Settings Nav.Settings_general_ui);
                   };
               })
      in
      assert_has ~label:(lang_s ^ "/Settings/TuiTheme") ~needle:"theme" set_txt;
      record_case ();
      let pop_m =
        {
          m_base with
          drafts =
            m_base.drafts |> Drafts.set_focus true |> Drafts.set_current_text "/";
        }
      in
      let pop_txt = grid_all_text (render_full ~model:pop_m) in
      assert_has ~label:(lang_s ^ "/Popup/Counter") ~needle:"1/22" pop_txt;
      assert_has ~label:(lang_s ^ "/Popup/TabHint") ~needle:"Tab" pop_txt;
      record_case ();
      let filt_m =
        {
          m_base with
          nav = { m_base.nav with workspace = Nav.Work; filter_focused = true };
        }
      in
      let footer_row =
        let g = render_full ~model:filt_m in
        grid_row_text g (Cell_grid.rows g - 1)
      in
      assert_has ~label:(lang_s ^ "/FilterFooter/Esc") ~needle:"Esc" footer_row;
      assert_has ~label:(lang_s ^ "/FilterFooter/Enter") ~needle:"Enter"
        footer_row;
      (* Single-pane footer omits Tab hint *)
      record_case ();
      let single_m =
        {
          m_base with
          nav = { m_base.nav with workspace = Nav.Work };
          work = Work_store.set_tab Nav.Work_candle_scorecard m_base.work;
        }
      in
      let single_footer =
        let g = render_full ~model:single_m in
        grid_row_text g (Cell_grid.rows g - 1)
      in
      assert_no ~label:(lang_s ^ "/SinglePaneFooter/NoTabNext")
        ~needle:(match lang with Say.Lang_ko -> "Tab 다음" | Say.Lang_en -> "Tab Next")
        single_footer;
      assert_no ~label:(lang_s ^ "/SinglePaneFooter/NoTabPane")
        ~needle:(match lang with Say.Lang_ko -> "Tab 패널" | Say.Lang_en -> "Tab Pane")
        single_footer)
    [ Say.Lang_ko; Say.Lang_en ]

(* ---------- 4. 26 Multi-Step Stateful End-to-End Journeys ---------- *)

let test_journeys_slash_palette_filter () =
  let base = populated_model () in
  (* J1: Composer '/' popup wrap, PgDn, Home/End, Enter executes cleanly *)
  record_case ();
  let m1 = { base with drafts = Drafts.set_focus true base.drafts } in
  let m1, _ = step m1 (char_key "/") in
  let m1_dn, _ = step m1 (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "J1 popup Down -> 1" 1 m1_dn.drafts.popup_selected;
  let m1_up, _ = step m1 (mk_key Keymap.Input.Up) in
  Alcotest.(check int) "J1 popup Up wraps to 21" 21 m1_up.drafts.popup_selected;
  let m1_pg, _ = step m1 (mk_key Keymap.Input.Page_down) in
  Alcotest.(check int) "J1 popup PgDn -> 8" 8 m1_pg.drafts.popup_selected;
  let m1_end, _ = step m1 (mk_key Keymap.Input.End) in
  Alcotest.(check int) "J1 popup End -> 21" 21 m1_end.drafts.popup_selected;
  let m1_home, _ = step m1_end (mk_key Keymap.Input.Home) in
  Alcotest.(check int) "J1 popup Home -> 0" 0 m1_home.drafts.popup_selected;
  let m1_exec, _ = step m1_home (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool)
    "J1 Enter on highlighted '/' command executes without error toast" true
    (match m1_exec.toast with
     | Some { level = Model.Toast_error; _ } -> false
     | _ -> true);

  (* J2: Required-arg '/bt' -> Enter inserts '/btw '; '/th' -> Tab -> arg popup -> Enter switches theme *)
  record_case ();
  let m_empty = { base with drafts = Drafts.set_focus true base.drafts } in
  let m_bt, _ = type_str m_empty "/bt" in
  let m_bt_enter, _ = step m_bt (mk_key Keymap.Input.Enter) in
  Alcotest.(check string) "J2 /bt + Enter inserts '/btw '" "/btw "
    (Drafts.current_draft m_bt_enter.drafts).text;
  let m_th, _ = type_str m_empty "/th" in
  let m_th_tab, _ = step m_th (mk_key Keymap.Input.Tab) in
  Alcotest.(check string) "J2 /th + Tab inserts '/theme '" "/theme "
    (Drafts.current_draft m_th_tab.drafts).text;
  let m_th_dn, _ = step m_th_tab (mk_key Keymap.Input.Down) in
  let m_th_run, cmds_th = step m_th_dn (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "J2 /theme arg popup switches preset to Arcade_hi" true
    (Theme.equal_preset m_th_run.theme_preset Theme.Arcade_hi);
  Alcotest.(check bool) "J2 /theme persists preferences" true
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_tui_preference _; _ } -> true
         | _ -> false)
       cmds_th);

  (* J3: /keeper, /model arg completion & @ mention completion *)
  record_case ();
  let m_kp, _ = type_str m_empty "/keeper b" in
  let m_kp_tab, _ = step m_kp (mk_key Keymap.Input.Tab) in
  Alcotest.(check string) "J3 /keeper b + Tab completes beta" "/keeper beta"
    (Drafts.current_draft m_kp_tab.drafts).text;
  let m_md, _ = type_str m_empty "/model gp" in
  let m_md_tab, _ = step m_md (mk_key Keymap.Input.Tab) in
  Alcotest.(check string) "J3 /model gp + Tab completes gpt-5" "/model gpt-5"
    (Drafts.current_draft m_md_tab.drafts).text;
  let m_at, _ = type_str m_empty "@al" in
  let m_at_tab, _ = step m_at (mk_key Keymap.Input.Tab) in
  Alcotest.(check string) "J3 @al + Tab completes '@alpha '" "@alpha "
    (Drafts.current_draft m_at_tab.drafts).text;

  (* J4: Esc dismisses popup first (keeps focus), 2nd Esc blurs *)
  record_case ();
  let m_esc1, _ = step m1 (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "J4 1st Esc dismisses popup" true
    m_esc1.drafts.popup_dismissed;
  Alcotest.(check bool) "J4 1st Esc keeps composer focused" true
    (Drafts.is_focused m_esc1.drafts);
  let m_esc2, _ = step m_esc1 (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "J4 2nd Esc blurs composer" false
    (Drafts.is_focused m_esc2.drafts);

  (* J5: /clear also clears workspace filter when draft empty *)
  record_case ();
  let m_wfilt =
    {
      base with
      nav = { base.nav with workspace = Nav.Work };
      work = Work_store.set_filter "matrix" base.work;
      drafts = Drafts.set_focus true base.drafts;
    }
  in
  let m_cl, _ = type_str m_wfilt "/clear" in
  let m_cl_run, _ = step m_cl (mk_key Keymap.Input.Enter) in
  Alcotest.(check string) "J5 /clear also clears workspace filter" ""
    m_cl_run.work.filter_query;

  (* J6: Unified Ctrl+K Palette executes across sections *)
  record_case ();
  let m_pal, _ = step base (char_key ~ctrl:true "k") in
  let m_pal_q, _ = type_str m_pal "/restart" in
  let _, cmds_rst = step m_pal_q (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "J6 Ctrl+K /restart emits Restart_tui" true
    (has_cmd (function Cmd.Restart_tui -> true | _ -> false) cmds_rst);
  let m_pal_kp, _ = type_str m_pal "beta" in
  let m_pal_kp_go, _ = step m_pal_kp (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "J6 Ctrl+K keeper entry dives beta" true
    (match Model.active_dive m_pal_kp_go with
     | Some (Nav.Dive_keeper { name = "beta"; _ }) -> true
     | _ -> false);
  let m_pal_goal, _ = type_str m_pal "Harden TUI Matrix" in
  let m_pal_goal_go, _ = step m_pal_goal (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "J6 Ctrl+K goal entry dives goal-1" true
    (match Model.active_dive m_pal_goal_go with
     | Some (Nav.Dive_work (Nav.Goal_dive "goal-1")) -> true
     | _ -> false);

  (* J7: Bare '/' filter bar live Up/Down, Tab commit, Esc clear+blur *)
  record_case ();
  let m_w = { base with nav = { base.nav with workspace = Nav.Work } } in
  let m_f, _ = step m_w (char_key "/") in
  Alcotest.(check bool) "J7 '/' focuses filter" true m_f.nav.filter_focused;
  let m_f_dn, _ = step m_f (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "J7 filter Down moves selection live" 1
    m_f_dn.work.selected_index;
  let m_f_q, _ = type_str m_f_dn "Paused" in
  let m_f_tab, _ = step m_f_q (mk_key Keymap.Input.Tab) in
  Alcotest.(check bool) "J7 Tab commits filter and blurs" false
    m_f_tab.nav.filter_focused;
  Alcotest.(check string) "J7 Tab keeps filter query" "Paused"
    m_f_tab.work.filter_query;
  let m_f_re, _ = step m_f_tab (char_key "/") in
  let m_f_esc, _ = step m_f_re (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "J7 Esc blurs filter" false m_f_esc.nav.filter_focused;
  Alcotest.(check string) "J7 Esc clears filter query" ""
    m_f_esc.work.filter_query;

  (* J8: Incidents filter paste & Esc unwind *)
  record_case ();
  let m_inc, _ = step base (char_key "I") in
  let m_inc_f, _ = step m_inc (char_key "/") in
  let m_inc_p, _ = Update.step ~now:t0 m_inc_f (Msg.Paste_text "backoff") in
  Alcotest.(check string) "J8 Incidents filter paste sets query" "backoff"
    m_inc_p.incidents.filter_query;
  let m_inc_e1, _ = step m_inc_p (mk_key Keymap.Input.Escape) in
  Alcotest.(check string) "J8 Incidents 1st Esc clears query" ""
    m_inc_e1.incidents.filter_query;
  Alcotest.(check bool) "J8 Incidents 1st Esc keeps drawer open" true
    (m_inc_e1.nav.overlay = Some Nav.Incidents);
  let m_inc_e2, _ = step m_inc_e1 (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "J8 Incidents 2nd Esc closes drawer" true
    (Option.is_none m_inc_e2.nav.overlay);

  (* J9: Runtime & Infra filter wiring *)
  record_case ();
  let rt_q = Runtime_store.set_filter "openai" base.runtime in
  Alcotest.(check int) "J9 Runtime Quotas filter narrows accounts to 1" 1
    (List.length (Runtime_store.filtered_accounts rt_q));
  let rt_l = Runtime_store.set_filter "fallback" base.runtime in
  Alcotest.(check int) "J9 Runtime Failover filter narrows lanes to 1" 1
    (List.length (Runtime_store.filtered_lanes rt_l));
  let rt_c = Runtime_store.set_filter "discord" base.runtime in
  Alcotest.(check int) "J9 Runtime Connectors filter narrows connectors to 1" 1
    (List.length (Runtime_store.filtered_connectors rt_c));
  let inf_s = Infra_store.set_filter "beta" base.infra in
  Alcotest.(check int) "J9 Infra Sandboxes filter narrows to beta" 1
    (List.length (Infra_store.filtered_sandbox_keepers inf_s));
  let inf_r = Infra_store.set_filter "docs" base.infra in
  Alcotest.(check int) "J9 Infra Repos filter narrows to masc-docs" 1
    (List.length (Infra_store.filtered_repositories inf_r))

let test_journeys_tab_multipane_dives_safety () =
  let base = populated_model () in
  let base_no_attn = populated_model ~with_attention:false () in

  (* J10: Pulse 4-pane vs 3-pane (skipping empty Attention) + Enter dives per pane *)
  record_case ();
  Alcotest.(check int) "J10 Pulse w/ attention has 4 panes" 4
    (Model.focusable_pane_count base);
  Alcotest.(check int) "J10 Pulse empty attention has 3 panes" 3
    (Model.focusable_pane_count base_no_attn);
  let p_pane2, _ =
    step_keys base [ mk_key Keymap.Input.Tab; mk_key Keymap.Input.Tab ]
  in
  let p_goal_dive, _ = step p_pane2 (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool)
    "J10 Pulse pane 2 (Goals) Enter dives top-ranked Goal_dive (goal-2)" true
    (match Model.active_dive p_goal_dive with
     | Some (Nav.Dive_work (Nav.Goal_dive "goal-2")) -> true
     | _ -> false);
  let p_pane2_dn, _ = step p_pane2 (mk_key Keymap.Input.Down) in
  let p_goal1_dive, _ = step p_pane2_dn (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool)
    "J10 Pulse pane 2 Down + Enter dives 2nd Goal_dive (goal-1)" true
    (match Model.active_dive p_goal1_dive with
     | Some (Nav.Dive_work (Nav.Goal_dive "goal-1")) -> true
     | _ -> false);
  let p_pane3, _ = step p_pane2 (mk_key Keymap.Input.Tab) in
  let p_thread_dive, _ = step p_pane3 (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "J10 Pulse pane 3 (World) Enter dives Thread_dive" true
    (match Model.active_dive p_thread_dive with
     | Some (Nav.Dive_knowledge (Nav.Thread_dive "post-1")) -> true
     | _ -> false);

  (* J11: Work_pipeline 3 panes & empty verifs never corrupts Goals *)
  record_case ();
  let m_wp =
    {
      base with
      nav = { base.nav with workspace = Nav.Work };
      work =
        base.work
        |> Work_store.set_tab Nav.Work_pipeline
        |> Work_store.apply_verifications ~observed_at:t0 [];
    }
  in
  let m_wp_g2, _ =
    step_keys m_wp [ mk_key Keymap.Input.Down; mk_key Keymap.Input.Down ]
  in
  Alcotest.(check int) "J11 Goals at index 2" 2 m_wp_g2.work.selected_index;
  let m_wp_p1, _ = step m_wp_g2 (mk_key Keymap.Input.Tab) in
  let m_wp_p2, _ = step m_wp_p1 (mk_key Keymap.Input.Tab) in
  let m_wp_scroll, _ = step m_wp_p2 (mk_key Keymap.Input.Down) in
  Alcotest.(check int)
    "J11 Goals preserved at 2 after Tab to empty verifs + pane 2" 2
    m_wp_scroll.work.selected_index;
  Alcotest.(check bool) "J11 pane 2 Down scrolls detail_scroll_offset" true
    (m_wp_scroll.work.detail_scroll_offset > 0);

  (* J12: Work_tasks_schedules Tab toggles Tasks vs Schedules *)
  record_case ();
  let m_ts =
    {
      base with
      nav = { base.nav with workspace = Nav.Work };
      work = Work_store.set_tab Nav.Work_tasks_schedules base.work;
    }
  in
  let m_ts_tab, _ = step m_ts (mk_key Keymap.Input.Tab) in
  Alcotest.(check int) "J12 Tasks->Schedules pane_index=1" 1
    m_ts_tab.nav.pane_index;
  Alcotest.(check bool) "J12 selected_index jumped into schedules section" true
    (m_ts_tab.work.selected_index >= 3);

  (* J13: Work_inbox Down -> Y resolves selected item 1, NEVER item 0! *)
  record_case ();
  let m_inb =
    {
      base with
      nav = { base.nav with workspace = Nav.Work };
      work = Work_store.set_tab Nav.Work_inbox base.work;
    }
  in
  let item0_id =
    match Attention.current_filtered_item ~query:"" m_inb.attention with
    | Some e -> e.id
    | None -> ""
  in
  let m_inb_1, _ = step m_inb (mk_key Keymap.Input.Down) in
  let expected_item1_id =
    match Attention.current_filtered_item ~query:"" m_inb_1.attention with
    | Some e -> e.id
    | None -> ""
  in
  Alcotest.(check bool) "J13 item 1 differs from item 0" true
    (not (String.equal item0_id expected_item1_id));
  let _, cmds_y = step m_inb_1 (char_key "Y") in
  Alcotest.(check bool)
    "J13 Work_inbox item 1 Y resolves selected item (NOT item 0)" true
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_ask_answer { ask_id; _ }; _ } ->
             String.equal ("ask:" ^ ask_id) expected_item1_id
         | Cmd.Http_post { req = Cmd.Post_tool_approval { approval_id; _ }; _ } ->
             String.equal ("tool:" ^ approval_id) expected_item1_id
         | Cmd.Http_post { req = Cmd.Post_gate_resolution { id; _ }; _ } ->
             String.equal ("gate:" ^ id) expected_item1_id
         | _ -> false)
       cmds_y);
  let m_inb_p1, _ = step m_inb_1 (mk_key Keymap.Input.Tab) in
  let m_inb_sc, _ = step m_inb_p1 (mk_key Keymap.Input.Down) in
  Alcotest.(check bool) "J13 Work_inbox pane 1 scrolls detail_scroll_offset" true
    (m_inb_sc.work.detail_scroll_offset > 0);
  let m_inb_dive, _ = step m_inb_1 (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "J13 Work_inbox Enter dives selected triage item" true
    (Option.is_some (Model.active_dive m_inb_dive));

  (* J14: Keepers Wide split pane 1 scrolls preview & ']' cycles embedded tab *)
  record_case ();
  let m_kp0 = { base with nav = { base.nav with workspace = Nav.Keepers } } in
  (* Move selection from company 'ops' (gamma, empty chat) to 'platform' (alpha, 32 msgs) *)
  let m_kp, _ = step m_kp0 (mk_key Keymap.Input.Down) in
  let m_kp_p1, _ = step m_kp (mk_key Keymap.Input.Tab) in
  let m_kp_sc, _ = step m_kp_p1 (mk_key Keymap.Input.Up) in
  Alcotest.(check bool) "J14 Keepers split pane 1 Up scrolls chat_scroll_offset"
    true
    (m_kp_sc.fleet.chat_scroll_offset > 0);
  let m_kp_tab, _ = step m_kp_p1 (char_key "]") in
  Alcotest.(check bool)
    "J14 Keepers split pane 1 ']' advances embedded dive tab" true
    (Nav.equal_keeper_tab m_kp_tab.fleet.keeper_dive_tab Nav.Keeper_memory);

  (* J15: Runtime Quotas independent pane 0 scroll + pane 1 credits *)
  record_case ();
  let m_rq =
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime };
      runtime = Runtime_store.set_tab Nav.Runtime_quotas_credits base.runtime;
    }
  in
  let m_rq_sc, _ = step m_rq (mk_key Keymap.Input.Down) in
  Alcotest.(check bool) "J15 Quotas pane 0 Down scrolls quota_scroll_offset" true
    (m_rq_sc.runtime.quota_scroll_offset > 0);
  let m_rq_p1, _ = step m_rq_sc (mk_key Keymap.Input.Tab) in
  Alcotest.(check int) "J15 Quotas pane 1 = credits" 1 m_rq_p1.nav.pane_index;

  (* J16: Wiki detail scroll reset + auto-fetch + Wiki [e] empty guard *)
  record_case ();
  let m_kw =
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge };
      knowledge =
        Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts base.knowledge;
    }
  in
  let m_kw_p1, _ = step m_kw (mk_key Keymap.Input.Tab) in
  let m_kw_sc, _ = step m_kw_p1 (mk_key Keymap.Input.Down) in
  Alcotest.(check bool) "J16 Wiki pane 1 Down scrolls detail_scroll_offset" true
    (m_kw_sc.knowledge.detail_scroll_offset > 0);
  let m_kw_p0, _ = step m_kw_sc (mk_key Keymap.Input.Tab) in
  let m_kw_dn, cmds_wiki = step m_kw_p0 (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "J16 Wiki left move resets detail_scroll_offset to 0" 0
    m_kw_dn.knowledge.detail_scroll_offset;
  Alcotest.(check bool) "J16 Wiki selection move fetches Get_wiki_page" true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_wiki_page { page = "runbook" }; _ } -> true
         | _ -> false)
       cmds_wiki);
  let m_kw_e_early, cmds_e_early = step m_kw_dn (char_key "e") in
  Alcotest.(check bool)
    "J16 Wiki [e] refuses empty modal before Get_wiki_page arrives" true
    (Option.is_none m_kw_e_early.inline_modal);
  Alcotest.(check bool) "J16 Wiki [e] early triggers Get_wiki_page fetch" true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_wiki_page { page = "runbook" }; _ } -> true
         | _ -> false)
       cmds_e_early);
  let m_kw_loaded =
    {
      m_kw_dn with
      knowledge =
        Knowledge_store.apply_wiki_page ~observed_at:t0
          (mk_wiki_detail ~slug:"runbook" ~title:"Operations Runbook")
          m_kw_dn.knowledge;
    }
  in
  let m_kw_e_ok, _ = step m_kw_loaded (char_key "e") in
  Alcotest.(check bool) "J16 Wiki [e] opens populated edit modal after page loaded"
    true
    (match m_kw_e_ok.inline_modal with
     | Some modal ->
         List.exists
           (fun f ->
             String.equal f.Model.key "wiki_body" && String.length f.value > 10)
           modal.fields
     | None -> false);

  (* J17: Infra Repos & Changes 3 panes *)
  record_case ();
  let m_ir =
    {
      base with
      nav = { base.nav with workspace = Nav.Infra };
      infra = Infra_store.set_tab Nav.Infra_repos_changes base.infra;
    }
  in
  Alcotest.(check int) "J17 Infra Repos w/ changes has 3 panes" 3
    (Model.focusable_pane_count m_ir);
  let m_ir_p1, _ = step m_ir (mk_key Keymap.Input.Tab) in
  let m_ir_d1, _ = step m_ir_p1 (mk_key Keymap.Input.Down) in
  Alcotest.(check bool) "J17 Infra Repos pane 1 scrolls diff_scroll_offset" true
    (m_ir_d1.infra.diff_scroll_offset > 0);
  Alcotest.(check int) "J17 Infra Repos pane 1 preserves repo selected_index" 0
    m_ir_d1.infra.selected_index;
  let m_ir_p2, _ = step m_ir_d1 (mk_key Keymap.Input.Tab) in
  let m_ir_c1, _ = step m_ir_p2 (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "J17 Infra Repos pane 2 moves change_selected_index" 1
    m_ir_c1.infra.change_selected_index;
  let ir_cmds = View_fetches.fetches_for_current_view ~force:true m_ir in
  Alcotest.(check bool) "J17 Infra Repos fetches Get_file_changes" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_file_changes _; _ } -> true
         | _ -> false)
       ir_cmds);

  (* J18: Dive_keeper [c] switches in-place (stack depth 1), Config [e] opens Settings *)
  record_case ();
  let m_dk =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory } ];
        };
    }
  in
  let m_dk_c, _ = step m_dk (char_key "c") in
  Alcotest.(check int) "J18 Dive_keeper [c] keeps dive_stack depth=1" 1
    (List.length m_dk_c.nav.dive_stack);
  Alcotest.(check bool)
    "J18 Dive_keeper [c] switches to Keeper_chat + focuses composer" true
    (Model.active_dive m_dk_c
     = Some (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat })
     && Drafts.is_focused m_dk_c.drafts);
  let m_dk_cfg =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_config } ];
        };
    }
  in
  let m_dk_e, _ = step m_dk_cfg (char_key "e") in
  Alcotest.(check bool)
    "J18 Keeper_config [e] opens Settings scoped to Target_keeper alpha" true
    (m_dk_e.nav.overlay = Some (Nav.Settings Nav.Settings_keepers_companies)
     && Config_store.equal_config_target m_dk_e.config.target
          (Wire_config.Target_keeper "alpha"));

  (* J19: Gate_reject modal submit closes immediately (never hangs) *)
  record_case ();
  let m_gr, _ = Update_nav.open_inline_modal base (Nav.Gate_reject "gate-1") in
  let m_gr_typed, _ = type_str m_gr "unsafe deploy" in
  let m_gr_done, cmds_gr = step m_gr_typed (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "J19 Gate_reject closes immediately (no hang)" true
    (Option.is_none m_gr_done.inline_modal && Option.is_none m_gr_done.nav.overlay);
  Alcotest.(check bool) "J19 Gate_reject emits Post_gate_resolution" true
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_gate_resolution _; _ } -> true
         | _ -> false)
       cmds_gr);

  (* J20: New keeper creation n -> "nova" -> Enter -> Ctrl+S allows ops=[] *)
  record_case ();
  let m_nk = { base with nav = { base.nav with workspace = Nav.Keepers } } in
  let m_nk_n, _ = step m_nk (char_key "n") in
  let m_nk_typed, _ = type_str m_nk_n "nova" in
  let m_nk_conf, _ = step m_nk_typed (mk_key Keymap.Input.Enter) in
  let _, cmds_save = step m_nk_conf (char_key ~ctrl:true "s") in
  Alcotest.(check bool)
    "J20 New keeper Ctrl+S emits Post_config_patch with ops=[] & keeper=nova"
    true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_config_patch
                   { keeper_name = Some "nova"; ops = []; _ };
               _;
             } ->
             true
         | _ -> false)
       cmds_save);

  (* J21: /btw -> answer -> Esc clears Drafts.btw -> reusable *)
  record_case ();
  let m_btw_ans =
    let m_o, _ = Update_nav.open_inline_modal base Nav.Btw_query in
    let d1, rid =
      Drafts.start_btw ~now:t0 ~keeper:"alpha" ~prompt:"q1" m_o.drafts
    in
    { m_o with drafts = Drafts.finish_btw ~request_id:rid ~reply:"a1" d1 }
  in
  let m_btw_closed, _ = step m_btw_ans (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "J21 /btw Esc clears Drafts.btw to Btw_idle" true
    (m_btw_closed.drafts.btw = Drafts.Btw_idle);

  (* J22: Composer Shift+Enter = newline, Ctrl+Enter = follow-up, Ctrl+A/E/U *)
  record_case ();
  let m_c = { base with drafts = Drafts.set_focus true base.drafts } in
  let m_c1, _ = type_str m_c "line1" in
  let m_c2, cmds_se = step m_c1 (mk_key ~shift:true Keymap.Input.Enter) in
  Alcotest.(check string) "J22 Shift+Enter inserts newline" "line1\n"
    (Drafts.current_draft m_c2.drafts).text;
  Alcotest.(check int) "J22 Shift+Enter does NOT submit" 0 (List.length cmds_se);
  let m_c3, _ = type_str m_c2 "line2" in
  let m_c4, _ = step m_c3 (char_key ~ctrl:true "a") in
  Alcotest.(check int) "J22 Ctrl+A jumps to line start" 6
    (Drafts.current_draft m_c4.drafts).cursor;
  let m_c5, _ = step m_c4 (char_key ~ctrl:true "e") in
  Alcotest.(check int) "J22 Ctrl+E jumps to line end" 11
    (Drafts.current_draft m_c5.drafts).cursor;
  let m_c6, _ = step m_c5 (char_key ~ctrl:true "u") in
  Alcotest.(check string) "J22 Ctrl+U kills to line start" "line1\n"
    (Drafts.current_draft m_c6.drafts).text;
  let _, cmds_ce = step m_c3 (mk_key ~ctrl:true Keymap.Input.Enter) in
  Alcotest.(check bool) "J22 Ctrl+Enter submits follow-up" true
    (has_cmd
       (function
         | Cmd.Http_post_stream
             {
               req =
                 Cmd.Stream_keeper_chat
                   { request = { mode = Wire_fleet.Follow_up; _ }; _ };
               _;
             } ->
             true
         | _ -> false)
       cmds_ce);

  (* J23: Help '?' toggle & scroll *)
  record_case ();
  let m_h1, _ = step base (char_key "?") in
  Alcotest.(check bool) "J23 '?' opens Help" true (m_h1.nav.overlay = Some Nav.Help);
  let m_h2, _ = step m_h1 (mk_key Keymap.Input.Down) in
  Alcotest.(check bool) "J23 Help Down scrolls help_scroll_offset" true
    (m_h2.nav.help_scroll_offset > 0);
  let m_h3, _ = step m_h2 (char_key "?") in
  Alcotest.(check bool) "J23 2nd '?' closes Help" true
    (Option.is_none m_h3.nav.overlay);

  (* J24: Korean 2-bulsik IME replay on contextual hotkeys *)
  record_case ();
  let m_dk_ko =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory } ];
        };
    }
  in
  let m_dk_ko_c, _ = step m_dk_ko (char_key "ㅊ") in
  Alcotest.(check bool) "J24 Korean 'ㅊ' replays 'c' -> switches to Keeper_chat"
    true
    (Model.active_dive m_dk_ko_c
     = Some (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat })
     && Drafts.is_focused m_dk_ko_c.drafts);
  let m_rt_ko =
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime };
      runtime = Runtime_store.set_tab Nav.Runtime_failover_lanes base.runtime;
    }
  in
  let m_rt_ko_f, _ = step m_rt_ko (char_key "ㄹ") in
  Alcotest.(check bool) "J24 Korean 'ㄹ' replays 'f' -> opens Fusion modal" true
    (Option.is_some m_rt_ko_f.inline_modal);

  (* J25: Inline_action Up/Down/Tab cycle fields while Home/End/Left/Right do NOT hijack active_field + Queue_context '['/']' *)
  record_case ();
  let m_sf, _ = Update_nav.open_inline_modal base Nav.Schedule_form in
  let m_sf_dn, _ = step m_sf (mk_key Keymap.Input.Down) in
  Alcotest.(check bool) "J25 Inline_action Down advances to field 1" true
    (match m_sf_dn.inline_modal with
     | Some modal -> modal.active_field = 1
     | None -> false);
  let m_sf_end, _ = step m_sf_dn (mk_key Keymap.Input.End) in
  Alcotest.(check bool) "J25 Inline_action End does NOT hijack active_field" true
    (match m_sf_end.inline_modal with
     | Some modal -> modal.active_field = 1
     | None -> false);
  let m_sf_home, _ = step m_sf_end (mk_key Keymap.Input.Home) in
  Alcotest.(check bool) "J25 Inline_action Home does NOT hijack active_field" true
    (match m_sf_home.inline_modal with
     | Some modal -> modal.active_field = 1
     | None -> false);
  let m_sf_up, _ = step m_sf_home (mk_key Keymap.Input.Up) in
  Alcotest.(check bool) "J25 Inline_action Up returns to field 0" true
    (match m_sf_up.inline_modal with
     | Some modal -> modal.active_field = 0
     | None -> false);
  let m_qc, _ = step base (char_key ~ctrl:true "t") in
  let m_qc2, _ = step m_qc (char_key "]") in
  Alcotest.(check bool) "J25 Queue_context ']' cycles to Context tab" true
    (m_qc2.nav.overlay = Some (Nav.Queue_context Nav.Drawer_context));

  (* J26: Settings edit-mode Tab exits edit cleanly (no trap) *)
  record_case ();
  let m_set, _ = step base (char_key ",") in
  let m_set_insp, _ = step m_set (mk_key Keymap.Input.Tab) in
  let m_set_edit, _ = step m_set_insp (mk_key Keymap.Input.Enter) in
  let m_set_tab, _ = step m_set_edit (mk_key Keymap.Input.Tab) in
  Alcotest.(check bool) "J26 Settings edit-mode Tab exits edit cleanly (no trap)"
    true
    (Option.is_none m_set_tab.config.editing_field_key);

  (* ---------- Adversarial Verifier Regressions (#336 Items 1-13) ---------- *)

  (* R1: Work_pipeline narrow/compact (80x24): linked card absent => 2 panes, never acts on hidden verifs *)
  record_case ();
  let m_wp_narrow =
    let m0 = populated_model ~cols:80 ~rows:24 () in
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Work; pane_index = 0 };
      work = Work_store.set_tab Nav.Work_pipeline m0.work;
    }
  in
  Alcotest.(check bool) "R1 Work_pipeline 80x24 has no linked card" false
    (Model.work_pipeline_has_linked_card m_wp_narrow);
  Alcotest.(check int) "R1 Work_pipeline 80x24 focusable_pane_count = 2" 2
    (Model.focusable_pane_count m_wp_narrow);
  let m_wp_n1, _ = step m_wp_narrow (mk_key Keymap.Input.Tab) in
  Alcotest.(check int) "R1 Tab moves to pane 1 (Goal Detail)" 1
    m_wp_n1.nav.pane_index;
  let m_wp_n1_dn, _ = step m_wp_n1 (mk_key Keymap.Input.Down) in
  Alcotest.(check bool) "R1 pane 1 Down scrolls Goal Detail" true
    (m_wp_n1_dn.work.detail_scroll_offset > 0);
  Alcotest.(check int) "R1 pane 1 Down does NOT move hidden verif_selected_index"
    0 m_wp_n1_dn.work.verif_selected_index;
  let m_wp_n1_ent, _ = step m_wp_n1 (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "R1 pane 1 Enter dives Goal_dive (never Verification_dive)"
    true
    (match Model.active_dive m_wp_n1_ent with
     | Some (Nav.Dive_work (Nav.Goal_dive _)) -> true
     | _ -> false);
  let _, cmds_wp_n1_a = step m_wp_n1 (char_key "a") in
  Alcotest.(check bool) "R1 pane 1 'a' NEVER posts verification verdict" false
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_verification_verdict _; _ } -> true
         | _ -> false)
       cmds_wp_n1_a);
  let m_wp_n1_x, _ = step m_wp_n1 (char_key "x") in
  Alcotest.(check bool) "R1 pane 1 'x' NEVER opens Verification_reject" false
    (match m_wp_n1_x.nav.overlay with
     | Some (Nav.Inline_action (Nav.Verification_reject _)) -> true
     | _ -> false);
  let _, cmds_wp_n1_y = step m_wp_n1 (char_key "y") in
  Alcotest.(check bool) "R1 pane 1 'y' copies goal title (not hidden verif)"
    true
    (has_cmd
       (function
         | Cmd.Copy_clipboard s -> String.equal s "Harden TUI Matrix"
         | _ -> false)
       cmds_wp_n1_y);

  (* R2: Infra Sandboxes 'ssh' / 'docker' filter parity between store and Screen_infra *)
  record_case ();
  let m_sb_ssh =
    {
      base with
      nav = { base.nav with workspace = Nav.Infra };
      infra =
        base.infra
        |> Infra_store.set_tab Nav.Infra_sandboxes
        |> Infra_store.set_filter "ssh";
    }
  in
  let sb_ssh_keepers = Infra_store.filtered_sandbox_keepers m_sb_ssh.infra in
  Alcotest.(check bool) "R2 store matches ssh sandbox keeper" true
    (List.mem "beta" sb_ssh_keepers);
  let g_sb_ssh = render_full ~model:m_sb_ssh in
  let txt_sb_ssh = grid_all_text g_sb_ssh in
  Alcotest.(check bool) "R2 Screen_infra renders matching ssh keeper row" true
    (Store_scroll.contains_ci ~needle:"beta" txt_sb_ssh);

  (* R3: Exact off-by-2 geometry thresholds (Settings 73/74, Keepers 105/106, Sandboxes 101/102) *)
  record_case ();
  Alcotest.(check bool) "R3 Settings 73 cols is single-pane" false
    (Config_store.is_two_pane_width ~cols:73);
  Alcotest.(check bool) "R3 Settings 74 cols is two-pane" true
    (Config_store.is_two_pane_width ~cols:74);
  let m_set_73 =
    let m0 = populated_model ~cols:73 ~rows:30 () in
    { m0 with nav = { m0.nav with overlay = Some (Nav.Settings Nav.Settings_general_ui) } }
  in
  let m_set_73_tab, _ = step m_set_73 (mk_key Keymap.Input.Tab) in
  Alcotest.(check bool) "R3 Settings 73 cols Tab does NOT toggle pane" true
    (Config_store.equal_settings_pane m_set_73_tab.config.settings_pane
       m_set_73.config.settings_pane);
  let m_kp_105 =
    let m0 = populated_model ~cols:105 ~rows:30 () in
    { m0 with nav = { m0.nav with workspace = Nav.Keepers } }
  in
  let m_kp_106 =
    let m0 = populated_model ~cols:106 ~rows:30 () in
    { m0 with nav = { m0.nav with workspace = Nav.Keepers } }
  in
  Alcotest.(check int) "R3 Keepers 105 cols (inner 103 < 104) => 1 pane" 1
    (Model.focusable_pane_count m_kp_105);
  Alcotest.(check int) "R3 Keepers 106 cols (inner 104 >= 104) => 2 panes" 2
    (Model.focusable_pane_count m_kp_106);
  let m_sb_101 =
    let m0 = populated_model ~cols:101 ~rows:30 () in
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Infra };
      infra = Infra_store.set_tab Nav.Infra_sandboxes m0.infra;
    }
  in
  let m_sb_102 =
    let m0 = populated_model ~cols:102 ~rows:30 () in
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Infra };
      infra = Infra_store.set_tab Nav.Infra_sandboxes m0.infra;
    }
  in
  Alcotest.(check int) "R3 Sandboxes 101 cols (inner 99 < 100) => 1 pane" 1
    (Model.focusable_pane_count m_sb_101);
  Alcotest.(check int) "R3 Sandboxes 102 cols (inner 100 >= 100) => 2 panes" 2
    (Model.focusable_pane_count m_sb_102);

  (* R4: Settings edit-mode Tab commits tui.* fallback preference cleanly *)
  record_case ();
  let m_s_gen =
    let m0, _ = step base (char_key ",") in
    let cfg =
      m0.config
      |> Config_store.set_tab Nav.Settings_general_ui
      |> Config_store.set_pane Config_store.Pane_inspector
    in
    {
      m0 with
      nav = { m0.nav with overlay = Some (Nav.Settings Nav.Settings_general_ui) };
      config = cfg;
    }
  in
  let m_s_ed, _ = step m_s_gen (mk_key Keymap.Input.Enter) in
  let m_s_buf =
    {
      m_s_ed with
      config = Config_store.update_edit_buffer "paper_light" m_s_ed.config;
    }
  in
  let m_s_tab, cmds_s_tab = step m_s_buf (mk_key Keymap.Input.Tab) in
  Alcotest.(check bool) "R4 Settings Tab applies tui.theme preference" true
    (Theme.equal_preset m_s_tab.theme_preset Theme.Paper_light);
  Alcotest.(check int) "R4 Settings Tab leaves 0 stale dirty_fields for tui.*" 0
    (Config_store.dirty_count m_s_tab.config);
  Alcotest.(check bool) "R4 Settings Tab emits Post_tui_preference" true
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_tui_preference _; _ } -> true
         | _ -> false)
       cmds_s_tab);

  (* R5: Composer popup 5a (Esc+cursor preserves dismissed), 5b (mid-line cursor), 5c (exact match first) *)
  record_case ();
  let m_p5a =
    {
      base with
      drafts = base.drafts |> Drafts.set_focus true |> Drafts.set_current_text "/he";
    }
  in
  let m_p5a_esc, _ = step m_p5a (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "R5a Esc dismisses popup" true
    m_p5a_esc.drafts.popup_dismissed;
  let m_p5a_left, _ = step m_p5a_esc (mk_key Keymap.Input.Left) in
  Alcotest.(check bool) "R5a Left arrow keeps popup_dismissed = true" true
    m_p5a_left.drafts.popup_dismissed;
  let m_p5a_home, _ = step m_p5a_left (mk_key Keymap.Input.Home) in
  Alcotest.(check bool) "R5a Home preserves popup_dismissed = true" true
    m_p5a_home.drafts.popup_dismissed;
  let m_p5b_mid =
    {
      base with
      drafts =
        base.drafts
        |> Drafts.set_focus true
        |> Drafts.set_current_text_and_cursor ~text:"foo bar @alp" ~cursor:4;
    }
  in
  Alcotest.(check bool) "R5b cursor before @alp does NOT open mention popup"
    true
    (match Update_nav.resolve_composer_popup m_p5b_mid with
     | Update_nav.Composer_popup_none -> true
     | _ -> false);
  let m_p5b_end, _ = step m_p5b_mid (mk_key Keymap.Input.End) in
  Alcotest.(check int) "R5b End moves cursor to end (not hijacked by popup)" 12
    (Drafts.current_draft m_p5b_end.drafts).cursor;
  let m_p5b_ins =
    {
      base with
      drafts =
        base.drafts
        |> Drafts.set_focus true
        |> Drafts.set_current_text_and_cursor ~text:"hi @alp world" ~cursor:7;
    }
  in
  let m_p5b_tab, _ = step m_p5b_ins (mk_key Keymap.Input.Tab) in
  Alcotest.(check string) "R5b Tab replaces only @alp and keeps trailing ' world'"
    "hi @alpha world" (Drafts.current_draft m_p5b_tab.drafts).text;
  let m_p5c =
    let k_dev = mk_keeper ~name:"alpha-dev" ~company:"core" ~health:Wire_fleet.Keeper_healthy in
    let k_exact = mk_keeper ~name:"alpha" ~company:"core" ~health:Wire_fleet.Keeper_healthy in
    let fleet = Fleet_store.apply_keepers ~observed_at:t0 [ k_dev; k_exact ] base.fleet in
    {
      base with
      fleet;
      drafts =
        base.drafts
        |> Drafts.set_focus true
        |> Drafts.set_current_text "/keeper alpha";
    }
  in
  let m_p5c_ent, _ = step m_p5c (mk_key Keymap.Input.Enter) in
  Alcotest.(check bool) "R5c '/keeper alpha' executes exact 'alpha' (not 'alpha-dev')"
    true
    (Model.active_dive m_p5c_ent
     = Some (Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat }));

  (* R6: z Toggle_zoom scoped to zoomable views & reset on sub-tab/dive/pop/Artifacts *)
  record_case ();
  let m_z_pulse, _ = step base (char_key "z") in
  Alcotest.(check bool) "R6 'z' on Pulse is a no-op (zoomed stays false)" false
    m_z_pulse.nav.zoomed;
  let m_z_kw =
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge };
      knowledge = Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts base.knowledge;
    }
  in
  let m_z_kw1, _ = step m_z_kw (char_key "z") in
  Alcotest.(check bool) "R6 'z' on Knowledge > Wiki toggles zoomed = true" true
    m_z_kw1.nav.zoomed;
  let m_z_art, _ = step m_z_kw1 (char_key " ") in
  Alcotest.(check bool) "R6 Space Wiki->Artifacts resets zoomed = false" false
    m_z_art.nav.zoomed;
  let m_z_art2, _ = step m_z_art (char_key "z") in
  Alcotest.(check bool) "R6 'z' on Artifacts stays false" false
    m_z_art2.nav.zoomed;
  let m_z_tab, _ = step m_z_kw1 (char_key "]") in
  Alcotest.(check bool) "R6 cycle_sub_tab resets zoomed = false" false
    m_z_tab.nav.zoomed;
  let m_z_dive, _ = Update_nav.push_dive m_z_kw1 (Nav.Dive_knowledge (Nav.Wiki_dive "architecture")) in
  Alcotest.(check bool) "R6 push_dive resets zoomed = false" false
    m_z_dive.nav.zoomed;

  (* R7 & R8: Bounded scroll on End, Micro composer/paste lock, Work_inbox/Tasks_schedules pane counts, Palette Tab clamp *)
  record_case ();
  let m_h_end, _ =
    let m_h, _ = step base (char_key "?") in
    step m_h (mk_key Keymap.Input.End)
  in
  Alcotest.(check bool) "R8 Help End scroll bounded (<= 60)" true
    (m_h_end.nav.help_scroll_offset <= 60);
  let m_micro = populated_model ~cols:60 ~rows:20 () in
  let m_micro_i, _ = step m_micro (char_key "i") in
  Alcotest.(check bool) "R8 Micro blocks Focus_composer ('i')" false
    (Drafts.is_focused m_micro_i.drafts);
  let m_micro_p, _ = Update.step ~now:t0 m_micro (Msg.Paste_text "hello") in
  Alcotest.(check string) "R8 Micro blocks apply_paste" ""
    (Drafts.current_draft m_micro_p.drafts).text;
  let m_inb_empty =
    let m0 =
      {
        base with
        nav = { base.nav with workspace = Nav.Work; pane_index = 1 };
        work = Work_store.set_tab Nav.Work_inbox base.work;
      }
    in
    Update_nav.set_active_filter_query "zzz-no-match" m0
  in
  Alcotest.(check int) "R8 Work_inbox filtered-empty => focusable_pane_count = 1" 1
    (Model.focusable_pane_count m_inb_empty);
  Alcotest.(check int) "R8 set_active_filter_query clamps pane_index to 0" 0
    m_inb_empty.nav.pane_index;
  let m_pal_hi =
    {
      base with
      nav = { base.nav with overlay = Some Nav.Palette };
      palette = { mode = Model.Palette_commands; query = ""; selected = 999 };
    }
  in
  let m_pal_tab, _ = step m_pal_hi (mk_key Keymap.Input.Tab) in
  Alcotest.(check int) "R8 Palette Tab clamps stale high selected before wrap" 0
    m_pal_tab.palette.selected;
  let m_mem_dive =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Knowledge;
          dive_stack =
            [ Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper = None; from_rev = 1; to_rev = 2 }) ];
        };
    }
  in
  ignore (render_full ~model:m_mem_dive);

  (* R9: Infra_repos_changes stale Reply_file_changes rejected + keepers=[] clears changes *)
  record_case ();
  let repo_no_keeper : Wire_infra.repository =
    {
      id = "repo-empty";
      name = "masc-empty";
      codebase = None;
      url = "https://example.invalid/masc-empty";
      local_path = "/workspace/masc-empty";
      default_branch = "main";
      auto_sync = false;
      status = Wire_infra.Repo_synced;
      keepers = [];
    }
  in
  let m_ir0 =
    let repos_with_empty =
      (match Observed.to_option base.infra.repositories with Some rs -> rs | None -> [])
      @ [ repo_no_keeper ]
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Infra; pane_index = 0 };
      infra =
        base.infra
        |> Infra_store.set_tab Nav.Infra_repos_changes
        |> Infra_store.apply_repositories ~observed_at:t0 repos_with_empty;
    }
  in
  let m_ir1, cmds_ir1 = step m_ir0 (mk_key Keymap.Input.Down) in
  Alcotest.(check bool) "R9 switching to repo with keeper 'gamma' emits Get_file_changes"
    true
    (has_cmd
       (function
         | Cmd.Http_get { req = Cmd.Get_file_changes { keeper = "gamma"; _ }; _ } -> true
         | _ -> false)
       cmds_ir1);
  let stale_change : Wire_infra.file_change =
    {
      path = "stale/alpha.ml";
      kind = Wire_infra.File_modified;
      additions = obs 1;
      deletions = obs 0;
      keeper = Some "alpha";
      diff_preview = Some "+stale";
    }
  in
  let m_ir_stale, _ =
    Update.step ~now:t0 m_ir1
      (Msg.Http_reply
         {
           epoch = m_ir1.epoch;
           reply =
             Msg.Reply_file_changes { keeper = "alpha"; result = Ok [ stale_change ] };
         })
  in
  Alcotest.(check bool) "R9 stale Reply_file_changes for 'alpha' ignored while 'gamma' repo selected"
    true
    (Option.is_none m_ir_stale.infra.file_changes_keeper);
  let m_ir_empty, _ = step m_ir1 (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "R9 repo with keepers=[] has focusable_pane_count = 2" 2
    (Model.focusable_pane_count m_ir_empty);
  Alcotest.(check bool) "R9 repo with keepers=[] clears file_changes_keeper" true
    (Option.is_none m_ir_empty.infra.file_changes_keeper);

  (* R10: Cross-dive isolation on 'o' (Open_external) & 'y' (Copy_selected) + Wiki slug parity *)
  record_case ();
  let m_dive_bleed =
    {
      m_ir0 with
      nav =
        {
          m_ir0.nav with
          dive_stack = [ Nav.Dive_work (Nav.Goal_dive "goal-1") ];
        };
    }
  in
  let _, cmds_o = step m_dive_bleed (char_key "o") in
  Alcotest.(check bool) "R10 'o' inside Goal_dive NEVER opens hidden Infra repo URL"
    false
    (has_cmd
       (function
         | Cmd.Open_external_url url -> Store_scroll.contains_ci ~needle:"masc" url
         | _ -> false)
       cmds_o);
  let _, cmds_y = step m_dive_bleed (char_key "y") in
  Alcotest.(check bool) "R10 'y' inside Goal_dive copies Goal title (never hidden Infra URL)"
    true
    (has_cmd
       (function
         | Cmd.Copy_clipboard s -> String.equal s "Harden TUI Matrix"
         | _ -> false)
       cmds_y);
  let m_wiki_mismatch =
    let stale_page =
      {
        (mk_wiki_detail ~slug:"stale-other-slug" ~title:"Stale") with
        body_markdown = "See https://stale.example.com/secret";
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge };
      knowledge =
        base.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts
        |> Knowledge_store.apply_wiki_page ~observed_at:t0 stale_page;
    }
  in
  let _, cmds_wo = step m_wiki_mismatch (char_key "o") in
  Alcotest.(check bool) "R10 Wiki 'o' refuses URL from mismatched wiki_page slug"
    false
    (has_cmd (function Cmd.Open_external_url _ -> true | _ -> false) cmds_wo);
  let _, cmds_wy = step m_wiki_mismatch (char_key "y") in
  Alcotest.(check bool) "R10 Wiki 'y' falls back to selected slug (never mismatched body)"
    false
    (has_cmd
       (function
         | Cmd.Copy_clipboard s ->
             Store_scroll.contains_ci ~needle:"stale.example.com" s
         | _ -> false)
       cmds_wy);

  (* R11: Work_inbox Approval Strip parity + Quarantine Y/N & Ask N stay active *)
  record_case ();
  let m_inb_ask =
    {
      base with
      nav = { base.nav with workspace = Nav.Work };
      work =
        base.work
        |> Work_store.set_tab Nav.Work_inbox
        |> Work_store.set_filter "ask";
    }
  in
  Alcotest.(check bool)
    "R11 Work_inbox Approval Strip hides mismatched tool_approval when Ask is selected"
    true
    (Option.is_none (Model.fast_approval_strip_item m_inb_ask));
  let _, cmds_inb_ask_n = step m_inb_ask (char_key ~shift:true "N") in
  Alcotest.(check bool) "R11 Work_inbox selected Ask 'N' skips Ask (Post_ask_answer)"
    true
    (has_cmd
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_ask_answer
                   { answers = [ (_, Wire_work.Ask_skipped) ]; _ };
               _;
             } ->
             true
         | _ -> false)
       cmds_inb_ask_n);
  let q_item : Wire_knowledge.quarantine_candidate =
    {
      partition_id = "part-1";
      quarantine_id = "q-1";
      keeper = "alpha";
      post_id = "post-q1";
      status = "quarantined";
      failure_reason = "policy";
      quarantined_at_unix = Some 1700000000.0;
    }
  in
  let m_inb_q =
    let attention =
      Attention.rebuild ~asks:[] ~tool_approvals:[] ~gate_pending:[] ~goals:[]
        ~quarantines:[ q_item ] Attention.empty
    in
    {
      base with
      attention;
      nav = { base.nav with workspace = Nav.Work };
      work = Work_store.set_tab Nav.Work_inbox base.work;
    }
  in
  Alcotest.(check bool)
    "R11 Work_inbox Quarantine keeps bottom Approval Strip hidden"
    true
    (Option.is_none (Model.fast_approval_strip_item m_inb_q));
  let _, cmds_q_y = step m_inb_q (char_key ~shift:true "Y") in
  Alcotest.(check bool)
    "R11 Work_inbox Quarantine 'Y' emits Post_quarantine_requeue"
    true
    (has_cmd
       (function
         | Cmd.Http_post
             { req = Cmd.Post_quarantine_requeue { quarantine_id = "q-1"; _ }; _ } ->
             true
         | _ -> false)
       cmds_q_y);
  let m_q_n, _ = step m_inb_q (char_key ~shift:true "N") in
  Alcotest.(check bool)
    "R11 Work_inbox Quarantine 'N' skips with toast"
    true
    (match m_q_n.toast with
     | Some t -> Store_scroll.contains_ci ~needle:"Skipped quarantine" t.message.en
     | None -> false);

  (* R12: apply_paste submitting guard + Server_offline clears inline_modal *)
  record_case ();
  let m_mod, _ = Update_nav.open_inline_modal base (Nav.Gate_reject "gate-1") in
  let m_mod_sub =
    {
      m_mod with
      inline_modal =
        Option.map (fun (md : Model.inline_modal_state) -> { md with submitting = true })
          m_mod.inline_modal;
    }
  in
  let m_mod_pasted, _ = Update.step ~now:t0 m_mod_sub (Msg.Paste_text "injected") in
  Alcotest.(check string) "R12 apply_paste blocked while inline_modal submitting"
    ""
    (match m_mod_pasted.inline_modal with
     | Some md -> Model.modal_field_value ~key:"reason" md
     | None -> "missing");
  let m_offline, _ =
    Update.step ~now:t0 m_mod
      (Msg.Server_health_result
         {
           epoch = m_mod.epoch;
           result = Error (Msg.Transport Health.Connect_refused);
         })
  in
  Alcotest.(check bool) "R12 Server_offline clears inline_modal" true
    (Option.is_none m_offline.inline_modal
     && m_offline.nav.overlay = Some (Nav.System_gate Nav.Server_offline));

  (* R13: Auth_gate 'r' emits Get_health, Ok health clears Auth_gate, chrome omits 'Esc return' *)
  record_case ();
  let m_auth =
    {
      base with
      lang = Say.Lang_en;
      nav = { base.nav with overlay = Some (Nav.System_gate Nav.Auth_gate) };
    }
  in
  let _, cmds_auth_r = step m_auth (char_key "r") in
  Alcotest.(check bool) "R13 Auth_gate 'r' emits Get_health" true
    (has_cmd
       (function Cmd.Http_get { req = Cmd.Get_health; _ } -> true | _ -> false)
       cmds_auth_r);
  let dummy_health : Wire_common.server_health =
    {
      ok = true;
      live = Some true;
      ready = Some true;
      phase = Some "ready";
      status = "ok";
      version = "0.1.0";
      binary_commit = Some "abc1234";
      uptime_display = Some "10s";
      uptime_sec = Some 10.0;
      scope = Wire_common.Public_health;
      gc = None;
      active_keepers = Some 1;
    }
  in
  let m_auth_ok, _ =
    Update.step ~now:t0 m_auth
      (Msg.Server_health_result { epoch = m_auth.epoch; result = Ok dummy_health })
  in
  Alcotest.(check bool) "R13 Ok health clears Auth_gate" true
    (Option.is_none m_auth_ok.nav.overlay);
  let g_auth = render_full ~model:m_auth in
  let txt_auth = grid_all_text g_auth in
  Alcotest.(check bool) "R13 Auth_gate chrome NEVER shows 'Esc return'" false
    (Store_scroll.contains_ci ~needle:"Esc return" txt_auth);

  (* Final case count gate >= 1,000 *)
  Alcotest.(check bool)
    (Printf.sprintf "Total matrix cases (%d) >= 1000" !matrix_case_count)
    true (!matrix_case_count >= 1000);
  Printf.printf "KEYMAP_MATRIX_TOTAL_CASES=%d\n%!" !matrix_case_count

let () =
  Alcotest.run "masc_tui_keymap_matrix"
    [
      ( "axis_a_screen_dive_x_keys"
      , [
          Alcotest.test_case "34 contexts x 20 keys (680 cases)" `Quick
            test_axis_a_screen_dive_matrix;
        ] );
      ( "axis_b_overlay_focus_x_isolation"
      , [
          Alcotest.test_case "33 states x 14 isolation keys (462 cases)" `Quick
            test_axis_b_overlay_isolation_matrix;
        ] );
      ( "dynamic_rendered_hints"
      , [
          Alcotest.test_case "KO & EN rendered hint truthfulness (46 cases)"
            `Quick test_dynamic_rendered_hint_contracts;
        ] );
      ( "stateful_journeys"
      , [
          Alcotest.test_case "Slash / Palette / Filter journeys" `Quick
            test_journeys_slash_palette_filter;
          Alcotest.test_case
            "Tab / Multi-Pane / Dive / Safety journeys + >=1000 gate" `Quick
            test_journeys_tab_multipane_dives_safety;
        ] );
    ]
