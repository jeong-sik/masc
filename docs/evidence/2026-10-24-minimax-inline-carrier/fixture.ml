open Carrier_slice
module Carrier = Inline_content_replay
let unwrap = function Ok value -> value | Error detail -> failwith detail
let blocks raw =
  let split = Inline_reasoning_split.create () in
  let first = Inline_reasoning_split.feed_segments split raw in
  List.map (function Inline_reasoning_split.Text text -> Text text
    | Inline_reasoning_split.Reasoning content -> Thinking {content;signature=None})
    (first @ Inline_reasoning_split.flush_segments split)
let indices content = List.mapi (fun index _ -> index) content
let witness raw_content = let content=blocks raw_content in
  content, unwrap (Carrier.make ~content ~raw_content ~block_indices:(indices content))
let () =
  let raw="before<think>one</think>middle<think>two</think>after" in
  let content, carrier=witness raw in
  let metadata=[Carrier.metadata carrier] in
  let checked_content=content@[ToolUse "call-1"] in
  let native=Thinking {content="native";signature=None} in
  let native_content=native::checked_content in
  let bound=unwrap (Carrier.make ~content:native_content ~raw_content:raw
      ~block_indices:(List.map ((+)1) (indices content))) in
  let no_native=unwrap (Carrier.retain_metadata ~original_content:native_content ~content:checked_content
      ~retained_indices:(List.mapi (fun index _ -> index+1) checked_content) [Carrier.metadata bound]) in
  let partial=List.filter_map (function Text text->Some(Text text)|_->None) content in
  let retained=List.filter_map (fun (index,block)->match block with Text _->Some index|_->None)
      (List.mapi (fun index block->index,block) content) in
  let check_partition raw =
    let expected=blocks raw in
    let all_cuts=List.init (String.length raw+1) Fun.id in
    List.for_all (fun cut ->
      let state=Inline_reasoning_split.create () in
      let first=Inline_reasoning_split.feed_segments state (String.sub raw 0 cut) in
      let second=Inline_reasoning_split.feed_segments state (String.sub raw cut (String.length raw-cut)) in
      let pieces=first@second@Inline_reasoning_split.flush_segments state in
      let pieces=List.map (function Inline_reasoning_split.Text text->Text text
        | Inline_reasoning_split.Reasoning content->Thinking {content;signature=None}) pieces in
      Result.is_ok (Carrier.make ~content:pieces ~raw_content:raw ~block_indices:(indices pieces))
      && Result.is_ok (Carrier.make ~content:expected ~raw_content:raw ~block_indices:(indices expected))) all_cuts in
  let result name value = name,`Bool value in
  let contract = Reasoning_replay_contract.{replay_policy=All_assistant_messages;
    streaming=Delta_field "reasoning_content";output_wire=Reasoning_split;content_carrier=Inline_chat_content} in
  let contract_json=Reasoning_replay_contract.to_yojson contract in
  let missing=match contract_json with `Assoc fields->`Assoc(List.remove_assoc "content_carrier" fields)|_->assert false in
  let unknown=match contract_json with `Assoc fields->`Assoc(("content_carrier",`String "unknown")::List.remove_assoc "content_carrier" fields)|_->assert false in
  let checks=[
    result "source_contract_json_round_trip" (Reasoning_replay_contract.of_yojson contract_json=Ok contract);
    result "missing_carrier_contract_is_rejected" (Result.is_error(Reasoning_replay_contract.of_yojson missing));
    result "unknown_carrier_contract_is_rejected" (Result.is_error(Reasoning_replay_contract.of_yojson unknown));
    result "carrier_contract_changes_source_semantics" (not(Reasoning_replay_contract.equal contract {contract with content_carrier=Canonical_blocks}));
    result "raw_scalar_bytes_preserved" (carrier.raw_content=raw);
    result "metadata_json_round_trip" (Carrier.of_metadata ~content (Yojson.Safe.from_string
      (Yojson.Safe.to_string (`Assoc metadata)) |> function `Assoc fields->fields|_->[]) = Ok(Some carrier));
    result "native_sidechannel_reasoning_is_unbound" (Carrier.of_metadata ~content:native_content
      [Carrier.metadata bound]=Ok(Some bound));
    result "retained_indices_remap_after_native_drop" (Carrier.of_metadata ~content:checked_content no_native=Ok(Some carrier));
    result "partial_inline_drop_removes_carrier" (Carrier.retain_metadata ~original_content:content ~content:partial
      ~retained_indices:retained metadata=Ok []);
    result "appended_uncovered_text_is_rejected" (Result.is_error(Carrier.make
      ~content:(content@[Text "new"]) ~raw_content:raw ~block_indices:(indices content)));
    result "raw_edit_is_rejected" (Result.is_error(Carrier.make ~content ~raw_content:(raw^"new") ~block_indices:(indices content)));
    result "duplicate_metadata_is_rejected" (Result.is_error(Carrier.of_metadata ~content (metadata@metadata)));
    result "duplicate_occurrence_is_rejected" (Result.is_error(Carrier.make ~content ~raw_content:raw ~block_indices:[0;0;1;2;3;4]));
    result "negative_occurrence_is_rejected" (Result.is_error(Carrier.make ~content ~raw_content:raw ~block_indices:[-1]));
    result "out_of_range_occurrence_is_rejected" (Result.is_error(Carrier.make ~content ~raw_content:raw ~block_indices:[100]));
    result "media_append_is_rejected" (Result.is_error(Carrier.make ~content:(content@[Image "image"]) ~raw_content:raw ~block_indices:(indices content)));
    result "every_tag_chunk_boundary_validates" (check_partition raw);
    result "unicode_and_whitespace_chunk_boundaries_validate" (check_partition "  <think>검토\n</think> 답변  ");
    result "unfinished_thinking_chunk_boundaries_validate" (check_partition "<think>unfinished");
    result "empty_tag_carrier_validates" (let _,value=witness "<think></think>" in value.raw_content="<think></think>");
    result "empty_scalar_is_distinct_metadata" (let _,value=witness "" in Carrier.of_metadata ~content:[] [Carrier.metadata value]=Ok(Some value))
  ] in print_endline(Yojson.Safe.to_string(`Assoc checks))
