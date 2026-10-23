(* [Masc_tui_io_domain] alone. Most of the work handed to it is plain OCaml,
   so what is checked is where it runs and what comes back; one check sends a
   real request through the domain's own connection pool. *)

(* How long a check waits for the request domain. Every check finishes as
   soon as the domain answers; this is reached only when it never does, which
   is the regression each check exists to catch, and the check then fails
   instead of hanging. *)
let regression_deadline_s = 10.0

let with_io_domain f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let domain = Masc_tui_io_domain.start ~sw ~env in
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) regression_deadline_s
    (fun () -> f ~env domain)

let test_work_runs_on_another_domain () =
  with_io_domain @@ fun ~env:_ domain ->
  let caller = Domain.self () in
  let ran_on = Masc_tui_io_domain.run domain Domain.self in
  Alcotest.(check bool) "the work ran on a domain other than the caller's" true
    (ran_on <> caller)

(* The property the TUI needs. Its main loop can go a whole frame without
   reaching a scheduling point, and a request must not wait for one. The
   caller's domain spins without yielding until the work has run: work left
   as a fiber on that domain cannot run during the spin, and work run in place
   runs on that domain, which the work records. *)
let test_work_finishes_while_the_caller_never_yields () =
  with_io_domain @@ fun ~env:_ domain ->
  let caller = Domain.self () in
  let ran_on = Atomic.make None in
  let seen_while_spinning = ref false in
  Eio.Fiber.both
    (fun () ->
      Masc_tui_io_domain.run domain (fun () ->
        Atomic.set ran_on (Some (Domain.self ()))))
    (fun () ->
      let deadline = Unix.gettimeofday () +. regression_deadline_s in
      while Option.is_none (Atomic.get ran_on) && Unix.gettimeofday () < deadline do
        ()
      done;
      seen_while_spinning := Option.is_some (Atomic.get ran_on));
  Alcotest.(check bool) "the work ran before the caller's domain yielded" true
    !seen_while_spinning;
  Alcotest.(check bool) "and not on the caller's domain" true
    (Atomic.get ran_on <> Some caller)

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
  with_io_domain @@ fun ~env:_ domain ->
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
  Eio.Promise.await released

(* A caller that leaves while its job is still queued. The domain is held by
   a job that spins without yielding, so the second job cannot be taken
   before its caller is gone. Jobs start in the order they were added, so a
   third job reads whether the second one's work ever ran. *)
let test_a_job_whose_caller_left_in_the_queue_never_starts () =
  with_io_domain @@ fun ~env:_ domain ->
  let holding = Atomic.make false in
  let release = Atomic.make false in
  let left_work_ran = Atomic.make false in
  Eio.Fiber.both
    (fun () ->
      Masc_tui_io_domain.run domain (fun () ->
        Atomic.set holding true;
        let deadline = Unix.gettimeofday () +. regression_deadline_s in
        while (not (Atomic.get release)) && Unix.gettimeofday () < deadline do
          Domain.cpu_relax ()
        done))
    (fun () ->
      while not (Atomic.get holding) do
        Eio.Fiber.yield ()
      done;
      Eio.Fiber.first
        (fun () ->
          Masc_tui_io_domain.run domain (fun () -> Atomic.set left_work_ran true))
        (fun () -> ());
      Atomic.set release true);
  Alcotest.(check bool) "the left job's work never ran" false
    (Masc_tui_io_domain.run domain (fun () -> Atomic.get left_work_ran))

(* One loopback server on the caller's domain, answering every request with
   [body]. *)
let serve ?(before_response = fun () -> ()) ~sw ~net body =
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> Alcotest.fail "the loopback listener has no TCP port"
  in
  let callback _conn _request _body =
    before_response ();
    Cohttp_eio.Server.respond_string ~status:`OK ~body ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d/" port

(* What the TUI does: the request goes through the pool the domain opened
   for itself, not the caller's. *)
let test_a_request_through_the_domain_comes_back () =
  with_io_domain @@ fun ~env domain ->
  Eio.Switch.run @@ fun sw ->
  let url = serve ~sw ~net:(Eio.Stdenv.net env) "answered" in
  let clock = Eio.Stdenv.clock env in
  match
    Masc_tui_io_domain.run domain (fun () ->
      Masc_http_client.get_sync ~clock ~timeout_sec:regression_deadline_s ~url
        ~headers:[] ())
  with
  | Ok (status, body) ->
      Alcotest.(check (pair int string)) "the server's answer" (200, "answered")
        (status, body)
  | Error detail -> Alcotest.failf "the request failed: %s" detail

(* An owned history read has no overall deadline. Even a peer that accepts
   the GET and never answers must be released when its caller leaves. Wait
   for the real request to reach the peer before withdrawing the caller. *)
let test_cancelling_an_unanswered_request_releases_the_work () =
  with_io_domain @@ fun ~env domain ->
  Eio.Switch.run @@ fun sw ->
  let received, set_received = Eio.Promise.create () in
  let released, set_released = Eio.Promise.create () in
  let requests = ref 0 in
  let before_response () =
    incr requests;
    if !requests=1 then begin
      Eio.Promise.resolve set_received ();
      Eio.Fiber.await_cancel ()
    end
  in
  let url = serve ~before_response ~sw ~net:(Eio.Stdenv.net env) "after cancellation" in
  let clock = Eio.Stdenv.clock env in
  let inflight () = Masc_tui_io_domain.run domain (fun () ->
    Masc_http_client.all_domain_pools () |> List.fold_left (fun total (_, pool) ->
      total + (Masc_http_client.Pool.stats pool).total_inflight) 0) in
  let original_inflight = inflight () in
  Eio.Fiber.first
    (fun () ->
      Masc_tui_io_domain.run domain (fun () ->
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve set_released ())
          (fun () ->
            ignore (Masc_http_client.get_sync ~clock ~url ~headers:[] ());
            Alcotest.fail "the unanswered request returned before cancellation")))
    (fun () -> Eio.Promise.await received);
  Eio.Promise.await released;
  Alcotest.(check int) "cancellation releases the actual pool borrower"
    original_inflight (inflight ());
  match Masc_tui_io_domain.run domain (fun () ->
    Masc_http_client.get_sync ~clock ~url ~headers:[] ()) with
  | Ok answer -> Alcotest.(check (pair int string))
      "the same request domain serves the next read" (200, "after cancellation") answer
  | Error detail -> Alcotest.failf "request after cancellation failed: %s" detail

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
          Alcotest.test_case "a job whose caller left in the queue never starts"
            `Quick test_a_job_whose_caller_left_in_the_queue_never_starts;
          Alcotest.test_case "a request through the domain comes back" `Quick
            test_a_request_through_the_domain_comes_back;
          Alcotest.test_case "cancelling an unanswered request releases the work" `Quick
            test_cancelling_an_unanswered_request_releases_the_work;
        ] );
    ]
