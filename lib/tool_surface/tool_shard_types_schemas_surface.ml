(** Tool_shard_types_schemas_surface — keeper_surface_* tool schemas
    (RFC-0223 P3). *)

(* Slack's chat.postMessage caps top-level blocks at 50. The executor holds the
   authority for this number ([Keeper_surface_post.max_rich_blocks]); this layer
   cannot reference it, because RFC-0056 makes a tool_surface -> keeper edge a
   dune cycle. Named here so the second copy is greppable rather than a bare
   literal, and pinned equal to the authority by
   test_keeper_tool_descriptor_registry_integrity. *)
let max_rich_blocks = 50

let keeper_surface_post_description =
  "Post a message to one conversation endpoint: 'dashboard' (appears \
   in the operator's chat transcript), 'discord', or 'slack'. Standard \
   Markdown is rendered natively by Discord and by Slack's Block Kit \
   markdown block. To create a real highlighted user mention, pass stable \
   participant-roster ids in mention_user_ids; never guess ids from display \
   names. A Slack post may reply inside an existing thread (thread_ts) \
   or carry Block Kit blocks; see those parameters. Posting to an unbound \
   surface is an error. These endpoints \
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
                            "Optional exact read mode. When absent, the request is exactly 'local' for the persisted lane; padded or unknown values are invalid. The other modes query Discord live and require surface='discord'." )
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
                        , `String
                            "Lane to post to: 'dashboard', 'discord', or 'slack'" )
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
                            "Bound Discord or Slack channel id; required only \
                             when more than one channel is bound for the selected surface" )
                      ] )
                ; ( "mention_user_ids"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "string" ]
                      ; "maxItems", `Int 100
                      ; ( "description"
                        , `String
                            "Stable ids from keeper_surface_read participants to visibly mention. Slack requires U.../W... ids; Discord requires decimal user snowflakes. Display names such as @Vincent do not create API mentions." )
                      ] )
                ; ( "thread_ts"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Slack timestamp of an existing thread's root message (from keeper_surface_read). Posts this message as a reply inside that thread. Slack surface only \226\128\148 a dashboard or discord target is rejected, not ignored. When both this and a continuation thread exist, this value wins." )
                      ] )
                ; ( "blocks"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "object" ]
                      ; "maxItems", `Int max_rich_blocks
                      ; ( "description"
                        , `String
                            "Slack Block Kit blocks (chat.postMessage blocks parameter) for a structurally rich PR report: section/header/divider/context blocks, color banners, images. Slack surface only \226\128\148 a dashboard or discord target is rejected, not ignored. Each block must be a JSON object carrying a non-empty string \"type\" member. When blocks is present it is sent alongside content (content remains the notification fallback text)." )
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
