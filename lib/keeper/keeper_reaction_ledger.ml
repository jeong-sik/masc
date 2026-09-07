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

module Event_id_set = Set.Make (String)

let state_change_observer : (unit -> unit) Atomic.t = Atomic.make ignore
let install_state_change_observer observer = Atomic.set state_change_observer observer

let notify_state_change_observer ~keeper_name =
  try (Atomic.get state_change_observer) () with
  | exn ->
    Log.Keeper.warn
      "reaction ledger state-change observer failed keeper=%s: %s"
      keeper_name
      (Printexc.to_string exn)
;;

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
let board_stimulus_id ~post_id = "board:" ^ post_id

let stimulus_kind_of_event_queue (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Keeper_event_queue.Board_signal _ | Keeper_event_queue.Board_attention _ ->
    Board_signal
  | Keeper_event_queue.Bootstrap -> Bootstrap
  | Keeper_event_queue.Fusion_completed _ -> Fusion_completed
  | Keeper_event_queue.Schedule_due _ -> Schedule_due
  | Keeper_event_queue.Connector_attention _ -> Connector_attention
  | Keeper_event_queue.Hitl_resolved _ -> Hitl_resolved
  | Keeper_event_queue.Ask_answered _ -> Ask_answered
  | Keeper_event_queue.Completion_authority_rejected _ ->
    Completion_authority_rejected
  | Keeper_event_queue.Task_cancelled _ -> Task_cancelled
  | Keeper_event_queue.Workspace_message _ -> Workspace_message
  | Keeper_event_queue.Delegate_completed _ -> Delegate_completed
  | Keeper_event_queue.Composition_completed _ -> Composition_completed
;;

let stimulus_id_of_event_queue (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload, stimulus_kind_of_event_queue stimulus with
  | Keeper_event_queue.Board_attention attention, Board_signal ->
    "board-attention:" ^ attention.candidate_id
  | Keeper_event_queue.Board_signal _, Board_signal ->
    board_stimulus_id ~post_id:stimulus.post_id
  | Keeper_event_queue.Schedule_due _, Schedule_due -> stimulus.post_id
  | Keeper_event_queue.Completion_authority_rejected _, Completion_authority_rejected ->
    stimulus.post_id
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

let store_dir ~masc_root ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat (Filename.concat masc_root Common.keepers_runtime_dirname) keeper_name)
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
           reaction.reacted
       | Keeper_event_queue.Vote_cast vote ->
         Printf.sprintf
           "vote_cast target=%s target_author=%s voter=%s direction=%s"
           (match vote.target with
            | Keeper_event_queue.Vote_on_post post_id -> "post:" ^ post_id
            | Keeper_event_queue.Vote_on_comment comment_id -> "comment:" ^ comment_id)
           vote.target_author
           vote.voter
           (match vote.direction with
            | Keeper_event_queue.Vote_up -> "up"
            | Keeper_event_queue.Vote_down -> "down"))
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
  | Keeper_event_queue.Schedule_due sw ->
    Printf.sprintf "schedule_due schedule_id=%s due_at=%.3f" sw.schedule_id sw.due_at
  | Keeper_event_queue.Connector_attention ca ->
    Printf.sprintf "connector_attention event_id=%s" ca.event_id
  | Keeper_event_queue.Ask_answered a ->
    Printf.sprintf "ask_answered ask_id=%s" a.ask_id
  | Keeper_event_queue.Hitl_resolved r ->
    Printf.sprintf
      "hitl_resolved approval=%s decision=%s"
      r.approval_id
      (Keeper_event_queue.hitl_resolution_decision_to_string r.decision)
  | Keeper_event_queue.Completion_authority_rejected rejection ->
    Printf.sprintf
      "completion_authority_rejected task_id=%s verification_id=%s"
      rejection.car_task_id
      rejection.car_verification_id
  | Keeper_event_queue.Task_cancelled cancellation ->
    Printf.sprintf
      "task_cancelled task_id=%s cancelled_by=%s"
      cancellation.tc_task_id
      cancellation.tc_cancelled_by
  | Keeper_event_queue.Workspace_message message ->
    Printf.sprintf
      "workspace_message request_id=%s from=%s"
      message.wmsg_request_id
      message.wmsg_from
  | Keeper_event_queue.Delegate_completed dc ->
    Printf.sprintf
      "keeper_delegate_completed operation_id=%s keeper=%s outcome=%s"
      dc.dc_operation_id
      dc.dc_keeper
      (match dc.dc_terminal with
       | Keeper_event_queue.Delegate_replied _ -> "replied"
       | Keeper_event_queue.Delegate_no_reply -> "no_reply"
       | Keeper_event_queue.Delegate_failed _ -> "failed")
  | Keeper_event_queue.Composition_completed cc ->
    Printf.sprintf
      "keeper_composition_completed request_id=%s tool=%s outcome=%s"
      cc.cc_request_id
      cc.cc_tool
      (match cc.cc_terminal with
       | Keeper_event_queue.Composition_succeeded -> "succeeded"
       | Keeper_event_queue.Composition_failed _ -> "failed"
       | Keeper_event_queue.Composition_cancelled _ -> "cancelled")
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
    | Keeper_event_queue.Schedule_due _
    | Keeper_event_queue.Connector_attention _
    | Keeper_event_queue.Hitl_resolved _
    | Keeper_event_queue.Ask_answered _
    | Keeper_event_queue.Completion_authority_rejected _ -> None
    | Keeper_event_queue.Task_cancelled _ -> None
    | Keeper_event_queue.Workspace_message _ -> None
    | Keeper_event_queue.Delegate_completed _ -> None
    | Keeper_event_queue.Composition_completed _ -> None
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
             ; "urgency", `String (Keeper_event_queue.urgency_to_string stimulus.urgency)
             ; "arrived_at_unix", `Float stimulus.arrived_at
             ; "board_updated_at_unix", Json_util.option_to_yojson (fun value -> `Float value) board_updated_at
             ; "payload_preview", `String (stimulus_payload_preview stimulus.payload)
             ] )
       ])
;;

let record_event_queue_stimulus ~base_path ~keeper_name stimulus =
  Dated_jsonl.append
    (store_for_base_path ~base_path ~keeper_name)
    (stimulus_json ~keeper_name stimulus);
  notify_state_change_observer ~keeper_name
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

let event_queue_turn_finished_json ~keeper_name ~disposition stimulus =
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  let recorded_at = Time_compat.now () in
  `Assoc
    (base_fields
       ~record_kind:"reaction"
       ~event_id:(stimulus_id ^ ":reaction:turn_finished")
       ~keeper_name
       ~recorded_at
     @ [ "stimulus_id", `String stimulus_id
       ; ( "reaction"
         , `Assoc
             [ "kind", `String (reaction_kind_to_string Turn_finished)
             ; "source", `String "keeper_event_queue"
             ; "post_id", `String stimulus.post_id
             ; "stimulus_kind", `String (stimulus_kind_to_string (stimulus_kind_of_event_queue stimulus))
             ; "disposition", `String disposition
             ] )
       ])
;;

let record_event_queue_turn_started ~base_path ~keeper_name stimulus =
  Dated_jsonl.append
    (store_for_base_path ~base_path ~keeper_name)
    (event_queue_turn_started_json ~keeper_name stimulus);
  notify_state_change_observer ~keeper_name
;;

(* The other end of the turn the stimulus opened. Without it a schedule's
   evidence stops at "a turn started at T" and the operator joins the rest by
   comparing that clock against Keeper Calls -- a reconstruction, not evidence.
   [disposition] is the turn boundary's own typed outcome rendered as its
   canonical token; this ledger never decides what a turn did. *)
let record_event_queue_turn_finished ~base_path ~keeper_name ~disposition stimulus =
  Dated_jsonl.append
    (store_for_base_path ~base_path ~keeper_name)
    (event_queue_turn_finished_json ~keeper_name ~disposition stimulus);
  notify_state_change_observer ~keeper_name
;;

let reaction_kind_of_transition = function
  | Keeper_event_queue_state.Cancel_accepted _ -> Event_queue_cancelled
  | Keeper_event_queue_state.Transfer_accepted _ -> Event_queue_ack
  | Keeper_event_queue_state.Ack_source_terminal _ -> Event_queue_ack
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
  let reaction_kind = reaction_kind_of_transition receipt.transition in
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  let event_id = event_queue_transition_event_id receipt source_index in
  `Assoc
    (base_fields
       ~record_kind:"reaction"
       ~event_id
       ~keeper_name
       ~recorded_at:receipt.applied_at
     @ [ "stimulus_id", `String stimulus_id
       ; ( "reaction"
         , `Assoc
             [ "kind", `String (reaction_kind_to_string reaction_kind)
            ; "source", `String "keeper_event_queue_transition"
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

let after_ledger_append_hook :
  (unit -> (unit, string) result) option Atomic.t
  =
  Atomic.make None
;;

let after_ledger_append_hook_mutex = Stdlib.Mutex.create ()

let project_event_queue_transition_outbox_result
      ~base_path
      ~keeper_name
      ~expected_transition_id
  =
  let ( let* ) = Result.bind in
  Keeper_event_queue_persistence.project_transition_outbox_result
    ~append_before_retire:(fun
        (entry : Keeper_event_queue_state.outbox_entry)
      ->
      let* () =
        if String.equal expected_transition_id entry.receipt.transition_id
        then Ok ()
        else
          Error
            (Printf.sprintf
               "event queue transition changed before ledger projection keeper=%s expected_transition_id=%s current_transition_id=%s"
               keeper_name
               expected_transition_id
               entry.receipt.transition_id)
      in
      match entry.stimuli with
      | [] ->
        Error
          (Printf.sprintf
             "event queue transition outbox has no sources keeper=%s transition_id=%s"
             keeper_name
             entry.receipt.transition_id)
      | stimuli ->
        let store = store_for_base_path ~base_path ~keeper_name in
        let source_count = List.length stimuli in
        let rec append_sources source_index = function
          | [] -> Ok ()
          | stimulus :: rest ->
            let event_id =
              event_queue_transition_event_id entry.receipt source_index
            in
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
                    "event queue transition ledger append failed keeper=%s event_id=%s: %s"
                    keeper_name
                    event_id
                    (Printexc.to_string exn)))
        in
        let* () = append_sources 0 stimuli in
        (match Atomic.get after_ledger_append_hook with
         | None -> Ok ()
         | Some hook -> hook ()))
    ~base_path
    ~keeper_name

module For_testing = struct
  let with_after_ledger_append ~after_ledger_append f =
    Stdlib.Mutex.lock after_ledger_append_hook_mutex;
    let previous =
      Atomic.exchange after_ledger_append_hook (Some after_ledger_append)
    in
    Fun.protect
      ~finally:(fun () ->
        Atomic.set after_ledger_append_hook previous;
        Stdlib.Mutex.unlock after_ledger_append_hook_mutex)
      f
  ;;
end

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

type event_queue_reaction_evidence =
  { keeper_name : string
  ; stimulus_id : string
  ; stimulus_seen : bool
  ; turn_started_seen : bool
  ; turn_finished_seen : bool
  ; event_queue_ack_seen : bool
  ; event_queue_cancelled_seen : bool
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; turn_finished_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; event_queue_cancelled_recorded_at : float option
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

type event_queue_reaction_evidence_accumulator =
  { mutable stimulus_seen : bool
  ; mutable turn_started_seen : bool
  ; mutable turn_finished_seen : bool
  ; mutable event_queue_ack_seen : bool
  ; mutable event_queue_cancelled_seen : bool
  ; mutable stimulus_recorded_at : float option
  ; mutable turn_started_recorded_at : float option
  ; mutable turn_finished_recorded_at : float option
  ; mutable event_queue_ack_recorded_at : float option
  ; mutable event_queue_cancelled_recorded_at : float option
  ; mutable latest_recorded_at : float option
  ; mutable matched_record_count : int
  ; mutable quarantined_record_count : int
  ; mutable first_matching_quarantine_reason : row_quarantine_reason option
  ; mutable seen_event_ids : Event_id_set.t
  }

let empty_event_queue_reaction_evidence_accumulator () =
  { stimulus_seen = false
  ; turn_started_seen = false
  ; turn_finished_seen = false
  ; event_queue_ack_seen = false
  ; event_queue_cancelled_seen = false
  ; stimulus_recorded_at = None
  ; turn_started_recorded_at = None
  ; turn_finished_recorded_at = None
  ; event_queue_ack_recorded_at = None
  ; event_queue_cancelled_recorded_at = None
  ; latest_recorded_at = None
  ; matched_record_count = 0
  ; quarantined_record_count = 0
  ; first_matching_quarantine_reason = None
  ; seen_event_ids = Event_id_set.empty
  }
;;

let note_event_queue_reaction_evidence_row ~keeper_name accumulator row =
  let is_replay =
    match string_field "event_id" row with
    | Some event_id
      when not (String.equal event_id "")
           && Event_id_set.mem event_id accumulator.seen_event_ids -> true
    | Some event_id when not (String.equal event_id "") ->
      accumulator.seen_event_ids
        <- Event_id_set.add event_id accumulator.seen_event_ids;
      false
    | Some _ | None -> false
  in
  if not is_replay
  then
    match decode_current_row ~keeper_name row with
    | Error reason ->
      accumulator.quarantined_record_count
        <- accumulator.quarantined_record_count + 1;
      (match accumulator.first_matching_quarantine_reason with
       | Some _ -> ()
       | None -> accumulator.first_matching_quarantine_reason <- Some reason)
    | Ok current_row ->
      accumulator.matched_record_count <- accumulator.matched_record_count + 1;
      let metadata =
        match current_row with
        | Current_stimulus { metadata; _ }
        | Current_reaction { metadata; _ } -> metadata
      in
      let recorded_at = Some metadata.recorded_at in
      accumulator.latest_recorded_at
        <- max_recorded_at accumulator.latest_recorded_at recorded_at;
      (match current_row with
       | Current_stimulus _ ->
         accumulator.stimulus_seen <- true;
         accumulator.stimulus_recorded_at
           <- max_recorded_at accumulator.stimulus_recorded_at recorded_at
       | Current_reaction { reaction_kind = Turn_started; _ } ->
         accumulator.turn_started_seen <- true;
         accumulator.turn_started_recorded_at
           <- max_recorded_at accumulator.turn_started_recorded_at recorded_at
       | Current_reaction { reaction_kind = Turn_finished; _ } ->
         accumulator.turn_finished_seen <- true;
         accumulator.turn_finished_recorded_at
           <- max_recorded_at accumulator.turn_finished_recorded_at recorded_at
       | Current_reaction { reaction_kind = Event_queue_ack; _ } ->
         accumulator.event_queue_ack_seen <- true;
         accumulator.event_queue_ack_recorded_at
           <- max_recorded_at accumulator.event_queue_ack_recorded_at recorded_at
       | Current_reaction { reaction_kind = Event_queue_cancelled; _ } ->
         accumulator.event_queue_cancelled_seen <- true;
         accumulator.event_queue_cancelled_recorded_at
           <- max_recorded_at
                accumulator.event_queue_cancelled_recorded_at
                recorded_at)
;;

let event_queue_reaction_evidence_of_accumulator
      ~keeper_name
      ~stimulus_id
      accumulator
  =
  let evidence =
    { keeper_name
    ; stimulus_id
    ; stimulus_seen = accumulator.stimulus_seen
    ; turn_started_seen = accumulator.turn_started_seen
    ; turn_finished_seen = accumulator.turn_finished_seen
    ; event_queue_ack_seen = accumulator.event_queue_ack_seen
    ; event_queue_cancelled_seen = accumulator.event_queue_cancelled_seen
    ; stimulus_recorded_at = accumulator.stimulus_recorded_at
    ; turn_started_recorded_at = accumulator.turn_started_recorded_at
    ; turn_finished_recorded_at = accumulator.turn_finished_recorded_at
    ; event_queue_ack_recorded_at = accumulator.event_queue_ack_recorded_at
    ; event_queue_cancelled_recorded_at =
        accumulator.event_queue_cancelled_recorded_at
    ; latest_recorded_at = accumulator.latest_recorded_at
    ; matched_record_count = accumulator.matched_record_count
    ; quarantined_record_count = accumulator.quarantined_record_count
    }
  in
  match accumulator.first_matching_quarantine_reason with
  | Some first_reason -> Evidence_quarantined { evidence; first_reason }
  | None -> Evidence_complete evidence
;;

let unique_stimulus_ids stimulus_ids =
  let seen = Hashtbl.create (List.length stimulus_ids) in
  List.fold_left
    (fun unique stimulus_id ->
       if Hashtbl.mem seen stimulus_id
       then unique
       else (
         Hashtbl.add seen stimulus_id ();
         stimulus_id :: unique))
    []
    stimulus_ids
  |> List.rev
;;

(* The dashboard asks this on every refresh, for every Keeper with a wake,
   and the answer used to come from a full scan of that Keeper's ledger.
   Measured 2026-09-07: 22 Keepers hold about 100 MB of reaction ledger, the
   largest 33 MB, and the scan was 4.1% of the process's allocation - a share
   that grows with the ledger, because a ledger only gets longer.

   A day file is append-only, so an answer can be kept and advanced.
   [Dated_jsonl.fold_range_appended] folds only what each file gained since
   the cursors say it was read to, which is the same primitive
   [Keeper_tool_call_log] uses for its trailing window.

   What is kept per Keeper: the cursors, and one accumulator per stimulus the
   dashboard has asked about. Not the ledger, and not every stimulus in it -
   an id nobody asks about is never tracked. An accumulator is five booleans,
   six timestamps, two counts, a reason and the event ids seen for that one
   stimulus.

   A stimulus asked about for the first time cannot be answered from a
   partial read, so it clears the cursors and every tracked accumulator
   restarts from an empty ledger read. That is the same full scan as before,
   once per stimulus rather than once per refresh.

   Bounding the scan by the wake's [started_at] would be wrong, and the
   reason is not obvious: [Keeper_wake_enqueued] carries an
   [occurrence_status], and [Keeper_wake_already_acked] means the wake is a
   repeat for a stimulus enqueued much earlier. Starting the read there drops
   that stimulus's evidence and the dashboard shows "no evidence" for a
   reaction that happened (issue #33798). *)
(* The read covers the whole ledger, so the range starts before any month
   directory could exist. [Dated_jsonl] lists the month directories that are
   there and ignores the rest of the range, so an early date costs nothing. *)
let event_queue_reaction_evidence_epoch = "1970-01-01"

type event_queue_reaction_evidence_cache =
  { mutable cursors : (string * int) list
  ; tracked : (string, event_queue_reaction_evidence_accumulator) Hashtbl.t
  }

(* Keyed by the store directory, so two base paths never share an entry and a
   test working in its own directory starts with an empty cache. *)
let event_queue_reaction_evidence_caches
  : (string, event_queue_reaction_evidence_cache) Hashtbl.t
  =
  Hashtbl.create 8
;;

let event_queue_reaction_evidence_cache_mu = Stdlib.Mutex.create ()

let restart_tracked_accumulators cache =
  let ids = Hashtbl.fold (fun id _ ids -> id :: ids) cache.tracked [] in
  List.iter
    (fun id ->
       Hashtbl.replace cache.tracked id (empty_event_queue_reaction_evidence_accumulator ()))
    ids;
  cache.cursors <- []
;;

(* A file shorter than its cursor was rotated or rewritten, and
   [fold_range_appended] re-reads it from zero rather than skipping rows -
   so the accumulators it just fed have counted those rows twice. The whole
   cache for this Keeper is dropped and read again. *)
let cursor_went_backwards ~previous ~next =
  List.exists
    (fun (path, boundary) ->
       match List.assoc_opt path previous with
       | Some earlier -> boundary < earlier
       | None -> false)
    next
;;

let event_queue_reaction_evidence_batch_result
      ~base_path
      ~keeper_name
      ~stimulus_ids
  =
  if List.exists (String.equal "") stimulus_ids
  then Error Evidence_invalid_stimulus_id
  else
    let stimulus_ids = unique_stimulus_ids stimulus_ids in
    match stimulus_ids with
    | [] -> Ok []
    | _ ->
      let store = store_for_base_path ~base_path ~keeper_name in
      let base_dir = Dated_jsonl.base_dir store in
      let until = Jsonl_writer.day_key ~ts:(Time_compat.now ()) in
      Stdlib.Mutex.protect event_queue_reaction_evidence_cache_mu (fun () ->
        let cache =
          match Hashtbl.find_opt event_queue_reaction_evidence_caches base_dir with
          | Some cache -> cache
          | None ->
            let cache = { cursors = []; tracked = Hashtbl.create 8 } in
            Hashtbl.replace event_queue_reaction_evidence_caches base_dir cache;
            cache
        in
        let untracked =
          List.filter (fun id -> not (Hashtbl.mem cache.tracked id)) stimulus_ids
        in
        if untracked <> []
        then begin
          List.iter
            (fun id ->
               Hashtbl.replace
                 cache.tracked
                 id
                 (empty_event_queue_reaction_evidence_accumulator ()))
            untracked;
          restart_tracked_accumulators cache
        end;
        let advance () =
          let previous = cache.cursors in
          let (), next =
            Dated_jsonl.fold_range_appended
              store
              ~since:event_queue_reaction_evidence_epoch
              ~until
              ~cursors:previous
              ~init:()
              ~f:(fun () row ->
                match string_field "stimulus_id" row with
                | Some stimulus_id ->
                  (match Hashtbl.find_opt cache.tracked stimulus_id with
                   | Some accumulator ->
                     note_event_queue_reaction_evidence_row
                       ~keeper_name
                       accumulator
                       row
                   | None -> ())
                | None -> ())
          in
          cache.cursors <- next;
          cursor_went_backwards ~previous ~next
        in
        match advance () with
        | exception Sys_error detail ->
          Hashtbl.remove event_queue_reaction_evidence_caches base_dir;
          Error
            (Evidence_read_error
               (Dated_jsonl.Io_error
                  { operation = Dated_jsonl.Read_file; path = base_dir; detail }))
        | went_backwards ->
          let rebuilt =
            if went_backwards
            then begin
              restart_tracked_accumulators cache;
              match advance () with
              | exception Sys_error detail -> Error detail
              | _ -> Ok ()
            end
            else Ok ()
          in
          (match rebuilt with
           | Error detail ->
             Hashtbl.remove event_queue_reaction_evidence_caches base_dir;
             Error
               (Evidence_read_error
                  (Dated_jsonl.Io_error
                     { operation = Dated_jsonl.Read_file; path = base_dir; detail }))
           | Ok () ->
             Ok
               (List.map
                  (fun stimulus_id ->
                     ( stimulus_id
                     , event_queue_reaction_evidence_of_accumulator
                         ~keeper_name
                         ~stimulus_id
                         (Hashtbl.find cache.tracked stimulus_id) ))
                  stimulus_ids)))
;;

let event_queue_reaction_evidence_result ~base_path ~keeper_name ~stimulus_id =
  match
    event_queue_reaction_evidence_batch_result
      ~base_path
      ~keeper_name
      ~stimulus_ids:[ stimulus_id ]
  with
  | Error _ as error -> error
  | Ok [ (_, evidence) ] -> Ok evidence
  | Ok _ -> Error Evidence_invalid_stimulus_id
;;

let event_queue_reaction_seen_for_source_result
    ~reaction_matches
    ~base_path
    ~keeper_name
    ~post_id
    ~stimulus_kind
  =
  if String.equal post_id ""
  then Error Evidence_invalid_stimulus_id
  else
    let reaction_seen = ref false in
    let expected_stimulus_kind = stimulus_kind_to_string stimulus_kind in
    let note_parsed_row row =
      match decode_current_row ~keeper_name row with
      | Ok
          (Current_reaction
             { metadata
             ; reaction_kind
             ; transition_receipt
             })
         when reaction_matches reaction_kind transition_receipt ->
        (match assoc_field "reaction" metadata.raw with
         | Some reaction
           when string_field "post_id" reaction = Some post_id
                && string_field "stimulus_kind" reaction
                   = Some expected_stimulus_kind ->
           reaction_seen := true
         | Some _ | None -> ())
      | Ok (Current_stimulus _ | Current_reaction _)
      | Error _ ->
        ()
    in
    let store = store_for_base_path ~base_path ~keeper_name in
    match
      Dated_jsonl.iter_all_entries_result store (function
        | Dated_jsonl.Parsed row -> note_parsed_row row
        | Dated_jsonl.Malformed_json _ -> ())
    with
    | Error error -> Error (Evidence_read_error error)
    | Ok () -> Ok !reaction_seen
;;

let event_queue_turn_started_seen_for_source_result =
  event_queue_reaction_seen_for_source_result
    ~reaction_matches:(fun reaction_kind transition_receipt ->
      match reaction_kind, transition_receipt with
      | Turn_started, None -> true
      | (Event_queue_ack | Event_queue_cancelled), _
      | Turn_finished, _
      | Turn_started, Some _ -> false)
;;

let event_queue_delivery_seen_for_source_result =
  event_queue_reaction_seen_for_source_result
    ~reaction_matches:(fun reaction_kind transition_receipt ->
      match reaction_kind, transition_receipt with
      | Turn_started, None
      | (Event_queue_ack | Event_queue_cancelled), Some _ -> true
      (* A finished row is the turn's outcome, not its delivery: delivery is
         proven by entry and by the queue transitions. *)
      | Turn_finished, _
      | Turn_started, Some _
      | (Event_queue_ack | Event_queue_cancelled), None -> false)
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
    Keeper_event_queue_persistence.load_snapshot_with_errors ~base_path ~keeper_name
  in
  let queue = snapshot.pending in
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
  | Bootstrap | Fusion_completed | Schedule_due
  | Connector_attention | Hitl_resolved | Ask_answered
  | Completion_authority_rejected
  | Task_cancelled
  | Workspace_message
  | Delegate_completed
  | Composition_completed -> None
;;

(* The per-keeper status this module publishes. The fleet roll-up used to
   recover it by reading back the JSON it had just written and comparing the
   string, so a renamed value or a missing field read as "not degraded" with
   nothing to fail the build (#27560). The value travels beside the JSON now
   and the string exists only at the boundary. *)
type keeper_summary_status =
  | Summary_empty
  | Summary_ok
  | Summary_degraded
  | Summary_unknown
  | Summary_unavailable
      (** The store could not be reached at all, which is not the same as
          reaching it and finding nothing ([Summary_empty]) or reading it and
          finding trouble ([Summary_degraded]). It was emitted as a bare
          string beside a four-case type, so the vocabulary a reader had to
          handle was one wider than anything in the code said (#27560). *)

let keeper_summary_status_to_string = function
  | Summary_empty -> "empty"
  | Summary_ok -> "ok"
  | Summary_degraded -> "degraded"
  | Summary_unknown -> "unknown"
  | Summary_unavailable -> "unavailable"
;;

let summarize_rows ~keeper_name ~limit rows =
  let scanned_row_count = List.length rows in
  let current_event_ids = ref Event_id_set.empty in
  let row_count = ref 0 in
  let stimulus_count = ref 0 in
  let reaction_count = ref 0 in
  let turn_started_count = ref 0 in
  let turn_finished_count = ref 0 in
  let event_queue_ack_count = ref 0 in
  let event_queue_cancelled_count = ref 0 in
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
    | Turn_finished, None -> incr turn_finished_count
    | Event_queue_ack, Some _ -> incr event_queue_ack_count
    | Event_queue_cancelled, Some _ -> incr event_queue_cancelled_count
    | Turn_finished, Some _
    | Turn_started, Some _
    | (Event_queue_ack | Event_queue_cancelled), None -> ()
  in
  let note_current_row current_row =
    let metadata =
      match current_row with
      | Current_stimulus { metadata; _ }
      | Current_reaction { metadata; _ } -> metadata
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
    if !row_count = 0 && !quarantined_row_count = 0 then Summary_empty
    else if degraded_signal_count = 0 then Summary_ok
    else Summary_degraded
  in
  ( status
  , `Assoc
    [ "schema", `String summary_schema
    ; "keeper_name", `String keeper_name
    ; "status", `String (keeper_summary_status_to_string status)
    ; "operator_action_required", `Bool (degraded_signal_count > 0)
    ; "scanned_row_count", `Int scanned_row_count
    ; "row_count", `Int !row_count
    ; "stimulus_count", `Int !stimulus_count
    ; "reaction_count", `Int !reaction_count
    ; "turn_started_count", `Int !turn_started_count
    ; "turn_finished_count", `Int !turn_finished_count
    ; "event_queue_ack_count", `Int !event_queue_ack_count
    ; "event_queue_cancelled_count", `Int !event_queue_cancelled_count
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
    ] )
;;

let error_summary ~keeper_name ~limit error =
  ( Summary_unknown
  , `Assoc
    [ "schema", `String summary_schema
    ; "keeper_name", `String keeper_name
    ; "status", `String (keeper_summary_status_to_string Summary_unknown)
    ; "operator_action_required", `Bool true
    ; "scanned_row_count", `Int 0
    ; "row_count", `Int 0
    ; "stimulus_count", `Int 0
    ; "reaction_count", `Int 0
    ; "turn_started_count", `Int 0
    ; "turn_finished_count", `Int 0
    ; "event_queue_ack_count", `Int 0
    ; "event_queue_cancelled_count", `Int 0
    ; "quarantined_row_count", `Int 0
    ; "quarantine_reason_counts", `List []
    ; "cursor_swept_stimulus_count", `Int 0
    ; "pending_stimulus_count", `Int 0
    ; "pending_stimulus_ids", `List []
    ; "latest_recorded_at_unix", `Null
    ; "latest_stimulus_id", `Null
    ; "read_error", `String error
    ] )
;;

(* The status travels with the JSON so the fleet roll-up can read it without
   parsing what this module just wrote. *)
let summary_with_status ~base_path ~keeper_name ~limit =
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

let summary_for_keeper ~base_path ~keeper_name ~limit =
  snd (summary_with_status ~base_path ~keeper_name ~limit)
;;

let summary_read_error_count json =
  match assoc_field "read_error" json with
  | Some (`String _) -> 1
  | _ -> 0
;;

(* Written out so the exhaustive match is what fails when a case is added,
   rather than a caller quietly missing the new string. *)
let fleet_summary_status_strings =
  List.map
    keeper_summary_status_to_string
    [ Summary_empty; Summary_ok; Summary_degraded; Summary_unknown; Summary_unavailable ]
;;

let unavailable_fleet_summary_json () =
  `Assoc
    [ "schema", `String fleet_summary_schema
    ; "status", `String (keeper_summary_status_to_string Summary_unavailable)
    ; "status_reasons", `List []
    ; "operator_action_required", `Bool false
    ; "keeper_count", `Int 0
    ; "keeper_names", `List []
    ; "scanned_row_count", `Int 0
    ; "row_count", `Int 0
    ; "stimulus_count", `Int 0
    ; "reaction_count", `Int 0
    ; "turn_started_count", `Int 0
    ; "turn_finished_count", `Int 0
    ; "event_queue_ack_count", `Int 0
    ; "event_queue_cancelled_count", `Int 0
    ; "quarantined_row_count", `Int 0
    ; "quarantine_reason_counts", `List []
    ; "quarantined_rows_by_keeper", `List []
    ; "cursor_swept_stimulus_count", `Int 0
    ; "pending_stimulus_count", `Int 0
    ; "durable_event_queue_count", `Int 0
    ; "durable_event_queue_pending_count", `Int 0
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
    Keeper_event_queue_persistence.discover_keeper_names_with_durable_state
      ~base_path
  in
  let keeper_names =
    List.sort_uniq
      String.compare
      (keeper_names @ durable_event_queue_discovery.keeper_names)
  in
  (* NDT-OK: fleet summary health renders stale-age telemetry at the read
     boundary; keeper control flow never branches on this timestamp. *)
  let now = Unix.gettimeofday () in
  let summaries_with_status =
    List.map
      (fun keeper_name ->
        summary_with_status ~base_path ~keeper_name ~limit:limit_per_keeper)
      keeper_names
  in
  let summaries = List.map snd summaries_with_status in
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
    then Summary_unknown
    else if
      List.exists
        (fun (status, _) -> status = Summary_degraded)
        summaries_with_status
      || durable_event_queue_stale_count > 0
    then Summary_degraded
    else if row_count = 0 && durable_event_queue_count = 0 then Summary_empty
    else Summary_ok
  in
  `Assoc
    [ "schema", `String fleet_summary_schema
    ; "status", `String (keeper_summary_status_to_string status)
    ; "status_reasons", `List (List.map (fun value -> `String value) status_reasons)
    ; ( "operator_action_required"
      , `Bool
          (status_reasons <> []) )
    ; "keeper_count", `Int (List.length keeper_names)
    ; "keeper_names", `List (List.map (fun value -> `String value) keeper_names)
    ; "scanned_row_count", `Int (total_int "scanned_row_count")
    ; "row_count", `Int row_count
    ; "stimulus_count", `Int (total_int "stimulus_count")
    ; "reaction_count", `Int (total_int "reaction_count")
    ; "turn_started_count", `Int (total_int "turn_started_count")
    ; "turn_finished_count", `Int (total_int "turn_finished_count")
    ; "event_queue_ack_count", `Int (total_int "event_queue_ack_count")
    ; ( "event_queue_cancelled_count"
      , `Int (total_int "event_queue_cancelled_count") )
    ; "quarantined_row_count", `Int quarantined_row_count
    ; "quarantine_reason_counts", quarantine_reason_counts
    ; "quarantined_rows_by_keeper", `List quarantined_rows_by_keeper
    ; "cursor_swept_stimulus_count", `Int (total_int "cursor_swept_stimulus_count")
    ; "pending_stimulus_count", `Int pending_count
    ; "durable_event_queue_count", `Int durable_event_queue_count
    ; "durable_event_queue_pending_count", `Int durable_event_queue_pending_count
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
