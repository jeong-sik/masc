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

let with_keeper t ~keeper_name callback =
  let ticket = admit t (Common.safe_filename keeper_name) in
  Fun.protect ~finally:(fun () -> release t ticket)
    (fun () -> protected_action ticket.lock.mutex callback)

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
