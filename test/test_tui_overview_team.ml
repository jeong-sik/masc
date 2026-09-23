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
  ; keeper ~ago:(Some 50460.) "sangsu" Types.Keeper_phase_absent
  ; keeper "rondo" (phase "paused")
  ]

let tasks =
  [ task "task-1519" (in_progress "glossary-maniac")
  ; task "task-1520" (in_progress "glossary-maniac")
  ; task "task-1600" (awaiting "glossary-maniac")
  ; task "task-1700" (in_progress "sangsu")
  ; task "task-1701" (in_progress "sangsu")
  ; task "task-1702" (in_progress "sangsu")
  ; task "task-1800" (in_progress "codex-mcp-client")
  ; task "task-1801" (in_progress "codex-mcp-client")
  ; task "task-1900" (awaiting "analyst")
  ; task "task-1950" (in_progress "rondo")
  ; task "task-2000" Masc_domain.Todo
  ]

let attention =
  [ keeper_item "tui-developer"
      "tui-developer: runtime_blocked (Keeper turn failed 2 consecutive cycle(s))"
  ; keeper_item "sangsu" "sangsu: keepalive_stopped"
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
    [ "sangsu"; "tui-developer"; "glossary-maniac"; "won-chik" ]
    (names team.rows);
  check (list (pair string int))
    "paused Keepers roll into one parked line, with the work they still hold"
    [ ("lane-smith", 0); ("rondo", 1) ] team.parked;
  check int "need you" 2 (Team.count team Team.Needs_you);
  check int "working" 1 (Team.count team Team.Working);
  check int "idle" 1 (Team.count team Team.Idle);
  check int "parked" 2 (Team.count team Team.Parked)

let detail_of name =
  (List.find (fun (row : Team.row) -> String.equal row.keeper.okp_name name) team.rows)
    .detail

let test_a_stuck_row_carries_the_attention_sentence_and_held_work () =
  (match detail_of "tui-developer" with
   | Team.Blocker { summary; held } ->
       check string "the item naming this Keeper, verbatim"
         "tui-developer: runtime_blocked (Keeper turn failed 2 consecutive cycle(s))"
         summary;
       check int "holds nothing" 0 held
   | Team.Phase_word _ | Team.Working_on _ | Team.No_open_task _ ->
       fail "a failing Keeper named by an attention item carries its sentence");
  match detail_of "sangsu" with
  | Team.Blocker { summary; held } ->
      check string "no registry phase, but named by attention"
        "sangsu: keepalive_stopped" summary;
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
  check int "drawn rows: four Keepers, parked line, holders line" 6
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

(* A paused Keeper is left out of autoboot, so after a server restart it has
   no registry entry: phase null, paused true, and the status bridge still
   raises a "<name>: paused" item for it. That is the operator's own stop. *)
let test_a_paused_keeper_without_a_phase_stays_parked () =
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
  check (list (pair string int)) "parked, with the task it still holds"
    [ ("lane-smith", 1) ] team.parked

let test_paused_wins_over_a_stuck_phase () =
  let team =
    Team.project
      ~keepers:[ keeper ~paused:(Some true) "x" (phase "failing") ]
      ~tasks:[]
      ~attention:[ keeper_item "x" "x: runtime_blocked" ]
  in
  check (list string) "no row" [] (names team.rows);
  check (list (pair string int)) "parked" [ ("x", 0) ] team.parked

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
      ~keepers:[ keeper "sangsu" Types.Keeper_phase_absent ]
      ~tasks:[]
      ~attention:[ info_item "sangsu" "sangsu has 3 external messages waiting" ]
  in
  check (list string) "an info item alone does not make Needs_you" []
    (names phase_less.rows);
  check (list (pair string int)) "it stays parked" [ ("sangsu", 0) ]
    phase_less.parked;
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
        ; test_case "paused Keeper without a phase stays parked" `Quick
            test_a_paused_keeper_without_a_phase_stays_parked
        ; test_case "paused wins over a stuck phase" `Quick
            test_paused_wins_over_a_stuck_phase
        ; test_case "an info item is not a blocker" `Quick
            test_an_info_item_is_not_a_blocker
        ] )
    ]
