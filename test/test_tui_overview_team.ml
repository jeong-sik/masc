(* The Overview Team block (RFC-0464). The fixture is the fleet the live
   workspace showed on 2026-09-23: a Keeper failing after a boot, one working
   a task, one alive with nothing held, a paused one, one with no registry
   phase whose keepalive stopped while it held three tasks, and an MCP client
   holding work outside the fleet. *)

open Alcotest
module Team = Masc_tui_overview_team
module Types = Masc_tui_types

let keeper ?(ago = Some 60.) name phase : Types.overview_keeper =
  { okp_name = name; okp_phase = phase; okp_last_turn_ago_s = ago }

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
  ; ai_evidence_ts = None
  }

let phase p = Types.Keeper_phase p

let fleet =
  [ keeper "won-chik" (phase Keeper_state_machine.Running)
  ; keeper "tui-developer" (phase Keeper_state_machine.Failing)
  ; keeper "glossary-maniac" (phase Keeper_state_machine.Running)
  ; keeper ~ago:None "lane-smith" (phase Keeper_state_machine.Paused)
  ; keeper ~ago:(Some 50460.) "sangsu" Types.Keeper_phase_absent
  ; keeper "rondo" (phase Keeper_state_machine.Paused)
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
    ; ai_evidence_ts = None
    }
  ]

let team = Team.project ~keepers:fleet ~tasks ~attention

let names rows = List.map (fun (row : Team.row) -> row.keeper.okp_name) rows

let test_bands_order_stuck_then_working_then_idle () =
  check (list string) "stuck Keepers first, by name; then working; then idle"
    [ "sangsu"; "tui-developer"; "glossary-maniac"; "won-chik" ]
    (names team.rows);
  check (list string) "paused Keepers roll into one parked line"
    [ "lane-smith"; "rondo" ] team.parked;
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
      ~keepers:[ keeper "tui-developer" (phase Keeper_state_machine.Failing) ]
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
        ] )
    ]
