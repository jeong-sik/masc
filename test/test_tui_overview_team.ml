(* The Overview Team block (RFC-0464). The fixture is the fleet the live
   workspace showed on 2026-09-23: a Keeper failing after a boot, one working
   a task, one alive with nothing held, a paused one, one with no registry
   phase whose keepalive stopped while it held three tasks, and an MCP client
   holding work outside the fleet. *)

open Alcotest
module Team = Masc_tui_overview_team
module Types = Masc_tui_types
module Tui_decode = Masc.Tui_decode

let keeper ?(ago = Some 60.) ?(paused = Some false) name phase :
    Types.overview_keeper =
  { okp_name = name; okp_phase = phase; okp_last_turn_ago_s = ago; okp_paused = paused }

let task id assignee_status : Tui_decode.task =
  { id; title = "title of " ^ id; status = assignee_status; priority = 2; goal_ids = [] }

let in_progress assignee =
  Masc_domain.InProgress { assignee; started_at = "2026-09-23T00:00:00Z" }

let awaiting assignee =
  Masc_domain.AwaitingVerification
    { assignee
    ; started_at = "2026-09-23T00:00:00Z"
    ; submitted_at = "2026-09-23T00:10:00Z"
    ; intent = Masc_domain.Complete_task
    ; verification_id = "v-1"
    }

let keeper_item name summary : Types.attention_item =
  { ai_kind = "keeper_runtime_blocked"
  ; ai_severity = Types.Attention_bad
  ; ai_summary = summary
  ; ai_target = Types.Attention_keeper name
  ; ai_blocker_summary = None
  ; ai_evidence_ts = None
  }

let phase word =
  match Tui_decode.keeper_phase_of_string word with
  | Some p -> Types.Keeper_phase p
  | None -> Alcotest.failf "fixture phase %S is not a Keeper phase" word

let fleet =
  [ keeper "won-chik" (phase "running")
  ; keeper "tui-developer" (phase "failing")
  ; keeper "glossary-maniac" (phase "running")
  ; keeper ~ago:None "lane-smith" (phase "paused")
  ; keeper ~ago:(Some 50460.) "stuck-fixture-keeper" Types.Keeper_phase_absent
  ; keeper "parked-fixture-keeper" (phase "paused")
  ]

let tasks =
  [ task "task-1519" (in_progress "glossary-maniac")
  ; task "task-1520" (in_progress "glossary-maniac")
  ; task "task-1600" (awaiting "glossary-maniac")
  ; task "task-1700" (in_progress "stuck-fixture-keeper")
  ; task "task-1701" (in_progress "stuck-fixture-keeper")
  ; task "task-1702" (in_progress "stuck-fixture-keeper")
  ; task "task-1800" (in_progress "codex-mcp-client")
  ; task "task-1801" (in_progress "codex-mcp-client")
  ; task "task-1900" (awaiting "analyst")
  ; task "task-1950" (in_progress "parked-fixture-keeper")
  ; task "task-2000" Masc_domain.Todo
  ]

let attention =
  [ keeper_item "tui-developer"
      "tui-developer: runtime_blocked (Keeper turn failed 2 consecutive cycle(s))"
  ; keeper_item "stuck-fixture-keeper" "stuck-fixture-keeper: keepalive_stopped"
  ; { (keeper_item "lane-smith" "lane-smith: paused") with
      ai_severity = Types.Attention_warning
    }
  ; { ai_kind = "board_attention"
    ; ai_severity = Types.Attention_info
    ; ai_summary = "a board item"
    ; ai_target = Types.Attention_other { target_type = "board"; target_id = Some "tui-developer" }
    ; ai_blocker_summary = None
    ; ai_evidence_ts = None
    }
  ]

let team = Team.project ~keepers:fleet ~tasks ~attention

let names rows = List.map (fun (row : Team.row) -> row.keeper.okp_name) rows

let test_bands_order_stuck_then_working_then_idle () =
  check (list string) "stuck Keepers first, by name; then working; then idle"
    [ "stuck-fixture-keeper"; "tui-developer"; "glossary-maniac"; "won-chik" ]
    (names team.rows);
  check (list (pair string int))
    "paused Keepers roll into one paused line, with the work they still hold"
    [ ("lane-smith", 0); ("parked-fixture-keeper", 1) ] team.paused;
  check (list (pair string int)) "no Keeper is stopped" [] team.stopped;
  check (list (pair string int)) "every Keeper has a phase" [] team.no_phase;
  check int "need you" 2 (Team.count team Team.Needs_you);
  check int "working" 1 (Team.count team Team.Working);
  check int "idle" 1 (Team.count team Team.Idle);
  check int "paused" 2 (Team.count team Team.Paused);
  check int "stopped" 0 (Team.count team Team.Stopped)

let detail_of name =
  (List.find (fun (row : Team.row) -> String.equal row.keeper.okp_name name) team.rows)
    .detail

let test_a_stuck_row_carries_the_attention_sentence_and_held_work () =
  (match detail_of "tui-developer" with
   | Team.Blocker { summary; held; _ } ->
       check string "the item naming this Keeper, verbatim"
         "tui-developer: runtime_blocked (Keeper turn failed 2 consecutive cycle(s))"
         summary;
       check int "holds nothing" 0 held
   | Team.Phase_word _ | Team.Working_on _ | Team.No_open_task _ ->
       fail "a failing Keeper named by an attention item carries its sentence");
  match detail_of "stuck-fixture-keeper" with
  | Team.Blocker { summary; held; _ } ->
      check string "no registry phase, but named by attention"
        "stuck-fixture-keeper: keepalive_stopped" summary;
      check int "the three tasks it stopped holding are said" 3 held
  | Team.Phase_word _ | Team.Working_on _ | Team.No_open_task _ ->
      fail "a phase-less Keeper that attention names needs the operator"

let test_a_working_row_names_its_first_task () =
  match detail_of "glossary-maniac" with
  | Team.Working_on { task; more; awaiting } ->
      check string "first held task in backlog order" "task-1519" task.id;
      check int "one more in progress" 1 more;
      check int "one waiting on a verifier" 1 awaiting
  | Team.Blocker _ | Team.Phase_word _ | Team.No_open_task _ ->
      fail "a running Keeper holding tasks is working"

(* An item about something else that happens to carry a Keeper's name as its
   id is not about that Keeper; the join is on the typed target. *)
let test_only_keeper_targets_join () =
  let only_board =
    Team.project
      ~keepers:[ keeper "tui-developer" (phase "failing") ]
      ~tasks:[]
      ~attention:[ List.nth attention 3 ]
  in
  match only_board.rows with
  | [ { detail = Team.Phase_word { word; held = 0 }; _ } ] ->
      check string "falls back to the Keeper's own phase" "failing" word
  | _ -> fail "a board item must not explain a Keeper's failure"

let test_work_held_outside_the_fleet_is_counted () =
  check (list (pair string int)) "non-Keeper holders, most first"
    [ ("codex-mcp-client", 2); ("analyst", 1) ]
    team.other_holders;
  check int "drawn rows: four Keepers, paused line, holders line" 6
    (Team.drawn_rows team)

let test_an_unreadable_phase_stays_visible () =
  let odd =
    Team.project
      ~keepers:[ keeper "x" (Types.Keeper_phase_unreadable "hibernating") ]
      ~tasks:[] ~attention:[]
  in
  match odd.rows with
  | [ { group = Team.Needs_you; detail = Team.Phase_word { word; _ }; _ } ] ->
      check string "the wire word as it came" "hibernating" word
  | _ -> fail "a phase this build cannot name is shown, not folded away"

(* The live catalogue on 2026-09-23 carried the Claude Code subscription's
   shut window on each of its runtimes, all with one reopening time; the
   Codex subscription's window was open. The Team block names the window
   once, with how many runtimes stand behind it. *)
let runtime ?resets ?scope ~exhausted id : Tui_decode.runtime_option =
  { ro_id = id
  ; ro_provider = "p"
  ; ro_model = id
  ; ro_effective_max_context = 200_000
  ; ro_max_context_source = Tui_decode.Runtime_context_capability
  ; ro_max_output_tokens = None
  ; ro_declared_reasoning_effort = None
  ; ro_is_local = false
  ; ro_is_default = false
  ; ro_quota_exhausted = exhausted
  ; ro_quota_resets_at = resets
  ; ro_quota_scope = scope
  }

let test_shut_windows_name_each_window_once () =
  let claude = Some "provider:claude_code" in
  let windows =
    Team.shut_windows
      [ runtime ~exhausted:true ~scope:"provider:claude_code" ~resets:1790140800.
          "claude_code.claude-sonnet-5"
      ; runtime ~exhausted:true ~scope:"provider:claude_code" ~resets:1790140800.
          "claude_code.claude-opus-5-medium"
      ; runtime ~exhausted:false ~scope:"provider:codex_subscription"
          "codex_subscription.gpt-5.6-luna"
      ; runtime ~exhausted:true ~scope:"provider:glm_coding" "glm-coding.glm-5.3-flash"
      ; runtime ~exhausted:true ~scope:"provider:kimi" ~resets:1790130000.
          "kimi.k3"
      ]
  in
  check
    (list (option string))
    "soonest reopening first, unreported time last; open windows absent"
    [ Some "provider:kimi"; claude; Some "provider:glm_coding" ]
    (List.map (fun (w : Team.shut_window) -> w.sw_scope) windows);
  check (list int) "runtimes behind each window" [ 1; 2; 1 ]
    (List.map (fun (w : Team.shut_window) -> w.sw_runtimes) windows);
  check int "every window open reports none" 0
    (List.length
       (Team.shut_windows
          [ runtime ~exhausted:false ~scope:"provider:claude_code" "a" ]))

(* The live item wraps the cause in the Keeper name and class word; on a
   75-cell row the cause fell off the end. The blocker sentence is carried
   on its own and is what the row shows. *)
let test_a_stuck_row_prefers_the_blocker_sentence () =
  let item =
    { (keeper_item "goo-yang-bong"
         "goo-yang-bong: runtime_blocked (Keeper turn failed 4 consecutive cycle(s))")
      with
      ai_blocker_summary = Some "Keeper turn failed 4 consecutive cycle(s)"
    }
  in
  let team =
    Team.project
      ~keepers:[ keeper "goo-yang-bong" (phase "failing") ]
      ~tasks:[] ~attention:[ item ]
  in
  match team.rows with
  | [ { detail = Team.Blocker { summary; _ }; _ } ] ->
      check string "the cause alone" "Keeper turn failed 4 consecutive cycle(s)"
        summary
  | _ -> fail "a failing Keeper named by an item is a Blocker row"

(* The Attention panel beside the Team block (#38148). An item leaves the
   panel only when a drawn Team row prints it; everything else stays. *)
module Panel = struct
  let a1 = keeper_item "stuck-a" "stuck-a: runtime_blocked"
  let a2 = keeper_item "stuck-a" "stuck-a: trust_needs_attention"
  let b1 = keeper_item "run-b" "run-b: runtime_blocked"
  let c1 = keeper_item "stuck-c" "stuck-c: keepalive_stopped"

  let o1 =
    { (keeper_item "x" "a board item") with
      ai_target = Types.Attention_other { target_type = "board"; target_id = None }
    }

  let attention = [ a1; a2; b1; c1; o1 ]

  let team =
    Team.project
      ~keepers:
        [ keeper "stuck-a" (phase "failing")
        ; keeper "run-b" (phase "running")
        ; keeper "stuck-c" (phase "crashed")
        ]
      ~tasks:[] ~attention

  let summaries items =
    List.map (fun (item : Types.attention_item) -> item.ai_summary) items

  let panel ~rows =
    fst (Team.settle team ~attention ~allocate:(fun _ -> rows) ~team_rows:Fun.id)
end

let test_a_running_keepers_item_stays_in_the_panel () =
  check bool "run-b's item is drawn in the panel" true
    (List.memq Panel.b1 (Panel.panel ~rows:10))

let test_a_second_item_about_a_stuck_keeper_stays_in_the_panel () =
  check (list string) "the row draws one item; the other stays"
    (Panel.summaries [ Panel.a2; Panel.b1; Panel.o1 ])
    (Panel.summaries (Panel.panel ~rows:10))

let test_items_of_cut_rows_stay_in_the_panel () =
  check (list string) "one row drawn: only stuck-a's item moved"
    (Panel.summaries [ Panel.a2; Panel.b1; Panel.c1; Panel.o1 ])
    (Panel.summaries (Panel.panel ~rows:1));
  check (list string) "no Team row drawn: the panel keeps everything"
    (Panel.summaries Panel.attention)
    (Panel.summaries (Panel.panel ~rows:0))

(* Handing items to the Team block frees panel rows, which can let the block
   draw more rows, whose items move too. The result must be the fixed point,
   and every moved item must sit on a row the final budget draws. *)
let test_settle_reaches_the_rows_the_final_budget_draws () =
  let allocate panel = if List.length panel >= 5 then 1 else 2 in
  let panel, rows =
    Team.settle Panel.team ~attention:Panel.attention ~allocate ~team_rows:Fun.id
  in
  check int "two rows drawn" 2 rows;
  check (list string) "both stuck rows' items moved, nothing else"
    (Panel.summaries [ Panel.a2; Panel.b1; Panel.o1 ])
    (Panel.summaries panel);
  check int "the budget is the one the panel was allocated with" rows
    (allocate panel)

(* A paused Keeper is left out of autoboot, so after a server restart it has
   no registry entry: phase null, paused true, and the status bridge still
   raises a "<name>: paused" item for it. That is the operator's own stop. *)
let test_a_paused_keeper_without_a_phase_stays_paused () =
  let team =
    Team.project
      ~keepers:
        [ keeper ~ago:None ~paused:(Some true) "lane-smith"
            Types.Keeper_phase_absent
        ]
      ~tasks:[ task "task-1" (in_progress "lane-smith") ]
      ~attention:
        [ { (keeper_item "lane-smith" "lane-smith: paused") with
            ai_severity = Types.Attention_warning
          }
        ]
  in
  check (list string) "no Needs_you row" [] (names team.rows);
  check (list (pair string int)) "paused, with the task it still holds"
    [ ("lane-smith", 1) ] team.paused

let test_paused_wins_over_a_stuck_phase () =
  let team =
    Team.project
      ~keepers:[ keeper ~paused:(Some true) "x" (phase "failing") ]
      ~tasks:[]
      ~attention:[ keeper_item "x" "x: runtime_blocked" ]
  in
  check (list string) "no row" [] (names team.rows);
  check (list (pair string int)) "paused" [ ("x", 0) ] team.paused

let info_item name summary : Types.attention_item =
  { (keeper_item name summary) with
    ai_kind = "connector_backlog"
  ; ai_severity = Types.Attention_info
  }

(* The connector's "N external messages waiting" names a Keeper at info
   severity. It is not a stop and not a cause. *)
let test_an_info_item_is_not_a_blocker () =
  let phase_less =
    Team.project
      ~keepers:[ keeper "stuck-fixture-keeper" Types.Keeper_phase_absent ]
      ~tasks:[]
      ~attention:[ info_item "stuck-fixture-keeper" "stuck-fixture-keeper has 3 external messages waiting" ]
  in
  check (list string) "an info item alone does not make Needs_you" []
    (names phase_less.rows);
  check (list (pair string int)) "its place is unknown"
    [ ("stuck-fixture-keeper", 0) ] phase_less.no_phase;
  check (list (pair string int)) "not stopped" [] phase_less.stopped;
  let failing =
    Team.project
      ~keepers:[ keeper "x" (phase "failing") ]
      ~tasks:[]
      ~attention:
        [ info_item "x" "x has 3 external messages waiting"
        ; keeper_item "x" "x: runtime_blocked"
        ]
  in
  match failing.rows with
  | [ { detail = Team.Blocker { summary; _ }; _ } ] ->
      check string "the non-info item explains the row" "x: runtime_blocked"
        summary
  | _ -> fail "a failing Keeper named by a bad item is a Blocker row"

(* A Keeper the operator paused, one that stopped and one with no phase are
   three populations: the Team title counts each on its own line, so
   "paused" never counts a stopped Keeper and "stopped" never counts one the
   briefing said nothing about. *)
let test_paused_stopped_and_no_phase_are_counted_apart () =
  let team =
    Team.project
      ~keepers:
        [ keeper ~paused:(Some true) "by-flag" (phase "running")
        ; keeper "by-phase" (phase "paused")
        ; keeper "halted" (phase "stopped")
        ; keeper "gone" (phase "offline")
        ; keeper "no-entry" Types.Keeper_phase_absent
        ]
      ~tasks:[ task "task-1" (in_progress "halted") ]
      ~attention:[]
  in
  check (list string) "no Keeper row" [] (names team.rows);
  check (list (pair string int)) "the paused line"
    [ ("by-flag", 0); ("by-phase", 0) ] team.paused;
  check (list (pair string int)) "the stopped line, with held work"
    [ ("gone", 0); ("halted", 1) ] team.stopped;
  check (list (pair string int)) "the no-phase line" [ ("no-entry", 0) ]
    team.no_phase;
  check int "paused count" 2 (Team.count team Team.Paused);
  check int "stopped count" 2 (Team.count team Team.Stopped);
  check int "no-phase count" 1 (Team.count team Team.No_phase);
  check int "one row per name line" 3 (Team.drawn_rows team)

let () =
  run "tui_overview_team"
    [ ( "team"
      , [ test_case "bands order stuck, working, idle" `Quick
            test_bands_order_stuck_then_working_then_idle
        ; test_case "stuck row carries attention sentence and held work" `Quick
            test_a_stuck_row_carries_the_attention_sentence_and_held_work
        ; test_case "working row names its first task" `Quick
            test_a_working_row_names_its_first_task
        ; test_case "only keeper targets join" `Quick test_only_keeper_targets_join
        ; test_case "work held outside the fleet is counted" `Quick
            test_work_held_outside_the_fleet_is_counted
        ; test_case "unreadable phase stays visible" `Quick
            test_an_unreadable_phase_stays_visible
        ; test_case "shut windows name each window once" `Quick
            test_shut_windows_name_each_window_once
        ; test_case "stuck row prefers the blocker sentence" `Quick
            test_a_stuck_row_prefers_the_blocker_sentence
        ; test_case "a running Keeper's item stays in the panel" `Quick
            test_a_running_keepers_item_stays_in_the_panel
        ; test_case "a second item about a stuck Keeper stays" `Quick
            test_a_second_item_about_a_stuck_keeper_stays_in_the_panel
        ; test_case "items of cut rows stay in the panel" `Quick
            test_items_of_cut_rows_stay_in_the_panel
        ; test_case "settle reaches the final budget's rows" `Quick
            test_settle_reaches_the_rows_the_final_budget_draws
        ; test_case "paused Keeper without a phase stays paused" `Quick
            test_a_paused_keeper_without_a_phase_stays_paused
        ; test_case "paused wins over a stuck phase" `Quick
            test_paused_wins_over_a_stuck_phase
        ; test_case "paused, stopped and no phase are counted apart" `Quick
            test_paused_stopped_and_no_phase_are_counted_apart
        ; test_case "an info item is not a blocker" `Quick
            test_an_info_item_is_not_a_blocker
        ] )
    ]
