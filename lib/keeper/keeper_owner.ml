let mailbox_capacity = 128

let state_change_observer : (unit -> unit) Atomic.t = Atomic.make ignore
let install_state_change_observer observer = Atomic.set state_change_observer observer

let notify_state_change_observer ~keeper_name =
  Cancel_safe.observe
    ~on_exn:(fun exn ->
      Log.Keeper.warn
        "keeper Owner state-change observer failed keeper=%s: %s"
        keeper_name
        (Printexc.to_string exn))
    (fun () -> (Atomic.get state_change_observer) ())
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
  ; has_claimable_queued : bool
  ; next_runtime_retry_wake : float option
  ; running_operation_id : Operation_id.t option
  ; terminal_count : int
  ; interrupted_count : int
  ; store_unavailable : bool
  }

type operation_interrupt_result =
  | Operation_interrupt_signalled
  | Operation_not_current of
      { running_operation_id : Operation_id.t option }
  | Operation_settling
  | Operation_maintenance_running
  | Operation_interrupt_failed of string

type pause_result = Interrupt_result of operation_interrupt_result | Pending_admission_paused

type interrupt_target =
  | Observed_turn of { interrupt_token : Keeper_interrupt_token.t }
  | Direct_operation of Chat_operation.Operation_id.t

type run_next_result =
  | Run_next_paused
  | Run_next_applied of { signalled : bool; interrupt_error : string option }

type interactive_outcome = Applied | Stale_control | Paused | Replayed
type interactive_receipt =
  { outcome : interactive_outcome; chat_control_token : string
  ; signalled : bool; resumed : bool; interrupt_error : string option }
type interactive_intent = { control_token : string; target : interrupt_target option }

type turn_lane =
  | Autonomous
  | Chat_operation
  | Maintenance

type turn_in_flight =
  { lane : turn_lane
  ; started_at : float
  ; interrupt_token : Keeper_interrupt_token.t
  }

type autonomous_block =
  | Turn_busy of turn_in_flight option
  | Admission_paused
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
  | Operation_deferred
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
  | Direct_checkpoint : Operation_id.t ->
      (Keeper_semantic_execution.gate_checkpoint option, error) result command
  | Defer_direct_checkpoint :
      { operation_id : Operation_id.t; execution_digest : string;
        checkpoint : Keeper_semantic_execution.gate_checkpoint } ->
      (Chat_operation.t, error) result command
  | Resume_direct_checkpoint :
      { operation_id : Operation_id.t; observed : Keeper_semantic_execution.gate_checkpoint } ->
      (unit, error) result command
  | Direct_runtime_retry : Operation_id.t ->
      (Keeper_semantic_execution.runtime_retry option, error) result command
  | Defer_direct_runtime_retry :
      { operation_id : Operation_id.t; execution_digest : string;
        continuation : Keeper_semantic_execution.runtime_retry } ->
      (Chat_operation.t, error) result command
  | Resume_direct_runtime_retry :
      { operation_id : Operation_id.t; observed : Keeper_semantic_execution.runtime_retry } ->
      (unit, error) result command
  | Direct_gate_bindings : ((Operation_id.t * Keeper_semantic_execution.gate_binding) list, error) result command
  | Reconcile_direct_gate_binding : {operation_id:Operation_id.t; binding:Keeper_semantic_execution.gate_binding;
      waiting:Keeper_semantic_execution.gate_wait} -> (unit, error) result command
  | Direct_gate_waits : ((Operation_id.t * Keeper_semantic_execution.gate_wait_state) list, error) result command
  | Discharge_direct_gate : {operation_id:Operation_id.t; obligation:Keeper_semantic_execution.gate_obligation} -> (unit, error) result command
  | Direct_gate_state : Operation_id.t -> (Keeper_semantic_execution.gate_wait_state option, error) result command
  | Direct_gate_binding : Operation_id.t -> (Keeper_semantic_execution.gate_binding option, error) result command
  | Direct_gate_obligations : Operation_id.t -> (Keeper_semantic_execution.gate_obligation list, error) result command
  | Defer_direct_gate_reconciliation : {operation_id:Operation_id.t; execution_digest:string;
      binding:Keeper_semantic_execution.gate_binding; diagnostic:string} -> (Chat_operation.t, error) result command
  | Defer_direct_gate : {operation_id:Operation_id.t; execution_digest:string;
      waiting:Keeper_semantic_execution.gate_wait} -> (Chat_operation.t, error) result command
  | Resolve_direct_gate : {operation_id:Operation_id.t; resolution:Keeper_semantic_execution.gate_resolution} ->
      (Chat_operation.t, error) result command
  | Resume_direct_gate : {operation_id:Operation_id.t; waiting:Keeper_semantic_execution.gate_wait;
      resolution:Keeper_semantic_execution.gate_resolution} -> (unit, error) result command
  | Pause_and_interrupt : {target : interrupt_target; expected_control_token : string option} -> (pause_result * string, error) result command
  | Run_next_operation : { operation_id : Operation_id.t; observed : interrupt_target option } ->
      (run_next_result, error) result command
  | Interrupt_running_operation :
      Operation_id.t -> (operation_interrupt_result, error) result command
  | Submit_operation :
      { operation_id : Operation_id.t
      ; source : Yojson.Safe.t
      ; input : Yojson.Safe.t
      }
      -> (operation_acceptance, error) result command
  | Submit_interactive_operation :
      { operation_id : Operation_id.t; source : Yojson.Safe.t; input : Yojson.Safe.t
      ; intent : interactive_intent }
      -> (operation_acceptance * interactive_receipt, error) result command
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
  | Move_queued_operation_to_front :
      Operation_id.t -> (Chat_operation.t, error) result command
  | Move_queued_operation_to_end :
      Operation_id.t -> (Chat_operation.t, error) result command
  | Cancel_queued_operation :
      Operation_id.t -> (Chat_operation.t, error) result command
  | Batch_operations : Chat_operation.Operation_id.t -> (Chat_operation.t list, error) result command
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

type child_cancel =
  { stop : unit -> unit
  ; interrupt : unit -> unit
  }

(* What a stop finds when it names the slot's occupant. *)
type interrupt_resolution =
  | Interrupt_now of (unit -> unit)
  | Interrupt_settling
  | Interrupt_maintenance_running
  | Interrupt_not_current

(* The metadata snapshot store and the chat operation store fail on their own
   terms and recover on their own terms, so each keeps its own fault slot.
   One shared slot coupled a chat-store outage to metadata commits: an
   operation fault refused the keeper's own pause and turn-runtime writes even
   though the metadata store was healthy (msx-retro-mania, 2026-09-14, #36203).
   A metadata persistence failure needs a process restart or an operator; it
   does not clear on a wake. *)
type metadata_fault = Metadata_persistence_failure of string

(* Why the Owner refuses operation-store work. Only
   [Operation_availability_failure] is retried: a stale SQLite handle heals by
   close+reopen at an idle wake. The other two need a process restart or an
   operator, so a wake must not churn the handle for them. *)
type operation_fault =
  | Operation_availability_failure of string
  | Operation_integrity_failure of string
  | Operation_reconciliation_required of Chat_operation.Operation_id.t
      (* A durable Running row with no live child: its terminal commit was
         lost to the outage. [settle_running_after_restart] settles it on
         the next boot; this process never fabricates an outcome. *)

let metadata_fault_detail (Metadata_persistence_failure detail) = detail

(* The integrity prefix matches [owner_error_of_operation_error], so the
   first refusal and every later one read the same. *)
let operation_fault_detail = function
  | Operation_availability_failure detail -> detail
  | Operation_integrity_failure detail ->
    "Keeper chat operation integrity failure: " ^ detail
  | Operation_reconciliation_required operation_id ->
    Printf.sprintf
      "operation %s is Running with no live child; restart the keeper to settle it before storage recovery"
      (Chat_operation.Operation_id.to_string operation_id)

let retain_operation_fault fault previous =
  match previous with
  | Some (Operation_integrity_failure _
         | Operation_reconciliation_required _) -> previous
  | None | Some (Operation_availability_failure _) -> Some fault

type t =
  { keeper_name : string
  ; mailbox : packed_command Eio.Stream.t
  ; projection : Keeper_owner_reducer.projection Atomic.t
  ; chat_control_token : string Atomic.t
  ; operation_projection : operation_projection Atomic.t
  ; turn_in_flight : turn_in_flight option Atomic.t
  ; shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option Atomic.t
  ; mutable operation_store : Chat_operation_store.t
  ; now : unit -> float
  ; closed : bool Atomic.t
  ; closed_p : unit Eio.Promise.t
  ; metadata_error : metadata_fault option ref
  ; operation_error : operation_fault option ref
  ; child_active : bool ref
  ; child_cancel : child_cancel option Atomic.t
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
  ; restart_interrupted : Chat_operation.t list
        (* The running operations this start settled as
           [Interrupted_by_restart], for the caller that owns the transcript
           to leave a failure row per request. Fixed at start; a later
           restart is a later owner. *)
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
let chat_control_token t = Atomic.get t.chat_control_token
let operation_projection t = Atomic.get t.operation_projection
let turn_in_flight t = Atomic.get t.turn_in_flight
let shutdown_operation_id t = Atomic.get t.shutdown_operation_id

let operation_projection_equal
      (left : operation_projection)
      (right : operation_projection)
  =
  Int.equal left.queued_count right.queued_count
  && Bool.equal left.has_claimable_queued right.has_claimable_queued
  && Option.equal Float.equal left.next_runtime_retry_wake right.next_runtime_retry_wake
  && Option.equal Operation_id.equal left.running_operation_id right.running_operation_id
  && Int.equal left.terminal_count right.terminal_count
  && Int.equal left.interrupted_count right.interrupted_count
  && Bool.equal left.store_unavailable right.store_unavailable
;;

let turn_in_flight_equal (left : turn_in_flight option) (right : turn_in_flight option) =
  match left, right with
  | None, None -> true
  | Some left, Some right ->
    left.lane = right.lane
    && Float.equal left.started_at right.started_at
    && Keeper_interrupt_token.equal left.interrupt_token right.interrupt_token
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
      Cancel_safe.observe
        ~on_exn:(fun exn ->
          Log.Keeper.routine
            ~keeper_name:t.keeper_name
            "turn slot release listener raised: %s"
            (Printexc.to_string exn))
        notify)
;;

let turn_lane_to_string = function
  | Autonomous -> "autonomous"
  | Chat_operation -> "chat_operation"
  | Maintenance -> "maintenance"
;;

let autonomous_block_kind = function
  | Admission_paused -> "admission_paused"
  | Turn_busy _ -> "turn_busy"
  | Shutdown_requested _ -> "shutdown_requested"
;;

let autonomous_block_to_string = function
  | Admission_paused -> "reason=admission_paused"
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
  | Admission_paused -> `Assoc ["kind", `String "admission_paused"]
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

(* A command the mailbox took as the owner closed is enqueued: the owner
   has it, so its caller waits for the answer instead of being told the owner
   refused it. *)
let enqueue_unless_closed mailbox command ~closed =
  Watched_work.run
    (fun () ->
       Eio.Stream.add mailbox command;
       `Enqueued)
    ~watcher:(fun () ->
       Eio.Promise.await closed;
       `Closed)
;;

(* When the owner answers a command it has taken.

   [In_its_drain_step]: the step that takes the command decides it, commits
   whatever it changes and answers before taking the next one. Nothing in that
   step waits on a child.

   [Possibly_when_the_child_finishes]: the step may park the resolver until the
   running child finishes. [Await_idle_after_shutdown] and [Begin_stopping] wait
   for an active child; [Run_if_idle] answers with the turn it admitted, when
   that turn ends. *)
type answer =
  | In_its_drain_step
  | Possibly_when_the_child_finishes

let answer : type response. response command -> answer = function
  | Exact_projection -> In_its_drain_step
  | Apply_meta _ -> In_its_drain_step
  | Exact_operation _ -> In_its_drain_step
  | Direct_checkpoint _ -> In_its_drain_step
  | Defer_direct_checkpoint _ -> In_its_drain_step
  | Resume_direct_checkpoint _ -> In_its_drain_step
  | Direct_runtime_retry _ -> In_its_drain_step
  | Defer_direct_runtime_retry _ -> In_its_drain_step
  | Resume_direct_runtime_retry _ -> In_its_drain_step
  | Direct_gate_bindings -> In_its_drain_step
  | Reconcile_direct_gate_binding _ -> In_its_drain_step
  | Direct_gate_waits -> In_its_drain_step
  | Discharge_direct_gate _ -> In_its_drain_step
  | Direct_gate_state _ -> In_its_drain_step
  | Direct_gate_binding _ -> In_its_drain_step
  | Direct_gate_obligations _ -> In_its_drain_step
  | Defer_direct_gate_reconciliation _ -> In_its_drain_step
  | Defer_direct_gate _ -> In_its_drain_step
  | Resolve_direct_gate _ -> In_its_drain_step
  | Resume_direct_gate _ -> In_its_drain_step
  | Pause_and_interrupt _ -> In_its_drain_step
  | Run_next_operation _ -> In_its_drain_step
  | Interrupt_running_operation _ -> In_its_drain_step
  | Submit_operation _ -> In_its_drain_step
  | Submit_interactive_operation _ -> In_its_drain_step
  | List_queued_operations _ -> In_its_drain_step
  | Edit_queued_operation _ -> In_its_drain_step
  | Move_queued_operation_to_front _ -> In_its_drain_step
  | Move_queued_operation_to_end _ -> In_its_drain_step
  | Cancel_queued_operation _ -> In_its_drain_step
  | Batch_operations _ -> In_its_drain_step
  | Claim_next_operation -> In_its_drain_step
  | Succeed_running_operation _ -> In_its_drain_step
  | Fail_running_operation _ -> In_its_drain_step
  | Wake_operation_drain -> In_its_drain_step
  | Run_if_idle _ -> Possibly_when_the_child_finishes
  | Begin_shutdown _ -> In_its_drain_step
  | Rollback_shutdown _ -> In_its_drain_step
  | Restore_shutdown _ -> In_its_drain_step
  | Transition_shutdown _ -> In_its_drain_step
  | Await_idle_after_shutdown -> Possibly_when_the_child_finishes
  | Child_finished _ -> In_its_drain_step
  | Begin_stopping -> Possibly_when_the_child_finishes
;;

let request t command =
  let ask () =
    if Atomic.get t.closed
    then Error Owner_closed
    else (
      let response, resolve = Eio.Promise.create () in
      match
        enqueue_unless_closed t.mailbox (Command (command, resolve)) ~closed:t.closed_p
      with
      | `Closed -> Error Owner_closed
      | `Enqueued ->
        (* A response that arrived as the owner closed is the answer: the
           command ran, and its caller must not be told the owner was closed
           to it. [Fiber.first] kept whichever wake-up was queued first, and a
           closing owner queues its close ahead of the response it settled in
           the same pass. *)
        Watched_work.run
          (fun () -> Eio.Promise.await response)
          ~watcher:(fun () ->
             Eio.Promise.await t.closed_p;
             Error Owner_closed))
  in
  match answer command with
  | In_its_drain_step ->
    (* A cancelled caller stays until the owner has answered. Callers change
       the owner inside an authority they release on return:
       [Keeper_owner_registry.apply_meta] holds the keeper's lifecycle key lock
       and reservation across its write. Leaving early would release them while
       the write is still queued, and it would commit after another holder took
       them. A claim's answer is also the only record of which row the child
       took.

       The handover is inside the protected region too. [enqueue_unless_closed]
       races the add against the owner's close with [Fiber.first], and
       [Fiber.first] raises its caller's cancellation even when the add has
       already returned (eio 1.3 fiber.ml [any_gen]: [(OK _ | New), Some ex]).
       Protecting only the wait left that return as a window: the owner took
       the command and ran it while its caller left. Every release build for
       0.35.18 hit it.

       Both waits end when the owner drains or closes, and a drain step never
       waits on a child. A cancelled caller blocked on a full mailbox therefore
       waits for room, and its command then runs. *)
    Eio.Cancel.protect ask
  | Possibly_when_the_child_finishes ->
    (* A cancelled caller leaves. The answer may wait for the child, and the
       caller can be that child: a turn asking [Await_idle_after_shutdown]
       waits for its own end. Under a protected wait an operator interrupt
       could not unwind it, so the slot was never released. None of these
       callers holds an authority across the wait. A command already handed
       over still runs after its caller left. *)
    ask ()
;;

(* Hand a command over without reading the answer.

   The settle path needs this. A child that an interrupt just cancelled still
   has to tell the owner it finished, and its [Child_finished] answer is
   discarded anyway; asking for that answer would have to survive the child's
   own cancellation. Only the handover is protected here, and the mailbox
   drains continuously, so the protected region ends with the owner's next
   take rather than with its answer. *)
let notify t command =
  if not (Atomic.get t.closed)
  then (
    let _, resolve = Eio.Promise.create () in
    Eio.Cancel.protect (fun () ->
      match
        enqueue_unless_closed t.mailbox (Command (command, resolve)) ~closed:t.closed_p
      with
      | `Enqueued | `Closed -> ()))
;;

(* The first fault is otherwise visible only as [store_unavailable = true] in
   the projection; the detail resurfaces later as a rejected meta commit and
   reads as if that commit were the cause. Log the onset once, at the source. *)
let set_metadata_fault t detail =
  match !(t.metadata_error) with
  | Some _ -> () (* Sticky until restart; the first detail is the cause. *)
  | None ->
    t.metadata_error := Some (Metadata_persistence_failure detail);
    Log.Keeper.error ~keeper_name:t.keeper_name
      "keeper Owner metadata store fenced: %s" detail
;;

let set_operation_fault t fault =
  let previous = !(t.operation_error) in
  let next = retain_operation_fault fault previous in
  t.operation_error := next;
  match previous, next with
  | None, Some fault ->
    Log.Keeper.error ~keeper_name:t.keeper_name
      "keeper Owner operation store fenced: %s" (operation_fault_detail fault)
  | Some before, Some after
    when operation_fault_detail before <> operation_fault_detail after ->
    Log.Keeper.error ~keeper_name:t.keeper_name
      "keeper Owner operation store fault replaced: %s" (operation_fault_detail after)
  | Some _, Some _ | None, None | Some _, None -> ()
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
    set_metadata_fault t detail;
    Error (old_state, error)
  | Error
      (Reducer_rejected _ | Operation_rejected _ | Owner_stopping | Owner_closed as error) ->
    Error (old_state, error)
  | Ok state ->
    let before = (Keeper_owner_reducer.projection old_state).meta in
    let pause_identity = Option.map (fun (meta : Keeper_meta_contract.keeper_meta) -> meta.paused, meta.latched_reason) in
    if pause_identity before <> pause_identity transition.projection.meta then
      Atomic.set t.chat_control_token (Random_id.uuid_v7 ());
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

let operation_projection_of_inventory ~has_claimable_queued ~next_runtime_retry_wake inventory =
  { queued_count = inventory.Chat_operation_store.queued_count
  ; has_claimable_queued
  ; next_runtime_retry_wake
  ; running_operation_id = inventory.running_operation_id
  ; terminal_count = inventory.terminal_count
  ; interrupted_count = inventory.interrupted_count
  ; store_unavailable = false
  }
;;

let read_operation_projection operation_store ~now =
  run_operation_store ~label:"keeper chat operation projection" (fun () ->
    let ( let* ) = Result.bind in
    let* inventory = Chat_operation_store.inventory operation_store in
    let* has_claimable_queued =
      if inventory.Chat_operation_store.queued_count = 0 then Ok false
      else Chat_operation_store.has_claimable_queued operation_store ~now
    in
    (* Read eligibility and its next time transition using the same instant.
       If the deadline passes before the sleeper is armed, the cached deadline
       still schedules an immediate wake instead of disappearing from a scan. *)
    let* next_runtime_retry_wake =
      Chat_operation_store.next_runtime_retry_wake operation_store ~now
    in
    Ok (operation_projection_of_inventory
          ~has_claimable_queued ~next_runtime_retry_wake inventory))
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
             (match read_operation_projection operation_store ~now:(t.now ())
                     |> Result.map_error owner_error_of_operation_error with
              | Error error ->
                ignore (Chat_operation_store.close operation_store : (unit, _) result);
                Error error
              | Ok projection ->
                t.operation_store <- operation_store;
                t.operation_error := None;
                Atomic.set t.operation_projection projection;
                Ok ()))))
;;

let mark_operation_store_unavailable t =
  let projection = Atomic.get t.operation_projection in
  publish_operation_projection t { projection with store_unavailable = true }
;;

let record_operation_error t error =
  (match error with
   | Chat_operation_store.Store_unavailable detail ->
     set_operation_fault t (Operation_availability_failure detail);
     mark_operation_store_unavailable t
   | Chat_operation_store.Integrity_error detail ->
     set_operation_fault t (Operation_integrity_failure detail);
     mark_operation_store_unavailable t
   | Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
   | Idempotency_conflict _ -> ());
  owner_error_of_operation_error error
;;

(* Only a Chat_operation child claims operation rows and can leave a Running
   row mid-settlement; an Autonomous or Maintenance turn reaches the operation
   store only through this Owner fiber, which reopens serially. The reopen
   guard is therefore the chat lane, not "any child in flight": fencing
   recovery behind every lane is what kept msx-retro-mania fenced for 25
   minutes while its autonomous turn ran without pause (2026-09-14, #36203). *)
let chat_child_in_flight t =
  match Atomic.get t.turn_in_flight with
  | Some { lane = Chat_operation; _ } -> true
  | Some { lane = Autonomous | Maintenance; _ } | None -> false
;;

let recover_operation_availability t =
  match !(t.operation_error) with
  | None -> Ok ()
  | Some (Operation_integrity_failure _
         | Operation_reconciliation_required _ as fault) ->
    Error (Store_unavailable (operation_fault_detail fault))
  | Some (Operation_availability_failure detail) when chat_child_in_flight t ->
    Error (Store_unavailable detail)
  | Some (Operation_availability_failure _) ->
    (* The Owner mailbox excludes all store commands here, and no Chat_operation
       child holds the handle (an Autonomous or Maintenance turn reaches the
       store only through this fiber). Reopening is not permission to replay a
       command: only authoritative queued/terminal rows determine the next
       action. *)
    let recovered = run_operation_store ~label:"recover Keeper operation store" (fun () ->
      let ( let* ) = Result.bind in
      let path = Chat_operation_store.path t.operation_store in
      let* () = Chat_operation_store.close t.operation_store in
      Chat_operation_store.open_existing ~path)
    in
    (match recovered with
     | Error error -> Error (record_operation_error t error)
     | Ok operation_store ->
       t.operation_store <- operation_store;
       (match read_operation_projection operation_store ~now:(t.now ()) with
        | Error error -> Error (record_operation_error t error)
        | Ok projection ->
          (match projection.running_operation_id with
           | Some operation_id ->
             (* Only a Chat_operation child creates a Running row, and this
                branch runs when none is in flight, so a Running row seen here
                lost its settlement commit to the outage. It may be an uncertain
                claim or a completed external effect. Neither starting it again
                nor manufacturing completion is justified, and re-fencing it as
                an availability fault would reopen the handle on every wake for
                nothing. *)
             let fault = Operation_reconciliation_required operation_id in
             set_operation_fault t fault;
             publish_operation_projection t { projection with store_unavailable = true };
             Error (Store_unavailable (operation_fault_detail fault))
           | None ->
             t.operation_error := None;
             publish_operation_projection t projection;
             Log.Keeper.info ~keeper_name:t.keeper_name
               "keeper Owner operation store recovered queued=%d" projection.queued_count;
             Ok ())))
;;

(* A command is the moment the fence is re-examined, not a later wake:
   [wake_operation_drain] fires only when a keepalive starts or a deferred
   retry comes due, so a fence raised mid-day had no trigger to lift it and
   every later submission was refused with a stale detail (msx-retro-mania,
   2026-09-14 16:45 KST). An availability fault is retried here while no
   child holds the handle; the other faults stay fenced. *)
let run_operation_command t ~label f =
  match recover_operation_availability t with
  | Error error -> Error error
  | Ok () ->
    (match run_operation_store ~label f with
     | Error error -> Error (record_operation_error t error)
     | Ok value ->
       (match read_operation_projection t.operation_store ~now:(t.now ()) with
        | Error error -> Error (record_operation_error t error)
        | Ok projection ->
          publish_operation_projection t projection;
          Keeper_waiting_inventory_broadcast.changed
            ~keeper_name:t.keeper_name
            ~source:Keeper_waiting_inventory_broadcast.Chat_operation;
          Ok (value, projection)))
;;

(* A read must not be what discovers a closed handle. [recover_operation_availability]
   closes before it reopens, so a reopen that fails leaves this field naming a
   closed database; every command is guarded, so the read then fails with
   "database handle is closed". That string is the closure, not the cause, and
   [retain_operation_fault] lets a new availability failure replace an older
   one -- so the reopen's real reason (the file gone, permission withdrawn, the
   disk full) was overwritten by its own consequence the first time a dashboard
   poll or a TUI refresh read the store. The operator was left with a sentence
   that says only that the handle is shut.

   These reads run while the fence is up -- unlike a child, which
   [start_child_if_needed] holds back -- so they are the ones that reach it.
   The recorded fault is returned instead, and the handle is left alone; the
   command path reopens it under its own guard. *)
let run_operation_read t ~label f =
  match !(t.operation_error) with
  | Some fault when not (Chat_operation_store.is_open t.operation_store) ->
    Error (Store_unavailable (operation_fault_detail fault))
  | Some _ | None ->
    run_operation_store ~label f
    |> Result.map_error (record_operation_error t)
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
    | Ok interrupted ->
      (* [interrupted_count] in the inventory is cumulative, so it cannot answer
         "did this restart cut anything off". That is the question asked right
         after a bad swap, and the number is only available here. *)
      (match interrupted with
       | [] -> ()
       | _ :: _ ->
         Log.Keeper.routine
           ~keeper_name
           "restart interrupted %d running chat operation(s)"
           (List.length interrupted));
      read_operation_projection operation_store ~now:startup_now
      |> Result.map_error owner_error_of_operation_error
      |> Result.map (fun projection -> projection, interrupted)
  in
  (match startup_result with
   | Error _ as error ->
     (* See startup failure path: preserve the original error; close is best-effort. *)
     ignore (Chat_operation_store.close operation_store : (unit, _) result);
     error
   | Ok (initial_operation_projection, restart_interrupted) ->
  let closed_p, resolve_closed = Eio.Promise.create () in
  let t =
    { keeper_name
    ; mailbox = Eio.Stream.create mailbox_capacity
    ; projection = Atomic.make (Keeper_owner_reducer.projection initial_state)
    ; chat_control_token = Atomic.make (Random_id.uuid_v7 ())
    ; operation_projection =
        Atomic.make initial_operation_projection
    ; turn_in_flight = Atomic.make None
    ; shutdown_operation_id = Atomic.make None
    ; operation_store
    ; now
    ; closed = Atomic.make false
    ; closed_p
    ; metadata_error = ref None
    ; operation_error = ref None
    ; child_active = ref false
    ; child_cancel = Atomic.make None
    ; autonomous_lost_slot = ref false
    ; stopping_waiters = ref []
    ; shutdown_idle_waiters = ref []
    ; on_turn_slot_released
    ; restart_interrupted
    }
  in
  (* [closed_p] is what a caller of {!request} waits on to learn that no
     answer is coming. It used to be set here only, on switch release — and a
     switch releases when its fibers finish, which the caller is one of. A
     cancelled drain therefore left every in-flight request waiting on a
     promise nobody would resolve, inside the [Cancel.protect] that
     with_durable_lock puts around a persistence transaction, holding the
     keeper manifest lock, the runtime.toml lock and the lifecycle key lock
     for as long as the process ran (#33200). The drain now says so when it
     leaves its loop, which is the moment the owner stops answering. *)
  (* [exchange] is the once-guard: exactly one caller sees [false], and only
     that one resolves. Both the drain exit and on_release call this, in
     whichever order the teardown takes. *)
  let mark_no_longer_answering () =
    if not (Atomic.exchange t.closed true)
    then Eio.Promise.resolve resolve_closed ()
  in
  (* A cooling retry's wake rides the pool switch and dies with the process,
     and the Owner never polls: after a restart, a persisted future
     [not_before] would sit until an unrelated mailbox event. Wakes are
     therefore re-armed at start and after every drain wake — a keeper can
     hold more than one cooling retry (a cooling op is Queued, so another op
     can claim, defer, and cool behind it), and each wake re-arms the next
     earliest one. *)
  let rearm_cooling_retry_wake () =
    match (Atomic.get t.operation_projection).next_runtime_retry_wake with
    | None -> ()
    | Some not_before ->
      (match Eio_context.get_clock_opt () with
       | None ->
         Log.Keeper.warn
           "keeper_owner: no clock to re-arm cooling retry wake keeper=%s"
           keeper_name
       | Some clock ->
         (try
            Eio.Fiber.fork_daemon ~sw (fun () ->
              (try
                 Eio.Time.sleep clock (Float.max 0.0 (not_before -. t.now ()));
                 (* fire-and-forget: the sleeper exists only to deliver the wake; if the owner has closed by then there is nothing to wake. *)
                 notify t Wake_operation_drain
               with
               | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
               | exn ->
                 Log.Keeper.warn
                   "keeper_owner: cooling retry wake fiber failed keeper=%s error=%s"
                   keeper_name
                   (Printexc.to_string exn));
              `Stop_daemon)
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
            Log.Keeper.warn
              "keeper_owner: cooling retry wake not scheduled keeper=%s error=%s"
              keeper_name
              (Printexc.to_string exn)))
  in
  (* A transient (non-throttle) failure defers with no cooling time: the
     continuation is immediately claimable again, but the Owner never polls
     on its own, so the retry waits for whatever ambient wake happens to
     arrive next. On 2026-09-12 the live msx-retro-mania chat showed what
     that costs: a glm-5.3 connection reset made each failed attempt wait
     out the ambient scheduled wakes (~9 minutes apart), and one chat
     operation burned 45-77 minutes in that loop before the provider
     recovered. This short-fused wake closes that gap for the defer that
     just happened.

     The fuse is deliberately nonzero: a zero-delay wake would turn a dead
     provider into a tight re-claim loop (the throttle classes carry real
     backoff; a network-class failure has none). 20 seconds bounds a
     persistent outage to three re-claims per minute while cutting the
     transient-failure recovery from one ambient-wake interval to seconds.
     One sleeper arms per defer, so concurrent deferring operations each
     carry their own fuse; every resulting drain is a cheap claim attempt. *)
  let transient_retry_wake_sec = 20.0 in
  let rearm_transient_retry_wake () =
    match Eio_context.get_clock_opt () with
    | None ->
      Log.Keeper.warn
        "keeper_owner: no clock to re-arm transient retry wake keeper=%s"
        keeper_name
    | Some clock ->
      (try
         Eio.Fiber.fork_daemon ~sw (fun () ->
           (try
              Eio.Time.sleep clock transient_retry_wake_sec;
              (* fire-and-forget: the sleeper exists only to deliver the wake; if the owner has closed by then there is nothing to wake. *)
              notify t Wake_operation_drain
            with
            | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
            | exn ->
              Log.Keeper.warn
                "keeper_owner: transient retry wake fiber failed keeper=%s error=%s"
                keeper_name
                (Printexc.to_string exn));
           `Stop_daemon)
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Keeper.warn
           "keeper_owner: transient retry wake not scheduled keeper=%s error=%s"
           keeper_name
           (Printexc.to_string exn))
  in
  Eio.Switch.on_release sw (fun () ->
    mark_no_longer_answering ();
    let projection = Atomic.get t.projection in
    Atomic.set t.projection { projection with stopping = true };
    match Chat_operation_store.close t.operation_store with
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
      | Some operation_id, Operation_deferred ->
        run_operation_read t ~label:"confirm deferred Keeper chat operation" (fun () ->
          match Chat_operation_store.get t.operation_store operation_id with
          | Error error -> Error error
          | Ok None -> Error (Chat_operation_store.Unknown_operation operation_id)
          | Ok (Some operation) ->
            (match operation.state with
             | Chat_operation.Queued ->
               (match Chat_operation_store.direct_checkpoint t.operation_store ~operation_id with
                | Ok (Some _) -> Ok ()
                | Error error -> Error error
                | Ok None -> match Chat_operation_store.direct_runtime_retry t.operation_store ~operation_id with
                | Ok (Some _) -> Ok ()
                | Ok None ->
                  (match Chat_operation_store.direct_gate_state t.operation_store ~operation_id with
                   | Ok (Some _) -> Ok ()
                   | Ok None ->
                     (match Chat_operation_store.direct_gate_binding t.operation_store ~operation_id with
                      | Ok (Some _) -> Ok ()
                      | Ok None -> Error (Chat_operation_store.Integrity_error "deferred operation has no continuation")
                      | Error error -> Error error)
                   | Error error -> Error error)
                | Error error -> Error error)
             | Chat_operation.Cancelled _ -> Ok ()
             | Chat_operation.Running _ | Chat_operation.Succeeded _ | Chat_operation.Failed _ ->
               Error (Chat_operation_store.Integrity_error "deferred operation is not queued")))
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
      | Some _ when Option.is_some !(t.operation_error) || Option.is_some !(t.metadata_error) -> ()
      | Some runner when not (runner.ready ~keeper_name:t.keeper_name) -> ()
      | Some runner ->
        let inventory = Atomic.get t.operation_projection in
        if inventory.has_claimable_queued && Option.is_none inventory.running_operation_id
        then (
          t.child_active := true;
          publish_turn_in_flight
            t
            (Some { lane = Chat_operation; started_at = t.now ()
                  ; interrupt_token = Keeper_interrupt_token.fresh () });
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
                  Atomic.set t.child_cancel
                    (Some
                       { stop = (fun () -> Eio.Switch.fail child_sw Stop_active_child)
                       ; interrupt =
                           (fun () ->
                              Eio.Switch.fail child_sw
                                Keeper_registry_types.Operator_interrupt)
                       });
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
               Child_finished handover below, as it always could here;
               [settle_running_after_restart] clears that window on the next
               boot. The handover itself is protected, so an interrupted child
               still reports what it settled. *)
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
            notify
              t
              (Child_finished
                 (Operation_child_finished
                    { claimed_operation_id = !claimed_operation_id; execution }))
          ))
    and loop state shutdown_operation_id =
        let exact_interrupt target =
          (* Both names are compared against Owner state only. The token is the
             one minted with the slot, so it lives exactly as long as the child
             does; the inner agent switch a turn registers in [Keeper_registry]
             ends earlier and cannot serve as a stop handle. The cancel
             capability is the child's own switch: failing it reaches every
             request and delivery fiber the child forked, and the child's real
             teardown releases the slot.

             [Fiber.fork] runs the child body before this loop resumes (Eio 1.3:
             "fn runs immediately, without switching to any other fiber first")
             and that body publishes [child_cancel] first. So a held slot with
             an empty [child_cancel] means the execution has already returned
             and only its durable settle is pending. Both names are checked
             against the slot itself, so a durable projection that outlives a
             released slot (a failed settle) cannot keep answering "settling".

             A maintenance run holds the slot for an internal transaction
             whose caller expects a value or a typed error, not an operator
             cancellation; a chat stop names it and cancels nothing. *)
          let resolve_held holds =
            match Atomic.get t.turn_in_flight with
            | None -> Interrupt_not_current
            | Some _ when not holds -> Interrupt_not_current
            | Some { lane = Maintenance; _ } -> Interrupt_maintenance_running
            | Some _ ->
              (match Atomic.get t.child_cancel with
               | Some cancel -> Interrupt_now cancel.interrupt
               | None -> Interrupt_settling)
          in
          match target with
          | Observed_turn { interrupt_token } ->
            Ok (resolve_held
              (match Atomic.get t.turn_in_flight with
               | Some turn -> Keeper_interrupt_token.equal turn.interrupt_token interrupt_token
               | None -> false))
          | Direct_operation expected ->
            (* A member can observe Run_started before Batch_bound reaches its
               socket. Resolve only its immutable durable membership, never
               substitute whichever operation happens to be running. *)
            (match run_operation_read t ~label:"resolve exact interrupt execution" (fun () ->
               Chat_operation_store.get t.operation_store expected) with
             | Error _ as error -> error
             | Ok None -> Ok Interrupt_not_current
             | Ok (Some operation) ->
               let expected = match operation.Chat_operation.batch_membership with
                 | Some member -> member.execution_id
                 | None -> operation.operation_id in
               Ok (resolve_held
                 (match (Atomic.get t.operation_projection).running_operation_id with
                  | Some running -> Operation_id.equal running expected
                  | None -> false)))
        in
        let signal_exact target =
          let resolved = match target with None -> Ok Interrupt_not_current | Some target -> exact_interrupt target in
          match resolved with
          | Error error -> false, Some (error_to_string error)
          | Ok (Interrupt_not_current | Interrupt_settling | Interrupt_maintenance_running) -> false, None
          | Ok (Interrupt_now interrupt) ->
            (try interrupt (); true, None with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> false, Some (Printexc.to_string exn))
        in
        match Eio.Stream.take t.mailbox with
        | Command (Exact_projection, resolve) ->
          Eio.Promise.resolve resolve (Ok (Keeper_owner_reducer.projection state));
          loop state shutdown_operation_id
        | Command (Apply_meta command, resolve) ->
          (match !(t.metadata_error) with
           | Some fault ->
             (* The metadata snapshot store is fenced until a restart. An
                operation-store fault never reaches here: it no longer blocks a
                metadata commit. *)
             Eio.Promise.resolve resolve
               (Error (Store_unavailable (metadata_fault_detail fault)));
             loop state shutdown_operation_id
           | None ->
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
             (* A fenced operation store must not block a metadata commit; try
                to reopen it opportunistically so a chat child can start after
                the commit, but do not gate the commit on the result. *)
             (* fire-and-forget: the reopen's result is not read. *)
             ignore (recover_operation_availability t : (unit, error) result);
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
        | Command (Direct_checkpoint operation_id, resolve) ->
          let response = run_operation_read t ~label:"read direct cooperative checkpoint" (fun () ->
            Chat_operation_store.direct_checkpoint t.operation_store ~operation_id) in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Defer_direct_checkpoint {operation_id; execution_digest; checkpoint}, resolve) ->
          let response = run_operation_command t ~label:"defer direct cooperative checkpoint" (fun () ->
            Chat_operation_store.defer_direct_checkpoint t.operation_store ~now:(t.now ())
              ~operation_id ~execution_digest ~checkpoint) |> Result.map fst in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Resume_direct_checkpoint {operation_id; observed}, resolve) ->
          let response = run_operation_command t ~label:"resume direct cooperative checkpoint" (fun () ->
            Chat_operation_store.resume_direct_checkpoint t.operation_store ~now:(t.now ())
              ~operation_id ~observed) |> Result.map fst in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Direct_runtime_retry operation_id, resolve) ->
          let response = run_operation_read t ~label:"read direct runtime continuation" (fun () ->
            Chat_operation_store.direct_runtime_retry t.operation_store ~operation_id) in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Defer_direct_runtime_retry {operation_id; execution_digest; continuation}, resolve) ->
          let response = run_operation_command t ~label:"defer direct runtime continuation" (fun () ->
            Chat_operation_store.defer_direct_runtime_retry t.operation_store ~now:(t.now ())
              ~operation_id ~execution_digest ~continuation) |> Result.map fst in
          (* A defer with no [not_before] is immediately claimable, and
             without this wake it waits for the next ambient event — the
             minutes-long stall this sleeper exists to remove. The cooling
             re-arm below only covers [not_before] in the future, so an
             immediate retry needs its own fuse. *)
          (match response with
           | Ok _ when continuation.Keeper_semantic_execution.not_before = None ->
             rearm_transient_retry_wake ()
           | _ -> ());
          rearm_cooling_retry_wake ();
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Resume_direct_runtime_retry {operation_id; observed}, resolve) ->
          let response = run_operation_command t ~label:"resume direct runtime continuation" (fun () ->
            Chat_operation_store.resume_direct_runtime_retry t.operation_store ~now:(t.now ())
              ~operation_id ~observed) |> Result.map fst in
          Eio.Promise.resolve resolve response;
          loop state shutdown_operation_id
        | Command (Direct_gate_bindings, resolve) ->
          let response = run_operation_read t ~label:"read unresolved direct Gate sources" (fun () ->
            Chat_operation_store.direct_gate_bindings t.operation_store) in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Reconcile_direct_gate_binding {operation_id; binding; waiting}, resolve) ->
          let response = run_operation_command t ~label:"confirm original direct Gate source" (fun () ->
            Chat_operation_store.reconcile_direct_gate_binding t.operation_store ~now:(t.now ())
              ~operation_id ~binding ~waiting) |> Result.map fst in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Direct_gate_waits, resolve) ->
          let response = run_operation_read t ~label:"read waiting direct Gate operations" (fun () ->
            Chat_operation_store.direct_gate_waits t.operation_store) in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Discharge_direct_gate {operation_id; obligation}, resolve) ->
          let response = run_operation_command t ~label:"record admitted Gate evidence" (fun () ->
            Chat_operation_store.discharge_direct_gate t.operation_store ~now:(t.now ()) ~operation_id ~obligation)
            |> Result.map fst in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Direct_gate_state operation_id, resolve) ->
          let response = run_operation_read t ~label:"read direct Gate wait" (fun () ->
            Chat_operation_store.direct_gate_state t.operation_store ~operation_id) in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Direct_gate_binding operation_id, resolve) ->
          let response = run_operation_read t ~label:"read unresolved Gate binding" (fun () ->
            Chat_operation_store.direct_gate_binding t.operation_store ~operation_id) in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Direct_gate_obligations operation_id, resolve) ->
          let response = run_operation_read t ~label:"read direct Gate obligations" (fun () ->
            Chat_operation_store.direct_gate_obligations t.operation_store ~operation_id) in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Defer_direct_gate_reconciliation {operation_id; execution_digest; binding; diagnostic}, resolve) ->
          let response = run_operation_command t ~label:"retain direct Gate reconciliation" (fun () ->
            Chat_operation_store.defer_direct_gate_reconciliation t.operation_store ~now:(t.now ())
              ~operation_id ~execution_digest ~binding ~diagnostic) |> Result.map fst in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Defer_direct_gate {operation_id; execution_digest; waiting}, resolve) ->
          let response = run_operation_command t ~label:"suspend direct Gate operation" (fun () ->
            Chat_operation_store.defer_direct_gate t.operation_store ~now:(t.now ())
              ~operation_id ~execution_digest ~waiting) |> Result.map fst in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Resolve_direct_gate {operation_id; resolution}, resolve) ->
          let response = run_operation_command t ~label:"resolve direct Gate obligation" (fun () ->
            Chat_operation_store.resolve_direct_gate t.operation_store ~now:(t.now ())
              ~operation_id ~resolution) |> Result.map fst in
          Eio.Promise.resolve resolve response;
          start_child_if_needed state shutdown_operation_id;
          loop state shutdown_operation_id
        | Command (Resume_direct_gate {operation_id; waiting; resolution}, resolve) ->
          let response = run_operation_command t ~label:"resume direct Gate operation" (fun () ->
            Chat_operation_store.resume_direct_gate t.operation_store ~now:(t.now ())
              ~operation_id ~waiting ~resolution) |> Result.map fst in
          Eio.Promise.resolve resolve response; loop state shutdown_operation_id
        | Command (Pause_and_interrupt {target; expected_control_token}, resolve) ->
          if Option.is_some shutdown_operation_id || (Keeper_owner_reducer.projection state).stopping then (
            Eio.Promise.resolve resolve (Error Owner_stopping);
            loop state shutdown_operation_id)
          else
          let authorization =
            let ( let* ) = Result.bind in
            let* interrupt = exact_interrupt target in
            let* pending = match interrupt, target, expected_control_token with
            | Interrupt_not_current, Direct_operation operation_id, Some token
              when String.equal token (chat_control_token t)
                && not !(t.child_active)
                && Option.is_none (Atomic.get t.turn_in_flight)
                && Option.is_none (Atomic.get t.operation_projection).running_operation_id ->
              run_operation_read t ~label:"authorize exact pending admission stop" (fun () ->
                Chat_operation_store.get t.operation_store operation_id)
              |> Result.map (function
                | None | Some {Chat_operation.state = Queued; _} -> true
                | Some {Chat_operation.state = (Running _ | Succeeded _ | Failed _ | Cancelled _); _} -> false)
            | (Interrupt_not_current | Interrupt_settling | Interrupt_maintenance_running | Interrupt_now _),
              (Observed_turn _ | Direct_operation _), (Some _ | None) -> Ok false in
            Ok (interrupt, pending) in
          (match authorization with
           | Error error -> Eio.Promise.resolve resolve (Error error); loop state shutdown_operation_id
           | Ok (Interrupt_not_current, false) ->
             Eio.Promise.resolve resolve (Ok
               (Interrupt_result (Operation_not_current { running_operation_id = (Atomic.get t.operation_projection).running_operation_id }), chat_control_token t));
             loop state shutdown_operation_id
           | Ok (interrupt, _) ->
             Atomic.set t.chat_control_token (Random_id.uuid_v7 ());
             let result = match interrupt with
               | Interrupt_not_current -> Pending_admission_paused
               | Interrupt_settling -> Interrupt_result Operation_settling
               | Interrupt_maintenance_running -> Interrupt_result Operation_maintenance_running
               | Interrupt_now interrupt -> Interrupt_result
                   (try interrupt (); Operation_interrupt_signalled with
                    | Eio.Cancel.Cancelled _ as exn -> raise exn
                    | exn -> Operation_interrupt_failed (Printexc.to_string exn)) in
             Eio.Promise.resolve resolve (Ok (result, chat_control_token t));
             loop state shutdown_operation_id)
        | Command (Run_next_operation { operation_id; observed }, resolve) ->
          if not (turn_admission_open state) then (
            Eio.Promise.resolve resolve (Ok Run_next_paused);
            loop state shutdown_operation_id)
          else
          let prioritized = reject_if_shutdown shutdown_operation_id (fun () ->
            reject_if_stopping state (fun () ->
              run_operation_command t ~label:"prioritize explicit next Keeper operation" (fun () ->
                Chat_operation_store.move_queued_to_front t.operation_store ~now:(t.now ()) ~operation_id)
                |> Result.map (fun _ -> ()))) in
          (match prioritized with
           | Error error -> Eio.Promise.resolve resolve (Error error); loop state shutdown_operation_id
           | Ok () ->
             let signalled, interrupt_error = signal_exact observed in
             Eio.Promise.resolve resolve (Ok (Run_next_applied { signalled; interrupt_error }));
             start_child_if_needed state shutdown_operation_id;
             loop state shutdown_operation_id)
        | Command (Interrupt_running_operation expected, resolve) ->
          let response = match exact_interrupt (Direct_operation expected) with
            | Error _ as error -> error
            | Ok Interrupt_not_current ->
              Ok (Operation_not_current
                {running_operation_id = (Atomic.get t.operation_projection).running_operation_id})
            | Ok Interrupt_settling -> Ok Operation_settling
            | Ok Interrupt_maintenance_running -> Ok Operation_maintenance_running
            | Ok (Interrupt_now interrupt) ->
              Ok (try interrupt (); Operation_interrupt_signalled with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn -> Operation_interrupt_failed (Printexc.to_string exn)) in
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
        | Command (Submit_interactive_operation {operation_id; source; input; intent}, resolve) ->
          let current = String.equal intent.control_token (chat_control_token t) in
          let permitted = current && turn_admission_open state in
          let result = reject_if_shutdown shutdown_operation_id (fun () ->
            reject_if_stopping state (fun () ->
              run_operation_command t ~label:"admit interactive Keeper message" (fun () ->
                Chat_operation_store.submit
                  ?priority:(if permitted then Some Keeper_chat_operation_batch.select else None)
                  t.operation_store ~now:(t.now ()) ~operation_id ~source ~input))) in
          (match result with
           | Error error -> Eio.Promise.resolve resolve (Error error); loop state shutdown_operation_id
           | Ok (admission, projection) ->
             let operation, existing = match admission with
               | Chat_operation_store.Accepted operation -> operation, false
               | Existing operation -> operation, true in
             let acceptance = {operation; existing; queued_count = projection.queued_count} in
             let outcome = if existing then Replayed else if not current then Stale_control else if not permitted then Paused else Applied in
             let signalled, interrupt_error = if outcome <> Applied then false, None
               else signal_exact intent.target in
             let receipt = {outcome; chat_control_token = chat_control_token t; signalled; resumed = false; interrupt_error} in
             Eio.Promise.resolve resolve (Ok (acceptance, receipt));
             start_child_if_needed state shutdown_operation_id;
             loop state shutdown_operation_id)
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
        | Command (Move_queued_operation_to_front operation_id, resolve) ->
          let response = reject_if_stopping state (fun () ->
            run_operation_command t ~label:"prioritize queued Keeper chat operation" (fun () ->
              Chat_operation_store.move_queued_to_front t.operation_store ~now:(t.now ()) ~operation_id)
            |> Result.map fst) in
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
        | Command (Batch_operations operation_id, resolve) ->
          let response = run_operation_read t ~label:"read shared chat execution" (fun () ->
            Chat_operation_store.batch_operations t.operation_store ~operation_id) in
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
                         ~batch:Keeper_chat_operation_batch.select
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
          (* Retry deadlines change readiness without a store mutation. Publish
             before attempting a claim, even while an autonomous turn owns the
             slot, so its next safe boundary can see the ready successor. *)
          let response =
            let ( let* ) = Result.bind in
            let* () = recover_operation_availability t in
            run_operation_command t ~label:"refresh Keeper operation readiness"
              (fun () -> Ok ())
            |> Result.map (fun _ -> ())
          in
          Eio.Promise.resolve resolve response;
          start_child_if_needed state shutdown_operation_id;
          (* The wake that just fired may have been the earliest of several
             cooling retries; arm the next one only after a fresh projection.
             A failed refresh must not re-arm an expired cached deadline. *)
          (match response with
           | Ok () -> rearm_cooling_retry_wake ()
           | Error _ -> ());
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
           | None when (match lane with
               | Autonomous | Chat_operation -> not (turn_admission_open state)
               | Maintenance -> false) ->
             Eio.Promise.resolve resolve (Ok (Autonomous_busy Admission_paused))
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
                   let run_admitted_turn () =
                     t.child_active := true;
                     publish_turn_in_flight
                       t
                       (Some { lane; started_at = t.now ()
                             ; interrupt_token = Keeper_interrupt_token.fresh () });
                     Eio.Fiber.fork ~sw (fun () ->
                       let outcome =
                         try
                           Ok
                             (Eio.Switch.run (fun child_sw ->
                                Atomic.set t.child_cancel
                                  (Some
                                     { stop =
                                         (fun () ->
                                            Eio.Switch.fail child_sw Stop_active_child)
                                     ; interrupt =
                                         (fun () ->
                                            Eio.Switch.fail child_sw
                                              Keeper_registry_types.Operator_interrupt)
                                     });
                                run ()))
                         with
                         | exn -> Error (exn, Printexc.get_raw_backtrace ())
                       in
                       Atomic.set t.child_cancel None;
                       notify
                         t
                         (Child_finished
                            (Autonomous_child_finished { outcome; resolve })))
                   in
                   (match lane with
                    | Chat_operation | Maintenance -> run_admitted_turn ()
                    | Autonomous ->
                      (* Do not take a free slot ahead of a queued chat. No
                         child holds the operation store here, so recover it
                         first; if it is healthy and a chat can claim, hand the
                         slot to the chat as every other slot-free path already
                         does through [start_child_if_needed]. A still-fenced
                         store keeps the autonomous lane productive rather than
                         idling on a chat that cannot start yet. *)
                      ignore (recover_operation_availability t : (unit, error) result);
                      let inventory = Atomic.get t.operation_projection in
                      let chat_can_take_slot =
                        inventory.has_claimable_queued
                        && not inventory.store_unavailable
                        && Option.is_none inventory.running_operation_id
                      in
                      if not chat_can_take_slot
                      then run_admitted_turn ()
                      else (
                        start_child_if_needed state shutdown_operation_id;
                        match Atomic.get t.turn_in_flight with
                        | Some ({ lane = Chat_operation; _ } as chat) ->
                          t.autonomous_lost_slot := true;
                          Eio.Promise.resolve
                            resolve
                            (Ok (Autonomous_busy (Turn_busy (Some chat))))
                        | Some _ | None -> run_admitted_turn ())))));
          loop state shutdown_operation_id
        | Command (Child_finished completion, resolve) ->
          let result =
            match completion with
            | Operation_child_finished { claimed_operation_id; execution } ->
              (* The child ignores this result and the row stays Running, so
                 a refused settlement is otherwise invisible until the next
                 boot settles it. *)
              (match finish_operation_child claimed_operation_id execution with
               | Ok () as ok -> ok
               | Error error as failed ->
                 Log.Keeper.error ~keeper_name:t.keeper_name
                   "chat operation settlement refused operation=%s: %s"
                   (match claimed_operation_id with
                    | Some operation_id -> Chat_operation.Operation_id.to_string operation_id
                    | None -> "unclaimed")
                   (error_to_string error);
                 failed)
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
                    try cancel.stop () with
                    | Invalid_argument _ -> ())
                 (Atomic.get t.child_cancel))
             else Eio.Promise.resolve resolve (Ok ());
             loop state shutdown_operation_id)
    in
    start_child_if_needed initial_state None;
    (* Cancellation reaches the drain at its [Stream.take]. Whatever the
       reason, the loop is the owner's only reader, so leaving it means no
       queued or future command will be answered. *)
    match loop initial_state None with
    | value ->
      mark_no_longer_answering ();
      value
    | exception exn ->
      mark_no_longer_answering ();
      raise exn);
  (* The defer-time wake died with the previous process; re-arm it. *)
  rearm_cooling_retry_wake ();
  Ok t))
;;

let exact_projection t = request t Exact_projection
let apply_meta t command = request t (Apply_meta command)
let direct_checkpoint t ~operation_id = request t (Direct_checkpoint operation_id)
let defer_direct_checkpoint t ~operation_id ~execution_digest ~checkpoint =
  request t (Defer_direct_checkpoint {operation_id; execution_digest; checkpoint})
let resume_direct_checkpoint t ~operation_id ~observed =
  request t (Resume_direct_checkpoint {operation_id; observed})

let direct_runtime_retry t ~operation_id = request t (Direct_runtime_retry operation_id)
let defer_direct_runtime_retry t ~operation_id ~execution_digest ~continuation =
  request t (Defer_direct_runtime_retry {operation_id; execution_digest; continuation})
let resume_direct_runtime_retry t ~operation_id ~observed =
  request t (Resume_direct_runtime_retry {operation_id; observed})

let exact_operation t operation_id = request t (Exact_operation operation_id)
let restart_interrupted_operations t = t.restart_interrupted
let pause_and_interrupt ?expected_control_token t target = request t (Pause_and_interrupt {target; expected_control_token})
let interrupt_turn = pause_and_interrupt
let run_next_operation t ~operation_id ~observed = request t (Run_next_operation { operation_id; observed })

let interrupt_running_operation t operation_id =
  request t (Interrupt_running_operation operation_id)
;;
let wake_operation_drain t = request t Wake_operation_drain

let submit_interactive_operation t ~operation_id ~source ~input ~intent =
  request t (Submit_interactive_operation {operation_id; source; input; intent})

let submit_operation t ~operation_id ~source ~input =
  request t (Submit_operation { operation_id; source; input })
;;

let list_queued_operations t ~after_sequence ~limit =
  request t (List_queued_operations { after_sequence; limit })
;;

let edit_queued_operation t ~operation_id ~input =
  request t (Edit_queued_operation { operation_id; input })
;;

let move_queued_operation_to_front t operation_id =
  request t (Move_queued_operation_to_front operation_id)
;;

let move_queued_operation_to_end t operation_id =
  request t (Move_queued_operation_to_end operation_id)
;;

let cancel_queued_operation t operation_id = request t (Cancel_queued_operation operation_id)
let batch_operations t operation_id = request t (Batch_operations operation_id)
let claim_next_operation t = request t Claim_next_operation

let succeed_running_operation t ~operation_id ~outcome_ref =
  request t (Succeed_running_operation { operation_id; outcome_ref })
;;

let run_autonomous_if_idle t run =
  match request t (Run_if_idle { lane = Autonomous; run }) with
  | Error _ as error -> error
  | Ok (Autonomous_ran value) -> Ok (`Ran value)
  | Ok (Autonomous_busy block) -> Ok (`Busy block)
  | Ok (Autonomous_raised (Stop_active_child, _)) -> Error Owner_stopping
  | Ok (Autonomous_raised (exn, _))
    when Keeper_registry_types.is_operator_interrupt exn ->
    (* [interrupt] fails the child switch, so [Switch.run] raises this even
       after the turn body caught it and returned. The chat child turns the
       same exception into a Turn_cancelled settlement; here it used to
       escape into the keepalive fiber, and the registry recorded a crash
       and restarted the Keeper for an operator's message. *)
    Ok `Interrupted
  | Ok (Autonomous_raised (exn, backtrace)) ->
    Printexc.raise_with_backtrace exn backtrace
;;

(* Maintenance is not interruptible ([Interrupt_maintenance_running]), so an
   operator interrupt reaching this lane is not a translated outcome. *)
let run_maintenance_if_idle t run =
  match request t (Run_if_idle { lane = Maintenance; run }) with
  | Error _ as error -> error
  | Ok (Autonomous_ran value) -> Ok (`Ran value)
  | Ok (Autonomous_busy block) -> Ok (`Busy block)
  | Ok (Autonomous_raised (Stop_active_child, _)) -> Error Owner_stopping
  | Ok (Autonomous_raised (exn, backtrace)) ->
    Printexc.raise_with_backtrace exn backtrace
;;

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
  let enqueue_unless_closed = enqueue_unless_closed

  let observe_state_changes ~sw observer =
    let previous = Atomic.get state_change_observer in
    (* Keep the installed observer and restore it with this test switch. The
       additional callback only resolves a test promise; it must not yield. *)
    install_state_change_observer (fun () ->
      Fun.protect ~finally:observer previous);
    Eio.Switch.on_release sw (fun () -> install_state_change_observer previous)
end

let direct_gate_state t ~operation_id = request t (Direct_gate_state operation_id)
let direct_gate_obligations t ~operation_id = request t (Direct_gate_obligations operation_id)
let defer_direct_gate t ~operation_id ~execution_digest ~waiting =
  request t (Defer_direct_gate {operation_id; execution_digest; waiting})
let resolve_direct_gate t ~operation_id ~resolution = request t (Resolve_direct_gate {operation_id; resolution})
let resume_direct_gate t ~operation_id ~waiting ~resolution = request t (Resume_direct_gate {operation_id; waiting; resolution})

let direct_gate_waits t = request t Direct_gate_waits
let discharge_direct_gate t ~operation_id ~obligation = request t (Discharge_direct_gate {operation_id; obligation})

let defer_direct_gate_reconciliation t ~operation_id ~execution_digest ~binding ~diagnostic =
  request t (Defer_direct_gate_reconciliation {operation_id; execution_digest; binding; diagnostic})

let direct_gate_binding t ~operation_id = request t (Direct_gate_binding operation_id)

let direct_gate_bindings t = request t Direct_gate_bindings
let reconcile_direct_gate_binding t ~operation_id ~binding ~waiting =
  request t (Reconcile_direct_gate_binding {operation_id; binding; waiting})
