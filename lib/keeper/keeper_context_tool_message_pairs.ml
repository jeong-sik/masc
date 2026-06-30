(* Tool-use / tool-result block pair invariants for keeper messages.

   Extracted from [Keeper_context_core] (godfile decomp). ToolResult
   and ToolUse projections delegate to [Agent_sdk.Canonical_tool] so pair
   repair consumes OAS-owned provider-boundary block projections. *)

module Canonical_tool = Agent_sdk.Canonical_tool

let tool_use_ids_of_message (msg : Agent_sdk.Types.message) : string list =
  match msg.role with
  | Agent_sdk.Types.Assistant ->
    List.filter_map
      (fun block ->
        Canonical_tool.tool_call_of_block block
        |> Option.map (fun call -> call.Canonical_tool.call_id))
      msg.content
  | Agent_sdk.Types.System
  | Agent_sdk.Types.User
  | Agent_sdk.Types.Tool -> []
;;

let has_tool_use_block (msg : Agent_sdk.Types.message) : bool =
  List.exists
    (fun block -> Canonical_tool.tool_call_of_block block |> Option.is_some)
    msg.content
;;

let tool_result_ids_of_message (msg : Agent_sdk.Types.message) : string list =
  List.filter_map
    (fun block ->
      Canonical_tool.tool_result_of_block block
      |> Option.map (fun result -> result.Canonical_tool.call_id))
    msg.content
;;

let has_tool_result_block (msg : Agent_sdk.Types.message) : bool =
  List.exists
    (fun block -> Canonical_tool.tool_result_of_block block |> Option.is_some)
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
