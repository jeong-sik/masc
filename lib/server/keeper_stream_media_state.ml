type finalized = {
  index : int;
  media_type : string;
  source : Llm_provider.Types.media_source;
}

type wire_drop = {
  media_type : string;
  encoded_bytes : int;
  max_wire_bytes : int;
}

type completed =
  | Persistable of finalized
  | Wire_dropped of wire_drop

type active_media = {
  media_type : string;
  chunks : Agent_core.Types.media_chunks;
  encoded_bytes : int;
}

type invalid_reason =
  | Tool_block
  | Oversize

type block_state =
  | Active_media of active_media
  | Invalid_block of invalid_reason
  | Closed_block

type terminal =
  | Stop_reason of Agent_core.Types.stop_reason
  | Message_stop

type stream_phase =
  | Accepting_content
  | Terminal of terminal

type t = {
  blocks_by_index : (int * block_state) list;
  completed_rev : completed list;
  current_stream_scope : int option;
  stream_phase : stream_phase;
  runtime_attempt_seen : bool;
  max_wire_bytes : int;
}

type metadata_drift = {
  index : int;
  expected_media_type : string;
  received_media_type : string;
  expected_source_type : Agent_core.Types.media_source_kind;
  received_source_type : Agent_core.Types.media_source_kind;
}

type pending_media = {
  index : int;
  media : active_media;
  max_wire_bytes : int;
}

type event_result =
  | Unchanged
  | Updated of t
  | Metadata_drift of metadata_drift
  | Wire_rejected of int * wire_drop
  | Finalize of pending_media list * terminal option

let create ~max_wire_bytes =
  { blocks_by_index = [];
    completed_rev = [];
    current_stream_scope = None;
    stream_phase = Accepting_content;
    runtime_attempt_seen = false;
    max_wire_bytes
  }

let start_runtime_attempt t =
  if t.runtime_attempt_seen
  then
    { t with
      blocks_by_index = [];
      current_stream_scope = None;
      stream_phase = Accepting_content
    }
  else { t with runtime_attempt_seen = true }

let enter_stream_scope t stream_scope =
  match t.current_stream_scope with
  | Some current when current = stream_scope -> t
  | None -> { t with current_stream_scope = Some stream_scope }
  | Some _ ->
    { t with
      blocks_by_index = [];
      current_stream_scope = Some stream_scope;
      stream_phase = Accepting_content
    }

let replace_block t index block =
  { t with
    blocks_by_index = (index, block) :: List.remove_assoc index t.blocks_by_index
  }

let record_completed t completed =
  { t with completed_rev = completed :: t.completed_rev }

let close_block t index = replace_block t index Closed_block
let reject_block t index = replace_block t index (Invalid_block Oversize)
let finish_message t terminal = { t with stream_phase = Terminal terminal }
let completed t = List.rev t.completed_rev

let stream_start_is_tool ~index ~content_type ~tool_id ~tool_name =
  Agent_core.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal
    (Agent_core.Types.ContentBlockStart
       { index; content_type; tool_id; tool_name })

(* [chunks] already holds [chunk]; [chunk] counts toward the wire cap. *)
let add_media_chunk (t : t) ~index ~media_type ~chunks ~encoded_bytes chunk =
  let encoded_bytes =
    encoded_bytes + String.length (Agent_core.Types.media_source_payload chunk)
  in
  let max_wire_bytes = t.max_wire_bytes in
  if encoded_bytes > max_wire_bytes
  then Wire_rejected (index, { media_type; encoded_bytes; max_wire_bytes })
  else
    Updated
      (replace_block t index
         (Active_media { media_type; chunks; encoded_bytes }))

let capture_media (t : t) index media =
  { index; media; max_wire_bytes = t.max_wire_bytes }

let capture_open_media t =
  (* Snapshot before any finalization: an observer cannot replace the block
     entries whose terminal event is already being processed. *)
  List.sort
    (fun (left_index, _) (right_index, _) -> Int.compare left_index right_index)
    t.blocks_by_index
  |> List.filter_map (fun (index, block) ->
       match block with
       | Active_media media -> Some (capture_media t index media)
       | Invalid_block (Tool_block | Oversize) | Closed_block -> None)

let finalize_media { index; media; max_wire_bytes } =
  let { media_type; chunks; encoded_bytes } = media in
  if encoded_bytes > max_wire_bytes
  then Error (index, { media_type; encoded_bytes; max_wire_bytes })
  else Ok { index; media_type; source = Agent_core.Types.media_chunks_source chunks }

let discard_current_scope t =
  (* Completed delivery evidence survives later failure or supersession. *)
  Updated { t with blocks_by_index = [] }

let on_event t (evt : Agent_core.Types.sse_event) =
  match evt with
  | Agent_core.Types.ContentBlockStart { index; content_type; tool_id; tool_name }
    when t.stream_phase = Accepting_content
         && stream_start_is_tool ~index ~content_type ~tool_id ~tool_name ->
      Updated (replace_block t index (Invalid_block Tool_block))
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.MediaDelta { media_type; source } } ->
      if t.stream_phase <> Accepting_content
      then Unchanged
      else
        (match List.assoc_opt index t.blocks_by_index with
         | Some (Active_media active) ->
             let added =
               if String.equal active.media_type media_type
               then Agent_core.Types.media_chunks_add active.chunks source
               else None
             in
             (match added with
              | Some chunks ->
                  add_media_chunk t ~index ~media_type ~chunks
                    ~encoded_bytes:active.encoded_bytes source
              | None ->
                  Metadata_drift
                    { index;
                      expected_media_type = active.media_type;
                      received_media_type = media_type;
                      expected_source_type = Agent_core.Types.media_chunks_kind active.chunks;
                      received_source_type =
                        Agent_core.Types.media_source_kind_of_source source
                    })
         | Some (Invalid_block (Tool_block | Oversize) | Closed_block) -> Unchanged
         | None ->
             add_media_chunk t ~index ~media_type
               ~chunks:(Agent_core.Types.media_chunks_start source) ~encoded_bytes:0 source)
  | Agent_core.Types.ContentBlockStop { index } ->
      if t.stream_phase = Terminal Message_stop
      then Unchanged
      else
        (match List.assoc_opt index t.blocks_by_index with
         | Some (Active_media media) -> Finalize ([ capture_media t index media ], None)
         | Some (Invalid_block (Tool_block | Oversize) | Closed_block) | None ->
             Unchanged)
  | Agent_core.Types.MessageDelta { stop_reason; _ } ->
      (match t.stream_phase, stop_reason with
       | Accepting_content, None -> Unchanged
       | Accepting_content, Some stop_reason ->
           Finalize (capture_open_media t, Some (Stop_reason stop_reason))
       | Terminal (Stop_reason _), None -> Unchanged
       | Terminal (Stop_reason recorded), Some replay when recorded = replay ->
           Unchanged
       | Terminal (Stop_reason _), Some _
       | Terminal Message_stop, None
       | Terminal Message_stop, Some _ -> discard_current_scope t)
  | Agent_core.Types.MessageStop ->
      (match t.stream_phase with
       | Terminal Message_stop -> Unchanged
       | Accepting_content | Terminal (Stop_reason _) ->
           Finalize (capture_open_media t, Some Message_stop))
  | Agent_core.Types.SSEError _
  | Agent_core.Types.NDJSONError _
  | Agent_core.Types.SSEParseFailed _
  | Agent_core.Types.NDJSONParseFailed _
  | Agent_core.Types.SSEUnknownEventType _
  | Agent_core.Types.SSEUnsupportedPart _
  | Agent_core.Types.SSEUnsupportedResponse _
  | Agent_core.Types.Timeout _ -> discard_current_scope t
  | Agent_core.Types.StreamIncomplete _
  | Agent_core.Types.MessageStart _
  | Agent_core.Types.ContentBlockStart _
  | Agent_core.Types.ContentBlockDelta
      { delta =
          ( Agent_core.Types.TextDelta _
          | Agent_core.Types.TextSnapshot _
          | (Agent_core.Types.ThinkingDelta _ | Agent_core.Types.ThinkingSnapshot _)
          | Agent_core.Types.ThinkingSignatureDelta _
          | Agent_core.Types.RedactedThinkingSnapshot _
          | Agent_core.Types.ReasoningDetailsDelta _
          | Agent_core.Types.InputJsonDelta _
          | Agent_core.Types.InputJsonSnapshot _ )
      ; _
      }
  | Agent_core.Types.Connected
  | Agent_core.Types.InlineContentReplay _ | Agent_core.Types.ResponsesOutputItems _
  | Agent_core.Types.Ping -> Unchanged
