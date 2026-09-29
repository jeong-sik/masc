module Team = Masc_tui_overview_team
module Tasks = Masc_tui_overview_tasks

type t = {
  mutable team_snapshot :
    (Masc_tui_types.overview_keeper list * Masc.Tui_decode.task list
     * Masc_tui_types.attention_item list * Team.t) option;
  mutable backlog_snapshot : (Masc_domain.task list * Tasks.backlog) option;
}

let create () =
  { team_snapshot = None; backlog_snapshot = None }

let team cache ~keepers ~tasks ~attention =
  match cache.team_snapshot with
  | Some (seen_keepers, seen_tasks, seen_attention, team)
    when seen_keepers == keepers && seen_tasks == tasks
         && seen_attention == attention -> team
  | Some _ | None ->
      let team = Team.project ~keepers ~tasks ~attention in
      cache.team_snapshot <- Some (keepers, tasks, attention, team);
      team

let backlog cache tasks =
  match cache.backlog_snapshot with
  | Some (seen, backlog) when seen == tasks -> backlog
  | Some _ | None ->
      let backlog = Tasks.backlog tasks in
      cache.backlog_snapshot <- Some (tasks, backlog);
      backlog
