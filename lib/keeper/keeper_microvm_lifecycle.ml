type keeper_lock =
  { name : string
  ; mutex : Eio.Mutex.t
  ; mutable users : int
  }

type ticket =
  { lock : keeper_lock
  ; finished : unit Eio.Promise.t
  ; resolve : unit Eio.Promise.u
  }

type t =
  { registry : Stdlib.Mutex.t
  ; inventory : Eio.Mutex.t
  ; mutable locks : keeper_lock list
  ; mutable active : ticket list
  ; mutable reopening : unit Eio.Promise.t option
  }

type admission = Wait_for_inventory of unit Eio.Promise.t | Admitted of ticket

type scope_phase = Open of int | Closing of int | Closed

type keeper_scope =
  { coordinator : t
  ; keeper : string
  ; mutable phase : scope_phase
  ; drained : unit Eio.Promise.t
  ; signal_drained : unit Eio.Promise.u
  }

type scope_error = Scope_closed | Other_keeper | Other_coordinator

let create () =
  {registry = Stdlib.Mutex.create (); inventory = Eio.Mutex.create ();
   locks = []; active = []; reopening = None}

(* Release a lifecycle mutex before propagating a callback exception. Runtime
   failures leave an external inventory to inspect; poisoning a coordinator
   would instead permanently prevent its later inspection and recovery. *)
let protected_action mutex callback =
  match Eio.Mutex.use_rw ~protect:true mutex (fun () ->
    try Ok (callback ()) with exn -> Error (exn, Printexc.get_raw_backtrace ())) with
  | Ok value -> value
  | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace

let rec admit t keeper_name =
  let admission = Stdlib.Mutex.protect t.registry (fun () ->
    match t.reopening with
    | Some reopened -> Wait_for_inventory reopened
    | None ->
      let lock = match List.find_opt (fun lock -> lock.name = keeper_name) t.locks with
        | Some lock -> lock
        | None ->
          let lock = {name = keeper_name; mutex = Eio.Mutex.create (); users = 0} in
          t.locks <- lock :: t.locks;
          lock in
      lock.users <- lock.users + 1;
      let finished, resolve = Eio.Promise.create () in
      let ticket = {lock; finished; resolve} in
      t.active <- ticket :: t.active;
      Admitted ticket) in
  match admission with
  | Wait_for_inventory reopened -> Eio.Promise.await reopened; admit t keeper_name
  | Admitted ticket -> ticket

let release t ticket =
  Stdlib.Mutex.protect t.registry (fun () ->
    t.active <- List.filter (fun active -> active != ticket) t.active;
    ticket.lock.users <- ticket.lock.users - 1;
    if ticket.lock.users = 0 then
      t.locks <- List.filter (fun lock -> lock != ticket.lock) t.locks);
  Eio.Promise.resolve ticket.resolve ()

let release_borrow scope =
  let signal = Stdlib.Mutex.protect scope.coordinator.registry (fun () ->
    match scope.phase with
    | Open count ->
      assert (count > 0);
      scope.phase <- Open (count - 1);
      false
    | Closing 1 -> scope.phase <- Closed; true
    | Closing count ->
      assert (count > 1);
      scope.phase <- Closing (count - 1);
      false
    | Closed -> assert false) in
  if signal then Eio.Promise.resolve scope.signal_drained ()

let with_borrowed_scope t ~scope ~keeper_name callback =
  if t != scope.coordinator then Error Other_coordinator
  else if Common.safe_filename keeper_name <> scope.keeper then Error Other_keeper
  else (
    Eio.Fiber.check ();
    let admitted = Stdlib.Mutex.protect t.registry (fun () ->
      match scope.phase with
      | Open count -> scope.phase <- Open (count + 1); true
      | Closing _ | Closed -> false) in
    if not admitted then Error Scope_closed
    else
      Ok (Fun.protect
        ~finally:(fun () -> Eio.Cancel.protect (fun () -> release_borrow scope))
        (fun () -> Eio.Cancel.protect callback)))

let close_and_drain scope =
  let await = Stdlib.Mutex.protect scope.coordinator.registry (fun () ->
    match scope.phase with
    | Open 0 -> scope.phase <- Closed; false
    | Open count -> scope.phase <- Closing count; true
    | Closing _ | Closed -> assert false) in
  if await then Eio.Promise.await scope.drained

let with_keeper_scope t ~keeper_name callback =
  let ticket = admit t (Common.safe_filename keeper_name) in
  Fun.protect ~finally:(fun () -> release t ticket)
    (fun () -> protected_action ticket.lock.mutex (fun () ->
      let drained, signal_drained = Eio.Promise.create () in
      let scope = {coordinator = t; keeper = ticket.lock.name; phase = Open 0;
                   drained; signal_drained} in
      Fun.protect
        ~finally:(fun () -> Eio.Cancel.protect (fun () -> close_and_drain scope))
        (fun () -> callback scope)))

let with_keeper t ~keeper_name callback =
  with_keeper_scope t ~keeper_name (fun _ -> callback ())

let with_inventory t callback =
  Eio.Mutex.use_ro t.inventory (fun () ->
    let reopened, reopen = Eio.Promise.create () in
    let preceding = Stdlib.Mutex.protect t.registry (fun () ->
      t.reopening <- Some reopened;
      List.map (fun ticket -> ticket.finished) t.active) in
    Fun.protect
      ~finally:(fun () ->
        Stdlib.Mutex.protect t.registry (fun () -> t.reopening <- None);
        Eio.Promise.resolve reopen ())
      (fun () -> List.iter Eio.Promise.await preceding; Eio.Cancel.protect callback))
