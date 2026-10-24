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
  | Invalid_response_replay of { message_index : int; detail : string }
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
  | Invalid_response_replay {message_index; detail} ->
    Printf.sprintf "invalid response replay at history index %d: %s" message_index detail
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
        match Response_replay.of_metadata ~content:message.content message.metadata with
        | Error detail -> Error (Invalid_response_replay {message_index; detail})
        | Ok (Some _) when message.role <> Assistant ->
          Error (Invalid_response_replay {message_index; detail="responses_replay:non_assistant"})
        | Ok _ -> match message.role, classification with
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

let filter_content keep content =
  let retained = List.mapi (fun index block -> index, block) content
    |> List.filter (fun (_, block) -> keep block) in
  List.map snd retained, List.map fst retained
;;

let without_reasoning content =
  filter_content
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
  filter_content
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

(* Only an ordinary caller User opens the semantic query boundary. The wire
   adapter must preserve this boundary when it lowers control messages. *)
let is_caller_query (message : Types.message) =
  match message.role, message.origin with
  | User, Conversation -> true
  | (System | Assistant | Tool), _
  | User, (System_context | Historical_system_context | Recovery_instruction
          | Tool_result_followup | Agent_instruction) -> false
;;

let find_latest_user_message_index classified_messages =
  List.fold_left
    (fun latest (message_index, (message : Types.message), _) ->
       match message.role with
       | User when is_caller_query message -> Some message_index
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
          | _, false -> Ok ((message.content, List.mapi (fun index _ -> index) message.content), None)
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
               let content, retained_indices = without_generic_reasoning message.content in
               Result.map
                 (fun content ->
                    let replay_drop =
                      if content_has_generic_reasoning message.content
                      then
                        Some
                          { message_index; reason = Replay_policy_excluded replay_policy }
                      else None
                    in
                    (content, retained_indices), replay_drop)
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
                   (fun content -> (content, List.mapi (fun index _ -> index) content), None)
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
         | Ok ((content, retained_indices), replay_drop) ->
           (match Response_replay.retain_metadata ~original_content:message.content
              ~content ~retained_indices message.metadata with
            | Error detail -> Error (Invalid_response_replay {message_index; detail})
            | Ok metadata ->
           let message = { message with content; metadata } in
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
           loop projected replay_drops removed_empty rest))
    in
    loop [] [] [] classified_messages
;;

let project_for_provider_config
      ?(tools_present = false)
      ~assistant_has_payload
      ~reasoning_block_supported
      config
      messages
  =
  match Reasoning_dialect.replay_capability_for_provider_config ~tools_present config with
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

(* Why one message's reasoning was removed before serialization. Every cause
   fails closed: the block is not sent and the turn proceeds without it.
   - [Prefix_entry_invalid] and [Prefix_entry_duplicate]: the stored digest
     tag cannot be read. They name corrupted history, not a changed request.
   - [Prefix_request_mismatch]: the request digest differs from the chain and
     no earlier drop in this request could have changed the chain.
   - [Prefix_chain_broken_upstream]: the same mismatch after an earlier drop
     that could have changed the chain. Later digests were stamped over the
     history with that block present, so this one is not an independent
     finding. *)
type prefix_drop_cause =
  | Prefix_source_not_present
  | Prefix_digest_absent
  | Prefix_entry_invalid
  | Prefix_entry_duplicate
  | Prefix_request_mismatch
  | Prefix_chain_broken_upstream
  | Prefix_reasoning_mismatch
[@@deriving show]

type prefix_drop =
  { message_index : int
  ; cause : prefix_drop_cause
  ; stored_message_digest : string option
  }
[@@deriving show]

type prefix_verdict =
  { messages : Types.message list
  ; prefix_drops : prefix_drop list
  ; removed_empty_assistant_indices : int list
  ; reasoning_message_count : int
  ; final_digest : string
  }
[@@deriving show]

(* Whether a dropped block can be the reason a later stored digest no longer
   matches the chain. A block that carried no readable stamp was never admitted
   by any request: every request that stamped a later block dropped it too, so
   the later digests already chain over its absence. A block that was stamped,
   or whose stamp is unreadable and so might have been, was sent at some point,
   and removing it moves every digest stamped after it. Listing every
   constructor makes a new cause fail to compile until it is classified. *)
let drop_can_change_later_digests = function
  | Prefix_source_not_present | Prefix_digest_absent -> false
  | Prefix_entry_invalid
  | Prefix_entry_duplicate
  | Prefix_request_mismatch
  | Prefix_chain_broken_upstream
  | Prefix_reasoning_mismatch -> true
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
  let rec loop message_index projected drops removed reasoning_messages = function
    | [] ->
      { messages = List.rev projected
      ; prefix_drops = List.rev drops
      ; removed_empty_assistant_indices = List.rev removed
      ; reasoning_message_count = reasoning_messages
      ; final_digest = !chain
      }
    | (message : Types.message) :: rest ->
      let has_reasoning = content_has_reasoning message.content in
      let dropped ?stored_message_digest cause =
        ( without_reasoning message.content
        , Some { message_index; cause; stored_message_digest } )
      in
      let (content, retained_indices), drop =
        if not has_reasoning
        then (message.content, List.mapi (fun index _ -> index) message.content), None
        else (
          match Types.Reasoning_source.classify message.metadata with
          | Types.Reasoning_source.Present _ -> (
            match Types.Reasoning_prefix.classify message.metadata with
            | Types.Reasoning_prefix.Absent -> dropped Prefix_digest_absent
            | Types.Reasoning_prefix.Invalid -> dropped Prefix_entry_invalid
            | Types.Reasoning_prefix.Duplicate -> dropped Prefix_entry_duplicate
            | Types.Reasoning_prefix.Present prefix ->
              let stored_message_digest = prefix.Reasoning_prefix.message_digest in
              if
                not
                  (String.equal prefix.Reasoning_prefix.request_digest !chain)
              then (
                let cause =
                  if
                    List.exists
                      (fun drop -> drop_can_change_later_digests drop.cause)
                      drops
                  then Prefix_chain_broken_upstream
                  else Prefix_request_mismatch
                in
                dropped ~stored_message_digest cause)
              else (
                let current = content_wire_digest ~encode_block message.content in
                if not (String.equal stored_message_digest current)
                then dropped ~stored_message_digest Prefix_reasoning_mismatch
                else (message.content, List.mapi (fun index _ -> index) message.content), None))
          | Types.Reasoning_source.Absent
          | Types.Reasoning_source.Invalid
          | Types.Reasoning_source.Duplicate ->
            (* Projection strips or refuses these before the fold runs; a
               standalone caller gets the same fail-closed answer. *)
            dropped Prefix_source_not_present)
      in
      chain := chain_extend !chain "role" (role_tag message.role);
      List.iter
        (fun block ->
           chain := chain_extend !chain "blk" (block_bytes ~encode_block block))
        content;
      let metadata = match Response_replay.retain_metadata
          ~original_content:message.content ~content ~retained_indices message.metadata with
        | Ok metadata -> metadata
        | Error detail -> invalid_arg detail in
      let message = { message with content; metadata } in
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
      loop
        (message_index + 1)
        projected
        drops
        removed
        (if has_reasoning then reasoning_messages + 1 else reasoning_messages)
        rest
  in
  loop 0 [] [] [] 0 messages
;;

(* Tag-corruption causes are unexpected state and log at Warn; the other
   causes follow from a changed request and log at Info. Listing every
   constructor makes a new cause fail to compile until it is classified. *)
let is_unreadable_entry_cause = function
  | Prefix_entry_invalid | Prefix_entry_duplicate -> true
  | Prefix_source_not_present
  | Prefix_digest_absent
  | Prefix_request_mismatch
  | Prefix_chain_broken_upstream
  | Prefix_reasoning_mismatch -> false
;;

(* A dropped block is named in the log by the head of its stored message
   digest, which does not move when the history window slides. Counting
   distinct blocks cut is then a log query over this field. *)
let block_id_hex_length = 12
let dropped_block_id_sample_limit = 8

let block_id_of_digest digest =
  if String.length digest <= block_id_hex_length
  then digest
  else String.sub digest 0 block_id_hex_length
;;

let prefix_snapshot_json ~component ~stream verdict =
  let drops = verdict.prefix_drops in
  let count cause =
    List.fold_left
      (fun total drop -> if drop.cause = cause then total + 1 else total)
      0
      drops
  in
  let rec take limit acc = function
    | [] -> List.rev acc
    | _ when limit <= 0 -> List.rev acc
    | id :: rest -> take (limit - 1) (id :: acc) rest
  in
  let block_ids =
    List.filter_map
      (fun drop -> Option.map block_id_of_digest drop.stored_message_digest)
      drops
  in
  let dropped = List.length drops in
  `Assoc
    [ "event", `String "reasoning_prefix_request_snapshot"
    ; "component", `String component
    ; "stream", `Bool stream
    ; "reasoning_messages", `Int verdict.reasoning_message_count
    ; "reasoning_messages_replayed", `Int (verdict.reasoning_message_count - dropped)
    ; "reasoning_messages_dropped", `Int dropped
    ; "source_not_present", `Int (count Prefix_source_not_present)
    ; "digest_absent", `Int (count Prefix_digest_absent)
    ; "entry_invalid", `Int (count Prefix_entry_invalid)
    ; "entry_duplicate", `Int (count Prefix_entry_duplicate)
    ; "request_mismatch", `Int (count Prefix_request_mismatch)
    ; "chain_broken_upstream", `Int (count Prefix_chain_broken_upstream)
    ; "reasoning_mismatch", `Int (count Prefix_reasoning_mismatch)
    ; ( "dropped_block_ids"
      , `List
          (List.map
             (fun id -> `String id)
             (take dropped_block_id_sample_limit [] block_ids)) )
    ; ( "removed_empty_assistant_count"
      , `Int (List.length verdict.removed_empty_assistant_indices) )
    ]
;;

(* A per-request reading of the history window, not an event count: the same
   stale block is dropped again by every request that still carries it. Only
   the first mismatch of a request is [request_mismatch]. *)
let observe_prefix_drops ~component ~stream verdict =
  match verdict.prefix_drops with
  | [] when verdict.removed_empty_assistant_indices = [] -> ()
  | drops ->
    let log =
      if List.exists (fun drop -> is_unreadable_entry_cause drop.cause) drops
      then Diag.warn
      else Diag.info
    in
    log
      component
      "%s"
      (Yojson.Safe.to_string (prefix_snapshot_json ~component ~stream verdict))
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
