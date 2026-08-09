let mailbox_capacity = 128

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
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
  }

let error_to_string = function
  | Reducer_rejected error -> Keeper_owner_reducer.error_to_string error
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
  | Error (Reducer_rejected _ | Store_unavailable _) -> ()
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

let start ~sw ~store ~keeper_name ~initial_meta =
  match Keeper_owner_reducer.create ~keeper_name initial_meta with
  | Error error -> Error (Reducer_rejected error)
  | Ok initial_state ->
  let closed_p, resolve_closed = Eio.Promise.create () in
  let t =
    { mailbox = Eio.Stream.create mailbox_capacity
    ; projection = Atomic.make (Keeper_owner_reducer.projection initial_state)
    ; closed = Atomic.make false
    ; closed_p
    ; active_completion = Atomic.make None
    }
  in
  Eio.Switch.on_release sw (fun () ->
    Atomic.set t.closed true;
    Eio.Promise.resolve resolve_closed ();
    Option.iter (fun completion -> settle completion Turn_cancelled)
      (Atomic.exchange t.active_completion None);
    let projection = Atomic.get t.projection in
    Atomic.set t.projection { projection with stopping = true });
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Switch.run (fun child_sw ->
      let rec loop state =
        match Eio.Stream.take t.mailbox with
        | Command (Exact_projection, resolve) ->
          Eio.Promise.resolve resolve (Ok (Keeper_owner_reducer.projection state));
          loop state
        | Command (Apply_meta command, resolve) ->
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
                loop state))
        | Command (Start_turn request, resolve) ->
          (match Keeper_owner_reducer.begin_turn state ~operation_id:request.operation_id with
           | Error (Turn_already_running running_operation_id) ->
             Eio.Promise.resolve resolve (Ok (Busy { running_operation_id }));
             loop state
           | Error error ->
             Eio.Promise.resolve resolve (Error (Reducer_rejected error));
             loop state
           | Ok transition ->
             (match apply_transition t store state transition with
              | Error (state, error) ->
                Eio.Promise.resolve resolve (Error error);
                loop state
              | Ok state ->
                Atomic.set t.active_completion (Some request.completion);
                Eio.Promise.resolve resolve (Ok (Started request.completion.handle));
                if transition_starts_child transition request.operation_id
                then Eio.Fiber.fork ~sw:child_sw (fun () -> run_child t request);
                loop state))
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
             loop state
           | Ok transition ->
             (match apply_transition t store state transition with
              | Error (state, error) ->
                Log.Keeper.error
                  "keeper_owner: child completion projection failed operation_id=%s error=%s"
                  operation_id
                  (error_to_string error);
                Eio.Promise.resolve resolve (Ok ());
                loop state
              | Ok state ->
                let terminal =
                  match outcome with
                  | Child_succeeded -> Turn_succeeded
                  | Child_failed detail -> Turn_failed detail
                  | Child_cancelled -> Turn_cancelled
                in
                settle_active t operation_id terminal;
                Eio.Promise.resolve resolve (Ok ());
                loop state))
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
      loop initial_state));
  Ok t
;;

let exact_projection t = request t Exact_projection
let apply_meta t command = request t (Apply_meta command)
let start_turn t ~operation_id ~run =
  let terminal, resolve = Eio.Promise.create () in
  let handle = { operation_id; terminal } in
  let completion = { handle; resolve; settled = Atomic.make false } in
  request t (Start_turn { operation_id; run; completion })
;;

let await_turn handle = Eio.Promise.await handle.terminal
let begin_stopping t = request t Begin_stopping

module For_testing = struct
  let mailbox_depth t = Eio.Stream.length t.mailbox
end
