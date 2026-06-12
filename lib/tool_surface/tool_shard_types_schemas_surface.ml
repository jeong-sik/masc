(** Tool_shard_types_schemas_surface — keeper_surface_* tool schemas
    (RFC-0223 P3). *)

let surface_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_surface_read"
    ; description =
        "Read recent conversation from one connected surface lane (dashboard, \
         discord, slack, or another connector label) with speaker identity \
         and a derived participant roster. Use when the user asks about a \
         current connector lane, recent lane messages, or participants. This \
         does not enumerate connector-wide channel registries; if asked for \
         channels outside Connected Surfaces, read only visible lane evidence \
         and state that the wider registry is unavailable."
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
                ; ( "before"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String
                            "Page backward: return messages strictly older \
                             than this ts (a message timestamp from a \
                             previous call). Walk history by passing the \
                             oldest_ts of the previous response; stop when \
                             has_more is false." )
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
  ; { name = "keeper_person_note_set"
    ; description =
        "Remember (or clear) a note about a person met on a connected \
         surface, keyed by their roster speaker_id (RFC-0229). The note \
         survives after their messages age out of the log window and \
         shows up on the keeper_surface_read roster."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "speaker_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Stable speaker id from the roster (Discord \
                             snowflake); notes attach to ids, never names" )
                      ] )
                ; ( "note"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "What to remember about this person; blank \
                             clears the note" )
                      ] )
                ] )
          ; "required", `List [ `String "speaker_id"; `String "note" ]
          ]
    }
  ]
