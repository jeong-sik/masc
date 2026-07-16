module T = Agent_sdk.Types
module Id_set = Set.Make (String)

type closed_unit =
  | Ordinary_message of T.message
  | Closed_tool_cycle of T.message list

type structural_error =
  | Orphan_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Duplicate_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Unknown_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Non_assistant_tool_use of
      { message_index : int
      ; tool_use_id : string
      }
  | Duplicate_tool_use_id of
      { message_index : int
      ; tool_use_id : string
      }
  | Overlapping_tool_cycle of
      { message_index : int
      ; tool_use_id : string
      }
  | Tool_request_contains_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Non_result_tool_role of
      { message_index : int
      ; tool_use_id : string
      }

type partition =
  { closed_prefix : closed_unit list
  ; protected_suffix : T.message list
  }

type open_cycle =
  { expected : Id_set.t
  ; pending : Id_set.t
  ; messages_rev : T.message list
  }

let top_level_anchors blocks =
  List.fold_left
    (fun (uses, results) -> function
      | T.ToolUse { id; _ } -> id :: uses, results
      | T.ToolResult { tool_use_id; _ } -> uses, tool_use_id :: results
      | T.Text _
      | T.Thinking _
      | T.ReasoningDetails _
      | T.RedactedThinking _
      | T.Image _
      | T.Document _
      | T.Audio _ ->
          uses, results)
    ([], []) blocks
  |> fun (uses, results) -> List.rev uses, List.rev results

let rec add_tool_ids ~message_index seen = function
  | [] -> Ok seen
  | tool_use_id :: rest ->
      if Id_set.mem tool_use_id seen then
        Error (Duplicate_tool_use_id { message_index; tool_use_id })
      else add_tool_ids ~message_index (Id_set.add tool_use_id seen) rest

let rec consume_results ~message_index ~expected pending seen = function
  | [] -> Ok (pending, seen)
  | tool_use_id :: rest ->
      if Id_set.mem tool_use_id seen then
        Error (Duplicate_tool_result { message_index; tool_use_id })
      else if not (Id_set.mem tool_use_id expected) then
        Error (Unknown_tool_result { message_index; tool_use_id })
      else
        consume_results ~message_index ~expected
          (Id_set.remove tool_use_id pending)
          (Id_set.add tool_use_id seen) rest

let is_result_role = function
  | T.User | T.Tool -> true
  | T.System | T.Assistant -> false

let partition messages =
  let rec loop index units_rev seen_tools seen_results open_cycle = function
    | [] ->
        let protected_suffix =
          match open_cycle with
          | None -> []
          | Some cycle -> List.rev cycle.messages_rev
        in
        Ok { closed_prefix = List.rev units_rev; protected_suffix }
    | (message : T.message) :: rest ->
        let tool_ids, result_ids = top_level_anchors message.content in
        (match message.role, tool_ids with
        | (T.System | T.User | T.Tool), tool_use_id :: _ ->
            Error (Non_assistant_tool_use { message_index = index; tool_use_id })
        | _ -> (
            match open_cycle, tool_ids, result_ids with
            | Some _, tool_use_id :: _, _ ->
                Error (Overlapping_tool_cycle { message_index = index; tool_use_id })
            | None, _, _ -> (
                match add_tool_ids ~message_index:index seen_tools tool_ids with
                | Error _ as error -> error
                | Ok seen_tools -> (
                    match tool_ids, result_ids with
                    | [], tool_use_id :: _ ->
                        if Id_set.mem tool_use_id seen_results then
                          Error
                            (Duplicate_tool_result
                               { message_index = index; tool_use_id })
                        else
                          Error
                            (Orphan_tool_result
                               { message_index = index; tool_use_id })
                    | [], [] ->
                        loop (index + 1)
                          (Ordinary_message message :: units_rev)
                          seen_tools seen_results None rest
                    | tool_use_id :: _, _ :: _ ->
                        Error
                          (Tool_request_contains_result
                             { message_index = index; tool_use_id })
                    | _ :: _, [] ->
                        let expected = Id_set.of_list tool_ids in
                        loop (index + 1) units_rev seen_tools seen_results
                          (Some
                             { expected
                             ; pending = expected
                             ; messages_rev = [ message ]
                             })
                          rest))
            | Some cycle, [], [] ->
                loop (index + 1) units_rev seen_tools seen_results
                  (Some { cycle with messages_rev = message :: cycle.messages_rev })
                  rest
            | Some _, [], tool_use_id :: _ when not (is_result_role message.role) ->
                Error (Non_result_tool_role { message_index = index; tool_use_id })
            | Some cycle, [], _ :: _ -> (
                match
                  consume_results ~message_index:index ~expected:cycle.expected
                    cycle.pending seen_results result_ids
                with
                | Error _ as error -> error
                | Ok (pending, seen_results) ->
                    let messages_rev = message :: cycle.messages_rev in
                    if Id_set.is_empty pending then
                      loop (index + 1)
                        (Closed_tool_cycle (List.rev messages_rev) :: units_rev)
                        seen_tools seen_results None rest
                    else
                      loop (index + 1) units_rev seen_tools seen_results
                        (Some { cycle with pending; messages_rev })
                        rest)))
  in
  loop 0 [] Id_set.empty Id_set.empty None messages
