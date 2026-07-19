module Sset = Set.Make (String)

let is_orphan_tool_use answered = function
  | Agent_sdk.Types.ToolUse { id; _ } -> not (Sset.mem id answered)
  | _ -> false
;;

let drop (msgs : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  let answered =
    List.fold_left
      (fun acc (m : Agent_sdk.Types.message) ->
         List.fold_left
           (fun acc block ->
              match block with
              | Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Sset.add tool_use_id acc
              | _ -> acc)
           acc
           m.content)
      Sset.empty
      msgs
  in
  let has_orphan =
    List.exists
      (fun (m : Agent_sdk.Types.message) ->
         List.exists (is_orphan_tool_use answered) m.content)
      msgs
  in
  if not has_orphan
  then msgs
  else
    List.filter_map
      (fun (m : Agent_sdk.Types.message) ->
         let content =
           List.filter (fun block -> not (is_orphan_tool_use answered block)) m.content
         in
         (* Orphan removal emptied a message that previously had content: drop it
            so no empty assistant turn is sent. Only [ToolUse] (assistant-only)
            blocks are ever removed, so this only affects assistant turns. The
            [= []] / [<> []] tests are nil-constructor checks, not structural
            block comparisons. *)
         let emptied_by_removal = content = [] && m.content <> [] in
         if emptied_by_removal then None else Some { m with content })
      msgs
;;
