(* A media store that holds no bytes: [get] hands back an empty payload for
   every reference. It exists only to lower a measured message; see the .mli
   on why the payload is left out. *)
let payload_free_media : Agent_core.History.media_store =
  { put = (fun ~media_type:_ ~raw -> Ok (Agent_core.History.stored_of_raw raw))
  ; get = (fun (_ : Agent_core.History.stored) -> Ok "")
  }
;;

(* The name the measured calls carry. It is the same in both forms a caller
   compares, so its bytes cancel. *)
let measured_call_name = "measured_call"

(* Every encoder resolves a tool result against the call before it
   ({!Agent_core.Llm_provider.Tool_result_projection}), so a result goes out
   after an assistant message that calls it. *)
let calls_of (message : Agent_core.Types.message) =
  List.filter_map
    (fun (block : Agent_core.Types.content_block) ->
       match block with
       | Agent_core.Types.ToolResult { tool_use_id; _ } ->
         Some
           (Agent_core.Types.ToolUse
              { id = tool_use_id; name = measured_call_name; input = `Assoc [] })
       | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
       | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
       | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _
       | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> None)
    message.content
;;

let measured_request (message : Agent_core.Types.message) =
  match calls_of message with
  | [] -> [ message ]
  | _ :: _ as calls ->
    let call : Agent_core.Types.message =
      { origin = Agent_core.Llm_provider.Types.Conversation
      ; role = Agent_core.Types.Assistant
      ; content = calls
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    in
    [ call; message ]
;;

let measurer ~config message =
  match Agent_core.History.to_wire_messages payload_free_media (measured_request message) with
  | Error (_ : Agent_core.History.media_error) -> None
  | Ok messages ->
    (match
       Agent_core.Llm_provider.Complete_common.serialize_http_request_body
         ~stream:false ~config ~messages ~tools:[]
     with
     | Ok body -> Some (String.length body)
     | Error (_ : Agent_core.Llm_provider.Http_client.http_error) -> None)
;;
