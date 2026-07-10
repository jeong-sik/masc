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
                      [ (* Issue #18472: wire-format widening — same
                           pattern as PR #19383 on [limit] siblings.
                           The runtime accepts both shapes; strict
                           ["integer"] only fires correction_pipeline. *)
                        ( "type"
                        , `List [ `String "integer"; `String "string" ] )
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
         last_seen. The workspace GC auto-releases orphaned tasks; this audit is read-only."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "limit"
                  , `Assoc
                      [ (* Issue #18472: wire-format widening — bundled
                           with keeper_tasks_list.limit above per
                           RFC-0088 §3 N-of-M avoidance. *)
                        ( "type"
                        , `List [ `String "integer"; `String "string" ] )
                      ; "description", `String "Max orphans to return (default: 20)"
                      ; "minimum", `Int 1
                      ; "maximum", `Int 50
                      ; "default", `Int 20
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_broadcast"
    ; description =
        "Send a message visible to all agents in the MASC workspace. Use for status updates, \
         announcements, warnings, or workspace."
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
        "Claim MASC backlog work. With no task_id, claims the next eligible \
         unclaimed todo task that matches your capabilities. With task_id, claims \
         that exact task when a user, mention, board item, or keeper_tasks_list row \
         identifies it. If you already own another Claimed/InProgress task, finish \
         it with keeper_task_done or explicitly release it first; keeper_task_claim \
         does not auto-release active work. If active_goal_ids are configured, the \
         no-arg claim prefers goal-linked work and only widens when the scoped pool \
         has no eligible task."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional exact task id from keeper_tasks_list, board, mention, or user request" )
                      ; "minLength", `Int 1
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_task_done"
    ; description =
        "Mark your claimed task as complete with a result summary and trusted \
         evidence_refs. The task must be claimed by you. The completion gate \
         accepts task completion only when evidence_refs contains a \
         reviewer-inspectable PR, commit, trace, receipt, or URL reference; \
         pure-placeholder results ('done', 'ok', etc.) are rejected."
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
                ; ( "evidence_refs"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "string" ]
                      ; "minItems", `Int 1
                      ; ( "description"
                        , `String
                            "Trusted references substantiating completion. At least \
                             one reference must validate against local state: an \
                             existing base-path file/file:// URI, local git commit \
                             hash, or .masc trace/turn/receipt ref that resolves on \
                             disk. Result text, URLs, PR numbers, and trace-shaped \
                             labels alone do not satisfy the task-completion gate." )
                      ] )
                ; ( "notes"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Verification handoff notes (>= 20 chars). For \
                             contracted tasks: summarise what changed AND \
                             mention each contract.required_evidence entry \
                             verbatim. Ignored when the task has no contract."
                        )
                      ] )
                ] )
          ; "required", `List [ `String "task_id"; `String "result"; `String "evidence_refs" ]
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
                            "Optional structured goal linkage." )
                      ] )
                ; ( "contract"
                  , `Assoc
                      [ "type", `String "object"
                      ; ( "description"
                        , `String
                            "Optional persisted task contract for deterministic \
                             completion and verification evidence." )
                      ; ( "properties"
                        , `Assoc
                            [ "strict", `Assoc [ "type", `String "boolean" ]
                            ; ( "completion_contract"
                              , `Assoc
                                  [ "type", `String "array"
                                  ; "items", `Assoc [ "type", `String "string" ]
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
