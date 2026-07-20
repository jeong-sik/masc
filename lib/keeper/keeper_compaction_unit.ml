module T = Agent_sdk.Types
module Id_set = Set.Make (String)

type closed_unit =
  | Ordinary_message of T.message
  | Closed_tool_cycle of T.message list

type structural_error =
  | Empty_tool_use_id of
      { message_index : int
      ; block_index : int
      ; tool_use_id : string
      }
  | Empty_tool_result_id of
      { message_index : int
      ; block_index : int
      ; tool_use_id : string
      }
  | Message_tool_call_id_mismatch of
      { message_index : int
      ; message_tool_call_id : string
      ; content_tool_use_ids : string list
      }
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
  (* Retained in the taxonomy for [show]/telemetry compatibility. No longer
     produced by [partition]: a dangling ToolUse followed by a new ToolUse now
     degrades gracefully into [protected_suffix] instead of aborting the whole
     compaction (see [partition]). *)
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
[@@deriving show]

type partition =
  { closed_prefix : closed_unit list
  ; protected_suffix : T.message list
  }

type open_cycle =
  { expected : Id_set.t
  ; pending : Id_set.t
  ; messages_rev : T.message list
  }

(* Blank classification must not normalize the provider-owned identity used
   by cycle matching and persisted evidence. *)
let tool_id_is_blank tool_use_id = String.trim tool_use_id = ""

let top_level_anchors ~message_index blocks =
  let rec collect block_index uses results = function
    | [] -> Ok (List.rev uses, List.rev results)
    | T.ToolUse { id; _ } :: _ when tool_id_is_blank id ->
      Error
        (Empty_tool_use_id
           { message_index; block_index; tool_use_id = id })
    | T.ToolUse { id; _ } :: rest ->
      collect (block_index + 1) (id :: uses) results rest
    | T.ToolResult { tool_use_id; _ } :: _ when tool_id_is_blank tool_use_id ->
      Error
        (Empty_tool_result_id
           { message_index; block_index; tool_use_id })
    | T.ToolResult { tool_use_id; _ } :: rest ->
      collect (block_index + 1) uses (tool_use_id :: results) rest
    | (T.Text _
      | T.Thinking _
      | T.ReasoningDetails _
      | T.RedactedThinking _
      | T.Image _
      | T.Document _
      | T.Audio _)
      :: rest ->
      collect (block_index + 1) uses results rest
  in
  collect 0 [] [] blocks

let validate_message_tool_call_id ~message_index ~content_tool_use_ids = function
  | None -> Ok ()
  | Some message_tool_call_id ->
    (match content_tool_use_ids with
     | [ content_tool_use_id ]
       when String.equal message_tool_call_id content_tool_use_id ->
       Ok ()
     | content_tool_use_ids ->
       Error
         (Message_tool_call_id_mismatch
            { message_index; message_tool_call_id; content_tool_use_ids }))

let validated_top_level_anchors ~message_index (message : T.message) =
  match top_level_anchors ~message_index message.content with
  | Error _ as error -> error
  | Ok (tool_ids, result_ids) ->
    Result.map
      (fun () -> tool_ids, result_ids)
      (validate_message_tool_call_id
         ~message_index
         ~content_tool_use_ids:result_ids
         message.tool_call_id)

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
  let ( let* ) = Result.bind in
  let rec loop index units_rev seen_tools seen_results open_cycle = function
    | [] ->
        let protected_suffix =
          match open_cycle with
          | None -> []
          | Some cycle -> List.rev cycle.messages_rev
        in
        Ok { closed_prefix = List.rev units_rev; protected_suffix }
    | (message : T.message) :: rest ->
        let* tool_ids, result_ids =
          validated_top_level_anchors ~message_index:index message
        in
        (match message.role, tool_ids with
        | (T.System | T.User | T.Tool), tool_use_id :: _ ->
            Error (Non_assistant_tool_use { message_index = index; tool_use_id })
        | _ -> (
            match open_cycle, tool_ids, result_ids with
            | Some cycle, _ :: _, _ ->
                (* A dangling ToolUse never received its ToolResult, then a new
                   ToolUse opens; the prior cycle can never close. [partition] is
                   a total read-side function over histories produced by an
                   external conversation owner (OAS) that masc cannot enforce at
                   write time. Erroring here rejects the ENTIRE compaction and
                   lets the keeper overflow. Preserve the unclosable region
                   verbatim in [protected_suffix] (no drop, no repair), exactly
                   as an open cycle at end-of-list is already protected by the
                   [[]] case above; only the well-formed, fully-paired prefix in
                   [units_rev] stays summarizable. Write-time prevention of the
                   dangling ToolUse is RFC-0240 (tool-pair write-time
                   enforcement), a separate boundary and follow-up. *)
                Ok
                  { closed_prefix = List.rev units_rev
                  ; protected_suffix =
                      List.rev_append cycle.messages_rev (message :: rest)
                  }
            | None, _, _ -> (
                match add_tool_ids ~message_index:index Id_set.empty tool_ids with
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
                        Id_set.empty Id_set.empty None rest
                    else
                      loop (index + 1) units_rev seen_tools seen_results
                        (Some { cycle with pending; messages_rev })
                        rest)))
  in
  loop 0 [] Id_set.empty Id_set.empty None messages

let validate messages = Result.map (fun _partition -> ()) (partition messages)
