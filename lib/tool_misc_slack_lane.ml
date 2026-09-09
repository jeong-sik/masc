(** Slack-lane reader tool (docs/design/slack-integration.md, task-1430).

    [masc_slack_read] reads the in-server buffer the poll fiber
    ({!Server_slack_poll_lane}) fills. Read-only by construction: it touches
    no socket, no REST, no Slack — the buffer is local memory, and an empty
    buffer is an explicit answer ("not collected"), never a silent empty
    success that would read as "the channel is quiet". *)

open Tool_args

let max_limit = 200

let err ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    message
;;

let message_json (m : Slack_lane.lane_message) : Yojson.Safe.t =
  `Assoc
    [ ("channel_id", `String m.Slack_lane.channel_id)
    ; ("ts", `String m.Slack_lane.ts)
    ; ("user_id", `String m.Slack_lane.user_id)
    ; ("text", `String m.Slack_lane.text)
    ]
;;

let handle_read ~tool_name ~start_time args : Tool_result.result =
  let action = get_string args "action" "messages" in
  if not (String.equal action "messages") then
    err ~tool_name ~start_time
      "action must be one of: messages (thread reading arrives with the write \
       increment)"
  else
    let channel_id = String.trim (get_string args "channel_id" "") in
    if String.equal channel_id "" then
      (* No channel named: the summary a caller picks a channel from. *)
      let channels = Slack_lane.channels () in
      let data =
        `Assoc
          [ ( "channels"
            , `List
                (List.map
                   (fun (cid, count) ->
                     `Assoc
                       [ ("channel_id", `String cid); ("buffered", `Int count) ])
                   channels) )
          ; ( "note"
            , `String
                (if channels = [] then
                   "lane empty: the poll fiber is off or has not collected yet"
                 else "newest-first reads: masc_slack_read channel_id=<id>") )
          ]
      in
      Tool_result.make_ok ~tool_name ~start_time ~data ()
    else
      let limit = max 1 (min max_limit (get_int args "limit" 50)) in
      match Slack_lane.recent ~channel_id ~limit with
      | [] ->
        (* Empty is an answer about the buffer, not about the channel. *)
        Tool_result.make_ok ~tool_name ~start_time
          ~data:
            (`Assoc
               [ ("messages", `List [])
               ; ( "note"
                 , `String
                     "nothing buffered for this channel: the buffer holds only \
                      what the poll fiber collected since it last started" )
               ])
          ()
      | msgs ->
        Tool_result.make_ok ~tool_name ~start_time
          ~data:(`Assoc [ ("messages", `List (List.map message_json msgs)) ])
          ()
;;
