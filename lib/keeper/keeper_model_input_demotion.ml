(** See [keeper_model_input_demotion.mli] for the contract (RFC-0363). *)

type occurrence = int * int

let compare_occurrence (m1, b1) (m2, b2) =
  let c = Int.compare m1 m2 in
  if c <> 0 then c else Int.compare b1 b2

module Occurrences = Map.Make (struct
  type t = occurrence
  let compare = compare_occurrence
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

(* Where one stored body sits in its block. A [ToolResult] has its [content],
   and one whose [content_blocks] is [Some] also has each [Text] block, named
   by its index among the blocks. Which of them reaches the wire depends on the
   provider encoder, so every one is a body of its own (RFC-0363 §3.1.2). *)
type payload_kind =
  | Result_body
  | Result_text_block of int
  | Call_arguments

let payload_mime = function
  | Result_body | Result_text_block _ -> "text/plain"
  | Call_arguments -> "application/json"
;;

let compare_payload_kind left right =
  match left, right with
  | Result_body, Result_body | Call_arguments, Call_arguments -> 0
  | Result_text_block left, Result_text_block right -> Int.compare left right
  | Result_body, (Result_text_block _ | Call_arguments)
  | Result_text_block _, Call_arguments -> -1
  | Result_text_block _, Result_body
  | Call_arguments, (Result_body | Result_text_block _) -> 1
;;

(* One body: the block it belongs to and its place in that block. A result
   has one slot for [content] and one for each demoted [Text] block. *)
type slot = occurrence * payload_kind

module Slots = Map.Make (struct
  type t = slot

  let compare (left_occurrence, left_kind) (right_occurrence, right_kind) =
    let c = compare_occurrence left_occurrence right_occurrence in
    if c <> 0 then c else compare_payload_kind left_kind right_kind
end)

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

(* [Invalid_marker] is marker-shaped text that failed to parse; storing it
   would give a corrupt payload a permanent content address, so it is left
   untouched and stays visible. *)
let demotable_text text =
  match Tool_output.decode_from_agent_core text with
  | Tool_output.Not_marker -> true
  | Tool_output.Decoded _ | Tool_output.Invalid_marker _ -> false
;;

(* The [Text] blocks of a result's [content_blocks], each with its index. A
   result's blocks hold text and media only: every producer builds them from
   MCP text, image and audio content or from a built-in tool's text and image,
   so no [ToolResult] nests inside one. *)
let inner_texts blocks =
  List.concat
    (List.mapi
       (fun index (inner : Agent_core.Types.content_block) ->
          match inner with
          | Agent_core.Types.Text text -> [ index, text ]
          | Agent_core.Types.Thinking _ | Agent_core.Types.ReasoningDetails _
          | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ToolUse _
          | Agent_core.Types.ToolResult _ | Agent_core.Types.Image _
          | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> [])
       blocks)
;;

(* The text one result carries on one lane: [content], or with [Some] the
   longer of [content] and the sum of its [Text] blocks. [min_bytes] checks
   the whole result, as it checks a result whose blocks are [None], so a
   result whose text is split over small blocks is as large as its sum. *)
let result_text_bytes ~content texts =
  max (String.length content)
    (List.fold_left (fun sum (_index, text) -> sum + String.length text) 0 texts)
;;

(* The text bodies of a block that some provider encoder serializes: a
   result's [content], and with [Some] each of its [Text] blocks. Which of
   them a given provider sends is the lane's measure to say ([plan]). Each is
   a candidate once the result reaches [min_bytes]. An image, document or
   audio block has no marker form and keeps its place. *)
let demotable_bodies ~min_bytes (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.ToolResult { content; content_blocks; _ } ->
    let texts = Option.fold ~none:[] ~some:inner_texts content_blocks in
    if result_text_bytes ~content texts < min_bytes
    then []
    else
      (if demotable_text content then [ Result_body, content ] else [])
      @ List.filter_map
          (fun (index, text) ->
             if demotable_text text then Some (Result_text_block index, text) else None)
          texts
  | Agent_core.Types.Text _
  | Agent_core.Types.Thinking _
  | Agent_core.Types.ReasoningDetails _
  | Agent_core.Types.RedactedThinking _
  | Agent_core.Types.ToolUse _
  | Agent_core.Types.Image _
  | Agent_core.Types.Document _
  | Agent_core.Types.Audio _ -> []
;;

(* The block with its [index]-th tool-result block replaced; [None] when the
   block has no such slot. *)
let with_result_block index replacement (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.ToolResult ({ content_blocks = Some blocks; _ } as fields)
    when index < List.length blocks ->
    Some
      (Agent_core.Types.ToolResult
         { fields with
           content_blocks =
             Some (List.mapi (fun at inner -> if Int.equal at index then replacement else inner) blocks)
         })
  | Agent_core.Types.ToolResult { content_blocks = Some _ | None; _ }
  | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
  | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
  | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _
  | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> None
;;

(* The block with its tool-result [content] replaced; [None] when the block
   is not a tool result. *)
let with_result_content content (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.ToolResult fields -> Some (Agent_core.Types.ToolResult { fields with content })
  | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
  | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
  | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _
  | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> None
;;

(* The block with the slot [kind] names holding [reference]; [None] when the
   block has no such slot. [plan] names only slots it read from the same
   block. *)
let with_reference kind (block : Agent_core.Types.content_block) reference =
  let marker () = Tool_output.encode_for_agent_core (Tool_output.Stored reference) in
  match kind with
  | Result_body -> with_result_content (marker ()) block
  | Result_text_block index -> with_result_block index (Agent_core.Types.Text (marker ())) block
  | Call_arguments ->
    (match block with
     | Agent_core.Types.ToolUse fields ->
       Some
         (Agent_core.Types.ToolUse
            { fields with input = Tool_output.normalized_artifact_ref_to_json reference })
     | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
     | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
     | Agent_core.Types.ToolResult _ | Agent_core.Types.Image _
     | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> None)
;;

(* Addressing and planning use the same preview, MIME and byte count. Fixed
   width hex digits give the planned reference the real address's wire size. *)
let planned_reference ~kind ~sha256 ~bytes =
  Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length bytes)
    ~preview:(Tool_blob_store.make_preview bytes) ~mime:(payload_mime kind)
  |> Result.to_option
;;

(* Whether a marker in one body made the lane's request smaller. A body the
   lane does not send leaves its bytes equal, and a marker longer than the
   body once the lane has escaped both makes them grow; neither is kept. A
   measure the lane refused keeps nothing. *)
let shrinks_on_the_wire ~before ~after =
  match before, after with
  | Some before, Some after -> after < before
  | Some (_ : int), None | None, (Some _ | None) -> false
;;

let plan ?(completed_arguments = Occurrences.empty) ?(min_result_bytes = 0)
    ~measure_message_bytes ~measure_wire_bytes ~demote_before messages =
  let labelled, _atom_count = Runtime_model_input_tail_window.annotate messages in
  if demote_before <= 0 && Occurrences.is_empty completed_arguments
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
               index < demote_before
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
                    let payloads =
                      match Occurrences.find_opt (message_index, block_index) completed_arguments with
                      | Some (original, bytes) when original == block -> [ Call_arguments, bytes ]
                      | Some _ | None ->
                        if aged then demotable_bodies ~min_bytes:min_result_bytes block else []
                    in
                    (* A bounded, distinct lookup token for this plan, not a
                       content address. All digest hex digits encode with
                       equal width. A [Text] block's token opens with [f],
                       which a whole block's never does, so the two never
                       share a token. Physical block identity remains the
                       authority when materializing the token. *)
                    let placeholder_sha256 = function
                      | Result_body | Call_arguments ->
                        Printf.sprintf "%032x%032x" message_index block_index
                      | Result_text_block index ->
                        Printf.sprintf "f%021x%021x%021x" message_index block_index index
                    in
                    (* A result body is kept as a marker only when the lane's
                       request for this block alone shrinks with it, each body
                       measured on top of the ones already kept: the lane
                       decides which bodies it sends and how often it escapes
                       them. Arguments are the whole input and keep the
                       per-message comparison alone. *)
                    let wire_bytes candidate =
                      measure_wire_bytes { message with content = [ candidate ] }
                    in
                    let placeholder, _wire, planned =
                      List.fold_left
                        (fun ((current, wire, planned) as unchanged) (kind, body) ->
                           let token = placeholder_sha256 kind in
                           match
                             Option.bind
                               (planned_reference ~kind ~sha256:token ~bytes:body)
                               (with_reference kind current)
                           with
                           | None -> unchanged
                           | Some candidate ->
                             (match kind with
                              | Call_arguments -> candidate, wire, (kind, body, token) :: planned
                              | Result_body | Result_text_block _ ->
                                let before = Lazy.force wire in
                                let after = wire_bytes candidate in
                                if shrinks_on_the_wire ~before ~after
                                then candidate, Lazy.from_val after, (kind, body, token) :: planned
                                else unchanged))
                        (block, lazy (wire_bytes block), [])
                        payloads
                    in
                    match planned with
                    | [] -> block
                    | _ :: _ ->
                      staged :=
                        List.rev_append
                          (List.rev_map
                             (fun (kind, body, token) ->
                                { occurrence = message_index, block_index
                                ; original = block; placeholder; placeholder_sha256 = token
                                ; bytes = body; kind })
                             planned)
                          !staged;
                      placeholder)
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

type address_memo = (slot, memo_entry) Hashtbl.t

let create_address_memo () = Hashtbl.create 64

module Sha256_map = Map.Make (String)

(* The entries whose placeholder is this exact block. A result carries one
   placeholder marker per demoted body, its [content] and each demoted [Text]
   block, so it has one entry per body; a call has at most one. *)
let pending_lookup pending =
    let placeholders =
      List.fold_left
        (fun acc (entry : pending) ->
           let prior =
             match Sha256_map.find_opt entry.placeholder_sha256 acc with
             | Some entries -> entries
             | None -> []
           in
           Sha256_map.add entry.placeholder_sha256 (entry :: prior) acc)
        Sha256_map.empty
        pending
    in
    let marker_reference text =
      match Tool_output.decode_from_agent_core text with
      | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> None
      | Tool_output.Decoded reference -> Some reference
    in
    let planned_entries (block : Agent_core.Types.content_block) =
      let references =
        match block with
        | Agent_core.Types.ToolResult { content; content_blocks; _ } ->
          let inner_references =
            match content_blocks with
            | None -> []
            | Some blocks ->
              List.filter_map
                (fun (inner : Agent_core.Types.content_block) ->
                   match inner with
                   | Agent_core.Types.Text text -> marker_reference text
                   | Agent_core.Types.Thinking _ | Agent_core.Types.ReasoningDetails _
                   | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ToolUse _
                   | Agent_core.Types.ToolResult _ | Agent_core.Types.Image _
                   | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> None)
                blocks
          in
          Option.to_list (marker_reference content) @ inner_references
        | Agent_core.Types.ToolUse { input; _ } ->
          (match Tool_output.normalized_artifact_ref_of_json input with
           | Tool_output.Not_normalized_artifact_ref
           | Tool_output.Invalid_normalized_artifact_ref _ -> []
           | Tool_output.Decoded_normalized_artifact_ref reference -> [ reference ])
        | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
        | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ReasoningDetails _
        | Agent_core.Types.Image _ | Agent_core.Types.Document _
        | Agent_core.Types.Audio _ -> []
      in
      List.concat_map
        (fun reference ->
           match Sha256_map.find_opt reference.Tool_output.sha256 placeholders with
           | Some entries ->
             List.filter (fun (entry : pending) -> block == entry.placeholder) entries
           | None -> [])
        references
    in
    planned_entries
;;

(* Outcomes are kept per block: every entry of one block shares its
   occurrence, original and placeholder, and the materialized block holds all
   of its slots at once. *)
type materialized_replay =
  (Agent_core.Types.content_block * Agent_core.Types.content_block) Occurrences.t

let capture_materialized ~pending ~before ~after =
  let lookup = pending_lookup pending in
  let rec blocks outcomes before after =
    match before, after with
    | [], [] -> Some outcomes
    | block :: before, replacement :: after ->
      (match lookup block with
       | entry :: _ ->
         blocks (Occurrences.add entry.occurrence (entry.original, replacement) outcomes) before after
       | [] -> if block = replacement then blocks outcomes before after else None)
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
      | [] -> block
      | entry :: _ ->
        (match Option.bind captured (Occurrences.find_opt entry.occurrence) with
         | Some (original, replacement) when original == entry.original -> replacement
         | Some _ | None -> entry.original)) message.content in
    {message with content}) messages
;;

let materialize ~store ~addresses ~pending messages =
  if pending = []
  then { messages; reverted = 0 }
  else (
    let planned_entries = pending_lookup pending in
    let slot_of (entry : pending) = entry.occurrence, entry.kind in
    let address_of (entry : pending) =
      match Hashtbl.find_opt addresses (slot_of entry) with
      | Some memo when memo.original == entry.original -> Some memo.address
      | Some _ | None -> None
    in
    (* Only retained placeholders need addressing. The queue is keyed by
       slot, so even repeated IDs with equal previews stay independent, and
       so do the [Text] blocks of one result.
       Hashing stays in the CPU pool; writes remain on the owning fiber. *)
    let queued =
      List.fold_left
        (fun acc (message : Agent_core.Types.message) ->
           List.fold_left
             (fun acc block ->
                List.fold_left
                  (fun acc entry ->
                     match address_of entry with
                     | Some _ -> acc
                     | None -> Slots.add (slot_of entry) entry acc)
                  acc
                  (planned_entries block))
             acc
             message.content)
        Slots.empty
        messages
    in
    List.iter
      (fun (slot, memo) -> Hashtbl.replace addresses slot memo)
      (match Slots.fold (fun _ entry acc -> entry :: acc) queued [] with
       | [] -> []
       | _ :: _ as to_address ->
         Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
           List.map
             (fun (entry : pending) ->
                slot_of entry,
                { original = entry.original
                ; address = Tool_blob_store.address store ~bytes:entry.bytes ~mime:(payload_mime entry.kind)
                })
             to_address));
    (* A placeholder's block is built again from its original, with a real
       marker in each slot whose body was written. A slot whose write failed
       is never touched, so it keeps the original body and the result's other
       slots keep the markers that were written. [plan] read every slot from
       this same original, so a slot it cannot find again is a broken plan. *)
    let reverted = ref 0 in
    let written (entry : pending) current reference =
      match with_reference entry.kind current reference with
      | Some block -> block
      | None ->
        invalid_arg
          "Keeper_model_input_demotion.materialize: a planned slot is not in its original block"
    in
    let messages =
      List.map
        (fun (message : Agent_core.Types.message) ->
           let content =
             List.map
               (fun block ->
                  match planned_entries block with
                  | [] -> block
                  | (first : pending) :: _ as entries ->
                    List.fold_left
                      (fun current (entry : pending) ->
                         match address_of entry with
                         | None ->
                           incr reverted;
                           current
                         | Some address ->
                           (match Tool_blob_store.put_addressed address with
                            | Tool_output.Stored reference -> written entry current reference
                            | exception Sys_error _ ->
                              incr reverted;
                              current))
                      first.original
                      entries)
               message.content
           in
           { message with content })
        messages
    in
    { messages; reverted = !reverted })
;;
