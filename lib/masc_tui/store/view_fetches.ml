open Masc_tui_core
open Masc_tui_protocol

let needs_fetch ~force obs =
  if force then true
  else
    match obs with
    | Observed.Value { stale = false; _ } -> false
    | Observed.Failed { retryable = false; _ } -> false
    | Observed.Loading _
    | Observed.Value { stale = true; _ }
    | Observed.Absent
    | Observed.Unreported
    | Observed.Failed { retryable = true; _ } ->
        true

let needs_target_fetch ~force ~holds_target obs =
  if force then true
  else
    match obs with
    | Observed.Value { data; stale = false; _ } when holds_target data -> false
    | Observed.Value _
    | Observed.Loading _
    | Observed.Absent
    | Observed.Unreported
    | Observed.Failed _ ->
        true

let add_if cond req acc = if cond then req :: acc else acc

(* Once the ledger route has answered 404, the Candle panels read the
   roster's Candle summary, which each roster reply refreshes. Only an
   explicit refresh asks the route again. *)
let candle_ledger_reqs ~force (m : Model.t) acc =
  add_if
    ((force || not m.work.candle_fallback_404)
    && needs_fetch ~force m.work.candle_ledger)
    (Cmd.Get_candle_ledger { limit = Some 50 })
    acc

(* The keeper-costs window every view asks for: the server's default and
   maximum (Dashboard_http_keeper_feeds.keeper_costs_max_window_minutes), so
   one response serves the Keepers table, the keeper dive and Runtime. *)
let keeper_costs_window_minutes = 1440

let add_keeper_costs ~force (m : Model.t) acc =
  add_if
    (needs_fetch ~force m.runtime.keeper_costs)
    (Cmd.Get_keeper_costs { window_minutes = keeper_costs_window_minutes })
    acc

(* Turns the Ctrl+T Context tab plots, newest last. *)
let context_history_turns = 60

let fetches_for_context_drawer ~force (m : Model.t) =
  match Model.target_keeper m with
  | None -> []
  | Some keeper ->
      let records_needed =
        needs_fetch ~force (Fleet_store.turn_records_for ~keeper m.fleet)
      in
      let internals_needed =
        needs_fetch ~force
          (Knowledge_store.memory_os_internals_for ~keeper m.knowledge)
      in
      []
      |> add_keeper_costs ~force m
      |> add_if records_needed
           (Cmd.Get_keeper_turn_records
              { keeper; limit = context_history_turns })
      |> add_if internals_needed
           (Cmd.Get_keeper_memory_os_internals { keeper })

let dedup_reqs reqs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | req :: rest ->
        let key = Cmd.get_request_path req in
        if List.exists (String.equal key) seen then loop seen acc rest
        else loop (key :: seen) (req :: acc) rest
  in
  loop [] [] reqs

let fetches_for_overlay ~force (m : Model.t) =
  match m.nav.overlay with
  | Some (Nav.Settings _) ->
      let schema_target_mismatch =
        match Observed.to_option m.config.schema with
        | Some s -> not (Config_store.equal_config_target s.target m.config.target)
        | None -> false
      in
      []
      |> add_if (needs_fetch ~force m.config.preferences) Cmd.Get_tui_preferences
      |> add_if
           (schema_target_mismatch || needs_fetch ~force m.config.schema)
           (Cmd.Get_config_schema m.config.target)
  | Some (Nav.Queue_context Nav.Drawer_context) ->
      fetches_for_context_drawer ~force m
  | Some
      ( Nav.Palette
      | Nav.Incidents
      | Nav.Queue_context (Nav.Drawer_queue | Nav.Drawer_schedules)
      | Nav.Inline_action _
      | Nav.Help
      | Nav.System_gate _ )
  | None ->
      []

let keeper_tab_fetches ~force ~name ~tab (m : Model.t) =
  match tab with
  | Nav.Keeper_chat ->
      let hist_needed =
        match Fleet_store.String_map.find_opt name m.fleet.chat_histories with
        | None -> true
        | Some obs -> needs_fetch ~force obs
      in
      []
      |> add_if (needs_fetch ~force m.fleet.turns) Cmd.Get_keeper_turns
      |> add_if hist_needed
           (Cmd.Get_chat_history
              { keeper = name; limit = Some 80; cursor = None })
  | Nav.Keeper_memory ->
      let diff_needed =
        needs_fetch ~force
          (Knowledge_store.memory_diff_for ~keeper:(Some name)
             ~window:m.knowledge.memory_diff_window m.knowledge)
      in
      let internals_needed =
        needs_fetch ~force
          (Knowledge_store.memory_os_internals_for ~keeper:name m.knowledge)
      in
      let facts_needed =
        match m.knowledge.keeper_memory_facts with
        | Observed.Value { data; stale = false; _ } ->
            force || not (String.equal data.keeper name)
        | Observed.Loading _
        | Observed.Value { stale = true; _ }
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ->
            needs_fetch ~force m.knowledge.keeper_memory_facts
      in
      let activity_needed =
        match m.knowledge.keeper_memory_activity with
        | Observed.Value { data; stale = false; _ } ->
            force || not (String.equal data.keeper name)
        | Observed.Loading _
        | Observed.Value { stale = true; _ }
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ->
            needs_fetch ~force m.knowledge.keeper_memory_activity
      in
      let health_needed = needs_fetch ~force m.knowledge.keeper_memory_health in
      []
      |> add_if diff_needed
           (Cmd.Get_memory_diff
              {
                keeper = Some name;
                window = m.knowledge.memory_diff_window;
              })
      |> add_if internals_needed
           (Cmd.Get_keeper_memory_os_internals { keeper = name })
      |> add_if facts_needed (Cmd.Get_keeper_memory_facts { keeper = name })
      |> add_if activity_needed
           (Cmd.Get_keeper_memory_activity { keeper = name; limit = 50 })
      |> add_if health_needed Cmd.Get_keeper_memory_health
  | Nav.Keeper_work_candle ->
      []
      |> add_if (needs_fetch ~force m.work.planning) Cmd.Get_planning
      |> add_if
           (needs_fetch ~force m.work.schedules)
           (Cmd.Get_schedules { cursor = None })
      |> candle_ledger_reqs ~force m
  | Nav.Keeper_sandbox ->
      let sandbox_needed =
        needs_fetch ~force (Infra_store.keeper_sandbox_for ~keeper:name m.infra)
      in
      []
      |> add_if sandbox_needed (Cmd.Get_keeper_sandbox { keeper = name })
  | Nav.Keeper_config ->
      let target = Wire_config.Target_keeper name in
      let schema_needed =
        force
        || not (Config_store.equal_config_target m.config.target target)
        || needs_fetch ~force m.config.schema
      in
      [] |> add_if schema_needed (Cmd.Get_config_schema target)

(* Every keeper tab sits under the dive header, whose KPI strip shows the
   keeper's cost and tokens from keeper-costs. *)
let fetches_for_keeper_tab ~force ~name ~tab (m : Model.t) =
  add_keeper_costs ~force m (keeper_tab_fetches ~force ~name ~tab m)

let fetches_for_dive ~force (m : Model.t) =
  match Model.active_dive m with
  | None -> []
  | Some (Nav.Dive_keeper { name; tab }) ->
      fetches_for_keeper_tab ~force ~name ~tab m
  | Some (Nav.Dive_work _) ->
      []
      |> add_if (needs_fetch ~force m.work.planning) Cmd.Get_planning
      |> add_if
           (needs_fetch ~force m.work.verifications)
           (Cmd.Get_verifications
              { view = m.work.verification_view; limit = 50; offset = 0 })
  | Some (Nav.Dive_knowledge target) -> (
      match target with
      | Nav.Thread_dive post_id ->
          [ Cmd.Get_board_thread { post_id; comment_limit = Some 100 } ]
      | Nav.Wiki_dive slug ->
          [
            Cmd.Get_wiki_page { page = slug };
            Cmd.Get_wiki_log { limit = Some 30; page = Some slug };
          ]
      | Nav.Artifact_dive target ->
          let detail_needed =
            needs_target_fetch ~force
              ~holds_target:
                (fun (d : Wire_knowledge.published_artifact_detail) ->
                  String.equal d.artifact.id target
                  || String.equal d.artifact.sha256 target)
              m.knowledge.active_artifact_detail
          in
          let art_id, rev =
            match Knowledge_store.find_artifact_by_id_or_sha target m.knowledge with
            | Some a -> (a.id, Some a.revision)
            | None -> (target, None)
          in
          []
          |> add_if (needs_fetch ~force m.knowledge.artifacts) Cmd.Get_artifacts
          |> add_if detail_needed (Cmd.Get_artifact_detail { id = art_id; revision = rev })
      | Nav.Memory_diff_dive { keeper; from_rev; to_rev } ->
          [
            Cmd.Get_memory_diff
              {
                keeper;
                window = Knowledge_store.Window_revs { from_rev; to_rev };
              };
          ])
  | Some (Nav.Dive_infra target) -> (
      match target with
      | Nav.Sandbox_dive keeper -> [ Cmd.Get_keeper_sandbox { keeper } ]
      | Nav.Lane_dive _ ->
          []
          |> add_if
               (needs_fetch ~force m.runtime.runtime_resolved)
               Cmd.Get_runtime_resolved
          |> add_if
               (needs_fetch ~force m.runtime.runtime_probe)
               (Cmd.Get_runtime_probe { force = false })
      | Nav.Incident_dive _ -> [])

(* The Wiki tab shows the selected page's body, so it needs that page unless
   the slot already holds it fresh. A dive covers the tab, and a Wiki dive
   keeps its own page in the same slot, so nothing is asked while one is
   open. *)
let selected_wiki_page_reqs ~force (m : Model.t) =
  match (Model.active_dive m, m.knowledge.wiki_artifacts_submode) with
  | Some _, (`Wiki | `Artifacts) | None, `Artifacts -> []
  | None, `Wiki -> (
      match Knowledge_store.selected_wiki_page m.knowledge with
      | None -> []
      | Some p ->
          if
            needs_fetch ~force
              (Knowledge_store.wiki_page_for ~slug:p.slug m.knowledge)
          then [ Cmd.Get_wiki_page { page = p.slug } ]
          else [])

let fetches_for_workspace ~force (m : Model.t) =
  match m.nav.workspace with
  | Nav.Pulse ->
      []
      |> add_if (needs_fetch ~force m.fleet.shell) Cmd.Get_dashboard_shell
      |> add_if (needs_fetch ~force m.fleet.keepers) Cmd.Get_keepers_roster
      |> add_if
           (needs_fetch ~force m.knowledge.board)
           (Cmd.Get_board_feed
              {
                sort_by = m.knowledge.board_sort_by;
                hearth = m.knowledge.board_hearth;
                signal_only = m.knowledge.board_signal_only;
                limit = Some 30;
                offset = None;
              })
      |> add_if
           (needs_fetch ~force m.knowledge.world_memory)
           Cmd.Get_world_memory
      |> add_if
           (needs_fetch ~force m.work.asks)
           (Cmd.Get_asks { keeper = None; include_resolved = false })
      |> add_if (needs_fetch ~force m.work.tool_approvals) Cmd.Get_tool_approvals
      |> add_if (needs_fetch ~force m.work.gate_pending) Cmd.Get_gate_pending
      |> add_if (needs_fetch ~force m.work.planning) Cmd.Get_planning
      |> add_if
           (needs_fetch ~force m.work.verifications)
           (Cmd.Get_verifications { view = `All; limit = 50; offset = 0 })
      |> candle_ledger_reqs ~force m
      |> add_if (needs_fetch ~force m.infra.sandboxes) Cmd.Get_sandboxes
      |> add_if
           (needs_fetch ~force m.runtime.tool_series)
           (Cmd.Get_tool_series { bucket = `Hour; since_hours = 24 })
      |> add_if
           (needs_fetch ~force m.runtime.models_metrics)
           (Cmd.Get_models_metrics
                  {
                    window_minutes = Wire_runtime.models_chart_window_minutes;
                    bucket_minutes = Wire_runtime.models_chart_bucket_minutes;
                  })
      |> add_if
           (needs_fetch ~force m.runtime.runtime_metrics)
           Cmd.Get_runtime_metrics
      |> add_keeper_costs ~force m
      |> add_if
           (needs_fetch ~force m.runtime.efficiency)
           (Cmd.Get_efficiency { month = None })
      |> add_if
           (needs_fetch ~force m.runtime.runtime_resolved)
           Cmd.Get_runtime_resolved
  | Nav.Work -> (
      match m.work.active_tab with
      | Nav.Work_pipeline ->
          []
          |> add_if (needs_fetch ~force m.work.planning) Cmd.Get_planning
          |> add_if
               (needs_fetch ~force m.work.verifications)
               (Cmd.Get_verifications
                  { view = m.work.verification_view; limit = 50; offset = 0 })
      | Nav.Work_tasks_schedules ->
          []
          |> add_if (needs_fetch ~force m.work.planning) Cmd.Get_planning
          |> add_if
               (needs_fetch ~force m.work.schedules)
               (Cmd.Get_schedules { cursor = None })
      | Nav.Work_inbox ->
          []
          |> add_if
               (needs_fetch ~force m.work.asks)
               (Cmd.Get_asks { keeper = None; include_resolved = false })
          |> add_if
               (needs_fetch ~force m.work.tool_approvals)
               Cmd.Get_tool_approvals
          |> add_if
               (needs_fetch ~force m.work.gate_pending)
               Cmd.Get_gate_pending
      | Nav.Work_candle_scorecard ->
          []
          |> candle_ledger_reqs ~force m
          |> add_if (needs_fetch ~force m.fleet.shell) Cmd.Get_dashboard_shell)
  | Nav.Knowledge -> (
      match m.knowledge.active_tab with
      | Nav.Knowledge_board ->
          []
          |> add_if
               (needs_fetch ~force m.knowledge.board)
               (Cmd.Get_board_feed
                  {
                    sort_by = m.knowledge.board_sort_by;
                    hearth = m.knowledge.board_hearth;
                    signal_only = m.knowledge.board_signal_only;
                    limit = Some 50;
                    offset = None;
                  })
      | Nav.Knowledge_wiki_artifacts ->
          let selected_artifact_req =
            match (Model.active_dive m, m.knowledge.wiki_artifacts_submode) with
            | Some _, (`Wiki | `Artifacts) | None, `Wiki -> []
            | None, `Artifacts -> (
                match Knowledge_store.selected_artifact m.knowledge with
                | None -> []
                | Some a ->
                    if
                      needs_target_fetch ~force
                        ~holds_target:
                          (fun (d : Wire_knowledge.published_artifact_detail) ->
                            String.equal d.artifact.id a.id
                            || String.equal d.artifact.sha256 a.sha256)
                        m.knowledge.active_artifact_detail
                    then
                      [
                        Cmd.Get_artifact_detail
                          { id = a.id; revision = Some a.revision };
                      ]
                    else [])
          in
          ([]
          |> add_if
               (needs_fetch ~force m.knowledge.wiki_index)
               (Cmd.Get_wiki_index { tag = None; source = None; sort = None })
          |> add_if (needs_fetch ~force m.knowledge.wiki_lint) Cmd.Get_wiki_lint
          |> add_if (needs_fetch ~force m.knowledge.artifacts) Cmd.Get_artifacts)
          @ selected_wiki_page_reqs ~force m
          @ selected_artifact_req
      | Nav.Knowledge_memory ->
          let keeper_scoped_reqs =
            match m.knowledge.memory_diff_keeper with
            | None -> []
            | Some keeper ->
                let internals_needed =
                  needs_fetch ~force
                    (Knowledge_store.memory_os_internals_for ~keeper m.knowledge)
                in
                let facts_needed =
                  match m.knowledge.keeper_memory_facts with
                  | Observed.Value { data; stale = false; _ } ->
                      force || not (String.equal data.keeper keeper)
                  | Observed.Loading _
                  | Observed.Value { stale = true; _ }
                  | Observed.Absent
                  | Observed.Unreported
                  | Observed.Failed _ ->
                      needs_fetch ~force m.knowledge.keeper_memory_facts
                in
                let activity_needed =
                  match m.knowledge.keeper_memory_activity with
                  | Observed.Value { data; stale = false; _ } ->
                      force || not (String.equal data.keeper keeper)
                  | Observed.Loading _
                  | Observed.Value { stale = true; _ }
                  | Observed.Absent
                  | Observed.Unreported
                  | Observed.Failed _ ->
                      needs_fetch ~force m.knowledge.keeper_memory_activity
                in
                []
                |> add_if internals_needed
                     (Cmd.Get_keeper_memory_os_internals { keeper })
                |> add_if facts_needed
                     (Cmd.Get_keeper_memory_facts { keeper })
                |> add_if activity_needed
                     (Cmd.Get_keeper_memory_activity { keeper; limit = 50 })
          in
          let diff_needed =
            needs_fetch ~force (Knowledge_store.current_memory_diff m.knowledge)
          in
          ([]
          |> add_if
               (needs_fetch ~force m.knowledge.world_memory)
               Cmd.Get_world_memory
          |> add_if
               (needs_fetch ~force m.knowledge.keeper_memory_health)
               Cmd.Get_keeper_memory_health
          |> add_if diff_needed
               (Cmd.Get_memory_diff
                  {
                    keeper = m.knowledge.memory_diff_keeper;
                    window = m.knowledge.memory_diff_window;
                  }))
          @ keeper_scoped_reqs)
  | Nav.Keepers ->
      let embedded_dive_reqs =
        match Fleet_store.selected_keeper_summary m.fleet with
        | Some k ->
            fetches_for_keeper_tab ~force ~name:k.name
              ~tab:m.fleet.keeper_dive_tab m
        | None -> []
      in
      ([]
      |> add_if (needs_fetch ~force m.fleet.keepers) Cmd.Get_keepers_roster
      |> add_if (needs_fetch ~force m.fleet.turns) Cmd.Get_keeper_turns
      |> add_if (needs_fetch ~force m.infra.sandboxes) Cmd.Get_sandboxes
      |> add_keeper_costs ~force m
      (* The list's next-due column reads the active schedules. *)
      |> add_if
           (needs_fetch ~force m.work.schedules)
           (Cmd.Get_schedules { cursor = None }))
      @ embedded_dive_reqs
  | Nav.Runtime -> (
      match m.runtime.active_tab with
      | Nav.Runtime_quotas_credits ->
          []
          |> add_if
               (needs_fetch ~force m.runtime.runtime_resolved)
               Cmd.Get_runtime_resolved
          |> add_if
               (needs_fetch ~force m.runtime.runtime_config_raw)
               Cmd.Get_runtime_config_raw
          |> add_if
               (needs_fetch ~force m.runtime.setup_inventory)
               Cmd.Get_setup_inventory
          |> add_if
               (needs_fetch ~force m.runtime.usage_history)
               (Cmd.Get_provider_usage { days = 7 })
          |> add_if
               (needs_fetch ~force m.runtime.runtime_probe)
               (Cmd.Get_runtime_probe { force = false })
          |> add_keeper_costs ~force m
      | Nav.Runtime_efficiency_spend ->
          []
          |> add_if
               (needs_fetch ~force m.runtime.models_metrics)
               (Cmd.Get_models_metrics
                  {
                    window_minutes = Wire_runtime.models_chart_window_minutes;
                    bucket_minutes = Wire_runtime.models_chart_bucket_minutes;
                  })
          |> add_if
               (needs_fetch ~force m.runtime.runtime_metrics)
               Cmd.Get_runtime_metrics
          |> add_if
               (needs_fetch ~force m.runtime.tool_series)
               (Cmd.Get_tool_series { bucket = `Hour; since_hours = 24 })
          |> add_if
               (needs_fetch ~force m.runtime.efficiency)
               (Cmd.Get_efficiency { month = None })
          |> add_keeper_costs ~force m
      | Nav.Runtime_failover_lanes ->
          []
          |> add_if
               (needs_fetch ~force m.runtime.runtime_resolved)
               Cmd.Get_runtime_resolved
          |> add_if
               (needs_fetch ~force m.runtime.runtime_config_raw)
               Cmd.Get_runtime_config_raw
          |> add_if
               (needs_fetch ~force m.runtime.setup_inventory)
               Cmd.Get_setup_inventory
          |> add_if
               (needs_fetch ~force m.runtime.runtime_probe)
               (Cmd.Get_runtime_probe { force = false })
          |> add_if
               (needs_fetch ~force m.runtime.exact_lane_runs)
               (Cmd.Get_exact_lane_runs { lane = None; limit = Some 30 })
          |> add_if
               (needs_fetch ~force m.runtime.fusion_runs)
               Cmd.Get_fusion_runs
      | Nav.Runtime_tools_connectors ->
          []
          |> add_if
               (needs_fetch ~force m.runtime.tool_series)
               (Cmd.Get_tool_series { bucket = `Hour; since_hours = 24 })
          |> add_if
               (needs_fetch ~force m.runtime.tools_catalog)
               (Cmd.Get_tools_catalog { keeper = None })
          |> add_if
               (needs_fetch ~force m.runtime.connectors)
               Cmd.Get_connectors
          |> add_if
               (needs_fetch ~force m.runtime.browser_lane)
               Cmd.Get_browser_lane
          |> add_if
               (needs_fetch ~force m.runtime.lane_addons)
               Cmd.Get_lane_addons
          |> add_if
               (needs_fetch ~force m.runtime.mcp_clients)
               Cmd.Get_mcp_clients
      | Nav.Runtime_addons_browser ->
          []
          |> add_if
               (needs_fetch ~force m.runtime.lane_addons)
               Cmd.Get_lane_addons
          |> add_if
               (needs_fetch ~force m.runtime.browser_lane)
               Cmd.Get_browser_lane)
  | Nav.Infra -> (
      match m.infra.active_tab with
      | Nav.Infra_sandboxes ->
          [] |> add_if (needs_fetch ~force m.infra.sandboxes) Cmd.Get_sandboxes
      | Nav.Infra_repos_changes -> (
          let base_reqs =
            []
            |> add_if
                 (needs_fetch ~force m.infra.repositories)
                 Cmd.Get_repositories
          in
          (* A slot holding another repository's answer reads as waiting,
             so [needs_fetch] asks for the selected one. *)
          match Infra_store.selected_repo_activity m.infra with
          | Some (repo, activity) ->
              base_reqs
              |> add_if
                   (needs_fetch ~force activity)
                   (Cmd.Get_repository_activity { repo_id = repo.id })
          | None -> base_reqs)
      | Nav.Infra_activity_logs ->
          []
          |> add_if
               (force || not m.infra.logs_loaded)
               (Cmd.Get_system_logs
                  { limit = Some 200; level = m.infra.log_level_filter }))

let fetches_for_current_view ?(force = false) (m : Model.t) =
  let reqs =
    fetches_for_workspace ~force m
    @ fetches_for_dive ~force m
    @ fetches_for_overlay ~force m
    |> dedup_reqs
  in
  let get_cmds = List.map (fun req -> Cmd.Http_get { epoch = m.epoch; req }) reqs in
  let post_cmds =
    if
      Option.is_none (Model.active_dive m)
      && Nav.equal_workspace m.nav.workspace Nav.Runtime
      && Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_addons_browser
    then
      match Runtime_store.selected_browser_client m.runtime with
      | None -> []
      | Some cl ->
          let tabs_fresh =
            match m.runtime.browser_tabs with
            | Observed.Value { data = cid, _; stale = false; _ } ->
                String.equal cid cl.client_id && not force
            | Observed.Loading _
            | Observed.Value { stale = true; _ }
            | Observed.Absent
            | Observed.Unreported
            | Observed.Failed _ ->
                false
          in
          if tabs_fresh then []
          else
            [
              Cmd.Http_post
                {
                  epoch = m.epoch;
                  req = Cmd.Post_browser_tabs { client_id = cl.client_id };
                };
            ]
    else []
  in
  get_cmds @ post_cmds

let overlay_fetches (m : Model.t) =
  List.map
    (fun req -> Cmd.Http_get { epoch = m.epoch; req })
    (fetches_for_overlay ~force:false m)

let selected_wiki_page_fetch (m : Model.t) =
  let wiki_tab_shown =
    Nav.equal_workspace m.nav.workspace Nav.Knowledge
    && Nav.equal_knowledge_tab m.knowledge.active_tab
         Nav.Knowledge_wiki_artifacts
  in
  if wiki_tab_shown then
    List.map
      (fun req -> Cmd.Http_get { epoch = m.epoch; req })
      (selected_wiki_page_reqs ~force:false m)
  else []

let bootstrap_fetches (m : Model.t) =
  let core_reqs =
    [
      Cmd.Get_tui_preferences;
      Cmd.Get_dashboard_shell;
      Cmd.Get_keepers_roster;
      Cmd.Get_asks { keeper = None; include_resolved = false };
      Cmd.Get_tool_approvals;
      Cmd.Get_gate_pending;
      Cmd.Get_planning;
    ]
  in
  let view_reqs =
    fetches_for_workspace ~force:true m
    @ fetches_for_dive ~force:true m
    @ fetches_for_overlay ~force:true m
  in
  dedup_reqs (core_reqs @ view_reqs)
  |> List.map (fun req -> Cmd.Http_get { epoch = m.epoch; req })
