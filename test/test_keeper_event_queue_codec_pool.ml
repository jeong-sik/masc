module Codec = Keeper_event_queue_snapshot_codec
module Persistence = Keeper_event_queue_persistence
module Queue = Keeper_event_queue
module State = Keeper_event_queue_state

let require_ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail

let rec remove_tree path =
  if Sys.is_directory path then begin
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  end else Unix.unlink path

let with_temp_dir f =
  let base_path = Filename.temp_dir "keeper-codec-pool-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)

(* Owner transactions mask fiber cancellation. A scheduler timeout cannot
   unwind the pool/owner cycle under test, so run it in a child with a fatal
   OS alarm. The parent has created no Eio scheduler or worker domains when
   it forks. This bounds a failed test, not Keeper execution. *)
let in_child label f =
  flush_all ();
  match Unix.fork () with
  | 0 ->
      Sys.set_signal Sys.sigalrm Sys.Signal_default;
      ignore (Unix.alarm 20 : int);
      (match f () with
       | () -> Unix._exit 0
       | exception exn ->
           Printf.eprintf "%s: %s\n%!" label (Printexc.to_string exn);
           Unix._exit 1)
  | child ->
      (match snd (Unix.waitpid [] child) with
       | Unix.WEXITED 0 -> ()
       | Unix.WEXITED code -> Alcotest.failf "%s: child exited %d" label code
       | Unix.WSIGNALED signal when signal = Sys.sigalrm ->
           Alcotest.failf "%s: codec or owner transaction did not finish" label
       | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
           Alcotest.failf "%s: child received signal %d" label signal)

let stimulus post_id : Queue.stimulus =
  { post_id; urgency = Queue.Normal; arrived_at = 1.; payload = Queue.Bootstrap }

let pending_ids state =
  State.pending state |> Queue.to_list
  |> List.map (fun (item : Queue.stimulus) -> item.post_id)

let with_shared_pool pool f =
  let previous = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some pool -> Domain_pool_ref.set pool
      | None -> Domain_pool_ref.clear_for_tests ())
    (fun () ->
      Domain_pool_ref.set pool;
      Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) f)

let test_update_progress_with_shared_owner_waiter () =
  with_temp_dir (fun base_path ->
    in_child "snapshot writer and shared-pool reader" (fun () ->
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let domain_mgr = Eio.Stdenv.domain_mgr env in
          let shared = Domain_pool.create ~sw ~domain_count:1 domain_mgr in
          Codec.install ~sw domain_mgr;
          with_shared_pool shared (fun () ->
            let keeper_name = "codec-owner" in
            let owner_held, resolve_owner_held = Eio.Promise.create () in
            let reader_started, resolve_reader_started = Eio.Promise.create () in
            let caller = Domain.self () in
            Eio.Fiber.both
              (fun () ->
                Persistence.update_checked_result ~base_path ~keeper_name
                  (fun pending ->
                    (* This callback is inside the real durable owner lock.
                       Do not return the changed queue until the one shared
                       worker is occupied by a reader needing this owner. *)
                    Eio.Promise.resolve resolve_owner_held ();
                    Eio.Promise.await reader_started;
                    Ok (Queue.enqueue pending (stimulus "persisted-after-encode")))
                |> require_ok "writer committed with shared worker occupied")
              (fun () ->
                Eio.Promise.await owner_held;
                let worker_domain, loaded =
                  Domain_pool.submit_cpu shared (fun () ->
                    Eio.Promise.resolve resolve_reader_started ();
                    let loaded = Persistence.load_state_result ~base_path ~keeper_name in
                    Domain.self (), loaded)
                in
                Alcotest.(check bool) "reader ran on the shared worker" true
                  (worker_domain <> caller);
                let loaded = require_ok "reader resumed after writer commit" loaded in
                Alcotest.(check (list string)) "reader sees the committed input"
                  ["persisted-after-encode"] (pending_ids loaded));
            let loaded =
              Persistence.load_state_result ~base_path ~keeper_name
              |> require_ok "owner remains readable"
            in
            Alcotest.(check int64) "one durable queue revision" 1L (State.revision loaded);
            (* Read the file independently of the persistence snapshot cache. *)
            let path =
              Filename.concat
                (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
                Persistence.snapshot_filename
            in
            let durable = Yojson.Safe.from_file path |> State.of_yojson
              |> require_ok "snapshot bytes decode as durable state" in
            Alcotest.(check (list string)) "the changed queue reached the snapshot file"
              ["persisted-after-encode"] (pending_ids durable))))))

let test_encoding_bytes_and_switch_lifetime () =
  in_child "snapshot codec switch lifetime" (fun () ->
    let state = State.with_pending
        (Queue.enqueue Queue.empty (stimulus "unicode-한글-invalid-\255-\192")) State.empty in
    let previous_encoding value =
      value |> Safe_ops.sanitize_json_utf8 |> Yojson.Safe.pretty_to_string
    in
    let expected_state = previous_encoding (State.to_yojson state) in
    let check_encoding phase =
      Alcotest.(check string) (phase ^ ": state construction, sanitizing and pretty-print bytes")
        expected_state (Codec.encode_state state)
    in
    check_encoding "before Eio installation";
    Eio_main.run (fun env ->
      check_encoding "uninstalled Eio caller";
      Eio.Switch.run (fun sw ->
        Codec.install ~sw (Eio.Stdenv.domain_mgr env);
        check_encoding "installed codec");
      (* These calls would hang or fail if release retained the stopped pool. *)
      check_encoding "after switch release";
      Eio.Switch.run (fun sw ->
        Codec.install ~sw (Eio.Stdenv.domain_mgr env);
        check_encoding "subsequent installation");
      check_encoding "after subsequent release");
    check_encoding "after Eio shutdown")

exception Shutdown_requested

type writer_outcome =
  | Not_finished
  | Finished of (unit, string) result
  | Cancelled

let test_cancelled_switch_releases_protected_writer () =
  with_temp_dir (fun base_path ->
    in_child "codec cancellation while owner is held" (fun () ->
      Eio_main.run (fun env ->
        let keeper_name = "cancelled-codec-owner" in
        Persistence.update_result ~base_path ~keeper_name
          (fun pending -> Queue.enqueue pending (stimulus "prior-input"))
        |> require_ok "seed the prior durable state";
        let outcome = ref Not_finished in
        let shutdown_propagated =
          match Eio.Switch.run (fun sw ->
            Codec.install ~sw (Eio.Stdenv.domain_mgr env);
            let owner_held, resolve_owner_held = Eio.Promise.create () in
            let cancelled, resolve_cancelled = Eio.Promise.create () in
            Eio.Fiber.fork ~sw (fun () ->
              match Persistence.update_checked_result ~base_path ~keeper_name
                (fun pending ->
                  Eio.Promise.resolve resolve_owner_held ();
                  (* The owner lock masks cancellation here. The changed
                     queue reaches encoding only after shutdown was requested. *)
                  Eio.Promise.await cancelled;
                  Ok (Queue.enqueue pending (stimulus "next-input")))
              with
              | result -> outcome := Finished result
              | exception (Eio.Cancel.Cancelled _ as exn) ->
                  outcome := Cancelled;
                  raise exn);
            Eio.Promise.await owner_held;
            Eio.Cancel.protect (fun () ->
              Eio.Switch.fail sw Shutdown_requested;
              Eio.Promise.resolve resolve_cancelled ()))
          with
          | () -> false
          | exception Shutdown_requested -> true
        in
        Alcotest.(check bool) "the failed switch terminated and propagated shutdown"
          true shutdown_propagated;
        (match !outcome with
         | Finished (Ok ()) | Cancelled -> ()
         | Finished (Error detail) -> Alcotest.failf "writer failed unexpectedly: %s" detail
         | Not_finished -> Alcotest.fail "switch returned before the writer finished");
        let durable = Persistence.load_state_result ~base_path ~keeper_name
          |> require_ok "owner is readable after cancellation" in
        (* Cancellation may win before encoding, or after the complete commit.
           Either outcome must retain an intact authoritative snapshot. *)
        (match pending_ids durable with
         | ["prior-input"] ->
             Alcotest.(check int64) "cancelled update leaves prior revision" 1L
               (State.revision durable)
         | ["prior-input"; "next-input"] ->
             Alcotest.(check int64) "completed update has exactly one new revision" 2L
               (State.revision durable)
         | ids -> Alcotest.failf "shutdown lost or duplicated pending input: %s"
                    (String.concat ", " ids));
        let after_shutdown = State.to_yojson State.empty
          |> Safe_ops.sanitize_json_utf8 |> Yojson.Safe.pretty_to_string in
        Alcotest.(check string) "released cancelled codec can encode again"
          after_shutdown
          (Codec.encode_state State.empty))))

let () =
  Alcotest.run "Keeper event queue snapshot codec"
    [ "persistence",
      [ Alcotest.test_case "owner writer progresses past shared-pool waiter" `Quick
          test_update_progress_with_shared_owner_waiter
      ; Alcotest.test_case "encoding bytes survive codec switch lifetime" `Quick
          test_encoding_bytes_and_switch_lifetime
      ; Alcotest.test_case "cancelled codec releases the protected owner writer" `Quick
          test_cancelled_switch_releases_protected_writer
      ]
    ]
