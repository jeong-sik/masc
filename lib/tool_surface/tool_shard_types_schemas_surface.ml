(** Tool_shard_types_schemas_surface — keeper_surface_* tool schemas
    (RFC-0223 P3). *)

let surface_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_surface_read"
    ; description =
        "Read recent conversation from one connected surface lane (dashboard, \
         discord, slack, or another connector label) with speaker identity \
         and a derived participant roster. Use after Connected Surfaces \
         shows a lane you want context from."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "surface"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Lane label exactly as shown in Connected \
                             Surfaces or chat history source: 'dashboard', \
                             'discord', 'slack', or another connector's \
                             channel label" )
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            "Maximum lane messages to return (default 20, \
                             max 100)" )
                      ] )
                ] )
          ; "required", `List [ `String "surface" ]
          ]
    }
  ; { name = "keeper_surface_post"
    ; description =
        "Post a message to one connected surface lane: 'dashboard' (appears \
         in the operator's chat transcript) or 'discord' (sends to the bound \
         channel). Posting to an unbound surface is an error."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "surface"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Lane to post to: 'dashboard' or 'discord'" )
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Message text to deliver on the lane" )
                      ] )
                ; ( "channel_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Discord channel snowflake; required only when \
                             more than one channel is bound" )
                      ] )
                ] )
          ; "required", `List [ `String "surface"; `String "content" ]
          ]
    }
  ]
