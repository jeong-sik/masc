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

type 'answer asked =
  | Answered of 'answer
  | Ended

type event =
  | Turn_closed
  | Pulse
  | Declaration_changed
  (* The writer reads the declaration when it takes this: of two that come
     close together, the one taken last carries the newer value. *)
  | Ask_ended of
      { ask : int
      ; result : Machine.ended
      }
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
  ; declared : unit -> Machine.declared option
  ; stores : Librarian_unit_content.stores
  ; ask : Librarian_ask.input -> Librarian_read_result.t
  ; ask_room : Librarian_ask.room_input -> Librarian_room_result.t
  ; start_turn_log : unit -> (unit, string) result
  ; mailbox : event Eio.Stream.t
  ; status : status Atomic.t
  ; between : status option Atomic.t
  (* The status while the fiber waits for its next event; [None] while it
     takes one. *)
  ; settled : Eio.Condition.t (* Broadcast when [between] is set. *)
  ; gone : unit Eio.Promise.t
  ; ended : unit Eio.Promise.u
  }

let status t = Atomic.get t.status
let lock_suffix = ".memory.lock"

let lock_path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ lock_suffix)
;;

let lock_path (place : Machine.place) =
  lock_path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id:place.keeper_id
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
  | Raised { detail } -> "raised: " ^ detail
;;

let status_of : Machine.state -> status = function
  | Idle { store; seen_length = (_ : int option) }
  | Asking { store; asking = (_ : Machine.asking) }
  | Resting store
  | Refused_at_bottom store -> Open (Store.tail store)
  | Stopped stop -> Stopped stop
;;

(* The state after an event, made visible before the event is answered: the
   caller that is woken reads the status the answer is about. *)
let publish t ~(was : Machine.t) (next : Machine.t) =
  (match was.state, next.state with
   | (Idle _ | Asking _ | Resting _ | Refused_at_bottom _), Stopped stop ->
     Log.Keeper.error ~keeper_name:t.place.keeper_id "librarian memory store stopped: %s"
       (stop_text stop)
   | ( (Idle _ | Asking _ | Resting _ | Refused_at_bottom _ | Stopped _)
     , (Idle _ | Asking _ | Resting _ | Refused_at_bottom _) )
   | Stopped _, Stopped _ -> ());
  Atomic.set t.status (status_of next.state)
;;

(* The revision the snapshot file holds, when the store is open. *)
let revision (value : Machine.t) =
  match value.state with
  | Idle { store; seen_length = (_ : int option) }
  | Asking { store; asking = (_ : Machine.asking) }
  | Resting store
  | Refused_at_bottom store -> Some (Store.memory store).revision
  | Stopped (_ : Store.stop) -> None
;;

(* Says that the snapshot file holds a revision this writer has not said it
   holds: whoever follows [Keeper_memory_commit_notifications] reads Memory
   again. [was] is the revision before the step, [None] for a store that was
   not open. So a store that opens says its revision too: the boot or the
   adoption that opened it can be what put that revision in the file. *)
let announce t ~was (value : Machine.t) =
  match revision value with
  | Some now when not (Option.equal Int.equal was (Some now)) ->
    Keeper_memory_commit_notifications.notify_committed
      { keepers_dir = Unix.realpath t.place.memory_dir
      ; keeper_id = t.place.keeper_id
      ; store = Ordinary
      ; revision = now
      }
  | Some (_ : int) | None -> ()
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

(* The tail an open writer shows while it waits for its next event: what an
   ask reads Memory under (§7.1). A read while it takes an event waits for
   the event to end. A commit appends its line and then replaces the
   snapshot file, and the status names the new line only after both: read
   in between, the old line would name the new bytes, and the ask would end
   as [Memory_diverged]. *)
let tail t () =
  Eio.Condition.loop_no_mutex t.settled (fun () ->
    match Atomic.get t.between with
    | None -> None
    | Some (Open line) -> Some (Some line)
    | Some (Booting | Stopped (_ : Store.stop) | Retired) -> Some None)
;;

(* What one event leaves the loop with. *)
type step =
  | Next of Machine.t
  | Retiring of retirement Eio.Promise.u

(* §9.2: the caller of an event that raised is told the store stopped. An
   answer it already has stays, since [try_resolve] keeps the first one.
   Whether the event's line landed is what the commit log holds, and the
   next boot reads it. Whether a retiring Keeper is still registered was not
   learnt, so its writer stays, and the next pulse asks again. *)
let answer_stopped event (stop : Store.stop) =
  let tell reply answer = ignore (Eio.Promise.try_resolve reply answer : bool) in
  match event with
  | Turn_closed | Pulse | Declaration_changed | Ask_ended _ -> ()
  | Write { reply; _ } -> tell reply (Machine.Unavailable (Store_stopped stop))
  | Resume reply | Adopt { reply; _ } ->
    tell reply (Machine.Not_done (Act_unavailable (Store_stopped stop)))
  | Retire reply -> tell reply Still_registered
;;

(* [sw] lives as long as the writer does and owns the lock. The loop returns
   the retirement it has to answer once the lock is released. *)
let live t ~sw =
  let locked = ref false in
  (* Resolving it cancels the ask that is out. Only this fiber reads or sets
     it. *)
  let out : unit Eio.Promise.u option ref = ref None in
  let cancel () =
    Option.iter (fun cancel -> ignore (Eio.Promise.try_resolve cancel () : bool)) !out;
    out := None
  in
  (* The ask runs in a fiber of its own and its result comes back through the
     mailbox. A daemon, so a writer that ends does not wait for it. An ask
     that ended before its cancel posts its result: the machine drops it as
     late. *)
  let start (asking : Machine.asking) =
    let cancelled, cancelling = Eio.Promise.create () in
    out := Some cancelling;
    (* The result comes back with what was asked, so the machine reads a
       reading result as the reading it asked for. *)
    let asked () : Machine.ended =
      match asking.asked with
      | Read asked ->
        Read_ended
          { asked
          ; result =
              t.ask
                { place = t.place
                ; stores = t.stores
                ; tail = tail t
                ; lane = asking.lane.value
                ; resolved = asking.lane.resolved
                ; asked
                ; bottom = asking.bottom
                }
          }
      | Room asked ->
        Room_ended
          (t.ask_room
             { place = t.place
             ; tail = tail t
             ; lane = asking.lane.value
             ; resolved = asking.lane.resolved
             ; asked
             })
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      (match
         Eio.Fiber.first
           (fun () ->
              Eio.Promise.await cancelled;
              None)
           (fun () -> Some (asked ()))
       with
       | Some result -> Eio.Stream.add t.mailbox (Ask_ended { ask = asking.ask; result })
       | None -> ());
      `Stop_daemon)
  in
  let follow ~before ~after =
    match Machine.fiber_change ~before ~after with
    | Keep -> ()
    | Start asking -> start asking
    | Cancel -> cancel ()
    | Cancel_then_start asking ->
      cancel ();
      start asking
  in
  let boot () =
    Atomic.set t.status Booting;
    Eio.Cancel.protect (fun () ->
      if not !locked then locked := take_lock t ~sw;
      let opened : (Store.t, Store.stop) result =
        if not !locked
        then Error Store_unwritable
        else (
          (* §8.6: the store start is the turn log's first line, then the
             boot. A first boot and a resume both do the two. *)
          match t.start_turn_log () with
          | Ok () -> Machine.boot t.place ~at:(t.now ())
          | Error detail ->
            Log.Keeper.error ~keeper_name:t.place.keeper_id
              "librarian memory store start: the turn log's first line was not written: %s"
              detail;
            Error Store_unwritable)
      in
      (match opened with
       | Error stop ->
         Log.Keeper.error ~keeper_name:t.place.keeper_id "librarian memory store did not open: %s"
           (stop_text stop)
       | Ok (_ : Store.t) -> ());
      opened)
  in
  (* One event. The caller has its answer before anyone is told to read
     Memory. *)
  let step (state : Machine.t) event =
    let settle next reply answer =
      publish t ~was:state next;
      follow ~before:state ~after:next;
      Eio.Promise.resolve reply answer;
      announce t ~was:(revision state) next;
      Next next
    in
    (* A commit and the reads before the next ask are not cancelled. *)
    let decided (event : Machine.event) =
      let next =
        Eio.Cancel.protect (fun () -> Machine.decide t.place state ~at:(t.now ()) event)
      in
      publish t ~was:state next;
      follow ~before:state ~after:next;
      announce t ~was:(revision state) next;
      Next next
    in
    match event with
    | Turn_closed -> decided Machine.Turn_closed
    | Pulse -> decided Machine.Pulse
    | Declaration_changed -> decided (Machine.Declaration_changed (t.declared ()))
    | Ask_ended { ask; result } -> decided (Machine.Ask_ended { ask; result })
    | Write { by; trace; write; reply } ->
      let next, answer =
        Eio.Cancel.protect (fun () ->
          Machine.write t.place state ~at:(t.now ()) ~by ~trace write)
      in
      settle next reply answer
    | Resume reply ->
      let next, answer = Machine.resume t.place ~boot state ~at:(t.now ()) in
      Atomic.set t.status (status_of next.state);
      follow ~before:state ~after:next;
      Eio.Promise.resolve reply answer;
      announce t ~was:(revision state) next;
      Next next
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
        Next state)
      else Retiring reply
  in
  (* §9.2: an exception that is not reserved stops this writer and no other.
     [stopped] makes the value it stops at, the ask that is out is
     cancelled, and [answer] tells the caller of the event. The fiber goes
     on taking events, so nothing makes the writer again but a [Resume].
     Cancellation and the reserved exceptions go on up. *)
  let stop_on exn ~stopped ~answer =
    let backtrace = Printexc.get_raw_backtrace () in
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    let raised : Store.raised = { detail = Printexc.to_string exn } in
    let next : Machine.t = stopped (Store.Raised raised) in
    cancel ();
    Atomic.set t.status (status_of next.state);
    answer (Store.Raised raised);
    Log.Keeper.error ~keeper_name:t.place.keeper_id "librarian memory writer raised: %s\n%s"
      raised.detail
      (Printexc.raw_backtrace_to_string backtrace);
    next
  in
  let rec loop (state : Machine.t) =
    Atomic.set t.between (Some (status_of state.state));
    Eio.Condition.broadcast t.settled;
    let event = Eio.Stream.take t.mailbox in
    Atomic.set t.between None;
    match step state event with
    | Next next -> loop next
    | Retiring reply -> reply
    | exception exn ->
      loop
        (stop_on exn
           ~stopped:(Machine.stopped ~lane:state.lane ~last_ask:state.last_ask)
           ~answer:(answer_stopped event))
  in
  (* A writer boots with no lane value, so the boot does not ask. The
     declaration is the first event in its mailbox. *)
  let first () =
    let state = Machine.booted t.place ~at:(t.now ()) ~lane:None ~last_ask:0 (boot ()) in
    Atomic.set t.status (status_of state.state);
    announce t ~was:None state;
    state
  in
  match first () with
  | state -> loop state
  | exception exn ->
    loop
      (stop_on exn
         ~stopped:(Machine.stopped ~lane:None ~last_ask:0)
         ~answer:(fun (_ : Store.stop) -> ()))
;;

let create ~now ~registered ~declared ~stores ~ask ~ask_room ~start_turn_log place =
  let gone, ended = Eio.Promise.create () in
  let mailbox = Eio.Stream.create max_int in
  Eio.Stream.add mailbox Declaration_changed;
  { place
  ; now
  ; registered
  ; declared
  ; stores
  ; ask
  ; ask_room
  ; start_turn_log
  ; mailbox
  ; status = Atomic.make Booting
  ; between = Atomic.make None
  ; settled = Eio.Condition.create ()
  ; gone
  ; ended
  }
;;

let run t =
  let retiring =
    Fun.protect
      ~finally:(fun () ->
        Atomic.set t.status Retired;
        Eio.Promise.resolve t.ended ())
      (fun () -> Eio.Switch.run (fun sw -> live t ~sw))
  in
  Eio.Promise.resolve retiring Retired_now
;;

(* A writer that has ended takes nothing from its mailbox, so the caller
   also waits for the end. An answer the writer gave before it ended is the
   answer. *)
let ask t event =
  let reply, resolver = Eio.Promise.create () in
  Eio.Stream.add t.mailbox (event resolver);
  match
    Eio.Fiber.first
      (fun () -> Some (Eio.Promise.await reply))
      (fun () ->
         Eio.Promise.await t.gone;
         None)
  with
  | Some answer -> Answered answer
  | None ->
    (match Eio.Promise.peek reply with
     | Some answer -> Answered answer
     | None -> Ended)
;;

let turn_closed t = Eio.Stream.add t.mailbox Turn_closed
let pulse t = Eio.Stream.add t.mailbox Pulse
let declaration_changed t = Eio.Stream.add t.mailbox Declaration_changed
let write t ~by ~trace write = ask t (fun reply -> Write { by; trace; write; reply })
let resume t = ask t (fun reply -> Resume reply)
let adopt t ~by ~observed = ask t (fun reply -> Adopt { by; observed; reply })

let retire t =
  match ask t (fun reply -> Retire reply) with
  | Answered retirement -> retirement
  | Ended -> Retired_now
;;
