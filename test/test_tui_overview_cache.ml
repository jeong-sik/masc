(* Successive Overview frames share snapshots until a loader read replaces
   one input. Check the rows and text the operator gets after those reads,
   keeping every other input physically identical so each invalidation key
   matters independently. *)
open Alcotest
module Cache = Masc_tui_overview_cache
module Team = Masc_tui_overview_team
module Tasks = Masc_tui_overview_tasks
module Types = Masc_tui_types

let keeper name phase : Types.overview_keeper =
  { okp_name = name; okp_phase = phase; okp_last_turn_ago_s = None;
    okp_paused = Some false }

let running =
  match Masc.Tui_decode.keeper_phase_of_string "running" with
  | Some phase -> Types.Keeper_phase phase
  | None -> fail "fixture running phase must decode"

let working assignee =
  Masc_domain.InProgress { assignee; started_at = "2026-09-29T00:00:00Z" }

let row id status : Masc.Tui_decode.task =
  { id; title = "Work " ^ id; status; priority = 2; goal_ids = [] }

let blocker summary : Types.attention_item =
  { ai_kind = "keeper_runtime_blocked"; ai_severity = Types.Attention_bad;
    ai_summary = summary; ai_target = Types.Attention_keeper "alpha";
    ai_blocker_summary = None; ai_evidence_ts = None }

let test_team_task_refresh () =
  let cache = Cache.create () in
  let keepers = [keeper "alpha" running] and attention = [] in
  let before = [row "old" (working "alpha")] in
  let first = Cache.team cache ~keepers ~tasks:before ~attention in
  check bool "cursor-only frame reuses the projection" true
    (first == Cache.team cache ~keepers ~tasks:before ~attention);
  let after = [row "replacement" (working "alpha")] in
  let refreshed = Cache.team cache ~keepers ~tasks:after ~attention in
  (match refreshed.rows with
   | [{ detail = Team.Working_on { task; _ }; _ }] ->
       check string "Team names the newly held task" "replacement" task.id
   | _ -> fail "Team lost the working Keeper");
  let released = Cache.team cache ~keepers ~tasks:[] ~attention in
  check int "released task stops counting as working" 0 (Team.count released Team.Working);
  check int "Keeper is idle after releasing work" 1 (Team.count released Team.Idle)

let test_team_roster_refresh () =
  let cache = Cache.create () in
  let tasks = [row "held" (working "alpha")] and attention = [] in
  ignore (Cache.team cache ~keepers:[keeper "alpha" running] ~tasks ~attention);
  let team = Cache.team cache ~keepers:[keeper "beta" running] ~tasks ~attention in
  check (list string) "replacement roster names beta, not departed alpha"
    ["beta"] (List.map (fun (r : Team.row) -> r.keeper.okp_name) team.rows);
  check (list (pair string int)) "departed Keeper's held work remains visible"
    [("alpha", 1)] team.other_holders

let test_team_attention_refresh () =
  let cache = Cache.create () in
  let keepers = [keeper "alpha" Types.Keeper_phase_absent] and tasks = [] in
  ignore (Cache.team cache ~keepers ~tasks ~attention:[]);
  let describe summary =
    let team = Cache.team cache ~keepers ~tasks ~attention:[blocker summary] in
    match team.rows with
    | [{ detail = Team.Blocker { summary; _ }; _ }] -> summary
    | _ -> fail "fresh attention must explain the stuck Keeper"
  in
  check string "new attention promotes an unknown Keeper to Needs you"
    "Reconnect account" (describe "Reconnect account");
  check string "changed reason replaces the old blocker sentence"
    "Resume paused provider" (describe "Resume paused provider");
  let cleared = Cache.team cache ~keepers ~tasks ~attention:[] in
  check int "cleared blocker is no longer shown" 0 (Team.count cleared Team.Needs_you);
  check int "phase remains unknown after attention clears" 1 (Team.count cleared Team.No_phase)

let task id created_at : Masc_domain.task =
  { id; title = "Work " ^ id; description = ""; task_status = Masc_domain.Todo;
    priority = 3; files = []; created_at; created_by = Some "producer";
    predecessor_task_id = None; contract = None;
    execution_links = Masc_domain.no_execution_links; handoff_context = None;
    cycle_count = 0; reclaim_policy = None; do_not_reclaim_reason = None; skills = [] }

let now =
  match Masc_domain.parse_iso8601_opt "2026-09-29T00:01:00Z" with
  | Some at -> at
  | None -> fail "fixture clock must parse"

let test_backlog_refresh_and_clock () =
  let cache = Cache.create () in
  let old = task "old" "2026-09-29T00:00:00Z" in
  let newer = task "newer" "2026-09-29T00:00:30Z" in
  let tasks = [old; newer] in
  let first = Cache.backlog cache tasks in
  let text ~now backlog =
    Tasks.summary_text ~age_text:(fun s -> string_of_int s ^ "s") ~now
      (Tasks.Todo_backlog backlog)
  in
  check (option string) "first frame's Todo count and oldest age"
    (Some "2 todo · oldest 60s") (text ~now first);
  let repeated = Cache.backlog cache tasks in
  check bool "unchanged backlog reuses its parsed creation times" true (first == repeated);
  check (option string) "age advances without a new loader snapshot"
    (Some "2 todo · oldest 120s") (text ~now:(now +. 60.) repeated);
  let changed = [{ old with task_status = working "alpha" }; newer] in
  check (option string) "claiming oldest task updates count and oldest Todo"
    (Some "1 todo · oldest 30s") (text ~now (Cache.backlog cache changed));
  check int "empty replacement drops the previous backlog" 0
    (Cache.backlog cache []).todo_count

let () =
  run "tui_overview_cache"
    [ "snapshot lifecycle",
      [ test_case "Team task refresh and reuse" `Quick test_team_task_refresh;
        test_case "Team roster replacement" `Quick test_team_roster_refresh;
        test_case "Team attention arrival, change and removal" `Quick test_team_attention_refresh;
        test_case "backlog refresh and age on unchanged inputs" `Quick test_backlog_refresh_and_clock ] ]
