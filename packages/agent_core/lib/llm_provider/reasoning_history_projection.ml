open Types

type reasoning_replay_drop_reason =
  | Replay_policy_excluded of Reasoning_replay_contract.replay_policy
  | Missing_reasoning_source
  | Incompatible_reasoning_source of Types.Reasoning_source.t
  | Reasoning_on_non_assistant
[@@deriving show]

type reasoning_replay_drop =
  { message_index : int
  ; reason : reasoning_replay_drop_reason
  }
[@@deriving show]

type reasoning_block_kind =
  | Thinking_block
  | Reasoning_details_block
  | Redacted_thinking_block
[@@deriving show]

type t =
  { messages : Types.message list
  ; reasoning_target : Types.Reasoning_source.t
  ; reasoning_replay_drops : reasoning_replay_drop list
  ; removed_empty_assistant_indices : int list
  }
[@@deriving show]

type error =
  | Invalid_reasoning_target of string
  | Invalid_reasoning_source of
      { message_index : int
      ; classification : Types.Reasoning_source.classification
      }
  | Reasoning_source_on_non_assistant of
      { message_index : int
      ; classification : Types.Reasoning_source.classification
      }
  | Unsupported_reasoning_block of
      { message_index : int
      ; block_index : int
      ; block_kind : reasoning_block_kind
      }
[@@deriving show]

let error_to_string = function
  | Invalid_reasoning_target detail -> "invalid reasoning target: " ^ detail
  | Invalid_reasoning_source { message_index; classification } ->
    Printf.sprintf
      "invalid reasoning source at history index %d (%s)"
      message_index
      (Types.Reasoning_source.show_classification classification)
  | Reasoning_source_on_non_assistant { message_index; classification } ->
    Printf.sprintf
      "reasoning source is attached to a non-Assistant message at history index %d (%s)"
      message_index
      (Types.Reasoning_source.show_classification classification)
  | Unsupported_reasoning_block { message_index; block_index; block_kind } ->
    Printf.sprintf
      "reasoning block %s at history index %d block %d is not representable by the \
       resolved provider codec"
      (show_reasoning_block_kind block_kind)
      message_index
      block_index
;;

let validate_and_classify (messages : Types.message list) =
  let rec loop message_index classified = function
    | [] -> Ok (List.rev classified)
    | (message : Types.message) :: rest ->
      let classification = Types.Reasoning_source.classify message.metadata in
      let result =
        match message.role, classification with
        | Assistant, (Types.Reasoning_source.Absent | Present _) -> Ok ()
        | Assistant, (Invalid | Duplicate) ->
          Error (Invalid_reasoning_source { message_index; classification })
        | (System | User | Tool), Types.Reasoning_source.Absent -> Ok ()
        | (System | User | Tool), (Present _ | Invalid | Duplicate) ->
          Error (Reasoning_source_on_non_assistant { message_index; classification })
      in
      (match result with
       | Error _ as error -> error
       | Ok () ->
         loop
           (message_index + 1)
           ((message_index, message, classification) :: classified)
           rest)
  in
  loop 0 [] messages
;;

let content_has_reasoning =
  List.exists (function
    | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
    | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false)
;;

let content_has_tool_use =
  List.exists (function
    | ToolUse _ -> true
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> false)
;;

let without_reasoning content =
  List.filter
    (function
      | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> false
      | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> true)
    content
;;

let content_has_generic_reasoning =
  List.exists (function
    | Thinking _ | ReasoningDetails _ -> true
    | Text _
    | RedactedThinking _
    | ToolUse _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> false)
;;

let without_generic_reasoning content =
  List.filter
    (function
      | Thinking _ | ReasoningDetails _ -> false
      | Text _
      | RedactedThinking _
      | ToolUse _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> true)
    content
;;

let unsupported_reasoning_block ~reasoning_block_supported content =
  let rec loop block_index = function
    | [] -> None
    | (Thinking _ as block) :: _ when not (reasoning_block_supported block) ->
      Some (block_index, Thinking_block)
    | (ReasoningDetails _ as block) :: _ when not (reasoning_block_supported block) ->
      Some (block_index, Reasoning_details_block)
    | (RedactedThinking _ as block) :: _ when not (reasoning_block_supported block) ->
      Some (block_index, Redacted_thinking_block)
    | ( Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | ToolUse _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ )
      :: rest -> loop (block_index + 1) rest
  in
  loop 0 content
;;

let validate_supported_reasoning ~reasoning_block_supported ~message_index content =
  match unsupported_reasoning_block ~reasoning_block_supported content with
  | None -> Ok content
  | Some (block_index, block_kind) ->
    Error (Unsupported_reasoning_block { message_index; block_index; block_kind })
;;

let find_latest_user_message_index classified_messages =
  List.fold_left
    (fun latest (message_index, (message : Types.message), _) ->
       match message.role with
       | User -> Some message_index
       | System | Assistant | Tool -> latest)
    None
    classified_messages
;;

let replay_selected
      replay_policy
      ~assistant_had_tool_call
      ~message_index
      ~latest_user_message_index
  =
  match replay_policy with
  | Reasoning_replay_contract.No_replay | Provider_opaque_state -> false
  | All_assistant_messages -> true
  | Tool_call_assistant_messages_all_history -> assistant_had_tool_call
  | Tool_call_assistant_messages_latest_user_turn ->
    assistant_had_tool_call
    &&
      (match latest_user_message_index with
      | Some user_message_index -> message_index > user_message_index
      | None -> false)
;;

let project
      ~assistant_has_payload
      ~reasoning_block_supported
      ~(replay_capability : Reasoning_dialect.replay_capability)
      (messages : Types.message list)
  =
  let reasoning_target = replay_capability.target in
  let replay_policy =
    replay_capability.contract.Reasoning_replay_contract.replay_policy
  in
  let rotation_policy = replay_capability.rotation in
  match validate_and_classify messages with
  | Error _ as error -> error
  | Ok classified_messages ->
    let latest_user_message_index = find_latest_user_message_index classified_messages in
    let rec loop projected replay_drops removed_empty = function
      | [] ->
        Ok
          { messages = List.rev projected
          ; reasoning_target
          ; reasoning_replay_drops = List.rev replay_drops
          ; removed_empty_assistant_indices = List.rev removed_empty
          }
      | (message_index, (message : Types.message), source_classification) :: rest ->
        let has_reasoning = content_has_reasoning message.content in
        let content_result =
          match message.role, has_reasoning with
          | _, false -> Ok (message.content, None)
          | Assistant, true ->
            (match source_classification with
             (* Continuity across a source change is a declared decision, not an
                incidental hash comparison: the target dialect's typed
                [rotation_policy] says which differences a stored artifact may
                survive (RFC-OAS-029 S3.1). *)
             | Types.Reasoning_source.Present source
               when not
                      (Types.Reasoning_source.rotation_admits
                         ~rotation_policy
                         ~stored:source
                         ~target:reasoning_target) ->
               Ok
                 ( without_reasoning message.content
                 , Some { message_index; reason = Incompatible_reasoning_source source }
                 )
             | Types.Reasoning_source.Absent ->
               Ok
                 ( without_reasoning message.content
                 , Some { message_index; reason = Missing_reasoning_source } )
             | Types.Reasoning_source.Present _
               when replay_policy = Reasoning_replay_contract.Provider_opaque_state ->
               let content = without_generic_reasoning message.content in
               Result.map
                 (fun content ->
                    let replay_drop =
                      if content_has_generic_reasoning message.content
                      then
                        Some
                          { message_index; reason = Replay_policy_excluded replay_policy }
                      else None
                    in
                    content, replay_drop)
                 (validate_supported_reasoning
                    ~reasoning_block_supported
                    ~message_index
                    content)
             | Types.Reasoning_source.Present _ ->
               if
                 replay_selected
                   replay_policy
                   ~assistant_had_tool_call:(content_has_tool_use message.content)
                   ~message_index
                   ~latest_user_message_index
               then
                 Result.map
                   (fun content -> content, None)
                   (validate_supported_reasoning
                      ~reasoning_block_supported
                      ~message_index
                      message.content)
               else
                 Ok
                   ( without_reasoning message.content
                   , Some { message_index; reason = Replay_policy_excluded replay_policy }
                   )
             | Types.Reasoning_source.Invalid | Types.Reasoning_source.Duplicate ->
               Ok (without_reasoning message.content, None))
          | (System | User | Tool), true ->
            Ok
              ( without_reasoning message.content
              , Some { message_index; reason = Reasoning_on_non_assistant } )
        in
        (match content_result with
         | Error _ as error -> error
         | Ok (content, replay_drop) ->
           let message = { message with content } in
           let projected, removed_empty =
             match message.role, assistant_has_payload content with
             | Assistant, false -> projected, message_index :: removed_empty
             | (System | User | Tool), _ | Assistant, true ->
               message :: projected, removed_empty
           in
           let replay_drops =
             match replay_drop with
             | Some drop -> drop :: replay_drops
             | None -> replay_drops
           in
           loop projected replay_drops removed_empty rest)
    in
    loop [] [] [] classified_messages
;;

let project_for_provider_config
      ~assistant_has_payload
      ~reasoning_block_supported
      config
      messages
  =
  match Reasoning_dialect.replay_capability_for_provider_config config with
  | Error detail -> Error (Invalid_reasoning_target detail)
  | Ok replay_capability ->
    project ~assistant_has_payload ~reasoning_block_supported ~replay_capability messages
;;

let summarize_drops drops =
  List.fold_left
    (fun (replay_policy_excluded, missing_source, incompatible_source, non_assistant)
      drop ->
       match drop.reason with
       | Replay_policy_excluded _ ->
         replay_policy_excluded + 1, missing_source, incompatible_source, non_assistant
       | Missing_reasoning_source ->
         replay_policy_excluded, missing_source + 1, incompatible_source, non_assistant
       | Incompatible_reasoning_source _ ->
         replay_policy_excluded, missing_source, incompatible_source + 1, non_assistant
       | Reasoning_on_non_assistant ->
         replay_policy_excluded, missing_source, incompatible_source, non_assistant + 1)
    (0, 0, 0, 0)
    drops
;;

let observe ~component projection =
  let target_json = snd (Types.Reasoning_source.entry projection.reasoning_target) in
  (match projection.reasoning_replay_drops with
   | [] -> ()
   | drops ->
     let replay_policy_excluded, missing_source, incompatible_source, non_assistant =
       summarize_drops drops
     in
     let payload =
       Yojson.Safe.to_string
         (`Assoc
             [ "event", `String "reasoning_replay_dropped"
             ; "target", target_json
             ; "drop_count", `Int (List.length drops)
             ; "replay_policy_excluded", `Int replay_policy_excluded
             ; "missing_source", `Int missing_source
             ; "incompatible_source", `Int incompatible_source
             ; "reasoning_on_non_assistant", `Int non_assistant
             ])
     in
     (* All drop reasons here are outcomes of a *successful* projection: the
        error path raises [invalid_arg] and never reaches this observe hook, so a
        drop summary always accompanies an [Ok projection] the caller proceeds
        with. Stripping untagged (missing_source) or cross-target (incompatible_
        source) prior-turn reasoning is the normal, expected behaviour for
        OpenAI-compat/Ollama backends where reasoning arrives as an untagged
        side-channel — an expected lifecycle event (Info), not a failure (Warn).
        The previous Warn split fired ~973x/day narrating routine replay
        normalisation. Per-reason counts remain in [payload] for diagnostics. *)
     Diag.info component "%s" payload);
  match projection.removed_empty_assistant_indices with
  | [] -> ()
  | indices ->
    Diag.info
      component
      "%s"
      (Yojson.Safe.to_string
         (`Assoc
             [ "event", `String "empty_assistant_history_removed"
             ; "target", target_json
             ; "removed_count", `Int (List.length indices)
             ]))
;;
