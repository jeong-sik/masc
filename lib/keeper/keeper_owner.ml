let mailbox_capacity = 128

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Operation_rejected of Keeper_chat_operation_store.error
  | Store_unavailable of string
  | Owner_closed

type turn_start =
  | Started of turn_handle
  | Busy of { running_operation_id : string }

and turn_terminal =
  | Turn_succeeded
  | Turn_failed of string
  | Turn_cancelled

and turn_handle =
  { operation_id : string
  ; terminal : turn_terminal Eio.Promise.t
  }

type completion =
  { handle : turn_handle
  ; resolve : turn_terminal Eio.Promise.u
  ; settled : bool Atomic.t
  }

type turn_request =
  { operation_id : string
  ; run : Eio.Switch.t -> unit
  ; completion : completion
  }

type child_outcome =
  | Child_succeeded
  | Child_failed of string
  | Child_cancelled

type _ command =
  | Exact_projection :
      (Keeper_owner_reducer.projection, error) result command
  | Apply_meta :
      Keeper_owner_reducer.meta_command
      -> (Keeper_meta_contract.keeper_meta option, error) result command
  | Submit_operation :
      { operation_id : string
      ; input : Keeper_chat_operation_store.input
      }
      -> (Keeper_chat_operation_store.submit_result, error) result command
  | Lookup_operation :
      { operation_id : string }
      -> (Keeper_chat_operation_store.operation, error) result command
  | List_queued_operations :
      { after_sequence : int64 option
      ; limit : int
      }
      -> (Keeper_chat_operation_store.operation list, error) result command
  | Edit_operation :
      { operation_id : string
      ; input : Keeper_chat_operation_store.edit_input
      }
      -> (Keeper_chat_operation_store.operation, error) result command
  | Move_operation_to_end :
      { operation_id : string }
      -> (Keeper_chat_operation_store.operation, error) result command
  | Cancel_operation :
      { operation_id : string
      ; completed_at : float
      }
      -> (Keeper_chat_operation_store.operation, error) result command
  | Start_next_operation :
      { started_at : float }
      -> (Keeper_chat_operation_store.operation option, error) result command
  | Succeed_operation :
      { operation_id : string
      ; completed_at : float
      ; outcome_ref : string
      }
      -> (Keeper_chat_operation_store.operation, error) result command
  | Fail_operation :
      { operation_id : string
      ; completed_at : float
      ; kind : Keeper_chat_operation_store.failure_kind
      ; detail : string
      ; outcome_ref : string option
      }
      -> (Keeper_chat_operation_store.operation, error) result command
  | Start_turn : turn_request -> (turn_start, error) result command
  | Child_finished :
      { operation_id : string
      ; outcome : child_outcome
      }
      -> (unit, error) result command
  | Begin_stopping : (unit, error) result command

type packed_command =
  | Command : 'response command * 'response Eio.Promise.u -> packed_command

type t =
  { mailbox : packed_command Eio.Stream.t
  ; projection : Keeper_owner_reducer.projection Atomic.t
  ; closed : bool Atomic.t
  ; closed_p : unit Eio.Promise.t
  ; active_completion : completion option Atomic.t
  ; startup_interrupted_count : int Atomic.t
  }

type operation_store_state =
  | Operations_disabled_for_testing
  | Operations_available of Keeper_chat_operation_store.t
  | Operations_unavailable of
      { store : Keeper_chat_operation_store.t
      ; detail : string
      }

type operation_store_config =
  | No_operation_store_for_testing
  | Open_operation_store of { base_path : string }

let error_to_string = function
  | Reducer_rejected error -> Keeper_owner_reducer.error_to_string error
  | Operation_rejected error -> Keeper_chat_operation_store.error_to_string error
  | Store_unavailable detail -> "keeper owner store unavailable: " ^ detail
  | Owner_closed -> "keeper owner is closed"
;;

let projection t = Atomic.get t.projection

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
      Eio.Fiber.first
        (fun () -> Eio.Promise.await response)
        (fun () ->
           Eio.Promise.await t.closed_p;
           Error Owner_closed))
;;

let settle completion terminal =
  if Atomic.compare_and_set completion.settled false true
  then Eio.Promise.resolve completion.resolve terminal
;;

let settle_active t operation_id terminal =
  let current = Atomic.get t.active_completion in
  match current with
  | Some completion when String.equal completion.handle.operation_id operation_id ->
    if Atomic.compare_and_set t.active_completion current None
    then settle completion terminal
  | Some _ | None -> ()
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

let publish_effect t = function
  | Keeper_owner_reducer.Publish_projection projection ->
    Atomic.set t.projection projection
  | Start_turn_child _ -> ()
;;

let apply_transition t store old_state transition =
  match commit store transition with
  | Error error -> Error (old_state, error)
  | Ok state ->
    List.iter (publish_effect t) transition.effects;
    Ok state
;;

let operation_error = function
  | Keeper_chat_operation_store.Store_unavailable detail -> Store_unavailable detail
  | error -> Operation_rejected error
;;

let run_operation_store state operation =
  match state with
  | Operations_disabled_for_testing ->
    state, Error (Store_unavailable "chat operation store is disabled in this owner test")
  | Operations_unavailable { detail; _ } -> state, Error (Store_unavailable detail)
  | Operations_available store ->
    let result =
      try Eio_guard.run_in_systhread (fun () -> operation store) with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Error
          (Keeper_chat_operation_store.Store_unavailable
             ("chat operation system-thread call failed: " ^ Printexc.to_string exn))
    in
    (match result with
     | Error (Keeper_chat_operation_store.Store_unavailable detail as error) ->
       Operations_unavailable { store; detail }, Error (operation_error error)
     | Error error -> state, Error (operation_error error)
     | Ok value -> state, Ok value)
;;

let mutation_allowed state =
  if (Keeper_owner_reducer.projection state).stopping
  then Error (Reducer_rejected Keeper_owner_reducer.Owner_stopping)
  else Ok ()
;;

let initialize_operation_store ~keeper_name = function
  | No_operation_store_for_testing -> Ok (Operations_disabled_for_testing, 0)
  | Open_operation_store { base_path } ->
    Eio_guard.run_in_systhread (fun () ->
      match Keeper_chat_operation_store.open_ ~base_path ~keeper_name with
      | Error error -> Error (operation_error error)
      | Ok store ->
        (match
           Keeper_chat_operation_store.settle_interrupted
             store
             ~completed_at:(Unix.gettimeofday ())
         with
         | Ok interrupted_count -> Ok (Operations_available store, interrupted_count)
         | Error error ->
           let close_result = Keeper_chat_operation_store.close store in
           let detail =
             match close_result with
             | Ok () -> Keeper_chat_operation_store.error_to_string error
             | Error close_error ->
               Keeper_chat_operation_store.error_to_string error
               ^ "; "
               ^ Keeper_chat_operation_store.error_to_string close_error
           in
           Error (Store_unavailable detail)))
;;

let close_operation_store = function
  | Operations_disabled_for_testing -> ()
  | Operations_available store | Operations_unavailable { store; _ } ->
    (match
       Eio.Cancel.protect (fun () ->
         Eio_guard.run_in_systhread (fun () -> Keeper_chat_operation_store.close store))
     with
     | Ok () -> ()
     | Error error ->
       Log.Keeper.error
         "keeper_owner: operation store close failed error=%s"
         (Keeper_chat_operation_store.error_to_string error))
;;

let transition_starts_child transition operation_id =
  List.exists
    (function
      | Keeper_owner_reducer.Start_turn_child { operation_id = effect_operation_id } ->
        String.equal effect_operation_id operation_id
      | Publish_projection _ -> false)
    transition.Keeper_owner_reducer.effects
;;

let notify_child_finished t ~operation_id outcome =
  match request t (Child_finished { operation_id; outcome }) with
  | Ok () -> ()
  | Error Owner_closed -> ()
  | Error (Reducer_rejected _ | Operation_rejected _ | Store_unavailable _) -> ()
;;

let run_child t request =
  let outcome =
    match Eio.Switch.run (fun turn_sw -> request.run turn_sw) with
    | () -> Child_succeeded
    | exception Eio.Cancel.Cancelled _ -> Child_cancelled
    | exception exn -> Child_failed (Printexc.to_string exn)
  in
  notify_child_finished t ~operation_id:request.operation_id outcome
;;

let log_child_failure operation_id = function
  | Child_succeeded -> ()
  | Child_cancelled ->
    Log.Keeper.info "keeper_owner: child turn cancelled operation_id=%s" operation_id
  | Child_failed detail ->
    Log.Keeper.error
      "keeper_owner: child turn failed operation_id=%s error=%s"
      operation_id
      detail
;;

let start_internal ~sw ~store ~operation_store_config ~keeper_name ~initial_meta =
  match Keeper_owner_reducer.create ~keeper_name initial_meta with
  | Error error -> Error (Reducer_rejected error)
  | Ok initial_state ->
  let closed_p, resolve_closed = Eio.Promise.create () in
  let initialized, resolve_initialized = Eio.Promise.create () in
  let t =
    { mailbox = Eio.Stream.create mailbox_capacity
    ; projection = Atomic.make (Keeper_owner_reducer.projection initial_state)
    ; closed = Atomic.make false
    ; closed_p
    ; active_completion = Atomic.make None
    ; startup_interrupted_count = Atomic.make 0
    }
  in
  Eio.Switch.on_release sw (fun () ->
    Atomic.set t.closed true;
    ignore (Eio.Promise.try_resolve resolve_closed () : bool);
    Option.iter (fun completion -> settle completion Turn_cancelled)
      (Atomic.exchange t.active_completion None);
    let projection = Atomic.get t.projection in
    Atomic.set t.projection { projection with stopping = true });
  Eio.Fiber.fork_daemon ~sw (fun () ->
    match initialize_operation_store ~keeper_name operation_store_config with
    | Error error ->
      Atomic.set t.closed true;
      ignore (Eio.Promise.try_resolve resolve_closed () : bool);
      Eio.Promise.resolve resolve_initialized (Error error);
      `Stop_daemon
    | Ok (initial_operation_store, interrupted_count) ->
      Atomic.set t.startup_interrupted_count interrupted_count;
      Eio.Promise.resolve resolve_initialized (Ok ());
      Fun.protect
        ~finally:(fun () -> close_operation_store initial_operation_store)
        (fun () -> Eio.Switch.run (fun child_sw ->
      let respond_operation operation_store resolve operation =
        let operation_store, result = run_operation_store operation_store operation in
        Eio.Promise.resolve resolve result;
        operation_store
      in
      let reject_mutation state operation_store resolve operation =
        match mutation_allowed state with
        | Error error ->
          Eio.Promise.resolve resolve (Error error);
          operation_store
        | Ok () -> respond_operation operation_store resolve operation
      in
      let rec loop state operation_store =
        match Eio.Stream.take t.mailbox with
        | Command (Exact_projection, resolve) ->
          Eio.Promise.resolve resolve (Ok (Keeper_owner_reducer.projection state));
          loop state operation_store
        | Command (Apply_meta command, resolve) ->
          (match Keeper_owner_reducer.apply_meta state command with
           | Error error ->
             Eio.Promise.resolve resolve (Error (Reducer_rejected error));
             loop state operation_store
           | Ok transition ->
             (match apply_transition t store state transition with
              | Error (state, error) ->
                Eio.Promise.resolve resolve (Error error);
                loop state operation_store
              | Ok state ->
                Eio.Promise.resolve
                  resolve
                  (Ok (Keeper_owner_reducer.projection state).meta);
                loop state operation_store))
        | Command (Submit_operation { operation_id; input }, resolve) ->
          let operation_store =
            reject_mutation state operation_store resolve (fun store ->
              Keeper_chat_operation_store.submit store ~operation_id input)
          in
          loop state operation_store
        | Command (Lookup_operation { operation_id }, resolve) ->
          let operation_store =
            respond_operation operation_store resolve (fun store ->
              Keeper_chat_operation_store.lookup store ~operation_id)
          in
          loop state operation_store
        | Command (List_queued_operations { after_sequence; limit }, resolve) ->
          let operation_store =
            respond_operation operation_store resolve (fun store ->
              Keeper_chat_operation_store.list_queued store ~after_sequence ~limit)
          in
          loop state operation_store
        | Command (Edit_operation { operation_id; input }, resolve) ->
          let operation_store =
            reject_mutation state operation_store resolve (fun store ->
              Keeper_chat_operation_store.edit store ~operation_id input)
          in
          loop state operation_store
        | Command (Move_operation_to_end { operation_id }, resolve) ->
          let operation_store =
            reject_mutation state operation_store resolve (fun store ->
              Keeper_chat_operation_store.move_to_end store ~operation_id)
          in
          loop state operation_store
        | Command (Cancel_operation { operation_id; completed_at }, resolve) ->
          let operation_store =
            reject_mutation state operation_store resolve (fun store ->
              Keeper_chat_operation_store.cancel store ~operation_id ~completed_at)
          in
          loop state operation_store
        | Command (Start_next_operation { started_at }, resolve) ->
          let operation_store =
            reject_mutation state operation_store resolve (fun store ->
              Keeper_chat_operation_store.start_next store ~started_at)
          in
          loop state operation_store
        | Command
            (Succeed_operation { operation_id; completed_at; outcome_ref }, resolve) ->
          let operation_store =
            reject_mutation state operation_store resolve (fun store ->
              Keeper_chat_operation_store.succeed
                store
                ~operation_id
                ~completed_at
                ~outcome_ref)
          in
          loop state operation_store
        | Command
            ( Fail_operation
                { operation_id; completed_at; kind; detail; outcome_ref }
            , resolve ) ->
          let operation_store =
            reject_mutation state operation_store resolve (fun store ->
              Keeper_chat_operation_store.fail
                store
                ~operation_id
                ~completed_at
                ~kind
                ~detail
                ~outcome_ref)
          in
          loop state operation_store
        | Command (Start_turn request, resolve) ->
          (match Keeper_owner_reducer.begin_turn state ~operation_id:request.operation_id with
           | Error (Turn_already_running running_operation_id) ->
             Eio.Promise.resolve resolve (Ok (Busy { running_operation_id }));
             loop state operation_store
           | Error error ->
             Eio.Promise.resolve resolve (Error (Reducer_rejected error));
             loop state operation_store
           | Ok transition ->
             (match apply_transition t store state transition with
              | Error (state, error) ->
                Eio.Promise.resolve resolve (Error error);
                loop state operation_store
              | Ok state ->
                Atomic.set t.active_completion (Some request.completion);
                Eio.Promise.resolve resolve (Ok (Started request.completion.handle));
                if transition_starts_child transition request.operation_id
                then Eio.Fiber.fork ~sw:child_sw (fun () -> run_child t request);
                loop state operation_store))
        | Command (Child_finished { operation_id; outcome }, resolve) ->
          log_child_failure operation_id outcome;
          (match Keeper_owner_reducer.finish_turn state ~operation_id with
           | Error error ->
             let detail = Keeper_owner_reducer.error_to_string error in
             Log.Keeper.error
               "keeper_owner: rejected child completion operation_id=%s error=%s"
               operation_id
               detail;
             settle_active t operation_id (Turn_failed detail);
             Eio.Promise.resolve resolve (Ok ());
             loop state operation_store
           | Ok transition ->
             (match apply_transition t store state transition with
              | Error (state, error) ->
                Log.Keeper.error
                  "keeper_owner: child completion projection failed operation_id=%s error=%s"
                  operation_id
                  (error_to_string error);
                Eio.Promise.resolve resolve (Ok ());
                loop state operation_store
              | Ok state ->
                let terminal =
                  match outcome with
                  | Child_succeeded -> Turn_succeeded
                  | Child_failed detail -> Turn_failed detail
                  | Child_cancelled -> Turn_cancelled
                in
                settle_active t operation_id terminal;
                Eio.Promise.resolve resolve (Ok ());
                loop state operation_store))
        | Command (Begin_stopping, resolve) ->
          let transition = Keeper_owner_reducer.begin_stopping state in
          (match apply_transition t store state transition with
           | Error (state, error) ->
             Eio.Promise.resolve resolve (Error error);
             loop state operation_store
           | Ok state ->
             Eio.Promise.resolve resolve (Ok ());
             loop state operation_store)
      in
      loop initial_state initial_operation_store)));
  (match Eio.Promise.await initialized with
   | Ok () -> Ok t
   | Error error -> Error error)
;;

let start ~sw ~store ~base_path ~keeper_name ~initial_meta =
  start_internal
    ~sw
    ~store
    ~operation_store_config:(Open_operation_store { base_path })
    ~keeper_name
    ~initial_meta
;;

let exact_projection t = request t Exact_projection
let apply_meta t command = request t (Apply_meta command)
let submit_operation t ~operation_id input =
  request t (Submit_operation { operation_id; input })
;;

let lookup_operation t ~operation_id = request t (Lookup_operation { operation_id })

let list_queued_operations t ~after_sequence ~limit =
  request t (List_queued_operations { after_sequence; limit })
;;

let edit_operation t ~operation_id input =
  request t (Edit_operation { operation_id; input })
;;

let move_operation_to_end t ~operation_id =
  request t (Move_operation_to_end { operation_id })
;;

let cancel_operation t ~operation_id ~completed_at =
  request t (Cancel_operation { operation_id; completed_at })
;;

let start_next_operation t ~started_at = request t (Start_next_operation { started_at })

let succeed_operation t ~operation_id ~completed_at ~outcome_ref =
  request t (Succeed_operation { operation_id; completed_at; outcome_ref })
;;

let fail_operation t ~operation_id ~completed_at ~kind ~detail ~outcome_ref =
  request
    t
    (Fail_operation { operation_id; completed_at; kind; detail; outcome_ref })
;;

let start_turn t ~operation_id ~run =
  let terminal, resolve = Eio.Promise.create () in
  let handle = { operation_id; terminal } in
  let completion = { handle; resolve; settled = Atomic.make false } in
  request t (Start_turn { operation_id; run; completion })
;;

let await_turn handle = Eio.Promise.await handle.terminal
let turn_handle_operation_id (handle : turn_handle) = handle.operation_id
let begin_stopping t = request t Begin_stopping

module For_testing = struct
  let start ~sw ~store ~keeper_name ~initial_meta =
    start_internal
      ~sw
      ~store
      ~operation_store_config:No_operation_store_for_testing
      ~keeper_name
      ~initial_meta
  ;;

  let mailbox_depth t = Eio.Stream.length t.mailbox
  let startup_interrupted_count t = Atomic.get t.startup_interrupted_count
end
