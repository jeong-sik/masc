(** Tool_shard_types_schemas_taskboard — task/broadcast tool schemas (keeper_tasks_*, keeper_task_*, keeper_broadcast). *)

let taskboard_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_tasks_list"
    ; description =
        "List backlog tasks. Rows carry id, title, priority, created_at, status, \
         assignee; projection=full adds description, files, contract, \
         handoff_context, execution_links. awaiting_verification means the task \
         awaits the completion-authority verdict and no Keeper can claim it; \
         never Read producer sandbox paths."
    ; input_schema =
        `Assoc
                  [ "type", `String "object"
                  ; ( "properties"
                      , `Assoc
                          [ ( "status"
                  , `Assoc
                      [ "type", `String "string"
                      ; (* Derived from the Masc_domain.task_status Variant SSOT. *)
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
                      [ (* #18472 widening removed: a multi-type schema trips
                           agent-core boundary fail-closed and crashes the keeper cycle.
                           Runtime coerces string->int, so strict integer is safe. *)
                        ( "type", `String "integer" )
                      ; "description", `String "Max tasks to return (default: 50)"
                      ; "minimum", `Int 1
                      ; "maximum", `Int 100
                      ; "default", `Int 50
                              ] )
                          ; ( "if_revision"
                            , `Assoc
                                [ "type", `String "string"
                                ; ( "description"
                                  , `String
                                      "Optional producer revision from the previous keeper_tasks_list snapshot; matching revisions return unchanged." )
                                ] )
                          ; ( "projection"
                            , `Assoc
                                [ "type", `String "string"
                                ; "enum", `List [ `String "compact"; `String "full" ]
                                ; "default", `String "compact"
                                ] )
                          ] )
          ]
    }
  ; { name = "keeper_tasks_audit"
    ; description =
        "Find tasks whose exact assignee identity is absent from explicit active \
         workspace/session membership. Returns the task status and assignee. This \
         audit is read-only: it never releases or reassigns tasks."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "limit"
                  , `Assoc
                      [ (* #18472 widening removed: a multi-type schema trips
                           agent-core boundary fail-closed and crashes the keeper cycle.
                           Runtime coerces string->int, so strict integer is safe. *)
                        ( "type", `String "integer" )
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
         announcements, or warnings."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Broadcast body text"
                      ; "minLength", `Int 1
                      ] )
                ; ( "task_cache_subject_agent"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Agent whose current-task cache was observed; supply together with task_cache_task_id" )
                      ; "minLength", `Int 1
                      ] )
                ; ( "task_cache_task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Task ID observed in the subject agent cache; supply together with task_cache_subject_agent" )
                      ; "minLength", `Int 1
                      ] )
                ] )
          ; "required", `List [ `String "content" ]
          ]
    }
  ; { name = "keeper_task_claim"
    ; description =
        "Claim MASC backlog work. With no task_id, claims the next eligible \
         unclaimed todo task that matches your capabilities. \
         awaiting_verification tasks are pending a verdict from the system LLM agent \
         at the completion-authority boundary and are not claimable Keeper work. \
         Never Read producer sandbox paths directly. \
         With task_id, claims that exact task when a user, mention, board item, or \
         keeper_tasks_list row identifies it; an awaiting_verification task returns \
         the typed pending-verdict refusal. If you already own another \
         Claimed/InProgress task, finish it with keeper_task_done or explicitly \
         release it first; keeper_task_claim does not auto-release active work."
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
        "Submit your claimed task for verification with a result summary and \
         trusted evidence_refs. The task must be claimed by you. This does not \
         make the task done: it moves to awaiting_verification and waits for a \
         completion authority's verdict, which no Keeper can produce. It also \
         does not hold your next claim while it waits. Every evidence_refs \
         entry must be artifact:<producer-root-relative-path> or note:<text>; \
         this tool refuses any other form at submit. Only an artifact: path is \
         opened and snapshotted for the reviewer — a note: entry is text the \
         reviewer reads but cannot inspect. Pure-placeholder results ('done', \
         'ok', etc.) are rejected."
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
                            "Trusted references substantiating completion. Every \
                             entry must be artifact:<producer-root-relative-path> \
                             or note:<text>; nothing else can be read back at \
                             review, so this tool refuses it here rather than \
                             letting the reviewer see missing evidence. An \
                             artifact: path is opened and snapshotted, and that \
                             is what satisfies the completion gate. A Board post \
                             id, a commit, a PR number, or a file:// URI is \
                             narrative until something opens it: pass it as \
                             note:<text> next to an artifact: entry, never on \
                             its own." )
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
         claim."
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
