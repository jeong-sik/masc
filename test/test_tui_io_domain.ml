(* [Masc_tui_io_domain] alone: the work handed to it is plain OCaml, so what
   is checked is where it runs and what comes back, not HTTP. *)

(* How long a check waits for something the request domain does. Every check
   finishes as soon as that happens; this is reached only when the work never
   ran on the request domain, which is the regression each check exists to
   catch. *)
let regression_deadline_s = 10.0

let with_io_domain f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw -> f ~env (Masc_tui_io_domain.start ~sw ~env)

let test_work_runs_on_another_domain () =
  with_io_domain @@ fun ~env:_ domain ->
  let caller = Domain.self () in
  let ran_on = Masc_tui_io_domain.run domain Domain.self in
  Alcotest.(check bool) "the work ran on a domain other than the caller's" true
    (ran_on <> caller)

(* The property the TUI needs. Its main loop can go a whole frame without
   reaching a scheduling point, and a request must not wait for one. Here the
   caller's domain spins without yielding until the work has run, so the work
   can only finish if it runs somewhere else. *)
let test_work_finishes_while_the_caller_never_yields () =
  with_io_domain @@ fun ~env:_ domain ->
  let ran = Atomic.make false in
  let seen_while_spinning = ref false in
  Eio.Fiber.both
    (fun () -> Masc_tui_io_domain.run domain (fun () -> Atomic.set ran true))
    (fun () ->
      let deadline = Unix.gettimeofday () +. regression_deadline_s in
      while (not (Atomic.get ran)) && Unix.gettimeofday () < deadline do
        ()
      done;
      seen_while_spinning := Atomic.get ran);
  Alcotest.(check bool) "the work ran before the caller's domain yielded" true
    !seen_while_spinning

exception Work_failed of string

let test_an_exception_from_the_work_is_raised_to_the_caller () =
  with_io_domain @@ fun ~env:_ domain ->
  Alcotest.check_raises "the work's exception reaches the caller"
    (Work_failed "refused") (fun () ->
      Masc_tui_io_domain.run domain (fun () -> raise (Work_failed "refused")))

(* A refresh that is abandoned -- the operator moved to another surface --
   cancels its fiber. The work it handed over must stop too, or the request
   domain keeps reading answers nobody will look at. *)
let test_cancelling_the_caller_cancels_the_work () =
  with_io_domain @@ fun ~env domain ->
  let started, set_started = Eio.Promise.create () in
  let released, set_released = Eio.Promise.create () in
  Eio.Fiber.first
    (fun () ->
      Masc_tui_io_domain.run domain (fun () ->
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve set_released ())
          (fun () ->
            Eio.Promise.resolve set_started ();
            Eio.Fiber.await_cancel ())))
    (fun () -> Eio.Promise.await started);
  match
    Eio.Time.with_timeout (Eio.Stdenv.clock env) regression_deadline_s
      (fun () -> Ok (Eio.Promise.await released))
  with
  | Ok () -> ()
  | Error `Timeout -> Alcotest.fail "the work outlived its cancelled caller"

let () =
  Alcotest.run "tui_io_domain"
    [
      ( "request domain",
        [
          Alcotest.test_case "work runs on another domain" `Quick
            test_work_runs_on_another_domain;
          Alcotest.test_case "work finishes while the caller never yields" `Quick
            test_work_finishes_while_the_caller_never_yields;
          Alcotest.test_case "an exception from the work is raised to the caller"
            `Quick test_an_exception_from_the_work_is_raised_to_the_caller;
          Alcotest.test_case "cancelling the caller cancels the work" `Quick
            test_cancelling_the_caller_cancels_the_work;
        ] );
    ]
