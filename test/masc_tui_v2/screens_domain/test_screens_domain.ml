open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store
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

let now_mono = Clock.Mono.of_ns 1_000_000_000L
let now_unix = 1_795_252_092.0

let grid_all_text (grid : Cell_grid.t) =
  let cols = Cell_grid.cols grid in
  let rows = Cell_grid.rows grid in
  let buf = Buffer.create (cols * rows) in
  for y = 0 to rows - 1 do
    for x = 0 to cols - 1 do
      let c = Cell_grid.get grid ~x ~y in
      match c.glyph with
      | Cell_grid.Empty -> Buffer.add_char buf ' '
      | Cell_grid.Ascii ch -> Buffer.add_char buf ch
      | Cell_grid.Braille mask ->
          Buffer.add_string buf (Cell_grid.braille_utf8 mask)
      | Cell_grid.Utf8 s -> Buffer.add_string buf s
      | Cell_grid.Continuation -> ()
    done;
    Buffer.add_char buf '\n'
  done;
  Buffer.contents buf

let contains_sub ~needle ~haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else
    let rec scan i =
      if i + n > h then false
      else if String.equal (String.sub haystack i n) needle then true
      else scan (i + 1)
    in
    scan 0

let forbidden_emojis = [ "⚠"; "⚡"; "🔒"; "🔥"; "🚀"; "✅" ]

let assert_grid_invariants ~label (grid : Cell_grid.t) =
  let cols = Cell_grid.cols grid in
  let rows = Cell_grid.rows grid in
  let non_empty = ref 0 in
  for y = 0 to rows - 1 do
    let top_opens = ref [] in
    let top_closes = ref [] in
    let bot_opens = ref [] in
    let bot_closes = ref [] in
    for x = 0 to cols - 1 do
      let c = Cell_grid.get grid ~x ~y in
      (match c.glyph with
       | Cell_grid.Empty -> ()
       | Cell_grid.Ascii _ | Cell_grid.Braille _ | Cell_grid.Utf8 _ ->
           incr non_empty
       | Cell_grid.Continuation -> ());
      (* CJK / wide-cell integrity invariant *)
      if c.width = 2 then begin
        if x + 1 >= cols then
          Alcotest.failf "%s: width-2 glyph overflow at (%d,%d)" label x y;
        let next = Cell_grid.get grid ~x:(x + 1) ~y in
        match next.glyph with
        | Cell_grid.Continuation when next.width = 0 -> ()
        | _ ->
            Alcotest.failf
              "%s: width-2 glyph at (%d,%d) missing Continuation partner" label
              x y
      end;
      (match c.glyph with
       | Cell_grid.Continuation ->
           if x = 0 then
             Alcotest.failf "%s: orphan Continuation at col 0 row %d" label y;
           let prev = Cell_grid.get grid ~x:(x - 1) ~y in
           if prev.width <> 2 then
             Alcotest.failf
               "%s: orphan Continuation at (%d,%d) without width-2 leader" label
               x y
       | Cell_grid.Utf8 s ->
           List.iter
             (fun bad ->
               if contains_sub ~needle:bad ~haystack:s then
                 Alcotest.failf
                   "%s: forbidden width-ambiguous emoji %S at (%d,%d)" label bad
                   x y)
             forbidden_emojis;
           if String.equal s "╭" then top_opens := x :: !top_opens
           else if String.equal s "╮" then top_closes := x :: !top_closes
           else if String.equal s "╰" then bot_opens := x :: !bot_opens
           else if String.equal s "╯" then bot_closes := x :: !bot_closes
       | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Braille _ -> ())
    done;
    (* Every closing card corner ╮/╯ must pair with an opening corner ╭/╰ to its left,
       and every closed card must have vertical │ sides down to a matching ╰..╯. *)
    List.iter
      (fun rx ->
        let has_open = List.exists (fun lx -> lx < rx) !top_opens in
        Alcotest.(check bool)
          (Printf.sprintf "%s row %d top-right corner at x=%d has top-left partner"
             label y rx)
          true has_open;
        (* Find nearest matching top-left corner for this card *)
        let lx_opt =
          !top_opens
          |> List.filter (fun lx -> lx < rx)
          |> List.fold_left
               (fun best lx ->
                 match best with None -> Some lx | Some b -> Some (Int.max b lx))
               None
        in
        match lx_opt with
        | None -> ()
        | Some lx ->
            let rec find_bottom ry =
              if ry >= rows then false
              else
                let lc = Cell_grid.get grid ~x:lx ~y:ry in
                let rc = Cell_grid.get grid ~x:rx ~y:ry in
                match lc.glyph, rc.glyph with
                | Cell_grid.Utf8 "╰", Cell_grid.Utf8 "╯" -> true
                | Cell_grid.Utf8 "│", Cell_grid.Utf8 "│" ->
                    find_bottom (ry + 1)
                | _ -> false
            in
            Alcotest.(check bool)
              (Printf.sprintf "%s card [%d..%d] starting at row %d closes cleanly"
                 label lx rx y)
              true
              (find_bottom (y + 1)))
      !top_closes;
    List.iter
      (fun rx ->
        let has_open = List.exists (fun lx -> lx < rx) !bot_opens in
        Alcotest.(check bool)
          (Printf.sprintf
             "%s row %d bottom-right corner at x=%d has bottom-left partner"
             label y rx)
          true has_open)
      !bot_closes
  done;
  Alcotest.(check bool)
    (Printf.sprintf "%s rendered non-empty content" label)
    true (!non_empty > 20)

(* --- Rich Fixture Model Covering Knowledge, Runtime, and Infra --- *)

let make_rich_model ~lang ~cols ~rows =
  let m0 = Model.initial ~cols ~rows ~lang () in
  let freshness = { m0.freshness with last_wall_unix = now_unix } in
  (* Fleet keepers + Done tasks for Company & Cost/Solved join *)
  let keeper_a : Wire_fleet.keeper_summary =
    {
      name = "e-masc-the-leader";
      group = Some "MASC Core Eng";
      company = "MASC Core Eng";
      health = Wire_fleet.Keeper_working;
      paused = false;
      keepalive_running = true;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "claude-opus-1";
      model_id = Some "claude-opus-4";
      current_task_id = Some "task-3898";
      context = Observed.value ~observed_at:now_mono (measured_context 0.48);
      total_turns = Observed.value ~observed_at:now_mono 312;
      last_turn_at_unix = Some (now_unix -. 30.0);
      active_turn = None;
      activity_sparkline_24h = [ 1.0; 3.0; 5.0; 4.0 ];
    }
  in
  let keeper_b : Wire_fleet.keeper_summary =
    {
      keeper_a with
      name = "code-reviewer";
      group = Some "Code Review Family";
      company = "Code Review Family";
      runtime_id = "glm-5-3";
    }
  in
  let fleet = Fleet_store.apply_keepers ~observed_at:now_mono [ keeper_a; keeper_b ] m0.fleet in
  let done_task_1 : Wire_work.task =
    {
      id = "task-1";
      title = "Review PR #54340";
      description = None;
      priority = 1;
      status =
        Wire_work.Done
          {
            assignee = "code-reviewer";
            completed_at = "2026-11-21T12:00:00Z";
            notes = None;
          };
      goal_link = Wire_work.Linked "goal-1";
      created_at = None;
      updated_at = None;
    }
  in
  let done_task_2 : Wire_work.task =
    {
      done_task_1 with
      id = "task-2";
      status =
        Wire_work.Done
          {
            assignee = "e-masc-the-leader";
            completed_at = "2026-11-21T13:00:00Z";
            notes = None;
          };
    }
  in
  let work =
    Work_store.apply_planning ~observed_at:now_mono
      { goals = []; tasks = [ done_task_1; done_task_2 ] }
      m0.work
  in
  (* Knowledge fixtures *)
  let p1 : Wire_knowledge.board_post =
    {
      id = "p-chain-22";
      title = "WKBL 조정 타래 (22) — 11월 외부 방문 캠페인";
      body =
        "## 핵심 진행\n\n- **#54344** `W2 경보` MERGED 확인\n- [Wiki RFC](masc://wiki/wkbl-campaign) 갱신 완료";
      author = "wkbl-web-leader";
      hearth = Some "wkbl";
      post_kind = Some Wire_knowledge.Human_post;
      visibility = Some Wire_knowledge.Vis_internal;
      created_at_unix = now_unix -. 840.0;
      updated_at_unix = Some (now_unix -. 120.0);
      score = 3;
      comment_count = 2;
      author_karma = Observed.value ~observed_at:now_mono 14;
      succession_chain_root_id = Some "chain-wkbl";
      chain_depth = Some 22;
      is_signal = true;
    }
  in
  let p2 : Wire_knowledge.board_post =
    {
      p1 with
      id = "p-chain-21";
      title = "WKBL 조정 타래 (21) — 선행 점검";
      author = "wkbl-growth";
      created_at_unix = now_unix -. 3600.0;
      chain_depth = Some 21;
    }
  in
  let p3 : Wire_knowledge.board_post =
    {
      id = "p-direct-1";
      title = "3-Stack Native Overhaul 착수 보고";
      body = "Clockwork, ACP, Living Memory 착수.";
      author = "e-masc-the-leader";
      hearth = Some "ops";
      post_kind = Some Wire_knowledge.Automation_post;
      visibility = Some Wire_knowledge.Vis_direct;
      created_at_unix = now_unix -. 900.0;
      updated_at_unix = None;
      score = 5;
      comment_count = 1;
      author_karma = Observed.unreported;
      succession_chain_root_id = None;
      chain_depth = None;
      is_signal = true;
    }
  in
  let p_noise : Wire_knowledge.board_post =
    {
      id = "p-verify-noise";
      title = "Verify: automated heartbeat check #991";
      body = "automated verify output";
      author = "verifier-bot";
      hearth = Some "sandbox";
      post_kind = Some Wire_knowledge.System_post;
      visibility = Some Wire_knowledge.Vis_internal;
      created_at_unix = now_unix -. 60.0;
      updated_at_unix = None;
      score = 0;
      comment_count = 0;
      author_karma = Observed.absent;
      succession_chain_root_id = None;
      chain_depth = None;
      is_signal = false;
    }
  in
  let comments : Wire_knowledge.board_comment list =
    [
      {
        id = "c-1";
        post_id = "p-chain-22";
        parent_id = None;
        author = "code-reviewer";
        body = "#54340 on-head review posted cleanly.";
        created_at_unix = now_unix -. 540.0;
        score = 2;
      };
    ]
  in
  let quarantines : Wire_knowledge.quarantine_candidate list =
    [
      {
        partition_id = "part-wkbl-01";
        quarantine_id = "q-deadbeef-01";
        keeper = "wkbl-front";
        post_id = "p-chain-22";
        status = "quarantined";
        failure_reason = "durable_partition_invariant";
        quarantined_at_unix = Some (now_unix -. 420.0);
      };
      {
        partition_id = "part-gloss-02";
        quarantine_id = "q-cafebabe-02";
        keeper = "glossary-maniac";
        post_id = "p-direct-1";
        status = "quarantined";
        failure_reason = "owner_lane_rejected";
        quarantined_at_unix = Some (now_unix -. 900.0);
      };
    ]
  in
  let lint_counts : Wire_knowledge.wiki_lint_counts =
    {
      broken_link = 1;
      unsupported_link = 0;
      orphan = 1;
      orphan_unconfirmed = 0;
      missing_sources = 0;
      hearsay_only = 0;
      unreadable_page = 0;
      revision_log_gap = 0;
      revision_log_hole = 0;
      duplicate_title_candidates = 1;
    }
  in
  let dup_cand : Wire_knowledge.wiki_duplicate_candidate =
    {
      page_a = "release-runbook";
      title_a = "Release Runbook";
      page_b = "release-guide";
      title_b = "Release Runbook";
      reason = "normalized_title_match";
    }
  in
  let wiki_page_1 : Wire_knowledge.wiki_page_summary =
    {
      slug = "release-runbook";
      file = "release-runbook.md";
      title = "릴리스 런북 (Release Runbook)";
      summary = "Native Stack 병합 및 릴리스 검증 절차";
      source = Wire_knowledge.Source_direct_experience;
      author = "e-masc-the-leader";
      created = "2026-10-01";
      updated = "2026-11-21";
      revision = 7;
      tags = [ "engineering"; "release" ];
      backlink_count = 4;
      outgoing_link_count = 3;
      sources_count = 2;
      hearsay_count = 0;
      sha256 = "abc1234567890def";
    }
  in
  let wiki_page_2 : Wire_knowledge.wiki_page_summary =
    {
      wiki_page_1 with
      slug = "orphan-notes";
      file = "orphan-notes.md";
      title = "고아 연구 메모";
      tags = [ "research" ];
      backlink_count = 0;
      revision = 2;
    }
  in
  let wiki_index : Wire_knowledge.wiki_index =
    {
      pages_total = 2;
      pages_readable = 2;
      pages_unreadable = 0;
      pages = [ wiki_page_1; wiki_page_2 ];
      unreadable_pages = [];
      lint =
        {
          total_findings = 3;
          counts = lint_counts;
          log_hole_suppressed = false;
          orphans = [ "orphan-notes" ];
          duplicate_title_candidates = [ dup_cand ];
          findings = [];
        };
    }
  in
  let wiki_detail : Wire_knowledge.wiki_page_detail =
    {
      page = "release-runbook";
      slug = "release-runbook";
      file = "release-runbook.md";
      frontmatter =
        {
          title = "릴리스 런북 (Release Runbook)";
          summary = "Native Stack 병합 및 릴리스 검증 절차";
          source = Wire_knowledge.Source_direct_experience;
          author = "e-masc-the-leader";
          created = "2026-10-01";
          updated = "2026-11-21";
          revision = 7;
          tags = [ "engineering"; "release" ];
        };
      sha256 = "abc1234567890def";
      body_markdown =
        "# 릴리스 런북\n\n[Stack Guide](https://github.com/jeong-sik/masc) 확인.\n\n```ocaml\nlet ok = true\n```";
      outgoing_links =
        [
          {
            text = "Stack Guide";
            target =
              Wire_knowledge.Link_page { slug = "stack-guide"; exists = true };
            raw = "stack-guide.md";
            line = 3;
          };
          {
            text = "Missing Page";
            target = Wire_knowledge.Link_page { slug = "missing"; exists = false };
            raw = "missing.md";
            line = 5;
          };
        ];
      backlinks = [ "wiki-home"; "ops-checklist" ];
      lint_findings =
        [
          {
            kind = Wire_knowledge.Broken_link;
            subject = "missing";
            page = Some "release-runbook";
            file = None;
            line = Some 5;
            target = Some "missing";
            form = None;
            reason = Some "target not found";
            log_revision = None;
            page_revision = None;
            missing_revision = None;
          };
        ];
    }
  in
  let wiki_log : Wire_knowledge.wiki_log_response =
    {
      total_lines = 1;
      entries =
        [
          {
            idx = 1;
            written_at_unix = now_unix -. 600.0;
            action = "update";
            revision = 7;
            page = "release-runbook";
            author = Some "e-masc-the-leader";
            note = Some "Add Native Stack rules";
          };
        ];
      unknown_action = 0;
      unreadable_line = 0;
      limit = 20;
    }
  in
  let artifact_1 : Wire_knowledge.artifact_entry =
    {
      id = "artifact-e3b0c44298fc1c149afbf4c8996fb924";
      revision = 3;
      title = "일일 성과 리포트";
      summary = "2026-11-21 경기 지표 요약";
      author = "wkbl-web-leader";
      created_at_unix = now_unix -. 1200.0;
      body =
        {
          sha256 =
            "e3b0c44298fc1c149afbf4c8996fb924e3b0c44298fc1c149afbf4c8996fb924";
          bytes = 48_120;
          mime = "text/html";
        };
    }
  in
  let world_memory : Wire_knowledge.world_memory =
    {
      ledger_state = Wire_knowledge.World_ledger_available;
      ledger_sha256 = Some "9f86d081884c";
      claims_count = 1025;
      facts_count = 1134;
      conflicts_count = 2;
      excluded_count = 11;
      claims =
        [
          {
            claim_id = "cl-1";
            claim = "Native Stack merges from top PR only";
            stage = "confirmed";
            supporting_keepers = [ "e-masc-the-leader"; "code-reviewer" ];
            support_count = 2;
            has_source_bound = true;
          };
        ];
      active_conflicts =
        [
          {
            conflict_id = "conf-01";
            description = "main CI trigger policy mismatch";
            member_count = 2;
            competing_claims =
              [
                {
                  store_kind = "keeper";
                  keeper_id = "e-masc-the-leader";
                  path = Some "board:p-1";
                  claim_sha256 = "1111aaaa";
                  resolved = false;
                  claim = Some "cron-minimal every 30m only";
                  category = Some "constraint";
                  origin = Some "derived:board:p-1";
                  first_seen_unix = Some (now_unix -. 7200.0);
                  last_seen_unix = Some (now_unix -. 300.0);
                };
                {
                  store_kind = "keeper";
                  keeper_id = "pr-updater";
                  path = Some "board:p-2";
                  claim_sha256 = "2222bbbb";
                  resolved = false;
                  claim = Some "full PR trigger on push";
                  category = Some "constraint";
                  origin = Some "derived:board:p-2";
                  first_seen_unix = Some (now_unix -. 3600.0);
                  last_seen_unix = Some (now_unix -. 200.0);
                };
              ];
          };
        ];
      briefing =
        {
          status = Wire_knowledge.Briefing_current;
          text = Some "3-Stack Overhaul active; 2 live conflicts pending";
          source_ids_count = 18;
          error = None;
          building_pass = None;
        };
      librarian_writers =
        Wire_knowledge.Writers_running
          {
            error_count = 0;
            warn_count = 1;
            keepers =
              [
                {
                  keeper = "e-masc-the-leader";
                  state = Wire_knowledge.Writer_idle;
                  available_act_tokens = [ "resume"; "adopt" ];
                  snapshot_file = None;
                };
                {
                  keeper = "wkbl-growth";
                  state = Wire_knowledge.Writer_resting;
                  available_act_tokens =
                    [ "resume"; "restart_reading"; "skip_item"; "skip_line" ];
                  snapshot_file = None;
                };
              ];
          };
      ordinary_absence_detail = None;
    }
  in
  let fact_added : Wire_knowledge.memory_fact_entry =
    {
      added_at_rev = Some 3828;
      memory_id = "mem-101";
      category = "constraint";
      origin = "derived:board:p-ead334";
      text = "Check full stack approval before ready transition";
      first_seen_unix = now_unix -. 7200.0;
      last_seen_unix = Some (now_unix -. 600.0);
      retrieval_count = 12;
      last_retrieved_at_unix = Some (now_unix -. 120.0);
      heat = Wire_knowledge.Heat_hot;
    }
  in
  let fact_before : Wire_knowledge.memory_fact_entry =
    {
      fact_added with
      memory_id = "mem-102";
      category = "lesson";
      text = "Run full dune build before push";
      retrieval_count = 4;
      heat = Wire_knowledge.Heat_warm;
    }
  in
  let fact_after : Wire_knowledge.memory_fact_entry =
    {
      fact_before with
      text = "Use targeted minimal check; skip full local sweep";
    }
  in
  let keeper_diff : Wire_knowledge.memory_diff =
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
          hot = 14;
          warm = 28;
          cold = 90;
          never_retrieved = 12;
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
                invalidated = 1;
                journal_failures_in_window = 0;
                journal_quarantines_in_window = 0;
                undecodable_journal_lines = 0;
              };
            revisions =
              [
                {
                  rev = 3828;
                  at_unix = now_unix -. 300.0;
                  source = "turn:3588";
                  added = 1;
                  removed = 1;
                  invalidated = 0;
                };
              ];
            added = [ fact_added ];
            updated =
              [
                {
                  relation = Wire_knowledge.Revision;
                  at_rev = 3827;
                  before = fact_before;
                  after = fact_after;
                };
              ];
            retracted =
              [
                {
                  memory_id = "mem-099";
                  category = "fact";
                  text = "Legacy serve binding active";
                  removed_at_rev = 3825;
                  removed_by = "librarian";
                  drop_reason = Some "superseded";
                };
              ];
            invalidated =
              [
                {
                  memory_id = "mem-098";
                  text = "Stale premise fact";
                  at_rev = 3826;
                  missing_premise_ids = [ "mem-010" ];
                };
              ];
            writer_status =
              Some
                (Wire_knowledge.Keeper_writer_active
                   {
                     state = Wire_knowledge.Writer_idle;
                     available_act_tokens = [ "resume"; "adopt" ];
                     snapshot_file = None;
                   });
          };
    }
  in
  let knowledge =
    m0.knowledge
    |> Knowledge_store.apply_board ~observed_at:now_mono
         {
           posts = [ p1; p2; p3; p_noise ];
           count = 4;
           sort_by = "recent";
           signal_only = true;
         }
    |> Knowledge_store.apply_thread ~observed_at:now_mono (p1, comments)
    |> Knowledge_store.apply_quarantines ~observed_at:now_mono quarantines
    |> Knowledge_store.apply_wiki_index ~observed_at:now_mono wiki_index
    |> Knowledge_store.apply_wiki_page ~observed_at:now_mono wiki_detail
    |> Knowledge_store.apply_wiki_log ~observed_at:now_mono wiki_log
    |> Knowledge_store.apply_artifacts ~observed_at:now_mono [ artifact_1 ]
    |> Knowledge_store.apply_world_memory ~observed_at:now_mono world_memory
    |> Knowledge_store.set_memory_diff_keeper (Some "e-masc-the-leader")
    |> Knowledge_store.set_memory_view_mode Knowledge_store.View_diff
    |> Knowledge_store.apply_memory_diff ~observed_at:now_mono keeper_diff
    |> Knowledge_store.record_memory_act_answer ~keeper:"wkbl-growth"
         (Wire_knowledge.Memory_act_done Wire_knowledge.Writer_idle)
  in
  (* Runtime fixtures *)
  let acct_sub_active : Wire_runtime.account_usage =
    {
      scope = "subscription";
      scope_id = "claude_max_1c0558f0";
      providers = [ { id = "claude"; display_name = "Claude Max" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "7d";
              kind = Wire_runtime.Window_seven_day;
              role = Wire_runtime.Role_gates_model_calls;
              utilization = Wire_runtime.Util_fraction 0.82;
              resets_at_unix = Some (now_unix +. 90_000.0);
              observed_at_unix = now_unix;
            };
            {
              limit_id = Some "5h";
              kind = Wire_runtime.Window_five_hour;
              role = Wire_runtime.Role_gates_model_calls;
              utilization = Wire_runtime.Util_percent 18;
              resets_at_unix = Some (now_unix +. 7200.0);
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Subscription_zero;
    }
  in
  let acct_sub_cooldown : Wire_runtime.account_usage =
    {
      scope = "subscription";
      scope_id = "kimi_coding_b2c3d4e5";
      providers = [ { id = "kimi"; display_name = "Kimi Coding" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "5h";
              kind = Wire_runtime.Window_five_hour;
              role = Wire_runtime.Role_gates_model_calls;
              utilization = Wire_runtime.Util_percent 100;
              resets_at_unix = Some (now_unix +. 1800.0);
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Subscription_zero;
    }
  in
  let acct_api_openrouter : Wire_runtime.account_usage =
    {
      scope = "api_wallet";
      scope_id = "openrouter_primary";
      providers = [ { id = "openrouter"; display_name = "OpenRouter" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "wallet";
              kind = Wire_runtime.Window_provider_label "wallet";
              role = Wire_runtime.Role_gates_model_calls;
              utilization =
                Wire_runtime.Util_credit_balance
                  { currency = "USD"; total = Some 80.0; remaining = 39.05 };
              resets_at_unix = None;
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Amount 39.05;
    }
  in
  let acct_api_exhausted : Wire_runtime.account_usage =
    {
      scope = "api_wallet";
      scope_id = "ollama_cloud_1";
      providers = [ { id = "ollama_cloud"; display_name = "Ollama Cloud" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "wallet";
              kind = Wire_runtime.Window_provider_label "wallet";
              role = Wire_runtime.Role_gates_model_calls;
              utilization =
                Wire_runtime.Util_credit_balance
                  { currency = "USD"; total = Some 100.0; remaining = 0.0 };
              resets_at_unix = None;
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Exhausted_zero;
    }
  in
  let acct_unreported : Wire_runtime.account_usage =
    {
      scope = "api_wallet";
      scope_id = "claude_api_team";
      providers = [ { id = "anthropic"; display_name = "Claude API" } ];
      state = Wire_runtime.Account_not_reported_since_start;
      cost_state = Format_val.Unreported;
    }
  in
  let velocity =
    List.init 48 (fun i ->
        let fi = float_of_int i in
        {
          Wire_runtime.at_unix = now_unix -. (float_of_int (48 - i) *. 1800.0);
          input_tok_per_min =
            Observed.value ~observed_at:now_mono (80_000.0 +. (fi *. 1500.0));
          cache_read_tok_per_min =
            Observed.value ~observed_at:now_mono (76_000.0 +. (fi *. 1450.0));
          output_tok_per_min =
            Observed.value ~observed_at:now_mono (14_000.0 +. (fi *. 250.0));
        })
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
            keeper = "code-reviewer";
            turns = 410;
            input_tokens = 4_200_000;
            cache_read_tokens = Observed.value ~observed_at:now_mono 38_000_000;
            cache_creation_tokens = Observed.value ~observed_at:now_mono 900_000;
            output_tokens = 1_100_000;
            cache_hit_pct = Observed.value ~observed_at:now_mono 96.4;
            cost_usd = 63.10;
            calls = 2418;
            failed = 12;
            deferred = 3;
            tool_ms = 14_200.0;
          };
          {
            keeper = "e-masc-the-leader";
            turns = 280;
            input_tokens = 2_800_000;
            cache_read_tokens = Observed.value ~observed_at:now_mono 24_000_000;
            cache_creation_tokens = Observed.value ~observed_at:now_mono 500_000;
            output_tokens = 720_000;
            cache_hit_pct = Observed.value ~observed_at:now_mono 95.1;
            cost_usd = 21.40;
            calls = 1142;
            failed = 4;
            deferred = 1;
            tool_ms = 9_100.0;
          };
        ];
      fleet =
        {
          turns_total = 690;
          calls_per_turn = 5.1;
          tool_s_per_turn = 1.4;
          output_tokens_per_turn = 2637.0;
          input_tokens_per_turn = 10144.0;
          cost_usd_per_turn = 0.12;
          fleet_cache_hit_pct = Observed.value ~observed_at:now_mono 95.7;
        };
      velocity;
    }
  in
  let resolved : Wire_runtime.runtime_resolved_snapshot =
    {
      generated_at_iso = "2026-11-21T20:00:00Z";
      config_path = Some ".masc/runtime.toml";
      default_route = Some "sonnet-then-glm";
      lanes =
        [
          {
            id = "sonnet-then-glm";
            declared = true;
            runtime_ids = [ "claude-sonnet-5"; "glm-5-3" ];
          };
        ];
      runtimes =
        [
          {
            id = "claude-sonnet-5";
            provider_id = "anthropic";
            provider = "anthropic";
            model = Some "claude-sonnet-5";
            declared_reasoning_effort = None;
            transport = Some "http";
            is_default = true;
          };
          {
            id = "glm-5-3";
            provider_id = "zhipu";
            provider = "zhipu";
            model = Some "glm-5.3-flash";
            declared_reasoning_effort = None;
            transport = Some "http";
            is_default = false;
          };
        ];
      usage_windows =
        Some
          {
            since_unix = now_unix -. 86400.0;
            accounts =
              [
                acct_sub_active;
                acct_sub_cooldown;
                acct_api_openrouter;
                acct_api_exhausted;
                acct_unreported;
              ];
          };
    }
  in
  let probe : Wire_runtime.runtime_probe_snapshot =
    {
      generated_at = "2026-11-21T20:00:00Z";
      cache_ttl_sec = 300.0;
      cache_age_sec = Some 12.0;
      cache_hit = true;
      refresh_state = Wire_runtime.Probe_fresh;
      status = Wire_runtime.Probe_degraded;
      probe_ok = false;
      default_runtime_id = Some "claude-sonnet-5";
      runtimes_count = 4;
      probed_count = 4;
      reachable_count = 2;
      failed_count = 2;
      skipped_count = 0;
      providers =
        [
          {
            runtime_id = "claude-sonnet-5";
            transport = `Http;
            status = "ok";
            reachable = Some true;
            http_status = Some 200;
            latency_ms = Some 142.0;
            error = None;
            checked_at = "2026-11-21T20:00:00Z";
          };
          {
            runtime_id = "glm-5-3";
            transport = `Http;
            status = "ok";
            reachable = Some true;
            http_status = Some 200;
            latency_ms = Some 210.0;
            error = None;
            checked_at = "2026-11-21T20:00:00Z";
          };
          (* Outside-lane failures — MUST be isolated from active SSOT header *)
          {
            runtime_id = "external-unused-1";
            transport = `Http;
            status = "error";
            reachable = Some false;
            http_status = Some 429;
            latency_ms = None;
            error = Some "rate_limited";
            checked_at = "2026-11-21T20:00:00Z";
          };
          {
            runtime_id = "external-unused-2";
            transport = `Http;
            status = "error";
            reachable = Some false;
            http_status = Some 402;
            latency_ms = None;
            error = Some "quota_exceeded";
            checked_at = "2026-11-21T20:00:00Z";
          };
        ];
      errors = [];
      observations = [];
      limitations = [];
    }
  in
  let tool_series : Wire_runtime.tool_series =
    {
      generated_at_unix = now_unix;
      bucket_width = `Hour;
      utc_offset_min = 540;
      buckets =
        List.init 24 (fun i ->
            {
              Wire_runtime.start_unix =
                now_unix -. (float_of_int (24 - i) *. 3600.0);
              activity =
                Wire_runtime.Series_active
                  {
                    calls = 120 + (i * 5);
                    failures = i mod 4;
                    deferred = 1;
                    p95_ms = 18.0 +. (float_of_int i *. 2.5);
                  };
            });
    }
  in
  let runtime =
    m0.runtime
    |> Runtime_store.apply_runtime_resolved ~observed_at:now_mono resolved
    |> Runtime_store.apply_runtime_probe ~observed_at:now_mono probe
    |> Runtime_store.apply_efficiency ~observed_at:now_mono efficiency
    |> Runtime_store.apply_exact_lane_runs ~observed_at:now_mono
         [
           {
             run_id = "ex-1";
             lane = "verifier";
             subject_id = Some "task-3898";
             status =
               Wire_runtime.Task_verification Wire_runtime.Task_review_approved;
             started_at_unix = now_unix -. 60.0;
           };
         ]
    |> Runtime_store.apply_fusion_runs ~observed_at:now_mono
         [
           {
             run_id = "fu-1";
             keeper = "e-masc-the-leader";
             preset = "council-3";
             topology = Wire_runtime.Judge_of_judges;
             started_at_unix = now_unix -. 180.0;
             finished_at_unix = Some (now_unix -. 120.0);
             status = Wire_runtime.Fusion_completed;
             stage = "final";
             decision = Some "Approve stack #54340";
             summary = None;
           };
         ]
    |> Runtime_store.apply_tool_series ~observed_at:now_mono tool_series
    |> Runtime_store.apply_tools_catalog ~observed_at:now_mono
         [
           {
             name = "masc_board_post";
             description = Some "Post to board";
             calls = Observed.value ~observed_at:now_mono 412;
             failure_rate_pct = Observed.value ~observed_at:now_mono 0.8;
           };
         ]
    |> Runtime_store.apply_connectors ~observed_at:now_mono
         [
           {
             connector_id = "slack-ops";
             display_name = "Slack #masc-ops";
             connection = Wire_runtime.Connector_connected;
             channel = Some "masc-ops";
             error = None;
             binding_count = 3;
           };
         ]
    |> Runtime_store.apply_browser_lane ~observed_at:now_mono
         {
           ok = true;
           available = true;
           inventory_complete = true;
           client_count = 2;
           issue_count = 0;
           automatic_browse_ok = true;
           detail = Some "chromium-ready";
         }
    |> Runtime_store.apply_mcp_clients ~observed_at:now_mono
         [
           {
             name = "codex-mcp-client";
             agent_type = "mcp";
             keeper_name = Some "e-masc-the-leader";
             keeper_id = Some "k-1";
             status = "connected";
             current_task = Some "task-3898";
             session_bound_at_unix = Some (now_unix -. 600.0);
             last_seen_unix = Some (now_unix -. 5.0);
             capabilities = [ "tools"; "resources" ];
           };
         ]
  in
  (* Infra fixtures *)
  let metrics_ok : Wire_infra.tool_metrics_24h =
    {
      calls = 412;
      failures = 8;
      failure_unclassified = 0;
      p50_ms = Observed.value ~observed_at:now_mono 4.2;
      p95_ms = Observed.value ~observed_at:now_mono 18.5;
      max_ms = Observed.value ~observed_at:now_mono 120.0;
      failure_classes =
        {
          dependency_unavailable = 3;
          runtime_failure = 2;
          policy_rejection = 2;
          workflow_rejection = 1;
          operator_cancelled = 0;
        };
    }
  in
  let sandboxes : Wire_infra.sandboxes_snapshot =
    {
      probe_state = Wire_infra.Probe_fresh now_unix;
      microvm_declared = 2;
      microvm_running = 2;
      microvm_sockets_present = 2;
      microvm_shim_mismatch = 1;
      ssh_pools_count = 1;
      ssh_keepers_count = 1;
      ssh_unbound_keepers_count = 1;
      ssh_active_sessions = Observed.value ~observed_at:now_mono 3;
      ssh_max_sessions = 8;
      docker_keepers_count = 1;
      microvm_guests =
        [
          {
            keeper = "e-masc-the-leader";
            backend = "apple_container";
            guest_name = "vm-leader";
            presence = "running";
            agent_socket =
              Wire_infra.Socket_present
                { path_basename = Some "e-masc-the-leader.sock" };
            shim_parity = Wire_infra.Shim_matched "3e2f6b7a";
            network_mode = Wire_infra.Net_inherit;
            cpus = Observed.value ~observed_at:now_mono 2;
            memory_mib = Observed.value ~observed_at:now_mono 2048;
            volume = Wire_infra.Volume_declared "masc-leader-work";
            metrics_24h = metrics_ok;
          };
          {
            keeper = "music-sensei";
            backend = "apple_container";
            guest_name = "vm-music";
            presence = "running";
            agent_socket =
              Wire_infra.Socket_present
                { path_basename = Some "music-sensei.sock" };
            shim_parity =
              Wire_infra.Shim_mismatch
                { shim_identity = "old1234"; server_identity = Some "3e2f6b7a" };
            network_mode = Wire_infra.Net_none;
            cpus = Observed.value ~observed_at:now_mono 2;
            memory_mib = Observed.value ~observed_at:now_mono 2048;
            volume = Wire_infra.Volume_invalid "ext4 journal error";
            metrics_24h = metrics_ok;
          };
        ];
      ssh_pools =
        [
          {
            pool_name = "masc-ssh-review-team";
            host = "127.0.0.1";
            port = 22268;
            unix_user = "ops-user";
            remote_root = "/srv/masc";
            private_home = true;
            max_sessions = 8;
            active_sessions = Observed.value ~observed_at:now_mono 3;
            reachability =
              Wire_infra.Ssh_reachable
                { rtt_ms = 18.0; measured_at_unix = now_unix };
            accounts =
              [
                {
                  unix_user = "ops-user";
                  active_sessions = Observed.value ~observed_at:now_mono 3;
                  max_sessions = 8;
                  keepers = [ "code-reviewer" ];
                };
              ];
            keeper_sessions =
              [
                {
                  keeper = "code-reviewer";
                  last_dispatch = `Assoc [ ("tool", `String "git_diff"); ("ok", `Bool true) ];
                  metrics_24h = metrics_ok;
                };
              ];
            metrics_24h = metrics_ok;
          };
        ];
      ssh_unbound_keepers =
        [
          {
            keeper = "wkbl-unbound-agent";
            backend = "remote_ssh";
            binding_state = "unassigned";
            remote_endpoint = Some "127.0.0.1:22270";
            metrics_24h = metrics_ok;
          };
        ];
      docker_keepers =
        [
          {
            keeper = "docker-eval-bot";
            backend = "docker";
            network_mode = Wire_infra.Net_policy;
            metrics_24h = metrics_ok;
          };
        ];
      fleet_metrics_24h = metrics_ok;
      volume_gc_report =
        Some (`Assoc [ ("reclaimed_mib", `Int 512); ("status", `String "ok") ]);
      host_storage =
        Some
          (`Assoc
            [ ("used_gib", `Float 41.2); ("total_gib", `Float 64.0) ]);
      unobserved_reasons = [];
    }
  in
  let repo_1 : Wire_infra.repository =
    {
      id = "repo-masc";
      name = "masc";
      codebase = Some "ocaml";
      url = "https://github.com/jeong-sik/masc";
      resolved_local_path = "/workspace/masc";
      default_branch = "main";
      status = Wire_infra.Repo_cloning;
      keepers = [ "e-masc-the-leader"; "code-reviewer" ];
      auto_sync = true;
    }
  in
  let activity_1 : Wire_infra.repository_activity =
    {
      window_hours = 24.0;
      changes =
        [
          {
            path = "lib/masc_tui/screens_domain/screen_infra.ml";
            keeper = "e-masc-the-leader";
            change =
              Wire_infra.Change_edit
                {
                  before = "let mode = Net_inherit\nlet old_val = 0";
                  after = "let mode = Net_inherit\nlet new_val = 42\nlet ok = true";
                  replace_all = false;
                };
            line_evidence =
              Some
                (Wire_infra.Edit_ranges
                   [
                     {
                       old_range = { start_line = 10; end_line = 11 };
                       new_range = Some { start_line = 10; end_line = 12 };
                     };
                   ]);
            succeeded = true;
          };
        ];
      incomplete = 1;
      unattributed = 0;
    }
  in
  let log_1 : Wire_infra.system_log_entry =
    {
      seq = 1042;
      ts = "2026-11-21T20:11:44Z";
      level = Wire_infra.Log_warn;
      source = "sandbox";
      module_name = "microvm_pool";
      message = "ext4 journal warning detected on guest volume";
      keeper = Some "e-masc-the-leader";
      turn_id = Some 3595;
      category = Some "storage";
      details =
        `Assoc
          [
            ("guest", `String "vm-leader");
            ("api_key", `String "sk-live-secret-should-redact");
            ("latency_ms", `Float 6.2);
          ];
    }
  in
  let infra =
    m0.infra
    |> Infra_store.apply_sandboxes ~observed_at:now_mono sandboxes
    |> Infra_store.apply_repositories ~observed_at:now_mono [ repo_1 ]
    |> Infra_store.apply_repo_activity ~repo_id:"repo-masc" ~observed_at:now_mono
         activity_1
    |> Infra_store.apply_log_snapshot [ log_1 ]
    |> Infra_store.push_activity
         {
           at_unix = now_unix -. 10.0;
           kind = Infra_store.Activity_tool_call;
           keeper = Some "code-reviewer";
           summary = "git_diff completed (18ms)";
           detail = None;
         }
    |> Infra_store.record_stream_gap 7
  in
  let incidents, _inc =
    Incidents.push ~occurred_at_unix:(now_unix -. 1200.0)
      ~source:(Health.Source_keeper "wkbl-growth")
      ~summary:(Say.make ~ko:"직전 턴 일시 타임아웃" ~en:"Transient turn timeout")
      ~detail:"Recovered on automatic retry without operator action."
      ~status:Health.Resolved m0.incidents
  in
  { m0 with freshness; fleet; work; knowledge; runtime; infra; incidents }

let render_into ~cols ~rows fn =
  let grid = Cell_grid.create ~cols ~rows in
  let cache = Card.Cache.create () in
  let rect = Rect.make ~x:0 ~y:0 ~w:cols ~h:rows in
  fn ~cache ~rect grid;
  grid

(* --- Test Cases --- *)

let test_knowledge_all_tabs_and_dives () =
  let sizes = [ (140, 40); (90, 28) ] in
  let langs = [ Say.Lang_ko; Say.Lang_en ] in
  let tabs =
    [
      Nav.Knowledge_board;
      Nav.Knowledge_wiki_artifacts;
      Nav.Knowledge_memory;
    ]
  in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun lang ->
          let m_base = make_rich_model ~lang ~cols ~rows in
          List.iter
            (fun tab ->
              let m =
                {
                  m_base with
                  knowledge = Knowledge_store.set_tab tab m_base.knowledge;
                }
              in
              let lbl =
                Printf.sprintf "Knowledge/%dx%d/%s" cols rows
                  (Say.lang_code lang)
              in
              let grid =
                render_into ~cols ~rows (fun ~cache ~rect g ->
                    Screen_knowledge.render ~model:m ~cache ~rect g)
              in
              assert_grid_invariants ~label:lbl grid;
              let text = grid_all_text grid in
              (match tab with
               | Nav.Knowledge_board ->
                   (* Signal-only default hides Verify: noise *)
                   Alcotest.(check bool)
                     (lbl ^ " hides Verify noise by default") false
                     (contains_sub ~needle:"Verify: automated" ~haystack:text);
                   (* Succession chain grouped with [x22] *)
                   Alcotest.(check bool)
                     (lbl ^ " shows succession chain [x22]") true
                     (contains_sub ~needle:"[x22]" ~haystack:text);
                   (* Karma badge present *)
                   Alcotest.(check bool)
                     (lbl ^ " shows Karma badge") true
                     (contains_sub ~needle:"Karma" ~haystack:text);
                   (* Also test expanded succession chain + zoomed preview *)
                   let m_exp =
                     {
                       m with
                       knowledge =
                         Knowledge_store.toggle_succession_chain
                           ~root_id:"chain-wkbl" m.knowledge;
                     }
                   in
                   let g_exp =
                     render_into ~cols ~rows (fun ~cache ~rect g ->
                         Screen_knowledge.render ~model:m_exp ~cache ~rect g)
                   in
                   assert_grid_invariants ~label:(lbl ^ "/ChainExpanded") g_exp;
                   let m_zoom =
                     { m with nav = { m.nav with zoomed = true } }
                   in
                   let g_zoom =
                     render_into ~cols ~rows (fun ~cache ~rect g ->
                         Screen_knowledge.render ~model:m_zoom ~cache ~rect g)
                   in
                   assert_grid_invariants ~label:(lbl ^ "/Zoomed") g_zoom
               | Nav.Knowledge_wiki_artifacts ->
                   (* OSC 8 hyperlink interned for wiki links *)
                   Alcotest.(check bool)
                     (lbl ^ " interns OSC 8 wiki hyperlink") true
                     (Option.is_some (Cell_grid.hyperlink_uri grid 1));
                   (* Also test the Artifacts submode *)
                   let m_art =
                     {
                       m with
                       knowledge =
                         Knowledge_store.toggle_wiki_artifacts_submode
                           m.knowledge;
                     }
                   in
                   let g_art =
                     render_into ~cols ~rows (fun ~cache ~rect g ->
                         Screen_knowledge.render ~model:m_art ~cache ~rect g)
                   in
                   assert_grid_invariants ~label:(lbl ^ "/Artifacts") g_art
               | Nav.Knowledge_memory ->
                   (* Retrieval heat & real /memory/act recovery acts *)
                   Alcotest.(check bool)
                     (lbl ^ " shows HOT heat pill") true
                     (contains_sub ~needle:"HOT" ~haystack:text);
                   let resume_lbl =
                     match lang with Say.Lang_ko -> "재개" | Say.Lang_en -> "Resume"
                   in
                   let restart_lbl =
                     match lang with
                     | Say.Lang_ko -> "다시 읽기"
                     | Say.Lang_en -> "Restart Reading"
                   in
                   Alcotest.(check bool)
                     (lbl ^ " shows localized Resume recovery act") true
                     (contains_sub ~needle:resume_lbl ~haystack:text);
                   Alcotest.(check bool)
                     (lbl ^ " shows localized Restart Reading recovery act") true
                     (contains_sub ~needle:restart_lbl ~haystack:text);
                   Alcotest.(check bool)
                     (lbl ^ " hides raw Restart_reading enum token") false
                     (contains_sub ~needle:"Restart_reading" ~haystack:text);
                   (* Also test World_diff variant *)
                   let world_diff : Wire_knowledge.memory_diff =
                     {
                       scope = Wire_knowledge.Scope_world;
                       range =
                         {
                           window = Some "7d";
                           from_rev = Some 100;
                           to_rev = Some 105;
                           from_unix = None;
                           to_unix = None;
                         };
                       retrieval_heat =
                         {
                           hot = 3;
                           warm = 5;
                           cold = 2;
                           never_retrieved = 1;
                           total_events = 40;
                           unreadable_event_lines = 0;
                         };
                       body =
                         Wire_knowledge.World_diff
                           {
                             counts =
                               {
                                 total_claims_now = 1025;
                                 added = 1;
                                 updated = 1;
                                 retracted = 1;
                                 incomplete_batches = 0;
                                 aborted_batches = 0;
                               };
                             unparseable_timestamps = 0;
                             revisions = [];
                             added =
                               [
                                 {
                                   seq = 1;
                                   batch_id = "b1";
                                   fact_id = "f-add-1";
                                   summary = "Added world claim";
                                   recorded_at = "2026-11-21T18:00:00Z";
                                   payload = `Assoc [ ("claim", `String "ok") ];
                                 };
                               ];
                             updated =
                               [
                                 {
                                   seq = 2;
                                   fact_id = "f-upd-2";
                                   summary = "Updated world claim";
                                   recorded_at = "2026-11-21T19:00:00Z";
                                   before = `Assoc [ ("ttl", `Int 30) ];
                                   after = `Assoc [ ("ttl", `Int 300) ];
                                 };
                               ];
                             retracted =
                               [
                                 {
                                   seq = 3;
                                   batch_id = "b2";
                                   fact_id = "f-ret-3";
                                   summary = "Retracted stale claim";
                                   recorded_at = "2026-11-21T19:30:00Z";
                                   payload = `Null;
                                 };
                               ];
                           };
                     }
                   in
                   let m_wd =
                     {
                       m with
                       knowledge =
                         m.knowledge
                         |> Knowledge_store.set_memory_diff_keeper None
                         |> Knowledge_store.apply_memory_diff
                              ~observed_at:now_mono world_diff;
                     }
                   in
                   let g_wd =
                     render_into ~cols ~rows (fun ~cache ~rect g ->
                         Screen_knowledge.render ~model:m_wd ~cache ~rect g)
                   in
                   assert_grid_invariants ~label:(lbl ^ "/WorldDiff") g_wd))
            tabs;
          (* All 4 Knowledge Dives *)
          let dives =
            [
              Nav.Thread_dive "p-chain-22";
              Nav.Wiki_dive "release-runbook";
              Nav.Artifact_dive "artifact-e3b0c44298fc1c149afbf4c8996fb924";
              Nav.Memory_diff_dive
                {
                  keeper = Some "e-masc-the-leader";
                  from_rev = 3794;
                  to_rev = 3828;
                };
            ]
          in
          List.iter
            (fun target ->
              let g =
                render_into ~cols ~rows (fun ~cache ~rect gr ->
                    Screen_knowledge.render_dive ~target ~model:m_base ~cache
                      ~rect gr)
              in
              assert_grid_invariants
                ~label:(Printf.sprintf "KnowledgeDive/%dx%d" cols rows)
                g)
            dives)
        langs)
    sizes

let test_runtime_all_tabs_and_invariants () =
  let sizes = [ (140, 40); (90, 28) ] in
  let langs = [ Say.Lang_ko; Say.Lang_en ] in
  let tabs =
    [
      Nav.Runtime_quotas_credits;
      Nav.Runtime_efficiency_spend;
      Nav.Runtime_failover_lanes;
      Nav.Runtime_tools_connectors;
    ]
  in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun lang ->
          let m_base = make_rich_model ~lang ~cols ~rows in
          List.iter
            (fun tab ->
              let m =
                {
                  m_base with
                  runtime = Runtime_store.set_tab tab m_base.runtime;
                }
              in
              let lbl =
                Printf.sprintf "Runtime/%dx%d/%s" cols rows (Say.lang_code lang)
              in
              let grid =
                render_into ~cols ~rows (fun ~cache ~rect g ->
                    Screen_runtime.render ~model:m ~cache ~rect g)
              in
              assert_grid_invariants ~label:lbl grid;
              let text = grid_all_text grid in
              match tab with
              | Nav.Runtime_quotas_credits ->
                  (* Observed cost state distinction: $0 Sub vs $0 Exhausted vs ? Unreported *)
                  let sub_s =
                    Format_val.format_cost Format_val.Subscription_zero ~lang
                  in
                  let exh_s =
                    Format_val.format_cost Format_val.Exhausted_zero ~lang
                  in
                  let unr_s =
                    Format_val.format_cost Format_val.Unreported ~lang
                  in
                  Alcotest.(check bool)
                    (lbl ^ " renders $0 Sub") true
                    (contains_sub ~needle:sub_s ~haystack:text);
                  Alcotest.(check bool)
                    (lbl ^ " renders $0 Exhausted") true
                    (contains_sub ~needle:exh_s ~haystack:text);
                  Alcotest.(check bool)
                    (lbl ^ " renders ? Unreported") true
                    (contains_sub ~needle:unr_s ~haystack:text);
                  (* Cooldown / exhausted subscription account never hidden *)
                  Alcotest.(check bool)
                    (lbl ^ " displays 100% cooldown Kimi account") true
                    (contains_sub ~needle:"Kimi Coding" ~haystack:text)
              | Nav.Runtime_efficiency_spend ->
                  (* Full-width btop Braille chart: verify Braille extends past 60% of width at 140x40 *)
                  if cols = 140 then begin
                    let max_braille_x = ref (-1) in
                    for y = 0 to rows - 1 do
                      for x = 0 to cols - 1 do
                        match (Cell_grid.get grid ~x ~y).glyph with
                        | Cell_grid.Braille _ ->
                            if x > !max_braille_x then max_braille_x := x
                        | Cell_grid.Empty
                        | Cell_grid.Ascii _
                        | Cell_grid.Utf8 _
                        | Cell_grid.Continuation ->
                            ()
                      done
                    done;
                    Alcotest.(check bool)
                      (lbl
                      ^ " full-width Braille chart fills past col 100 (kills 60% right void)")
                      true (!max_braille_x >= 100)
                  end
              | Nav.Runtime_failover_lanes ->
                  (* Active SSOT shows 2/2 active reachable; external failures isolated *)
                  Alcotest.(check bool)
                    (lbl ^ " active SSOT shows 2/2 reachable") true
                    (contains_sub ~needle:"2/2" ~haystack:text);
                  let ext_expected =
                    match lang with
                    | Say.Lang_ko -> "외부 프로브: 2 실패 [Space]"
                    | Say.Lang_en -> "External probes: 2 failed [Space]"
                  in
                  Alcotest.(check bool)
                    (lbl ^ " isolates external probe failures with [Space] hint")
                    true
                    (contains_sub ~needle:ext_expected ~haystack:text);
                  Alcotest.(check bool)
                    (lbl ^ " never shows conflicting [I] hint on external probes")
                    false
                    (contains_sub ~needle:"[I]" ~haystack:text);
                  (* Also test toggling outside-lane probes view *)
                  let m_ext =
                    {
                      m with
                      runtime =
                        Runtime_store.toggle_outside_lane_probes m.runtime;
                    }
                  in
                  let g_ext =
                    render_into ~cols ~rows (fun ~cache ~rect g ->
                        Screen_runtime.render ~model:m_ext ~cache ~rect g)
                  in
                  assert_grid_invariants ~label:(lbl ^ "/ExtOpen") g_ext
              | Nav.Runtime_tools_connectors ->
                  Alcotest.(check bool)
                    (lbl ^ " renders 4-bucket error classes") true
                    (contains_sub ~needle:"policy_rejection" ~haystack:text
                    || contains_sub ~needle:"Slack #masc-ops" ~haystack:text))
            tabs)
        langs)
    sizes

let test_infra_all_tabs_and_dives () =
  let sizes = [ (140, 40); (90, 28) ] in
  let langs = [ Say.Lang_ko; Say.Lang_en ] in
  let tabs =
    [
      Nav.Infra_sandboxes;
      Nav.Infra_repos_changes;
      Nav.Infra_activity_logs;
    ]
  in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun lang ->
          let m_base = make_rich_model ~lang ~cols ~rows in
          List.iter
            (fun tab ->
              let m =
                {
                  m_base with
                  infra = Infra_store.set_tab tab m_base.infra;
                }
              in
              let lbl =
                Printf.sprintf "Infra/%dx%d/%s" cols rows (Say.lang_code lang)
              in
              let grid =
                render_into ~cols ~rows (fun ~cache ~rect g ->
                    Screen_infra.render ~model:m ~cache ~rect g)
              in
              assert_grid_invariants ~label:lbl grid;
              let text = grid_all_text grid in
              match tab with
              | Nav.Infra_sandboxes ->
                  Alcotest.(check bool)
                    (lbl ^ " shows microVM fleet") true
                    (contains_sub ~needle:"apple_container" ~haystack:text
                    || contains_sub ~needle:"microVM" ~haystack:text);
                  Alcotest.(check bool)
                    (lbl ^ " shows SSH pool") true
                    (contains_sub ~needle:"masc-ssh-review-team" ~haystack:text)
              | Nav.Infra_repos_changes ->
                  (* OSC 8 file:// IDE link interned *)
                  Alcotest.(check bool)
                    (lbl ^ " interns file:// OSC 8 hyperlink") true
                    (Option.is_some (Cell_grid.hyperlink_uri grid 1));
                  (* Unified diff rendered *)
                  Alcotest.(check bool)
                    (lbl ^ " renders syntax-highlighted diff content") true
                    (contains_sub ~needle:"new_val = 42" ~haystack:text)
              | Nav.Infra_activity_logs ->
                  (* Stream_gap badge shown *)
                  Alcotest.(check bool)
                    (lbl ^ " shows typed Stream_gap indicator") true
                    (contains_sub ~needle:"Stream_gap: 7" ~haystack:text);
                  (* Full readable keeper name preserved *)
                  Alcotest.(check bool)
                    (lbl ^ " preserves full keeper name") true
                    (contains_sub ~needle:"e-masc-the-leader" ~haystack:text);
                  (* Secret redacted in Json_tree details *)
                  Alcotest.(check bool)
                    (lbl ^ " redacts secret api_key in Json_tree") false
                    (contains_sub ~needle:"sk-live-secret-should-redact"
                       ~haystack:text))
            tabs;
          (* All 3 Infra Dives in both structured mode and [J] Json_tree mode *)
          let dives =
            [
              Nav.Sandbox_dive "e-masc-the-leader";
              Nav.Lane_dive "sonnet-then-glm";
              Nav.Incident_dive 1;
            ]
          in
          List.iter
            (fun target ->
              let g1 =
                render_into ~cols ~rows (fun ~cache ~rect g ->
                    Screen_infra.render_dive ~target ~model:m_base ~cache ~rect
                      g)
              in
              assert_grid_invariants
                ~label:(Printf.sprintf "InfraDive/%dx%d" cols rows)
                g1;
              let m_json =
                { m_base with infra = Infra_store.toggle_raw_json m_base.infra }
              in
              let g2 =
                render_into ~cols ~rows (fun ~cache ~rect g ->
                    Screen_infra.render_dive ~target ~model:m_json ~cache ~rect
                      g)
              in
              assert_grid_invariants
                ~label:(Printf.sprintf "InfraDiveJson/%dx%d" cols rows)
                g2)
            dives)
        langs)
    sizes

let test_empty_loading_and_failed_observed_states () =
  (* Ensure zero crashes when every Observed.t is Loading / Unreported / Failed *)
  let m_empty = Model.initial ~cols:90 ~rows:28 ~lang:Say.Lang_en () in
  let m_failed =
    {
      m_empty with
      knowledge =
        {
          m_empty.knowledge with
          board =
            Observed.failed ~reason:"http 503" ~retryable:true ~at:now_mono;
          world_memory = Observed.loading ~since_ns:now_mono;
        };
      runtime =
        {
          m_empty.runtime with
          usage_windows = Observed.loading ~since_ns:now_mono;
          efficiency =
            Observed.failed ~reason:"timeout" ~retryable:true ~at:now_mono;
        };
      infra =
        {
          m_empty.infra with
          sandboxes = Observed.loading ~since_ns:now_mono;
          repositories = Observed.absent;
        };
    }
  in
  let g1 =
    render_into ~cols:90 ~rows:28 (fun ~cache ~rect g ->
        Screen_knowledge.render ~model:m_failed ~cache ~rect g)
  in
  assert_grid_invariants ~label:"Empty/Knowledge" g1;
  let g2 =
    render_into ~cols:90 ~rows:28 (fun ~cache ~rect g ->
        Screen_runtime.render ~model:m_failed ~cache ~rect g)
  in
  assert_grid_invariants ~label:"Empty/Runtime" g2;
  let g3 =
    render_into ~cols:90 ~rows:28 (fun ~cache ~rect g ->
        Screen_infra.render ~model:m_failed ~cache ~rect g)
  in
  assert_grid_invariants ~label:"Empty/Infra" g3

let test_p1_p2_verifier_regressions () =
  let m_base = make_rich_model ~lang:Say.Lang_en ~cols:140 ~rows:40 in
  (* P1-1: No synthetic RTT sparkline glyphs in SSH pool card *)
  let m_sbox =
    { m_base with infra = Infra_store.set_tab Nav.Infra_sandboxes m_base.infra }
  in
  let g_sbox =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
        Screen_infra.render ~model:m_sbox ~cache ~rect g)
  in
  assert_grid_invariants ~label:"Reg/P1-1-Sandboxes" g_sbox;
  let ssh_top_text =
    let buf = Buffer.create 512 in
    for y = 0 to 6 do
      for x = 46 to 93 do
        match (Cell_grid.get g_sbox ~x ~y).glyph with
        | Cell_grid.Utf8 s -> Buffer.add_string buf s
        | Cell_grid.Ascii c -> Buffer.add_char buf c
        | Cell_grid.Empty | Cell_grid.Braille _ | Cell_grid.Continuation -> ()
      done
    done;
    Buffer.contents buf
  in
  Alcotest.(check bool) "P1-1 renders real observed 18.0ms RTT" true
    (contains_sub ~needle:"18.0ms" ~haystack:ssh_top_text);
  List.iter
    (fun spark ->
      Alcotest.(check bool)
        ("P1-1 no fabricated sparkline glyph " ^ spark)
        false
        (contains_sub ~needle:spark ~haystack:ssh_top_text))
    [ "▁"; "▂"; "▃"; "▄"; "▅"; "▆"; "▇" ];
  (* P1-2: Incident_dive redacts secrets in embedded JSON and plain text (default & [J] modes) *)
  let inc_json_secret =
    "HTTP 500: {\"error\":\"upstream_fail\",\"api_key\":\"sk-live-secret-999\",\"token\":\"ghp_secretvalue123\"}"
  in
  let inc_plain_secret =
    "Auth failed Authorization: Bearer topsecret_bearer_xyz api_key=sk-plain-secret-888"
  in
  let incs1, i_json =
    Incidents.push ~occurred_at_unix:now_unix
      ~source:Health.Source_client_http
      ~summary:(Say.literal "HTTP 500")
      ~detail:inc_json_secret ~status:Health.Resolved m_base.incidents
  in
  let incs2, i_plain =
    Incidents.push ~occurred_at_unix:now_unix
      ~source:Health.Source_client_http
      ~summary:(Say.literal "Auth failure")
      ~detail:inc_plain_secret ~status:Health.Resolved incs1
  in
  let m_inc = { m_base with incidents = incs2 } in
  List.iter
    (fun raw_flag ->
      let m_cur =
        { m_inc with infra = { m_inc.infra with show_raw_json = raw_flag } }
      in
      let g_j =
        render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
            Screen_infra.render_dive ~target:(Nav.Incident_dive i_json.id)
              ~model:m_cur ~cache ~rect g)
      in
      let txt_j = grid_all_text g_j in
      Alcotest.(check bool)
        "P1-2 redacts sk-live-secret-999" false
        (contains_sub ~needle:"sk-live-secret-999" ~haystack:txt_j);
      Alcotest.(check bool)
        "P1-2 redacts ghp_secretvalue123" false
        (contains_sub ~needle:"ghp_secretvalue123" ~haystack:txt_j);
      Alcotest.(check bool)
        "P1-2 no raw JSON object dump in Incident_dive" false
        (contains_sub ~needle:"{\"error\":" ~haystack:txt_j);
      let g_p =
        render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
            Screen_infra.render_dive ~target:(Nav.Incident_dive i_plain.id)
              ~model:m_cur ~cache ~rect g)
      in
      let txt_p = grid_all_text g_p in
      Alcotest.(check bool)
        "P1-2 redacts Bearer token" false
        (contains_sub ~needle:"topsecret_bearer_xyz" ~haystack:txt_p);
      Alcotest.(check bool)
        "P1-2 redacts plain sk-plain-secret-888" false
        (contains_sub ~needle:"sk-plain-secret-888" ~haystack:txt_p))
    [ false; true ];
  (* P1-3: Unreported 4-Bucket Tool Error Classes does NOT fabricate 0 errors *)
  let m_unrep_tools =
    {
      m_base with
      runtime = Runtime_store.set_tab Nav.Runtime_tools_connectors m_base.runtime;
      infra = { m_base.infra with sandboxes = Observed.unreported };
    }
  in
  let g_ut =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
        Screen_runtime.render ~model:m_unrep_tools ~cache ~rect g)
  in
  let txt_ut = grid_all_text g_ut in
  Alcotest.(check bool) "P1-3 renders honest Unreported placeholder" true
    (contains_sub ~needle:"Unreported by server" ~haystack:txt_ut);
  Alcotest.(check bool) "P1-3 does not fabricate Total errors bar" false
    (contains_sub ~needle:"Total errors" ~haystack:txt_ut);
  (* P1-4: Wiki & Artifacts lists respect k.filter_query and align with selected_* *)
  let m_wiki_f =
    {
      m_base with
      knowledge =
        m_base.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts
        |> Knowledge_store.set_filter "orphan";
    }
  in
  let g_wf =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
        Screen_knowledge.render ~model:m_wiki_f ~cache ~rect g)
  in
  let txt_wf = grid_all_text g_wf in
  Alcotest.(check bool) "P1-4 filtered Wiki shows matching orphan-notes" true
    (contains_sub ~needle:"고아 연구 메모" ~haystack:txt_wf);
  Alcotest.(check bool) "P1-4 filtered Wiki hides non-matching release-runbook"
    false
    (contains_sub ~needle:"릴리스 런북" ~haystack:txt_wf);
  let art_a : Wire_knowledge.artifact_entry =
    {
      id = "artifact-aaaa111122223333aaaa111122223333";
      revision = 1;
      title = "Alpha Report";
      summary = "First report";
      author = "alpha-writer";
      created_at_unix = now_unix -. 600.0;
      body = { sha256 = "aaaa111122223333"; bytes = 1024; mime = "text/html" };
    }
  in
  let art_b : Wire_knowledge.artifact_entry =
    {
      id = "artifact-bbbb444455556666bbbb444455556666";
      revision = 1;
      title = "Beta Report";
      summary = "Second report";
      author = "alpha-writer";
      created_at_unix = now_unix -. 300.0;
      body = { sha256 = "bbbb444455556666"; bytes = 2048; mime = "text/html" };
    }
  in
  let m_art_f =
    {
      m_base with
      knowledge =
        m_base.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts
        |> Knowledge_store.toggle_wiki_artifacts_submode
        |> Knowledge_store.apply_artifacts ~observed_at:now_mono [ art_a; art_b ]
        |> Knowledge_store.set_filter "beta";
    }
  in
  let g_af =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
        Screen_knowledge.render ~model:m_art_f ~cache ~rect g)
  in
  let txt_af = grid_all_text g_af in
  Alcotest.(check bool) "P1-4 filtered Artifacts shows Beta Report" true
    (contains_sub ~needle:"Beta Report" ~haystack:txt_af);
  Alcotest.(check bool) "P1-4 filtered Artifacts hides Alpha Report" false
    (contains_sub ~needle:"Alpha Report" ~haystack:txt_af);
  (* P1-5: Wiki_dive slug matching prevents stale page body/backlinks bleed *)
  let g_wdive =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
        Screen_knowledge.render_dive ~target:(Nav.Wiki_dive "orphan-notes")
          ~model:m_base ~cache ~rect g)
  in
  let txt_wdive = grid_all_text g_wdive in
  Alcotest.(check bool) "P1-5 Wiki_dive does not leak release-runbook body" false
    (contains_sub ~needle:"let ok = true" ~haystack:txt_wdive);
  Alcotest.(check bool) "P1-5 Wiki_dive does not leak release-runbook backlinks"
    false
    (contains_sub ~needle:"ops-checklist" ~haystack:txt_wdive);
  (* P1-6: Memory recovery acts drop conflicting [1]..[5] workspace-switch prefixes *)
  let m_mem =
    {
      m_base with
      knowledge = Knowledge_store.set_tab Nav.Knowledge_memory m_base.knowledge;
    }
  in
  let g_mem =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
        Screen_knowledge.render ~model:m_mem ~cache ~rect g)
  in
  let txt_mem = grid_all_text g_mem in
  Alcotest.(check bool) "P1-6 Memory acts have no [1] Resume prefix" false
    (contains_sub ~needle:"[1] Resume" ~haystack:txt_mem);
  Alcotest.(check bool) "P1-6 Memory acts still render Resume" true
    (contains_sub ~needle:"Resume" ~haystack:txt_mem);
  (* P1-7: Failover Cascade Trees scrolls to lower selected lane at 90x28 *)
  let many_lanes =
    List.init 12 (fun i ->
        {
          Wire_runtime.id = Printf.sprintf "lane-%02d-cascade" i;
          declared = true;
          runtime_ids = [ "claude-sonnet-5"; "glm-5-3" ];
        })
  in
  let resolved_many =
    match Observed.to_option m_base.runtime.runtime_resolved with
    | Some snap -> { snap with lanes = many_lanes }
    | None ->
        {
          Wire_runtime.generated_at_iso = "2026-11-21T20:00:00Z";
          config_path = None;
          default_route = None;
          lanes = many_lanes;
          runtimes = [];
          usage_windows = None;
        }
  in
  let rt_scroll =
    m_base.runtime
    |> Runtime_store.set_tab Nav.Runtime_failover_lanes
    |> Runtime_store.apply_runtime_resolved ~observed_at:now_mono resolved_many
    |> Runtime_store.move_selection ~delta:11
  in
  let m_scroll = { m_base with runtime = rt_scroll } in
  let g_scroll =
    render_into ~cols:90 ~rows:28 (fun ~cache ~rect g ->
        Screen_runtime.render ~model:m_scroll ~cache ~rect g)
  in
  assert_grid_invariants ~label:"Reg/P1-7-FailoverScroll" g_scroll;
  let txt_scroll = grid_all_text g_scroll in
  Alcotest.(check bool)
    "P1-7 lower selected lane-11-cascade scrolled into view at 90x28" true
    (contains_sub ~needle:"lane-11-cascade" ~haystack:txt_scroll);
  (* P2-2: Efficiency table can select the last keeper cleanly *)
  let rt_eff_last =
    m_base.runtime
    |> Runtime_store.set_tab Nav.Runtime_efficiency_spend
    |> Runtime_store.move_selection ~delta:1
  in
  let g_eff_last =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
        Screen_runtime.render
          ~model:{ m_base with runtime = rt_eff_last }
          ~cache ~rect g)
  in
  assert_grid_invariants ~label:"Reg/P2-2-EffSelection" g_eff_last;
  (* P2-3: wiki_lint report extracts Orphan_page findings *)
  let lint_rep : Wire_knowledge.wiki_lint_report =
    {
      pages_total = 2;
      pages_unreadable = 0;
      findings =
        [
          {
            kind = Wire_knowledge.Orphan_page;
            subject = "stray-orphan-slug";
            page = Some "stray-orphan-slug";
            file = None;
            line = None;
            target = None;
            form = None;
            reason = None;
            log_revision = None;
            page_revision = None;
            missing_revision = None;
          };
        ];
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
          duplicate_title_candidates = 0;
        };
      duplicate_title_candidates = [];
      log_hole_suppressed = false;
      log_unknown_action = 0;
      log_unreadable_line = 0;
    }
  in
  let m_lint =
    {
      m_base with
      knowledge =
        m_base.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts
        |> Knowledge_store.apply_wiki_lint ~observed_at:now_mono lint_rep;
    }
  in
  let g_lint =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect g ->
        Screen_knowledge.render ~model:m_lint ~cache ~rect g)
  in
  Alcotest.(check bool) "P2-3 wiki_lint displays extracted orphan slug" true
    (contains_sub ~needle:"stray-orphan-slug" ~haystack:(grid_all_text g_lint));
  (* R2-P1-2: Uninitialized now_unix=0.0 never formats bogus 20779d countdowns or 'now' ages *)
  let missing_glyph = Glyph.to_utf8 Glyph.Missing_absent in
  Alcotest.(check string) "format_countdown guards now_unix=0.0" missing_glyph
    (Domain_helpers.format_countdown ~now_unix:0.0 1_795_252_092.0);
  Alcotest.(check string) "format_age guards now_unix=0.0" missing_glyph
    (Domain_helpers.format_age ~now_unix:0.0 1_795_252_092.0)

let grid_row_text (grid : Cell_grid.t) ~y ~x0 ~x1 =
  let cols = Cell_grid.cols grid in
  let lo = Int.max 0 x0 in
  let hi = Int.min cols x1 in
  let buf = Buffer.create (Int.max 0 (hi - lo)) in
  for x = lo to hi - 1 do
    match (Cell_grid.get grid ~x ~y).glyph with
    | Cell_grid.Empty -> Buffer.add_char buf ' '
    | Cell_grid.Ascii ch -> Buffer.add_char buf ch
    | Cell_grid.Braille mask -> Buffer.add_string buf (Cell_grid.braille_utf8 mask)
    | Cell_grid.Utf8 s -> Buffer.add_string buf s
    | Cell_grid.Continuation -> ()
  done;
  Buffer.contents buf

let count_occurrences ~needle ~haystack =
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

let count_braille_in_rect (grid : Cell_grid.t) ~x0 ~x1 ~y0 ~y1 =
  let c = ref 0 in
  for y = Int.max 0 y0 to Int.min (Cell_grid.rows grid - 1) y1 do
    for x = Int.max 0 x0 to Int.min (Cell_grid.cols grid - 1) x1 do
      match (Cell_grid.get grid ~x ~y).glyph with
      | Cell_grid.Braille mask when mask <> 0 -> incr c
      | Cell_grid.Braille _
      | Cell_grid.Empty
      | Cell_grid.Ascii _
      | Cell_grid.Utf8 _
      | Cell_grid.Continuation ->
          ()
    done
  done;
  !c

let assert_no_cobalt_selection ~label (grid : Cell_grid.t) =
  let cobalt = Color.of_rgb 0x1D4ED8 in
  for y = 0 to Cell_grid.rows grid - 1 do
    for x = 0 to Cell_grid.cols grid - 1 do
      let cell = Cell_grid.get grid ~x ~y in
      if Color.equal cell.style.bg cobalt then
        Alcotest.failf "%s: legacy #1D4ED8 cobalt bg found at (%d,%d)" label x y
    done
  done

let test_v25_runtime_efficiency_real_charts () =
  (* Live 8935 scenario: efficiency is Unreported, models/metrics + keeper_costs + tool_series drive all 3 panels *)
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko () in
  let freshness = { m0.freshness with last_wall_unix = now_unix } in
  let buckets =
    List.init 24 (fun i ->
        let fi = float_of_int i in
        {
          Wire_runtime.ts_start = now_unix -. (float_of_int (24 - i) *. 3600.0);
          entry_count = 35 + (i * 4);
          success_count = 34 + (i * 4);
          error_count = 1;
          total_cost_usd = 0.40 +. (fi *. 0.08);
          p95_latency_ms = Some (420.0 +. (fi *. 18.0));
          (* Bucket max is 97.2% while fleet_cache_hit_pct below is 98.0% -> peak must clamp to >= current *)
          cache_hit_pct = Some (94.0 +. (fi *. (3.2 /. 23.0)));
          input_tokens = None;
          output_tokens = None;
          cache_read_tokens = None;
        })
  in
  let models_metrics : Wire_runtime.models_metrics_snapshot =
    {
      window_minutes = 1440;
      bucket_minutes = 60;
      total_entries = 948;
      total_error_entries = 12;
      models = [];
      hourly_buckets = buckets;
      fleet_cache_hit_pct = Observed.value ~observed_at:now_mono 98.0;
      fleet_cost_usd = Observed.value ~observed_at:now_mono 14.82;
      fleet_input_tokens = 1_000_000;
      fleet_output_tokens = 85_000;
      fleet_cache_read_tokens = 979_000;
      fleet_cache_creation_tokens = 12_000;
      fleet_tool_calls = 412;
      fleet_p95_latency_ms = Some 640.0;
    }
  in
  let keeper_costs : Wire_runtime.keeper_costs_window =
    {
      generated_at_unix = now_unix;
      window_minutes = 1440;
      rows =
        [
          {
            keeper_name = "e-masc-the-leader";
            sample_count = 120;
            total_tokens = Observed.value ~observed_at:now_mono 820_000;
            total_cost_usd = Observed.value ~observed_at:now_mono 9.10;
            tokens_reported_samples = 120;
            tokens_missing_samples = 0;
            cost_reported_samples = 120;
            cost_missing_samples = 0;
          };
          {
            keeper_name = "code-reviewer";
            sample_count = 88;
            total_tokens = Observed.value ~observed_at:now_mono 410_000;
            total_cost_usd = Observed.value ~observed_at:now_mono 5.72;
            tokens_reported_samples = 88;
            tokens_missing_samples = 0;
            cost_reported_samples = 88;
            cost_missing_samples = 0;
          };
        ];
    }
  in
  let rt_models =
    m0.runtime
    |> Runtime_store.set_tab Nav.Runtime_efficiency_spend
    |> Runtime_store.apply_models_metrics ~observed_at:now_mono models_metrics
    |> Runtime_store.apply_keeper_costs ~observed_at:now_mono keeper_costs
  in
  let m_models = { m0 with freshness; runtime = rt_models } in
  let g =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_runtime.render ~model:m_models ~cache ~rect gr)
  in
  assert_grid_invariants ~label:"v25/RuntimeEfficiencyModels" g;
  assert_no_cobalt_selection ~label:"v25/RuntimeEfficiencyModels" g;
  let txt = grid_all_text g in
  Alcotest.(check bool) "renders authoritative 98.0% cache hit" true
    (contains_sub ~needle:"98.0%" ~haystack:txt);
  Alcotest.(check bool) "peak >= current: shows 최대 98.0% and never 최대 97.2%" true
    (contains_sub ~needle:"현재 98.0%" ~haystack:txt
     && contains_sub ~needle:"최대 98.0%" ~haystack:txt
     && not (contains_sub ~needle:"최대 97.2%" ~haystack:txt));
  Alcotest.(check bool) "omits redundant 적중률 · 24h left header label" false
    (contains_sub ~needle:"적중률 · 24h" ~haystack:txt);
  Alcotest.(check bool) "renders 24h spend $14.82" true
    (contains_sub ~needle:"$14.82" ~haystack:txt);
  Alcotest.(check bool) "renders keeper cost row without efficiency payload" true
    (contains_sub ~needle:"e-masc-the-leader" ~haystack:txt);
  (* Left chart (cols 10..62) and right Dual-Mirror chart (cols 78..134) BOTH span left/mid/right thirds *)
  let left_l = count_braille_in_rect g ~x0:10 ~x1:26 ~y0:6 ~y1:22 in
  let left_m = count_braille_in_rect g ~x0:27 ~x1:44 ~y0:6 ~y1:22 in
  let left_r = count_braille_in_rect g ~x0:45 ~x1:63 ~y0:6 ~y1:22 in
  let right_l = count_braille_in_rect g ~x0:78 ~x1:95 ~y0:6 ~y1:22 in
  let right_m = count_braille_in_rect g ~x0:96 ~x1:114 ~y0:6 ~y1:22 in
  let right_r = count_braille_in_rect g ~x0:115 ~x1:135 ~y0:6 ~y1:22 in
  Alcotest.(check bool)
    (Printf.sprintf "left cache chart fills all 3 thirds (%d/%d/%d)" left_l left_m left_r)
    true (left_l >= 10 && left_m >= 10 && left_r >= 10);
  Alcotest.(check bool)
    (Printf.sprintf "right dual-mirror chart fills all 3 thirds (%d/%d/%d)"
       right_l right_m right_r)
    true (right_l >= 10 && right_m >= 10 && right_r >= 10);
  (* Zero duplicate titles inside chart card headers *)
  Alcotest.(check int) "no duplicate Prompt Cache card title" 1
    (count_occurrences ~needle:"프롬프트 캐시 적중률 (24h %)" ~haystack:txt);
  (* Also verify Velocity_tool_calls_and_p95 fallback when only tool_series exists *)
  let tool_series : Wire_runtime.tool_series =
    {
      generated_at_unix = now_unix;
      bucket_width = `Hour;
      utc_offset_min = 540;
      buckets =
        List.init 12 (fun i ->
            {
              Wire_runtime.start_unix =
                now_unix -. (float_of_int (12 - i) *. 3600.0);
              activity =
                Wire_runtime.Series_active
                  {
                    calls = 40 + (i * 12);
                    failures = 1;
                    deferred = 0;
                    p95_ms = 25.0 +. (float_of_int i *. 18.0);
                  };
            });
    }
  in
  let rt_tools_only =
    m0.runtime
    |> Runtime_store.set_tab Nav.Runtime_efficiency_spend
    |> Runtime_store.apply_tool_series ~observed_at:now_mono tool_series
  in
  let g_ts =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_runtime.render
          ~model:{ m0 with freshness; runtime = rt_tools_only }
          ~cache ~rect gr)
  in
  assert_grid_invariants ~label:"v25/RuntimeEfficiencyToolSeries" g_ts;
  let ts_braille = count_braille_in_rect g_ts ~x0:68 ~x1:139 ~y0:4 ~y1:24 in
  Alcotest.(check bool)
    (Printf.sprintf "tool_series fallback draws Braille dual-mirror (got %d)"
       ts_braille)
    true (ts_braille >= 20)

let test_v25_runtime_quotas_aliases_and_collapsed_unreported () =
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko () in
  let freshness = { m0.freshness with last_wall_unix = now_unix } in
  let mk_unrep id disp =
    {
      Wire_runtime.scope = "api_wallet";
      scope_id = id;
      providers = [ { id; display_name = disp } ];
      state = Wire_runtime.Account_not_reported_since_start;
      cost_state = Format_val.Unreported;
    }
  in
  let acct_zai : Wire_runtime.account_usage =
    {
      scope = "subscription";
      scope_id = "1d3a9988";
      providers = [ { id = "glm-coding"; display_name = "Z.AI Coding" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "5h";
              kind = Wire_runtime.Window_five_hour;
              role = Wire_runtime.Role_gates_model_calls;
              utilization = Wire_runtime.Util_percent 64;
              resets_at_unix = Some (now_unix +. 5400.0);
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Subscription_zero;
    }
  in
  let acct_or : Wire_runtime.account_usage =
    {
      scope = "api_wallet";
      scope_id = "openrouter";
      providers = [ { id = "openrouter"; display_name = "OpenRouter" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "wallet";
              kind = Wire_runtime.Window_provider_label "wallet";
              role = Wire_runtime.Role_gates_model_calls;
              utilization =
                Wire_runtime.Util_credit_balance
                  { currency = "USD"; total = Some 80.0; remaining = 2.50 };
              resets_at_unix = None;
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Amount 2.50;
    }
  in
  let acct_exh : Wire_runtime.account_usage =
    {
      scope = "api_wallet";
      scope_id = "ollama_cloud";
      providers = [ { id = "ollama_cloud"; display_name = "Ollama Cloud" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "wallet";
              kind = Wire_runtime.Window_provider_label "wallet";
              role = Wire_runtime.Role_gates_model_calls;
              utilization =
                Wire_runtime.Util_credit_balance
                  { currency = "USD"; total = Some 20.0; remaining = 0.0 };
              resets_at_unix = None;
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Exhausted_zero;
    }
  in
  let resolved : Wire_runtime.runtime_resolved_snapshot =
    {
      generated_at_iso = "2026-11-22T02:00:00Z";
      config_path = Some ".masc/runtime.toml";
      default_route = Some "default";
      lanes = [];
      runtimes =
        [
          {
            id = "alice.opus";
            provider_id = "claude_code_1c0558f0";
            provider = "claude_code_1c0558f0";
            model = Some "opus";
            declared_reasoning_effort = None;
            transport = Some "cli";
            is_default = true;
          };
        ];
      usage_windows =
        Some
          {
            since_unix = now_unix -. 3600.0;
            accounts =
              [
                mk_unrep "claude_code_1c0558f0" "claude_code_1c0558f0";
                mk_unrep "custom_cli_9f8e7d6c" "custom_cli_9f8e7d6c";
                mk_unrep "antigravity_e5f60718" "antigravity_e5f60718";
                acct_zai;
                acct_or;
                acct_exh;
              ];
          };
    }
  in
  let rt =
    m0.runtime
    |> Runtime_store.set_tab Nav.Runtime_quotas_credits
    |> Runtime_store.apply_runtime_resolved ~observed_at:now_mono resolved
  in
  let g_collapsed =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_runtime.render ~model:{ m0 with freshness; runtime = rt } ~cache
          ~rect gr)
  in
  assert_grid_invariants ~label:"v25/RuntimeQuotasCollapsed" g_collapsed;
  assert_no_cobalt_selection ~label:"v25/RuntimeQuotasCollapsed" g_collapsed;
  let txt_c = grid_all_text g_collapsed in
  Alcotest.(check bool) "shows human alias Z.AI Coding without #1d3a suffix" true
    (contains_sub ~needle:"Z.AI Coding" ~haystack:txt_c
    && not (contains_sub ~needle:"#1d3a" ~haystack:txt_c));
  Alcotest.(check bool) "hides raw claude_code_1c0558f0 hash" false
    (contains_sub ~needle:"claude_code_1c0558f0" ~haystack:txt_c);
  Alcotest.(check bool) "hides raw custom_cli_9f8e7d6c hash" false
    (contains_sub ~needle:"custom_cli_9f8e7d6c" ~haystack:txt_c);
  Alcotest.(check bool) "renders collapsed ▸ 미보고 API 키 (3개) footer" true
    (contains_sub ~needle:"▸ 미보고 API 키 (3개)" ~haystack:txt_c);
  Alcotest.(check bool) "fills left bottom with cooldown/health card" true
    (contains_sub ~needle:"쿨다운 · 프로바이더 헬스" ~haystack:txt_c);
  (* Expanding via toggle_unreported_accounts reveals clean human aliases *)
  let rt_exp = Runtime_store.toggle_unreported_accounts rt in
  let g_exp =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_runtime.render ~model:{ m0 with freshness; runtime = rt_exp }
          ~cache ~rect gr)
  in
  assert_grid_invariants ~label:"v25/RuntimeQuotasExpanded" g_exp;
  let txt_e = grid_all_text g_exp in
  Alcotest.(check bool) "expanded footer switches to ▾ 미보고 API 키 (3개)" true
    (contains_sub ~needle:"▾ 미보고 API 키 (3개)" ~haystack:txt_e);
  Alcotest.(check bool) "expanded shows human alias Claude Code (alice)" true
    (contains_sub ~needle:"Claude Code (alice)" ~haystack:txt_e);
  Alcotest.(check bool) "expanded shows human alias Antigravity CLI" true
    (contains_sub ~needle:"Antigravity CLI" ~haystack:txt_e);
  Alcotest.(check bool) "expanded shows human alias Custom Cli #9f8e" true
    (contains_sub ~needle:"Custom Cli #9f8e" ~haystack:txt_e)

let test_v25_infra_sandboxes_8col_mapping_and_inspector () =
  let m_base = make_rich_model ~lang:Say.Lang_ko ~cols:140 ~rows:40 in
  let m =
    {
      m_base with
      infra =
        Infra_store.set_tab Nav.Infra_sandboxes m_base.infra
        |> Infra_store.move_selection ~delta:2;
    }
  in
  let g =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_infra.render ~model:m ~cache ~rect gr)
  in
  assert_grid_invariants ~label:"v25/InfraSandboxes8Col" g;
  assert_no_cobalt_selection ~label:"v25/InfraSandboxes8Col" g;
  let txt = grid_all_text g in
  (* Verify all 8 canonical Korean column headers appear in table *)
  List.iter
    (fun col_hdr ->
      Alcotest.(check bool)
        ("renders 8-col header " ^ col_hdr)
        true
        (contains_sub ~needle:col_hdr ~haystack:txt))
    [ "키퍼"; "백엔드"; "상태"; "RTT"; "호스트/풀"; "네트워크"; "심/계정"; "24h 실패" ];
  (* Find exact table header row & column X boundaries for host_pool / network / shim_acct *)
  let find_col_x ~y ~needle =
    let rec scan x =
      if x >= 84 then None
      else
        let seg = grid_row_text g ~y ~x0:x ~x1:(x + 12) in
        if String.starts_with ~prefix:needle seg then Some x else scan (x + 1)
    in
    scan 0
  in
  let hdr_y =
    let rec find_y y =
      if y >= 40 then Alcotest.fail "could not locate sandbox table header row"
      else
        let row_s = grid_row_text g ~y ~x0:0 ~x1:84 in
        if
          contains_sub ~needle:"호스트/풀" ~haystack:row_s
          && contains_sub ~needle:"네트워크" ~haystack:row_s
          && contains_sub ~needle:"심/계정" ~haystack:row_s
        then y
        else find_y (y + 1)
    in
    find_y 6
  in
  let x_host = Option.get (find_col_x ~y:hdr_y ~needle:"호스트/풀") in
  let x_net = Option.get (find_col_x ~y:hdr_y ~needle:"네트워크") in
  let x_shim = Option.get (find_col_x ~y:hdr_y ~needle:"심/계정") in
  let x_fail = Option.get (find_col_x ~y:hdr_y ~needle:"24h 실패") in
  let ssh_row_y =
    let rec find_y y =
      if y >= 40 then Alcotest.fail "could not locate remote_ssh code-reviewer row"
      else
        let row_s = grid_row_text g ~y ~x0:0 ~x1:x_host in
        if contains_sub ~needle:"code-reviewer" ~haystack:row_s then y
        else find_y (y + 1)
    in
    find_y (hdr_y + 1)
  in
  let host_cell = grid_row_text g ~y:ssh_row_y ~x0:x_host ~x1:x_net in
  let net_cell = grid_row_text g ~y:ssh_row_y ~x0:x_net ~x1:x_shim in
  let shim_cell = grid_row_text g ~y:ssh_row_y ~x0:x_shim ~x1:x_fail in
  Alcotest.(check bool)
    (Printf.sprintf "host_pool cell maps pool_name (got %S)" host_cell)
    true
    (contains_sub ~needle:"masc-ssh" ~haystack:host_cell);
  Alcotest.(check bool)
    (Printf.sprintf "network cell maps 'ssh' and NOT pool_name (got %S)" net_cell)
    true
    (contains_sub ~needle:"ssh" ~haystack:net_cell
    && not (contains_sub ~needle:"masc-ssh" ~haystack:net_cell));
  Alcotest.(check bool)
    (Printf.sprintf "shim_acct cell maps unix_user 'ops-user' (got %S)" shim_cell)
    true
    (contains_sub ~needle:"ops-user" ~haystack:shim_cell);
  (* Right-side 4-section Inspector populates all sections without void *)
  let right_txt =
    let buf = Buffer.create 1024 in
    for y = 6 to 39 do
      Buffer.add_string buf (grid_row_text g ~y ~x0:82 ~x1:140);
      Buffer.add_char buf '\n'
    done;
    Buffer.contents buf
  in
  List.iter
    (fun sec ->
      Alcotest.(check bool)
        ("right inspector renders section " ^ sec)
        true
        (contains_sub ~needle:sec ~haystack:right_txt))
    [ "리소스 · 연결 스펙"; "24h 도구 실행 요약"; "최근 로그 · 이벤트" ]

let test_v25_knowledge_stacked_bar_and_conflict_rails () =
  let m_base = make_rich_model ~lang:Say.Lang_ko ~cols:140 ~rows:40 in
  let m_mem =
    {
      m_base with
      knowledge = Knowledge_store.set_tab Nav.Knowledge_memory m_base.knowledge;
    }
  in
  let g =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_knowledge.render ~model:m_mem ~cache ~rect gr)
  in
  assert_grid_invariants ~label:"v25/KnowledgeMemory" g;
  assert_no_cobalt_selection ~label:"v25/KnowledgeMemory" g;
  let theme = Theme.of_preset m_mem.theme_preset in
  let violet = Color.of_rgb theme.status_ai in
  let amber = Color.of_rgb theme.status_attention in
  let rail_utf8 = Glyph.to_utf8 Glyph.Left_rail in
  let violet_rails = ref 0 in
  let amber_rails = ref 0 in
  let stacked_blocks = ref 0 in
  for y = 0 to 39 do
    for x = 0 to 139 do
      let c = Cell_grid.get g ~x ~y in
      match c.glyph with
      | Cell_grid.Utf8 s when String.equal s rail_utf8 ->
          if Color.equal c.style.fg violet then incr violet_rails;
          if Color.equal c.style.fg amber then incr amber_rails
      | Cell_grid.Utf8 s when String.equal s "\xe2\x96\x88" ->
          if x >= 65 then incr stacked_blocks
      | Cell_grid.Utf8 _
      | Cell_grid.Empty
      | Cell_grid.Ascii _
      | Cell_grid.Braille _
      | Cell_grid.Continuation ->
          ()
    done
  done;
  Alcotest.(check bool)
    (Printf.sprintf "MVCC Claim A renders Violet ▎ rail (got %d)" !violet_rails)
    true (!violet_rails >= 2);
  Alcotest.(check bool)
    (Printf.sprintf "MVCC Claim B renders Amber ▎ rail (got %d)" !amber_rails)
    true (!amber_rails >= 2);
  Alcotest.(check bool)
    (Printf.sprintf "Temporal Memory renders HOT/WARM/COLD Stacked_bar (got %d blocks)"
       !stacked_blocks)
    true (!stacked_blocks >= 20);
  (* Also verify Wiki Wide TOC rail renders on 140x40 *)
  let m_wiki =
    {
      m_base with
      knowledge =
        Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts m_base.knowledge;
    }
  in
  let g_wiki =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_knowledge.render ~model:m_wiki ~cache ~rect gr)
  in
  assert_grid_invariants ~label:"v25/KnowledgeWikiToc" g_wiki;
  assert_no_cobalt_selection ~label:"v25/KnowledgeWikiToc" g_wiki;
  Alcotest.(check bool) "Wiki Wide renders TOC rail" true
    (contains_sub ~needle:"목차" ~haystack:(grid_all_text g_wiki))

let test_p1_7_fleet_health_counts_ssot () =
  let mk_k ~name ~health ?(paused = false) ?(keepalive_running = true) () :
      Wire_fleet.keeper_summary =
    {
      name;
      group = Some "MASC Core";
      company = "MASC Core";
      health;
      paused;
      keepalive_running;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "sonnet";
      model_id = Some "claude-sonnet-4";
      current_task_id = None;
      context = Observed.unreported;
      total_turns = Observed.unreported;
      last_turn_at_unix = None;
      active_turn = None;
      activity_sparkline_24h = [];
    }
  in
  (* Live 8935 realistic 32-keeper roster: 11 active (3 working + 7 healthy + 1 degraded),
     5 failing (with keepalive_running=true!), 16 ordinary offline keepers. *)
  let keepers =
    List.init 3 (fun i ->
        mk_k ~name:(Printf.sprintf "work-%d" i) ~health:Wire_fleet.Keeper_working ())
    @ List.init 7 (fun i ->
        mk_k ~name:(Printf.sprintf "ok-%d" i) ~health:Wire_fleet.Keeper_healthy ())
    @ [ mk_k ~name:"deg-0" ~health:Wire_fleet.Keeper_degraded () ]
    @ List.init 5 (fun i ->
        mk_k ~name:(Printf.sprintf "fail-%d" i) ~health:Wire_fleet.Keeper_failing
          ~keepalive_running:true ())
    @ List.init 16 (fun i ->
        mk_k ~name:(Printf.sprintf "off-%d" i) ~health:Wire_fleet.Keeper_offline
          ~keepalive_running:false ())
  in
  let hc = Fleet_store.fleet_health_counts keepers in
  Alcotest.(check int) "total = 32" 32 hc.total;
  Alcotest.(check int) "active = 11" 11 hc.active;
  Alcotest.(check int) "working = 3" 3 hc.working;
  Alcotest.(check int) "healthy = 7" 7 hc.healthy;
  Alcotest.(check int) "degraded = 1" 1 hc.degraded;
  Alcotest.(check int) "failing = 5 (never lumps 16 offline into 21)" 5 hc.failing;
  Alcotest.(check int) "offline = 16" 16 hc.offline;
  Alcotest.(check int) "paused = 0" 0 hc.paused;
  Alcotest.(check int) "active partition invariant" hc.active
    (hc.working + hc.healthy + hc.degraded);
  Alcotest.(check int) "total partition invariant" hc.total
    (hc.active + hc.failing + hc.paused + hc.offline);
  let k_off = mk_k ~name:"stopped-k" ~health:Wire_fleet.Keeper_offline ~keepalive_running:false () in
  let k_fail = mk_k ~name:"broken-k" ~health:Wire_fleet.Keeper_failing () in
  Alcotest.(check bool) "Keeper_offline maps to Health.Idle (not Down)" true
    (match Fleet_store.keeper_live_state k_off with
    | Health.Idle -> true
    | Health.Healthy
    | Health.Working _
    | Health.Needs_attention _
    | Health.Degraded _
    | Health.Down _ ->
        false);
  Alcotest.(check bool) "Keeper_failing maps to Health.Down" true
    (match Fleet_store.keeper_live_state k_fail with
    | Health.Down _ -> true
    | Health.Healthy
    | Health.Working _
    | Health.Needs_attention _
    | Health.Idle
    | Health.Degraded _ ->
        false)

let test_p1_5_infra_sandboxes_404_fallback_honesty () =
  let mk_k ~name ~health : Wire_fleet.keeper_summary =
    {
      name;
      group = Some "MASC Core";
      company = "MASC Core";
      health;
      paused = false;
      keepalive_running = (health <> Wire_fleet.Keeper_offline);
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "sonnet";
      model_id = None;
      current_task_id = None;
      context = Observed.unreported;
      total_turns = Observed.unreported;
      last_turn_at_unix = None;
      active_turn = None;
      activity_sparkline_24h = [];
    }
  in
  let keepers =
    List.init 5 (fun i ->
        mk_k ~name:(Printf.sprintf "vm-ok-%02d" i) ~health:Wire_fleet.Keeper_healthy)
    @ List.init 14 (fun i ->
        mk_k ~name:(Printf.sprintf "vm-off-%02d" i) ~health:Wire_fleet.Keeper_offline)
  in
  let profiles =
    List.map (fun (k : Wire_fleet.keeper_summary) -> (k.name, Wire_fleet.Profile_microvm))
      keepers
  in
  let infra =
    Infra_store.empty
    |> Infra_store.set_tab Nav.Infra_sandboxes
    |> Infra_store.apply_sandboxes_fallback ~observed_at:now_mono
         ~wall_unix:now_unix ~keepers ~sandbox_profiles:profiles
         ~tool_series_totals:None
  in
  (match Observed.to_option infra.sandboxes with
  | None -> Alcotest.fail "expected fallback sandboxes snapshot"
  | Some snap ->
      Alcotest.(check int) "19 microVM guests synthesized" 19 snap.microvm_declared;
      Alcotest.(check int)
        "microvm_running = 0 when agent_socket = Socket_absent (never 5/19)" 0
        snap.microvm_running;
      List.iter
        (fun (g : Wire_infra.microvm_guest) ->
          Alcotest.(check bool) "fallback shim_parity = Shim_undeclared" true
            (g.shim_parity = Wire_infra.Shim_undeclared);
          Alcotest.(check bool)
            "fallback presence is NOT 'running' when Socket_absent" false
            (String.equal g.presence "running"))
        snap.microvm_guests);
  List.iter
    (fun lang ->
      let m0 = Model.initial ~cols:140 ~rows:40 ~lang () in
      let m =
        {
          m0 with
          freshness = { m0.freshness with last_wall_unix = now_unix };
          infra;
        }
      in
      let g =
        render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
            Screen_infra.render ~model:m ~cache ~rect gr)
      in
      assert_grid_invariants ~label:("P1-5/InfraFallback/" ^ Say.lang_code lang) g;
      let txt = grid_all_text g in
      let expected_shim =
        match lang with
        | Say.Lang_ko -> "심 미보고"
        | Say.Lang_en -> "Shim unreported"
      in
      let forbidden_green_shim =
        match lang with
        | Say.Lang_ko -> "✓ 심 일치"
        | Say.Lang_en -> "✓ Shim match"
      in
      Alcotest.(check bool)
        ("renders neutral Shim_undeclared label (" ^ Say.lang_code lang ^ ")")
        true
        (contains_sub ~needle:expected_shim ~haystack:txt);
      Alcotest.(check bool)
        ("mentions Legacy API on 404 fallback (" ^ Say.lang_code lang ^ ")")
        true
        (contains_sub ~needle:"Legacy API" ~haystack:txt);
      Alcotest.(check bool)
        ("NEVER renders false-green shim match (" ^ Say.lang_code lang ^ ")")
        false
        (contains_sub ~needle:forbidden_green_shim ~haystack:txt);
      Alcotest.(check bool)
        ("NEVER renders 5/19 running contradiction (" ^ Say.lang_code lang ^ ")")
        false
        (contains_sub ~needle:"5/19" ~haystack:txt);
      (* Sandbox_dive aligns raw JSON toggle hint to [Space], never conflicting [J] *)
      let g_dive =
        render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
            Screen_infra.render_dive ~target:(Nav.Sandbox_dive "vm-ok-00")
              ~model:m ~cache ~rect gr)
      in
      assert_grid_invariants ~label:("P1-5/SandboxDive/" ^ Say.lang_code lang) g_dive;
      let dive_txt = grid_all_text g_dive in
      Alcotest.(check bool) "Sandbox_dive uses [Space] for Json_tree" true
        (contains_sub ~needle:"[Space]" ~haystack:dive_txt);
      Alcotest.(check bool) "Sandbox_dive never prints conflicting [J] Json_tree"
        false
        (contains_sub ~needle:"[J]" ~haystack:dive_txt))
    [ Say.Lang_ko; Say.Lang_en ]

let test_p0_1_p0_2_runtime_spend_provenance_mtd_and_dual_usd () =
  let m0 = Model.initial ~cols:140 ~rows:40 ~lang:Say.Lang_ko () in
  let freshness = { m0.freshness with last_wall_unix = now_unix } in
  (* 32 active keepers in fleet roster *)
  let active_keepers =
    List.init 32 (fun i ->
        {
          Wire_fleet.name = Printf.sprintf "active-keeper-%02d" i;
          group = Some "MASC Core";
          company = "MASC Core";
          health = Wire_fleet.Keeper_healthy;
          paused = false;
          keepalive_running = true;
          activation_mode = Wire_fleet.Activation_autonomous;
          runtime_id = "sonnet";
          model_id = None;
          current_task_id = None;
          context = Observed.unreported;
          total_turns = Observed.unreported;
          last_turn_at_unix = None;
          active_turn = None;
          activity_sparkline_24h = [];
        })
  in
  let fleet = Fleet_store.apply_keepers ~observed_at:now_mono active_keepers m0.fleet in
  let keeper_costs : Wire_runtime.keeper_costs_window =
    {
      generated_at_unix = now_unix;
      window_minutes = 1440;
      rows =
        [
          {
            keeper_name = "active-keeper-00";
            sample_count = 40;
            total_tokens = Observed.value ~observed_at:now_mono 120_000;
            total_cost_usd = Observed.value ~observed_at:now_mono 7.83;
            tokens_reported_samples = 40;
            tokens_missing_samples = 0;
            cost_reported_samples = 40;
            cost_missing_samples = 0;
          };
        ];
    }
  in
  (* 1. Keeper-costs only: Spend_keeper_turns_24h & Spend_window_24h *)
  let rt_kp_only =
    m0.runtime
    |> Runtime_store.apply_keeper_costs ~observed_at:now_mono keeper_costs
  in
  let bd_kp = Runtime_store.spend_24h_breakdown rt_kp_only in
  Alcotest.(check bool) "keeper-only source = Spend_keeper_turns_24h" true
    (bd_kp.source = Runtime_store.Spend_keeper_turns_24h);
  Alcotest.(check (option (float 0.01))) "keeper-only total = 7.83" (Some 7.83)
    (Observed.to_option bd_kp.total_usd);
  Alcotest.(check (option (float 0.01))) "keeper-only system delta = None" None
    bd_kp.system_unattributed_usd;
  (match Runtime_store.keeper_spend_table_window rt_kp_only with
  | Runtime_store.Spend_window_24h { window_minutes = 1440 } -> ()
  | Runtime_store.Spend_window_24h _
  | Runtime_store.Spend_window_mtd _
  | Runtime_store.Spend_window_month_complete _
  | Runtime_store.Spend_window_none ->
      Alcotest.fail "expected Spend_window_24h(1440)");
  (* 2. Add models/metrics ($82.57 24h provider total, peak 4200 calls & $6.12/h)
     and monthly MTD efficiency (40 keepers = 32 active + 8 retired). *)
  let buckets =
    List.init 24 (fun i ->
        let fi = float_of_int i in
        {
          Wire_runtime.ts_start = now_unix -. (float_of_int (24 - i) *. 3600.0);
          entry_count = if i = 18 then 4200 else 300 + (i * 40);
          success_count = if i = 18 then 4190 else 295 + (i * 40);
          error_count = 5;
          total_cost_usd = if i = 18 then 6.12 else 0.45 +. (fi *. 0.12);
          p95_latency_ms = Some 1200.0;
          cache_hit_pct = Some 97.5;
          input_tokens = None;
          output_tokens = None;
          cache_read_tokens = None;
        })
  in
  let models_metrics : Wire_runtime.models_metrics_snapshot =
    {
      window_minutes = 1440;
      bucket_minutes = 60;
      total_entries = 18_400;
      total_error_entries = 120;
      models = [];
      hourly_buckets = buckets;
      fleet_cache_hit_pct = Observed.value ~observed_at:now_mono 97.8;
      fleet_cost_usd = Observed.value ~observed_at:now_mono 82.57;
      fleet_input_tokens = 20_000_000;
      fleet_output_tokens = 1_200_000;
      fleet_cache_read_tokens = 19_560_000;
      fleet_cache_creation_tokens = 120_000;
      fleet_tool_calls = 9200;
      fleet_p95_latency_ms = Some 1400.0;
    }
  in
  let eff_rows =
    List.init 32 (fun i ->
        {
          Wire_runtime.keeper = Printf.sprintf "active-keeper-%02d" i;
          turns = 100 + i;
          input_tokens = 200_000;
          cache_read_tokens = Observed.unreported;
          cache_creation_tokens = Observed.unreported;
          output_tokens = 12_000;
          cache_hit_pct = Observed.unreported;
          cost_usd = 16.0;
          calls = 250;
          failed = 1;
          deferred = 0;
          tool_ms = 5000.0;
        })
    @ List.init 8 (fun i ->
        {
          Wire_runtime.keeper = Printf.sprintf "retired-keeper-%02d" i;
          turns = 50 + i;
          input_tokens = 80_000;
          cache_read_tokens = Observed.unreported;
          cache_creation_tokens = Observed.unreported;
          output_tokens = 4_000;
          cache_hit_pct = Observed.unreported;
          cost_usd = 20.05;
          calls = 120;
          failed = 0;
          deferred = 0;
          tool_ms = 2000.0;
        })
  in
  let eff_mtd : Wire_runtime.efficiency_month =
    {
      month = "2026-11";
      window_kind = Some Wire_runtime.Efficiency_month_mtd;
      generated_at_unix = now_unix;
      days_covered = 22;
      keepers = eff_rows;
      fleet =
        {
          turns_total = 4200;
          calls_per_turn = 2.4;
          tool_s_per_turn = 1.2;
          output_tokens_per_turn = 120.0;
          input_tokens_per_turn = 2100.0;
          cost_usd_per_turn = 0.16;
          fleet_cache_hit_pct = Observed.unreported;
        };
      velocity = [];
    }
  in
  let rt_full =
    rt_kp_only
    |> Runtime_store.set_tab Nav.Runtime_efficiency_spend
    |> Runtime_store.apply_models_metrics ~observed_at:now_mono models_metrics
    |> Runtime_store.apply_efficiency ~observed_at:now_mono eff_mtd
  in
  let bd_full = Runtime_store.spend_24h_breakdown rt_full in
  Alcotest.(check bool) "provider source = Spend_provider_24h" true
    (bd_full.source = Runtime_store.Spend_provider_24h);
  Alcotest.(check (option (float 0.01))) "provider total = 82.57" (Some 82.57)
    (Observed.to_option bd_full.total_usd);
  Alcotest.(check (option (float 0.01))) "keeper attributed = 7.83" (Some 7.83)
    (Observed.to_option bd_full.keeper_attributed_usd);
  Alcotest.(check (option (float 0.01))) "system delta = 74.74" (Some 74.74)
    bd_full.system_unattributed_usd;
  (match Runtime_store.keeper_spend_table_window rt_full with
  | Runtime_store.Spend_window_mtd { month = "2026-11"; days_covered = 22 } -> ()
  | Runtime_store.Spend_window_mtd _
  | Runtime_store.Spend_window_month_complete _
  | Runtime_store.Spend_window_24h _
  | Runtime_store.Spend_window_none ->
      Alcotest.fail "expected Spend_window_mtd(2026-11, 22)");
  let g =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_runtime.render
          ~model:{ m0 with freshness; fleet; runtime = rt_full }
          ~cache ~rect gr)
  in
  assert_grid_invariants ~label:"P0-1-P0-2/RuntimeEfficiency" g;
  let txt = grid_all_text g in
  Alcotest.(check bool) "table explicitly badged 월간 누계 (MTD)" true
    (contains_sub ~needle:"월간 누계 (MTD)" ~haystack:txt);
  Alcotest.(check bool) "active vs retired split shown (32 활성 · 8 이력)" true
    (contains_sub ~needle:"32 활성 · 8 이력" ~haystack:txt);
  Alcotest.(check bool) "Dual-Mirror Spend Y-axis prints real USD ($6.12)" true
    (contains_sub ~needle:"$6.12" ~haystack:txt);
  Alcotest.(check bool) "Dual-Mirror Spend Y-axis NEVER prints ▼5.0k or ▼6.1k"
    false
    (contains_sub ~needle:"▼5.0k" ~haystack:txt
    || contains_sub ~needle:"▼6.1k" ~haystack:txt);
  (* Deduplicated Chart B title vs row+1 legend: border must not repeat '호출'/'지출' *)
  Alcotest.(check bool)
    "Chart B outer title avoids repeating legend '▲ 호출 · ▼ 지출'" false
    (contains_sub ~needle:"24h 모델 호출 · 지출" ~haystack:txt);
  (* Completed past month emits Spend_window_month_complete & '월간 마감' badge *)
  let eff_complete =
    {
      eff_mtd with
      month = "2026-10";
      days_covered = 31;
      window_kind = Some Wire_runtime.Efficiency_month_complete;
    }
  in
  let rt_complete =
    Runtime_store.apply_efficiency ~observed_at:now_mono eff_complete rt_full
  in
  (match Runtime_store.keeper_spend_table_window rt_complete with
  | Runtime_store.Spend_window_month_complete { month = "2026-10"; days_covered = 31 } -> ()
  | Runtime_store.Spend_window_month_complete _
  | Runtime_store.Spend_window_mtd _
  | Runtime_store.Spend_window_24h _
  | Runtime_store.Spend_window_none ->
      Alcotest.fail "expected Spend_window_month_complete(2026-10, 31)");
  let g_complete =
    render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
        Screen_runtime.render
          ~model:{ m0 with freshness; fleet; runtime = rt_complete }
          ~cache ~rect gr)
  in
  let txt_complete = grid_all_text g_complete in
  Alcotest.(check bool) "completed month badged 월간 마감" true
    (contains_sub ~needle:"월간 마감" ~haystack:txt_complete);
  Alcotest.(check bool) "completed month NOT mislabeled as MTD" false
    (contains_sub ~needle:"월간 누계 (MTD)" ~haystack:txt_complete)

let test_p1_9_p1_10_quotas_max_window_buckets_and_human_cooldowns () =
  (* Saturated Subscription_zero account: 5h=0%, 7d=100% (max across ALL windows!) *)
  let acct_sat_sub : Wire_runtime.account_usage =
    {
      scope = "subscription";
      scope_id = "sub_sat";
      providers = [ { id = "claude_code_sat"; display_name = "Claude Code Sat" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "5h";
              kind = Wire_runtime.Window_five_hour;
              role = Wire_runtime.Role_gates_model_calls;
              utilization = Wire_runtime.Util_percent 0;
              resets_at_unix = Some (now_unix +. 3600.0);
              observed_at_unix = now_unix;
            };
            {
              limit_id = Some "7d";
              kind = Wire_runtime.Window_seven_day;
              role = Wire_runtime.Role_gates_model_calls;
              utilization = Wire_runtime.Util_percent 100;
              resets_at_unix = Some (now_unix +. (5.0 *. 86400.0) +. (21.0 *. 3600.0));
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Subscription_zero;
    }
  in
  let mk_cooldown_sub ~id ~disp ~reset_sec : Wire_runtime.account_usage =
    {
      scope = "subscription";
      scope_id = id;
      providers = [ { id; display_name = disp } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "7d";
              kind = Wire_runtime.Window_seven_day;
              role = Wire_runtime.Role_gates_model_calls;
              utilization = Wire_runtime.Util_percent 100;
              resets_at_unix = Some (now_unix +. reset_sec);
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Subscription_zero;
    }
  in
  let acct_cd_43h =
    mk_cooldown_sub ~id:"cd_43h" ~disp:"Cooldown 43h"
      ~reset_sec:((43.0 *. 3600.0) +. (58.0 *. 60.0))
  in
  let acct_cd_12m =
    mk_cooldown_sub ~id:"cd_12m" ~disp:"Cooldown 12m"
      ~reset_sec:((12.0 *. 60.0) +. 4.0)
  in
  let acct_ollama_exh : Wire_runtime.account_usage =
    {
      scope = "api_wallet";
      scope_id = "ollama_cloud";
      providers = [ { id = "ollama_cloud"; display_name = "Ollama Cloud" } ];
      state =
        Wire_runtime.Account_reported
          [
            {
              limit_id = Some "wallet";
              kind = Wire_runtime.Window_provider_label "wallet";
              role = Wire_runtime.Role_gates_model_calls;
              utilization =
                Wire_runtime.Util_credit_balance
                  { currency = "USD"; total = Some 20.0; remaining = 0.0 };
              resets_at_unix = None;
              observed_at_unix = now_unix;
            };
          ];
      cost_state = Format_val.Exhausted_zero;
    }
  in
  (* Extra healthy subscription accounts so left Quotas pane overflows (>16 rows) and renders ▼ N개 더 *)
  let extra_subs =
    List.init 18 (fun i ->
        let id = Printf.sprintf "sub_extra_%02d" i in
        {
          Wire_runtime.scope = "subscription";
          scope_id = id;
          providers = [ { id; display_name = Printf.sprintf "Sub Extra %02d" i } ];
          state =
            Wire_runtime.Account_reported
              [
                {
                  limit_id = Some "5h";
                  kind = Wire_runtime.Window_five_hour;
                  role = Wire_runtime.Role_gates_model_calls;
                  utilization = Wire_runtime.Util_percent (15 + (i * 3));
                  resets_at_unix = Some (now_unix +. 7200.0);
                  observed_at_unix = now_unix;
                };
              ];
          cost_state = Format_val.Subscription_zero;
        })
  in
  let accounts =
    [ acct_sat_sub; acct_cd_43h; acct_cd_12m; acct_ollama_exh ] @ extra_subs
  in
  let runtimes : Wire_runtime.runtime_option list =
    [
      { id = "slot-ollama"; provider_id = "ollama_cloud"; provider = "ollama_cloud"; model = Some "qwen3"; declared_reasoning_effort = None; transport = Some "http"; is_default = false };
      { id = "slot-5d"; provider_id = "claude_code_sat"; provider = "claude_code_sat"; model = Some "sonnet"; declared_reasoning_effort = None; transport = Some "cli"; is_default = true };
      { id = "slot-43h"; provider_id = "cd_43h"; provider = "cd_43h"; model = Some "glm"; declared_reasoning_effort = None; transport = Some "http"; is_default = false };
      { id = "slot-12m"; provider_id = "cd_12m"; provider = "cd_12m"; model = Some "kimi"; declared_reasoning_effort = None; transport = Some "http"; is_default = false };
    ]
  in
  let resolved : Wire_runtime.runtime_resolved_snapshot =
    {
      generated_at_iso = "2026-11-22T02:00:00Z";
      config_path = Some ".masc/runtime.toml";
      default_route = Some "lane-honesty";
      lanes =
        [
          {
            id = "lane-honesty";
            declared = true;
            runtime_ids = [ "slot-ollama"; "slot-5d"; "slot-43h"; "slot-12m" ];
          };
        ];
      runtimes;
      usage_windows = Some { since_unix = now_unix -. 3600.0; accounts };
    }
  in
  let probe : Wire_runtime.runtime_probe_snapshot =
    {
      generated_at = "2026-11-22T02:00:00Z";
      cache_ttl_sec = 60.0;
      cache_age_sec = Some 5.0;
      cache_hit = true;
      refresh_state = Wire_runtime.Probe_fresh;
      status = Wire_runtime.Probe_degraded;
      probe_ok = true;
      default_runtime_id = Some "slot-5d";
      runtimes_count = 4;
      probed_count = 4;
      reachable_count = 1;
      failed_count = 3;
      skipped_count = 0;
      providers =
        [
          (* Probe says reachable=true 297ms, BUT account has Exhausted_zero ($0 소진)! *)
          {
            runtime_id = "slot-ollama";
            transport = `Http;
            status = "ok";
            reachable = Some true;
            http_status = Some 200;
            latency_ms = Some 297.0;
            error = None;
            checked_at = "2026-11-22T02:00:00Z";
          };
          {
            runtime_id = "slot-5d";
            transport = `Cli;
            status = "rate_limited";
            reachable = Some false;
            http_status = Some 429;
            latency_ms = None;
            error = Some "rate_limited";
            checked_at = "2026-11-22T02:00:00Z";
          };
          {
            runtime_id = "slot-43h";
            transport = `Http;
            status = "rate_limited";
            reachable = Some false;
            http_status = Some 429;
            latency_ms = None;
            error = Some "rate_limited";
            checked_at = "2026-11-22T02:00:00Z";
          };
          {
            runtime_id = "slot-12m";
            transport = `Http;
            status = "rate_limited";
            reachable = Some false;
            http_status = Some 429;
            latency_ms = None;
            error = Some "rate_limited";
            checked_at = "2026-11-22T02:00:00Z";
          };
        ];
      errors = [];
      observations = [];
      limitations = [];
    }
  in
  List.iter
    (fun lang ->
      let m0 = Model.initial ~cols:140 ~rows:40 ~lang () in
      let freshness = { m0.freshness with last_wall_unix = now_unix } in
      let rt_base =
        m0.runtime
        |> Runtime_store.apply_runtime_resolved ~observed_at:now_mono resolved
        |> Runtime_store.apply_runtime_probe ~observed_at:now_mono probe
      in
      (* A. Quotas & Credits tab *)
      let g_q =
        render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
            Screen_runtime.render
              ~model:
                {
                  m0 with
                  freshness;
                  runtime = Runtime_store.set_tab Nav.Runtime_quotas_credits rt_base;
                }
              ~cache ~rect gr)
      in
      assert_grid_invariants ~label:("P1-9/Quotas/" ^ Say.lang_code lang) g_q;
      let txt_q = grid_all_text g_q in
      let sat_lbl =
        match lang with
        | Say.Lang_ko -> "한도 소진 (구독)"
        | Say.Lang_en -> "Limit Exhausted (Sub)"
      in
      let more_lbl =
        match lang with
        | Say.Lang_ko -> "개 더"
        | Say.Lang_en -> "more"
      in
      Alcotest.(check bool)
        ("P1-9 max(5h=0%,7d=100%) renders saturated sub (" ^ Say.lang_code lang ^ ")")
        true
        (contains_sub ~needle:sat_lbl ~haystack:txt_q);
      (* Total 22 providers = 18 ok + 3 cooldown + 1 exhausted + 0 unreported *)
      let bucket_summary =
        match lang with
        | Say.Lang_ko -> "22 프로바이더"
        | Say.Lang_en -> "22 Providers"
      in
      Alcotest.(check bool)
        ("P1-9 reconciled provider total 22 (" ^ Say.lang_code lang ^ ")")
        true
        (contains_sub ~needle:bucket_summary ~haystack:txt_q);
      Alcotest.(check bool)
        ("P1-9 left Quotas overflow indicator shown (" ^ Say.lang_code lang ^ ")")
        true
        (contains_sub ~needle:more_lbl ~haystack:txt_q);
      (* Verifier #243 finding 1: Quotas bottom card cross-checks Exhausted_zero -> 0/4 (not 1/4) *)
      let quotas_lane_ok =
        match lang with
        | Say.Lang_ko -> "1 · 0/4 가용"
        | Say.Lang_en -> "1 · 0/4 ok"
      in
      Alcotest.(check bool)
        ("P1-10 Quotas cooldown summary reports 0/4 ok (" ^ Say.lang_code lang ^ ")")
        true
        (contains_sub ~needle:quotas_lane_ok ~haystack:txt_q);
      (* B. Failover Lanes tab *)
      let g_l =
        render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
            Screen_runtime.render
              ~model:
                {
                  m0 with
                  freshness;
                  runtime = Runtime_store.set_tab Nav.Runtime_failover_lanes rt_base;
                }
              ~cache ~rect gr)
      in
      assert_grid_invariants ~label:("P1-10/Lanes/" ^ Say.lang_code lang) g_l;
      let txt_l = grid_all_text g_l in
      (* Verifier #243 finding 1: Failover Lanes header pill MUST agree with inspector (0/4, never 1/4) *)
      let header_lane_ok =
        match lang with
        | Say.Lang_ko -> "활성 레인: 1 · 0/4 가용"
        | Say.Lang_en -> "Active Lanes: 1 · 0/4 reachable"
      in
      Alcotest.(check bool)
        ("P1-10 Failover Lanes header pill reports 0/4 (" ^ Say.lang_code lang ^ ")")
        true
        (contains_sub ~needle:header_lane_ok ~haystack:txt_l);
      Alcotest.(check bool) "P1-10 human multi-day cooldown 5d 21h" true
        (contains_sub ~needle:"5d 21h" ~haystack:txt_l);
      Alcotest.(check bool) "P1-10 human multi-hour cooldown 43h 58m" true
        (contains_sub ~needle:"43h 58m" ~haystack:txt_l);
      Alcotest.(check bool) "P1-10 human minute cooldown 12m 04s" true
        (contains_sub ~needle:"12m 04s" ~haystack:txt_l);
      Alcotest.(check bool) "P1-10 NEVER formats raw MM:SS 8518:xx" false
        (contains_sub ~needle:"8518:" ~haystack:txt_l);
      let exh_lbl = Format_val.format_cost Format_val.Exhausted_zero ~lang in
      Alcotest.(check bool)
        ("P1-10 Exhausted_zero Ollama Cloud renders " ^ exh_lbl) true
        (contains_sub ~needle:exh_lbl ~haystack:txt_l);
      Alcotest.(check bool)
        "P1-10 Exhausted_zero Ollama Cloud NEVER renders Active 297ms" false
        (contains_sub ~needle:"Active 297ms" ~haystack:txt_l
        || contains_sub ~needle:"297ms" ~haystack:txt_l);
      Alcotest.(check bool)
        "P1-10 lane reachability excludes exhausted slot (0/4)" true
        (contains_sub ~needle:"0/4" ~haystack:txt_l);
      (* Verifier #243 finding 2: Exhausted_zero provider returning HTTP 429 MUST render $0 소진
         in left cascade (matching right inspector), NOT amber Cooldown 429. *)
      let probe_exh_429 =
        {
          probe with
          providers =
            [
              {
                runtime_id = "slot-ollama";
                transport = `Http;
                status = "rate_limited";
                reachable = Some false;
                http_status = Some 429;
                latency_ms = None;
                error = Some "429 quota exhausted";
                checked_at = "2026-11-22T02:00:00Z";
              };
            ];
        }
      in
      let resolved_exh_429 =
        {
          resolved with
          lanes =
            [ { id = "lane-exh-429"; declared = true; runtime_ids = [ "slot-ollama" ] } ];
        }
      in
      let rt_exh_429 =
        m0.runtime
        |> Runtime_store.apply_runtime_resolved ~observed_at:now_mono resolved_exh_429
        |> Runtime_store.apply_runtime_probe ~observed_at:now_mono probe_exh_429
        |> Runtime_store.set_tab Nav.Runtime_failover_lanes
      in
      let g_exh_429 =
        render_into ~cols:140 ~rows:40 (fun ~cache ~rect gr ->
            Screen_runtime.render
              ~model:{ m0 with freshness; runtime = rt_exh_429 }
              ~cache ~rect gr)
      in
      assert_grid_invariants ~label:("P1-10/Exh429/" ^ Say.lang_code lang) g_exh_429;
      let txt_exh_429 = grid_all_text g_exh_429 in
      Alcotest.(check bool)
        ("P1-10 Exhausted_zero+429 renders " ^ exh_lbl ^ " in cascade & inspector")
        true
        (count_occurrences ~needle:exh_lbl ~haystack:txt_exh_429 >= 2);
      Alcotest.(check bool)
        "P1-10 Exhausted_zero+429 NEVER downgrades to Cooldown" false
        (contains_sub ~needle:"Cooldown" ~haystack:txt_exh_429))
    [ Say.Lang_ko; Say.Lang_en ]

let find_left_rail_row ?(y_min = 0) ~x_max (grid : Cell_grid.t) =
  let rail = Glyph.to_utf8 Glyph.Left_rail in
  let found = ref None in
  for y = y_min to Cell_grid.rows grid - 1 do
    if Option.is_none !found then
      for x = 0 to Int.min (Cell_grid.cols grid - 1) x_max do
        if Option.is_none !found then
          match (Cell_grid.get grid ~x ~y).glyph with
          | Cell_grid.Utf8 s when String.equal s rail -> found := Some y
          | Cell_grid.Empty | Cell_grid.Ascii _ | Cell_grid.Braille _
          | Cell_grid.Utf8 _ | Cell_grid.Continuation ->
              ()
      done
  done;
  !found

let assert_strictly_increasing ~label xs =
  let rec check = function
    | [] | [ _ ] -> ()
    | a :: (b :: _ as rest) ->
        Alcotest.(check bool)
          (Printf.sprintf "%s strictly increasing (%d < %d)" label a b)
          true (a < b);
        check rest
  in
  check xs

let test_nav_display_order_monotonic_screen_rows () =
  let m0 = Model.initial ~cols:140 ~rows:44 ~lang:Say.Lang_en () in
  let mk_keeper group name : Wire_fleet.keeper_summary =
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
      context = Observed.value ~observed_at:now_mono (measured_context 0.30);
      total_turns = Observed.value ~observed_at:now_mono 20;
      last_turn_at_unix = Some now_unix;
      active_turn = None;
      activity_sparkline_24h = [ 1.0; 2.0 ];
    }
  in
  let ks =
    [
      mk_keeper "org-high" "high-1";
      mk_keeper "org-high" "high-2";
      mk_keeper "org-mid" "mid-1";
      mk_keeper "org-mid" "mid-2";
      mk_keeper "org-low" "low-1";
    ]
  in
  let mk_eff keeper cost_usd : Wire_runtime.keeper_efficiency_row =
    {
      keeper;
      turns = 10;
      input_tokens = 10_000;
      cache_read_tokens = Observed.value ~observed_at:now_mono 8_000;
      cache_creation_tokens = Observed.value ~observed_at:now_mono 0;
      output_tokens = 400;
      cache_hit_pct = Observed.value ~observed_at:now_mono 80.0;
      cost_usd;
      calls = 20;
      failed = 0;
      deferred = 0;
      tool_ms = 50.0;
    }
  in
  let eff : Wire_runtime.efficiency_month =
    {
      month = "2026-11";
      window_kind = Some Wire_runtime.Efficiency_month_mtd;
      generated_at_unix = now_unix;
      days_covered = 22;
      keepers =
        [
          mk_eff "mid-2" 1.0;
          mk_eff "high-1" 10.0;
          mk_eff "low-1" 5.0;
          mk_eff "mid-1" 8.0;
          mk_eff "high-2" 2.0;
        ];
      fleet =
        {
          turns_total = 50;
          calls_per_turn = 2.0;
          tool_s_per_turn = 0.5;
          output_tokens_per_turn = 40.0;
          input_tokens_per_turn = 1000.0;
          cost_usd_per_turn = 0.52;
          fleet_cache_hit_pct = Observed.value ~observed_at:now_mono 80.0;
        };
      velocity = [];
    }
  in
  let fleet = Fleet_store.apply_keepers ~observed_at:now_mono ks m0.fleet in
  let rt0 =
    m0.runtime
    |> Runtime_store.sync_keeper_companies ks
    |> Runtime_store.set_tab Nav.Runtime_efficiency_spend
    |> Runtime_store.apply_efficiency ~observed_at:now_mono eff
  in
  let rec collect_rt_ys rt steps acc =
    let g =
      render_into ~cols:140 ~rows:44 (fun ~cache ~rect gr ->
          Screen_runtime.render ~model:{ m0 with fleet; runtime = rt }
            ~cache ~rect gr)
    in
    let y =
      match find_left_rail_row ~x_max:10 g with
      | Some y -> y
      | None -> Alcotest.fail "Expected Left_rail selection on Runtime Efficiency"
    in
    if steps = 0 then List.rev (y :: acc)
    else
      collect_rt_ys
        (Runtime_store.move_selection ~viewport_rows:20 ~delta:1 rt)
        (steps - 1) (y :: acc)
  in
  let rt_ys = collect_rt_ys rt0 4 [] in
  assert_strictly_increasing ~label:"Runtime Efficiency ▎ row y" rt_ys;

  (* Knowledge Wiki clusters monotonic ▎ row y *)
  let mk_wiki slug tags : Wire_knowledge.wiki_page_summary =
    {
      slug;
      file = slug ^ ".md";
      title = "Page " ^ slug;
      summary = "Summary";
      source = Wire_knowledge.Source_research;
      author = "high-1";
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
  let kw0 =
    Knowledge_store.empty
    |> Knowledge_store.set_tab Nav.Knowledge_wiki_artifacts
    |> Knowledge_store.apply_wiki_index ~observed_at:now_mono
         {
           pages_total = 4;
           pages_readable = 4;
           pages_unreadable = 0;
           pages =
             [
               mk_wiki "untagged-1" [];
               mk_wiki "ops-1" [ "ops" ];
               mk_wiki "arch-1" [ "arch" ];
               mk_wiki "ops-2" [ "ops" ];
             ];
           unreadable_pages = [];
           lint = empty_lint;
         }
  in
  let rec collect_wiki_ys kw steps acc =
    let g =
      render_into ~cols:140 ~rows:44 (fun ~cache ~rect gr ->
          Screen_knowledge.render ~model:{ m0 with knowledge = kw } ~cache ~rect
            gr)
    in
    let y =
      match find_left_rail_row ~y_min:3 ~x_max:10 g with
      | Some y -> y
      | None -> Alcotest.fail "Expected Left_rail selection on Knowledge Wiki"
    in
    if steps = 0 then List.rev (y :: acc)
    else
      collect_wiki_ys
        (Knowledge_store.move_selection ~viewport_rows:20 ~delta:1 kw)
        (steps - 1) (y :: acc)
  in
  let wiki_ys = collect_wiki_ys kw0 3 [] in
  assert_strictly_increasing ~label:"Knowledge Wiki ▎ row y" wiki_ys

let () =
  Alcotest.run "masc_tui_screens_domain"
    [
      ( "knowledge"
      , [
          Alcotest.test_case "3 sub-tabs + 4 dives at 140x40 & 90x28 (KO/EN)"
            `Quick test_knowledge_all_tabs_and_dives;
        ] );
      ( "runtime"
      , [
          Alcotest.test_case
            "4 sub-tabs, Observed cost states, full-width charts & SSOT isolation"
            `Quick test_runtime_all_tabs_and_invariants;
        ] );
      ( "infra"
      , [
          Alcotest.test_case
            "3 sub-tabs + 3 dives (structured & [J] Json_tree) at 140x40 & 90x28"
            `Quick test_infra_all_tabs_and_dives;
        ] );
      ( "observed_states"
      , [
          Alcotest.test_case "empty/loading/failed Observed resilience" `Quick
            test_empty_loading_and_failed_observed_states;
        ] );
      ( "verifier_regressions"
      , [
          Alcotest.test_case
            "P1-1..P1-7 & P2-1..P2-3 data integrity, redaction, filter/slug sync, scrolling"
            `Quick test_p1_p2_verifier_regressions;
        ] );
      ( "v25_renewal"
      , [
          Alcotest.test_case
            "Runtime Efficiency full-width Braille charts, peak>=current & tool_series fallback"
            `Quick test_v25_runtime_efficiency_real_charts;
          Alcotest.test_case
            "Runtime Quotas human aliases, collapsed ▸ unreported footer & cooldown card"
            `Quick test_v25_runtime_quotas_aliases_and_collapsed_unreported;
          Alcotest.test_case
            "Infra Sandboxes canonical 8-col SSH/VM mapping & 4-section inspector"
            `Quick test_v25_infra_sandboxes_8col_mapping_and_inspector;
          Alcotest.test_case
            "Knowledge Memory Stacked_bar, Violet/Amber ▎ conflict rails & Wiki TOC rail"
            `Quick test_v25_knowledge_stacked_bar_and_conflict_rails;
        ] );
      ( "p0_p1_data_truth"
      , [
          Alcotest.test_case
            "P1-7 Fleet_store.fleet_health_counts SSOT & offline vs failing separation"
            `Quick test_p1_7_fleet_health_counts_ssot;
          Alcotest.test_case
            "P1-5 Infra 404 fallback Shim_undeclared neutral badge, 0/19 running & [Space]"
            `Quick test_p1_5_infra_sandboxes_404_fallback_honesty;
          Alcotest.test_case
            "P0-1/P0-2 Spend 24h provenance, MTD badge, active/retired split & Dual USD axis"
            `Quick test_p0_1_p0_2_runtime_spend_provenance_mtd_and_dual_usd;
          Alcotest.test_case
            "P1-9/P1-10 Max-window saturated sub, reconciled buckets, overflow & human cooldowns"
            `Quick test_p1_9_p1_10_quotas_max_window_buckets_and_human_cooldowns;
          Alcotest.test_case
            "Nav display-order monotonic Left_rail row progression (Runtime Efficiency & Wiki)"
            `Quick test_nav_display_order_monotonic_screen_rows;
        ] );
    ]
