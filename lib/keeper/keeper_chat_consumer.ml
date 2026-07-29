(** Keeper_chat_consumer — transition-driven per-Keeper queue drain. *)

module Wake_inbox = struct
  type t =
    { mutex : Stdlib.Mutex.t
    ; condition : Eio.Condition.t
    ; pending : (string, unit) Hashtbl.t
    ; fifo : string Queue.t
    }

  let inbox =
    { mutex = Stdlib.Mutex.create ()
    ; condition = Eio.Condition.create ()
    ; pending = Hashtbl.create 16
    ; fifo = Queue.create ()
    }

  let with_lock f =
    Stdlib.Mutex.lock inbox.mutex;
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock inbox.mutex) f

  let notify keeper_name =
    let added =
      with_lock (fun () ->
        if Hashtbl.mem inbox.pending keeper_name
        then false
        else (
          Hashtbl.add inbox.pending keeper_name ();
          Queue.add keeper_name inbox.fifo;
          true))
    in
    if added then Eio.Condition.broadcast inbox.condition

  let take_nonblocking () =
    with_lock (fun () ->
      match Queue.take_opt inbox.fifo with
      | None -> None
      | Some keeper_name ->
        Hashtbl.remove inbox.pending keeper_name;
        Some keeper_name)

  let take () = Eio.Condition.loop_no_mutex inbox.condition take_nonblocking

  let reset () =
    with_lock (fun () ->
      Hashtbl.clear inbox.pending;
      Queue.clear inbox.fifo);
    Eio.Condition.broadcast inbox.condition
end

let notify_transition ~keeper_name = Wake_inbox.notify keeper_name

type turn_outcome =
  | Delivered of { outcome_ref : string }
  | Failed of
      { kind : Keeper_chat_queue.failure_kind
      ; detail : string
      ; outcome_ref : string option
      }
  | Deferred of { rejection : Keeper_turn_admission.rejection }

type claim_outcome =
  | Complete of Keeper_chat_queue.finalization
  | Requeue

type persistence_blocked_operation =
  | Claim_next_blocked
  | Complete_blocked
  | Requeue_blocked

type persistence_blocked_status =
  { operation : persistence_blocked_operation
  ; attempt_id : string option
  ; error : Keeper_chat_queue.mutation_error
  }

type blocked_retry =
  | Retry_claim_next
  | Retry_claim_outcome of
      { attempt_id : string
      ; action : claim_outcome
      }

module Persistence_blocked = struct
  type entry =
    { status : persistence_blocked_status
    ; retry : blocked_retry
    }

  let mutex = Stdlib.Mutex.create ()
  let entries : (string, entry) Hashtbl.t = Hashtbl.create 16

  let with_lock f =
    Stdlib.Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mutex) f

  let key ~base_path ~keeper_name =
    Keeper_registry_types.registry_key ~base_path keeper_name

  let remember ~base_path ~keeper_name entry =
    with_lock (fun () ->
      Hashtbl.replace entries (key ~base_path ~keeper_name) entry)

  let remember_claim ~base_path ~keeper_name entry =
    with_lock (fun () ->
      let key = key ~base_path ~keeper_name in
      match Hashtbl.find_opt entries key with
      | Some { retry = Retry_claim_outcome _; _ } -> ()
      | Some { retry = Retry_claim_next; _ } | None ->
        Hashtbl.replace entries key entry)

  let find ~base_path ~keeper_name =
    with_lock (fun () ->
      Hashtbl.find_opt entries (key ~base_path ~keeper_name))

  let clear ~base_path ~keeper_name =
    with_lock (fun () ->
      Hashtbl.remove entries (key ~base_path ~keeper_name))

  let clear_claim_outcome ~base_path ~keeper_name ~attempt_id =
    with_lock (fun () ->
      let key = key ~base_path ~keeper_name in
      match Hashtbl.find_opt entries key with
      | Some
          { retry = Retry_claim_outcome { attempt_id = pending_attempt_id; _ }; _ }
        when String.equal pending_attempt_id attempt_id ->
        Hashtbl.remove entries key
      | Some _ | None -> ())

  let reset () = with_lock (fun () -> Hashtbl.clear entries)
end

type dispatch_state = {
  base_path : string;
  mutex : Eio.Mutex.t;
  running_by_keeper : (string, unit) Hashtbl.t;
  rerun_by_keeper : (string, unit) Hashtbl.t;
}

type lane_activity =
  | Dispatchable of bool

let create_dispatch_state ~base_path =
  { base_path = Keeper_registry_types.canonical_base_path_exn base_path
  ; mutex = Eio.Mutex.create ()
  ; running_by_keeper = Hashtbl.create 16
  ; rerun_by_keeper = Hashtbl.create 16
  }

let with_dispatch_state state f =
  Eio.Mutex.use_rw ~protect:true state.mutex f

let is_dispatching state keeper_name =
  with_dispatch_state state (fun () ->
      Hashtbl.mem state.running_by_keeper keeper_name)

let mark_dispatching state keeper_name =
  with_dispatch_state state (fun () ->
      if Hashtbl.mem state.running_by_keeper keeper_name
      then (
        Hashtbl.replace state.rerun_by_keeper keeper_name ();
        false)
      else (
        Hashtbl.replace state.running_by_keeper keeper_name ();
        true))

let finish_dispatching state keeper_name =
  Eio.Cancel.protect (fun () ->
      with_dispatch_state state (fun () ->
          Hashtbl.remove state.running_by_keeper keeper_name;
          let rerun = Hashtbl.mem state.rerun_by_keeper keeper_name in
          Hashtbl.remove state.rerun_by_keeper keeper_name;
          rerun))

let clear_dispatching state keeper_name =
  ignore (finish_dispatching state keeper_name : bool)

let finish_dispatching_and_reschedule state keeper_name =
  if finish_dispatching state keeper_name
  then notify_transition ~keeper_name

let pending_claim_outcome state keeper_name =
  match
    Persistence_blocked.find
      ~base_path:state.base_path
      ~keeper_name
  with
  | Some { retry = Retry_claim_outcome { attempt_id; action }; _ } ->
    Some (attempt_id, action)
  | Some { retry = Retry_claim_next; _ } | None -> None

let clear_pending_claim_outcome state ~keeper_name ~attempt_id =
  Persistence_blocked.clear_claim_outcome
    ~base_path:state.base_path
    ~keeper_name
    ~attempt_id

let operation_of_claim_outcome = function
  | Complete _ -> Complete_blocked
  | Requeue -> Requeue_blocked

let remember_pending_claim_outcome state ~keeper_name ~attempt_id ~action ~error =
  Persistence_blocked.remember
    ~base_path:state.base_path
    ~keeper_name
    { status =
        { operation = operation_of_claim_outcome action
        ; attempt_id = Some attempt_id
        ; error
        }
    ; retry = Retry_claim_outcome { attempt_id; action }
    }

let remember_blocked_claim state ~keeper_name ~error =
  Persistence_blocked.remember_claim
    ~base_path:state.base_path
    ~keeper_name
    { status =
        { operation = Claim_next_blocked; attempt_id = None; error }
    ; retry = Retry_claim_next
    }

let clear_blocked_claim state ~keeper_name =
  match
    Persistence_blocked.find
      ~base_path:state.base_path
      ~keeper_name
  with
  | Some { retry = Retry_claim_next; _ } ->
    Persistence_blocked.clear
      ~base_path:state.base_path
      ~keeper_name
  | Some { retry = Retry_claim_outcome _; _ } | None -> ()

let persistence_blocked_status ~base_path ~keeper_name =
  match Config_dir_resolver.canonical_base_path base_path with
  | Error error ->
    Error (Config_dir_resolver.canonical_base_path_error_to_string error)
  | Ok base_path ->
    Ok
      (Persistence_blocked.find ~base_path ~keeper_name
       |> Option.map (fun entry -> entry.Persistence_blocked.status))

module For_testing = struct
  type nonrec dispatch_state = dispatch_state

  let create_dispatch_state = create_dispatch_state
  let is_dispatching = is_dispatching
  let mark_dispatching = mark_dispatching
  let clear_dispatching = clear_dispatching
  let finish_dispatching_and_reschedule = finish_dispatching_and_reschedule
  let notify_transition = notify_transition
  let take_wake_nonblocking = Wake_inbox.take_nonblocking
  let reset_wake_inbox = Wake_inbox.reset
  let reset_persistence_blocked = Persistence_blocked.reset
end

(* A terminal persist failure is recoverable: queue-core keeps the claim
   unchanged. Retain the exact typed decision and retry it before dispatching
   another turn for this Keeper. *)
let invalid_finalization_fallback message =
  let completed_at = Time_compat.now () in
  if Float.is_finite completed_at
  then
    Ok
      (Keeper_chat_queue.Mark_failed
         { completed_at
         ; kind = Keeper_chat_queue.Internal_error
         ; detail =
             Safe_ops.sanitize_text_utf8
               ("queued turn produced an invalid terminal outcome: " ^ message)
         ; outcome_ref = None
         })
  else
    Error
      (Keeper_chat_queue.Invalid_input
         "cannot replace an invalid terminal outcome because the system clock returned a non-finite completion time")

let reconcile_published_transition ~keeper_name error =
  match Keeper_chat_queue.reconcile_persistence ~keeper_name with
  | Ok report ->
    Log.Keeper.info
      "keeper_chat_consumer: reconciled published queue transition keeper=%s revision=%Ld"
      keeper_name
      report.revision
  | Error reconciliation_error ->
    Log.Keeper.error
      "keeper_chat_consumer: published queue transition requires operator reconciliation keeper=%s publication_error=%s reconciliation_error=%s"
      keeper_name
      (Keeper_chat_queue.mutation_error_to_string error)
      (Keeper_chat_queue.mutation_error_to_string reconciliation_error)

let persist_claim_outcome state ~keeper_name ~attempt_id action =
  let result =
    match action with
    | Complete outcome ->
      let rec complete ~allow_invalid_fallback outcome =
        match Keeper_chat_queue.complete_claim ~keeper_name ~attempt_id ~outcome with
        | `Completed _ ->
          clear_pending_claim_outcome state ~keeper_name ~attempt_id;
          `Persisted
        | `Unknown_claim ->
          clear_pending_claim_outcome state ~keeper_name ~attempt_id;
          Log.Keeper.warn
            "keeper_chat_consumer: completion found no matching claim=%s for \
             keeper=%s (already completed/requeued?)"
            attempt_id
            keeper_name;
          `Persisted
        | `Error (Keeper_chat_queue.Invalid_input message)
          when allow_invalid_fallback ->
          (match invalid_finalization_fallback message with
           | Ok fallback ->
             Log.Keeper.error
               "keeper_chat_consumer: rejected invalid terminal outcome for \
                keeper=%s claim=%s: %s; replacing it with a typed internal_error"
               keeper_name attempt_id message;
             complete ~allow_invalid_fallback:false fallback
           | Error error ->
             let retry_action = Complete outcome in
             remember_pending_claim_outcome state ~keeper_name ~attempt_id
               ~action:retry_action ~error;
             Log.Keeper.error
               "keeper_chat_consumer: rejected invalid terminal outcome for \
                keeper=%s claim=%s: %s; typed replacement is unavailable: %s"
               keeper_name attempt_id message
               (Keeper_chat_queue.mutation_error_to_string error);
             `Retry_pending)
        | `Error
            (Keeper_chat_queue.Persist_failed
               { publication = Complete_indeterminate _; _ } as error) ->
          clear_pending_claim_outcome state ~keeper_name ~attempt_id;
          reconcile_published_transition ~keeper_name error;
          `Persisted
        | `Error error ->
          let retry_action = Complete outcome in
          remember_pending_claim_outcome state ~keeper_name ~attempt_id
            ~action:retry_action ~error;
          Log.Keeper.error
            "keeper_chat_consumer: completion persist failed for keeper=%s \
             claim=%s: %s; completion will retry after the next durable \
             transition or automatic persistence reconciliation"
            keeper_name
            attempt_id
            (Keeper_chat_queue.mutation_error_to_string error);
          `Retry_pending
      in
      complete ~allow_invalid_fallback:true outcome
    | Requeue ->
      (match Keeper_chat_queue.requeue_claim ~keeper_name ~attempt_id with
       | `Requeued _ ->
         clear_pending_claim_outcome state ~keeper_name ~attempt_id;
         `Persisted
       | `Unknown_claim ->
         clear_pending_claim_outcome state ~keeper_name ~attempt_id;
         Log.Keeper.warn
           "keeper_chat_consumer: requeue found no matching claim=%s for keeper=%s \
            (already completed/requeued?)"
           attempt_id
           keeper_name;
         `Persisted
       | `Error
           (Keeper_chat_queue.Persist_failed
              { publication = Requeue_indeterminate _; _ } as error) ->
         clear_pending_claim_outcome state ~keeper_name ~attempt_id;
         reconcile_published_transition ~keeper_name error;
         `Persisted
       | `Error error ->
         remember_pending_claim_outcome state ~keeper_name ~attempt_id ~action
           ~error;
         Log.Keeper.error
           "keeper_chat_consumer: requeue persist failed for keeper=%s claim=%s: %s; \
            completion will retry after the next durable transition or \
            automatic persistence reconciliation"
           keeper_name
           attempt_id
           (Keeper_chat_queue.mutation_error_to_string error);
         `Retry_pending)
  in
  result

let complete_claim_or_remember state ~keeper_name ~attempt_id outcome =
  match persist_claim_outcome state ~keeper_name ~attempt_id (Complete outcome) with
  | `Persisted | `Retry_pending -> ()

let requeue_claim_or_remember state ~keeper_name ~attempt_id =
  match persist_claim_outcome state ~keeper_name ~attempt_id Requeue with
  | `Persisted | `Retry_pending -> ()

let interrupt_claim_or_remember state ~keeper_name ~attempt_id =
  complete_claim_or_remember state ~keeper_name ~attempt_id
    (Keeper_chat_queue.Mark_failed
       { completed_at = Time_compat.now ()
       ; kind = Keeper_chat_queue.Interrupted
       ; detail =
           "Keeper stopped before this claim completed; its external effect is unknown."
       ; outcome_ref = None
       })

(* A later wake cannot start a new turn while an earlier claim outcome is not
   durably known. *)
let retry_pending_claim_outcome state ~keeper_name =
  match pending_claim_outcome state keeper_name with
  | None -> false
  | Some (attempt_id, action) ->
    (match persist_claim_outcome state ~keeper_name ~attempt_id action with
    | `Persisted | `Retry_pending -> ());
    true

let canonical_turn_ref_string value =
  if not (String.is_valid_utf_8 value) then None
  else
    match Ids.Turn_ref.of_string value with
    | Some turn_ref
      when String.equal (Ids.Turn_ref.to_string turn_ref) value ->
      Some value
    | Some _ | None -> None

let canonical_optional_outcome_ref = function
  | None -> None, false
  | Some value ->
    (match canonical_turn_ref_string value with
     | Some value -> Some value, false
     | None -> None, true)

let canonical_failure_detail detail =
  let detail = Safe_ops.sanitize_text_utf8 detail |> String.trim in
  if String.equal detail ""
  then "queued turn failed without diagnostic detail"
  else detail

let finalization_of_delivered ~clock ~outcome_ref =
  match canonical_turn_ref_string outcome_ref with
  | Some outcome_ref ->
    Keeper_chat_queue.Mark_delivered
      { completed_at = Eio.Time.now clock; outcome_ref = Some outcome_ref }
  | None ->
    Keeper_chat_queue.Mark_failed
      { completed_at = Eio.Time.now clock
      ; kind = Keeper_chat_queue.Internal_error
      ; detail = "queued turn claimed delivery with an invalid turn_ref"
      ; outcome_ref = None
      }

let finalization_of_failed ~clock ~kind ~detail ~outcome_ref =
  let outcome_ref, invalid_outcome_ref =
    canonical_optional_outcome_ref outcome_ref
  in
  let detail = canonical_failure_detail detail in
  let detail =
    if invalid_outcome_ref
    then detail ^ "; invalid turn_ref omitted from terminal correlation"
    else detail
  in
  Keeper_chat_queue.Mark_failed
    { completed_at = Eio.Time.now clock; kind; detail; outcome_ref }

let log_deferred_turn ~keeper_name
    ({ Keeper_turn_admission.waiting
     ; in_flight
     ; shutdown_operation_id
     } : Keeper_turn_admission.rejection) =
  match shutdown_operation_id with
  | Some operation_id ->
      Log.Keeper.info
        "keeper_chat_consumer: admission fenced for keeper=%s by shutdown=%s; \
         returning the claimed receipt to Pending"
        keeper_name
        (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | None ->
      Log.Keeper.info
        "keeper_chat_consumer: admission deferred for keeper=%s waiting=%d \
         in_flight=%b; returning the claimed receipt to Pending"
        keeper_name waiting (Option.is_some in_flight)

let run_claimed_turn state ~sw ~clock ~handle_turn ~keeper_name ~attempt_id
    ~delivery_key ~queued =
  match handle_turn ~sw ~keeper_name ~delivery_key ~queued_message:queued with
  | Deferred { rejection } ->
      log_deferred_turn ~keeper_name rejection;
      requeue_claim_or_remember state ~keeper_name ~attempt_id
  | Delivered { outcome_ref } ->
      complete_claim_or_remember state ~keeper_name ~attempt_id
        (finalization_of_delivered ~clock ~outcome_ref)
  | Failed { kind; detail; outcome_ref } ->
      complete_claim_or_remember state ~keeper_name ~attempt_id
        (finalization_of_failed ~clock ~kind ~detail ~outcome_ref)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
      let detail = Printexc.to_string exn in
      Log.Keeper.error
        "keeper_chat_consumer: handle_turn raised for keeper=%s: %s; recording \
         a terminal internal_error receipt"
        keeper_name detail;
      complete_claim_or_remember state ~keeper_name ~attempt_id
        (Keeper_chat_queue.Mark_failed
           { completed_at = Eio.Time.now clock
           ; kind = Keeper_chat_queue.Internal_error
           ; detail
           ; outcome_ref = None
           })

let dispatch_queued_turn state ~sw ~clock ~handle_turn ~keeper_name ~attempt_id
    ~delivery_key ~queued =
  Eio.Fiber.fork ~sw (fun () ->
      try
        Eio.Switch.run (fun claim_sw ->
          run_claimed_turn state ~sw:claim_sw ~clock ~handle_turn ~keeper_name
            ~attempt_id ~delivery_key ~queued);
        finish_dispatching_and_reschedule state keeper_name
      with
      | Eio.Cancel.Cancelled _ as e ->
          Eio.Cancel.protect (fun () ->
              interrupt_claim_or_remember state ~keeper_name ~attempt_id);
          finish_dispatching_and_reschedule state keeper_name;
          raise e
      | exn ->
          interrupt_claim_or_remember state ~keeper_name ~attempt_id;
          finish_dispatching_and_reschedule state keeper_name;
          Log.Keeper.error
            "keeper_chat_consumer: dispatch finalization failed unexpectedly \
             for keeper=%s: %s"
            keeper_name
            (Printexc.to_string exn))

let run ~sw ~clock ~base_path ~handle_turn =
  let dispatch_state = create_dispatch_state ~base_path in
  let release keeper_name =
    finish_dispatching_and_reschedule dispatch_state keeper_name
  in
  let unavailable error =
    Error (Keeper_chat_queue.Snapshot_unavailable error)
  in
  let ready_lane_activity keeper_name =
    match Keeper_chat_queue.lane_status ~keeper_name with
    | Error _ as error -> error
    | Ok { health = Keeper_chat_queue.Ready; has_active; _ } ->
      Ok (Dispatchable has_active)
    | Ok { health = Keeper_chat_queue.Unavailable error; _ } ->
      unavailable error
    | Ok
        { revision = uncertain_revision
        ; health = Keeper_chat_queue.Persistence_reconciliation_required
        ; _
        } ->
      (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
       | Error _ as error -> error
       | Ok report ->
         Log.Keeper.info
           "keeper_chat_consumer: reconciled lane keeper=%s uncertain_revision=%Ld durable_revision=%Ld"
           keeper_name
           uncertain_revision
           report.revision;
         (match Keeper_chat_queue.lane_status ~keeper_name with
          | Error _ as error -> error
          | Ok { health = Keeper_chat_queue.Ready; has_active; _ } ->
            Ok (Dispatchable has_active)
          | Ok { health = Keeper_chat_queue.Unavailable error; _ } ->
            unavailable error
          | Ok
              { revision
              ; health = Keeper_chat_queue.Persistence_reconciliation_required
              ; _
              } ->
            unavailable
              { kind = Keeper_chat_queue.Reconciliation_failed
              ; path = None
              ; message =
                  Printf.sprintf
                    "lane still requires reconciliation after a successful reconciliation report at revision %Ld"
                    revision
              }))
  in
  let dispatch_claim keeper_name
      ({ Keeper_chat_queue.receipt_id; attempt_id; message = queued } :
        Keeper_chat_queue.claim) =
      let delivery_key =
        [ receipt_id ]
        |> Keeper_chat_delivery_identity.Receipt_ids.of_list
        |> Result.map (fun receipt_ids ->
          Keeper_chat_delivery_identity.Queue_receipts receipt_ids)
        |> Result.map_error
             Keeper_chat_delivery_identity.Receipt_ids.error_to_string
      in
      let admission =
        Keeper_turn_admission.snapshot_for ~base_path ~keeper_name
      in
      (match
         admission.snapshot_in_flight,
         admission.snapshot_shutdown_operation_id
       with
       | Some _, _ | _, Some _ ->
         requeue_claim_or_remember dispatch_state ~keeper_name ~attempt_id;
         release keeper_name
       | None, None ->
         (match delivery_key with
          | Error detail ->
            complete_claim_or_remember dispatch_state ~keeper_name ~attempt_id
              (Keeper_chat_queue.Mark_failed
                 { completed_at = Eio.Time.now clock
                 ; kind = Keeper_chat_queue.Internal_error
                 ; detail
                 ; outcome_ref = None
                 });
            release keeper_name
          | Ok delivery_key ->
            (try
               dispatch_queued_turn dispatch_state ~sw ~clock ~handle_turn
                 ~keeper_name ~attempt_id ~delivery_key ~queued
             with
             | Eio.Cancel.Cancelled _ as exception_ ->
               Eio.Cancel.protect (fun () ->
                   interrupt_claim_or_remember dispatch_state ~keeper_name ~attempt_id);
               release keeper_name;
               raise exception_
             | exception_ ->
               interrupt_claim_or_remember dispatch_state ~keeper_name ~attempt_id;
               release keeper_name;
               Log.Keeper.warn
                 "keeper_chat_consumer: dispatch fork failed for keeper=%s: %s"
                 keeper_name
                 (Printexc.to_string exception_))))
  in
  let inspect_keeper keeper_name =
    try
      match ready_lane_activity keeper_name with
      | Error error ->
        remember_blocked_claim dispatch_state ~keeper_name ~error;
        Log.Keeper.error
          "keeper_chat_consumer: lane state unavailable keeper=%s error=%s; lane is persistence_blocked until automatic persistence reconciliation or another durable transition"
          keeper_name
          (Keeper_chat_queue.mutation_error_to_string error);
        release keeper_name
      | Ok _ when retry_pending_claim_outcome dispatch_state ~keeper_name ->
        release keeper_name
      | Ok (Dispatchable false) ->
        clear_blocked_claim dispatch_state ~keeper_name;
        release keeper_name
      | Ok (Dispatchable true) ->
        clear_blocked_claim dispatch_state ~keeper_name;
        let admission =
          Keeper_turn_admission.snapshot_for ~base_path ~keeper_name
        in
        (match
           admission.snapshot_in_flight,
           admission.snapshot_shutdown_operation_id
         with
         | Some _, _ | _, Some _ -> release keeper_name
         | None, None ->
           (match Keeper_chat_queue.claim_next ~keeper_name with
            | `Empty -> release keeper_name
            | `Already_claimed _ -> release keeper_name
            | `Error
                (Keeper_chat_queue.Persist_failed
                   { publication = Claim_indeterminate _; _ } as error)
            | `Error
                (Keeper_chat_queue.Snapshot_unavailable
                   { kind = Durability_uncertain; _ } as error) ->
              reconcile_published_transition ~keeper_name error;
              release keeper_name
            | `Error error ->
              remember_blocked_claim dispatch_state ~keeper_name ~error;
              Log.Keeper.warn
                "keeper_chat_consumer: claim_next failed for keeper=%s: %s; lane is persistence_blocked until automatic persistence reconciliation or another durable transition"
                keeper_name
                (Keeper_chat_queue.mutation_error_to_string error);
              release keeper_name
            | `Claimed claim -> dispatch_claim keeper_name claim))
    with
    | Eio.Cancel.Cancelled _ as exception_ ->
      release keeper_name;
      raise exception_
    | exception_ ->
      release keeper_name;
      Log.Keeper.error
        "keeper_chat_consumer: isolated Keeper lane inspection failed keeper=%s error=%s"
        keeper_name
        (Printexc.to_string exception_)
  in
  let spawn_keeper keeper_name =
    if mark_dispatching dispatch_state keeper_name
    then
      try Eio.Fiber.fork ~sw (fun () -> inspect_keeper keeper_name) with
      | Eio.Cancel.Cancelled _ as exception_ ->
        release keeper_name;
        raise exception_
      | exception_ ->
        release keeper_name;
        Log.Keeper.error
          "keeper_chat_consumer: failed to start isolated Keeper lane keeper=%s error=%s"
          keeper_name
          (Printexc.to_string exception_)
  in
  let initial_keeper_names = Keeper_chat_queue.all_keeper_names () in
  List.iter (fun keeper_name -> notify_transition ~keeper_name) initial_keeper_names;
  let rec wake_loop () =
    let keeper_name = Wake_inbox.take () in
    spawn_keeper keeper_name;
    Eio.Fiber.yield ();
    wake_loop ()
  in
  wake_loop ()
