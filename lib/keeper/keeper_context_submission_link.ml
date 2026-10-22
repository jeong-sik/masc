module Assembly = Keeper_context_assembly
module Write = Runtime_official_client_write

type unavailable_reason =
  | Missing_issuer
  | Issuer_has_no_carrier
  | Stale_issuer
  | Invalid_subset
  | Unsupported_carrier
  | Invalid_provenance
  | Trimmed_occurrence

type evidence =
  | Not_applicable
  | Verified of Yojson.Safe.t
  | Unavailable of unavailable_reason

type disposition = Delivered | Omitted_held
type acquisition = { disposition : disposition; evidence : evidence }

type occurrence =
  { offset : int
  ; bytes : int
  ; proof : Yojson.Safe.t
  }

type t =
  { text : string
  ; occurrences : occurrence list
  ; omitted : Yojson.Safe.t list
  ; acquisitions : acquisition list
  }

let hash text = Digestif.SHA256.(digest_string text |> to_hex)
let literal text = { text; occurrences = []; omitted = []; acquisitions = [] }
let text t = t.text

(* The text a selected block renders: all of it, or for the [Dynamic_context]
   block, its renderer's sections without the ones a resume left out, and of a
   section a resume sent in part, its head, the rows it did not leave out and
   its tail. A left-out section or row the partition does not name makes the
   selection invalid. *)
let selected_block_text assembly ~omitted_sections ~omitted_rows (id, text) =
  match id with
  | Prompt_block_id.Dynamic_context when omitted_sections <> [] || omitted_rows <> [] ->
    Option.bind (Assembly.dynamic_context_sections assembly) (fun sections ->
      let names source =
        List.exists
          (fun (section : Keeper_context_layers.section) ->
             section.Keeper_context_layers.section_source = source)
          sections
      in
      let rendered (section : Keeper_context_layers.section) =
        if List.mem section.Keeper_context_layers.section_source omitted_sections then Some ""
        else
          match List.assoc_opt section.section_source omitted_rows, section.section_rows with
          | None, (Keeper_context_layers.Whole_section | Keeper_context_layers.Head_and_rows _) ->
            Some section.section_text
          | Some digests, Keeper_context_layers.Head_and_rows { head; rows; tail } ->
            let named = List.map (fun row -> hash row, row) rows in
            if List.for_all (fun digest -> List.mem_assoc digest named) digests
            then
              Some
                (head
                 ^ String.concat ""
                     (List.filter_map
                        (fun (digest, row) -> if List.mem digest digests then None else Some row)
                        named)
                 ^ tail)
            else None
          | Some _, Keeper_context_layers.Whole_section -> None
      in
      if List.for_all names omitted_sections
         && List.for_all (fun (source, _) -> names source) omitted_rows
      then
        let texts = List.map rendered sections in
        if List.exists Option.is_none texts
        then None
        else Some (String.concat "" (List.filter_map Fun.id texts))
      else None)
  | Prompt_block_id.(
      Dynamic_context | Keeper_instructions | Temporal_summary | Memory_os_recall
      | Librarian_working_context | Operator_note | Skill_compositions) -> Some text

let source assembly selected_blocks ~omitted_sections ~omitted_rows
    (message : Agent_core.Types.message) =
  let omits = omitted_sections <> [] || omitted_rows <> [] in
  let inspect assembly actual =
    match assembly.Assembly.extra_system_context, assembly.receipt with
    | Some original, Some receipt ->
      let selected =
        match selected_blocks with
        | None when actual = original && not omits ->
          Some (List.mapi (fun i _ -> i) receipt.spans)
        | None -> None
        | Some ids ->
          (match Assembly.blocks_for_carrier assembly original with
           | None -> None
           | Some blocks ->
             let wanted = List.filter
                 (fun (id, _) -> List.exists (Prompt_block_id.equal id) ids) blocks in
             let texts =
               List.map (selected_block_text assembly ~omitted_sections ~omitted_rows) wanted
             in
             if List.map fst wanted <> ids
                || (omits
                    && not (List.exists (Prompt_block_id.equal Prompt_block_id.Dynamic_context) ids))
                || List.exists Option.is_none texts
                || String.concat "\n\n" (List.filter_map Fun.id texts) <> actual
             then None
             else
               Some (List.filter_map (fun (i, (span : Assembly.span)) ->
                 match span.kind with
                 | Block id when List.exists (Prompt_block_id.equal id) ids -> Some i
                 | Block _ | Unattributed _ -> None) (List.mapi (fun i span -> i, span) receipt.spans)))
      in
      (match selected with
       | None ->
         Unavailable (match selected_blocks with None -> Stale_issuer | Some _ -> Invalid_subset)
       | Some indices ->
         Verified (`Assoc (
           [ "assembly", Assembly.receipt_to_json receipt
           ; "source_span_indices", `List (List.map (fun i -> `Int i) indices)
           ; "rendered_text_bytes", `Int (String.length actual)
           ; "rendered_text_sha256", `String (hash actual)
           ; "rendering", `String (match selected_blocks, omitted_sections, omitted_rows with
               | None, _, _ -> "whole_carrier"
               | Some _, [], [] -> "ordered_blocks_joined_by_two_newlines"
               | Some _, _ :: _, [] ->
                 "ordered_blocks_joined_by_two_newlines_without_held_world_state_sections"
               | Some _, [], _ :: _ ->
                 "ordered_blocks_joined_by_two_newlines_without_held_world_state_rows"
               | Some _, _ :: _, _ :: _ ->
                 "ordered_blocks_joined_by_two_newlines_without_held_world_state_sections_and_rows")
           ; "codec_schema", `String Keeper_official_client_context_codec.schema
           ; "codec_text_path", `String "/message/content_blocks/0/text"
           ]
           @ (match omitted_sections with
              | [] -> []
              | _ :: _ ->
                [ "omitted_world_state_sections",
                  `List (List.map (fun section ->
                    `String (Keeper_context_layers.source_name section)) omitted_sections) ])
           @ (match omitted_rows with
              | [] -> []
              | _ :: _ ->
                [ "omitted_world_state_rows",
                  `List (List.map (fun (section, digests) ->
                    `Assoc [ "section", `String (Keeper_context_layers.source_name section)
                           ; "row_sha256", `List (List.map (fun digest -> `String digest) digests) ])
                    omitted_rows) ]))))
    | _ -> Unavailable Issuer_has_no_carrier
  in
  match Agent_core.Types.Extra_system_context_provenance.classify message.metadata with
  | Absent | Historical -> Not_applicable
  | Invalid | Duplicate -> Unavailable Invalid_provenance
  | Present ->
    (match message.role, message.content, assembly with
     | System, [Text _], None -> Unavailable Missing_issuer
     | System, [Text actual], Some assembly -> inspect assembly actual
     | (Agent_core.Types.System, (Agent_core.Types.Text _)::_::_, _)
     | (Agent_core.Types.System, (Agent_core.Types.Thinking _ | (Agent_core.Types.ReasoningDetails _ | (Agent_core.Types.RedactedThinking _ | (Agent_core.Types.ToolUse _ | (Agent_core.Types.ToolResult _ | (Agent_core.Types.Image _ | (Agent_core.Types.Document _ | Agent_core.Types.Audio _)))))))::_, _)
     | (Agent_core.Types.System, [], _)
     | ((Agent_core.Types.User | (Agent_core.Types.Assistant | Agent_core.Types.Tool)), _, _) -> Unavailable Unsupported_carrier)

let encoded_carrier ~assembly ~selected_blocks ?(omitted_sections = []) ?(omitted_rows = [])
    message =
  let text = Keeper_official_client_context_codec.encode message in
  let evidence = source assembly selected_blocks ~omitted_sections ~omitted_rows message in
  let occurrences = match evidence with
    | Not_applicable | Unavailable _ -> []
    | Verified proof -> [ { offset = 0; bytes = String.length text; proof } ] in
  { text; occurrences; omitted = []; acquisitions = [{ disposition = Delivered; evidence }] }

let concat ~separator pieces =
  let offset = ref 0 in
  let occurrences = List.mapi (fun i piece ->
    if i > 0 then offset := !offset + String.length separator;
    let shifted = List.map (fun occurrence -> {occurrence with offset = !offset + occurrence.offset}) piece.occurrences in
    offset := !offset + String.length piece.text; shifted) pieces |> List.concat in
  { text = String.concat separator (List.map text pieces); occurrences;
    omitted = List.concat_map (fun p -> p.omitted) pieces;
    acquisitions = List.concat_map (fun p -> p.acquisitions) pieces }

let trim piece =
  let text = String.trim piece.text in
  let rec left i = if i < String.length piece.text &&
    List.mem piece.text.[i] [' ';'\012';'\n';'\r';'\t'] then left (i + 1) else i in
  let removed = left 0 in
  let occurrences = List.filter_map (fun occurrence ->
    let offset = occurrence.offset - removed in
    if offset < 0 || offset + occurrence.bytes > String.length text then None
    else Some {occurrence with offset}) piece.occurrences in
  let acquisitions =
    if List.length occurrences = List.length piece.occurrences then piece.acquisitions
    else piece.acquisitions @ [{ disposition = Delivered; evidence = Unavailable Trimmed_occurrence }] in
  { piece with text; occurrences; acquisitions }

let omit_held ~assembly ~blocks message piece =
  let evidence = source assembly blocks ~omitted_sections:[] ~omitted_rows:[] message in
  let omitted = match evidence with
    | Verified proof -> piece.omitted @ [proof]
    | Not_applicable | Unavailable _ -> piece.omitted in
  { piece with omitted;
    acquisitions = piece.acquisitions @ [{ disposition = Omitted_held; evidence }] }

let reason_to_string = function
  | Missing_issuer -> "missing_issuer"
  | Issuer_has_no_carrier -> "issuer_has_no_carrier"
  | Stale_issuer -> "stale_issuer"
  | Invalid_subset -> "invalid_subset"
  | Unsupported_carrier -> "unsupported_carrier"
  | Invalid_provenance -> "invalid_provenance"
  | Trimmed_occurrence -> "trimmed_occurrence"

let issuer_attribution acquisitions =
  let verified, unavailable = List.fold_left (fun (verified, unavailable) acquisition ->
    match acquisition.evidence with
    | Not_applicable -> verified, unavailable
    | Verified _ -> verified + 1, unavailable
    | Unavailable reason ->
      let disposition = match acquisition.disposition with
        | Delivered -> "rendered_carrier" | Omitted_held -> "locally_omitted_held" in
      verified, (`Assoc ["reason", `String (reason_to_string reason);
        "disposition", `String disposition]) :: unavailable) (0, []) acquisitions in
  let status = match verified, unavailable with
    | 0, [] -> "not_applicable"
    | _, [] -> "verified"
    | 0, _ -> "unavailable"
    | _, _ -> "partial" in
  `Assoc ["status", `String status; "verified_carrier_count", `Int verified;
    "unavailable", `List (List.rev unavailable);
    "scope", `String "source_acquisition_and_local_filter_not_transport_or_remote_retention"]

let binding_to_json ~slot piece (write : Write.t) =
  let matched = Write.matching_fragment write ~slot piece.text in
  let status = match matched with None -> "unavailable_slot_mismatch" | Some _ -> "matched_completed_slot" in
  let matched_slot = Option.fold ~none:`Null ~some:(fun (fragment : Write.fragment) ->
    `Assoc [ "bytes", `Int fragment.bytes;
      "sha256", `String fragment.sha256;
      "offset", Option.fold ~none:`Null ~some:(fun i -> `Int i) fragment.offset]) matched in
  let occurrences = match matched with None -> [] | Some _ -> List.mapi (fun index occurrence ->
    `Assoc [ "attributed_occurrence_index", `Int index;
      "encoded_message_offset_in_decoded_slot", `Int occurrence.offset;
      "encoded_message_bytes", `Int occurrence.bytes;
      "encoded_message_sha256", `String (hash (String.sub piece.text occurrence.offset occurrence.bytes));
      "source",occurrence.proof]) piece.occurrences in
  `Assoc ([ "schema", `String "masc.client-assembly-slot-binding.v1";
      "status", `String status;
    "scope", `String "issuer_carrier_only_not_tool_history_or_remote_retention" ]
    @ Write.slot_fields slot
    @ [ "matched_slot", matched_slot;
    "expected_slot_sha256", `String (Write.encoded_text_sha256 write piece.text);
    "issuer_attribution", issuer_attribution piece.acquisitions;
    "occurrences", `List occurrences;
    "omission_scope", `String "local_resume_filter_decision_not_remote_retention";
    "omitted_held", `List (match matched with None -> [] | Some _ -> piece.omitted)])
