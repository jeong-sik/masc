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
      |> add_if
           (needs_fetch ~force m.runtime.efficiency)
           (Cmd.Get_efficiency { month = None })
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

let fetches_for_keeper_context ~force ~name (m : Model.t) =
  let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
  let base =
    []
    |> add_if
         (needs_fetch ~force ks.turn_records)
         (Cmd.Get_keeper_context_turn_records
            { keeper = name; limit = Some 50; turn_ref = None })
    |> add_if
         ((force || not ks.next_request_absent)
          && needs_fetch ~force ks.next_request)
         (Cmd.Get_keeper_next_request { keeper = name })
  in
  match Keeper_context_store.selected_turn_entry ks with
  | None -> base
  | Some entry ->
      let turn_ref = Ids.Turn_ref.to_string entry.record.turn_ref in
      let is_absent_ref opt =
        (not force)
        &&
        match opt with
        | Some r -> String.equal r turn_ref
        | None -> false
      in
      let matches_ref obs =
        match obs with
        | Observed.Value { data = r, _; stale = false; _ } ->
            String.equal r turn_ref && not force
        | Observed.Loading _
        | Observed.Value { stale = true; _ }
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ->
            false
      in
      let exec_ids =
        List.map Ids.Execution_id.to_string entry.record.execution_ids
      in
      base
      |> add_if
           ((force || not ks.provider_input_auth_denied)
            && (not (is_absent_ref ks.absent_provider_input_ref))
            && not (matches_ref ks.provider_input))
           (Cmd.Get_keeper_provider_input { keeper = name; turn_ref })
      |> add_if
           ((not (is_absent_ref ks.absent_cache_outcome_ref))
            && not (matches_ref ks.cache_outcome))
           (Cmd.Get_keeper_cache_outcome { keeper = name; turn_ref })
      |> add_if
           ((not (is_absent_ref ks.absent_transcript_ref))
            && not (matches_ref ks.turn_transcript))
           (Cmd.Get_keeper_turn_transcript { keeper = name; turn_ref })
      |> add_if
           ((force || not ks.call_evidence_auth_denied)
            && (not (is_absent_ref ks.absent_call_evidence_ref))
            && exec_ids <> []
            && not (matches_ref ks.call_evidence))
           (Cmd.Get_keeper_tool_calls
              {
                keeper = name;
                limit = None;
                execution_ids = Some exec_ids;
                turn_ref = Some turn_ref;
              })

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
      let drawer_reqs = fetches_for_context_drawer ~force m in
      let target =
        match Drafts.target_keeper_key m.drafts with
        | k when not (String.equal (String.trim k) "") && not (String.equal k "fleet")
          ->
            Some k
        | _ ->
            Option.map
              (fun (k : Wire_fleet.keeper_summary) -> k.name)
              (Fleet_store.selected_keeper_summary m.fleet)
      in
      let ctx_reqs =
        match target with
        | Some name -> fetches_for_keeper_context ~force ~name m
        | None -> []
      in
      drawer_reqs @ ctx_reqs
  | Some (Nav.Queue_context Nav.Drawer_schedules) ->
      if needs_fetch ~force m.work.schedules then
        [ Cmd.Get_schedules { cursor = None } ]
      else []
  | Some
      ( Nav.Palette
      | Nav.Incidents
      | Nav.Queue_context Nav.Drawer_queue
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate _ )
  | None ->
      []

(* Each failure row that stands for a cut reply reads its operation's
   journal, one page after another, until the reply is rebuilt. *)
let cut_reply_reqs ~force ~keeper (m : Model.t) =
  List.filter_map
    (fun (_row_id, operation_id) ->
      let slot = Fleet_store.cut_reply_for ~keeper ~operation_id m.fleet in
      if needs_fetch ~force slot then
        Option.map
          (fun from ->
            Cmd.Get_chat_operation_events { keeper; operation_id; from })
          (Cut_reply.pending_page slot)
      else None)
    (Fleet_store.cut_reply_rows ~keeper m.fleet)

let keeper_tab_fetches ~force ~name ~tab (m : Model.t) =
  match tab with
  | Nav.Keeper_chat ->
      let hist_needed =
        match Fleet_store.String_map.find_opt name m.fleet.chat_histories with
        | None -> true
        | Some obs -> needs_fetch ~force obs
      in
      ([]
      |> add_if (needs_fetch ~force m.fleet.turns) Cmd.Get_keeper_turns
      |> add_if hist_needed
           (Cmd.Get_chat_history
              { keeper = name; limit = Some 80; cursor = None }))
      @ cut_reply_reqs ~force ~keeper:name m
  | Nav.Keeper_context -> fetches_for_keeper_context ~force ~name m
  | Nav.Keeper_tool_calls ->
      let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
      []
      |> add_if
           ((force || not ks.tool_stats_absent)
            && needs_fetch ~force ks.tool_stats)
           (Cmd.Get_keeper_tool_stats { keeper = name; window_hours = Some 24 })
      |> add_if
           ((force || not ks.tool_calls_auth_denied)
            && (force || not ks.tool_calls_absent)
            && needs_fetch ~force ks.tool_calls)
           (Cmd.Get_keeper_tool_calls
              {
                keeper = name;
                limit = Some 50;
                execution_ids = None;
                turn_ref = None;
              })
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
        (force
         || not
              (Knowledge_store.String_set.mem name
                 m.knowledge.keeper_memory_facts_auth_denied))
        && needs_fetch ~force
             (Knowledge_store.keeper_memory_facts_for ~keeper:name m.knowledge)
      in
      let activity_needed =
        needs_fetch ~force
          (Knowledge_store.keeper_memory_activity_for ~keeper:name m.knowledge)
      in
      let journal_needed =
        (force
         || not
              (Knowledge_store.String_set.mem name
                 m.knowledge.keeper_memory_journal_auth_denied))
        &&
        match m.knowledge.keeper_memory_journal with
        | Observed.Value { data = k, _; stale = false; _ } ->
            force || not (String.equal k name)
        | Observed.Loading _
        | Observed.Value { stale = true; _ }
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ->
            needs_fetch ~force m.knowledge.keeper_memory_journal
      in
      let fleet_health_needed =
        needs_fetch ~force m.knowledge.keeper_memory_health
      in
      let keeper_health_needed =
        match m.knowledge.memory_health_keeper with
        | Observed.Value { data = k, _; stale = false; _ } ->
            force || not (String.equal k name)
        | Observed.Loading _
        | Observed.Value { stale = true; _ }
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ->
            needs_fetch ~force m.knowledge.memory_health_keeper
      in
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
      |> add_if fleet_health_needed
           (Cmd.Get_keeper_memory_health { keeper = None })
      |> add_if
           (keeper_health_needed
            && Knowledge_store.equal_keeper_memory_subview
                 m.knowledge.keeper_memory_subview Knowledge_store.Kmem_health)
           (Cmd.Get_keeper_memory_health { keeper = Some name })
      |> add_if
           (journal_needed
            && Knowledge_store.equal_keeper_memory_subview
                 m.knowledge.keeper_memory_subview Knowledge_store.Kmem_journal)
           (Cmd.Get_keeper_memory_journal { keeper = name; limit = Some 50 })
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
  | Nav.Keeper_logs ->
      let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
      []
      |> add_if
           (needs_fetch ~force ks.metrics)
           (Cmd.Get_keeper_metrics { keeper = name })
      |> add_if
           (needs_fetch ~force ks.sandbox_logs)
           (Cmd.Get_keeper_sandbox_logs { keeper = name; tail = Some 200 })
  | Nav.Keeper_identity ->
      let ks = Keeper_context_store.get_keeper ~keeper:name m.keeper_context in
      []
      |> add_if
           (needs_fetch ~force m.keeper_context.oauth_providers)
           Cmd.Get_oauth_providers
      |> add_if
           ((force || not ks.oauth_auth_denied)
            && needs_fetch ~force ks.oauth_attached)
           (Cmd.Get_oauth_attached_tools { keeper = name })
      |> add_if
           ((force || not ks.github_auth_denied)
            && needs_fetch ~force ks.github_identity)
           (Cmd.Get_github_identity { keeper = name })

(* Every keeper tab sits under the dive header, whose KPI strip shows the
   keeper's cost and tokens from keeper-costs. *)
let fetches_for_keeper_tab ~force ~name ~tab (m : Model.t) =
  add_keeper_costs ~force m (keeper_tab_fetches ~force ~name ~tab m)

let fetches_for_dive ~force (m : Model.t) =
  match Model.active_dive m with
  | None -> []
  | Some (Nav.Dive_keeper { name; tab }) ->
      fetches_for_keeper_tab ~force ~name ~tab m
  | Some (Nav.Dive_work target) ->
      let extra =
        match target with
        | Nav.Verification_dive req_id ->
            let ev_reqs =
              if (not force) && m.work.verification_evidence_auth_denied then []
              else
                let needed =
                  match m.work.verification_evidence with
                  | Observed.Value { data = vid, _; stale = false; _ } ->
                      force || not (String.equal vid req_id)
                  | Observed.Loading _
                  | Observed.Value { stale = true; _ }
                  | Observed.Absent
                  | Observed.Unreported
                  | Observed.Failed _ ->
                      needs_fetch ~force m.work.verification_evidence
                in
                if not needed then []
                else
                  match
                    List.find_opt
                      (fun (v : Wire_work.verification_request) ->
                        String.equal v.request_id req_id)
                      (Work_store.verifications_list m.work)
                  with
                  | Some v ->
                      [
                        Cmd.Get_verification_evidence
                          { task_id = v.task_id; verification_id = v.request_id };
                      ]
                  | None -> []
            in
            ev_reqs
            |> add_if
                 (needs_fetch ~force m.work.verification_summary)
                 Cmd.Get_verification_summary
            |> add_if
                 (needs_fetch ~force m.work.verification_specs)
                 Cmd.Get_verification_specs
            |> add_if
                 (needs_fetch ~force m.work.verification_tlc_results)
                 Cmd.Get_verification_tlc_results
        | Nav.Goal_dive _ | Nav.Task_dive _ -> []
      in
      ([]
      |> add_if (needs_fetch ~force m.work.planning) Cmd.Get_planning
      |> add_if
           (needs_fetch ~force m.work.verifications)
           (Cmd.Get_verifications
              { view = m.work.verification_view; limit = 50; offset = 0 }))
      @ extra
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
          let art_id, rev =
            match Knowledge_store.find_artifact_by_id_or_sha target m.knowledge with
            | Some a -> (a.id, Some a.revision)
            | None -> (target, None)
          in
          let detail_needed =
            match m.knowledge.active_artifact_detail with
            | Observed.Value { data; stale = false; _ } ->
                force
                || not
                     (String.equal data.artifact.id target
                      || String.equal data.artifact.body.sha256 target)
            | Observed.Failed { retryable = false; _ } when not force -> (
                match m.knowledge.active_artifact_detail_target with
                | Some failed_id ->
                    not
                      (String.equal failed_id target
                       || String.equal failed_id art_id)
                | None -> true)
            | Observed.Loading _
            | Observed.Value { stale = true; _ }
            | Observed.Absent
            | Observed.Unreported
            | Observed.Failed _ ->
                true
          in
          []
          |> add_if (needs_fetch ~force m.knowledge.artifacts) Cmd.Get_artifacts
          |> add_if
               (needs_fetch ~force m.knowledge.artifact_checks)
               Cmd.Get_artifact_checks
          |> add_if detail_needed (Cmd.Get_artifact_detail { id = art_id; revision = rev })
      | Nav.Memory_diff_dive { keeper; from_rev; to_rev } ->
          [
            Cmd.Get_memory_diff
              {
                keeper;
                window = Knowledge_store.Window_revs { from_rev; to_rev };
              };
          ])
  | Some (Nav.Dive_runtime (Nav.Tool_dive tool_name)) ->
      let bucket, since_hours =
        Runtime_store.tools_window_params m.runtime.tools_window
      in
      let series_needed =
        match m.runtime.tool_detail_series with
        | Observed.Value { data = t_name, _; stale = false; _ } ->
            force || not (String.equal t_name tool_name)
        | Observed.Loading _
        | Observed.Value { stale = true; _ }
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ->
            true
      in
      []
      |> add_if
           (needs_fetch ~force m.runtime.tools_dashboard)
           (Cmd.Get_tools_catalog { keeper = None })
      |> add_if series_needed
           (Cmd.Get_tool_series_filtered
              { bucket; since_hours; tool = Some tool_name })
  | Some (Nav.Dive_runtime (Nav.Fusion_dive run_id)) ->
      let detail_needed =
        match m.runtime.fusion_detail with
        | Observed.Value { data = rid, _; stale = false; _ } ->
            force || not (String.equal rid run_id)
        | Observed.Loading _
        | Observed.Value { stale = true; _ }
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ->
            needs_fetch ~force m.runtime.fusion_detail
      in
      []
      |> add_if (needs_fetch ~force m.runtime.fusion_runs) Cmd.Get_fusion_runs
      |> add_if detail_needed (Cmd.Get_fusion_run_detail { run_id })
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
      | Nav.Incident_dive _ | Nav.Log_detail_dive _ -> []
      | Nav.Runtime_trace_dive keeper ->
          let trace_needed =
            match m.infra.runtime_trace with
            | Observed.Value { data = k, _; stale = false; _ } ->
                force || not (String.equal k keeper)
            | Observed.Loading _
            | Observed.Value { stale = true; _ }
            | Observed.Absent
            | Observed.Unreported
            | Observed.Failed _ ->
                needs_fetch ~force m.infra.runtime_trace
          in
          []
          |> add_if trace_needed
               (Cmd.Get_keeper_runtime_trace { keeper; limit = Some 50 }))

(* The Wiki tab shows the selected page's body, so it needs that page unless
   the slot already holds it fresh. A dive covers the tab, and a Wiki dive
   keeps its own page in the same slot, so nothing is asked while one is
   open. *)
let selected_wiki_page_reqs ~force (m : Model.t) =
  match (Model.active_dive m, m.knowledge.active_tab) with
  | Some _, _
  | None, (Nav.Knowledge_board | Nav.Knowledge_artifacts | Nav.Knowledge_memory)
    ->
      []
  | None, Nav.Knowledge_wiki -> (
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
      | Nav.Work_tasks ->
          [] |> add_if (needs_fetch ~force m.work.planning) Cmd.Get_planning
      | Nav.Work_schedules ->
          []
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
          |> add_if (needs_fetch ~force m.fleet.shell) Cmd.Get_dashboard_shell
      | Nav.Work_harness ->
          []
          |> add_if
               (needs_fetch ~force m.work.harness_health)
               Cmd.Get_harness_health)
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
          |> add_if
               (needs_fetch ~force m.knowledge.board_hearths)
               Cmd.Get_board_hearths
      | Nav.Knowledge_wiki ->
          ([]
          |> add_if
               (needs_fetch ~force m.knowledge.wiki_index)
               (Cmd.Get_wiki_index { tag = None; source = None; sort = None })
          |> add_if (needs_fetch ~force m.knowledge.wiki_lint) Cmd.Get_wiki_lint
          |> add_if
               (needs_fetch ~force m.knowledge.wiki_log)
               (Cmd.Get_wiki_log { limit = Some 30; page = None }))
          @ selected_wiki_page_reqs ~force m
      | Nav.Knowledge_artifacts ->
          let selected_artifact_req =
            match Knowledge_store.selected_artifact m.knowledge with
            | None -> []
            | Some a ->
                let detail_matches =
                  match m.knowledge.active_artifact_detail with
                  | Observed.Value { data; stale = false; _ } ->
                      (String.equal data.artifact.id a.id
                       || String.equal data.artifact.body.sha256 a.body.sha256)
                      && not force
                  | Observed.Failed { retryable = false; _ } when not force -> (
                      match m.knowledge.active_artifact_detail_target with
                      | Some failed_id ->
                          String.equal failed_id a.id
                          || String.equal failed_id a.body.sha256
                      | None -> false)
                  | Observed.Loading _
                  | Observed.Value { stale = true; _ }
                  | Observed.Absent
                  | Observed.Unreported
                  | Observed.Failed _ ->
                      false
                in
                if detail_matches then []
                else
                  [
                    Cmd.Get_artifact_detail
                      { id = a.id; revision = Some a.revision };
                  ]
          in
          ([]
          |> add_if (needs_fetch ~force m.knowledge.artifacts) Cmd.Get_artifacts
          |> add_if
               (needs_fetch ~force m.knowledge.artifact_checks)
               Cmd.Get_artifact_checks)
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
                  (force
                   || not
                        (Knowledge_store.String_set.mem keeper
                           m.knowledge.keeper_memory_facts_auth_denied))
                  && needs_fetch ~force
                       (Knowledge_store.keeper_memory_facts_for ~keeper
                          m.knowledge)
                in
                let activity_needed =
                  needs_fetch ~force
                    (Knowledge_store.keeper_memory_activity_for ~keeper
                       m.knowledge)
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
               (Cmd.Get_keeper_memory_health { keeper = None })
          |> add_if
               (Knowledge_store.equal_memory_subview m.knowledge.memory_subview
                  Knowledge_store.Mem_health_ledger
                && (force || not m.knowledge.workspace_memory_ledger_auth_denied)
                && needs_fetch ~force m.knowledge.workspace_memory_ledger)
               Cmd.Get_workspace_memory_ledger
          |> add_if
               (Knowledge_store.equal_memory_subview m.knowledge.memory_subview
                  Knowledge_store.Mem_context
                && (force || not m.knowledge.workspace_memory_context_auth_denied)
                && needs_fetch ~force m.knowledge.workspace_memory_context)
               Cmd.Get_workspace_memory_context
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
      | Nav.Runtime_fusion ->
          let detail_req =
            match Runtime_store.selected_fusion_run m.runtime with
            | None -> []
            | Some run -> (
                if Runtime_store.is_retained_fusion_run ~run_id:run.run_id m.runtime then
                  let needed =
                    match m.runtime.fusion_detail with
                    | Observed.Value { data = rid, _; stale = false; _ } ->
                        force || not (String.equal rid run.run_id)
                    | Observed.Loading _
                    | Observed.Value { stale = true; _ }
                    | Observed.Absent
                    | Observed.Unreported
                    | Observed.Failed _ ->
                        needs_fetch ~force m.runtime.fusion_detail
                  in
                  if not needed then []
                  else [ Cmd.Get_fusion_run_detail { run_id = run.run_id } ]
                else
                  match
                    Runtime_store.historical_evidence_for_run ~run_id:run.run_id
                      m.runtime
                  with
                  | Some hist ->
                      let ev_needed =
                        match m.runtime.fusion_board_evidence with
                        | Observed.Value { data = pid, _; stale = false; _ } ->
                            force || not (String.equal pid hist.post_id)
                        | Observed.Loading _
                        | Observed.Value { stale = true; _ }
                        | Observed.Absent
                        | Observed.Unreported
                        | Observed.Failed _ ->
                            needs_fetch ~force m.runtime.fusion_board_evidence
                      in
                      if not ev_needed then []
                      else
                        [
                          Cmd.Get_fusion_board_evidence { post_id = hist.post_id };
                        ]
                  | None -> [])
          in
          ([]
          |> add_if (needs_fetch ~force m.runtime.fusion_runs) Cmd.Get_fusion_runs
          |> add_if
               ((force || not m.runtime.fusion_config_auth_denied)
                && needs_fetch ~force m.runtime.fusion_config)
               Cmd.Get_fusion_config
          |> add_if
               (needs_fetch ~force m.runtime.exact_lane_runs)
               (Cmd.Get_exact_lane_runs { lane = None; limit = Some 30 }))
          @ detail_req
      | Nav.Runtime_tools_usage ->
          let bucket, since_hours =
            Runtime_store.tools_window_params m.runtime.tools_window
          in
          let keeper_names =
            match Observed.to_option m.fleet.keepers with
            | Some ks ->
                List.map (fun (k : Wire_fleet.keeper_summary) -> k.name) ks
            | None -> []
          in
          let surface_keeper =
            match m.runtime.tools_subview with
            | Runtime_store.Tools_keeper_skills ->
                Runtime_store.selected_tools_surface_keeper ~keeper_names
                  m.runtime
            | Runtime_store.Tools_usage_calls
            | Runtime_store.Tools_catalog_tree ->
                None
          in
          []
          |> add_if
               (needs_fetch ~force m.runtime.tool_series_summary)
               (Cmd.Get_tool_series_filtered
                  { bucket; since_hours; tool = None })
          |> add_if
               (needs_fetch ~force m.runtime.tools_dashboard)
               (Cmd.Get_tools_catalog { keeper = surface_keeper })
          |> add_if (needs_fetch ~force m.runtime.skills) Cmd.Get_skills
      | Nav.Runtime_connectors ->
          let name_reqs =
            match Runtime_store.selected_connector m.runtime with
            | Some c
              when force
                   || not
                        (Runtime_store.String_map.mem c.connector_id
                           m.runtime.connector_names) ->
                [
                  Cmd.Get_connector_names
                    { connector = c.connector_id; scope = "channel" };
                ]
            | Some _ | None -> []
          in
          ([]
          |> add_if (needs_fetch ~force m.runtime.connectors) Cmd.Get_connectors
          |> add_if (needs_fetch ~force m.runtime.mcp_clients) Cmd.Get_mcp_clients
          |> add_if (needs_fetch ~force m.runtime.browser_lane) Cmd.Get_browser_lane)
          @ name_reqs
      | Nav.Runtime_addons_browser ->
          let catalog_reqs =
            if not m.runtime.addon_catalog_mode then []
            else
              let preview_req =
                match Runtime_store.selected_addon_catalog_entry m.runtime with
                | Some (Wire_runtime.Catalog_package { manifest_path; _ }) ->
                    let needed =
                      match m.runtime.addon_package_preview with
                      | Observed.Value { data = mp, _; stale = false; _ } ->
                          force || not (String.equal mp manifest_path)
                      | Observed.Loading _
                      | Observed.Value { stale = true; _ }
                      | Observed.Absent
                      | Observed.Unreported
                      | Observed.Failed _ ->
                          needs_fetch ~force m.runtime.addon_package_preview
                    in
                    if not needed then []
                    else [ Cmd.Get_addon_package_preview { manifest_path } ]
                | Some (Wire_runtime.Catalog_folder _ | Wire_runtime.Catalog_issue _)
                | None ->
                    []
              in
              ([]
              |> add_if
                   (needs_fetch ~force m.runtime.addon_package_catalog)
                   (Cmd.Get_addon_package_catalog { directory = None }))
              @ preview_req
          in
          ([]
          |> add_if
               (needs_fetch ~force m.runtime.lane_addons)
               Cmd.Get_lane_addons
          |> add_if
               (needs_fetch ~force m.runtime.browser_lane)
               Cmd.Get_browser_lane)
          @ catalog_reqs)
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
      | Nav.Infra_code ->
          let sc = m.infra.code.scope in
          let cur_file_opt = Infra_store.active_code_file_path m.infra in
          let mode_reqs =
            match m.infra.code.right_mode with
            | Infra_store.Code_file | Infra_store.Code_search_results -> []
            | Infra_store.Code_git_status ->
                let needed =
                  match m.infra.code.git_status with
                  | Observed.Value { data = s, _; stale = false; _ } ->
                      force || not (Wire_infra.equal_workspace_scope s sc)
                  | Observed.Loading _
                  | Observed.Value { stale = true; _ }
                  | Observed.Absent
                  | Observed.Unreported
                  | Observed.Failed _ ->
                      needs_fetch ~force m.infra.code.git_status
                in
                if not needed then [] else [ Cmd.Get_git_status { scope = sc } ]
            | Infra_store.Code_git_branches ->
                let needed =
                  match m.infra.code.git_branches with
                  | Observed.Value { data = s, _; stale = false; _ } ->
                      force || not (Wire_infra.equal_workspace_scope s sc)
                  | Observed.Loading _
                  | Observed.Value { stale = true; _ }
                  | Observed.Absent
                  | Observed.Unreported
                  | Observed.Failed _ ->
                      needs_fetch ~force m.infra.code.git_branches
                in
                if not needed then [] else [ Cmd.Get_git_branches { scope = sc } ]
            | Infra_store.Code_git_worktrees ->
                let needed =
                  match m.infra.code.git_worktrees with
                  | Observed.Value { data = s, _; stale = false; _ } ->
                      force || not (Wire_infra.equal_workspace_scope s sc)
                  | Observed.Loading _
                  | Observed.Value { stale = true; _ }
                  | Observed.Absent
                  | Observed.Unreported
                  | Observed.Failed _ ->
                      needs_fetch ~force m.infra.code.git_worktrees
                in
                if not needed then []
                else [ Cmd.Get_git_worktrees { scope = sc } ]
            | Infra_store.Code_git_blame -> (
                match cur_file_opt with
                | None -> []
                | Some path ->
                    let needed =
                      match m.infra.code.git_blame with
                      | Observed.Value { data = s, p, _; stale = false; _ } ->
                          force
                          || not
                               (Wire_infra.equal_workspace_scope s sc
                                && String.equal p path)
                      | Observed.Loading _
                      | Observed.Value { stale = true; _ }
                      | Observed.Absent
                      | Observed.Unreported
                      | Observed.Failed _ ->
                          needs_fetch ~force m.infra.code.git_blame
                    in
                    if not needed then []
                    else [ Cmd.Get_git_blame { scope = sc; path } ])
            | Infra_store.Code_git_log -> (
                match cur_file_opt with
                | None -> []
                | Some path ->
                    let needed =
                      match m.infra.code.git_log with
                      | Observed.Value { data = s, p, _; stale = false; _ } ->
                          force
                          || not
                               (Wire_infra.equal_workspace_scope s sc
                                && String.equal p path)
                      | Observed.Loading _
                      | Observed.Value { stale = true; _ }
                      | Observed.Absent
                      | Observed.Unreported
                      | Observed.Failed _ ->
                          needs_fetch ~force m.infra.code.git_log
                    in
                    if not needed then []
                    else [ Cmd.Get_git_log { scope = sc; path } ])
            | Infra_store.Code_git_diff -> (
                match cur_file_opt with
                | None -> []
                | Some path ->
                    let needed =
                      match m.infra.code.git_diff with
                      | Observed.Value { data = s, p, _; stale = false; _ } ->
                          force
                          || not
                               (Wire_infra.equal_workspace_scope s sc
                                && String.equal p path)
                      | Observed.Loading _
                      | Observed.Value { stale = true; _ }
                      | Observed.Absent
                      | Observed.Unreported
                      | Observed.Failed _ ->
                          needs_fetch ~force m.infra.code.git_diff
                    in
                    if not needed then []
                    else [ Cmd.Get_git_diff { scope = sc; path } ])
          in
          ([]
          |> add_if
               (force || not m.infra.code.tree_loaded)
               (Cmd.Get_workspace_children { scope = sc; dir = "" }))
          @ mode_reqs
      | Nav.Infra_activity_logs ->
          []
          |> add_if
               (force || not m.infra.logs_loaded)
               (Cmd.Get_system_logs
                  { limit = Some 200; level = m.infra.log_level_filter })
          |> add_if
               (force || not m.infra.activity_events_loaded)
               (Cmd.Get_activity_events { limit = Some 200; after_seq = Some 0 })
          |> add_if (needs_fetch ~force m.fleet.turns) Cmd.Get_keeper_turns)

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
            match
              Runtime_store.browser_tabs_for ~client_id:cl.client_id m.runtime
            with
            | Observed.Value { stale = false; _ }
            | Observed.Failed { retryable = false; _ } ->
                not force
            | Observed.Loading _
            | Observed.Value { stale = true; _ }
            | Observed.Absent
            | Observed.Unreported
            | Observed.Failed { retryable = true; _ } ->
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

(* The keeper's Chat transcript is on screen: as the top dive's Chat tab, or
   as the Keepers split's Chat pane for the selected keeper with no dive
   open. *)
let chat_tab_shown ~keeper (m : Model.t) =
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_chat }) ->
      String.equal name keeper
  | Some
      (Nav.Dive_keeper
         {
           tab =
             ( Nav.Keeper_context
             | Nav.Keeper_tool_calls
             | Nav.Keeper_memory
             | Nav.Keeper_work_candle
             | Nav.Keeper_logs
             | Nav.Keeper_identity
             | Nav.Keeper_sandbox
             | Nav.Keeper_config );
           _;
         })
  | Some
      ( Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime _
      | Nav.Dive_infra _ ) ->
      false
  | None -> (
      Nav.equal_workspace m.nav.workspace Nav.Keepers
      && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_chat
      &&
      match Fleet_store.selected_keeper_summary m.fleet with
      | Some k -> String.equal k.name keeper
      | None -> false)

let cut_reply_fetches ~keeper (m : Model.t) =
  if chat_tab_shown ~keeper m then
    List.map
      (fun req -> Cmd.Http_get { epoch = m.epoch; req })
      (cut_reply_reqs ~force:false ~keeper m)
  else []

let selected_wiki_page_fetch (m : Model.t) =
  let wiki_tab_shown =
    Nav.equal_workspace m.nav.workspace Nav.Knowledge
    && Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_wiki
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
