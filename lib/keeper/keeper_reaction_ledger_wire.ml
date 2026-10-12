(* Canonical current reaction-ledger wire contract. This module decodes
   rows without storage, clocks, caches, or outbox effects. *)

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed  (* RFC-0266: async masc_fusion completion wake *)
  | Schedule_due  (* Scheduled automation due wake for a specific keeper *)
  | Connector_attention
      (* RFC-connector-ambient-attention-wake: ambient connector message wake *)
  | Hitl_resolved  (* HITL resolution delivered as an ordinary Keeper wake *)
  | Ask_answered  (* A human answered a question this Keeper asked *)
  | Completion_authority_rejected
  | Task_outcome  (* The approval twin of Completion_authority_rejected *)
  | Task_cancelled
  | Workspace_message
  | Delegate_completed  (* One Keeper's answer to a turn another asked it to run *)
  | Composition_completed  (* An async composition this Keeper submitted has settled *)

type reaction_kind =
  | Turn_started
  | Turn_finished
  | Event_queue_ack
  | Event_queue_cancelled

type reaction_decode_error = Unknown_reaction_kind of string

(* The storage namespace and row schema advance together. Readers inspect
   exactly this namespace, keeping exact evidence under one authority. *)
let storage_generation = "v7"
let schema = "keeper.reaction_ledger." ^ storage_generation

let stimulus_kind_to_string = function
  | Board_signal -> "board_signal"
  | Bootstrap -> "bootstrap"
  | Fusion_completed -> "fusion_completed"
  | Schedule_due -> "schedule_due"
  | Connector_attention -> "connector_attention"
  | Hitl_resolved -> "hitl_resolved"
  | Ask_answered -> "ask_answered"
  | Completion_authority_rejected -> "completion_authority_rejected"
  | Task_outcome -> "task_outcome"
  | Task_cancelled -> "task_cancelled"
  | Workspace_message -> "workspace_message"
  | Delegate_completed -> "keeper_delegate_completed"
  | Composition_completed -> "keeper_composition_completed"
;;

(* stimulus_kind_to_string의 역. 닫힌 합에 없는 문자열(스키마 드리프트/손상 row)은
   [None]. 소비자([note_stimulus_kind])가 파싱된 variant를 exhaustive match하므로 새
   variant 추가 시 컴파일러가 분류 누락을 강제한다 — RFC-0266에서 [Fusion_completed]가
   문자열 화이트리스트에 누락돼 정상 wake가 unsupported로 오집계된 회귀를 차단한다. *)
let stimulus_kind_of_string = function
  | "board_signal" -> Some Board_signal
  | "bootstrap" -> Some Bootstrap
  | "fusion_completed" -> Some Fusion_completed
  | "schedule_due" -> Some Schedule_due
  | "connector_attention" -> Some Connector_attention
  | "hitl_resolved" -> Some Hitl_resolved
  | "ask_answered" -> Some Ask_answered
  | "completion_authority_rejected" -> Some Completion_authority_rejected
  | "task_outcome" -> Some Task_outcome
  | "task_cancelled" -> Some Task_cancelled
  | "workspace_message" -> Some Workspace_message
  | "keeper_delegate_completed" -> Some Delegate_completed
  | "keeper_composition_completed" -> Some Composition_completed
  | _ -> None
;;

let reaction_kind_to_string = function
  | Turn_started -> "turn_started"
  | Turn_finished -> "turn_finished"
  | Event_queue_ack -> "event_queue_ack"
  | Event_queue_cancelled -> "event_queue_cancelled"
;;

(* Closed inverse. Wire drift is a typed decoder failure rather than an open
   reaction value, so an unknown label can never clear a pending stimulus. *)
let reaction_kind_of_string = function
  | "turn_started" -> Ok Turn_started
  | "turn_finished" -> Ok Turn_finished
  | "event_queue_ack" -> Ok Event_queue_ack
  | "event_queue_cancelled" -> Ok Event_queue_cancelled
  | other -> Error (Unknown_reaction_kind other)
;;

(* The event id is recomputed on read and compared, so a collision is a replay
   decision, not a display artefact -- two stimuli landing on one id make the
   second read as the first. Stdlib.Digest is MD5; the schedule, auth and
   cache identities in this repository already use Digestif.SHA256 (#26720).
   The digest feeds the id readers compare, so the storage generation advances
   with it: rows written under v6 stay in the v6 namespace and are not read. *)
let digest_id prefix payload =
  prefix ^ ":" ^ Digestif.SHA256.(digest_string payload |> to_hex)
;;
let event_queue_transition_event_id
      (receipt : Keeper_event_queue_state.transition_receipt)
      source_index
  =
  Printf.sprintf "%s:source:%d" receipt.event_id source_index
;;

type transition_source =
  { stimulus_id : string
  ; post_id : string
  ; stimulus_kind : stimulus_kind
  }

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let string_field name json =
  match assoc_field name json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let float_field name json =
  match assoc_field name json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let int_field name json =
  match assoc_field name json with
  | Some (`Int value) -> value
  | _ -> 0
;;

let int_field_opt name json =
  match assoc_field name json with
  | Some (`Int value) -> Some value
  | _ -> None
;;

let list_field name json =
  match assoc_field name json with
  | Some (`List values) -> values
  | _ -> []
;;

type row_quarantine_reason =
  | Malformed_json_row
  | Missing_schema
  | Unexpected_schema
  | Missing_event_id
  | Empty_event_id
  | Missing_keeper_name
  | Empty_keeper_name
  | Keeper_name_mismatch
  | Missing_recorded_at
  | Non_finite_recorded_at
  | Missing_stimulus_id
  | Empty_stimulus_id
  | Missing_record_kind
  | Unknown_record_kind
  | Missing_stimulus
  | Missing_stimulus_kind
  | Unknown_stimulus_kind
  | Missing_stimulus_source
  | Unknown_stimulus_source
  | Missing_stimulus_post_id
  | Missing_stimulus_urgency
  | Unknown_stimulus_urgency
  | Missing_stimulus_arrived_at
  | Non_finite_stimulus_arrived_at
  | Missing_reaction
  | Missing_reaction_kind
  | Quarantine_unknown_reaction_kind
  | Missing_reaction_source
  | Unknown_reaction_source
  | Reaction_source_mismatch
  | Missing_reaction_post_id
  | Missing_reaction_stimulus_kind
  | Unknown_reaction_stimulus_kind
  | Missing_transition_receipt
  | Invalid_transition_receipt
  | Missing_transition_source_index
  | Missing_transition_source_count
  | Invalid_transition_source_count
  | Missing_transition_source
  | Invalid_transition_source
  | Transition_source_index_out_of_bounds
  | Transition_source_identity_mismatch
  | Event_identity_mismatch
  | Transition_kind_mismatch
  | Non_finite_board_updated_at

let row_quarantine_reason_to_string = function
  | Malformed_json_row -> "malformed_json"
  | Missing_schema -> "missing_schema"
  | Unexpected_schema -> "unexpected_schema"
  | Missing_event_id -> "missing_event_id"
  | Empty_event_id -> "empty_event_id"
  | Missing_keeper_name -> "missing_keeper_name"
  | Empty_keeper_name -> "empty_keeper_name"
  | Keeper_name_mismatch -> "keeper_name_mismatch"
  | Missing_recorded_at -> "missing_recorded_at"
  | Non_finite_recorded_at -> "non_finite_recorded_at"
  | Missing_stimulus_id -> "missing_stimulus_id"
  | Empty_stimulus_id -> "empty_stimulus_id"
  | Missing_record_kind -> "missing_record_kind"
  | Unknown_record_kind -> "unknown_record_kind"
  | Missing_stimulus -> "missing_stimulus"
  | Missing_stimulus_kind -> "missing_stimulus_kind"
  | Unknown_stimulus_kind -> "unknown_stimulus_kind"
  | Missing_stimulus_source -> "missing_stimulus_source"
  | Unknown_stimulus_source -> "unknown_stimulus_source"
  | Missing_stimulus_post_id -> "missing_stimulus_post_id"
  | Missing_stimulus_urgency -> "missing_stimulus_urgency"
  | Unknown_stimulus_urgency -> "unknown_stimulus_urgency"
  | Missing_stimulus_arrived_at -> "missing_stimulus_arrived_at"
  | Non_finite_stimulus_arrived_at -> "non_finite_stimulus_arrived_at"
  | Missing_reaction -> "missing_reaction"
  | Missing_reaction_kind -> "missing_reaction_kind"
  | Quarantine_unknown_reaction_kind -> "unknown_reaction_kind"
  | Missing_reaction_source -> "missing_reaction_source"
  | Unknown_reaction_source -> "unknown_reaction_source"
  | Reaction_source_mismatch -> "reaction_source_mismatch"
  | Missing_reaction_post_id -> "missing_reaction_post_id"
  | Missing_reaction_stimulus_kind -> "missing_reaction_stimulus_kind"
  | Unknown_reaction_stimulus_kind -> "unknown_reaction_stimulus_kind"
  | Missing_transition_receipt -> "missing_transition_receipt"
  | Invalid_transition_receipt -> "invalid_transition_receipt"
  | Missing_transition_source_index -> "missing_transition_source_index"
  | Missing_transition_source_count -> "missing_transition_source_count"
  | Invalid_transition_source_count -> "invalid_transition_source_count"
  | Missing_transition_source -> "missing_transition_source"
  | Invalid_transition_source -> "invalid_transition_source"
  | Transition_source_index_out_of_bounds -> "transition_source_index_out_of_bounds"
  | Transition_source_identity_mismatch -> "transition_source_identity_mismatch"
  | Event_identity_mismatch -> "event_identity_mismatch"
  | Transition_kind_mismatch -> "transition_kind_mismatch"
  | Non_finite_board_updated_at -> "non_finite_board_updated_at"
;;

type current_row_metadata =
  { event_id : string
  ; stimulus_id : string
  ; recorded_at : float
  ; raw : Yojson.Safe.t
  }

type current_row =
  | Current_stimulus of
      { metadata : current_row_metadata
      ; stimulus_kind : stimulus_kind
      }
  | Current_reaction of
      { metadata : current_row_metadata
      ; reaction_kind : reaction_kind
      ; transition_receipt : Keeper_event_queue_state.transition_receipt option
      }

let require_string reason field json =
  match string_field field json with
  | Some value -> Ok value
  | None -> Error reason
;;

let require_non_empty_string ~missing ~empty field json =
  match string_field field json with
  | None -> Error missing
  | Some "" -> Error empty
  | Some value -> Ok value
;;

let require_finite_float ~missing ~non_finite field json =
  match float_field field json with
  | None -> Error missing
  | Some value when Float.is_finite value -> Ok value
  | Some _ -> Error non_finite
;;

let reaction_kind_matches_transition reaction_kind transition =
  match reaction_kind, transition with
  | Event_queue_ack, Keeper_event_queue_state.Transfer_accepted _ -> true
  | Event_queue_ack, Keeper_event_queue_state.Ack_source_terminal _ -> true
  | Event_queue_cancelled, Keeper_event_queue_state.Cancel_accepted _ -> true
  | (Turn_started | Turn_finished), _
  | Event_queue_ack, Keeper_event_queue_state.Cancel_accepted _
  | Event_queue_cancelled,
    ( Keeper_event_queue_state.Transfer_accepted _
    | Keeper_event_queue_state.Ack_source_terminal _ )
    -> false
;;

let decode_reaction_stimulus_reference reaction =
  let ( let* ) = Result.bind in
  let* post_id = require_string Missing_reaction_post_id "post_id" reaction in
  let* raw_stimulus_kind =
    require_string Missing_reaction_stimulus_kind "stimulus_kind" reaction
  in
  let* stimulus_kind =
    match stimulus_kind_of_string raw_stimulus_kind with
    | Some value -> Ok value
    | None -> Error Unknown_reaction_stimulus_kind
  in
  Ok (post_id, stimulus_kind)
;;

let decode_transition_source = function
  | `Assoc _ as json ->
    let ( let* ) = Result.bind in
    let* stimulus_id =
      require_non_empty_string
        ~missing:Invalid_transition_source
        ~empty:Invalid_transition_source
        "stimulus_id"
        json
    in
    let* post_id = require_string Invalid_transition_source "post_id" json in
    let* raw_stimulus_kind =
      require_string Invalid_transition_source "stimulus_kind" json
    in
    let* stimulus_kind =
      match stimulus_kind_of_string raw_stimulus_kind with
      | Some value -> Ok value
      | None -> Error Invalid_transition_source
    in
    Ok { stimulus_id; post_id; stimulus_kind }
  | _ -> Error Invalid_transition_source
;;

let decode_transition_reaction
      ~event_id
      ~metadata
      ~reaction_kind
      ~reaction_post_id
      ~reaction_stimulus_kind
      reaction
  =
  let ( let* ) = Result.bind in
  let* source_index =
    match int_field_opt "source_index" reaction with
    | Some value when value >= 0 -> Ok value
    | Some _ | None -> Error Missing_transition_source_index
  in
  let* source_count =
    match int_field_opt "source_count" reaction with
    | Some value when value > 0 -> Ok value
    | Some _ -> Error Invalid_transition_source_count
    | None -> Error Missing_transition_source_count
  in
  let* () =
    if source_index < source_count
    then Ok ()
    else Error Transition_source_index_out_of_bounds
  in
  let* transition_source =
    match assoc_field "transition_source" reaction with
    | None -> Error Missing_transition_source
    | Some json -> decode_transition_source json
  in
  let* () =
    if
      String.equal transition_source.stimulus_id metadata.stimulus_id
      && String.equal transition_source.post_id reaction_post_id
      && transition_source.stimulus_kind = reaction_stimulus_kind
    then Ok ()
    else Error Transition_source_identity_mismatch
  in
  let* receipt_json =
    match assoc_field "transition_receipt" reaction with
    | Some value -> Ok value
    | None -> Error Missing_transition_receipt
  in
  let* receipt =
    Keeper_event_queue_state.transition_receipt_of_yojson receipt_json
    |> Result.map_error (fun _ -> Invalid_transition_receipt)
  in
  let expected_event_id = event_queue_transition_event_id receipt source_index in
  let transition_id_matches =
    match string_field "transition_id" reaction with
    | Some transition_id -> String.equal transition_id receipt.transition_id
    | None -> false
  in
  if not (String.equal event_id expected_event_id && transition_id_matches)
  then Error Event_identity_mismatch
  else if reaction_kind_matches_transition reaction_kind receipt.transition
  then Ok receipt
  else Error Transition_kind_mismatch
;;

let decode_reaction_row ~event_id metadata reaction =
  let ( let* ) = Result.bind in
  let* raw_kind = require_string Missing_reaction_kind "kind" reaction in
  let* reaction_kind =
    reaction_kind_of_string raw_kind
    |> Result.map_error (fun (Unknown_reaction_kind _) ->
      Quarantine_unknown_reaction_kind)
  in
  let* source = require_string Missing_reaction_source "source" reaction in
  let* reaction_post_id, reaction_stimulus_kind =
    decode_reaction_stimulus_reference reaction
  in
  match reaction_kind, source with
  | (Turn_started | Turn_finished), "keeper_event_queue" ->
    let expected_event_id =
      metadata.stimulus_id ^ ":reaction:" ^ reaction_kind_to_string reaction_kind
    in
    if String.equal event_id expected_event_id
    then Ok (Current_reaction { metadata; reaction_kind; transition_receipt = None })
    else Error Event_identity_mismatch
  | (Event_queue_ack | Event_queue_cancelled),
    "keeper_event_queue_transition" ->
    let* transition_receipt =
      decode_transition_reaction
        ~event_id
        ~metadata
        ~reaction_kind
        ~reaction_post_id
        ~reaction_stimulus_kind
        reaction
    in
    Ok
      (Current_reaction
         { metadata; reaction_kind; transition_receipt = Some transition_receipt })
  | (Turn_started | Turn_finished), "keeper_event_queue_transition"
  | (Event_queue_ack | Event_queue_cancelled),
    "keeper_event_queue" -> Error Reaction_source_mismatch
  | (Turn_started | Turn_finished | Event_queue_ack | Event_queue_cancelled),
    _ -> Error Unknown_reaction_source
;;

let decode_current_row ~keeper_name row =
  let ( let* ) = Result.bind in
  let* row_schema = require_string Missing_schema "schema" row in
  let* () =
    if String.equal row_schema schema then Ok () else Error Unexpected_schema
  in
  let* event_id =
    require_non_empty_string
      ~missing:Missing_event_id
      ~empty:Empty_event_id
      "event_id"
      row
  in
  let* row_keeper_name =
    require_non_empty_string
      ~missing:Missing_keeper_name
      ~empty:Empty_keeper_name
      "keeper_name"
      row
  in
  let* () =
    if String.equal row_keeper_name keeper_name
    then Ok ()
    else Error Keeper_name_mismatch
  in
  let* recorded_at =
    require_finite_float
      ~missing:Missing_recorded_at
      ~non_finite:Non_finite_recorded_at
      "recorded_at_unix"
      row
  in
  let* stimulus_id =
    require_non_empty_string
      ~missing:Missing_stimulus_id
      ~empty:Empty_stimulus_id
      "stimulus_id"
      row
  in
  let metadata = { event_id; stimulus_id; recorded_at; raw = row } in
  let* record_kind = require_string Missing_record_kind "record_kind" row in
  match record_kind with
  | "stimulus" ->
    let* stimulus =
      match assoc_field "stimulus" row with
      | Some value -> Ok value
      | None -> Error Missing_stimulus
    in
    let* raw_kind = require_string Missing_stimulus_kind "kind" stimulus in
    let* stimulus_kind =
      match stimulus_kind_of_string raw_kind with
      | Some value -> Ok value
      | None -> Error Unknown_stimulus_kind
    in
    let* source = require_string Missing_stimulus_source "source" stimulus in
    let* () =
      if String.equal source "keeper_event_queue"
      then Ok ()
      else Error Unknown_stimulus_source
    in
    let* _post_id = require_string Missing_stimulus_post_id "post_id" stimulus in
    let* raw_urgency = require_string Missing_stimulus_urgency "urgency" stimulus in
    let* _urgency =
      Keeper_event_queue.urgency_of_string raw_urgency
      |> Result.map_error (fun _ -> Unknown_stimulus_urgency)
    in
    let* _arrived_at =
      require_finite_float
        ~missing:Missing_stimulus_arrived_at
        ~non_finite:Non_finite_stimulus_arrived_at
        "arrived_at_unix"
        stimulus
    in
    let* () =
      match stimulus_kind, float_field "board_updated_at_unix" stimulus with
      | Board_signal, Some value when not (Float.is_finite value) ->
        Error Non_finite_board_updated_at
      | Board_signal, (Some _ | None)
      | ( Bootstrap | Fusion_completed | Schedule_due
        | Connector_attention | Hitl_resolved | Ask_answered
        | Completion_authority_rejected
        | Task_outcome
        | Task_cancelled
        | Workspace_message
        | Delegate_completed
        | Composition_completed ),
        _ -> Ok ()
    in
    let expected_event_id = digest_id "krl" (stimulus_id ^ "|stimulus") in
    if String.equal event_id expected_event_id
    then Ok (Current_stimulus { metadata; stimulus_kind })
    else Error Event_identity_mismatch
  | "reaction" ->
    let* reaction =
      match assoc_field "reaction" row with
      | Some value -> Ok value
      | None -> Error Missing_reaction
    in
    decode_reaction_row ~event_id metadata reaction
  | _ -> Error Unknown_record_kind
;;
