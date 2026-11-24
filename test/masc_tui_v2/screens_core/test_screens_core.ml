open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_screens_core

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

let obs v = Observed.value ~observed_at:Clock.Mono.zero v

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
  let rows = Cell_grid.rows grid in
  List.init rows (grid_row_text grid) |> String.concat "\n"

let has_substring ~needle haystack =
  Render_util.contains_ci ~needle haystack

let assert_contains ~label ~needle haystack =
  if not (has_substring ~needle haystack) then
    Alcotest.fail
      (Printf.sprintf "%s: expected %S in rendered text:\n%s" label needle
         haystack)

let assert_not_contains ~label ~needle haystack =
  if has_substring ~needle haystack then
    Alcotest.fail
      (Printf.sprintf "%s: did NOT expect %S in rendered text:\n%s" label needle
         haystack)

let assert_clean_grid ~label (grid : Cell_grid.t) =
  let all = grid_all_text grid in
  let forbidden =
    [ "...?"; "g:퀴즈"; "s:음악"; "Candle: 0.000"; "진단 확인"; "\xE2\x9A\xA0"; "\xE2\x9A\xA1"; "\xF0\x9F\x94\x92"; "\xE2\x9A\x99" ]
  in
  List.iter
    (fun bad -> assert_not_contains ~label ~needle:bad all)
    forbidden;
  (* Verify width-2 continuation invariant across all cells *)
  let cols = Cell_grid.cols grid in
  let rows = Cell_grid.rows grid in
  for y = 0 to rows - 1 do
    for x = 0 to cols - 1 do
      let c = Cell_grid.get grid ~x ~y in
      match c.glyph with
      | Cell_grid.Continuation ->
          if not (x > 0 && Int.equal (Cell_grid.get grid ~x:(x - 1) ~y).width 2)
          then
            Alcotest.fail
              (Printf.sprintf "%s: orphaned continuation at (%d,%d)" label x y)
      | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Braille _ | Cell_grid.Utf8 _ ->
          if Int.equal c.width 2 then
            let ok_cont =
              x + 1 < cols
              &&
              match (Cell_grid.get grid ~x:(x + 1) ~y).glyph with
              | Cell_grid.Continuation -> true
              | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Braille _ | Cell_grid.Utf8 _ ->
                  false
            in
            if not ok_cont then
              Alcotest.fail
                (Printf.sprintf "%s: wide glyph at (%d,%d) missing continuation"
                   label x y)
    done
  done

(* ---------- Realistic Populated Model Fixture ---------- *)

let mk_keeper ~name ~company ~health ?(turns = 120) ?(ctx = 0.42) () :
    Wire_fleet.keeper_summary =
  {
    name;
    group = Some company;
    company;
    health;
    paused = (match health with Wire_fleet.Keeper_paused -> true | _ -> false);
    keepalive_running =
      (match health with
       | Wire_fleet.Keeper_paused | Wire_fleet.Keeper_offline -> false
       | _ -> true);
    activation_mode = Wire_fleet.Activation_autonomous;
    runtime_id = "sonnet-med-glm";
    model_id = Some "claude-sonnet-4";
    current_task_id = Some "task-3898";
    context = obs (measured_context ctx);
    total_turns = obs turns;
    last_turn_at_unix = Some 1763700000.0;
    active_turn = None;
  }

let populated_model ~cols ~rows ~lang =
  let m0 = Model.initial ~cols ~rows ~lang () in
  let now_unix = 1763701200.0 in
  let keepers =
    [
      mk_keeper ~name:"e-masc-the-leader" ~company:"MASC Core Eng"
        ~health:Wire_fleet.Keeper_working ~turns:412 ();
      mk_keeper ~name:"ocaml-dev" ~company:"MASC Core Eng"
        ~health:Wire_fleet.Keeper_healthy ~turns:285 ();
      mk_keeper ~name:"code-reviewer" ~company:"Code Review Family"
        ~health:Wire_fleet.Keeper_working ~turns:510 ();
      mk_keeper ~name:"code-rev-brother" ~company:"Code Review Family"
        ~health:Wire_fleet.Keeper_healthy ~turns:340 ();
      mk_keeper ~name:"wkbl-growth" ~company:"WKBL Startup"
        ~health:Wire_fleet.Keeper_failing ~turns:190 ();
      mk_keeper ~name:"wkbl-front" ~company:"WKBL Startup"
        ~health:Wire_fleet.Keeper_healthy ~turns:150 ();
      mk_keeper ~name:"kidsnote-ops" ~company:"KidsNote Ops"
        ~health:Wire_fleet.Keeper_working ~turns:95 ();
      mk_keeper ~name:"music-sensei" ~company:"Creative / R&D"
        ~health:Wire_fleet.Keeper_paused ~turns:80 ();
    ]
  in
  let scorecard : Wire_fleet.daily_scorecard =
    {
      tasks_done_24h = obs 34;
      tasks_done_total = obs 707;
      tasks_in_progress = obs 12;
      tasks_claimed = obs 8;
      tasks_awaiting_verification = obs 5;
      tasks_todo = obs 522;
      tasks_cancelled = obs 4;
      goals_completed_24h = obs 3;
      verifications_passed_24h = obs 31;
      verifications_rejected_24h = obs 3;
      board_posts_24h = obs 19;
      turns_24h = obs 1420;
      cost_24h_usd = obs 108.78;
    }
  in
  let shell : Wire_fleet.dashboard_shell =
    {
      generated_at_unix = Some now_unix;
      project = Some "masc";
      version = Some "0.77.1";
      counts =
        {
          agents = 8;
          tasks = 1547;
          tasks_done_24h = 34;
          keepers = 8;
          persisted_keepers = obs 8;
          configured_keepers = obs 8;
          total_runtimes = 177;
        };
      scorecard_24h = scorecard;
      groups = [];
    }
  in
  let fleet_reading : Wire_fleet.fleet_stream_reading =
    {
      status = "ok";
      operator_action_required = true;
      bootable_count = 8;
      running_count = 7;
      executable_count = 8;
      failing_count = 1;
      recovering_count = 0;
      paused_count = 1;
      proactive_interval_sec = Some 60;
    }
  in
  let chat_page : Wire_fleet.chat_history_page =
    {
      messages =
        [
          {
            id = "m1";
            role = Wire_fleet.Role_user;
            content = "Check daily status";
            ts_unix = now_unix -. 120.0;
            turn_ref = Some "t1";
            model_used = None;
            tool_call_id = None;
            tool_call_name = None;
            execution_id = None;
            provenance = None;
            failure_kind = None;
          };
          {
            id = "m2";
            role = Wire_fleet.Role_assistant;
            content = "All 4 stack layers verified and ready.";
            ts_unix = now_unix -. 60.0;
            turn_ref = Some "t1";
            model_used = Some "claude-sonnet-4";
            tool_call_id = None;
            tool_call_name = None;
            execution_id = None;
            provenance = None;
            failure_kind = None;
          };
        ];
      has_more = false;
      next_cursor = None;
    }
  in
  let fleet =
    Fleet_store.empty
    |> Fleet_store.apply_shell ~observed_at:Clock.Mono.zero shell
    |> Fleet_store.apply_keepers ~observed_at:Clock.Mono.zero keepers
    |> Fleet_store.apply_fleet_stream_event ~observed_at:Clock.Mono.zero
         (Wire_fleet.Fleet_snapshot
            {
              schema = 1;
              revision = 42;
              measured_at_unix = now_unix;
              reading = fleet_reading;
              degraded = None;
            })
    |> Fleet_store.apply_chat_history ~observed_at:Clock.Mono.zero
         ~keeper:"e-masc-the-leader" chat_page
    |> Fleet_store.select_keeper "e-masc-the-leader"
  in
  let goals : Wire_work.goal list =
    [
      {
        id = "goal-1";
        title = "MASC Core Overhaul (Clockwork/ACP/Memory)";
        phase = Wire_work.Executing;
        priority = 1;
        due_date = None;
        measure = "3 Native Stacks merged";
        procedure = "Verify head reviews";
        criterion_revision = Some "rev-2";
        criterion_verdict = Wire_work.Criterion_valid;
        last_review_note = None;
        last_review_at = None;
        created_at = None;
        updated_at = None;
        linked_task_count = obs 0;
      };
      {
        id = "goal-2";
        title = "TUI V2 Ground-Up Redesign";
        phase = Wire_work.Awaiting_confirmation;
        priority = 1;
        due_date = None;
        measure = "All 6 workspaces verified";
        procedure = "Visual PNG verification";
        criterion_revision = Some "rev-1";
        criterion_verdict = Wire_work.Criterion_valid;
        last_review_note = None;
        last_review_at = None;
        created_at = None;
        updated_at = None;
        linked_task_count = obs 2;
      };
      {
        id = "goal-3";
        title = "Completed Previous Wave";
        phase = Wire_work.Completed;
        priority = 2;
        due_date = None;
        measure = "Done";
        procedure = "Merged";
        criterion_revision = None;
        criterion_verdict = Wire_work.Criterion_valid;
        last_review_note = None;
        last_review_at = None;
        created_at = None;
        updated_at = None;
        linked_task_count = obs 0;
      };
    ]
  in
  let tasks : Wire_work.task list =
    [
      {
        id = "task-3898";
        title = "Clockwork fault isolation";
        description = None;
        priority = 1;
        status =
          Wire_work.Done
            {
              assignee = "e-masc-the-leader";
              completed_at = "2026-11-21T02:00:00Z";
              notes = None;
            };
        goal_link = Wire_work.Unlinked;
        created_at = None;
        updated_at = None;
      };
    ]
  in
  let asks : Wire_work.ask_row list =
    [
      {
        ask_id = "ask-1";
        keeper = "e-masc-the-leader";
        asked_at = now_unix -. 90.0;
        context = Some "Native Stack #54340";
        questions =
          [
            {
              question_id = "q1";
              header = "Merge Stack";
              prompt = "Merge Native Stack #54340 (all 4 layers approved)?";
              mode = Wire_work.Ask_single;
              allow_free_text = true;
              free_text_hint = None;
              choices =
                [
                  { choice_id = "yes"; label = "Approve merge"; description = None };
                  { choice_id = "hold"; label = "Hold"; description = None };
                ];
            };
          ];
        resolution = Wire_work.Ask_open;
      };
    ]
  in
  let tool_approvals : Wire_work.held_tool_approval list =
    [
      {
        approval_id = "appr-1";
        tool_call_id = "tc-1";
        keeper = "ocaml-dev";
        tool = "git_push";
        args_preview = "origin feat/tui-v2";
        question = "Allow git_push?";
        because = None;
        asked_at = now_unix -. 30.0;
        timeout_sec = 300.0;
      };
    ]
  in
  let candle_ledger : Wire_work.candle_ledger =
    {
      ledger_state = Wire_work.Ledger_present;
      total_events = 14;
      balance_error = None;
      policy_configuration = "active";
      pricing_mode = "standard";
      disabled_reason = None;
      half_life_sec = Some 604800.0;
      issued_milli = "0";
      burned_milli = "0";
      circulating_milli = "0";
      total_supply_milli = "0";
      active_keepers = 5;
      diagnostics =
        {
          unattributed_count = 3;
          backlog_fenced_count = 3;
          zero_linked_tasks_goals = 3;
          held_windows_count = 0;
        };
      balances = [];
      recent_events = [];
    }
  in
  let schedules : Wire_work.schedule_row list =
    [
      {
        schedule_instance_id = "si-1";
        schedule_id = "sched-patrol";
        status = Wire_work.Sched_scheduled;
        source = "keeper";
        due_at_unix = now_unix +. 600.0;
        next_due_at_unix = Some (now_unix +. 3600.0);
        recurrence_kind = "interval";
        recurrence_summary = "every 1h";
        payload_kind = Some "prompt";
        payload_support = "supported";
        payload_target = Some "e-masc-the-leader";
        payload_keeper_name = Some "e-masc-the-leader";
        payload_summary = Some "PR patrol sweep";
        last_wake_unix = Some (now_unix -. 3000.0);
        last_disposition = Wire_work.Wake_succeeded;
      };
      {
        schedule_instance_id = "si-2";
        schedule_id = "sched-wkbl";
        status = Wire_work.Sched_failed;
        source = "keeper";
        due_at_unix = now_unix +. 1200.0;
        next_due_at_unix = None;
        recurrence_kind = "cron";
        recurrence_summary = "0 9 * * *";
        payload_kind = Some "prompt";
        payload_support = "supported";
        payload_target = Some "wkbl-growth";
        payload_keeper_name = Some "wkbl-growth";
        payload_summary = Some "Daily campaign digest";
        last_wake_unix = Some (now_unix -. 600.0);
        last_disposition = Wire_work.Wake_failed (Some "provider timeout");
      };
    ]
  in
  let work =
    Work_store.empty
    |> Work_store.apply_planning ~observed_at:Clock.Mono.zero { goals; tasks }
    |> Work_store.apply_asks ~observed_at:Clock.Mono.zero asks
    |> Work_store.apply_tool_approvals ~observed_at:Clock.Mono.zero tool_approvals
    |> Work_store.apply_candle_ledger ~observed_at:Clock.Mono.zero candle_ledger
    |> Work_store.apply_schedules ~observed_at:Clock.Mono.zero (schedules, None)
  in
  let board_feed : Wire_knowledge.board_feed =
    {
      posts =
        [
          {
            id = "p-1";
            title = "WKBL coordination thread";
            body = "Campaign progress update";
            author = "wkbl-web-leader";
            hearth = Some "wkbl";
            post_kind = Some Wire_knowledge.Automation_post;
            visibility = Some Wire_knowledge.Vis_internal;
            created_at_unix = now_unix -. 840.0;
            updated_at_unix = None;
            score = 5;
            comment_count = 12;
            author_karma = obs 42;
            succession_chain_root_id = Some "p-root-1";
            chain_depth = Some 22;
            is_signal = true;
          };
          {
            id = "p-2";
            title = "3-Stack Native Overhaul kickoff";
            body = "Clockwork / ACP / Living Memory";
            author = "codex-mcp-client";
            hearth = Some "ops";
            post_kind = Some Wire_knowledge.Human_post;
            visibility = Some Wire_knowledge.Vis_internal;
            created_at_unix = now_unix -. 900.0;
            updated_at_unix = None;
            score = 8;
            comment_count = 4;
            author_karma = obs 90;
            succession_chain_root_id = None;
            chain_depth = None;
            is_signal = true;
          };
          {
            id = "p-noise";
            title = "Verify: automated noise post MUST_BE_HIDDEN";
            body = "Automated verification spam";
            author = "verifier-bot";
            hearth = Some "sandbox";
            post_kind = Some Wire_knowledge.System_post;
            visibility = Some Wire_knowledge.Vis_internal;
            created_at_unix = now_unix -. 60.0;
            updated_at_unix = None;
            score = 999;
            comment_count = 999;
            author_karma = obs 0;
            succession_chain_root_id = None;
            chain_depth = None;
            is_signal = false;
          };
        ];
      count = 3;
      sort_by = "recent";
      signal_only = true;
    }
  in
  let world_memory : Wire_knowledge.world_memory =
    {
      ledger_state = Wire_knowledge.World_ledger_available;
      ledger_sha256 = Some "abc123";
      claims_count = 1025;
      facts_count = 1134;
      conflicts_count = 2;
      excluded_count = 0;
      claims = [];
      active_conflicts = [];
      briefing =
        {
          status = Wire_knowledge.Briefing_current;
          text = Some "3-Stack Native Overhaul active across 5 companies";
          source_ids_count = 12;
          error = None;
          building_pass = None;
        };
      librarian_writers = Wire_knowledge.Writers_none_in_process;
      ordinary_absence_detail = None;
    }
  in
  let wiki_index : Wire_knowledge.wiki_index =
    {
      pages_total = 25;
      pages_readable = 25;
      pages_unreadable = 0;
      pages =
        [
          {
            slug = "wkbl-seo-playbook";
            file = "wkbl-seo-playbook.md";
            title = "WKBL SEO Playbook";
            summary = "Organic growth strategy";
            source = Wire_knowledge.Source_research;
            author = "wkbl-growth";
            created = "2026-11-01";
            updated = "2026-11-19";
            revision = 4;
            tags = [ "wkbl" ];
            backlink_count = 3;
            outgoing_link_count = 2;
            sources_count = 2;
            hearsay_count = 0;
            sha256 = "deadbeef";
          };
        ];
      unreadable_pages = [];
      lint =
        {
          total_findings = 2;
          counts =
            {
              broken_link = 0;
              unsupported_link = 0;
              orphan = 1;
              orphan_unconfirmed = 0;
              missing_sources = 0;
              hearsay_only = 0;
              unreadable_page = 0;
              revision_log_gap = 0;
              revision_log_hole = 0;
              duplicate_title_candidates = 1;
            };
          log_hole_suppressed = false;
          orphans = [ "draft-page" ];
          duplicate_title_candidates = [];
          findings = [];
        };
    }
  in
  let artifacts : Wire_knowledge.artifact_entry list =
    [
      {
        id = "artifact-0123456789abcdef0123456789abcdef";
        revision = 1;
        title = "TUI v2 Retina Capture";
        summary = "Screen capture notes";
        author = "e-masc-the-leader";
        created_at_unix = now_unix;
        body =
          {
            sha256 =
              "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
            bytes = 245_760;
            mime = "text/html";
          };
      };
    ]
  in
  let knowledge =
    Knowledge_store.empty
    |> Knowledge_store.apply_board ~observed_at:Clock.Mono.zero board_feed
    |> Knowledge_store.apply_world_memory ~observed_at:Clock.Mono.zero world_memory
    |> Knowledge_store.apply_wiki_index ~observed_at:Clock.Mono.zero wiki_index
    |> Knowledge_store.apply_artifacts ~observed_at:Clock.Mono.zero artifacts
  in
  let efficiency : Wire_runtime.efficiency_month =
    {
      month = "2026-11";
      window_kind = Some Wire_runtime.Efficiency_month_mtd;
      generated_at_unix = now_unix;
      days_covered = 21;
      keepers =
        [
          {
            keeper = "e-masc-the-leader";
            turns = 412;
            input_tokens = 1_000_000;
            cache_read_tokens = obs 957_000;
            cache_creation_tokens = obs 12_000;
            output_tokens = 48_000;
            cache_hit_pct = obs 95.7;
            cost_usd = 21.4;
            calls = 11_420;
            failed = 120;
            deferred = 5;
            tool_ms = 4200.0;
          };
        ];
      fleet =
        {
          turns_total = 1420;
          calls_per_turn = 4.2;
          tool_s_per_turn = 1.8;
          output_tokens_per_turn = 620.0;
          input_tokens_per_turn = 14_000.0;
          cost_usd_per_turn = 0.08;
          fleet_cache_hit_pct = obs 95.7;
        };
      velocity =
        [
          {
            at_unix = now_unix -. 3600.0;
            input_tok_per_min = obs 120_000.0;
            cache_read_tok_per_min = obs 114_000.0;
            output_tok_per_min = obs 8_000.0;
          };
          {
            at_unix = now_unix -. 1800.0;
            input_tok_per_min = obs 180_000.0;
            cache_read_tok_per_min = obs 172_000.0;
            output_tok_per_min = obs 11_500.0;
          };
          {
            at_unix = now_unix;
            input_tok_per_min = obs 150_000.0;
            cache_read_tok_per_min = obs 143_000.0;
            output_tok_per_min = obs 9_200.0;
          };
        ];
    }
  in
  let runtime_resolved : Wire_runtime.runtime_resolved_snapshot =
    {
      generated_at_iso = "2026-11-21T02:12:00Z";
      config_path = Some ".masc/runtime.toml";
      default_route = Some "sonnet-med-glm";
      lanes =
        [
          {
            id = "sonnet-med-glm";
            declared = true;
            runtime_ids = [ "claude-sonnet"; "glm-5-3" ];
          };
        ];
      runtimes =
        [
          {
            id = "claude-sonnet";
            provider_id = "anthropic";
            provider = "anthropic";
            model = Some "claude-sonnet-4";
            declared_reasoning_effort = None;
            transport = Some "http";
            is_default = true;
          };
          {
            id = "glm-5-3";
            provider_id = "zai";
            provider = "zai";
            model = Some "glm-5.3-flash";
            declared_reasoning_effort = None;
            transport = Some "http";
            is_default = false;
          };
        ];
      usage_windows = None;
    }
  in
  let runtime_probe : Wire_runtime.runtime_probe_snapshot =
    {
      generated_at = "2026-11-21T02:12:00Z";
      cache_ttl_sec = 60.0;
      cache_age_sec = Some 4.0;
      cache_hit = true;
      refresh_state = Wire_runtime.Probe_fresh;
      status = Wire_runtime.Probe_ok;
      probe_ok = true;
      default_runtime_id = Some "claude-sonnet";
      runtimes_count = 16;
      probed_count = 16;
      reachable_count = 16;
      failed_count = 0;
      skipped_count = 0;
      providers = [];
      errors = [];
      observations = [];
      limitations = [];
    }
  in
  let runtime =
    Runtime_store.empty
    |> Runtime_store.apply_efficiency ~observed_at:Clock.Mono.zero efficiency
    |> Runtime_store.apply_runtime_resolved ~observed_at:Clock.Mono.zero runtime_resolved
    |> Runtime_store.apply_runtime_probe ~observed_at:Clock.Mono.zero runtime_probe
  in
  let fleet_metrics : Wire_infra.tool_metrics_24h =
    {
      calls = 38_700;
      failures = 967;
      failure_unclassified = 0;
      p50_ms = obs 1.8;
      p95_ms = obs 4.7;
      max_ms = obs 120.0;
      failure_classes =
        {
          dependency_unavailable = 14;
          runtime_failure = 6;
          policy_rejection = 2;
          workflow_rejection = 1;
          operator_cancelled = 0;
        };
    }
  in
  let sandboxes : Wire_infra.sandboxes_snapshot =
    {
      probe_state = Wire_infra.Probe_fresh now_unix;
      microvm_declared = 19;
      microvm_running = 15;
      microvm_sockets_present = 15;
      microvm_shim_mismatch = 0;
      ssh_pools_count = 2;
      ssh_keepers_count = 13;
      ssh_unbound_keepers_count = 0;
      ssh_active_sessions = obs 12;
      ssh_max_sessions = 32;
      docker_keepers_count = 0;
      microvm_guests =
        [
          {
            keeper = "e-masc-the-leader";
            backend = "apple_container";
            guest_name = "vm-leader";
            presence = "running";
            agent_socket = Wire_infra.Socket_present { path_basename = Some "leader.sock" };
            shim_parity = Wire_infra.Shim_matched "v0.77.1";
            network_mode = Wire_infra.Net_inherit;
            cpus = obs 2;
            memory_mib = obs 2048;
            volume = Wire_infra.Volume_declared "vol-leader";
            metrics_24h = fleet_metrics;
          };
        ];
      ssh_pools =
        [
          {
            pool_name = "masc-ssh-review-team";
            host = "127.0.0.1";
            port = 22268;
            unix_user = "review";
            remote_root = "/srv/work";
            private_home = true;
            max_sessions = 24;
            active_sessions = obs 8;
            reachability =
              Wire_infra.Ssh_reachable { rtt_ms = 18.0; measured_at_unix = now_unix };
            accounts = [];
            keeper_sessions =
              [
                {
                  keeper = "code-reviewer";
                  last_dispatch = `Null;
                  metrics_24h = fleet_metrics;
                };
              ];
            metrics_24h = fleet_metrics;
          };
        ];
      ssh_unbound_keepers = [];
      docker_keepers = [];
      fleet_metrics_24h = fleet_metrics;
      volume_gc_report = None;
      host_storage = None;
      unobserved_reasons = [];
    }
  in
  let infra =
    Infra_store.empty
    |> Infra_store.apply_sandboxes ~observed_at:Clock.Mono.zero sandboxes
  in
  let config_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha256-base";
      sections =
        [
          {
            id = "routing";
            category = Wire_config.Cat_routing_failover;
            title = "Routing & Failover";
            fields =
              [
                {
                  table = "turn";
                  key = "stream_idle_timeout_sec";
                  full_key = "turn.stream_idle_timeout_sec";
                  label = "Stream Idle Timeout";
                  env = None;
                  description = Some "Must stay > 0";
                  kind = Wire_config.Field_int { min = Some 1; max = Some 3600 };
                  value = Wire_config.Val_int 120;
                  default_value = Some (Wire_config.Val_int 120);
                  provenance = Wire_config.Prov_global;
                  reload_scope = Wire_config.Restart_required;
                  secret = false;
                  writable = true;
                };
                {
                  table = "provider";
                  key = "api_key";
                  full_key = "provider.api_key";
                  label = "Provider API Key";
                  env = Some "ANTHROPIC_API_KEY";
                  description = Some "Masked secret credential";
                  kind = Wire_config.Field_secret;
                  value =
                    Wire_config.Val_secret
                      {
                        configured = true;
                        source = Wire_config.Secret_inline_redacted;
                      };
                  default_value = None;
                  provenance = Wire_config.Prov_env_override;
                  reload_scope = Wire_config.Hot_reload;
                  secret = true;
                  writable = false;
                };
              ];
          };
        ];
    }
  in
  let dry_run_resp : Wire_config.patch_response =
    {
      applied = false;
      dry_run = true;
      target = "runtime";
      changed = true;
      before_sha256 = "sha256-base";
      new_sha256 = "sha256-next";
      snapshot_id = Some "snap-20261121-01";
      snapshot_path = None;
      reload_scope = Wire_config.Restart_required;
      unified_diff =
        "--- runtime.toml\n+++ runtime.toml\n@@ -1,2 +1,2 @@\n-stream_idle_timeout_sec = 120\n+stream_idle_timeout_sec = 180\n";
      diff_hunks = [];
      validation_warnings = [];
    }
  in
  let config =
    Config_store.empty
    |> Config_store.set_tab Nav.Settings_routing_failover
    |> Config_store.apply_schema ~observed_at:Clock.Mono.zero config_schema
    |> Config_store.stage_patch ~full_key:"turn.stream_idle_timeout_sec"
         (Wire_config.Set_int
            { table = "turn"; key = "stream_idle_timeout_sec"; value = 180 })
    |> Config_store.apply_patch_response ~dry_run:true dry_run_resp
  in
  let incidents, _ =
    Incidents.empty
    |> Incidents.push ~occurred_at_unix:(now_unix -. 120.0)
         ~source:(Health.Source_keeper "wkbl-growth")
         ~summary:(Say.make ~ko:"과거 턴 실패 (복구됨)" ~en:"Past turn failure (recovered)")
         ~detail:
           "{\"kind\":\"operator_action.v1\",\"keeper\":\"wkbl-growth\",\"api_key\":\"sk-SUPERSECRET123456\",\"status\":\"resolved\"}"
         ~status:Health.Resolved
  in
  let health : Wire_common.server_health =
    {
      ok = true;
      live = Some true;
      ready = Some true;
      phase = Some "ready";
      status = "ok";
      version = "0.77.1";
      binary_commit = Some "3e2f6b7";
      uptime_display = Some "4h12m";
      uptime_sec = Some 15120.0;
      scope =
        Wire_common.Full_health
          {
            instance_id = Some "inst-01";
            base_path = "/srv/masc";
            masc_root = "/srv/masc/.masc";
            workspace_sha256 = Some "ws-hash";
          };
      gc =
        Some
          {
            live_words = Some 524_288_000;
            heap_words = Some 590_000_000;
            major_collections = Some 120;
            minor_collections = Some 4200;
          };
      active_keepers = Some 8;
    }
  in
  let m1 =
    {
      m0 with
      freshness =
        {
          m0.freshness with
          observer = Health.Live { last_event_ns = Clock.Mono.zero; revision = 99 };
          fleet = Health.Live { last_event_ns = Clock.Mono.zero; revision = 42 };
          last_wall_unix = now_unix;
          server_offline = false;
        };
      server_identity =
        {
          m0.server_identity with
          health = Some health;
          workspace =
            Some
              {
                instance_id = Some "inst-01";
                base_path = "/srv/masc";
                masc_root = "/srv/masc/.masc";
                workspace_sha256 = Some "ws-hash";
              };
        };
      fleet;
      work;
      knowledge;
      runtime;
      infra;
      config;
      incidents;
    }
  in
  Model.rebuild_attention m1

let render_full ~model ~cols ~rows =
  let grid = Cell_grid.create ~cols ~rows in
  let cache = Card.Cache.create () in
  let cursor =
    Chrome.render_frame ~model ~cache
      ~render_body:(fun rect g -> Screen_pulse.render ~model ~cache ~rect g)
      ~render_overlay:(fun rect g -> Overlays.render ~model ~cache ~rect g)
      grid
  in
  (grid, cursor)

(* ---------- Tests ---------- *)

let test_compact_chrome_auto_fold () =
  (* 90x28 on tabbed workspace Work, idle & empty draft & no approval strip -> 3 chrome rows (10.7%) *)
  let m_work =
    let m = Model.initial ~cols:90 ~rows:28 ~lang:Say.Lang_ko () in
    { m with nav = { m.nav with workspace = Nav.Work } }
  in
  let l_idle = Chrome.compute_layout ~model:m_work ~cols:90 ~rows:28 in
  Alcotest.(check int) "90x28 Work idle chrome_rows = 3" 3 l_idle.chrome_rows;
  Alcotest.(check bool) "90x28 Work idle composer_folded" true l_idle.composer_folded;
  Alcotest.(check bool) "90x28 Work idle composer rect is None" true
    (Option.is_none l_idle.composer);
  Alcotest.(check bool) "90x28 Work has sub_tab_bar" true
    (Option.is_some l_idle.sub_tab_bar);

  (* Pulse has 0 sub-tab rows -> 2 chrome rows when composer folded *)
  let m_pulse = Model.initial ~cols:90 ~rows:28 ~lang:Say.Lang_en () in
  let l_pulse = Chrome.compute_layout ~model:m_pulse ~cols:90 ~rows:28 in
  Alcotest.(check int) "90x28 Pulse idle chrome_rows = 2" 2 l_pulse.chrome_rows;
  Alcotest.(check bool) "90x28 Pulse has no sub_tab_bar" true
    (Option.is_none l_pulse.sub_tab_bar);

  (* Focusing composer or entering draft auto-expands composer on Compact *)
  let m_draft = { m_work with drafts = Drafts.insert_text "hello" m_work.drafts } in
  let l_draft = Chrome.compute_layout ~model:m_draft ~cols:90 ~rows:28 in
  Alcotest.(check bool) "Compact non-empty draft expands composer" false
    l_draft.composer_folded;
  Alcotest.(check bool) "Compact non-empty draft allocates composer rect" true
    (Option.is_some l_draft.composer);

  let m_focused = { m_work with drafts = Drafts.set_focus true m_work.drafts } in
  let l_focused = Chrome.compute_layout ~model:m_focused ~cols:90 ~rows:28 in
  Alcotest.(check bool) "Compact focused composer expands" false
    l_focused.composer_folded;

  (* Voice recording expands composer *)
  let m_voice =
    {
      m_work with
      drafts = Drafts.voice_start_recording ~now:Clock.Mono.zero m_work.drafts;
    }
  in
  let l_voice = Chrome.compute_layout ~model:m_voice ~cols:90 ~rows:28 in
  Alcotest.(check bool) "Compact voice active expands composer" false
    l_voice.composer_folded;

  (* Wide 140x40 keeps persistent collapsed composer bar *)
  let m_wide = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_en () in
  let l_wide = Chrome.compute_layout ~model:m_wide ~cols:140 ~rows:40 in
  Alcotest.(check bool) "Wide 140x40 composer not folded" false
    l_wide.composer_folded;
  Alcotest.(check bool) "Wide 140x40 composer rect present" true
    (Option.is_some l_wide.composer)

let test_footer_never_overflows () =
  let widths = [ 80; 90; 140; 180 ] in
  let langs = [ Say.Lang_ko; Say.Lang_en ] in
  List.iter
    (fun lang ->
      List.iter
        (fun cols ->
          let rows = if cols >= 140 then 40 else 28 in
          let m_pop = populated_model ~cols ~rows ~lang in
          let m_empty = Model.initial ~cols ~rows ~lang () in
          let variants =
            [
              ("pop_idle", m_pop);
              ("empty_idle", m_empty);
              ( "composer_focused",
                { m_pop with drafts = Drafts.set_focus true m_pop.drafts } );
              ( "overlay_help",
                { m_pop with nav = { m_pop.nav with overlay = Some Nav.Help } } );
            ]
          in
          List.iter
            (fun (tag, model) ->
              let grid, _ = render_full ~model ~cols ~rows in
              let label = Printf.sprintf "footer_%s_%dx%d" tag cols rows in
              assert_clean_grid ~label grid;
              let footer_line = grid_row_text grid (rows - 1) in
              assert_not_contains ~label ~needle:"...?" footer_line;
              Alcotest.(check bool)
                (label ^ " footer non-empty")
                true
                (String.length (String.trim footer_line) > 0))
            variants)
        widths)
    langs

let test_chrome_freshness_and_subtabs () =
  let base = populated_model ~cols:90 ~rows:28 ~lang:Say.Lang_en in
  let states =
    [
      ( "live",
        {
          base with
          freshness =
            {
              base.freshness with
              observer = Health.Live { last_event_ns = Clock.Mono.zero; revision = 1 };
              server_offline = false;
            };
        },
        "LIVE" );
      ( "reconnecting",
        {
          base with
          freshness =
            {
              base.freshness with
              observer =
                Health.Reconnecting
                  { last_live_ns = None; attempt = 2; reason = Health.Timeout };
              server_offline = false;
            };
        },
        "RECON" );
      ( "stale",
        {
          base with
          freshness =
            {
              base.freshness with
              observer = Health.Stale { last_live_ns = Clock.Mono.zero; age_sec = 45.0 };
              server_offline = false;
            };
        },
        "STALE" );
      ( "offline",
        {
          base with
          freshness = { base.freshness with server_offline = true };
        },
        "OFFLINE" );
    ]
  in
  List.iter
    (fun (tag, model, expected_pill) ->
      let grid, _ = render_full ~model ~cols:90 ~rows:28 in
      assert_clean_grid ~label:("freshness_" ^ tag) grid;
      let rail = grid_row_text grid 0 in
      assert_contains ~label:("freshness_" ^ tag) ~needle:expected_pill rail)
    states;
  (* Verify sub-tab bars fit cleanly at 90x28 KO & EN without 4> hiding *)
  List.iter
    (fun lang ->
      List.iter
        (fun ws ->
          let m = { base with lang; nav = { base.nav with workspace = ws } } in
          let grid, _ = render_full ~model:m ~cols:90 ~rows:28 in
          let lbl = Printf.sprintf "subtab_ws%d" (Nav.workspace_index ws) in
          assert_clean_grid ~label:lbl grid;
          if Chrome.has_sub_tab_bar m then
            assert_not_contains ~label:lbl ~needle:"4>" (grid_row_text grid 1))
        Nav.all_workspaces)
    [ Say.Lang_ko; Say.Lang_en ]

let test_micro_viewport_guard () =
  (* 60x18 Micro guard with hidden draft: NOT a dead blocker, protects draft *)
  let m0 = populated_model ~cols:60 ~rows:18 ~lang:Say.Lang_en in
  let m = { m0 with drafts = Drafts.insert_text "unsent message" m0.drafts } in
  let layout = Chrome.compute_layout ~model:m ~cols:60 ~rows:18 in
  Alcotest.(check bool) "60x18 is_micro_guard" true layout.is_micro_guard;
  Alcotest.(check bool) "60x18 is_too_small = false" false layout.is_too_small;
  let grid, _ = render_full ~model:m ~cols:60 ~rows:18 in
  assert_clean_grid ~label:"micro_60x18_en" grid;
  let all = grid_all_text grid in
  assert_contains ~label:"micro_60x18_en" ~needle:"LIVE" all;
  assert_contains ~label:"micro_60x18_en" ~needle:"Action Queue" all;
  assert_contains ~label:"micro_60x18_en" ~needle:"draft" all;

  (* Korean 60x18 *)
  let m_ko = { m with lang = Say.Lang_ko } in
  let grid_ko, _ = render_full ~model:m_ko ~cols:60 ~rows:18 in
  assert_clean_grid ~label:"micro_60x18_ko" grid_ko;
  assert_contains ~label:"micro_60x18_ko" ~needle:"초안" (grid_all_text grid_ko);

  (* <40x12 too small blocker renders without throwing *)
  let grid_tiny, _ = render_full ~model:m ~cols:34 ~rows:10 in
  assert_clean_grid ~label:"too_small_34x10" grid_tiny

let test_pulse_populated_and_empty () =
  let viewports = [ (140, 40); (110, 32); (90, 28) ] in
  List.iter
    (fun lang ->
      List.iter
        (fun (cols, rows) ->
          (* Populated Pulse *)
          let m_pop = populated_model ~cols ~rows ~lang in
          let g_pop, _ = render_full ~model:m_pop ~cols ~rows in
          let lbl = Printf.sprintf "pulse_pop_%dx%d" cols rows in
          assert_clean_grid ~label:lbl g_pop;
          let txt = grid_all_text g_pop in
          assert_contains ~label:lbl ~needle:"MASC Core Eng" txt;
          assert_contains ~label:lbl ~needle:"95.7%" txt;
          assert_contains ~label:lbl ~needle:"[x22]" txt;
          assert_contains ~label:lbl ~needle:"1025" txt;
          (* Verify noise thread is excluded *)
          assert_not_contains ~label:lbl ~needle:"MUST_BE_HIDDEN" txt;
          (* Unattributed Candle alert surfaced *)
          let unattrib =
            match lang with Say.Lang_ko -> "미귀속" | Say.Lang_en -> "unattributed"
          in
          assert_contains ~label:lbl ~needle:unattrib txt;

          (* Empty Pulse: Panel A collapses to 1-line All clear pill *)
          let m_empty = Model.initial ~cols ~rows ~lang () in
          let g_empty, _ = render_full ~model:m_empty ~cols ~rows in
          let lbl_e = Printf.sprintf "pulse_empty_%dx%d" cols rows in
          assert_clean_grid ~label:lbl_e g_empty;
          let txt_e = grid_all_text g_empty in
          let clear_str =
            match lang with Say.Lang_ko -> "확인 대기 없음" | Say.Lang_en -> "All clear"
          in
          assert_contains ~label:lbl_e ~needle:clear_str txt_e)
        viewports)
    [ Say.Lang_ko; Say.Lang_en ]

let test_all_7_overlays () =
  let viewports = [ (140, 40); (90, 28); (60, 18) ] in
  List.iter
    (fun lang ->
      List.iter
        (fun (cols, rows) ->
          let base = populated_model ~cols ~rows ~lang in
          (* 1. Palette: commands, keepers, models + geometry check *)
          let overlay_area = Rect.make ~x:0 ~y:1 ~w:cols ~h:(Int.max 0 (rows - 2)) in
          let pal_r = Overlays.palette_modal_rect ~rect:overlay_area in
          Alcotest.(check bool) "Palette max height <= 22" true (pal_r.h <= 22);
          if cols >= 80 then
            Alcotest.(check bool) "Palette min width >= 74" true (pal_r.w >= 74);
          List.iter
            (fun (pmode, query) ->
              let m =
                {
                  base with
                  nav = { base.nav with overlay = Some Nav.Palette };
                  palette = { mode = pmode; query; selected = 0 };
                }
              in
              let g, _ = render_full ~model:m ~cols ~rows in
              assert_clean_grid ~label:"overlay_palette" g)
            [
              (Model.Palette_commands, "");
              (Model.Palette_commands, "wkbl");
              (Model.Palette_keepers, "code");
              (Model.Palette_models, "glm");
            ];

          (* 2. Settings: all 7 tabs + targets + secret masking + dry_run + snapshot *)
          List.iter
            (fun tab ->
              let m =
                {
                  base with
                  nav = { base.nav with overlay = Some (Nav.Settings tab) };
                  config = { base.config with active_tab = tab };
                }
              in
              let g, _ = render_full ~model:m ~cols ~rows in
              let lbl = Printf.sprintf "overlay_settings_%dx%d" cols rows in
              assert_clean_grid ~label:lbl g;
              let txt = grid_all_text g in
              if cols >= 90 then begin
                (* All 7 tabs visible without 4> hiding *)
                assert_not_contains ~label:lbl ~needle:"4>" txt;
                assert_contains ~label:lbl ~needle:"1" txt;
                assert_contains ~label:lbl ~needle:"7" txt
              end)
            Nav.all_settings_tabs;
          (* Verify dry_run diff preview & snapshot receipt & keeper_create target *)
          let m_save =
            let saved_resp : Wire_config.patch_response =
              {
                applied = true;
                dry_run = false;
                target = "runtime";
                changed = true;
                before_sha256 = "sha256-base";
                new_sha256 = "sha256-saved";
                snapshot_id = Some "snap-9999";
                snapshot_path = None;
                reload_scope = Wire_config.Hot_reload;
                unified_diff = "";
                diff_hunks = [];
                validation_warnings = [];
              }
            in
            let cfg =
              base.config
              |> Config_store.apply_patch_response ~dry_run:false saved_resp
            in
            {
              base with
              nav = { base.nav with overlay = Some (Nav.Settings Nav.Settings_routing_failover) };
              config = cfg;
            }
          in
          let g_save, _ = render_full ~model:m_save ~cols ~rows in
          assert_clean_grid ~label:"overlay_settings_saved" g_save;
          if rows >= 24 then
            assert_contains ~label:"overlay_settings_saved" ~needle:"snap-9999"
              (grid_all_text g_save);

          (* 3. Incidents Drawer: structured Json_tree + secret redaction, ZERO raw JSON dump *)
          let m_inc =
            { base with nav = { base.nav with overlay = Some Nav.Incidents } }
          in
          let g_inc, _ = render_full ~model:m_inc ~cols ~rows in
          assert_clean_grid ~label:"overlay_incidents" g_inc;
          let inc_txt = grid_all_text g_inc in
          assert_not_contains ~label:"overlay_incidents_no_raw_json"
            ~needle:"{\"kind\":\"operator_action.v1\"" inc_txt;
          assert_not_contains ~label:"overlay_incidents_no_secret_leak"
            ~needle:"sk-SUPERSECRET123456" inc_txt;

          (* 4. Queue / Context / Schedules Drawer (3 tabs) *)
          List.iter
            (fun tab ->
              let drafts =
                match
                  Drafts.enqueue_submission ~now:Clock.Mono.zero
                    ~keeper:"e-masc-the-leader" ~mode:Drafts.Mode_steer
                    (Drafts.insert_text "Steer test msg" base.drafts)
                with
                | Some (d, _) -> d
                | None -> base.drafts
              in
              let m =
                {
                  base with
                  drafts;
                  nav = { base.nav with overlay = Some (Nav.Queue_context tab) };
                }
              in
              let g, _ = render_full ~model:m ~cols ~rows in
              assert_clean_grid ~label:"overlay_queue_context" g)
            Nav.all_queue_context_tabs;

          (* 5. Inline Action & /btw Modal (all 8 kinds + btw streaming/answered) *)
          let btw_drafts, req_id =
            Drafts.start_btw ~now:Clock.Mono.zero ~keeper:"e-masc-the-leader"
              ~prompt:"Summarize PR #54340" base.drafts
          in
          let btw_streaming =
            Drafts.append_btw_delta ~request_id:req_id
              ~delta:"All 4 layers approved." btw_drafts
          in
          let inline_kinds =
            [
              Nav.Btw_query;
              Nav.Gate_reject "gate-1";
              Nav.Verification_reject "ver-1";
              Nav.Task_cancel "task-3898";
              Nav.Goal_drop "goal-1";
              Nav.Schedule_form;
              Nav.Connector_form;
              Nav.Repo_add_form;
              Nav.Board_new_post;
            ]
          in
          List.iter
            (fun kind ->
              let m =
                {
                  base with
                  drafts = btw_streaming;
                  nav = { base.nav with overlay = Some (Nav.Inline_action kind) };
                  inline_modal = Some (Model.inline_modal_for kind);
                }
              in
              let g, _ = render_full ~model:m ~cols ~rows in
              assert_clean_grid ~label:"overlay_inline_action" g)
            inline_kinds;

          (* 6. ? Dynamic SSOT Help *)
          let m_help =
            { base with nav = { base.nav with overlay = Some Nav.Help } }
          in
          let g_help, _ = render_full ~model:m_help ~cols ~rows in
          assert_clean_grid ~label:"overlay_help" g_help;
          assert_contains ~label:"overlay_help" ~needle:"Ctrl+K"
            (grid_all_text g_help);

          (* 7. System / Auth / Media Gate Overlays *)
          let gates =
            [
              ( Nav.Server_offline,
                {
                  base with
                  freshness =
                    {
                      base.freshness with
                      server_offline = true;
                      observer =
                        Health.Disconnected
                          {
                            since_ns = Clock.Mono.zero;
                            reason = Health.Connect_refused;
                          };
                    };
                } );
              ( Nav.Server_offline,
                {
                  base with
                  freshness =
                    {
                      base.freshness with
                      observer =
                        Health.Workspace_mismatch
                          {
                            expected_instance = "inst-old";
                            observed_instance = "inst-new";
                          };
                    };
                  server_identity =
                    {
                      base.server_identity with
                      mismatch_state = Model.Mismatch_halted;
                    };
                } );
              (Nav.Auth_gate, base);
              (Nav.Media_viewer, base);
              (Nav.Micro_viewport, base);
            ]
          in
          List.iter
            (fun (gate, (m0 : Model.t)) ->
              let m =
                { m0 with nav = { m0.nav with overlay = Some (Nav.System_gate gate) } }
              in
              let g, _ = render_full ~model:m ~cols ~rows in
              assert_clean_grid ~label:"overlay_system_gate" g)
            gates)
        viewports)
    [ Say.Lang_ko; Say.Lang_en ]

let find_focused_row_containing ~needle (grid : Cell_grid.t) =
  let rail = Glyph.to_utf8 Glyph.Left_rail in
  let rows = Cell_grid.rows grid in
  let rec scan y =
    if y >= rows then None
    else
      let line = grid_row_text grid y in
      if has_substring ~needle:rail line && has_substring ~needle line then
        Some line
      else scan (y + 1)
  in
  scan 0

let test_palette_high_selection_and_sync () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let m_pal_base =
    {
      base with
      nav = { base.nav with overlay = Some Nav.Palette };
      palette = { mode = Model.Palette_commands; query = ""; selected = 0 };
    }
  in
  let entries = Update_nav.palette_entries m_pal_base in
  Alcotest.(check bool) "unified palette has > 25 entries across all sections"
    true (List.length entries > 25);
  let entry15 =
    match List.nth_opt entries 15 with
    | Some e -> e
    | None -> Alcotest.fail "expected at least 16 palette entries"
  in
  let last_entry =
    match List.nth_opt entries (List.length entries - 1) with
    | Some e -> e
    | None -> Alcotest.fail "expected non-empty palette entries"
  in
  List.iter
    (fun (cols, rows) ->
      let m15 =
        {
          m_pal_base with
          palette = { mode = Model.Palette_commands; query = ""; selected = 15 };
        }
      in
      let g15, _ = render_full ~model:m15 ~cols ~rows in
      assert_clean_grid ~label:"palette_sel15" g15;
      let prefix15 =
        String.sub entry15.title 0 (Int.min 12 (String.length entry15.title))
      in
      (match find_focused_row_containing ~needle:prefix15 g15 with
       | Some _ -> ()
       | None ->
           Alcotest.fail
             (Printf.sprintf
                "palette_sel15 (%dx%d): expected focused row containing %S:\n%s"
                cols rows prefix15 (grid_all_text g15)));
      (* Out-of-bounds selection clamps to last selectable unified entry *)
      let m_oob =
        {
          m_pal_base with
          palette = { mode = Model.Palette_commands; query = ""; selected = 999 };
        }
      in
      let g_oob, _ = render_full ~model:m_oob ~cols ~rows in
      assert_clean_grid ~label:"palette_oob" g_oob;
      let prefix_last =
        String.sub last_entry.title 0
          (Int.min 12 (String.length last_entry.title))
      in
      (match find_focused_row_containing ~needle:prefix_last g_oob with
       | Some _ -> ()
       | None ->
           Alcotest.fail
             (Printf.sprintf
                "palette_oob (%dx%d): expected clamped last entry %S:\n%s"
                cols rows prefix_last (grid_all_text g_oob))))
    [ (140, 40); (90, 28) ];
  (* Palette_keepers & Palette_models stay in sync with Update_nav *)
  let m_keep =
    {
      base with
      nav = { base.nav with overlay = Some Nav.Palette };
      palette = { mode = Model.Palette_keepers; query = ""; selected = 6 };
    }
  in
  let keepers = Update_nav.palette_filtered_keepers m_keep in
  let expected_keeper = (List.nth keepers 6).name in
  let g_keep, _ = render_full ~model:m_keep ~cols:140 ~rows:40 in
  (match find_focused_row_containing ~needle:expected_keeper g_keep with
   | Some _ -> ()
   | None ->
       Alcotest.fail
         (Printf.sprintf "palette_keepers: expected focused %S:\n%s"
            expected_keeper (grid_all_text g_keep)));
  let m_mdl =
    {
      base with
      nav = { base.nav with overlay = Some Nav.Palette };
      palette = { mode = Model.Palette_models; query = ""; selected = 1 };
    }
  in
  let g_mdl, _ = render_full ~model:m_mdl ~cols:140 ~rows:40 in
  match find_focused_row_containing ~needle:"glm-5-3" g_mdl with
  | Some _ -> ()
  | None ->
      Alcotest.fail
        (Printf.sprintf "palette_models: expected focused glm-5-3:\n%s"
           (grid_all_text g_mdl))

let test_incident_prefixed_and_truncated_redaction () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let now = 1763701200.0 in
  let inc0, _ =
    Incidents.empty
    |> Incidents.push ~occurred_at_unix:(now -. 10.0)
         ~source:Health.Source_client_http
         ~summary:(Say.make ~ko:"HTTP 500" ~en:"HTTP 500 JSON")
         ~detail:
           "HTTP 500 Internal Server Error: {\"error\":\"boom\",\"api_key\":\"sk-PREFIXEDSECRET99\",\"nested\":{\"token\":\"ghp_NESTEDSECRET77\"}}"
         ~status:Health.Resolved
  in
  let inc1, _ =
    Incidents.push ~occurred_at_unix:(now -. 20.0)
      ~source:Health.Source_client_http
      ~summary:(Say.make ~ko:"HTTP 502" ~en:"HTTP 502 Truncated")
      ~detail:
        "HTTP 502: {\"error\":\"upstream\",\"authorization\":\"Bearer eyJTRUNCATEDSECRET88"
      ~status:Health.Resolved inc0
  in
  let inc2, _ =
    Incidents.push ~occurred_at_unix:(now -. 30.0)
      ~source:Health.Source_stream
      ~summary:(Say.make ~ko:"평문 시크릿" ~en:"Plain text secret")
      ~detail:
        "Authorization: Bearer sk-PLAINTEXTSECRET66\n-----BEGIN RSA PRIVATE KEY-----\nMIIEFAKEKEY\n-----END RSA PRIVATE KEY-----"
      ~status:Health.Resolved inc1
  in
  let check_entry idx fn =
    let m =
      {
        base with
        nav = { base.nav with overlay = Some Nav.Incidents };
        incidents = { inc2 with selected_index = idx };
      }
    in
    let g, _ = render_full ~model:m ~cols:140 ~rows:40 in
    assert_clean_grid ~label:(Printf.sprintf "incident_redaction_%d" idx) g;
    fn (grid_all_text g)
  in
  (* Latest pushed is index 0 -> plain text secret *)
  check_entry 0 (fun txt ->
      assert_not_contains ~label:"plain_bearer" ~needle:"sk-PLAINTEXTSECRET66" txt;
      assert_not_contains ~label:"plain_pem" ~needle:"MIIEFAKEKEY" txt;
      assert_contains ~label:"plain_redacted" ~needle:"[redacted]" txt);
  (* Index 1 -> truncated invalid JSON *)
  check_entry 1 (fun txt ->
      assert_not_contains ~label:"trunc_json" ~needle:"eyJTRUNCATEDSECRET88" txt;
      assert_contains ~label:"trunc_redacted" ~needle:"[redacted]" txt);
  (* Index 2 -> prefixed valid JSON *)
  check_entry 2 (fun txt ->
      assert_contains ~label:"prefixed_hdr" ~needle:"HTTP 500" txt;
      assert_not_contains ~label:"prefixed_no_raw_json"
        ~needle:"{\"error\":\"boom\"" txt;
      assert_not_contains ~label:"prefixed_key" ~needle:"sk-PREFIXEDSECRET99" txt;
      assert_not_contains ~label:"prefixed_nested" ~needle:"ghp_NESTEDSECRET77" txt;
      assert_contains ~label:"prefixed_redacted" ~needle:"[redacted]" txt)

let test_pulse_selection_scroll_and_velocity_units () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  (* 1. Velocity chart labels reflect tok/min (150.0k & 9.2k), NOT 95.7 tok *)
  let g_wide, _ = render_full ~model:base ~cols:140 ~rows:40 in
  let txt_wide = grid_all_text g_wide in
  assert_contains ~label:"velocity_upper_tok" ~needle:"150.0k" txt_wide;
  assert_contains ~label:"velocity_lower_tok" ~needle:"9.2k" txt_wide;
  assert_not_contains ~label:"velocity_no_pct_as_tok" ~needle:"95.7 tok" txt_wide;
  assert_contains ~label:"velocity_cache_pct" ~needle:"95.7%" txt_wide;

  (* 2. Companies panel follows selected keeper's company when Companies pane is focused *)
  let m_wkbl =
    {
      base with
      nav = { base.nav with pane_index = 1 };
      fleet = Fleet_store.select_keeper "wkbl-growth" base.fleet;
    }
  in
  let g_wkbl, _ = render_full ~model:m_wkbl ~cols:140 ~rows:40 in
  (match find_focused_row_containing ~needle:"WKBL Startup" g_wkbl with
   | Some _ -> ()
   | None ->
       Alcotest.fail
         (Printf.sprintf "pulse_company_sel: expected WKBL Startup focused:\n%s"
            (grid_all_text g_wkbl)));

  (* 3. Companies & Attention scroll selected item into view when overflowing *)
  let many_keepers =
    List.init 8 (fun i ->
        mk_keeper
          ~name:(Printf.sprintf "keeper-c%02d" (i + 1))
          ~company:(Printf.sprintf "Company-%02d" (i + 1))
          ~health:Wire_fleet.Keeper_working ())
  in
  let many_asks : Wire_work.ask_row list =
    List.init 8 (fun i : Wire_work.ask_row ->
        {
          ask_id = Printf.sprintf "ask-%02d" (i + 1);
          keeper = Printf.sprintf "ask-keeper-%02d" (i + 1);
          asked_at = 1763701100.0 -. float_of_int i;
          context = None;
          questions =
            [
              {
                question_id = "q1";
                header = "Approve";
                prompt = Printf.sprintf "Confirm action #%d?" (i + 1);
                mode = Wire_work.Ask_single;
                allow_free_text = false;
                free_text_hint = None;
                choices = [];
              };
            ];
          resolution = Wire_work.Ask_open;
        })
  in
  let m_scroll =
    let fleet =
      base.fleet
      |> Fleet_store.apply_keepers ~observed_at:Clock.Mono.zero many_keepers
      |> Fleet_store.select_keeper "keeper-c08"
    in
    let work =
      base.work
      |> Work_store.apply_asks ~observed_at:Clock.Mono.zero many_asks
      |> Work_store.apply_tool_approvals ~observed_at:Clock.Mono.zero []
    in
    let m1 = Model.rebuild_attention { base with fleet; work } in
    let last_idx = Int.max 0 (Attention.count m1.attention - 1) in
    { m1 with attention = { m1.attention with triage_index = last_idx } }
  in
  let g_scroll, _ = render_full ~model:m_scroll ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"pulse_scroll" g_scroll;
  let g_scroll_co, _ =
    render_full
      ~model:{ m_scroll with nav = { m_scroll.nav with pane_index = 1 } }
      ~cols:140 ~rows:40
  in
  (match find_focused_row_containing ~needle:"Company-08" g_scroll_co with
   | Some _ -> ()
   | None ->
       Alcotest.fail
         (Printf.sprintf "pulse_company_scroll: expected Company-08 visible & focused:\n%s"
            (grid_all_text g_scroll_co)));
  let last_attn_needle =
    match Attention.current_triage_item m_scroll.attention with
    | Some item -> (
        match Render_util.attention_kind_keeper item.kind with
        | Some k -> k
        | None ->
            if String.length item.title > 12 then String.sub item.title 0 12
            else item.title)
    | None -> "ask-keeper-08"
  in
  match find_focused_row_containing ~needle:last_attn_needle g_scroll with
  | Some _ -> ()
  | None ->
      Alcotest.fail
        (Printf.sprintf "pulse_attn_scroll: expected %S visible & focused:\n%s"
           last_attn_needle (grid_all_text g_scroll))

let test_no_default_leak_no_dup_diff_and_micro_grid_dims () =
  (* 1. Empty model NEVER leaks "@_default" across Composer, Compact, Micro, Ctrl+T *)
  List.iter
    (fun (lang, expected_none) ->
      let m_wide = Model.initial ~cols:140 ~rows:40 ~lang () in
      let g_wide, _ = render_full ~model:m_wide ~cols:140 ~rows:40 in
      let txt_wide = grid_all_text g_wide in
      assert_not_contains ~label:"no_default_wide" ~needle:"_default" txt_wide;
      assert_contains ~label:"display_none_wide" ~needle:expected_none txt_wide;

      let m_compact = Model.initial ~cols:90 ~rows:28 ~lang () in
      let g_compact, _ = render_full ~model:m_compact ~cols:90 ~rows:28 in
      assert_not_contains ~label:"no_default_compact" ~needle:"_default"
        (grid_all_text g_compact);

      let m_micro = Model.initial ~cols:60 ~rows:18 ~lang () in
      let g_micro, _ = render_full ~model:m_micro ~cols:60 ~rows:18 in
      let txt_micro = grid_all_text g_micro in
      assert_not_contains ~label:"no_default_micro" ~needle:"_default" txt_micro;
      assert_contains ~label:"display_none_micro" ~needle:expected_none txt_micro;

      let m_drawer =
        {
          m_wide with
          nav =
            {
              m_wide.nav with
              overlay = Some (Nav.Queue_context Nav.Drawer_queue);
            };
        }
      in
      let g_drawer, _ = render_full ~model:m_drawer ~cols:140 ~rows:40 in
      let txt_drawer = grid_all_text g_drawer in
      assert_not_contains ~label:"no_default_drawer" ~needle:"_default" txt_drawer;
      assert_contains ~label:"display_none_drawer" ~needle:expected_none
        txt_drawer)
    [ (Say.Lang_en, "@none"); (Say.Lang_ko, "@미선택") ];

  (* 2. Settings Dry_run_idle with dirty field shows single footer diff, NOT duplicate diff block *)
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let m_settings_idle =
    let cfg =
      { base.config with dry_run_preview = Config_store.Dry_run_idle }
      |> Config_store.set_tab Nav.Settings_keepers_companies
    in
    {
      base with
      nav =
        {
          base.nav with
          overlay = Some (Nav.Settings Nav.Settings_keepers_companies);
        };
      config = cfg;
    }
  in
  let g_set, _ = render_full ~model:m_settings_idle ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"settings_idle_no_dup_diff" g_set;
  let txt_set = grid_all_text g_set in
  assert_contains ~label:"settings_idle_single_change_footer"
    ~needle:"120 -> 180" txt_set;
  assert_not_contains ~label:"settings_idle_no_second_diff_hdr"
    ~needle:"Dry-run TOML Diff" txt_set;

  (* 3. Micro Cockpit & Micro_viewport show actual grid dims, not stale model.viewport *)
  let g_micro_mismatch, _ = render_full ~model:base ~cols:60 ~rows:18 in
  let txt_mm = grid_all_text g_micro_mismatch in
  assert_contains ~label:"micro_cockpit_actual_dims" ~needle:"60x18" txt_mm;
  assert_not_contains ~label:"micro_cockpit_no_stale_dims" ~needle:"140x40" txt_mm;

  let m_gate =
    {
      base with
      nav = { base.nav with overlay = Some (Nav.System_gate Nav.Micro_viewport) };
    }
  in
  let g_gate, _ = render_full ~model:m_gate ~cols:60 ~rows:18 in
  let txt_gate = grid_all_text g_gate in
  assert_contains ~label:"micro_gate_actual_dims" ~needle:"60x18" txt_gate;
  assert_not_contains ~label:"micro_gate_no_stale_dims" ~needle:"140x40" txt_gate

let test_round1_local_clock_pills_and_compact_fit () =
  (* P1-6: Pure local HH:MM clock via model.tz_offset_sec (+09:00 KST) *)
  let utc_21_06 = 1763759160.0 in
  Alcotest.(check (option string)) "UTC 21:06" (Some "21:06")
    (Render_util.format_hhmm_utc utc_21_06);
  Alcotest.(check (option string)) "KST +09:00 -> 06:06" (Some "06:06")
    (Render_util.format_hhmm_with_offset ~tz_offset_sec:32400 utc_21_06);
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  let m_kst =
    {
      base with
      tz_offset_sec = 32400;
      freshness = { base.freshness with last_wall_unix = utc_21_06 };
    }
  in
  let g_kst, _ = render_full ~model:m_kst ~cols:140 ~rows:40 in
  let rail_kst = grid_row_text g_kst 0 in
  assert_contains ~label:"local_clock_kst" ~needle:"06:06" rail_kst;
  assert_not_contains ~label:"local_clock_not_utc" ~needle:"21:06" rail_kst;

  (* P2-1 + P2-2: Symmetric sub-tab pill + Compact 90x28 Work & Settings fit *)
  let m_work_90 =
    {
      base with
      viewport = { cols = 90; rows = 28 };
      breakpoint = Model.Compact;
      nav = { base.nav with workspace = Nav.Work };
    }
  in
  let g_w90, _ = render_full ~model:m_work_90 ~cols:90 ~rows:28 in
  assert_clean_grid ~label:"work_90x28_ko" g_w90;
  let sub_w90 = grid_row_text g_w90 1 in
  assert_contains ~label:"work_90_symmetric_pill" ~needle:" 목표 " sub_w90;
  assert_contains ~label:"work_90_candle_not_clipped" ~needle:"캔들·성과" sub_w90;
  assert_contains ~label:"work_90_compact_hint" ~needle:"[[ ]]" sub_w90;
  assert_not_contains ~label:"work_90_no_long_hint" ~needle:"탭 전환" sub_w90;

  let m_set_90 =
    {
      m_work_90 with
      nav = { m_work_90.nav with overlay = Some (Nav.Settings Nav.Settings_general_ui) };
    }
  in
  let g_s90, _ = render_full ~model:m_set_90 ~cols:90 ~rows:28 in
  assert_clean_grid ~label:"settings_90x28_ko" g_s90;
  let set_txt = grid_all_text g_s90 in
  assert_contains ~label:"settings_90_esc_close_unclipped" ~needle:"[Esc] 닫기" set_txt

let test_round2_palette_and_settings_regressions () =
  (* R2-P1-6 + R2-P2-6: KO empty-query Palette keeps wide '검' intact (no cursor clobber)
     and omits 'KO 동기화' / 'EN synced' jargon. *)
  let base_ko = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  let m_pal_ko =
    {
      base_ko with
      nav = { base_ko.nav with overlay = Some Nav.Palette };
      palette = { mode = Model.Palette_commands; query = ""; selected = 0 };
    }
  in
  let g_pal_ko, _ = render_full ~model:m_pal_ko ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"r2_palette_ko_empty" g_pal_ko;
  let txt_ko = grid_all_text g_pal_ko in
  assert_contains ~label:"r2_palette_ko_keeps_wide_geom" ~needle:"검색어 입력"
    txt_ko;
  assert_not_contains ~label:"r2_palette_no_ko_sync_jargon" ~needle:"KO 동기화"
    txt_ko;
  let base_en = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let m_pal_en =
    {
      base_en with
      nav = { base_en.nav with overlay = Some Nav.Palette };
      palette = { mode = Model.Palette_commands; query = ""; selected = 0 };
    }
  in
  let g_pal_en, _ = render_full ~model:m_pal_en ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"r2_palette_en_empty" g_pal_en;
  assert_not_contains ~label:"r2_palette_no_en_sync_jargon" ~needle:"EN synced"
    (grid_all_text g_pal_en);

  (* R2-P1-1: Settings modal at 140x40 spans full overlay width (cols 0..139) with
     zero bleed from underlying Pulse borders/brackets. *)
  let m_set_140 =
    {
      base_ko with
      nav =
        {
          base_ko.nav with
          overlay = Some (Nav.Settings Nav.Settings_general_ui);
        };
    }
  in
  let g_set, _ = render_full ~model:m_set_140 ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"r2_settings_140_full_width" g_set;
  let cell_glyph_str (grid : Cell_grid.t) ~x ~y =
    match (Cell_grid.get grid ~x ~y).glyph with
    | Cell_grid.Empty -> " "
    | Cell_grid.Ascii ch -> String.make 1 ch
    | Cell_grid.Utf8 s -> s
    | Cell_grid.Braille m -> Cell_grid.braille_utf8 m
    | Cell_grid.Continuation -> ""
  in
  Alcotest.(check string) "settings overlay top-left at col 0 is box corner" "┏"
    (cell_glyph_str g_set ~x:0 ~y:1);
  Alcotest.(check string) "settings overlay top-right at col 139 is box corner"
    "┓" (cell_glyph_str g_set ~x:139 ~y:1);
  for y = 2 to 37 do
    let left_ch = cell_glyph_str g_set ~x:0 ~y in
    let right_ch = cell_glyph_str g_set ~x:139 ~y in
    Alcotest.(check bool)
      (Printf.sprintf "no bleed at col 0 row %d (got %S)" y left_ch) true
      (String.equal left_ch "│" || String.equal left_ch "┃"
       || String.equal left_ch "╰" || String.equal left_ch "┗"
       || String.equal left_ch "├");
    Alcotest.(check bool)
      (Printf.sprintf "no bleed at col 139 row %d (got %S)" y right_ch) true
      (String.equal right_ch "│" || String.equal right_ch "┃"
       || String.equal right_ch "╯" || String.equal right_ch "┛"
       || String.equal right_ch "┤")
  done

let test_v25_chrome_margins_and_keycaps () =
  let base_wide = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  let l_wide = Chrome.compute_layout ~model:base_wide ~cols:140 ~rows:40 in
  Alcotest.(check bool) "Wide auto-docks left sidebar" true
    (Option.is_some l_wide.sidebar && not l_wide.sidebar_is_drawer);
  Alcotest.(check int) "Wide body x after docked sidebar = 26" 26 l_wide.body.x;
  Alcotest.(check int) "Wide body w after docked sidebar = 113" 113 l_wide.body.w;
  let base_wide_collapsed =
    { base_wide with nav = { base_wide.nav with sidebar_open = Some false } }
  in
  let l_wide_c =
    Chrome.compute_layout ~model:base_wide_collapsed ~cols:140 ~rows:40
  in
  Alcotest.(check int) "Wide collapsed sidebar body inset x = 1" 1
    l_wide_c.body.x;
  Alcotest.(check int) "Wide collapsed sidebar body inset w = 138" 138
    l_wide_c.body.w;

  let base_std = populated_model ~cols:110 ~rows:32 ~lang:Say.Lang_en in
  let l_std = Chrome.compute_layout ~model:base_std ~cols:110 ~rows:32 in
  Alcotest.(check int) "Standard body inset x = 1" 1 l_std.body.x;
  Alcotest.(check int) "Standard body inset w = 108" 108 l_std.body.w;

  let base_cmp = populated_model ~cols:90 ~rows:28 ~lang:Say.Lang_ko in
  let l_cmp = Chrome.compute_layout ~model:base_cmp ~cols:90 ~rows:28 in
  Alcotest.(check int) "Compact body inset x = 0" 0 l_cmp.body.x;
  Alcotest.(check int) "Compact body inset w = 90" 90 l_cmp.body.w;

  (* Top Nav uses elevated surface_2 + Left_rail (▎), ZERO selection_bg cobalt block *)
  let g_wide, _ = render_full ~model:base_wide ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"v25_chrome_wide" g_wide;
  let theme = Theme.of_preset base_wide.theme_preset in
  let top_row = grid_row_text g_wide 0 in
  assert_contains ~label:"v25_top_rail_left_rail"
    ~needle:(Glyph.to_utf8 Glyph.Left_rail) top_row;
  assert_contains ~label:"v25_top_rail_brand" ~needle:"MASC" top_row;
  for x = 0 to 139 do
    let c = Cell_grid.get g_wide ~x ~y:0 in
    Alcotest.(check bool)
      (Printf.sprintf "row 0 col %d never uses selection_bg" x)
      false
      (Color.equal c.style.bg (Color.of_rgb theme.selection_bg))
  done;
  (* Quiet Footer: surface_2 keycaps + italic whisper right status hint, zero middle-dot spam *)
  let footer_y = 39 in
  let keycap_bg = Color.of_rgb theme.surface_2 in
  let keycap_runs = ref 0 in
  let in_cap = ref false in
  let has_italic_hint = ref false in
  for x = 0 to 139 do
    let c = Cell_grid.get g_wide ~x ~y:footer_y in
    let is_cap = Color.equal c.style.bg keycap_bg in
    if is_cap && not !in_cap then incr keycap_runs;
    in_cap := is_cap;
    if Attr.has c.style.attrs Attr.italic then has_italic_hint := true
  done;
  Alcotest.(check bool) "footer has elevated keycaps (1..14)" true
    (!keycap_runs >= 1 && !keycap_runs <= 14);
  Alcotest.(check bool) "footer has Tier-4 italic status hint on Wide" true
    !has_italic_hint;
  (* P3: Top-rail HH:MM clock uses Tier-4 italic Typography.whisper *)
  let has_italic_clock = ref false in
  for x = 120 to 139 do
    let c = Cell_grid.get g_wide ~x ~y:0 in
    if Attr.has c.style.attrs Attr.italic then has_italic_clock := true
  done;
  Alcotest.(check bool) "top-rail clock is Tier-4 italic whisper" true
    !has_italic_clock

let test_v25_pulse_4kpi_hero_and_5_companies () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  (* Build a 5-group fleet with explicit keeper.group metadata (company="") to verify neutral grouping + costs *)
  let mk_grouped ~group ~name ~health ~turns =
    {
      (mk_keeper ~name ~company:"" ~health ~turns ()) with
      group = Some group;
      company = "";
    }
  in
  let five_co_keepers =
    [
      mk_grouped ~group:"MASC Core" ~name:"e-masc-the-leader" ~health:Wire_fleet.Keeper_working ~turns:420;
      mk_grouped ~group:"Code Review" ~name:"code-reviewer-son" ~health:Wire_fleet.Keeper_healthy ~turns:310;
      mk_grouped ~group:"WKBL Startup" ~name:"wkbl-growth" ~health:Wire_fleet.Keeper_working ~turns:240;
      mk_grouped ~group:"KidsNote Ops" ~name:"kidsnote-ops" ~health:Wire_fleet.Keeper_healthy ~turns:115;
      mk_grouped ~group:"Creative & R&D" ~name:"music-sensei" ~health:Wire_fleet.Keeper_healthy ~turns:90;
    ]
  in
  let mk_cost ~name ~usd ~samples ~tokens : Wire_runtime.keeper_cost_row =
    {
      keeper_name = name;
      sample_count = samples;
      total_tokens = obs tokens;
      total_cost_usd = obs usd;
      tokens_reported_samples = samples;
      tokens_missing_samples = 0;
      cost_reported_samples = samples;
      cost_missing_samples = 0;
    }
  in
  let keeper_costs : Wire_runtime.keeper_costs_window =
    {
      generated_at_unix = 1763701200.0;
      window_minutes = 1440;
      rows =
        [
          mk_cost ~name:"e-masc-the-leader" ~usd:3.42 ~samples:420 ~tokens:200_000;
          mk_cost ~name:"code-reviewer-son" ~usd:2.15 ~samples:310 ~tokens:150_000;
          mk_cost ~name:"wkbl-growth" ~usd:1.30 ~samples:240 ~tokens:90_000;
          mk_cost ~name:"kidsnote-ops" ~usd:0.60 ~samples:115 ~tokens:40_000;
          mk_cost ~name:"music-sensei" ~usd:0.40 ~samples:90 ~tokens:25_000;
        ];
    }
  in
  let fleet =
    base.fleet
    |> Fleet_store.apply_keepers ~observed_at:Clock.Mono.zero five_co_keepers
    |> Fleet_store.select_keeper "wkbl-growth"
  in
  let runtime =
    base.runtime
    |> Runtime_store.apply_keeper_costs ~observed_at:Clock.Mono.zero keeper_costs
  in
  let m = { base with fleet; runtime } in
  let g, _ = render_full ~model:m ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"v25_pulse_5co_wide" g;
  let txt = grid_all_text g in
  (* All 5 real companies present, 0 ungrouped *)
  List.iter
    (fun co -> assert_contains ~label:"v25_pulse_company" ~needle:co txt)
    [ "MASC Core"; "Code Review"; "WKBL Startup"; "KidsNote Ops"; "Creative & R&D" ];
  assert_not_contains ~label:"v25_pulse_no_ungrouped" ~needle:"ungrouped" txt;
  (* 4-KPI Hero Band metrics: infra mix, cache %, spend, claims, Violet Candle spark *)
  assert_contains ~label:"v25_pulse_infra_mix" ~needle:"19vm · 13ssh" txt;
  assert_contains ~label:"v25_pulse_cache_pct" ~needle:"95.7%" txt;
  assert_contains ~label:"v25_pulse_spend" ~needle:"$7.87" txt;
  assert_contains ~label:"v25_pulse_candle_spark"
    ~needle:(Glyph.to_utf8 Glyph.Ai_spark) txt;
  assert_contains ~label:"v25_pulse_company_spend" ~needle:"$3.42" txt;
  (* Hero Band uses vertical hairlines (│), NOT nested card corners (╭) on row 2 *)
  let hero_row0 = grid_row_text g 2 in
  assert_contains ~label:"v25_pulse_hero_v_hairline" ~needle:"│" hero_row0;
  assert_not_contains ~label:"v25_pulse_hero_no_nested_box" ~needle:"╭" hero_row0;
  (* P3: Companies header shows distinct '성과' column instead of duplicate '24h' *)
  assert_contains ~label:"v25_pulse_company_output_hdr" ~needle:"성과" txt;
  (* P2 #2: Selected keeper 'wkbl-growth' (company="") syncs selection to WKBL Startup row via g.keepers membership when Companies pane is focused *)
  let g_co, _ =
    render_full
      ~model:{ m with nav = { m.nav with pane_index = 1 } }
      ~cols:140 ~rows:40
  in
  let theme = Theme.of_preset m.theme_preset in
  let sel_bg = Color.of_rgb theme.selection_bg in
  let wkbl_selected = ref false in
  let masc_selected = ref false in
  for y = 6 to 28 do
    let row_txt = grid_row_text g_co y in
    let has_sel_bg =
      let found = ref false in
      for x = 2 to 60 do
        if Color.equal (Cell_grid.get g_co ~x ~y).style.bg sel_bg then
          found := true
      done;
      !found
    in
    if has_sel_bg && has_substring ~needle:"WKBL Startup" row_txt then
      wkbl_selected := true;
    if has_sel_bg && has_substring ~needle:"MASC Core" row_txt then
      masc_selected := true
  done;
  Alcotest.(check bool)
    "WKBL Startup row highlighted via g.keepers membership" true !wkbl_selected;
  Alcotest.(check bool) "MASC Core row NOT wrongly highlighted at index 0" false
    !masc_selected;
  (* P2 #3: Compact 90x28 keeps ALL 5 Autonomous Companies visible *)
  let g_cmp, _ = render_full ~model:m ~cols:90 ~rows:28 in
  assert_clean_grid ~label:"v25_pulse_5co_compact" g_cmp;
  let txt_cmp = grid_all_text g_cmp in
  List.iter
    (fun co ->
      assert_contains ~label:"v25_pulse_5co_compact_all5" ~needle:co txt_cmp)
    [ "MASC Core"; "Code Review"; "WKBL Startup"; "KidsNote Ops"; "Creative & R&D" ];
  (* P3: Degenerate tiny Pulse rect (w=2, h=4) renders safely without OOB *)
  let tiny_g = Cell_grid.create ~cols:2 ~rows:4 in
  let tiny_cache = Card.Cache.create () in
  Screen_pulse.render ~model:m ~cache:tiny_cache
    ~rect:(Rect.make ~x:0 ~y:0 ~w:2 ~h:4)
    tiny_g

let test_v25_pulse_honest_observed_and_no_fabricated_zeros () =
  (* P1 #1: Unloaded/unreported Pulse NEVER fabricates 0.00 C, 0.0%, $0.00, 0 calls, or PR 0 *)
  List.iter
    (fun lang ->
      let m_empty = Model.initial ~cols:140 ~rows:40 ~lang () in
      let g_e, _ = render_full ~model:m_empty ~cols:140 ~rows:40 in
      assert_clean_grid ~label:"v25_pulse_honest_empty" g_e;
      let txt_e = grid_all_text g_e in
      List.iter
        (fun fake ->
          assert_not_contains ~label:"v25_pulse_no_fabricated_zero" ~needle:fake
            txt_e)
        [ "0.00 C"; "0.0%"; "$0.00"; "0 calls"; "PR 0" ];
      (* All-time tasks_done_total fallback is labeled '누적 N'/'Total N' and unreported PR uses live turns_24h *)
      let base = populated_model ~cols:140 ~rows:40 ~lang in
      let fleet_honest =
        match Observed.to_option base.fleet.shell with
        | None -> base.fleet
        | Some sh ->
            let sc : Wire_fleet.daily_scorecard =
              {
                sh.scorecard_24h with
                tasks_done_24h = Observed.unreported;
                tasks_done_total = obs 730;
                turns_24h = obs 1450;
                cost_24h_usd = Observed.unreported;
              }
            in
            Fleet_store.apply_shell ~observed_at:Clock.Mono.zero
              { sh with scorecard_24h = sc }
              base.fleet
      in
      let m_honest =
        {
          base with
          fleet = fleet_honest;
          runtime =
            {
              base.runtime with
              usage_windows = Observed.unreported;
              usage_history = Observed.unreported;
              efficiency = Observed.unreported;
              models_metrics = Observed.unreported;
              runtime_metrics = Observed.unreported;
              keeper_costs = Observed.unreported;
              tool_series = Observed.unreported;
              runtime_probe = Observed.unreported;
            };
          infra = { base.infra with sandboxes = Observed.unreported };
          work = { base.work with candle_ledger = Observed.unreported };
        }
      in
      let g_h, _ = render_full ~model:m_honest ~cols:140 ~rows:40 in
      assert_clean_grid ~label:"v25_pulse_honest_fallback" g_h;
      let txt_h = grid_all_text g_h in
      let tot_needle =
        match lang with Say.Lang_ko -> "누적 730" | Say.Lang_en -> "Total 730"
      in
      let turns_needle =
        match lang with Say.Lang_ko -> "턴 1.4k" | Say.Lang_en -> "Turns 1.4k"
      in
      assert_contains ~label:"v25_pulse_total_fallback_labeled" ~needle:tot_needle
        txt_h;
      assert_contains ~label:"v25_pulse_live_turns_replaces_pr0"
        ~needle:turns_needle txt_h;
      List.iter
        (fun fake ->
          assert_not_contains ~label:"v25_pulse_honest_no_fake" ~needle:fake
            txt_h)
        [ "PR 0"; "0.0%"; "$0.00"; "0.00 C"; "0 calls" ])
    [ Say.Lang_ko; Say.Lang_en ]

let test_v25_settings_2pane_tree_inspector () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  let mk_f ~table ~key ~label ~kind ~value ?(prov = Wire_config.Prov_global)
      ?(rel = Wire_config.Restart_required) ?(secret = false) ?(writable = true)
      ?env ?desc () : Wire_config.schema_field =
    {
      table;
      key;
      full_key = table ^ "." ^ key;
      label;
      env;
      description = desc;
      kind;
      value;
      default_value = None;
      provenance = prov;
      reload_scope = rel;
      secret;
      writable;
    }
  in
  let multi_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha256-v25";
      sections =
        [
          {
            id = "providers";
            category = Wire_config.Cat_providers_models;
            title = "Providers & Models";
            fields =
              [
                mk_f ~table:"providers.claude_alpha" ~key:"display_name"
                  ~label:"providers.claude_alpha.display_name"
                  ~kind:Wire_config.Field_string
                  ~value:(Wire_config.Val_string "Claude Code (alpha)")
                  ~desc:"Human-friendly provider title" ();
                mk_f ~table:"providers.claude_alpha" ~key:"endpoint_url"
                  ~label:"providers.claude_alpha.endpoint_url"
                  ~kind:Wire_config.Field_string
                  ~value:(Wire_config.Val_string "https://api.anthropic.com")
                  ~desc:"Anthropic Messages API endpoint" ();
                mk_f ~table:"providers.claude_alpha.credentials" ~key:"api_key"
                  ~label:"providers.claude_alpha.credentials.api_key"
                  ~kind:Wire_config.Field_secret
                  ~value:
                    (Wire_config.Val_secret
                       {
                         configured = true;
                         source = Wire_config.Secret_inline_redacted;
                       })
                  ~prov:Wire_config.Prov_env_override ~env:"ANTHROPIC_API_KEY"
                  ~secret:true ~writable:false ();
                mk_f ~table:"providers.claude_alpha.headers"
                  ~key:"anthropic-version"
                  ~label:"providers.claude_alpha.headers.anthropic-version"
                  ~kind:Wire_config.Field_string
                  ~value:(Wire_config.Val_string "2023-06-01") ();
                mk_f ~table:"providers.openrouter" ~key:"display_name"
                  ~label:"providers.openrouter.display_name"
                  ~kind:Wire_config.Field_string
                  ~value:(Wire_config.Val_string "OpenRouter") ();
                mk_f ~table:"models.\"gpt-5.6\"" ~key:"context_window"
                  ~label:"models.gpt-5.6.context_window"
                  ~kind:(Wire_config.Field_int { min = Some 1024; max = None })
                  ~value:(Wire_config.Val_int 200000) ();
                mk_f ~table:"models.\"gpt-5.5\"" ~key:"context_window"
                  ~label:"models.gpt-5.5.context_window"
                  ~kind:(Wire_config.Field_int { min = Some 1024; max = None })
                  ~value:(Wire_config.Val_int 128000) ();
              ];
          };
        ];
    }
  in
  let cfg0 =
    Config_store.empty
    |> Config_store.set_tab Nav.Settings_providers_models
    |> Config_store.apply_schema ~observed_at:Clock.Mono.zero multi_schema
  in
  let m_set =
    {
      base with
      nav =
        {
          base.nav with
          overlay = Some (Nav.Settings Nav.Settings_providers_models);
        };
      config = cfg0;
    }
  in
  let g_wide, _ = render_full ~model:m_set ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"v25_settings_2pane_wide" g_wide;
  let txt = grid_all_text g_wide in
  (* Left Tree shows human entity titles & collapsed Models Catalog (2개) *)
  assert_contains ~label:"v25_settings_tree_provider" ~needle:"Claude Code (alpha)" txt;
  assert_contains ~label:"v25_settings_tree_openrouter" ~needle:"OpenRouter" txt;
  assert_contains ~label:"v25_settings_tree_catalog" ~needle:"모델 카탈로그 (2개)" txt;
  (* Right Property Inspector shows clean KO leaf labels & sub-group dividers, ZERO raw dot-path labels *)
  assert_contains ~label:"v25_settings_leaf_endpoint" ~needle:"엔드포인트" txt;
  assert_contains ~label:"v25_settings_section_header" ~needle:"출처: 전역 TOML" txt;
  assert_contains ~label:"v25_settings_subgroup_creds" ~needle:"인증" txt;
  assert_contains ~label:"v25_settings_subgroup_headers" ~needle:"헤더" txt;
  (* Single provenance header — NOT repeated per-row "[전역 TOML] △ 재시작 필요" wall *)
  assert_not_contains ~label:"v25_settings_no_repeated_row_badge"
    ~needle:"[전역 TOML]" txt;
  (* Global / search across sections surfaces matching model catalog item *)
  let cfg_search = Config_store.set_search_query "gpt-5.6" cfg0 in
  let m_search = { m_set with config = cfg_search } in
  let g_search, _ = render_full ~model:m_search ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"v25_settings_search" g_search;
  assert_contains ~label:"v25_settings_search_hit" ~needle:"gpt-5.6"
    (grid_all_text g_search);
  (* Compact 90x28 2-pane fits cleanly without clipping *)
  let g_cmp, _ = render_full ~model:m_set ~cols:90 ~rows:28 in
  assert_clean_grid ~label:"v25_settings_2pane_compact" g_cmp

let test_v25_settings_grouped_scroll_1subgroup_and_single_highlight () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  let mk_f ~table ~key ~kind ~value ?(prov = Wire_config.Prov_global)
      ?(rel = Wire_config.Hot_reload) () : Wire_config.schema_field =
    {
      table;
      key;
      full_key = table ^ "." ^ key;
      label = table ^ "." ^ key;
      env = None;
      description = Some ("desc " ^ key);
      kind;
      value;
      default_value = None;
      provenance = prov;
      reload_scope = rel;
      secret = false;
      writable = true;
    }
  in
  (* Model card with base fields (None) + 1 named subgroup (capabilities) + multiple int fields for error-scroll test *)
  let schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha256-v25-grp";
      sections =
        [
          {
            id = "providers";
            category = Wire_config.Cat_providers_models;
            title = "Providers & Models";
            fields =
              [
                mk_f ~table:"providers.alpha" ~key:"display_name"
                  ~kind:Wire_config.Field_string
                  ~value:(Wire_config.Val_string "Alpha Provider") ();
                mk_f ~table:"providers.alpha" ~key:"timeout_sec"
                  ~kind:(Wire_config.Field_int { min = Some 10; max = Some 300 })
                  ~value:(Wire_config.Val_int 60) ();
                mk_f ~table:"providers.alpha" ~key:"max_retries"
                  ~kind:(Wire_config.Field_int { min = Some 1; max = Some 10 })
                  ~value:(Wire_config.Val_int 3) ();
                mk_f ~table:"providers.alpha" ~key:"concurrency"
                  ~kind:(Wire_config.Field_int { min = Some 1; max = Some 64 })
                  ~value:(Wire_config.Val_int 8) ();
                mk_f ~table:"providers.alpha" ~key:"rate_limit"
                  ~kind:(Wire_config.Field_int { min = Some 1; max = Some 1000 })
                  ~value:(Wire_config.Val_int 100) ();
                mk_f ~table:"providers.alpha.capabilities" ~key:"max_images"
                  ~kind:(Wire_config.Field_int { min = Some 1; max = Some 20 })
                  ~value:(Wire_config.Val_int 4) ();
                mk_f ~table:"providers.alpha.capabilities" ~key:"vision_sentinel"
                  ~kind:Wire_config.Field_string
                  ~value:(Wire_config.Val_string "FOCUSED_TARGET_OK") ();
                mk_f ~table:"models.\"gpt-5.6\"" ~key:"context_window"
                  ~kind:(Wire_config.Field_int { min = Some 1024; max = None })
                  ~value:(Wire_config.Val_int 200000) ();
              ];
          };
        ];
    }
  in
  let cfg0 =
    Config_store.empty
    |> Config_store.set_tab Nav.Settings_providers_models
    |> Config_store.apply_schema ~observed_at:Clock.Mono.zero schema
  in
  (* P2 #4a: 1 named subgroup alongside base fields triggers Card.draw_hairline subgroup divider ('기능') *)
  let m_1sub =
    {
      base with
      nav =
        {
          base.nav with
          overlay = Some (Nav.Settings Nav.Settings_providers_models);
        };
      config = cfg0;
    }
  in
  let g_1sub, _ = render_full ~model:m_1sub ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"v25_settings_1subgroup" g_1sub;
  assert_contains ~label:"v25_settings_1subgroup_divider" ~needle:"기능"
    (grid_all_text g_1sub);

  (* P2 #4b: Height-aware scroll keeps focused last field visible even when 5 earlier fields have 2-row validation errors *)
  let cfg_err =
    cfg0
    |> Config_store.stage_patch ~full_key:"providers.alpha.timeout_sec"
         (Wire_config.Set_int
            { table = "providers.alpha"; key = "timeout_sec"; value = -1 })
    |> Config_store.stage_patch ~full_key:"providers.alpha.max_retries"
         (Wire_config.Set_int
            { table = "providers.alpha"; key = "max_retries"; value = -1 })
    |> Config_store.stage_patch ~full_key:"providers.alpha.concurrency"
         (Wire_config.Set_int
            { table = "providers.alpha"; key = "concurrency"; value = -1 })
    |> Config_store.stage_patch ~full_key:"providers.alpha.rate_limit"
         (Wire_config.Set_int
            { table = "providers.alpha"; key = "rate_limit"; value = -1 })
    |> Config_store.stage_patch ~full_key:"providers.alpha.capabilities.max_images"
         (Wire_config.Set_int
            {
              table = "providers.alpha.capabilities";
              key = "max_images";
              value = -1;
            })
    |> fun c ->
    {
      c with
      settings_pane = Config_store.Pane_inspector;
      selected_field_index = 6;
    }
  in
  let m_err = { m_1sub with config = cfg_err } in
  let g_err, _ = render_full ~model:m_err ~cols:90 ~rows:28 in
  assert_clean_grid ~label:"v25_settings_err_scroll_90x28" g_err;
  assert_contains ~label:"v25_settings_err_scroll_focused_visible"
    ~needle:"FOCUSED_TARGET_OK" (grid_all_text g_err);

  (* P2 #5: Left Tree NEVER double-highlights 2 rows when Inspector is focused,
     even if selected_section_idx rests on Tree_category or Tree_models_catalog_toggle *)
  let rows_vis = Config_store.visible_tree_rows cfg0 in
  let find_row_idx pred =
    let rec loop i = function
      | [] -> None
      | r :: rest -> if pred r then Some i else loop (i + 1) rest
    in
    loop 0 rows_vis
  in
  let cat_idx =
    find_row_idx (function
      | Config_store.Tree_category _ -> true
      | Config_store.Tree_models_catalog_toggle _ | Config_store.Tree_section _
        ->
          false)
  in
  let toggle_idx =
    find_row_idx (function
      | Config_store.Tree_models_catalog_toggle _ -> true
      | Config_store.Tree_category _ | Config_store.Tree_section _ -> false)
  in
  let theme = Theme.of_preset base.theme_preset in
  let sel_bg = Color.of_rgb theme.selection_bg in
  let muted_sel_bg = Color.of_rgb theme.surface_2 in
  let assert_single_tree_highlight ~label tree_idx =
    let cfg_insp =
      {
        cfg0 with
        settings_pane = Config_store.Pane_inspector;
        selected_section_idx = tree_idx;
      }
    in
    let m_insp = { m_1sub with config = cfg_insp } in
    let g_insp, _ = render_full ~model:m_insp ~cols:140 ~rows:40 in
    assert_clean_grid ~label g_insp;
    let bright_rows = ref [] in
    let muted_rows = ref [] in
    (* Left tree sits in cols 1..32, rows 4..37: when unfocused (Pane_inspector),
       active section row uses muted surface_2, never competing selection_bg. *)
    for y = 4 to 37 do
      let bg = (Cell_grid.get g_insp ~x:2 ~y).style.bg in
      if Color.equal bg sel_bg then bright_rows := y :: !bright_rows;
      if Color.equal bg muted_sel_bg then muted_rows := y :: !muted_rows
    done;
    Alcotest.(check int)
      (label ^ ": 0 active-focus selection_bg rows in unfocused Left Tree")
      0 (List.length !bright_rows);
    Alcotest.(check int)
      (label ^ ": exactly 1 muted active-section row in unfocused Left Tree")
      1 (List.length !muted_rows)
  in
  (match cat_idx with
   | Some i -> assert_single_tree_highlight ~label:"tree_cat_pane_insp" i
   | None -> Alcotest.fail "expected Tree_category row");
  (match toggle_idx with
   | Some i -> assert_single_tree_highlight ~label:"tree_toggle_pane_insp" i
   | None -> Alcotest.fail "expected Tree_models_catalog_toggle row")

let test_v25_round55_attention_bar_5companies_fail_and_settings_polish () =
  (* 1. [P1] Persistent Attention Bar: ZERO text collision or bleed between
     [Y] 승인 / [N] 거절 / [J] 상세 at BOTH 140x40 and 90x28 (KO & EN),
     even when a Goal_confirmation has a 110+ char title (keeper = None) or a
     Held_tool_approval has an extra-long summary. *)
  let long_goal_title =
    "MASC Core Overhaul (Clockwork / ACP / Living Memory / Runtime Failover / MCP Streamable HTTP Transport)"
  in
  let long_goal : Wire_work.goal =
    {
      id = "goal-long";
      title = long_goal_title;
      phase = Wire_work.Awaiting_confirmation;
      priority = 1;
      due_date = None;
      measure = "All 3 stacks merged cleanly with zero regressions across 140x40 and 90x28";
      procedure = "Visual Retina verification";
      criterion_revision = Some "rev-9";
      criterion_verdict = Wire_work.Criterion_valid;
      last_review_note = None;
      last_review_at = None;
      created_at = None;
      updated_at = None;
      linked_task_count = obs 4;
    }
  in
  let long_approval : Wire_work.held_tool_approval =
    {
      approval_id = "appr-long";
      tool_call_id = "tc-long";
      keeper = "e-masc-the-leader";
      tool = "masc_shell";
      args_preview = "dune build && dune runtest";
      question =
        "Allow executing long cross-repo verification pipeline for Living Memory and Runtime Failover MCP checks?";
      because = None;
      asked_at = 1763701100.0;
      timeout_sec = 300.0;
    }
  in
  List.iter
    (fun (lang, expected_goal_actions, expected_tool_actions) ->
      List.iter
        (fun (cols, rows) ->
          let base = populated_model ~cols ~rows ~lang in
          (* Case A: Goal_confirmation with keeper = None and huge title *)
          let attn_goal =
            Attention.rebuild ~asks:[] ~tool_approvals:[] ~gate_pending:[]
              ~goals:[ long_goal ] Attention.empty
          in
          let m_goal = { base with attention = attn_goal } in
          let layout_g = Chrome.compute_layout ~model:m_goal ~cols ~rows in
          let strip_y_g =
            match layout_g.approval_strip with
            | Some r -> r.y
            | None -> Alcotest.fail "expected approval_strip rect for goal"
          in
          let g_goal, _ = render_full ~model:m_goal ~cols ~rows in
          assert_clean_grid
            ~label:(Printf.sprintf "r55_attn_goal_%dx%d" cols rows)
            g_goal;
          let row_g = grid_row_text g_goal strip_y_g in
          assert_contains
            ~label:(Printf.sprintf "r55_attn_goal_clean_actions_%dx%d" cols rows)
            ~needle:expected_goal_actions row_g;
          Alcotest.(check bool)
            (Printf.sprintf "r55_attn_goal_ends_with_clean_actions_%dx%d: %S"
               cols rows row_g)
            true
            (String.ends_with ~suffix:expected_goal_actions row_g);
          assert_contains
            ~label:(Printf.sprintf "r55_attn_goal_ellipsis_%dx%d" cols rows)
            ~needle:"…" row_g;
          (* Case B: Held_tool_approval with long summary *)
          let attn_tool =
            Attention.rebuild ~asks:[] ~tool_approvals:[ long_approval ]
              ~gate_pending:[] ~goals:[] Attention.empty
          in
          let m_tool = { base with attention = attn_tool } in
          let layout_t = Chrome.compute_layout ~model:m_tool ~cols ~rows in
          let strip_y_t =
            match layout_t.approval_strip with
            | Some r -> r.y
            | None -> Alcotest.fail "expected approval_strip rect for tool"
          in
          let g_tool, _ = render_full ~model:m_tool ~cols ~rows in
          assert_clean_grid
            ~label:(Printf.sprintf "r55_attn_tool_%dx%d" cols rows)
            g_tool;
          let row_t = grid_row_text g_tool strip_y_t in
          Alcotest.(check bool)
            (Printf.sprintf "r55_attn_tool_ends_with_clean_actions_%dx%d: %S"
               cols rows row_t)
            true
            (String.ends_with ~suffix:expected_tool_actions row_t))
        [ (140, 40); (90, 28) ])
    [
      ( Say.Lang_ko
      , "  [Y/Enter] 확인  [N] 보류·중단  [J] 상세 "
      , "  [Y] 승인  [N] 거절  [J] 상세 " );
      ( Say.Lang_en
      , "  [Y/Enter] Confirm  [N] Hold/Drop  [J] Dive "
      , "  [Y] Allow  [N] Deny  [J] Dive " );
    ];

  (* 2. [P2] All 5 Autonomous Companies including Creative & R&D stay visible
     simultaneously on Pulse at BOTH 140x40 and 90x28 even when the live fault
     banner ("× 실시간 오류:") is shown — covering BOTH Keeper_failing AND
     Keeper_offline / Keeper_degraded live faults. *)
  let five_companies =
    [ "MASC Core"; "Code Review"; "WKBL Startup"; "KidsNote Ops"; "Creative & R&D" ]
  in
  let mk_grouped ~group ~name ~health ~turns =
    {
      (mk_keeper ~name ~company:"" ~health ~turns ()) with
      group = Some group;
      company = "";
    }
  in
  List.iter
    (fun (fault_label, fault_health) ->
      let keepers =
        [
          mk_grouped ~group:"MASC Core" ~name:"e-masc-the-leader" ~health:Wire_fleet.Keeper_working ~turns:420;
          mk_grouped ~group:"Code Review" ~name:"code-reviewer-son" ~health:Wire_fleet.Keeper_healthy ~turns:310;
          mk_grouped ~group:"WKBL Startup" ~name:"wkbl-growth" ~health:fault_health ~turns:240;
          mk_grouped ~group:"KidsNote Ops" ~name:"kidsnote-ops" ~health:Wire_fleet.Keeper_healthy ~turns:115;
          mk_grouped ~group:"Creative & R&D" ~name:"music-sensei" ~health:Wire_fleet.Keeper_healthy ~turns:90;
        ]
      in
      List.iter
        (fun (cols, rows) ->
          let base = populated_model ~cols ~rows ~lang:Say.Lang_ko in
          let fleet =
            Fleet_store.apply_keepers ~observed_at:Clock.Mono.zero keepers
              base.fleet
          in
          let m = { base with fleet } in
          let g, _ = render_full ~model:m ~cols ~rows in
          assert_clean_grid
            ~label:(Printf.sprintf "r55_5co_%s_%dx%d" fault_label cols rows)
            g;
          let txt = grid_all_text g in
          (match fault_health with
          | Wire_fleet.Keeper_failing ->
              assert_contains
                ~label:
                  (Printf.sprintf "r55_5co_%s_fail_banner_%dx%d" fault_label
                     cols rows)
                ~needle:"실시간 오류:" txt
          | Wire_fleet.Keeper_offline
          | Wire_fleet.Keeper_degraded
          | Wire_fleet.Keeper_healthy
          | Wire_fleet.Keeper_working
          | Wire_fleet.Keeper_idle
          | Wire_fleet.Keeper_recovering
          | Wire_fleet.Keeper_paused
          | Wire_fleet.Keeper_booting ->
              ());
          List.iter
            (fun co ->
              assert_contains
                ~label:(Printf.sprintf "r55_5co_%s_%s_%dx%d" fault_label co cols rows)
                ~needle:co txt)
            five_companies)
        [ (140, 40); (90, 28) ])
    [
      ("failing", Wire_fleet.Keeper_failing);
      ("offline", Wire_fleet.Keeper_offline);
      ("degraded", Wire_fleet.Keeper_degraded);
    ];

  (* 3. [P2] Settings Left Tree renders human provider titles (Claude Code #a1b2,
     Claude Code #b2c3, Antigravity CLI — ZERO raw hex8 slugs) and Right Inspector
     renders distinct per-model binding dividers ("모델 바인딩 · <model_id>"). *)
  let base_ko = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  let mk_f ~table ~key ~kind ~value () : Wire_config.schema_field =
    {
      table;
      key;
      full_key = table ^ "." ^ key;
      label = key;
      env = None;
      description = None;
      kind;
      value;
      default_value = None;
      provenance = Wire_config.Prov_project;
      reload_scope = Wire_config.Restart_required;
      secret = false;
      writable = true;
    }
  in
  let f1 =
    mk_f ~table:"providers.claude_code_a1b2c3d4" ~key:"protocol"
      ~kind:Wire_config.Field_string ~value:(Wire_config.Val_string "claude-code")
      ()
  in
  let f2 =
    mk_f ~table:"claude_code_a1b2c3d4.claude-sonnet-5-5" ~key:"max-context"
      ~kind:(Wire_config.Field_int { min = Some 1024; max = None })
      ~value:(Wire_config.Val_int 1000000) ()
  in
  let f3 =
    mk_f ~table:"claude_code_a1b2c3d4.claude-sonnet-5-5" ~key:"max-concurrent"
      ~kind:(Wire_config.Field_int { min = Some 1; max = Some 64 })
      ~value:(Wire_config.Val_int 4) ()
  in
  let f4 =
    mk_f ~table:"claude_code_a1b2c3d4.claude-opus-5-5" ~key:"max-context"
      ~kind:(Wire_config.Field_int { min = Some 1024; max = None })
      ~value:(Wire_config.Val_int 1000000) ()
  in
  let f5 =
    mk_f ~table:"claude_code_a1b2c3d4.claude-opus-5-5" ~key:"max-concurrent"
      ~kind:(Wire_config.Field_int { min = Some 1; max = Some 64 })
      ~value:(Wire_config.Val_int 2) ()
  in
  let f6 =
    mk_f ~table:"providers.claude_code_b2c3d4e5" ~key:"display-name"
      ~kind:Wire_config.Field_string
      ~value:(Wire_config.Val_string "claude_code_b2c3d4e5") ()
  in
  let f7 =
    mk_f ~table:"providers.antigravity_e5f60718" ~key:"protocol"
      ~kind:Wire_config.Field_string ~value:(Wire_config.Val_string "antigravity")
      ()
  in
  let schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha256-r55";
      sections =
        [
          {
            id = "runtime_providers";
            category = Wire_config.Cat_providers_models;
            title = "Providers & Models";
            fields = [ f1; f2; f3; f4; f5; f6; f7 ];
          };
        ];
    }
  in
  let meta : (string * Wire_config.field_entity_meta) list =
    [
      ( f1.full_key,
        {
          entity_group = Some "provider:claude_code_a1b2c3d4";
          entity_title = Some "Claude Code A1b2c3d4";
          sub_group = None;
        } );
      ( f2.full_key,
        {
          entity_group = Some "provider:claude_code_a1b2c3d4";
          entity_title = Some "Claude Code A1b2c3d4";
          sub_group = Some "model_bindings";
        } );
      ( f3.full_key,
        {
          entity_group = Some "provider:claude_code_a1b2c3d4";
          entity_title = Some "Claude Code A1b2c3d4";
          sub_group = Some "model_bindings";
        } );
      ( f4.full_key,
        {
          entity_group = Some "provider:claude_code_a1b2c3d4";
          entity_title = Some "Claude Code A1b2c3d4";
          sub_group = Some "model_bindings";
        } );
      ( f5.full_key,
        {
          entity_group = Some "provider:claude_code_a1b2c3d4";
          entity_title = Some "Claude Code A1b2c3d4";
          sub_group = Some "model_bindings";
        } );
      ( f6.full_key,
        {
          entity_group = Some "provider:claude_code_b2c3d4e5";
          entity_title = Some "claude_code_b2c3d4e5";
          sub_group = None;
        } );
      ( f7.full_key,
        {
          entity_group = Some "provider:antigravity_e5f60718";
          entity_title = Some "Antigravity E5f60718";
          sub_group = None;
        } );
    ]
  in
  let cfg =
    Config_store.empty
    |> Config_store.set_tab Nav.Settings_providers_models
    |> Config_store.apply_schema ~field_meta:meta ~observed_at:Clock.Mono.zero
         schema
  in
  let m_set =
    {
      base_ko with
      nav =
        {
          base_ko.nav with
          overlay = Some (Nav.Settings Nav.Settings_providers_models);
        };
      config = cfg;
    }
  in
  let g_set, _ = render_full ~model:m_set ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"r55_settings_providers_bindings" g_set;
  (* Left Tree region: cols 1..32, rows 4..37 *)
  let tree_text =
    let buf = Buffer.create 512 in
    for y = 4 to 37 do
      for x = 1 to 32 do
        match (Cell_grid.get g_set ~x ~y).glyph with
        | Cell_grid.Empty -> Buffer.add_char buf ' '
        | Cell_grid.Ascii c -> Buffer.add_char buf c
        | Cell_grid.Braille m -> Buffer.add_string buf (Cell_grid.braille_utf8 m)
        | Cell_grid.Utf8 s -> Buffer.add_string buf s
        | Cell_grid.Continuation -> ()
      done;
      Buffer.add_char buf '\n'
    done;
    Buffer.contents buf
  in
  List.iter
    (fun human ->
      assert_contains ~label:"r55_tree_human_provider" ~needle:human tree_text)
    [ "Claude Code #a1b2"; "Claude Code #b2c3"; "Antigravity CLI" ];
  List.iter
    (fun raw ->
      assert_not_contains ~label:"r55_tree_no_raw_slug" ~needle:raw tree_text)
    [ "claude_code_a1b2c3d4"; "claude_code_b2c3d4e5"; "antigravity_e5f60718" ];
  let full_txt = grid_all_text g_set in
  assert_contains ~label:"r55_inspector_binding_sonnet"
    ~needle:"모델 바인딩 · claude-sonnet-5-5" full_txt;
  assert_contains ~label:"r55_inspector_binding_opus"
    ~needle:"모델 바인딩 · claude-opus-5-5" full_txt

let test_p0_toast_above_active_overlay_and_settings_tab_focus () =
  let base_ko = populated_model ~lang:Say.Lang_ko ~cols:140 ~rows:40 in
  let base_en = populated_model ~lang:Say.Lang_en ~cols:140 ~rows:40 in
  (* (a) P0-5: Active toasts MUST render ABOVE Settings and Palette overlays *)
  let m_set_toast =
    {
      base_ko with
      nav =
        {
          base_ko.nav with
          overlay = Some (Nav.Settings Nav.Settings_general_ui);
        };
    }
    |> Model.with_toast ~now:Clock.Mono.zero ~level:Model.Toast_warning
         (Say.make ~ko:"저장 전 미리보기 경고" ~en:"Dry-run warning toast")
  in
  let g_set_toast, _ = render_full ~model:m_set_toast ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"p0_5_toast_above_settings" g_set_toast;
  assert_contains ~label:"p0_5_toast_visible_above_settings"
    ~needle:"저장 전 미리보기 경고" (grid_all_text g_set_toast);

  let m_pal_toast =
    {
      base_en with
      nav = { base_en.nav with overlay = Some Nav.Palette };
    }
    |> Model.with_toast ~now:Clock.Mono.zero ~level:Model.Toast_error
         (Say.make ~ko:"검증 오류 토스트" ~en:"Validation error toast")
  in
  let g_pal_toast, _ = render_full ~model:m_pal_toast ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"p0_5_toast_above_palette" g_pal_toast;
  assert_contains ~label:"p0_5_toast_visible_above_palette"
    ~needle:"Validation error toast" (grid_all_text g_pal_toast);

  (* (b) P1-11: Pressing Tab in Settings produces unmistakable pane focus diff *)
  let m_insp_ko =
    {
      base_ko with
      nav =
        {
          base_ko.nav with
          overlay = Some (Nav.Settings Nav.Settings_providers_models);
        };
      config =
        base_ko.config
        |> Config_store.set_tab Nav.Settings_providers_models
        |> Config_store.set_pane Config_store.Pane_inspector;
    }
  in
  let m_tree_ko =
    { m_insp_ko with config = Config_store.toggle_pane m_insp_ko.config }
  in
  let g_insp_ko, _ = render_full ~model:m_insp_ko ~cols:140 ~rows:40 in
  let g_tree_ko, _ = render_full ~model:m_tree_ko ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"p1_11_settings_insp_ko" g_insp_ko;
  assert_clean_grid ~label:"p1_11_settings_tree_ko" g_tree_ko;
  let txt_insp_ko = grid_all_text g_insp_ko in
  let txt_tree_ko = grid_all_text g_tree_ko in
  Alcotest.(check bool) "Tab changes Settings rendered grid (KO)" true
    (not (String.equal txt_insp_ko txt_tree_ko));
  assert_contains ~label:"p1_11_insp_focus_ko" ~needle:"속성 검사기 · 활성"
    txt_insp_ko;
  assert_not_contains ~label:"p1_11_tree_inactive_ko" ~needle:"탐색 트리 · 활성"
    txt_insp_ko;
  assert_contains ~label:"p1_11_tree_focus_ko" ~needle:"탐색 트리 · 활성"
    txt_tree_ko;
  assert_not_contains ~label:"p1_11_insp_inactive_ko" ~needle:"속성 검사기 · 활성"
    txt_tree_ko;

  let m_insp_en =
    {
      base_en with
      nav =
        {
          base_en.nav with
          overlay = Some (Nav.Settings Nav.Settings_providers_models);
        };
      config =
        base_en.config
        |> Config_store.set_tab Nav.Settings_providers_models
        |> Config_store.set_pane Config_store.Pane_inspector;
    }
  in
  let m_tree_en =
    { m_insp_en with config = Config_store.toggle_pane m_insp_en.config }
  in
  let g_insp_en, _ = render_full ~model:m_insp_en ~cols:140 ~rows:40 in
  let g_tree_en, _ = render_full ~model:m_tree_en ~cols:140 ~rows:40 in
  assert_contains ~label:"p1_11_insp_focus_en" ~needle:"INSPECTOR · FOCUS"
    (grid_all_text g_insp_en);
  assert_contains ~label:"p1_11_tree_focus_en" ~needle:"TREE · FOCUS"
    (grid_all_text g_tree_en)

let test_p1_pulse_collapsed_company_highlight_and_scroll () =
  let mk_k group name : Wire_fleet.keeper_summary =
    {
      name;
      group = Some group;
      company = group;
      health = Wire_fleet.Keeper_healthy;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "rt-1";
      model_id = Some "model-1";
      current_task_id = None;
      context = Observed.value ~observed_at:Clock.Mono.zero (measured_context 0.30);
      total_turns = Observed.value ~observed_at:Clock.Mono.zero 20;
      last_turn_at_unix = Some 1_795_200_000.0;
      active_turn = None;
    }
  in
  let ks =
    [
      mk_k "org-alpha" "alpha-1";
      mk_k "org-beta" "beta-1";
      mk_k "org-mid" "mid-1";
      mk_k "org-zeta" "zeta-1";
    ]
  in
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_en () in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_keepers ~observed_at:Clock.Mono.zero ks
    |> Fleet_store.toggle_company_collapsed "org-beta"
    |> Fleet_store.move_company_selection ~viewport_rows:10 ~delta:1
  in
  let m = { m0 with fleet; nav = { m0.nav with workspace = Nav.Pulse } } in
  let g, _ = render_full ~model:m ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"pulse_collapsed_beta_highlight" g;
  let rail = Glyph.to_utf8 Glyph.Left_rail in
  let has_sub ~needle haystack =
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
  in
  let rail_row_text =
    let rec scan y =
      if y >= 40 then None
      else
        let row = grid_row_text g y in
        if has_sub ~needle:rail row && has_sub ~needle:"org-" row then
          Some row
        else scan (y + 1)
    in
    scan 6
  in
  match rail_row_text with
  | None -> Alcotest.fail "Expected highlighted org row on Pulse Panel B"
  | Some row ->
      Alcotest.(check bool)
        ("Pulse highlights collapsed org-beta row (got: " ^ String.trim row ^ ")")
        true
        (has_sub ~needle:"org-beta" row)

let test_setup_key_inline_modal_masks_secret () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let modal : Model.inline_modal_state =
    {
      kind = Nav.Board_new_post;
      fields =
        [
          {
            key = "setup_key_integration";
            label = Say.make ~ko:"프로바이더 ID" ~en:"Provider ID";
            value = "gemini";
            required = true;
            secret = false;
          };
          {
            key = "setup_key_secret";
            label = Say.make ~ko:"API 키" ~en:"API key";
            value = "sk-SUPER-SECRET-TOKEN-999";
            required = true;
            secret = true;
          };
        ];
      active_field = 1;
      submitting = false;
      error = None;
    }
  in
  let m =
    {
      base with
      nav = { base.nav with overlay = Some (Nav.Inline_action Nav.Board_new_post) };
      inline_modal = Some modal;
    }
  in
  let g, _ = render_full ~model:m ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"setup_key_modal_secret_masked" g;
  let txt = grid_all_text g in
  assert_contains ~label:"setup_key_provider_visible" ~needle:"gemini" txt;
  assert_not_contains ~label:"setup_key_raw_secret_never_rendered"
    ~needle:"sk-SUPER-SECRET-TOKEN-999" txt

let test_memory_diff_viewport_skip_multi_row_selection () =
  let skip = Masc_tui_screens_core.Memory_explorer.diff_viewport_skip in
  (* Selected 3-row block [30..32] starts past avail_h=12 when scroll=15:
     skip must advance so [30, 32] lies inside [skip, skip + 11]. *)
  let s1 =
    skip ~total_rows:80 ~avail_h:12 ~scroll:15 ~selected_range:(Some (30, 32))
  in
  Alcotest.(check int) "advances skip so multi-row selection stays visible" 21 s1;
  Alcotest.(check bool) "sel_start >= skip" true (30 >= s1);
  Alcotest.(check bool) "sel_end <= skip + avail_h - 1" true (32 <= s1 + 11);
  (* Selected block above current scroll pulls viewport back up to sel_start *)
  let s2 =
    skip ~total_rows:80 ~avail_h:12 ~scroll:20 ~selected_range:(Some (5, 7))
  in
  Alcotest.(check int) "pulls skip up to sel_start" 5 s2;
  (* Tall wrapped entry taller than avail_h pins header at top of viewport *)
  let s3 =
    skip ~total_rows:80 ~avail_h:12 ~scroll:10 ~selected_range:(Some (40, 65))
  in
  Alcotest.(check int) "pins tall entry header at sel_start" 40 s3;
  (* Already-visible selection leaves scroll untouched *)
  let s4 =
    skip ~total_rows:80 ~avail_h:12 ~scroll:10 ~selected_range:(Some (12, 14))
  in
  Alcotest.(check int) "keeps scroll when selection already visible" 10 s4;
  (* Bottom clamp respects max_skip *)
  let s5 =
    skip ~total_rows:40 ~avail_h:12 ~scroll:999 ~selected_range:(Some (38, 39))
  in
  Alcotest.(check int) "clamps to max_skip at bottom" 28 s5;
  (* None selection preserves clamped scroll *)
  let s6 = skip ~total_rows:40 ~avail_h:12 ~scroll:9 ~selected_range:None in
  Alcotest.(check int) "None selection keeps clamped scroll" 9 s6

(* The Ctrl+T Context tab draws the gauge, the cache bar and the cost line
   first. The turn history and compaction facts take the rows left, so a
   short drawer keeps the cache bar and cost line and never reports a held
   cache snapshot as awaited. *)
let test_context_tab_keeps_cache_and_cost_first () =
  let keeper = "e-masc-the-leader" in
  let row i : Wire_fleet.turn_record_row =
    {
      absolute_turn = i + 1;
      input_tokens = Some (40_000 + (i * 5_000));
      usage_scope = Wire_fleet.Usage_per_request;
      input_provenance = Some Wire_fleet.Input_measured_request;
      context_window = Some 200_000;
      provider_context_window = None;
    }
  in
  let records : Wire_fleet.keeper_turn_records =
    { keeper; skipped_rows = 1; rows = List.init 6 row }
  in
  List.iter
    (fun (cols, rows, history_fits) ->
      let base = populated_model ~cols ~rows ~lang:Say.Lang_en in
      let m =
        {
          base with
          drafts = Drafts.set_active_keeper keeper base.drafts;
          fleet = Fleet_store.set_turn_records ~keeper (obs records) base.fleet;
          nav =
            {
              base.nav with
              overlay = Some (Nav.Queue_context Nav.Drawer_context);
            };
        }
      in
      let g, _ = render_full ~model:m ~cols ~rows in
      let label = Printf.sprintf "context_tab_%dx%d" cols rows in
      assert_clean_grid ~label g;
      let txt = grid_all_text g in
      assert_contains ~label ~needle:"Cache Read" txt;
      assert_contains ~label ~needle:"Runtime:" txt;
      assert_not_contains ~label
        ~needle:"Awaiting token & cache breakdown snapshot" txt;
      if history_fits then
        assert_contains ~label ~needle:"Context per turn" txt)
    [ (60, 18, false); (90, 28, true) ]

let test_feature_wave1_honest_ssot_chrome_transitions () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let live_fr =
    {
      base.freshness with
      observer = Health.Live { last_event_ns = Clock.Mono.zero; revision = 1 };
      fleet = Health.Live { last_event_ns = Clock.Mono.zero; revision = 1 };
      view_stream = Some (Health.Live { last_event_ns = Clock.Mono.zero; revision = 1 });
      server_offline = false;
    }
  in
  let m_pulse = { base with freshness = live_fr } in
  let g_pulse, _ = render_full ~model:m_pulse ~cols:140 ~rows:40 in
  assert_contains ~label:"Pulse top bar shows LIVE SSE" ~needle:"LIVE SSE"
    (grid_row_text g_pulse 0);
  let m_work = { m_pulse with nav = { m_pulse.nav with workspace = Nav.Work } } in
  let g_work, _ = render_full ~model:m_work ~cols:140 ~rows:40 in
  assert_contains ~label:"Work top bar shows SYNCED" ~needle:"SYNCED"
    (grid_row_text g_work 0);
  assert_not_contains ~label:"Work top bar never claims LIVE SSE" ~needle:"LIVE SSE"
    (grid_row_text g_work 0);
  let m_repos =
    {
      m_pulse with
      nav = { m_pulse.nav with workspace = Nav.Infra };
      infra = Infra_store.set_tab Nav.Infra_repos_changes m_pulse.infra;
    }
  in
  let g_repos, _ = render_full ~model:m_repos ~cols:140 ~rows:40 in
  assert_contains ~label:"Infra > Repos top bar shows SNAPSHOT" ~needle:"SNAPSHOT"
    (grid_row_text g_repos 0);
  assert_not_contains ~label:"Infra > Repos never claims LIVE SSE" ~needle:"LIVE SSE"
    (grid_row_text g_repos 0)

let test_build_commit_display_in_help_and_settings () =
  (* 1. Pure Model build-label & mismatch helpers *)
  let m_bare = Model.initial ~tui_version:"0.81.0" ~tui_commit:None () in
  Alcotest.(check string) "tui_build_label without commit" "v0.81.0"
    (Model.tui_build_label m_bare);
  Alcotest.(check (option string)) "server_build_label when unknown" None
    (Model.server_build_label m_bare);
  Alcotest.(check bool) "no mismatch when commits missing" false
    (Model.build_commit_mismatch m_bare);
  let m_short = Model.initial ~tui_version:"0.81.0" ~tui_commit:(Some "abc") () in
  Alcotest.(check string) "tui_build_label safe on short commit" "v0.81.0 (abc)"
    (Model.tui_build_label m_short);
  let m_full =
    let m0 =
      Model.initial ~tui_version:"0.81.0"
        ~tui_commit:(Some "2a58dc5799999999999999999999999999999999") ()
    in
    {
      m0 with
      server_identity =
        {
          m0.server_identity with
          observer_version = Some "0.81.0";
          observer_commit = Some "4a271ac588888888888888888888888888888888";
        };
    }
  in
  Alcotest.(check string) "tui_build_label 8-char short SHA"
    "v0.81.0 (2a58dc57)" (Model.tui_build_label m_full);
  Alcotest.(check (option string)) "server_build_label 8-char short SHA"
    (Some "v0.81.0 (4a271ac5)") (Model.server_build_label m_full);
  Alcotest.(check bool) "mismatch detected when commits differ" true
    (Model.build_commit_mismatch m_full);
  let m_same =
    {
      m_full with
      server_identity =
        {
          m_full.server_identity with
          observer_commit = Some "2a58dc5799999999999999999999999999999999";
        };
    }
  in
  Alcotest.(check bool) "no mismatch when commits equal" false
    (Model.build_commit_mismatch m_same);

  (* 2. ? Help and , Settings render TUI + Server build commit hashes cleanly
        at normal (140x40), compact (90x28), and narrow (60x18) viewports. *)
  let with_builds ~server_commit (m : Model.t) =
    {
      m with
      tui_version = "0.81.0";
      tui_commit = Some "2a58dc5799999999999999999999999999999999";
      server_identity =
        {
          m.server_identity with
          observer_version = Some "0.81.0";
          observer_commit = Some server_commit;
        };
    }
  in
  List.iter
    (fun lang ->
      List.iter
        (fun (cols, rows) ->
          let base_mismatch =
            populated_model ~cols ~rows ~lang
            |> with_builds
                 ~server_commit:"4a271ac588888888888888888888888888888888"
          in
          let base_match =
            populated_model ~cols ~rows ~lang
            |> with_builds
                 ~server_commit:"2a58dc5799999999999999999999999999999999"
          in
          (* ? Help with mismatched commits *)
          let m_help =
            {
              base_mismatch with
              nav = { base_mismatch.nav with overlay = Some Nav.Help };
            }
          in
          let g_help, _ = render_full ~model:m_help ~cols ~rows in
          let lbl_h = Printf.sprintf "help_build_mismatch_%dx%d" cols rows in
          assert_clean_grid ~label:lbl_h g_help;
          let txt_h = grid_all_text g_help in
          assert_contains ~label:lbl_h ~needle:"TUI v0.81.0 (2a58dc57)" txt_h;
          assert_contains ~label:lbl_h ~needle:"Server v0.81.0 (4a271ac5)" txt_h;
          assert_contains ~label:lbl_h
            ~needle:(Glyph.to_utf8 Glyph.Warning_triangle) txt_h;
          (* ? Help with matching commits omits mismatch warning *)
          let m_help_ok =
            {
              base_match with
              nav = { base_match.nav with overlay = Some Nav.Help };
            }
          in
          let g_help_ok, _ = render_full ~model:m_help_ok ~cols ~rows in
          let lbl_hok = Printf.sprintf "help_build_match_%dx%d" cols rows in
          assert_clean_grid ~label:lbl_hok g_help_ok;
          let txt_hok = grid_all_text g_help_ok in
          assert_contains ~label:lbl_hok ~needle:"TUI v0.81.0 (2a58dc57)"
            txt_hok;
          assert_contains ~label:lbl_hok ~needle:"Server v0.81.0 (2a58dc57)"
            txt_hok;
          assert_not_contains ~label:lbl_hok ~needle:"commit mismatch" txt_hok;
          assert_not_contains ~label:lbl_hok ~needle:"커밋 불일치" txt_hok;
          (* , Settings (clean and dirty) renders TUI + Server build hashes at
             wide/compact and clips gracefully at narrow 60x18 without losing
             [Esc] or breaking layout. *)
          let m_set_clean =
            {
              base_mismatch with
              nav =
                {
                  base_mismatch.nav with
                  overlay = Some (Nav.Settings Nav.Settings_general_ui);
                };
              config =
                {
                  base_mismatch.config with
                  dirty_fields = Config_store.String_map.empty;
                };
            }
          in
          let g_set_clean, _ = render_full ~model:m_set_clean ~cols ~rows in
          let lbl_sc = Printf.sprintf "settings_build_clean_%dx%d" cols rows in
          assert_clean_grid ~label:lbl_sc g_set_clean;
          let txt_sc = grid_all_text g_set_clean in
          if cols >= 90 then begin
            assert_contains ~label:lbl_sc ~needle:"TUI v0.81.0 (2a58dc57)"
              txt_sc;
            assert_contains ~label:lbl_sc ~needle:"Server v0.81.0 (4a271ac5)"
              txt_sc
          end
          else
            (* Narrow 60x18 clips subtitle gracefully while keeping Esc close intact *)
            assert_contains ~label:lbl_sc ~needle:"[Esc]" txt_sc;
          let m_set_dirty =
            {
              base_mismatch with
              nav =
                {
                  base_mismatch.nav with
                  overlay = Some (Nav.Settings Nav.Settings_general_ui);
                };
            }
          in
          let g_set_dirty, _ = render_full ~model:m_set_dirty ~cols ~rows in
          let lbl_sd = Printf.sprintf "settings_build_dirty_%dx%d" cols rows in
          assert_clean_grid ~label:lbl_sd g_set_dirty;
          if cols >= 140 then begin
            let txt_sd = grid_all_text g_set_dirty in
            assert_contains ~label:lbl_sd ~needle:"TUI v0.81.0 (2a58dc57)"
              txt_sd;
            assert_contains ~label:lbl_sd ~needle:"Server v0.81.0 (4a271ac5)"
              txt_sd
          end)
        [ (140, 40); (90, 28); (60, 18) ])
    [ Say.Lang_ko; Say.Lang_en ]

let test_wave2_sidebar_keepers_sync_and_overlays () =
  (* 1. Wide 140x40 renders docked Left Sidebar + Top Chrome persistent utility badges *)
  let m_wide = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let l_wide = Chrome.compute_layout ~model:m_wide ~cols:140 ~rows:40 in
  let g_wide, _ = render_full ~model:m_wide ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"Wave2/DockedSidebar" g_wide;
  Alcotest.(check bool) "Wide docked sidebar present and non-drawer" true
    (Option.is_some l_wide.sidebar && not l_wide.sidebar_is_drawer);
  let row0 = grid_row_text g_wide 0 in
  assert_contains ~label:"Top Chrome shows [b] Menu badge" ~needle:"[b]" row0;
  assert_contains ~label:"Top Chrome shows [?] badge" ~needle:"[?]" row0;
  let all_wide = grid_all_text g_wide in
  assert_contains ~label:"Docked sidebar lists Schedules" ~needle:"Schedules" all_wide;
  assert_contains ~label:"Docked sidebar lists Artifacts" ~needle:"Artifacts" all_wide;
  assert_contains ~label:"Docked sidebar lists Context & Turns" ~needle:"Context" all_wide;
  assert_contains ~label:"Docked sidebar lists Fusion" ~needle:"Fusion" all_wide;

  (* 2. Compact 100x30 drawer overlay opens when sidebar_open && sidebar_focused *)
  let m_cmp =
    let m0 = populated_model ~cols:100 ~rows:30 ~lang:Say.Lang_en in
    {
      m0 with
      nav = { m0.nav with sidebar_open = Some true; sidebar_focused = true };
    }
  in
  let l_cmp = Chrome.compute_layout ~model:m_cmp ~cols:100 ~rows:30 in
  let g_cmp, _ = render_full ~model:m_cmp ~cols:100 ~rows:30 in
  assert_clean_grid ~label:"Wave2/DrawerSidebar" g_cmp;
  Alcotest.(check bool) "Compact open+focused sidebar is floating drawer" true
    (Option.is_some l_cmp.sidebar && l_cmp.sidebar_is_drawer);

  (* 3. Keepers Split Sub-Tab Bar Sync: pane_index=0 shows fleet modes; pane_index=1 shows all 7 Keeper tabs *)
  let m_kp0 =
    {
      m_wide with
      nav = { m_wide.nav with workspace = Nav.Keepers; pane_index = 0 };
    }
  in
  let g_kp0, _ = render_full ~model:m_kp0 ~cols:140 ~rows:40 in
  let sub0 = grid_row_text g_kp0 1 in
  assert_contains ~label:"Keepers pane 0 sub-tab shows Companies"
    ~needle:"Companies" sub0;
  let m_kp1 = { m_kp0 with nav = { m_kp0.nav with pane_index = 1 } } in
  let g_kp1, _ = render_full ~model:m_kp1 ~cols:140 ~rows:40 in
  let sub1 = grid_row_text g_kp1 1 in
  assert_contains ~label:"Keepers pane 1 sub-tab syncs to Ctx/Context tab"
    ~needle:"Ctx" sub1;
  assert_contains ~label:"Keepers pane 1 sub-tab syncs to Tools tab"
    ~needle:"Tools" sub1;

  (* 4. Upgraded Drawer_context & Rich HTML Media_viewer render cleanly *)
  let m_ctx_ov =
    {
      m_wide with
      nav = { m_wide.nav with overlay = Some (Nav.Queue_context Nav.Drawer_context) };
    }
  in
  let g_ctx, _ = render_full ~model:m_ctx_ov ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"Wave2/DrawerContext" g_ctx;
  let m_mv =
    {
      m_wide with
      nav = { m_wide.nav with overlay = Some (Nav.System_gate Nav.Media_viewer) };
    }
  in
  let g_mv, _ = render_full ~model:m_mv ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"Wave2/MediaViewer" g_mv

let test_ask_answer_modal_and_honest_ask_surfaces () =
  let t0 = Clock.Mono.zero in
  let sample_ask : Wire_work.ask_row =
    {
      ask_id = "ask-render-1";
      keeper = "alpha";
      asked_at = 1710000000.0;
      context = Some "Need operator decision before merge.";
      questions =
        [
          {
            question_id = "q1";
            header = "Rollout";
            prompt = "Choose rollout plan:";
            mode = Wire_work.Ask_multi;
            allow_free_text = true;
            free_text_hint = Some "Custom notes";
            choices =
              List.init 6 (fun i ->
                  {
                    Wire_work.choice_id = Printf.sprintf "opt-%d" (i + 1);
                    label = Printf.sprintf "Option %d" (i + 1);
                    description = Some (Printf.sprintf "Details %d" (i + 1));
                  });
          };
          {
            question_id = "q2";
            header = "Followup";
            prompt = "Confirm followup step:";
            mode = Wire_work.Ask_single;
            allow_free_text = false;
            free_text_hint = None;
            choices =
              [
                {
                  Wire_work.choice_id = "yes";
                  label = "Proceed";
                  description = None;
                };
              ];
          };
        ];
      resolution = Wire_work.Ask_open;
    }
  in
  List.iter
    (fun (lang, want_y, want_n, want_j, want_pulse, want_closed) ->
      let base = populated_model ~cols:140 ~rows:40 ~lang in
      let m_ask =
        {
          base with
          nav = { base.nav with workspace = Nav.Pulse; overlay = None };
          work =
            Work_store.empty
            |> Work_store.apply_asks ~observed_at:t0 [ sample_ask ];
        }
        |> Model.rebuild_attention
      in
      (* 1. Honest Approval Strip & Pulse labels at 140x40 and 80x24 *)
      let g_wide, _ = render_full ~model:m_ask ~cols:140 ~rows:40 in
      assert_clean_grid ~label:"ask_surface_140x40" g_wide;
      let txt_wide = grid_all_text g_wide in
      assert_contains ~label:"approval_strip_y" ~needle:want_y txt_wide;
      assert_contains ~label:"approval_strip_n" ~needle:want_n txt_wide;
      assert_contains ~label:"approval_strip_j" ~needle:want_j txt_wide;
      assert_contains ~label:"pulse_ask_hint" ~needle:want_pulse txt_wide;
      (* Sidebar scrolled to System section shows 7/, 8/I 9/^T 0/? utility shortcuts *)
      let m_sb_sys =
        {
          m_ask with
          incidents = Incidents.empty;
          nav =
            {
              m_ask.nav with
              sidebar_focused = true;
              sidebar_cursor = Nav.menu_item_index Nav.Menu_help;
            };
        }
      in
      let g_sb_sys, _ = render_full ~model:m_sb_sys ~cols:140 ~rows:40 in
      assert_clean_grid ~label:"sidebar_system_140x40" g_sb_sys;
      let txt_sb = grid_all_text g_sb_sys in
      assert_contains ~label:"sidebar_7" ~needle:"7/," txt_sb;
      assert_contains ~label:"sidebar_8" ~needle:"8/I" txt_sb;
      assert_contains ~label:"sidebar_9" ~needle:"9/^T" txt_sb;
      assert_contains ~label:"sidebar_0" ~needle:"0/?" txt_sb;

      let g_narrow, _ =
        render_full
          ~model:
            {
              m_ask with
              viewport = { cols = 80; rows = 24 };
              breakpoint = Model.Compact;
            }
          ~cols:80 ~rows:24
      in
      assert_clean_grid ~label:"ask_surface_80x24" g_narrow;

      (* 2. Open Ask Answer Modal with free-text Korean caret & scrolled choice *)
      let modal_open =
        Model.ask_modal_for sample_ask
        |> Model.ask_modal_toggle_or_select_choice 0
        |> Model.ask_modal_enter_free_text
        |> Model.ask_modal_insert_free_text "한글 입력 테스트"
      in
      let m_modal =
        {
          m_ask with
          nav = { m_ask.nav with overlay = Some Nav.Ask_answer };
          ask_modal = Some modal_open;
        }
      in
      List.iter
        (fun (cols, rows) ->
          let bp = Model.classify_viewport { cols; rows } in
          let m_vp =
            { m_modal with viewport = { cols; rows }; breakpoint = bp }
          in
          let g, _ = render_full ~model:m_vp ~cols ~rows in
          assert_clean_grid
            ~label:(Printf.sprintf "ask_modal_%dx%d" cols rows)
            g;
          let txt = grid_all_text g in
          assert_contains ~label:"ask_modal_progress" ~needle:"Q 1/2" txt;
          assert_contains
            ~label:(Printf.sprintf "ask_modal_prompt_visible_%dx%d" cols rows)
            ~needle:"Choose rollout plan:" txt;
          assert_contains ~label:"ask_modal_korean_ft" ~needle:"한글" txt)
        [ (140, 40); (90, 28); (80, 24); (60, 20) ];

      (* 2b. Overflowing prompt shows [J/K] scroll indicator *)
      let long_ask =
        {
          sample_ask with
          context =
            Some
              (String.concat "\n"
                 (List.init 10 (fun i ->
                      Printf.sprintf "Extra context paragraph line %d." (i + 1))));
        }
      in
      let m_long =
        {
          m_modal with
          work = Work_store.empty |> Work_store.apply_asks ~observed_at:t0 [ long_ask ];
          ask_modal = Some (Model.ask_modal_for long_ask);
        }
        |> Model.rebuild_attention
      in
      let g_long, _ = render_full ~model:m_long ~cols:80 ~rows:24 in
      assert_clean_grid ~label:"ask_modal_long_prompt_80x24" g_long;
      assert_contains ~label:"ask_modal_prompt_scroll_hint" ~needle:"[J/K]"
        (grid_all_text g_long);

      (* 3. Closed Live Status Guard & Submitting/In-flight read-only hints *)
      let m_closed =
        {
          m_modal with
          work = Work_store.apply_asks ~observed_at:t0 [] m_modal.work;
        }
        |> Model.rebuild_attention
      in
      let g_closed, _ = render_full ~model:m_closed ~cols:140 ~rows:40 in
      assert_clean_grid ~label:"ask_modal_closed" g_closed;
      let txt_closed = grid_all_text g_closed in
      assert_contains ~label:"ask_modal_closed_banner" ~needle:want_closed
        txt_closed;
      assert_not_contains ~label:"ask_modal_closed_no_submit_hint"
        ~needle:"[^↵]" txt_closed;
      assert_not_contains ~label:"ask_modal_closed_no_enter_submit"
        ~needle:"[Enter]" txt_closed;

      let m_submitting =
        {
          m_modal with
          ask_modal =
            Some
              {
                modal_open with
                editing_free_text = false;
                submitting = true;
              };
        }
      in
      let g_sub, _ = render_full ~model:m_submitting ~cols:140 ~rows:40 in
      assert_clean_grid ~label:"ask_modal_submitting" g_sub;
      let txt_sub = grid_all_text g_sub in
      assert_not_contains ~label:"ask_modal_submitting_no_submit_hint"
        ~needle:"[^↵]" txt_sub;
      assert_not_contains ~label:"ask_modal_submitting_no_enter_submit"
        ~needle:"[Enter]" txt_sub)
    [
      ( Say.Lang_ko
      , "[Y] 질문 답변"
      , "[N] 건너뛰기"
      , "[J] 수신함"
      , "[Y] 답변"
      , "이미 응답되었거나 철회된 질문입니다" );
      ( Say.Lang_en
      , "[Y] Answer Ask"
      , "[N] Skip"
      , "[J] Inbox"
      , "[Y] Answer"
      , "already answered or withdrawn" );
    ]

let test_pr54557_form_cursor_insertion_and_settings_secret_mask () =
  let base = populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  (* 1. Form.draw inserts cursor glyph without overwriting following ASCII or CJK chars *)
  let mk_modal_model ~value ~cursor =
    let modal : Model.inline_modal_state =
      {
        kind = Nav.Board_new_post;
        fields =
          [
            {
              key = "title";
              label = Say.literal "Title";
              value;
              required = true;
              secret = false;
            };
          ];
        active_field = 0;
        submitting = false;
        error = None;
      }
    in
    {
      base with
      nav =
        {
          base.nav with
          overlay = Some (Nav.Inline_action Nav.Board_new_post);
          modal_edit_cursor = cursor;
        };
      inline_modal = Some modal;
    }
  in
  let g_ascii, _ =
    render_full ~model:(mk_modal_model ~value:"abc" ~cursor:1) ~cols:120 ~rows:36
  in
  assert_clean_grid ~label:"PR54557/FormCursorASCII" g_ascii;
  assert_contains ~label:"PR54557/FormCursorASCII preserves 'b' after cursor"
    ~needle:"a▏bc" (grid_all_text g_ascii);
  let g_cjk, _ =
    render_full ~model:(mk_modal_model ~value:"가나" ~cursor:3) ~cols:120 ~rows:36
  in
  assert_clean_grid ~label:"PR54557/FormCursorCJK no orphan continuation" g_cjk;
  assert_contains ~label:"PR54557/FormCursorCJK preserves '나' after cursor"
    ~needle:"가▏나" (grid_all_text g_cjk);

  (* 2. Settings grouped inspector never leaks unrevealed Secret_val during inline editing *)
  let secret_plain = "sk-ant-super-secret-999" in
  let secret_field : Wire_config.schema_field =
    {
      table = "providers.anthropic";
      key = "api_key";
      full_key = "providers.anthropic.api_key";
      label = "API Key";
      env = Some "ANTHROPIC_API_KEY";
      description = None;
      kind = Wire_config.Field_secret;
      value = Wire_config.Val_string secret_plain;
      default_value = None;
      provenance = Wire_config.Prov_project;
      reload_scope = Wire_config.Hot_reload;
      secret = true;
      writable = true;
    }
  in
  let schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_runtime;
      keeper = None;
      file_exists = true;
      file_sha256 = "sha256-secret-test";
      sections =
        [
          {
            id = "providers.anthropic";
            category = Wire_config.Cat_providers_models;
            title = "Anthropic";
            fields = [ secret_field ];
          };
        ];
    }
  in
  let cfg_editing =
    let c0 =
      Config_store.empty
      |> Config_store.set_tab Nav.Settings_providers_models
      |> Config_store.apply_schema ~observed_at:Clock.Mono.zero schema
    in
    {
      c0 with
      editing_field_key = Some "providers.anthropic.api_key";
      editing_buffer = secret_plain;
      editing_cursor = String.length secret_plain;
    }
  in
  let m_set =
    {
      base with
      nav =
        {
          base.nav with
          overlay = Some (Nav.Settings Nav.Settings_providers_models);
          pane_index = 1;
        };
      config = cfg_editing;
    }
  in
  let g_set, _ = render_full ~model:m_set ~cols:140 ~rows:40 in
  assert_clean_grid ~label:"PR54557/SettingsSecretEdit" g_set;
  let txt_set = grid_all_text g_set in
  Alcotest.(check bool)
    "PR54557/SettingsSecretEdit renders masked cursor while editing secret" true
    (Store_scroll.contains_ci ~needle:"▏" txt_set);
  Alcotest.(check bool)
    "PR54557/SettingsSecretEdit must never leak plaintext secret" false
    (Store_scroll.contains_ci ~needle:secret_plain txt_set)

let test_ux_sweep_world_pulse_and_too_small_quit_arm () =
  (* Finding #3: World Pulse keeps [3] Knowledge discovery visible across 80x24, 120x36, 140x40, 160x40 KO & EN *)
  List.iter
    (fun (lang, needle) ->
      List.iter
        (fun (cols, rows, empty_attn) ->
          let m0 = populated_model ~cols ~rows ~lang in
          let m =
            if empty_attn then { m0 with attention = Attention.empty } else m0
          in
          let g, _ = render_full ~model:m ~cols ~rows in
          assert_clean_grid
            ~label:(Printf.sprintf "WorldPulse_%dx%d" cols rows)
            g;
          let txt = grid_all_text g in
          assert_contains
            ~label:(Printf.sprintf "WorldPulse_%dx%d shows %s" cols rows needle)
            ~needle txt)
        [ (80, 24, true); (120, 36, false); (140, 40, false); (160, 40, false) ])
    [ (Say.Lang_ko, "[3] 지식"); (Say.Lang_en, "[3] Knowledge") ];
  (* Finding #4: <40x12 too_small_guard displays armed Ctrl+Q confirmation prompt *)
  let m_small =
    {
      (populated_model ~cols:36 ~rows:10 ~lang:Say.Lang_en) with
      quit_armed_at = Some Clock.Mono.zero;
    }
  in
  let g_small, _ = render_full ~model:m_small ~cols:36 ~rows:10 in
  let txt_small = grid_all_text g_small in
  assert_contains ~label:"TooSmallGuard shows armed Ctrl+Q prompt"
    ~needle:"Press Ctrl+Q again to quit" txt_small

let () =
  Alcotest.run "masc_tui_screens_core"
    [
      ( "chrome",
        [
          Alcotest.test_case "compact 3-row auto-fold and expand triggers" `Quick
            test_compact_chrome_auto_fold;
          Alcotest.test_case "footer never overflows across 80/90/140/180 KO & EN" `Quick
            test_footer_never_overflows;
          Alcotest.test_case "freshness pills and 90x28 sub-tab fit" `Quick
            test_chrome_freshness_and_subtabs;
          Alcotest.test_case "micro 60x18 cockpit guard and <40x12 blocker" `Quick
            test_micro_viewport_guard;
          Alcotest.test_case "no @_default leak, no dup settings diff, actual micro grid dims" `Quick
            test_no_default_leak_no_dup_diff_and_micro_grid_dims;
          Alcotest.test_case "round1 local clock, symmetric pills & 90x28 compact fit"
            `Quick test_round1_local_clock_pills_and_compact_fit;
          Alcotest.test_case "v2.5 body margins, calm top nav & quiet keycap footer"
            `Quick test_v25_chrome_margins_and_keycaps;
          Alcotest.test_case "Feature Wave 1: honest LIVE SSE vs SYNCED vs SNAPSHOT top bar"
            `Quick test_feature_wave1_honest_ssot_chrome_transitions;
          Alcotest.test_case "Feature Wave 2: Left Navigation Sidebar, Top Chrome badges, Keepers sub-tab sync & Drawer_context"
            `Quick test_wave2_sidebar_keepers_sync_and_overlays;
        ] );
      ( "pulse",
        [
          Alcotest.test_case "populated and empty Pulse at 140x40, 110x32, 90x28 KO & EN"
            `Quick test_pulse_populated_and_empty;
          Alcotest.test_case "Pulse selection sync, scroll windows, and velocity tok/min units"
            `Quick test_pulse_selection_scroll_and_velocity_units;
          Alcotest.test_case "v2.5 4-KPI hero band & 5-company sparklines/costs"
            `Quick test_v25_pulse_4kpi_hero_and_5_companies;
          Alcotest.test_case "v2.5 honest Observed markers & zero fabricated zeros"
            `Quick test_v25_pulse_honest_observed_and_no_fabricated_zeros;
          Alcotest.test_case "P1 #3: Pulse highlights collapsed company row correctly"
            `Quick test_p1_pulse_collapsed_company_highlight_and_scroll;
        ] );
      ( "overlays",
        [
          Alcotest.test_case "all 7 universal overlays at 140x40, 90x28, 60x18 KO & EN"
            `Quick test_all_7_overlays;
          Alcotest.test_case "Context tab keeps the cache bar and cost line first"
            `Quick test_context_tab_keeps_cache_and_cost_first;
          Alcotest.test_case "palette high selection >12 and Update_nav parity"
            `Quick test_palette_high_selection_and_sync;
          Alcotest.test_case "incident prefixed JSON and truncated/plain-text secret redaction"
            `Quick test_incident_prefixed_and_truncated_redaction;
          Alcotest.test_case "round2 palette wide-cursor & settings full-width no-bleed"
            `Quick test_round2_palette_and_settings_regressions;
          Alcotest.test_case "v2.5 2-pane Settings tree -> property inspector & global search"
            `Quick test_v25_settings_2pane_tree_inspector;
          Alcotest.test_case "v2.5 Settings 1-subgroup divider, 2-row error scroll & single tree highlight"
            `Quick test_v25_settings_grouped_scroll_1subgroup_and_single_highlight;
          Alcotest.test_case "v2.5 Round 5.5 attention bar no-collision, 5 companies with fail banner, and human Settings providers/bindings"
            `Quick test_v25_round55_attention_bar_5companies_fail_and_settings_polish;
          Alcotest.test_case "P0-5 toast above active overlay & P1-11 Settings Tab pane focus"
            `Quick test_p0_toast_above_active_overlay_and_settings_tab_focus;
          Alcotest.test_case "Setup API key inline modal masks secret field on screen"
            `Quick test_setup_key_inline_modal_masks_secret;
          Alcotest.test_case "Help & Settings render TUI and Server build commit hashes"
            `Quick test_build_commit_display_in_help_and_settings;
          Alcotest.test_case "Ask Answer Modal & honest Approval Strip / Pulse / Sidebar surfaces"
            `Quick test_ask_answer_modal_and_honest_ask_surfaces;
          Alcotest.test_case "PR #54557: Form cursor insertion (ASCII/CJK) & Settings secret edit masking"
            `Quick test_pr54557_form_cursor_insertion_and_settings_secret_mask;
          Alcotest.test_case "UX Sweep Findings #3/#4: World Pulse [3] across viewports & <40x12 Ctrl+Q armed prompt"
            `Quick test_ux_sweep_world_pulse_and_too_small_quit_arm;
        ] );
      ( "memory_explorer",
        [
          Alcotest.test_case
            "diff_viewport_skip keeps multi-row selection inside visible slice"
            `Quick test_memory_diff_viewport_skip_multi_row_selection;
        ] );
    ]
