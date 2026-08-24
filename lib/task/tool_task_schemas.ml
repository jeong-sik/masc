(** Tool_task_schemas — JSON schema definitions for task tools.

    Pure data module containing MCP tool schemas for all task operations.

    @since God file decomposition — extracted from tool_task.ml *)

let masc_add_task_name =
  Tool_name.Task_name.to_string Tool_name.Task_name.Add_task

let handoff_context_description =
  "Typed handoff payload. 'summary' is REQUIRED (non-empty) for exit-class \
     actions (submit_for_verification / done / release / cancel). On \
     action='submit_for_verification', every 'evidence_refs' entry must use \
     'artifact:<producer-root-relative-path>' for a bounded file snapshot or \
     'note:<text>' for narrative evidence. A public URL inside a note (a PR, \
     a CI run) can be fetched live by the verifier itself; materialize \
     volatile contents as an artifact when they must be pinned at submit \
     time. Commits and traces are not fetched. Bare relative paths \
     and absolute host paths are persisted as typed invalid references. The \
     list itself is optional. Example: {\"summary\": \"tests green, local proof saved\", \
     \"evidence_refs\": [\"artifact:artifacts/proof.json\"]}."

let schemas : Masc_domain.tool_schema list = [
  {
    name = masc_add_task_name;
    description = Printf.sprintf
      "Add a new task to the backlog for agents to claim. \
Task contracts provide completion/evidence context to the judge; they do not select a completion lane. \
Write one when you know what done looks like: none is derived from the title, so a task without a contract reaches the judge with no criteria and is judged against a standard the worker never saw. \
Every task must be submitted for an out-of-band system LLM completion-authority verdict. \
submit_for_verification creates an asynchronous review state that no agent or Keeper can claim. The application-owned system LLM agent reads the immutable submitted-evidence snapshot and commits the typed verdict; an authenticated human operator is the separate HITL path. \
To re-run completed work, create a new task with predecessor_task_id instead of touching the done one. \
Priority 1=urgent, 5=low (default 3). \
Returns task-XXX ID for tracking. \
Example: %s({title: 'Fix login bug', priority: 1, description: 'Users cannot login with SSO'})"
      masc_add_task_name;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Task title");
        ]);
        ("priority", `Assoc [
          ("type", `String "integer");
          ("description", `String "Priority 1-5 (1=highest)");
          ("default", `Int 3);
        ]);
        ("description", `Assoc [
          ("type", `String "string");
          ("description", `String "Task description");
        ]);
        ("goal_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional structured goal link for rollups. If omitted, the task is created unscoped (goalless); pass goal_id explicitly to link it to a goal.");
        ]);
        ("predecessor_task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional re-run provenance link (RFC-0323): the terminal (done/cancelled) task this one re-runs. Rejected if the id is unknown or the predecessor is not terminal. To re-run completed work, create a new task with this link instead of re-claiming the old one.");
        ]);
        ("contract", `Assoc [
          ("type", `String "object");
          ("additionalProperties", `Bool false);
          ("description", `String "What counts as done for this task, and what evidence shows it. Recorded at creation and never rewritten. Omit it and the task carries no criteria.");
          ("properties", `Assoc [
            ("strict", `Assoc [ ("type", `String "boolean") ]);
            ("completion_contract", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("required_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("inspect_gate_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("verify_gate_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
          ]);
        ]);
      ]);
      ("required", `List [`String "title"]);
    ];
  };
  {
    name = "masc_batch_add_tasks";
    description = Printf.sprintf
      "Add multiple tasks in one call (more efficient than repeated %s). \
Use when: loading sprint backlog, importing from JIRA, creating related tasks. \
A task carries a completion contract only if you write one; none is derived from the title. \
Each task gets unique ID (task-XXX). Atomic: all succeed or all fail. \
Example: masc_batch_add_tasks({tasks: [{title: 'Task A', priority: 2}, {title: 'Task B', goal_id: 'g-124'}]})"
      masc_add_task_name;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tasks", `Assoc [
          ("type", `String "array");
          ("maxItems", `Int 20);
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("title", `Assoc [
                ("type", `String "string");
                ("description", `String "Task title");
              ]);
              ("priority", `Assoc [
                ("type", `String "integer");
                ("description", `String "Priority 1-5 (1=highest)");
                ("default", `Int 3);
              ]);
              ("description", `Assoc [
                ("type", `String "string");
                ("description", `String "Task description");
              ]);
              ("goal_id", `Assoc [
                ("type", `String "string");
                ("description", `String "Optional structured goal link for rollups. If omitted, the task is created unscoped (goalless); pass goal_id explicitly to link it to a goal.");
              ]);
              ("contract", `Assoc [
                ("type", `String "object");
                ("additionalProperties", `Bool false);
                ("properties", `Assoc [
                  ("strict", `Assoc [ ("type", `String "boolean") ]);
                  ("completion_contract", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("required_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("inspect_gate_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                  ("verify_gate_evidence", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ]);
              ]);
            ]);
            ("required", `List [`String "title"]);
          ]);
          ("description", `String "List of tasks to add");
        ]);
      ]);
      ("required", `List [`String "tasks"]);
    ];
  };
  Tool_task_schemas_toml.task_history;
  Tool_task_schemas_toml.tasks;

  Tool_task_schemas_toml.update_priority;
  {
    name = "masc_transition";
    description =
      "Move a Task through the agent actions claim, start, submit_for_verification, cancel, or release. Ownership is exact and cannot be overridden by caller arguments. Completion requires the assignee to submit evidence, then wait for an authenticated human-operator or typed auto-judge verdict outside this tool. Direct done and approve/reject are deliberately unavailable here. Supports expected_version CAS.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID (e.g., 'task-001')");
        ]);
        (* The enum below is the list; spelling it out again in prose was a
           second copy that drifted from what the tool accepts. It presented
           [done] as one ordinary option among six, and [done] is refused from
           every status a Keeper can be working: the lifecycle answers
           [Verification_submission_required] from Claimed and InProgress and
           [Invalid_transition] from the rest, leaving only the Done->Done
           no-op. Measured over the live tool log: 111 calls passed
           action="done", 70 errored and the other 41 were that no-op — no
           state change, ever. This says what each action does instead of
           restating their names. *)
        ("action", `Assoc [
          ("type", `String "string");
          ("description", `String "Which transition to apply. claim takes an unclaimed Task; start moves your claim into progress; release hands it back with a required handoff_context.summary; cancel ends it with a reason. Completion goes through submit_for_verification with evidence in notes — done is refused from every working status and cannot complete a Task here.");
          ("enum", `List (List.map (fun action -> `String action) Masc_domain.valid_task_action_strings));
        ]);
        ("expected_version", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional CAS guard (current backlog.version). Transition fails if mismatched");
        ]);
        ("notes", `Assoc [
          ("type", `String "string");
          ("description", `String "Evidence summary for submit_for_verification, or completion notes for done");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Cancellation reason (used with action='cancel')");
        ]);
        ("handoff_context", `Assoc [
          ("type", `String "object");
          ("description", `String handoff_context_description);
          ("properties", `Assoc [
            ("summary", `Assoc [
              ("type", `String "string");
              ("minLength", `Int 1);
              ("description", `String "REQUIRED. Non-empty one-line summary of current state at release time. Example: 'tests green, PR #123 pending review'.");
            ]);
            ("reason", `Assoc [
              ("type", `String "string");
              ("description", `String "Why the task is being released (blocker, handoff, pause).");
            ]);
            ("next_step", `Assoc [
              ("type", `String "string");
              ("description", `String "What the next owner should do first.");
            ]);
            ("failure_mode", `Assoc [
              ("type", `String "string");
              ("description", `String "If released due to failure, describe the failure mode.");
            ]);
            ("reclaim_policy", `Assoc [
              ("type", `String "string");
              ("enum", `List [ `String "allow_reclaim"; `String "block_reclaim" ]);
              ("description", `String "Explicit reclaim policy. Omit or use allow_reclaim for normal handoff. Use block_reclaim only for deterministic terminal mismatches that must require operator review.");
            ]);
            ("evidence_refs", `Assoc [
              ("type", `String "array");
              ("items", `Assoc [ ("type", `String "string"); ("minLength", `Int 1) ]);
              ("description", `String "Typed verifier evidence. Use artifact:<producer-root-relative-path> for files or note:<text> for narrative, commit, trace, receipt, or URL evidence. Bare and absolute paths are invalid.");
            ]);
          ]);
          ("required", `List [`String "summary"]);
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "action"]);
    ];
  };
  (* RFC-0267 Phase 2: assign an existing goalless task to a goal. *)
  Tool_task_schemas_toml.task_set_goal;
]
