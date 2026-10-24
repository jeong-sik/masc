open Fixture_support
open Types
module Lower = Message_origin_lowering
module Prefix = Prefix_slice
let policy = Lower.Turn_scoped_system_context
let msg ?(origin=Conversation) ?(metadata=[]) role content =
  make_message ~role ~origin ~metadata content
let unwrap = function Ok value -> value | Error error -> failwith (Lower.error_to_string error)
let lower messages = (unwrap (Lower.lower policy messages)).messages
let encode_block = function
  | Text text -> `Assoc ["type",`String "text";"text",`String text]
  | Thinking text -> `Assoc ["type",`String "thinking";"thinking",`String text;"signature",`String "fixture-signature"]
  | ToolUse id -> `Assoc ["type",`String "tool_use";"id",`String id]
  | ToolResult id -> `Assoc ["type",`String "tool_result";"tool_use_id",`String id]
  | _ -> failwith "fixture encoder supports only exercised blocks"
let header = Lower.anthropic_message_header policy
let fold ?(message_header=header) messages =
  Prefix.verify_prefix_binding ~head:["system",`String "fixture prompt"] ~encode_block ~message_header messages
let wire message = `Assoc (header message @ ["content",`List (List.map encode_block message.content)])
let () =
  let caller = msg User [Text "inspect"] in
  let fresh = msg ~origin:System_context User [Text "workspace one"] in
  let historical = {fresh with origin=Historical_system_context} in
  let first = lower [caller;fresh] in
  let content = [Thinking "planning";ToolUse "call-1"] in
  let stamp = Reasoning_prefix.{request_digest=(fold first).final_digest;
    message_digest=Prefix.content_wire_digest ~encode_block content} in
  let assistant = msg ~metadata:(("fixture.source",`Bool true)::Reasoning_prefix.metadata stamp) Assistant content in
  let result = msg Tool [ToolResult "call-1"] in
  let next = msg ~origin:System_context User [Text "workspace two"] in
  let canonical = [caller;historical;assistant;result;next] in
  let lowered = lower canonical in
  let verified = fold lowered in
  let changed = lower [caller;{historical with content=[Text "edited old context"]};assistant;result;next] in
  let changed_header message = List.remove_assoc "clear_at" (header message) in
  let orphan = msg Assistant [Thinking "orphan"] in
  let empty = fold (lower [caller;fresh;orphan;caller]) in
  let valid messages = Result.is_ok (Lower.lower policy messages) in
  let headers_body = Yojson.Safe.to_string (`Assoc ["messages",`List (List.map wire first)]) in
  let beta_headers = Header_slice.request_headers ~body:headers_body ["Anthropic-Beta","custom-beta"] in
  let betas = List.assoc "anthropic-beta" beta_headers |> String.split_on_char ',' in
  let binding_body = Yojson.Safe.to_string (`Assoc ["messages",`List (List.map wire first);
    "thinking",`Assoc ["block_binding",`Assoc []]]) in
  let binding_betas = Header_slice.request_headers ~body:binding_body beta_headers
    |> List.assoc "anthropic-beta" |> String.split_on_char ',' in
  let native_caps = Capabilities.{reasoning_replay_override=Force_turn_scoped_system_context_preserve_always} in
  let declaration codec = Lower.policy_for_provider_config Provider_config.{codec;capabilities=Some native_caps} in
  let old_stamp = msg ~metadata:["fixture.source",`Bool true;
    "agent_core.reasoning_prefix.v1", Reasoning_prefix.to_json stamp] Assistant content in
  let checks = [
    "fresh_historical_wire_identical", wire (List.nth first 1) = wire (List.nth lowered 1);
    "source_coordinates_preserved", (unwrap (Lower.lower policy canonical)).source_indices=[0;1;2;3;4];
    "canonical_origin_and_role_unchanged", historical.origin=Historical_system_context && historical.role=User;
    "context_header_scopes_next_user", header (List.nth lowered 1) = ["role",`String "system";"clear_at",`String "next_user_message"];
    "tool_continuation_retains_thinking", verified.prefix_drops=[] && (List.nth verified.messages 2).content=content;
    "text_edit_invalidates_creation_prefix", (fold changed).prefix_drops<>[];
    "header_edit_invalidates_creation_prefix", (fold ~message_header:changed_header lowered).prefix_drops<>[];
    "old_stamp_is_not_v2_certification", (fold (first@[old_stamp])).prefix_drops<>[];
    "removed_assistant_has_no_phantom_header", (fold [caller;orphan]).final_digest=(fold [caller]).final_digest;
    "post_prefix_placement_requires_revalidation", Result.is_error (Lower.validate_turn_scoped_contexts policy empty.messages);
    "leading_context_rejected", not (valid [fresh;caller]);
    "context_after_assistant_rejected", not (valid [caller;msg Assistant [Text "answer"];fresh]);
    "context_before_user_rejected", not (valid [caller;fresh;caller]);
    "context_between_tool_use_and_result_rejected", not (valid [caller;assistant;fresh;result]);
    "consecutive_context_group_accepted", valid [caller;fresh;historical];
    "nontext_context_rejected", not (valid [caller;{fresh with content=[Thinking "not text"]}]);
    "default_positions_unchanged", (unwrap (Lower.lower Lower.Preserve_positions canonical)).messages=canonical;
    "native_policy_is_declared", declaration Anthropic_messages=Ok policy;
    "wrong_codec_rejected", declaration Openai_chat=Error Lower.Unsupported_codec;
    "count_body_without_thinking_adds_beta", List.mem "mid-conversation-system-clear-at-2026-08-21" betas;
    "caller_beta_preserved", List.mem "custom-beta" betas;
    "binding_and_context_betas_coexist", List.mem "thinking-binding-controls-2026-08-01" binding_betas
      && List.mem "mid-conversation-system-clear-at-2026-08-21" binding_betas;
    "beta_merge_idempotent", Header_slice.request_headers ~body:headers_body beta_headers=beta_headers;
    "ordinary_body_has_no_extra_beta", Header_slice.request_headers ~body:"{\"messages\":[]}" []=[]
  ] in
  print_endline (Yojson.Safe.to_string (`Assoc (List.map (fun (name,value)->name,`Bool value) checks)))
