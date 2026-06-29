(* Tool-use / tool-result block pair invariants for keeper messages.

   Extracted from [Keeper_context_core] (godfile decomp). All
   functions are pure projections over the message-content variant
   and total over [Agent_sdk.Types] (exhaustive matches, no catch-all). *)

let tool_use_ids_of_message (msg : Agent_sdk.Types.message) : string list =
  match msg.role with
  | Agent_sdk.Types.Assistant ->
    List.filter_map
      (function
        | Agent_sdk.Types.ToolUse { id; _ } -> Some id
        (* Only assistant [ToolUse] blocks are provider tool-call anchors. *)
        | Agent_sdk.Types.Text _
        | Agent_sdk.Types.Thinking _
        | Agent_sdk.Types.RedactedThinking _
        | Agent_sdk.Types.ToolResult _
        | Agent_sdk.Types.Image _
        | Agent_sdk.Types.Document _
        | Agent_sdk.Types.Audio _ -> None)
      msg.content
  | Agent_sdk.Types.System
  | Agent_sdk.Types.User
  | Agent_sdk.Types.Tool -> []
;;

let has_tool_use_block (msg : Agent_sdk.Types.message) : bool =
  List.exists
    (function
      | Agent_sdk.Types.ToolUse _ -> true
      | Agent_sdk.Types.Text _
      | Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.RedactedThinking _
      | Agent_sdk.Types.ToolResult _
      | Agent_sdk.Types.Image _
      | Agent_sdk.Types.Document _
      | Agent_sdk.Types.Audio _ -> false)
    msg.content
;;

let tool_result_ids_of_message (msg : Agent_sdk.Types.message) : string list =
  List.filter_map
    (function
      | Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
      (* Only [ToolResult] carries a tool_use_id reference; others contribute none. *)
      | Agent_sdk.Types.Text _
      | Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.RedactedThinking _
      | Agent_sdk.Types.ToolUse _
      | Agent_sdk.Types.Image _
      | Agent_sdk.Types.Document _
      | Agent_sdk.Types.Audio _ -> None)
    msg.content
;;

let has_tool_result_block (msg : Agent_sdk.Types.message) : bool =
  List.exists
    (function
      | Agent_sdk.Types.ToolResult _ -> true
      (* Only [ToolResult] qualifies; other blocks are not tool-result evidence. *)
      | Agent_sdk.Types.Text _
      | Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.RedactedThinking _
      | Agent_sdk.Types.ToolUse _
      | Agent_sdk.Types.Image _
      | Agent_sdk.Types.Document _
      | Agent_sdk.Types.Audio _ -> false)
    msg.content
;;

(** Trim messages to at most [max_count] while preserving ToolUse/ToolResult
    pairing.  Drops from the front.  If the drop point lands on a
    ToolResult whose ToolUse would be the last dropped message, advance
    the drop by 1 so the orphan ToolResult is also removed (pair stays
    together on the dropped side).  This may yield fewer than [max_count]
    messages but never creates orphans.

    Root cause of recurring "unexpected tool_use_id" errors: the previous
    implementation used [List.filteri (fun i _ -> i >= drop)] which splits
    on message index, breaking mid-pair boundaries. *)
let trim_messages_preserving_pairs
      (messages : Agent_sdk.Types.message list)
      ~(max_count : int)
  : Agent_sdk.Types.message list
  =
  let n = List.length messages in
  if n <= max_count
  then messages
  else (
    let drop = n - max_count in
    (* If the first kept message would be an orphan ToolResult,
       drop it too so the pair stays together on the removed side. *)
    let effective_drop =
      match List.nth_opt messages drop with
      | Some msg when has_tool_result_block msg ->
        (* Advance drop to skip the orphan ToolResult *)
        drop + 1
      | _ -> drop
    in
    List.filteri (fun i _ -> i >= effective_drop) messages)
;;
