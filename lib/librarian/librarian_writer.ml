module Digest = Agent_core.Checkpoint_objects
module Machine = Librarian_machine
module Store = Librarian_store
module Log_line = Librarian_log

type view =
  { covers_through : Log_line.position
  ; covered : Keeper_turn_log.mark
  ; working_state : string option
  }

let view : Log_line.line -> view = function
  | Started { covered; _ } -> { covers_through = Before_first; covered; working_state = None }
  | Committed { covers_through; covered; working_state; _ } ->
    { covers_through; covered; working_state }
;;

type status =
  | Booting
  | Open of Log_line.line
  | Stopped of Store.stop
  | Retired

type retirement =
  | Retired_now
  | Still_registered

type event =
  | Write of
      { by : Librarian_effects.actor
      ; trace : string
      ; write : Librarian_direct.write
      ; reply : Machine.write_answer Eio.Promise.u
      }
  | Resume of Machine.act_answer Eio.Promise.u
  | Adopt of
      { by : string
      ; observed : Digest.digest
      ; reply : Machine.act_answer Eio.Promise.u
      }
  | Retire of retirement Eio.Promise.u

type t =
  { place : Machine.place
  ; now : unit -> float
  ; registered : unit -> bool
  ; mailbox : event Eio.Stream.t
  ; status : status Atomic.t
  ; gone : unit Eio.Promise.t
  }

let status t = Atomic.get t.status
let lock_suffix = ".memory.lock"

let lock_path (place : Machine.place) =
  Filename.concat place.memory_dir (place.keeper_id ^ lock_suffix)
;;

let lock_file_permissions = 0o600

(* The lock is taken on a file that exists. It is made once and never
   replaced: a second file under the same name would be a second lock. *)
let ensure_lock_file path =
  match
    Fs_compat.mkdir_p (Filename.dirname path);
    Unix.close (Unix.openfile path [ O_WRONLY; O_CREAT; O_CLOEXEC ] lock_file_permissions)
  with
  | () -> Ok ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception Unix.Unix_error (error, operation, (_ : string)) ->
    Error (operation ^ ": " ^ Unix.error_message error)
  | exception Sys_error detail -> Error detail
;;

let stop_text : Store.stop -> string = function
  | Log_diverged { expected; observed } ->
    Printf.sprintf "log_diverged expected=%s observed=%s" (expected :> string) (observed :> string)
  | Memory_unreadable -> "memory_unreadable"
  | Log_unreadable -> "log_unreadable"
  | Store_unwritable -> "store_unwritable"
;;

let status_of : Machine.state -> status = function
  | Idle store -> Open (Store.tail store)
  | Stopped stop -> Stopped stop
  | Retired -> Retired
;;

(* The state after an event, made visible before the event is answered: the
   caller that is woken reads the status the answer is about. *)
let publish t ~was (state : Machine.state) =
  (match was, state with
   | (Machine.Idle _ | Retired), Stopped stop ->
     Log.Keeper.error ~keeper_name:t.place.keeper_id "librarian memory store stopped: %s"
       (stop_text stop)
   | (Machine.Idle _ | Stopped _ | Retired), (Idle _ | Stopped _ | Retired) -> ());
  Atomic.set t.status (status_of state)
;;

let take_lock t ~sw =
  let path = lock_path t.place in
  let refused detail =
    Log.Keeper.error ~keeper_name:t.place.keeper_id "librarian memory lock not taken: %s" detail;
    false
  in
  match ensure_lock_file path with
  | Error detail -> refused detail
  | Ok () ->
    (match File_lock_eio.acquire_liveness_lock ~sw ~lock_path:path with
     | Ok () -> true
     | Error error -> refused (File_lock_eio.durable_lock_error_to_string error))
;;

(* [sw] lives as long as the writer does and owns the lock. The loop returns
   the retirement it has to answer once the lock is released. *)
let live t ~sw =
  let locked = ref false in
  let boot () =
    Atomic.set t.status Booting;
    Eio.Cancel.protect (fun () ->
      if not !locked then locked := take_lock t ~sw;
      let state : Machine.state =
        if !locked then Machine.boot t.place ~at:(t.now ()) else Stopped Store_unwritable
      in
      (match state with
       | Stopped stop ->
         Log.Keeper.error ~keeper_name:t.place.keeper_id "librarian memory store did not open: %s"
           (stop_text stop)
       | Idle (_ : Store.t) | Retired -> ());
      state)
  in
  let rec loop state =
    let settle next reply answer =
      publish t ~was:state next;
      Eio.Promise.resolve reply answer;
      loop next
    in
    match Eio.Stream.take t.mailbox with
    | Write { by; trace; write; reply } ->
      let next, answer =
        Eio.Cancel.protect (fun () -> Machine.write state ~at:(t.now ()) ~by ~trace write)
      in
      settle next reply answer
    | Resume reply ->
      let next, answer = Machine.resume ~boot state in
      Atomic.set t.status (status_of next);
      Eio.Promise.resolve reply answer;
      loop next
    | Adopt { by; observed; reply } ->
      let next, answer =
        Eio.Cancel.protect (fun () ->
          Machine.adopt t.place state ~at:(t.now ()) ~by ~observed)
      in
      settle next reply answer
    | Retire reply ->
      if t.registered ()
      then (
        Eio.Promise.resolve reply Still_registered;
        loop state)
      else reply
  in
  let state = boot () in
  Atomic.set t.status (status_of state);
  loop state
;;

let run t ~gone =
  let retiring =
    Fun.protect
      ~finally:(fun () ->
        Atomic.set t.status Retired;
        Eio.Promise.resolve gone ())
      (fun () -> Eio.Switch.run (fun sw -> live t ~sw))
  in
  Eio.Promise.resolve retiring Retired_now
;;

let start ~sw ~now ~registered place =
  let gone, resolve_gone = Eio.Promise.create () in
  let t =
    { place
    ; now
    ; registered
    ; mailbox = Eio.Stream.create max_int
    ; status = Atomic.make Booting
    ; gone
    }
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    run t ~gone:resolve_gone;
    `Stop_daemon);
  t
;;

(* A writer that has ended takes nothing from its mailbox, so the caller
   also waits for the end. An answer the writer gave before it ended is the
   answer. *)
let ask t ~when_gone event =
  let reply, resolver = Eio.Promise.create () in
  Eio.Stream.add t.mailbox (event resolver);
  match
    Eio.Fiber.first
      (fun () -> Some (Eio.Promise.await reply))
      (fun () ->
         Eio.Promise.await t.gone;
         None)
  with
  | Some answer -> answer
  | None -> Option.value (Eio.Promise.peek reply) ~default:when_gone
;;

let write t ~by ~trace write =
  ask t
    ~when_gone:(Machine.Unavailable Keeper_retired)
    (fun reply -> Write { by; trace; write; reply })
;;

let resume t =
  ask t ~when_gone:(Machine.Not_done (Act_unavailable Keeper_retired)) (fun reply -> Resume reply)
;;

let adopt t ~by ~observed =
  ask t
    ~when_gone:(Machine.Not_done (Act_unavailable Keeper_retired))
    (fun reply -> Adopt { by; observed; reply })
;;

let retire t = ask t ~when_gone:Retired_now (fun reply -> Retire reply)
