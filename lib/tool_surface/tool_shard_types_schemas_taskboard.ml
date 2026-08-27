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
  ; Tool_shard_types_schemas_taskboard_toml.tasks_audit
  ; Tool_shard_types_schemas_taskboard_toml.broadcast
  ; Tool_shard_types_schemas_taskboard_toml.task_claim
  ; Tool_shard_types_schemas_taskboard_toml.task_done
  ; Tool_shard_types_schemas_taskboard_toml.task_release
  ; Tool_shard_types_schemas_taskboard_toml.task_create
  ]
;;
