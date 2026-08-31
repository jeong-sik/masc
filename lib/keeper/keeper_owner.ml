let mailbox_capacity = 128

let state_change_observer : (unit -> unit) Atomic.t = Atomic.make ignore
let install_state_change_observer observer = Atomic.set state_change_observer observer

let notify_state_change_observer ~keeper_name =
  try (Atomic.get state_change_observer) () with
  | exn ->
    Log.Keeper.warn
      "keeper Owner state-change observer failed keeper=%s: %s"
      keeper_name
      (Printexc.to_string exn)
;;

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

module Chat_operation = Keeper_chat_operation
module Chat_operation_store = Keeper_chat_operation_store
module Operation_id = Chat_operation.Operation_id

type operation_projection =
  { queued_count : int
  ; running_operation_id : Operation_id.t option
  ; terminal_count : int
  ; interrupted_count : int
  ; store_unavailable : bool
  }

type turn_lane =
  | Autonomous
  | Chat_operation
  | Maintenance

type turn_in_flight =
  { lane : turn_lane
  ; started_at : float
  }

type autonomous_block =
  | Turn_busy of turn_in_flight option
  | Shutdown_requested of Keeper_shutdown_types.Operation_id.t

type shutdown_reservation =
  { operation_id : Keeper_shutdown_types.Operation_id.t
  ; in_flight : turn_in_flight option
  }

type begin_shutdown_result =
  | Shutdown_reserved of shutdown_reservation
  | Shutdown_already_reserved of shutdown_reservation

type rollback_shutdown_result =
  | Shutdown_rolled_back
  | Shutdown_not_reserved
  | Shutdown_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type restore_shutdown_result =
  | Shutdown_restored
  | Shutdown_already_restored
  | Shutdown_restore_conflict of Keeper_shutdown_types.Operation_id.t

type transition_shutdown_result =
  | Shutdown_transition_applied
  | Shutdown_transition_already_applied
  | Shutdown_transition_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type operation_acceptance =
  { operation : Chat_operation.t
  ; existing : bool
  ; queued_count : int
  }

type operation_error_kind =
  | Invalid_operation_input
  | Unknown_operation
  | Operation_not_queued
  | Operation_idempotency_conflict
  | Operation_store_unavailable

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Operation_rejected of Chat_operation_store.error
  | Store_unavailable of string
  | Owner_stopping
  | Owner_closed

type operation_execution =
  | Operation_succeeded of { outcome_ref : string }
  | Operation_failed of
      { kind : Chat_operation.failure_kind
      ; detail : string
      ; outcome_ref : string option
      }

type operation_executor =
  sw:Eio.Switch.t ->
  keeper_name:string ->
  claim:(unit -> (Chat_operation.t option, error) result) ->
  operation_execution

type operation_runner =
  { ready : keeper_name:string -> bool
  ; execute : operation_executor
  ; on_execution_settled :
      keeper_name:string ->
      claimed_operation_id:Chat_operation.Operation_id.t option ->
      execution:operation_execution ->
      unit
  }

type 'a autonomous_response =
  | Autonomous_ran of 'a
  | Autonomous_busy of autonomous_block
  | Autonomous_raised of exn * Printexc.raw_backtrace

type child_completion =
  | Operation_child_finished of
      { claimed_operation_id : Operation_id.t option
      ; execution : operation_execution
      }
  | Autonomous_child_finished :
      { outcome : ('a, exn * Printexc.raw_backtrace) result
      ; resolve : ('a autonomous_response, error) result Eio.Promise.u
      }
      -> child_completion

type _ command =
  | Exact_projection :
      (Keeper_owner_reducer.projection, error) result command
  | Apply_meta :
      Keeper_owner_reducer.meta_command
      -> (Keeper_meta_contract.keeper_meta option, error) result command
  | Exact_operation :
      Operation_id.t -> (Chat_operation.t option, error) result command
  | Submit_operation :
      { operation_id : Operation_id.t
      ; source : Yojson.Safe.t
      ; input : Yojson.Safe.t
      }
      -> (operation_acceptance, error) result command
  | List_queued_operations :
      { after_sequence : int64 option
      ; limit : int
      }
      -> (Chat_operation.t list, error) result command
  | Edit_queued_operation :
      { operation_id : Operation_id.t
      ; input : Yojson.Safe.t
      }
      -> (Chat_operation.t, error) result command
  | Move_queued_operation_to_end :
      Operation_id.t -> (Chat_operation.t, error) result command
  | Cancel_queued_operation :
      Operation_id.t -> (Chat_operation.t, error) result command
  | Claim_next_operation : (Chat_operation.t option, error) result command
  | Succeed_running_operation :
      { operation_id : Operation_id.t
      ; outcome_ref : string
      }
      -> (Chat_operation.t, error) result command
  | Fail_running_operation :
      { operation_id : Operation_id.t
      ; kind : Chat_operation.failure_kind
      ; detail : string
      ; outcome_ref : string option
      }
      -> (Chat_operation.t, error) result command
  | Wake_operation_drain : (unit, error) result command
  | Run_if_idle :
      { lane : turn_lane
      ; run : unit -> 'a
      }
      -> ('a autonomous_response, error) result command
  | Begin_shutdown :
      { operation_id : Keeper_shutdown_types.Operation_id.t }
      -> (begin_shutdown_result, error) result command
  | Rollback_shutdown :
      { operation_id : Keeper_shutdown_types.Operation_id.t }
      -> (rollback_shutdown_result, error) result command
  | Restore_shutdown :
      { operation_id : Keeper_shutdown_types.Operation_id.t }
      -> (restore_shutdown_result, error) result command
  | Transition_shutdown :
      { from_operation_id : Keeper_shutdown_types.Operation_id.t
      ; to_operation_id : Keeper_shutdown_types.Operation_id.t option
      }
      -> (transition_shutdown_result, error) result command
  | Await_idle_after_shutdown : (unit, error) result command
  | Child_finished : child_completion -> (unit, error) result command
  | Begin_stopping : (unit, error) result command

type packed_command =
  | Command : 'response command * 'response Eio.Promise.u -> packed_command

(* Declared in Keeper_owner_signals so the runtime adapters can match it
   without depending on this module; see #28012. *)
exception Stop_active_child = Keeper_owner_signals.Stop_active_child

type t =
  { keeper_name : string
  ; mailbox : packed_command Eio.Stream.t
  ; projection : Keeper_owner_reducer.projection Atomic.t
  ; operation_projection : operation_projection Atomic.t
  ; turn_in_flight : turn_in_flight option Atomic.t
  ; shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option Atomic.t
  ; mutable operation_store : Chat_operation_store.t
  ; now : unit -> float
  ; closed : bool Atomic.t
  ; closed_p : unit Eio.Promise.t
  ; store_error : string option ref
  ; child_active : bool ref
  ; child_cancel : (unit -> unit) option Atomic.t
  ; stopping_waiters : ((unit, error) result Eio.Promise.u) list ref
  ; shutdown_idle_waiters : ((unit, error) result Eio.Promise.u) list ref
  ; on_turn_slot_released : (unit -> unit) option
  ; autonomous_lost_slot : bool ref
        (* Set when the autonomous lane asked for the slot and was refused,
           cleared when the release notification is delivered. Without it the
           notification fires after every turn, and since a woken keeper starts
           its next turn immediately, each turn's end schedules the next one:
           the keepalive cadence stops governing and turn rate rises to one per
           turn duration. Only a lane that actually lost the slot needs telling
           that it is free. Owner-fiber-local; every reader and writer below
           runs in the command loop. *)
  }

let error_to_string = function
  | Reducer_rejected error -> Keeper_owner_reducer.error_to_string error
  | Operation_rejected error -> Chat_operation_store.error_to_string error
  | Store_unavailable detail -> "keeper owner store unavailable: " ^ detail
  | Owner_stopping -> "keeper owner is stopping"
  | Owner_closed -> "keeper owner is closed"
;;

let operation_error_kind = function
  | Chat_operation_store.Invalid_input _ -> Invalid_operation_input
  | Unknown_operation _ -> Unknown_operation
  | Not_queued _ | Not_running _ -> Operation_not_queued
  | Idempotency_conflict _ -> Operation_idempotency_conflict
  | Store_unavailable _ | Integrity_error _ -> Operation_store_unavailable
;;

let projection t = Atomic.get t.projection
let operation_projection t = Atomic.get t.operation_projection
let turn_in_flight t = Atomic.get t.turn_in_flight
let shutdown_operation_id t = Atomic.get t.shutdown_operation_id

let operation_projection_equal
      (left : operation_projection)
      (right : operation_projection)
  =
  Int.equal left.queued_count right.queued_count
  && Option.equal Operation_id.equal left.running_operation_id right.running_operation_id
  && Int.equal left.terminal_count right.terminal_count
  && Int.equal left.interrupted_count right.interrupted_count
  && Bool.equal left.store_unavailable right.store_unavailable
;;

let turn_in_flight_equal (left : turn_in_flight option) (right : turn_in_flight option) =
  match left, right with
  | None, None -> true
  | Some left, Some right ->
    left.lane = right.lane && Float.equal left.started_at right.started_at
  | None, Some _ | Some _, None -> false
;;

let shutdown_operation_id_equal =
  Option.equal Keeper_shutdown_types.Operation_id.equal
;;

let publish_operation_projection t next =
  let previous = Atomic.get t.operation_projection in
  if not (operation_projection_equal previous next)
  then (
    Atomic.set t.operation_projection next;
    notify_state_change_observer ~keeper_name:t.keeper_name)
;;

let publish_turn_in_flight t next =
  let previous = Atomic.get t.turn_in_flight in
  if not (turn_in_flight_equal previous next)
  then (
    Atomic.set t.turn_in_flight next;
    notify_state_change_observer ~keeper_name:t.keeper_name)
;;

let publish_shutdown_operation_id t next =
  let previous = Atomic.get t.shutdown_operation_id in
  if not (shutdown_operation_id_equal previous next)
  then (
    Atomic.set t.shutdown_operation_id next;
    notify_state_change_observer ~keeper_name:t.keeper_name)
;;

(* The freed slot is offered to a queued chat operation first (the caller runs
   [start_child_if_needed] immediately before this). Notifying only when it is
   still unclaimed makes the signal mean "a turn can start now" rather than "a
   turn ended": a listener woken by the latter would find the slot taken and
   defer again, which is the cycle this notification exists to end.

   The callback runs on the Owner fiber, so an exception from it would take
   down the actor that every producer depends on. Contain it; a lost wake
   degrades to the listener's own cadence, which is the behaviour before this
   notification existed. *)
let notify_turn_slot_released t =
  match t.on_turn_slot_released with
  | None -> ()
  | Some notify ->
    if Option.is_none (Atomic.get t.turn_in_flight) && !(t.autonomous_lost_slot)
    then (
      t.autonomous_lost_slot := false;
      try notify () with
      | exn ->
        Log.Keeper.routine
          ~keeper_name:t.keeper_name
          "turn slot release listener raised: %s"
          (Printexc.to_string exn))
;;

let turn_lane_to_string = function
  | Autonomous -> "autonomous"
  | Chat_operation -> "chat_operation"
  | Maintenance -> "maintenance"
;;

let autonomous_block_kind = function
  | Turn_busy _ -> "turn_busy"
  | Shutdown_requested _ -> "shutdown_requested"
;;

let autonomous_block_to_string = function
  | Turn_busy None -> "reason=turn_busy holder=unpublished"
  | Turn_busy (Some { lane; started_at }) ->
    Printf.sprintf
      "reason=turn_busy holder_lane=%s holder_started_at=%.17g"
      (turn_lane_to_string lane)
      started_at
  | Shutdown_requested operation_id ->
    Printf.sprintf
      "reason=shutdown_requested operation_id=%s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
;;

let autonomous_block_to_yojson = function
  | Turn_busy in_flight ->
    let holder =
      match in_flight with
      | None -> `Null
      | Some { lane; started_at } ->
        `Assoc
          [ "lane", `String (turn_lane_to_string lane)
          ; "started_at", `Float started_at
          ]
    in
    `Assoc [ "kind", `String "turn_busy"; "holder", holder ]
  | Shutdown_requested operation_id ->
    `Assoc
      [ "kind", `String "shutdown_requested"
      ; ( "operation_id"
        , `String (Keeper_shutdown_types.Operation_id.to_string operation_id) )
      ]
;;

let request t command =
  if Atomic.get t.closed
  then Error Owner_closed
  else (
    let response, resolve = Eio.Promise.create () in
    match
      Eio.Fiber.first
        (fun () ->
           Eio.Stream.add t.mailbox (Command (command, resolve));
           `Enqueued)
        (fun () ->
           Eio.Promise.await t.closed_p;
           `Closed)
    with
    | `Closed -> Error Owner_closed
    | `Enqueued ->
      Eio.Cancel.protect (fun () ->
        Eio.Fiber.first
          (fun () -> Eio.Promise.await response)
          (fun () ->
             Eio.Promise.await t.closed_p;
             Error Owner_closed)))
;;

let commit store transition =
  match transition.Keeper_owner_reducer.persistence with
  | Keeper_owner_reducer.No_persistence -> Ok transition.state
  | Replace_snapshot meta ->
    (match store.replace meta with
     | Ok () -> Ok transition.state
     | Error detail -> Error (Store_unavailable detail))
  | Remove_snapshot meta ->
    (match store.remove meta with
     | Ok () -> Ok transition.state
     | Error detail -> Error (Store_unavailable detail))
;;

let apply_transition t store old_state transition =
  match commit store transition with
  | Error (Store_unavailable detail as error) ->
    t.store_error := Some detail;
    Error (old_state, error)
  | Error
      (Reducer_rejected _ | Operation_rejected _ | Owner_stopping | Owner_closed as error) ->
    Error (old_state, error)
  | Ok state ->
    Atomic.set t.projection transition.projection;
    Ok state
;;

let owner_error_of_operation_error = function
  | Chat_operation_store.Store_unavailable detail -> Store_unavailable detail
  | Integrity_error detail ->
    Store_unavailable ("Keeper chat operation integrity failure: " ^ detail)
  | (Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
    | Idempotency_conflict _) as error ->
    Operation_rejected error
;;

let run_operation_store ~label f =
  try Eio_unix.run_in_systhread ~label f with
  (* [run_in_systhread] awaits — a cancellation point. Folding Cancelled
     into [Store_unavailable] misreported keeper cancellation as a store
     outage and let the owner continue past its own cancellation. *)
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error
      (Chat_operation_store.Store_unavailable
         (Printf.sprintf "%s raised: %s" label (Printexc.to_string exn)))
;;

let operation_projection_of_inventory inventory =
  { queued_count = inventory.Chat_operation_store.queued_count
  ; running_operation_id = inventory.running_operation_id
  ; terminal_count = inventory.terminal_count
  ; interrupted_count = inventory.interrupted_count
  ; store_unavailable = false
  }
;;

let read_operation_inventory operation_store =
  run_operation_store ~label:"keeper chat operation inventory" (fun () ->
    Chat_operation_store.inventory operation_store)
  |> Result.map_error owner_error_of_operation_error
;;

let reopen_operation_store_if_missing t =
  let path = Chat_operation_store.path t.operation_store in
  let path_exists =
    run_operation_store ~label:"probe Keeper chat operation store path" (fun () ->
      Ok (Sys.file_exists path))
  in
  match path_exists with
  | Error error -> Error (owner_error_of_operation_error error)
  | Ok true -> Ok ()
  | Ok false ->
    let prepare_parent =
      run_operation_store ~label:"recreate Keeper chat operation store parent" (fun () ->
        let parent = Filename.dirname path in
        (try Unix.mkdir parent 0o755 with
         | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        if Sys.is_directory parent
        then Ok ()
        else
          Error
            (Chat_operation_store.Store_unavailable
               (Printf.sprintf
                  "Keeper chat operation store parent is not a directory: %s"
                  parent)))
    in
    (match prepare_parent with
     | Error error -> Error (owner_error_of_operation_error error)
     | Ok () ->
       (match
          run_operation_store ~label:"close purged Keeper chat operation store" (fun () ->
            Chat_operation_store.close t.operation_store)
        with
        | Error error -> Error (owner_error_of_operation_error error)
        | Ok () ->
          (match
             run_operation_store ~label:"reopen purged Keeper chat operation store" (fun () ->
               Chat_operation_store.open_or_create ~path)
           with
           | Error error -> Error (owner_error_of_operation_error error)
           | Ok operation_store ->
             (match read_operation_inventory operation_store with
              | Error error ->
                ignore (Chat_operation_store.close operation_store : (unit, _) result);
                Error error
              | Ok inventory ->
                t.operation_store <- operation_store;
                t.store_error := None;
                Atomic.set
                  t.operation_projection
                  (operation_projection_of_inventory inventory);
                Ok ()))))
;;

let mark_operation_store_unavailable t =
  let projection = Atomic.get t.operation_projection in
  publish_operation_projection t { projection with store_unavailable = true }
;;

let run_operation_command t ~label f =
  match !(t.store_error) with
  | Some detail -> Error (Store_unavailable detail)
  | None ->
    (match
       run_operation_store ~label f
       |> Result.map_error owner_error_of_operation_error
     with
     | Error (Store_unavailable detail as error) ->
       t.store_error := Some detail;
       mark_operation_store_unavailable t;
       Error error
     | Error _ as error -> error
     | Ok value ->
       (match read_operation_inventory t.operation_store with
        | Error (Store_unavailable detail as error) ->
          t.store_error := Some detail;
          mark_operation_store_unavailable t;
          Error error
        | Error _ as error -> error
        | Ok inventory ->
          let projection = operation_projection_of_inventory inventory in
          publish_operation_projection t projection;
          Keeper_waiting_inventory_broadcast.changed
            ~keeper_name:t.keeper_name
            ~source:Keeper_waiting_inventory_broadcast.Chat_operation;
          Ok (value, projection)))
;;

let run_operation_read t ~label f =
  match
    run_operation_store ~label f
    |> Result.map_error owner_error_of_operation_error
  with
  | Error (Store_unavailable detail as error) ->
    t.store_error := Some detail;
    mark_operation_store_unavailable t;
    Error error
  | (Error _ | Ok _) as result -> result
;;

let reject_if_stopping state f =
  if (Keeper_owner_reducer.projection state).stopping then Error Owner_stopping else f ()
;;

let turn_admission_open state =
  match (Keeper_owner_reducer.projection state).meta with
  | Some meta -> not meta.Keeper_meta_contract.paused
  | None -> false
;;

let reject_if_shutdown shutdown_operation_id f =
  match shutdown_operation_id with
  | Some _ -> Error Owner_stopping
  | None -> f ()
;;

let shutdown_reservation t operation_id =
  { operation_id; in_flight = Atomic.get t.turn_in_flight }
;;

let start
      ~sw
      ~store
      ~operation_store_path
      ~now
      ~operation_runner
      ~on_turn_slot_released
      ~keeper_name
      ~initial_meta
  =
  match Keeper_owner_reducer.create ~keeper_name initial_meta with
  | Error error -> Error (Reducer_rejected error)
  | Ok initial_state ->
  let operation_store_result =
    run_operation_store ~label:"open Keeper chat operation store" (fun () ->
      Chat_operation_store.open_or_create ~path:operation_store_path)
    |> Result.map_error owner_error_of_operation_error
  in
  (match operation_store_result with
   | Error _ as error -> error
   | Ok operation_store ->
  let startup_result =
    let startup_now = now () in
    match
      run_operation_store ~label:"settle Keeper chat operations after restart" (fun () ->
        Chat_operation_store.settle_running_after_restart operation_store ~now:startup_now)
      |> Result.map_error owner_error_of_operation_error
    with
    | Error _ as error -> error
    | Ok settled ->
      (* [interrupted_count] in the inventory is cumulative, so it cannot answer
         "did this restart cut anything off". That is the question asked right
         after a bad swap, and the number is only available here. *)
      if settled > 0
      then
        Log.Keeper.routine
          ~keeper_name
          "restart interrupted %d running chat operation(s)"
          settled;
      read_operation_inventory operation_store
  in
  (match startup_result with
   | Error _ as error ->
     (* See startup failure path: preserve the original error; close is best-effort. *)
     ignore (Chat_operation_store.close operation_store : (unit, _) result);
     error
   | Ok initial_operation_inventory ->
  let closed_p, resolve_closed = Eio.Promise.create () in
  let t =
    { keeper_name
    ; mailbox = Eio.Stream.create mailbox_capacity
    ; projection = Atomic.make (Keeper_owner_reducer.projection initial_state)
    ; operation_projection =
        Atomic.make (operation_projection_of_inventory initial_operation_inventory)
    ; turn_in_flight = Atomic.make None
    ; shutdown_operation_id = Atomic.make None
    ; operation_store
    ; now
    ; closed = Atomic.make false
    ; closed_p
    ; store_error = ref None
    ; child_active = ref false
    ; child_cancel = Atomic.make None
    ; autonomous_lost_slot = ref false
    ; stopping_waiters = ref []
    ; shutdown_idle_waiters = ref []
    ; on_turn_slot_released
    }
  in
  Eio.Switch.on_release sw (fun () ->
    Atomic.set t.closed true;
    Eio.Promise.resolve resolve_closed ();
    let projection = Atomic.get t.projection in
    Atomic.set t.projection { projection with stopping = true };
    match Chat_operation_store.close operation_store with
    | Ok () -> ()
    | Error error ->
      Log.Keeper.error
        "keeper_owner: operation store close failed keeper=%s error=%s"
        keeper_name
        (Chat_operation_store.error_to_string error));
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let finish_operation_child claimed_operation_id execution =
      match claimed_operation_id, execution with
      | None, _ -> Ok ()
      | Some operation_id, Operation_succeeded { outcome_ref } ->
        run_operation_command t ~label:"succeed running Keeper chat operation" (fun () ->
          Chat_operation_store.succeed_running
            t.operation_store
            ~now:(t.now ())
            ~operation_id
            ~outcome_ref)
        |> Result.map (fun _ -> ())
      | Some operation_id, Operation_failed { kind; detail; outcome_ref } ->
        run_operation_command t ~label:"fail running Keeper chat operation" (fun () ->
          Chat_operation_store.fail_running
            t.operation_store
            ~now:(t.now ())
            ~operation_id
            ~kind
            ~detail
            ~outcome_ref)
        |> Result.map (fun _ -> ())
    in
    let rec start_child_if_needed state shutdown_operation_id =
      match operation_runner with
      | None -> ()
      | Some _ when !(t.child_active) -> ()
      | Some _ when Option.is_some shutdown_operation_id -> ()
      | Some _ when (Keeper_owner_reducer.projection state).stopping -> ()
      | Some _ when not (turn_admission_open state) -> ()
      | Some _ when Option.is_some !(t.store_error) -> ()
      | Some runner when not (runner.ready ~keeper_name:t.keeper_name) -> ()
      | Some runner ->
        let inventory = Atomic.get t.operation_projection in
        if inventory.queued_count > 0 && Option.is_none inventory.running_operation_id
        then (
          t.child_active := true;
          publish_turn_in_flight
            t
            (Some { lane = Chat_operation; started_at = t.now () });
          Eio.Fiber.fork ~sw (fun () ->
            let claimed_operation_id = ref None in
            let claim () =
              match request t Claim_next_operation with
              | Ok (Some operation) as result ->
                claimed_operation_id := Some operation.Chat_operation.operation_id;
                result
              | (Ok None | Error _) as result -> result
            in
            let execution =
              try
                Eio.Switch.run (fun child_sw ->
                  Atomic.set
                    t.child_cancel
                    (Some (fun () -> Eio.Switch.fail child_sw Stop_active_child));
                  if (Atomic.get t.projection).Keeper_owner_reducer.stopping
                  then
                    Operation_failed
                      { kind = Chat_operation.Turn_cancelled
                      ; detail = "Keeper owner is stopping"
                      ; outcome_ref = None
                      }
                  else runner.execute ~sw:child_sw ~keeper_name ~claim)
              with
              | Stop_active_child ->
                Operation_failed
                  { kind = Chat_operation.Turn_cancelled
                  ; detail = "Keeper owner stopped the active turn"
                  ; outcome_ref = None
                  }
              | exn when Keeper_registry_types.is_operator_interrupt exn ->
                (* Typed operator cancellation (#28810): the interrupt route
                   fails the turn switch with this exception. The guard
                   covers every delivery shape — bare, [Cancelled]-wrapped,
                   and [Finally_raised]/[Multiple] combinations
                   (#28868 review). None of them is an internal error. *)
                Operation_failed
                  { kind = Chat_operation.Turn_cancelled
                  ; detail = Keeper_registry_types.operator_interrupt_detail
                  ; outcome_ref = None
                  }
              | Eio.Cancel.Cancelled cause ->
                Operation_failed
                  { kind = Chat_operation.Turn_cancelled
                  ; detail = Printexc.to_string cause
                  ; outcome_ref = None
                  }
              | exn ->
                Operation_failed
                  { kind = Chat_operation.Turn_exception
                  ; detail = Printexc.to_string exn
                  ; outcome_ref = None
                  }
            in
            Atomic.set t.child_cancel None;
            (* Hook-before-durable-settle gives observers a happens-before: a
               durably Failed/Succeeded operation implies its wire synthesis
               already ran (the stopping test relies on this ordering).
               Cancellation of the owner switch inside the hook skips the
               Child_finished commit below exactly as it always could during
               [request]; [settle_running_after_restart] clears that window
               on the next boot. *)
            (try
               runner.on_execution_settled
                 ~keeper_name:t.keeper_name
                 ~claimed_operation_id:!claimed_operation_id
                 ~execution
             with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
               Log.Keeper.error "operation settle hook raised for %s: %s"
                 t.keeper_name (Printexc.to_string exn));
            ignore
              (request
                 t
                 (Child_finished
                    (Operation_child_finished
                       { claimed_operation_id = !claimed_operation_id; execution })))
          ))
    and loop state shutdown_operation_id =
        match Eio.Stream.take t.mailbox with
        | Command (Exact_projection, resolve) ->
          Eio.Promise.resolve resolve (Ok (Keeper_owner_reducer.projection state));
          loop state shutdown_operation_id
        | Command (Apply_meta command, resolve) ->
          let operation_store_ready =
            match command, (Keeper_owner_reducer.projection state).meta with
            | Keeper_owner_reducer.Create _, None ->
              reopen_operation_store_if_missing t
            | _ -> Ok ()
          in
          (match operation_store_ready with
           | Error error ->
             Eio.Promise.resolve resolve (Error error);
             loop state shutdown_operation_id
           | Ok () ->
          (match !(t.store_error) with
           | Some detail ->
             Eio.Promise.resolve resolve (Error (Store_unavailable detail));
             loop state shutdown_operation_id
           | None ->
             (match Keeper_owner_reducer.apply_meta state command with
              | Error error ->
                Eio.Promise.resolve resolve (Error (Reducer_rejected error));
                loop state shutdown_operation_id
              | Ok transition ->
                (match apply_transition t store state transition with
                 | Error (state, error) ->
                   Eio.Promise.resolve resolve (Error error);
                   loop state shutdown_operation_id
                 | Ok state ->
                   Eio.Promise.resolve
                     resolve
                   (Ok (Keeper_owner_reducer.projection state).meta);
                   start_child_if_needed state shutdown_operation_id;
                   loop state shutdown_operation_id))))
        | Command (Exact_operation operation_id, resolve) ->
          let response =
            run_operation_read t ~label:"lookup Keeper chat operation" (fun () ->
              Chat_operation_store.get t.operation_store operation_id)
          in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Submit_operation { operation_id; source; input }, resolve) ->
          let response =
            reject_if_shutdown shutdown_operation_id (fun () ->
              reject_if_stopping state (fun () ->
                match
                  run_operation_command t ~label:"submit Keeper chat operation" (fun () ->
                    Chat_operation_store.submit
                      t.operation_store
                      ~now:(t.now ())
                      ~operation_id
                      ~source
                      ~input)
                with
                | Error _ as error -> error
                | Ok (admission, projection) ->
                  let operation, existing =
                    match admission with
                    | Chat_operation_store.Accepted operation -> operation, false
                    | Existing operation -> operation, true
                  in
                  Ok { operation; existing; queued_count = projection.queued_count }))
          in
          Eio.Promise.resolve resolve response;
          start_child_if_needed state shutdown_operation_id;
          loop state shutdown_operation_id
        | Command (List_queued_operations { after_sequence; limit }, resolve) ->
          let response =
            run_operation_read t ~label:"list queued Keeper chat operations" (fun () ->
              Chat_operation_store.list_queued
                t.operation_store
                ~after_sequence
                ~limit)
          in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Edit_queued_operation { operation_id; input }, resolve) ->
          let response =
            reject_if_stopping state (fun () ->
              run_operation_command t ~label:"edit queued Keeper chat operation" (fun () ->
                Chat_operation_store.edit_queued
                  t.operation_store
                  ~operation_id
                  ~input)
              |> Result.map fst)
          in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Move_queued_operation_to_end operation_id, resolve) ->
          let response =
            reject_if_stopping state (fun () ->
              run_operation_command
                t
                ~label:"move queued Keeper chat operation to end"
                (fun () ->
                   Chat_operation_store.move_queued_to_end
                     t.operation_store
                     ~operation_id)
              |> Result.map fst)
          in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Cancel_queued_operation operation_id, resolve) ->
          let response =
            reject_if_stopping state (fun () ->
              run_operation_command t ~label:"cancel queued Keeper chat operation" (fun () ->
                Chat_operation_store.cancel_queued
                  t.operation_store
                  ~now:(t.now ())
                  ~operation_id)
              |> Result.map fst)
          in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Claim_next_operation, resolve) ->
          let response =
            reject_if_shutdown shutdown_operation_id (fun () ->
              reject_if_stopping state (fun () ->
                if not (turn_admission_open state)
                then Ok None
                else
                  run_operation_command
                    t
                    ~label:"claim next Keeper chat operation"
                    (fun () ->
                       Chat_operation_store.claim_next
                         t.operation_store
                         ~now:(t.now ()))
                  |> Result.map fst))
          in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Succeed_running_operation { operation_id; outcome_ref }, resolve) ->
          let response =
            run_operation_command t ~label:"succeed running Keeper chat operation" (fun () ->
              Chat_operation_store.succeed_running
                t.operation_store
                ~now:(t.now ())
                ~operation_id
                ~outcome_ref)
            |> Result.map fst
          in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command
            ( Fail_running_operation
                { operation_id; kind; detail; outcome_ref }
            , resolve ) ->
          let response =
            run_operation_command t ~label:"fail running Keeper chat operation" (fun () ->
              Chat_operation_store.fail_running
                t.operation_store
                ~now:(t.now ())
                ~operation_id
                ~kind
                ~detail
                ~outcome_ref)
            |> Result.map fst
          in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Wake_operation_drain, resolve) ->
          Eio.Promise.resolve resolve (Ok ());
          start_child_if_needed state shutdown_operation_id;
          loop state shutdown_operation_id
        | Command (Begin_shutdown { operation_id }, resolve) ->
          (match shutdown_operation_id with
           | None ->
             publish_shutdown_operation_id t (Some operation_id);
             Eio.Promise.resolve
               resolve
               (Ok (Shutdown_reserved (shutdown_reservation t operation_id)));
             loop state (Some operation_id)
           | Some existing ->
             Eio.Promise.resolve
               resolve
               (Ok
                  (Shutdown_already_reserved
                     (shutdown_reservation t existing)));
             loop state shutdown_operation_id)
        | Command (Rollback_shutdown { operation_id }, resolve) ->
          (match shutdown_operation_id with
           | None ->
             Eio.Promise.resolve resolve (Ok Shutdown_not_reserved);
             loop state shutdown_operation_id
           | Some existing
             when Keeper_shutdown_types.Operation_id.equal existing operation_id ->
             publish_shutdown_operation_id t None;
             Eio.Promise.resolve resolve (Ok Shutdown_rolled_back);
             start_child_if_needed state None;
             loop state None
           | Some existing ->
             Eio.Promise.resolve resolve (Ok (Shutdown_reserved_by_other existing));
             loop state shutdown_operation_id)
        | Command (Restore_shutdown { operation_id }, resolve) ->
          (match shutdown_operation_id with
           | None ->
             publish_shutdown_operation_id t (Some operation_id);
             Eio.Promise.resolve resolve (Ok Shutdown_restored);
             loop state (Some operation_id)
           | Some existing
             when Keeper_shutdown_types.Operation_id.equal existing operation_id ->
             Eio.Promise.resolve resolve (Ok Shutdown_already_restored);
             loop state shutdown_operation_id
           | Some existing ->
             Eio.Promise.resolve resolve (Ok (Shutdown_restore_conflict existing));
             loop state shutdown_operation_id)
        | Command
            ( Transition_shutdown { from_operation_id; to_operation_id }
            , resolve ) ->
          let result, next_shutdown_operation_id =
            match shutdown_operation_id, to_operation_id with
            | Some existing, _
              when Keeper_shutdown_types.Operation_id.equal
                     existing
                     from_operation_id ->
              Shutdown_transition_applied, to_operation_id
            | None, None -> Shutdown_transition_already_applied, None
            | Some existing, Some successor
              when Keeper_shutdown_types.Operation_id.equal existing successor ->
              Shutdown_transition_already_applied, shutdown_operation_id
            | None, Some successor -> Shutdown_transition_applied, Some successor
            | Some existing, _ ->
              Shutdown_transition_reserved_by_other existing, shutdown_operation_id
          in
          publish_shutdown_operation_id t next_shutdown_operation_id;
          Eio.Promise.resolve resolve (Ok result);
          if Option.is_none next_shutdown_operation_id
          then start_child_if_needed state None;
          loop state next_shutdown_operation_id
        | Command (Await_idle_after_shutdown, resolve) ->
          if !(t.child_active)
          then (
            t.shutdown_idle_waiters := resolve :: !(t.shutdown_idle_waiters);
            loop state shutdown_operation_id)
          else (
            Eio.Promise.resolve resolve (Ok ());
            loop state shutdown_operation_id)
        | Command (Run_if_idle { lane; run }, resolve) ->
          (match shutdown_operation_id with
           | Some operation_id ->
             Eio.Promise.resolve
               resolve
               (Ok (Autonomous_busy (Shutdown_requested operation_id)))
           | None ->
             (match reject_if_stopping state (fun () -> Ok ()) with
              | Error error -> Eio.Promise.resolve resolve (Error error)
              | Ok () ->
                (match Atomic.get t.turn_in_flight with
                 | Some in_flight ->
                   (match lane with
                    | Autonomous -> t.autonomous_lost_slot := true
                    | Chat_operation | Maintenance -> ());
                   Eio.Promise.resolve
                     resolve
                     (Ok (Autonomous_busy (Turn_busy (Some in_flight))))
                 | None ->
                   t.child_active := true;
                   publish_turn_in_flight
                     t
                     (Some { lane; started_at = t.now () });
                   Eio.Fiber.fork ~sw (fun () ->
                     let outcome =
                       try
                         Ok
                           (Eio.Switch.run (fun child_sw ->
                              Atomic.set
                                t.child_cancel
                                (Some
                                   (fun () -> Eio.Switch.fail child_sw Stop_active_child));
                              run ()))
                       with
                       | exn -> Error (exn, Printexc.get_raw_backtrace ())
                     in
                     Atomic.set t.child_cancel None;
                     ignore
                       (request
                          t
                          (Child_finished
                             (Autonomous_child_finished { outcome; resolve })))))));
          loop state shutdown_operation_id
        | Command (Child_finished completion, resolve) ->
          let result =
            match completion with
            | Operation_child_finished { claimed_operation_id; execution } ->
              finish_operation_child claimed_operation_id execution
            | Autonomous_child_finished { outcome; resolve = autonomous_resolve } ->
              let response =
                match outcome with
                | Ok value -> Ok (Autonomous_ran value)
                | Error (exn, backtrace) -> Ok (Autonomous_raised (exn, backtrace))
              in
              Eio.Promise.resolve autonomous_resolve response;
              Ok ()
          in
          t.child_active := false;
          publish_turn_in_flight t None;
          Eio.Promise.resolve resolve result;
          let stopping_waiters = List.rev !(t.stopping_waiters) in
          t.stopping_waiters := [];
          List.iter (fun waiter -> Eio.Promise.resolve waiter result) stopping_waiters;
          let shutdown_idle_waiters = List.rev !(t.shutdown_idle_waiters) in
          t.shutdown_idle_waiters := [];
          List.iter
            (fun waiter -> Eio.Promise.resolve waiter result)
            shutdown_idle_waiters;
          start_child_if_needed state shutdown_operation_id;
          notify_turn_slot_released t;
          loop state shutdown_operation_id
        | Command (Begin_stopping, resolve) ->
          let transition = Keeper_owner_reducer.begin_stopping state in
          (match apply_transition t store state transition with
           | Error (state, error) ->
             Eio.Promise.resolve resolve (Error error);
             loop state shutdown_operation_id
           | Ok state ->
             if !(t.child_active)
             then (
               t.stopping_waiters := resolve :: !(t.stopping_waiters);
               Option.iter
                 (fun cancel ->
                    try cancel () with
                    | Invalid_argument _ -> ())
                 (Atomic.get t.child_cancel))
             else Eio.Promise.resolve resolve (Ok ());
             loop state shutdown_operation_id)
    in
    start_child_if_needed initial_state None;
    loop initial_state None);
  Ok t))
;;

let exact_projection t = request t Exact_projection
let apply_meta t command = request t (Apply_meta command)
let exact_operation t operation_id = request t (Exact_operation operation_id)
let wake_operation_drain t = request t Wake_operation_drain

let submit_operation t ~operation_id ~source ~input =
  request t (Submit_operation { operation_id; source; input })
;;

let list_queued_operations t ~after_sequence ~limit =
  request t (List_queued_operations { after_sequence; limit })
;;

let edit_queued_operation t ~operation_id ~input =
  request t (Edit_queued_operation { operation_id; input })
;;

let move_queued_operation_to_end t operation_id =
  request t (Move_queued_operation_to_end operation_id)
;;

let cancel_queued_operation t operation_id = request t (Cancel_queued_operation operation_id)
let claim_next_operation t = request t Claim_next_operation

let succeed_running_operation t ~operation_id ~outcome_ref =
  request t (Succeed_running_operation { operation_id; outcome_ref })
;;

let run_if_idle t lane run =
  match request t (Run_if_idle { lane; run }) with
  | Error _ as error -> error
  | Ok (Autonomous_ran value) -> Ok (`Ran value)
  | Ok (Autonomous_busy block) -> Ok (`Busy block)
  | Ok (Autonomous_raised (Stop_active_child, _)) -> Error Owner_stopping
  | Ok (Autonomous_raised (exn, backtrace)) ->
    Printexc.raise_with_backtrace exn backtrace
;;

let run_autonomous_if_idle t run = run_if_idle t Autonomous run
let run_maintenance_if_idle t run = run_if_idle t Maintenance run

let begin_shutdown t ~operation_id = request t (Begin_shutdown { operation_id })
let rollback_shutdown t ~operation_id = request t (Rollback_shutdown { operation_id })
let restore_shutdown t ~operation_id = request t (Restore_shutdown { operation_id })

let transition_shutdown t ~from_operation_id ~to_operation_id =
  request t (Transition_shutdown { from_operation_id; to_operation_id })
;;

let await_idle_after_shutdown t = request t Await_idle_after_shutdown

let begin_stopping t = request t Begin_stopping

module For_testing = struct
  let mailbox_depth t = Eio.Stream.length t.mailbox
end
