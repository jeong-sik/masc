(* See keeper_stream_tool_accum.mli. Kept as a parallel turn-local collector to
   [Keeper_stream_media_accum] rather than a shared abstraction, for the same
   reason that one gives: the SSE bridge owns live translation and this owns
   durable persistence, so they stay on their own side of the OAS-stream /
   chat-store boundary. *)

type open_block = {
  call_id : string option;
  call_name : string option;
  (* Fragments arrive in order and are concatenated at finalize; a snapshot
     replaces them because the provider sends it as the whole argument object,
     not as one more fragment. *)
  args_fragments : string list;
}

type t = {
  mutable blocks : (int * open_block) list;
  mutable finalized : Keeper_chat_store.tool_call list;
}

let create () = { blocks = []; finalized = [] }

let block_for_index t index = List.assoc_opt index t.blocks

let replace_block t index block =
  t.blocks <- (index, block) :: List.remove_assoc index t.blocks

let drop_block t index = t.blocks <- List.remove_assoc index t.blocks

(* A block with no call id cannot be joined to its output row, so it is dropped
   rather than persisted as an anonymous step. The name alone does not identify
   which of several same-named calls produced which result. *)
let finalize_block t index =
  match block_for_index t index with
  | None -> ()
  | Some block ->
    drop_block t index;
    (match block.call_id with
     | None -> ()
     | Some call_id ->
       let args = String.concat "" (List.rev block.args_fragments) in
       let call : Keeper_chat_store.tool_call =
         { call_id
         ; call_name = Option.value block.call_name ~default:""
         ; args
         }
       in
       t.finalized <- call :: t.finalized)

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

let stream_start_is_tool (evt : Agent_sdk.Types.sse_event) =
  match evt with
  | Agent_sdk.Types.ContentBlockStart { content_type; tool_id; tool_name; _ } ->
    Agent_sdk.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal evt
    &&
    (match tool_id, tool_name with
     | Some tid, Some tname
       when String.trim tid <> "" && String.trim tname <> "" -> true
     | _ -> false)
  | _ -> false

let on_event t (evt : Agent_sdk.Types.sse_event) =
  match evt with
  | Agent_sdk.Types.ContentBlockStart { index; tool_id; tool_name; _ } ->
    if stream_start_is_tool evt then
      replace_block t index
        { call_id = tool_id; call_name = tool_name; args_fragments = [] }
    else
      drop_block t index
  | Agent_sdk.Types.ContentBlockDelta
      { index; delta = Agent_sdk.Types.InputJsonDelta fragment } ->
    append_fragment t index fragment
  | Agent_sdk.Types.ContentBlockDelta
      { index; delta = Agent_sdk.Types.InputJsonSnapshot snapshot } ->
    replace_fragments t index snapshot
  | Agent_sdk.Types.ContentBlockStop { index } -> finalize_block t index
  | Agent_sdk.Types.MessageStop ->
    List.iter (fun (index, _) -> finalize_block t index) t.blocks
  | _ -> ()
;;

let to_tool_calls t = List.rev t.finalized
