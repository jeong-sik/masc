type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Alive_but_stuck_recovery
  | Unknown of string

type reaction_kind =
  | Turn_started
  | Execution_receipt
  | Terminal_reason
  | Cursor_ack
  | Operator_escalation
  | Unknown_reaction of string

let schema = "keeper.reaction_ledger.v1"

let stimulus_kind_to_string = function
  | Board_signal -> "board_signal"
  | Bootstrap -> "bootstrap"
  | Alive_but_stuck_recovery -> "alive_but_stuck_recovery"
  | Unknown value -> value
;;

let reaction_kind_to_string = function
  | Turn_started -> "turn_started"
  | Execution_receipt -> "execution_receipt"
  | Terminal_reason -> "terminal_reason"
  | Cursor_ack -> "cursor_ack"
  | Operator_escalation -> "operator_escalation"
  | Unknown_reaction value -> value
;;

let option_json f = function
  | Some value -> f value
  | None -> `Null
;;

let list_json values = `List (List.map (fun value -> `String value) values)

let payload_preview payload =
  let limit = 512 in
  if String.length payload <= limit
  then payload
  else String.sub payload 0 limit ^ "...[truncated]"
;;

let digest_id prefix payload = prefix ^ ":" ^ Digest.to_hex (Digest.string payload)
let board_stimulus_id ~post_id = "board:" ^ post_id

let stimulus_kind_of_event_queue (stimulus : Keeper_event_queue.stimulus) =
  match Keeper_event_queue.classify stimulus with
  | Board_signal -> Board_signal
  | Bootstrap -> Bootstrap
  | Alive_but_stuck_recovery -> Alive_but_stuck_recovery
  | Unsupported prefix -> Unknown prefix
;;

let stimulus_id_of_event_queue (stimulus : Keeper_event_queue.stimulus) =
  match stimulus_kind_of_event_queue stimulus with
  | Board_signal -> board_stimulus_id ~post_id:stimulus.post_id
  | kind ->
    digest_id
      "stimulus"
      (String.concat
         "|"
         [ stimulus.post_id
         ; stimulus_kind_to_string kind
         ; Printf.sprintf "%.6f" stimulus.arrived_at
         ; stimulus.payload
         ])
;;

let urgency_to_string = function
  | Keeper_event_queue.Immediate -> "immediate"
  | Normal -> "normal"
  | Low -> "low"
;;

let store_dir ~masc_root ~keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat masc_root "keepers") keeper_name)
    "reaction-ledger"
;;

let store_for_base_path ~base_path ~keeper_name =
  Dated_jsonl.create
    ~base_dir:(store_dir ~masc_root:(Common.masc_dir_from_base_path ~base_path) ~keeper_name)
    ()
;;

let store_for_config config ~keeper_name =
  Dated_jsonl.create
    ~base_dir:(store_dir ~masc_root:(Coord.masc_root_dir config) ~keeper_name)
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

let stimulus_json ~keeper_name (stimulus : Keeper_event_queue.stimulus) =
  let kind = stimulus_kind_of_event_queue stimulus in
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  let recorded_at = Time_compat.now () in
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
             ; "payload_preview", `String (payload_preview stimulus.payload)
             ] )
       ])
;;

let record_event_queue_stimulus ~base_path ~keeper_name stimulus =
  Dated_jsonl.append
    (store_for_base_path ~base_path ~keeper_name)
    (stimulus_json ~keeper_name stimulus)
;;

let event_queue_reaction_json ~keeper_name ~reaction_kind stimulus =
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  let recorded_at = Time_compat.now () in
  `Assoc
    (base_fields
       ~record_kind:"reaction"
       ~event_id:
         (digest_id
            "krl"
            (String.concat
               "|"
               [ stimulus_id
               ; reaction_kind_to_string reaction_kind
               ; Printf.sprintf "%.6f" recorded_at
               ]))
       ~keeper_name
       ~recorded_at
     @ [ "stimulus_id", `String stimulus_id
       ; ( "reaction"
         , `Assoc
             [ "kind", `String (reaction_kind_to_string reaction_kind)
             ; "source", `String "keeper_event_queue"
             ; "post_id", `String stimulus.post_id
             ; "stimulus_kind", `String (stimulus_kind_to_string (stimulus_kind_of_event_queue stimulus))
             ] )
       ])
;;

let record_event_queue_reaction ~base_path ~keeper_name ~reaction_kind stimulus =
  Dated_jsonl.append
    (store_for_base_path ~base_path ~keeper_name)
    (event_queue_reaction_json ~keeper_name ~reaction_kind stimulus)
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

let receipt_reaction_kind ~terminal_reason_code =
  let trimmed = String.trim terminal_reason_code in
  if trimmed = "" || String.equal trimmed "completed"
  then Execution_receipt
  else Terminal_reason
;;

let record_execution_receipt_reaction
      config
      ~keeper_name
      ~trace_id
      ?turn_count
      ~current_task_id
      ~goal_ids
      ~outcome
      ~terminal_reason_code
      ~receipt_json
      ()
  =
  let reaction_kind = receipt_reaction_kind ~terminal_reason_code in
  let recorded_at = Time_compat.now () in
  let stimulus_id =
    match current_task_id with
    | Some task_id -> "task:" ^ task_id
    | None -> digest_id "turn" (keeper_name ^ "|" ^ trace_id)
  in
  let json =
    `Assoc
      (base_fields
         ~record_kind:"reaction"
         ~event_id:
           (digest_id
              "krl"
              (String.concat
                 "|"
                 [ stimulus_id
                 ; trace_id
                 ; reaction_kind_to_string reaction_kind
                 ; Printf.sprintf "%.6f" recorded_at
                 ]))
         ~keeper_name
         ~recorded_at
       @ [ "stimulus_id", `String stimulus_id
         ; ( "reaction"
           , `Assoc
               [ "kind", `String (reaction_kind_to_string reaction_kind)
               ; "source", `String "keeper_execution_receipt"
               ; "trace_id", `String trace_id
               ; "turn_count", option_json (fun value -> `Int value) turn_count
               ; "current_task_id", option_json (fun value -> `String value) current_task_id
               ; "goal_ids", list_json goal_ids
               ; "outcome", `String outcome
               ; "terminal_reason_code", `String terminal_reason_code
               ; "receipt", receipt_json
               ] )
         ])
  in
  Dated_jsonl.append (store_for_config config ~keeper_name) json
;;

let read_recent_for_keeper ~base_path ~keeper_name ~limit =
  Dated_jsonl.read_recent (store_for_base_path ~base_path ~keeper_name) limit
;;
