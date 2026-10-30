let domain_count = 1

type 'a outcome =
  | Served of ('a, exn * Printexc.raw_backtrace) result
  | Unserved

type job =
  | Job :
      { id : int
      ; work : unit -> 'a
      ; label : string option
      ; claimed : bool Atomic.t
      ; outcome : 'a outcome Eio.Promise.u
      }
      -> job

type host =
  | Not_started
  | Running
  | Failed of exn

exception Host_failed of exn

let state = Atomic.make Not_started

(* Unbounded, as [Eio_unix.run_in_systhread] is: adding never waits. *)
let jobs : job Eio.Stream.t = Eio.Stream.create max_int

(* Every job handed over and not yet answered, with how to answer it if the
   host fails. The host's scheduler can die outside any fiber (a failed
   [Thread.create] escapes its effect handler), and then nothing else would
   ever resolve these. *)
let pending : (int, exn -> unit) Hashtbl.t = Hashtbl.create 16
let pending_mutex = Mutex.create ()
let next_id = Atomic.make 0

let unregister id = Mutex.protect pending_mutex (fun () -> Hashtbl.remove pending id)

(* [claimed] decides who runs a job: the host when it takes it, or the caller
   when the host failed first. Only the winner of the CAS runs the work. *)
let answer_after_failure ~claimed ~outcome exn =
  if Atomic.compare_and_set claimed false true
  then ignore (Eio.Promise.try_resolve outcome Unserved : bool)
  else
    ignore
      (Eio.Promise.try_resolve outcome
         (Served (Error (Host_failed exn, Printexc.get_callstack 0)))
       : bool)
;;

let fail_host exn =
  Atomic.set state (Failed exn);
  Log.Misc.error
    "system-thread host failed; its callers now start threads on their own domain: %s"
    (Printexc.to_string exn);
  let answers =
    Mutex.protect pending_mutex (fun () ->
      let answers = Hashtbl.fold (fun _ answer acc -> answer :: acc) pending [] in
      Hashtbl.reset pending;
      answers)
  in
  List.iter (fun answer -> answer exn) answers
;;

(* Each job gets its own fiber at once, so a long one never delays the next.
   The fiber catches everything the work raises. *)
let serve () =
  Minor_heap.tune ();
  match
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let rec loop () =
          let (Job { id; work; label; claimed; outcome }) = Eio.Stream.take jobs in
          if Atomic.compare_and_set claimed false true
          then
            Eio.Fiber.fork ~sw (fun () ->
              let result =
                match Eio_unix.run_in_systhread ?label work with
                | value -> Ok value
                | exception exn -> Error (exn, Printexc.get_raw_backtrace ())
              in
              ignore (Eio.Promise.try_resolve outcome (Served result) : bool);
              unregister id);
          loop ()
        in
        loop ()))
  with
  | () -> fail_host (Failure "system-thread host scheduler returned")
  | exception exn -> fail_host exn
;;

let start () =
  if Atomic.compare_and_set state Not_started Running
  then (
    try ignore (Domain.spawn serve : unit Domain.t) with
    | exn -> fail_host exn)
;;

let run ?label work =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> work ()
  | Eio_guard.Eio_fiber ->
    let on_own_domain () = Eio_unix.run_in_systhread ?label work in
    (match Atomic.get state with
     | Not_started | Failed _ -> on_own_domain ()
     | Running when Executor_pool_ref.in_worker_context () -> on_own_domain ()
     | Running ->
       Eio.Fiber.check ();
       let answer, outcome = Eio.Promise.create () in
       let claimed = Atomic.make false in
       let id = Atomic.fetch_and_add next_id 1 in
       Mutex.protect pending_mutex (fun () ->
         Hashtbl.replace pending id (answer_after_failure ~claimed ~outcome));
       Eio.Stream.add jobs (Job { id; work; label; claimed; outcome });
       (* A host that failed after the check above may never take this job,
          and its failure may have answered the pending table before the job
          was in it. *)
       (match Atomic.get state with
        | Failed exn -> answer_after_failure ~claimed ~outcome exn
        | Not_started | Running -> ());
       (match Eio.Cancel.protect (fun () -> Eio.Promise.await answer) with
        | Served (Ok value) -> value
        | Served (Error (exn, backtrace)) -> Printexc.raise_with_backtrace exn backtrace
        | Unserved ->
          unregister id;
          on_own_domain ()))
;;
