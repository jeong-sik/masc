open Masc_tui_core
open Masc_tui_protocol

let get_cmd epoch req = Cmd.Http_get { epoch; req }

let is_viewing_keeper_chat ~keeper (m : Model.t) =
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_chat }) ->
      String.equal name keeper
  | None -> (
      Nav.equal_workspace m.nav.workspace Nav.Keepers
      && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_chat
      &&
      match Fleet_store.selected_keeper_summary m.fleet with
      | Some k -> String.equal k.name keeper
      | None -> false)
  | Some
      ( Nav.Dive_keeper
          {
            tab =
              ( Nav.Keeper_context
              | Nav.Keeper_tool_calls
              | Nav.Keeper_memory
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox
              | Nav.Keeper_config
              | Nav.Keeper_logs
              | Nav.Keeper_identity );
            _;
          }
      | Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime _
      | Nav.Dive_infra _ ) ->
      false

let active_memory_keeper (m : Model.t) =
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_memory }) -> Some name
  | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; _ })) -> keeper
  | Some
      ( Nav.Dive_keeper
          {
            tab =
              ( Nav.Keeper_chat
              | Nav.Keeper_context
              | Nav.Keeper_tool_calls
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox
              | Nav.Keeper_config
              | Nav.Keeper_logs
              | Nav.Keeper_identity );
            _;
          }
      | Nav.Dive_work _
      | Nav.Dive_knowledge
          (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
      | Nav.Dive_runtime _
      | Nav.Dive_infra _ ) ->
      None
  | None -> (
      match m.nav.workspace with
      | Nav.Knowledge
        when Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_memory
        ->
          m.knowledge.memory_diff_keeper
      | Nav.Keepers
        when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory ->
          Option.map
            (fun (k : Wire_fleet.keeper_summary) -> k.name)
            (Fleet_store.selected_keeper_summary m.fleet)
      | Nav.Pulse
      | Nav.Work
      | Nav.Knowledge
      | Nav.Keepers
      | Nav.Runtime
      | Nav.Infra ->
          None)

let is_viewing_memory (m : Model.t) =
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { tab = Nav.Keeper_memory; _ })
  | Some (Nav.Dive_knowledge (Nav.Memory_diff_dive _)) ->
      true
  | Some
      ( Nav.Dive_keeper
          {
            tab =
              ( Nav.Keeper_chat
              | Nav.Keeper_context
              | Nav.Keeper_tool_calls
              | Nav.Keeper_work_candle
              | Nav.Keeper_sandbox
              | Nav.Keeper_config
              | Nav.Keeper_logs
              | Nav.Keeper_identity );
            _;
          }
      | Nav.Dive_work _
      | Nav.Dive_knowledge
          (Nav.Thread_dive _ | Nav.Wiki_dive _ | Nav.Artifact_dive _)
      | Nav.Dive_runtime _
      | Nav.Dive_infra _ ) ->
      false
  | None -> (
      match m.nav.workspace with
      | Nav.Knowledge ->
          Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_memory
      | Nav.Keepers ->
          Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
      | Nav.Pulse | Nav.Work | Nav.Runtime | Nav.Infra -> false)

(* The views that read the schedule rows: Work's schedule list, the Keepers
   list's next-due column and a keeper's work tab, wherever it was opened. *)
let reads_schedules (m : Model.t) =
  let workspace_reads =
    match m.nav.workspace with
    | Nav.Work | Nav.Keepers -> true
    | Nav.Pulse | Nav.Knowledge | Nav.Runtime | Nav.Infra -> false
  in
  match Model.active_dive m with
  | Some (Nav.Dive_keeper { tab = Nav.Keeper_work_candle; _ }) -> true
  | Some
      (Nav.Dive_keeper
         {
           tab =
             ( Nav.Keeper_chat
             | Nav.Keeper_context
             | Nav.Keeper_tool_calls
             | Nav.Keeper_memory
             | Nav.Keeper_sandbox
             | Nav.Keeper_config
             | Nav.Keeper_logs
             | Nav.Keeper_identity );
           _;
         })
  | Some
      ( Nav.Dive_work _
      | Nav.Dive_knowledge _
      | Nav.Dive_runtime _
      | Nav.Dive_infra _ )
  | None -> workspace_reads

let apply_dataset_invalidation (m : Model.t) ds =
  let e = m.epoch in
  let ws = m.nav.workspace in
  match ds with
  | Wire_observer.Dataset_goals | Wire_observer.Dataset_backlog ->
      let work =
        { m.work with planning = Observed.mark_stale m.work.planning }
      in
      let cmds =
        match ws with
        | Nav.Work | Nav.Pulse -> [ get_cmd e Cmd.Get_planning ]
        | Nav.Knowledge | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
      in
      ({ m with work }, cmds)
  | Wire_observer.Dataset_board ->
      let knowledge =
        { m.knowledge with board = Observed.mark_stale m.knowledge.board }
      in
      let cmds =
        match ws with
        | Nav.Knowledge | Nav.Pulse ->
            [
              get_cmd e
                (Cmd.Get_board_feed
                   {
                     sort_by = knowledge.board_sort_by;
                     hearth = knowledge.board_hearth;
                     signal_only = knowledge.board_signal_only;
                     limit = Some 50;
                     offset = None;
                   });
            ]
        | Nav.Work | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
      in
      ({ m with knowledge }, cmds)
  | Wire_observer.Dataset_memory_health keeper_opt ->
      (* The named keeper's slots turn stale; with no keeper named, every
         keeper's slots do. *)
      let mark_scoped slots =
        match keeper_opt with
        | None -> Knowledge_store.String_map.map Observed.mark_stale slots
        | Some target ->
            Knowledge_store.String_map.update target
              (Option.map Observed.mark_stale)
              slots
      in
      let knowledge =
        {
          m.knowledge with
          world_memory = Observed.mark_stale m.knowledge.world_memory;
          keeper_memory_health =
            Observed.mark_stale m.knowledge.keeper_memory_health;
          keeper_memory_facts = mark_scoped m.knowledge.keeper_memory_facts;
          memory_os_internals = mark_scoped m.knowledge.memory_os_internals;
        }
      in
      let base_cmds =
        match ws with
        | Nav.Knowledge | Nav.Pulse -> [ get_cmd e Cmd.Get_world_memory ]
        | Nav.Work | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
      in
      let mem_cmds =
        if not (is_viewing_memory m) then []
        else
          let keeper_cmds =
            match active_memory_keeper m, keeper_opt with
            | Some kp, None ->
                [
                  get_cmd e (Cmd.Get_keeper_memory_facts { keeper = kp });
                  get_cmd e (Cmd.Get_keeper_memory_os_internals { keeper = kp });
                ]
            | Some kp, Some target when String.equal kp target ->
                [
                  get_cmd e (Cmd.Get_keeper_memory_facts { keeper = kp });
                  get_cmd e (Cmd.Get_keeper_memory_os_internals { keeper = kp });
                ]
            | Some _, Some _ | None, (Some _ | None) -> []
          in
          get_cmd e (Cmd.Get_keeper_memory_health { keeper = None }) :: keeper_cmds
      in
      ({ m with knowledge }, base_cmds @ mem_cmds)
  | Wire_observer.Dataset_world_memory ->
      let knowledge =
        {
          m.knowledge with
          world_memory = Observed.mark_stale m.knowledge.world_memory;
        }
      in
      let cmds =
        match ws with
        | Nav.Knowledge | Nav.Pulse -> [ get_cmd e Cmd.Get_world_memory ]
        | Nav.Work | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
      in
      ({ m with knowledge }, cmds)
  | Wire_observer.Dataset_memory_diff ->
      let knowledge =
        {
          m.knowledge with
          memory_diffs =
            Knowledge_store.Memory_diff_map.map Observed.mark_stale
              m.knowledge.memory_diffs;
          keeper_memory_activity =
            Knowledge_store.String_map.map Observed.mark_stale
              m.knowledge.keeper_memory_activity;
          keeper_memory_facts =
            Knowledge_store.String_map.map Observed.mark_stale
              m.knowledge.keeper_memory_facts;
          keeper_memory_health =
            Observed.mark_stale m.knowledge.keeper_memory_health;
          memory_os_internals =
            Knowledge_store.String_map.map Observed.mark_stale
              m.knowledge.memory_os_internals;
        }
      in
      let cmds =
        if not (is_viewing_memory m) then
          match ws with
          | Nav.Knowledge ->
              [
                get_cmd e
                  (Cmd.Get_memory_diff
                     {
                       keeper = knowledge.memory_diff_keeper;
                       window = knowledge.memory_diff_window;
                     });
              ]
          | Nav.Pulse | Nav.Work | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
        else
          match active_memory_keeper m with
          | Some kp ->
              [
                get_cmd e
                  (Cmd.Get_memory_diff
                     { keeper = Some kp; window = knowledge.memory_diff_window });
                get_cmd e
                  (Cmd.Get_keeper_memory_activity { keeper = kp; limit = 50 });
                get_cmd e (Cmd.Get_keeper_memory_facts { keeper = kp });
                get_cmd e (Cmd.Get_keeper_memory_os_internals { keeper = kp });
                get_cmd e (Cmd.Get_keeper_memory_health { keeper = None });
              ]
          | None ->
              [
                get_cmd e
                  (Cmd.Get_memory_diff
                     {
                       keeper = knowledge.memory_diff_keeper;
                       window = knowledge.memory_diff_window;
                     });
                get_cmd e (Cmd.Get_keeper_memory_health { keeper = None });
              ]
      in
      ({ m with knowledge }, cmds)
  | Wire_observer.Dataset_runtime_config ->
      let runtime =
        {
          m.runtime with
          runtime_resolved = Observed.mark_stale m.runtime.runtime_resolved;
        }
      in
      let config =
        { m.config with schema = Observed.mark_stale m.config.schema }
      in
      let cmds =
        match m.nav.overlay with
        | Some (Nav.Settings _) ->
            [ get_cmd e (Cmd.Get_config_schema config.target) ]
        | Some
            ( Nav.Palette
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Ask_answer
            | Nav.Help
            | Nav.System_gate _ )
        | None -> (
            match ws with
            | Nav.Runtime -> [ get_cmd e Cmd.Get_runtime_resolved ]
            | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra ->
                [])
      in
      ({ m with runtime; config }, cmds)
  | Wire_observer.Dataset_provider_usage | Wire_observer.Dataset_provider_standing
    ->
      let runtime =
        {
          m.runtime with
          usage_windows = Observed.mark_stale m.runtime.usage_windows;
          usage_history = Observed.mark_stale m.runtime.usage_history;
          runtime_resolved = Observed.mark_stale m.runtime.runtime_resolved;
        }
      in
      let cmds =
        match ws with
        | Nav.Runtime ->
            [
              get_cmd e Cmd.Get_runtime_resolved;
              get_cmd e (Cmd.Get_provider_usage { days = 7 });
            ]
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra -> []
      in
      ({ m with runtime }, cmds)
  | Wire_observer.Dataset_runtime_probe ->
      let runtime =
        {
          m.runtime with
          runtime_probe = Observed.mark_stale m.runtime.runtime_probe;
        }
      in
      let cmds =
        match ws with
        | Nav.Runtime ->
            [ get_cmd e (Cmd.Get_runtime_probe { force = false }) ]
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra -> []
      in
      ({ m with runtime }, cmds)
  | Wire_observer.Dataset_tool_metrics ->
      let runtime =
        {
          m.runtime with
          tool_series = Observed.mark_stale m.runtime.tool_series;
          tools_catalog = Observed.mark_stale m.runtime.tools_catalog;
        }
      in
      let cmds =
        match ws with
        | Nav.Runtime -> [ get_cmd e (Cmd.Get_tools_catalog { keeper = None }) ]
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra -> []
      in
      ({ m with runtime }, cmds)
  | Wire_observer.Dataset_verification_requests ->
      let work =
        { m.work with verifications = Observed.mark_stale m.work.verifications }
      in
      let cmds =
        match ws with
        | Nav.Work ->
            [
              get_cmd e
                (Cmd.Get_verifications
                   { view = work.verification_view; limit = 50; offset = 0 });
            ]
        | Nav.Pulse | Nav.Knowledge | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
      in
      ({ m with work }, cmds)
  | Wire_observer.Dataset_scheduled_automation ->
      let work =
        { m.work with schedules = Observed.mark_stale m.work.schedules }
      in
      let cmds =
        if reads_schedules m then [ get_cmd e (Cmd.Get_schedules { cursor = None }) ]
        else []
      in
      ({ m with work }, cmds)
  | Wire_observer.Dataset_wiki ->
      let knowledge =
        {
          m.knowledge with
          wiki_index = Observed.mark_stale m.knowledge.wiki_index;
          wiki_lint = Observed.mark_stale m.knowledge.wiki_lint;
        }
      in
      let cmds =
        match ws with
        | Nav.Knowledge ->
            [
              get_cmd e
                (Cmd.Get_wiki_index { tag = None; source = None; sort = None });
            ]
        | Nav.Pulse | Nav.Work | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
      in
      ({ m with knowledge }, cmds)
  | Wire_observer.Dataset_infra_sandboxes ->
      let infra =
        { m.infra with sandboxes = Observed.mark_stale m.infra.sandboxes }
      in
      let cmds =
        match ws with
        | Nav.Infra -> [ get_cmd e Cmd.Get_sandboxes ]
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime -> []
      in
      ({ m with infra }, cmds)
  | Wire_observer.Dataset_candle_ledger ->
      let work =
        { m.work with candle_ledger = Observed.mark_stale m.work.candle_ledger }
      in
      let cmds =
        match ws with
        | Nav.Work -> [ get_cmd e (Cmd.Get_candle_ledger { limit = Some 50 }) ]
        | Nav.Pulse | Nav.Knowledge | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
      in
      ({ m with work }, cmds)
  | Wire_observer.Dataset_gate ->
      (* Global attention surface always stays fresh. *)
      let work =
        { m.work with gate_pending = Observed.mark_stale m.work.gate_pending }
      in
      ({ m with work }, [ get_cmd e Cmd.Get_gate_pending ])
  | Wire_observer.Dataset_keepers ->
      let fleet = Fleet_store.mark_keepers_stale m.fleet in
      ({ m with fleet }, [ get_cmd e Cmd.Get_keepers_roster ])
  | Wire_observer.Dataset_health ->
      (m, [ get_cmd e Cmd.Get_dashboard_shell ])
  | Wire_observer.Dataset_lane_addons ->
      let runtime =
        {
          m.runtime with
          lane_addons = Observed.mark_stale m.runtime.lane_addons;
          browser_lane = Observed.mark_stale m.runtime.browser_lane;
        }
      in
      let cmds =
        match ws with
        | Nav.Runtime ->
            [ get_cmd e Cmd.Get_lane_addons; get_cmd e Cmd.Get_browser_lane ]
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra -> []
      in
      ({ m with runtime }, cmds)
  | Wire_observer.Dataset_logs
  | Wire_observer.Dataset_activity
  | Wire_observer.Dataset_other _ ->
      (m, [])

let apply_observation_changed (m : Model.t)
    (payload : Sse_event.Types.dashboard_observation_changed_payload) =
  let e = m.epoch in
  match payload.topic with
  | `Logs -> (m, [])
  | `Health -> apply_dataset_invalidation m Wire_observer.Dataset_health
  | `Runtime_probe ->
      apply_dataset_invalidation m Wire_observer.Dataset_runtime_probe
  | `Runtime_resolved ->
      apply_dataset_invalidation m Wire_observer.Dataset_runtime_config
  | `Model_metrics | `Attribution | `Runtime_observables | `Telemetry ->
      let runtime =
        {
          m.runtime with
          efficiency = Observed.mark_stale m.runtime.efficiency;
          models_metrics = Observed.mark_stale m.runtime.models_metrics;
          runtime_metrics = Observed.mark_stale m.runtime.runtime_metrics;
        }
      in
      let cmds =
        match m.nav.workspace with
        | Nav.Runtime ->
            [
              get_cmd e (Cmd.Get_efficiency { month = None });
              get_cmd e
                (Cmd.Get_models_metrics
                  {
                    window_minutes = Wire_runtime.models_chart_window_minutes;
                    bucket_minutes = Wire_runtime.models_chart_bucket_minutes;
                  });
            ]
        | Nav.Pulse ->
            [
              get_cmd e
                (Cmd.Get_models_metrics
                  {
                    window_minutes = Wire_runtime.models_chart_window_minutes;
                    bucket_minutes = Wire_runtime.models_chart_bucket_minutes;
                  });
            ]
        | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra -> []
      in
      ({ m with runtime }, cmds)
  | `Keeper_composite | `Keeper_runtime_trace ->
      apply_dataset_invalidation m Wire_observer.Dataset_keepers
  | `Keeper_turns ->
      let fleet = { m.fleet with turns = Observed.mark_stale m.fleet.turns } in
      let wants_turns =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper _) -> true
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            false
        | None -> (
            match m.nav.workspace with
            | Nav.Keepers | Nav.Pulse -> true
            | Nav.Infra ->
                Nav.equal_infra_tab m.infra.active_tab Nav.Infra_activity_logs
            | Nav.Work | Nav.Knowledge | Nav.Runtime -> false)
      in
      let cmds = if wants_turns then [ get_cmd e Cmd.Get_keeper_turns ] else [] in
      ({ m with fleet }, cmds)
  | `Keeper_sandbox ->
      apply_dataset_invalidation m Wire_observer.Dataset_infra_sandboxes
  | `Keeper_memory_health ->
      apply_dataset_invalidation m (Wire_observer.Dataset_memory_health None)
  | `Scheduled_automation ->
      apply_dataset_invalidation m Wire_observer.Dataset_scheduled_automation
  | `Tools | `Tool_metrics ->
      apply_dataset_invalidation m Wire_observer.Dataset_tool_metrics
  | `Published_artifacts | `Artifact_checks ->
      let knowledge =
        { m.knowledge with artifacts = Observed.mark_stale m.knowledge.artifacts }
      in
      let cmds =
        match m.nav.workspace with
        | Nav.Knowledge -> [ get_cmd e Cmd.Get_artifacts ]
        | Nav.Pulse | Nav.Work | Nav.Keepers | Nav.Runtime | Nav.Infra -> []
      in
      ({ m with knowledge }, cmds)
  | `Verification_requests | `Verification_specs ->
      apply_dataset_invalidation m Wire_observer.Dataset_verification_requests
  | `Gate | `Gate_tool_events ->
      apply_dataset_invalidation m Wire_observer.Dataset_gate
  | `Chat_operation -> (
      match payload.scope with
      | `Operation { keeper_name; _ } | `Keeper keeper_name ->
          let fleet =
            Fleet_store.mark_chat_history_stale ~keeper:keeper_name m.fleet
          in
          let cmds =
            if is_viewing_keeper_chat ~keeper:keeper_name m then
              [
                get_cmd e
                  (Cmd.Get_chat_history
                     { keeper = keeper_name; limit = Some 80; cursor = None });
              ]
            else []
          in
          ({ m with fleet }, cmds)
      | `Workspace -> (m, []))
  | `Skills
  | `Async_requests
  | `Skill_usage
  | `Skill_activations
  | `Tlc_results
  | `Activity
  | `Ide_presence
  | `Ide_events ->
      (m, [])

let apply_agent_core (m : Model.t) (ev : Wire_observer.agent_core_event) =
  match ev.kind with
  | Wire_observer.Agent_failed { error_code; error; _ } ->
      (* Channel 3 isolation: historical agent failure goes to Incidents + Activity,
         NEVER mutates Channel 2 live keeper health directly. *)
      let source =
        match ev.agent with
        | Some k -> Health.Source_keeper k
        | None -> Health.Source_stream
      in
      let summary =
        Say.make
          ~ko:("에이전트 실행 실패 (" ^ error_code ^ ")")
          ~en:("Agent failure (" ^ error_code ^ ")")
      in
      let incidents, _ =
        Incidents.push ~occurred_at_unix:ev.at_unix ~source ~summary
          ~detail:error ~status:Health.Resolved m.incidents
      in
      let infra =
        Infra_store.push_activity
          {
            at_unix = ev.at_unix;
            kind = Infra_store.Activity_agent_core;
            keeper = ev.agent;
            summary = "agent_failed: " ^ error_code;
            detail = Some error;
          }
          m.infra
      in
      ({ m with incidents; infra }, [])
  | Wire_observer.Relay_subscription_loss { source_id; dropped_count; _ } ->
      let infra =
        m.infra
        |> Infra_store.record_stream_gap dropped_count
        |> Infra_store.push_activity
             {
               at_unix = ev.at_unix;
               kind = Infra_store.Activity_stream_gap;
               keeper = ev.agent;
               summary =
                 Printf.sprintf "relay loss on %s (%d dropped)" source_id
                   dropped_count;
               detail = None;
             }
      in
      let incidents, _ =
        Incidents.push ~occurred_at_unix:ev.at_unix ~source:Health.Source_stream
          ~summary:
            (Say.make
               ~ko:(Printf.sprintf "스트림 유실 %d건 (%s)" dropped_count source_id)
               ~en:(Printf.sprintf "Stream gap %d (%s)" dropped_count source_id))
          ~detail:
            (Printf.sprintf "Relay subscription loss on %s: %d events dropped"
               source_id dropped_count)
          ~status:Health.Resolved m.incidents
      in
      ({ m with infra; incidents }, [])
  | Wire_observer.Agent_input_required { request_id; question; _ } ->
      let infra =
        Infra_store.push_activity
          {
            at_unix = ev.at_unix;
            kind = Infra_store.Activity_agent_core;
            keeper = ev.agent;
            summary = "input_required: " ^ request_id;
            detail = Some question;
          }
          m.infra
      in
      ( { m with infra }
      , [
          get_cmd m.epoch
            (Cmd.Get_asks { keeper = None; include_resolved = false });
        ] )
  | Wire_observer.Telemetry ->
      (* Provider streaming telemetry (first chunk, stream summary) arrives
         several times a minute and no TUI view reads it, so it is not pushed
         into the activity log. *)
      (m, [])
  | Wire_observer.Tool_called
  | Wire_observer.Tool_completed
  | Wire_observer.Turn_started
  | Wire_observer.Turn_ready
  | Wire_observer.Turn_completed
  | Wire_observer.Agent_started
  | Wire_observer.Agent_completed _
  | Wire_observer.Agent_yielded _
  | Wire_observer.Tool_approval_completed
  | Wire_observer.Agent_core_other _ ->
      let summary =
        match ev.tool with Some tool -> "tool: " ^ tool | None -> "agent_core"
      in
      let infra =
        Infra_store.push_activity
          {
            at_unix = ev.at_unix;
            kind = Infra_store.Activity_agent_core;
            keeper = ev.agent;
            summary;
            detail = ev.task;
          }
          m.infra
      in
      ({ m with infra }, [])

let apply_observer_event (m : Model.t) = function
  | Wire_observer.Observation_changed payload ->
      apply_observation_changed m payload
  | Wire_observer.Dataset_changed ds -> apply_dataset_invalidation m ds
  | Wire_observer.Agent_core ev -> apply_agent_core m ev
  | Wire_observer.Keeper_heartbeat { keeper; phase; in_turn; at_unix; _ } ->
      let fleet =
        Fleet_store.apply_heartbeat ~keeper ~phase ~in_turn ~at_unix m.fleet
      in
      ({ m with fleet }, [])
  | Wire_observer.Keeper_turn_complete { keeper; turn; model; at_unix; _ } ->
      let summary =
        match turn, model with
        | Some n, Some mdl -> Printf.sprintf "turn #%d complete (%s)" n mdl
        | Some n, None -> Printf.sprintf "turn #%d complete" n
        | None, Some mdl -> "turn complete (" ^ mdl ^ ")"
        | None, None -> "turn complete"
      in
      let infra =
        Infra_store.push_activity
          {
            at_unix;
            kind = Infra_store.Activity_turn_complete;
            keeper = Some keeper;
            summary;
            detail = None;
          }
          m.infra
      in
      ({ m with infra }, [ get_cmd m.epoch Cmd.Get_dashboard_shell ])
  | Wire_observer.Keeper_tool_call { keeper; tool; at_unix; _ } ->
      let infra =
        Infra_store.push_activity
          {
            at_unix;
            kind = Infra_store.Activity_tool_call;
            keeper = Some keeper;
            summary = "tool: " ^ tool;
            detail = None;
          }
          m.infra
      in
      ({ m with infra }, [])
  | Wire_observer.Keeper_chat_queue_changed keeper ->
      let queue = Fleet_store.chat_queue_for ~keeper m.fleet in
      let queue = { queue with read = Observed.mark_stale queue.read } in
      let next = { m with fleet = Fleet_store.set_chat_queue ~keeper queue m.fleet } in
      let reads =
        if Option.equal Nav.equal_overlay m.nav.overlay (Some (Nav.Queue_context Nav.Drawer_queue))
           && Option.equal String.equal (Model.target_keeper m) (Some keeper)
        then [get_cmd m.epoch (Cmd.Get_chat_queue { keeper })] else []
      in
      (next, reads @ View_fetches.chat_status_fetches ~keeper next)
  | Wire_observer.Keeper_chat_appended { keeper; _ } ->
      let fleet = Fleet_store.mark_chat_history_stale ~keeper m.fleet in
      let viewing_chat = is_viewing_keeper_chat ~keeper m in
      let has_pending = Drafts.has_unreconciled_tx_for ~keeper m.drafts in
      let cmds =
        if viewing_chat || has_pending then
          [
            get_cmd m.epoch
              (Cmd.Get_chat_history { keeper; limit = Some 80; cursor = None });
          ]
        else []
      in
      ({ m with fleet }, cmds)
  | Wire_observer.Keeper_chat_stream_frame _ -> (m, [])
  | Wire_observer.Keeper_roster_changed _ ->
      let fleet = Fleet_store.mark_keepers_stale m.fleet in
      ({ m with fleet }, [ get_cmd m.epoch Cmd.Get_keepers_roster ])
  | Wire_observer.Keeper_turn_changed { keeper; preview_only } ->
      let fleet = { m.fleet with turns = Observed.mark_stale m.fleet.turns } in
      let wants_turns =
        match Model.active_dive m with
        | Some (Nav.Dive_keeper { name; _ }) -> String.equal keeper name
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _
            | Nav.Dive_infra _ ) ->
            false
        | None -> (
            match m.nav.workspace with
            | Nav.Keepers -> true
            | Nav.Pulse -> not preview_only
            | Nav.Infra ->
                (not preview_only)
                && Nav.equal_infra_tab m.infra.active_tab
                     Nav.Infra_activity_logs
            | Nav.Work | Nav.Knowledge | Nav.Runtime -> false)
      in
      let cmds =
        if wants_turns then [ get_cmd m.epoch Cmd.Get_keeper_turns ] else []
      in
      ({ m with fleet }, cmds)
  | Wire_observer.Keeper_memory_journal_appended { keeper; _ } ->
      let mark_keeper_slot slots =
        Knowledge_store.String_map.update keeper
          (Option.map Observed.mark_stale)
          slots
      in
      let memory_diffs =
        Knowledge_store.Memory_diff_map.mapi
          (fun (scope_keeper, _) obs ->
            match scope_keeper with
            | None -> Observed.mark_stale obs
            | Some k when String.equal k keeper -> Observed.mark_stale obs
            | Some _ -> obs)
          m.knowledge.memory_diffs
      in
      let knowledge =
        {
          m.knowledge with
          memory_diffs;
          keeper_memory_activity =
            mark_keeper_slot m.knowledge.keeper_memory_activity;
          keeper_memory_facts = mark_keeper_slot m.knowledge.keeper_memory_facts;
          keeper_memory_health =
            Observed.mark_stale m.knowledge.keeper_memory_health;
          memory_os_internals =
            mark_keeper_slot m.knowledge.memory_os_internals;
        }
      in
      let e = m.epoch in
      let cmds =
        if not (is_viewing_memory m) then []
        else
          match active_memory_keeper m with
          | Some kp when String.equal kp keeper ->
              [
                get_cmd e
                  (Cmd.Get_memory_diff
                     { keeper = Some kp; window = knowledge.memory_diff_window });
                get_cmd e
                  (Cmd.Get_keeper_memory_activity { keeper = kp; limit = 50 });
                get_cmd e (Cmd.Get_keeper_memory_facts { keeper = kp });
                get_cmd e (Cmd.Get_keeper_memory_os_internals { keeper = kp });
                get_cmd e (Cmd.Get_keeper_memory_health { keeper = None });
              ]
          | Some _ ->
              [ get_cmd e (Cmd.Get_keeper_memory_health { keeper = None }) ]
          | None ->
              [
                get_cmd e
                  (Cmd.Get_memory_diff
                     { keeper = None; window = knowledge.memory_diff_window });
                get_cmd e (Cmd.Get_keeper_memory_health { keeper = None });
              ]
      in
      ({ m with knowledge }, cmds)
  | Wire_observer.Board_changed _ ->
      apply_dataset_invalidation m Wire_observer.Dataset_board
  | Wire_observer.Approval_changed ev -> (
      match ev with
      | Wire_observer.Approval_queue_changed
      | Wire_observer.Approval_rules_changed
      | Wire_observer.Gate_mode_changed ->
          (m, [ get_cmd m.epoch Cmd.Get_gate_pending ])
      | Wire_observer.Tool_approval_waits_changed _
      | Wire_observer.Tool_approval_mode_changed _ ->
          (m, [ get_cmd m.epoch Cmd.Get_tool_approvals ])
      | Wire_observer.Keeper_asks_changed _ ->
          ( m
          , [
              get_cmd m.epoch
                (Cmd.Get_asks { keeper = None; include_resolved = false });
            ] ))
  | Wire_observer.Fusion_run_status _ ->
      let runtime =
        {
          m.runtime with
          fusion_runs = Observed.mark_stale m.runtime.fusion_runs;
        }
      in
      let cmds =
        match m.nav.workspace with
        | Nav.Runtime -> [ get_cmd m.epoch Cmd.Get_fusion_runs ]
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra -> []
      in
      ({ m with runtime }, cmds)
  | Wire_observer.Gate_connector_changed _ ->
      let runtime =
        { m.runtime with connectors = Observed.mark_stale m.runtime.connectors }
      in
      let cmds =
        match m.nav.workspace with
        | Nav.Runtime -> [ get_cmd m.epoch Cmd.Get_connectors ]
        | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Infra -> []
      in
      ({ m with runtime }, cmds)
  | Wire_observer.Schedule_store_changed ->
      apply_dataset_invalidation m Wire_observer.Dataset_scheduled_automation
  | Wire_observer.Pending_confirms_changed
  | Wire_observer.Goal_projection_changed ->
      ( m
      , [ get_cmd m.epoch Cmd.Get_planning ] )
  | Wire_observer.Runtime_config_changed ->
      apply_dataset_invalidation m Wire_observer.Dataset_runtime_config
  | Wire_observer.Transport_health_snapshot ->
      (m, [ get_cmd m.epoch Cmd.Get_dashboard_shell ])
  | Wire_observer.Ignored_legacy _ | Wire_observer.Other _ -> (m, [])

let apply_sse_event ~now (m : Model.t) = function
  | Msg.Sse_observer_handshake hs ->
      let observer_instance_id =
        match hs.handshake with
        | Some h -> Some h.instance_id
        | None -> m.server_identity.observer_instance_id
      in
      let observer_version, observer_commit =
        match hs.identity with
        | Some id -> (Some id.version, id.binary_commit)
        | None ->
            ( m.server_identity.observer_version
            , m.server_identity.observer_commit )
      in
      let server_identity =
        {
          m.server_identity with
          observer_instance_id;
          observer_version;
          observer_commit;
        }
      in
      let next = { m with server_identity } in
      if hs.needs_cold_resync then
        let next =
          { next with infra = Infra_store.forget_log_cursor next.infra }
          |> Model.mark_all_domains_stale
        in
        (next, View_fetches.bootstrap_fetches next)
      else (next, [])
  | Msg.Sse_observer_delivery delivery -> (
      let freshness =
        match delivery.cursor with
        | Some c -> { m.freshness with last_observer_cursor = Some c }
        | None -> m.freshness
      in
      let m' = { m with freshness } in
      match delivery.decoded with
      | Wire_observer.Event ev -> apply_observer_event m' ev
      | Wire_observer.Undecodable reason ->
          let incidents, _ =
            Incidents.push ~occurred_at_unix:m'.freshness.last_wall_unix
              ~source:Health.Source_stream
              ~summary:
                (Say.make ~ko:"SSE 프레임 디코드 건너뜀"
                   ~en:"Skipped undecodable SSE frame")
              ~detail:reason ~status:Health.Resolved m'.incidents
          in
          ({ m' with incidents }, []))
  | Msg.Sse_fleet ev ->
      let fleet =
        Fleet_store.apply_fleet_stream_event ~observed_at:now ev m.fleet
      in
      ({ m with fleet }, [])
  | Msg.Sse_log_frame frame ->
      ({ m with infra = Infra_store.apply_log_frame frame m.infra }, [])
  | Msg.Sse_models_metrics_snapshot snap ->
      ( {
          m with
          runtime =
            Runtime_store.apply_models_metrics ~observed_at:now snap m.runtime;
        }
        |> Model.sync_effective_scorecard ~now
      , [] )
  | Msg.Sse_tool_series series ->
      let runtime =
        Runtime_store.apply_tool_series ~observed_at:now series m.runtime
      in
      let infra =
        if m.infra.sandboxes_fallback_404 then
          let keepers =
            match Observed.to_option m.fleet.keepers with Some ks -> ks | None -> []
          in
          Infra_store.apply_sandboxes_fallback ~observed_at:now
            ~wall_unix:m.freshness.last_wall_unix ~keepers
            ~sandbox_profiles:(Fleet_store.String_map.bindings m.fleet.sandbox_profiles)
            ~tool_series_totals:(Runtime_store.tool_series_totals runtime)
            m.infra
        else m.infra
      in
      ({ m with runtime; infra }, [])

let apply_sse_freshness ~now ~stream ~freshness (m : Model.t) =
  match stream with
  | Subscriptions.Stream_model_metrics
  | Subscriptions.Stream_tool_metrics_series
  | Subscriptions.Stream_logs _
    when not
           (Option.equal Subscriptions.equal_stream_kind
              (Subscriptions.view_scoped_stream m)
              (Some stream)) ->
      (m, [])
  | Subscriptions.Stream_observer
  | Subscriptions.Stream_fleet
  | Subscriptions.Stream_model_metrics
  | Subscriptions.Stream_tool_metrics_series
  | Subscriptions.Stream_logs _ -> (
      let updated_freshness =
        match stream with
        | Subscriptions.Stream_observer ->
            { m.freshness with observer = freshness }
        | Subscriptions.Stream_fleet -> { m.freshness with fleet = freshness }
        | Subscriptions.Stream_model_metrics
        | Subscriptions.Stream_tool_metrics_series
        | Subscriptions.Stream_logs _ ->
            { m.freshness with view_stream = Some freshness }
      in
      let next = { m with freshness = updated_freshness } in
      match freshness with
      | Health.Workspace_mismatch { expected_instance; observed_instance } ->
          Update_http.handle_workspace_mismatch ~now
            ~expected:(Some expected_instance) ~observed:(Some observed_instance)
            ~message:"SSE stream reported 409 workspace_mismatch" next
      | Health.Connecting
      | Health.Live _
      | Health.Reconnecting _
      | Health.Stale _
      | Health.Disconnected _ ->
          (next, []))

let allow_stream_takeover ~keeper ~request_id (m : Model.t) =
  match Fleet_store.String_map.find_opt keeper m.fleet.chat_streams with
  | None -> true
  | Some b when String.equal b.request_id request_id -> false
  | Some b -> (
      let inc_is_terminal =
        match
          List.find_opt
            (fun (tx : Drafts.pending_message) ->
              String.equal tx.request_id request_id)
            m.drafts.pending_txs
        with
        | Some { state = Drafts.Delivered | Drafts.No_operation_record | Drafts.Failed_retryable _; _ } ->
            true
        | Some
            {
              state =
                ( Drafts.Queued
                | Drafts.Sending
                | Drafts.Pending_processing
                | Drafts.Confirming_delivery
                | Drafts.Interrupting );
              _;
            }
        | None ->
            false
      in
      if inc_is_terminal then false
      else
        let cur_pos =
          Drafts.tx_position_for_keeper ~keeper ~request_id:b.request_id m.drafts
        in
        let inc_pos =
          Drafts.tx_position_for_keeper ~keeper ~request_id m.drafts
        in
        match cur_pos, inc_pos with
        | Some cp, Some ip -> ip > cp
        | None, Some _ -> true
        | Some _, None -> false
        | None, None -> not b.active)

let apply_chat_stream_chunk ~now ~keeper ~request_id ~is_btw ~chunk (m : Model.t)
    =
  if is_btw then
    let drafts =
      match chunk with
      | Wire_fleet.Chunk_run_started _ ->
          Drafts.reset_btw_run ~request_id m.drafts
      | Wire_fleet.Chunk_runtime_attempt_started _ ->
          Drafts.retire_btw_attempt ~request_id m.drafts
      | Wire_fleet.Chunk_text_delta { delta; owner; _ } ->
          Drafts.append_btw_delta ~owner ~request_id ~delta m.drafts
      | Wire_fleet.Chunk_reply_details { reply; _ } ->
          if String.equal (String.trim reply) "" then m.drafts
          else Drafts.finish_btw ~request_id ~reply m.drafts
      | Wire_fleet.Chunk_turn_done { reply = Some reply; _ } ->
          Drafts.finish_btw ~request_id ~reply m.drafts
      | Wire_fleet.Chunk_turn_done { reply = None; _ } ->
          Drafts.finalize_btw_eof ~request_id m.drafts
      | Wire_fleet.Chunk_error { message; _ } ->
          Drafts.fail_btw ~request_id ~reason:message m.drafts
      | Wire_fleet.Chunk_accepted _
      | Wire_fleet.Chunk_thinking_delta _
      | Wire_fleet.Chunk_thinking_snapshot _
      | Wire_fleet.Chunk_model_content _
      | Wire_fleet.Chunk_model_response_stop _
      | Wire_fleet.Chunk_tool_start _
      | Wire_fleet.Chunk_tool_args _
      | Wire_fleet.Chunk_tool_block_end _
      | Wire_fleet.Chunk_tool_end _
      | Wire_fleet.Chunk_tool_quarantined _
      | Wire_fleet.Chunk_ignored ->
          m.drafts
    in
    ({ m with drafts }, [])
  else
    let allow_takeover = allow_stream_takeover ~keeper ~request_id m in
    let fleet =
      Fleet_store.apply_chat_stream_chunk ~allow_takeover ~keeper ~request_id
        chunk m.fleet
    in
    let drafts, cmds =
      match chunk with
      | Wire_fleet.Chunk_accepted
          { operation_id; state; interactive_outcome; _ } ->
          let d0 =
            match interactive_outcome with
            | Some Wire_fleet.Interactive_stale_control ->
                Drafts.downgrade_mode_to_follow_up ~request_id m.drafts
            | Some
                ( Wire_fleet.Interactive_applied
                | Wire_fleet.Interactive_paused
                | Wire_fleet.Interactive_replayed )
            | None ->
                m.drafts
          in
          let d1, extra_cmds =
            match state with
            | Keeper_chat_operation.State_name.Queued ->
                ( Drafts.mark_queued ~now ~request_id
                    ~operation_id:(Some operation_id) d0
                , [ get_cmd m.epoch Cmd.Get_keeper_turns ] )
            | Keeper_chat_operation.State_name.Running ->
                ( Drafts.mark_accepted ~now ~request_id
                    ~operation_id:(Some operation_id) d0
                , [ get_cmd m.epoch Cmd.Get_keeper_turns ] )
            | Keeper_chat_operation.State_name.Succeeded | Keeper_chat_operation.State_name.Cancelled ->
                let d_conf =
                  Drafts.mark_accepted ~now ~request_id
                    ~operation_id:(Some operation_id) d0
                  |> Drafts.mark_confirming ~now ~request_id
                in
                ( d_conf
                , [
                    get_cmd m.epoch
                      (Cmd.Get_chat_history
                         { keeper; limit = Some 80; cursor = None });
                  ] )
            | Keeper_chat_operation.State_name.Failed ->
                let d_fail =
                  Drafts.mark_accepted ~now ~request_id
                    ~operation_id:(Some operation_id) d0
                  |> Drafts.mark_failed_retryable ~now ~request_id
                       ~reason:"operation failed"
                in
                ( d_fail
                , [
                    get_cmd m.epoch
                      (Cmd.Get_chat_history
                         { keeper; limit = Some 80; cursor = None });
                  ] )
          in
          (d1, extra_cmds)
      | Wire_fleet.Chunk_run_started { operation_id }
      | Wire_fleet.Chunk_runtime_attempt_started { operation_id }
      | Wire_fleet.Chunk_text_delta { operation_id; _ }
      | Wire_fleet.Chunk_thinking_delta { operation_id; _ }
      | Wire_fleet.Chunk_thinking_snapshot { operation_id; _ }
      | Wire_fleet.Chunk_tool_start { operation_id; _ }
      | Wire_fleet.Chunk_tool_args { operation_id; _ }
      | Wire_fleet.Chunk_tool_end { operation_id; _ }
      | Wire_fleet.Chunk_reply_details { operation_id; _ } ->
          (Drafts.mark_accepted ~now ~request_id ~operation_id m.drafts, [])
      | Wire_fleet.Chunk_turn_done _ ->
          ( Drafts.mark_confirming ~now ~request_id m.drafts
          , [
              get_cmd m.epoch
                (Cmd.Get_chat_history
                   { keeper; limit = Some 80; cursor = None });
            ] )
      | Wire_fleet.Chunk_error { message; _ } ->
          let tx = Drafts.pending_txs_for_keeper ~keeper m.drafts
            |> List.find_opt (fun (tx : Drafts.pending_message) -> String.equal tx.request_id request_id) in
          let history = get_cmd m.epoch
            (Cmd.Get_chat_history { keeper; limit = Some 80; cursor = None }) in
          if Option.fold ~none:false ~some:(fun (tx : Drafts.pending_message) -> tx.state = Drafts.No_operation_record) tx then
            (m.drafts, [])
          else (match Option.bind tx (fun (tx : Drafts.pending_message) -> tx.operation_id) with
           | Some operation_id ->
               (Drafts.mark_confirming ~now ~request_id m.drafts,
                [history; get_cmd m.epoch (Cmd.Get_chat_status { keeper; operation_id })])
           | None ->
               (Drafts.mark_failed_retryable ~now ~request_id ~reason:message m.drafts, [history]))
      | Wire_fleet.Chunk_model_content _
      | Wire_fleet.Chunk_model_response_stop _
      | Wire_fleet.Chunk_tool_quarantined _
      | Wire_fleet.Chunk_tool_block_end _
      | Wire_fleet.Chunk_ignored -> (m.drafts, [])
    in
    ({ m with fleet; drafts }, cmds)

let apply_chat_stream_decode_warning ~now:_ ~keeper ~request_id ~reason
    (m : Model.t) =
  let incidents, _ =
    Incidents.push ~occurred_at_unix:m.freshness.last_wall_unix
      ~source:Health.Source_stream
      ~summary:
        (Say.make ~ko:"대화 스트림 프레임 디코드 경고"
           ~en:"Chat stream frame decode warning")
      ~detail:(Printf.sprintf "%s (%s): %s" keeper request_id reason)
      ~status:Health.Resolved m.incidents
  in
  ({ m with incidents }, [])

(* The server that answered is not the instance the request went to: a
   reattach POST that reached a restarted server. *)
let refused_by_another_instance = function
  | Msg.Workspace_mismatch _ -> true
  | Msg.Transport _ | Msg.Http_error _ | Msg.Decode_error _ -> false

let apply_chat_stream_done ~now ~keeper ~request_id ~is_btw ~result (m : Model.t)
    =
  if is_btw then
    match result with
    | Ok () ->
        ({ m with drafts = Drafts.finalize_btw_eof ~request_id m.drafts }, [])
    | Error err ->
        let drafts =
          Drafts.fail_btw ~request_id ~reason:(Msg.http_error_detail err) m.drafts
        in
        Update_http.record_http_incident ~now
          ~source:(Health.Source_keeper keeper)
          ~context:(Say.make ~ko:"/btw 질의" ~en:"/btw query")
          err { m with drafts }
  else
    let hist_cmd epoch =
      get_cmd epoch
        (Cmd.Get_chat_history { keeper; limit = Some 80; cursor = None })
    in
    let tx =
      List.find_opt (fun (tx : Drafts.pending_message) ->
        String.equal tx.request_id request_id && String.equal tx.keeper keeper) m.drafts.pending_txs in
    let tx_state_opt = Option.map (fun (tx : Drafts.pending_message) -> tx.state) tx in
    let accepted = Option.exists (fun (tx : Drafts.pending_message) -> Option.is_some tx.operation_id) tx in
    let reads epoch =
      match tx with
      | None -> [hist_cmd epoch]
      | Some tx ->
          let operation_id = Option.value tx.operation_id ~default:request_id in
          [hist_cmd epoch; get_cmd epoch (Cmd.Get_chat_status { keeper; operation_id })] in
    let context = Say.make ~ko:"키퍼 대화 전송" ~en:"Keeper chat stream" in
    match result with
    | Ok () ->
        let fleet =
          Fleet_store.finish_chat_stream ~keeper ~request_id ~error:None m.fleet
        in
        (match tx_state_opt with
        | Some (Drafts.Delivered | Drafts.No_operation_record) -> ({ m with fleet }, [])
        | Some (Drafts.Failed_retryable _) ->
            ({ m with fleet }, [ hist_cmd m.epoch ])
        | Some
            ( Drafts.Queued
            | Drafts.Sending
            | Drafts.Pending_processing
            | Drafts.Confirming_delivery
            | Drafts.Interrupting )
        | None ->
            let drafts = Drafts.mark_confirming ~now ~request_id m.drafts in
            ({ m with fleet; drafts }, reads m.epoch))
    | Error err when Option.equal Drafts.equal_tx_state tx_state_opt (Some Drafts.No_operation_record) ->
        let fleet = Fleet_store.finish_chat_stream ~keeper ~request_id ~error:None m.fleet in
        Update_http.record_http_incident ~now ~source:(Health.Source_keeper keeper) ~context err { m with fleet }
    | Error err
      when refused_by_another_instance err && accepted
      ->
        (* The old instance accepted the request, and only the reattach was
           refused. The 409 moves the epoch, so [Update.step] ends the buffer
           and sends the request to [Confirming_delivery], where the next
           epoch's history settles it. Marking it failed here would keep a
           failure row beside a reply the history delivers. *)
        Update_http.record_http_incident ~now
          ~source:(Health.Source_keeper keeper) ~context err m
    | Error err ->
        let refusal =
          match err with
          | Msg.Http_error { status; _ } -> status >= 400 && status < 500
          | Msg.Workspace_mismatch _ -> true
          | Msg.Transport _ | Msg.Decode_error _ -> false
        in
        let rejected = refusal && not (accepted) in
        let detail = Msg.http_error_detail err in
        let fleet = Fleet_store.finish_chat_stream ~keeper ~request_id
            ~error:(if rejected then Some detail else None) m.fleet in
        let drafts =
          if rejected then Drafts.mark_failed_retryable ~now ~request_id ~reason:detail m.drafts
          else Drafts.mark_confirming ~now ~request_id m.drafts in
        let next, inc_cmds = Update_http.record_http_incident ~now
            ~source:(Health.Source_keeper keeper) ~context err { m with fleet; drafts } in
        (next, inc_cmds @ (if rejected then [hist_cmd next.epoch] else reads next.epoch))

let apply_stream_gap ~now dropped (m : Model.t) =
  if dropped <= 0 then (m, [])
  else
    let infra =
      m.infra
      |> Infra_store.record_stream_gap dropped
      |> Infra_store.push_activity
           {
             at_unix = m.freshness.last_wall_unix;
             kind = Infra_store.Activity_stream_gap;
             keeper = None;
             summary = Printf.sprintf "UI bus dropped %d stream events" dropped;
             detail = None;
           }
    in
    let summary =
      Say.make
        ~ko:(Printf.sprintf "스트림 버퍼 초과로 %d건 생략됨" dropped)
        ~en:(Printf.sprintf "Stream buffer overflow: %d events skipped" dropped)
    in
    let incidents, _ =
      Incidents.push ~occurred_at_unix:m.freshness.last_wall_unix
        ~source:Health.Source_stream ~summary
        ~detail:
          (Printf.sprintf "Bounded UI bus evicted %d unread stream items"
             dropped)
        ~status:Health.Resolved m.incidents
    in
    let next =
      { m with infra; incidents }
      |> Model.with_toast ~now ~level:Model.Toast_warning summary
    in
    (next, [])
