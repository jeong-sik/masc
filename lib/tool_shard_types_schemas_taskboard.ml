(** Tool_shard_types_schemas_taskboard — task/broadcast tool schemas (keeper_tasks_*, keeper_task_*, keeper_broadcast). *)

let taskboard_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_tasks_list"
    ; description =
        "List tasks on the MASC backlog. Returns task_id, title, status, assignee, and \
         priority for each task. Use to see what work is available or in progress."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "status"
                  , `Assoc
                      [ "type", `String "string"
                      ; (* Issue #8354: derived from Masc_domain.task_status Variant SSOT.
             Hand-rolled enum used to drop awaiting_verification. *)
                        ( "enum"
                        , `List
                            (List.map
                               (fun s -> `String s)
                               Masc_domain.valid_task_status_strings) )
                      ; "description", `String "Filter by task status"
                      ] )
                ; ( "include_done"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; "description", `String "Include completed tasks (default: false)"
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Max tasks to return (default: 50)"
                      ; "minimum", `Int 1
                      ; "maximum", `Int 100
                      ; "default", `Int 50
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_tasks_audit"
    ; description =
        "Find orphaned tasks: claimed/in_progress tasks assigned to agents that are \
         offline (no heartbeat >10 min). Returns orphan list with assignee and \
         last_seen. Use keeper_task_force_release to reassign orphaned tasks."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Max orphans to return (default: 20)"
                      ; "minimum", `Int 1
                      ; "maximum", `Int 50
                      ; "default", `Int 20
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_task_force_release"
    ; description =
        "Release a stuck task back to Todo status, removing the current assignee. \
         Applies when the assignee is offline (no heartbeat >10 min). Broadcasts the \
         release to the room."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Task ID from keeper_tasks_list or keeper_tasks_audit" )
                      ; "minLength", `Int 1
                      ] )
                ; ( "reason"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Why this task is being released (audit trail)" )
                      ; "minLength", `Int 1
                      ] )
                ] )
          ; "required", `List [ `String "task_id"; `String "reason" ]
          ]
    }
  ; { name = "keeper_task_force_done"
    ; description =
        "Mark a task Done when the assignee completed the work but did not transition it \
         (e.g. went offline after finishing). Broadcasts completion to room."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Task ID from keeper_tasks_list or keeper_tasks_audit" )
                      ; "minLength", `Int 1
                      ] )
                ; ( "notes"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Completion evidence: PR merged, test output, file diff"
                        )
                      ; "minLength", `Int 1
                      ] )
                ] )
          ; "required", `List [ `String "task_id"; `String "notes" ]
          ]
    }
  ; { name = "keeper_broadcast"
    ; description =
        "Send a message visible to all agents in the MASC room. Use for status updates, \
         announcements, warnings, or coordination."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "message"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Message content to broadcast"
                      ; "minLength", `Int 1
                      ] )
                ] )
          ; "required", `List [ `String "message" ]
          ]
    }
  ; { name = "keeper_task_claim"
    ; description =
        "Claim the next unclaimed todo task that matches your capabilities. Returns \
         claimed task details (task_id, title, description) or empty if none available. \
         If active_goal_ids are configured, only tasks linked to those goals are \
         eligible; when that scoped pool has no claimable task for your current \
         capabilities, the claim stops instead of crossing into unrelated goals. \
         Auto-repaired keeper-purpose goals may still fall back to all claimable tasks."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_task_done"
    ; description =
        "Mark your claimed task as complete with a result summary. The task must be \
         claimed by you. Other agents verify completion from the result field."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Task ID returned by keeper_task_claim"
                      ; "minLength", `Int 1
                      ] )
                ; ( "result"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "What was done: files changed, tests run, outcome observed" )
                      ; "minLength", `Int 1
                      ] )
                ] )
          ; "required", `List [ `String "task_id"; `String "result" ]
          ]
    }
  ; { name = "keeper_task_submit_for_verification"
    ; description =
        "Submit your claimed task to verification instead of marking it done directly. \
         Use this after opening a PR or when review evidence must be attached before \
         final approval."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Task ID returned by keeper_task_claim"
                      ; "minLength", `Int 1
                      ] )
                ; ( "notes"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Verification handoff notes: tests run, scope, remaining \
                             review expectations" )
                      ; "minLength", `Int 1
                      ] )
                ; ( "pr_url"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Draft or open PR URL to include in the verification handoff"
                        )
                      ; "minLength", `Int 1
                      ] )
                ] )
          ; "required", `List [ `String "task_id"; `String "notes"; `String "pr_url" ]
          ]
    }
  ; { name = "keeper_task_create"
    ; description =
        "Create a new task on the MASC backlog. The task appears for any keeper to \
         claim. Duplicate titles are rejected automatically (dedup by normalized title)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "title"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Task title: verb + object + scope (e.g. 'Fix CI timeout in \
                             keeper_agent_run.ml')" )
                      ; "minLength", `Int 5
                      ; "maxLength", `Int 200
                      ] )
                ; ( "description"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "What to do, why, and acceptance criteria. Another keeper \
                             reads this to start working." )
                      ; "minLength", `Int 10
                      ] )
                ; ( "priority"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "1=critical 2=high 3=medium 4=low 5=backlog" )
                      ; "minimum", `Int 1
                      ; "maximum", `Int 5
                      ; "default", `Int 3
                      ] )
                ; ( "goal_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional structured goal linkage. Preferred over relying \
                             only on [goal:<id>] in the title." )
                      ] )
                ; ( "contract"
                  , `Assoc
                      [ "type", `String "object"
                      ; ( "description"
                        , `String
                            "Optional persisted task contract. Use required_tools to \
                             prevent routing execution work to keepers without needed \
                             tools." )
                      ; ( "properties"
                        , `Assoc
                            [ "strict", `Assoc [ "type", `String "boolean" ]
                            ; ( "completion_contract"
                              , `Assoc
                                  [ "type", `String "array"
                                  ; "items", `Assoc [ "type", `String "string" ]
                                  ] )
                            ; ( "required_tools"
                              , `Assoc
                                  [ "type", `String "array"
                                  ; "items", `Assoc [ "type", `String "string" ]
                                  ; ( "description"
                                    , `String
                                        "Tool names required to claim this task, e.g. \
                                         keeper_bash or masc_code_git." )
                                  ] )
                            ; ( "required_evidence"
                              , `Assoc
                                  [ "type", `String "array"
                                  ; "items", `Assoc [ "type", `String "string" ]
                                  ] )
                            ; ( "inspect_gate_evidence"
                              , `Assoc
                                  [ "type", `String "array"
                                  ; "items", `Assoc [ "type", `String "string" ]
                                  ] )
                            ; ( "verify_gate_evidence"
                              , `Assoc
                                  [ "type", `String "array"
                                  ; "items", `Assoc [ "type", `String "string" ]
                                  ] )
                            ] )
                      ] )
                ] )
          ; "required", `List [ `String "title"; `String "description" ]
          ]
    }
  ]
;;
