(** See [keeper_model_input_demotion.mli] for the contract (RFC-0363). *)

(* Every demoted body is stored and previewed as opaque text. The provider
   never sees these bytes again — it sees the marker — so the media type only
   has to be the one [materialize] and the placeholder agree on, or the
   placeholder stops bounding the marker it is standing in for. *)
let demoted_mime = "text/plain"

type occurrence = int * int

type pending =
  { occurrence : occurrence
  ; original : Agent_core.Types.content_block
  ; placeholder : Agent_core.Types.content_block
  ; placeholder_sha256 : string
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
  | Agent_core.Types.ToolResult { content; content_blocks = None; _ }
    ->
    (match Tool_output.decode_from_agent_core content with
     | Tool_output.Not_marker -> Some content
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
  | (Agent_core.Types.Text _ | Agent_core.Types.Thinking _ | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _ | Agent_core.Types.Document _ | Agent_core.Types.Audio _) as other -> other
;;

(* Addressing uses this exact preview and byte count. SHA256 hex digits have
   equal encoded width, so the digest placeholder needs no body hashing.
   Measuring the store's real preview avoids rejecting useful demotions due
   to a worst-case preview that this body will never produce. *)
let planned_marker ~sha256 ~bytes =
  match
    Tool_output.make_artifact_ref
      ~sha256
      ~bytes:(String.length bytes)
      ~preview:(Tool_blob_store.make_preview bytes)
      ~mime:demoted_mime
  with
  | Ok reference -> Some (Tool_output.encode_for_agent_core (Tool_output.Stored reference))
  | Error _ ->
    (* Unreachable with the arguments above, but a total match keeps a future
       validation rule in [make_artifact_ref] from silently disabling
       demotion — [None] skips this body rather than demoting it unbounded. *)
    None
;;

let plan ?(demote_from = 0) ~measure_message_bytes ~demote_before messages =
  let labelled, _atom_count = Runtime_model_input_tail_window.annotate messages in
  if demote_before <= demote_from
  then { messages; pending = [] }
  else (
    let pending = ref [] in
    let changed = ref false in
    let rewritten =
      List.mapi
        (fun message_index ((message : Agent_core.Types.message), label) ->
           let aged =
             match label with
             | Runtime_model_input_tail_window.Pinned -> false
             | Runtime_model_input_tail_window.Atom index ->
               demote_from <= index && index < demote_before
           in
           if not aged
           then message
           else (
             (* Per-message staging: the candidate and the entries it would add
                are decided together, so a candidate that is rejected leaves no
                pending entry behind. *)
             let staged = ref [] in
             let content =
               List.mapi
                 (fun block_index block ->
                    match demotable_body block with
                    | None -> block
                    | Some body ->
                      (* A bounded, distinct lookup token for this plan, not a
                         content address. All digest hex digits encode with
                         equal width. Physical block identity remains the
                         authority when materializing the token. *)
                      let placeholder_sha256 =
                        Printf.sprintf "%032x%032x" message_index block_index
                      in
                      (match planned_marker ~sha256:placeholder_sha256 ~bytes:body with
                       | None -> block
                       | Some marker ->
                         let placeholder = with_content block marker in
                         staged :=
                           { occurrence = message_index, block_index
                           ; original = block; placeholder; placeholder_sha256
                           ; bytes = body } :: !staged;
                         placeholder))
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

(* Positions keep memo lookup independent of body size and of how often a
   provider reuses a tool ID. The original immutable block guards each hit:
   a rewritten prefix at the same position must be addressed again. *)
type memo_entry =
  { original : Agent_core.Types.content_block
  ; address : Tool_blob_store.addressed
  }

type address_memo = (occurrence, memo_entry) Hashtbl.t

let create_address_memo () = Hashtbl.create 64

let materialize ~store ~addresses ~pending messages =
  if pending = []
  then { messages; reverted = 0 }
  else (
    let placeholders = Hashtbl.create (List.length pending) in
    List.iter
      (fun (entry : pending) ->
         Hashtbl.add placeholders entry.placeholder_sha256 entry)
      pending;
    let planned_entry (block : Agent_core.Types.content_block) =
      match block with
      | Agent_core.Types.ToolResult { content; content_blocks = None; _ } ->
        (match Tool_output.decode_from_agent_core content with
         | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> None
         | Tool_output.Decoded reference ->
           (match Hashtbl.find_opt placeholders reference.Tool_output.sha256 with
            | Some entry when block == entry.placeholder -> Some entry
            | Some _ | None -> None))
      | Agent_core.Types.ToolResult { content_blocks = Some _; _ }
      | Agent_core.Types.Text _
      | Agent_core.Types.Thinking _
      | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.ToolUse _
      | Agent_core.Types.Image _
      | Agent_core.Types.Document _
      | Agent_core.Types.Audio _ -> None
    in
    let address_of (entry : pending) =
      match Hashtbl.find_opt addresses entry.occurrence with
      | Some memo when memo.original == entry.original -> Some memo.address
      | Some _ | None -> None
    in
    (* Only retained placeholders need addressing. The queue is keyed by
       occurrence, so even repeated IDs with equal previews stay independent.
       Hashing stays in the CPU pool; writes remain on the owning fiber. *)
    let queued = Hashtbl.create 16 in
    List.iter
      (fun (message : Agent_core.Types.message) ->
         List.iter
           (fun block ->
              match planned_entry block with
              | None -> ()
              | Some entry ->
                (match address_of entry with
                 | Some _ -> ()
                 | None -> Hashtbl.replace queued entry.occurrence entry))
           message.content)
      messages;
    List.iter
      (fun (occurrence, memo) -> Hashtbl.replace addresses occurrence memo)
      (match Hashtbl.fold (fun _ entry acc -> entry :: acc) queued [] with
       | [] -> []
       | _ :: _ as to_address ->
         Domain_pool_ref.submit_cpu_or_inline (fun () ->
           List.map
             (fun (entry : pending) ->
                entry.occurrence,
                { original = entry.original
                ; address = Tool_blob_store.address store ~bytes:entry.bytes ~mime:demoted_mime
                })
             to_address));
    let reverted = ref 0 in
    let messages =
      List.map
        (fun (message : Agent_core.Types.message) ->
           let content =
             List.map
               (fun block ->
                  match planned_entry block with
                  | None -> block
                  | Some entry ->
                    (match address_of entry with
                     | None ->
                       incr reverted;
                       entry.original
                     | Some address ->
                       (match Tool_blob_store.put_addressed address with
                        | Tool_output.Stored _ as stored ->
                          with_content block (Tool_output.encode_for_agent_core stored)
                        | exception Sys_error _ ->
                          incr reverted;
                          entry.original)))
               message.content
           in
           { message with content })
        messages
    in
    { messages; reverted = !reverted })
;;
