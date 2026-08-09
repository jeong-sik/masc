let mailbox_capacity = 128

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
  }

type operation_acceptance =
  { operation : Chat_operation.t
  ; existing : bool
  ; queued_count : int
  }

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Operation_rejected of Chat_operation_store.error
  | Store_unavailable of string
  | Owner_stopping
  | Owner_closed

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
      ; kind : string
      ; detail : string
      ; outcome_ref : string option
      }
      -> (Chat_operation.t, error) result command
  | Begin_stopping : (unit, error) result command

type packed_command =
  | Command : 'response command * 'response Eio.Promise.u -> packed_command

type t =
  { mailbox : packed_command Eio.Stream.t
  ; projection : Keeper_owner_reducer.projection Atomic.t
  ; operation_projection : operation_projection Atomic.t
  ; operation_store : Chat_operation_store.t
  ; now : unit -> float
  ; closed : bool Atomic.t
  ; closed_p : unit Eio.Promise.t
  ; store_error : string option ref
  }

let error_to_string = function
  | Reducer_rejected error -> Keeper_owner_reducer.error_to_string error
  | Operation_rejected error -> Chat_operation_store.error_to_string error
  | Store_unavailable detail -> "keeper owner store unavailable: " ^ detail
  | Owner_stopping -> "keeper owner is stopping"
  | Owner_closed -> "keeper owner is closed"
;;

let projection t = Atomic.get t.projection
let operation_projection t = Atomic.get t.operation_projection

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
  | exn ->
    Error
      (Chat_operation_store.Store_unavailable
         (Printf.sprintf "%s raised: %s" label (Printexc.to_string exn)))
;;

let operation_projection_of_inventory inventory =
  { queued_count = inventory.Chat_operation_store.queued_count
  ; running_operation_id = inventory.running_operation_id
  ; terminal_count = inventory.terminal_count
  }
;;

let read_operation_inventory operation_store =
  run_operation_store ~label:"keeper chat operation inventory" (fun () ->
    Chat_operation_store.inventory operation_store)
  |> Result.map_error owner_error_of_operation_error
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
       Error error
     | Error _ as error -> error
     | Ok value ->
       (match read_operation_inventory t.operation_store with
        | Error (Store_unavailable detail as error) ->
          t.store_error := Some detail;
          Error error
        | Error _ as error -> error
        | Ok inventory ->
          let projection = operation_projection_of_inventory inventory in
          Atomic.set t.operation_projection projection;
          Ok (value, projection)))
;;

let run_operation_read t ~label f =
  match
    run_operation_store ~label f
    |> Result.map_error owner_error_of_operation_error
  with
  | Error (Store_unavailable detail as error) ->
    t.store_error := Some detail;
    Error error
  | (Error _ | Ok _) as result -> result
;;

let reject_if_stopping state f =
  if (Keeper_owner_reducer.projection state).stopping then Error Owner_stopping else f ()
;;

let start ~sw ~store ~operation_store_path ~now ~keeper_name ~initial_meta =
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
    | Ok _ -> read_operation_inventory operation_store
  in
  (match startup_result with
   | Error _ as error ->
     ignore (Chat_operation_store.close operation_store : (unit, _) result);
     error
   | Ok initial_operation_inventory ->
  let closed_p, resolve_closed = Eio.Promise.create () in
  let t =
    { mailbox = Eio.Stream.create mailbox_capacity
    ; projection = Atomic.make (Keeper_owner_reducer.projection initial_state)
    ; operation_projection =
        Atomic.make (operation_projection_of_inventory initial_operation_inventory)
    ; operation_store
    ; now
    ; closed = Atomic.make false
    ; closed_p
    ; store_error = ref None
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
    let rec loop state =
        match Eio.Stream.take t.mailbox with
        | Command (Exact_projection, resolve) ->
          Eio.Promise.resolve resolve (Ok (Keeper_owner_reducer.projection state));
          loop state
        | Command (Apply_meta command, resolve) ->
          (match !(t.store_error) with
           | Some detail ->
             Eio.Promise.resolve resolve (Error (Store_unavailable detail));
             loop state
           | None ->
             (match Keeper_owner_reducer.apply_meta state command with
              | Error error ->
                Eio.Promise.resolve resolve (Error (Reducer_rejected error));
                loop state
              | Ok transition ->
                (match apply_transition t store state transition with
                 | Error (state, error) ->
                   Eio.Promise.resolve resolve (Error error);
                   loop state
                 | Ok state ->
                   Eio.Promise.resolve
                     resolve
                     (Ok (Keeper_owner_reducer.projection state).meta);
                   loop state)))
        | Command (Exact_operation operation_id, resolve) ->
          let response =
            run_operation_read t ~label:"lookup Keeper chat operation" (fun () ->
              Chat_operation_store.get t.operation_store operation_id)
          in
          Eio.Promise.resolve resolve response;
          loop state
        | Command (Submit_operation { operation_id; source; input }, resolve) ->
          let response =
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
                Ok { operation; existing; queued_count = projection.queued_count })
          in
          Eio.Promise.resolve resolve response;
          loop state
        | Command (List_queued_operations { after_sequence; limit }, resolve) ->
          let response =
            run_operation_read t ~label:"list queued Keeper chat operations" (fun () ->
              Chat_operation_store.list_queued
                t.operation_store
                ~after_sequence
                ~limit)
          in
          Eio.Promise.resolve resolve response;
          loop state
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
          loop state
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
          loop state
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
          loop state
        | Command (Claim_next_operation, resolve) ->
          let response =
            reject_if_stopping state (fun () ->
              run_operation_command t ~label:"claim next Keeper chat operation" (fun () ->
                Chat_operation_store.claim_next t.operation_store ~now:(t.now ()))
              |> Result.map fst)
          in
          Eio.Promise.resolve resolve response;
          loop state
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
          loop state
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
          loop state
        | Command (Begin_stopping, resolve) ->
          let transition = Keeper_owner_reducer.begin_stopping state in
          (match apply_transition t store state transition with
           | Error (state, error) ->
             Eio.Promise.resolve resolve (Error error);
             loop state
           | Ok state ->
             Eio.Promise.resolve resolve (Ok ());
             loop state)
    in
    loop initial_state);
  Ok t))
;;

let exact_projection t = request t Exact_projection
let apply_meta t command = request t (Apply_meta command)
let exact_operation t operation_id = request t (Exact_operation operation_id)

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

let fail_running_operation t ~operation_id ~kind ~detail ~outcome_ref =
  request t (Fail_running_operation { operation_id; kind; detail; outcome_ref })
;;

let begin_stopping t = request t Begin_stopping

module For_testing = struct
  let mailbox_depth t = Eio.Stream.length t.mailbox
end
