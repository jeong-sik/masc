type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed  (* RFC-0266: async masc_fusion completion wake *)
  | Bg_completed  (* RFC-0290: generic background job completion wake *)
  | Schedule_due  (* Scheduled automation due wake for a specific keeper *)
  | Connector_attention
      (* RFC-connector-ambient-attention-wake: ambient connector message wake *)
  | Hitl_resolved  (* HITL resolution delivered as an ordinary Keeper wake *)
  | Failure_judgment
      (* RFC-0313 W2: deterministic turn-failure escalated for LLM judgment. *)
  | Manual_compaction
  | Goal_assigned
      (* RFC-0315 P3 W0: goal entered active_goal_ids — assignment edge wake. *)

type reaction_kind =
  | Turn_started
  | Event_queue_ack
  | Event_queue_no_compaction
  | Event_queue_requeued
  | Event_queue_escalated
  | Cursor_ack

type reaction_decode_error = Unknown_reaction_kind of string

module Event_id_set = Set.Make (String)

(* The storage namespace and row schema advance together.  A generation hard
   cut never scans or writes an older namespace, so retired data cannot remain
   on the exact-evidence hot path or become a second authority. *)
let storage_generation = "v4"
let schema = "keeper.reaction_ledger." ^ storage_generation

let stimulus_kind_to_string = function
  | Board_signal -> "board_signal"
  | Bootstrap -> "bootstrap"
  | Fusion_completed -> "fusion_completed"
  | Bg_completed -> "bg_completed"
  | Schedule_due -> "schedule_due"
  | Connector_attention -> "connector_attention"
  | Hitl_resolved -> "hitl_resolved"
  | Failure_judgment -> "failure_judgment"
  | Manual_compaction -> "manual_compaction"
  | Goal_assigned -> "goal_assigned"
;;

(* stimulus_kind_to_string의 역. 닫힌 합에 없는 문자열(스키마 드리프트/손상 row)은
   [None]. 소비자([note_stimulus_kind])가 파싱된 variant를 exhaustive match하므로 새
   variant 추가 시 컴파일러가 분류 누락을 강제한다 — RFC-0266에서 [Fusion_completed]가
   문자열 화이트리스트에 누락돼 정상 wake가 unsupported로 오집계된 회귀를 차단한다. *)
let stimulus_kind_of_string = function
  | "board_signal" -> Some Board_signal
  | "bootstrap" -> Some Bootstrap
  | "fusion_completed" -> Some Fusion_completed
  | "bg_completed" -> Some Bg_completed
  | "schedule_due" -> Some Schedule_due
  | "connector_attention" -> Some Connector_attention
  | "hitl_resolved" -> Some Hitl_resolved
  | "failure_judgment" -> Some Failure_judgment
  | "manual_compaction" -> Some Manual_compaction
  | "goal_assigned" -> Some Goal_assigned
  | _ -> None
;;

let reaction_kind_to_string = function
  | Turn_started -> "turn_started"
  | Event_queue_ack -> "event_queue_ack"
  | Event_queue_no_compaction -> "event_queue_no_compaction"
  | Event_queue_requeued -> "event_queue_requeued"
  | Event_queue_escalated -> "event_queue_escalated"
  | Cursor_ack -> "cursor_ack"
;;

(* Closed inverse. Wire drift is a typed decoder failure rather than an open
   reaction value, so an unknown label can never clear a pending stimulus. *)
let reaction_kind_of_string = function
  | "turn_started" -> Ok Turn_started
  | "event_queue_ack" -> Ok Event_queue_ack
  | "event_queue_no_compaction" -> Ok Event_queue_no_compaction
  | "event_queue_requeued" -> Ok Event_queue_requeued
  | "event_queue_escalated" -> Ok Event_queue_escalated
  | "cursor_ack" -> Ok Cursor_ack
  | other -> Error (Unknown_reaction_kind other)
;;

let option_json f = function
  | Some value -> f value
  | None -> `Null
;;

let digest_id prefix payload = prefix ^ ":" ^ Digest.to_hex (Digest.string payload)
let board_stimulus_id ~post_id = "board:" ^ post_id

let stimulus_kind_of_event_queue (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Keeper_event_queue.Board_signal _ | Keeper_event_queue.Board_attention _ ->
    Board_signal
  | Keeper_event_queue.Bootstrap -> Bootstrap
  | Keeper_event_queue.Fusion_completed _ -> Fusion_completed
  | Keeper_event_queue.Bg_completed _ -> Bg_completed
  | Keeper_event_queue.Schedule_due _ -> Schedule_due
  | Keeper_event_queue.Connector_attention _ -> Connector_attention
  | Keeper_event_queue.Hitl_resolved _ -> Hitl_resolved
  | Keeper_event_queue.Failure_judgment _ -> Failure_judgment
  | Keeper_event_queue.Manual_compaction_requested -> Manual_compaction
  | Keeper_event_queue.Goal_assigned _ -> Goal_assigned
;;

let stimulus_id_of_event_queue (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload, stimulus_kind_of_event_queue stimulus with
  | Keeper_event_queue.Board_attention attention, Board_signal ->
    "board-attention:" ^ attention.candidate_id
  | Keeper_event_queue.Board_signal _, Board_signal ->
    board_stimulus_id ~post_id:stimulus.post_id
  | Keeper_event_queue.Schedule_due _, Schedule_due -> stimulus.post_id
  | _, kind ->
    digest_id
      "stimulus"
      (String.concat
         "|"
         [ stimulus.post_id
         ; stimulus_kind_to_string kind
         ; Printf.sprintf "%.6f" stimulus.arrived_at
         ])
;;

let urgency_to_string = function
  | Keeper_event_queue.Immediate -> "immediate"
  | Normal -> "normal"
  | Low -> "low"
;;

let store_dir ~masc_root ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat (Filename.concat masc_root "keepers") keeper_name)
       "reaction-ledger")
    storage_generation
;;

let store_for_base_path ~base_path ~keeper_name =
  Dated_jsonl.create
    ~base_dir:(store_dir ~masc_root:(Common.masc_dir_from_base_path ~base_path) ~keeper_name)
    ()
;;

let base_fields ~record_kind ~event_id ~keeper_name ~recorded_at =
  [ "schema", `String schema
  ; "record_kind", `String record_kind
  ; "event_id", `String event_id
  ; "keeper_name", `String keeper_name
  ; "recorded_at_unix", `Float recorded_at
  ]
;;

let stimulus_payload_preview (payload : Keeper_event_queue.stimulus_payload) =
  match payload with
  | Keeper_event_queue.Board_signal bs
  | Keeper_event_queue.Board_attention { signal = bs; _ } ->
    let limit = 256 in
    let title =
      if String.length bs.title <= limit
      then bs.title
      else String.sub bs.title 0 limit ^ "...[truncated]"
    in
    Printf.sprintf
      "board_signal kind=%s author=%s title=%s"
      (match bs.kind with
       | Keeper_event_queue.Post_created -> "post_created"
       | Keeper_event_queue.Comment_added -> "comment_added"
       | Keeper_event_queue.Reaction_changed reaction ->
         Printf.sprintf
           "reaction_changed target=%s:%s user=%s emoji=%s active=%b"
           (match reaction.target_type with
            | Keeper_event_queue.Reaction_post -> "post"
            | Keeper_event_queue.Reaction_comment -> "comment")
           reaction.target_id
           reaction.user_id
           reaction.emoji
           reaction.reacted)
      bs.author
      title
  | Keeper_event_queue.Bootstrap -> "bootstrap"
  | Keeper_event_queue.Fusion_completed fc ->
    let terminal =
      match fc.terminal with
      | Keeper_event_queue.Fusion_succeeded _ -> "succeeded"
      | Keeper_event_queue.Fusion_failed _ -> "failed"
      | Keeper_event_queue.Fusion_cancelled -> "cancelled"
    in
    Printf.sprintf "fusion_completed run_id=%s terminal=%s" fc.run_id terminal
  | Keeper_event_queue.Bg_completed c ->
    Printf.sprintf
      "bg_completed run_id=%s kind=%s"
      c.bg_run_id
      (Keeper_event_queue.bg_job_kind_to_string c.bg_kind)
  | Keeper_event_queue.Schedule_due sw ->
    Printf.sprintf "schedule_due schedule_id=%s due_at=%.3f" sw.schedule_id sw.due_at
  | Keeper_event_queue.Connector_attention ca ->
    Printf.sprintf "connector_attention event_id=%s" ca.event_id
  | Keeper_event_queue.Hitl_resolved r ->
    Printf.sprintf
      "hitl_resolved approval=%s decision=%s"
      r.approval_id
      (Keeper_event_queue.hitl_resolution_decision_to_string r.decision)
  | Keeper_event_queue.Failure_judgment fj ->
    Printf.sprintf
      "failure_judgment runtime=%s class=%s provenance=%s"
      fj.fj_runtime_id
      (Keeper_runtime_failure_route.judgment_class_label fj.fj_judgment)
      (Keeper_runtime_failure_route.judgment_provenance_label fj.fj_provenance)
  | Keeper_event_queue.Manual_compaction_requested -> "manual_compaction_requested"
  | Keeper_event_queue.Goal_assigned ga ->
    Printf.sprintf
      "goal_assigned goal_id=%s assigned_by=%s"
      ga.ga_goal_id
      ga.ga_assigned_by
;;

let stimulus_json ~keeper_name (stimulus : Keeper_event_queue.stimulus) =
  let kind = stimulus_kind_of_event_queue stimulus in
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  let recorded_at = Time_compat.now () in
  let board_updated_at =
    match stimulus.payload with
    | Keeper_event_queue.Board_signal bs
    | Keeper_event_queue.Board_attention { signal = bs; _ } -> bs.updated_at
    | Keeper_event_queue.Bootstrap
    | Keeper_event_queue.Fusion_completed _
    | Keeper_event_queue.Bg_completed _
    | Keeper_event_queue.Schedule_due _
    | Keeper_event_queue.Connector_attention _
    | Keeper_event_queue.Hitl_resolved _
    | Keeper_event_queue.Failure_judgment _
    | Keeper_event_queue.Manual_compaction_requested
    | Keeper_event_queue.Goal_assigned _ -> None
  in
  `Assoc
    (base_fields
       ~record_kind:"stimulus"
       ~event_id:(digest_id "krl" (stimulus_id ^ "|stimulus"))
       ~keeper_name
       ~recorded_at
     @ [ "stimulus_id", `String stimulus_id
       ; ( "stimulus"
         , `Assoc
             [ "kind", `String (stimulus_kind_to_string kind)
             ; "source", `String "keeper_event_queue"
             ; "post_id", `String stimulus.post_id
             ; "urgency", `String (urgency_to_string stimulus.urgency)
             ; "arrived_at_unix", `Float stimulus.arrived_at
             ; "board_updated_at_unix", option_json (fun value -> `Float value) board_updated_at
             ; "payload_preview", `String (stimulus_payload_preview stimulus.payload)
             ] )
       ])
;;

let record_event_queue_stimulus ~base_path ~keeper_name stimulus =
  Dated_jsonl.append
    (store_for_base_path ~base_path ~keeper_name)
    (stimulus_json ~keeper_name stimulus)
;;

let event_queue_turn_started_json ~keeper_name stimulus =
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  let recorded_at = Time_compat.now () in
  `Assoc
    (base_fields
       ~record_kind:"reaction"
       ~event_id:(stimulus_id ^ ":reaction:turn_started")
       ~keeper_name
       ~recorded_at
     @ [ "stimulus_id", `String stimulus_id
       ; ( "reaction"
         , `Assoc
             [ "kind", `String (reaction_kind_to_string Turn_started)
             ; "source", `String "keeper_event_queue"
             ; "post_id", `String stimulus.post_id
             ; "stimulus_kind", `String (stimulus_kind_to_string (stimulus_kind_of_event_queue stimulus))
             ] )
       ])
;;

let record_event_queue_turn_started ~base_path ~keeper_name stimulus =
  Dated_jsonl.append
    (store_for_base_path ~base_path ~keeper_name)
    (event_queue_turn_started_json ~keeper_name stimulus)
;;

let reaction_kind_of_settlement = function
  | Keeper_event_queue_state.Ack -> Event_queue_ack
  | Keeper_event_queue_state.No_compaction _ -> Event_queue_no_compaction
  | Keeper_event_queue_state.Requeue _ -> Event_queue_requeued
  | Keeper_event_queue_state.Escalate _ -> Event_queue_escalated
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

let transition_source_of_stimulus stimulus =
  { stimulus_id = stimulus_id_of_event_queue stimulus
  ; post_id = stimulus.Keeper_event_queue.post_id
  ; stimulus_kind = stimulus_kind_of_event_queue stimulus
  }
;;

let transition_source_json source =
  `Assoc
    [ "stimulus_id", `String source.stimulus_id
    ; "post_id", `String source.post_id
    ; "stimulus_kind", `String (stimulus_kind_to_string source.stimulus_kind)
    ]
;;

let event_queue_transition_reaction_json
      ~keeper_name
      ~source_index
      ~source_count
      ~transition_source
      (receipt : Keeper_event_queue_state.transition_receipt)
      stimulus
  =
  let reaction_kind = reaction_kind_of_settlement receipt.settlement in
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  let event_id = event_queue_transition_event_id receipt source_index in
  `Assoc
    (base_fields
       ~record_kind:"reaction"
       ~event_id
       ~keeper_name
       ~recorded_at:receipt.settled_at
     @ [ "stimulus_id", `String stimulus_id
       ; ( "reaction"
         , `Assoc
             [ "kind", `String (reaction_kind_to_string reaction_kind)
             ; "source", `String "keeper_event_queue_settlement"
             ; "post_id", `String stimulus.post_id
             ; ( "stimulus_kind"
               , `String
                   (stimulus_kind_to_string (stimulus_kind_of_event_queue stimulus)) )
             ; "source_index", `Int source_index
             ; "source_count", `Int source_count
             ; "transition_source", transition_source_json transition_source
             ; "transition_id", `String receipt.transition_id
             ; ( "transition_receipt"
               , Keeper_event_queue_state.transition_receipt_to_yojson receipt )
             ] )
       ])
;;

let append_event_queue_transition_outbox_result
      ~base_path
      ~keeper_name
      (entry : Keeper_event_queue_state.outbox_entry)
  =
  match entry.stimuli with
  | [] ->
    Error
      (Printf.sprintf
         "event queue settlement outbox has no sources keeper=%s transition_id=%s"
         keeper_name
         entry.receipt.transition_id)
  | stimuli ->
    let store = store_for_base_path ~base_path ~keeper_name in
    let source_count = List.length stimuli in
    let rec append_sources source_index = function
      | [] -> Ok ()
      | stimulus :: rest ->
        let event_id = event_queue_transition_event_id entry.receipt source_index in
        (try
           Dated_jsonl.append
             store
             (event_queue_transition_reaction_json
                ~keeper_name
                ~source_index
                ~source_count
                ~transition_source:(transition_source_of_stimulus stimulus)
                entry.receipt
                stimulus);
           append_sources (source_index + 1) rest
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Error
             (Printf.sprintf
                "event queue settlement ledger append failed keeper=%s event_id=%s: %s"
                keeper_name
                event_id
                (Printexc.to_string exn)))
    in
    append_sources 0 stimuli
;;

let project_event_queue_transition_outbox_result ~base_path ~keeper_name =
  let ( let* ) = Result.bind in
  let* outbox =
    Keeper_event_queue_persistence.transition_outbox_result
      ~base_path
      ~keeper_name
  in
  match outbox with
  | [] -> Ok ()
  | [ entry ] ->
    let* () =
      append_event_queue_transition_outbox_result
        ~base_path
        ~keeper_name
        entry
    in
    Keeper_event_queue_persistence.mark_transition_projected_result
      ~base_path
      ~keeper_name
      ~transition_id:entry.receipt.transition_id
  | entries ->
    Error
      (Printf.sprintf
         "event queue transition outbox cardinality invalid keeper=%s count=%d"
         keeper_name
         (List.length entries))
;;

let cursor_json { cursor_ts; post_id } =
  `Assoc
    [ "scope", `String "board"
    ; "cursor_ts", `Float cursor_ts
    ; "post_id", option_json (fun value -> `String value) post_id
    ]
;;

let record_board_cursor_ack
      ~base_path
      ~keeper_name
      ?stimulus_id
      ~cursor_ts
      ~post_id
      ()
  =
  let cursor = { cursor_ts; post_id } in
  let stimulus_id =
    match stimulus_id, post_id with
    | Some value, _ -> value
    | None, Some post_id -> board_stimulus_id ~post_id
    | None, None -> digest_id "cursor" (Printf.sprintf "%.6f" cursor_ts)
  in
  let recorded_at = Time_compat.now () in
  let json =
    `Assoc
      (base_fields
         ~record_kind:"cursor_ack"
         ~event_id:
           (digest_id
              "krl"
              (String.concat
                 "|"
                 [ stimulus_id; "cursor_ack"; Printf.sprintf "%.6f" cursor_ts ]))
         ~keeper_name
         ~recorded_at
       @ [ "stimulus_id", `String stimulus_id
         ; "cursor", cursor_json cursor
         ; ( "reaction"
           , `Assoc
               [ "kind", `String (reaction_kind_to_string Cursor_ack)
               ; "source", `String "keeper_world_observation.board_cursor"
               ; "cursor_acked", `Bool true
               ] )
         ])
  in
  Dated_jsonl.append (store_for_base_path ~base_path ~keeper_name) json
;;

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
  | Transition_settlement_mismatch
  | Missing_cursor
  | Missing_cursor_ts
  | Non_finite_cursor_ts
  | Non_finite_board_updated_at
  | Invalid_cursor_reaction

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
  | Transition_settlement_mismatch -> "transition_settlement_mismatch"
  | Missing_cursor -> "missing_cursor"
  | Missing_cursor_ts -> "missing_cursor_ts"
  | Non_finite_cursor_ts -> "non_finite_cursor_ts"
  | Non_finite_board_updated_at -> "non_finite_board_updated_at"
  | Invalid_cursor_reaction -> "invalid_cursor_reaction"
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
  | Current_cursor_ack of
      { metadata : current_row_metadata
      ; cursor_token : float * string option
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

let reaction_kind_matches_settlement reaction_kind settlement =
  match reaction_kind, settlement with
  | Event_queue_ack, Keeper_event_queue_state.Ack -> true
  | Event_queue_no_compaction, Keeper_event_queue_state.No_compaction _ -> true
  | Event_queue_requeued, Keeper_event_queue_state.Requeue _ -> true
  | Event_queue_escalated, Keeper_event_queue_state.Escalate _ -> true
  | Turn_started, _
  | Cursor_ack, _
  | Event_queue_ack,
    ( Keeper_event_queue_state.No_compaction _
    | Keeper_event_queue_state.Requeue _
    | Keeper_event_queue_state.Escalate _ )
  | Event_queue_no_compaction,
    ( Keeper_event_queue_state.Ack
    | Keeper_event_queue_state.Requeue _
    | Keeper_event_queue_state.Escalate _ )
  | Event_queue_requeued,
    ( Keeper_event_queue_state.Ack
    | Keeper_event_queue_state.No_compaction _
    | Keeper_event_queue_state.Escalate _ )
  | Event_queue_escalated,
    ( Keeper_event_queue_state.Ack
    | Keeper_event_queue_state.No_compaction _
    | Keeper_event_queue_state.Requeue _ ) -> false
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
  else if reaction_kind_matches_settlement reaction_kind receipt.settlement
  then Ok receipt
  else Error Transition_settlement_mismatch
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
  | Turn_started, "keeper_event_queue" ->
    let expected_event_id = metadata.stimulus_id ^ ":reaction:turn_started" in
    if String.equal event_id expected_event_id
    then Ok (Current_reaction { metadata; reaction_kind; transition_receipt = None })
    else Error Event_identity_mismatch
  | ( Event_queue_ack | Event_queue_no_compaction | Event_queue_requeued
    | Event_queue_escalated ),
    "keeper_event_queue_settlement" ->
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
  | Cursor_ack, "keeper_world_observation.board_cursor" ->
    Error Reaction_source_mismatch
  | Turn_started, "keeper_event_queue_settlement"
  | ( Event_queue_ack | Event_queue_no_compaction | Event_queue_requeued
    | Event_queue_escalated ),
    "keeper_event_queue"
  | Cursor_ack, ("keeper_event_queue" | "keeper_event_queue_settlement") ->
    Error Reaction_source_mismatch
  | ( Turn_started | Event_queue_ack | Event_queue_no_compaction
    | Event_queue_requeued | Event_queue_escalated | Cursor_ack ),
    _ -> Error Unknown_reaction_source
;;

let decode_cursor_ack_row metadata row =
  let ( let* ) = Result.bind in
  let* cursor =
    match assoc_field "cursor" row with
    | Some value -> Ok value
    | None -> Error Missing_cursor
  in
  let* cursor_ts =
    require_finite_float
      ~missing:Missing_cursor_ts
      ~non_finite:Non_finite_cursor_ts
      "cursor_ts"
      cursor
  in
  let post_id = string_field "post_id" cursor in
  let* reaction =
    match assoc_field "reaction" row with
    | Some value -> Ok value
    | None -> Error Invalid_cursor_reaction
  in
  let valid_reaction =
    match string_field "kind" reaction, string_field "source" reaction with
    | Some "cursor_ack", Some "keeper_world_observation.board_cursor" -> true
    | _ -> false
  in
  let expected_event_id =
    digest_id
      "krl"
      (String.concat
         "|"
         [ metadata.stimulus_id; "cursor_ack"; Printf.sprintf "%.6f" cursor_ts ])
  in
  if not valid_reaction
  then Error Invalid_cursor_reaction
  else if String.equal metadata.event_id expected_event_id
  then Ok (Current_cursor_ack { metadata; cursor_token = cursor_ts, post_id })
  else Error Event_identity_mismatch
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
      | ( Bootstrap | Fusion_completed | Bg_completed | Schedule_due
        | Connector_attention | Hitl_resolved | Failure_judgment
        | Manual_compaction | Goal_assigned ),
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
  | "cursor_ack" -> decode_cursor_ack_row metadata row
  | _ -> Error Unknown_record_kind
;;

type event_queue_reaction_evidence =
  { keeper_name : string
  ; stimulus_id : string
  ; stimulus_seen : bool
  ; turn_started_seen : bool
  ; event_queue_ack_seen : bool
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; latest_recorded_at : float option
  ; matched_record_count : int
  ; quarantined_record_count : int
  }

type event_queue_reaction_evidence_outcome =
  | Evidence_complete of event_queue_reaction_evidence
  | Evidence_quarantined of
      { evidence : event_queue_reaction_evidence
      ; first_reason : row_quarantine_reason
      }

type event_queue_reaction_evidence_error =
  | Evidence_invalid_stimulus_id
  | Evidence_read_error of Dated_jsonl.read_error

let event_queue_reaction_evidence_error_to_string = function
  | Evidence_invalid_stimulus_id ->
    "reaction ledger evidence stimulus_id must be non-empty"
  | Evidence_read_error error -> Dated_jsonl.read_error_to_string error
;;

let max_recorded_at current candidate =
  match current, candidate with
  | None, None -> None
  | Some value, None | None, Some value -> Some value
  | Some left, Some right -> Some (Float.max left right)
;;

let event_queue_reaction_evidence_result ~base_path ~keeper_name ~stimulus_id =
  if String.equal stimulus_id ""
  then Error Evidence_invalid_stimulus_id
  else begin
  let stimulus_seen = ref false in
  let turn_started_seen = ref false in
  let event_queue_ack_seen = ref false in
  let stimulus_recorded_at = ref None in
  let turn_started_recorded_at = ref None in
  let event_queue_ack_recorded_at = ref None in
  let latest_recorded_at = ref None in
  let matched_record_count = ref 0 in
  let quarantined_record_count = ref 0 in
  let first_matching_quarantine_reason = ref None in
  let seen_event_ids = ref Event_id_set.empty in
  let remember_first slot value =
    match !slot with
    | Some _ -> ()
    | None -> slot := Some value
  in
  let note_matching_row row =
    let is_replay =
      match string_field "event_id" row with
      | Some event_id
        when not (String.equal event_id "")
             && Event_id_set.mem event_id !seen_event_ids -> true
      | Some event_id when not (String.equal event_id "") ->
        seen_event_ids := Event_id_set.add event_id !seen_event_ids;
        false
      | Some _ | None -> false
    in
    if not is_replay
    then
      match decode_current_row ~keeper_name row with
      | Error reason ->
        incr quarantined_record_count;
        remember_first first_matching_quarantine_reason reason
      | Ok current_row ->
        incr matched_record_count;
        let metadata =
          match current_row with
          | Current_stimulus { metadata; _ }
          | Current_reaction { metadata; _ }
          | Current_cursor_ack { metadata; _ } -> metadata
        in
        let recorded_at = Some metadata.recorded_at in
        latest_recorded_at := max_recorded_at !latest_recorded_at recorded_at;
        (match current_row with
         | Current_stimulus _ ->
           stimulus_seen := true;
           stimulus_recorded_at
             := max_recorded_at !stimulus_recorded_at recorded_at
         | Current_reaction { reaction_kind = Turn_started; _ } ->
           turn_started_seen := true;
           turn_started_recorded_at
             := max_recorded_at !turn_started_recorded_at recorded_at
         | Current_reaction { reaction_kind = Event_queue_ack; _ } ->
           event_queue_ack_seen := true;
           event_queue_ack_recorded_at
             := max_recorded_at !event_queue_ack_recorded_at recorded_at
         | Current_reaction
             { reaction_kind =
                 ( Event_queue_no_compaction | Event_queue_requeued
                 | Event_queue_escalated | Cursor_ack )
             ; _
             }
         | Current_cursor_ack _ -> ())
  in
  let note_parsed_row row =
    match string_field "stimulus_id" row with
    | Some row_stimulus_id when String.equal row_stimulus_id stimulus_id ->
      note_matching_row row
    | Some _ | None -> ()
  in
  let store = store_for_base_path ~base_path ~keeper_name in
  let iteration =
    Dated_jsonl.iter_all_entries_result store (function
      | Dated_jsonl.Parsed row -> note_parsed_row row
      | Dated_jsonl.Malformed_json _ -> ())
  in
  match iteration with
  | Error error -> Error (Evidence_read_error error)
  | Ok () ->
    let evidence =
      { keeper_name
      ; stimulus_id
      ; stimulus_seen = !stimulus_seen
      ; turn_started_seen = !turn_started_seen
      ; event_queue_ack_seen = !event_queue_ack_seen
      ; stimulus_recorded_at = !stimulus_recorded_at
      ; turn_started_recorded_at = !turn_started_recorded_at
      ; event_queue_ack_recorded_at = !event_queue_ack_recorded_at
      ; latest_recorded_at = !latest_recorded_at
      ; matched_record_count = !matched_record_count
      ; quarantined_record_count = !quarantined_record_count
      }
    in
    (match !first_matching_quarantine_reason with
     | Some first_reason ->
       Ok (Evidence_quarantined { evidence; first_reason })
     | None -> Ok (Evidence_complete evidence))
  end
;;

let nested_string_field outer inner json =
  match assoc_field outer json with
  | Some nested -> string_field inner nested
  | None -> None
;;

let nested_float_field outer inner json =
  match assoc_field outer json with
  | Some nested -> float_field inner nested
  | None -> None
;;

let summary_schema = "keeper.reaction_ledger.summary.v2"
let fleet_summary_schema = "keeper.reaction_ledger.fleet_summary.v2"

let cap_list limit values =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop limit [] values
;;

let increment_count tbl key =
  let current =
    match Hashtbl.find_opt tbl key with
    | Some value -> value
    | None -> 0
  in
  Hashtbl.replace tbl key (current + 1)
;;

let string_count_table_json ~field tbl =
  Hashtbl.fold (fun name count acc -> (name, count) :: acc) tbl []
  |> List.sort (fun (left_name, left_count) (right_name, right_count) ->
    let count_cmp = Int.compare right_count left_count in
    if count_cmp <> 0 then count_cmp else String.compare left_name right_name)
  |> List.map (fun (name, count) ->
    `Assoc [ field, `String name; "count", `Int count ])
  |> fun values -> `List values
;;

type durable_event_queue_health =
  { keeper_name : string
  ; durable_event_queue_count : int
  ; durable_event_queue_pending_count : int
  ; durable_event_queue_inflight_count : int
  ; immediate_count : int
  ; oldest_arrived_at : float option
  ; newest_arrived_at : float option
  ; payload_kind_counts : (string * int) list
  ; read_errors : Keeper_event_queue_persistence.snapshot_read_error list
  }

let durable_event_queue_is_stale ~now ~stale_after_sec health =
  health.durable_event_queue_count > 0
  &&
  match health.oldest_arrived_at with
  | None -> false
  | Some arrived_at -> now -. arrived_at >= stale_after_sec
;;

let payload_kind_count_pairs stimuli =
  let tbl = Hashtbl.create 8 in
  List.iter
    (fun (stimulus : Keeper_event_queue.stimulus) ->
      increment_count tbl (Keeper_event_queue.payload_kind_label stimulus.payload))
    stimuli;
  Hashtbl.fold (fun name count acc -> (name, count) :: acc) tbl []
  |> List.sort (fun (left_name, left_count) (right_name, right_count) ->
    let count_cmp = Int.compare right_count left_count in
    if count_cmp <> 0 then count_cmp else String.compare left_name right_name)
;;

let durable_event_queue_health ~base_path ~keeper_name =
  let snapshot =
    Keeper_event_queue_persistence.load_snapshot_pair_with_errors ~base_path ~keeper_name
  in
  let queue =
    Keeper_event_queue.prepend_list
      (Keeper_event_queue.to_list snapshot.inflight)
      snapshot.pending
    |> Keeper_event_queue.dedup_by_identity
  in
  let stimuli = Keeper_event_queue.to_list queue in
  let oldest_arrived_at, newest_arrived_at =
    List.fold_left
      (fun (oldest, newest) (stimulus : Keeper_event_queue.stimulus) ->
        let arrived_at = stimulus.arrived_at in
        ( (match oldest with
           | None -> Some arrived_at
           | Some value -> Some (Float.min value arrived_at))
        , match newest with
          | None -> Some arrived_at
          | Some value -> Some (Float.max value arrived_at) ))
      (None, None)
      stimuli
  in
  let immediate_count =
    List.fold_left
      (fun acc (stimulus : Keeper_event_queue.stimulus) ->
        match stimulus.urgency with
        | Keeper_event_queue.Immediate -> acc + 1
        | Normal | Low -> acc)
      0
      stimuli
  in
  { keeper_name
  ; durable_event_queue_count = Keeper_event_queue.length queue
  ; durable_event_queue_pending_count = Keeper_event_queue.length snapshot.pending
  ; durable_event_queue_inflight_count = Keeper_event_queue.length snapshot.inflight
  ; immediate_count
  ; oldest_arrived_at
  ; newest_arrived_at
  ; payload_kind_counts = payload_kind_count_pairs stimuli
  ; read_errors = snapshot.read_errors
  }
;;

let durable_event_queue_health_json ~now ~stale_after_sec health =
  let float_opt_to_json = function
    | None -> `Null
    | Some value -> `Float value
  in
  let age_opt_to_json = function
    | None -> `Null
    | Some value -> `Int (int_of_float (max 0.0 (now -. value)))
  in
  let stale = durable_event_queue_is_stale ~now ~stale_after_sec health in
  let read_errors_json =
    List.map
      (fun (error : Keeper_event_queue_persistence.snapshot_read_error) ->
        `Assoc
          [ ( "kind"
            , `String
                (Keeper_event_queue_persistence.snapshot_read_error_kind_to_string
                   error.kind) )
          ; ( "path"
            , match error.path with
              | Some path -> `String path
              | None -> `Null )
          ; "message", `String error.message
          ])
      health.read_errors
  in
  `Assoc
    [ "keeper_name", `String health.keeper_name
    ; "durable_event_queue_count", `Int health.durable_event_queue_count
    ; ( "durable_event_queue_pending_count"
      , `Int health.durable_event_queue_pending_count )
    ; ( "durable_event_queue_inflight_count"
      , `Int health.durable_event_queue_inflight_count )
    ; "immediate_count", `Int health.immediate_count
    ; "oldest_arrived_at_unix", float_opt_to_json health.oldest_arrived_at
    ; "oldest_age_sec", age_opt_to_json health.oldest_arrived_at
    ; "newest_arrived_at_unix", float_opt_to_json health.newest_arrived_at
    ; "newest_age_sec", age_opt_to_json health.newest_arrived_at
    ; "stale_after_sec", `Float stale_after_sec
    ; "stale", `Bool stale
    ; "read_error_count", `Int (List.length health.read_errors)
    ; "read_errors", `List read_errors_json
    ; ( "payload_kind_counts"
      , `List
          (List.map
             (fun (payload_kind, count) ->
               `Assoc [ "payload_kind", `String payload_kind; "count", `Int count ])
             health.payload_kind_counts) )
    ]
;;

let compare_board_cursor_token (ts_a, post_id_a) (ts_b, post_id_b) =
  let cmp = Float.compare ts_a ts_b in
  if cmp <> 0 then cmp else Option.compare String.compare post_id_a post_id_b
;;

let board_stimulus_token metadata stimulus_kind =
  match stimulus_kind with
  | Board_signal ->
    let updated_at =
      nested_float_field "stimulus" "board_updated_at_unix" metadata.raw
    in
    let post_id = nested_string_field "stimulus" "post_id" metadata.raw in
    Option.map (fun timestamp -> timestamp, post_id) updated_at
  | Bootstrap | Fusion_completed | Bg_completed | Schedule_due
  | Connector_attention | Hitl_resolved | Failure_judgment
  | Manual_compaction | Goal_assigned -> None
;;

let summarize_rows ~keeper_name ~limit rows =
  let scanned_row_count = List.length rows in
  let current_event_ids = ref Event_id_set.empty in
  let row_count = ref 0 in
  let stimulus_count = ref 0 in
  let reaction_count = ref 0 in
  let turn_started_count = ref 0 in
  let event_queue_ack_count = ref 0 in
  let event_queue_no_compaction_count = ref 0 in
  let event_queue_requeue_count = ref 0 in
  let event_queue_escalation_count = ref 0 in
  let event_queue_external_input_count = ref 0 in
  let cursor_ack_count = ref 0 in
  let quarantined_row_count = ref 0 in
  let quarantine_reason_counts = Hashtbl.create 8 in
  let latest_recorded_at = ref None in
  let latest_stimulus_id = ref None in
  let stimulus_seen = Hashtbl.create 16 in
  let board_stimulus_tokens = Hashtbl.create 16 in
  let stimulus_order = ref [] in
  let latest_board_cursor = ref None in
  let cursor_swept_stimulus_count = ref 0 in
  let note_quarantine reason =
    incr quarantined_row_count;
    increment_count quarantine_reason_counts (row_quarantine_reason_to_string reason)
  in
  let remember_stimulus stimulus_id =
    if not (Hashtbl.mem stimulus_seen stimulus_id) then begin
      Hashtbl.add stimulus_seen stimulus_id false;
      stimulus_order := stimulus_id :: !stimulus_order
    end
  in
  let mark_reacted stimulus_id =
    match Hashtbl.find_opt stimulus_seen stimulus_id with
    | Some _ -> Hashtbl.replace stimulus_seen stimulus_id true
    | None -> ()
  in
  let mark_cursor_swept stimulus_id =
    match Hashtbl.find_opt stimulus_seen stimulus_id with
    | Some false ->
      Hashtbl.replace stimulus_seen stimulus_id true;
      incr cursor_swept_stimulus_count
    | Some true | None -> ()
  in
  let mark_board_cursor_swept cursor_token =
    Hashtbl.iter
      (fun stimulus_id stimulus_token ->
        if compare_board_cursor_token stimulus_token cursor_token <= 0
        then mark_cursor_swept stimulus_id)
      board_stimulus_tokens
  in
  let note_board_cursor cursor_token =
    (match !latest_board_cursor with
     | Some latest when compare_board_cursor_token latest cursor_token >= 0 -> ()
     | _ -> latest_board_cursor := Some cursor_token);
    mark_board_cursor_swept cursor_token
  in
  let remember_board_stimulus metadata stimulus_kind =
    match board_stimulus_token metadata stimulus_kind with
    | Some stimulus_token ->
      Hashtbl.replace board_stimulus_tokens metadata.stimulus_id stimulus_token;
      (match !latest_board_cursor with
       | Some cursor_token
         when compare_board_cursor_token stimulus_token cursor_token <= 0 ->
         mark_cursor_swept metadata.stimulus_id
       | _ -> ())
    | None -> ()
  in
  let note_reaction_kind reaction_kind transition_receipt =
    match reaction_kind, transition_receipt with
    | Turn_started, None -> incr turn_started_count
    | Event_queue_ack, Some _ -> incr event_queue_ack_count
    | Event_queue_no_compaction, Some _ -> incr event_queue_no_compaction_count
    | Event_queue_requeued, Some _ -> incr event_queue_requeue_count
    | Event_queue_escalated, Some receipt ->
      incr event_queue_escalation_count;
      (match receipt.Keeper_event_queue_state.settlement with
       | Keeper_event_queue_state.Escalate { reason; _ } ->
         if Keeper_event_queue_state.escalation_reason_requests_external_input reason
         then incr event_queue_external_input_count
       | Keeper_event_queue_state.Ack
       | Keeper_event_queue_state.No_compaction _
       | Keeper_event_queue_state.Requeue _ -> ())
    | Cursor_ack, None -> incr cursor_ack_count
    | Turn_started, Some _
    | ( Event_queue_ack | Event_queue_no_compaction | Event_queue_requeued
      | Event_queue_escalated ), None
    | Cursor_ack, Some _ -> ()
  in
  let note_current_row current_row =
    let metadata =
      match current_row with
      | Current_stimulus { metadata; _ }
      | Current_reaction { metadata; _ }
      | Current_cursor_ack { metadata; _ } -> metadata
    in
    if Event_id_set.mem metadata.event_id !current_event_ids
    then ()
    else begin
      current_event_ids := Event_id_set.add metadata.event_id !current_event_ids;
      incr row_count;
      latest_recorded_at := Some metadata.recorded_at;
      latest_stimulus_id := Some metadata.stimulus_id;
      match current_row with
      | Current_stimulus { metadata; stimulus_kind } ->
        incr stimulus_count;
        remember_stimulus metadata.stimulus_id;
        remember_board_stimulus metadata stimulus_kind
      | Current_reaction { metadata; reaction_kind; transition_receipt } ->
        incr reaction_count;
        note_reaction_kind reaction_kind transition_receipt;
        mark_reacted metadata.stimulus_id
      | Current_cursor_ack { cursor_token; _ } ->
        incr reaction_count;
        incr cursor_ack_count;
        note_board_cursor cursor_token
    end
  in
  List.iter
    (function
      | Dated_jsonl.Malformed_json _ -> note_quarantine Malformed_json_row
      | Dated_jsonl.Parsed row ->
        (match decode_current_row ~keeper_name row with
         | Error reason -> note_quarantine reason
         | Ok current_row -> note_current_row current_row))
    rows;
  let pending_stimulus_ids =
    !stimulus_order
    |> List.rev
    |> List.filter (fun id ->
      match Hashtbl.find_opt stimulus_seen id with
      | Some false -> true
      | Some true | None -> false)
  in
  let pending_stimulus_count = List.length pending_stimulus_ids in
  let degraded_signal_count = pending_stimulus_count + !quarantined_row_count in
  let status =
    if !row_count = 0 && !quarantined_row_count = 0 then "empty"
    else if degraded_signal_count = 0 then "ok"
    else "degraded"
  in
  `Assoc
    [ "schema", `String summary_schema
    ; "keeper_name", `String keeper_name
    ; "status", `String status
    ; "operator_action_required", `Bool (degraded_signal_count > 0)
    ; "scanned_row_limit", `Int limit
    ; "scanned_row_count", `Int scanned_row_count
    ; "row_count", `Int !row_count
    ; "stimulus_count", `Int !stimulus_count
    ; "reaction_count", `Int !reaction_count
    ; "turn_started_count", `Int !turn_started_count
    ; "event_queue_ack_count", `Int !event_queue_ack_count
    ; "event_queue_no_compaction_count", `Int !event_queue_no_compaction_count
    ; "event_queue_requeue_count", `Int !event_queue_requeue_count
    ; "event_queue_escalation_count", `Int !event_queue_escalation_count
    ; "event_queue_external_input_count", `Int !event_queue_external_input_count
    ; "cursor_ack_count", `Int !cursor_ack_count
    ; "quarantined_row_count", `Int !quarantined_row_count
    ; ( "quarantine_reason_counts"
      , string_count_table_json ~field:"reason" quarantine_reason_counts )
    ; "cursor_swept_stimulus_count", `Int !cursor_swept_stimulus_count
    ; "pending_stimulus_count", `Int pending_stimulus_count
    ; ( "pending_stimulus_ids"
      , `List
          (List.map
             (fun value -> `String value)
             (cap_list 8 pending_stimulus_ids)) )
    ; "latest_recorded_at_unix", Json_util.float_opt_to_json !latest_recorded_at
    ; "latest_stimulus_id", Json_util.string_opt_to_json !latest_stimulus_id
    ; "read_error", `Null
    ]
;;

let error_summary ~keeper_name ~limit error =
  `Assoc
    [ "schema", `String summary_schema
    ; "keeper_name", `String keeper_name
    ; "status", `String "unknown"
    ; "operator_action_required", `Bool true
    ; "scanned_row_limit", `Int limit
    ; "scanned_row_count", `Int 0
    ; "row_count", `Int 0
    ; "stimulus_count", `Int 0
    ; "reaction_count", `Int 0
    ; "turn_started_count", `Int 0
    ; "event_queue_ack_count", `Int 0
    ; "event_queue_no_compaction_count", `Int 0
    ; "event_queue_requeue_count", `Int 0
    ; "event_queue_escalation_count", `Int 0
    ; "cursor_ack_count", `Int 0
    ; "event_queue_external_input_count", `Int 0
    ; "quarantined_row_count", `Int 0
    ; "quarantine_reason_counts", `List []
    ; "cursor_swept_stimulus_count", `Int 0
    ; "pending_stimulus_count", `Int 0
    ; "pending_stimulus_ids", `List []
    ; "latest_recorded_at_unix", `Null
    ; "latest_stimulus_id", `Null
    ; "read_error", `String error
    ]
;;

let summary_for_keeper ~base_path ~keeper_name ~limit =
  try
    match
      Dated_jsonl.read_recent_result
        (store_for_base_path ~base_path ~keeper_name)
        limit
    with
    | Ok rows -> summarize_rows ~keeper_name ~limit rows
    | Error error ->
      error_summary
        ~keeper_name
        ~limit
        (Dated_jsonl.read_error_to_string error)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> error_summary ~keeper_name ~limit (Printexc.to_string exn)
;;

let summary_status json =
  match string_field "status" json with
  | Some value -> value
  | None -> "unknown"
;;

let summary_read_error_count json =
  match assoc_field "read_error" json with
  | Some (`String _) -> 1
  | _ -> 0
;;

let unavailable_fleet_summary_json () =
  `Assoc
    [ "schema", `String fleet_summary_schema
    ; "status", `String "unavailable"
    ; "status_reasons", `List []
    ; "operator_action_required", `Bool false
    ; "keeper_count", `Int 0
    ; "keeper_names", `List []
    ; "scanned_row_limit_per_keeper", `Int 0
    ; "scanned_row_count", `Int 0
    ; "row_count", `Int 0
    ; "stimulus_count", `Int 0
    ; "reaction_count", `Int 0
    ; "turn_started_count", `Int 0
    ; "event_queue_ack_count", `Int 0
    ; "event_queue_requeue_count", `Int 0
    ; "event_queue_escalation_count", `Int 0
    ; "event_queue_external_input_count", `Int 0
    ; "cursor_ack_count", `Int 0
    ; "quarantined_row_count", `Int 0
    ; "quarantine_reason_counts", `List []
    ; "quarantined_rows_by_keeper", `List []
    ; "cursor_swept_stimulus_count", `Int 0
    ; "pending_stimulus_count", `Int 0
    ; "durable_event_queue_count", `Int 0
    ; "durable_event_queue_pending_count", `Int 0
    ; "durable_event_queue_inflight_count", `Int 0
    ; "durable_event_queue_discovered_keeper_count", `Int 0
    ; "durable_event_queue_discovered_keeper_names", `List []
    ; "durable_event_queue_discovery_error", `Null
    ; "durable_event_queue_discovery_error_count", `Int 0
    ; ( "durable_event_queue_stale_after_sec"
      , `Float (Env_config.KeeperHealth.durable_queue_stale_sec ()) )
    ; "durable_event_queue_stale_count", `Int 0
    ; "durable_event_queue_stale_keeper_count", `Int 0
    ; "durable_event_queue_read_error_count", `Int 0
    ; "durable_event_queue_read_errors_by_keeper", `List []
    ; "durable_event_queue_by_keeper", `List []
    ; "durable_event_queue_stale_by_keeper", `List []
    ; "durable_event_queue_payload_counts", `List []
    ; "pending_by_keeper", `List []
    ; "read_error_count", `Int 0
    ; "keepers", `List []
    ]
;;

let fleet_summary_json ~base_path ~keeper_names ~limit_per_keeper =
  let durable_event_queue_discovery =
    Keeper_event_queue_persistence.discover_keeper_names_with_snapshots ~base_path
  in
  let keeper_names =
    List.sort_uniq
      String.compare
      (keeper_names @ durable_event_queue_discovery.keeper_names)
  in
  (* NDT-OK: fleet summary health renders stale-age telemetry at the read
     boundary; keeper control flow never branches on this timestamp. *)
  let now = Unix.gettimeofday () in
  let summaries =
    List.map
      (fun keeper_name -> summary_for_keeper ~base_path ~keeper_name ~limit:limit_per_keeper)
      keeper_names
  in
  let durable_event_queue_summaries =
    List.map (fun keeper_name -> durable_event_queue_health ~base_path ~keeper_name) keeper_names
  in
  let durable_event_queue_stale_after_sec =
    Env_config.KeeperHealth.durable_queue_stale_sec ()
  in
  let total_int name =
    List.fold_left (fun acc summary -> acc + int_field name summary) 0 summaries
  in
  let durable_event_queue_count =
    List.fold_left
      (fun acc summary -> acc + summary.durable_event_queue_count)
      0
      durable_event_queue_summaries
  in
  let durable_event_queue_pending_count =
    List.fold_left
      (fun acc summary -> acc + summary.durable_event_queue_pending_count)
      0
      durable_event_queue_summaries
  in
  let durable_event_queue_inflight_count =
    List.fold_left
      (fun acc summary -> acc + summary.durable_event_queue_inflight_count)
      0
      durable_event_queue_summaries
  in
  let durable_event_queue_by_keeper =
    durable_event_queue_summaries
    |> List.filter (fun summary -> summary.durable_event_queue_count > 0)
    |> List.map
         (durable_event_queue_health_json
            ~now
            ~stale_after_sec:durable_event_queue_stale_after_sec)
  in
  let durable_event_queue_stale_summaries =
    List.filter
      (durable_event_queue_is_stale
         ~now
         ~stale_after_sec:durable_event_queue_stale_after_sec)
      durable_event_queue_summaries
  in
  let durable_event_queue_stale_count =
    List.fold_left
      (fun acc summary -> acc + summary.durable_event_queue_count)
      0
      durable_event_queue_stale_summaries
  in
  let durable_event_queue_stale_keeper_count =
    List.length durable_event_queue_stale_summaries
  in
  let durable_event_queue_read_error_count =
    List.fold_left
      (fun acc summary -> acc + List.length summary.read_errors)
      0
      durable_event_queue_summaries
  in
  let durable_event_queue_read_errors_by_keeper =
    durable_event_queue_summaries
    |> List.filter (fun summary -> summary.read_errors <> [])
    |> List.map
         (durable_event_queue_health_json
            ~now
            ~stale_after_sec:durable_event_queue_stale_after_sec)
  in
  let durable_event_queue_stale_by_keeper =
    durable_event_queue_stale_summaries
    |> List.map
         (durable_event_queue_health_json
            ~now
            ~stale_after_sec:durable_event_queue_stale_after_sec)
  in
  let durable_event_queue_payload_counts =
    let tbl = Hashtbl.create 8 in
    List.iter
      (fun summary ->
        List.iter
          (fun (payload_kind, count) ->
            let current =
              match Hashtbl.find_opt tbl payload_kind with
              | Some value -> value
              | None -> 0
            in
            Hashtbl.replace tbl payload_kind (current + count))
          summary.payload_kind_counts)
      durable_event_queue_summaries;
    string_count_table_json ~field:"payload_kind" tbl
  in
  let pending_by_keeper =
    List.filter_map
      (fun summary ->
        let pending_count = int_field "pending_stimulus_count" summary in
        if pending_count = 0
        then None
        else
          Some
            (`Assoc
               [ "keeper_name"
               , (match string_field "keeper_name" summary with
                  | Some value -> `String value
                  | None -> `String "unknown")
               ; "pending_stimulus_count", `Int pending_count
               ; ( "pending_stimulus_ids"
                 , match assoc_field "pending_stimulus_ids" summary with
                   | Some value -> value
                   | None -> `List [] )
               ]))
      summaries
  in
  let quarantined_rows_by_keeper =
    List.filter_map
      (fun summary ->
        let quarantined_count = int_field "quarantined_row_count" summary in
        if quarantined_count = 0
        then None
        else
          Some
            (`Assoc
               [ "keeper_name"
               , (match string_field "keeper_name" summary with
                  | Some value -> `String value
                  | None -> `String "unknown")
               ; "quarantined_row_count", `Int quarantined_count
               ; ( "quarantine_reason_counts"
                 , `List (list_field "quarantine_reason_counts" summary) )
               ]))
      summaries
  in
  let quarantine_reason_counts =
    let tbl = Hashtbl.create 8 in
    List.iter
      (fun summary ->
        List.iter
          (fun item ->
            match string_field "reason" item with
            | Some reason ->
              let count = int_field "count" item in
              (match Hashtbl.find_opt tbl reason with
               | Some prior -> Hashtbl.replace tbl reason (prior + count)
               | None -> Hashtbl.add tbl reason count)
            | None -> ())
          (list_field "quarantine_reason_counts" summary))
      summaries;
    string_count_table_json ~field:"reason" tbl
  in
  let read_error_count =
    List.fold_left
      (fun acc summary -> acc + summary_read_error_count summary)
      0
      summaries
  in
  let pending_count = total_int "pending_stimulus_count" in
  let event_queue_external_input_count =
    total_int "event_queue_external_input_count"
  in
  let quarantined_row_count = total_int "quarantined_row_count" in
  let row_count = total_int "row_count" in
  let durable_event_queue_discovery_error_count =
    match durable_event_queue_discovery.read_error with
    | Some _ -> 1
    | None -> 0
  in
  let status_reasons =
    []
    |> (fun reasons -> if read_error_count > 0 then "read_error" :: reasons else reasons)
    |> (fun reasons ->
      if durable_event_queue_discovery_error_count > 0
      then "durable_event_queue_discovery_error" :: reasons
      else reasons)
    |> (fun reasons ->
      if durable_event_queue_read_error_count > 0
      then "durable_event_queue_read_error" :: reasons
      else reasons)
    |> (fun reasons ->
      if pending_count > 0 then "reaction_ledger_pending_stimulus" :: reasons else reasons)
    |> (fun reasons ->
      if quarantined_row_count > 0
      then "reaction_ledger_quarantined_row" :: reasons
      else reasons)
    |> (fun reasons ->
      if durable_event_queue_stale_count > 0
      then "durable_event_queue_stale" :: reasons
      else reasons)
    |> List.rev
  in
  let status =
    if
      read_error_count > 0
      || durable_event_queue_discovery_error_count > 0
      || durable_event_queue_read_error_count > 0
    then "unknown"
    else if
      pending_count > 0
      || quarantined_row_count > 0
      || durable_event_queue_stale_count > 0
    then "degraded"
    else if row_count = 0 && durable_event_queue_count = 0 then "empty"
    else if List.exists (fun summary -> summary_status summary = "degraded") summaries
    then "degraded"
    else "ok"
  in
  `Assoc
    [ "schema", `String fleet_summary_schema
    ; "status", `String status
    ; "status_reasons", `List (List.map (fun value -> `String value) status_reasons)
    ; ( "operator_action_required"
      , `Bool
          (status_reasons <> []) )
    ; "keeper_count", `Int (List.length keeper_names)
    ; "keeper_names", `List (List.map (fun value -> `String value) keeper_names)
    ; "scanned_row_limit_per_keeper", `Int limit_per_keeper
    ; "scanned_row_count", `Int (total_int "scanned_row_count")
    ; "row_count", `Int row_count
    ; "stimulus_count", `Int (total_int "stimulus_count")
    ; "reaction_count", `Int (total_int "reaction_count")
    ; "turn_started_count", `Int (total_int "turn_started_count")
    ; "event_queue_ack_count", `Int (total_int "event_queue_ack_count")
    ; "event_queue_requeue_count", `Int (total_int "event_queue_requeue_count")
    ; ( "event_queue_escalation_count"
      , `Int (total_int "event_queue_escalation_count") )
    ; "event_queue_external_input_count", `Int event_queue_external_input_count
    ; "cursor_ack_count", `Int (total_int "cursor_ack_count")
    ; "quarantined_row_count", `Int quarantined_row_count
    ; "quarantine_reason_counts", quarantine_reason_counts
    ; "quarantined_rows_by_keeper", `List quarantined_rows_by_keeper
    ; "cursor_swept_stimulus_count", `Int (total_int "cursor_swept_stimulus_count")
    ; "pending_stimulus_count", `Int pending_count
    ; "durable_event_queue_count", `Int durable_event_queue_count
    ; "durable_event_queue_pending_count", `Int durable_event_queue_pending_count
    ; "durable_event_queue_inflight_count", `Int durable_event_queue_inflight_count
    ; ( "durable_event_queue_discovered_keeper_count"
      , `Int (List.length durable_event_queue_discovery.keeper_names) )
    ; ( "durable_event_queue_discovered_keeper_names"
      , `List
          (List.map
             (fun value -> `String value)
             durable_event_queue_discovery.keeper_names) )
    ; ( "durable_event_queue_discovery_error"
      , match durable_event_queue_discovery.read_error with
        | Some error -> `String error
        | None -> `Null )
    ; ( "durable_event_queue_discovery_error_count"
      , `Int durable_event_queue_discovery_error_count )
    ; "durable_event_queue_stale_after_sec", `Float durable_event_queue_stale_after_sec
    ; "durable_event_queue_stale_count", `Int durable_event_queue_stale_count
    ; ( "durable_event_queue_stale_keeper_count"
      , `Int durable_event_queue_stale_keeper_count )
    ; "durable_event_queue_read_error_count", `Int durable_event_queue_read_error_count
    ; ( "durable_event_queue_read_errors_by_keeper"
      , `List durable_event_queue_read_errors_by_keeper )
    ; "durable_event_queue_by_keeper", `List durable_event_queue_by_keeper
    ; "durable_event_queue_stale_by_keeper", `List durable_event_queue_stale_by_keeper
    ; "durable_event_queue_payload_counts", durable_event_queue_payload_counts
    ; "pending_by_keeper", `List pending_by_keeper
    ; "read_error_count", `Int read_error_count
    ; "keepers", `List summaries
    ]
;;
