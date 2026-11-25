open Masc_tui_core
open Masc_tui_term
open Masc_tui_keymap
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_screens_ops

(* A measured context reading: [ratio] of a 200k-token window. *)
let operation_provenance id transcript_slot =
  let open Keeper_chat_delivery_identity in
  match Request_id.of_string id with
  | Ok id -> Some { delivery_key = Operation id; transcript_slot }
  | Error error -> Alcotest.fail error

let measured_context ratio : Wire_fleet.context_reading =
  Wire_fleet.Context_measured
    {
      ratio = Some ratio;
      tokens = Float.to_int (ratio *. 200_000.0);
      window = Some 200_000;
      absolute_turn = None;
      measured_at_unix = None;
    }

let grid_row_text (grid : Cell_grid.t) ~y =
  let buf = Buffer.create (Cell_grid.cols grid) in
  for x = 0 to Cell_grid.cols grid - 1 do
    let cell = Cell_grid.get grid ~x ~y in
    match cell.glyph with
    | Cell_grid.Empty -> Buffer.add_char buf ' '
    | Cell_grid.Ascii ch -> Buffer.add_char buf ch
    | Cell_grid.Braille mask ->
        Buffer.add_string buf (Cell_grid.braille_utf8 mask)
    | Cell_grid.Utf8 s -> Buffer.add_string buf s
    | Cell_grid.Continuation -> ()
  done;
  Buffer.contents buf

let grid_all_text (grid : Cell_grid.t) =
  let rows = List.init (Cell_grid.rows grid) (fun y -> grid_row_text grid ~y) in
  String.concat "\n" rows

let non_empty_row_count (grid : Cell_grid.t) =
  let count = ref 0 in
  for y = 0 to Cell_grid.rows grid - 1 do
    let row = String.trim (grid_row_text grid ~y) in
    if String.length row > 0 then incr count
  done;
  !count

let contains_sub ~needle haystack =
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

let has_any_hyperlink (grid : Cell_grid.t) =
  let found = ref false in
  for y = 0 to Cell_grid.rows grid - 1 do
    for x = 0 to Cell_grid.cols grid - 1 do
      let cell = Cell_grid.get grid ~x ~y in
      if cell.style.hyperlink_id > 0 then found := true
    done
  done;
  !found

(* Two grids that show the same glyphs in the same styles. *)
let grids_draw_the_same (a : Cell_grid.t) (b : Cell_grid.t) =
  Int.equal (Cell_grid.cols a) (Cell_grid.cols b)
  && Int.equal (Cell_grid.rows a) (Cell_grid.rows b)
  &&
  let cells = Cell_grid.cols a * Cell_grid.rows a in
  let rec loop i =
    i >= cells
    ||
    let ca = Cell_grid.get_linear a i in
    let cb = Cell_grid.get_linear b i in
    ( Cell_grid.glyph_equal ca.glyph cb.glyph
      && Int.equal ca.width cb.width
      && Style.equal ca.style cb.style )
    && loop (i + 1)
  in
  loop 0

(* --- Rich Deterministic Fixture Model --- *)

let now_mono = Clock.Mono.of_ns 10_000_000_000L
let now_unix = 1_795_200_000.0

let sample_keepers : Wire_fleet.keeper_summary list =
  [
    {
      name = "e-masc-the-leader";
      group = Some "MASC Core Eng";
      company = "MASC Core Eng";
      health = Wire_fleet.Keeper_healthy;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "sonnet-med-cascade";
      model_id = Some "claude-sonnet-4-6";
      current_task_id = Some "task-3898";
      context = Observed.value ~observed_at:now_mono (measured_context 0.48);
      total_turns = Observed.value ~observed_at:now_mono 412;
      last_turn_at_unix = Some (now_unix -. 45.0);
      active_turn = None;
    };
    {
      name = "wkbl-growth";
      group = Some "WKBL Startup";
      company = "WKBL Startup";
      health = Wire_fleet.Keeper_failing;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "gpt-6.2-sol";
      model_id = Some "gpt-6.2-sol";
      current_task_id = Some "task-3215";
      context = Observed.value ~observed_at:now_mono (measured_context 0.44);
      total_turns = Observed.value ~observed_at:now_mono 288;
      last_turn_at_unix = Some (now_unix -. 240.0);
      active_turn =
        Some
          {
            lane = Wire_fleet.Lane_task;
            turn_ref = None;
            started_at_unix = now_unix -. 240.0;
            interrupt_token = "tok-wkbl-1";
            phase = Some "retrying";
            tool_in_flight = Some "MascBoardPostGet";
            elapsed_ms = Some 1420.0;
            preview_observed_through = None;
            preview = None;
          };
    };
    {
      name = "code-reviewer";
      group = Some "Code Review Family";
      company = "Code Review Family";
      health = Wire_fleet.Keeper_working;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_on_demand;
      runtime_id = "glm-5-3";
      model_id = Some "glm-5-3";
      current_task_id = Some "task-3900";
      context = Observed.value ~observed_at:now_mono (measured_context 0.62);
      total_turns = Observed.value ~observed_at:now_mono 520;
      last_turn_at_unix = Some (now_unix -. 12.0);
      active_turn =
        Some
          {
            lane = Wire_fleet.Lane_verification;
            turn_ref = None;
            started_at_unix = now_unix -. 12.0;
            interrupt_token = "tok-cr-1";
            phase = Some "reviewing";
            tool_in_flight = Some "git_diff";
            elapsed_ms = Some 380.0;
            preview_observed_through = None;
            preview = None;
          };
    };
    {
      name = "music-sensei";
      group = Some "Creative / R&D";
      company = "Creative / R&D";
      health = Wire_fleet.Keeper_paused;
      paused = true;
      keepalive_running = false;
      activation_mode = Wire_fleet.Activation_manual;
      runtime_id = "local-qwen";
      model_id = None;
      current_task_id = None;
      context = Observed.unreported;
      total_turns = Observed.value ~observed_at:now_mono 44;
      last_turn_at_unix = None;
      active_turn = None;
    };
  ]

let sample_goals : Wire_work.goal list =
  [
    {
      id = "goal-overhaul";
      title = "MASC Core Architecture Overhaul";
      phase = Wire_work.Executing;
      priority = 1;
      due_date = Some "2026-12-01";
      measure = "3 Native Stacks merged and verified on main";
      procedure =
        "Inspect board:p-55f0c859abcdef and github:jeong-sik/masc/pulls confirming all stacks pass review.";
      criterion_revision = Some "rev-2";
      criterion_verdict = Wire_work.Criterion_valid;
      last_review_note = Some "Stacks 1 and 2 merged cleanly";
      last_review_at = Some "2026-11-21T18:00:00Z";
      created_at = Some "2026-11-18T00:00:00Z";
      updated_at = Some "2026-11-21T19:00:00Z";
      linked_task_count = Observed.value ~observed_at:now_mono 2;
    };
    {
      id = "goal-runtime";
      title = "OpenAI gpt-6.2 Sol Runtime";
      phase = Wire_work.Awaiting_confirmation;
      priority = 2;
      due_date = None;
      measure = "8/8 provider bindings passing probe";
      procedure = "Check board:p-991122334455 for final probe proof.";
      criterion_revision = Some "rev-1";
      criterion_verdict = Wire_work.Criterion_invalid "1 binding missing evidence";
      last_review_note = Some "Verifier refuted earlier run";
      last_review_at = Some "2026-11-21T17:00:00Z";
      created_at = Some "2026-11-15T00:00:00Z";
      updated_at = Some "2026-11-21T17:30:00Z";
      linked_task_count = Observed.value ~observed_at:now_mono 0;
    };
    {
      id = "goal-tui-r6";
      title = "TUI V2 Round 6 Polish";
      phase = Wire_work.Completed;
      priority = 3;
      due_date = None;
      measure = "Zero P0/P1 findings";
      procedure = "Verify release checklist";
      criterion_revision = Some "rev-3";
      criterion_verdict = Wire_work.Criterion_valid;
      last_review_note = None;
      last_review_at = None;
      created_at = None;
      updated_at = None;
      linked_task_count = Observed.value ~observed_at:now_mono 0;
    };
  ]

let sample_tasks : Wire_work.task list =
  [
    {
      id = "task-3898";
      title = "Clockwork fault isolation & 3-tier cache";
      description = Some "See board:p-55f0c859abcdef for design invariants.";
      priority = 1;
      status =
        Wire_work.AwaitingVerification
          {
            assignee = "e-masc-the-leader";
            started_at = "2026-11-20T09:15:00Z";
            submitted_at = "2026-11-21T18:45:00Z";
            verification_id = "verif-901";
          };
      goal_link = Wire_work.Linked "goal-overhaul";
      created_at = Some "2026-11-20T09:00:00Z";
      updated_at = Some "2026-11-21T18:45:00Z";
    };
    {
      id = "task-3899";
      title = "Unified persistent ACP v1 multi-runtime";
      description = Some "Implement persistent ACP channels.";
      priority = 1;
      status =
        Wire_work.Done
          {
            assignee = "code-reviewer";
            completed_at = "2026-11-21T12:00:00Z";
            notes = Some "All Alcotests green";
          };
      goal_link = Wire_work.Linked "goal-overhaul";
      created_at = Some "2026-11-19T08:00:00Z";
      updated_at = Some "2026-11-21T12:00:00Z";
    };
    {
      id = "task-3900";
      title = "Living evolutionary memory & Librarian v2";
      description = None;
      priority = 2;
      status =
        Wire_work.InProgress
          { assignee = "wkbl-growth"; started_at = "2026-11-21T11:30:00Z" };
      goal_link = Wire_work.Unlinked;
      created_at = Some "2026-11-21T11:00:00Z";
      updated_at = Some "2026-11-21T18:00:00Z";
    };
    {
      id = "task-3901";
      title = "Audit unlinked backlog tasks";
      description = None;
      priority = 3;
      status = Wire_work.Todo;
      goal_link = Wire_work.Unlinked;
      created_at = None;
      updated_at = None;
    };
  ]

let sample_verifications : Wire_work.verification_request list =
  [
    {
      request_id = "verif-901";
      task_id = "task-3898";
      task_title = "Clockwork fault isolation & 3-tier cache";
      submitted_by = "e-masc-the-leader";
      created_at_unix = Some (now_unix -. 600.0);
      completion_contract = [ "Unit tests pass"; "No race conditions" ];
      required_artifacts = [ "alcotest-report.txt"; "bench-proof.md" ];
      submitted_evidence = [ "alcotest-report.txt: 42/42 PASS" ];
      evidence_projection_error = Some "bench-proof.md missing";
      review_observation =
        Some
          {
            state = Wire_work.Review_rejected;
            detail = "Missing bench-proof.md artifact";
            actor = "verifier_exact";
          };
    };
  ]

let sample_schedules : Wire_work.schedule_row list =
  [
    {
      schedule_instance_id = "si-1";
      schedule_id = "sched-wkbl-daily";
      status = Wire_work.Sched_scheduled;
      source = "keeper.toml";
      due_at_unix = now_unix +. 3600.0;
      next_due_at_unix = Some (now_unix +. 3600.0);
      recurrence_kind = "cron";
      recurrence_summary = "daily 18:00";
      payload_kind = Some "prompt";
      payload_support = "supported";
      payload_target = Some "wkbl-growth";
      payload_keeper_name = Some "wkbl-growth";
      payload_summary = Some "Published daily traffic digest (3,120 visits)";
      last_wake_unix = Some (now_unix -. 86400.0);
      last_disposition = Wire_work.Wake_succeeded;
    };
    {
      schedule_instance_id = "si-2";
      schedule_id = "sched-leader-patrol";
      status = Wire_work.Sched_failed;
      source = "keeper.toml";
      due_at_unix = now_unix -. 300.0;
      next_due_at_unix = None;
      recurrence_kind = "interval";
      recurrence_summary = "every 30m";
      payload_kind = Some "prompt";
      payload_support = "supported";
      payload_target = Some "e-masc-the-leader";
      payload_keeper_name = Some "e-masc-the-leader";
      payload_summary = Some "PR stack patrol check";
      last_wake_unix = Some (now_unix -. 300.0);
      last_disposition = Wire_work.Wake_failed (Some "GitHub API 503");
    };
  ]

let sample_asks : Wire_work.ask_row list =
  [
    {
      ask_id = "ask-54340";
      keeper = "e-masc-the-leader";
      asked_at = now_unix -. 120.0;
      context = Some "Native Stack #54340 has 4/4 layers approved.";
      questions =
        [
          {
            question_id = "q1";
            header = "Merge Native Stack #54340?";
            prompt = "Check board:p-55f0c859abcdef and choose merge action.";
            mode = Wire_work.Ask_single;
            allow_free_text = true;
            free_text_hint = Some "Optional note";
            choices =
              [
                { choice_id = "c1"; label = "Merge now"; description = Some "Squash-merge full stack" };
                { choice_id = "c2"; label = "Hold"; description = Some "Wait for next window" };
                { choice_id = "c3"; label = "Request changes"; description = None };
              ];
          };
        ];
      resolution = Wire_work.Ask_open;
    };
  ]

let sample_tool_approvals : Wire_work.held_tool_approval list =
  [
    {
      approval_id = "ta-1";
      tool_call_id = "tc-1";
      keeper = "wkbl-growth";
      tool = "bash_exec";
      args_preview = {|{"cmd":"dune build","api_key":"sk-live-secret999"}|};
      question = "Approve running build command inside remote SSH pool?";
      because = Some "Workspace write boundary";
      asked_at = now_unix -. 30.0;
      timeout_sec = 300.0;
    };
  ]

let sample_candle_ledger : Wire_work.candle_ledger =
  {
    ledger_state = Wire_work.Ledger_present;
    total_events = 3;
    balance_error = None;
    policy_configuration = "decay_enabled";
    pricing_mode = "fixed";
    disabled_reason = None;
    half_life_sec = Some 604800.0;
    issued_milli = "15000";
    burned_milli = "2600";
    circulating_milli = "12400";
    total_supply_milli = "12400";
    active_keepers = 2;
    diagnostics =
      {
        unattributed_count = 3;
        backlog_fenced_count = 3;
        zero_linked_tasks_goals = 2;
        held_windows_count = 0;
      };
    balances =
      [
        {
          keeper = "e-masc-the-leader";
          balance_milli = 10000;
          decayed_milli = "8400";
          last_event_unix = Some (now_unix -. 3600.0);
          owned_items = [ "golden-crown"; "lantern-badge" ];
        };
        {
          keeper = "code-reviewer";
          balance_milli = 5000;
          decayed_milli = "4000";
          last_event_unix = Some (now_unix -. 7200.0);
          owned_items = [ "monocle" ];
        };
      ];
    recent_events =
      [
        {
          seq = 1;
          at_unix = now_unix -. 7200.0;
          kind =
            Wire_work.Candle_paid
              {
                goal_id = "goal-overhaul";
                total_milli = 10000;
                allocations =
                  [ { keeper = "e-masc-the-leader"; amount_milli = 10000; weight = 1 } ];
              };
        };
        {
          seq = 2;
          at_unix = now_unix -. 5400.0;
          kind =
            Wire_work.Candle_equipped
              { keeper = "e-masc-the-leader"; slot = "head"; choice = "golden-crown" };
        };
        {
          seq = 3;
          at_unix = now_unix -. 1800.0;
          kind =
            Wire_work.Candle_unattributed
              {
                goal_id = "goal-tui-r6";
                reason = "backlog_fenced";
                observation = "0 linked tasks";
                diagnostic_hint = Some "Link tasks to Goal before completion";
              };
        };
      ];
  }

let sample_metrics_24h : Wire_infra.tool_metrics_24h =
  {
    calls = 148;
    failures = 5;
    failure_unclassified = 0;
    p50_ms = Observed.value ~observed_at:now_mono 18.4;
    p95_ms = Observed.value ~observed_at:now_mono 94.2;
    max_ms = Observed.value ~observed_at:now_mono 410.0;
    failure_classes =
      {
        dependency_unavailable = 2;
        runtime_failure = 1;
        policy_rejection = 1;
        workflow_rejection = 1;
        operator_cancelled = 0;
      };
  }

let sample_sandboxes : Wire_infra.sandboxes_snapshot =
  {
    probe_state = Wire_infra.Probe_fresh now_unix;
    microvm_declared = 19;
    microvm_running = 15;
    microvm_sockets_present = 15;
    microvm_shim_mismatch = 1;
    ssh_pools_count = 2;
    ssh_keepers_count = 13;
    ssh_unbound_keepers_count = 0;
    ssh_active_sessions = Observed.value ~observed_at:now_mono 6;
    ssh_max_sessions = 24;
    docker_keepers_count = 0;
    microvm_guests =
      [
        {
          keeper = "e-masc-the-leader";
          backend = "apple_container";
          guest_name = "vm-leader";
          presence = "running";
          agent_socket = Wire_infra.Socket_present { path_basename = Some "agent.sock" };
          shim_parity = Wire_infra.Shim_matched "v0.77.1";
          network_mode = Wire_infra.Net_policy;
          cpus = Observed.value ~observed_at:now_mono 4;
          memory_mib = Observed.value ~observed_at:now_mono 4096;
          volume = Wire_infra.Volume_declared "ext4-leader-ok";
          metrics_24h = sample_metrics_24h;
        };
      ];
    ssh_pools =
      [
        {
          pool_name = "apple-wkbl-team-runtime";
          host = "127.0.0.1";
          port = 22268;
          unix_user = "wkbl";
          remote_root = "/srv/wkbl";
          private_home = true;
          max_sessions = 8;
          active_sessions = Observed.value ~observed_at:now_mono 3;
          reachability =
            Wire_infra.Ssh_reachable { rtt_ms = 22.0; measured_at_unix = now_unix };
          accounts = [];
          keeper_sessions =
            [
              {
                keeper = "wkbl-growth";
                last_dispatch =
                  `Assoc [ ("tool", `String "git_status"); ("ms", `Int 42) ];
                metrics_24h = sample_metrics_24h;
              };
            ];
          metrics_24h = sample_metrics_24h;
        };
      ];
    ssh_unbound_keepers = [];
    docker_keepers = [];
    fleet_metrics_24h = sample_metrics_24h;
    volume_gc_report = None;
    host_storage = None;
    unobserved_reasons = [];
  }

let sample_memory_diff : Wire_knowledge.memory_diff =
  let make_fact ~id ~cat ~text ~heat ~hits =
    {
      event_order = None;
      Wire_knowledge.added_at_rev = Some 3820;
      memory_id = id;
      category = cat;
      origin = "turn:3588";
      text;
      first_seen_unix = now_unix -. 7200.0;
      last_seen_unix = Some (now_unix -. 600.0);
      retrieval_count = hits;
      last_retrieved_at_unix = Some (now_unix -. 300.0);
      heat;
    }
  in
  {
    scope = Wire_knowledge.Scope_keeper "e-masc-the-leader";
    range =
      {
        window = Some "24h";
        from_rev = Some 3794;
        to_rev = Some 3828;
        from_unix = Some (now_unix -. 86400.0);
        to_unix = Some now_unix;
      };
    retrieval_heat =
      {
        hot = 12;
        warm = 8;
        cold = 3;
        never_retrieved = 1;
        total_events = 1186;
        unreadable_event_lines = 0;
      };
    body =
      Wire_knowledge.Keeper_diff
        {
          counts =
            {
              total_facts_now = 313;
              added = 1;
              updated = 1;
              retracted = 1;
              invalidated = 0;
              journal_failures_in_window = 0;
              journal_quarantines_in_window = 0;
              undecodable_journal_lines = 0;
              history_coverage = None;
            };
          revisions =
            [
              {
                rev = 3828;
                at_unix = now_unix -. 600.0;
                source = "librarian";
                added = 1;
                removed = 1;
                invalidated = 0;
              };
            ];
          added =
            [
              make_fact ~id:"m1" ~cat:"constraint"
                ~text:"Check full Native Stack draft/approval state before ready"
                ~heat:Wire_knowledge.Heat_hot ~hits:12;
            ];
          updated =
            [
              {
                relation = Wire_knowledge.Revision;
                after_source = None;
                event_order = None;
                at_rev = Some 3825;
                at_unix = None;
                before =
                  make_fact ~id:"m2-old" ~cat:"lesson"
                    ~text:"Run full local dune build before push"
                    ~heat:Wire_knowledge.Heat_warm ~hits:4;
                after =
                  make_fact ~id:"m2-new" ~cat:"lesson"
                    ~text:"Use targeted minimal checks per constitution"
                    ~heat:Wire_knowledge.Heat_warm ~hits:5;
              };
            ];
          retracted =
            [
              {
                memory_id = "m3";
                category = "fact";
                text = "Legacy endpoint active";
                event_order = None;
                removed_at_rev = Some 3822;
                at_unix = None;
                removed_by = Some "librarian";
                drop_reason = Some "superseded";
              };
            ];
          invalidated = [];
          writer_status =
            Some
              (Wire_knowledge.Keeper_writer_active
                 {
                   state = Wire_knowledge.Writer_open;
                   available_act_tokens = [ "resume"; "adopt" ];
                   snapshot_file = None;
                 });
        };
  }

let sample_keeper_schema ~name : Wire_config.config_schema =
  {
    target = Wire_config.Target_keeper name;
    keeper = Some name;
    file_exists = true;
    file_sha256 = "abc123";
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
                key = "group";
                full_key = "keeper.group";
                label = "Company Group";
                env = None;
                description = Some "Operational company grouping";
                kind = Wire_config.Field_string;
                value = Wire_config.Val_string "MASC Core Eng";
                default_value = None;
                provenance = Wire_config.Prov_keeper;
                reload_scope = Wire_config.Hot_reload;
                secret = false;
                writable = true;
              };
              {
                table = "keeper";
                key = "activation";
                full_key = "keeper.activation";
                label = "Activation";
                env = None;
                description = None;
                kind =
                  Wire_config.Field_enum
                    [ "autonomous"; "on_demand"; "manual" ];
                value = Wire_config.Val_string "autonomous";
                default_value = None;
                provenance = Wire_config.Prov_keeper;
                reload_scope = Wire_config.Next_turn;
                secret = false;
                writable = true;
              };
              {
                table = "keeper";
                key = "github_token";
                full_key = "keeper.github_token";
                label = "GitHub Token";
                env = Some "KEEPER_GH_PAT";
                description = None;
                kind = Wire_config.Field_secret;
                value =
                  Wire_config.Val_secret
                    {
                      configured = true;
                      source = Wire_config.Secret_env "KEEPER_GH_PAT";
                    };
                default_value = None;
                provenance = Wire_config.Prov_env_override;
                reload_scope = Wire_config.Restart_required;
                secret = true;
                writable = false;
              };
            ];
        };
      ];
  }

let make_populated_model ~cols ~rows ~lang =
  let m0 = Model.initial ~cols ~rows ~lang () in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_keepers ~observed_at:now_mono sample_keepers
    |> Fleet_store.select_keeper "e-masc-the-leader"
    |> Fleet_store.apply_chat_history ~observed_at:now_mono
         ~keeper:"e-masc-the-leader"
         {
           messages =
             [
               {
                 id = "msg-1";
                 role = Wire_fleet.Role_system;
                 content = "3-Stack Native Overhaul started";
                 ts_unix = now_unix -. 900.0;
                 turn_ref = None;
                 model_used = None;
                 tool_call_id = None;
                 tool_call_name = None;
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
               {
                 id = "msg-2";
                 role = Wire_fleet.Role_user;
                 content = "Check stack #54340 verification status";
                 ts_unix = now_unix -. 300.0;
                 turn_ref = Some "t-100";
                 model_used = None;
                 tool_call_id = None;
                 tool_call_name = None;
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
               {
                 id = "msg-3";
                 role = Wire_fleet.Role_tool;
                 content = "3 files (+45 -12)";
                 ts_unix = now_unix -. 280.0;
                 turn_ref = Some "t-100";
                 model_used = None;
                 tool_call_id = Some "tc-99";
                 tool_call_name = Some "git_diff";
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
               {
                 id = "msg-4";
                 role = Wire_fleet.Role_assistant;
                 content =
                   "All 4 layers are approved.\n```ocaml\nlet ready = true\n```";
                 ts_unix = now_unix -. 240.0;
                 turn_ref = Some "t-100";
                 model_used = Some "claude-sonnet-4-6";
                 tool_call_id = None;
                 tool_call_name = None;
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
             ];
           has_more = false;
           next_cursor = None;
         }
    |> Fleet_store.start_chat_stream ~keeper:"e-masc-the-leader"
         ~request_id:"req-live-1"
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"e-masc-the-leader"
         ~request_id:"req-live-1"
         (Wire_fleet.Chunk_thinking_delta
            { operation_id = Some "op-1"; delta = "Checking head commit and approvals..."; owner = None })
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"e-masc-the-leader"
         ~request_id:"req-live-1"
         (Wire_fleet.Chunk_tool_start
            {
              operation_id = Some "op-1";
              tool_use_id = "tu-1";
              stream_scope = None;
              tool_name = "gh_pr_view";
              args_preview = Some "#54340";
            })
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"e-masc-the-leader"
         ~request_id:"req-live-1"
         (Wire_fleet.Chunk_tool_end
            {
              operation_id = Some "op-1";
              tool_use_id = "tu-1";
              tool_name = Some "gh_pr_view";
              ok = Some true;
              output_preview = Some "state=OPEN reviewDecision=APPROVED";
            })
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"e-masc-the-leader"
         ~request_id:"req-live-1"
         (Wire_fleet.Chunk_text_delta
            {
              operation_id = Some "op-1";
              delta = "Confirmed head SHA matches.";
              owner = Wire_chat_journal.Unobserved_scope None;
            })
  in
  let fleet =
    Fleet_store.apply_shell ~observed_at:now_mono
      {
        generated_at_unix = Some now_unix;
        project = Some "masc";
        version = Some "0.77.1";
        counts =
          {
            agents = 4;
            tasks = 4;
            tasks_done_24h = 34;
            keepers = 4;
            persisted_keepers = Observed.value ~observed_at:now_mono 4;
            configured_keepers = Observed.value ~observed_at:now_mono 4;
            total_runtimes = 177;
          };
        scorecard_24h =
          {
            tasks_done_24h = Observed.value ~observed_at:now_mono 34;
            tasks_done_total = Observed.value ~observed_at:now_mono 707;
            tasks_in_progress = Observed.value ~observed_at:now_mono 12;
            tasks_claimed = Observed.value ~observed_at:now_mono 4;
            tasks_awaiting_verification = Observed.value ~observed_at:now_mono 2;
            tasks_todo = Observed.value ~observed_at:now_mono 18;
            tasks_cancelled = Observed.value ~observed_at:now_mono 1;
            goals_completed_24h = Observed.value ~observed_at:now_mono 3;
            verifications_passed_24h = Observed.value ~observed_at:now_mono 31;
            verifications_rejected_24h = Observed.value ~observed_at:now_mono 3;
            board_posts_24h = Observed.value ~observed_at:now_mono 19;
            turns_24h = Observed.value ~observed_at:now_mono 412;
            cost_24h_usd = Observed.value ~observed_at:now_mono 108.78;
          };
        groups = [];
      }
      fleet
  in
  (* Add an honest pending transmission in Drafts for e-masc-the-leader *)
  let drafts =
    m0.drafts
    |> Drafts.set_active_keeper "e-masc-the-leader"
    |> Drafts.insert_text "Proceed with merge after checks"
  in
  let drafts =
    match
      Drafts.enqueue_submission ~now:now_mono ~keeper:"e-masc-the-leader"
        ~mode:Drafts.Mode_steer drafts
    with
    | Some (d, tx) -> Drafts.mark_sending ~now:now_mono ~request_id:tx.request_id d
    | None -> drafts
  in
  (* Add resolved historical incidents on healthy keeper e-masc-the-leader *)
  let incidents, _ =
    Incidents.push ~occurred_at_unix:(now_unix -. 14400.0)
      ~source:(Health.Source_keeper "e-masc-the-leader")
      ~summary:(Say.make ~ko:"12시간 전 메모리 타임아웃 복구" ~en:"12h ago memory timeout recovered")
      ~detail:"transient timeout recovered"
      ~status:Health.Resolved m0.incidents
  in
  let incidents, _ =
    Incidents.push ~occurred_at_unix:(now_unix -. 7200.0)
      ~source:(Health.Source_keeper "e-masc-the-leader")
      ~summary:(Say.make ~ko:"과거 429 재시도" ~en:"Past 429 retry")
      ~detail:"retried cleanly" ~status:Health.Retried incidents
  in
  let work =
    m0.work
    |> Work_store.apply_planning ~observed_at:now_mono
         { goals = sample_goals; tasks = sample_tasks }
    |> Work_store.apply_verifications ~observed_at:now_mono sample_verifications
    |> Work_store.apply_schedules ~observed_at:now_mono (sample_schedules, None)
    |> Work_store.apply_asks ~observed_at:now_mono sample_asks
    |> Work_store.apply_tool_approvals ~observed_at:now_mono sample_tool_approvals
    |> Work_store.apply_candle_ledger ~observed_at:now_mono sample_candle_ledger
    |> Work_store.record_decision ~at_unix:(now_unix -. 1800.0)
         ~kind:Work_store.Decision_ask_answered ~target_id:"ask-prev-1"
         ~keeper:(Some "code-reviewer") ~summary:"Approved PR #54339"
  in
  let knowledge =
    m0.knowledge
    |> Knowledge_store.set_memory_diff ~keeper:(Some "e-masc-the-leader")
         ~window:Knowledge_store.Window_24h
         (Observed.value ~observed_at:now_mono sample_memory_diff)
    |> Knowledge_store.apply_board ~observed_at:now_mono
         {
           posts =
             [
               {
                 id = "p-55f0c859";
                 title = "3-Stack Native Overhaul";
                 body = "Kickoff";
                 author = "e-masc-the-leader";
                 hearth = Some "ops";
                 post_kind = Some Wire_knowledge.Automation_post;
                 visibility = Some Wire_knowledge.Vis_internal;
                 created_at_unix = now_unix -. 900.0;
                 updated_at_unix = None;
                 score = 5;
                 comment_count = 3;
                 author_karma = Observed.value ~observed_at:now_mono 42;
                 succession_chain_root_id = None;
                 chain_depth = None;
                 is_signal = true;
                 pinned = false;
               };
             ];
           count = 1;
           sort_by = "recent";
           signal_only = true;
         }
  in
  let infra =
    m0.infra
    |> Infra_store.apply_sandboxes ~observed_at:now_mono sample_sandboxes
    |> Infra_store.apply_log_snapshot
         [
           {
             seq = 1;
             ts = "19:55:01";
             level = Wire_infra.Log_info;
             source = "sandbox";
             module_name = "apple_container";
             message = "agent.sock healthy";
             keeper = Some "e-masc-the-leader";
             turn_id = Some 412;
             category = Some "sandbox";
             details = `Null;
           };
           {
             seq = 2;
             ts = "19:56:10";
             level = Wire_infra.Log_warn;
             source = "sandbox";
             module_name = "remote_ssh";
             message = "reconnecting channel";
             keeper = Some "wkbl-growth";
             turn_id = Some 288;
             category = Some "sandbox";
             details = `Null;
           };
         ]
  in
  let config =
    m0.config
    |> Config_store.set_target (Wire_config.Target_keeper "e-masc-the-leader")
    |> Config_store.apply_schema ~observed_at:now_mono
         (sample_keeper_schema ~name:"e-masc-the-leader")
    |> Config_store.stage_patch ~full_key:"keeper.group"
         (Wire_config.Set_scalar
            { table = "keeper"; key = "group"; value = "MASC Platform" })
    |> Config_store.apply_patch_response ~dry_run:true
         {
           applied = false;
           dry_run = true;
           target = "keeper:e-masc-the-leader";
           changed = true;
           before_sha256 = "abc123";
           new_sha256 = "def456";
           snapshot_id = None;
           snapshot_path = None;
           reload_scope = Wire_config.Hot_reload;
           unified_diff = "-group = \"MASC Core Eng\"\n+group = \"MASC Platform\"";
           diff_hunks = [];
           validation_warnings = [];
         }
  in
  { m0 with fleet; drafts; incidents; work; knowledge; infra; config }
  |> Model.rebuild_attention

let render_to_grid ~cols ~rows fn =
  let grid = Cell_grid.create ~cols ~rows in
  let cache = Card.Cache.create () in
  let rect = Rect.make ~x:0 ~y:0 ~w:cols ~h:rows in
  fn ~cache ~rect grid;
  grid

(* --- Tests --- *)

let test_keepers_all_modes_viewports_langs () =
  let viewports = [ (140, 40); (90, 28) ] in
  let langs = [ Say.Lang_ko; Say.Lang_en ] in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun lang ->
          List.iter
            (fun mode ->
              let m = make_populated_model ~cols ~rows ~lang in
              let m = { m with fleet = Fleet_store.set_fleet_mode mode m.fleet } in
              let grid =
                render_to_grid ~cols ~rows (Screen_keepers.render ~model:m)
              in
              let populated = non_empty_row_count grid in
              Alcotest.(check bool)
                (Printf.sprintf "Keepers %dx%d populated (got %d)" cols rows populated)
                true (populated >= 10);
              let text = grid_all_text grid in
              Alcotest.(check bool) "contains keeper name" true
                (contains_sub ~needle:"e-masc-the-leader" text);
              Alcotest.(check bool) "contains failing keeper" true
                (contains_sub ~needle:"wkbl-growth" text))
            Nav.all_keepers_fleet_modes)
        langs)
    viewports

let test_keepers_strict_live_vs_historical_separation () =
  (* e-masc-the-leader is Keeper_healthy, has ZERO Channel 1 attention when we
     clear asks, and has 2 resolved historical incidents in model.incidents.
     Its live glyph MUST remain ● (Live_healthy) and NEVER ✕ (Live_failing),
     while its historical trail MUST surface strictly as muted ◂2. *)
  let m = make_populated_model ~cols:90 ~rows:28 ~lang:Say.Lang_en in
  let m =
    {
      m with
      attention = Attention.empty;
      fleet = Fleet_store.set_fleet_mode Nav.Fleet_attention m.fleet;
    }
  in
  let grid = render_to_grid ~cols:90 ~rows:28 (Screen_keepers.render ~model:m) in
  let leader_row =
    let rec find y =
      if y >= 28 then None
      else
        let txt = grid_row_text grid ~y in
        if contains_sub ~needle:"e-masc-the-leader" txt then Some (y, txt)
        else find (y + 1)
    in
    find 0
  in
  match leader_row with
  | None -> Alcotest.fail "Expected e-masc-the-leader row in roster"
  | Some (_, row_txt) ->
      Alcotest.(check bool) "healthy keeper shows ● live glyph" true
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Live_healthy) row_txt);
      Alcotest.(check bool) "healthy keeper never shows ✕ from past incidents" false
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Live_failing) row_txt);
      Alcotest.(check bool) "past incidents appear strictly as muted ◂2 trail" true
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Recovered ^ " 2") row_txt
         || contains_sub ~needle:(Glyph.to_utf8 Glyph.Recovered ^ "2") row_txt)

let test_keeper_dive_all_5_tabs () =
  let viewports = [ (140, 40); (90, 28) ] in
  let langs = [ Say.Lang_ko; Say.Lang_en ] in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun lang ->
          let m = make_populated_model ~cols ~rows ~lang in
          List.iter
            (fun tab ->
              let m_tab =
                match tab with
                | Nav.Keeper_memory ->
                    {
                      m with
                      knowledge =
                        Knowledge_store.set_memory_view_mode
                          Knowledge_store.View_diff m.knowledge;
                    }
                | Nav.Keeper_chat
                | Nav.Keeper_context
                | Nav.Keeper_tool_calls
                | Nav.Keeper_work_candle
                | Nav.Keeper_sandbox
                | Nav.Keeper_config
                | Nav.Keeper_logs
                | Nav.Keeper_identity ->
                    m
              in
              let grid =
                render_to_grid ~cols ~rows
                  (Screen_keepers.render_dive ~name:"e-masc-the-leader" ~tab ~model:m_tab)
              in
              let populated = non_empty_row_count grid in
              Alcotest.(check bool)
                (Printf.sprintf "Keeper Dive %dx%d populated" cols rows)
                true (populated >= 8);
              let text = grid_all_text grid in
              match tab with
              | Nav.Keeper_chat ->
                  Alcotest.(check bool) "shows thinking fold" true
                    (contains_sub ~needle:"tok" text);
                  Alcotest.(check bool) "shows tool card" true
                    (contains_sub ~needle:"gh_pr_view" text);
                  let expected_tx =
                    match lang with Say.Lang_ko -> "전송 중" | Say.Lang_en -> "Sending"
                  in
                  Alcotest.(check bool) "shows honest pending tx state" true
                    (contains_sub ~needle:expected_tx text)
              | Nav.Keeper_context ->
                  Alcotest.(check bool) "renders Context & Turns inspector" true
                    (contains_sub ~needle:"Composition" text
                     || contains_sub ~needle:"구성" text
                     || contains_sub ~needle:"Context" text
                     || contains_sub ~needle:"컨텍스트" text)
              | Nav.Keeper_tool_calls ->
                  Alcotest.(check bool) "renders Tool Calls inspector" true
                    (contains_sub ~needle:"Tool" text
                     || contains_sub ~needle:"도구" text)
              | Nav.Keeper_memory ->
                  Alcotest.(check bool) "shows HOT heat" true
                    (contains_sub ~needle:"HOT" text);
                  Alcotest.(check bool) "shows before->after updated lesson" true
                    (contains_sub ~needle:"constitution" text)
              | Nav.Keeper_work_candle ->
                  Alcotest.(check bool) "shows assigned task" true
                    (contains_sub ~needle:"task-3898" text);
                  Alcotest.(check bool) "shows portrait ornament" true
                    (contains_sub ~needle:"golden-crown" text)
              | Nav.Keeper_sandbox ->
                  Alcotest.(check bool) "shows microVM guest" true
                    (contains_sub ~needle:"apple_container" text);
                  Alcotest.(check bool) "shows sandbox log" true
                    (contains_sub ~needle:"agent.sock" text)
              | Nav.Keeper_config ->
                  Alcotest.(check bool) "never leaks raw secret" false
                    (contains_sub ~needle:"sk-live" text);
                  Alcotest.(check bool) "shows TOML diff preview" true
                    (contains_sub ~needle:"MASC Platform" text)
              | Nav.Keeper_logs ->
                  Alcotest.(check bool) "renders Keeper Logs tab" true
                    (contains_sub ~needle:"Metrics" text
                     || contains_sub ~needle:"Sandbox" text
                     || contains_sub ~needle:"Logs" text)
              | Nav.Keeper_identity ->
                  Alcotest.(check bool) "renders Keeper Identity tab" true
                    (contains_sub ~needle:"Identity" text
                     || contains_sub ~needle:"GitHub" text))
            Nav.all_keeper_tabs;
          (* Also verify remote_ssh keeper sandbox dive *)
          let ssh_grid =
            render_to_grid ~cols ~rows
              (Screen_keepers.render_dive ~name:"wkbl-growth"
                 ~tab:Nav.Keeper_sandbox ~model:m)
          in
          let ssh_txt = grid_all_text ssh_grid in
          Alcotest.(check bool) "shows remote_ssh pool" true
            (contains_sub ~needle:"apple-wkbl-team-runtime" ssh_txt))
        langs)
    viewports

let test_work_all_4_subtabs_and_empty_inbox () =
  let viewports = [ (140, 40); (90, 28) ] in
  let langs = [ Say.Lang_ko; Say.Lang_en ] in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun lang ->
          let m = make_populated_model ~cols ~rows ~lang in
          List.iter
            (fun tab ->
              let m_tab = { m with work = Work_store.set_tab tab m.work } in
              let grid =
                render_to_grid ~cols ~rows (Screen_work.render ~model:m_tab)
              in
              let populated = non_empty_row_count grid in
              Alcotest.(check bool)
                (Printf.sprintf "Work tab %dx%d populated (got %d)" cols rows populated)
                true (populated >= 10);
              let text = grid_all_text grid in
              match tab with
              | Nav.Work_pipeline ->
                  Alcotest.(check bool) "zero raw board:p-... strings" false
                    (contains_sub ~needle:"board:p-55f0c859" text);
                  Alcotest.(check bool) "interned OSC 8 hyperlinks" true
                    (has_any_hyperlink grid);
                  Alcotest.(check bool) "shows unlinked attribution warning" true
                    (contains_sub ~needle:"goal_id" text
                     || contains_sub ~needle:"backlog_fenced" text)
              | Nav.Work_tasks ->
                  Alcotest.(check bool) "shows started_at timestamp" true
                    (contains_sub ~needle:"started_at" text)
              | Nav.Work_schedules ->
                  Alcotest.(check bool) "shows schedule output summary" true
                    (contains_sub ~needle:"wkbl-growth" text
                     || contains_sub ~needle:"sched-" text)
              | Nav.Work_inbox ->
                  (* Top urgency item is Held Tool Approval with Json_tree redacting secret *)
                  Alcotest.(check bool) "redacts secret inside tool args Json_tree" false
                    (contains_sub ~needle:"sk-live-secret999" text);
                  Alcotest.(check bool) "shows bash_exec tool" true
                    (contains_sub ~needle:"bash_exec" text)
              | Nav.Work_candle_scorecard ->
                  Alcotest.(check bool) "shows root cause backlog_fenced" true
                    (contains_sub ~needle:"backlog_fenced" text);
                  Alcotest.(check bool) "shows portrait-accessories-only contract" true
                    (contains_sub ~needle:"portrait" text
                     || contains_sub ~needle:"초상화" text)
              | Nav.Work_harness ->
                  Alcotest.(check bool) "renders Work Harness Health view" true
                    (contains_sub ~needle:"Harness" text
                     || contains_sub ~needle:"하네스" text))
            Nav.all_work_tabs;
          (* Inbox with Ask selected shows 1..4 choices *)
          let m_ask =
            {
              m with
              work = Work_store.set_tab Nav.Work_inbox m.work;
              attention = Attention.select_triage_index 1 m.attention;
            }
          in
          let ask_grid =
            render_to_grid ~cols ~rows (Screen_work.render ~model:m_ask)
          in
          let ask_txt = grid_all_text ask_grid in
          Alcotest.(check bool) "shows [a] Merge now choice" true
            (contains_sub ~needle:"[a] Merge now" ask_txt);
          (* Empty Inbox renders Recent Decisions Audit (24h) + Policy Summary, never black void *)
          let m_empty_inbox =
            {
              m with
              work = Work_store.set_tab Nav.Work_inbox m.work;
              attention = Attention.empty;
            }
          in
          let empty_grid =
            render_to_grid ~cols ~rows (Screen_work.render ~model:m_empty_inbox)
          in
          let empty_rows = non_empty_row_count empty_grid in
          Alcotest.(check bool)
            (Printf.sprintf "Empty Inbox populated (got %d rows)" empty_rows)
            true (empty_rows >= 8);
          let empty_txt = grid_all_text empty_grid in
          Alcotest.(check bool) "empty inbox shows 24h recent decision audit" true
            (contains_sub ~needle:"Approved PR #54339" empty_txt);
          (* Ask choices are bound to a..d; bare 1..4 switch workspaces. *)
          Alcotest.(check bool) "empty inbox does not advertise 1..4 choices" false
            (contains_sub ~needle:"1..4" empty_txt))
        langs)
    viewports

let test_work_dives_and_json_tree () =
  let viewports = [ (140, 40); (90, 28) ] in
  let langs = [ Say.Lang_ko; Say.Lang_en ] in
  let targets =
    [
      Nav.Goal_dive "goal-overhaul";
      Nav.Task_dive "task-3898";
      Nav.Verification_dive "verif-901";
    ]
  in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun lang ->
          let m = make_populated_model ~cols ~rows ~lang in
          List.iter
            (fun target ->
              let g1 =
                render_to_grid ~cols ~rows
                  (Screen_work.render_dive ~target ~model:m)
              in
              Alcotest.(check bool) "work dive populated" true
                (non_empty_row_count g1 >= 8);
              let t1 = grid_all_text g1 in
              Alcotest.(check bool) "zero raw board:p-... in dive" false
                (contains_sub ~needle:"board:p-55f0c859" t1);
              (* Opt-in [J] Json_tree mode *)
              let m_j = { m with infra = Infra_store.toggle_raw_json m.infra } in
              let g2 =
                render_to_grid ~cols ~rows
                  (Screen_work.render_dive ~target ~model:m_j)
              in
              Alcotest.(check bool) "work dive with Json_tree populated" true
                (non_empty_row_count g2 >= 8);
              let t2 = grid_all_text g2 in
              Alcotest.(check bool) "Json_tree card header shown" true
                (contains_sub ~needle:"[Space]" t2))
            targets)
        langs)
    viewports

let count_sub ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 || n > h then 0
  else
    let rec loop i acc =
      if i + n > h then acc
      else if String.equal (String.sub haystack i n) needle then
        loop (i + n) (acc + 1)
      else loop (i + 1) acc
    in
    loop 0 0

let test_p1_scope_mismatch_memory_and_config () =
  let m = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  (* Memory diff in model is scoped to e-masc-the-leader; viewing wkbl-growth MUST NOT leak leader's facts or acts *)
  let mem_grid =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"wkbl-growth" ~tab:Nav.Keeper_memory
         ~model:m)
  in
  let mem_txt = grid_all_text mem_grid in
  Alcotest.(check bool) "scope mismatch hides other keeper facts" false
    (contains_sub ~needle:"Check full Native Stack" mem_txt);
  Alcotest.(check bool) "scope mismatch hides other keeper counts" false
    (contains_sub ~needle:"313 facts" mem_txt);
  Alcotest.(check bool) "scope mismatch hides other keeper writer acts" false
    (contains_sub ~needle:"[resume]" mem_txt);
  Alcotest.(check bool) "scope mismatch shows awaiting notice for wkbl-growth" true
    (contains_sub ~needle:"wkbl-growth" mem_txt);
  (* Config in model is Target_keeper e-masc-the-leader with 1 staged patch + dry_run diff; viewing wkbl-growth MUST NOT bleed dirty_n or diff *)
  let cfg_grid =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"wkbl-growth" ~tab:Nav.Keeper_config
         ~model:m)
  in
  let cfg_txt = grid_all_text cfg_grid in
  Alcotest.(check bool) "cross-target config hides other keeper dry-run diff" false
    (contains_sub ~needle:"MASC Platform" cfg_txt);
  Alcotest.(check bool) "cross-target config shows 0 staged" true
    (contains_sub ~needle:"0 staged" cfg_txt);
  (* Secret field with secret=false & kind=Field_secret + Set_scalar staged op MUST stay masked *)
  let sec_schema : Wire_config.config_schema =
    {
      target = Wire_config.Target_keeper "wkbl-growth";
      keeper = Some "wkbl-growth";
      file_exists = true;
      file_sha256 = "sha-sec";
      sections =
        [
          {
            id = "sec";
            category = Wire_config.Cat_keepers_companies;
            title = "Secrets";
            fields =
              [
                {
                  table = "keeper";
                  key = "api_token";
                  full_key = "keeper.api_token";
                  label = "API Token";
                  env = None;
                  description = None;
                  kind = Wire_config.Field_secret;
                  value =
                    Wire_config.Val_secret
                      { configured = true; source = Wire_config.Secret_inline_redacted };
                  default_value = None;
                  provenance = Wire_config.Prov_keeper;
                  reload_scope = Wire_config.Restart_required;
                  secret = false;
                  writable = false;
                };
              ];
          };
        ];
    }
  in
  let sec_cfg =
    Config_store.empty
    |> Config_store.set_target (Wire_config.Target_keeper "wkbl-growth")
    |> Config_store.apply_schema ~observed_at:now_mono sec_schema
    |> Config_store.stage_patch ~full_key:"keeper.api_token"
         (Wire_config.Set_scalar
            { table = "keeper"; key = "api_token"; value = "ghp_SHOULD_NOT_LEAK" })
  in
  let m_sec = { m with config = sec_cfg } in
  let sec_grid =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"wkbl-growth" ~tab:Nav.Keeper_config
         ~model:m_sec)
  in
  let sec_txt = grid_all_text sec_grid in
  Alcotest.(check bool) "Field_secret staged Set_scalar never leaks plaintext" false
    (contains_sub ~needle:"ghp_SHOULD_NOT_LEAK" sec_txt);
  Alcotest.(check bool) "configured Field_secret not rendered as (empty)" false
    (contains_sub ~needle:"(empty)" sec_txt)

let test_p1_chat_dedup_untyped_tool_and_code_bg () =
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  (* Finish stream with text identical to an already persisted assistant message *)
  let done_reply = "Final persisted answer #9001" in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_chat_history ~observed_at:now_mono
         ~keeper:"e-masc-the-leader"
         {
           messages =
             [
               {
                 id = "msg-tool";
                 role = Wire_fleet.Role_tool;
                 content = "tool_raw_output_only";
                 ts_unix = now_unix -. 60.0;
                 turn_ref = Some "t-200";
                 model_used = None;
                 tool_call_id = Some "tc-200";
                 tool_call_name = Some "hist_tool";
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
               {
                 id = "msg-asst";
                 role = Wire_fleet.Role_assistant;
                 content = done_reply;
                 ts_unix = now_unix -. 30.0;
                 turn_ref = Some "t-200";
                 model_used = Some "claude-sonnet-4-6";
                 tool_call_id = None;
                 tool_call_name = None;
                 execution_id = None;
                 provenance = operation_provenance "op-2" Terminal_result;
                 failure_kind = None;
                 thinking = None;
               };
               {
                 id = "msg-code";
                 role = Wire_fleet.Role_assistant;
                 content = "Code:\n```ocaml\nlet code_bg_check = 42\n```";
                 ts_unix = now_unix -. 10.0;
                 turn_ref = Some "t-201";
                 model_used = None;
                 tool_call_id = None;
                 tool_call_name = None;
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
             ];
           has_more = false;
           next_cursor = None;
         }
    |> Fleet_store.start_chat_stream ~keeper:"e-masc-the-leader" ~request_id:"req-done"
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"e-masc-the-leader"
         ~request_id:"req-done"
         (Wire_fleet.Chunk_turn_done
            {
              operation_id = Some "op-2";
              turn_ref = Some "t-200";
              reply = Some done_reply;
            })
  in
  let m = { m0 with fleet } in
  let grid =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"e-masc-the-leader" ~tab:Nav.Keeper_chat
         ~model:m)
  in
  let txt = grid_all_text grid in
  Alcotest.(check int) "completed stream reply deduplicated against persisted history"
    1 (count_sub ~needle:done_reply txt);
  (* Untyped Role_tool history row must NOT stamp ● *)
  let tool_row =
    let rec find y =
      if y >= 40 then None
      else
        let r = grid_row_text grid ~y in
        if contains_sub ~needle:"hist_tool" r then Some r else find (y + 1)
    in
    find 0
  in
  (match tool_row with
  | None -> Alcotest.fail "Expected hist_tool row"
  | Some r ->
      Alcotest.(check bool) "untyped Role_tool history row does not fabricate ●" false
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Live_healthy) r));
  (* Fenced code block preserves Markdown surface_0 background instead of surface_1 *)
  let theme = Theme.of_preset m.theme_preset in
  let code_cell_has_surface0 =
    let found = ref false in
    for y = 0 to 39 do
      let r = grid_row_text grid ~y in
      if contains_sub ~needle:"code_bg_check" r then
        for x = 0 to 139 do
          let c = Cell_grid.get grid ~x ~y in
          if Color.equal c.style.bg (Color.of_rgb theme.surface_0) then
            found := true
        done
    done;
    !found
  in
  Alcotest.(check bool) "fenced code block keeps surface_0 background" true
    code_cell_has_surface0

let test_p1_inbox_truncated_secrets_scrubbed () =
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let render_preview args_preview =
    let approval : Wire_work.held_tool_approval =
      {
        approval_id = "ta-sec";
        tool_call_id = "tc-sec";
        keeper = "wkbl-growth";
        tool = "bash_exec";
        args_preview;
        question = "Approve command?";
        because = None;
        asked_at = now_unix -. 5.0;
        timeout_sec = 60.0;
      }
    in
    let m =
      {
        m0 with
        work =
          m0.work
          |> Work_store.apply_tool_approvals ~observed_at:now_mono [ approval ]
          |> Work_store.set_tab Nav.Work_inbox;
      }
      |> Model.rebuild_attention
    in
    grid_all_text (render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m))
  in
  (* 1. Valid JSON: separate short fields so every value fits well inside the right pane *)
  let v_txt =
    render_preview
      {|{"h1":"Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig OK1","h2":"Authorization: Basic dXNlcjpwYXNz OK2","h3":"Authorization: Token tok_val_42 OK3","h4":"k=sk_live_valid987654 OK4","h5":"-----BEGIN RSA PRIVATE KEY-----\nMIIEValidPemSecret\n-----END RSA PRIVATE KEY----- OK5"}|}
  in
  Alcotest.(check bool) "valid JSON: OK1 visible after Bearer redaction" true
    (contains_sub ~needle:"OK1" v_txt);
  Alcotest.(check bool) "valid JSON: OK2 visible after Basic redaction" true
    (contains_sub ~needle:"OK2" v_txt);
  Alcotest.(check bool) "valid JSON: OK3 visible after Token redaction" true
    (contains_sub ~needle:"OK3" v_txt);
  Alcotest.(check bool) "valid JSON: OK4 visible after sk_live_ redaction" true
    (contains_sub ~needle:"OK4" v_txt);
  Alcotest.(check bool) "valid JSON: OK5 visible after PEM redaction" true
    (contains_sub ~needle:"OK5" v_txt);
  Alcotest.(check bool) "valid JSON: no Bearer JWT leak" false
    (contains_sub ~needle:"eyJhbGciOiJIUzI1NiJ9" v_txt);
  Alcotest.(check bool) "valid JSON: no Basic base64 leak" false
    (contains_sub ~needle:"dXNlcjpwYXNz" v_txt);
  Alcotest.(check bool) "valid JSON: no Token cred leak" false
    (contains_sub ~needle:"tok_val_42" v_txt);
  Alcotest.(check bool) "valid JSON: no Stripe sk_live_ leak" false
    (contains_sub ~needle:"sk_live_valid987654" v_txt);
  Alcotest.(check bool) "valid JSON: no PEM private key body leak" false
    (contains_sub ~needle:"MIIEValidPemSecret" v_txt);
  Alcotest.(check bool) "valid JSON: shows redacted placeholder" true
    (contains_sub ~needle:"[redacted]" v_txt);
  (* 2. Truncated invalid JSON: short individual previews so each secret is within visible cols *)
  let t1 =
    render_preview {|{"cmd":"Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.trunc.sig T1|}
  in
  Alcotest.(check bool) "truncated Bearer: T1 visible" true (contains_sub ~needle:"T1" t1);
  Alcotest.(check bool) "truncated Bearer: no JWT leak" false
    (contains_sub ~needle:"eyJhbGci" t1);
  Alcotest.(check bool) "truncated Bearer: shows [redacted]" true
    (contains_sub ~needle:"[redacted]" t1);
  let t2 =
    render_preview {|{"cmd":"Authorization: Basic dXNlcjpwYXNz T2|}
  in
  Alcotest.(check bool) "truncated Basic: T2 visible" true (contains_sub ~needle:"T2" t2);
  Alcotest.(check bool) "truncated Basic: no base64 leak" false
    (contains_sub ~needle:"dXNlcjpwYXNz" t2);
  let t3 =
    render_preview {|{"url":"https://admin:topsecret@ex.io","k":"sk_live_trunc987|}
  in
  Alcotest.(check bool) "truncated URL/Stripe: ex.io visible" true
    (contains_sub ~needle:"ex.io" t3);
  Alcotest.(check bool) "truncated URL/Stripe: no password leak" false
    (contains_sub ~needle:"topsecret" t3);
  Alcotest.(check bool) "truncated URL/Stripe: no sk_live_ leak" false
    (contains_sub ~needle:"sk_live_trunc987" t3);
  let t4 =
    render_preview {|{"pem":"-----BEGIN PRIVATE KEY-----\nMIIETruncPemLeak|}
  in
  Alcotest.(check bool) "truncated PEM: no PEM body leak" false
    (contains_sub ~needle:"MIIETruncPemLeak" t4);
  Alcotest.(check bool) "truncated PEM: shows [redacted]" true
    (contains_sub ~needle:"[redacted]" t4);
  let t5 =
    render_preview {|{"api_key":"sk-live-trunc123|}
  in
  Alcotest.(check bool) "truncated api_key: no sk-live-trunc123 leak" false
    (contains_sub ~needle:"sk-live-trunc123" t5);
  Alcotest.(check bool) "truncated api_key: shows [redacted]" true
    (contains_sub ~needle:"[redacted]" t5)

let test_p1_pipeline_and_tasks_selection_sync () =
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  (* Pipeline: select 0-link Completed goal (index 2) and out-of-bounds index 9 *)
  let m_pipe_last =
    {
      m0 with
      work =
        {
          (Work_store.set_tab Nav.Work_pipeline m0.work) with
          selected_index = 9;
        };
    }
  in
  let pipe_grid =
    render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m_pipe_last)
  in
  let pipe_txt = grid_all_text pipe_grid in
  Alcotest.(check bool) "0-link goal does NOT leak unrelated Rejection Diff" false
    (contains_sub ~needle:"Rejection Diff" pipe_txt);
  Alcotest.(check bool) "0-link goal does NOT leak bench-proof.md" false
    (contains_sub ~needle:"bench-proof.md" pipe_txt);
  Alcotest.(check bool) "out-of-bounds selected_index renders last goal detail" true
    (contains_sub ~needle:"Zero P0/P1 findings" pipe_txt);
  (* Tasks: Done chip selects task-3899 cleanly *)
  let m_done =
    {
      m0 with
      work =
        m0.work
        |> Work_store.set_tab Nav.Work_tasks
        |> Work_store.set_task_status_filter Work_store.Status_done;
    }
  in
  let done_grid =
    render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m_done)
  in
  let done_txt = grid_all_text done_grid in
  Alcotest.(check bool) "done filter detail shows task-3899" true
    (contains_sub ~needle:"Implement persistent ACP channels" done_txt);
  (* Schedules 1st-class tab highlights Schedules and shows schedule detail *)
  let m_sched =
    {
      m0 with
      work =
        {
          (m0.work |> Work_store.set_tab Nav.Work_schedules)
          with
          selected_index = 1;
        };
    }
  in
  let sched_grid =
    render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m_sched)
  in
  let sched_txt = grid_all_text sched_grid in
  Alcotest.(check bool) "schedules filter shows selected schedule 1 detail" true
    (contains_sub ~needle:"sched-leader-patrol" sched_txt)

let test_p2_zero_candle_decay_company_counts_and_filter_isolation () =
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  (* 0-supply Candle ledger with 12h half-life must NOT fabricate 1.000 C or hardcode 7d *)
  let zero_ledger : Wire_work.candle_ledger =
    {
      sample_candle_ledger with
      half_life_sec = Some 43200.0;
      circulating_milli = "0";
      balances =
        [
          {
            keeper = "e-masc-the-leader";
            balance_milli = 500;
            decayed_milli = "400";
            last_event_unix = Some now_unix;
            owned_items = [];
          };
        ];
    }
  in
  let m_zero =
    {
      m0 with
      (* Also apply a Keepers filter_query to verify it does NOT leak into Work leaderboards *)
      fleet = Fleet_store.set_filter "wkbl" m0.fleet;
      work =
        m0.work
        |> Work_store.apply_candle_ledger ~observed_at:now_mono zero_ledger
        |> Work_store.set_tab Nav.Work_candle_scorecard;
    }
  in
  let c_grid = render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m_zero) in
  let c_txt = grid_all_text c_grid in
  Alcotest.(check bool) "half-life title uses dynamic 12h" true
    (contains_sub ~needle:"12h" c_txt);
  Alcotest.(check bool) "0 circulating supply shows Now 0.000 C" true
    (contains_sub ~needle:"Now 0.000 C" c_txt);
  Alcotest.(check bool) "0 circulating supply shows Peak 0.000 C" true
    (contains_sub ~needle:"Peak 0.000 C" c_txt);
  Alcotest.(check bool) "0 circulating supply never fabricates Peak 1.000 C" false
    (contains_sub ~needle:"Peak 1.000 C" c_txt);
  Alcotest.(check bool) "0 circulating supply header shows Circulating 0.000 C" true
    (contains_sub ~needle:"Circulating 0.000 C" c_txt);
  Alcotest.(check bool) "Keepers filter does not hide MASC Core Eng from Work Leaderboard" true
    (contains_sub ~needle:"MASC Core Eng" c_txt);
  (* Keeper Dive > Work & Candle sub-1.0 C retention (400/500 mC = 80%, not 40%) *)
  let kd_grid =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"e-masc-the-leader"
         ~tab:Nav.Keeper_work_candle ~model:m_zero)
  in
  let kd_txt = grid_all_text kd_grid in
  Alcotest.(check bool) "sub-1.0 C decay retention shows 80.0%" true
    (contains_sub ~needle:"80.0%" kd_txt);
  Alcotest.(check bool) "sub-1.0 C decay retention shows 0.400 C / 0.500 C" true
    (contains_sub ~needle:"0.400 C / 0.500 C" kd_txt);
  Alcotest.(check bool) "sub-1.0 C decay retention never clamps limit to 1.000 C" false
    (contains_sub ~needle:"40.0%" kd_txt);
  (* P2-4: Creative / R&D has only paused music-sensei -> Wide header shows ‖1, NOT ●1 *)
  let k_grid = render_to_grid ~cols:140 ~rows:40 (Screen_keepers.render ~model:m0) in
  let creative_row =
    let rec find y =
      if y >= 40 then None
      else
        let r = grid_row_text k_grid ~y in
        if contains_sub ~needle:"Creative / R&D" r then Some r else find (y + 1)
    in
    find 0
  in
  match creative_row with
  | None -> Alcotest.fail "Expected Creative / R&D company header row"
  | Some r ->
      Alcotest.(check bool) "paused-only company shows ‖1" true
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Live_paused ^ "1") r);
      Alcotest.(check bool) "paused-only company does not count paused as ●1" false
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Live_healthy ^ "1") r)

let test_p2_tight_populated_rects_preserve_borders () =
  let m = make_populated_model ~cols:80 ~rows:24 ~lang:Say.Lang_en in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun target ->
          let g =
            render_to_grid ~cols ~rows
              (Screen_work.render_dive ~target ~model:m)
          in
          let bl = Cell_grid.get g ~x:0 ~y:(rows - 1) in
          let br = Cell_grid.get g ~x:(cols - 1) ~y:(rows - 1) in
          Alcotest.(check bool)
            (Printf.sprintf "tight %dx%d bottom-left border intact" cols rows)
            true
            (Cell_grid.glyph_equal bl.glyph (Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_bl))
             || Cell_grid.glyph_equal bl.glyph (Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_heavy_bl)));
          Alcotest.(check bool)
            (Printf.sprintf "tight %dx%d bottom-right border intact" cols rows)
            true
            (Cell_grid.glyph_equal br.glyph (Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_br))
             || Cell_grid.glyph_equal br.glyph (Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_heavy_br))))
        [
          Nav.Goal_dive "goal-overhaul";
          Nav.Task_dive "task-3898";
          Nav.Verification_dive "verif-901";
        ];
      (* Also test populated Work tabs + Keeper Dive tabs on tight rects *)
      List.iter
        (fun tab ->
          ignore
            (render_to_grid ~cols ~rows
               (Screen_work.render ~model:{ m with work = Work_store.set_tab tab m.work })))
        Nav.all_work_tabs;
      List.iter
        (fun tab ->
          ignore
            (render_to_grid ~cols ~rows
               (Screen_keepers.render_dive ~name:"e-masc-the-leader" ~tab ~model:m)))
        Nav.all_keeper_tabs)
    [ (20, 6); (10, 4) ]

let has_any_italic_cell (grid : Cell_grid.t) =
  let found = ref false in
  for y = 0 to Cell_grid.rows grid - 1 do
    for x = 0 to Cell_grid.cols grid - 1 do
      let cell = Cell_grid.get grid ~x ~y in
      if Attr.has cell.style.attrs Attr.italic then found := true
    done
  done;
  !found

let has_any_braille_cell (grid : Cell_grid.t) =
  let found = ref false in
  for y = 0 to Cell_grid.rows grid - 1 do
    for x = 0 to Cell_grid.cols grid - 1 do
      match (Cell_grid.get grid ~x ~y).glyph with
      | Cell_grid.Braille mask when mask <> 0 -> found := true
      | _ -> ()
    done
  done;
  !found

(* Count rounded top-left card corners (╭) located strictly inside an outer
   card's interior — detects forbidden boxes-inside-boxes. *)
let count_nested_box_corners (grid : Cell_grid.t) =
  let cols = Cell_grid.cols grid in
  let rows = Cell_grid.rows grid in
  let tl_glyph = Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_tl) in
  let tr_glyph = Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_tr) in
  let bl_glyph = Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_bl) in
  let boxes = ref [] in
  for y = 0 to rows - 1 do
    for x = 0 to cols - 1 do
      if Cell_grid.glyph_equal (Cell_grid.get grid ~x ~y).glyph tl_glyph then begin
        let rx = ref (x + 1) in
        while !rx < cols && not (Cell_grid.glyph_equal (Cell_grid.get grid ~x:!rx ~y).glyph tr_glyph) do
          incr rx
        done;
        let by = ref (y + 1) in
        while !by < rows && not (Cell_grid.glyph_equal (Cell_grid.get grid ~x ~y:!by).glyph bl_glyph) do
          incr by
        done;
        if !rx < cols && !by < rows then
          boxes := (x, y, !rx, !by) :: !boxes
      end
    done
  done;
  List.fold_left
    (fun acc (x1, y1, rx1, by1) ->
      let is_nested =
        List.exists
          (fun (x0, y0, rx0, by0) ->
            x1 > x0 && y1 > y0 && rx1 < rx0 && by1 < by0)
          !boxes
      in
      if is_nested then acc + 1 else acc)
    0 !boxes

let test_v25_work_pipeline_adaptive_height_and_linked_card () =
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  (* Add a 0/4 goal to verify selected 0/4 gauge never looks falsely filled *)
  let zero_goal : Wire_work.goal =
    {
      id = "goal-zero-four";
      title = "Zero Done Four Linked";
      phase = Wire_work.Executing;
      priority = 1;
      due_date = Some "2026-12-15";
      measure = "4/4 linked tasks passing";
      procedure = "Run verification suite";
      criterion_revision = Some "rev-1";
      criterion_verdict = Wire_work.Criterion_pending;
      last_review_note = Some "Waiting on first PR";
      last_review_at = Some "2026-11-22T01:00:00Z";
      created_at = None;
      updated_at = Some "2026-11-22T01:00:00Z";
      linked_task_count = Observed.value ~observed_at:now_mono 4;
    }
  in
  let four_todo =
    List.init 4 (fun i ->
        {
          Wire_work.id = Printf.sprintf "task-zf-%d" (i + 1);
          title = Printf.sprintf "Subtask %d" (i + 1);
          description = None;
          priority = 2;
          status = Wire_work.Todo;
          goal_link = Wire_work.Linked "goal-zero-four";
          created_at = None;
          updated_at = None;
        })
  in
  let m =
    {
      m0 with
      work =
        m0.work
        |> Work_store.apply_planning ~observed_at:now_mono
             { goals = zero_goal :: sample_goals; tasks = four_todo @ sample_tasks }
        |> Work_store.set_tab Nav.Work_pipeline;
    }
  in
  let grid = render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m) in
  let txt = grid_all_text grid in
  (* 1. Adaptive left Goals card height: 4 goals -> height = 8 (ends before row 13),
        and bottom-left Linked Tasks & Verifications peer card fills the reclaimed space! *)
  let bl_glyph = Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_bl) in
  let first_left_bl_y =
    let heavy_bl = Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_heavy_bl) in
    let rec find y =
      if y >= 40 then None
      else if
        Cell_grid.glyph_equal (Cell_grid.get grid ~x:0 ~y).glyph bl_glyph
        || Cell_grid.glyph_equal (Cell_grid.get grid ~x:0 ~y).glyph heavy_bl
      then Some y
      else find (y + 1)
    in
    find 0
  in
  (match first_left_bl_y with
  | None -> Alcotest.fail "Expected top-left Goals card bottom border"
  | Some y ->
      Alcotest.(check bool)
        (Printf.sprintf "Goals card uses adaptive height <= 12 (bottom at y=%d)" y)
        true (y <= 12));
  Alcotest.(check bool) "bottom-left Linked Tasks & Verifications peer card rendered" true
    (contains_sub ~needle:"연결된 작업" txt && contains_sub ~needle:"task-zf-1" txt);
  Alcotest.(check bool) "zero nested boxes in Work Pipeline" true
    (count_nested_box_corners grid = 0);
  (* 2. Selected 0/4 goal row in the LEFT Goals table (y >= 3, x < 64) uses Left_rail ▎ + calm selection_bg (zero filled █ blocks) *)
  let theme = Theme.of_preset m.theme_preset in
  let grid_slice_text ~x0 ~x1 ~y =
    let buf = Buffer.create (x1 - x0) in
    for x = x0 to x1 - 1 do
      match (Cell_grid.get grid ~x ~y).glyph with
      | Cell_grid.Empty -> Buffer.add_char buf ' '
      | Cell_grid.Ascii ch -> Buffer.add_char buf ch
      | Cell_grid.Braille mask -> Buffer.add_string buf (Cell_grid.braille_utf8 mask)
      | Cell_grid.Utf8 s -> Buffer.add_string buf s
      | Cell_grid.Continuation -> ()
    done;
    Buffer.contents buf
  in
  let zf_row_opt =
    let rec find y =
      if y >= 12 then None
      else
        let r = grid_slice_text ~x0:0 ~x1:64 ~y in
        if contains_sub ~needle:"Zero Done" r then Some (y, r)
        else find (y + 1)
    in
    find 3
  in
  (match zf_row_opt with
  | None -> Alcotest.fail "Expected Zero Done Four selected row in left Goals table"
  | Some (y, row_txt) ->
      Alcotest.(check bool) "0/4 label rendered" true (contains_sub ~needle:"0/4" row_txt);
      Alcotest.(check bool) "selected row uses Left_rail ▎" true
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Left_rail) row_txt);
      Alcotest.(check bool) "0/4 gauge never shows full block █" false
        (contains_sub ~needle:"█" row_txt);
      let sel_cell = Cell_grid.get grid ~x:1 ~y in
      Alcotest.(check bool) "selected row uses calm selection_bg" true
        (Color.equal sel_cell.style.bg (Color.of_rgb theme.selection_bg)));
  Alcotest.(check bool) "Tier-4 italic cells active in Pipeline" true
    (has_any_italic_cell grid)

let test_v25_candle_peer_cards_zero_nested_boxes_and_violet_ai () =
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let m = { m0 with work = Work_store.set_tab Nav.Work_candle_scorecard m0.work } in
  let grid = render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m) in
  let txt = grid_all_text grid in
  let theme = Theme.of_preset m.theme_preset in
  Alcotest.(check int) "zero boxes-inside-boxes in Candle Economy" 0
    (count_nested_box_corners grid);
  Alcotest.(check bool) "Candle Economy uses Ai_spark ✦" true
    (contains_sub ~needle:(Glyph.to_utf8 Glyph.Ai_spark) txt);
  let has_violet_ai =
    let found = ref false in
    for y = 0 to 39 do
      for x = 0 to 139 do
        let c = Cell_grid.get grid ~x ~y in
        if Color.equal c.style.fg (Color.of_rgb theme.status_ai) then
          found := true
      done
    done;
    !found
  in
  Alcotest.(check bool) "Candle Economy paints Theme.status_ai Violet accents" true
    has_violet_ai;
  Alcotest.(check bool) "Half-Life Decay Curve renders Braille cells" true
    (has_any_braille_cell grid);
  Alcotest.(check bool) "Tier-4 italic captions/timestamps present" true
    (has_any_italic_cell grid);
  (* Round 5.5 polish: omit redundant decay left prefix & permanently-unreported PR ? 미보고 *)
  let m_ko0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  let ledger_no_hl = { sample_candle_ledger with half_life_sec = None } in
  let sc_unrep_pr : Wire_fleet.daily_scorecard =
    {
      (Model.effective_scorecard m_ko0) with
      board_posts_24h = Observed.value ~observed_at:now_mono 14;
      goals_completed_24h = Observed.value ~observed_at:now_mono 2;
    }
  in
  let fleet_unrep_pr =
    match Observed.to_option m_ko0.fleet.shell with
    | Some sh ->
        Fleet_store.apply_shell ~observed_at:now_mono
          { sh with scorecard_24h = sc_unrep_pr }
          m_ko0.fleet
    | None -> m_ko0.fleet
  in
  let m_ko =
    {
      m_ko0 with
      fleet = fleet_unrep_pr;
      work =
        m_ko0.work
        |> Work_store.apply_candle_ledger ~observed_at:now_mono ledger_no_hl
        |> Work_store.set_tab Nav.Work_candle_scorecard;
    }
  in
  let grid_ko = render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m_ko) in
  let txt_ko = grid_all_text grid_ko in
  Alcotest.(check bool) "omits redundant 반감기 — 감쇠 left prefix" false
    (contains_sub ~needle:"반감기 — 감쇠" txt_ko
     || contains_sub ~needle:"감쇠 · 7d" txt_ko);
  Alcotest.(check bool) "keeps crisp 현재/최대/평균 stats strip on decay card" true
    (contains_sub ~needle:"현재" txt_ko
     && contains_sub ~needle:"최대" txt_ko
     && contains_sub ~needle:"평균" txt_ko);
  Alcotest.(check bool) "never prints permanently-unreported PR ? 미보고" false
    (contains_sub ~needle:"PR ?" txt_ko
     || contains_sub ~needle:"PR ? 미보고" txt_ko);
  Alcotest.(check bool) "substitutes live 게시 / 목표 in right achievement header" true
    (contains_sub ~needle:"게시 14" txt_ko
     && contains_sub ~needle:"목표 2" txt_ko);
  (* 28-point Half-Life Decay Curve stretches across left, mid, AND right thirds of left chart *)
  let count_braille ~x0 ~x1 ~y0 ~y1 =
    let n = ref 0 in
    for y = y0 to y1 do
      for x = x0 to x1 do
        match (Cell_grid.get grid_ko ~x ~y).glyph with
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
  let dec_l = count_braille ~x0:11 ~x1:31 ~y0:6 ~y1:13 in
  let dec_m = count_braille ~x0:32 ~x1:52 ~y0:6 ~y1:13 in
  let dec_r = count_braille ~x0:53 ~x1:73 ~y0:6 ~y1:13 in
  Alcotest.(check bool)
    (Printf.sprintf "Half-Life Decay Curve fills all 3 thirds (%d/%d/%d)" dec_l dec_m dec_r)
    true (dec_l >= 8 && dec_m >= 8 && dec_r >= 8)

let test_v25_keepers_5_company_fleet_tree_and_preview_inspector () =
  let mk_keeper ~group ~name ~health : Wire_fleet.keeper_summary =
    {
      name;
      group = Some group;
      company = "";
      health;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "claude_code_a1b2c3d4.claude-sonnet-4-6";
      model_id = Some "claude-sonnet-4-6";
      current_task_id = Some "task-501";
      context = Observed.value ~observed_at:now_mono (measured_context 0.42);
      total_turns = Observed.value ~observed_at:now_mono 120;
      last_turn_at_unix = Some (now_unix -. 60.0);
      active_turn = None;
    }
  in
  let five_co_keepers =
    [
      mk_keeper ~group:"MASC Core" ~name:"e-masc-the-leader" ~health:Wire_fleet.Keeper_healthy;
      mk_keeper ~group:"Code Review" ~name:"code-reviewer" ~health:Wire_fleet.Keeper_working;
      mk_keeper ~group:"WKBL Startup" ~name:"wkbl-growth" ~health:Wire_fleet.Keeper_healthy;
      mk_keeper ~group:"KidsNote Ops" ~name:"kidsnote-ops-monitor" ~health:Wire_fleet.Keeper_healthy;
      mk_keeper ~group:"Creative & R&D" ~name:"music-sensei" ~health:Wire_fleet.Keeper_idle;
    ]
  in
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko () in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_keepers ~observed_at:now_mono five_co_keepers
    |> Fleet_store.select_keeper "e-masc-the-leader"
    |> Fleet_store.apply_roster_extras
         {
           sandbox_profiles =
             [
               ("e-masc-the-leader", Wire_fleet.Profile_microvm);
               ("wkbl-growth", Wire_fleet.Profile_remote_ssh);
             ];
           candle_balances_milli = [ ("e-masc-the-leader", 4250) ];
           candle_summary = None;
           turn_pulses = [];
           diagnostics = [];
           roster_total = None;
           roster_truncated = false;
         }
  in
  let runtime =
    Runtime_store.apply_keeper_costs ~observed_at:now_mono
      {
        generated_at_unix = now_unix;
        window_minutes = 1440;
        rows =
          [
            {
              keeper_name = "e-masc-the-leader";
              sample_count = 12;
              total_tokens = Observed.value ~observed_at:now_mono 350_000;
              total_cost_usd = Observed.value ~observed_at:now_mono 6.75;
              tokens_reported_samples = 12;
              tokens_missing_samples = 0;
              cost_reported_samples = 12;
              cost_missing_samples = 0;
            };
          ];
      }
      m0.runtime
  in
  let m = { m0 with fleet; runtime } in
  let grid = render_to_grid ~cols:140 ~rows:40 (Screen_keepers.render ~model:m) in
  let txt = grid_all_text grid in
  let theme = Theme.of_preset m.theme_preset in
  (* All 5 companies rendered, 0 ungrouped *)
  List.iter
    (fun co ->
      Alcotest.(check bool) ("shows company " ^ co) true
        (contains_sub ~needle:co txt))
    [ "MASC Core"; "Code Review"; "WKBL Startup"; "KidsNote Ops"; "Creative & R&D" ];
  Alcotest.(check bool) "zero ungrouped dump" false
    (contains_sub ~needle:"ungrouped" (String.lowercase_ascii txt));
  (* Selected keeper uses Left_rail ▎ + preserves semantic Emerald ● glyph color *)
  let leader_y =
    let rec find y =
      if y >= 40 then None
      else
        let r = grid_row_text grid ~y in
        if contains_sub ~needle:"e-masc-the-leader" r && contains_sub ~needle:"vm" r then
          Some (y, r)
        else find (y + 1)
    in
    find 0
  in
  (match leader_y with
  | None -> Alcotest.fail "Expected e-masc-the-leader row with vm fallback tag"
  | Some (y, r) ->
      Alcotest.(check bool) "selected keeper row has Left_rail ▎" true
        (contains_sub ~needle:(Glyph.to_utf8 Glyph.Left_rail) r);
      let dot_cell = Cell_grid.get grid ~x:3 ~y in
      Alcotest.(check bool) "selected keeper preserves semantic Emerald ● color" true
        (Color.equal dot_cell.style.fg (Color.of_rgb theme.status_ok)));
  (* Right Live Keeper Preview Inspector shows Hero + 4 metrics + Candle + Cost + Footer cue *)
  Alcotest.(check bool) "preview shows 24h cost from keeper_costs_24h_assoc" true
    (contains_sub ~needle:"$6.75" txt);
  Alcotest.(check bool) "preview shows Violet Candle balance" true
    (contains_sub ~needle:"4.250 C" txt);
  Alcotest.(check bool) "preview shows [Enter] Dive footer cue" true
    (contains_sub ~needle:"[Enter] Dive" txt);
  Alcotest.(check int) "zero nested boxes in Keepers Fleet + Preview" 0
    (count_nested_box_corners grid)

let test_v25_keeper_dive_chat_claude_code_archetypes_and_empty_state () =
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let theme = Theme.of_preset m0.theme_preset in
  (* 1. Expanded Thinking (Thinking_full) + Expanded Tools (Tools_full) *)
  let m_full =
    {
      m0 with
      fleet =
        {
          m0.fleet with
          chat_thinking_mode = Fleet_store.Thinking_full;
          chat_tools_mode = Slash.Tools_full;
        };
    }
  in
  let g_full =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"e-masc-the-leader" ~tab:Nav.Keeper_chat
         ~model:m_full)
  in
  let txt_full = grid_all_text g_full in
  Alcotest.(check bool) "Thinking header uses Ai_spark ✦" true
    (contains_sub ~needle:(Glyph.to_utf8 Glyph.Ai_spark) txt_full);
  Alcotest.(check bool) "Thinking body renders in Thinking_full" true
    (contains_sub ~needle:"Checking head commit" txt_full);
  (* Verify Violet ▎ rail + italic cells on Thinking line *)
  let think_row_ok =
    let found_rail = ref false in
    let found_italic = ref false in
    for y = 0 to 39 do
      let r = grid_row_text g_full ~y in
      if contains_sub ~needle:"Checking head commit" r then
        for x = 0 to 139 do
          let c = Cell_grid.get g_full ~x ~y in
          if
            Cell_grid.glyph_equal c.glyph
              (Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Left_rail))
            && Color.equal c.style.fg (Color.of_rgb theme.status_ai)
          then found_rail := true;
          if Attr.has c.style.attrs Attr.italic then found_italic := true
        done
    done;
    !found_rail && !found_italic
  in
  Alcotest.(check bool) "Thinking uses Violet ▎ rail + Attr.italic text" true
    think_row_ok;
  (* Verify expanded Tool call output uses recessed surface_0 bg *)
  let tool_out_surface0 =
    let found = ref false in
    for y = 0 to 39 do
      let r = grid_row_text g_full ~y in
      if contains_sub ~needle:"reviewDecision=APPROVED" r then
        for x = 0 to 139 do
          let c = Cell_grid.get g_full ~x ~y in
          if Color.equal c.style.bg (Color.of_rgb theme.surface_0) then
            found := true
        done
    done;
    !found
  in
  Alcotest.(check bool) "Expanded tool output uses recessed surface_0 bg" true
    tool_out_surface0;
  (* 2. Rich Non-Void Empty State when keeper has 0 chat turns *)
  let g_empty =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"music-sensei" ~tab:Nav.Keeper_chat
         ~model:m0)
  in
  let txt_empty = grid_all_text g_empty in
  Alcotest.(check bool) "Empty chat renders rich context (>= 12 populated rows)" true
    (non_empty_row_count g_empty >= 12);
  Alcotest.(check bool) "Empty chat shows keeper identity & company" true
    (contains_sub ~needle:"@music-sensei" txt_empty
     && contains_sub ~needle:"Creative / R&D" txt_empty);
  Alcotest.(check bool) "Empty chat shows italic prompt starters" true
    (contains_sub ~needle:"Summarize your current task" txt_empty
     && has_any_italic_cell g_empty);
  Alcotest.(check int) "zero nested boxes in Empty Chat" 0
    (count_nested_box_corners g_empty);
  (* 3. Zero nested boxes on Tab 3 (Keeper_work_candle) *)
  let g_wc =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"e-masc-the-leader"
         ~tab:Nav.Keeper_work_candle ~model:m0)
  in
  Alcotest.(check int) "zero nested boxes in Keeper Dive Work & Candle" 0
    (count_nested_box_corners g_wc)

let test_p1_keeper_dive_tool_card_secret_redaction () =
  let m0 = make_populated_model ~cols:140 ~rows:48 ~lang:Say.Lang_en in
  let sk_tok = "sk-" ^ "demoSecret99887766" in
  let ghp_tok = "ghp_" ^ "fakeGhToken112233445566" in
  let bearer_tok = "jwt_secret_payload_4242" in
  let url_pass = "superSecretUrlPass77" in
  let pem_body = "MIIE_DEMO_PRIVATE_KEY_BODY_88" in
  let kv_secret = "plain_api_secret_55" in
  let trunc_secret = "sk-live-truncSecret12345" in
  let raw_non_json_out =
    String.concat "\n"
      [
        "token=" ^ sk_tok;
        "gh=" ^ ghp_tok;
        "Authorization: Bearer " ^ bearer_tok;
        "url=https://ops:" ^ url_pass ^ "@api.example.invalid/hook";
        "-----BEGIN " ^ "PRIVATE KEY-----";
        pem_body;
        "-----END " ^ "PRIVATE KEY-----";
        "api_key=" ^ kv_secret;
      ]
  in
  let json_embedded_out =
    Printf.sprintf
      {|{"cmd":"curl -H 'Authorization: Bearer %s' https://u:%s@example.invalid","status":"ok"}|}
      bearer_tok url_pass
  in
  let truncated_json_args = {|{"api_key":"|} ^ trunc_secret in
  let check_no_leaks label txt =
    List.iter
      (fun (name, leak) ->
        Alcotest.(check bool)
          (Printf.sprintf "%s scrubs %s" label name)
          false (contains_sub ~needle:leak txt))
      [
        ("sk token", sk_tok);
        ("ghp token", ghp_tok);
        ("bearer token", bearer_tok);
        ("url password", url_pass);
        ("pem body", pem_body);
        ("api_key kv", kv_secret);
        ("truncated json secret", trunc_secret);
      ];
    Alcotest.(check bool)
      (Printf.sprintf "%s shows [redacted]" label)
      true (contains_sub ~needle:"[redacted]" txt)
  in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_chat_history ~keeper:"e-masc-the-leader"
         ~observed_at:now_mono
         {
           messages =
             [
               {
                 id = "sec-1";
                 role = Wire_fleet.Role_tool;
                 content = raw_non_json_out;
                 ts_unix = now_unix -. 20.0;
                 turn_ref = Some "t-sec-1";
                 model_used = None;
                 tool_call_id = Some "tc-sec-1";
                 tool_call_name = Some "hist_non_json";
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
               {
                 id = "sec-2";
                 role = Wire_fleet.Role_tool;
                 content = json_embedded_out;
                 ts_unix = now_unix -. 15.0;
                 turn_ref = Some "t-sec-2";
                 model_used = None;
                 tool_call_id = Some "tc-sec-2";
                 tool_call_name = Some "hist_json_embed";
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
               {
                 id = "sec-3";
                 role = Wire_fleet.Role_tool;
                 content = truncated_json_args;
                 ts_unix = now_unix -. 10.0;
                 turn_ref = Some "t-sec-3";
                 model_used = None;
                 tool_call_id = Some "tc-sec-3";
                 tool_call_name = Some "hist_trunc_json";
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
               {
                 id = "sec-4";
                 role = Wire_fleet.Role_tool;
                 content =
                   Printf.sprintf
                     {|{"target":"Bearer\t%s","operation_id":"%s","prompt":"Bearer\n%s api_key:\n%s"}|}
                     bearer_tok sk_tok bearer_tok kv_secret;
                 ts_unix = now_unix -. 5.0;
                 turn_ref = Some "t-sec-4";
                 model_used = None;
                 tool_call_id = Some "tc-sec-4";
                 tool_call_name = Some "masc_keeper_delegate";
                 execution_id = None;
                 provenance = None;
                 failure_kind = None;
                 thinking = None;
               };
             ];
           has_more = false;
           next_cursor = None;
         }
    |> Fleet_store.start_chat_stream ~keeper:"e-masc-the-leader"
         ~request_id:"req-sec"
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"e-masc-the-leader"
         ~request_id:"req-sec"
         (Wire_fleet.Chunk_tool_start
            {
              operation_id = Some "op-sec";
              tool_use_id = "tu-sec-stream";
              stream_scope = None;
              tool_name = "bash_exec";
              args_preview = Some truncated_json_args;
            })
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"e-masc-the-leader"
         ~request_id:"req-sec"
         (Wire_fleet.Chunk_tool_end
            {
              operation_id = Some "op-sec";
              tool_use_id = "tu-sec-stream";
              tool_name = Some "bash_exec";
              ok = Some true;
              output_preview = Some raw_non_json_out;
            })
  in
  List.iter
    (fun (mode_name, mode) ->
      let m = { m0 with fleet = { fleet with chat_tools_mode = mode } } in
      let g =
        render_to_grid ~cols:140 ~rows:48
          (Screen_keepers.render_dive ~name:"e-masc-the-leader"
             ~tab:Nav.Keeper_chat ~model:m)
      in
      check_no_leaks mode_name (grid_all_text g))
    [
      ("Tools_compact", Slash.Tools_compact);
      ("Tools_results", Slash.Tools_results);
      ("Tools_full", Slash.Tools_full);
    ]

let test_p2_tool_modes_ctrl_o_hint_and_origin_modes () =
  let m0 = make_populated_model ~cols:140 ~rows:64 ~lang:Say.Lang_en in
  let make_lines n =
    List.init n (fun i -> Printf.sprintf "tool_output_line_%02d ok" (i + 1))
    |> String.concat "\n"
  in
  let render_with_out ~rows ~mode out_text =
    let fleet =
      m0.fleet
      |> Fleet_store.apply_chat_history ~keeper:"e-masc-the-leader"
           ~observed_at:now_mono
           {
             messages =
               [
                 {
                   id = "t-lines";
                   role = Wire_fleet.Role_tool;
                   content = out_text;
                   ts_unix = now_unix -. 5.0;
                   turn_ref = Some "t-lines-1";
                   model_used = None;
                   tool_call_id = Some "tc-lines-1";
                   tool_call_name = Some "log_dump";
                   execution_id = None;
                   provenance = None;
                   failure_kind = None;
                   thinking = None;
                 };
               ];
             has_more = false;
             next_cursor = None;
           }
    in
    let m = { m0 with fleet = { fleet with chat_tools_mode = mode } } in
    grid_all_text
      (render_to_grid ~cols:140 ~rows
         (Screen_keepers.render_dive ~name:"e-masc-the-leader"
            ~tab:Nav.Keeper_chat ~model:m))
  in
  (* 1. Tools_results caps at 8 lines and displays SSOT [Ctrl+O], NEVER dead [Ctrl+D] *)
  let txt_res = render_with_out ~rows:40 ~mode:Slash.Tools_results (make_lines 16) in
  Alcotest.(check bool) "Tools_results shows line 08" true
    (contains_sub ~needle:"tool_output_line_08" txt_res);
  Alcotest.(check bool) "Tools_results hides line 14" false
    (contains_sub ~needle:"tool_output_line_14" txt_res);
  Alcotest.(check bool) "Tools_results shows SSOT [Ctrl+O] hint" true
    (contains_sub ~needle:"[Ctrl+O]" txt_res);
  Alcotest.(check bool) "Tools_results never shows dead [Ctrl+D]" false
    (contains_sub ~needle:"[Ctrl+D]" txt_res);
  (* 2. Tools_full expands beyond 8 lines (16 lines all visible) *)
  let txt_full_16 = render_with_out ~rows:40 ~mode:Slash.Tools_full (make_lines 16) in
  Alcotest.(check bool) "Tools_full renders line 14 (> 8 lines)" true
    (contains_sub ~needle:"tool_output_line_14" txt_full_16);
  (* 3. Tools_full caps huge 60-line output at 48 lines with plain notice (no [Ctrl+O]/[Ctrl+D]) *)
  let txt_full_60 = render_with_out ~rows:64 ~mode:Slash.Tools_full (make_lines 60) in
  Alcotest.(check bool) "Tools_full shows line 48" true
    (contains_sub ~needle:"tool_output_line_48" txt_full_60);
  Alcotest.(check bool) "Tools_full hides line 55 past 48-line cap" false
    (contains_sub ~needle:"tool_output_line_55" txt_full_60);
  Alcotest.(check bool) "Tools_full shows plain cap notice" true
    (contains_sub ~needle:"48-line cap" txt_full_60);
  Alcotest.(check bool) "Tools_full omits misleading [Ctrl+O] expand hint" false
    (contains_sub ~needle:"more lines [Ctrl+O]" txt_full_60);
  Alcotest.(check bool) "Tools_full never shows dead [Ctrl+D]" false
    (contains_sub ~needle:"[Ctrl+D]" txt_full_60);
  (* 4. Ctrl+F origin modes: Bare, Inline, and Row render 3 distinct views *)
  let render_origin mode =
    let m = { m0 with fleet = { m0.fleet with chat_origin_mode = mode } } in
    grid_all_text
      (render_to_grid ~cols:140 ~rows:40
         (Screen_keepers.render_dive ~name:"e-masc-the-leader"
            ~tab:Nav.Keeper_chat ~model:m))
  in
  let txt_bare = render_origin Fleet_store.Display_origin_bare in
  let txt_inline = render_origin Fleet_store.Display_origin_inline in
  let txt_row = render_origin Fleet_store.Display_origin_row in
  Alcotest.(check bool) "Display_origin_bare differs from Display_origin_inline"
    false (String.equal txt_bare txt_inline);
  Alcotest.(check bool) "Display_origin_bare differs from Display_origin_row"
    false (String.equal txt_bare txt_row);
  Alcotest.(check bool) "Display_origin_inline differs from Display_origin_row"
    false (String.equal txt_inline txt_row);
  Alcotest.(check bool) "Display_origin_row shows explicit direct origin metadata"
    true (contains_sub ~needle:"direct" txt_row);
  Alcotest.(check bool) "Display_origin_bare omits direct origin metadata"
    false (contains_sub ~needle:"direct ·" txt_bare)

let test_p2_standard_viewport_keepers_split_and_kpi_visibility () =
  List.iter
    (fun (cols, rows) ->
      let m0 = make_populated_model ~cols ~rows ~lang:Say.Lang_ko in
      let fleet =
        Fleet_store.apply_roster_extras
          {
            sandbox_profiles =
              [ ("e-masc-the-leader", Wire_fleet.Profile_microvm) ];
            candle_balances_milli = [ ("e-masc-the-leader", 4250) ];
            candle_summary = None;
            turn_pulses = [];
            diagnostics = [];
            roster_total = None;
            roster_truncated = false;
          }
          m0.fleet
      in
      let runtime =
        Runtime_store.apply_keeper_costs ~observed_at:now_mono
          {
            generated_at_unix = now_unix;
            window_minutes = 1440;
            rows =
              [
                {
                  keeper_name = "e-masc-the-leader";
                  sample_count = 12;
                  total_tokens = Observed.value ~observed_at:now_mono 350_000;
                  total_cost_usd = Observed.value ~observed_at:now_mono 6.75;
                  tokens_reported_samples = 12;
                  tokens_missing_samples = 0;
                  cost_reported_samples = 12;
                  cost_missing_samples = 0;
                };
              ];
          }
          m0.runtime
      in
      (* The preview reads the keeper's cost from keeper_costs ($6.75) *)
      let k_leader =
        {
          (List.hd sample_keepers) with
          context = Observed.value ~observed_at:now_mono (measured_context 0.42);
          total_turns = Observed.value ~observed_at:now_mono 120;
        }
      in
      let fleet =
        Fleet_store.apply_keepers ~observed_at:now_mono
          (k_leader :: List.tl sample_keepers)
          fleet
      in
      let m = { m0 with fleet; runtime } in
      let g_k = render_to_grid ~cols ~rows (Screen_keepers.render ~model:m) in
      (* 1. Verify left Fleet Tree uses true ~36% (37 at 104, 39 at 112), NEVER slams 46/52 cols *)
      let tr_glyph = Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_tr) in
      let heavy_tr = Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_heavy_tr) in
      let first_tr_x =
        let rec scan x =
          if x >= cols then None
          else if
            Cell_grid.glyph_equal (Cell_grid.get g_k ~x ~y:0).glyph tr_glyph
            || Cell_grid.glyph_equal (Cell_grid.get g_k ~x ~y:0).glyph heavy_tr
          then Some x
          else scan (x + 1)
        in
        scan 0
      in
      (match first_tr_x with
      | None -> Alcotest.fail "Expected left Keepers card top-right border"
      | Some rx ->
          let left_w = rx + 1 in
          let expected_max = int_of_float (Float.ceil (float_of_int cols *. 0.38)) in
          Alcotest.(check bool)
            (Printf.sprintf "Keepers left split ~36%% at %dx%d (got %d, max %d)"
               cols rows left_w expected_max)
            true (left_w >= 34 && left_w <= expected_max));
      (* 2. Verify Korean Preview KPI values never clip to 0 width on Standard *)
      let txt_k = grid_all_text g_k in
      Alcotest.(check bool) (Printf.sprintf "KO %dx%d preview shows 42%%" cols rows)
        true (contains_sub ~needle:"42%" txt_k);
      Alcotest.(check bool) (Printf.sprintf "KO %dx%d preview shows 120" cols rows)
        true (contains_sub ~needle:"120" txt_k);
      Alcotest.(check bool) (Printf.sprintf "KO %dx%d preview shows $6.75" cols rows)
        true (contains_sub ~needle:"$6.75" txt_k);
      Alcotest.(check bool) (Printf.sprintf "KO %dx%d preview shows 8.400 C" cols rows)
        true (contains_sub ~needle:"8.400 C" txt_k);
      (* 3. Verify Work Candle right-pane Korean KPI values never clip at Standard *)
      let m_work =
        { m with work = Work_store.set_tab Nav.Work_candle_scorecard m.work }
      in
      let g_w = render_to_grid ~cols ~rows (Screen_work.render ~model:m_work) in
      let txt_w = grid_all_text g_w in
      let sc = Model.effective_scorecard m_work in
      let fmt_i o =
        Format_val.format_observed Format_val.Count
          (Observed.map Float.of_int o)
          ~lang:Say.Lang_ko
      in
      let done_v = fmt_i sc.tasks_done_24h in
      let ver_v =
        Printf.sprintf "%s/%s"
          (fmt_i sc.verifications_passed_24h)
          (fmt_i sc.verifications_rejected_24h)
      in
      let turns_v = fmt_i sc.turns_24h in
      Alcotest.(check bool)
        (Printf.sprintf "KO %dx%d Candle shows Done %s" cols rows done_v)
        true (contains_sub ~needle:done_v txt_w);
      Alcotest.(check bool)
        (Printf.sprintf "KO %dx%d Candle shows Verify %s" cols rows ver_v)
        true (contains_sub ~needle:ver_v txt_w);
      Alcotest.(check bool)
        (Printf.sprintf "KO %dx%d Candle shows Turns %s" cols rows turns_v)
        true (contains_sub ~needle:turns_v txt_w))
    [ (104, 32); (112, 32) ]

let test_degenerate_empty_and_tiny_rects () =
  let m_empty = Model.initial ~cols:80 ~rows:24 () in
  let m_pop_ko = make_populated_model ~cols:90 ~rows:28 ~lang:Say.Lang_ko in
  let m_pop_json =
    {
      m_pop_ko with
      infra = { m_pop_ko.infra with show_raw_json = true };
    }
  in
  let tiny_sizes =
    [ (0, 0); (1, 1); (2, 2); (3, 2); (4, 3); (5, 3); (10, 4); (90, 28) ]
  in
  List.iter
    (fun (cols, rows) ->
      let g = Cell_grid.create ~cols:(Int.max 1 cols) ~rows:(Int.max 1 rows) in
      let cache = Card.Cache.create () in
      let rect = Rect.make ~x:0 ~y:0 ~w:cols ~h:rows in
      (* 1. Empty model resilience *)
      Screen_keepers.render ~model:m_empty ~cache ~rect g;
      Screen_keepers.render_dive ~name:"missing" ~tab:Nav.Keeper_chat
        ~model:m_empty ~cache ~rect g;
      Screen_work.render ~model:m_empty ~cache ~rect g;
      Screen_work.render_dive ~target:(Nav.Goal_dive "missing") ~model:m_empty
        ~cache ~rect g;
      (* 2. Populated model resilience across ALL Keepers modes, ALL 5 Keeper Dive
            tabs (both embedded:false & embedded:true), ALL 4 Work tabs, and ALL
            Work dives (including [J] Json_tree split) *)
      List.iter
        (fun mode ->
          let mk =
            { m_pop_ko with fleet = { m_pop_ko.fleet with fleet_mode = mode } }
          in
          Screen_keepers.render ~model:mk ~cache ~rect g)
        Nav.all_keepers_fleet_modes;
      List.iter
        (fun tab ->
          Screen_keepers.render_dive ~name:"e-masc-the-leader" ~tab
            ~model:m_pop_ko ~cache ~rect g;
          Keeper_dive.render_tabs_body ~embedded:true ~name:"e-masc-the-leader"
            ~tab ~model:m_pop_ko ~cache ~rect g)
        Nav.all_keeper_tabs;
      List.iter
        (fun tab ->
          let mw = { m_pop_ko with work = Work_store.set_tab tab m_pop_ko.work } in
          Screen_work.render ~model:mw ~cache ~rect g)
        Nav.all_work_tabs;
      List.iter
        (fun target ->
          Screen_work.render_dive ~target ~model:m_pop_ko ~cache ~rect g;
          Screen_work.render_dive ~target ~model:m_pop_json ~cache ~rect g)
        [
          Nav.Goal_dive "goal-tui-v2";
          Nav.Task_dive "task-101";
          Nav.Verification_dive "ver-1";
        ])
    tiny_sizes

let test_p0_keeper_dive_honest_24h_vs_lifetime_turns () =
  (* P0-1: Keeper preview MUST NEVER label lifetime total_turns (e.g. 20.4k) as "24h 턴" *)
  let m0_ko = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_ko in
  let m0_en = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let k_high_lifetime =
    {
      (List.hd sample_keepers) with
      total_turns = Observed.value ~observed_at:now_mono 20_400;
    }
  in
  let slot_now =
    Int.of_float (Float.floor (now_unix /. 1800.0)) * 1800
  in
  let pulse_25 : Wire_fleet.turn_pulse =
    {
      known_since = Float.of_int (slot_now - 3600);
      slots =
        [
          {
            starts_at = slot_now - 1800;
            ok = 10;
            rested = 0;
            failed = 0;
            scheduled = 0;
            reacted = 0;
            chat = 0;
            own = 10;
            unknown = 0;
          };
          {
            starts_at = slot_now;
            ok = 12;
            rested = 0;
            failed = 3;
            scheduled = 0;
            reacted = 0;
            chat = 0;
            own = 15;
            unknown = 0;
          };
        ];
    }
  in
  (* Case 1: turn_pulse present -> shows "24h 턴" / "24h Turns" with sum 25, NOT 20.4k *)
  let m_spark_ko =
    {
      m0_ko with
      fleet =
        m0_ko.fleet
        |> Fleet_store.apply_keepers ~observed_at:now_mono
             (k_high_lifetime :: List.tl sample_keepers)
        |> Fleet_store.apply_roster_extras
             {
               sandbox_profiles = [];
               candle_balances_milli = [];
               candle_summary = None;
               turn_pulses = [ (k_high_lifetime.name, pulse_25) ];
               diagnostics = [];
               roster_total = None;
               roster_truncated = false;
             };
    }
  in
  let g_spark_ko =
    render_to_grid ~cols:140 ~rows:40 (Screen_keepers.render ~model:m_spark_ko)
  in
  let txt_spark_ko = grid_all_text g_spark_ko in
  Alcotest.(check bool) "turn pulse present shows 24h 턴 label" true
    (contains_sub ~needle:"24h 턴" txt_spark_ko);
  Alcotest.(check bool) "turn pulse present shows true 24h sum 25" true
    (contains_sub ~needle:"25" txt_spark_ko);
  Alcotest.(check bool) "turn pulse present does NOT print 20.4k as 24h turns" false
    (contains_sub ~needle:"20.4k" txt_spark_ko);

  (* Case 2: no turn_pulse -> explicitly labels lifetime total_turns as 누적 턴 / Total turns, NEVER 24h 턴 *)
  let m_life_ko =
    {
      m0_ko with
      fleet =
        m0_ko.fleet
        |> Fleet_store.apply_keepers ~observed_at:now_mono
             (k_high_lifetime :: List.tl sample_keepers)
        |> Fleet_store.apply_roster_extras
             {
               sandbox_profiles = [];
               candle_balances_milli = [];
               candle_summary = None;
               turn_pulses = [];
               diagnostics = [];
               roster_total = None;
               roster_truncated = false;
             };
    }
  in
  let g_life_ko =
    render_to_grid ~cols:140 ~rows:40 (Screen_keepers.render ~model:m_life_ko)
  in
  let txt_life_ko = grid_all_text g_life_ko in
  Alcotest.(check bool) "empty sparkline shows 누적 턴 label" true
    (contains_sub ~needle:"누적 턴" txt_life_ko);
  Alcotest.(check bool) "empty sparkline shows 20.4k lifetime turns" true
    (contains_sub ~needle:"20.4k" txt_life_ko);
  Alcotest.(check bool) "empty sparkline NEVER labels lifetime as 24h 턴" false
    (contains_sub ~needle:"24h 턴" txt_life_ko);

  let m_life_en =
    {
      m0_en with
      fleet =
        m0_en.fleet
        |> Fleet_store.apply_keepers ~observed_at:now_mono
             (k_high_lifetime :: List.tl sample_keepers)
        |> Fleet_store.apply_roster_extras
             {
               sandbox_profiles = [];
               candle_balances_milli = [];
               candle_summary = None;
               turn_pulses = [];
               diagnostics = [];
               roster_total = None;
               roster_truncated = false;
             };
    }
  in
  let g_life_en =
    render_to_grid ~cols:140 ~rows:40 (Screen_keepers.render ~model:m_life_en)
  in
  let txt_life_en = grid_all_text g_life_en in
  Alcotest.(check bool) "EN empty sparkline shows Total turns label" true
    (contains_sub ~needle:"Total turns" txt_life_en);
  Alcotest.(check bool) "EN empty sparkline NEVER shows 24h Turns" false
    (contains_sub ~needle:"24h Turns" txt_life_en);
  (* P0-4: Voice PTT hint uses uppercase [V], never dead lowercase [v] *)
  Alcotest.(check bool) "Preview uses uppercase [V] PTT hint" true
    (contains_sub ~needle:"[V]" txt_life_en);
  Alcotest.(check bool) "Preview never shows lowercase [v] PTT hint" false
    (contains_sub ~needle:"[v]" txt_life_en)

let test_nav_keepers_display_order_monotonic_screen_rows () =
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
      context = Observed.value ~observed_at:now_mono (measured_context 0.25);
      total_turns = Observed.value ~observed_at:now_mono 10;
      last_turn_at_unix = Some now_unix;
      active_turn = None;
    }
  in
  let scrambled =
    [
      mk_k "org-zeta" "zeta-1";
      mk_k "org-alpha" "alpha-2";
      mk_k "org-mid" "mid-1";
      mk_k "org-beta" "beta-2";
      mk_k "org-alpha" "alpha-1";
      mk_k "org-beta" "beta-1";
    ]
  in
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_en () in
  let fleet0 = Fleet_store.apply_keepers ~observed_at:now_mono scrambled m0.fleet in
  let rail = Glyph.to_utf8 Glyph.Left_rail in
  let find_rail_y (grid : Cell_grid.t) =
    let found = ref None in
    for y = 0 to Cell_grid.rows grid - 1 do
      if Option.is_none !found then
        for x = 0 to 6 do
          if Option.is_none !found then
            match (Cell_grid.get grid ~x ~y).glyph with
            | Cell_grid.Utf8 s when String.equal s rail -> found := Some y
            | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Braille _
            | Cell_grid.Utf8 _ | Cell_grid.Continuation ->
                ()
        done
    done;
    !found
  in
  let rec walk fleet steps acc =
    let g =
      render_to_grid ~cols:140 ~rows:40
        (Screen_keepers.render ~model:{ m0 with fleet })
    in
    let y =
      match find_rail_y g with
      | Some y -> y
      | None -> Alcotest.fail "Expected Left_rail row on Screen_keepers"
    in
    if steps = 0 then List.rev (y :: acc)
    else
      walk
        (Fleet_store.move_selection ~viewport_rows:25 ~delta:1 fleet)
        (steps - 1) (y :: acc)
  in
  let ys = walk fleet0 5 [] in
  let rec check_inc = function
    | [] | [ _ ] -> ()
    | a :: (b :: _ as tl) ->
        Alcotest.(check bool)
          (Printf.sprintf "Keepers ▎ row strictly increasing (%d < %d)" a b)
          true (a < b);
        check_inc tl
  in
  check_inc ys;
  (* Now collapse middle group org-beta and verify remaining 4 keepers still step monotonically *)
  let fleet_col = Fleet_store.toggle_company_collapsed "org-beta" fleet0 in
  let ys_col = walk fleet_col 3 [] in
  check_inc ys_col

let test_p1_chat_transcript_render_parity () =
  let cols, rows = (80, 24) in
  let mk_k name : Wire_fleet.keeper_summary =
    {
      name;
      group = Some "org-alpha";
      company = "org-alpha";
      health = Wire_fleet.Keeper_healthy;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "rt-1";
      model_id = Some "model-1";
      current_task_id = None;
      context = Observed.value ~observed_at:now_mono (measured_context 0.25);
      total_turns = Observed.value ~observed_at:now_mono 10;
      last_turn_at_unix = Some now_unix;
      active_turn = None;
    }
  in
  let mk_msg ~id ~role ~content ?tool_call_name ?provenance ts : Wire_fleet.chat_message =
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
      provenance;
      failure_kind = None;
      thinking = None;
    }
  in
  let json_1line =
    "{\"a\":1,\"b\":2,\"c\":3,\"d\":4,\"e\":5,\"f\":6,\"g\":7,\"h\":8,\"i\":9,\"j\":10}"
  in
  let msgs =
    [
      mk_msg ~id:"c-1" ~role:Wire_fleet.Role_user
        ~content:"TOP_ROW_MARKER_001 Verify narrow Markdown wrap and https://example.invalid/long/path/check"
        (now_unix -. 600.0);
      {
        (mk_msg ~id:"c-2" ~role:Wire_fleet.Role_assistant
           ~content:"# Audit Summary\n\n- Bullet one with generous wording so it wraps across multiple narrow rows\n- Bullet two referencing board:p-1234567890"
           (now_unix -. 540.0))
        with
        thinking = Some (Wire_fleet.Thinking_visible "Inspecting narrow Markdown layout and delegate cards.");
      };
      {
        (mk_msg ~id:"c-3" ~role:Wire_fleet.Role_tool ~tool_call_name:"json_tool"
           ~content:json_1line (now_unix -. 500.0))
        with
        turn_ref = Some "t-grp-parity";
      };
      {
        (mk_msg ~id:"c-3b" ~role:Wire_fleet.Role_tool
           ~tool_call_name:"masc_keeper_delegate"
           ~content:{|{"target":{"kind":"keeper","name":"worker-alpha"},"prompt":"Verify diff","operation_id":"op-del-1"}|}
           (now_unix -. 495.0))
        with
        turn_ref = Some "t-grp-parity";
      };
      {
        (mk_msg ~id:"c-3c" ~role:Wire_fleet.Role_assistant
           ~content:"Redacted reasoning turn." (now_unix -. 480.0))
        with
        thinking = Some Wire_fleet.Thinking_redacted;
      };
    ]
    @ List.init 10 (fun i ->
          mk_msg
            ~id:(Printf.sprintf "c-mid-%d" i)
            ~role:
              (if i mod 2 = 0 then Wire_fleet.Role_user
               else Wire_fleet.Role_assistant)
            ~content:
              (Printf.sprintf
                 "BODY_TURN_%02d Long multi-word paragraph that wraps cleanly at eighty columns width."
                 i)
            (now_unix -. 400.0 +. float_of_int (i * 10)))
    @ [
        mk_msg ~id:"c-last" ~role:Wire_fleet.Role_assistant ?provenance:(operation_provenance "op-p" Terminal_result)
          ~content:"BOTTOM_MARKER_FINAL persisted reply." (now_unix -. 10.0);
      ]
  in
  let m0 = Model.initial ~cols ~rows ~lang:Say.Lang_en () in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_keepers ~observed_at:now_mono [ mk_k "alpha-1" ]
    |> Fleet_store.set_tools_mode Slash.Tools_results
    |> Fleet_store.start_chat_stream ~keeper:"alpha-1" ~request_id:"req-p"
    |> Fleet_store.apply_chat_stream_chunk ~keeper:"alpha-1" ~request_id:"req-p"
         (Wire_fleet.Chunk_turn_done
            {
              operation_id = Some "op-p";
              turn_ref = Some "t-p";
              reply = Some "BOTTOM_MARKER_FINAL persisted reply.";
            })
    |> Fleet_store.apply_chat_history ~observed_at:now_mono ~keeper:"alpha-1"
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
  let render_dive_body (m : Model.t) =
    let geom = Chat_transcript.chat_viewport_geometry ~model:m in
    (* Pass exact Card outer rect matching Chrome body_outer so render_chat_tab matches body_h *)
    let rect_h = geom.body_h + 3 in
    let bp = Ops_common.layout_bp m in
    let body_outer =
      Layout.inset_body bp (Rect.make ~x:0 ~y:0 ~w:cols ~h:rect_h)
    in
    let grid = Cell_grid.create ~cols ~rows:rect_h in
    let cache = Card.Cache.create () in
    Screen_keepers.render_dive ~name:"alpha-1" ~tab:Nav.Keeper_chat ~model:m
      ~cache ~rect:body_outer grid;
    grid_all_text grid
  in
  let txt_bot = render_dive_body m_chat in
  Alcotest.(check bool) "bottom frame renders BOTTOM_MARKER_FINAL" true
    (contains_sub ~needle:"BOTTOM_MARKER_FINAL" txt_bot);
  Alcotest.(check bool) "bottom frame does NOT yet show TOP_ROW_MARKER_001" false
    (contains_sub ~needle:"TOP_ROW_MARKER_001" txt_bot);
  let m_home, _ =
    Update.step ~now:now_mono m_chat
      (Msg.Key_event
         {
           Keymap.Input.key = Keymap.Input.Home;
           mods = Keymap.Input.no_mods;
         })
  in
  let txt_top = render_dive_body m_home in
  Alcotest.(check bool)
    "Home reaches true top row (TOP_ROW_MARKER_001 visible even with wrapped Markdown + JSON tool)"
    true
    (contains_sub ~needle:"TOP_ROW_MARKER_001" txt_top);
  let m_dn1, _ =
    Update.step ~now:now_mono m_home
      (Msg.Key_event
         {
           Keymap.Input.key = Keymap.Input.Down;
           mods = Keymap.Input.no_mods;
         })
  in
  let txt_dn1 = render_dive_body m_dn1 in
  Alcotest.(check bool)
    "Single Down right after Home immediately changes rendered transcript (0 dead presses)"
    true
    (not (String.equal txt_top txt_dn1));
  (* Verify 1:1 Home/Down parity also holds under Tools_compact + Thinking_full *)
  let m_compact_full =
    {
      m_chat with
      fleet =
        {
          m_chat.fleet with
          chat_tools_mode = Slash.Tools_compact;
          chat_thinking_mode = Fleet_store.Thinking_full;
        };
    }
  in
  let m_cf_home, _ =
    Update.step ~now:now_mono m_compact_full
      (Msg.Key_event
         {
           Keymap.Input.key = Keymap.Input.Home;
           mods = Keymap.Input.no_mods;
         })
  in
  let txt_cf_top = render_dive_body m_cf_home in
  Alcotest.(check bool)
    "Tools_compact + Thinking_full Home reaches TOP_ROW_MARKER_001"
    true
    (contains_sub ~needle:"TOP_ROW_MARKER_001" txt_cf_top);
  let m_cf_dn1, _ =
    Update.step ~now:now_mono m_cf_home
      (Msg.Key_event
         {
           Keymap.Input.key = Keymap.Input.Down;
           mods = Keymap.Input.no_mods;
         })
  in
  Alcotest.(check bool)
    "Tools_compact + Thinking_full single Down advances immediately"
    true
    (not (String.equal txt_cf_top (render_dive_body m_cf_dn1)))

(* A [user] row another Keeper wrote is headed with that Keeper, not
   "Operator", and its header row is counted for scrolling. *)
let test_chat_peer_rows_name_their_author () =
  let cols, rows = (80, 24) in
  let mk_k name : Wire_fleet.keeper_summary =
    {
      name;
      group = Some "org-alpha";
      company = "org-alpha";
      health = Wire_fleet.Keeper_healthy;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "rt-1";
      model_id = Some "model-1";
      current_task_id = None;
      context = Observed.value ~observed_at:now_mono (measured_context 0.25);
      total_turns = Observed.value ~observed_at:now_mono 10;
      last_turn_at_unix = Some now_unix;
      active_turn = None;
    }
  in
  let mk_msg ~id ~role ~content ts : Wire_fleet.chat_message =
    {
      id;
      role;
      content;
      ts_unix = ts;
      turn_ref = None;
      model_used = None;
      tool_call_id = None;
      tool_call_name = None;
      execution_id = None;
      provenance = None;
      failure_kind = None;
      thinking = None;
    }
  in
  let broadcast =
    Wire_fleet.Role_peer
      {
        peer = Wire_fleet.Peer_keeper "leader-1";
        surface = Some Wire_fleet.Surface_broadcast;
      }
  in
  let direct =
    Wire_fleet.Role_peer
      {
        peer = Wire_fleet.Peer_keeper "reviewer-2";
        surface = Some Wire_fleet.Surface_agent;
      }
  in
  let msgs =
    [
      mk_msg ~id:"p-top" ~role:broadcast ~content:"PEER_TOP_MARKER freeze lifted"
        (now_unix -. 900.0);
    ]
    @ List.init 8 (fun i ->
          mk_msg
            ~id:(Printf.sprintf "p-%d" i)
            ~role:(if i mod 2 = 0 then direct else broadcast)
            ~content:
              (Printf.sprintf
                 "PEER_BODY_%02d Long multi-word paragraph that wraps cleanly at eighty columns width."
                 i)
            (now_unix -. 800.0 +. float_of_int (i * 10)))
    @ [
        mk_msg ~id:"u-last" ~role:Wire_fleet.Role_user
          ~content:"OPERATOR_LAST_MARKER" (now_unix -. 10.0);
      ]
  in
  let m0 = Model.initial ~cols ~rows ~lang:Say.Lang_en () in
  let fleet =
    m0.fleet
    |> Fleet_store.apply_keepers ~observed_at:now_mono [ mk_k "alpha-1" ]
    |> Fleet_store.apply_chat_history ~observed_at:now_mono ~keeper:"alpha-1"
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
  let render_dive_body (m : Model.t) =
    let geom = Chat_transcript.chat_viewport_geometry ~model:m in
    let rect_h = geom.body_h + 3 in
    let bp = Ops_common.layout_bp m in
    let body_outer =
      Layout.inset_body bp (Rect.make ~x:0 ~y:0 ~w:cols ~h:rect_h)
    in
    let grid = Cell_grid.create ~cols ~rows:rect_h in
    let cache = Card.Cache.create () in
    Screen_keepers.render_dive ~name:"alpha-1" ~tab:Nav.Keeper_chat ~model:m
      ~cache ~rect:body_outer grid;
    grid_all_text grid
  in
  let lines_with ~needle txt =
    List.filter (contains_sub ~needle) (String.split_on_char '\n' txt)
  in
  let txt_bot = render_dive_body m_chat in
  Alcotest.(check bool) "bottom frame shows the operator's last row" true
    (contains_sub ~needle:"OPERATOR_LAST_MARKER" txt_bot);
  Alcotest.(check bool) "operator row keeps the Operator header" true
    (contains_sub ~needle:"Operator" txt_bot);
  let m_home, _ =
    Update.step ~now:now_mono m_chat
      (Msg.Key_event
         {
           Keymap.Input.key = Keymap.Input.Home;
           mods = Keymap.Input.no_mods;
         })
  in
  let txt_top = render_dive_body m_home in
  Alcotest.(check bool) "Home reaches the first peer row" true
    (contains_sub ~needle:"PEER_TOP_MARKER" txt_top);
  let m_dn1, _ =
    Update.step ~now:now_mono m_home
      (Msg.Key_event
         {
           Keymap.Input.key = Keymap.Input.Down;
           mods = Keymap.Input.no_mods;
         })
  in
  Alcotest.(check bool) "one Down after Home moves the frame (no uncounted rows)"
    true
    (not (String.equal txt_top (render_dive_body m_dn1)));
  let broadcast_headers = lines_with ~needle:"leader-1 · broadcast" txt_top in
  Alcotest.(check bool) "broadcast row names its Keeper and route" true
    (broadcast_headers <> []);
  Alcotest.(check bool) "broadcast header is not the operator's" true
    (List.for_all
       (fun line -> not (contains_sub ~needle:"Operator" line))
       broadcast_headers);
  Alcotest.(check bool) "direct row names its Keeper without a route" true
    (contains_sub ~needle:"reviewer-2" txt_top
    && not (contains_sub ~needle:"reviewer-2 · " txt_top));
  let m_inline =
    { m_home with fleet = Fleet_store.cycle_origin_mode m_home.fleet }
  in
  Alcotest.(check bool) "inline origin mode still names the peer" true
    (contains_sub ~needle:"leader-1 · broadcast" (render_dive_body m_inline))

let test_agui_chat_chronological_projection_and_phase_parity () =
  let cols, rows = (120, 36) in
  let mk_k name : Wire_fleet.keeper_summary =
    {
      name;
      group = Some "alpha";
      company = "alpha";
      health = Wire_fleet.Keeper_healthy;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "rt-1";
      model_id = Some "model-1";
      current_task_id = None;
      context = Observed.value ~observed_at:now_mono (measured_context 0.25);
      total_turns = Observed.value ~observed_at:now_mono 3;
      last_turn_at_unix = Some now_unix;
      active_turn = None;
    }
  in
  let find_row_y grid needle =
    let rec scan y =
      if y >= rows then None
      else if contains_sub ~needle (grid_row_text grid ~y) then Some y
      else scan (y + 1)
    in
    scan 0
  in
  let m0 = Model.initial ~cols ~rows ~lang:Say.Lang_ko () in
  let hist_msg : Wire_fleet.chat_message =
    {
      id = "hist-1";
      role = Wire_fleet.Role_user;
      content = "HISTORY_FIRST_MSG";
      ts_unix = now_unix -. 120.0;
      turn_ref = None;
      model_used = None;
      tool_call_id = None;
      tool_call_name = None;
      execution_id = None;
      provenance = operation_provenance "op-old" Accepted_user;
      failure_kind = None;
      thinking = None;
    }
  in
  let m1 =
    {
      m0 with
      fleet =
        m0.fleet
        |> Fleet_store.apply_keepers ~observed_at:now_mono [ mk_k "alpha-leader" ]
        |> Fleet_store.apply_chat_history ~observed_at:now_mono
             ~keeper:"alpha-leader"
             { messages = [ hist_msg ]; has_more = false; next_cursor = None };
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
  (* 1. Submit active turn A (direct), start streaming text, then submit Follow_up B *)
  let m2 = { m1 with drafts = Drafts.insert_text "ACTIVE_USER_A" m1.drafts } in
  let m3, _ = Update.execute_action ~now:now_mono m2 Keymap.Submit_steer in
  let req_a =
    match Drafts.active_tx_for_keeper ~keeper:"alpha-leader" m3.drafts with
    | Some tx -> tx.request_id
    | None -> Alcotest.fail "missing active tx A"
  in
  let m4, _ =
    Update.step ~now:now_mono m3
      (Msg.Chat_stream_chunk
         {
           epoch = m3.epoch;
           keeper = "alpha-leader";
           request_id = req_a;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_text_delta
               {
                 operation_id = Some req_a;
                 delta = "LIVE_STREAM_A_REPLY";
                 owner = Wire_chat_journal.Unobserved_scope None;
               };
         })
  in
  let m5 = { m4 with drafts = Drafts.insert_text "QUEUED_FOLLOWUP_B" m4.drafts } in
  let m6, _ = Update.execute_action ~now:now_mono m5 Keymap.Submit_followup in
  let req_b =
    match List.rev (Drafts.pending_txs_for_keeper ~keeper:"alpha-leader" m6.drafts) with
    | tx :: _ -> tx.request_id
    | [] -> Alcotest.fail "missing queued tx B"
  in
  let m7, _ =
    Update.step ~now:now_mono m6
      (Msg.Chat_stream_chunk
         {
           epoch = m6.epoch;
           keeper = "alpha-leader";
           request_id = req_b;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_accepted
               {
                 operation_id = req_b;
                 queued_count = 1;
                 state = Keeper_chat_operation.State_name.Queued;
                 interactive_outcome = None;
                 control_token = None;
               };
         })
  in
  let grid =
    render_to_grid ~cols ~rows
      (Screen_keepers.render_dive ~name:"alpha-leader" ~tab:Nav.Keeper_chat
         ~model:m7)
  in
  let y_hist = find_row_y grid "HISTORY_FIRST_MSG" in
  let y_user_a = find_row_y grid "ACTIVE_USER_A" in
  let y_stream_a = find_row_y grid "LIVE_STREAM_A_REPLY" in
  let y_queued_b = find_row_y grid "QUEUED_FOLLOWUP_B" in
  (match y_hist, y_user_a, y_stream_a, y_queued_b with
  | Some yh, Some ya, Some ys, Some yq ->
      Alcotest.(check bool)
        (Printf.sprintf "chronological order hist(%d) < active_user(%d) < stream(%d) < queued(%d)"
           yh ya ys yq)
        true (yh < ya && ya < ys && ys < yq)
  | _ ->
      Alcotest.fail
        ("Missing expected chronological sections in rendered grid:\n"
       ^ grid_all_text grid));
  (* Direct idle send A must NOT show misleading 조향 tag *)
  let row_a =
    match y_user_a with Some y -> grid_row_text grid ~y | None -> ""
  in
  Alcotest.(check bool) "Direct send does NOT print 조향" false
    (contains_sub ~needle:"조향" row_a);
  (* 2. Persisted failure reconciliation renders Role_request_failure ONCE with 0 duplicate user rows *)
  let m_err, _ =
    Update.step ~now:now_mono m7
      (Msg.Chat_stream_chunk
         {
           epoch = m7.epoch;
           keeper = "alpha-leader";
           request_id = req_a;
           is_btw = false;
           chunk =
             Wire_fleet.Chunk_error
               {
                 operation_id = Some req_a;
                 code = Some "turn_failed";
                 message = "provider failed";
               };
         })
  in
  let m_reconciled, _ =
    Update.step ~now:now_mono m_err
      (Msg.Http_reply
         {
           epoch = m_err.epoch;
           reply =
             Msg.Reply_chat_history
               {
                 keeper = "alpha-leader";
                 result =
                   Ok
                     {
                       messages =
                         [
                           hist_msg;
                           {
                             id = "hist-2";
                             role = Wire_fleet.Role_user;
                             content = "ACTIVE_USER_A";
                             ts_unix = now_unix -. 10.0;
                             turn_ref = None;
                             model_used = None;
                             tool_call_id = None;
                             tool_call_name = None;
                             execution_id = None;
                             provenance = operation_provenance req_a Accepted_user;
                             failure_kind = None;
                             thinking = None;
                           };
                           {
                             id = "hist-3";
                             role = Wire_fleet.Role_request_failure;
                             content = "provider failed";
                             ts_unix = now_unix -. 9.0;
                             turn_ref = None;
                             model_used = None;
                             tool_call_id = None;
                             tool_call_name = None;
                             execution_id = None;
                             provenance = operation_provenance req_a Settled_failure;
                             failure_kind = Some "turn_exception";
                             thinking = None;
                           };
                         ];
                       has_more = false;
                       next_cursor = None;
                     };
               };
         })
  in
  let grid_rec =
    render_to_grid ~cols ~rows
      (Screen_keepers.render_dive ~name:"alpha-leader" ~tab:Nav.Keeper_chat
         ~model:m_reconciled)
  in
  let txt_rec = grid_all_text grid_rec in
  Alcotest.(check int) "ACTIVE_USER_A appears exactly ONCE after failure persistence"
    1 (count_sub ~needle:"ACTIVE_USER_A" txt_rec);
  Alcotest.(check bool) "Role_request_failure renders failure_kind" true
    (contains_sub ~needle:"turn_exception" txt_rec);
  Alcotest.(check bool) "Stale 스트림 오류 banner is suppressed after persistence" false
    (contains_sub ~needle:"스트림 오류" txt_rec);
  (* 3. Header operator-attention disambiguation (승인/질문 필요, never 응답 대기) *)
  let _, _, attn_lbl =
    Ops_common.keeper_live_status ~has_attention:true (mk_k "alpha-leader")
  in
  Alcotest.(check string) "Attention badge disambiguated in Korean" "승인/질문 필요"
    (Say.resolve Say.Lang_ko attn_lbl)

let cadence_slot ~starts_at ~ok ~scheduled ~reacted ~chat ~own : Wire_fleet.turn_slot =
  { starts_at; ok; rested = 0; failed = 0; scheduled; reacted; chat; own; unknown = 0 }

(* A window is the last [hours * 2] half-hour slots, the current one included,
   and a pulse known only from inside the window says so instead of reading
   as a quiet start. *)
let test_keeper_cadence_window_counts_causes () =
  let slot = Wire_fleet.turn_slot_seconds in
  let now_unix = 1_795_400_000.0 in
  let current = int_of_float now_unix / slot * slot in
  let pulse : Wire_fleet.turn_pulse =
    {
      known_since = now_unix -. 90_000.0;
      slots =
        [
          (* the 6h window's oldest slot starts 11 slots back; 12 is outside *)
          cadence_slot ~starts_at:(current - (12 * slot)) ~ok:2 ~scheduled:2 ~reacted:0 ~chat:0 ~own:0;
          cadence_slot ~starts_at:(current - (11 * slot)) ~ok:3 ~scheduled:1 ~reacted:1 ~chat:1 ~own:0;
          cadence_slot ~starts_at:current ~ok:1 ~scheduled:0 ~reacted:0 ~chat:0 ~own:1;
        ];
    }
  in
  let six = Keeper_cadence.window ~now_unix ~hours:6 pulse in
  Alcotest.(check (list int)) "6h: turns, scheduled, reacted, chat, own"
    [ 4; 1; 1; 1; 1 ] [ six.turns; six.scheduled; six.reacted; six.chat; six.own ];
  Alcotest.(check bool) "6h window is fully known" true (six.known_from = None);
  let day = Keeper_cadence.window ~now_unix ~hours:24 pulse in
  Alcotest.(check int) "24h counts every slot" 6 day.turns;
  let late_start = { pulse with known_since = now_unix -. 3_600.0 } in
  Alcotest.(check (option (float 0.5))) "a pulse known from inside the window names its start"
    (Some (now_unix -. 3_600.0)) (Keeper_cadence.window ~now_unix ~hours:6 late_start).known_from

let cadence_schedules json_rows =
  match
    Wire_work.decode_schedules_snapshot
      (Yojson.Safe.from_string (Printf.sprintf {|{"status":"ok","requests":[%s]}|} json_rows))
  with
  | Ok (rows, _) -> rows
  | Error e -> Alcotest.fail ("schedules decode: " ^ e)

let cadence_row ~id ~keeper ~next_due =
  Printf.sprintf
    {|{"schedule_instance_id":"si-%s","schedule_id":"%s","status":"scheduled","source":"operator",
       "due_at":%s,"next_due_at":%s,"recurrence_kind":"interval","recurrence_summary":"every 15m",
       "payload_kind":"keeper_wake","payload_support":"supported","payload_target":"%s",
       "payload_keeper_name":"%s","payload_summary":"poll",
       "last_wake":{"status":"succeeded","started_at":1795173600.0,"finished_at":1795173605.0}}|}
    id id next_due next_due keeper keeper

(* The earliest due time among the keeper's own schedules decides; another
   keeper's schedule does not. *)
let test_keeper_cadence_next_due () =
  let now_unix = 1_795_400_000.0 in
  let rows =
    cadence_schedules
      (String.concat ","
         [
           cadence_row ~id:"a" ~keeper:"alpha" ~next_due:"1795400900.0";
           cadence_row ~id:"b" ~keeper:"alpha" ~next_due:"1795400300.0";
           cadence_row ~id:"c" ~keeper:"beta" ~next_due:"1795399000.0";
         ])
  in
  let due ?(more_pages = false) name =
    Keeper_cadence.next_due ~now_unix ~more_pages (Keeper_cadence.keeper_schedules ~name rows)
  in
  Alcotest.(check bool) "alpha is due in 300s" true (due "alpha" = Keeper_cadence.Due_in 300.0);
  Alcotest.(check bool) "beta is 1000s late" true (due "beta" = Keeper_cadence.Late_by 1000.0);
  Alcotest.(check bool) "gamma has no schedule" true (due "gamma" = Keeper_cadence.No_schedule);
  Alcotest.(check bool) "gamma may lie past the page read" true
    (due ~more_pages:true "gamma" = Keeper_cadence.Past_page_read)

let test_wave2_keeper_context_tool_calls_and_schedules () =
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let tr_json =
    Yojson.Safe.from_string
      {|{
        "keeper": "e-masc-the-leader",
        "count": 1,
        "skipped_rows": 0,
        "health": "healthy",
        "live_turn_in_progress": false,
        "entries": [
          {
            "diff_vs_prev": null,
            "record": {
              "execution_ids": ["exec-900"],
            "keeper": "e-masc-the-leader",
            "agent_name": "e-masc-the-leader",
            "turn_kind": "direct",
            "trace_id": "tr-900",
            "absolute_turn": 90,
            "turn_ref": "tr-900#90",
            "blocks": [
              { "block": "keeper_instructions", "bytes": 4200, "digest": "aabbcc11223344556677889900aabbcc11223344556677889900aabbcc112233" },
              { "block": "active_goals", "bytes": 900, "digest": "ddeeff4455667788990011223344556677889900aabbccddeeff001122334455" }
            ],
            "input_components": [
              { "component": "prompt.keeper_instructions", "bytes": 4200 },
              { "component": "tool_schemas", "bytes": 7600 },
              { "component": "message_user", "bytes": 400 }
            ],
            "request_observations": [],
            "runtime_profile": "claude-sonnet-4",
            "request_runtime_profile": "claude-sonnet-4",
            "request_body_bytes": 14400,
            "transmitted_atoms": null,
            "total_atoms": null,
            "model_input_measurement": null,
            "model_input_front": null,
            "response_observed_model_input": null,
            "refused_model_input": null,
            "raw_trace_run_ref": null,
            "selected_model": "claude-sonnet-4",
            "finish_reason": "end_turn",
            "context_window": 200000,
            "provider_context_window": 200000,
            "request_latency_ms": 850,
            "input_tokens": 36000,
            "cache_creation_input_tokens": 2000,
            "cache_read_input_tokens": 30000,
            "output_tokens": 500,
            "usage_scope": "per_request",
            "input_provenance": "measured_request",
            "ts": 1795252000.0
            }
          }
        ]
      }|}
  in
  let tr_page =
    match Wire_keeper_context.decode_turn_records tr_json with
    | Ok p -> p
    | Error e -> Alcotest.fail ("decode_turn_records failed: " ^ e)
  in
  let co =
    match
      Wire_keeper_context.decode_cache_outcome
        (Yojson.Safe.from_string
           {|{
             "schema": "masc.keeper-cache-outcome.v1",
             "keeper": "e-masc-the-leader",
             "turn_ref": "tr-900#90",
             "unattributed_rows": 0,
             "outcome": {
               "kind": "first_request",
               "request": {
                 "turn_ref": "tr-900#90", "runtime_id": "claude-sonnet-4",
                 "scope": "per_request", "ended_at": 1795252005.0,
                 "latency_ms": 850, "cache_read_tokens": 30000,
                 "cache_creation_tokens": 2000, "cache_write_lifetime": null
               },
               "other_runtime_since": null,
               "earlier": {
                 "kind": "earlier",
                 "request": {
                   "turn_ref": "tr-900#89", "runtime_id": "claude-sonnet-4",
                   "scope": "per_request", "ended_at": 1795251950.0,
                   "latency_ms": 700, "cache_read_tokens": 28000,
                   "cache_creation_tokens": 0, "cache_write_lifetime": null
                 },
                 "idle": {
                   "kind": "idle", "idle_s": 54.0,
                   "lifetime": { "kind": "declared", "lifetime_s": 300.0, "check": "within" }
                 },
                 "prefix": {
                   "kind": "compared", "system_changed": false, "tools_changed": false,
                   "messages": { "kind": "appended", "kept": 10, "added": 2 }
                 }
               }
             }
           }|})
    with
    | Ok r -> r
    | Error e -> Alcotest.fail ("decode_cache_outcome failed: " ^ e)
  in
  let tc_page =
    match
      Wire_keeper_context.decode_keeper_tool_calls
        (Yojson.Safe.from_string
           {|{
             "keeper": "e-masc-the-leader",
             "count": 1,
             "coverage_gaps_count": 0,
             "entries": [
               {
                 "ts": 1795252001.0,
                 "tool": "masc_board_post",
                 "execution_id": "exec-900",
                 "duration_ms": 48.0,
                 "ok": true,
                 "disposition": "succeeded",
                 "input": { "payload": "{\"title\":\"Wave2\"}" },
                 "output": "posted",
                 "original_bytes": 6,
                 "truncated_to": null
               }
             ]
           }|})
    with
    | Ok p -> p
    | Error e -> Alcotest.fail ("decode_keeper_tool_calls failed: " ^ e)
  in
  let t0 = Clock.Mono.of_ns 10_000_000_000L in
  let kc =
    Keeper_context_store.empty
    |> Keeper_context_store.apply_turn_records ~observed_at:t0
         ~keeper:"e-masc-the-leader" tr_page
    |> Keeper_context_store.apply_cache_outcome ~observed_at:t0
         ~keeper:"e-masc-the-leader" ~turn_ref:"tr-900#90" co
    |> Keeper_context_store.apply_tool_calls ~observed_at:t0
         ~keeper:"e-masc-the-leader" tc_page
  in
  let m_ctx = { m0 with keeper_context = kc } in
  (* All 4 Context sub-tabs render cleanly *)
  List.iter
    (fun subtab ->
      let m_st =
        {
          m_ctx with
          keeper_context =
            Keeper_context_store.set_subtab ~keeper:"e-masc-the-leader" subtab
              m_ctx.keeper_context;
        }
      in
      let g =
        render_to_grid ~cols:140 ~rows:40
          (Screen_keepers.render_dive ~name:"e-masc-the-leader"
             ~tab:Nav.Keeper_context ~model:m_st)
      in
      let txt = grid_all_text g in
      Alcotest.(check bool) "Keeper_context subtab populated" true
        (non_empty_row_count g >= 8);
      match subtab with
      | Keeper_context_store.Ctx_composition ->
          Alcotest.(check bool) "Composition shows turn #90 & cache" true
            (contains_sub ~needle:"90" txt)
      | Keeper_context_store.Ctx_flow ->
          Alcotest.(check bool) "Flow subtab renders turn flow & control strip" true
            (contains_sub ~needle:"/ctl" txt || contains_sub ~needle:"Flow" txt)
      | Keeper_context_store.Ctx_exact_input ->
          Alcotest.(check bool) "Exact_input shows Cache Outcome TTL Within" true
            (contains_sub ~needle:"TTL Within" txt
             || contains_sub ~needle:"Appended" txt)
      | Keeper_context_store.Ctx_input_map ->
          Alcotest.(check bool) "Input_map shows proof table" true
            (contains_sub ~needle:"keeper_instructions" txt
             || contains_sub ~needle:"VERIFIED" txt
             || contains_sub ~needle:"BYTES" txt)
      | Keeper_context_store.Ctx_response ->
          Alcotest.(check bool) "Response subtab renders" true
            (contains_sub ~needle:"Response" txt || contains_sub ~needle:"Transcript" txt))
    Keeper_context_store.all_context_subtabs;
  (* 401/403 permission notice on Exact_input renders gracefully without crashing *)
  let m_denied =
    {
      m_ctx with
      keeper_context =
        m_ctx.keeper_context
        |> Keeper_context_store.set_subtab ~keeper:"e-masc-the-leader"
             Keeper_context_store.Ctx_exact_input
        |> Keeper_context_store.mark_provider_input_denied ~at:t0
             ~keeper:"e-masc-the-leader" ~reason:"403 CanAdmin required";
    }
  in
  let g_den =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"e-masc-the-leader"
         ~tab:Nav.Keeper_context ~model:m_denied)
  in
  Alcotest.(check bool) "Exact_input 403 notice renders gracefully" true
    (contains_sub ~needle:"CanAdmin" (grid_all_text g_den)
     || contains_sub ~needle:"403" (grid_all_text g_den)
     || contains_sub ~needle:"Admin" (grid_all_text g_den));
  (* Keeper_tool_calls renders tool call row + unfolded JSON detail *)
  let g_tc =
    render_to_grid ~cols:140 ~rows:40
      (Screen_keepers.render_dive ~name:"e-masc-the-leader"
         ~tab:Nav.Keeper_tool_calls ~model:m_ctx)
  in
  let txt_tc = grid_all_text g_tc in
  Alcotest.(check bool) "Keeper_tool_calls shows masc_board_post" true
    (contains_sub ~needle:"masc_board_post" txt_tc);
  Alcotest.(check bool) "Keeper_tool_calls unfolds nested JSON string" true
    (contains_sub ~needle:"Wave2" txt_tc);
  (* Dedicated Work_schedules tab renders both populated AND empty state cleanly *)
  let m_empty_sched =
    {
      m0 with
      work =
        Work_store.empty
        |> Work_store.set_tab Nav.Work_schedules
        |> Work_store.apply_schedules ~observed_at:t0 ([], None);
    }
  in
  let g_es = render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m_empty_sched) in
  Alcotest.(check bool) "Empty Work_schedules renders honest notice" true
    (non_empty_row_count g_es >= 5)

let test_layer2_ops_due_delta_cadence_outcomes_and_diagnostics () =
  let now_unix = 1795254000.0 in
  (* 1. Signed due delta distinguishes future vs overdue *)
  let future_en =
    Ops_common.format_due_delta ~now_unix (now_unix +. 300.0) ~lang:Say.Lang_en
  in
  let future_ko =
    Ops_common.format_due_delta ~now_unix (now_unix +. 300.0) ~lang:Say.Lang_ko
  in
  let past_en =
    Ops_common.format_due_delta ~now_unix (now_unix -. 300.0) ~lang:Say.Lang_en
  in
  let past_ko =
    Ops_common.format_due_delta ~now_unix (now_unix -. 300.0) ~lang:Say.Lang_ko
  in
  Alcotest.(check bool) "future EN starts with 'in '" true
    (contains_sub ~needle:"in " future_en);
  Alcotest.(check bool) "future KO ends with '뒤'" true
    (contains_sub ~needle:"뒤" future_ko);
  Alcotest.(check bool) "past EN contains 'late'" true
    (contains_sub ~needle:"late" past_en);
  Alcotest.(check bool) "past KO contains '늦음'" true
    (contains_sub ~needle:"늦음" past_ko);

  (* 2. Keeper_cadence.window exposes ok/rested/failed breakdown *)
  let slot_ts = (int_of_float now_unix / 1800) * 1800 in
  let pulse : Wire_fleet.turn_pulse =
    {
      known_since = Float.of_int (slot_ts - 3600);
      slots =
        [
          {
            starts_at = slot_ts;
            ok = 3;
            rested = 2;
            failed = 1;
            scheduled = 4;
            reacted = 1;
            chat = 1;
            own = 0;
            unknown = 0;
          };
        ];
    }
  in
  let w = Keeper_cadence.window ~now_unix ~hours:6 pulse in
  Alcotest.(check int) "cadence total turns" 6 w.turns;
  Alcotest.(check int) "cadence ok" 3 w.ok;
  Alcotest.(check int) "cadence rested" 2 w.rested;
  Alcotest.(check int) "cadence failed" 1 w.failed;

  (* 3. Fleet_store.path_rest_for gates on runnable keepers + Keeper_dive renders diagnostic banner *)
  let m0 = make_populated_model ~cols:140 ~rows:40 ~lang:Say.Lang_en in
  let extras : Wire_fleet.keeper_roster_extras =
    {
      sandbox_profiles = [];
      candle_balances_milli = [];
      candle_summary = None;
      turn_pulses = [];
      diagnostics =
        [
          ( "e-masc-the-leader"
          , {
              Wire_fleet.empty_keeper_diagnostics with
              runtime_blocker_summary = Some "Quota resting across lane";
              runtime_blocker_signature = Some "lane_quota_rest";
              runtime_path_rest =
                Some
                  {
                    status = "resting";
                    runtime_id = "claude-sonnet-4";
                    release_at_unix = Some (now_unix +. 600.0);
                    release_basis = Some "quota_reset";
                  };
            } );
        ];
      roster_total = Some 25;
      roster_truncated = true;
    }
  in
  let fleet = Fleet_store.apply_roster_extras extras m0.fleet in
  let m1 =
    {
      m0 with
      fleet;
      freshness = { m0.freshness with last_wall_unix = now_unix };
    }
  in
  let leader =
    match Fleet_store.find_keeper ~name:"e-masc-the-leader" m1.fleet with
    | Some k -> k
    | None -> Alcotest.fail "e-masc-the-leader missing in populated model"
  in
  Alcotest.(check bool) "runnable keeper surfaces path_rest" true
    (Option.is_some (Fleet_store.path_rest_for ~keeper:leader m1.fleet));
  Alcotest.(check bool) "paused keeper suppresses path_rest" false
    (Option.is_some
       (Fleet_store.path_rest_for ~keeper:{ leader with paused = true } m1.fleet));
  let g_keepers =
    render_to_grid ~cols:140 ~rows:40 (Screen_keepers.render ~model:m1)
  in
  let txt_keepers = grid_all_text g_keepers in
  Alcotest.(check bool) "Keepers surfaces truncated roster ratio badge" true
    (contains_sub ~needle:"/25" txt_keepers);
  Alcotest.(check bool) "Keeper dive renders diagnostic blocker banner" true
    (contains_sub ~needle:"Quota resting" txt_keepers);
  (* Healthy keeper with benign server pass/direct_message produces 0 banner rows *)
  let benign_extras : Wire_fleet.keeper_roster_extras =
    {
      extras with
      diagnostics =
        [
          ( "e-masc-the-leader"
          , {
              Wire_fleet.empty_keeper_diagnostics with
              operator_disposition = Some "pass";
              operator_disposition_reason = Some "healthy";
              next_action = Some "direct_message";
            } );
        ];
    }
  in
  let m_benign =
    {
      m0 with
      attention = Attention.empty;
      work = Work_store.empty;
      fleet = Fleet_store.apply_roster_extras benign_extras m0.fleet;
    }
  in
  Alcotest.(check int) "benign pass/direct_message emits 0 banner rows" 0
    (List.length
       (Model.keeper_diagnostic_banner ~name:"e-masc-the-leader" m_benign));
  let banner_with_hitl =
    Model.keeper_diagnostic_banner ~name:"e-masc-the-leader" m0
    |> List.map (fun (r : Model.keeper_banner_row) -> r.text)
    |> String.concat " | "
  in
  Alcotest.(check bool) "unified blocker banner correlates HITL pending for keeper"
    true (contains_sub ~needle:"HITL pending" banner_with_hitl);
  (* Layer 3: Empty Work > Inbox renders live server gate_resolved_row 'approve' honestly *)
  let gate_snap : Wire_work.gate_snapshot =
    {
      generated_at = Some "2026-11-25T03:00:00Z";
      pending = [];
      retry_meta = [];
      rules = [];
      rules_error = None;
      recent_resolved =
        [
          {
            id = "gr-1";
            event = "resolved";
            keeper = "e-masc-the-leader";
            tool = "masc_board_post";
            decision = "approve";
            decision_kind = Some "approve";
            decision_reason = Some "safe post";
            decision_source = Some "operator";
            authorization_source = None;
            actor = Some "jeong-sik";
            ts = now_unix -. 60.0;
          };
        ];
      recent_resolved_error = None;
      hitl = None;
    }
  in
  let m_server_audit =
    {
      m0 with
      attention = Attention.empty;
      work =
        {
          m0.work with
          active_tab = Nav.Work_inbox;
          recent_decisions_24h = [];
          gate_snapshot = Observed.value ~observed_at:now_mono gate_snap;
        };
    }
  in
  let g_audit =
    render_to_grid ~cols:140 ~rows:40 (Screen_work.render ~model:m_server_audit)
  in
  let txt_audit = grid_all_text g_audit in
  Alcotest.(check bool) "Empty Work Inbox surfaces Server Gate Decisions with live 'approve'"
    true
    (contains_sub ~needle:"Server Gate Decisions" txt_audit
     && contains_sub ~needle:"approve" txt_audit
     && contains_sub ~needle:"masc_board_post" txt_audit)

(* --- Chat history rows: laid out once, kept while nothing changed --- *)

let history_msg ~id ~role ~content ~thinking ~seconds_ago :
    Wire_fleet.chat_message =
  {
    id;
    role;
    content;
    ts_unix = now_unix -. seconds_ago;
    turn_ref = Some "t-history";
    model_used = None;
    tool_call_id = None;
    tool_call_name = None;
    execution_id = None;
    provenance = None;
    failure_kind = None;
    thinking;
  }

let apply_history keeper messages fleet =
  Fleet_store.apply_chat_history ~observed_at:now_mono ~keeper
    { messages; has_more = false; next_cursor = None }
    fleet

(* A fleet whose named keepers each store [n] Markdown messages. A reply
   carries a visible block of its thinking. *)
let make_history_model ~n keepers =
  let m = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko () in
  let message i =
    history_msg ~id:(Printf.sprintf "h-%d" i)
      ~role:(if i mod 2 = 0 then Wire_fleet.Role_user else Wire_fleet.Role_assistant)
      ~content:
        (Printf.sprintf
           "메시지 %d번입니다.\n\n- 항목 하나\n- 항목 둘\n\n```ocaml\nlet x = %d\n```"
           i i)
      ~thinking:
        (if i mod 2 = 0 then None
         else Some (Wire_fleet.Thinking_visible (Printf.sprintf "생각 %d" i)))
      ~seconds_ago:(float_of_int (600 - i))
  in
  let messages = List.init n message in
  let fleet =
    Fleet_store.apply_keepers ~observed_at:now_mono sample_keepers m.fleet
  in
  let fleet =
    List.fold_left
      (fun fleet keeper -> apply_history keeper messages fleet)
      fleet keepers
  in
  { m with fleet }

(* The chat tab of one keeper, drawn with or without kept history rows. *)
let draw_chat ?history_rows ~cols ~name model =
  render_to_grid ~cols ~rows:40
    (Screen_keepers.render_dive_with_history_rows ~name ~tab:Nav.Keeper_chat
       ~history_rows ~model)

let test_chat_history_rows_kept_draw_a_fresh_layout () =
  let name = "e-masc-the-leader" in
  let m = make_history_model ~n:24 [ name ] in
  let kept = Keeper_dive.History_rows.create () in
  let fresh = draw_chat ~cols:140 ~name m in
  Alcotest.(check bool) "the stored history is on screen" true
    (contains_sub ~needle:"항목 둘" (grid_all_text fresh));
  let first = draw_chat ~history_rows:kept ~cols:140 ~name m in
  let second = draw_chat ~history_rows:kept ~cols:140 ~name m in
  Alcotest.(check bool) "first draw from the kept rows draws the fresh layout"
    true (grids_draw_the_same fresh first);
  Alcotest.(check bool) "second draw from the kept rows draws the fresh layout"
    true (grids_draw_the_same fresh second);
  let s = Keeper_dive.History_rows.stats kept in
  Alcotest.(check int) "history laid out once" 1 s.misses;
  Alcotest.(check int) "second draw reused the rows" 1 s.hits;
  Alcotest.(check int) "one keeper kept" 1 s.entries

(* The messages the model stores for one keeper. *)
let stored_history (model : Model.t) keeper =
  match Fleet_store.String_map.find_opt keeper model.fleet.chat_histories with
  | Some obs -> (
      match Observed.to_option obs with
      | Some page -> page.messages
      | None -> Alcotest.fail "the stored history is not reported")
  | None -> Alcotest.fail "the keeper has no stored history"

let test_chat_history_rows_are_laid_out_again_when_an_input_changes () =
  let name = "e-masc-the-leader" in
  let m = make_history_model ~n:12 [ name ] in
  let kept = Keeper_dive.History_rows.create () in
  ignore (draw_chat ~history_rows:kept ~cols:140 ~name m);
  let with_one_more_message =
    {
      m with
      fleet =
        apply_history name
          (stored_history m name
          @ [
              history_msg ~id:"h-new" ~role:Wire_fleet.Role_user
                ~content:"새 메시지" ~thinking:None ~seconds_ago:1.;
            ])
          m.fleet;
    }
  in
  (* Each one differs from [m] in a single input of the history rows. *)
  let changed =
    [
      ("a new message", with_one_more_message, 140);
      ("a narrower pane", m, 100);
      ("another theme", { m with theme_preset = Theme.Paper_light }, 140);
      ("another language", { m with lang = Say.Lang_en }, 140);
      ( "another time zone",
        { m with tz_offset_sec = m.tz_offset_sec + 3600 },
        140 );
      ( "another origin mode",
        { m with fleet = Fleet_store.cycle_origin_mode m.fleet },
        140 );
      ( "another tools mode",
        { m with fleet = Fleet_store.set_tools_mode Slash.Tools_results m.fleet },
        140 );
      ( "expanded turn details",
        { m with fleet = Fleet_store.toggle_turn_details m.fleet },
        140 );
      ( "another thinking mode",
        { m with fleet = Fleet_store.cycle_thinking_mode m.fleet },
        140 );
    ]
  in
  List.iter
    (fun (what, changed_model, cols) ->
      let fresh = draw_chat ~cols ~name changed_model in
      let from_kept = draw_chat ~history_rows:kept ~cols ~name changed_model in
      Alcotest.(check bool)
        (Printf.sprintf "%s: kept rows draw the fresh layout" what)
        true (grids_draw_the_same fresh from_kept))
    changed;
  let s = Keeper_dive.History_rows.stats kept in
  Alcotest.(check int) "every changed input laid the history out again" 10
    s.misses;
  Alcotest.(check int) "no changed input reused rows laid out for another" 0 s.hits

let test_chat_history_rows_keep_the_keepers_drawn_last () =
  let names = [ "e-masc-the-leader"; "code-reviewer"; "wkbl-growth" ] in
  let m = make_history_model ~n:4 names in
  let kept = Keeper_dive.History_rows.create ~capacity:2 () in
  let draw name = ignore (draw_chat ~history_rows:kept ~cols:140 ~name m) in
  List.iter draw
    [ "e-masc-the-leader"; "code-reviewer"; "e-masc-the-leader"; "wkbl-growth" ];
  let s = Keeper_dive.History_rows.stats kept in
  Alcotest.(check int) "two keepers kept" 2 s.entries;
  Alcotest.(check int) "three histories laid out" 3 s.misses;
  Alcotest.(check int) "the keeper drawn again reused its rows" 1 s.hits;
  Alcotest.(check int) "the keeper drawn longest ago was dropped" 1 s.evictions;
  draw "code-reviewer";
  let s = Keeper_dive.History_rows.stats kept in
  Alcotest.(check int) "a dropped keeper is laid out again" 4 s.misses;
  Alcotest.(check int) "the keeper now drawn longest ago was dropped" 2 s.evictions

let test_chat_history_rows_keep_one_slot_per_keeper () =
  let first = "e-masc-the-leader" in
  let second = "code-reviewer" in
  let m = make_history_model ~n:4 [ first; second ] in
  let kept = Keeper_dive.History_rows.create ~capacity:2 () in
  let draw name model =
    ignore (draw_chat ~history_rows:kept ~cols:140 ~name model)
  in
  (* The first keeper gets one more message. *)
  let with_one_more_message model =
    let extra =
      history_msg ~id:"h-new" ~role:Wire_fleet.Role_user ~content:"새 메시지"
        ~thinking:None ~seconds_ago:1.
    in
    let messages = stored_history model first @ [ extra ] in
    { model with fleet = apply_history first messages model.fleet }
  in
  draw first m;
  draw second m;
  (* Both slots are taken. The keeper drawn first gets two messages in a
     row, each laid out again. *)
  let m1 = with_one_more_message m in
  draw first m1;
  let m2 = with_one_more_message m1 in
  draw first m2;
  draw second m;
  let s = Keeper_dive.History_rows.stats kept in
  Alcotest.(check int) "two keepers kept" 2 s.entries;
  Alcotest.(check int) "four histories laid out" 4 s.misses;
  Alcotest.(check int) "the other keeper still has its rows" 1 s.hits;
  Alcotest.(check int) "a new message dropped no keeper" 0 s.evictions

let () =
  Alcotest.run "masc_tui_screens_ops"
    [
      ( "keepers"
      , [
          Alcotest.test_case "layer2 due_delta, cadence outcomes, path_rest & diagnostics" `Quick
            test_layer2_ops_due_delta_cadence_outcomes_and_diagnostics;
          Alcotest.test_case "cadence window counts causes" `Quick
            test_keeper_cadence_window_counts_causes;
          Alcotest.test_case "cadence next due is the keeper's earliest" `Quick
            test_keeper_cadence_next_due;
          Alcotest.test_case "all 3 roster modes at 140x40 & 90x28 (KO/EN)"
            `Quick test_keepers_all_modes_viewports_langs;
          Alcotest.test_case "strict live SSOT vs historical 12h trail" `Quick
            test_keepers_strict_live_vs_historical_separation;
          Alcotest.test_case "all 7 Keeper Dive tabs + SSH sandbox (KO/EN)"
            `Quick test_keeper_dive_all_5_tabs;
          Alcotest.test_case "scope-mismatched Memory/Config & Field_secret masking"
            `Quick test_p1_scope_mismatch_memory_and_config;
          Alcotest.test_case "completed stream dedup, untyped Role_tool & code bg"
            `Quick test_p1_chat_dedup_untyped_tool_and_code_bg;
          Alcotest.test_case "v2.5 5-company Fleet Tree, sparklines & Preview Inspector"
            `Quick test_v25_keepers_5_company_fleet_tree_and_preview_inspector;
          Alcotest.test_case "v2.5 Keeper Dive Chat archetypes, italic Thinking & Empty State"
            `Quick test_v25_keeper_dive_chat_claude_code_archetypes_and_empty_state;
          Alcotest.test_case "P1 Keeper Dive tool cards scrub JSON, non-JSON & truncated secrets"
            `Quick test_p1_keeper_dive_tool_card_secret_redaction;
          Alcotest.test_case "P2 Tools_results [Ctrl+O] vs Tools_full cap & 3 distinct Ctrl+F origins"
            `Quick test_p2_tool_modes_ctrl_o_hint_and_origin_modes;
          Alcotest.test_case "P2 Standard (104/112) Keepers 36/64 split & unclipped Korean KPIs"
            `Quick test_p2_standard_viewport_keepers_split_and_kpi_visibility;
          Alcotest.test_case "P0-1 Keeper Dive honest 24h vs lifetime turns & uppercase [V] hint"
            `Quick test_p0_keeper_dive_honest_24h_vs_lifetime_turns;
          Alcotest.test_case "Nav display-order monotonic Left_rail row progression & collapse"
            `Quick test_nav_keepers_display_order_monotonic_screen_rows;
          Alcotest.test_case "P1 #1: Chat_transcript Home/Down render parity (narrow Markdown + JSON tool + dedup)"
            `Quick test_p1_chat_transcript_render_parity;
          Alcotest.test_case "Chat rows from another Keeper name their author, not Operator"
            `Quick test_chat_peer_rows_name_their_author;
          Alcotest.test_case "kept chat history rows draw what a fresh layout draws"
            `Quick test_chat_history_rows_kept_draw_a_fresh_layout;
          Alcotest.test_case
            "kept chat history rows are laid out again when an input changes"
            `Quick
            test_chat_history_rows_are_laid_out_again_when_an_input_changes;
          Alcotest.test_case "kept chat history rows hold the keepers drawn last"
            `Quick test_chat_history_rows_keep_the_keepers_drawn_last;
          Alcotest.test_case "kept chat history rows keep one slot per keeper"
            `Quick test_chat_history_rows_keep_one_slot_per_keeper;
          Alcotest.test_case "AG-UI chat chronological projection, dedup & SSOT phase parity"
            `Quick test_agui_chat_chronological_projection_and_phase_parity;
          Alcotest.test_case "Keeper cadence window counts wake causes and notes short windows"
            `Quick test_keeper_cadence_window_counts_causes;
          Alcotest.test_case "Keeper cadence next_due selects earliest keeper schedule"
            `Quick test_keeper_cadence_next_due;
          Alcotest.test_case "Feature Wave 2: Keeper Context (4 subtabs + 403), Tool Calls & Work_schedules"
            `Quick test_wave2_keeper_context_tool_calls_and_schedules;
        ] );
      ( "work"
      , [
          Alcotest.test_case "all 4 Work sub-tabs + empty Inbox audit (KO/EN)"
            `Quick test_work_all_4_subtabs_and_empty_inbox;
          Alcotest.test_case "Goal/Task/Verification Dives + opt-in Json_tree"
            `Quick test_work_dives_and_json_tree;
          Alcotest.test_case "Inbox truncated/non-JSON secret scrubbing" `Quick
            test_p1_inbox_truncated_secrets_scrubbed;
          Alcotest.test_case "Pipeline 0-link isolation & Tasks/Schedules selection sync"
            `Quick test_p1_pipeline_and_tasks_selection_sync;
          Alcotest.test_case "0-supply Candle decay, company counts & filter isolation"
            `Quick test_p2_zero_candle_decay_company_counts_and_filter_isolation;
          Alcotest.test_case "v2.5 Pipeline adaptive height, Linked card & 0/4 gauge"
            `Quick test_v25_work_pipeline_adaptive_height_and_linked_card;
          Alcotest.test_case "v2.5 Candle peer cards (zero nested boxes) & Violet AI"
            `Quick test_v25_candle_peer_cards_zero_nested_boxes_and_violet_ai;
          Alcotest.test_case "populated tight rects (20x6, 10x4) preserve borders"
            `Quick test_p2_tight_populated_rects_preserve_borders;
          Alcotest.test_case "empty & populated tiny rect resilience across all tabs/dives"
            `Quick test_degenerate_empty_and_tiny_rects;
        ] );
    ]
