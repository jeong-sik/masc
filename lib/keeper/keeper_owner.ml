let mailbox_capacity = 128

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Store_unavailable of string
  | Owner_closed

type _ command =
  | Exact_projection :
      (Keeper_owner_reducer.projection, error) result command
  | Apply_meta :
      Keeper_owner_reducer.meta_command
      -> (Keeper_meta_contract.keeper_meta option, error) result command
  | Begin_stopping : (unit, error) result command

type packed_command =
  | Command : 'response command * 'response Eio.Promise.u -> packed_command

type t =
  { mailbox : packed_command Eio.Stream.t
  ; projection : Keeper_owner_reducer.projection Atomic.t
  ; closed : bool Atomic.t
  ; closed_p : unit Eio.Promise.t
  ; store_error : string option ref
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
  | Error (Reducer_rejected _ | Owner_closed as error) -> Error (old_state, error)
  | Ok state ->
    Atomic.set t.projection transition.projection;
    Ok state
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
    ; store_error = ref None
    }
  in
  Eio.Switch.on_release sw (fun () ->
    Atomic.set t.closed true;
    Eio.Promise.resolve resolve_closed ();
    let projection = Atomic.get t.projection in
    Atomic.set t.projection { projection with stopping = true });
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
  Ok t
;;

let exact_projection t = request t Exact_projection
let apply_meta t command = request t (Apply_meta command)
let begin_stopping t = request t Begin_stopping

module For_testing = struct
  let mailbox_depth t = Eio.Stream.length t.mailbox
end
