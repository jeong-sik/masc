(* See keeper_stream_tool_accum.mli. Kept as a parallel turn-local collector to
   [Keeper_stream_media_accum] rather than a shared abstraction, for the same
   reason that one gives: the SSE bridge owns live translation and this owns
   durable persistence, so they stay on their own side of the AGENT_CORE-stream /
   chat-store boundary. *)

type open_block = {
  opened_at : int;
  raw_call_id : string;
  raw_call_name : string;
  call_id : string;
  call_name : string;
  (* Fragments arrive in order and are concatenated at finalize; a snapshot
     replaces them because the provider sends it as the whole argument object,
     not as one more fragment. *)
  args_fragments : string list;
}

type t = {
  mutable blocks : (int * open_block) list;
  (* A conflicting start makes the whole provider block untrustworthy.  Keep
     its index closed until the matching terminator arrives; otherwise a third
     start could resurrect the first call's fragments under a new identity. *)
  mutable invalid_indices : int list;
  mutable finalized : (int * Keeper_chat_store.tool_call) list;
  mutable next_opened_at : int;
}

let create () = { blocks = []; invalid_indices = []; finalized = []; next_opened_at = 0 }

let block_for_index t index = List.assoc_opt index t.blocks

let replace_block t index block =
  t.blocks <- (index, block) :: List.remove_assoc index t.blocks

let drop_block t index = t.blocks <- List.remove_assoc index t.blocks

let invalidate_index t index =
  drop_block t index;
  if not (List.mem index t.invalid_indices)
  then t.invalid_indices <- index :: t.invalid_indices

let clear_invalid_index t index =
  t.invalid_indices <- List.filter (fun invalid -> invalid <> index) t.invalid_indices

let has_finalized_call_id t call_id =
  List.exists
    (fun (_, (call : Keeper_chat_store.tool_call)) -> String.equal call.call_id call_id)
    t.finalized

let has_open_call_id t call_id =
  List.exists
    (fun (_, block) -> String.equal block.call_id call_id)
    t.blocks

let finalize_block t index =
  match block_for_index t index with
  | None -> ()
  | Some block ->
    drop_block t index;
    let args = String.concat "" (List.rev block.args_fragments) in
    let call : Keeper_chat_store.tool_call =
      { call_id = block.call_id; call_name = block.call_name; args }
    in
    t.finalized <- (block.opened_at, call) :: t.finalized

let append_fragment t index fragment =
  match block_for_index t index with
  | None -> ()
  | Some block ->
    replace_block t index
      { block with args_fragments = fragment :: block.args_fragments }

let replace_fragments t index snapshot =
  match block_for_index t index with
  | None -> ()
  | Some block -> replace_block t index { block with args_fragments = [ snapshot ] }

(* [sse_event_is_deliverable_progress_signal] answers a [content_type = "tool_use"]
   check alone (agent_core's [Streaming.sse_event_is_deliverable_progress_signal]),
   independent of whether identity fields are populated. Keeping that check
   separate from the identity check below lets the malformed-but-tool-typed
   case (deliverable, no id/name) be told apart from a genuinely non-tool
   start (not deliverable): the bridge voids the former
   (Tool_start_missing_identity, keeper_chat_agent_core_stream_bridge.ml's
   ContentBlockStart handler) and leaves the latter's index untouched. *)
let stream_start_is_tool_progress (evt : Agent_core.Types.sse_event) =
  match evt with
  | Agent_core.Types.ContentBlockStart _ ->
    Agent_core.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal evt
  | _ -> false

let stream_start_has_tool_identity (evt : Agent_core.Types.sse_event) =
  match evt with
  | Agent_core.Types.ContentBlockStart { tool_id; tool_name; _ } -> (
    match tool_id, tool_name with
    | Some tid, Some tname
      when String.trim tid <> "" && String.trim tname <> "" -> true
    | _ -> false)
  | _ -> false

let stream_start_is_tool evt =
  stream_start_is_tool_progress evt && stream_start_has_tool_identity evt

let on_event t (evt : Agent_core.Types.sse_event) =
  match evt with
  | Agent_core.Types.ContentBlockStart { index; tool_id; tool_name; _ } ->
    if List.mem index t.invalid_indices
    then ()
    else if stream_start_is_tool evt then (
      match tool_id, tool_name with
      | Some raw_call_id, Some raw_call_name ->
        let call_id = raw_call_id in
        let call_name = String.trim raw_call_name in
        (match block_for_index t index with
      (* Providers may replay a start event after its JSON deltas. It is the
         same open block, not a replacement, so retaining it preserves the
         already received fragments. A conflicting replay is malformed and is
         dropped rather than combining two calls under one block index. *)
      (* DET-OK: these are exact equality checks on the provider's opaque
         identifiers; neither absence nor a new identity is defaulted. *)
      | Some block
        when String.equal block.raw_call_id raw_call_id
             && String.equal block.raw_call_name raw_call_name ->
        ()
      | Some _ -> invalidate_index t index
      | None when has_finalized_call_id t call_id || has_open_call_id t call_id ->
        (* A provider can replay an entire block after its stop. The live
           dashboard keys tool cards by call id, so reopening a completed or
           already-active id here would make durable reload diverge with a
           duplicate row. Keep the conflicting index closed until its own
           terminator too, so a later start cannot resurrect it under a
           second identity. *)
        invalidate_index t index
      | None ->
        let opened_at = t.next_opened_at in
        t.next_opened_at <- opened_at + 1;
        replace_block t index
          { opened_at
          ; raw_call_id
          ; raw_call_name
          ; call_id
          ; call_name
          ; args_fragments = []
          })
      | None, _ | _, None ->
        (* [stream_start_is_tool] proves this arm unreachable, but keep the
           malformed event fail-closed if the shared predicate changes. *)
        invalidate_index t index)
    else if stream_start_is_tool_progress evt
    then
      (* Deliverable tool-use content type but missing/blank identity: the
         live bridge voids this index (Tool_start_missing_identity)
         until its terminator, so a later valid start at the same index must
         not resurrect it as a fresh block. *)
      invalidate_index t index
    else
      (match tool_id, tool_name with
       | None, None ->
         (* An identity-free non-tool block leaves occupancy untouched. *)
         ()
       | Some _, _ | _, Some _ ->
         (* The live bridge voids a non-tool block carrying tool identity
            until its stop, so it cannot be reopened as a valid tool block. *)
         invalidate_index t index)
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.InputJsonDelta fragment } ->
    append_fragment t index fragment
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.InputJsonSnapshot snapshot } ->
    replace_fragments t index snapshot
  | Agent_core.Types.ContentBlockDelta { index; delta = Agent_core.Types.MediaDelta _ } ->
    (* The SSE bridge opens an [Active_media] block straight from a bare
       [MediaDelta] — no [ContentBlockStart] announces it — and then rejects a
       tool start at that index as a protocol error without emitting
       [Tool_call_start] (keeper_chat_agent_core_stream_bridge.ml, [Some (Active_media _)]
       arm). Mirror that occupancy: the index stays closed to tool starts until
       its terminator, so a reload cannot gain a tool row the live stream never
       showed. A delta landing on an already-open tool block leaves the block
       alone, matching the bridge's active-tool arm which reports the error but
       keeps the tool state. *)
    (match block_for_index t index with
     | Some _ -> ()
     | None -> invalidate_index t index)
  | Agent_core.Types.ContentBlockStop { index } ->
    if List.mem index t.invalid_indices
    then clear_invalid_index t index
    else finalize_block t index
  | Agent_core.Types.MessageStop ->
    List.iter (fun (index, _) -> finalize_block t index) t.blocks;
    t.invalid_indices <- []
  | _ -> ()
;;

let to_tool_calls t =
  t.finalized
  |> List.sort (fun (left, _) (right, _) -> Int.compare left right)
  |> List.map snd
