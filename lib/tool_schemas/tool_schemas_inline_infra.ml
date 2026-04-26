open Types

(** Issue #8520: hand-mirrored from [Mcp_session.valid_action_strings].
    [masc_tool_schemas] only depends on [masc_types], so it cannot
    derive directly. The sync regression test in [test_types.ml ::
    mcp_session_action_ssot] catches drift. Same shape as
    #8467/#8480/#8484/#8490/#8493/#8506/#8513 mirror+sync pattern. *)
let mcp_session_action_enum_strings = [ "get"; "create"; "list"; "cleanup"; "remove" ]

let schemas : tool_schema list =
  [ (* masc_mcp_session *)
    { name = "masc_mcp_session"
    ; description =
        "Create, get, list, or remove MCP sessions that track client context across \
         requests. Use when managing multi-request workflows that need session \
         continuity (Mcp-Session-Id header). Pair with masc_subscription to receive \
         session-scoped event notifications."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "action"
                  , `Assoc
                      [ "type", `String "string"
                      ; (* Issue #8520: derive from local mirror tracking
             [Mcp_session.valid_action_strings]. *)
                        ( "enum"
                        , `List
                            (List.map
                               (fun s -> `String s)
                               mcp_session_action_enum_strings) )
                      ; "description", `String "Session action"
                      ] )
                ; ( "session_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Session ID (for get/remove)"
                      ] )
                ; ( "agent_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Agent name (for create)"
                      ] )
                ] )
          ; "required", `List [ `String "action" ]
          ]
    }
  ; (* masc_cancellation, masc_subscription, masc_progress,
     masc_governance_set removed: pruned from surfaces *)

    (* masc_approval_get *)
    { name = "masc_approval_get"
    ; description =
        "Operator/admin-only detail view. Fetch one pending HITL approval by id, \
         including the full input JSON. Use after finding an approval id in the \
         dashboard or pending approval queue when the preview is insufficient for an \
         operator decision. Requires the same privileged approval surface as resolving \
         an approval."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Pending approval id, for example appr_abc123def456" )
                      ] )
                ] )
          ; "required", `List [ `String "id" ]
          ]
    }
  ; (* masc_spawn *)
    { name = "masc_spawn"
    ; description =
        "Spawn an agent process (claude, gemini, codex, or llama) to execute a task. Use \
         when you need another agent to work in parallel on a subtask. For llama, \
         provide model explicitly. Pair with masc_add_task to create the task first."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "agent_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Agent to spawn: 'claude', 'gemini', 'codex', or custom \
                             command" )
                      ] )
                ; ( "model"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Explicit model id. Required when agent_name='llama'." )
                      ] )
                ; ( "prompt"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "The task/prompt to send to the agent"
                      ] )
                ; ( "timeout_seconds"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "default", `Int 300
                      ; ( "description"
                        , `String "Max execution time in seconds (default: 300)" )
                      ] )
                ; ( "working_dir"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Working directory for the agent (optional)" )
                      ] )
                ] )
          ; "required", `List [ `String "agent_name"; `String "prompt" ]
          ]
    }
  ]
;;
