module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Board_dispatch - Runtime backend selection for MASC Board

    Board now runs on the JSONL store only. Backend is selected once at
    server startup and fixed for the session.

    @since 0.6.0
*)

type sort_order = Hot | Trending | Recent | Updated | Discussed

(** Issue #8449: SSOT helpers for [sort_order]. Three call sites used to
    own private parsers and a separate Variant in [Board_tool]; this PR
    A introduces the canonical helpers here so the schema enum can derive
    from the Variant. PR B will collapse the duplicate Variant; PR C
    will route [server_utils] through these parsers.

    All constructors are nullary so [List.map] works. *)
let all_sort_orders = [ Hot; Trending; Recent; Updated; Discussed ]

let sort_order_to_string = function
  | Hot -> "hot"
  | Trending -> "trending"
  | Recent -> "recent"
  | Updated -> "updated"
  | Discussed -> "discussed"

let valid_sort_order_strings = List.map sort_order_to_string all_sort_orders

(** Canonical parser shared by Board_tool and HTTP query-param handling. *)
let sort_order_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "hot" -> Some Hot
  | "trending" -> Some Trending
  | "recent" -> Some Recent
  | "updated" -> Some Updated
  | "discussed" -> Some Discussed
  | _ -> None

type board_backend =
  | Jsonl of Board.store

(** Lifecycle state carried inside [Active] for each long-lived Board actor.
    A live transition retains its exact owner switch, so backend publication,
    actor liveness, and cleanup authority remain one immutable atomic fact. *)
type actor_status =
  | Actor_stopped
  | Actor_starting of Eio.Switch.t
  | Actor_started of Eio.Switch.t

type runtime_actor_state = {
  flusher : actor_status;
  routing_retry : actor_status;
}

let runtime_actors_stopped =
  { flusher = Actor_stopped; routing_retry = Actor_stopped }
;;

type backend_state =
  | Uninitialized
  | Active of board_backend * runtime_actor_state

type board_signal_kind = Board_signal_command.signal_kind =
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed of board_reaction_change

and board_reaction_change = Board_signal_command.reaction_change = {
  target_type : Board.reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

type board_signal = Board_signal_command.signal = {
  kind : board_signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type board_signal_event = {
  event_id : string;
  audience : Board_signal_audience.t;
  signal : board_signal;
}

type board_signal_delivery =
  | Atomic_sink_accepted
  | Recipient_settlement_complete

let routing_mutation_mu = Eio.Mutex.create ()

let routing_delivery_claim_mu = Stdlib.Mutex.create ()
let routing_delivery_claims : (string, unit) Hashtbl.t = Hashtbl.create 64

let with_routing_mutation_lock f =
  Eio.Mutex.use_rw ~protect:true routing_mutation_mu f
;;

let claim_routing_delivery event_id =
  Stdlib.Mutex.protect routing_delivery_claim_mu (fun () ->
    if Hashtbl.mem routing_delivery_claims event_id
    then false
    else (
      Hashtbl.add routing_delivery_claims event_id ();
      true))
;;

let release_routing_delivery event_id =
  Stdlib.Mutex.protect routing_delivery_claim_mu (fun () ->
    Hashtbl.remove routing_delivery_claims event_id)
;;

let ensure_no_prepared_routing_mutation () =
  Result.bind (Board_signal_outbox.entries ()) (fun entries ->
    match
      List.find_opt
        (fun (entry : Board_signal_outbox.entry) ->
           match entry.phase with
           | Board_signal_outbox.Prepared _ -> true
           | Board_signal_outbox.Committed _ | Board_signal_outbox.Delivered _ -> false)
        entries
    with
    | None -> Ok ()
    | Some entry ->
      Error
        (Printf.sprintf
           "prior Board routing mutation remains prepared: event_id=%s"
           entry.event_id))
;;

type pending_routing_references = {
  post_ids : string list;
  comment_ids : string list;
}

let prepared_routing_references () =
  Result.map
    (fun entries ->
       List.fold_left
         (fun references (entry : Board_signal_outbox.entry) ->
            let command =
              match entry.phase with
              | Board_signal_outbox.Prepared command -> Some command
              | Board_signal_outbox.Committed _ | Board_signal_outbox.Delivered _ -> None
            in
            match command with
            | None -> references
            | Some command ->
              let post_id = Board_signal_command.referenced_post_id command in
              let comment_ids =
                match Board_signal_command.referenced_comment_id command with
                | None -> references.comment_ids
                | Some comment_id -> comment_id :: references.comment_ids
              in
              { post_ids = post_id :: references.post_ids; comment_ids })
         { post_ids = []; comment_ids = [] }
         entries
       |> fun references ->
       { post_ids = List.sort_uniq String.compare references.post_ids
       ; comment_ids = List.sort_uniq String.compare references.comment_ids
       })
    (Board_signal_outbox.entries ())
;;

let reject_referenced_post_mutation ~operation ~post_id mutation =
  match prepared_routing_references () with
  | Error detail -> Error (Board_types.Io_error detail)
  | Ok references ->
    if List.exists (String.equal post_id) references.post_ids
    then
      Error
        (Board_types.Io_error
           (Printf.sprintf
              "Board post %s is fenced by its pending routing command: %s"
              operation
              post_id))
    else mutation ()
;;

type board_sse_event =
  | Post_created of {
      post_id : string;
      author : string;
      title : string;
      content : string;
      post_kind : Board.post_kind;
      hearth : string option;
    }
  | Comment_added of { post_id : string; comment_id : string; author : string }
  | Post_voted of { post_id : string; voter : string; direction : Board.vote_direction }
  | Comment_voted of { comment_id : string; voter : string; direction : Board.vote_direction }
  | Reaction_changed of {
      target_type : Board.reaction_target_type;
      target_id : string;
      user_id : string;
      emoji : string;
      reacted : bool;
    }

let backend_state : backend_state Atomic.t = Atomic.make Uninitialized

type routing_callback = unit -> (unit, string) result

let run_routing_callback ~name callback =
  match Atomic.get callback with
  | Some callback -> callback ()
  | None -> Error (name ^ " is not installed")
;;

let routing_retry_callback : routing_callback option Atomic.t =
  Atomic.make None
;;

let routing_retry_requested = Atomic.make false
let routing_retry_inbox = Eio.Stream.create 1

let request_routing_retry () =
  if Atomic.compare_and_set routing_retry_requested false true
  then
    try Eio.Stream.add routing_retry_inbox () with
    | exn ->
      Atomic.set routing_retry_requested false;
      raise exn
;;

let rec clear_routing_retry_inbox_for_test () =
  match Eio.Stream.take_nonblocking routing_retry_inbox with
  | Some () -> clear_routing_retry_inbox_for_test ()
  | None -> ()
;;

type runtime_actor = Board_metrics_hooks.runtime_actor =
  | Flusher
  | Routing_retry

type runtime_actor_start_error =
  | Backend_uninitialized
  | Backend_replaced_during_start of runtime_actor
  | Switch_unavailable of runtime_actor * exn
  | Actor_spawn_failed of runtime_actor * exn

type runtime_actor_start_failures =
  | One_actor_start_failed of runtime_actor_start_error
  | Both_actors_start_failed of
      runtime_actor_start_error * runtime_actor_start_error

type dirty_projection_flush_failure =
  | Flush_rejected of Board_types.board_error
  | Flush_raised of {
      cause : exn;
      backtrace : Printexc.raw_backtrace;
    }

type flusher_attempt_failure =
  | Dirty_projection_flush_failed of dirty_projection_flush_failure
  | Sweep_routing_references_unavailable of string
  | Sweep_raised of {
      cause : exn;
      backtrace : Printexc.raw_backtrace;
    }

type flusher_retry_obligations = {
  flush_retry_at : float option;
  sweep_retry_at : float option;
}

exception Runtime_actor_start_failure of runtime_actor_start_failures

let runtime_actor_to_string = function
  | Flusher -> "flusher"
  | Routing_retry -> "routing_retry"
;;

let runtime_actor_start_error_to_string = function
  | Backend_uninitialized ->
    "Board backend must be initialized before its runtime actors"
  | Backend_replaced_during_start actor ->
    Printf.sprintf "Board backend was replaced while actor=%s was starting"
      (runtime_actor_to_string actor)
  | Switch_unavailable (actor, exn) ->
    Printf.sprintf "Board runtime actor=%s switch is unavailable: %s"
      (runtime_actor_to_string actor)
      (Printexc.to_string exn)
  | Actor_spawn_failed (actor, exn) ->
    Printf.sprintf "Board runtime actor=%s spawn failed: %s"
      (runtime_actor_to_string actor)
      (Printexc.to_string exn)
;;

let runtime_actor_start_failures_to_string = function
  | One_actor_start_failed error -> runtime_actor_start_error_to_string error
  | Both_actors_start_failed (first, second) ->
    Printf.sprintf "Board runtime actor startup failures: [%s; %s]"
      (runtime_actor_start_error_to_string first)
      (runtime_actor_start_error_to_string second)
;;

let () =
  Printexc.register_printer (function
    | Runtime_actor_start_failure error ->
      Some (runtime_actor_start_failures_to_string error)
    | _ -> None)
;;

let spawn_runtime_actor_on_switch ~sw ~clock store actor =
  let flush_attempt () =
    try
      match Board.flush_dirty store with
      | Ok () -> Ok ()
      | Error error ->
        Error
          ( Board_types.Flush
          , Dirty_projection_flush_failed (Flush_rejected error) )
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | (Out_of_memory | Stack_overflow) as exn -> raise exn
    | exn ->
      Error
        ( Board_types.Flush
        , Dirty_projection_flush_failed
            (Flush_raised
               { cause = exn; backtrace = Printexc.get_raw_backtrace () }) )
  in
  let sweep_attempt () =
    try
      with_routing_mutation_lock (fun () ->
        match prepared_routing_references () with
        | Error detail ->
          Error
            (Board_types.Sweep, Sweep_routing_references_unavailable detail)
        | Ok references ->
          (match
             Board.sweep_and_flush
               ~protected_post_ids:references.post_ids
               ~protected_comment_ids:references.comment_ids
               store
           with
           | Ok _ -> Ok ()
           | Error error ->
             (* The sweep mutation completed before its projection flush was
                rejected.  Only the dirty projection remains an obligation. *)
             Error
               ( Board_types.Flush
               , Dirty_projection_flush_failed (Flush_rejected error) )))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | (Out_of_memory | Stack_overflow) as exn -> raise exn
    | exn ->
      Error
        ( Board_types.Sweep
        , Sweep_raised
            { cause = exn; backtrace = Printexc.get_raw_backtrace () } )
  in
  let operation_to_string = function
    | Board_types.Flush -> "flush_projection"
    | Board_types.Sweep -> "sweep_board"
  in
  let retry_deadline obligations = function
    | Board_types.Flush -> obligations.flush_retry_at
    | Board_types.Sweep -> obligations.sweep_retry_at
  in
  let without_retry obligations = function
    | Board_types.Flush -> { obligations with flush_retry_at = None }
    | Board_types.Sweep -> { obligations with sweep_retry_at = None }
  in
  let with_retry_at obligations operation retry_at =
    match operation with
    | Board_types.Flush -> { obligations with flush_retry_at = Some retry_at }
    | Board_types.Sweep -> { obligations with sweep_retry_at = Some retry_at }
  in
  let earliest_retry obligations =
    match obligations.flush_retry_at, obligations.sweep_retry_at with
    | None, None -> None
    | Some retry_at, None -> Some (retry_at, Board_types.Flush)
    | None, Some retry_at -> Some (retry_at, Board_types.Sweep)
    | Some flush_at, Some sweep_at ->
      if Float.compare flush_at sweep_at <= 0
      then Some (flush_at, Board_types.Flush)
      else Some (sweep_at, Board_types.Sweep)
  in
  let retry_obligation obligations operation =
    let proposed_retry_at = Eio.Time.now clock +. Board.flush_interval_sec in
    let retry_at =
      match retry_deadline obligations operation with
      | None -> proposed_retry_at
      | Some current_retry_at -> Float.min current_retry_at proposed_retry_at
    in
    with_retry_at obligations operation retry_at
  in
  let rec await_operation obligations =
    let now = Eio.Time.now clock in
    match earliest_retry obligations with
    | Some (retry_at, operation) when Float.compare retry_at now <= 0 ->
      operation, true, without_retry obligations operation
    | retry ->
      (match retry with
       | None ->
         let operation = Eio.Stream.take store.Board.flusher_inbox in
         let recovering =
           Option.is_some (retry_deadline obligations operation)
         in
         operation, recovering, without_retry obligations operation
       | Some (retry_at, _) ->
         let remaining = retry_at -. now in
         (match
            Eio.Time.with_timeout clock remaining (fun () ->
              Ok (Eio.Stream.take store.Board.flusher_inbox))
          with
          | Ok message ->
            let operation = message in
            let recovering =
              Option.is_some (retry_deadline obligations operation)
            in
            operation, recovering, without_retry obligations operation
          | Error `Timeout -> await_operation obligations))
  in
  let log_attempt_failure ~operation ~retry_operation = function
    | Dirty_projection_flush_failed (Flush_rejected error) ->
      Log.BoardLog.error
        "Board flusher operation=%s failed; retry obligation=%s remains active: %s"
        (operation_to_string operation)
        (operation_to_string retry_operation)
        (Board.show_board_error error)
    | Dirty_projection_flush_failed (Flush_raised { cause; backtrace }) ->
      Log.BoardLog.error
        "Board flusher operation=%s raised; retry obligation=%s remains active: %s\n%s"
        (operation_to_string operation)
        (operation_to_string retry_operation)
        (Printexc.to_string cause)
        (Printexc.raw_backtrace_to_string backtrace)
    | Sweep_routing_references_unavailable detail ->
      Log.BoardLog.warn
        "Board flusher operation=%s deferred; retry obligation=%s remains active: %s"
        (operation_to_string operation)
        (operation_to_string retry_operation)
        detail
    | Sweep_raised { cause; backtrace } ->
      Log.BoardLog.error
        "Board flusher operation=%s raised; retry obligation=%s remains active: %s\n%s"
        (operation_to_string operation)
        (operation_to_string retry_operation)
        (Printexc.to_string cause)
        (Printexc.raw_backtrace_to_string backtrace)
  in
  let flusher_loop () =
    Log.BoardLog.info "Board flusher actor started";
    let rec loop obligations =
      let operation, recovering, obligations = await_operation obligations in
      let outcome =
        match operation with
        | Board_types.Flush -> flush_attempt ()
        | Board_types.Sweep -> sweep_attempt ()
      in
      match outcome with
      | Ok () ->
        if recovering
        then
          Log.BoardLog.info
            "Board flusher obligation settled operation=%s"
            (operation_to_string operation);
        loop obligations
      | Error (retry_operation, failure) ->
        log_attempt_failure ~operation ~retry_operation failure;
        loop (retry_obligation obligations retry_operation)
    in
    let startup_reconciliation_at = Eio.Time.now clock in
    loop
      { flush_retry_at = Some startup_reconciliation_at
      ; sweep_retry_at = Some startup_reconciliation_at
      }
  in
  let routing_retry_loop () =
    Log.BoardLog.info "Board routing retry actor started";
    while true do
      Eio.Stream.take routing_retry_inbox;
      Atomic.set routing_retry_requested false;
      let outcome =
        try
          run_routing_callback
            ~name:"Board routing retry authority"
            routing_retry_callback
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Error
            (Printf.sprintf
               "Board routing retry actor callback raised: %s"
               (Printexc.to_string exn))
      in
      match outcome with
      | Ok () -> ()
      | Error detail ->
        Log.BoardLog.error
          "Board signal outbox retry remains pending: %s"
          detail;
        Eio.Time.sleep clock Env_config.Board.flush_interval_sec;
        request_routing_retry ()
    done
  in
  let loop =
    match actor with
    | Flusher -> flusher_loop
    | Routing_retry -> routing_retry_loop
  in
  Eio.Fiber.fork_daemon ~sw (fun () -> loop ())

(** Claim and start the Board runtime actors against the caller-owned root
    switch.  A losing caller yields and re-reads the typed backend state until
    another caller publishes a live owner or it can claim the transition.  An
    unavailable prior owner is retired by exact switch identity.  There is no
    retry budget or timing policy. *)
let actor_status actors = function
  | Flusher -> actors.flusher
  | Routing_retry -> actors.routing_retry
;;

let with_actor_status actors actor status =
  match actor with
  | Flusher -> { actors with flusher = status }
  | Routing_retry -> { actors with routing_retry = status }
;;

let switch_is_available sw = Option.is_none (Eio.Switch.get_error sw)

(** Switches are opaque allocated capabilities.  Physical equality expresses
    exact capability identity; structural comparison is neither available nor
    meaningful for this ownership check. *)
let actor_status_owned_by sw = function
  | Actor_starting owner
  | Actor_started owner -> owner == sw
  | Actor_stopped -> false
;;

let rec stop_runtime_actor_owned_by ~sw actor =
  let current = Atomic.get backend_state in
  match current with
  | Uninitialized -> false
  | Active (backend, actors) ->
    let status = actor_status actors actor in
    if not (actor_status_owned_by sw status)
    then false
    else
      let stopped_state =
        Active (backend, with_actor_status actors actor Actor_stopped)
      in
      if Atomic.compare_and_set backend_state current stopped_state
      then true
      else stop_runtime_actor_owned_by ~sw actor
;;

let retire_unavailable_actor_owner actor owner =
  if switch_is_available owner
  then false
  else begin
    let _retired = stop_runtime_actor_owned_by ~sw:owner actor in
    true
  end
;;

let start_runtime_actor ~sw ~clock actor =
  let rec loop () =
    let current = Atomic.get backend_state in
    match current with
    | Uninitialized -> Error Backend_uninitialized
    | Active (Jsonl store as backend, actors) ->
      (match actor_status actors actor with
       | Actor_started owner ->
         if retire_unavailable_actor_owner actor owner then loop () else Ok ()
       | Actor_starting owner ->
         if retire_unavailable_actor_owner actor owner
         then loop ()
         else begin
           Eio.Fiber.yield ();
           loop ()
         end
       | Actor_stopped ->
         let starting_actors =
           with_actor_status actors actor (Actor_starting sw)
         in
         let starting_state = Active (backend, starting_actors) in
         if Atomic.compare_and_set backend_state current starting_state
         then begin
           let rollback () =
             stop_runtime_actor_owned_by ~sw actor
           in
           let record outcome =
             Board_metrics_hooks.inc_runtime_actor_start_outcome ~actor ~outcome
           in
           match Eio.Switch.get_error sw with
           | Some exn ->
             let rolled_back = rollback () in
             record Start_failed;
             if rolled_back
             then Error (Switch_unavailable (actor, exn))
             else Error (Backend_replaced_during_start actor)
           | None ->
             (try
                Eio.Switch.on_release sw (fun () ->
                  if stop_runtime_actor_owned_by ~sw actor
                  then
                    Log.BoardLog.info
                      "Board runtime actor stopped with owner switch: actor=%s"
                      (runtime_actor_to_string actor));
                spawn_runtime_actor_on_switch ~sw ~clock store actor;
                let started_state =
                  Active
                    ( backend
                    , with_actor_status starting_actors actor (Actor_started sw) )
                in
                if Atomic.compare_and_set backend_state starting_state started_state
                then begin
                  record Started;
                  Ok ()
                end
                else begin
                  record Start_failed;
                  Error (Backend_replaced_during_start actor)
                end
              with
              | exn ->
                let _rolled_back = rollback () in
                record Start_failed;
                (match exn with
                 | Eio.Cancel.Cancelled _ -> raise exn
                 | _ ->
                   (match Eio.Switch.get_error sw with
                    | Some owner_error ->
                      Error (Switch_unavailable (actor, owner_error))
                    | None -> Error (Actor_spawn_failed (actor, exn)))))
         end
         else begin
           Eio.Fiber.yield ();
           loop ()
         end)
  in
  loop ()

let start_runtime_actors ~sw ~clock =
  let flusher = start_runtime_actor ~sw ~clock Flusher in
  let routing_retry = start_runtime_actor ~sw ~clock Routing_retry in
  match flusher, routing_retry with
  | Ok (), Ok () -> Ok ()
  | Error error, Ok ()
  | Ok (), Error error -> Error (One_actor_start_failed error)
  | Error first, Error second -> Error (Both_actors_start_failed (first, second))


let board_signal_hook :
    (board_signal_event -> (board_signal_delivery, string) result) option Atomic.t
  =
  Atomic.make None
;;

let recover_and_drain_callback :
    routing_callback option Atomic.t
  =
  Atomic.make None
;;

let recover_prepared_callback :
    routing_callback option Atomic.t
  =
  Atomic.make None
;;

let admit_routing_mutation mutation =
  match
    run_routing_callback
      ~name:"Board prepared-event recovery authority"
      recover_prepared_callback
  with
  | Error detail ->
    Error (Board_types.Io_error ("board routing-event recovery failed: " ^ detail))
  | Ok () ->
    with_routing_mutation_lock (fun () ->
      match ensure_no_prepared_routing_mutation () with
      | Error detail -> Error (Board_types.Io_error detail)
      | Ok () -> mutation ())
;;

let set_board_signal_hook hook =
  Atomic.set board_signal_hook (Some hook);
  match Atomic.get backend_state with
  | Active (_, { routing_retry = Actor_started _; _ }) -> request_routing_retry ()
  | Active (_, { routing_retry = (Actor_stopped | Actor_starting _); _ })
  | Uninitialized ->
    (match
       run_routing_callback
         ~name:"Board signal recovery-and-drain authority"
         recover_and_drain_callback
     with
     | Ok () -> ()
     | Error detail ->
       Log.BoardLog.error "Board signal outbox recovery failed: %s" detail)
;;

let deliver_committed_signal event_id =
  if not (claim_routing_delivery event_id)
  then Ok ()
  else
    Fun.protect
      ~finally:(fun () -> release_routing_delivery event_id)
      (fun () ->
        Result.bind (Board_signal_outbox.entries ()) (fun entries ->
      match
        List.find_opt
          (fun (entry : Board_signal_outbox.entry) ->
             String.equal entry.event_id event_id)
          entries
      with
      | None
      | Some { phase = Board_signal_outbox.Delivered _; _ } -> Ok ()
      | Some { phase = Board_signal_outbox.Prepared _; _ } ->
        Error ("Board routing event is not committed: " ^ event_id)
      | Some
          { phase = Board_signal_outbox.Committed { mutation = payload; _ }
          ; _
          } ->
        let signal = Board_signal_command.signal payload in
        let audience = Board_signal_command.audience payload in
          match Atomic.get board_signal_hook with
          | None ->
            Log.BoardLog.info
              "Board routing event remains committed until a hook is installed: event_id=%s"
              event_id;
            Ok ()
          | Some hook ->
            let delivery =
              try hook { event_id; audience; signal } with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn -> Error (Printexc.to_string exn)
            in
            (match delivery with
             | Error detail ->
               Log.BoardLog.error
                 "Board signal hook rejected committed event: event_id=%s error=%s"
                 event_id
                 detail;
               Error detail
             | Ok delivery ->
               let settlement =
                 match delivery with
                 | Atomic_sink_accepted ->
                   Board_signal_outbox.plan_recipients
                     ~event_id
                     ~recipients:[]
                 | Recipient_settlement_complete -> Ok ()
               in
               (match Result.bind settlement (fun () ->
                  Board_signal_outbox.mark_delivered
                    ~event_id
                    ~at:(Time_compat.now ()))
                with
                | Ok () ->
                  (match Board_signal_outbox.compact_terminal () with
                   | Ok () -> Ok ()
                   | Error detail ->
                     Log.BoardLog.error
                       "Board signal outbox terminal compaction failed: event_id=%s error=%s"
                       event_id
                       detail;
                     Error detail)
                | Error detail ->
                  Log.BoardLog.error
                    "Board signal delivery acknowledgement failed: event_id=%s error=%s"
                    event_id
                    detail;
                  Error detail))))
;;

let new_routing_event_id () = Random_id.prefixed ~prefix:"bse-" ~bytes:16

let prepare_routing_event ~event_id mutation =
  Board_signal_outbox.prepare ~event_id ~command:mutation
;;

let commit_routing_event ~event_id value =
  match Board_signal_outbox.commit ~event_id with
  | Error detail ->
    (* The Board mutation has already durably succeeded.  Its Prepared row and
       preassigned entity id are sufficient for deterministic recovery. *)
    Log.BoardLog.error
      "Board mutation committed but routing-event commit failed; recovery remains pending: event_id=%s error=%s"
      event_id
      detail;
    Ok value
  | Ok () -> Ok value
;;

let drain_after_mutation () =
  match Atomic.get backend_state with
  | Active (_, { routing_retry = Actor_started _; _ }) -> request_routing_retry ()
  | Active (_, { routing_retry = (Actor_stopped | Actor_starting _); _ })
  | Uninitialized ->
    (match
       run_routing_callback
         ~name:"Board signal recovery-and-drain authority"
         recover_and_drain_callback
     with
     | Ok () -> ()
     | Error detail ->
       Log.BoardLog.error "Board signal outbox drain remains pending: %s" detail)
;;

let board_sse_hook : (board_sse_event -> unit) option Atomic.t = Atomic.make None

let set_board_sse_hook hook =
  Atomic.set board_sse_hook (Some hook)

let emit_board_sse_event event =
  match Atomic.get board_sse_hook with
  | Some hook -> Safe_ops.protect ~default:() (fun () -> hook event)
  | None -> ()

let is_initialized () =
  match Atomic.get backend_state with
  | Active _ -> true
  | Uninitialized -> false

let init_jsonl () =
  if match Atomic.get backend_state with Active _ -> true | Uninitialized -> false then
    Log.BoardLog.warn "already initialized, ignoring init_jsonl"
  else begin
    let store = Board.global () in
    let backend = Active (Jsonl store, runtime_actors_stopped) in
    if Atomic.compare_and_set backend_state Uninitialized backend then begin
      Log.BoardLog.info "JSONL backend initialized"
    end else
      Log.BoardLog.warn "already initialized concurrently, ignoring init_jsonl"
  end

let reset_for_test () =
  (* Dropping [Active] also drops the runtime-actor state. *)
  Atomic.set backend_state Uninitialized;
  Atomic.set routing_retry_requested false;
  clear_routing_retry_inbox_for_test ();
  Atomic.set board_signal_hook None;
  Atomic.set board_sse_hook None;
  Stdlib.Mutex.protect routing_delivery_claim_mu (fun () ->
    Hashtbl.clear routing_delivery_claims)

let jsonl_forced () =
  match Env_config.Board.backend_opt () with
  | Some Env_config.Board.Jsonl -> true
  | Some (Env_config.Board.Pg | Env_config.Board.Unknown_backend _) | None -> false

let backend () =
  match Atomic.get backend_state with
  | Active (Jsonl _ as backend, _) -> backend
  | Uninitialized ->
      Log.BoardLog.warn "backend() called before server init, auto-initializing JSONL";
      let store = Board.global () in
      let b = Jsonl store in
      let backend_val = Active (b, runtime_actors_stopped) in
      let _ = Atomic.compare_and_set backend_state Uninitialized backend_val in
      match Atomic.get backend_state with
      | Active (Jsonl _ as active_b, _) -> active_b
      | Uninitialized -> b

let sort_posts_in_memory ~sort_by (posts : Board.post list) =
  (* Ranking formulas live in [Board_sort] (single source of truth) so the
     Hot/Trending definitions cannot drift between this in-memory sort and
     [Board_core.list_posts]'s cached default sort. See [Board_sort]. *)
  match sort_by with
  | Hot -> List.sort Board_sort.hot_compare posts
  | Recent ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        Stdlib.Float.compare b.created_at a.created_at) posts
  | Updated ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        Stdlib.Float.compare b.updated_at a.updated_at) posts
  | Trending ->
      List.sort (Board_sort.trending_compare ~now:(Time_compat.now ())) posts
  | Discussed ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        let cmp = Stdlib.Int.compare b.reply_count a.reply_count in
        if cmp <> 0 then cmp else Stdlib.Float.compare b.created_at a.created_at) posts

let normalize_author_filter = function
  | Some raw ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then None else Some (String.lowercase_ascii trimmed)
  | None -> None

let agent_matches_author_filter ~needle (agent_id : Board.Agent_id.t) =
  let author = Board.Agent_id.to_string agent_id |> String.lowercase_ascii in
  String_util.contains_substring author needle

let matching_post_ids_for_comment_author_filter ~needle (comments : Board.comment list) =
  let matches = Hashtbl.create 64 in
  List.iter
    (fun (comment : Board.comment) ->
      if agent_matches_author_filter ~needle comment.author then
        Hashtbl.replace matches (Board.Post_id.to_string comment.post_id) true)
    comments;
  matches

let emit_post_created_sse (post : Board.post) =
  let pid = Board.Post_id.to_string post.id in
  let auth = Board.Agent_id.to_string post.author in
  emit_board_sse_event
    (Post_created
       { post_id = pid; author = auth; title = post.title;
         content = post.content; post_kind = post.post_kind;
         hearth = post.hearth })
;;

let create_post ~author ~content ?title ?body ~post_kind ?meta_json
    ?visibility ?ttl_hours ?hearth ?thread_id ?origin () =
  match backend () with
  | Jsonl store ->
    let mutation_result =
      admit_routing_mutation (fun () ->
        let event_id = new_routing_event_id () in
        let post_id = Board.Post_id.generate () in
        match
          Board.prepare_post
            store
            ~post_id
            ~author
            ~content
            ?title
            ?body
            ~post_kind
            ?meta_json
            ?visibility
            ?ttl_hours
            ?hearth
            ?thread_id
            ?origin
            ()
        with
        | Error _ as error -> error
        | Ok post ->
          (match Board_signal_command.post post with
           | Error _ as error -> error
           | Ok command ->
          (match
             prepare_routing_event ~event_id command
           with
           | Error detail ->
             Error
               (Board_types.Io_error ("board routing-event prepare failed: " ^ detail))
           | Ok () ->
             (match Board.apply_prepared_post store post with
              | Error board_error -> Error board_error
              | Ok
                  (Board.Applied applied
                  | Board.Already_applied applied
                  | Board.Repaired_partial_apply applied) ->
                commit_routing_event ~event_id applied))))
    in
    (match mutation_result with
     | Error _ as error -> error
     | Ok post ->
       emit_post_created_sse post;
       drain_after_mutation ();
       Ok post)

let update_post ~post_id ~editor ~content ?title ?body ?new_author () =
  match backend () with
  | Jsonl store ->
    admit_routing_mutation (fun () ->
      reject_referenced_post_mutation ~operation:"edit" ~post_id (fun () ->
        Board.update_post_with_outcome
          store
          ~post_id
          ~editor
          ~content
          ?title
          ?body
          ?new_author
          ()))

let get_post ~post_id =
  match backend () with
  | Jsonl store -> Board.get_post store ~post_id

let list_posts ?(visibility_filter = None) ?hearth ?author_filter ?exclude_author_filter
    ?post_kind_filter
    ?(sort_by = Hot) ?(exclude_system = false) ?(exclude_automation = false)
    ?(limit = 50) () =
  let author_filter = normalize_author_filter author_filter in
  let exclude_author_filter = normalize_author_filter exclude_author_filter in
  let apply_visibility_and_hearth_filters posts =
    let posts =
      match visibility_filter with
      | Some visibility ->
          List.filter (fun (post : Board.post) -> (=) post.visibility visibility) posts
      | None -> posts
    in
    match hearth with
    | Some hearth_name ->
        let hearth_name = String.lowercase_ascii (String.trim hearth_name) in
        List.filter (fun (post : Board.post) -> Option.equal String.equal post.hearth (Some hearth_name)) posts
    | None -> posts
  in
  let apply_post_kind_filter posts =
    posts
    |> List.filter (fun (p : Board.post) ->
           Board.post_matches_filters ~exclude_system ~exclude_automation p)
    |> (match post_kind_filter with
       | Some kind ->
           List.filter
             (fun (p : Board.post) -> (=) (Board.classify_post_kind p) kind)
       | None -> Stdlib.Fun.id)
  in
  match backend () with
  | Jsonl store ->
      let needs_full_scan =
        Option.is_some author_filter
        || Option.is_some exclude_author_filter
        ||
        match sort_by with
        | Hot -> false
        | Trending | Recent | Updated | Discussed -> true
      in
      let fetch_limit = if needs_full_scan then Stdlib.max_int else max limit 500 in
      let posts =
        if needs_full_scan then
          Board.search_posts store ~predicate:(fun _ -> true) ~limit:fetch_limit
        else
          Board.list_posts store ~visibility_filter ?hearth ~limit:fetch_limit ()
      in
      let sorted =
        posts
        |> apply_visibility_and_hearth_filters
        |> sort_posts_in_memory ~sort_by
      in
      let filtered = apply_post_kind_filter sorted in
      let filtered =
        match author_filter with
        | None -> filtered
        | Some needle ->
            let matching_comment_post_ids =
              Board.list_comments store ~limit:Stdlib.max_int ()
              |> matching_post_ids_for_comment_author_filter ~needle
            in
            List.filter
              (fun (post : Board.post) ->
                agent_matches_author_filter ~needle post.author
                || Hashtbl.mem matching_comment_post_ids
                     (Board.Post_id.to_string post.id))
              filtered
      in
      (* Exclude posts by author (post author only, not comment author).
         Unlike the positive author_filter which matches comment authors too,
         exclusion is post-author-only: hiding agent X should not remove
         agent Y's post just because X commented on it. *)
      let filtered =
        match exclude_author_filter with
        | None -> filtered
        | Some needle ->
            List.filter
              (fun (post : Board.post) ->
                not (agent_matches_author_filter ~needle post.author))
              filtered
      in
      Board.take limit filtered

let current_post_cursor () =
  match backend () with
  | Jsonl store -> Board.current_post_cursor store

let get_comments ~post_id =
  match backend () with
  | Jsonl store -> Board.get_comments store ~post_id

let get_post_and_comments ~post_id ?comment_offset ?comment_limit () =
  match backend () with
  | Jsonl store -> Board.get_post_and_comments store ~post_id ?comment_offset ?comment_limit ()

let add_comment ~post_id ~author ~content ?parent_id
    ?(ttl_hours = Board.Limits.default_ttl_hours) () =
  match backend () with
  | Jsonl store ->
    let mutation_result =
      admit_routing_mutation (fun () ->
        let event_id = new_routing_event_id () in
        let comment_id = Board.Comment_id.generate () in
        match
          Board.prepare_comment
            store
            ~comment_id
            ~post_id
            ~author
            ~content
            ?parent_id
            ~ttl_hours
            ()
        with
        | Error _ as error -> error
        | Ok (comment, post) ->
          (match Board.get_comments store ~post_id with
           | Error _ as error -> error
           | Ok prior_comments ->
          (match
             Board_signal_command.comment
               ~post
               ~comments:prior_comments
               comment
           with
           | Error _ as error -> error
           | Ok prepared ->
          (match prepare_routing_event ~event_id prepared with
           | Error detail ->
             Error
               (Board_types.Io_error ("board routing-event prepare failed: " ^ detail))
           | Ok () ->
             (match
                Board.apply_prepared_comment
                  store
                  ~parent_reply_count_before:post.reply_count
                  comment
              with
              | Error board_error -> Error board_error
              | Ok
                  (Board.Applied applied
                  | Board.Already_applied applied
                  | Board.Repaired_partial_apply applied) ->
                commit_routing_event ~event_id applied)))))
    in
    (match mutation_result with
     | Error _ as error -> error
     | Ok comment ->
       emit_board_sse_event
         (Comment_added
            { post_id
            ; comment_id = Board.Comment_id.to_string comment.id
            ; author = Board.Agent_id.to_string comment.author
            });
       drain_after_mutation ();
       Ok comment)

let current_vote_for_post ~voter ~post_id =
  match backend () with
  | Jsonl store -> Board.current_vote_for_post store ~voter ~post_id

let vote ~voter ~post_id ~direction =
  let result =
    match backend () with
    | Jsonl store -> Board.vote store ~voter ~post_id ~direction
  in
  (match result with
   | Ok _score ->
       emit_board_sse_event
         (Post_voted { post_id; voter; direction })
   | Error e ->
       (match e with
        | Board_types.Already_voted _ ->
            Log.BoardLog.debug
        | Board_types.Post_not_found _ | Board_types.Comment_not_found _ ->
            Log.BoardLog.info
        | _ -> Log.BoardLog.warn)
         "board vote failed: post_id=%s voter=%s: %s"
         post_id voter (Board_types.show_board_error e));
  result

let current_vote_for_comment ~voter ~comment_id =
  match backend () with
  | Jsonl store -> Board.current_vote_for_comment store ~voter ~comment_id

let vote_comment ~voter ~comment_id ~direction =
  let result =
    match backend () with
    | Jsonl store -> Board.vote_comment store ~voter ~comment_id ~direction
  in
  (match result with
   | Ok _score ->
       emit_board_sse_event
         (Comment_voted { comment_id; voter; direction })
   | Error e ->
       (match e with
        | Board_types.Already_voted _ ->
            Log.BoardLog.debug
        | Board_types.Post_not_found _ | Board_types.Comment_not_found _ ->
            Log.BoardLog.info
        | _ -> Log.BoardLog.warn)
         "board vote_comment failed: comment_id=%s voter=%s: %s"
         comment_id voter (Board_types.show_board_error e));
  result

let post_for_reaction_target store ~target_type ~target_id =
  match target_type with
  | Board.Reaction_post -> Board.get_post store ~post_id:target_id
  | Board.Reaction_comment ->
      (match Board.get_comment store ~comment_id:target_id with
       | Error _ as err -> err
       | Ok comment ->
           let post_id = Board.Post_id.to_string comment.post_id in
           Board.get_post store ~post_id)

let toggle_reaction ~target_type ~target_id ~user_id ~emoji =
  let mutation_result =
    match backend () with
    | Jsonl store ->
      admit_routing_mutation (fun () ->
        match
          Board.prepare_reaction_toggle store ~target_type ~target_id ~user_id ~emoji
        with
        | Error _ as error -> error
        | Ok prepared ->
          let event_id = new_routing_event_id () in
          (match post_for_reaction_target store ~target_type ~target_id with
           | Error _ as error -> error
           | Ok post ->
             (match
                Board.get_comments
                  store
                  ~post_id:(Board.Post_id.to_string post.id)
              with
              | Error _ as error -> error
              | Ok comments ->
             (match
                Board_signal_command.reaction
                  ~post
                  ~comments
                  ~target_type
                  ~target_id
                  ~user_id:prepared.user_id
                  ~emoji:prepared.emoji
                  ~reacted:prepared.reacted
                  ~created_at:prepared.created_at
              with
               | Error _ as error -> error
              | Ok mutation ->
             (match prepare_routing_event ~event_id mutation with
              | Error detail ->
                Error
                  (Board_types.Io_error
                     ("board routing-event prepare failed: " ^ detail))
              | Ok () ->
                (match
                   Board.set_reaction
                     store
                     ~target_type
                     ~target_id
                     ~user_id:prepared.user_id
                     ~emoji:prepared.emoji
                     ~reacted:prepared.reacted
                     ~created_at:prepared.created_at
                 with
                 | Error board_error -> Error board_error
                 | Ok toggled -> commit_routing_event ~event_id toggled))))))
  in
  let result = mutation_result in
  (match result with
   | Ok toggled ->
       emit_board_sse_event
         (Reaction_changed
            {
              target_type;
              target_id;
              user_id = toggled.user_id;
              emoji = toggled.emoji;
              reacted = toggled.reacted;
            });
       drain_after_mutation ()
   | Error e ->
       (match e with
        | Board_types.Post_not_found _ | Board_types.Comment_not_found _ ->
            Log.BoardLog.info
        | _ -> Log.BoardLog.warn)
         "board reaction failed: target=%s:%s user=%s emoji=%s: %s"
         (Board.reaction_target_type_to_string target_type)
         target_id user_id emoji (Board_types.show_board_error e));
  result

let collect_result errors = function
  | Ok () -> errors
  | Error detail -> detail :: errors
;;

let recover_prepared_entries store entries =
  let rec replay = function
    | [] -> Ok ()
    | (entry : Board_signal_outbox.entry) :: successors ->
      (match entry.phase with
       | Board_signal_outbox.Committed _ | Board_signal_outbox.Delivered _ ->
         replay successors
       | Board_signal_outbox.Prepared command ->
         let recovery =
           Result.bind (Board_signal_command.apply store command) (fun () ->
             Board_signal_outbox.commit ~event_id:entry.event_id)
         in
         (match recovery with
          | Ok () -> replay successors
          | Error detail ->
            Error
              (Printf.sprintf
                 "Board routing recovery stopped at event_id=%s; \
                  successors_not_attempted=%d; error=%s"
                 entry.event_id
                 (List.length successors)
                 detail)))
  in
  replay entries
;;

let deliver_committed_entries entries =
  List.fold_left
    (fun errors (entry : Board_signal_outbox.entry) ->
       match entry.phase with
       | Board_signal_outbox.Committed _ ->
         collect_result errors (deliver_committed_signal entry.event_id)
       | Board_signal_outbox.Prepared _
       | Board_signal_outbox.Delivered _ -> errors)
    []
    entries
;;

let recover_prepared_board_signal_outbox () =
  with_routing_mutation_lock (fun () ->
    let store = match backend () with Jsonl store -> store in
    match Board_signal_outbox.entries () with
    | Error detail -> Error detail
    | Ok initial_entries ->
      recover_prepared_entries store initial_entries)
;;

let recover_and_drain_board_signal_outbox () =
  let recovery_errors =
    run_routing_callback
      ~name:"Board prepared-event recovery authority"
      recover_prepared_callback
  in
  match recovery_errors with
  | Error _ as error -> error
  | Ok () ->
    (match Board_signal_outbox.entries () with
     | Error detail -> Error detail
     | Ok recovered_entries ->
       let delivery_errors = deliver_committed_entries recovered_entries in
       (match delivery_errors with
        | [] -> Board_signal_outbox.compact_terminal ()
        | errors -> Error (String.concat "; " (List.rev errors))))
;;

let () =
  Atomic.set recover_prepared_callback (Some recover_prepared_board_signal_outbox);
  Atomic.set recover_and_drain_callback (Some recover_and_drain_board_signal_outbox);
  Atomic.set routing_retry_callback (Some recover_and_drain_board_signal_outbox)
;;

let list_reactions ~target_type ~target_id ?user_id () =
  match backend () with
  | Jsonl store -> Board.list_reactions store ~target_type ~target_id ?user_id ()

let list_reactions_batch ~targets ?user_id () =
  match backend () with
  | Jsonl store -> Board.list_reactions_batch store ~targets ?user_id ()

let stats () =
  match backend () with
  | Jsonl store -> Board.stats store

let list_comments ?(limit = 1000) () =
  match backend () with
  | Jsonl store -> Board.list_comments store ~limit ()

let list_hearths () =
  match backend () with
  | Jsonl store -> Board.list_hearths store

let set_thread_id ~post_id ~thread_id =
  match backend () with
  | Jsonl store ->
    with_routing_mutation_lock (fun () ->
      reject_referenced_post_mutation ~operation:"thread update" ~post_id (fun () ->
        Board.set_thread_id store ~post_id ~thread_id))

let set_pinned ~post_id ~pinned =
  match backend () with
  | Jsonl store -> Board.set_pinned store ~post_id ~pinned

let delete_post ~post_id =
  match backend () with
  | Jsonl store ->
    with_routing_mutation_lock (fun () ->
      reject_referenced_post_mutation ~operation:"deletion" ~post_id (fun () ->
        Board.delete_post store ~post_id))

let search ~query ~limit =
  match backend () with
  | Jsonl store ->
      let query_lower = String.lowercase_ascii query in
      let matches_str s =
        String_util.contains_substring (String.lowercase_ascii s) query_lower
      in
      let predicate (p : Board.post) =
        matches_str p.title
        || matches_str p.content
        || matches_str (Board.Agent_id.to_string p.author)
        || (match p.hearth with Some h -> matches_str h | None -> false)
      in
      Board.search_posts store ~predicate ~limit

let flush () =
  match Atomic.get backend_state with
  | Active (Jsonl store, _) -> Board.flush_dirty store
  | Uninitialized -> Ok ()

let sweep () =
  match backend () with
  | Jsonl store ->
    with_routing_mutation_lock (fun () ->
      match prepared_routing_references () with
      | Error detail -> Error detail
      | Ok references ->
        Result.map_error
          Board.show_board_error
          (Board.sweep_and_flush
            ~protected_post_ids:references.post_ids
            ~protected_comment_ids:references.comment_ids
            store))

let get_all_karma () =
  match backend () with
  | Jsonl store -> Board.get_all_karma store

let get_agent_karma ~agent_name =
  match backend () with
  | Jsonl store -> Board.get_agent_karma store ~agent_name

let karma_score_for_direction = Board.karma_score_for_direction

let get_karma_ledger ?agent ?(limit = max_int) () =
  let events =
    match backend () with
    | Jsonl store -> Board.build_karma_ledger store
  in
  let filtered =
    match agent with
    | None -> events
    | Some name ->
        List.filter (fun (e : Board.karma_event) -> String.equal e.recipient name) events
  in
  Board.take limit filtered

let post_to_yojson_with_karma (p : Board.post) ~author_karma =
  Board.post_to_yojson_with_karma p ~author_karma

let backend_name () =
  match Atomic.get backend_state with
  | Active (Jsonl _, _) -> "jsonl"
  | Uninitialized -> "uninitialized"

(* AI curation delegate — thin wrappers around Board_curation *)

let submit_curation_snapshot ~submitted_by ?summary ~ordering ~highlights
    ?(tag_suggestions = []) ?(answer_matches = []) ~rationale
    ?(provenance = `Assoc []) () =
  let snap : Board_curation.curation_snapshot = {
    id = Board_curation.generate_id ();
    generated_at = Time_compat.now ();
    submitted_by;
    summary;
    ordering;
    highlights;
    tag_suggestions;
    answer_matches;
    rationale;
    provenance;
  } in
  Board_curation.submit_snapshot snap;
  snap

let latest_curation_snapshot () =
  Board_curation.latest_snapshot ()

(** {1 SubBoard operations} *)

let create_sub_board ~slug ~name ~description ~owner ?members ?access () =
  match backend () with
  | Jsonl store ->
      Board.create_sub_board store ~slug ~name ~description ~owner ?members ?access ()

let get_sub_board ~sub_board_id =
  match backend () with
  | Jsonl store -> Board.get_sub_board store ~sub_board_id

let list_sub_boards () =
  match backend () with
  | Jsonl store -> Board.list_sub_boards store

let delete_sub_board ~sub_board_id =
  match backend () with
  | Jsonl store -> Board.delete_sub_board store ~sub_board_id

let update_sub_board ~sub_board_id ?name ?description ?members ?access () =
  match backend () with
  | Jsonl store -> Board.update_sub_board store ~sub_board_id ?name ?description ?members ?access ()
