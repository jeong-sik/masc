module Pending = Keeper_oauth_pending

let keeper = "oauth-lock-fixture"
let provider_id = "fixture"

let table_and_publication () =
  let table = Pending.create ~base_path:"isolated-cross-context-oauth" () in
  let attachment = Pending.capture_attachment table ~keeper ~provider_id in
  let publication = match Pending.begin_catalog attachment with
    | Some publication -> publication
    | None -> Alcotest.fail "fresh attachment could not start discovery" in
  table, publication

let rec await_atomic flag =
  if not (Atomic.get flag) then (Eio.Fiber.yield (); await_atomic flag)

let await_atomic_in_domain flag =
  while not (Atomic.get flag) do Domain.cpu_relax () done

let with_catalog_file f =
  let path = Filename.temp_file "masc-oauth-lock-" ".json" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path)
    (fun () -> f path)

let write_catalog path =
  Out_channel.with_open_text path (fun out -> output_string out "{\"tools\":[]}");
  Ok ()

let test_domain_publication_precedes_eio_disconnect () =
  with_catalog_file @@ fun path ->
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let table, publication = table_and_publication () in
  let publishing = Atomic.make false in
  let release = Atomic.make false in
  let overlapped = Atomic.make false in
  let owner = Domain.spawn (fun () ->
    Alcotest.(check bool) "raw Domain has no Eio handler" true
      (Eio_guard.execution_context () = Eio_guard.Non_eio);
    Pending.publish_catalog publication ~write:(fun () ->
      Atomic.set publishing true;
      await_atomic_in_domain release;
      Fun.protect ~finally:(fun () -> Atomic.set publishing false)
        (fun () -> write_catalog path))) in
  let joined = ref false in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set release true;
      if not !joined then ignore (Domain.join owner))
    (fun () ->
      await_atomic publishing;
      let detached, resolve_detached = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        let result = Pending.retire_scope table ~keeper ~provider_id
          ~local_delete:(fun () ->
            Atomic.set overlapped (Atomic.get publishing);
            Unix.unlink path;
            Ok ()) in
        Eio.Promise.resolve resolve_detached result);
      (* A contended Eio caller must suspend so this fiber can release the
         raw owner. With unrelated locks, deletion already ran above. *)
      Eio.Fiber.yield ();
      Atomic.set release true;
      let result = Eio.Promise.await detached in
      joined := true;
      let publication_result = Domain.join owner in
      Alcotest.(check bool) "publication completed" true
        (publication_result = Pending.Published ());
      Alcotest.(check (result unit string)) "disconnect completed" (Ok ()) result;
      Alcotest.(check bool) "disconnect did not overlap publication" false
        (Atomic.get overlapped);
      Alcotest.(check bool) "late publication cannot restore deleted catalog" false
        (Sys.file_exists path))

let test_eio_publication_precedes_systhread_disconnect () =
  with_catalog_file @@ fun path ->
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let table, publication = table_and_publication () in
  let entered, resolve_entered = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let published, resolve_published = Eio.Promise.create () in
  let publishing = Atomic.make false in
  let attempted = Atomic.make false in
  let overlapped = Atomic.make false in
  Eio.Fiber.fork ~sw (fun () ->
    let result = Pending.publish_catalog publication ~write:(fun () ->
      Atomic.set publishing true;
      Fun.protect ~finally:(fun () -> Atomic.set publishing false) (fun () ->
        Eio.Promise.resolve resolve_entered ();
        Eio.Promise.await release;
        write_catalog path)) in
    Eio.Promise.resolve resolve_published result);
  Eio.Promise.await entered;
  let detached, resolve_detached = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result = Eio_unix.run_in_systhread (fun () ->
      Alcotest.(check bool) "system thread has no Eio handler" true
        (Eio_guard.execution_context () = Eio_guard.Non_eio);
      Atomic.set attempted true;
      Pending.retire_scope table ~keeper ~provider_id ~local_delete:(fun () ->
        Atomic.set overlapped (Atomic.get publishing);
        Unix.unlink path;
        Ok ())) in
    Eio.Promise.resolve resolve_detached result);
  await_atomic attempted;
  (* The publishing fiber suspended inside its callback; its table lock must
     exclude the system thread without blocking this Eio scheduler. *)
  Eio.Fiber.yield ();
  Eio.Promise.resolve resolve_release ();
  let publication_result = Eio.Promise.await published in
  let result = Eio.Promise.await detached in
  Alcotest.(check bool) "publication completed" true
    (publication_result = Pending.Published ());
  Alcotest.(check (result unit string)) "disconnect completed" (Ok ()) result;
  Alcotest.(check bool) "system thread did not overlap publication" false
    (Atomic.get overlapped);
  Alcotest.(check bool) "disconnect remains the final filesystem operation" false
    (Sys.file_exists path)

exception Cancel_publication

let test_cancelled_publication_releases_non_eio_caller () =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let table, publication = table_and_publication () in
  let context, resolve_context = Eio.Promise.create () in
  let entered, resolve_entered = Eio.Promise.create () in
  let cancelled, resolve_cancelled = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let was_cancelled =
      try
        Eio.Cancel.sub (fun cancel_context ->
          Eio.Promise.resolve resolve_context cancel_context;
          ignore (Pending.publish_catalog publication ~write:(fun () ->
            Eio.Promise.resolve resolve_entered ();
            Eio.Promise.await never;
            Ok ())); false)
      with Eio.Cancel.Cancelled _ -> true in
    Eio.Promise.resolve resolve_cancelled was_cancelled);
  let cancel_context = Eio.Promise.await context in
  Eio.Promise.await entered;
  Eio.Cancel.cancel cancel_context Cancel_publication;
  Alcotest.(check bool) "publication propagates cancellation" true
    (Eio.Promise.await cancelled);
  let result = Eio_unix.run_in_systhread (fun () ->
    Pending.retire_scope table ~keeper ~provider_id ~local_delete:(fun () -> Ok ())) in
  Alcotest.(check (result unit string)) "cancelled callback releases both gates"
    (Ok ()) result;
  let attachment = Pending.capture_attachment table ~keeper ~provider_id in
  Alcotest.(check bool) "Eio can reuse the table after the raw caller" true
    (Pending.attachment_current attachment)

let () =
  Alcotest.run "keeper-oauth-pending-cross-context"
    [ "publication and disconnect",
      [ Alcotest.test_case "raw Domain publication excludes Eio disconnect" `Quick
          test_domain_publication_precedes_eio_disconnect;
        Alcotest.test_case "suspended Eio publication excludes system thread" `Quick
          test_eio_publication_precedes_systhread_disconnect;
        Alcotest.test_case "cancelled publication releases cross-context lock" `Quick
          test_cancelled_publication_releases_non_eio_caller ] ]
