type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | No_progress_recovery
  | Fusion_completed  (* RFC-0266: async masc_fusion completion wake *)
  | Bg_completed  (* RFC-0290: generic background job completion wake *)
  | Schedule_due  (* Scheduled automation due wake for a specific keeper *)
  | Connector_attention
      (* RFC-connector-ambient-attention-wake: ambient connector message wake *)
  | Hitl_resolved  (* HITL approval resolution wake — unblocks Skip Approval_pending *)
  | Goal_verification_failed
      (* Goal verification rejection wake — resumes assigned goal work. *)
  | Failure_judgment
      (* RFC-0313 W2: deterministic turn-failure escalated for LLM judgment. *)

type reaction_kind =
  | Turn_started
  | Event_queue_ack
  | Execution_receipt
  | Terminal_reason
  | Cursor_ack
  | Operator_escalation
  | Supervisor_recovery_requested
  | Unknown_reaction of string

let schema = "keeper.reaction_ledger.v1"

let stimulus_kind_to_string = function
  | Board_signal -> "board_signal"
  | Bootstrap -> "bootstrap"
  | No_progress_recovery -> "no_progress_recovery"
  | Fusion_completed -> "fusion_completed"
  | Bg_completed -> "bg_completed"
  | Schedule_due -> "schedule_due"
  | Connector_attention -> "connector_attention"
  | Hitl_resolved -> "hitl_resolved"
  | Goal_verification_failed -> "goal_verification_failed"
  | Failure_judgment -> "failure_judgment"
;;

(* stimulus_kind_to_string의 역. 닫힌 합에 없는 문자열(스키마 드리프트/손상 row)은
   [None]. 소비자([note_stimulus_kind])가 파싱된 variant를 exhaustive match하므로 새
   variant 추가 시 컴파일러가 분류 누락을 강제한다 — RFC-0266에서 [Fusion_completed]가
   문자열 화이트리스트에 누락돼 정상 wake가 unsupported로 오집계된 회귀를 차단한다. *)
let stimulus_kind_of_string = function
  | "board_signal" -> Some Board_signal
  | "bootstrap" -> Some Bootstrap
  | "no_progress_recovery" -> Some No_progress_recovery
  | "fusion_completed" -> Some Fusion_completed
  | "bg_completed" -> Some Bg_completed
  | "schedule_due" -> Some Schedule_due
  | "connector_attention" -> Some Connector_attention
  | "hitl_resolved" -> Some Hitl_resolved
  | "goal_verification_failed" -> Some Goal_verification_failed
  | "failure_judgment" -> Some Failure_judgment
  | _ -> None
;;

let reaction_kind_to_string = function
  | Turn_started -> "turn_started"
  | Event_queue_ack -> "event_queue_ack"
  | Execution_receipt -> "execution_receipt"
  | Terminal_reason -> "terminal_reason"
  | Cursor_ack -> "cursor_ack"
  | Operator_escalation -> "operator_escalation"
  | Supervisor_recovery_requested -> "supervisor_recovery_requested"
  | Unknown_reaction value -> value
;;

(* reaction_kind_to_string의 역(전사). 알려진 문자열은 typed variant로, 그 외에는
   [Unknown_reaction]으로 — reaction_kind는 [Unknown_reaction of string] escape를 가져
   항상 전사다. 소비자([note_reaction_kind])가 exhaustive match하므로 새 typed variant
   추가 시 컴파일러가 분류 누락을 강제한다(stimulus와 동일한 닫힌-합 안티패턴 방지). *)
let reaction_kind_of_string = function
  | "turn_started" -> Turn_started
  | "event_queue_ack" -> Event_queue_ack
  | "execution_receipt" -> Execution_receipt
  | "terminal_reason" -> Terminal_reason
  | "cursor_ack" -> Cursor_ack
  | "operator_escalation" -> Operator_escalation
  | "supervisor_recovery_requested" -> Supervisor_recovery_requested
  | other -> Unknown_reaction other
;;

let option_json f = function
  | Some value -> f value
  | None -> `Null
;;

let list_json values = `List (List.map (fun value -> `String value) values)

let digest_id prefix payload = prefix ^ ":" ^ Digest.to_hex (Digest.string payload)
let board_stimulus_id ~post_id = "board:" ^ post_id

let stimulus_kind_of_event_queue (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Keeper_event_queue.Board_signal _ -> Board_signal
  | Keeper_event_queue.Bootstrap -> Bootstrap
  | Keeper_event_queue.No_progress_recovery -> No_progress_recovery
  | Keeper_event_queue.Fusion_completed _ -> Fusion_completed
  | Keeper_event_queue.Bg_completed _ -> Bg_completed
  | Keeper_event_queue.Schedule_due _ -> Schedule_due
  | Keeper_event_queue.Connector_attention _ -> Connector_attention
  | Keeper_event_queue.Hitl_resolved _ -> Hitl_resolved
  | Keeper_event_queue.Goal_verification_failed _ -> Goal_verification_failed
  | Keeper_event_queue.Failure_judgment _ -> Failure_judgment
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
    ~base_dir:(store_dir ~masc_root:(Workspace.masc_root_dir config) ~keeper_name)
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
  | Keeper_event_queue.Board_signal bs ->
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
  | Keeper_event_queue.No_progress_recovery -> "no_progress_recovery"
  | Keeper_event_queue.Fusion_completed fc ->
    Printf.sprintf "fusion_completed run_id=%s ok=%b" fc.run_id fc.ok
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
  | Keeper_event_queue.Goal_verification_failed failure ->
    Printf.sprintf
      "goal_verification_failed goal_id=%s request_id=%s rejected_by=%s"
      failure.goal_id
      failure.request_id
      failure.rejected_by
  | Keeper_event_queue.Failure_judgment fj ->
    Printf.sprintf
      "failure_judgment runtime=%s class=%s"
      fj.fj_runtime_id
      (Keeper_failure_route.judgment_class_label fj.fj_judgment)
;;

let stimulus_json ~keeper_name (stimulus : Keeper_event_queue.stimulus) =
  let kind = stimulus_kind_of_event_queue stimulus in
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  let recorded_at = Time_compat.now () in
  let board_updated_at =
    match stimulus.payload with
    | Keeper_event_queue.Board_signal bs -> bs.updated_at
    | Keeper_event_queue.Bootstrap
    | Keeper_event_queue.No_progress_recovery
    | Keeper_event_queue.Fusion_completed _
    | Keeper_event_queue.Bg_completed _
    | Keeper_event_queue.Schedule_due _
    | Keeper_event_queue.Connector_attention _
    | Keeper_event_queue.Hitl_resolved _
    | Keeper_event_queue.Goal_verification_failed _
    | Keeper_event_queue.Failure_judgment _ -> None
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

let list_field name json =
  match assoc_field name json with
  | Some (`List values) -> values
  | _ -> []
;;

let bool_field name json =
  match assoc_field name json with
  | Some (`Bool value) -> value
  | _ -> false
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
  }

let max_recorded_at current candidate =
  match current, candidate with
  | None, None -> None
  | Some value, None | None, Some value -> Some value
  | Some left, Some right -> Some (Float.max left right)
;;

let reaction_kind_field row =
  match assoc_field "reaction" row with
  | Some reaction ->
    (match string_field "kind" reaction with
     | None -> None
     | Some kind -> Some (reaction_kind_of_string kind))
  | None -> None
;;

let event_queue_reaction_evidence ~base_path ~keeper_name ~stimulus_id =
  let stimulus_seen = ref false in
  let turn_started_seen = ref false in
  let event_queue_ack_seen = ref false in
  let stimulus_recorded_at = ref None in
  let turn_started_recorded_at = ref None in
  let event_queue_ack_recorded_at = ref None in
  let latest_recorded_at = ref None in
  let matched_record_count = ref 0 in
  let store = store_for_base_path ~base_path ~keeper_name in
  Dated_jsonl.iter_all store (fun row ->
    match string_field "stimulus_id" row with
    | Some row_stimulus_id when String.equal row_stimulus_id stimulus_id ->
      incr matched_record_count;
      let recorded_at = float_field "recorded_at_unix" row in
      latest_recorded_at := max_recorded_at !latest_recorded_at recorded_at;
      (match string_field "record_kind" row with
       | Some record_kind when String.equal record_kind "stimulus" ->
         stimulus_seen := true;
         stimulus_recorded_at := max_recorded_at !stimulus_recorded_at recorded_at
       | Some record_kind when String.equal record_kind "reaction" ->
         (match reaction_kind_field row with
          | Some Turn_started ->
            turn_started_seen := true;
            turn_started_recorded_at
              := max_recorded_at !turn_started_recorded_at recorded_at
          | Some Event_queue_ack ->
            event_queue_ack_seen := true;
            event_queue_ack_recorded_at
              := max_recorded_at !event_queue_ack_recorded_at recorded_at
          | Some Execution_receipt
          | Some Terminal_reason
          | Some Cursor_ack
          | Some Operator_escalation
          | Some Supervisor_recovery_requested
          | Some (Unknown_reaction _)
          | None -> ())
       | Some _
       | None -> ())
    | Some _
    | None -> ());
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
  }
;;

let string_list_field name json =
  list_field name json
  |> List.filter_map (function
    | `String value -> Some value
    | _ -> None)
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

let reaction_receipt_field name row =
  match assoc_field "reaction" row with
  | Some reaction ->
    (match assoc_field "receipt" reaction with
     | Some receipt -> string_field name receipt
     | None -> None)
  | None -> None
;;

let summary_schema = "keeper.reaction_ledger.summary.v1"
let fleet_summary_schema = "keeper.reaction_ledger.fleet_summary.v1"

module Receipt_result = Keeper_completion_contract_result_label

let cap_list limit values =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop limit [] values
;;

let unknown_receipt_contract_result_label raw =
  if raw = "" then "<empty>" else raw
;;

type contract_result_attention =
  | Contract_attention of
      { result : Receipt_result.t
      ; label : string
      }
  | Contract_no_attention

let contract_result_attention_of_typed result =
  if Receipt_result.requires_attention result
  then Contract_attention { result; label = Receipt_result.to_string result }
  else
    Contract_no_attention
;;

let increment_count tbl key =
  let current =
    match Hashtbl.find_opt tbl key with
    | Some value -> value
    | None -> 0
  in
  Hashtbl.replace tbl key (current + 1)
;;

let count_table_json tbl =
  Hashtbl.fold (fun name count acc -> (name, count) :: acc) tbl []
  |> List.sort (fun (left_name, left_count) (right_name, right_count) ->
    let count_cmp = Int.compare right_count left_count in
    if count_cmp <> 0 then count_cmp else String.compare left_name right_name)
  |> List.map (fun (name, count) ->
    `Assoc [ "result", `String name; "count", `Int count ])
  |> fun values -> `List values
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
  if cmp <> 0 then cmp else String.compare post_id_a post_id_b
;;

let board_stimulus_token row =
  match nested_string_field "stimulus" "kind" row with
  | Some "board_signal" ->
    let post_id =
      match nested_string_field "stimulus" "post_id" row with
      | Some value -> value
      | None -> ""
    in
    (match nested_float_field "stimulus" "board_updated_at_unix" row with
     | Some updated_at -> Some ((updated_at, post_id), false)
     | None ->
       (* Legacy rows written before board cursor tokens were persisted still
          need a conservative replay path for live operator visibility. *)
       (match nested_float_field "stimulus" "arrived_at_unix" row with
        | Some arrived_at -> Some ((arrived_at, post_id), true)
        | None -> None))
  | _ -> None
;;

let summarize_rows ~keeper_name ~limit rows =
  let row_count = List.length rows in
  let stimulus_count = ref 0 in
  let reaction_count = ref 0 in
  let turn_started_count = ref 0 in
  let event_queue_ack_count = ref 0 in
  let cursor_ack_count = ref 0 in
  let execution_receipt_count = ref 0 in
  let terminal_reason_count = ref 0 in
  let operator_escalation_count = ref 0 in
  let supervisor_recovery_requested_count = ref 0 in
  let completion_contract_attention_count = ref 0 in
  let completion_contract_passive_only_count = ref 0 in
  let completion_contract_unknown_result_count = ref 0 in
  let unsupported_stimulus_count = ref 0 in
  let payload_parse_error_count = ref 0 in
  let unknown_reaction_count = ref 0 in
  let latest_recorded_at = ref None in
  let latest_stimulus_id = ref None in
  let latest_completion_contract_attention = ref None in
  let completion_contract_result_counts = Hashtbl.create 8 in
  let completion_contract_unknown_result_counts = Hashtbl.create 8 in
  let stimulus_seen = Hashtbl.create 16 in
  let stimulus_kind_by_id = Hashtbl.create 16 in
  let stimulus_recorded_at_by_id = Hashtbl.create 16 in
  let reaction_recorded_at_by_id = Hashtbl.create 16 in
  let board_stimulus_tokens = Hashtbl.create 16 in
  let stimulus_order = ref [] in
  let latest_board_cursor = ref None in
  let cursor_swept_stimulus_count = ref 0 in
  let legacy_cursor_swept_stimulus_count = ref 0 in
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
      (fun stimulus_id (stimulus_token, legacy_token) ->
        if compare_board_cursor_token stimulus_token cursor_token <= 0 then begin
          let before = Hashtbl.find_opt stimulus_seen stimulus_id in
          mark_cursor_swept stimulus_id;
          match before, Hashtbl.find_opt stimulus_seen stimulus_id with
          | Some false, Some true when legacy_token ->
            incr legacy_cursor_swept_stimulus_count
          | _ -> ()
        end)
      board_stimulus_tokens
  in
  let note_board_cursor cursor_token =
    (match !latest_board_cursor with
     | Some latest when compare_board_cursor_token latest cursor_token >= 0 -> ()
     | _ -> latest_board_cursor := Some cursor_token);
    mark_board_cursor_swept cursor_token
  in
  let note_reaction_time stimulus_id = function
    | None -> ()
    | Some value ->
      (match Hashtbl.find_opt reaction_recorded_at_by_id stimulus_id with
       | Some latest when latest >= value -> ()
       | _ -> Hashtbl.replace reaction_recorded_at_by_id stimulus_id value)
  in
  let remember_board_stimulus row stimulus_id =
    match board_stimulus_token row with
    | Some (stimulus_token, legacy_token) ->
      Hashtbl.replace board_stimulus_tokens stimulus_id (stimulus_token, legacy_token);
      (match !latest_board_cursor with
       | Some cursor_token
         when compare_board_cursor_token stimulus_token cursor_token <= 0 ->
         let before = Hashtbl.find_opt stimulus_seen stimulus_id in
         mark_cursor_swept stimulus_id;
         (match before, Hashtbl.find_opt stimulus_seen stimulus_id with
          | Some false, Some true when legacy_token ->
            incr legacy_cursor_swept_stimulus_count
          | _ -> ())
       | _ -> ())
    | None -> ()
  in
  let note_reaction_kind = function
    | None -> incr unknown_reaction_count
    | Some raw ->
      (match reaction_kind_of_string raw with
       | Turn_started -> incr turn_started_count
       | Event_queue_ack -> incr event_queue_ack_count
       | Cursor_ack -> incr cursor_ack_count
       | Execution_receipt -> incr execution_receipt_count
       | Terminal_reason -> incr terminal_reason_count
       | Operator_escalation -> incr operator_escalation_count
       | Supervisor_recovery_requested -> incr supervisor_recovery_requested_count
       | Unknown_reaction _ -> incr unknown_reaction_count)
  in
  let note_contract_attention_label ~result ~label =
    incr completion_contract_attention_count;
    latest_completion_contract_attention := Some label
  in
  let note_contract_result_label ~result ~label =
    (match result with
     | Receipt_result.Passive_only -> incr completion_contract_passive_only_count
     | Receipt_result.Violated
     | Receipt_result.Surface_mismatch
     | Receipt_result.No_capable_provider
     | Receipt_result.Claim_only_after_owned_task
     | Receipt_result.Needs_execution_progress
     | Receipt_result.Unknown
     | Receipt_result.Not_dispatched
     | Receipt_result.Satisfied_completion
     | Receipt_result.Satisfied_execution -> ());
    increment_count completion_contract_result_counts label;
  in
  let note_completion_contract_result row =
    match reaction_receipt_field "completion_contract_result" row with
    | Some result ->
      (match Receipt_result.of_string result with
       | Some typed ->
         let label = Receipt_result.to_string typed in
         note_contract_result_label ~result:typed ~label;
         (match contract_result_attention_of_typed typed with
          | Contract_attention { result; label } ->
            note_contract_attention_label ~result ~label
          | Contract_no_attention -> ())
       | None ->
         let label = unknown_receipt_contract_result_label result in
         incr completion_contract_unknown_result_count;
         increment_count completion_contract_unknown_result_counts label)
    | None -> ()
  in
  let note_stimulus_kind = function
    | None -> incr unsupported_stimulus_count
    | Some raw ->
      (match stimulus_kind_of_string raw with
       | None -> incr unsupported_stimulus_count
       (* 닫힌 합의 모든 variant는 인식된 정상 stimulus다(미지원 아님). 새 variant
          추가 시 이 or-pattern이 non-exhaustive가 되어 컴파일 에러 → 분류 갱신을
          강제한다 (catch-all 금지). *)
       | Some
           ( Board_signal | Bootstrap | No_progress_recovery | Fusion_completed
           | Bg_completed | Schedule_due | Connector_attention | Hitl_resolved
           | Goal_verification_failed | Failure_judgment )
         -> ())
  in
  let note_payload_parse_error row =
    match assoc_field "stimulus" row with
    | Some stimulus_json ->
      (match assoc_field "payload_parse_error" stimulus_json with
       | Some (`String _) -> incr payload_parse_error_count
       | _ -> ())
    | None -> ()
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
        let stimulus_kind = nested_string_field "stimulus" "kind" row in
        note_stimulus_kind stimulus_kind;
        note_payload_parse_error row;
        (match float_field "recorded_at_unix" row with
         | Some recorded_at ->
           Hashtbl.replace stimulus_recorded_at_by_id id recorded_at
         | None -> ());
        (match stimulus_kind with
         | Some kind -> Hashtbl.replace stimulus_kind_by_id id kind
         | None -> ());
        remember_stimulus id;
        remember_board_stimulus row id
      | Some "reaction", Some id ->
        incr reaction_count;
        note_reaction_time id (float_field "recorded_at_unix" row);
        note_reaction_kind (nested_string_field "reaction" "kind" row);
        note_completion_contract_result row;
        mark_reacted id
      | Some "cursor_ack", Some _id ->
        incr reaction_count;
        incr cursor_ack_count;
        (match nested_float_field "cursor" "cursor_ts" row with
         | Some cursor_ts ->
           let cursor_post_id =
             nested_string_field "cursor" "post_id" row |> Option.value ~default:""
           in
           note_board_cursor (cursor_ts, cursor_post_id)
         | None -> ())
      | Some "reaction", None ->
        incr reaction_count;
        note_reaction_kind (nested_string_field "reaction" "kind" row);
        note_completion_contract_result row
      | Some "cursor_ack", None ->
        incr reaction_count;
        incr cursor_ack_count;
        (match nested_float_field "cursor" "cursor_ts" row with
         | Some cursor_ts ->
           let cursor_post_id =
             nested_string_field "cursor" "post_id" row |> Option.value ~default:""
           in
           note_board_cursor (cursor_ts, cursor_post_id)
         | None -> ())
      | _ -> ())
    rows;
  Hashtbl.iter
    (fun id raw_kind ->
       match
         stimulus_kind_of_string raw_kind,
         Hashtbl.find_opt stimulus_seen id,
         Hashtbl.find_opt stimulus_recorded_at_by_id id,
         Hashtbl.find_opt reaction_recorded_at_by_id id
       with
       | Some No_progress_recovery, Some false, Some stimulus_ts, Some reaction_ts
         when reaction_ts >= stimulus_ts ->
         Hashtbl.replace stimulus_seen id true
       | _ -> ())
    stimulus_kind_by_id;
  let pending_stimulus_ids =
    !stimulus_order
    |> List.rev
    |> List.filter (fun id ->
      match Hashtbl.find_opt stimulus_seen id with
      | Some false -> true
      | Some true | None -> false)
  in
  let pending_stimulus_count = List.length pending_stimulus_ids in
  let pending_no_progress_recovery_ids =
    List.filter
      (fun id ->
        match Option.bind (Hashtbl.find_opt stimulus_kind_by_id id) stimulus_kind_of_string with
        | Some No_progress_recovery -> true
        | Some
            ( Board_signal | Bootstrap | Fusion_completed | Bg_completed
            | Schedule_due | Connector_attention | Hitl_resolved
            | Goal_verification_failed | Failure_judgment )
        | None ->
          false)
      pending_stimulus_ids
  in
  let pending_no_progress_recovery_count =
    List.length pending_no_progress_recovery_ids
  in
  let degraded_signal_count =
    pending_stimulus_count
    + !unsupported_stimulus_count
    + !payload_parse_error_count
    + !unknown_reaction_count
    + !completion_contract_unknown_result_count
  in
  let status =
    if row_count = 0 then "empty"
    else if degraded_signal_count = 0 then "ok"
    else "degraded"
  in
  `Assoc
    [ "schema", `String summary_schema
    ; "keeper_name", `String keeper_name
    ; "status", `String status
    ; "operator_action_required", `Bool (degraded_signal_count > 0)
    ; "scanned_row_limit", `Int limit
    ; "row_count", `Int row_count
    ; "stimulus_count", `Int !stimulus_count
    ; "reaction_count", `Int !reaction_count
    ; "turn_started_count", `Int !turn_started_count
    ; "event_queue_ack_count", `Int !event_queue_ack_count
    ; "cursor_ack_count", `Int !cursor_ack_count
    ; "execution_receipt_count", `Int !execution_receipt_count
    ; "terminal_reason_count", `Int !terminal_reason_count
    ; "operator_escalation_count", `Int !operator_escalation_count
    ; "supervisor_recovery_requested_count", `Int !supervisor_recovery_requested_count
    ; "completion_contract_attention_count", `Int !completion_contract_attention_count
    ; "completion_contract_passive_only_count", `Int !completion_contract_passive_only_count
    ; "completion_contract_result_counts", count_table_json completion_contract_result_counts
    ; ( "completion_contract_unknown_result_count"
      , `Int !completion_contract_unknown_result_count )
    ; ( "completion_contract_unknown_result_counts"
      , count_table_json completion_contract_unknown_result_counts )
    ; ( "latest_completion_contract_attention"
      , Json_util.string_opt_to_json !latest_completion_contract_attention )
    ; "unsupported_stimulus_count", `Int !unsupported_stimulus_count
    ; "payload_parse_error_count", `Int !payload_parse_error_count
    ; "unknown_reaction_count", `Int !unknown_reaction_count
    ; "cursor_swept_stimulus_count", `Int !cursor_swept_stimulus_count
    ; "legacy_cursor_swept_stimulus_count", `Int !legacy_cursor_swept_stimulus_count
    ; "pending_stimulus_count", `Int pending_stimulus_count
    ; "pending_no_progress_recovery_count", `Int pending_no_progress_recovery_count
    ; ( "pending_stimulus_ids"
      , `List
          (List.map
             (fun value -> `String value)
             (cap_list 8 pending_stimulus_ids)) )
    ; ( "pending_no_progress_recovery_ids"
      , `List
          (List.map
             (fun value -> `String value)
             (cap_list 8 pending_no_progress_recovery_ids)) )
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
    ; "row_count", `Int 0
    ; "stimulus_count", `Int 0
    ; "reaction_count", `Int 0
    ; "turn_started_count", `Int 0
    ; "cursor_ack_count", `Int 0
    ; "execution_receipt_count", `Int 0
    ; "terminal_reason_count", `Int 0
    ; "operator_escalation_count", `Int 0
    ; "supervisor_recovery_requested_count", `Int 0
    ; "completion_contract_attention_count", `Int 0
    ; "completion_contract_passive_only_count", `Int 0
    ; "completion_contract_result_counts", `List []
    ; "completion_contract_unknown_result_count", `Int 0
    ; "completion_contract_unknown_result_counts", `List []
    ; "latest_completion_contract_attention", `Null
    ; "unsupported_stimulus_count", `Int 0
    ; "payload_parse_error_count", `Int 0
    ; "unknown_reaction_count", `Int 0
    ; "cursor_swept_stimulus_count", `Int 0
    ; "legacy_cursor_swept_stimulus_count", `Int 0
    ; "pending_stimulus_count", `Int 0
    ; "pending_no_progress_recovery_count", `Int 0
    ; "pending_stimulus_ids", `List []
    ; "pending_no_progress_recovery_ids", `List []
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
  let completion_contract_attention_by_keeper =
    List.filter_map
      (fun summary ->
        let attention_count = int_field "completion_contract_attention_count" summary in
        if attention_count = 0
        then None
        else
          Some
            (`Assoc
               [ "keeper_name"
               , (match string_field "keeper_name" summary with
                  | Some value -> `String value
                  | None -> `String "unknown")
               ; "completion_contract_attention_count", `Int attention_count
               ; ( "completion_contract_passive_only_count"
                 , `Int (int_field "completion_contract_passive_only_count" summary) )
               ; ( "latest_completion_contract_attention"
                 , match assoc_field "latest_completion_contract_attention" summary with
                   | Some value -> value
                   | None -> `Null )
               ; ( "completion_contract_result_counts"
                 , `List (list_field "completion_contract_result_counts" summary) )
               ]))
      summaries
  in
  let completion_contract_unknown_results_by_keeper =
    List.filter_map
      (fun summary ->
        let unknown_count = int_field "completion_contract_unknown_result_count" summary in
        if unknown_count = 0
        then None
        else
          Some
            (`Assoc
               [ "keeper_name"
               , (match string_field "keeper_name" summary with
                  | Some value -> `String value
                  | None -> `String "unknown")
               ; "completion_contract_unknown_result_count", `Int unknown_count
               ; ( "completion_contract_unknown_result_counts"
                 , `List
                     (list_field "completion_contract_unknown_result_counts" summary) )
               ]))
      summaries
  in
  let pending_no_progress_recovery_by_keeper =
    List.filter_map
      (fun summary ->
        let pending_count = int_field "pending_no_progress_recovery_count" summary in
        if pending_count = 0
        then None
        else
          Some
            (`Assoc
               [ "keeper_name"
               , (match string_field "keeper_name" summary with
                  | Some value -> `String value
                  | None -> `String "unknown")
               ; "pending_no_progress_recovery_count", `Int pending_count
               ; ( "pending_no_progress_recovery_ids"
                 , match assoc_field "pending_no_progress_recovery_ids" summary with
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
  let pending_no_progress_recovery_count =
    total_int "pending_no_progress_recovery_count"
  in
  let unknown_reaction_count = total_int "unknown_reaction_count" in
  let completion_contract_unknown_result_count =
    total_int "completion_contract_unknown_result_count"
  in
  let unsupported_stimulus_count = total_int "unsupported_stimulus_count" in
  let payload_parse_error_count = total_int "payload_parse_error_count" in
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
      if durable_event_queue_stale_count > 0
      then "durable_event_queue_stale" :: reasons
      else reasons)
    |> (fun reasons ->
      if unknown_reaction_count > 0 then "unknown_reaction" :: reasons else reasons)
    |> (fun reasons ->
      if completion_contract_unknown_result_count > 0
      then "completion_contract_unknown_result" :: reasons
      else reasons)
    |> (fun reasons ->
      if unsupported_stimulus_count > 0 then "unsupported_stimulus" :: reasons else reasons)
    |> (fun reasons ->
      if payload_parse_error_count > 0 then "payload_parse_error" :: reasons else reasons)
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
      || durable_event_queue_stale_count > 0
      || unknown_reaction_count > 0
      || completion_contract_unknown_result_count > 0
      || unsupported_stimulus_count > 0
      || payload_parse_error_count > 0
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
    ; "row_count", `Int row_count
    ; "stimulus_count", `Int (total_int "stimulus_count")
    ; "reaction_count", `Int (total_int "reaction_count")
    ; "turn_started_count", `Int (total_int "turn_started_count")
    ; "event_queue_ack_count", `Int (total_int "event_queue_ack_count")
    ; "cursor_ack_count", `Int (total_int "cursor_ack_count")
    ; "execution_receipt_count", `Int (total_int "execution_receipt_count")
    ; "terminal_reason_count", `Int (total_int "terminal_reason_count")
    ; "operator_escalation_count", `Int (total_int "operator_escalation_count")
    ; "supervisor_recovery_requested_count", `Int (total_int "supervisor_recovery_requested_count")
    ; "completion_contract_attention_count", `Int (total_int "completion_contract_attention_count")
    ; ( "completion_contract_passive_only_count"
      , `Int (total_int "completion_contract_passive_only_count") )
    ; ( "completion_contract_attention_by_keeper"
      , `List completion_contract_attention_by_keeper )
    ; ( "completion_contract_unknown_result_count"
      , `Int completion_contract_unknown_result_count )
    ; ( "completion_contract_unknown_results_by_keeper"
      , `List completion_contract_unknown_results_by_keeper )
    ; "unsupported_stimulus_count", `Int unsupported_stimulus_count
    ; "payload_parse_error_count", `Int payload_parse_error_count
    ; "unknown_reaction_count", `Int unknown_reaction_count
    ; "cursor_swept_stimulus_count", `Int (total_int "cursor_swept_stimulus_count")
    ; ( "legacy_cursor_swept_stimulus_count"
      , `Int (total_int "legacy_cursor_swept_stimulus_count") )
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
    ; "pending_no_progress_recovery_count", `Int pending_no_progress_recovery_count
    ; "pending_by_keeper", `List pending_by_keeper
    ; ( "pending_no_progress_recovery_by_keeper"
      , `List pending_no_progress_recovery_by_keeper )
    ; "read_error_count", `Int read_error_count
    ; "keepers", `List summaries
    ]
;;
