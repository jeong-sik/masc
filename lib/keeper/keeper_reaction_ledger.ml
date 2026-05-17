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

let bool_field name json =
  match assoc_field name json with
  | Some (`Bool value) -> value
  | _ -> false
;;

let nested_string_field outer inner json =
  match assoc_field outer json with
  | Some nested -> string_field inner nested
  | None -> None
;;

let option_string_json = function
  | Some value -> `String value
  | None -> `Null
;;

let option_float_json = function
  | Some value -> `Float value
  | None -> `Null
;;

let summary_schema = "keeper.reaction_ledger.summary.v1"
let fleet_summary_schema = "keeper.reaction_ledger.fleet_summary.v1"

let cap_list limit values =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop limit [] values
;;

let summarize_rows ~keeper_name ~limit rows =
  let row_count = List.length rows in
  let stimulus_count = ref 0 in
  let reaction_count = ref 0 in
  let turn_started_count = ref 0 in
  let cursor_ack_count = ref 0 in
  let execution_receipt_count = ref 0 in
  let terminal_reason_count = ref 0 in
  let operator_escalation_count = ref 0 in
  let unknown_reaction_count = ref 0 in
  let latest_recorded_at = ref None in
  let latest_stimulus_id = ref None in
  let stimulus_seen = Hashtbl.create 16 in
  let stimulus_order = ref [] in
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
  let note_reaction_kind = function
    | Some "turn_started" -> incr turn_started_count
    | Some "cursor_ack" -> incr cursor_ack_count
    | Some "execution_receipt" -> incr execution_receipt_count
    | Some "terminal_reason" -> incr terminal_reason_count
    | Some "operator_escalation" -> incr operator_escalation_count
    | Some _ -> incr unknown_reaction_count
    | None -> incr unknown_reaction_count
  in
  List.iter
    (fun row ->
      (match float_field "recorded_at_unix" row with
       | Some value -> latest_recorded_at := Some value
       | None -> ());
      let stimulus_id = string_field "stimulus_id" row in
      latest_stimulus_id := stimulus_id;
      match string_field "record_kind" row, stimulus_id with
      | Some "stimulus", Some id ->
        incr stimulus_count;
        remember_stimulus id
      | Some "reaction", Some id ->
        incr reaction_count;
        note_reaction_kind (nested_string_field "reaction" "kind" row);
        mark_reacted id
      | Some "cursor_ack", Some id ->
        incr reaction_count;
        incr cursor_ack_count;
        mark_reacted id
      | Some "reaction", None ->
        incr reaction_count;
        note_reaction_kind (nested_string_field "reaction" "kind" row)
      | Some "cursor_ack", None ->
        incr reaction_count;
        incr cursor_ack_count
      | _ -> ())
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
  let status =
    if row_count = 0 then "empty"
    else if pending_stimulus_count = 0 then "ok"
    else "degraded"
  in
  `Assoc
    [ "schema", `String summary_schema
    ; "keeper_name", `String keeper_name
    ; "status", `String status
    ; "operator_action_required", `Bool (pending_stimulus_count > 0)
    ; "scanned_row_limit", `Int limit
    ; "row_count", `Int row_count
    ; "stimulus_count", `Int !stimulus_count
    ; "reaction_count", `Int !reaction_count
    ; "turn_started_count", `Int !turn_started_count
    ; "cursor_ack_count", `Int !cursor_ack_count
    ; "execution_receipt_count", `Int !execution_receipt_count
    ; "terminal_reason_count", `Int !terminal_reason_count
    ; "operator_escalation_count", `Int !operator_escalation_count
    ; "unknown_reaction_count", `Int !unknown_reaction_count
    ; "pending_stimulus_count", `Int pending_stimulus_count
    ; ( "pending_stimulus_ids"
      , `List
          (List.map
             (fun value -> `String value)
             (cap_list 8 pending_stimulus_ids)) )
    ; "latest_recorded_at_unix", option_float_json !latest_recorded_at
    ; "latest_stimulus_id", option_string_json !latest_stimulus_id
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
    ; "row_count", `Int 0
    ; "stimulus_count", `Int 0
    ; "reaction_count", `Int 0
    ; "turn_started_count", `Int 0
    ; "cursor_ack_count", `Int 0
    ; "execution_receipt_count", `Int 0
    ; "terminal_reason_count", `Int 0
    ; "operator_escalation_count", `Int 0
    ; "unknown_reaction_count", `Int 0
    ; "pending_stimulus_count", `Int 0
    ; "pending_stimulus_ids", `List []
    ; "latest_recorded_at_unix", `Null
    ; "latest_stimulus_id", `Null
    ; "read_error", `String error
    ]
;;

let summary_for_keeper ~base_path ~keeper_name ~limit =
  try
    read_recent_for_keeper ~base_path ~keeper_name ~limit
    |> summarize_rows ~keeper_name ~limit
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

let fleet_summary_json ~base_path ~keeper_names ~limit_per_keeper =
  let keeper_names = List.sort_uniq String.compare keeper_names in
  let summaries =
    List.map
      (fun keeper_name -> summary_for_keeper ~base_path ~keeper_name ~limit:limit_per_keeper)
      keeper_names
  in
  let total_int name =
    List.fold_left (fun acc summary -> acc + int_field name summary) 0 summaries
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
  let read_error_count =
    List.fold_left
      (fun acc summary -> acc + summary_read_error_count summary)
      0
      summaries
  in
  let pending_count = total_int "pending_stimulus_count" in
  let row_count = total_int "row_count" in
  let status =
    if read_error_count > 0 then "unknown"
    else if pending_count > 0 then "degraded"
    else if row_count = 0 then "empty"
    else if List.exists (fun summary -> summary_status summary = "degraded") summaries
    then "degraded"
    else "ok"
  in
  `Assoc
    [ "schema", `String fleet_summary_schema
    ; "status", `String status
    ; ( "operator_action_required"
      , `Bool (read_error_count > 0 || pending_count > 0) )
    ; "keeper_count", `Int (List.length keeper_names)
    ; "keeper_names", `List (List.map (fun value -> `String value) keeper_names)
    ; "scanned_row_limit_per_keeper", `Int limit_per_keeper
    ; "row_count", `Int row_count
    ; "stimulus_count", `Int (total_int "stimulus_count")
    ; "reaction_count", `Int (total_int "reaction_count")
    ; "turn_started_count", `Int (total_int "turn_started_count")
    ; "cursor_ack_count", `Int (total_int "cursor_ack_count")
    ; "execution_receipt_count", `Int (total_int "execution_receipt_count")
    ; "terminal_reason_count", `Int (total_int "terminal_reason_count")
    ; "operator_escalation_count", `Int (total_int "operator_escalation_count")
    ; "unknown_reaction_count", `Int (total_int "unknown_reaction_count")
    ; "pending_stimulus_count", `Int pending_count
    ; "pending_by_keeper", `List pending_by_keeper
    ; "read_error_count", `Int read_error_count
    ; "keepers", `List summaries
    ]
;;
