type accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  }

type source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
  | Turn_completed
  | Turn_attempt_terminal of { detail : string }

type accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type transition =
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

type transition_receipt =
  { transition_id : string
  ; event_id : string
  ; applied_at : float
  ; transition : transition
  }

type projected_disposition_kind =
  | Projected_cancel of { reason_ref : string }
  | Projected_transfer of
      { from_keeper : string
      ; to_keeper : string
      ; target_trace_id : Keeper_id.Trace_id.t
      }
  | Projected_fusion_terminal
  | Projected_hitl_terminal
  | Projected_turn_completed
  | Projected_turn_attempt_terminal

type projected_source_kind =
  | Source_board_signal
  | Source_board_attention
  | Source_bootstrap
  | Source_fusion_completed
  | Source_schedule_due
  | Source_connector_attention
  | Source_hitl_resolved
  | Source_ask_answered
  | Source_completion_authority_rejected
  | Source_task_outcome
  | Source_task_cancelled
  | Source_workspace_message
  | Source_delegate_completed
  | Source_composition_completed

type projected_disposition_witness =
  { transition_id : string
  ; event_id : string
  ; applied_at : float
  ; operator_operation_id : string
  ; transition_ref : string
  ; source_ref : string
  ; post_id : string
  ; urgency : Keeper_event_queue.urgency
  ; source_arrived_at : float
  ; source_kind : projected_source_kind
  ; source_incarnation : int64
  ; kind : projected_disposition_kind
  }

type durable_disposition =
  | Current_receipt of transition_receipt
  | Projected_witness of projected_disposition_witness

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  }

type pending_selection =
  { source : Keeper_event_queue.stimulus
  ; admitted_revision : int64
  ; checkpoint_retentions : int
  ; repetition_scope : Keeper_execution_scope_id.t option
  }

type scope_binding_error =
  | Empty_scope_batch
  | Duplicate_scope_selection
  | Invalid_scope_selection of string
  | Scope_binding_conflict of
      { requested : Keeper_execution_scope_id.t
      ; existing : Keeper_execution_scope_id.t
      }

let scope_binding_error_to_string = function
  | Empty_scope_batch -> "repetition scope binding requires a nonempty source batch"
  | Duplicate_scope_selection -> "repetition scope batch repeats an exact selection"
  | Invalid_scope_selection detail -> "repetition scope selection is stale: " ^ detail
  | Scope_binding_conflict { requested; existing } ->
    Printf.sprintf "repetition scope binding conflict: requested %s, existing %s"
      (Yojson.Safe.to_string (Keeper_execution_scope_id.to_json requested))
      (Yojson.Safe.to_string (Keeper_execution_scope_id.to_json existing))
;;

type t =
  { revision : int64
  ; pending_entries : pending_selection list
  ; last_transition : transition_receipt option
  ; projected_dispositions : durable_disposition list
  ; transition_outbox : outbox_entry list
  ; accepted_transfer_projections : accepted_transfer list
  }

type transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

let empty =
  { revision = 0L
  ; pending_entries = []
  ; last_transition = None
  ; projected_dispositions = []
  ; transition_outbox = []
  ; accepted_transfer_projections = []
  }
;;

let revision state = state.revision
let pending_selections state = state.pending_entries

let source_snapshot_ref source =
  Keeper_event_queue.stimulus_to_yojson source
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let disposition_reason_ref reason =
  ("keeper.event_queue.cancel_reason.v1\000" ^ reason)
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let resolve_pending_selection
      ~source_ref
      ~source_incarnation
      state
  =
  let matching =
    List.filter
      (fun selection ->
         String.equal
           (source_snapshot_ref selection.source)
           source_ref)
      state.pending_entries
  in
  match matching with
  | [ selection ]
    when Int64.equal selection.admitted_revision source_incarnation ->
    Ok selection
  | [ _ ] -> Error "event queue source incarnation changed"
  | [] -> Error "event queue source is no longer pending"
  | _ -> Error "event queue source reference is ambiguous"
;;

let pending state =
  List.fold_left
    (fun queue entry ->
       Keeper_event_queue.enqueue queue entry.source)
    Keeper_event_queue.empty
    state.pending_entries
;;

let last_transition state = state.last_transition

let disposition_operation_id = function
  | Cancel_accepted cancellation -> cancellation.operator_operation_id
  | Transfer_accepted transfer -> transfer.operator_operation_id
  | Ack_source_terminal source_terminal ->
    source_terminal.operator_operation_id
;;

let projected_dispositions state =
  List.map (fun receipt -> Current_receipt receipt) (Option.to_list state.last_transition)
  @ state.projected_dispositions
;;

let transition_outbox state = state.transition_outbox
let accepted_transfer_projections state = state.accepted_transfer_projections

let transition_source = function
  | Cancel_accepted cancellation -> cancellation.source
  | Transfer_accepted transfer -> transfer.source
  | Ack_source_terminal terminal -> terminal.source
;;

let transition_source_incarnation = function
  | Cancel_accepted cancellation -> cancellation.source_incarnation
  | Transfer_accepted transfer -> transfer.source_incarnation
  | Ack_source_terminal terminal -> terminal.source_incarnation
;;

let projected_kind_of_transition = function
  | Cancel_accepted cancellation ->
    Projected_cancel { reason_ref = disposition_reason_ref cancellation.reason }
  | Transfer_accepted transfer ->
    Projected_transfer
      { from_keeper = transfer.from_keeper
      ; to_keeper = transfer.to_keeper
      ; target_trace_id = transfer.target_trace_id
      }
  | Ack_source_terminal { source_receipt = Fusion_terminal _; _ } ->
    Projected_fusion_terminal
  | Ack_source_terminal { source_receipt = Hitl_terminal _; _ } ->
    Projected_hitl_terminal
  | Ack_source_terminal { source_receipt = Turn_completed; _ } ->
    Projected_turn_completed
  | Ack_source_terminal { source_receipt = Turn_attempt_terminal _; _ } ->
    Projected_turn_attempt_terminal
;;

let projected_source_kind = function
  | Keeper_event_queue.Board_signal _ -> Source_board_signal
  | Keeper_event_queue.Board_attention _ -> Source_board_attention
  | Keeper_event_queue.Bootstrap -> Source_bootstrap
  | Keeper_event_queue.Fusion_completed _ -> Source_fusion_completed
  | Keeper_event_queue.Schedule_due _ -> Source_schedule_due
  | Keeper_event_queue.Connector_attention _ -> Source_connector_attention
  | Keeper_event_queue.Hitl_resolved _ -> Source_hitl_resolved
  | Keeper_event_queue.Ask_answered _ -> Source_ask_answered
  | Keeper_event_queue.Completion_authority_rejected _ ->
    Source_completion_authority_rejected
  | Keeper_event_queue.Task_outcome _ -> Source_task_outcome
  | Keeper_event_queue.Task_cancelled _ -> Source_task_cancelled
  | Keeper_event_queue.Workspace_message _ -> Source_workspace_message
  | Keeper_event_queue.Delegate_completed _ -> Source_delegate_completed
  | Keeper_event_queue.Composition_completed _ -> Source_composition_completed
;;

let transition_ref transition =
  let source_ref = source_snapshot_ref (transition_source transition) in
  let fields =
    match transition with
    | Cancel_accepted cancellation ->
      [ "kind", `String "cancel"
      ; "source_ref", `String source_ref
      ; "source_incarnation", `Intlit (Int64.to_string cancellation.source_incarnation)
      ; "operator_operation_id", `String cancellation.operator_operation_id
      ; "reason", `String cancellation.reason
      ]
    | Transfer_accepted transfer ->
      [ "kind", `String "transfer"
      ; "source_ref", `String source_ref
      ; "source_incarnation", `Intlit (Int64.to_string transfer.source_incarnation)
      ; "operator_operation_id", `String transfer.operator_operation_id
      ; "from_keeper", `String transfer.from_keeper
      ; "to_keeper", `String transfer.to_keeper
      ; "target_trace_id", `String (Keeper_id.Trace_id.to_string transfer.target_trace_id)
      ]
    | Ack_source_terminal terminal ->
      let receipt_fields =
        match terminal.source_receipt with
        | Fusion_terminal _ -> [ "source_receipt_kind", `String "fusion" ]
        | Hitl_terminal _ -> [ "source_receipt_kind", `String "hitl" ]
        | Turn_completed -> [ "source_receipt_kind", `String "turn_completed" ]
        | Turn_attempt_terminal _ ->
          (* [detail] is diagnostic rather than operation authority: both the
             full-receipt replay contract and retry callers may supply a newer
             rendering for the same admitted attempt. Keep the compact
             fingerprint aligned with that typed replay identity. *)
          [ "source_receipt_kind", `String "turn_attempt_terminal" ]
      in
      [ "kind", `String "source_terminal"
      ; "source_ref", `String source_ref
      ; "source_incarnation", `Intlit (Int64.to_string terminal.source_incarnation)
      ; "operator_operation_id", `String terminal.operator_operation_id
      ]
      @ receipt_fields
  in
  `Assoc (("schema", `String "keeper.event_queue.transition_ref.v1") :: fields)
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let witness_of_receipt receipt =
  let transition = receipt.transition in
  let source = transition_source transition in
  { transition_id = receipt.transition_id
  ; event_id = receipt.event_id
  ; applied_at = receipt.applied_at
  ; operator_operation_id = disposition_operation_id transition
  ; transition_ref = transition_ref transition
  ; source_ref = source_snapshot_ref source
  ; post_id = source.post_id
  ; urgency = source.urgency
  ; source_arrived_at = source.arrived_at
  ; source_kind = projected_source_kind source.payload
  ; source_incarnation = transition_source_incarnation transition
  ; kind = projected_kind_of_transition transition
  }
;;

let durable_of_projected_receipt receipt =
  Projected_witness (witness_of_receipt receipt)
;;

let durable_transition_id = function
  | Current_receipt receipt -> receipt.transition_id
  | Projected_witness witness -> witness.transition_id
;;

let durable_operation_id = function
  | Current_receipt receipt -> disposition_operation_id receipt.transition
  | Projected_witness witness -> witness.operator_operation_id
;;

let witness_receipt_for_exact_transition witness transition =
  if String.equal witness.transition_ref (transition_ref transition)
  then
    Ok
      { transition_id = witness.transition_id
      ; event_id = witness.event_id
      ; applied_at = witness.applied_at
      ; transition
      }
  else Error "projected disposition transition fingerprint conflicts"
;;

let durable_matches_receipt disposition (receipt : transition_receipt) =
  match disposition with
  | Current_receipt current ->
    String.equal current.transition_id receipt.transition_id
    && String.equal current.event_id receipt.event_id
    && Float.equal current.applied_at receipt.applied_at
    && current.transition = receipt.transition
  | Projected_witness witness ->
    String.equal witness.transition_id receipt.transition_id
    && String.equal witness.event_id receipt.event_id
    && Float.equal witness.applied_at receipt.applied_at
    && String.equal witness.transition_ref (transition_ref receipt.transition)
;;

let transition_receipt_is_projected receipt state =
  List.exists
    (fun disposition -> durable_matches_receipt disposition receipt)
    (projected_dispositions state)
;;

let accounted_stimuli state =
  Keeper_event_queue.to_list (pending state)
  @ List.concat_map
      (fun (entry : outbox_entry) -> entry.stimuli)
      state.transition_outbox
;;

let project_accepted_transfer (transfer : accepted_transfer) state =
  let same_operation (candidate : accepted_transfer) =
    String.equal candidate.operator_operation_id transfer.operator_operation_id
  in
  match List.find_opt same_operation state.accepted_transfer_projections with
  | Some existing when existing = transfer -> Ok (state, Transfer_already_projected)
  | Some _ -> Error "target transfer operation ID conflicts with its durable projection"
  | None ->
    let matching =
      accounted_stimuli state
      |> List.filter (fun candidate ->
        Keeper_event_queue.stimulus_identity_equal candidate transfer.source)
    in
    (match matching with
     | [] ->
       Ok
         ( { state with
             pending_entries =
               state.pending_entries
               @ [ { source = transfer.source
                   ; admitted_revision = state.revision
                   ; checkpoint_retentions = 0
                   ; repetition_scope = None
                   }
                 ]
           ; accepted_transfer_projections =
               state.accepted_transfer_projections @ [ transfer ]
           }
         , Transfer_projected )
     | [ existing ] when existing = transfer.source ->
       Ok
         ( { state with
             accepted_transfer_projections =
               state.accepted_transfer_projections @ [ transfer ]
           }
         , Transfer_already_projected )
     | [ _ ] ->
       Error "target transfer source identity has a different durable snapshot"
     | _ :: _ :: _ ->
       Error "target transfer source identity is duplicated in durable state")
;;

(* schema-compat: projected_dispositions rows keep the same constructors and
   JSON fields; only which prior receipts enter the list changed. *)
let mark_transition_projected ~transition_id ~retain_previous state =
  match state.transition_outbox with
  | [ entry ] when String.equal entry.receipt.transition_id transition_id ->
    (* #38527: the retiring projection is the only moment the prior receipt
       can be judged. A standing asker -- today, a durable paused-work
       disposition receipt keyed by the same operation id, which re-asks by
       [prior_disposition_by_operation_id] -- says the receipt stays; every
       receipt nobody can re-ask (each turn-completion ack, each
       superseded-occurrence cancellation) is dropped here instead of
       accumulating, because the reaction ledger is where its delivery stays
       answerable. The newest receipt still lives in [last_transition], which
       the [projected_dispositions] reader folds in. *)
    let projected_dispositions =
      match state.last_transition with
      | Some receipt when retain_previous receipt ->
        durable_of_projected_receipt receipt :: state.projected_dispositions
      | Some _ | None -> state.projected_dispositions
    in
    Ok
      { state with
        last_transition = Some entry.receipt
      ; projected_dispositions
      ; transition_outbox = []
      }
  | [] ->
    (match
       List.find_opt
         (fun disposition ->
            String.equal (durable_transition_id disposition) transition_id)
         (projected_dispositions state)
     with
     | Some _ -> Ok state
     | None ->
       Error (Printf.sprintf "event queue transition not found: %s" transition_id))
  | [ _ ] ->
    Error (Printf.sprintf "event queue transition not found: %s" transition_id)
  | _ :: _ :: _ -> Error "event queue state has multiple unprojected transitions"
;;
let with_pending pending state =
  let rec take_matching source skipped = function
    | [] -> None, List.rev skipped
    | entry :: rest
      when Keeper_event_queue.stimulus_identity_equal entry.source source
           && entry.source = source ->
      Some entry, List.rev_append skipped rest
    | entry :: rest -> take_matching source (entry :: skipped) rest
  in
  let rec reconcile available acc = function
    | [] -> List.rev acc
    | source :: rest ->
      let existing, available = take_matching source [] available in
      let entry =
        match existing with
        | Some entry -> entry
        | None -> { source; admitted_revision = state.revision; checkpoint_retentions = 0
                 ; repetition_scope = None }
      in
      reconcile available (entry :: acc) rest
  in
  (* Urgency order is a property of the pending list, not of the
     reprioritize/defer transitions alone: an [Immediate] arrival lands ahead
     of every [Normal] entry on arrival, and the sort is stable so arrival
     order is kept among entries of the same urgency. *)
  let pending_entries =
    Keeper_event_queue.sort_by_urgency pending
    |> Keeper_event_queue.to_list
    |> Keeper_event_queue.uniq_stimuli
    |> reconcile state.pending_entries []
  in
  { state with pending_entries }
;;

let with_revision revision state = { state with revision }

let transition_outbox_blocked state = state.transition_outbox <> []

(* #31597: a plain head-of-list scan never looks past the first ready
   [Normal]/[Immediate] entry, so a [Low] entry sitting further back never
   gets picked while the Keeper's own [Normal] backlog keeps refilling ahead
   of it — measured as a recurring schedule dispatching "succeeded" every
   hour for 16 days with zero Board output. [pending_entries] is still
   urgency-sorted on arrival (see [with_pending] above), so this full scan
   is over an already-short, already-ordered list; it picks the ready entry
   with the lowest *effective* urgency rank (aging applied), tie-broken by
   earliest [arrived_at] — which reduces to the old head-of-list behaviour
   whenever no entry has aged, since the list is still urgency-then-arrival
   ordered in that case. *)
let first_ready_entry ~now ~ready entries =
  let rank_of entry = Keeper_event_queue.effective_urgency_rank ~now entry.source in
  entries
  |> List.filter (fun entry -> ready entry.source)
  |> List.fold_left
       (fun best entry ->
          match best with
          | None -> Some entry
          | Some current ->
            let cmp = Int.compare (rank_of entry) (rank_of current) in
            if cmp < 0
            then Some entry
            else if cmp > 0
            then Some current
            else if entry.source.arrived_at < current.source.arrived_at
            then Some entry
            else Some current)
       None
;;

let peek_when ~now ~ready state =
  Option.map
    (fun entry -> entry.source)
    (first_ready_entry ~now ~ready state.pending_entries)
;;

let select_when ~now ~ready state = first_ready_entry ~now ~ready state.pending_entries

let validate_pending_selection
      ~(selection : pending_selection)
      state
  =
  let matching =
    state.pending_entries
    |> List.filter (fun entry ->
      Keeper_event_queue.stimulus_identity_equal
        selection.source
        entry.source)
  in
  match matching with
  | [ actual ] when actual = selection -> Ok ()
  | [ { source; _ } ] when source <> selection.source ->
    Error "event queue pending selection typed snapshot changed"
  | [ _ ] -> Error "event queue pending selection incarnation changed"
  | [] -> Error "event queue pending selection is no longer present"
  | _ :: _ :: _ ->
    Error "event queue pending selection is present more than once"
;;

let ack_pending ~(selection : pending_selection) state =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    let pending_entries =
      List.filter (Fun.negate (( = ) selection)) state.pending_entries
    in
    Ok { state with pending_entries }
;;

let bind_pending_repetition_scope ~selections ~scope state =
  let ( let* ) = Result.bind in
  let* () = if selections = [] then Error Empty_scope_batch else Ok () in
  let rec validate seen = function
    | [] -> Ok ()
    | selection :: rest ->
      let* () = if List.mem selection seen then Error Duplicate_scope_selection else Ok () in
      let* () = validate_pending_selection ~selection state
        |> Result.map_error (fun detail -> Invalid_scope_selection detail) in
      let* () = match selection.repetition_scope with
        | None -> Ok ()
        | Some existing when Keeper_execution_scope_id.equal existing scope -> Ok ()
        | Some existing -> Error (Scope_binding_conflict { requested = scope; existing }) in
      validate (selection :: seen) rest
  in
  let* () = validate [] selections in
  if List.for_all (fun selection -> Option.is_some selection.repetition_scope) selections
  then Ok (state, selections)
  else
    let updates = List.map (fun selection ->
      selection, { selection with repetition_scope = Some scope }) selections in
    let pending_entries = List.map (fun entry ->
      match List.assoc_opt entry updates with
      | Some updated -> updated
      | None -> entry) state.pending_entries in
    Ok ({ state with pending_entries }, List.map snd updates)
;;

(* A checkpoint-yield turn retains Connector_attention entries instead of
   acking them (see [Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome]).
   That retention is a typed fact about delivery, so it is counted on the
   entry itself — durably, because the retention decision spans cycles and a
   server restart must not reset it. The returned selection carries the new
   count: validation is structural, so the caller's pre-bump snapshot is
   spent and must not be reused for a later ack or defer of this entry. *)
let note_checkpoint_retention ~(selection : pending_selection) state =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    let retentions = selection.checkpoint_retentions + 1 in
    let updated = { selection with checkpoint_retentions = retentions } in
    let pending_entries =
      List.map
        (fun entry -> if entry = selection then updated else entry)
        state.pending_entries
    in
    Ok ({ state with pending_entries }, (updated, retentions))
;;

let reprioritize_pending
      ~(selection : pending_selection)
      ~urgency
      state
  =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    if selection.source.urgency = urgency
    then Ok (state, state.revision)
    else if Int64.equal state.revision Int64.max_int
    then Error "event queue revision exhausted"
    else
      let next_revision = Int64.succ state.revision in
      let updated =
        { source = { selection.source with urgency }
        ; admitted_revision = next_revision
        ; checkpoint_retentions = selection.checkpoint_retentions
        ; repetition_scope = selection.repetition_scope
        }
      in
      let pending_entries =
        List.map
          (fun entry -> if entry = selection then updated else entry)
          state.pending_entries
      in
      let state = { state with pending_entries } in
      let sorted_pending =
        pending state |> Keeper_event_queue.sort_by_urgency
      in
      Ok (with_pending sorted_pending state, next_revision)
;;

let defer_pending ~(selection : pending_selection) state =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    if Int64.equal state.revision Int64.max_int
    then Error "event queue revision exhausted"
    else
      let next_revision = Int64.succ state.revision in
      let deferred = { selection with admitted_revision = next_revision } in
      let same_urgency, other_urgency =
        state.pending_entries
        |> List.filter (Fun.negate (( = ) selection))
        |> List.partition (fun entry ->
          entry.source.urgency = selection.source.urgency)
      in
      let pending_entries = same_urgency @ [ deferred ] @ other_urgency in
      let state = { state with pending_entries } in
      let sorted_pending = state |> pending |> Keeper_event_queue.sort_by_urgency in
      Ok (with_pending sorted_pending state, next_revision)
;;

let ( let* ) = Result.bind

let pending_transition_id = function
  | Cancel_accepted cancellation ->
    "pending-cancel:" ^ cancellation.operator_operation_id
  | Transfer_accepted transfer ->
    "pending-transfer:" ^ transfer.operator_operation_id
  | Ack_source_terminal source_terminal ->
    "pending-source-terminal-ack:" ^ source_terminal.operator_operation_id
;;

let event_id_of_transition transition_id =
  "keeper-event-queue-transition:" ^ transition_id
;;

let transition_equal left right =
  match left, right with
  | Cancel_accepted left, Cancel_accepted right -> left = right
  | Transfer_accepted left, Transfer_accepted right -> left = right
  | Ack_source_terminal left, Ack_source_terminal right ->
    left = right
  | _ -> false
;;

let transition_receipt_equal (left : transition_receipt) (right : transition_receipt) =
  String.equal left.transition_id right.transition_id
  && String.equal left.event_id right.event_id
  && Float.equal left.applied_at right.applied_at
  && left.transition = right.transition
;;

let validate_accepted_cancellation (cancellation : accepted_cancellation) =
  if String.equal (String.trim cancellation.source.post_id) ""
  then Error "accepted cancellation source post id must not be empty"
  else if Int64.compare cancellation.source_incarnation 0L < 0
  then Error "accepted cancellation source incarnation must not be negative"
  else if String.equal (String.trim cancellation.operator_operation_id) ""
  then Error "accepted cancellation operator operation id must not be empty"
  else if String.equal (String.trim cancellation.reason) ""
  then Error "accepted cancellation reason must not be empty"
  else Ok ()
;;

let validate_accepted_transfer (transfer : accepted_transfer) =
  if String.equal (String.trim transfer.source.post_id) ""
  then Error "accepted transfer source post id must not be empty"
  else if Int64.compare transfer.source_incarnation 0L < 0
  then Error "accepted transfer source incarnation must not be negative"
  else if String.equal (String.trim transfer.operator_operation_id) ""
  then Error "accepted transfer operator operation id must not be empty"
  else if String.equal (String.trim transfer.from_keeper) ""
  then Error "accepted transfer source Keeper must not be empty"
  else if String.equal (String.trim transfer.to_keeper) ""
  then Error "accepted transfer target Keeper must not be empty"
  else if String.equal transfer.from_keeper transfer.to_keeper
  then Error "accepted transfer source and target Keepers must differ"
  else Ok ()
;;

let source_terminal_receipt_of_stimulus source =
  match source.Keeper_event_queue.payload with
  | Keeper_event_queue.Fusion_completed completion ->
    Ok (Fusion_terminal completion)
  | Keeper_event_queue.Hitl_resolved resolution -> Ok (Hitl_terminal resolution)
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Completion_authority_rejected _
  (* The approval twin of the rejection: it is not a repair receipt either,
     and its producer is the one being woken. *)
  | Keeper_event_queue.Task_outcome _
  | Keeper_event_queue.Task_cancelled _
  | Keeper_event_queue.Workspace_message _
  (* Transferable receipts are the ones an operator can hand to another
     Keeper. A delegation answer belongs to the Keeper that asked; moving it
     would deliver an answer to someone who never asked. *)
  | Keeper_event_queue.Delegate_completed _
  (* Same reason: an answer belongs to the Keeper that asked the question. *)
  | Keeper_event_queue.Ask_answered _
  (* Same reason: an async composition's result belongs to the Keeper that
     submitted it. *)
  | Keeper_event_queue.Composition_completed _ ->
    Error "source event does not carry a typed terminal receipt"
;;

let validate_accepted_source_terminal
      (source_terminal : accepted_source_terminal)
  =
  if String.equal (String.trim source_terminal.source.post_id) ""
  then Error "source-terminal ACK source post id must not be empty"
  else if Int64.compare source_terminal.source_incarnation 0L < 0
  then Error "source-terminal ACK source incarnation must not be negative"
  else if String.equal (String.trim source_terminal.operator_operation_id) ""
  then Error "source-terminal ACK operation id must not be empty"
  else (
    match source_terminal.source_receipt with
    | Turn_completed | Turn_attempt_terminal _ -> Ok ()
    | (Fusion_terminal _ | Hitl_terminal _) as expected ->
      let* receipt = source_terminal_receipt_of_stimulus source_terminal.source in
      if receipt = expected
      then Ok ()
      else Error "source-terminal ACK receipt does not match source payload")
;;

let validate_transition = function
  | Cancel_accepted cancellation -> validate_accepted_cancellation cancellation
  | Transfer_accepted transfer -> validate_accepted_transfer transfer
  | Ack_source_terminal source_terminal ->
    validate_accepted_source_terminal source_terminal
;;

(* Pure receipt-vs-stimuli invariant shared by the live pending-transition
   path and the persist decode boundary. *)
let validate_transition_for_stimuli transition stimuli =
  match transition, stimuli with
  | Cancel_accepted cancellation, [ source ] when cancellation.source = source ->
    Ok ()
  | Cancel_accepted _, [ _ ] ->
    Error "accepted cancellation source does not match its exact event stimulus"
  | Cancel_accepted _, _ ->
    Error "accepted cancellation requires exactly one accepted event stimulus"
  | Transfer_accepted transfer, [ source ] when transfer.source = source -> Ok ()
  | Transfer_accepted _, [ _ ] ->
    Error "accepted transfer source does not match its exact event stimulus"
  | Transfer_accepted _, _ ->
    Error "accepted transfer requires exactly one accepted event stimulus"
  | Ack_source_terminal source_terminal, [ source ]
    when source_terminal.source = source -> Ok ()
  | Ack_source_terminal _, [ _ ] ->
    Error "source-terminal receipt does not match its exact event stimulus"
  | Ack_source_terminal _, _ ->
    Error "source-terminal ACK requires exactly one accepted event stimulus"
;;

let receipt_for_pending_transition ~applied_at ~transition =
  let transition_id = pending_transition_id transition in
  { transition_id
  ; event_id = event_id_of_transition transition_id
  ; applied_at
  ; transition
  }
;;

let apply_pending_transition ~applied_at ~transition ~source ~pending state =
  if not (Float.is_finite applied_at)
  then Error "event queue transition application time must be finite"
  else
    let* () = validate_transition transition in
    let* () = validate_transition_for_stimuli transition [ source ] in
    let receipt = receipt_for_pending_transition ~applied_at ~transition in
    let state = with_pending pending state in
    Ok
      ( { state with
          transition_outbox = [ { receipt; stimuli = [ source ] } ]
        }
      , Transition_applied receipt )
;;

let prior_disposition_by_operation_id operation_id state =
  let is_same_operation disposition =
    String.equal (durable_operation_id disposition) operation_id
  in
  match state.transition_outbox with
  | [ entry ]
    when String.equal
           (disposition_operation_id entry.receipt.transition)
           operation_id ->
    Some (Current_receipt entry.receipt)
  | [] | [ _ ] ->
    List.find_opt is_same_operation (projected_dispositions state)
  | _ :: _ :: _ -> None
;;

let accepted_pending_cancellation_replay cancellation state =
  let requested = Cancel_accepted cancellation in
  match
    prior_disposition_by_operation_id cancellation.operator_operation_id state
  with
  | None -> Ok None
  | Some (Current_receipt receipt)
    when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some (Projected_witness witness) ->
    witness_receipt_for_exact_transition witness requested
    |> Result.map Option.some
    |> Result.map_error (fun _ ->
      Printf.sprintf
        "accepted cancellation operation conflict: %s"
        cancellation.operator_operation_id)
  | Some (Current_receipt _) ->
    Error
      (Printf.sprintf
         "accepted cancellation operation conflict: %s"
         cancellation.operator_operation_id)
;;

let cancel_pending_accepted
      ~applied_at
      ~cancellation
      state
  =
  let transition = Cancel_accepted cancellation in
  match accepted_pending_cancellation_replay cancellation state with
  | Error _ as error -> error
  | Ok (Some receipt) ->
    Ok (state, Transition_already_applied receipt)
  | Ok None ->
    let* () = validate_accepted_cancellation cancellation in
    let* () =
      (* Identity and admission revision, not full structural equality:
         a live entry can carry checkpoint retentions the receipt cannot
         know, so exact-selection comparison would fail against a retained
         entry. *)
      resolve_pending_selection
        ~source_ref:(source_snapshot_ref cancellation.source)
        ~source_incarnation:cancellation.source_incarnation
        state
      |> Result.map (fun _ -> ())
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot cancel pending work while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list (pending state)
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal cancellation.source source)
    in
    (match matching with
     | [] -> Error "accepted cancellation source is not pending"
     | _ :: _ :: _ -> Error "accepted cancellation source identity is duplicated"
     | [ source ] when source <> cancellation.source ->
       Error "accepted cancellation source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       apply_pending_transition
         ~applied_at
         ~transition
         ~source
         ~pending
         state)
;;

let accepted_pending_transfer_replay transfer state =
  let requested = Transfer_accepted transfer in
  match prior_disposition_by_operation_id transfer.operator_operation_id state with
  | None -> Ok None
  | Some (Current_receipt receipt)
    when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some (Projected_witness witness) ->
    witness_receipt_for_exact_transition witness requested
    |> Result.map Option.some
    |> Result.map_error (fun _ ->
      Printf.sprintf
        "accepted transfer operation conflict: %s"
        transfer.operator_operation_id)
  | Some (Current_receipt _) ->
    Error
      (Printf.sprintf
         "accepted transfer operation conflict: %s"
         transfer.operator_operation_id)
;;

let transfer_pending_accepted
      ~applied_at
      ~transfer
      state
  =
  let transition = Transfer_accepted transfer in
  match accepted_pending_transfer_replay transfer state with
  | Error _ as error -> error
  | Ok (Some receipt) -> Ok (state, Transition_already_applied receipt)
  | Ok None ->
    let* () = validate_accepted_transfer transfer in
    let* () =
      (* Identity and admission revision, not full structural equality:
         a live entry can carry checkpoint retentions the receipt cannot
         know, so exact-selection comparison would fail against a retained
         entry. *)
      resolve_pending_selection
        ~source_ref:(source_snapshot_ref transfer.source)
        ~source_incarnation:transfer.source_incarnation
        state
      |> Result.map (fun _ -> ())
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot transfer pending work while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list (pending state)
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal transfer.source source)
    in
    (match matching with
     | [] -> Error "accepted transfer source is not pending"
     | _ :: _ :: _ -> Error "accepted transfer source identity is duplicated"
     | [ source ] when source <> transfer.source ->
       Error "accepted transfer source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       apply_pending_transition
         ~applied_at
         ~transition
         ~source
         ~pending
         state)
;;

let accepted_pending_source_terminal_ack_replay source_terminal state =
  let requested = Ack_source_terminal source_terminal in
  match
    prior_disposition_by_operation_id
      source_terminal.operator_operation_id
      state
  with
  | None -> Ok None
  | Some (Current_receipt receipt)
    when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some (Projected_witness witness) ->
    witness_receipt_for_exact_transition witness requested
    |> Result.map Option.some
    |> Result.map_error (fun _ ->
      Printf.sprintf
        "source-terminal ACK operation conflict: %s"
        source_terminal.operator_operation_id)
  | Some (Current_receipt _) ->
    Error
      (Printf.sprintf
         "source-terminal ACK operation conflict: %s"
         source_terminal.operator_operation_id)
;;

let turn_attempt_terminal_operation_id
      ~admitted_revision
      source
  =
  Printf.sprintf
    "turn-attempt-terminal:%Ld:%s"
    admitted_revision
    (source_snapshot_ref source)
;;

let ack_pending_source_terminal
      ~applied_at
      ~source_terminal
      state
  =
  let ack = Ack_source_terminal source_terminal in
  match accepted_pending_source_terminal_ack_replay source_terminal state with
  | Error _ as error -> error
  | Ok (Some receipt) -> Ok (state, Transition_already_applied receipt)
  | Ok None ->
    let* () = validate_accepted_source_terminal source_terminal in
    let* () =
      (* Identity and admission revision, not full structural equality:
         a live entry can carry checkpoint retentions the receipt cannot
         know, so exact-selection comparison would fail against a retained
         entry. *)
      resolve_pending_selection
        ~source_ref:(source_snapshot_ref source_terminal.source)
        ~source_incarnation:source_terminal.source_incarnation
        state
      |> Result.map (fun _ -> ())
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot ACK pending source while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list (pending state)
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal source_terminal.source source)
    in
    (match matching with
     | [] -> Error "source-terminal ACK source is not pending"
     | _ :: _ :: _ ->
       Error "source-terminal ACK source identity is duplicated"
     | [ source ] when source <> source_terminal.source ->
       Error "source-terminal ACK source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       apply_pending_transition
         ~applied_at
         ~transition:ack
         ~source
         ~pending
       state)
;;

let turn_terminal_receipt_matches_replay left right =
  match left, right with
  | Turn_completed, Turn_completed
  | Turn_attempt_terminal _, Turn_attempt_terminal _ ->
    true
  | Fusion_terminal _, _
  | Hitl_terminal _, _
  | Turn_completed, _
  | Turn_attempt_terminal _, _ ->
    false
;;

let terminalize_pending_turn
      ~applied_at
      ~selection
      ~source_receipt
      state
  =
  let { source; admitted_revision } = selection in
  let operator_operation_id =
    turn_attempt_terminal_operation_id
      ~admitted_revision
      source
  in
  match prior_disposition_by_operation_id operator_operation_id state with
  | Some
      (Current_receipt
        ({ transition =
             Ack_source_terminal
               { source = prior_source
               ; source_receipt = prior_source_receipt
               ; _
               }
         ; _
         } as receipt))
    when prior_source = source
         && turn_terminal_receipt_matches_replay
              prior_source_receipt
              source_receipt ->
    Ok (state, Transition_already_applied receipt)
  | Some (Projected_witness witness)
    when String.equal witness.source_ref (source_snapshot_ref source)
         && Int64.equal witness.source_incarnation admitted_revision
         && (match witness.kind, source_receipt with
             | Projected_turn_completed, Turn_completed
             | Projected_turn_attempt_terminal, Turn_attempt_terminal _ -> true
             | Projected_fusion_terminal, Fusion_terminal _
             | Projected_hitl_terminal, Hitl_terminal _ ->
               String.equal witness.transition_ref (transition_ref (Ack_source_terminal
                 { source
                 ; source_incarnation = admitted_revision
                 ; operator_operation_id
                 ; source_receipt
                 }))
             | Projected_cancel _, _
             | Projected_transfer _, _
             | Projected_fusion_terminal, _
             | Projected_hitl_terminal, _
             | Projected_turn_completed, _
             | Projected_turn_attempt_terminal, _ -> false) ->
    let transition =
      Ack_source_terminal
        { source
        ; source_incarnation = admitted_revision
        ; operator_operation_id
        ; source_receipt
        }
    in
    let receipt =
      { transition_id = witness.transition_id
      ; event_id = witness.event_id
      ; applied_at = witness.applied_at
      ; transition
      }
    in
    Ok (state, Transition_already_applied receipt)
  | Some _ ->
    Error
      (Printf.sprintf
         "turn-attempt terminal operation conflict: %s"
         operator_operation_id)
  | None ->
    let* () = validate_pending_selection ~selection state in
    let source_terminal =
      { source
      ; source_incarnation = admitted_revision
      ; operator_operation_id
      ; source_receipt
      }
    in
    ack_pending_source_terminal
      ~applied_at
      ~source_terminal
      state
;;

let terminalize_pending_turn_attempt
      ~applied_at
      ~selection
      ~detail
      state
  =
  terminalize_pending_turn
    ~applied_at
    ~selection
    ~source_receipt:(Turn_attempt_terminal { detail })
    state
;;

let terminalize_pending_turn_completed
      ~applied_at
      ~selection
      state
  =
  terminalize_pending_turn
    ~applied_at
    ~selection
    ~source_receipt:Turn_completed
    state
;;

(* A turn leaves its batch pending until its terminal receipt, and a
   schedule withdrawal, a transfer or another source's terminal may remove an
   entry of that batch meanwhile; a withdrawal fold reads the pending list
   once and may find an entry already settled when it reaches it. The
   operation's own receipt answers first, so a replay still reads as a
   replay; only an operation with no receipt whose source identity is gone
   from the pending entries has nothing left to do. *)
let pending_source_left ~operator_operation_id ~source state =
  Option.is_none (prior_disposition_by_operation_id operator_operation_id state)
  && not
       (List.exists
          (fun entry -> Keeper_event_queue.stimulus_identity_equal source entry.source)
          state.pending_entries)
;;

let pending_turn_selection_withdrawn ~(selection : pending_selection) state =
  pending_source_left
    ~operator_operation_id:
      (turn_attempt_terminal_operation_id
         ~admitted_revision:selection.admitted_revision
         selection.source)
    ~source:selection.source
    state
;;

let pending_cancellation_source_withdrawn ~(cancellation : accepted_cancellation) state =
  pending_source_left
    ~operator_operation_id:cancellation.operator_operation_id
    ~source:cancellation.source
    state
;;

type admitted_selection_standing =
  | Admitted_selection_pending
  | Admitted_selection_withdrawn

let admitted_selection_standing ~selection state =
  if pending_turn_selection_withdrawn ~selection state
  then Ok Admitted_selection_withdrawn
  else
    validate_pending_selection ~selection state
    |> Result.map (fun () -> Admitted_selection_pending)
;;

let restore_pending_transition entry state apply =
  let* replayed, result = apply state in
  let actual_receipt =
    match result with
    | Transition_applied receipt | Transition_already_applied receipt -> receipt
  in
  match replayed.transition_outbox with
  | [ actual ]
    when transition_receipt_equal entry.receipt actual_receipt
         && actual.stimuli = entry.stimuli ->
    Ok replayed
  | [] | [ _ ] | _ :: _ :: _ ->
    Error
      (Printf.sprintf
         "pending transition WAL replay conflict: %s"
         entry.receipt.transition_id)
;;

let replay_transition_outbox_entry entry state =
  match state.transition_outbox with
  | [ current ] when current = entry -> Ok state
  | [ current ] ->
    Error
      (Printf.sprintf
         "event queue WAL conflicts with checkpointed outbox: %s"
         current.receipt.transition_id)
  | _ :: _ :: _ -> Error "event queue checkpoint contains multiple outbox entries"
  | [] ->
    (match
       List.find_opt
         (fun disposition -> durable_matches_receipt disposition entry.receipt)
         (projected_dispositions state)
     with
     | Some _ -> Ok state
     | None ->
       (match entry.receipt.transition, entry.stimuli with
     | Cancel_accepted cancellation, [ source ] when source = cancellation.source ->
       restore_pending_transition entry state (fun state ->
         cancel_pending_accepted
           ~applied_at:entry.receipt.applied_at
           ~cancellation
           state)
     | Cancel_accepted _, [ _ ] ->
       Error "pending cancellation WAL source conflicts with its receipt"
     | Cancel_accepted _, ([] | _ :: _ :: _) ->
       Error "pending cancellation WAL must carry exactly one source"
     | Transfer_accepted transfer, [ source ] when source = transfer.source ->
       restore_pending_transition entry state (fun state ->
         transfer_pending_accepted
           ~applied_at:entry.receipt.applied_at
           ~transfer
           state)
     | Transfer_accepted _, [ _ ] ->
       Error "pending transfer WAL source conflicts with its receipt"
     | Transfer_accepted _, ([] | _ :: _ :: _) ->
       Error "pending transfer WAL must carry exactly one source"
     | Ack_source_terminal source_terminal, [ source ]
       when source = source_terminal.source ->
       restore_pending_transition entry state (fun state ->
         ack_pending_source_terminal
           ~applied_at:entry.receipt.applied_at
           ~source_terminal
           state)
     | Ack_source_terminal _, [ _ ] ->
       Error "pending source-terminal ACK WAL source conflicts with its receipt"
     | Ack_source_terminal _, ([] | _ :: _ :: _) ->
       Error "pending source-terminal ACK WAL must carry exactly one source"
    ))
;;

let remove_by_post_id post_id state =
  let removed, pending =
    Keeper_event_queue.remove_by_post_id post_id (pending state)
  in
  Keeper_event_queue.uniq_stimuli removed, with_pending pending state
;;
