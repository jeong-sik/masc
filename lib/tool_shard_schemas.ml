(** Tool_shard_schemas - MCP tool schema definitions for shard management.
    Extracted from tool_shard.ml to reduce godfile size.
*)

(** {1 MCP Schemas} *)

let schemas : Masc_domain.tool_schema list =
  [ { name = "masc_tool_grant"
    ; description =
        "Grant a capability group to an agent. Groups: base (core), board, filesystem, \
         shell, voice, taskboard, coding, autoresearch."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "agent_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Agent to grant shard to"
                      ] )
                ; ( "shard_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Group to grant: base, board, filesystem, shell, voice, \
                             taskboard, coding, autoresearch" )
                      ] )
                ] )
          ; "required", `List [ `String "agent_name"; `String "shard_name" ]
          ]
    }
  ; { name = "masc_tool_revoke"
    ; description =
        "Revoke a capability group from an agent. Cannot revoke 'base' (always present)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "agent_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Agent to revoke shard from"
                      ] )
                ; ( "shard_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Group to revoke (must be removable). One of: board, \
                             filesystem, shell, voice, taskboard, coding, autoresearch" )
                      ] )
                ] )
          ; "required", `List [ `String "agent_name"; `String "shard_name" ]
          ]
    }
  ; { name = "masc_tool_list"
    ; description = "List all available capability groups with their tool counts."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ]
;;

