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

type 'a acquire_result =
  | Acquired of 'a
  | Account_busy of Authz_types.Provider_account_id.t

let try_acquire provider_account_id f =
  with_entry provider_account_id (fun entry ->
    if Eio.Mutex.try_lock entry.lock
    then Acquired (holding entry provider_account_id f)
    else Account_busy provider_account_id)
;;

let one_call_of provider_account_id ~busy f =
  match try_acquire provider_account_id f with
  | Acquired res -> res
  | Account_busy _ -> Error busy
;;

let call_in_turn_of provider_account_id f =
  with_entry provider_account_id (fun entry ->
    (* Outside an Eio fiber this raises before the lock is touched. There
       [Eio.Mutex.lock] on a busy account raises while it holds the mutex
       inside the lock, and no later call of the account gets past it. A
       fiber that comes cancelled stops here too. *)
    Eio.Fiber.check ();
    Eio.Mutex.lock entry.lock;
    holding entry provider_account_id (fun call ->
      (* [Eio.Mutex.lock] returns to a fiber that was cancelled after the lock
         was handed to it. That fiber does not run the work. *)
      Eio.Fiber.check ();
      f call))
;;

let call_in_turn_of_with_timeout ~clock ~timeout_s provider_account_id f =
  if not (Float.is_finite timeout_s) || timeout_s <= 0.0
  then try_acquire provider_account_id f
  else
    with_entry provider_account_id (fun entry ->
      (* Match [call_in_turn_of]: fail outside an Eio fiber or if already
         cancelled before touching [entry.lock]. *)
      Eio.Fiber.check ();
      (* [Eio.Mutex.unlock] keeps the lock held across handover to queued
         waiters, so [try_lock] succeeds only when the slot is uncontended and
         no fiber is waiting ahead of us. *)
      if Eio.Mutex.try_lock entry.lock
      then
        Acquired
          (holding entry provider_account_id (fun call ->
             Eio.Fiber.check ();
             f call))
      else (
        let acquired = ref false in
        let timed_out =
          try
            match
              Eio.Time.with_timeout clock timeout_s (fun () ->
                Eio.Mutex.lock entry.lock;
                acquired := true;
                Ok ())
            with
            | Ok () -> false
            | Error `Timeout -> true
          with
          | exn ->
            let bt = Printexc.get_raw_backtrace () in
            if !acquired then Eio.Mutex.unlock entry.lock;
            Printexc.raise_with_backtrace exn bt
        in
        if !acquired
        then
          holding entry provider_account_id (fun call ->
            if timed_out
            then Account_busy provider_account_id
            else (
              Eio.Fiber.check ();
              Acquired (f call)))
        else (
          Eio.Fiber.check ();
          Account_busy provider_account_id)))
;;
