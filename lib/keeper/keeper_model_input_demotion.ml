(** See [keeper_model_input_demotion.mli] for the contract (RFC-0363). *)

(* Every demoted body is stored and previewed as opaque text. The provider
   never sees these bytes again — it sees the marker — so the media type only
   has to be the one [materialize] and the placeholder agree on, or the
   placeholder stops bounding the marker it is standing in for. *)
let demoted_mime = "text/plain"

type pending =
  { tool_use_id : string
  ; bytes : string
  }

type plan_result =
  { messages : Agent_core.Types.message list
  ; pending : pending list
  }

type materialize_outcome =
  { messages : Agent_core.Types.message list
  ; reverted : int
  }

(* A body is demotable only in the shape the provider encoder actually
   serializes. [content_blocks = Some] makes [content] dead weight that is
   never emitted (agent_core api_common.ml: the [Some] arm maps the blocks and
   drops [content]), so rewriting it would free nothing while the caller
   credited a saving — an under-estimate, which is the direction that lets a
   materialized request exceed the cap. [Invalid_marker] is marker-shaped
   content that failed to parse; storing it would give a corrupt payload a
   permanent content address, so it is left untouched and stays visible. *)
let demotable_body (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.ToolResult { tool_use_id; content; content_blocks = None; _ }
    ->
    (match Tool_output.decode_from_agent_core content with
     | Tool_output.Not_marker -> Some (tool_use_id, content)
     | Tool_output.Decoded _ | Tool_output.Invalid_marker _ -> None)
  | Agent_core.Types.ToolResult { content_blocks = Some _; _ }
  | Agent_core.Types.Text _
  | Agent_core.Types.Thinking _
  | Agent_core.Types.ReasoningDetails _
  | Agent_core.Types.RedactedThinking _
  | Agent_core.Types.ToolUse _
  | Agent_core.Types.Image _
  | Agent_core.Types.Document _
  | Agent_core.Types.Audio _ -> None
;;

let with_content (block : Agent_core.Types.content_block) replacement =
  match block with
  | Agent_core.Types.ToolResult fields ->
    Agent_core.Types.ToolResult { fields with content = replacement }
  | other -> other
;;

(* The placeholder saturates every variable-length field the real marker can
   carry: an all-'f' digest is the widest hex, [Tool_blob_store.preview_max]
   bytes of 0xFF is the widest preview after [encode_for_agent_core] escapes it and
   the JSON encoder escapes the escapes, and the byte count is the true one so
   its decimal width is exact. The result is therefore never shorter than the
   marker [materialize] will produce for the same body. *)
let saturating_marker ~bytes =
  match
    Tool_output.make_artifact_ref
      ~sha256:(String.make 64 'f')
      ~bytes:(String.length bytes)
      ~preview:(String.make Tool_blob_store.preview_max '\255')
      ~mime:demoted_mime
  with
  | Ok reference -> Some (Tool_output.encode_for_agent_core (Tool_output.Stored reference))
  | Error _ ->
    (* Unreachable with the arguments above, but a total match keeps a future
       validation rule in [make_artifact_ref] from silently disabling
       demotion — [None] skips this body rather than demoting it unbounded. *)
    None
;;

let plan ~measure_message_bytes ~demote_before messages =
  let labelled, _atom_count = Runtime_model_input_tail_window.annotate messages in
  if demote_before <= 0
  then { messages; pending = [] }
  else (
    let pending = ref [] in
    let changed = ref false in
    let rewritten =
      List.map
        (fun ((message : Agent_core.Types.message), label) ->
           let aged =
             match label with
             | Runtime_model_input_tail_window.Pinned -> false
             | Runtime_model_input_tail_window.Atom index -> index < demote_before
           in
           if not aged
           then message
           else (
             (* Per-message staging: the candidate and the entries it would add
                are decided together, so a candidate that is rejected leaves no
                pending entry behind. *)
             let staged = ref [] in
             let content =
               List.map
                 (fun block ->
                    match demotable_body block with
                    | None -> block
                    | Some (tool_use_id, body) ->
                      (match saturating_marker ~bytes:body with
                       | None -> block
                       | Some placeholder ->
                         staged := { tool_use_id; bytes = body } :: !staged;
                         with_content block placeholder))
                 message.content
             in
             if !staged = []
             then message
             else (
               let candidate = { message with content } in
               (* Compare whole messages, not bodies: the encoder frames a tool
                  result differently per provider style, and an escaped marker
                  can exceed a short body. A candidate that does not shrink
                  this message is discarded. *)
               if measure_message_bytes candidate < measure_message_bytes message
               then (
                 changed := true;
                 pending := List.rev_append !staged !pending;
                 candidate)
               else message)))
        labelled
    in
    if !changed
    then { messages = rewritten; pending = List.rev !pending }
    else { messages; pending = [] })
;;

let materialize ~store ~pending messages =
  if pending = []
  then { messages; reverted = 0 }
  else (
    let body_of id =
      List.find_map
        (fun entry ->
           if String.equal entry.tool_use_id id then Some entry.bytes else None)
        pending
    in
    let reverted = ref 0 in
    let messages =
      List.map
        (fun (message : Agent_core.Types.message) ->
           let content =
             List.map
               (fun block ->
                  match block with
                  | Agent_core.Types.ToolResult
                      { tool_use_id; content; content_blocks = None; _ }
                    when Tool_output.is_marker content ->
                    (match body_of tool_use_id with
                     | None -> block
                     | Some body ->
                       (match
                          Tool_blob_store.put store ~bytes:body ~mime:demoted_mime
                        with
                        | Tool_output.Stored _ as stored ->
                          with_content block (Tool_output.encode_for_agent_core stored)
                        | Tool_output.Inline _ ->
                          (* The store declined to externalize. Emitting a
                             marker for bytes it did not persist would dangle,
                             so the body goes back. *)
                          incr reverted;
                          with_content block body
                        (* [put] documents Sys_error as its failure mode
                           (disk full, EACCES). Anything else is not a storage
                           outcome and must not be turned into one here. *)
                        | exception Sys_error _ ->
                          incr reverted;
                          with_content block body))
                  | _ -> block)
               message.content
           in
           { message with content })
        messages
    in
    { messages; reverted = !reverted })
;;
