let command_plane_help_http_json () =
  let str_list values = `List (List.map (fun value -> `String value) values) in
  let concept ~id ~title ~summary =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("summary", `String summary);
      ]
  in
  let step ~id ~title ~tool ~summary ~success_signals ~pitfalls =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("tool", `String tool);
        ("summary", `String summary);
        ("success_signals", str_list success_signals);
        ("pitfalls", str_list pitfalls);
      ]
  in
  let path ~id ~title ~summary ~when_to_use ~steps =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("summary", `String summary);
        ("when_to_use", `String when_to_use);
        ("steps", `List steps);
      ]
  in
  let tool_group ~id ~title ~description ~tools =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("description", `String description);
        ("tools", str_list tools);
      ]
  in
  let workload_template ~id ~title ~summary ~workload_profile ~default_stage
      ~autonomy_target ~recommended_tools =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("summary", `String summary);
        ("workload_profile", `String workload_profile);
        ("default_stage", `String default_stage);
        ("autonomy_target", `String autonomy_target);
        ("recommended_tools", str_list recommended_tools);
      ]
  in
  let pitfall ~id ~title ~symptom ~why ~fix_tool ~fix_summary =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("symptom", `String symptom);
        ("why", `String why);
        ("fix_tool", `String fix_tool);
        ("fix_summary", `String fix_summary);
      ]
  in
  let example ~id ~title ~path_id ~transport ~request ~response ~notes =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("path_id", `String path_id);
        ("transport", `String transport);
        ("request", request);
        ("response", response);
        ("notes", str_list notes);
      ]
  in
  `Assoc
    [
      ("version", `String "1");
      ("generated_at", `String (Types.now_iso ()));
      ( "docs",
        `List
          [
            `Assoc
              [
                ("title", `String "Command Plane Runbook");
                ("path", `String "docs/COMMAND-PLANE-RUNBOOK.md");
              ];
            `Assoc
              [
                ("title", `String "Benchmark Runbook");
                ("path", `String "docs/BENCHMARK-RUNBOOK.md");
              ];
            `Assoc
              [
                ("title", `String "Supervisor Mode");
                ("path", `String "docs/SUPERVISOR-MODE.md");
              ];
            `Assoc
              [
                ("title", `String "Swarm Delivery Runbook");
                ("path", `String "docs/SWARM-DELIVERY-RUNBOOK.md");
              ];
            `Assoc
              [
                ("title", `String "Model Front Door");
                ("path", `String "llms.txt");
              ];
            `Assoc
              [
                ("title", `String "Model Front Door Full");
                ("path", `String "llms-full.txt");
              ];
          ] );
      ( "concepts",
        `List
          [
            concept ~id:"namespace" ~title:"Project Scope"
              ~summary:
                "Shared project coordination scope. Use masc_start as the primary onboarding entrypoint. Historical room naming remains only as a compatibility alias, and masc_set_room now selects only the project coordination root while runtime state still lives in the flattened default scope under .masc/.";
            concept ~id:"task" ~title:"Task"
              ~summary:
                "Backlog work item. Claim semantics differ by tool: masc_transition(action=claim) leaves planning current_task unset, while masc_claim_next auto-binds it in current builds.";
            concept ~id:"operation" ~title:"Operation"
              ~summary:
                "Managed operation record on the experimental command-plane compatibility lane.";
            concept ~id:"detachment" ~title:"Detachment"
              ~summary:
                "Scheduler/runtime view of active work under an operation. Use it to inspect progress, liveness, and runtime binding.";
            concept ~id:"policy_decision" ~title:"Policy Decision"
              ~summary:
                "Pending approval item. Cross-platoon moves and disruptive actions stop here until approved or denied.";
            concept ~id:"trace" ~title:"Trace"
              ~summary:
                "End-to-end lineage of operation, checkpoint, dispatch, and policy events.";
          ] );
      ( "golden_paths",
        `List
          [
            path ~id:"namespace_task_hygiene" ~title:"Project Scope / Task Hygiene"
              ~summary:
                "Minimal MCP sequence before doing any real work in the shared project scope."
              ~when_to_use:
                "Use this before ordinary implementation work and before any optional managed-operation experiment."
              ~steps:
                [
                  step ~id:"start" ~title:"Start project onboarding" ~tool:"masc_start"
                    ~summary:
                      "Preferred front door. Sets the project coordination root, joins the default shared scope, and can optionally create+claim a task in one call."
                    ~success_signals:
                      [ "coordination root resolves to the project root"; "agent can appear in masc_status immediately after onboarding" ]
                    ~pitfalls:
                      [ "calling masc_set_room only changes project scope; it does not complete the full onboarding flow";
                        "omitting task_title means you still need a later claim/create step" ];
                  step ~id:"status" ~title:"Verify project state" ~tool:"masc_status"
                    ~summary:
                      "Confirm the shared project scope is healthy, your agent is visible, and the backlog is in the expected state."
                    ~success_signals:
                      [ "agent visible in masc_status"; "project agent roster includes your agent" ]
                    ~pitfalls:
                      [ "if you only called masc_set_room, or masc_start did not complete successfully, your agent may not be joined and will not appear for scheduling" ];
                  step ~id:"claim" ~title:"Claim or create work" ~tool:"masc_transition"
                    ~summary:
                      "Claim a specific task with masc_transition(action=claim), or use masc_claim_next when any queued task is acceptable."
                    ~success_signals:
                      [ "task assignee is your agent"; "task status becomes claimed/in_progress" ]
                    ~pitfalls:
                      [ "masc_transition(action=claim) does not set planning current_task"; "masc_claim_next auto-binds current_task in current builds" ];
                  step ~id:"set-task" ~title:"Bind current task" ~tool:"masc_plan_set_task"
                    ~summary:
                      "Set the current session task pointer when the claim path did not auto-bind it, especially after masc_transition(action=claim)."
                    ~success_signals:
                      [ "masc_plan_get_task returns the claimed task id" ]
                    ~pitfalls:
                      [ "dashboard can show claimed task and missing current_task at the same time after manual claim paths" ];
                  step ~id:"heartbeat" ~title:"Refresh presence" ~tool:"masc_heartbeat"
                    ~summary:
                      "Update liveness before or during long-running work."
                    ~success_signals:
                      [ "agent status stays active/busy"; "last_seen remains fresh" ]
                    ~pitfalls:
                      [ "without heartbeat an otherwise healthy agent looks zombie/stale" ];
                ];
            path ~id:"cpv2_benchmark" ~title:"Managed Operation Compatibility Lane"
              ~summary:
                "Experimental managed-operation path for benchmark topology checks and command-plane compatibility coverage."
              ~when_to_use:
                "Use this only when you explicitly need managed operations, detachments, and policy gates. It is not the default delivery front door."
              ~steps:
                [
                  step ~id:"define-units" ~title:"Define hierarchy" ~tool:"masc_unit_define"
                    ~summary:
                      "Create managed company/platoon/squad/agent units with policy and budget envelopes."
                    ~success_signals:
                      [ "masc_observe_topology shows managed units"; "capacity rows appear for units" ]
                    ~pitfalls:
                      [ "missing leaders or empty live rosters block operation start" ];
                  step ~id:"start-operation" ~title:"Start operation" ~tool:"masc_operation_start"
                    ~summary:
                      "Create the managed benchmark operation and bind it to the target unit."
                    ~success_signals:
                      [ "operation appears in masc_observe_operations"; "trace_id is issued" ]
                    ~pitfalls:
                      [ "starting directly on a frozen or killed unit fails" ];
                  step ~id:"dispatch" ~title:"Materialize detachments" ~tool:"masc_dispatch_tick"
                    ~summary:
                      "Run the scheduler/reconciler to create or update detachments."
                    ~success_signals:
                      [ "operation moves from planned to active runtime" ]
                    ~pitfalls:
                      [ "active op with zero detachments usually means tick has not been run yet" ];
                  step ~id:"observe" ~title:"Observe runtime" ~tool:"masc_observe_operations"
                    ~summary:
                      "Inspect operations, topology, alerts, and trace events while the operation runs."
                    ~success_signals:
                      [ "heartbeat_deadline and last_progress_at advance"; "alerts/traces explain stalls or approvals" ]
                    ~pitfalls:
                      [ "pending approvals stop cross-platoon movement until policy action happens" ];
                  step ~id:"approve" ~title:"Handle approval queue" ~tool:"masc_policy_approve"
                    ~summary:
                      "Approve or deny pending policy decisions for strict actions."
                    ~success_signals:
                      [ "decision leaves pending state"; "next tick applies the move or leaves a denial trace" ]
                    ~pitfalls:
                      [ "dispatch_rebalance can legitimately return pending_approval" ];
                  step ~id:"checkpoint" ~title:"Checkpoint and finalize" ~tool:"masc_operation_checkpoint"
                    ~summary:
                      "Record durable state, then finish with masc_operation_finalize when done."
                    ~success_signals:
                      [ "checkpoint_ref stored on operation"; "finalized operation is completed in operations view" ]
                    ~pitfalls:
                      [ "stop/finalize without checkpoint loses resume breadcrumbs" ];
                ];
            path ~id:"supervisor_session" ~title:"Supervisor / Session Runtime"
              ~summary:
                "Guided intervention loop for supervised implementation sessions."
              ~when_to_use:
                "Use this when a human or supervisor agent steers an execution session instead of running the managed-operation compatibility lane directly."
              ~steps:
                [
                  step ~id:"snapshot" ~title:"Read operator snapshot" ~tool:"masc_operator_snapshot"
                    ~summary:"Read state first from the small operator surface."
                    ~success_signals:[ "summary/full snapshot available" ]
                    ~pitfalls:[ "this is the default delivery path; do not force managed-operation terminology unless the caller explicitly needs it" ];
                  step ~id:"intervene" ~title:"Preview intervention" ~tool:"masc_operator_action"
                    ~summary:"Prepare a small intervention such as team_note or team_task_inject."
                    ~success_signals:[ "preview token or immediate action result returned" ]
                    ~pitfalls:[ "disruptive actions require confirm" ];
                  step ~id:"confirm" ~title:"Confirm disruptive action" ~tool:"masc_operator_confirm"
                    ~summary:"Execute the previewed intervention once a human approves it."
                    ~success_signals:[ "intervention trace appended"; "session reflects the change" ]
                    ~pitfalls:[ "do not mix this path with managed-operation commands in the same explanation unless the caller explicitly needs both" ];
                ];
          ] );
      ( "workload_templates",
        `List
          [
            workload_template ~id:"coding_team" ~title:"Coding Team"
              ~summary:
                "Planner -> implementer -> verifier/reviewer style team. Defaults to coding_task/decompose."
              ~workload_profile:"coding_task" ~default_stage:"decompose"
              ~autonomy_target:"L3_Guided -> L5_Independent"
              ~recommended_tools:
                [ "masc_operation_start"; "masc_operator_digest"; "masc_operation_finalize" ];
            workload_template ~id:"research_team" ~title:"Research Team"
              ~summary:
                "Collect -> verify -> curate -> rank -> audit style team. Defaults to research_pipeline/normalize."
              ~workload_profile:"research_pipeline" ~default_stage:"normalize"
              ~autonomy_target:"L3_Guided -> L5_Independent"
              ~recommended_tools:
                [ "masc_operation_start"; "masc_dispatch_tick"; "masc_observe_operations"; "masc_operation_finalize" ];
            workload_template ~id:"ops_governance_team" ~title:"Ops / Governance Team"
              ~summary:
                "Audit, intervention, approval, and operator-heavy team. Defaults to research_pipeline/audit for decision-heavy work."
              ~workload_profile:"research_pipeline" ~default_stage:"audit"
              ~autonomy_target:"L2_Suggestive -> L4_Autonomous"
              ~recommended_tools:
                [ "masc_operation_start"; "masc_operator_snapshot"; "masc_policy_approve" ];
          ] );
      ( "tool_groups",
        `List
          [
            tool_group ~id:"namespace-task" ~title:"Namespace / Task Hygiene"
              ~description:
                "Core namespace/task tools every session should use before higher-level workflows."
              ~tools:
                [ "masc_start"; "masc_join"; "masc_status"; "masc_transition"; "masc_claim_next"; "masc_plan_set_task"; "masc_heartbeat" ];
            tool_group ~id:"cpv2-core" ~title:"Managed Operation Core"
              ~description:
                "Canonical swarm/benchmark tool family."
              ~tools:
                [ "masc_unit_define"; "masc_operation_start"; "masc_dispatch_tick"; "masc_observe_topology"; "masc_observe_operations"; "masc_observe_alerts"; "masc_observe_traces"; "masc_policy_status"; "masc_policy_approve"; "masc_policy_deny"; "masc_operation_checkpoint"; "masc_operation_finalize" ];
            tool_group ~id:"supervisor" ~title:"Supervisor Session"
              ~description:
                "Small operator loop for intervention-oriented sessions."
              ~tools:
                [ "masc_operator_snapshot"; "masc_operator_action"; "masc_operator_confirm" ];
          ] );
      ( "pitfalls",
        `List
          [
            pitfall ~id:"project-scope-default-namespace" ~title:"Project scope flattens to default namespace"
              ~symptom:"You point masc_start or masc_set_room at a worktree but the visible coordination state still behaves like the project root."
              ~why:"Current builds flatten coordination to the default namespace under the project root; worktrees are code-isolation only."
              ~fix_tool:"masc_start"
              ~fix_summary:"Treat worktrees as code-isolation only. Use masc_start against the project root, then reason about shared coordination state in the default namespace.";
            pitfall ~id:"claimed-not-current" ~title:"Claimed task is not current task"
              ~symptom:"Task is claimed, but planning/log tools still act like no current task is selected."
              ~why:"Some claim paths only mutate backlog ownership. In current builds masc_transition(action=claim) still requires an explicit current_task bind."
              ~fix_tool:"masc_plan_set_task"
              ~fix_summary:"Call masc_plan_set_task after claim paths that did not auto-bind current_task.";
            pitfall ~id:"heartbeat-stale" ~title:"Agent looks stale"
              ~symptom:"Your agent appears inactive/zombie during long work even though the process is alive."
              ~why:"Heartbeat/liveness was not refreshed recently."
              ~fix_tool:"masc_heartbeat"
              ~fix_summary:"Call masc_heartbeat periodically during long operations or before observing state.";
            pitfall ~id:"no-detachments" ~title:"Operation exists but no detachments"
              ~symptom:"Operation is visible, but detachments list is empty."
              ~why:"The scheduler has not reconciled yet, or the target unit is blocked."
              ~fix_tool:"masc_dispatch_tick"
              ~fix_summary:"Run masc_dispatch_tick, then inspect topology/capacity or policy queue if detachments still do not appear.";
            pitfall ~id:"pending-approval" ~title:"Dispatch is blocked by approval"
              ~symptom:"dispatch_rebalance or related control action returns pending_approval."
              ~why:"Strict cross-platoon or disruptive action requires a policy decision."
              ~fix_tool:"masc_policy_approve"
              ~fix_summary:"Review the pending decision and approve/deny it before running tick again.";
            pitfall ~id:"http-actor-defaults-dashboard"
              ~title:"HTTP actor defaults to dashboard"
              ~symptom:"Operation or trace entries show actor=dashboard even though a human or agent initiated the request."
              ~why:"Mutating HTTP endpoints use dashboard as the fallback actor unless x-masc-agent, x-masc-agent-name, or agent_name is provided."
              ~fix_tool:"masc_operation_start"
              ~fix_summary:"Send x-masc-agent-name (or x-masc-agent) on mutating HTTP requests when actor attribution matters.";
          ] );
      ( "examples",
        `List
          [
            example ~id:"join-namespace" ~title:"Join namespace for task hygiene"
              ~path_id:"namespace_task_hygiene" ~transport:"mcp"
              ~request:
                (`Assoc
                   [
                     ("tool", `String "masc_start");
                     ("arguments",
                      `Assoc
                        [
                          ("path", `String "/workspace/project");
                          ("task_title", `String "Audit namespace consistency");
                        ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("agent", `String "codex-...");
                     ("status", `String "started");
                     ("project", `String "default");
                   ])
              ~notes:
                [ "Response is trimmed to canonical fields."; "Use masc_status next to confirm visibility." ];
            example ~id:"start-op" ~title:"Start benchmark operation"
              ~path_id:"cpv2_benchmark" ~transport:"http"
              ~request:
                (`Assoc
                   [
                     ("method", `String "POST");
                     ("path", `String "/api/v1/command-plane/operations");
                     ("headers", `Assoc [ ("x-masc-agent-name", `String "codex") ]);
                     ("body",
                      `Assoc
                        [
                          ("assigned_unit_id", `String "squad-research-normalize");
                          ("objective", `String "Normalize and verify latest AI research items");
                          ("policy_class", `String "guarded");
                        ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("status", `String "ok");
                     ("result",
                      `Assoc
                        [
                          ("operation_id", `String "op-...");
                          ("trace_id", `String "trace-...");
                          ("status", `String "active");
                        ]);
                   ])
              ~notes:
                [
                  "Run dispatch/tick after operation start to materialize detachments.";
                  "Without x-masc-agent-name (or x-masc-agent), actor attribution falls back to dashboard.";
                ];
            example ~id:"approval" ~title:"Approve strict action"
              ~path_id:"cpv2_benchmark" ~transport:"mcp"
              ~request:
                (`Assoc
                   [
                     ("tool", `String "masc_policy_approve");
                     ("arguments",
                      `Assoc [ ("decision_id", `String "decision-...") ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("status", `String "ok");
                     ("decision_id", `String "decision-...");
                     ("approval_state", `String "approved");
                   ])
              ~notes:
                [ "Follow with masc_dispatch_tick to apply the approved move." ];
          ] );
    ]

let command_plane_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
