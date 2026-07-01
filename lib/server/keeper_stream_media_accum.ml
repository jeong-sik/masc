(* RFC-0301 item 6 — see keeper_stream_media_accum.mli. Mirrors the media chunk
   accumulation the SSE bridge does ([Keeper_chat_oas_stream_bridge]'s
   [Active_media] block), kept as a parallel turn-local collector rather than a
   shared abstraction so the bridge (which owns live SSE translation) and this
   collector (which owns durable persistence) stay on their own side of the
   OAS-stream / chat-store boundary. *)

(* Attach-block label for generated media with no dedicated image/voice reload
   block (documents, unrecognized types). The payload is still persisted and served
   by token, so this keeps it visible on reload rather than dropping it silently. *)
let generic_media_label = "generated media"

type finalized = {
  index : int;
  media_type : string;
  source_type : Agent_sdk.Types.media_source_kind;
  data : string;
}

type block_state =
  | Active_media of
      { media_type : string;
        source_type : Agent_sdk.Types.media_source_kind;
        chunks : string list;
        encoded_bytes : int
      }
  | Invalid_block

type t = {
  mutable blocks_by_index : (int * block_state) list;
  mutable finalized_rev : finalized list;
}

let create () = { blocks_by_index = []; finalized_rev = [] }

let stream_block_for_index t index = List.assoc_opt index t.blocks_by_index

let replace_block t index block =
  t.blocks_by_index <- (index, block) :: List.remove_assoc index t.blocks_by_index

let remove_block t index =
  t.blocks_by_index <- List.remove_assoc index t.blocks_by_index

let has_any_tool_identity ~tool_id ~tool_name =
  match tool_id, tool_name with
  | None, None -> false
  | _ -> true

let stream_start_is_tool ~index ~content_type ~tool_id ~tool_name =
  Agent_sdk.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal
    (Agent_sdk.Types.ContentBlockStart
       { index; content_type; tool_id; tool_name })

let add_media_chunk ~media_type ~source_type ~chunks ~encoded_bytes data =
  let encoded_bytes = encoded_bytes + String.length data in
  if encoded_bytes > Keeper_chat_media_store.max_wire_bytes ()
  then None
  else Some (Active_media { media_type; source_type; chunks = data :: chunks; encoded_bytes })

let finalize_media t index ~media_type ~source_type ~chunks ~encoded_bytes =
  if encoded_bytes <= Keeper_chat_media_store.max_wire_bytes () then (
    let data = String.concat "" (List.rev chunks) in
    t.finalized_rev <- { index; media_type; source_type; data } :: t.finalized_rev);
  remove_block t index

let finalize_open_media t =
  let blocks = t.blocks_by_index in
  List.iter
    (fun (index, block) ->
      match block with
      | Active_media { media_type; source_type; chunks; encoded_bytes } ->
          finalize_media t index ~media_type ~source_type ~chunks ~encoded_bytes
      | Invalid_block -> ())
    blocks;
  t.blocks_by_index <- []

let on_event t (evt : Agent_sdk.Types.sse_event) =
  match evt with
  | Agent_sdk.Types.ContentBlockStart { index; content_type; tool_id; tool_name }
    when stream_start_is_tool ~index ~content_type ~tool_id ~tool_name
         || has_any_tool_identity ~tool_id ~tool_name ->
      replace_block t index Invalid_block
  | Agent_sdk.Types.ContentBlockDelta
      { index; delta = Agent_sdk.Types.MediaDelta { media_type; source_type; data } } ->
      (match stream_block_for_index t index with
       | Some (Active_media m)
         when String.equal m.media_type media_type && m.source_type = source_type ->
           (match
              add_media_chunk ~media_type ~source_type ~chunks:m.chunks
                ~encoded_bytes:m.encoded_bytes data
            with
            | Some block -> replace_block t index block
            | None -> replace_block t index Invalid_block)
       | Some (Active_media _) ->
           ()
       | Some Invalid_block ->
           ()
       | None ->
           (match
              add_media_chunk ~media_type ~source_type ~chunks:[]
                ~encoded_bytes:0 data
            with
            | Some block -> replace_block t index block
            | None -> replace_block t index Invalid_block))
  | Agent_sdk.Types.ContentBlockStop { index } -> (
      match stream_block_for_index t index with
      | Some (Active_media { media_type; source_type; chunks; encoded_bytes }) ->
          finalize_media t index ~media_type ~source_type ~chunks ~encoded_bytes
      | Some Invalid_block ->
          remove_block t index
      | None -> ())
  | Agent_sdk.Types.MessageStop ->
      finalize_open_media t
  | _ -> ()

let to_chat_blocks ~base_dir t =
  List.rev t.finalized_rev
  |> List.filter_map (fun { index; media_type; source_type; data } ->
         match
           Keeper_chat_media_store.persist_media_source_result ~base_dir
             ~media_type ~source_type ~data
         with
         | Error err ->
             Log.Keeper.warn
               "generated media reload persist failed index=%d media_type=%s source_type=%s: %s"
               index
               media_type
               (Agent_sdk.Types.media_source_kind_to_string source_type)
               (Keeper_chat_media_store.persist_error_to_string err);
             None
         | Ok (_token, media_ref) ->
             match Keeper_chat_media_store.category_of_media_type media_type with
             | Keeper_chat_media_store.Image ->
                 Some (Keeper_chat_blocks.Image { src = media_ref; cap = None })
             | Keeper_chat_media_store.Audio ->
                 Some
                   (Keeper_chat_blocks.Voice
                      { secs = None;
                        wave = None;
                        via = None;
                        size = None;
                        transcript = None;
                        src = Some media_ref
                      })
             | Keeper_chat_media_store.Document | Keeper_chat_media_store.Other ->
                 Some
                   (Keeper_chat_blocks.Attach
                      { name = generic_media_label;
                        dims = None;
                        src = Some media_ref;
                        svg = None;
                        ph = None;
                        via = None;
                        size = None;
                        data = None;
                        mime_type = Some media_type;
                        size_bytes = None;
                        kind = None
                      }))
