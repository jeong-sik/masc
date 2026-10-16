type t = { jobs : (unit -> unit) Eio.Stream.t }

(* A caller adds its job and goes straight to waiting for the reply. With a
   bounded stream an add can block until the domain takes the job, and on the
   main domain a blocked fiber resumes only at the loop's next pass: one pass
   lost before the request even starts. The callers are TUI fibers, each
   holding at most one job, so nothing here grows without them. *)
let unbounded = max_int

let start ~sw ~env =
  let jobs = Eio.Stream.create unbounded in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
      (* A minor collection stops every domain, so this one collects on the
         heap size the rest of the process collects on ([Domain_pool]). *)
      Domain_pool.tune_minor_heap ();
      Eio.Switch.run (fun io_sw ->
        Masc_http_client.with_scoped_pool ~sw:io_sw ~env (fun () ->
          while true do
            let job = Eio.Stream.take jobs in
            Eio.Fiber.fork ~sw:io_sw job
          done;
          `Stop_daemon))));
  { jobs }

type 'a outcome = ('a, exn * Printexc.raw_backtrace) result

let run t work =
  let (reply : _ outcome Eio.Promise.t), set_reply = Eio.Promise.create () in
  let abandoned, abandon = Eio.Promise.create () in
  let job () =
    Eio.Fiber.first
      (fun () ->
        let outcome =
          match work () with
          | value -> Ok value
          | exception (Eio.Cancel.Cancelled _ as cancelled) ->
              (* The caller left or the domain is closing; neither has anyone
                 waiting for an answer. *)
              raise cancelled
          | exception failure -> Error (failure, Printexc.get_raw_backtrace ())
        in
        Eio.Promise.resolve set_reply outcome)
      (fun () -> Eio.Promise.await abandoned)
  in
  Eio.Stream.add t.jobs job;
  match Eio.Promise.await reply with
  | Ok value -> value
  | Error (failure, backtrace) -> Printexc.raise_with_backtrace failure backtrace
  | exception (Eio.Cancel.Cancelled _ as cancelled) ->
      ignore (Eio.Promise.try_resolve abandon () : bool);
      raise cancelled
