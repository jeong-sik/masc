module State = Keeper_event_queue_state
module Ledger = Keeper_reaction_ledger
module Wire = Keeper_reaction_ledger_wire

let schema = "masc.keeper.turn-source-outcomes/v1"

type selection =
  { stimulus_id : string
  ; snapshot_ref : string
  ; admitted_revision : int64
  }

let source_of_json json =
  let ( let* ) = Option.bind in
  let* stimulus_id = Wire.string_field "stimulus_id" json in
  let* snapshot_ref = Wire.string_field "source_snapshot_ref" json in
  let* revision = Wire.string_field "admitted_revision" json in
  let* admitted_revision = Int64.of_string_opt revision in
  let unique_fields = match json with
    | `Assoc fields ->
      List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
    | _ -> false in
  if unique_fields && String.trim stimulus_id <> ""
     && String.length snapshot_ref = 64
     && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) snapshot_ref
     && Int64.compare admitted_revision 0L >= 0
     && String.equal (Int64.to_string admitted_revision) revision
  then Some { stimulus_id; snapshot_ref; admitted_revision }
  else None

let same_source left right =
  String.equal left.stimulus_id right.stimulus_id
  && String.equal left.snapshot_ref right.snapshot_ref
  && Int64.equal left.admitted_revision right.admitted_revision

let selections_of_yojson = function
  | `List rows ->
    let rec decode sources = function
      | [] -> Some (List.rev sources)
      | row :: rest ->
        (match source_of_json row with
         | Some source when not (List.exists (same_source source) sources) ->
           decode (source :: sources) rest
         | Some _ | None -> None)
    in
    decode [] rows
  | _ -> None

let receipt_source (receipt : State.transition_receipt) =
  let source, admitted_revision = match receipt.transition with
    | State.Cancel_accepted value -> value.source, value.source_incarnation
    | State.Transfer_accepted value -> value.source, value.source_incarnation
    | State.Ack_source_terminal value -> value.source, value.source_incarnation in
  { stimulus_id = Ledger.stimulus_id_of_event_queue source
  ; snapshot_ref = State.source_snapshot_ref source
  ; admitted_revision
  }

let receipt_kind (receipt : State.transition_receipt) =
  match receipt.transition with
  | State.Cancel_accepted _ -> "cancelled"
  | State.Transfer_accepted _ -> "transferred"
  | State.Ack_source_terminal value ->
    (match value.source_receipt with
     | State.Turn_completed -> "ack_turn_completed"
     | State.Turn_attempt_terminal _ -> "ack_turn_attempt_terminal"
     | State.Fusion_terminal _ -> "ack_fusion_terminal"
     | State.Hitl_terminal _ -> "ack_hitl_terminal")

let receipt_to_json (receipt : State.transition_receipt) =
  `Assoc
    [ "transition_id", `String receipt.transition_id
    ; "event_id", `String receipt.event_id
    ; "applied_at", `Float receipt.applied_at
    ; "kind", `String (receipt_kind receipt)
    ]

let source_to_json (source, receipts) =
  `Assoc
    [ "stimulus_id", `String source.stimulus_id
    ; "source_snapshot_ref", `String source.snapshot_ref
    ; "admitted_revision", `String (Int64.to_string source.admitted_revision)
    ; "receipts", `List (List.map receipt_to_json (List.rev !receipts))
    ]

let observe_sources ~base_path ~keeper_name sources =
  let selected = List.map (fun source -> source, ref []) sources in
  let by_id = Hashtbl.create (List.length sources) in
  List.iter (fun ((source, _) as item) ->
    let existing = Option.value ~default:[] (Hashtbl.find_opt by_id source.stimulus_id) in
    Hashtbl.replace by_id source.stimulus_id (item :: existing)) selected;
  let rows = ref 0 and invalid_json = ref 0 and invalid_ledger = ref 0 in
  let observe entry =
    incr rows;
    match entry with
    | Dated_jsonl.Malformed_json _ -> incr invalid_json
    | Dated_jsonl.Parsed json ->
      (match Wire.decode_current_row ~keeper_name json with
       | Error _ -> incr invalid_ledger
       | Ok (Wire.Current_stimulus _) -> ()
       | Ok (Wire.Current_reaction {transition_receipt=None; _}) -> ()
       | Ok (Wire.Current_reaction {metadata; transition_receipt=Some receipt; _}) ->
         (match Hashtbl.find_opt by_id metadata.stimulus_id with
          | None -> ()
          | Some candidates ->
            let actual = receipt_source receipt in
            if not (String.equal actual.stimulus_id metadata.stimulus_id)
            then incr invalid_ledger
            else
              List.iter (fun (source, receipts) ->
                if same_source source actual
                   && not (List.exists (State.transition_receipt_equal receipt) !receipts)
                then receipts := receipt :: !receipts) candidates))
  in
  let read_result = match sources with
    | [] -> Ok ()
    | _ :: _ ->
      let store = Dated_jsonl.open_store (Ledger.location ~base_path ~keeper_name) in
      Dated_jsonl.iter_all_entries_result store observe in
  let storage_error = Result.is_error read_result in
  let coverage =
    if sources = [] then "not_needed"
    else if storage_error && !rows = 0 then "unavailable"
    else if storage_error || !invalid_json > 0 || !invalid_ledger > 0 then "partial"
    else "read" in
  [ "coverage", `Assoc
      [ "state", `String coverage
      ; "rows_inspected", `Int !rows
      ; "invalid_json_rows", `Int !invalid_json
      ; "invalid_ledger_rows", `Int !invalid_ledger
      ; "storage_error", `Bool storage_error
      ]
  ; "sources", `List (List.map source_to_json selected)
  ]

let observe ~base_path ~keeper_name selections =
  let fields = observe_sources ~base_path ~keeper_name selections in
  `Assoc
    (("schema", `String schema)
     :: ("observed_at", `Float (Unix.gettimeofday ()))
     :: ("state", `String "observed") :: fields)
