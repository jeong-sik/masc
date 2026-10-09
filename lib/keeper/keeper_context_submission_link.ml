module Assembly = Keeper_context_assembly
module Wire = Runtime_codex_app_server

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

let source assembly selected_blocks (message : Agent_core.Types.message) =
  let inspect assembly actual =
    match assembly.Assembly.extra_system_context, assembly.receipt with
    | Some original, Some receipt ->
      let selected =
        match selected_blocks with
        | None when actual = original ->
          Some (List.mapi (fun i _ -> i) receipt.spans)
        | None -> None
        | Some ids ->
          (match Assembly.blocks_for_carrier assembly original with
           | None -> None
           | Some blocks ->
             let wanted = List.filter
                 (fun (id, _) -> List.exists (Prompt_block_id.equal id) ids) blocks in
             if List.map fst wanted <> ids
                || String.concat "\n\n" (List.map snd wanted) <> actual
             then None
             else
               Some (List.filter_map (fun (i, (span : Assembly.span)) ->
                 match span.kind with
                 | Block id when List.exists (Prompt_block_id.equal id) ids -> Some i
                 | _ -> None) (List.mapi (fun i span -> i, span) receipt.spans)))
      in
      (match selected with
       | None ->
         Unavailable (match selected_blocks with None -> Stale_issuer | Some _ -> Invalid_subset)
       | Some indices ->
         Verified (`Assoc
           [ "assembly", Assembly.receipt_to_json receipt
           ; "source_span_indices", `List (List.map (fun i -> `Int i) indices)
           ; "rendered_text_bytes", `Int (String.length actual)
           ; "rendered_text_sha256", `String (hash actual)
           ; "rendering", `String (match selected_blocks with
               | None -> "whole_carrier"
               | Some _ -> "ordered_blocks_joined_by_two_newlines")
           ; "codec_schema", `String Keeper_official_client_context_codec.schema
           ; "codec_text_path", `String "/message/content_blocks/0/text"
           ]))
    | _ -> Unavailable Issuer_has_no_carrier
  in
  match Agent_core.Types.Extra_system_context_provenance.classify message.metadata with
  | Absent -> Not_applicable
  | Invalid | Duplicate -> Unavailable Invalid_provenance
  | Present ->
    (match message.role, message.content, assembly with
     | System, [Text _], None -> Unavailable Missing_issuer
     | System, [Text actual], Some assembly -> inspect assembly actual
     | _ -> Unavailable Unsupported_carrier)

let encoded_carrier ~assembly ~selected_blocks message =
  let text = Keeper_official_client_context_codec.encode message in
  let evidence = source assembly selected_blocks message in
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
  let evidence = source assembly blocks message in
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

let binding_to_json ~slot piece (submission : Wire.context_submission) =
  let encoded = Yojson.Safe.to_string (`String piece.text) in
  let matched = match submission.fragments with
    | Serialization_mismatch -> None
    | Partitioned fragments -> List.find_opt (fun (f : Wire.context_fragment) ->
      f.slot = slot && f.json_bytes = String.length encoded && f.json_sha256 = hash encoded) fragments in
  let status = match matched with None -> "unavailable_slot_mismatch" | Some _ -> "matched_completed_slot" in
  let method_name = match submission.method_ with
    | Thread_start -> "thread/start" | Thread_resume -> "thread/resume"
    | Thread_inject_items -> "thread/inject_items" | Turn_start -> "turn/start" in
  let slot_name, index = match slot with
    | Developer_instructions -> "developer_instructions", `Null
    | Turn_text i -> "turn_text", `Int i
    | Injected_item i -> "injected_item", `Int i
    | Dynamic_tools -> "dynamic_tools", `Null
    | Unattributed_carrier -> "unattributed_carrier", `Null in
  let matched_slot = Option.fold ~none:`Null ~some:(fun (fragment : Wire.context_fragment) ->
    `Assoc [ "json_bytes", `Int fragment.json_bytes;
      "json_sha256", `String fragment.json_sha256;
      "json_offset", Option.fold ~none:`Null ~some:(fun i -> `Int i) fragment.json_offset]) matched in
  let occurrences = match matched with None -> [] | Some _ -> List.mapi (fun index occurrence ->
    `Assoc [ "attributed_occurrence_index", `Int index;
      "encoded_message_offset_in_decoded_slot", `Int occurrence.offset;
      "encoded_message_bytes", `Int occurrence.bytes;
      "encoded_message_sha256", `String (hash (String.sub piece.text occurrence.offset occurrence.bytes));
      "source",occurrence.proof]) piece.occurrences in
  `Assoc [ "schema", `String "masc.codex-assembly-slot-binding.v2";
      "status", `String status;
    "scope", `String "issuer_carrier_only_not_tool_history_or_remote_retention";
    "request_id", `Int submission.request_id;
    "method", `String method_name; "slot", `String slot_name; "index", index;
    "matched_slot", matched_slot;
    "expected_slot_json_sha256", `String (hash encoded);
    "issuer_attribution", issuer_attribution piece.acquisitions;
    "occurrences", `List occurrences;
    "omission_scope", `String "local_resume_filter_decision_not_remote_retention";
    "omitted_held", `List (match matched with None -> [] | Some _ -> piece.omitted)]
