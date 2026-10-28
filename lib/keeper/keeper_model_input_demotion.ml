(** See [keeper_model_input_demotion.mli] for the contract (RFC-0363). *)

type occurrence = int * int

module Occurrences = Map.Make (struct
  type t = occurrence
  let compare = Stdlib.compare
end)

type completed_arguments =
  (Agent_core.Types.content_block * string) Occurrences.t

let prepend_argument_messages ~prefix arguments =
  let offset = List.length prefix in
  Occurrences.fold (fun (message_index, block_index) value shifted ->
    Occurrences.add (message_index + offset, block_index) value shifted)
    arguments Occurrences.empty
;;

let protect_argument_prefix ~through_message arguments =
  Occurrences.filter (fun (message_index, _) _ -> message_index > through_message) arguments
;;

type argument_binding_error =
  | Invalid_argument_seed of Keeper_transcript_unit.structural_error
  | Argument_seed_prefix_mismatch of Keeper_replay_prefix.prefix_mismatch
  | Argument_replay_prefix_mismatch of Keeper_replay_prefix.restore_error
  | Argument_occurrence_mismatch

let tool_uses (message : Agent_core.Types.message) =
  List.mapi (fun index block -> index, block) message.content
  |> List.filter (fun (_, block) ->
    match block with
    | Agent_core.Types.ToolUse _ -> true
    | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
    | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
    | Agent_core.Types.ToolResult _ | Agent_core.Types.Image _
    | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> false)
;;

let bind_completed_arguments ~completed_before ~seed ~replay_prefix messages =
  let open Result.Syntax in
  (* A cycle can span more than one atom when ordinary Assistant messages
     occur between its ToolUse and final ToolResult. Restrict the source
     before partitioning: an opener below the boundary is insufficient. *)
  let labelled_seed, _ = Runtime_model_input_tail_window.annotate seed in
  let rec completed_prefix = function
    | [] -> []
    | (message, Runtime_model_input_tail_window.Pinned) :: rest ->
      message :: completed_prefix rest
    | (message, Runtime_model_input_tail_window.Atom index) :: rest
        when index < completed_before -> message :: completed_prefix rest
    | (_, Runtime_model_input_tail_window.Atom _) :: _ -> []
  in
  let* partition =
    Keeper_transcript_unit.partition ~quarantine:true (completed_prefix labelled_seed)
    |> Result.map_error (fun error -> Invalid_argument_seed error)
  in
  let closed =
    List.concat_map Keeper_transcript_unit.messages_of_closed_unit partition.closed_prefix
  in
  let* canonical =
    Keeper_replay_prefix.restore_messages replay_prefix messages
    |> Result.map_error (fun error -> Argument_replay_prefix_mismatch error)
  in
  let* _suffix =
    Keeper_replay_prefix.split ~prefix:closed canonical
    |> Result.map_error (fun error -> Argument_seed_prefix_mismatch error)
  in
  let labelled, _ = Runtime_model_input_tail_window.annotate closed in
  let rec bind_blocks message_index arguments expected actual =
    match expected, actual with
    | [], [] -> Ok arguments
    | (_, source) :: expected, (block_index, target) :: actual when source = target ->
      let arguments =
        match target with
        | Agent_core.Types.ToolUse { input; _ } ->
          (match Tool_output.normalized_artifact_ref_of_json input with
           | Tool_output.Not_normalized_artifact_ref ->
             Occurrences.add (message_index, block_index)
               (target, Yojson.Safe.to_string input) arguments
           | Tool_output.Invalid_normalized_artifact_ref _
           | Tool_output.Decoded_normalized_artifact_ref _ -> arguments)
        | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
        | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
        | Agent_core.Types.ToolResult _ | Agent_core.Types.Image _
        | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> arguments
      in
      bind_blocks message_index arguments expected actual
    | [], _ :: _ | _ :: _, [] | _ :: _, _ :: _ ->
      Error Argument_occurrence_mismatch
  in
  let rec bind_messages message_index arguments labelled actual =
    match labelled, actual with
    | [], _ -> Ok arguments
    | _ :: _, [] -> Error Argument_occurrence_mismatch
    | (source, label) :: rest, target :: actual ->
      let* arguments =
        match label with
        | Runtime_model_input_tail_window.Pinned -> Ok arguments
        | Runtime_model_input_tail_window.Atom index ->
          if index < completed_before
          then bind_blocks message_index arguments (tool_uses source) (tool_uses target)
          else Ok arguments
      in
      bind_messages (message_index + 1) arguments rest actual
  in
  bind_messages 0 Occurrences.empty labelled messages
;;

type payload_kind = Result_body | Call_arguments

let payload_mime = function
  | Result_body -> "text/plain"
  | Call_arguments -> "application/json"
;;

type pending =
  { occurrence : occurrence
  ; original : Agent_core.Types.content_block
  ; placeholder : Agent_core.Types.content_block
  ; placeholder_sha256 : string
  ; bytes : string
  ; kind : payload_kind
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

let with_reference (block : Agent_core.Types.content_block) reference =
  match block with
  | Agent_core.Types.ToolResult fields ->
    Agent_core.Types.ToolResult
      { fields with content = Tool_output.encode_for_agent_core (Tool_output.Stored reference) }
  | Agent_core.Types.ToolUse fields ->
    Agent_core.Types.ToolUse
      { fields with input = Tool_output.normalized_artifact_ref_to_json reference }
  | (Agent_core.Types.Text _ | Agent_core.Types.Thinking _
    | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
    | Agent_core.Types.Image _ | Agent_core.Types.Document _
    | Agent_core.Types.Audio _) as other -> other
;;

(* Addressing and planning use the same preview, MIME and byte count. Fixed
   width hex digits give the planned reference the real address's wire size. *)
let planned_reference ~kind ~sha256 ~bytes =
  Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length bytes)
    ~preview:(Tool_blob_store.make_preview bytes) ~mime:(payload_mime kind)
  |> Result.to_option
;;

let plan ?(completed_arguments = Occurrences.empty) ?(demote_from = 0)
    ~measure_message_bytes ~demote_before messages =
  let labelled, _atom_count = Runtime_model_input_tail_window.annotate messages in
  if demote_before <= demote_from && Occurrences.is_empty completed_arguments
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
           if not aged && Occurrences.is_empty completed_arguments then message
           else
           (
             (* Per-message staging: the candidate and the entries it would add
                are decided together, so a candidate that is rejected leaves no
                pending entry behind. *)
             let staged = ref [] in
             let content =
               List.mapi
                 (fun block_index block ->
                    let payload =
                      match Occurrences.find_opt (message_index, block_index) completed_arguments with
                      | Some (original, bytes) when original == block -> Some (Call_arguments, bytes)
                      | Some _ | None ->
                        if aged then Option.map (fun bytes -> Result_body, bytes) (demotable_body block)
                        else None
                    in
                    match payload with
                    | None -> block
                    | Some (kind, body) ->
                      (* A bounded, distinct lookup token for this plan, not a
                         content address. All digest hex digits encode with
                         equal width. Physical block identity remains the
                         authority when materializing the token. *)
                      let placeholder_sha256 =
                        Printf.sprintf "%032x%032x" message_index block_index
                      in
                      (match planned_reference ~kind ~sha256:placeholder_sha256 ~bytes:body with
                       | None -> block
                       | Some reference ->
                         let placeholder = with_reference block reference in
                         staged :=
                           { occurrence = message_index, block_index
                           ; original = block; placeholder; placeholder_sha256
                           ; bytes = body; kind } :: !staged;
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

let pending_lookup pending =
    let placeholders = Hashtbl.create (List.length pending) in
    List.iter
      (fun (entry : pending) ->
         Hashtbl.add placeholders entry.placeholder_sha256 entry)
      pending;
    let planned_entry (block : Agent_core.Types.content_block) =
      let reference =
        match block with
        | Agent_core.Types.ToolResult { content; content_blocks = None; _ } ->
          (match Tool_output.decode_from_agent_core content with
           | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> None
           | Tool_output.Decoded reference -> Some reference)
        | Agent_core.Types.ToolUse { input; _ } ->
          (match Tool_output.normalized_artifact_ref_of_json input with
           | Tool_output.Not_normalized_artifact_ref
           | Tool_output.Invalid_normalized_artifact_ref _ -> None
           | Tool_output.Decoded_normalized_artifact_ref reference -> Some reference)
        | Agent_core.Types.ToolResult { content_blocks = Some _; _ }
        | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
        | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ReasoningDetails _
        | Agent_core.Types.Image _ | Agent_core.Types.Document _
        | Agent_core.Types.Audio _ -> None
      in
      Option.bind reference (fun reference ->
        match Hashtbl.find_opt placeholders reference.Tool_output.sha256 with
        | Some entry when block == entry.placeholder -> Some entry
        | Some _ | None -> None)
    in
    planned_entry
;;

type materialized_replay =
  (Agent_core.Types.content_block * Agent_core.Types.content_block) Occurrences.t

let capture_materialized ~pending ~before ~after =
  let lookup = pending_lookup pending in
  let rec blocks outcomes before after =
    match before, after with
    | [], [] -> Some outcomes
    | block :: before, replacement :: after ->
      (match lookup block with
       | Some entry ->
         blocks (Occurrences.add entry.occurrence (entry.original, replacement) outcomes) before after
       | None -> if block = replacement then blocks outcomes before after else None)
    | [], _ :: _ | _ :: _, [] -> None
  in
  let rec messages outcomes before after =
    match before, after with
    | [], [] -> Some outcomes
    | (original : Agent_core.Types.message) :: before,
      (materialized : Agent_core.Types.message) :: after ->
      if original.role <> materialized.role || original.name <> materialized.name
         || original.tool_call_id <> materialized.tool_call_id
         || original.metadata <> materialized.metadata then None
      else Option.bind (blocks outcomes original.content materialized.content)
        (fun outcomes -> messages outcomes before after)
    | [], _ :: _ | _ :: _, [] -> None
  in
  messages Occurrences.empty before after
;;

let replay_materialized captured ~pending messages =
  let lookup = pending_lookup pending in
  List.map (fun (message : Agent_core.Types.message) ->
    let content = List.map (fun block ->
      match lookup block with
      | None -> block
      | Some entry ->
        (match Option.bind captured (Occurrences.find_opt entry.occurrence) with
         | Some (original, replacement) when original == entry.original -> replacement
         | Some _ | None -> entry.original)) message.content in
    {message with content}) messages
;;

let materialize ~store ~addresses ~pending messages =
  if pending = []
  then { messages; reverted = 0 }
  else (
    let planned_entry = pending_lookup pending in
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
         Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
           List.map
             (fun (entry : pending) ->
                entry.occurrence,
                { original = entry.original
                ; address = Tool_blob_store.address store ~bytes:entry.bytes ~mime:(payload_mime entry.kind)
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
                        | Tool_output.Stored reference -> with_reference block reference
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
