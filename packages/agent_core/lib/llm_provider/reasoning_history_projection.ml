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

(* The extra-system-context carrier rides the User role for wire
   compatibility, but it is runtime-assembled context, not a person speaking:
   [Types.Extra_system_context_provenance] exists so consumers attribute the
   carrier by typed identity. Counting it as a user turn made
   [Tool_call_assistant_messages_latest_user_turn] drop every assistant
   reasoning block whenever a request carried the trailing per-turn context —
   a keeper tool loop injects one on every provider round, so replay was
   permanently empty on those lanes. Any classification of the carrier key
   marks the message as a carrier (a replay question: does this message
   carry context the thinking prefix must keep?). This deliberately differs
   from [Runtime_model_input_tail_window.is_extra_context], which answers a
   pinning question (must this message survive every cut?) and returns
   false for [Historical]. *)
let is_extra_system_context_carrier (message : Types.message) =
  match Types.Extra_system_context_provenance.classify message.metadata with
  | Types.Extra_system_context_provenance.Absent -> false
  | Types.Extra_system_context_provenance.Present
  | Types.Extra_system_context_provenance.Historical
  | Types.Extra_system_context_provenance.Invalid
  | Types.Extra_system_context_provenance.Duplicate -> true
;;

let find_latest_user_message_index classified_messages =
  List.fold_left
    (fun latest (message_index, (message : Types.message), _) ->
       match message.role with
       | User when not (is_extra_system_context_carrier message) -> Some message_index
       | User | System | Assistant | Tool -> latest)
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
                survive (Agent Core contract S3.1). *)
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

(* Creation-prefix binding: admit stored reasoning only when the bytes
   before it still hash to the digest its producing request carried. *)

type prefix_drop_cause =
  | Prefix_source_not_present
  | Prefix_digest_absent
  | Prefix_request_mismatch
  | Prefix_reasoning_mismatch
[@@deriving show]

type prefix_drop =
  { message_index : int
  ; cause : prefix_drop_cause
  }
[@@deriving show]

type prefix_verify_error =
  | Malformed_prefix_entry of
      { message_index : int
      ; classification : Types.Reasoning_prefix.classification
      }
[@@deriving show]

type prefix_verdict =
  { messages : Types.message list
  ; prefix_drops : prefix_drop list
  ; removed_empty_assistant_indices : int list
  ; final_digest : string
  }
[@@deriving show]

let prefix_verify_error_to_string = function
  | Malformed_prefix_entry { message_index; classification } ->
    Printf.sprintf
      "malformed reasoning prefix entry at history index %d (%s)"
      message_index
      (Types.Reasoning_prefix.show_classification classification)
;;

let sha256_hex material = Digestif.SHA256.(to_hex (digest_string material))

(* One chain step over a running hex digest and one tagged piece. Chained
   single-shot hashes cost O(total bytes); the fold compares at every
   message start, so a per-message snapshot of one running context would
   either re-feed the whole prefix or rely on context persistence. *)
let chain_extend previous_hex tag payload =
  sha256_hex (previous_hex ^ "\000" ^ tag ^ "\000" ^ payload)
;;

let block_bytes ~encode_block block = Yojson.Safe.to_string (encode_block block)

let content_wire_digest ~encode_block content =
  let material =
    String.concat "\000" (List.map (fun block -> "blk\000" ^ block_bytes ~encode_block block) content)
  in
  sha256_hex ("msg\000" ^ material)
;;

let verify_prefix_binding ~head ~encode_block ~role_tag messages =
  let head_bytes = Yojson.Safe.to_string (`Assoc head) in
  let chain = ref (sha256_hex ("head\000" ^ head_bytes)) in
  let rec loop message_index projected drops removed = function
    | [] ->
      Ok
        { messages = List.rev projected
        ; prefix_drops = List.rev drops
        ; removed_empty_assistant_indices = List.rev removed
        ; final_digest = !chain
        }
    | (message : Types.message) :: rest ->
      let content_result =
        if not (content_has_reasoning message.content)
        then Ok (message.content, None)
        else (
          match Types.Reasoning_source.classify message.metadata with
          | Types.Reasoning_source.Present _ -> (
            match Types.Reasoning_prefix.classify message.metadata with
            | Types.Reasoning_prefix.Absent ->
              Ok
                ( without_reasoning message.content
                , Some { message_index; cause = Prefix_digest_absent } )
            | (Types.Reasoning_prefix.Invalid | Types.Reasoning_prefix.Duplicate) as
              classification ->
              Error (Malformed_prefix_entry { message_index; classification })
            | Types.Reasoning_prefix.Present prefix ->
              if
                not
                  (String.equal prefix.Reasoning_prefix.request_digest !chain)
              then
                Ok
                  ( without_reasoning message.content
                  , Some { message_index; cause = Prefix_request_mismatch } )
              else (
                let current = content_wire_digest ~encode_block message.content in
                if
                  not
                    (String.equal
                       prefix.Reasoning_prefix.message_digest
                       current)
                then
                  Ok
                    ( without_reasoning message.content
                    , Some { message_index; cause = Prefix_reasoning_mismatch } )
                else Ok (message.content, None)))
          | Types.Reasoning_source.Absent
          | Types.Reasoning_source.Invalid
          | Types.Reasoning_source.Duplicate ->
            (* Projection strips or refuses these before the fold runs; a
               standalone caller gets the same fail-closed answer. *)
            Ok
              ( without_reasoning message.content
              , Some { message_index; cause = Prefix_source_not_present } ))
      in
      (match content_result with
       | Error _ as error -> error
       | Ok (content, drop) ->
         chain := chain_extend !chain "role" (role_tag message.role);
         List.iter
           (fun block ->
              chain := chain_extend !chain "blk" (block_bytes ~encode_block block))
           content;
         let message = { message with content } in
         let projected, removed =
           match message.role, content with
           | Assistant, [] -> projected, message_index :: removed
           | (System | User | Tool), _ | Assistant, _ :: _ ->
             message :: projected, removed
         in
         let drops =
           match drop with
           | Some drop -> drop :: drops
           | None -> drops
         in
         loop (message_index + 1) projected drops removed rest)
  in
  loop 0 [] [] [] messages
;;

let observe_prefix_drops ~component ~stream verdict =
  match verdict.prefix_drops with
  | [] when verdict.removed_empty_assistant_indices = [] -> ()
  | _ ->
    let drops = verdict.prefix_drops in
    let count cause =
      List.fold_left
        (fun total drop -> if drop.cause = cause then total + 1 else total)
        0
        drops
    in
    let rec take count acc = function
      | [] -> List.rev acc
      | _ when count <= 0 -> List.rev acc
      | drop :: rest -> take (count - 1) (drop.message_index :: acc) rest
    in
    Diag.info
      component
      "%s"
      (Yojson.Safe.to_string
         (`Assoc
             [ "event", `String "reasoning_prefix_dropped"
             ; "component", `String component
             ; "stream", `Bool stream
             ; "drop_count", `Int (List.length drops)
             ; "source_not_present", `Int (count Prefix_source_not_present)
             ; "digest_absent", `Int (count Prefix_digest_absent)
             ; "request_mismatch", `Int (count Prefix_request_mismatch)
             ; "reasoning_mismatch", `Int (count Prefix_reasoning_mismatch)
             ; ( "dropped_indices_sample"
               , `List
                   (List.map
                      (fun index -> `Int index)
                      (take 8 [] drops)) )
             ; ( "removed_empty_assistant_count"
               , `Int (List.length verdict.removed_empty_assistant_indices) )
             ]))
;;

(* [stream] tells the two serializations of one request apart. Exact-output
   planning serializes with [stream:false] before admission serializes with the
   transport's real value, so the same history is projected twice and this
   summary is emitted twice with byte-identical payloads. Without the flag the
   pair says nothing about which stage produced it (#28636). *)
let observe ~component ~stream projection =
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
             ; "component", `String component
             ; "stream", `Bool stream
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
