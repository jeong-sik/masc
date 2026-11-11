let domain_count = 1

(* The suspend reason [Eio_unix.run_in_systhread] gives an unlabelled call. *)
let default_label = "systhread"

type 'a outcome =
  | Served of ('a, exn * Printexc.raw_backtrace) result
  | Unserved

(* Where a caller waits for its outcome. The first [fill] wins, and the
   waiter is woken once. A promise would do the same, but [Eio.Promise.await]
   writes "Promise.await" as the fiber's suspend reason, and a trace of the
   caller's domain places code by that reason: the caller suspends under the
   work's label here, as it does under [Eio_unix.run_in_systhread]. *)
type 'a slot =
  | Empty
  | Waiting of ('a -> unit)
  | Filled of 'a

let rec fill slot value =
  match Atomic.get slot with
  | Filled _ -> ()
  | Empty as seen ->
    if not (Atomic.compare_and_set slot seen (Filled value)) then fill slot value
  | Waiting wake as seen ->
    if Atomic.compare_and_set slot seen (Filled value) then wake value else fill slot value
;;

(* Not cancellable: no cancel function is set, as in Eio's thread pool. The
   scheduler's [enqueue] may be called from any domain or thread. *)
let await ~label slot =
  match Atomic.get slot with
  | Filled value -> value
  | Empty | Waiting _ ->
    Eio.Private.Suspend.enter_unchecked label (fun _context enqueue ->
      let wake value = enqueue (Ok value) in
      let rec register () =
        match Atomic.get slot with
        | Filled value -> wake value
        | Waiting _ -> invalid_arg "Systhread_host: a slot has one waiter"
        | Empty as seen ->
          if not (Atomic.compare_and_set slot seen (Waiting wake)) then register ()
      in
      register ())
;;

type job =
  | Job :
      { id : int
      ; work : unit -> 'a
      ; label : string option
      ; claimed : bool Atomic.t
      ; outcome : 'a outcome slot Atomic.t
      }
      -> job

(* What the layers above supply: see [start]. *)
type wiring =
  { on_failure : exn -> unit
  ; keeps_own_domain : unit -> bool
  }

type host =
  | Not_started
  | Running of wiring
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
  then fill outcome Unserved
  else fill outcome (Served (Error (Host_failed exn, Printexc.get_callstack 0)))
;;

let fail_host exn =
  (match Atomic.exchange state (Failed exn) with
   | Running { on_failure; keeps_own_domain = _ } -> on_failure exn
   | Not_started | Failed _ -> ());
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
let serve ~on_domain_start () =
  on_domain_start ();
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
              fill outcome (Served result);
              unregister id);
          loop ()
        in
        loop ()))
  with
  | () -> fail_host (Failure "system-thread host scheduler returned")
  | exception exn -> fail_host exn
;;

let start ~on_domain_start ~on_failure ~keeps_own_domain () =
  if Atomic.compare_and_set state Not_started (Running { on_failure; keeps_own_domain })
  then (
    try ignore (Domain.spawn (serve ~on_domain_start) : unit Domain.t) with
    | exn -> fail_host exn)
;;

let run ?label work =
  match Execution_context.current () with
  | Execution_context.Non_eio -> work ()
  | Execution_context.Eio_fiber ->
    let on_own_domain () = Eio_unix.run_in_systhread ?label work in
    (match Atomic.get state with
     | Not_started | Failed _ -> on_own_domain ()
     | Running { keeps_own_domain; on_failure = _ } when keeps_own_domain () ->
       on_own_domain ()
     | Running _ ->
       Eio.Fiber.check ();
       let outcome = Atomic.make Empty in
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
        | Not_started | Running _ -> ());
       (match await ~label:(Option.value label ~default:default_label) outcome with
        | Served (Ok value) -> value
        | Served (Error (exn, backtrace)) -> Printexc.raise_with_backtrace exn backtrace
        | Unserved ->
          unregister id;
          on_own_domain ()))
;;
