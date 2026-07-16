type lease_kind =
  | Single
  | Board_batch
  | Legacy_inflight

type requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery
  | Retry_after_observed
  | Context_compaction_retry
  | Approval_grant_unconsumed
  | Approval_grant_state_unavailable

type escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }

let escalation_reason_requests_external_input = function
  | Failure_judgment_external_input_requested _ -> true
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed _ -> false
;;

type settlement =
  | Ack
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type lease =
  { lease_id : string
  ; sequence : int64
  ; kind : lease_kind
  ; claimed_at : float option
  ; stimuli : Keeper_event_queue.stimulus list
  }

type transition_receipt =
  { transition_id : string
  ; event_id : string
  ; lease_id : string
  ; lease_sequence : int64
  ; settled_at : float
  ; settlement : settlement
  }

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  }

type t =
  { revision : int64
  ; next_lease_sequence : int64
  ; pending : Keeper_event_queue.t
  ; leases : lease list
  ; last_settlement : transition_receipt option
  ; transition_outbox : outbox_entry list
  }

type settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt

let schema = "keeper.event_queue.state.v2"

let empty =
  { revision = 0L
  ; next_lease_sequence = 1L
  ; pending = Keeper_event_queue.empty
  ; leases = []
  ; last_settlement = None
  ; transition_outbox = []
  }
;;

let revision state = state.revision
let next_lease_sequence state = state.next_lease_sequence
let pending state = state.pending
let leases state = state.leases
let last_settlement state = state.last_settlement
let transition_outbox state = state.transition_outbox
let lease_kind (lease : lease) = lease.kind
let active_lease state =
  match state.leases with
  | [] -> None
  | lease :: _ -> Some lease
;;

let mark_transition_projected ~transition_id state =
  match state.transition_outbox with
  | [ entry ] when String.equal entry.receipt.transition_id transition_id ->
    Ok
      { state with
        last_settlement = Some entry.receipt
      ; transition_outbox = []
      }
  | [] ->
    (match state.last_settlement with
     | Some receipt when String.equal receipt.transition_id transition_id -> Ok state
     | Some _ | None ->
       Error (Printf.sprintf "event queue transition not found: %s" transition_id))
  | [ _ ] ->
    Error (Printf.sprintf "event queue transition not found: %s" transition_id)
  | _ :: _ :: _ -> Error "event queue state has multiple unprojected transitions"
;;
let with_pending pending state = { state with pending }
let with_revision revision state = { state with revision }

let rec queue_contains queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) ->
    Keeper_event_queue.stimulus_identity_equal head stimulus
    || queue_contains rest stimulus
;;

let enqueue_if_missing queue stimulus =
  if queue_contains queue stimulus
  then queue
  else Keeper_event_queue.enqueue queue stimulus
;;

let prepend_missing stimuli queue =
  let missing =
    List.filter (fun stimulus -> not (queue_contains queue stimulus)) stimuli
  in
  Keeper_event_queue.prepend_list missing queue
;;

let append_missing stimuli queue =
  List.fold_left
    (fun pending stimulus -> enqueue_if_missing pending stimulus)
    queue
    stimuli
;;

let remove_stimuli queue stimuli =
  let should_remove stimulus =
    List.exists
      (Keeper_event_queue.stimulus_identity_equal stimulus)
      stimuli
  in
  queue
  |> Keeper_event_queue.to_list
  |> List.filter (fun stimulus -> not (should_remove stimulus))
  |> List.fold_left Keeper_event_queue.enqueue Keeper_event_queue.empty
;;

let lease_id_of_sequence sequence = Printf.sprintf "lease:%Ld" sequence

let make_lease ~kind ~claimed_at stimuli state =
  match stimuli with
  | [] -> Ok (state, None)
  | _ when Int64.equal state.next_lease_sequence Int64.max_int ->
    Error "event queue lease sequence exhausted"
  | _ ->
    let sequence = state.next_lease_sequence in
    let lease =
      { lease_id = lease_id_of_sequence sequence; sequence; kind; claimed_at; stimuli }
    in
    Ok
      ( { state with
          next_lease_sequence = Int64.succ sequence
        ; leases = state.leases @ [ lease ]
        }
      , Some lease )
;;

let lease_admission_blocked state =
  state.leases <> [] || state.transition_outbox <> []
;;

let rec dequeue_first_ready ~ready skipped pending =
  match Keeper_event_queue.dequeue pending with
  | None -> None
  | Some (stimulus, rest) when ready stimulus ->
    Some (stimulus, Keeper_event_queue.prepend_list (List.rev skipped) rest)
  | Some (stimulus, rest) ->
    dequeue_first_ready ~ready (stimulus :: skipped) rest
;;

let claim_when ~claimed_at ~ready state =
  if lease_admission_blocked state
  then Ok (state, None)
  else match dequeue_first_ready ~ready [] state.pending with
  | None -> Ok (state, None)
  | Some (stimulus, pending) ->
    make_lease
      ~kind:Single
      ~claimed_at:(Some claimed_at)
      [ stimulus ]
      { state with pending }
;;

let claim_board ~claimed_at state =
  if lease_admission_blocked state
  then Ok (state, None)
  else (
    let stimuli, pending = Keeper_event_queue.drain_board_all state.pending in
    make_lease ~kind:Board_batch ~claimed_at:(Some claimed_at) stimuli { state with pending })
;;

let add_legacy_inflight stimuli state =
  if lease_admission_blocked state
  then Error "event queue cannot migrate legacy inflight work while a lease or outbox exists"
  else (
    let stimuli = Keeper_event_queue.uniq_stimuli stimuli in
    let pending = remove_stimuli state.pending stimuli in
    make_lease ~kind:Legacy_inflight ~claimed_at:None stimuli { state with pending })
;;

let lease_kind_label = function
  | Single -> "single"
  | Board_batch -> "board_batch"
  | Legacy_inflight -> "legacy_inflight"
;;

let lease_kind_of_label = function
  | "single" -> Ok Single
  | "board_batch" -> Ok Board_batch
  | "legacy_inflight" -> Ok Legacy_inflight
  | label -> Error (Printf.sprintf "unknown event queue lease kind: %s" label)
;;

let requeue_reason_label = function
  | Cycle_busy -> "cycle_busy"
  | Turn_not_scheduled -> "turn_not_scheduled"
  | Rotate_now -> "rotate_now"
  | Cancelled -> "cancelled"
  | Cycle_crashed -> "cycle_crashed"
  | Registration_recovery -> "registration_recovery"
  | Retry_after_observed -> "retry_after_observed"
  | Context_compaction_retry -> "context_compaction_retry"
  | Approval_grant_unconsumed -> "approval_grant_unconsumed"
  | Approval_grant_state_unavailable -> "approval_grant_state_unavailable"
;;

let requeue_reason_of_label = function
  | "cycle_busy" -> Ok Cycle_busy
  | "turn_not_scheduled" -> Ok Turn_not_scheduled
  | "rotate_now" -> Ok Rotate_now
  | "cancelled" -> Ok Cancelled
  | "cycle_crashed" -> Ok Cycle_crashed
  | "registration_recovery" -> Ok Registration_recovery
  | "retry_after_observed" -> Ok Retry_after_observed
  | "context_compaction_retry" -> Ok Context_compaction_retry
  | "approval_grant_unconsumed" -> Ok Approval_grant_unconsumed
  | "approval_grant_state_unavailable" -> Ok Approval_grant_state_unavailable
  | label -> Error (Printf.sprintf "unknown event queue requeue reason: %s" label)
;;

let ( let* ) = Result.bind

let escalation_reason_label = function
  | Failure_judgment_requested -> "failure_judgment_requested"
  | Failure_judgment_boundary_failed _ -> "failure_judgment_boundary_failed"
  | Failure_judgment_external_input_requested _ ->
    "failure_judgment_external_input_requested"
;;

let escalation_reason_detail_to_yojson = function
  | Failure_judgment_requested -> `Null
  | Failure_judgment_boundary_failed { detail } ->
    `Assoc [ "detail", `String detail ]
  | Failure_judgment_external_input_requested { judge_runtime_id; rationale } ->
    `Assoc
      [ "judge_runtime_id", `String judge_runtime_id
      ; "rationale", `String rationale
      ]
;;

let required_nonempty_reason_string ~context name fields =
  match List.assoc_opt name fields with
  | Some (`String value) ->
    let value = String.trim value in
    if String.equal value ""
    then Error (Printf.sprintf "%s.%s must not be empty" context name)
    else Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" context name)
  | None -> Error (Printf.sprintf "%s.%s is required" context name)
;;

let exact_reason_fields ~context expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  let expected = List.sort String.compare expected in
  if actual = expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields must be exactly [%s], got [%s]"
         context
         (String.concat "," expected)
         (String.concat "," actual))
;;

let escalation_reason_of_wire ~label ~detail_json =
  match label, detail_json with
  | "failure_judgment_requested", `Null -> Ok Failure_judgment_requested
  | "failure_judgment_boundary_failed", `Assoc fields ->
    let* () =
      exact_reason_fields
        ~context:"failure_judgment_boundary_failed"
        [ "detail" ]
        fields
    in
    let* detail =
      required_nonempty_reason_string
        ~context:"failure_judgment_boundary_failed"
        "detail"
        fields
    in
    Ok (Failure_judgment_boundary_failed { detail })
  | "failure_judgment_external_input_requested", `Assoc fields ->
    let* () =
      exact_reason_fields
        ~context:"failure_judgment_external_input_requested"
        [ "judge_runtime_id"; "rationale" ]
        fields
    in
    let* judge_runtime_id =
      required_nonempty_reason_string
        ~context:"failure_judgment_external_input_requested"
        "judge_runtime_id"
        fields
    in
    let* rationale =
      required_nonempty_reason_string
        ~context:"failure_judgment_external_input_requested"
        "rationale"
        fields
    in
    Ok (Failure_judgment_external_input_requested { judge_runtime_id; rationale })
  | "failure_judgment_requested", _ ->
    Error (Printf.sprintf "%s reason_detail must be null" label)
  | ( "failure_judgment_boundary_failed"
    | "failure_judgment_external_input_requested" ), _ ->
    Error (Printf.sprintf "%s reason_detail must be an object" label)
  | unknown, _ ->
    Error (Printf.sprintf "unknown event queue escalation reason: %s" unknown)
;;

let settlement_kind_label = function
  | Ack -> "ack"
  | Requeue _ -> "requeue"
  | Escalate _ -> "escalate"
;;

let transition_id (lease : lease) settlement =
  Printf.sprintf "%s:%s" lease.lease_id (settlement_kind_label settlement)
;;

let event_id_of_transition transition_id =
  "keeper-event-queue-transition:" ^ transition_id
;;

let successor_equal left right =
  match left, right with
  | None, None -> true
  | Some left, Some right ->
    Keeper_event_queue.stimulus_identity_equal left right
  | None, Some _ | Some _, None -> false
;;

let settlement_equal left right =
  match left, right with
  | Ack, Ack -> true
  | Requeue left, Requeue right -> left = right
  | ( Escalate { reason = left_reason; successor = left_successor }
    , Escalate { reason = right_reason; successor = right_successor } ) ->
    left_reason = right_reason
    && successor_equal left_successor right_successor
  | Ack, (Requeue _ | Escalate _)
  | Requeue _, (Ack | Escalate _)
  | Escalate _, (Ack | Requeue _) ->
    false
;;

let validate_settlement = function
  | Ack | Requeue _ -> Ok ()
  | Escalate
      { reason = Failure_judgment_requested
      ; successor =
          Some
            { Keeper_event_queue.payload =
                Keeper_event_queue.Failure_judgment _
            ; _
            }
      } ->
    Ok ()
  | Escalate
      { reason = Failure_judgment_boundary_failed { detail }
      ; successor = None
      }
    when String.equal (String.trim detail) "" ->
    Error "failure judgment boundary failure detail must not be empty"
  | Escalate
      { reason =
          Failure_judgment_external_input_requested
            { judge_runtime_id; rationale }
      ; successor = None
      }
    when
      String.equal (String.trim judge_runtime_id) ""
      || String.equal (String.trim rationale) "" ->
    Error "external-input failure judgment evidence must not be empty"
  | Escalate
      { reason =
          ( Failure_judgment_boundary_failed _
          | Failure_judgment_external_input_requested _ )
      ; successor = None
      } ->
    Ok ()
  | Escalate { reason = Failure_judgment_requested; successor = None } ->
    Error "failure judgment request settlement requires a typed successor"
  | Escalate { reason = Failure_judgment_requested; successor = Some _ } ->
    Error "failure judgment request successor has the wrong payload kind"
  | Escalate { reason = Failure_judgment_boundary_failed _; successor = Some _ } ->
    Error "failure judgment boundary failure must not enqueue a successor"
  | Escalate
      { reason = Failure_judgment_external_input_requested _; successor = Some _ }
    ->
    Error "external-input failure judgment must not enqueue a successor"
;;

let receipt_for_lease ~settled_at ~settlement (lease : lease) =
  let transition_id = transition_id lease settlement in
  { transition_id
  ; event_id = event_id_of_transition transition_id
  ; lease_id = lease.lease_id
  ; lease_sequence = lease.sequence
  ; settled_at
  ; settlement
  }
;;

let find_prior_receipt lease_id state =
  match state.transition_outbox with
  | [ entry ] when String.equal entry.receipt.lease_id lease_id -> Some entry.receipt
  | [] | [ _ ] ->
    (match state.last_settlement with
     | Some receipt when String.equal receipt.lease_id lease_id -> Some receipt
     | Some _ | None -> None)
  | _ :: _ :: _ -> None
;;

let remove_lease lease_id leases =
  List.filter
    (fun (lease : lease) -> not (String.equal lease.lease_id lease_id))
    leases
;;

let committed_lease (lease : lease) state =
  List.find_opt
    (fun (current : lease) -> String.equal current.lease_id lease.lease_id)
    state.leases
;;

let lease_equal (left : lease) (right : lease) =
  Int64.equal left.sequence right.sequence
  && String.equal left.lease_id right.lease_id
  && left.kind = right.kind
  && List.length left.stimuli = List.length right.stimuli
  && List.for_all2 Keeper_event_queue.stimulus_identity_equal left.stimuli right.stimuli
;;

let settle ~settled_at ~lease ~settlement state =
  let* () = validate_settlement settlement in
  match committed_lease lease state with
  | None ->
    (match find_prior_receipt lease.lease_id state with
     | Some receipt when settlement_equal receipt.settlement settlement ->
       Ok (state, Already_settled receipt)
     | Some receipt ->
       Error
         (Printf.sprintf
            "event queue lease %s already settled as %s; refusing %s"
            lease.lease_id
            (settlement_kind_label receipt.settlement)
            (settlement_kind_label settlement))
     | None -> Error (Printf.sprintf "event queue lease not found: %s" lease.lease_id))
  | Some committed when not (lease_equal committed lease) ->
    Error (Printf.sprintf "event queue lease payload conflict: %s" lease.lease_id)
  | Some committed ->
    let pending =
      match settlement with
      | Ack -> state.pending
      | Requeue
          ( Retry_after_observed
          | Context_compaction_retry
          | Approval_grant_unconsumed
          | Approval_grant_state_unavailable ) ->
        (* Retryable provider work, a completed context-compaction handoff,
           and a durable one-shot grant retain the exact leased stimuli
           without monopolizing the FIFO front. *)
        append_missing committed.stimuli state.pending
      | Requeue _ -> prepend_missing committed.stimuli state.pending
      | Escalate { successor = None; _ } -> state.pending
      | Escalate { successor = Some successor; _ } ->
        enqueue_if_missing state.pending successor
    in
    let receipt = receipt_for_lease ~settled_at ~settlement committed in
    let outbox_entry =
      { receipt
      ; stimuli = committed.stimuli
      }
    in
    Ok
      ( { state with
          pending
        ; leases = remove_lease committed.lease_id state.leases
        ; transition_outbox = [ outbox_entry ]
        }
      , Settled receipt )
;;

let recover_leases ~settled_at state =
  let rec loop state = function
    | [] -> Ok state
    | lease :: rest ->
      (match
         settle
           ~settled_at
           ~lease
           ~settlement:(Requeue Registration_recovery)
           state
       with
       | Error _ as error -> error
       | Ok (state, (Settled _ | Already_settled _)) -> loop state rest)
  in
  loop state state.leases
;;

let remove_by_post_id post_id state =
  let removed_pending, pending =
    Keeper_event_queue.remove_by_post_id post_id state.pending
  in
  let removed_leases, leases =
    List.fold_right
      (fun (lease : lease) (removed, kept) ->
         let matched, remaining =
           List.partition
             (fun stimulus -> String.equal stimulus.Keeper_event_queue.post_id post_id)
             lease.stimuli
         in
         let kept =
           match remaining with
           | [] -> kept
           | _ -> { lease with stimuli = remaining } :: kept
         in
         matched @ removed, kept)
      state.leases
      ([], [])
  in
  ( Keeper_event_queue.uniq_stimuli (removed_pending @ removed_leases)
  , { state with pending; leases } )
;;

let release_legacy_inflight stimuli state =
  let should_release stimulus =
    List.exists
      (Keeper_event_queue.stimulus_identity_equal stimulus)
      stimuli
  in
  let leases =
    List.filter_map
      (fun (lease : lease) ->
         let remaining = List.filter (fun stimulus -> not (should_release stimulus)) lease.stimuli in
         match remaining with
         | [] -> None
         | _ :: _ -> Some { lease with stimuli = remaining })
      state.leases
  in
  { state with leases }
;;

let assoc_fields ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (context ^ " must be a JSON object")
;;

let required_field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing required field %s" context name)
;;

let string_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be a string" context name)
;;

let float_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (Printf.sprintf "%s.%s must be a number" context name)
;;

let int64_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok (Int64.of_int value)
  | `Intlit value ->
    (match Int64.of_string_opt value with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s.%s must be an int64" context name))
  | _ -> Error (Printf.sprintf "%s.%s must be an int64" context name)
;;

let list_field ~context name parse fields =
  let* value = required_field ~context name fields in
  match value with
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* parsed = parse value in
        loop (parsed :: acc) rest
    in
    loop [] values
  | _ -> Error (Printf.sprintf "%s.%s must be a list" context name)
;;

let int64_json value = `Intlit (Int64.to_string value)

let lease_to_yojson (lease : lease) =
  `Assoc
    [ "lease_id", `String lease.lease_id
    ; "sequence", int64_json lease.sequence
    ; "kind", `String (lease_kind_label lease.kind)
    ; ( "claimed_at_unix"
      , match lease.claimed_at with
        | None -> `Null
        | Some claimed_at -> `Float claimed_at )
    ; "stimuli", `List (List.map Keeper_event_queue.stimulus_to_yojson lease.stimuli)
    ]
;;

let lease_of_yojson json =
  let context = "event queue lease" in
  let* fields = assoc_fields ~context json in
  let* lease_id = string_field ~context "lease_id" fields in
  let* sequence = int64_field ~context "sequence" fields in
  let* kind_label = string_field ~context "kind" fields in
  let* kind = lease_kind_of_label kind_label in
  let* claimed_at =
    match List.assoc_opt "claimed_at_unix" fields with
    | None | Some `Null -> Ok None
    | Some (`Float value) -> Ok (Some value)
    | Some (`Int value) -> Ok (Some (float_of_int value))
    | Some _ -> Error "event queue lease.claimed_at_unix must be a number or null"
  in
  let* stimuli =
    list_field ~context "stimuli" Keeper_event_queue.stimulus_of_yojson fields
  in
  if Int64.compare sequence 1L < 0
  then Error "event queue lease sequence must be positive"
  else if stimuli = []
  then Error "event queue lease must contain at least one stimulus"
  else if kind = Single && List.length stimuli <> 1
  then Error "single event queue lease must contain exactly one stimulus"
  else if
    kind = Board_batch
    && not
         (List.for_all
            (fun (stimulus : Keeper_event_queue.stimulus) ->
               Keeper_event_queue.is_board_signal stimulus.payload)
            stimuli)
  then Error "board event queue lease contains a non-board stimulus"
  else if not (String.equal lease_id (lease_id_of_sequence sequence))
  then Error (Printf.sprintf "event queue lease id/sequence mismatch: %s" lease_id)
  else Ok { lease_id; sequence; kind; claimed_at; stimuli }
;;

let settlement_to_yojson = function
  | Ack -> `Assoc [ "kind", `String "ack" ]
  | Requeue reason ->
    `Assoc
      [ "kind", `String "requeue"
      ; "reason", `String (requeue_reason_label reason)
      ]
  | Escalate { reason; successor } ->
    `Assoc
      [ "kind", `String "escalate"
      ; "reason", `String (escalation_reason_label reason)
      ; "reason_detail", escalation_reason_detail_to_yojson reason
      ; ( "successor"
        , match successor with
          | None -> `Null
          | Some successor -> Keeper_event_queue.stimulus_to_yojson successor )
      ]
;;

let settlement_of_yojson json =
  let context = "event queue settlement" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  match kind with
  | "ack" -> Ok Ack
  | "requeue" ->
    let* reason = string_field ~context "reason" fields in
    let* reason = requeue_reason_of_label reason in
    Ok (Requeue reason)
  | "escalate" ->
    let* reason_label = string_field ~context "reason" fields in
    let reason_detail =
      match List.assoc_opt "reason_detail" fields with
      | Some json -> json
      | None -> `Null
    in
    let* reason = escalation_reason_of_wire ~label:reason_label ~detail_json:reason_detail in
    let* successor =
      match List.assoc_opt "successor" fields with
      | None | Some `Null -> Ok None
      | Some json ->
        let* successor = Keeper_event_queue.stimulus_of_yojson json in
        Ok (Some successor)
    in
    let settlement = Escalate { reason; successor } in
    let* () = validate_settlement settlement in
    Ok settlement
  | kind -> Error (Printf.sprintf "unknown event queue settlement kind: %s" kind)
;;

let transition_receipt_to_yojson receipt =
  `Assoc
    [ "transition_id", `String receipt.transition_id
    ; "event_id", `String receipt.event_id
    ; "lease_id", `String receipt.lease_id
    ; "lease_sequence", int64_json receipt.lease_sequence
    ; "settled_at_unix", `Float receipt.settled_at
    ; "settlement", settlement_to_yojson receipt.settlement
    ]
;;

let transition_receipt_of_yojson json =
  let context = "event queue transition receipt" in
  let* fields = assoc_fields ~context json in
  let* transition_id = string_field ~context "transition_id" fields in
  let* event_id = string_field ~context "event_id" fields in
  let* lease_id = string_field ~context "lease_id" fields in
  let* lease_sequence = int64_field ~context "lease_sequence" fields in
  let* settled_at = float_field ~context "settled_at_unix" fields in
  let* settlement_json = required_field ~context "settlement" fields in
  let* settlement = settlement_of_yojson settlement_json in
  let expected_lease_id = lease_id_of_sequence lease_sequence in
  let expected_transition_id =
    Printf.sprintf "%s:%s" expected_lease_id (settlement_kind_label settlement)
  in
  let expected_event_id = event_id_of_transition expected_transition_id in
  if not (String.equal lease_id expected_lease_id)
  then Error (Printf.sprintf "event queue receipt lease id mismatch: %s" lease_id)
  else if not (String.equal transition_id expected_transition_id)
  then Error (Printf.sprintf "event queue receipt transition id mismatch: %s" transition_id)
  else if not (String.equal event_id expected_event_id)
  then Error (Printf.sprintf "event queue receipt event id mismatch: %s" event_id)
  else
    Ok
      { transition_id
      ; event_id
      ; lease_id
      ; lease_sequence
      ; settled_at
      ; settlement
      }
;;

let outbox_entry_to_yojson entry =
  `Assoc
    [ "receipt", transition_receipt_to_yojson entry.receipt
    ; "stimuli", `List (List.map Keeper_event_queue.stimulus_to_yojson entry.stimuli)
    ]
;;

let outbox_entry_of_yojson json =
  let context = "event queue outbox entry" in
  let* fields = assoc_fields ~context json in
  let* receipt_json = required_field ~context "receipt" fields in
  let* receipt = transition_receipt_of_yojson receipt_json in
  let* stimuli =
    list_field ~context "stimuli" Keeper_event_queue.stimulus_of_yojson fields
  in
  Ok { receipt; stimuli }
;;

let to_yojson state =
  `Assoc
    [ "schema", `String schema
    ; "revision", int64_json state.revision
    ; "next_lease_sequence", int64_json state.next_lease_sequence
    ; "pending", Keeper_event_queue.queue_to_yojson state.pending
    ; "leases", `List (List.map lease_to_yojson state.leases)
    ; ( "last_settlement"
      , match state.last_settlement with
        | None -> `Null
        | Some receipt -> transition_receipt_to_yojson receipt )
    ; ( "transition_outbox"
      , `List (List.map outbox_entry_to_yojson state.transition_outbox) )
    ]
;;

let duplicate_by key values =
  let rec loop seen = function
    | [] -> None
    | value :: rest ->
      let key = key value in
      if List.exists (String.equal key) seen
      then Some key
      else loop (key :: seen) rest
  in
  loop [] values
;;

let validate_state state =
  if Int64.compare state.revision 0L < 0
  then Error "event queue revision must not be negative"
  else if Int64.compare state.next_lease_sequence 1L < 0
  then Error "event queue next lease sequence must be positive"
  else if List.length state.leases > 1
  then Error "event queue state must contain at most one active lease"
  else if List.length state.transition_outbox > 1
  then Error "event queue state must contain at most one unprojected transition"
  else if state.leases <> [] && state.transition_outbox <> []
  then Error "event queue state cannot contain both an active lease and an outbox transition"
  else if
    match state.last_settlement, state.transition_outbox with
    | Some receipt, [ entry ] ->
      String.equal receipt.transition_id entry.receipt.transition_id
    | None, _ | Some _, ([] | _ :: _ :: _) -> false
  then Error "event queue last settlement duplicates the unprojected transition"
  else
    match duplicate_by (fun (lease : lease) -> lease.lease_id) state.leases with
    | Some lease_id -> Error (Printf.sprintf "duplicate event queue lease id: %s" lease_id)
    | None ->
      (match
         duplicate_by
           (fun entry -> entry.receipt.transition_id)
           state.transition_outbox
       with
       | Some transition_id ->
         Error (Printf.sprintf "duplicate event queue transition id: %s" transition_id)
       | None ->
         let max_sequence =
           List.fold_left
             (fun acc (lease : lease) -> Int64.max acc lease.sequence)
             0L
             state.leases
         in
         let max_sequence =
           List.fold_left
             (fun acc entry -> Int64.max acc entry.receipt.lease_sequence)
             max_sequence
             state.transition_outbox
         in
         let max_sequence =
           match state.last_settlement with
           | None -> max_sequence
           | Some receipt -> Int64.max max_sequence receipt.lease_sequence
         in
         if Int64.compare state.next_lease_sequence max_sequence <= 0
         then
           Error
             "event queue next lease sequence must exceed every lease and receipt sequence"
         else Ok state)
;;

let of_yojson json =
  let context = "keeper event queue state" in
  let* fields = assoc_fields ~context json in
  let* schema_value = string_field ~context "schema" fields in
  if not (String.equal schema_value schema)
  then Error (Printf.sprintf "unsupported keeper event queue state schema: %s" schema_value)
  else
    let* revision = int64_field ~context "revision" fields in
    let* next_lease_sequence = int64_field ~context "next_lease_sequence" fields in
    let* pending_json = required_field ~context "pending" fields in
    let* pending = Keeper_event_queue.queue_of_yojson pending_json in
    let* leases = list_field ~context "leases" lease_of_yojson fields in
    let* last_settlement =
      match List.assoc_opt "last_settlement" fields with
      | Some `Null -> Ok None
      | Some json -> transition_receipt_of_yojson json |> Result.map Option.some
      | None -> Error "keeper event queue state missing required field last_settlement"
    in
    let* transition_outbox =
      list_field ~context "transition_outbox" outbox_entry_of_yojson fields
    in
    validate_state
      { revision
      ; next_lease_sequence
      ; pending
      ; leases
      ; last_settlement
      ; transition_outbox
      }
;;
