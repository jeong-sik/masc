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

(* A generated media payload the wire cap rejected. Recorded the moment the
   block is invalidated so the drop surfaces as a reload-visible placeholder
   block instead of the media silently vanishing from the persisted turn. *)
type wire_drop = {
  media_type : string;
  encoded_bytes : int;
  max_wire_bytes : int;
}

type completed =
  | Persistable of finalized
  | Wire_dropped of wire_drop

(* Why a block index stopped accepting media deltas. [Tool_block] indexes are
   never media and are skipped without trace (mirrors the SSE bridge);
   [Oversize] is a real generated payload the reader must still learn about. *)
type invalid_reason =
  | Tool_block
  | Oversize

type block_state =
  | Active_media of
      { media_type : string;
        source_type : Agent_sdk.Types.media_source_kind;
        chunks : string list;
        encoded_bytes : int
      }
  | Invalid_block of invalid_reason

type t = {
  mutable blocks_by_index : (int * block_state) list;
  mutable completed_rev : completed list;
}

let create () = { blocks_by_index = []; completed_rev = [] }

let record_oversize_drop t ~index ~media_type ~encoded_bytes ~max_wire_bytes =
  Log.Keeper.warn
    "generated media dropped index=%d media_type=%S: %d wire-carrier bytes exceed the %d-byte cap"
    index
    media_type
    encoded_bytes
    max_wire_bytes;
  t.completed_rev <-
    Wire_dropped { media_type; encoded_bytes; max_wire_bytes }
    :: t.completed_rev

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
  let max_wire_bytes = Keeper_chat_media_store.max_wire_bytes () in
  if encoded_bytes > max_wire_bytes
  then Error (encoded_bytes, max_wire_bytes)
  else
    Ok
      (Active_media
         { media_type; source_type; chunks = data :: chunks; encoded_bytes })

let finalize_media t index ~media_type ~source_type ~chunks ~encoded_bytes =
  let max_wire_bytes = Keeper_chat_media_store.max_wire_bytes () in
  if encoded_bytes > max_wire_bytes
  then
    record_oversize_drop t ~index ~media_type ~encoded_bytes ~max_wire_bytes
  else (
    let data = String.concat "" (List.rev chunks) in
    t.completed_rev <-
      Persistable { index; media_type; source_type; data } :: t.completed_rev);
  remove_block t index

let finalize_open_media t =
  (* [MessageStop] terminalizes every still-open block at once. Content-block
     index is the protocol order and therefore the deterministic tie-breaker. *)
  let blocks =
    List.sort
      (fun (left_index, _) (right_index, _) ->
         Int.compare left_index right_index)
      t.blocks_by_index
  in
  List.iter
    (fun (index, block) ->
      match block with
      | Active_media { media_type; source_type; chunks; encoded_bytes } ->
          finalize_media t index ~media_type ~source_type ~chunks ~encoded_bytes
      | Invalid_block (Tool_block | Oversize) -> ())
    blocks;
  t.blocks_by_index <- []

let on_event t (evt : Agent_sdk.Types.sse_event) =
  match evt with
  | Agent_sdk.Types.ContentBlockStart { index; content_type; tool_id; tool_name }
    when stream_start_is_tool ~index ~content_type ~tool_id ~tool_name
         || has_any_tool_identity ~tool_id ~tool_name ->
      replace_block t index (Invalid_block Tool_block)
  | Agent_sdk.Types.ContentBlockDelta
      { index; delta = Agent_sdk.Types.MediaDelta { media_type; source_type; data } } ->
      (match stream_block_for_index t index with
       | Some (Active_media m)
         when String.equal m.media_type media_type && m.source_type = source_type ->
           (match
              add_media_chunk ~media_type ~source_type ~chunks:m.chunks
                ~encoded_bytes:m.encoded_bytes data
            with
            | Ok block -> replace_block t index block
            | Error (encoded_bytes, max_wire_bytes) ->
                record_oversize_drop t ~index ~media_type ~encoded_bytes
                  ~max_wire_bytes;
                replace_block t index (Invalid_block Oversize))
       | Some (Active_media active) ->
           Log.Keeper.warn
             "generated media metadata drift ignored index=%d expected_media_type=%S received_media_type=%S expected_source_type=%s received_source_type=%s"
             index
             active.media_type
             media_type
             (Agent_sdk.Types.media_source_kind_to_string active.source_type)
             (Agent_sdk.Types.media_source_kind_to_string source_type)
       | Some (Invalid_block _) ->
           ()
       | None ->
           (match
              add_media_chunk ~media_type ~source_type ~chunks:[]
                ~encoded_bytes:0 data
            with
            | Ok block -> replace_block t index block
            | Error (encoded_bytes, max_wire_bytes) ->
                record_oversize_drop t ~index ~media_type ~encoded_bytes
                  ~max_wire_bytes;
                replace_block t index (Invalid_block Oversize)))
  | Agent_sdk.Types.ContentBlockStop { index } -> (
      match stream_block_for_index t index with
      | Some (Active_media { media_type; source_type; chunks; encoded_bytes }) ->
          finalize_media t index ~media_type ~source_type ~chunks ~encoded_bytes
      | Some (Invalid_block (Tool_block | Oversize)) ->
          remove_block t index
      | None -> ())
  | Agent_sdk.Types.MessageStop ->
      finalize_open_media t
  | _ -> ()

(* Reload placeholder for an oversize drop: no payload to serve (src = None),
   but the reader sees what was generated, its type, and how large it was
   instead of the media silently missing from the persisted turn. *)
let unavailable_attachment ~name ~media_type ~size ~size_bytes =
  Keeper_chat_blocks.Attach
    { name;
      dims = None;
      src = None;
      svg = None;
      ph = Some "Generated media is unavailable.";
      via = None;
      size;
      data = None;
      mime_type = Some media_type;
      size_bytes;
      kind = None
    }

let wire_drop_placeholder_block
    { media_type; encoded_bytes; max_wire_bytes } =
  unavailable_attachment
    ~name:
      (Printf.sprintf
         "generated media unavailable: %s exceeded the %d-byte wire-carrier cap"
         media_type
         max_wire_bytes)
    ~media_type
    ~size:(Some (Printf.sprintf "%d wire-carrier bytes observed" encoded_bytes))
    ~size_bytes:(Some encoded_bytes)

let persist_failure_placeholder ~media_type ~encoded_bytes = function
  | Keeper_chat_media_store.Unsupported_source_type source_type ->
      unavailable_attachment
        ~name:
          (Printf.sprintf
             "generated media unavailable: unsupported source type %s"
             (Agent_sdk.Types.media_source_kind_to_string source_type))
        ~media_type
        ~size:(Some (Printf.sprintf "%d wire-carrier bytes observed" encoded_bytes))
        ~size_bytes:(Some encoded_bytes)
  | Keeper_chat_media_store.Invalid_base64 _ ->
      unavailable_attachment
        ~name:"generated media unavailable: provider returned invalid base64"
        ~media_type
        ~size:(Some (Printf.sprintf "%d wire-carrier bytes observed" encoded_bytes))
        ~size_bytes:(Some encoded_bytes)
  | Keeper_chat_media_store.Media_too_large { size_bytes; max_bytes } ->
      unavailable_attachment
        ~name:
          (Printf.sprintf
             "generated media unavailable: decoded payload exceeded the %d-byte storage cap"
             max_bytes)
        ~media_type
        ~size:(Some (Printf.sprintf "%d decoded bytes observed" size_bytes))
        ~size_bytes:(Some size_bytes)
  | Keeper_chat_media_store.Write_failed _ ->
      unavailable_attachment
        ~name:"generated media unavailable: storage write failed"
        ~media_type
        ~size:(Some (Printf.sprintf "%d wire-carrier bytes observed" encoded_bytes))
        ~size_bytes:(Some encoded_bytes)

let persisted_block ~media_type media_ref =
  match Keeper_chat_media_store.category_of_media_type media_type with
  | Keeper_chat_media_store.Image ->
      Keeper_chat_blocks.Image { src = media_ref; cap = None }
  | Keeper_chat_media_store.Audio ->
      Keeper_chat_blocks.Voice
        { secs = None;
          wave = None;
          via = None;
          size = None;
          transcript = None;
          src = Some media_ref
        }
  | Keeper_chat_media_store.Document | Keeper_chat_media_store.Other ->
      Keeper_chat_blocks.Attach
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
        }

let completed_to_chat_block ~base_dir = function
  | Wire_dropped dropped -> wire_drop_placeholder_block dropped
  | Persistable { index; media_type; source_type; data } ->
      (match
         Keeper_chat_media_store.persist_media_source_result ~base_dir
           ~media_type ~source_type ~data
       with
       | Ok (_token, media_ref) -> persisted_block ~media_type media_ref
       | Error err ->
           Log.Keeper.warn
             "generated media reload persist failed index=%d media_type=%S source_type=%s: %s"
             index
             media_type
             (Agent_sdk.Types.media_source_kind_to_string source_type)
             (Keeper_chat_media_store.persist_error_to_string err);
           persist_failure_placeholder
             ~media_type
             ~encoded_bytes:(String.length data)
             err)

let to_chat_blocks ~base_dir t =
  t.completed_rev
  |> List.rev
  |> List.map (completed_to_chat_block ~base_dir)
