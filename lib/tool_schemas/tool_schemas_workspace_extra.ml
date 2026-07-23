(** MCP tool schemas for shared Goal planning and lifecycle operations. *)

open Masc_domain

let goal_phase_enum = List.map Goal_phase.to_string Goal_phase.all

let goal_transition_action_enum =
  List.map Goal_phase.action_to_string Goal_phase.all_actions
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
        "Create or update Goal metadata and parent linkage. Use masc_goal_transition for lifecycle changes."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ "id", `Assoc [ "type", `String "string" ]
                ; "title", `Assoc [ "type", `String "string" ]
                ; "metric", `Assoc [ "type", `String "string" ]
                ; "target_value", `Assoc [ "type", `String "string" ]
                ; "due_date", `Assoc [ "type", `String "string" ]
                ; "priority", `Assoc [ "type", `String "integer" ]
                ; "parent_goal_id", `Assoc [ "type", `String "string" ]
                ] )
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "masc_goal_transition"
    ; description =
        "Apply an explicit Goal lifecycle transition. request_complete completes the Goal directly."
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
