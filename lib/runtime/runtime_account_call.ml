type t = { of_account : Authz_types.Provider_account_id.t }

let account call = call.of_account

(* HIGH-RISK-UNREVIEWED: this keeps two official clients off the credential
   of one home.

   The lock of an account, in the table while a call of the account runs or
   waits. [users] counts those calls, and the entry leaves the table with
   the last of them. A call that runs is one of them, so every other call of
   the account finds the same lock.

   [Eio.Mutex.unlock] hands the lock to the fiber that waited longest and
   leaves it locked meanwhile, so [Eio.Mutex.try_lock] takes it only when
   nothing waits. test_runtime_account_call pins the order. *)
type entry =
  { lock : Eio.Mutex.t
  ; mutable users : int
  }

let entries : (string, entry) Hashtbl.t = Hashtbl.create 8
let entries_mutex = Mutex.create ()

(* Runs [f] on the entry of the account, counted as one of its users. *)
let with_entry provider_account_id f =
  let key = Authz_types.Provider_account_id.to_string provider_account_id in
  let entry =
    Mutex.protect entries_mutex (fun () ->
      let entry =
        match Hashtbl.find_opt entries key with
        | Some entry -> entry
        | None ->
          let entry = { lock = Eio.Mutex.create (); users = 0 } in
          Hashtbl.replace entries key entry;
          entry
      in
      entry.users <- entry.users + 1;
      entry)
  in
  Fun.protect
    (fun () -> f entry)
    ~finally:(fun () ->
      Mutex.protect entries_mutex (fun () ->
        entry.users <- entry.users - 1;
        if entry.users = 0 then Hashtbl.remove entries key))
;;

(* Runs [f] in the call that took [entry.lock], and gives the lock on. *)
let holding entry provider_account_id f =
  Fun.protect
    (fun () -> f { of_account = provider_account_id })
    ~finally:(fun () -> Eio.Mutex.unlock entry.lock)
;;

let one_call_of provider_account_id ~busy f =
  with_entry provider_account_id (fun entry ->
    if Eio.Mutex.try_lock entry.lock
    then holding entry provider_account_id f
    else Error busy)
;;

let call_in_turn_of provider_account_id f =
  with_entry provider_account_id (fun entry ->
    Eio.Mutex.lock entry.lock;
    holding entry provider_account_id (fun call ->
      (* [Eio.Mutex.lock] returns to a fiber that was cancelled after the lock
         was handed to it, and to a cancelled fiber that found the lock free.
         Neither runs the work. *)
      Eio.Fiber.check ();
      f call))
;;
