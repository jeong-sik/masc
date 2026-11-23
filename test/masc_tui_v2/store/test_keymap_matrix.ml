open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_screens_core
open Masc_tui_screens_ops
open Masc_tui_screens_domain

(* A measured context reading: [ratio] of a 200k-token window. *)
let measured_context ratio : Wire_fleet.context_reading =
  Wire_fleet.Context_measured
    {
      ratio = Some ratio;
      tokens = Float.to_int (ratio *. 200_000.0);
      window = Some 200_000;
      absolute_turn = None;
      measured_at_unix = None;
    }

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
    context = obs (measured_context 0.45);
    total_turns = obs 84;
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
              operation_id = None;
              transcript_slot = None;
              failure_kind = None;
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
        id = "art-matrix-report";
        url = Some "/api/v1/published-artifacts/art-matrix-report";
        revision = 1;
        format = `Markdown;
        summary = Some "Matrix summary";
        preview = Some "# Matrix Report\n\nBody preview";
        sha256 = "aaaa1111bbbb2222";
        name = "matrix-report.md";
        mime_type = "text/markdown";
        bytes = 4096;
        created_at_unix = Some 1700000000.0;
        producer = Some "alpha";
        title = Some "Matrix Report";
        task_id = None;
        goal_id = None;
      };
      {
        id = "art-perf-trace";
        url = Some "/api/v1/published-artifacts/art-perf-trace";
        revision = 1;
        format = `Html;
        summary = Some "Perf summary";
        preview = Some "<html><body>Perf Trace</body></html>";
        sha256 = "cccc3333dddd4444";
        name = "perf-trace.html";
        mime_type = "text/html";
        bytes = 8192;
        created_at_unix = Some 1700000100.0;
        producer = Some "beta";
        title = Some "Perf Trace";
        task_id = None;
        goal_id = None;
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
    |> Knowledge_store.set_memory_diff ~keeper:None
         ~window:Knowledge_store.Window_24h
         (Observed.value ~observed_at:t0 memory_diff)
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
        calls = obs 120;
        failure_rate_pct = obs 0.0;
      };
      {
        name = "edit_file";
        description = Some "Edit file";
        calls = obs 45;
        failure_rate_pct = obs 2.0;
      };
      {
        name = "run_command";
        description = Some "Shell exec";
        calls = obs 30;
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
        resolved_local_path = "/workspace/masc";
        default_branch = "main";
        auto_sync = true;
        status = Wire_infra.Repo_active;
        keepers = [ "alpha"; "beta" ];
      };
      {
        id = "repo-docs";
        name = "masc-docs";
        codebase = None;
        url = "https://example.invalid/masc-docs";
        resolved_local_path = "/workspace/masc-docs";
        default_branch = "main";
        auto_sync = false;
        status = Wire_infra.Repo_cloning;
        keepers = [ "gamma" ];
      };
    ]
  in
  let repo_activity : Wire_infra.repository_activity =
    {
      window_hours = 24.0;
      changes =
        [
          {
            path = "lib/masc_tui/keymap/keymap.ml";
            keeper = "alpha";
            change =
              Wire_infra.Change_edit
                {
                  before = "let x = 1\nlet a = 4";
                  after = "let x = 1\nlet y = 2\nlet z = 3\nlet a = 4";
                  replace_all = false;
                };
            line_evidence =
              Some
                (Wire_infra.Edit_ranges
                   [
                     {
                       old_range = { start_line = 1; end_line = 2 };
                       new_range = Some { start_line = 1; end_line = 4 };
                     };
                   ]);
            succeeded = true;
          };
          {
            path = "lib/masc_tui/store/update_nav.ml";
            keeper = "beta";
            change = Wire_infra.Change_insert { line = 10; text = "let g = 2" };
            line_evidence = None;
            succeeded = true;
          };
          {
            path = "docs/TUI-GUIDE.md";
            keeper = "gamma";
            change = Wire_infra.Change_write { content = "# Guide\nUpdated\n" };
            line_evidence =
              Some (Wire_infra.Write_range (Some { start_line = 1; end_line = 2 }));
            succeeded = true;
          };
        ];
      incomplete = 0;
      unattributed = 0;
    }
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
    |> Infra_store.apply_repo_activity ~repo_id:"repo-masc" ~observed_at:t0
         repo_activity
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
        Attention.empty
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
      ( "Runtime/AddonsBrowser/Wide"
      , {
          (with_ws Nav.Runtime base) with
          runtime =
            Runtime_store.set_tab Nav.Runtime_addons_browser base.runtime;
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
  Alcotest.(check int) "Axis A contexts" 35 (List.length contexts);
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
                (m'.work.verification_view = m.work.verification_view);
            let is_work_tasks =
              Option.is_none dive_before
              && Option.is_none m.nav.overlay
              && Nav.equal_workspace m.nav.workspace Nav.Work
              && Nav.equal_work_tab m.work.active_tab Nav.Work_tasks_schedules
            in
            if not is_work_tasks then
              Alcotest.(check bool)
                (tag ^ " Space never bleeds work.task_status_filter")
                true
                (Work_store.equal_task_status_filter m'.work.task_status_filter
                   m.work.task_status_filter);
            let is_runtime_ab =
              Option.is_none dive_before
              && Option.is_none m.nav.overlay
              && Nav.equal_workspace m.nav.workspace Nav.Runtime
              && Nav.equal_runtime_tab m.runtime.active_tab
                   Nav.Runtime_addons_browser
            in
            if not is_runtime_ab then
              Alcotest.(check bool)
                (tag ^ " Space never bleeds runtime.browser_right_focus")
                true
                (m'.runtime.browser_right_focus = m.runtime.browser_right_focus)
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
                  || (Nav.equal_workspace m.nav.workspace Nav.Runtime
                      && Nav.equal_runtime_tab m.runtime.active_tab
                           Nav.Runtime_addons_browser)
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
  Alcotest.(check int) "Axis B states" 32 (List.length states);
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
          ( "Runtime/AddonsBrowser"
          , {
              m_base with
              nav = { m_base.nav with workspace = Nav.Runtime };
              runtime =
                Runtime_store.set_tab Nav.Runtime_addons_browser
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
            assert_has ~label ~needle:"Ctrl+S" txt)
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

  (* J4: Bare '/' single Esc clears & blurs; typed '/hel' 1st Esc dismisses popup (keeps focus), 2nd Esc blurs *)
  record_case ();
  let m_esc_bare, _ = step m1 (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "J4 bare '/' single Esc blurs composer cleanly" false
    (Drafts.is_focused m_esc_bare.drafts);
  Alcotest.(check string) "J4 bare '/' single Esc clears lone '/'" ""
    (Drafts.current_draft m_esc_bare.drafts).text;
  let m_typed, _ = type_str m_empty "/hel" in
  let m_esc1, _ = step m_typed (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "J4 typed '/hel' 1st Esc dismisses popup" true
    m_esc1.drafts.popup_dismissed;
  Alcotest.(check bool) "J4 typed '/hel' 1st Esc keeps composer focused" true
    (Drafts.is_focused m_esc1.drafts);
  let m_esc2, _ = step m_esc1 (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "J4 typed '/hel' 2nd Esc blurs composer" false
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
    let long_proc =
      List.init 40 (fun i -> Printf.sprintf "- Step %d: verify contract detail" i)
      |> String.concat "\n"
    in
    let goals =
      List.map
        (fun (g : Wire_work.goal) ->
          if String.equal g.id "goal-3" then { g with procedure = long_proc }
          else g)
        (Work_store.goals base.work)
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Work };
      work =
        base.work
        |> Work_store.apply_planning ~observed_at:t0
             { goals; tasks = Work_store.tasks base.work }
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
    let long_ctx =
      List.init 40 (fun i -> Printf.sprintf "- Detail line %02d for inbox scroll" i)
      |> String.concat "\n"
    in
    let asks =
      List.map
        (fun (a : Wire_work.ask_row) -> { a with context = Some long_ctx })
        (Work_store.asks_list base.work)
    in
    let tool_approvals =
      List.map
        (fun (ta : Wire_work.held_tool_approval) ->
          { ta with question = long_ctx })
        (Work_store.tool_approvals_list base.work)
    in
    let long_gate_json =
      "{"
      ^ (List.init 35 (fun i -> Printf.sprintf {|"k%02d":"val-%02d"|} i i)
         |> String.concat ",")
      ^ "}"
    in
    let gates =
      List.map
        (fun (g : Wire_work.gate_pending) ->
          { g with input_preview = Some long_gate_json })
        (Work_store.gate_pending_list base.work)
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Work };
      work =
        base.work
        |> Work_store.apply_asks ~observed_at:t0 asks
        |> Work_store.apply_tool_approvals ~observed_at:t0 tool_approvals
        |> Work_store.apply_gate_pending ~observed_at:t0 gates
        |> Work_store.set_tab Nav.Work_inbox;
    }
    |> Model.rebuild_attention
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
    let many_windows : Wire_runtime.provider_usage_windows =
      {
        since_unix = 1700000000.0;
        accounts =
          List.init 40 (fun i : Wire_runtime.account_usage ->
              {
                scope = "anthropic";
                scope_id = Printf.sprintf "anth-%02d" i;
                providers =
                  [
                    {
                      id = Printf.sprintf "anthropic-%02d" i;
                      display_name = Printf.sprintf "Anthropic %02d" i;
                    };
                  ];
                state =
                  Wire_runtime.Account_reported
                    [
                      {
                        limit_id = Some "5h";
                        kind = Wire_runtime.Window_five_hour;
                        role = Wire_runtime.Role_gates_model_calls;
                        utilization = Wire_runtime.Util_percent (10 + (i mod 80));
                        resets_at_unix = Some 1700018000.0;
                        observed_at_unix = 1700000000.0;
                      };
                    ];
                cost_state = Format_val.Subscription_zero;
              });
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime };
      runtime =
        base.runtime
        |> Runtime_store.apply_usage_windows ~observed_at:t0 many_windows
        |> Runtime_store.set_tab Nav.Runtime_quotas_credits;
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
    let long_wiki =
      {
        (mk_wiki_detail ~slug:"arch-overview" ~title:"Architecture Overview") with
        body_markdown =
          "# Architecture Overview\n\n"
          ^ (List.init 50 (fun i ->
                 Printf.sprintf "- Section line %02d documenting architecture" i)
             |> String.concat "\n");
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge };
      knowledge =
        base.knowledge
        |> Knowledge_store.set_wiki_page ~slug:long_wiki.slug
             (Observed.value ~observed_at:t0 long_wiki)
        |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts;
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
        Knowledge_store.set_wiki_page ~slug:"runbook"
          (Observed.value ~observed_at:t0
             (mk_wiki_detail ~slug:"runbook" ~title:"Operations Runbook"))
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
    let long_body =
      List.init 45 (fun i -> Printf.sprintf "let added_line_%02d = %d" i i)
      |> String.concat "\n"
    in
    let long_activity : Wire_infra.repository_activity =
      {
        window_hours = 24.0;
        changes =
          List.init 3 (fun i : Wire_infra.file_change ->
              {
                path = Printf.sprintf "lib/long_%d.ml" i;
                keeper = "alpha";
                change = Wire_infra.Change_write { content = long_body };
                line_evidence = None;
                succeeded = true;
              });
        incomplete = 0;
        unattributed = 0;
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Infra };
      infra =
        base.infra
        |> Infra_store.apply_repo_activity ~repo_id:"repo-masc" ~observed_at:t0
             long_activity
        |> Infra_store.set_tab Nav.Infra_repos_changes;
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
  Alcotest.(check bool)
    "J17 Infra Repos fetches the selected repository's activity" true
    (List.exists
       (function
         | Cmd.Http_get
             { req = Cmd.Get_repository_activity { repo_id = "repo-masc" }; _ }
           ->
             true
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

  (* J22: Composer Shift+Enter = newline, Ctrl+Enter = steer (a plain send on an idle Keeper), Ctrl+A/E/U *)
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
  Alcotest.(check bool) "J22 Ctrl+Enter on an idle Keeper sends without cutting a turn" true
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

  (* J23: Help '?' toggle & scroll (on compact 80x24 where Help overflows 1-col) *)
  record_case ();
  let m_h0 = populated_model ~cols:80 ~rows:24 () in
  let m_h1, _ = step m_h0 (char_key "?") in
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
    let long_proc =
      List.init 25 (fun i -> Printf.sprintf "- Narrow step %02d" i)
      |> String.concat "\n"
    in
    let goals =
      List.map
        (fun (g : Wire_work.goal) -> { g with procedure = long_proc })
        (Work_store.goals m0.work)
    in
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Work; pane_index = 0 };
      work =
        m0.work
        |> Work_store.apply_planning ~observed_at:t0
             { goals; tasks = Work_store.tasks m0.work }
        |> Work_store.set_tab Nav.Work_pipeline;
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
  let m_z_filtered =
    { m_z_kw1 with knowledge = Knowledge_store.set_filter "arch" m_z_kw1.knowledge }
  in
  let m_z_esc, _ = step m_z_filtered (mk_key Keymap.Input.Escape) in
  Alcotest.(check bool) "R6 Esc on a zoomed view resets zoomed = false" false
    m_z_esc.nav.zoomed;
  Alcotest.(check string) "R6 Esc unzooms before clearing the filter" "arch"
    m_z_esc.knowledge.filter_query;
  let m_z_esc2, _ = step m_z_esc (mk_key Keymap.Input.Escape) in
  Alcotest.(check string) "R6 second Esc clears the filter" ""
    m_z_esc2.knowledge.filter_query;

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
    fst (Update_nav.set_active_filter_query "zzz-no-match" m0)
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

  (* R9: Infra_repos_changes follows the selected repository; a stale reply is dropped *)
  record_case ();
  let repo_no_keeper : Wire_infra.repository =
    {
      id = "repo-empty";
      name = "masc-empty";
      codebase = None;
      url = "https://example.invalid/masc-empty";
      resolved_local_path = "/workspace/masc-empty";
      default_branch = "main";
      auto_sync = false;
      status = Wire_infra.Repo_active;
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
  Alcotest.(check bool) "R9 moving to repo-docs asks for repo-docs' activity"
    true
    (has_cmd
       (function
         | Cmd.Http_get
             { req = Cmd.Get_repository_activity { repo_id = "repo-docs" }; _ }
           ->
             true
         | _ -> false)
       cmds_ir1);
  let stale_activity : Wire_infra.repository_activity =
    {
      window_hours = 24.0;
      changes =
        [
          {
            path = "stale/alpha.ml";
            keeper = "alpha";
            change = Wire_infra.Change_write { content = "stale\n" };
            line_evidence = None;
            succeeded = true;
          };
        ];
      incomplete = 0;
      unattributed = 0;
    }
  in
  let m_ir_stale, _ =
    Update.step ~now:t0 m_ir1
      (Msg.Http_reply
         {
           epoch = m_ir1.epoch;
           reply =
             Msg.Reply_repository_activity
               { repo_id = "repo-masc"; result = Ok stale_activity };
         })
  in
  Alcotest.(check (list string))
    "R9 a reply for repo-masc is dropped while repo-docs is selected" []
    (List.map
       (fun (fc : Wire_infra.file_change) -> fc.path)
       (Infra_store.repo_changes m_ir_stale.infra));
  Alcotest.(check (option string)) "R9 the slot stays on repo-docs"
    (Some "repo-docs")
    (Option.map
       (fun (slot : Infra_store.repo_activity) -> slot.repo_id)
       m_ir_stale.infra.repo_activity);
  let m_ir_empty, cmds_ir_empty = step m_ir1 (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "R9 a repo whose answer is not in has focusable_pane_count = 2" 2
    (Model.focusable_pane_count m_ir_empty);
  Alcotest.(check bool)
    "R9 a repo with no assigned keepers still asks for its activity" true
    (has_cmd
       (function
         | Cmd.Http_get
             { req = Cmd.Get_repository_activity { repo_id = "repo-empty" }; _ }
           ->
             true
         | _ -> false)
       cmds_ir_empty);

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
        |> Knowledge_store.set_wiki_page ~slug:stale_page.slug
             (Observed.value ~observed_at:t0 stale_page);
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

  (* R11: Work_inbox Approval Strip parity + Ask N stays active *)
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

(* ---------- Pillar 1: Editable Keeper_config & Settings Pane_inspector ←/→ ---------- *)

let mk_keeper_rich_schema ~keeper : Wire_config.config_schema =
  let mk_f ~table ~key ~label ~kind ~value ?(writable = true) ?(secret = false)
      ?(description = None) () : Wire_config.schema_field =
    {
      table;
      key;
      full_key = table ^ "." ^ key;
      label;
      env = None;
      description;
      kind;
      value;
      default_value = Some value;
      provenance = Wire_config.Prov_keeper;
      reload_scope = Wire_config.Hot_reload;
      secret;
      writable;
    }
  in
  let extra_fields =
    List.init 10 (fun i ->
        mk_f ~table:"safety"
          ~key:(Printf.sprintf "limit_%02d" i)
          ~label:(Printf.sprintf "Limit %02d" i)
          ~kind:(Wire_config.Field_int { min = Some 1; max = Some 99 })
          ~value:(Wire_config.Val_int (10 + i))
          ~description:(Some (Printf.sprintf "Safety ceiling number %d" i))
          ())
  in
  {
    target = Wire_config.Target_keeper keeper;
    keeper = Some keeper;
    file_exists = true;
    file_sha256 = "sha-keeper-rich";
    sections =
      [
        {
          id = "identity";
          category = Wire_config.Cat_keepers_companies;
          title = "Identity";
          fields =
            [
              mk_f ~table:"keeper" ~key:"activation_mode"
                ~label:"Activation Mode"
                ~kind:(Wire_config.Field_enum [ "autonomous"; "reactive"; "manual" ])
                ~value:(Wire_config.Val_string "autonomous")
                ~description:(Some "Turn wake policy") ();
              mk_f ~table:"keeper" ~key:"paused" ~label:"Paused"
                ~kind:Wire_config.Field_bool ~value:(Wire_config.Val_bool false)
                ();
              mk_f ~table:"keeper" ~key:"max_turns" ~label:"Max Turns"
                ~kind:(Wire_config.Field_int { min = Some 1; max = Some 5 })
                ~value:(Wire_config.Val_int 3) ();
              mk_f ~table:"keeper" ~key:"group" ~label:"Group"
                ~kind:Wire_config.Field_string
                ~value:(Wire_config.Val_string "platform") ();
            ];
        };
        {
          id = "runtime";
          category = Wire_config.Cat_providers_models;
          title = "Runtime";
          fields =
            [
              mk_f ~table:"runtime" ~key:"temperature" ~label:"Temperature"
                ~kind:(Wire_config.Field_float { min = Some 0.0; max = Some 1.0 })
                ~value:(Wire_config.Val_float 0.5) ();
              mk_f ~table:"runtime" ~key:"tags" ~label:"Tags"
                ~kind:Wire_config.Field_string_list
                ~value:(Wire_config.Val_string_list [ "ops"; "prod" ]) ();
              mk_f ~table:"runtime" ~key:"api_secret" ~label:"API Secret"
                ~kind:Wire_config.Field_secret
                ~value:
                  (Wire_config.Val_secret
                     {
                       configured = true;
                       source = Wire_config.Secret_inline_redacted;
                     })
                ~writable:false ~secret:true ();
              mk_f ~table:"runtime" ~key:"readonly_id" ~label:"Readonly ID"
                ~kind:Wire_config.Field_string
                ~value:(Wire_config.Val_string "ro-42") ~writable:false ();
            ];
        };
        {
          id = "safety";
          category = Wire_config.Cat_sandbox_ssh;
          title = "Safety Limits";
          fields = extra_fields;
        };
      ];
  }

let test_pillar1_keeper_config_and_settings_lr () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en () in
  let rich_schema = mk_keeper_rich_schema ~keeper:"alpha" in
  let rich_cfg =
    Config_store.empty
    |> Config_store.set_target (Wire_config.Target_keeper "alpha")
    |> Config_store.set_tab Nav.Settings_sandbox_ssh
       (* Deliberately mismatch active_tab to prove keeper_visible_fields NEVER filters by active_tab *)
    |> Config_store.apply_schema ~observed_at:t0 rich_schema
  in
  let verify_keeper_config_context ~label m0 =
    Alcotest.(check bool) (label ^ ": is_keeper_config_active = true") true
      (Model.is_keeper_config_active m0);
    let visible = Config_store.keeper_visible_fields ~lang:m0.lang m0.config in
    Alcotest.(check int) (label ^ ": all 18 multi-section fields visible") 18
      (List.length visible);
    (* 1. ArrowDown traverses ALL 18 fields past index 3 (Group) to index 17 *)
    let m_dn =
      List.init 25 (fun _ -> mk_key Keymap.Input.Down) |> step_keys m0 |> fst
    in
    Alcotest.(check int)
      (label ^ ": ArrowDown reaches last field 17 (past index 3) and clamps")
      17 m_dn.config.selected_field_index;
    let m_home, _ = step m_dn (mk_key Keymap.Input.Home) in
    Alcotest.(check int) (label ^ ": Home returns to 0") 0
      m_home.config.selected_field_index;
    let m_end, _ = step m_home (mk_key Keymap.Input.End) in
    Alcotest.(check int) (label ^ ": End jumps directly to 17") 17
      m_end.config.selected_field_index;
    (* 2. ←/→ NEVER switches tab; cycles Field_enum and unstages back to original *)
    let m_enum_r, _ = step m_home (mk_key Keymap.Input.Right) in
    Alcotest.(check bool) (label ^ ": Right stays on Keeper_config (not hijacked)")
      true (Model.is_keeper_config_active m_enum_r);
    Alcotest.(check int) (label ^ ": Right on enum stages 1 patch") 1
      (Config_store.dirty_count m_enum_r.config);
    let m_enum_l, _ = step m_enum_r (mk_key Keymap.Input.Left) in
    Alcotest.(check int) (label ^ ": Left back to original unstages to 0") 0
      (Config_store.dirty_count m_enum_l.config);
    (* Wrap-around Left from index 0 -> last enum ("manual") *)
    let m_enum_wrap, _ = step m_enum_l (mk_key Keymap.Input.Left) in
    Alcotest.(check int) (label ^ ": Left wrap-around stages 1 patch") 1
      (Config_store.dirty_count m_enum_wrap.config);
    (* 3. Field_bool: Right/Space toggles and unstages back *)
    let m_bool, _ = step m_home (mk_key Keymap.Input.Down) in
    let m_bool_t, _ = step m_bool (char_key " ") in
    Alcotest.(check int) (label ^ ": Space toggles Field_bool (dirty=1)") 1
      (Config_store.dirty_count m_bool_t.config);
    let m_bool_t2, _ = step m_bool_t (mk_key Keymap.Input.Left) in
    Alcotest.(check int) (label ^ ": Left toggles Field_bool back (dirty=0)") 0
      (Config_store.dirty_count m_bool_t2.config);
    (* 4. Field_int clamped to [1; 5] *)
    let m_int, _ = step_keys m_home [ mk_key Keymap.Input.Down; mk_key Keymap.Input.Down ] in
    let m_int_hi, _ =
      step_keys m_int (List.init 6 (fun _ -> mk_key Keymap.Input.Right))
    in
    Alcotest.(check bool) (label ^ ": Field_int clamps at max=5") true
      (match
         Config_store.String_map.find_opt "keeper.max_turns"
           m_int_hi.config.dirty_fields
       with
       | Some (Wire_config.Set_int { value = 5; _ }) -> true
       | _ -> false);
    (* 5. Field_float steps by 0.1 clamped to [0.0; 1.0] *)
    let m_flt, _ =
      step_keys m_home (List.init 4 (fun _ -> mk_key Keymap.Input.Down))
    in
    let m_flt1, _ = step m_flt (mk_key Keymap.Input.Right) in
    Alcotest.(check bool) (label ^ ": Field_float steps +0.1 -> 0.6") true
      (match
         Config_store.String_map.find_opt "runtime.temperature"
           m_flt1.config.dirty_fields
       with
       | Some (Wire_config.Set_float { value; _ }) ->
           Float.abs (value -. 0.6) < 0.001
       | _ -> false);
    (* 6. Field_string: Right shows toast, Enter opens inline edit + Paste + Enter commits + Esc cancels *)
    let m_str, _ =
      step_keys m_home (List.init 3 (fun _ -> mk_key Keymap.Input.Down))
    in
    let m_str_r, _ = step m_str (mk_key Keymap.Input.Right) in
    Alcotest.(check int) (label ^ ": Right on string leaves dirty=0") 0
      (Config_store.dirty_count m_str_r.config);
    let m_edit, _ = step m_str (mk_key Keymap.Input.Enter) in
    Alcotest.(check bool) (label ^ ": Enter opens inline edit") true
      (Config_store.is_editing_field m_edit.config
       && Model.is_text_capture_active m_edit);
    let m_edit_p, _ = Update.step ~now:t0 m_edit (Msg.Paste_text "-v2") in
    let m_edit_c, _ = step m_edit_p (mk_key Keymap.Input.Enter) in
    Alcotest.(check bool) (label ^ ": Enter commits inline edit") true
      ((not (Config_store.is_editing_field m_edit_c.config))
       && Config_store.dirty_count m_edit_c.config = 1);
    (* Space on non-bool with dirty_count > 0 emits dry-run Post_config_patch *)
    let _, cmds_dry = step m_edit_c (char_key " ") in
    Alcotest.(check bool) (label ^ ": Space emits dry_run Post_config_patch") true
      (has_cmd
         (function
           | Cmd.Http_post { req = Cmd.Post_config_patch { dry_run = true; _ }; _ } ->
               true
           | _ -> false)
         cmds_dry);
    (* Ctrl+S emits real save Post_config_patch *)
    let _, cmds_save = step m_edit_c (char_key ~ctrl:true "s") in
    Alcotest.(check bool) (label ^ ": Ctrl+S emits save Post_config_patch") true
      (has_cmd
         (function
           | Cmd.Http_post { req = Cmd.Post_config_patch { dry_run = false; _ }; _ } ->
               true
           | _ -> false)
         cmds_save);
    (* Delete stages Remove_key and renders "(removed)" (parity with Settings) *)
    let m_del, _ = step m_str (mk_key Keymap.Input.Delete) in
    Alcotest.(check bool) (label ^ ": Delete stages Remove_key") true
      (match
         Config_store.String_map.find_opt "keeper.group"
           m_del.config.dirty_fields
       with
       | Some (Wire_config.Remove_key _) -> true
       | _ -> false);
    let txt_del = grid_all_text (render_full ~model:m_del) in
    Alcotest.(check bool) (label ^ ": Remove_key renders \"(removed)\"") true
      (Store_scroll.contains_ci ~needle:"(removed)" txt_del);
    (* Read-only & Secret refuse stepping with toast *)
    let m_sec, _ =
      step_keys m_home (List.init 6 (fun _ -> mk_key Keymap.Input.Down))
    in
    let m_sec_r, _ = step m_sec (mk_key Keymap.Input.Right) in
    Alcotest.(check int) (label ^ ": Secret field refuses Right step") 0
      (Config_store.dirty_count m_sec_r.config);
    (* '/' filters Keeper_config (NOT fleet roster!), renders filter pill in chrome sub-tab bar,
       and Esc ladder cancels edit -> clears search -> pops/pane0 *)
    let m_f1, _ = step m_home (char_key "/") in
    let m_f2, _ = type_str m_f1 "limit_09" in
    let txt_f2 = grid_all_text (render_full ~model:m_f2) in
    Alcotest.(check bool) (label ^ ": chrome sub-tab bar shows active '/' query while typing")
      true (Store_scroll.contains_ci ~needle:"limit_09" txt_f2);
    let m_f3, _ = step m_f2 (mk_key Keymap.Input.Enter) in
    let txt_f3 = grid_all_text (render_full ~model:m_f3) in
    Alcotest.(check bool) (label ^ ": chrome sub-tab bar shows '/' filter pill after Enter")
      true (Store_scroll.contains_ci ~needle:"limit_09" txt_f3);
    Alcotest.(check string) (label ^ ": '/' sets config.search_query") "limit_09"
      m_f3.config.search_query;
    Alcotest.(check string) (label ^ ": '/' leaves fleet.filter_query untouched") ""
      m_f3.fleet.filter_query;
    Alcotest.(check int) (label ^ ": filtered keeper_visible_fields = 1") 1
      (List.length (Config_store.keeper_visible_fields ~lang:m_f3.lang m_f3.config));
    let m_f_edit, _ = step m_f3 (mk_key Keymap.Input.Enter) in
    (* Mouse wheel while editing cancels editing_field_key cleanly *)
    let m_wheel, _ =
      Update.step ~now:t0 m_f_edit
        (Msg.Mouse_event
           (Keymap.Input.Wheel
              { dir = Keymap.Input.Wheel_down; col = 50; row = 12 }))
    in
    Alcotest.(check bool) (label ^ ": Mouse wheel cancels editing_field_key")
      false (Config_store.is_editing_field m_wheel.config);
    let m_esc1, _ = step m_f_edit (mk_key Keymap.Input.Escape) in
    Alcotest.(check bool) (label ^ ": Esc #1 cancels inline edit") true
      ((not (Config_store.is_editing_field m_esc1.config))
       && String.equal m_esc1.config.search_query "limit_09");
    let m_esc2, _ = step m_esc1 (mk_key Keymap.Input.Escape) in
    Alcotest.(check string) (label ^ ": Esc #2 clears config search_query") ""
      m_esc2.config.search_query;
    Alcotest.(check bool) (label ^ ": Esc #2 stays in Keeper_config") true
      (Model.is_keeper_config_active m_esc2);
    (* Dry-run diff preview J/K scrolls dry_run_scroll_offset in Keeper_config *)
    let kc_dry_hunk : Wire_config.diff_hunk =
      {
        header = "@@ -1,1 +1,20 @@";
        old_start = 1;
        old_count = 1;
        new_start = 1;
        new_count = 20;
        lines =
          List.init 20 (fun i ->
              Printf.sprintf "+kc_diff_row_%02d = %d" i i);
      }
    in
    let m_kc_dry =
      {
        m_home with
        config =
          {
            m_home.config with
            dry_run_preview =
              Config_store.Dry_run_ready
                {
                  applied = false;
                  dry_run = true;
                  target = "keeper:alpha";
                  changed = true;
                  before_sha256 = "sha-old";
                  new_sha256 = "sha-new";
                  snapshot_id = None;
                  snapshot_path = None;
                  reload_scope = Wire_config.Hot_reload;
                  unified_diff = "";
                  diff_hunks = [ kc_dry_hunk ];
                  validation_warnings = [];
                };
          };
      }
    in
    let m_kc_j, _ = step m_kc_dry (char_key ~shift:true "J") in
    Alcotest.(check bool) (label ^ ": Keeper_config Shift+J scrolls dry-run diff")
      true (m_kc_j.config.dry_run_scroll_offset > 0);
    let m_kc_k, _ = step m_kc_j (char_key ~shift:true "K") in
    Alcotest.(check int) (label ^ ": Keeper_config Shift+K decrements dry-run diff")
      0 m_kc_k.config.dry_run_scroll_offset;
    (* '[' / ']' switches keeper dive tabs *)
    let m_tab_next, _ = step m_home (char_key "]") in
    Alcotest.(check bool) (label ^ ": ']' leaves Keeper_config to next tab") false
      (Model.is_keeper_config_active m_tab_next);
    (* 'e' opens Settings overlay targeting Target_keeper alpha *)
    let m_set, _ = step m_home (char_key "e") in
    Alcotest.(check bool) (label ^ ": 'e' opens Settings overlay on Target_keeper")
      true
      ((match m_set.nav.overlay with
        | Some (Nav.Settings _) -> true
        | Some
            ( Nav.Palette
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Help
            | Nav.System_gate _ )
        | None ->
            false)
       && m_set.config.target = Wire_config.Target_keeper "alpha");
    (* Dangling edit & target guard: e -> n (Target_keeper_create + editing) -> Ctrl+K -> Esc
       must cancel editing_field_key and restore Target_keeper alpha! *)
    let m_leak_n, _ = step m_set (char_key "n") in
    Alcotest.(check bool) (label ^ ": e -> n enters Target_keeper_create editing")
      true
      (m_leak_n.config.target = Wire_config.Target_keeper_create
       && Config_store.is_editing_field m_leak_n.config);
    let m_leak_pal, _ = step m_leak_n (char_key ~ctrl:true "k") in
    Alcotest.(check bool) (label ^ ": Ctrl+K cancels dangling editing_field_key")
      false (Config_store.is_editing_field m_leak_pal.config);
    let m_leak_esc, _ = step m_leak_pal (mk_key Keymap.Input.Escape) in
    Alcotest.(check bool)
      (label ^ ": e -> n -> Ctrl+K -> Esc restores Target_keeper alpha & editing=false")
      true
      (m_leak_esc.config.target = Wire_config.Target_keeper "alpha"
       && not (Config_store.is_editing_field m_leak_esc.config));
    (* Rendered hints & body truth check *)
    let g = render_full ~model:m_edit_c in
    let txt = grid_all_text g in
    Alcotest.(check bool) (label ^ ": rendered hints show Ctrl+S") true
      (Store_scroll.contains_ci ~needle:"Ctrl+S" txt);
    Alcotest.(check bool) (label ^ ": header omits misleading [↔]") false
      (Store_scroll.contains_ci ~needle:"[↔]" txt);
    Alcotest.(check bool) (label ^ ": sub-tab bar omits misleading [←→] Tabs") false
      (Store_scroll.contains_ci ~needle:"[←→] Tabs" txt);
    Alcotest.(check bool) (label ^ ": sub-tab bar shows truthful [[ ]] Tabs") true
      (Store_scroll.contains_ci ~needle:"[[ ]] Tabs" txt);
    Alcotest.(check bool) (label ^ ": rendered body shows Keeper Profile band") true
      (Store_scroll.contains_ci ~needle:"alpha Keeper Profile" txt);
    Alcotest.(check bool) (label ^ ": rendered body shows Activation Mode field") true
      (Store_scroll.contains_ci ~needle:"Activation Mode" txt);
    let g_end = render_full ~model:m_end in
    let txt_end = grid_all_text g_end in
    Alcotest.(check bool) (label ^ ": rendered body after End shows Limit 09") true
      (Store_scroll.contains_ci ~needle:"Limit 09" txt_end)
  in
  let m_dive =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_config } ];
        };
      config = rich_cfg;
    }
  in
  verify_keeper_config_context ~label:"Dive_keeper" m_dive;
  let m_split =
    (* Move fleet selection from index 0 (ops/gamma) to index 1 (platform/alpha) *)
    let m_kp0 = { base with nav = { base.nav with workspace = Nav.Keepers } } in
    let m_kp_alpha, _ = step m_kp0 (mk_key Keymap.Input.Down) in
    {
      m_kp_alpha with
      nav = { m_kp_alpha.nav with workspace = Nav.Keepers; pane_index = 1 };
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_config m_kp_alpha.fleet;
      config = rich_cfg;
    }
  in
  verify_keeper_config_context ~label:"Split_pane1" m_split;
  (* Zoomed Keepers (z) Keeper_config: '['/']' keeps zoom active and cycles keeper tabs (not fleet_mode) *)
  let m_zoom, _ = step m_split (char_key "z") in
  Alcotest.(check bool) "Zoomed Keepers Keeper_config is active & zoomed" true
    (m_zoom.nav.zoomed && Model.is_keeper_config_active m_zoom);
  let txt_zoom = grid_all_text (render_full ~model:m_zoom) in
  Alcotest.(check bool) "Zoomed Keeper_config sub-tab bar omits [←→] Tabs" false
    (Store_scroll.contains_ci ~needle:"[←→] Tabs" txt_zoom);
  let m_zoom_next, _ = step m_zoom (char_key "]") in
  Alcotest.(check bool)
    "Zoomed Keeper_config ']' keeps zoom active & cycles keeper_dive_tab (not fleet_mode)"
    true
    (m_zoom_next.nav.zoomed
     && (not (Nav.equal_keeper_tab m_zoom_next.fleet.keeper_dive_tab Nav.Keeper_config))
     && m_zoom_next.fleet.fleet_mode = m_zoom.fleet.fleet_mode);
  let m_zoom_back, _ = step m_zoom_next (char_key "[") in
  Alcotest.(check bool) "Zoomed Keepers '[' returns to Keeper_config while zoomed"
    true (m_zoom_back.nav.zoomed && Model.is_keeper_config_active m_zoom_back);
  (* Settings Pane_inspector ←/→ on BOTH wide (140 cols) and narrow (68 cols),
     INCLUDING when tui.theme & tui.language exist in server runtime.toml schema! *)
  let runtime_schema_with_tui : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha-rt-tui";
      sections =
        [
          {
            id = "tui";
            category = Wire_config.Cat_general_ui;
            title = "General & UI";
            fields =
              [
                {
                  table = "tui";
                  key = "theme";
                  full_key = "tui.theme";
                  label = "Theme";
                  env = None;
                  description = Some "TUI theme preset";
                  kind =
                    Wire_config.Field_enum
                      [ "midnight"; "arcade_hi"; "paper_light"; "mono" ];
                  value = Wire_config.Val_string "midnight";
                  default_value = Some (Wire_config.Val_string "midnight");
                  provenance = Wire_config.Prov_global;
                  reload_scope = Wire_config.Hot_reload;
                  secret = false;
                  writable = true;
                };
                {
                  table = "tui";
                  key = "language";
                  full_key = "tui.language";
                  label = "Language";
                  env = None;
                  description = Some "UI Language";
                  kind = Wire_config.Field_enum [ "ko"; "en" ];
                  value = Wire_config.Val_string "en";
                  default_value = Some (Wire_config.Val_string "en");
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
  let m_set_wide0, _ = step base (char_key ~ctrl:true ",") in
  let m_set_wide =
    {
      m_set_wide0 with
      config =
        Config_store.apply_schema ~observed_at:t0 runtime_schema_with_tui
          m_set_wide0.config;
    }
  in
  Alcotest.(check bool) "Settings wide opens on Pane_inspector" true
    (m_set_wide.config.settings_pane = Config_store.Pane_inspector);
  let m_set_tree, _ = step m_set_wide (mk_key Keymap.Input.Tab) in
  Alcotest.(check bool) "Settings wide Tab toggles Pane_inspector -> Pane_tree"
    true (m_set_tree.config.settings_pane = Config_store.Pane_tree);
  let m_set_insp, _ = step m_set_tree (mk_key Keymap.Input.Tab) in
  Alcotest.(check bool) "Settings wide 2nd Tab -> Pane_inspector" true
    (m_set_insp.config.settings_pane = Config_store.Pane_inspector);
  let theme_before = m_set_insp.theme_preset in
  let m_set_r, cmds_pref = step m_set_insp (mk_key Keymap.Input.Right) in
  Alcotest.(check bool) "Settings wide Right steps schema-backed tui.theme live"
    true (m_set_r.theme_preset <> theme_before);
  Alcotest.(check int) "Settings wide Right stages tui.theme dirty=1" 1
    (Config_store.dirty_count m_set_r.config);
  Alcotest.(check bool) "Settings wide Right emits Post_tui_preference" true
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_tui_preference _; _ } -> true
         | _ -> false)
       cmds_pref);
  let m_set_l, cmds_revert = step m_set_r (mk_key Keymap.Input.Left) in
  Alcotest.(check int)
    "Settings wide Left back to original unstages tui.theme (dirty=0)" 0
    (Config_store.dirty_count m_set_l.config);
  Alcotest.(check bool)
    "Settings wide Left back to original STILL reverts live theme_preset" true
    (m_set_l.theme_preset = theme_before);
  Alcotest.(check bool)
    "Settings wide Left back to original STILL emits Post_tui_preference revert"
    true
    (has_cmd
       (function
         | Cmd.Http_post { req = Cmd.Post_tui_preference _; _ } -> true
         | _ -> false)
       cmds_revert);
  (* Narrow Settings (68 cols): 1-pane inspector ←/→ steps enum directly *)
  let base_narrow = populated_model ~cols:68 ~rows:28 ~lang:Say.Lang_en () in
  let m_sn, _ = step base_narrow (char_key ~ctrl:true ",") in
  let m_sn_r, cmds_sn = step m_sn (mk_key Keymap.Input.Right) in
  Alcotest.(check bool) "Settings narrow Right steps tui.theme live" true
    (m_sn_r.theme_preset <> m_sn.theme_preset
     && has_cmd
          (function
            | Cmd.Http_post { req = Cmd.Post_tui_preference _; _ } -> true
            | _ -> false)
          cmds_sn);
  (* Wide Settings Left on non-steppable string field returns to Pane_tree *)
  let m_set_str =
    {
      m_set_insp with
      config =
        rich_cfg
        |> Config_store.set_tab Nav.Settings_keepers_companies
        |> Config_store.set_pane Config_store.Pane_inspector
        |> fun c -> { c with selected_field_index = 3 };
    }
  in
  let m_set_back, _ = step m_set_str (mk_key Keymap.Input.Left) in
  Alcotest.(check bool) "Settings wide Left on Field_string leaves to Pane_tree"
    true (m_set_back.config.settings_pane = Config_store.Pane_tree);
  (* Settings dry-run diff J/K scrolls dry_run_scroll_offset cleanly for diff_hunks & exact diff_r.h *)
  let set_dry_hunk : Wire_config.diff_hunk =
    {
      header = "@@ -1,1 +1,40 @@";
      old_start = 1;
      old_count = 1;
      new_start = 1;
      new_count = 40;
      lines =
        List.init 40 (fun i -> Printf.sprintf "+SET_DRY_LINE_%02d = true" i);
    }
  in
  let m_set_dry =
    {
      m_set_insp with
      config =
        {
          m_set_insp.config with
          dry_run_preview =
            Config_store.Dry_run_ready
              {
                applied = false;
                dry_run = true;
                target = "runtime";
                changed = true;
                before_sha256 = "sha-old";
                new_sha256 = "sha-new";
                snapshot_id = None;
                snapshot_path = None;
                reload_scope = Wire_config.Hot_reload;
                unified_diff = "";
                diff_hunks = [ set_dry_hunk ];
                validation_warnings = [];
              };
        };
    }
  in
  let m_set_j_end =
    List.init 45 (fun _ -> char_key ~shift:true "J") |> step_keys m_set_dry |> fst
  in
  Alcotest.(check bool) "Settings Shift+J scrolls diff_hunks > 0" true
    (m_set_j_end.config.dry_run_scroll_offset > 0);
  let txt_set_dry = grid_all_text (render_full ~model:m_set_j_end) in
  Alcotest.(check bool) "Settings dry-run at bottom renders SET_DRY_LINE_39" true
    (Store_scroll.contains_ci ~needle:"SET_DRY_LINE_39" txt_set_dry);
  let m_set_k1, _ = step m_set_j_end (char_key ~shift:true "K") in
  Alcotest.(check int)
    "Settings Shift+K from bottom immediately decrements by 1 (zero sticky K)"
    (m_set_j_end.config.dry_run_scroll_offset - 1)
    m_set_k1.config.dry_run_scroll_offset

(* ---------- Pillar 2: All 16 ArrowDown / End / Viewport Scroll Bounds ---------- *)

let test_pillar2_scroll_bounds_all_surfaces () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en () in
  (* 1. Keeper_memory & Keeper_work_candle: >160 rows, End reaches exact bottom, no overshoot, ArrowUp steps -1 *)
  let big_facts =
    List.init 220 (fun i : Wire_knowledge.memory_fact_entry ->
        {
          added_at_rev = Some 2;
          memory_id = Printf.sprintf "fact-%03d" i;
          category = "verified";
          origin = "alpha";
          text = Printf.sprintf "Detail fact line %03d" i;
          first_seen_unix = 1700000000.0 +. float_of_int i;
          last_seen_unix = Some (1700000010.0 +. float_of_int i);
          retrieval_count = 1;
          last_retrieved_at_unix = None;
          heat = Wire_knowledge.Heat_hot;
        })
  in
  let big_diff : Wire_knowledge.memory_diff =
    {
      scope = Wire_knowledge.Scope_keeper "alpha";
      range =
        {
          window = Some "24h";
          from_rev = Some 1;
          to_rev = Some 2;
          from_unix = None;
          to_unix = None;
        };
      retrieval_heat =
        {
          hot = 220;
          warm = 0;
          cold = 0;
          never_retrieved = 0;
          total_events = 220;
          unreadable_event_lines = 0;
        };
      body =
        Wire_knowledge.Keeper_diff
          {
            counts =
              {
                total_facts_now = 220;
                added = 220;
                updated = 0;
                retracted = 0;
                invalidated = 1;
                journal_failures_in_window = 0;
                journal_quarantines_in_window = 0;
                undecodable_journal_lines = 0;
              };
            revisions = [];
            added = big_facts;
            updated = [];
            retracted = [];
            invalidated =
              [
                {
                  memory_id = "inv-1";
                  text = "Invalidated stale premise";
                  at_rev = 2;
                  missing_premise_ids = [ "prem-secret-99" ];
                };
              ];
            writer_status = None;
          };
    }
  in
  let m_kmem =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_memory } ];
        };
      knowledge =
        base.knowledge
        |> Knowledge_store.set_memory_diff_keeper (Some "alpha")
        |> Knowledge_store.set_memory_view_mode Knowledge_store.View_diff
        |> Knowledge_store.set_memory_diff ~keeper:(Some "alpha")
             ~window:Knowledge_store.Window_24h
             (Observed.value ~observed_at:t0 big_diff);
    }
  in
  let m_kmem_end, _ = step m_kmem (mk_key Keymap.Input.End) in
  Alcotest.(check bool) "Keeper_memory End goes past old 160 cap (>180)" true
    (m_kmem_end.nav.dive_scroll_offset > 180);
  let m_kmem_dn, _ = step m_kmem_end (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "Keeper_memory Down at End does NOT overshoot"
    m_kmem_end.nav.dive_scroll_offset m_kmem_dn.nav.dive_scroll_offset;
  let m_kmem_up, _ = step m_kmem_end (mk_key Keymap.Input.Up) in
  Alcotest.(check int) "Keeper_memory Up from End immediately decrements by 1"
    (m_kmem_end.nav.dive_scroll_offset - 1) m_kmem_up.nav.dive_scroll_offset;
  let txt_kmem = grid_all_text (render_full ~model:m_kmem_end) in
  Alcotest.(check bool) "Keeper_memory at End renders bottom row (never blank)"
    true
    (Store_scroll.contains_ci ~needle:"Detail fact line 219" txt_kmem
     || Store_scroll.contains_ci ~needle:"Invalidated stale premise" txt_kmem);
  (* 2. Keeper_work_candle: >160 rows (tasks + schedules + posts), no skip > 0 jump, exact clamp *)
  let many_alpha_tasks =
    List.init 100 (fun i ->
        mk_task
          ~id:(Printf.sprintf "alpha-task-%03d" i)
          ~title:(Printf.sprintf "Alpha deliverable %03d" i)
          ~goal_id:(Some "goal-1"))
  in
  let many_alpha_scheds =
    List.init 100 (fun i ->
        mk_schedule
          ~id:(Printf.sprintf "alpha-sched-%03d" i)
          ~name:(Printf.sprintf "alpha-cron-%03d" i)
          ~keeper:"alpha")
  in
  let many_alpha_posts =
    List.init 20 (fun i ->
        mk_post
          ~id:(Printf.sprintf "alpha-post-%03d" i)
          ~title:(Printf.sprintf "Alpha board update %03d" i)
          ~author:"alpha" ~signal:true)
  in
  let m_kwc =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_work_candle } ];
        };
      work =
        base.work
        |> Work_store.apply_planning ~observed_at:t0
             { goals = Work_store.goals base.work; tasks = many_alpha_tasks }
        |> Work_store.apply_schedules ~observed_at:t0 (many_alpha_scheds, None);
      knowledge =
        Knowledge_store.apply_board ~observed_at:t0
          {
            posts = many_alpha_posts;
            count = List.length many_alpha_posts;
            sort_by = "hot";
            signal_only = false;
          }
          base.knowledge;
    }
  in
  let m_kwc_end, _ = step m_kwc (mk_key Keymap.Input.End) in
  Alcotest.(check bool) "Keeper_work_candle End goes past old 160 cap" true
    (m_kwc_end.nav.dive_scroll_offset > 160);
  let m_kwc_dn, _ = step m_kwc_end (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "Keeper_work_candle Down at End clamps cleanly"
    m_kwc_end.nav.dive_scroll_offset m_kwc_dn.nav.dive_scroll_offset;
  let txt_kwc = grid_all_text (render_full ~model:m_kwc_end) in
  Alcotest.(check bool) "Keeper_work_candle at End renders last post row (never blank)"
    true (Store_scroll.contains_ci ~needle:"Alpha board update 019" txt_kwc);
  (* 3. Keepers Split pane 1 Keeper_chat uses ~embedded:true geometry & renders exact top msg *)
  let m_split_chat =
    let m_kp0 = { base with nav = { base.nav with workspace = Nav.Keepers } } in
    let m_kp_alpha, _ = step m_kp0 (mk_key Keymap.Input.Down) in
    {
      m_kp_alpha with
      nav = { m_kp_alpha.nav with workspace = Nav.Keepers; pane_index = 1 };
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_chat m_kp_alpha.fleet;
    }
  in
  let m_split_home, _ = step m_split_chat (mk_key Keymap.Input.Home) in
  Alcotest.(check bool)
    "Keepers Split pane 1 Keeper_chat Home scrolls > 0" true
    (m_split_home.fleet.chat_scroll_offset > 0);
  let m_split_up, _ = step m_split_home (mk_key Keymap.Input.Up) in
  Alcotest.(check int) "Keepers Split pane 1 Keeper_chat Up at Home clamps"
    m_split_home.fleet.chat_scroll_offset m_split_up.fleet.chat_scroll_offset;
  let m_split_dn, _ = step m_split_home (mk_key Keymap.Input.Down) in
  Alcotest.(check int)
    "Keepers Split pane 1 Keeper_chat Down from Home decrements by 1"
    (m_split_home.fleet.chat_scroll_offset - 1)
    m_split_dn.fleet.chat_scroll_offset;
  let txt_split_top = grid_all_text (render_full ~model:m_split_home) in
  Alcotest.(check bool)
    "Keepers Split pane 1 Keeper_chat at Home renders first message (line 0)"
    true (Store_scroll.contains_ci ~needle:"Message content line 0" txt_split_top);
  (* 4. Knowledge > Artifacts pane 1 detail_scroll_offset works and renders scrolled slice *)
  let many_artifacts =
    List.init 60 (fun i : Wire_knowledge.artifact_entry ->
        {
          id = Printf.sprintf "art-%04d" i;
          url = Some (Printf.sprintf "/api/v1/published-artifacts/art-%04d" i);
          revision = 1;
          format = `Markdown;
          summary = None;
          preview = None;
          sha256 = Printf.sprintf "sha-%04d-abcdef" i;
          name = Printf.sprintf "artifact-%02d.log" i;
          title = Some (Printf.sprintf "Artifact Report %02d" i);
          mime_type = "text/plain";
          bytes = 1024 * (i + 1);
          created_at_unix = Some 1700000000.0;
          producer = Some "alpha";
          task_id = None;
          goal_id = None;
        })
  in
  let m_art_tall =
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge; pane_index = 1 };
      knowledge =
        base.knowledge
        |> Knowledge_store.apply_artifacts ~observed_at:t0 many_artifacts
        |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts
        |> Knowledge_store.toggle_wiki_artifacts_submode;
    }
  in
  let m_art_tall_end, _ = step m_art_tall (mk_key Keymap.Input.End) in
  Alcotest.(check int)
    "Knowledge > Artifacts pane 1 (tall viewport) clamps 5-row detail cleanly to 0"
    0 m_art_tall_end.knowledge.detail_scroll_offset;
  let m_art_dive =
    {
      m_art_tall with
      nav =
        {
          m_art_tall.nav with
          dive_stack =
            [ Nav.Dive_knowledge (Nav.Artifact_dive (Printf.sprintf "artifact-%032d" 0)) ];
        };
    }
  in
  let m_art_dive_end, _ = step m_art_dive (mk_key Keymap.Input.End) in
  Alcotest.(check bool)
    "Knowledge > Artifact_dive End scrolls 60 revisions > 0" true
    (m_art_dive_end.nav.dive_scroll_offset > 0);
  let txt_art = grid_all_text (render_full ~model:m_art_dive_end) in
  Alcotest.(check bool)
    "Knowledge > Artifact_dive at End renders last Artifact Report 59" true
    (Store_scroll.contains_ci ~needle:"Artifact Report 59" txt_art);
  (* 4b. Knowledge > Wiki pane 1 with wide 22-col TOC rail wraps prose cleanly & reaches exact bottom *)
  let long_wiki_toc =
    {
      (mk_wiki_detail ~slug:"arch-overview" ~title:"Architecture Overview") with
      body_markdown =
        "# Architecture Overview\n\n## Section One\n\n"
        ^ (List.init 60 (fun i ->
               Printf.sprintf
                 "- Bullet %02d with enough wrapped prose width to exercise the \
                  22-column TOC rail layout cleanly"
                 i)
           |> String.concat "\n")
        ^ "\n\n## Final Marker\n\nFINAL_WIKI_BOTTOM_LINE";
    }
  in
  let m_wiki_toc =
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge; pane_index = 1 };
      knowledge =
        base.knowledge
        |> Knowledge_store.set_wiki_page ~slug:long_wiki_toc.slug
             (Observed.value ~observed_at:t0 long_wiki_toc)
        |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts;
    }
  in
  let m_wiki_end, _ = step m_wiki_toc (mk_key Keymap.Input.End) in
  Alcotest.(check bool) "Knowledge > Wiki pane 1 (22-col TOC) End scrolls > 40"
    true (m_wiki_end.knowledge.detail_scroll_offset > 40);
  let m_wiki_dn, _ = step m_wiki_end (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "Knowledge > Wiki pane 1 Down at End clamps cleanly"
    m_wiki_end.knowledge.detail_scroll_offset
    m_wiki_dn.knowledge.detail_scroll_offset;
  let txt_wiki = grid_all_text (render_full ~model:m_wiki_end) in
  Alcotest.(check bool)
    "Knowledge > Wiki pane 1 at End renders FINAL_WIKI_BOTTOM_LINE (never blank)"
    true (Store_scroll.contains_ci ~needle:"FINAL_WIKI_BOTTOM_LINE" txt_wiki);
  (* 5. Runtime > Failover Lanes pane 0 keeps last lane child slots in viewport *)
  let many_lanes =
    List.init 8 (fun i : Wire_runtime.failover_lane ->
        {
          id = Printf.sprintf "lane-%02d" i;
          declared = true;
          runtime_ids =
            List.init 5 (fun j -> Printf.sprintf "slot-%02d-%d" i j);
        })
  in
  let m_lanes =
    let rr : Wire_runtime.runtime_resolved_snapshot =
      {
        generated_at_iso = "2026-11-22T00:00:00Z";
        config_path = None;
        default_route = Some "lane-00";
        lanes = many_lanes;
        runtimes = [];
        usage_windows = None;
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime; pane_index = 0 };
      runtime =
        base.runtime
        |> Runtime_store.set_tab Nav.Runtime_failover_lanes
        |> Runtime_store.apply_runtime_resolved ~observed_at:t0 rr;
    }
  in
  let m_lanes_end, _ = step m_lanes (mk_key Keymap.Input.End) in
  let txt_lanes = grid_all_text (render_full ~model:m_lanes_end) in
  let last_slot_lbl = Wire_runtime.human_runtime_slot_label "slot-07-4" in
  Alcotest.(check bool)
    "Runtime > Failover Lanes pane 0 End keeps last lane's last child slot visible"
    true (Store_scroll.contains_ci ~needle:last_slot_lbl txt_lanes);
  (* 6. Queue_context (Ctrl+T) scrolls cleanly bounded *)
  let many_scheds =
    List.init 80 (fun i ->
        mk_schedule
          ~id:(Printf.sprintf "sched-inst-%03d" i)
          ~name:(Printf.sprintf "job-%03d" i)
          ~keeper:"alpha")
  in
  let m_q0 =
    {
      base with
      work =
        Work_store.apply_schedules ~observed_at:t0 (many_scheds, None) base.work;
    }
  in
  let m_q1, _ = step_keys m_q0 [ char_key ~ctrl:true "t"; char_key "]"; char_key "]" ] in
  let m_q_end, _ = step m_q1 (mk_key Keymap.Input.End) in
  Alcotest.(check bool) "Queue_context (Ctrl+T) End scrolls > 0" true
    (m_q_end.nav.queue_scroll_offset > 0);
  let m_q_dn, _ = step m_q_end (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "Queue_context Down at End clamps cleanly"
    m_q_end.nav.queue_scroll_offset m_q_dn.nav.queue_scroll_offset;
  let txt_q = grid_all_text (render_full ~model:m_q_end) in
  Alcotest.(check bool) "Queue_context at End renders last schedule row" true
    (Store_scroll.contains_ci ~needle:"job-079" txt_q);
  (* 7. Work > Pipeline height-14 race: inner_body_height=14 => false, 15 => true *)
  let mk_wp_h ~rows =
    let m0 = populated_model ~cols:140 ~rows ~with_attention:true () in
    let drafts =
      m0.drafts
      |> Drafts.set_focus true
      |> Drafts.set_current_text "l1\nl2\nl3\nl4\nl5"
    in
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Work };
      work = Work_store.set_tab Nav.Work_pipeline m0.work;
      drafts;
    }
  in
  let m_h14 = mk_wp_h ~rows:24 in
  let m_h15 = mk_wp_h ~rows:25 in
  Alcotest.(check int) "m_h14 inner_body_height = 14" 14
    (Model.inner_body_height m_h14);
  Alcotest.(check int) "m_h15 inner_body_height = 15" 15
    (Model.inner_body_height m_h15);
  Alcotest.(check bool)
    "work_pipeline_has_linked_card false when inner_body_height=14 (left_rect.h=13)"
    false (Model.work_pipeline_has_linked_card m_h14);
  Alcotest.(check bool)
    "work_pipeline_has_linked_card true when inner_body_height=15 (left_rect.h=14)"
    true (Model.work_pipeline_has_linked_card m_h15);
  (* 8. Knowledge > Memory filtered_memory_diff_items matches missing_premise_ids & pane 0 scrolls writers when conflicts=[] *)
  let k_prem =
    m_kmem.knowledge |> Knowledge_store.set_filter "prem-secret-99"
  in
  Alcotest.(check int)
    "filtered_memory_diff_items matches inv.missing_premise_ids" 1
    (List.length (Knowledge_store.filtered_memory_diff_items k_prem));
  let many_writers =
    List.init 35 (fun i : Wire_knowledge.librarian_writer_row ->
        {
          keeper = Printf.sprintf "writer-%02d" i;
          state = Wire_knowledge.Writer_open;
          available_act_tokens = [];
          snapshot_file = None;
        })
  in
  let m_mem_w =
    let wm : Wire_knowledge.world_memory =
      {
        ledger_state = Wire_knowledge.World_ledger_available;
        ledger_sha256 = Some "sha-wm";
        claims_count = 0;
        facts_count = 0;
        conflicts_count = 0;
        excluded_count = 0;
        claims = [];
        active_conflicts = [];
        briefing =
          {
            status = Wire_knowledge.Briefing_missing;
            text = None;
            source_ids_count = 0;
            error = None;
            building_pass = None;
          };
        librarian_writers =
          Wire_knowledge.Writers_running
            { error_count = 0; warn_count = 0; keepers = many_writers };
        ordinary_absence_detail = None;
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge; pane_index = 0 };
      knowledge =
        base.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_memory
        |> Knowledge_store.apply_world_memory ~observed_at:t0 wm;
    }
  in
  let m_mem_w_end, _ = step m_mem_w (mk_key Keymap.Input.End) in
  Alcotest.(check int)
    "Knowledge > Memory pane 0 scrolls World + librarian_writers when conflicts=[]"
    35 m_mem_w_end.knowledge.selected_index;
  Alcotest.(check (option string))
    "Selecting last writer updates memory_diff_keeper" (Some "writer-34")
    m_mem_w_end.knowledge.memory_diff_keeper;
  (* 9. Incidents detail J/K scrolls detail_scroll_offset *)
  let m_inc =
    let inc, _ =
      Incidents.push ~occurred_at_unix:1700000000.0
        ~source:Health.Source_client_http
        ~summary:(Say.make ~ko:"긴 트레이스" ~en:"long trace")
        ~detail:
          (List.init 40 (fun i -> Printf.sprintf "frame %02d: stack detail" i)
           |> String.concat "\n")
        ~status:Health.Resolved base.incidents
    in
    {
      base with
      incidents = inc;
      nav = { base.nav with overlay = Some Nav.Incidents };
    }
  in
  let m_inc_j, _ = step m_inc (char_key ~shift:true "J") in
  Alcotest.(check bool) "Incidents Shift+J scrolls detail_scroll_offset" true
    (m_inc_j.incidents.detail_scroll_offset > 0);
  ignore (render_full ~model:m_inc_j);
  (* 10. Non-trivial bottom-row render + zero-sticky-ArrowUp proof for EVERY fixed surface & all 9 Dives *)
  let assert_scroll_exact ~label ~needle ~get_off (m0 : Model.t) =
    let m_end, _ = step m0 (mk_key Keymap.Input.End) in
    let off_end = get_off m_end in
    Alcotest.(check bool) (label ^ ": End scrolls > 0") true (off_end > 0);
    let m_dn, _ = step m_end (mk_key Keymap.Input.Down) in
    Alcotest.(check int) (label ^ ": Down at End clamps cleanly (zero overshoot)")
      off_end (get_off m_dn);
    let m_up, _ = step m_end (mk_key Keymap.Input.Up) in
    Alcotest.(check int)
      (label ^ ": Up from End decrements by 1 (zero sticky ArrowUp)")
      (off_end - 1) (get_off m_up);
    let txt = grid_all_text (render_full ~model:m_end) in
    Alcotest.(check bool) (label ^ ": render_full at End shows bottom sentinel " ^ needle)
      true (Store_scroll.contains_ci ~needle txt)
  in
  (* 10-wave1-a. Runtime > Addons & Browser: Left Addons, Right Clients, Right Tabs + compact clamp *)
  let many_addons : Wire_runtime.lane_addons_snapshot =
    {
      configuration_complete = true;
      declarations = [];
      issues = [];
      instances =
        List.init 30 (fun i : Wire_runtime.addon_instance ->
            {
              runtime_presence = Wire_runtime.Addon_live;
              instance_id = Printf.sprintf "inst-ab-%02d" i;
              addon_id = Printf.sprintf "addon-ab-%02d" i;
              title = Printf.sprintf "Addon Title %02d" i;
              revision = "r1";
              phase = Wire_runtime.Addon_observing;
              execution_kind = Some "host_process";
              resolved_image = None;
              observation_seq = i;
              rows_count = i;
              observation_pending = false;
              visibility_kind = Some "shared";
              visibility_keeper = None;
              host_cycles = Some i;
              host_waiting_count = 0;
              host_issue_kind = None;
              action_names = [ "observe" ];
              config_declaration_id = None;
            });
    }
  in
  let many_clients : Wire_runtime.browser_lane_status =
    {
      ok = true;
      available = true;
      inventory_complete = false;
      client_count = 30;
      issue_count = 2;
      automatic_browse_ok = true;
      detail = None;
      clients =
        List.init 30 (fun i : Wire_runtime.browser_client_row ->
            {
              client_id = Printf.sprintf "ego-client-%02d" i;
              browser = "Ego";
              version = "131";
              engine_version = "131";
              transport = "ego";
              space = Some { space_id = i + 1; space_name = Printf.sprintf "space-%02d" i };
              ownership = Some "agent";
              presence_state = Some "present";
              presence_reason = None;
              interactions = [];
              last_activities = [];
            });
      issues =
        [
          {
            kind = "ego_user_owned_space";
            instance_id = Some "inst-0";
            client_id = None;
            space = Some "personal";
            space_id = None;
            message = "personal space";
          };
          {
            kind = "ego_space_missing";
            instance_id = Some "inst-1";
            client_id = None;
            space = Some "missing";
            space_id = Some 9;
            message = "missing space";
          };
        ];
    }
  in
  let many_tabs : Wire_runtime.browser_tabs_response =
    {
      client_id = Some "ego-client-00";
      complete = true;
      unavailable_count = 0;
      error = None;
      tabs =
        List.init 25 (fun i : Wire_runtime.browser_tab_row ->
            {
              id = 100 + i;
              title = Printf.sprintf "TabSentinel-%02d" i;
              url = Printf.sprintf "https://example.com/tab-%02d" i;
              active = i = 0;
              window_id = Some 1;
              opened_by = Some Wire_runtime.Tab_origin_agent;
              label = None;
              dialog_present = false;
              dialog_kind = None;
            });
    }
  in
  let m_ab_base =
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime; pane_index = 0 };
      runtime =
        base.runtime
        |> Runtime_store.set_tab Nav.Runtime_addons_browser
        |> Runtime_store.apply_lane_addons ~observed_at:t0 many_addons
        |> Runtime_store.apply_browser_lane ~observed_at:t0 many_clients
        |> Runtime_store.apply_browser_tabs ~observed_at:t0
             ~client_id:"ego-client-00" many_tabs;
    }
  in
  let m_ab_l_end, _ = step m_ab_base (mk_key Keymap.Input.End) in
  Alcotest.(check int) "AddonsBrowser Left End selects last addon (29)" 29
    m_ab_l_end.runtime.addon_selected_index;
  Alcotest.(check bool) "AddonsBrowser Left End scrolls addon_scroll_offset > 0"
    true (m_ab_l_end.runtime.addon_scroll_offset > 0);
  let txt_ab_l = grid_all_text (render_full ~model:m_ab_l_end) in
  Alcotest.(check bool) "AddonsBrowser Left End renders Addon Title 29" true
    (Store_scroll.contains_ci ~needle:"Addon Title 29" txt_ab_l);
  let m_ab_cl =
    { m_ab_base with nav = { m_ab_base.nav with pane_index = 1 } }
  in
  let m_ab_cl_end, _ = step m_ab_cl (mk_key Keymap.Input.End) in
  Alcotest.(check int) "AddonsBrowser Right Clients End selects last client (29)"
    29 m_ab_cl_end.runtime.browser_client_selected_index;
  Alcotest.(check bool)
    "AddonsBrowser Right Clients End scrolls browser_client_scroll_offset > 15 (exact clients_h)"
    true (m_ab_cl_end.runtime.browser_client_scroll_offset > 15);
  let txt_ab_cl = grid_all_text (render_full ~model:m_ab_cl_end) in
  Alcotest.(check bool) "AddonsBrowser Right Clients End renders space-29" true
    (Store_scroll.contains_ci ~needle:"space-29" txt_ab_cl);
  let m_ab_tb =
    {
      m_ab_cl with
      runtime = Runtime_store.toggle_browser_right_focus m_ab_cl.runtime;
    }
  in
  let m_ab_tb_end, _ = step m_ab_tb (mk_key Keymap.Input.End) in
  Alcotest.(check int) "AddonsBrowser Right Tabs End selects last tab (24)" 24
    m_ab_tb_end.runtime.browser_tab_selected_index;
  Alcotest.(check bool)
    "AddonsBrowser Right Tabs End scrolls browser_tab_scroll_offset > 10"
    true (m_ab_tb_end.runtime.browser_tab_scroll_offset > 10);
  let txt_ab_tb = grid_all_text (render_full ~model:m_ab_tb_end) in
  Alcotest.(check bool) "AddonsBrowser Right Tabs End renders TabSentinel-24" true
    (Store_scroll.contains_ci ~needle:"TabSentinel-24" txt_ab_tb);
  (* Compact short viewport clamp check: must never overflow or raise *)
  let m_ab_short =
    {
      m_ab_cl with
      viewport = { cols = 72; rows = 16 };
      breakpoint = Model.Compact;
    }
  in
  ignore (render_full ~model:m_ab_short);
  (* 10-wave1-b. Infra > Activity & Logs pane 1 Entry_event multi-line wrap parity *)
  let evt_long_detail =
    (List.init 35 (fun i ->
         Printf.sprintf "line-%02d: longtoken_without_spaces_%s" i
           (String.make 45 'x'))
     |> String.concat "\n")
    ^ "\nEVT_BOTTOM_SENTINEL"
  in
  let m_evt_det =
    {
      base with
      nav = { base.nav with workspace = Nav.Infra; pane_index = 1 };
      infra =
        Infra_store.empty
        |> Infra_store.set_tab Nav.Infra_activity_logs
        |> Infra_store.push_activity
             {
               Infra_store.at_unix = 1795400000.0;
               kind = Infra_store.Activity_tool_call;
               keeper = Some "alpha";
               summary = "Summary line 1\nSummary line 2";
               detail = Some evt_long_detail;
             };
    }
  in
  assert_scroll_exact ~label:"Infra/Logs pane 1 Entry_event"
    ~needle:"EVT_BOTTOM_SENTINEL"
    ~get_off:(fun m -> m.infra.detail_scroll_offset)
    m_evt_det;
  (* 10-wave1-c. Media_viewer overlay scroll bounds & bottom render *)
  let mv_preview =
    (List.init 24 (fun i -> Printf.sprintf "<p>Media preview line %02d</p>" i)
     |> String.concat "\n")
    ^ "\n<p>MEDIA_BOTTOM_SENTINEL</p>"
  in
  let mv_art : Wire_knowledge.artifact_entry =
    {
      id = "artifact-mv01";
      url = Some "/api/v1/published-artifacts/artifact-mv01";
      revision = 1;
      sha256 = "sha-mv-01";
      name = "media-scroll.html";
      mime_type = "text/html";
      bytes = String.length mv_preview;
      format = `Html;
      summary = None;
      preview = Some mv_preview;
      created_at_unix = Some 1795254000.0;
      producer = Some "alpha";
      title = Some "Media Scroll Test";
      task_id = None;
      goal_id = None;
    }
  in
  let m_mv =
    {
      base with
      nav = { base.nav with overlay = Some (Nav.System_gate Nav.Media_viewer) };
      knowledge =
        Knowledge_store.empty
        |> Knowledge_store.apply_artifacts ~observed_at:t0 [ mv_art ];
    }
  in
  assert_scroll_exact ~label:"Overlay/Media_viewer"
    ~needle:"MEDIA_BOTTOM_SENTINEL"
    ~get_off:(fun m -> m.knowledge.detail_scroll_offset)
    m_mv;
  let m_mv_end, _ = step m_mv (mk_key Keymap.Input.End) in
  let m_mv_home, _ = step m_mv_end (mk_key Keymap.Input.Home) in
  Alcotest.(check int) "Overlay/Media_viewer Home resets detail_scroll_offset to 0"
    0 m_mv_home.knowledge.detail_scroll_offset;
  (* 10a. 5 Runtime > Quotas pane 0: 20 windows (> 14-row 52% sub_rect) *)
  let twenty_quota_accts : Wire_runtime.account_usage list =
    List.init 20 (fun i : Wire_runtime.account_usage ->
        {
          scope = Printf.sprintf "qprov-%02d" i;
          scope_id = Printf.sprintf "qacct-%02d" i;
          providers =
            [
              {
                id = Printf.sprintf "qprov-%02d" i;
                display_name = Printf.sprintf "QuotaProv-%02d" i;
              };
            ];
          state =
            Wire_runtime.Account_reported
              [
                {
                  limit_id = Some "5h";
                  kind = Wire_runtime.Window_five_hour;
                  role = Wire_runtime.Role_gates_model_calls;
                  utilization = Wire_runtime.Util_percent (90 - (i * 3));
                  resets_at_unix = Some 1700018000.0;
                  observed_at_unix = 1700000000.0;
                };
              ];
          cost_state = Format_val.Subscription_zero;
        })
  in
  let m_quotas0 =
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime; pane_index = 0 };
      runtime =
        base.runtime
        |> Runtime_store.set_tab Nav.Runtime_quotas_credits
        |> Runtime_store.apply_usage_windows ~observed_at:t0
             { since_unix = 1700000000.0; accounts = twenty_quota_accts };
    }
  in
  assert_scroll_exact ~label:"Runtime > Quotas pane 0 (20 windows)"
    ~needle:"QuotaProv-19"
    ~get_off:(fun m -> m.runtime.quota_scroll_offset)
    m_quotas0;
  (* 10b. 5 Runtime > Failover Lanes pane 1: 18 slots (> ~10-row 52% insp_rect) *)
  let big_lane_rr : Wire_runtime.runtime_resolved_snapshot =
    {
      generated_at_iso = "2026-11-22T00:00:00Z";
      config_path = None;
      default_route = Some "lane-big";
      lanes =
        [
          {
            id = "lane-big";
            declared = true;
            runtime_ids =
              List.init 18 (fun i -> Printf.sprintf "big-slot-%02d" i);
          };
        ];
      runtimes = [];
      usage_windows = None;
    }
  in
  let m_lane_p1 =
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime; pane_index = 1 };
      runtime =
        base.runtime
        |> Runtime_store.set_tab Nav.Runtime_failover_lanes
        |> Runtime_store.apply_runtime_resolved ~observed_at:t0 big_lane_rr;
    }
  in
  assert_scroll_exact ~label:"Runtime > Failover Lanes pane 1 (18 slots)"
    ~needle:(Wire_runtime.human_runtime_slot_label "big-slot-17")
    ~get_off:(fun m -> m.runtime.detail_scroll_offset)
    m_lane_p1;
  (* 10c. Keeper_work_candle with Done & Cancelled tasks (matches Ops_common.task_assignee_opt) *)
  let done_and_cancel_tasks =
    List.init 25 (fun i ->
        {
          (mk_task
             ~id:(Printf.sprintf "done-t-%02d" i)
             ~title:(Printf.sprintf "Done task %02d" i)
             ~goal_id:(Some "goal-1"))
          with
          status =
            if i mod 2 = 0 then
              Wire_work.Done
                {
                  assignee = "alpha";
                  completed_at = "2026-11-22T02:00:00Z";
                  notes = None;
                }
            else
              Wire_work.Cancelled
                {
                  cancelled_by = "alpha";
                  cancelled_at = "2026-11-22T02:00:00Z";
                  reason = Some "superseded";
                };
        })
  in
  let m_kwc_dc =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_work_candle } ];
        };
      work =
        base.work
        |> Work_store.apply_planning ~observed_at:t0
             { goals = Work_store.goals base.work; tasks = done_and_cancel_tasks }
        |> Work_store.apply_schedules ~observed_at:t0
             (List.init 10 (fun i ->
                  mk_schedule
                    ~id:(Printf.sprintf "dc-s-%02d" i)
                    ~name:(Printf.sprintf "dc-sched-%02d" i)
                    ~keeper:"alpha")
             , None);
      knowledge =
        Knowledge_store.apply_board ~observed_at:t0
          {
            posts =
              List.init 8 (fun i ->
                  mk_post
                    ~id:(Printf.sprintf "dc-p-%02d" i)
                    ~title:
                      (if i = 7 then "CANDLE_LAST_POST"
                       else Printf.sprintf "Candle post %02d" i)
                    ~author:"alpha" ~signal:true);
            count = 8;
            sort_by = "hot";
            signal_only = false;
          }
          base.knowledge;
    }
  in
  assert_scroll_exact ~label:"Keeper_work_candle (Done + Cancelled tasks)"
    ~needle:"CANDLE_LAST_POST"
    ~get_off:(fun m -> m.nav.dive_scroll_offset)
    m_kwc_dc;
  (* 10d. 3 Knowledge > Board pane 1 (wrapped long post body, Fixed 1 + 0.48/0.54) *)
  let long_board_post =
    {
      (mk_post ~id:"post-long" ~title:"Long Wrapped Post" ~author:"alpha"
         ~signal:true)
      with
      body =
        (List.init 45 (fun i ->
             Printf.sprintf
               "Paragraph %02d with enough prose text to wrap cleanly inside \
                the 52%% board detail pane width."
               i)
         |> String.concat "\n\n")
        ^ "\n\nBOARD_LAST_SENTINEL";
    }
  in
  let m_board_p1 =
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge; pane_index = 1 };
      knowledge =
        base.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_board
        |> Knowledge_store.apply_board ~observed_at:t0
             {
               posts = [ long_board_post ];
               count = 1;
               sort_by = "recent";
               signal_only = true;
             };
    }
  in
  assert_scroll_exact ~label:"Knowledge > Board pane 1 (wrapped post)"
    ~needle:"BOARD_LAST_SENTINEL"
    ~get_off:(fun m -> m.knowledge.detail_scroll_offset)
    m_board_p1;
  (* 10e. 3 Knowledge > Memory pane 1 & Memory_diff_dive with World_diff (unconditional 2-row heat bar) *)
  let world_diff_40 : Wire_knowledge.memory_diff =
    {
      scope = Wire_knowledge.Scope_world;
      range =
        {
          window = Some "24h";
          from_rev = Some 1;
          to_rev = Some 40;
          from_unix = None;
          to_unix = None;
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
        Wire_knowledge.World_diff
          {
            counts =
              {
                total_claims_now = 40;
                added = 40;
                updated = 0;
                retracted = 0;
                incomplete_batches = 0;
                aborted_batches = 0;
              };
            unparseable_timestamps = 0;
            revisions = [];
            added =
              List.init 40 (fun i ->
                  {
                    Wire_knowledge.seq = i + 1;
                    batch_id = Printf.sprintf "wb-%02d" i;
                    fact_id = Printf.sprintf "wf-%02d" i;
                    summary = Printf.sprintf "WORLD_CLAIM_LAST_%02d" i;
                    recorded_at = "2026-11-22T10:00:00Z";
                    payload = `Null;
                  });
            updated = [];
            retracted = [];
          };
    }
  in
  let m_mem_world =
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge; pane_index = 1 };
      knowledge =
        base.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_memory
        |> Knowledge_store.set_memory_diff ~keeper:None
             ~window:Knowledge_store.Window_24h
             (Observed.value ~observed_at:t0 world_diff_40);
    }
  in
  assert_scroll_exact ~label:"Knowledge > Memory pane 1 (World_diff)"
    ~needle:"WORLD_CLAIM_LAST_39"
    ~get_off:(fun m -> m.knowledge.diff_scroll_offset)
    m_mem_world;
  (* The dive fetches into the Window_revs slot of its own range, not the
     Memory tab's Window_24h slot. *)
  let m_mem_dive_z =
    {
      m_mem_world with
      nav =
        {
          m_mem_world.nav with
          zoomed = true;
          dive_stack =
            [
              Nav.Dive_knowledge
                (Nav.Memory_diff_dive { keeper = None; from_rev = 1; to_rev = 40 });
            ];
        };
      knowledge =
        Knowledge_store.set_memory_diff ~keeper:None
          ~window:(Knowledge_store.Window_revs { from_rev = 1; to_rev = 40 })
          (Observed.value ~observed_at:t0 world_diff_40)
          m_mem_world.knowledge;
    }
  in
  assert_scroll_exact ~label:"Memory_diff_dive (World_diff + zoomed)"
    ~needle:"WORLD_CLAIM_LAST_39"
    ~get_off:(fun m -> m.nav.dive_scroll_offset)
    m_mem_dive_z;
  (* 10f. 6 Infra > Sandboxes pane 1 (microVM + 35 logs), Logs pane 1 (long wrapped msg + 30-key JSON), Repos pane 1 (with sel_repo link_rect) *)
  let sb_35_logs =
    List.init 35 (fun i : Wire_infra.system_log_entry ->
        {
          seq = i + 1;
          ts = Printf.sprintf "2026-11-22T10:%02d:00Z" (i mod 60);
          level = Wire_infra.Log_info;
          source = "sandbox";
          module_name = "alpha";
          message = Printf.sprintf "SB_LOG_SENT_%02d" i;
          keeper = Some "alpha";
          turn_id = None;
          category = None;
          details = `Assoc [];
        })
  in
  let m_sb_p1 =
    {
      base with
      nav = { base.nav with workspace = Nav.Infra; pane_index = 1 };
      infra =
        base.infra
        |> Infra_store.set_tab Nav.Infra_sandboxes
        |> Infra_store.apply_log_snapshot sb_35_logs;
    }
  in
  assert_scroll_exact ~label:"Infra > Sandboxes pane 1 (microVM + 35 logs)"
    ~needle:"SB_LOG_SENT_00"
    ~get_off:(fun m -> m.infra.detail_scroll_offset)
    m_sb_p1;
  let rich_log_entry : Wire_infra.system_log_entry =
    {
      seq = 1;
      ts = "2026-11-22T10:00:00Z";
      level = Wire_infra.Log_warn;
      source = "server";
      module_name = "http";
      message =
        String.concat " "
          (List.init 30 (fun i -> Printf.sprintf "wrapped_token_%02d" i));
      keeper = Some "alpha";
      turn_id = None;
      category = None;
      details =
        `Assoc
          (List.init 30 (fun i ->
               ( Printf.sprintf "k_%02d" i
               , `String (Printf.sprintf "LOG_JSON_BOTTOM_%02d" i) )));
    }
  in
  let m_logs_p1 =
    {
      base with
      nav = { base.nav with workspace = Nav.Infra; pane_index = 1 };
      infra =
        base.infra
        |> Infra_store.set_tab Nav.Infra_activity_logs
        |> Infra_store.apply_log_snapshot [ rich_log_entry ];
    }
  in
  assert_scroll_exact ~label:"Infra > Logs pane 1 (wrapped msg + 30-key JSON)"
    ~needle:"LOG_JSON_BOTTOM_29"
    ~get_off:(fun m -> m.infra.detail_scroll_offset)
    m_logs_p1;
  let big_repo_body =
    List.init 45 (fun i -> Printf.sprintf "let repo_line_%02d = %d" i i)
    |> String.concat "\n"
  in
  let m_repos_p1 =
    let activity : Wire_infra.repository_activity =
      {
        window_hours = 24.0;
        changes =
          [
            {
              path = "lib/masc_tui/store/update_nav.ml";
              keeper = "alpha";
              change = Wire_infra.Change_write { content = big_repo_body };
              line_evidence = None;
              succeeded = true;
            };
          ];
        incomplete = 0;
        unattributed = 0;
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Infra; pane_index = 1 };
      infra =
        base.infra
        |> Infra_store.set_tab Nav.Infra_repos_changes
        |> Infra_store.apply_repo_activity ~repo_id:"repo-masc" ~observed_at:t0
             activity;
    }
  in
  assert_scroll_exact ~label:"Infra > Repos pane 1 (with sel_repo link row)"
    ~needle:"repo_line_44"
    ~get_off:(fun m -> m.infra.diff_scroll_offset)
    m_repos_p1;
  (* 10g. 2 Work > Pipeline pane 2 (long Markdown + rejected completion_contract) *)
  let long_pipe_goal =
    {
      (mk_goal ~id:"goal-1" ~title:"Long Pipeline Goal"
         ~phase:Wire_work.Executing)
      with
      measure =
        (List.init 35 (fun i -> Printf.sprintf "- Measure requirement %02d" i)
         |> String.concat "\n")
        ^ "\n- PIPE_MD_BOTTOM_34";
      procedure = "Verify bottom sentinel";
    }
  in
  let rejected_contract_verif : Wire_work.verification_request =
    {
      (mk_verif ~req_id:"verif-1" ~task_id:"task-1" ~title:"Contract Check")
      with
      completion_contract =
        List.init 18 (fun i -> Printf.sprintf "CONTRACT_ITEM_%02d" i);
      required_artifacts = [ "art-1.log"; "art-2.log" ];
      submitted_evidence = [ "ev-1.log" ];
      review_observation =
        Some
          {
            state = Wire_work.Review_rejected;
            actor = "verifier";
            detail = "Missing required contract items";
          };
    }
  in
  let m_pipe_p2 =
    {
      base with
      nav = { base.nav with workspace = Nav.Work; pane_index = 2 };
      work =
        base.work
        |> Work_store.set_tab Nav.Work_pipeline
        |> Work_store.apply_planning ~observed_at:t0
             { goals = [ long_pipe_goal ]; tasks = Work_store.tasks base.work }
        |> Work_store.apply_verifications ~observed_at:t0
             [ rejected_contract_verif ];
    }
  in
  assert_scroll_exact ~label:"Work > Pipeline pane 2 (long Markdown + contract diff)"
    ~needle:"PIPE_MD_BOTTOM_34"
    ~get_off:(fun m -> m.work.detail_scroll_offset)
    m_pipe_p2;
  let m_pipe_contract_only =
    let short_goal =
      {
        long_pipe_goal with
        measure = "Short measure";
        procedure = "Short procedure";
      }
    in
    {
      m_pipe_p2 with
      work =
        m_pipe_p2.work
        |> Work_store.apply_planning ~observed_at:t0
             { goals = [ short_goal ]; tasks = Work_store.tasks base.work };
    }
  in
  assert_scroll_exact ~label:"Work > Pipeline pane 2 (completion_contract diff)"
    ~needle:"CONTRACT_ITEM_17"
    ~get_off:(fun m -> m.work.detail_scroll_offset)
    m_pipe_contract_only;
  (* 10h. 2 Work > Inbox pane 1: ALL 4 scrollable payloads (Tool_approval, Gate, Ask, Goal_confirmation) *)
  let mk_inbox_model payload =
    let entry : Attention.entry =
      {
        id = "inbox-test";
        kind =
          Health.Held_tool_approval
            { request_id = "req-1"; keeper = "alpha"; tool = "bash" };
        title = "Inbox Scroll Test";
        summary = "Testing band-subtracted scroll bounds";
        keeper = Some "alpha";
        created_at_unix = Some 1700000000.0;
        payload;
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Work; pane_index = 1 };
      work = Work_store.set_tab Nav.Work_inbox base.work;
      attention = { base.attention with items = [ entry ]; triage_index = 0 };
    }
  in
  let ta_json =
    `Assoc
      (List.init 30 (fun i ->
           ( Printf.sprintf "arg_%02d" i
           , `String (Printf.sprintf "TA_ARG_BOTTOM_%02d" i) )))
    |> Yojson.Safe.to_string
  in
  assert_scroll_exact ~label:"Work > Inbox pane 1 (Payload_tool_approval)"
    ~needle:"TA_ARG_BOTTOM_29"
    ~get_off:(fun m -> m.work.detail_scroll_offset)
    (mk_inbox_model
       (Attention.Payload_tool_approval
          {
            approval_id = "appr-big";
            tool_call_id = "tc-big";
            keeper = "alpha";
            tool = "bash";
            args_preview = ta_json;
            question = "Approve command?";
            because = Some "testing";
            asked_at = 1700000000.0;
            timeout_sec = 300.0;
          }));
  let gate_json =
    `Assoc
      (List.init 32 (fun i ->
           ( Printf.sprintf "in_%02d" i
           , `String (Printf.sprintf "GATE_IN_BOTTOM_%02d" i) )))
    |> Yojson.Safe.to_string
  in
  assert_scroll_exact ~label:"Work > Inbox pane 1 (Payload_gate)"
    ~needle:"GATE_IN_BOTTOM_31"
    ~get_off:(fun m -> m.work.detail_scroll_offset)
    (mk_inbox_model
       (Attention.Payload_gate
          {
            id = "gate-big";
            keeper = "alpha";
            tool_name = "deploy";
            input_preview = Some gate_json;
            waiting_s = Some 5.0;
            phase = "pending";
          }));
  assert_scroll_exact ~label:"Work > Inbox pane 1 (Payload_ask)"
    ~needle:"ASK_BOTTOM_34"
    ~get_off:(fun m -> m.work.detail_scroll_offset)
    (mk_inbox_model
       (Attention.Payload_ask
          {
            ask_id = "ask-big";
            keeper = "alpha";
            asked_at = 1700000000.0;
            context = Some "Context header";
            questions =
              [
                {
                  question_id = "q-big";
                  header = "Long Ask";
                  prompt =
                    (List.init 35 (fun i -> Printf.sprintf "- Ask line %02d" i)
                     |> String.concat "\n")
                    ^ "\n- ASK_BOTTOM_34";
                  mode = Wire_work.Ask_single;
                  allow_free_text = false;
                  free_text_hint = None;
                  choices =
                    [ { choice_id = "ok"; label = "OK"; description = None } ];
                };
              ];
            resolution = Wire_work.Ask_open;
          }));
  assert_scroll_exact ~label:"Work > Inbox pane 1 (Payload_goal_confirmation)"
    ~needle:"CONF_BOTTOM_34"
    ~get_off:(fun m -> m.work.detail_scroll_offset)
    (mk_inbox_model
       (Attention.Payload_goal_confirmation
          {
            (mk_goal ~id:"goal-conf" ~title:"Confirm Me"
               ~phase:Wire_work.Awaiting_confirmation)
            with
            measure = "Measure";
            procedure =
              (List.init 35 (fun i -> Printf.sprintf "- Conf step %02d" i)
               |> String.concat "\n")
              ^ "\n- CONF_BOTTOM_34";
          }));
  (* 10i. Help (?) on short terminals 100x28 & 80x24 (overlay_rect.h = rows - 2 -> modal_h = rows - 4) *)
  let m_help_28 =
    let m0 = populated_model ~cols:100 ~rows:28 ~lang:Say.Lang_en () in
    { m0 with nav = { m0.nav with overlay = Some Nav.Help } }
  in
  let m_help_end, _ = step m_help_28 (mk_key Keymap.Input.End) in
  Alcotest.(check bool) "Help (100x28) End scrolls > 0" true
    (m_help_end.nav.help_scroll_offset > 0);
  let m_help_dn, _ = step m_help_end (mk_key Keymap.Input.Down) in
  Alcotest.(check int) "Help (100x28) Down at End clamps"
    m_help_end.nav.help_scroll_offset m_help_dn.nav.help_scroll_offset;
  let m_help_up, _ = step m_help_end (mk_key Keymap.Input.Up) in
  Alcotest.(check int) "Help (100x28) Up from End decrements by 1"
    (m_help_end.nav.help_scroll_offset - 1) m_help_up.nav.help_scroll_offset;
  let txt_help_end = grid_all_text (render_full ~model:m_help_end) in
  let txt_help_top = grid_all_text (render_full ~model:m_help_28) in
  Alcotest.(check bool) "Help (100x28) End renders scrolled bottom view" true
    (not (String.equal txt_help_top txt_help_end));
  (* 10j. Queue_context (Ctrl+T) at rows=24 for BOTH Drawer_queue and Drawer_schedules *)
  let m_q24 =
    let m0 = populated_model ~cols:100 ~rows:24 ~lang:Say.Lang_en () in
    let drafts =
      let rec add_tx i d =
        if i >= 25 then d
        else
          let d_text =
            Drafts.set_current_text (Printf.sprintf "TX_QUEUE_%02d" i) d
          in
          let d' =
            match
              Drafts.enqueue_submission ~now:t0 ~keeper:"alpha"
                ~mode:Drafts.Mode_follow_up d_text
            with
            | Some (d_next, _) -> d_next
            | None -> d_text
          in
          add_tx (i + 1) d'
      in
      add_tx 0 (Drafts.set_active_keeper "alpha" m0.drafts)
    in
    {
      m0 with
      drafts;
      work =
        Work_store.apply_schedules ~observed_at:t0 (many_scheds, None) m0.work;
      nav = { m0.nav with overlay = Some (Nav.Queue_context Nav.Drawer_queue) };
    }
  in
  assert_scroll_exact ~label:"Queue_context Drawer_queue (rows=24)"
    ~needle:"TX_QUEUE_24"
    ~get_off:(fun m -> m.nav.queue_scroll_offset)
    m_q24;
  let m_q24_sched =
    {
      m_q24 with
      nav =
        { m_q24.nav with overlay = Some (Nav.Queue_context Nav.Drawer_schedules) };
    }
  in
  assert_scroll_exact ~label:"Queue_context Drawer_schedules (rows=24)"
    ~needle:"job-079"
    ~get_off:(fun m -> m.nav.queue_scroll_offset)
    m_q24_sched;
  (* 10k. Incidents detail J/K with compact 1-line embedded JSON (flattens to 30+ lines!) *)
  let compact_inc_json =
    "payload "
    ^ (`Assoc
         (List.init 28 (fun i ->
              ( Printf.sprintf "k%02d" i
              , `String (Printf.sprintf "INC_JSON_LAST_%02d" i) )))
       |> Yojson.Safe.to_string)
  in
  let m_inc_json =
    let inc, _ =
      Incidents.push ~occurred_at_unix:1700000000.0
        ~source:Health.Source_client_http
        ~summary:(Say.make ~ko:"컴팩트 JSON" ~en:"compact json")
        ~detail:compact_inc_json ~status:Health.Resolved base.incidents
    in
    {
      base with
      incidents = inc;
      nav = { base.nav with overlay = Some Nav.Incidents };
    }
  in
  let m_inc_json_bot =
    List.init 40 (fun _ -> char_key ~shift:true "J")
    |> step_keys m_inc_json |> fst
  in
  Alcotest.(check bool) "Incidents Shift+J scrolls compact 1-line JSON > 0" true
    (m_inc_json_bot.incidents.detail_scroll_offset > 0);
  let txt_inc_j = grid_all_text (render_full ~model:m_inc_json_bot) in
  Alcotest.(check bool) "Incidents compact JSON at bottom renders INC_JSON_LAST_27"
    true (Store_scroll.contains_ci ~needle:"INC_JSON_LAST_27" txt_inc_j);
  let m_inc_json_k, _ = step m_inc_json_bot (char_key ~shift:true "K") in
  Alcotest.(check int)
    "Incidents Shift+K from bottom immediately decrements by 1"
    (m_inc_json_bot.incidents.detail_scroll_offset - 1)
    m_inc_json_k.incidents.detail_scroll_offset;
  (* 10l. Populated long fixtures for ALL 9 non-chat Dives (bottom-row rendered + zero sticky Up!) *)
  let long_comments =
    List.init 45 (fun i : Wire_knowledge.board_comment ->
        {
          id = Printf.sprintf "c-%02d" i;
          post_id = "post-1";
          parent_id = None;
          author = "alpha";
          body = Printf.sprintf "Comment number %02d with verification detail" i;
          created_at_unix = 1700000100.0 +. float_of_int i;
          score = 1;
        })
  in
  let post1 =
    match Knowledge_store.selected_post base.knowledge with
    | Some p -> p
    | None -> mk_post ~id:"post-1" ~title:"Post 1" ~author:"alpha" ~signal:true
  in
  let dive_tasks =
    List.init 35 (fun i ->
        {
          (mk_task
             ~id:(Printf.sprintf "task-%02d" (i + 1))
             ~title:(Printf.sprintf "GD_TASK_%02d" i)
             ~goal_id:(Some "goal-1"))
          with
          description =
            Some
              ((List.init 40 (fun j -> Printf.sprintf "- Desc line %02d" j)
                |> String.concat "\n")
               ^ "\n- TD_DESC_39");
        })
  in
  let dive_verif : Wire_work.verification_request =
    {
      (mk_verif ~req_id:"verif-1" ~task_id:"task-01" ~title:"GD_TASK_00")
      with
      completion_contract =
        List.init 25 (fun i -> Printf.sprintf "VD_CONTRACT_%02d" i);
      required_artifacts =
        List.init 15 (fun i -> Printf.sprintf "vd-art-%02d.log" i);
      submitted_evidence = [ "vd-art-00.log" ];
      review_observation =
        Some
          {
            state = Wire_work.Review_rejected;
            actor = "verifier";
            detail = "Missing artifacts";
          };
    }
  in
  let dive_logs =
    List.init 45 (fun i : Wire_infra.system_log_entry ->
        {
          seq = i + 1;
          ts = Printf.sprintf "2026-11-22T11:%02d:00Z" (i mod 60);
          level = Wire_infra.Log_info;
          source = "server";
          module_name = "alpha";
          message = Printf.sprintf "DIVE_LOG_%02d" i;
          keeper = if i = 0 then None else Some "alpha";
          turn_id = None;
          category = None;
          details = `Assoc [];
        })
  in
  let dive_inc, dive_inc_id =
    Incidents.push ~occurred_at_unix:1700000000.0
      ~source:(Health.Source_keeper "alpha")
      ~summary:(Say.make ~ko:"모듈 로그 매칭" ~en:"module log match")
      ~detail:"short incident detail" ~status:Health.Resolved base.incidents
  in
  let m_dives_base =
    {
      base with
      work =
        base.work
        |> Work_store.apply_planning ~observed_at:t0
             { goals = [ long_pipe_goal ]; tasks = dive_tasks }
        |> Work_store.apply_verifications ~observed_at:t0 [ dive_verif ];
      knowledge =
        base.knowledge
        |> Knowledge_store.apply_thread ~observed_at:t0 (post1, long_comments)
        |> Knowledge_store.set_wiki_page ~slug:long_wiki_toc.slug
             (Observed.value ~observed_at:t0 long_wiki_toc)
        |> Knowledge_store.apply_artifacts ~observed_at:t0 many_artifacts;
      runtime = m_lanes.runtime;
      infra = Infra_store.apply_log_snapshot dive_logs base.infra;
      incidents = dive_inc;
    }
  in
  let dives_with_sentinels =
    [
      ("Goal_dive", Nav.Dive_work (Nav.Goal_dive "goal-1"), "GD_TASK_34");
      ("Task_dive", Nav.Dive_work (Nav.Task_dive "task-01"), "TD_DESC_39");
      ( "Verification_dive"
      , Nav.Dive_work (Nav.Verification_dive "verif-1")
      , "Missing artifacts" );
      ("Thread_dive", Nav.Dive_knowledge (Nav.Thread_dive "post-1"), "Comment number 44");
      ("Wiki_dive", Nav.Dive_knowledge (Nav.Wiki_dive "arch-overview"), "FINAL_WIKI_BOTTOM_LINE");
      ("Artifact_dive", Nav.Dive_knowledge (Nav.Artifact_dive (Printf.sprintf "artifact-%032d" 0)), "Artifact Report 59");
      ("Sandbox_dive", Nav.Dive_infra (Nav.Sandbox_dive "alpha"), "DIVE_LOG_01");
      ("Lane_dive", Nav.Dive_infra (Nav.Lane_dive "lane-00"), "DIVE_LOG_00");
      ("Incident_dive (module_name match)", Nav.Dive_infra (Nav.Incident_dive dive_inc_id.id), "DIVE_LOG_00");
    ]
  in
  List.iter
    (fun (dname, dive, needle) ->
      let md0 =
        { m_dives_base with nav = { m_dives_base.nav with dive_stack = [ dive ] } }
      in
      assert_scroll_exact ~label:dname ~needle
        ~get_off:(fun m -> m.nav.dive_scroll_offset)
        md0)
    dives_with_sentinels

(* ---------- Pillar 3: Centered-Rectangle Keeper Chat UX & Korean IME Guard ---------- *)

let test_pillar3_keeper_chat_empty_loading_and_korean_ime () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko () in
  let theme = Theme.of_preset base.theme_preset in
  let count_surface2_cells (g : Cell_grid.t) =
    (* Scan the chat transcript canvas (excluding the top header/tab bar y<5
       and the bottom composer/status bar y>=rows-6) for any floating
       centered surface_2 rectangle. *)
    let s2 = Color.of_rgb theme.surface_2 in
    let n = ref 0 in
    for y = 5 to Cell_grid.rows g - 7 do
      for x = 0 to Cell_grid.cols g - 1 do
        let c = Cell_grid.get g ~x ~y in
        if Color.equal c.style.bg s2 then incr n
      done
    done;
    !n
  in
  (* 1. Observed.Loading _ renders clean 1-line left-aligned whisper, ZERO surface_2 centered box *)
  let m_loading =
    let empty_fleet =
      let f0 =
        Fleet_store.empty
        |> Fleet_store.apply_keepers ~observed_at:t0
             [
               mk_keeper ~name:"fresh" ~company:"platform"
                 ~health:Wire_fleet.Keeper_healthy;
             ]
      in
      {
        f0 with
        chat_histories =
          Fleet_store.String_map.add "fresh"
            (Observed.loading ~since_ns:t0)
            f0.chat_histories;
      }
    in
    {
      base with
      fleet = empty_fleet;
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "fresh"; tab = Nav.Keeper_chat } ];
        };
    }
  in
  let g_load = render_full ~model:m_loading in
  Alcotest.(check int)
    "Observed.Loading Keeper_chat has ZERO centered surface_2 rectangle cells" 0
    (count_surface2_cells g_load);
  let txt_load = grid_all_text g_load in
  Alcotest.(check bool)
    "Observed.Loading Keeper_chat shows clean loading whisper" true
    (Store_scroll.contains_ci ~needle:"불러오는 중" txt_load);
  (* 2. Genuinely empty chat renders left-aligned on surface_1, ZERO centered surface_2 box *)
  let m_empty =
    {
      m_loading with
      fleet =
        Fleet_store.apply_chat_history ~observed_at:t0 ~keeper:"fresh"
          { messages = []; has_more = false; next_cursor = None }
          m_loading.fleet;
    }
  in
  let g_empty = render_full ~model:m_empty in
  Alcotest.(check int)
    "Empty Keeper_chat renders cleanly without floating surface_2 rectangle" 0
    (count_surface2_cells g_empty);
  (* 3. Korean typing while unfocused in Dive_keeper Keeper_chat auto-focuses composer & inserts char (NEVER opens modals!) *)
  let m_unfocused =
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat } ];
        };
      drafts = Drafts.set_focus false base.drafts;
    }
  in
  let m_ko1, cmds_ko1 = step m_unfocused (char_key "ㅇ") in
  Alcotest.(check bool)
    "Korean jamo 'ㅇ' unfocused in Keeper_chat auto-focuses composer" true
    (Drafts.is_focused m_ko1.drafts);
  Alcotest.(check string)
    "Korean jamo 'ㅇ' inserted directly into composer draft" "ㅇ"
    (Drafts.current_draft m_ko1.drafts).text;
  Alcotest.(check bool)
    "Korean jamo 'ㅇ' NEVER opens any modal/overlay" true
    (Option.is_none m_ko1.nav.overlay && Option.is_none m_ko1.inline_modal);
  Alcotest.(check bool)
    "Korean jamo 'ㅇ' NEVER triggers fast deny/approve HTTP post" false
    (has_cmd (function Cmd.Http_post _ -> true | _ -> false) cmds_ko1);
  let m_ko2, _ = step m_unfocused (char_key "안") in
  Alcotest.(check string)
    "Korean syllable '안' unfocused in Keeper_chat auto-focuses & inserts '안'"
    "안" (Drafts.current_draft m_ko2.drafts).text;
  Alcotest.(check bool)
    "Korean syllable '안' NEVER opens any modal/overlay" true
    (Option.is_none m_ko2.nav.overlay && Option.is_none m_ko2.inline_modal);
  (* 4. Micro breakpoint (<80x24) blocks unfocused Korean auto-focus in Keeper_chat *)
  let m_micro_ko =
    let m0 = populated_model ~cols:70 ~rows:22 ~lang:Say.Lang_ko () in
    {
      m0 with
      nav =
        {
          m0.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_chat } ];
        };
      drafts = Drafts.set_focus false m0.drafts;
    }
  in
  let m_micro_after, _ = step m_micro_ko (char_key "안") in
  Alcotest.(check bool) "Micro breakpoint blocks unfocused Korean auto-focus"
    false (Drafts.is_focused m_micro_after.drafts);
  Alcotest.(check string) "Micro breakpoint leaves draft empty on Korean key" ""
    (Drafts.current_draft m_micro_after.drafts).text;
  (* 5. Dive 'c' quick-chat marks chat_histories loading (no empty flash) *)
  let m_dive_c0 =
    let fresh_fleet =
      Fleet_store.empty
      |> Fleet_store.apply_keepers ~observed_at:t0
           [
             mk_keeper ~name:"fresh" ~company:"platform"
               ~health:Wire_fleet.Keeper_healthy;
           ]
    in
    {
      base with
      fleet = fresh_fleet;
      nav =
        {
          base.nav with
          workspace = Nav.Keepers;
          dive_stack =
            [ Nav.Dive_keeper { name = "fresh"; tab = Nav.Keeper_memory } ];
        };
    }
  in
  let m_dive_c1, _ = step m_dive_c0 (char_key "c") in
  Alcotest.(check bool)
    "Dive 'c' quick-chat switches to Keeper_chat and marks chat_histories Loading"
    true
    (match
       Fleet_store.String_map.find_opt "fresh" m_dive_c1.fleet.chat_histories
     with
     | Some (Observed.Loading _) -> true
     | _ -> false)

let enter_hint_name = function
  | Update_nav.Enter_hint_hidden -> "hidden"
  | Update_nav.Enter_hint_dive -> "dive"
  | Update_nav.Enter_hint_edit_field -> "edit field"
  | Update_nav.Enter_hint_confirm_field -> "confirm field"

let test_enter_hint_follows_enter_plan () =
  let m_base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en () in
  let no_target_views : (string * Model.t) list =
    [
      ( "Runtime/Tools"
      , {
          m_base with
          nav = { m_base.nav with workspace = Nav.Runtime };
          runtime =
            Runtime_store.set_tab Nav.Runtime_tools_connectors m_base.runtime;
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
      ( "Work/Candle"
      , {
          m_base with
          nav = { m_base.nav with workspace = Nav.Work };
          work = Work_store.set_tab Nav.Work_candle_scorecard m_base.work;
        } );
    ]
  in
  List.iter
    (fun (label, (m : Model.t)) ->
      Alcotest.(check string)
        (label ^ ": footer drops Enter")
        "hidden"
        (enter_hint_name (Update_nav.enter_hint m));
      let m', cmds = Update_nav.dive_selected m in
      Alcotest.(check int)
        (label ^ ": Enter pushes no dive")
        (List.length m.nav.dive_stack)
        (List.length m'.nav.dive_stack);
      Alcotest.(check int) (label ^ ": Enter sends no request") 0
        (List.length cmds))
    no_target_views;
  let keepers =
    { m_base with nav = { m_base.nav with workspace = Nav.Keepers } }
  in
  Alcotest.(check string) "Keepers: footer offers Enter" "dive"
    (enter_hint_name (Update_nav.enter_hint keepers));
  let dived, _ = Update_nav.dive_selected keepers in
  Alcotest.(check int) "Keepers: Enter pushes the keeper dive" 1
    (List.length dived.nav.dive_stack);
  (* Keeper config takes Enter before the keymap and edits a field, both in
     the keeper dive and in the Keepers detail pane. *)
  let config_dive =
    {
      keepers with
      nav =
        {
          keepers.nav with
          dive_stack =
            [ Nav.Dive_keeper { name = "alpha"; tab = Nav.Keeper_config } ];
        };
    }
  in
  Alcotest.(check string) "Keeper config dive: Enter edits a field"
    "edit field"
    (enter_hint_name (Update_nav.enter_hint config_dive));
  let config_pane =
    {
      keepers with
      nav = { keepers.nav with pane_index = 1 };
      fleet = Fleet_store.set_keeper_dive_tab Nav.Keeper_config keepers.fleet;
    }
  in
  Alcotest.(check string) "Keepers config pane: Enter edits a field"
    "edit field"
    (enter_hint_name (Update_nav.enter_hint config_pane))

let () =
  Alcotest.run "masc_tui_keymap_matrix"
    [
      ( "enter_hint"
      , [
          Alcotest.test_case "footer offers Enter only where Enter acts"
            `Quick test_enter_hint_follows_enter_plan;
        ] );
      ( "axis_a_screen_dive_x_keys"
      , [
          Alcotest.test_case "34 contexts x 20 keys (680 cases)" `Quick
            test_axis_a_screen_dive_matrix;
        ] );
      ( "axis_b_overlay_focus_x_isolation"
      , [
          Alcotest.test_case "32 states x 14 isolation keys (448 cases)" `Quick
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
      ( "pr_a_pillars_1_2_3"
      , [
          Alcotest.test_case
            "Pillar 1: Keeper_config editing (Dive+Split) & Settings Pane_inspector ←/→"
            `Quick test_pillar1_keeper_config_and_settings_lr;
          Alcotest.test_case
            "Pillar 2: All 16 ArrowDown / End / Viewport scroll bounds" `Quick
            test_pillar2_scroll_bounds_all_surfaces;
          Alcotest.test_case
            "Pillar 3: Keeper chat loading/empty left-align & Korean IME guard"
            `Quick test_pillar3_keeper_chat_empty_loading_and_korean_ime;
        ] );
    ]
