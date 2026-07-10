include Dashboard_execution_helpers

let execution_smoke_fixture_json () =
  let generated_at = Masc_domain.now_iso () in
  let command_handoff =
    handoff_json
      ~surface:"command"
      ~command_surface:"operations"
      ~operation_id:"op-runtime-001"
      ~label:"작전 원인 보기"
      ~target_type:"operation"
      ~target_id:"op-runtime-001"
      ~focus_kind:"operation"
      ()
  in
  let operation_handoff =
    handoff_json
      ~surface:"command"
      ~command_surface:"operations"
      ~operation_id:"op-runtime-002"
      ~label:"작전 원인 보기"
      ~target_type:"operation"
      ~target_id:"op-runtime-002"
      ~focus_kind:"operation"
      ()
  in
  `Assoc
    [
      ("generated_at", `String generated_at);
      ( "status",
        `Assoc
          [
            ("workspace_root", `String "/tmp/masc-execution-fixture");
            ("cluster", `String "fixture");
            ("project", `String "execution-smoke");
            ("tempo_interval_s", `Float 300.0);
            ("paused", `Bool false);
            ("version", `String Version.version);
          ] );
      ( "execution_queue",
        `List
          [
            `Assoc
              [
                ("id", `String "operation-op-runtime-002");
                ("kind", `String "operation");
                ("severity", `String "warn");
                ("status", `String "active");
                ("summary", `String "Waiting on upstream checkpoint before verify stage");
                ("target_type", `String "operation");
                ("target_id", `String "op-runtime-002");
                ("linked_session_id", `Null);
                ("linked_operation_id", `String "op-runtime-002");
                ("last_seen_at", `String generated_at);
                ("top_handoff", operation_handoff);
                ("intervene_handoff", `Null);
                ("command_handoff", operation_handoff);
              ];
            `Assoc
              [
                ("id", `String "operation-op-runtime-001");
                ("kind", `String "operation");
                ("severity", `String "bad");
                ("status", `String "active");
                ("summary", `String "Runtime squad needs trace review before verify proceeds");
                ("target_type", `String "operation");
                ("target_id", `String "op-runtime-001");
                ("linked_session_id", `Null);
                ("linked_operation_id", `String "op-runtime-001");
                ("last_seen_at", `String generated_at);
                ("top_handoff", command_handoff);
                ("intervene_handoff", `Null);
                ("command_handoff", command_handoff);
              ];
          ] );
      ( "priority_queue",
        `List
          [
            `Assoc
              [
                ("id", `String "operation-op-runtime-002");
                ("kind", `String "operation");
                ("tone", `String "warn");
                ("title", `String "op-runtime-002");
                ("subtitle", `String "Waiting on upstream checkpoint before verify stage");
                ("timestamp", `String generated_at);
                ("target_type", `String "operation");
                ("target_id", `String "op-runtime-002");
              ];
            `Assoc
              [
                ("id", `String "operation-op-runtime-001");
                ("kind", `String "operation");
                ("tone", `String "bad");
                ("title", `String "op-runtime-001");
                ("subtitle", `String "Runtime squad needs trace review before verify proceeds");
                ("timestamp", `String generated_at);
                ("target_type", `String "operation");
                ("target_id", `String "op-runtime-001");
              ];
          ] );
      ( "operation_briefs",
        `List
          [
            `Assoc
              [
                ("operation_id", `String "op-runtime-001");
                ("objective", `String "Validate local64 swarm role coverage");
                ("status", `String "active");
                ("stage", `String "verify");
                ("assigned_unit_id", `String "squad-runtime");
                ("assigned_unit_label", `String "Runtime Squad");
                ("linked_session_id", `Null);
                ("linked_detachment_id", `Null);
                ("blocker_summary", `String "Runtime squad needs trace review before verify proceeds");
                ("search_status", `String "blocked");
                ("next_tool", `String "masc_operator_snapshot");
                ("updated_at", `String generated_at);
                ("top_handoff", command_handoff);
                ("command_handoff", command_handoff);
              ];
            `Assoc
              [
                ("operation_id", `String "op-runtime-002");
                ("objective", `String "Audit dependency blockers before verify stage");
                ("status", `String "active");
                ("stage", `String "verify");
                ("assigned_unit_id", `String "squad-review");
                ("assigned_unit_label", `String "Review Squad");
                ("linked_session_id", `Null);
                ("linked_detachment_id", `Null);
                ("blocker_summary", `String "Waiting on upstream checkpoint before verify stage");
                ("search_status", `String "blocked");
                ("next_tool", `String "masc_status");
                ("updated_at", `String generated_at);
                ("top_handoff", operation_handoff);
                ("command_handoff", operation_handoff);
              ];
          ] );
      ( "worker_support_briefs",
        `List
          [
            `Assoc
              [
                ("name", `String "local-alpha");
                ("agent_name", `String "local-alpha");
                ("status", `String "busy");
                ("tone", `String "ok");
                ("state", `String "working");
                ("note", `String "Task and live signal aligned");
                ("focus", `String "Validate local64 swarm role coverage");
                ("last_signal_at", `String generated_at);
                ("last_signal_age_sec", `Int 18);
                ("signal_truth", `String "live");
                ("evidence_source", `String "message");
                ("active_task_count", `Int 1);
                ("related_session_id", `Null);
                ("related_operation_id", `String "op-runtime-001");
                ("emoji", `String "🤖");
                ("koreanName", `String "local-alpha");
                ("model", `String "runtime");
                ("recent_output_preview", `String "manager synthesized runtime visibility and handed next checks to beta");
                ("recent_event", `String "manager handoff");
              ];
            `Assoc
              [
                ("name", `String "local-beta");
                ("agent_name", `String "local-beta");
                ("status", `String "active");
                ("tone", `String "warn");
                ("state", `String "quiet");
                ("note", `String "Execution looks quiet for too long");
                ("focus", `String "Inspect secondary runtime health");
                ("last_signal_at", `String "2026-03-11T09:15:00Z");
                ("last_signal_age_sec", `Int 780);
                ("signal_truth", `String "stale");
                ("evidence_source", `String "message");
                ("active_task_count", `Int 1);
                ("related_session_id", `String "ts-execution-fixture-001");
                ("related_operation_id", `String "op-runtime-001");
                ("emoji", `String "🤖");
                ("koreanName", `String "local-beta");
                ("model", `String (Runtime_provider_binding.local_runtime_label "fixture-claude"));
                ("recent_output_preview", `String "secondary runtime is quiet; watching queue depth before escalation");
                ("recent_event", `String "secondary runtime probe");
              ];
            `Assoc
              [
                ("name", `String "local-gamma");
                ("agent_name", `String "local-gamma");
                ("status", `String "idle");
                ("tone", `String "ok");
                ("state", `String "watching");
                ("note", `String "Standing by for the next task");
                ("focus", `String "Idle / waiting for assignment");
                ("last_signal_at", `String generated_at);
                ("last_signal_age_sec", `Int 12);
                ("signal_truth", `String "live");
                ("evidence_source", `String "presence");
                ("active_task_count", `Int 0);
                ("related_session_id", `String "ts-execution-fixture-002");
                ("related_operation_id", `String "op-runtime-003");
                ("emoji", `String "🤖");
                ("koreanName", `String "local-gamma");
                ("model", `String (Runtime_provider_binding.local_runtime_label "fixture-model-b"));
                ("recent_output_preview", `Null);
                ("recent_event", `String "idle");
              ];
          ] );
      ( "worker_briefs",
        `List
          [
            `Assoc
              [
                ("name", `String "local-alpha");
                ("agent_name", `String "local-alpha");
                ("status", `String "busy");
                ("tone", `String "ok");
                ("state", `String "working");
                ("note", `String "Task and live signal aligned");
                ("focus", `String "Validate local64 swarm role coverage");
                ("last_signal_at", `String generated_at);
                ("last_signal_age_sec", `Int 18);
                ("signal_truth", `String "live");
                ("evidence_source", `String "message");
                ("active_task_count", `Int 1);
              ];
            `Assoc
              [
                ("name", `String "local-beta");
                ("agent_name", `String "local-beta");
                ("status", `String "active");
                ("tone", `String "warn");
                ("state", `String "quiet");
                ("note", `String "Execution looks quiet for too long");
                ("focus", `String "Inspect secondary runtime health");
                ("last_signal_at", `String "2026-03-11T09:15:00Z");
                ("last_signal_age_sec", `Int 780);
                ("signal_truth", `String "stale");
                ("evidence_source", `String "message");
                ("active_task_count", `Int 1);
              ];
          ] );
      ( "continuity_briefs",
        `List
          [
            `Assoc
              [
                ("name", `String "dm-keeper");
                ("agent_name", `String "dm-keeper");
                ("status", `String "active");
                ("tone", `String "bad");
                ("state", `String "critical");
                ("note", `String "핸드오프 임박");
                ("focus", `String "masc-keeper-autonomy");
                ("last_signal_at", `String generated_at);
                ("last_autonomous_action_at", `String generated_at);
                ("generation", `Int 2);
                ("turn_count", `Int 84);
                ("context_ratio", `Float 0.91);
                ("continuity", `String "Gen 2 · Turns 84 · Goals 2");
                ("lifecycle", `String "handoff-imminent");
                ("related_session_id", `Null);
                ("model", `String (Runtime_provider_binding.local_runtime_label "fixture-claude"));
                ("emoji", `String "🤖");
                ("koreanName", `String "dm-keeper");
                ("recent_input_preview", `String "Player asked to continue the next scene without breaking continuity");
                ("recent_output_preview", `String "Prepared the next scene transition and handoff summary");
                ("recent_tool_names", `List [ `String "masc_keeper_status"; `String "masc_board_post" ]);
                ("latest_tool_names", `List [ `String "masc_board_post" ]);
                ("latest_tool_call_count", `Int 1);
                ("tool_audit_source", `String "heartbeat_result");
                ("tool_audit_at", `String generated_at);
                ("last_proactive_preview", `String "Summarized the next scene handoff");
                ("skill_route_summary", `String "scene-director · +1 · judgment");
              ];
          ] );
      ( "offline_worker_briefs",
        `List
          [
            `Assoc
              [
                ("name", `String "local-delta");
                ("agent_name", `String "local-delta");
                ("status", `String "inactive");
                ("tone", `String "bad");
                ("state", `String "offline");
                ("note", `String "Offline or inactive");
                ("focus", `String "Recover worker before reassigning");
                ("last_signal_at", `String "2026-03-11T08:55:00Z");
                ("last_signal_age_sec", `Int 1200);
                ("signal_truth", `String "absent");
                ("evidence_source", `String "none");
                ("active_task_count", `Int 0);
                ("related_session_id", `String "ts-execution-fixture-001");
                ("related_operation_id", `String "op-runtime-001");
                ("emoji", `String "🤖");
                ("koreanName", `String "local-delta");
                ("model", `String (Runtime_provider_binding.local_runtime_label "fixture-model-b"));
                ("recent_output_preview", `Null);
                ("recent_event", `String "missing heartbeat");
              ];
          ] );
      ( "agents",
        `List
          [
            `Assoc
              [
                ("name", `String "local-alpha");
                ("agent_type", `String "llama");
                ("status", `String "busy");
                ("current_task", `String "Validate local64 swarm role coverage");
                ("session_bound_at", `String generated_at);
                ("last_seen", `String generated_at);
                ("capabilities", `List [ `String "manager"; `String "local64" ]);
                ("emoji", `String "🤖");
                ("koreanName", `String "local-alpha");
              ];
            `Assoc
              [
                ("name", `String "local-beta");
                ("agent_type", `String "llama");
                ("status", `String "active");
                ("current_task", `String "Inspect secondary runtime health");
                ("session_bound_at", `String generated_at);
                ("last_seen", `String "2026-03-11T09:15:00Z");
                ("capabilities", `List [ `String "metacog"; `String "local64" ]);
                ("emoji", `String "🤖");
                ("koreanName", `String "local-beta");
              ];
            `Assoc
              [
                ("name", `String "local-gamma");
                ("agent_type", `String "llama");
                ("status", `String "idle");
                ("current_task", `Null);
                ("session_bound_at", `String generated_at);
                ("last_seen", `String generated_at);
                ("capabilities", `List [ `String "executor"; `String "local64" ]);
                ("emoji", `String "🤖");
                ("koreanName", `String "local-gamma");
              ];
            `Assoc
              [
                ("name", `String "local-delta");
                ("agent_type", `String "llama");
                ("status", `String "inactive");
                ("current_task", `Null);
                ("session_bound_at", `String generated_at);
                ("last_seen", `String "2026-03-11T08:55:00Z");
                ("capabilities", `List [ `String "observer"; `String "local64" ]);
                ("emoji", `String "🤖");
                ("koreanName", `String "local-delta");
              ];
          ] );
      ( "tasks",
        `List
          [
            `Assoc
              [
                ("id", `String "task-local64-001");
                ("title", `String "Validate local64 swarm role coverage");
                ("description", `String "manager census and runtime visibility");
                ("status", `String "in_progress");
                ("priority", `Int 1);
                ("assignee", `String "local-alpha");
                ("created_at", `String generated_at);
              ];
            `Assoc
              [
                ("id", `String "task-local64-002");
                ("title", `String "Inspect secondary runtime health");
                ("description", `String "probe quiet worker path");
                ("status", `String "claimed");
                ("priority", `Int 2);
                ("assignee", `String "local-beta");
                ("created_at", `String generated_at);
              ];
            `Assoc
              [
                ("id", `String "task-local64-003");
                ("title", `String "Recover worker before reassigning");
                ("description", `String "pending observer replacement");
                ("status", `String "todo");
                ("priority", `Int 2);
                ("assignee", `Null);
                ("created_at", `String generated_at);
              ];
          ] );
      ( "messages",
        `List
          [
            `Assoc
              [
                ("from", `String "local-alpha");
                ("content", `String "manager synthesized runtime visibility and handed next checks to beta");
                ("timestamp", `String generated_at);
                ("seq", `Int 1);
              ];
            `Assoc
              [
                ("from", `String "local-beta");
                ("content", `String "secondary runtime is quiet; watching queue depth before escalation");
                ("timestamp", `String "2026-03-11T09:15:00Z");
                ("seq", `Int 2);
              ];
          ] );
      ( "keepers",
        `List
          [
            `Assoc
              [
                ("name", `String "dm-keeper");
                ("agent_name", `String "dm-keeper");
                ("status", `String "active");
                ("generation", `Int 2);
                ("turn_count", `Int 84);
                ("context_ratio", `Float 0.91);
                ("context_tokens", `Int 245000);
                ("last_autonomous_action_at", `String generated_at);
                ("autonomous_action_count", `Int 11);
                ("active_goal_ids", `List [ `String "goal-runtime"; `String "goal-story" ]);
                ("model", `String "runtime");
                ("active_model", `String "runtime");
                ("goal", `String "masc-keeper-autonomy");
                ("updated_at", `String generated_at);
                ("created_at", `String generated_at);
              ];
          ] );
    ]
