(** MCP tool schemas for shared Goal planning and lifecycle operations. *)

open Masc_domain

let goal_phase_enum = List.map Goal_phase.to_string Goal_phase.all

let goal_transition_action_enum =
  List.map Goal_phase.Public_action.to_string Goal_phase.Public_action.all
;;

let enum_schema ?description values =
  `Assoc
    ([ "type", `String "string"
     ; "enum", `List (List.map (fun value -> `String value) values)
     ]
     @
     match description with
     | Some description -> [ "description", `String description ]
     | None -> [])
;;

let schemas : tool_schema list =
  [ { name = "masc_goal_list"
    ; description =
        "List shared planning goals, optionally filtered by explicit lifecycle phase."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "phase"
                  , enum_schema
                      ~description:"Optional explicit Goal lifecycle phase filter"
                      goal_phase_enum )
                ] )
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "masc_goal_upsert"
    ; description =
        "Create or update Goal metadata and parent linkage. Creation requires a \
         measurable success condition: metric and target_value (RFC-0387 B1). Use \
         masc_goal_transition for lifecycle changes."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ "id", `Assoc [ "type", `String "string" ]
                ; "title", `Assoc [ "type", `String "string" ]
                ; ( "metric"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Required (non-blank) when the upsert creates a new \
                             goal (RFC-0387 B1); optional on update." )
                      ] )
                ; ( "target_value"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Required (non-blank) when the upsert creates a new \
                             goal (RFC-0387 B1); optional on update." )
                      ] )
                ; "due_date", `Assoc [ "type", `String "string" ]
                ; "priority", `Assoc [ "type", `String "integer" ]
                ] )
          ; "additionalProperties", `Bool false
          ]
      (* B1 is NOT expressed in a schema-level [required] array on purpose:
         this one tool serves both create and update, and JSON Schema
         [required] is unconditional — listing metric/target_value there would
         reject every metadata update of an existing goal. The create/update
         split is only decidable against the store, so the handler enforces
         the requirement on the creation branch (Goal_store.upsert_goal,
         inside the write lock). *)
    }
  ; { name = "masc_goal_transition"
    ; description =
        "Apply an explicit Goal lifecycle transition (RFC-0387 stage 2 gate). \
         request_complete no longer completes the Goal directly: it moves \
         executing -> verifying and persists a durable proof request. Verifier \
         verdicts are application-owned typed commits and are deliberately not \
         accepted by this MCP tool. A Goal whose criterion was judged \
         unreachable is refused on request_complete."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ "goal_id", `Assoc [ "type", `String "string" ]
                ; "action", enum_schema goal_transition_action_enum
                ; "note", `Assoc [ "type", `String "string" ]
                ] )
          ; "required", `List [ `String "goal_id"; `String "action" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ]
;;
