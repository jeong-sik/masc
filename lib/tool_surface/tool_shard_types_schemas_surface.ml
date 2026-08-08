(** Tool_shard_types_schemas_surface — keeper_surface_* tool schemas
    (RFC-0223 P3). *)

let keeper_surface_post_description =
  "Post a message to one conversation endpoint: 'dashboard' (appears \
   in the operator's chat transcript) or 'discord' (sends to the bound \
   channel). Posting to an unbound surface is an error. Both endpoints \
   are read by a person, so an unchanged status reposted every cycle \
   crowds their view and says nothing the previous one did not; when \
   there is nothing new, the turn ends without a post."
;;

let surface_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_surface_read"
    ; description =
        "Read recent messages from one conversation endpoint (dashboard, \
         discord, slack, or another connector label) with speaker identity \
         and a derived participant roster. With mode='channel', 'messages', \
         'members', or 'member', the Discord lane can also query its live \
         channel and server read surface within the keeper's bound channels."
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
                ; ( "mode"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map
                               (fun value -> `String value)
                               [ "local"; "channel"; "messages"; "members"; "member" ]) )
                      ; ( "description"
                        , `String
                            "Read mode: local persisted lane, or a live Discord channel/messages/members/member query" )
                      ] )
                ; ( "channel_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Bound Discord channel snowflake; optional when exactly one channel is bound" )
                      ] )
                ; ( "user_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description", `String "Discord user snowflake for mode='member'" )
                      ] )
                ; ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description", `String "Optional member username/nickname prefix" )
                      ] )
                ; ( "discord_before"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description", `String "Discord message snowflake for backward paging" )
                      ] )
                ; ( "discord_after"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description", `String "Discord paging cursor; do not combine with discord_before" )
                      ] )
                ] )
          ; "required", `List [ `String "surface" ]
          ]
    }
  ; { name = "keeper_surface_post"
    ; description = keeper_surface_post_description
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
