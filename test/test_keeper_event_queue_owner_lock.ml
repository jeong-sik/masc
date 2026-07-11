(** Deterministic concurrency contracts for durable event-queue owner locks.

    Every interleaving below is controlled by an explicit [Atomic] barrier.
    There are no timing thresholds: a participant either reaches the protected
    transition or remains blocked until the owning Keeper lane releases it. *)

module Persistence = Keeper_event_queue_persistence
module Queue = Keeper_event_queue

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir prefix f =
  let base_path = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () -> f base_path)
;;

let require_ok label = function
  | Ok value -> value
  | Error message -> Alcotest.failf "%s: %s" label message
;;

let require_some label = function
  | Some value -> value
  | None -> Alcotest.failf "%s: missing result" label
;;

let rec await_atomic flag =
  if Atomic.get flag
  then ()
  else (
    Eio.Fiber.yield ();
    await_atomic flag)
;;

let await_atomic_in_domain flag =
  while not (Atomic.get flag) do
    Domain.cpu_relax ()
  done
;;

let stimulus ~post_id ~arrived_at : Queue.stimulus =
  { post_id; urgency = Queue.Normal; arrived_at; payload = Queue.Bootstrap }
;;

let post_ids queue =
  Queue.to_list queue
  |> List.map (fun (item : Queue.stimulus) -> item.post_id)
;;

let snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue.json"
;;

let inflight_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue-inflight.json"
;;

let persist_queue_file path queue =
  Queue.queue_to_yojson queue
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file_atomic path
  |> require_ok ("write split-state fixture " ^ path)
;;

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let int_field name json =
  match json_field name json with
  | Some (`Int value) -> value
  | _ -> Alcotest.failf "expected int field %S" name
;;

let list_field name json =
  match json_field name json with
  | Some (`List values) -> values
  | _ -> Alcotest.failf "expected list field %S" name
;;

let string_field name json =
  match json_field name json with
  | Some (`String value) -> value
  | _ -> Alcotest.failf "expected string field %S" name
;;

let keeper_summary keeper_name json =
  match
    list_field "keepers" json
    |> List.find_opt (fun item ->
      String.equal keeper_name (string_field "keeper_name" item))
  with
  | Some summary -> summary
  | None -> Alcotest.failf "missing fleet summary for keeper %S" keeper_name
;;

let test_canonical_owner_and_cross_context_isolation () =
  with_temp_dir "event-queue-owner-a" (fun base_a ->
    with_temp_dir "event-queue-owner-b" (fun base_b ->
      let keeper_a = "owner_a" in
      let keeper_b = "owner_b" in
      let base_a_masc = Filename.concat base_a Common.masc_dirname in
      (match
         Persistence.update_result
           ~base_path:base_a
           ~keeper_name:"owner.with.untyped-separator"
           (fun queue -> queue)
       with
       | Error _ -> ()
       | Ok () -> Alcotest.fail "invalid Keeper identity resolved an owner lock");

      let held = Atomic.make false in
      let release = Atomic.make false in
      let holder_result = ref None in
      let holder =
        Domain.spawn (fun () ->
          Persistence.update_result
            ~base_path:base_a_masc
            ~keeper_name:keeper_a
            (fun queue ->
               Atomic.set held true;
               await_atomic_in_domain release;
               Queue.enqueue queue (stimulus ~post_id:"domain-a" ~arrived_at:1.0)))
      in
      Fun.protect
        ~finally:(fun () ->
          Atomic.set release true;
          holder_result := Some (Domain.join holder))
        (fun () ->
           await_atomic held;
           Eio.Switch.run (fun sw ->
             let same_attempted = Atomic.make false in
             let same_entered = Atomic.make false in
             let same_done, resolve_same_done = Eio.Promise.create () in
             Eio.Fiber.fork ~sw (fun () ->
               Atomic.set same_attempted true;
               let result =
                 Persistence.update_result
                   ~base_path:base_a
                   ~keeper_name:keeper_a
                   (fun queue ->
                      Atomic.set same_entered true;
                      Queue.enqueue
                        queue
                        (stimulus ~post_id:"fiber-a" ~arrived_at:2.0))
               in
               Eio.Promise.resolve resolve_same_done result);
             await_atomic same_attempted;
             Eio.Fiber.yield ();
             Alcotest.(check bool)
               "same owner cannot enter while Domain owns it"
               false
               (Atomic.get same_entered);

             Persistence.update_result
               ~base_path:base_a
               ~keeper_name:keeper_b
               (fun queue ->
                  Queue.enqueue queue (stimulus ~post_id:"other-keeper" ~arrived_at:3.0))
             |> require_ok "different keeper proceeds while owner A is held";
             Persistence.update_result
               ~base_path:base_b
               ~keeper_name:keeper_a
               (fun queue ->
                  Queue.enqueue queue (stimulus ~post_id:"other-base" ~arrived_at:4.0))
             |> require_ok "different BasePath proceeds while owner A is held";

             Atomic.set release true;
             Eio.Promise.await same_done
             |> require_ok "same-owner fiber completes after release"));
      require_some "Domain holder join" !holder_result
      |> require_ok "Domain holder update";

      Alcotest.(check (list string))
        "BasePath aliases preserve both serialized updates exactly once"
        [ "domain-a"; "fiber-a" ]
        (Persistence.load ~base_path:base_a ~keeper_name:keeper_a |> post_ids);
      Alcotest.(check (list string))
        "different keeper persisted independently"
        [ "other-keeper" ]
        (Persistence.load ~base_path:base_a ~keeper_name:keeper_b |> post_ids);
      Alcotest.(check (list string))
        "different BasePath persisted independently"
        [ "other-base" ]
        (Persistence.load ~base_path:base_b ~keeper_name:keeper_a |> post_ids)))
;;

let test_cancelled_waiter_does_not_leak_owner_lock () =
  with_temp_dir "event-queue-owner-cancel" (fun base_path ->
    let keeper_name = "cancel_owner" in
    let peer_name = "cancel_peer" in
    let held = Atomic.make false in
    let release = Atomic.make false in
    let holder_result = ref None in
    let holder =
      Domain.spawn (fun () ->
        Persistence.update_result ~base_path ~keeper_name (fun queue ->
          Atomic.set held true;
          await_atomic_in_domain release;
          queue))
    in
    Fun.protect
      ~finally:(fun () ->
        Atomic.set release true;
        holder_result := Some (Domain.join holder))
      (fun () ->
         await_atomic held;
         let waiter_started = Atomic.make false in
         let waiter_entered = Atomic.make false in
         let first_result =
           Eio.Fiber.first
             (fun () ->
                Atomic.set waiter_started true;
                (match
                   Persistence.update_result ~base_path ~keeper_name (fun queue ->
                     Atomic.set waiter_entered true;
                     Queue.enqueue
                       queue
                       (stimulus ~post_id:"cancelled" ~arrived_at:5.0))
                 with
                 | Ok () -> `Waiter_committed
                 | Error message -> `Waiter_failed message))
             (fun () ->
                await_atomic waiter_started;
                `Cancel_waiter)
         in
         (match first_result with
          | `Cancel_waiter -> ()
          | `Waiter_committed ->
            Alcotest.fail "same-owner waiter committed before its owner released"
          | `Waiter_failed message ->
            Alcotest.failf
              "same-owner waiter failed instead of remaining blocked: %s"
              message);
         Alcotest.(check bool)
           "cancelled waiter never entered persistence transform"
           false
           (Atomic.get waiter_entered);
         Persistence.update_result ~base_path ~keeper_name:peer_name (fun queue ->
           Queue.enqueue
             queue
             (stimulus ~post_id:"peer-during-cancel" ~arrived_at:5.5))
         |> require_ok "peer owner proceeds while cancelled owner remains held";
         Atomic.set release true);
    require_some "cancel holder join" !holder_result
    |> require_ok "cancel holder update";

    Persistence.update_result ~base_path ~keeper_name (fun queue ->
      Queue.enqueue queue (stimulus ~post_id:"survivor" ~arrived_at:6.0))
    |> require_ok "owner remains usable after waiter cancellation";
    Alcotest.(check (list string))
      "cancelled waiter committed no durable stimulus"
      [ "survivor" ]
      (Persistence.load ~base_path ~keeper_name |> post_ids);
    Alcotest.(check (list string))
      "peer owner persisted during cancellation"
      [ "peer-during-cancel" ]
      (Persistence.load ~base_path ~keeper_name:peer_name |> post_ids))
;;

let test_exception_does_not_poison_owner_or_other_lane () =
  with_temp_dir "event-queue-owner-exception" (fun base_path ->
    let keeper_a = "exception_owner" in
    let keeper_b = "exception_peer" in
    (match
       Persistence.update_result ~base_path ~keeper_name:keeper_a (fun _queue ->
         raise Exit)
     with
     | Error _ -> ()
     | Ok () -> Alcotest.fail "raising transform was reported as committed");
    Persistence.update_result ~base_path ~keeper_name:keeper_a (fun queue ->
      Queue.enqueue queue (stimulus ~post_id:"same-owner" ~arrived_at:7.0))
    |> require_ok "same owner remains usable after exception";
    Persistence.update_result ~base_path ~keeper_name:keeper_b (fun queue ->
      Queue.enqueue queue (stimulus ~post_id:"peer-owner" ~arrived_at:8.0))
    |> require_ok "peer owner remains independent after exception";
    Alcotest.(check (list string))
      "same owner durable state after exception"
      [ "same-owner" ]
      (Persistence.load ~base_path ~keeper_name:keeper_a |> post_ids);
    Alcotest.(check (list string))
      "peer owner durable state after exception"
      [ "peer-owner" ]
      (Persistence.load ~base_path ~keeper_name:keeper_b |> post_ids))
;;

let test_fleet_summary_never_observes_split_owner_pair () =
  with_temp_dir "event-queue-owner-summary" (fun base_path ->
    let keeper_name = "summary_owner" in
    let pending = stimulus ~post_id:"pending" ~arrived_at:9.0 in
    let inflight = stimulus ~post_id:"inflight" ~arrived_at:10.0 in
    Persistence.persist
      ~base_path
      ~keeper_name
      (Queue.enqueue Queue.empty pending);
    Persistence.record_inflight ~base_path ~keeper_name [ inflight ];
    let pending_path = snapshot_path ~base_path ~keeper_name in
    let inflight_path = inflight_path ~base_path ~keeper_name in
    let split_ready = Atomic.make false in
    let release = Atomic.make false in
    let writer_result = ref None in
    let writer =
      Domain.spawn (fun () ->
        Persistence.update_result ~base_path ~keeper_name (fun _queue ->
          persist_queue_file pending_path Queue.empty;
          Atomic.set split_ready true;
          await_atomic_in_domain release;
          persist_queue_file inflight_path Queue.empty;
          Queue.empty))
    in
    Fun.protect
      ~finally:(fun () ->
        Atomic.set release true;
        writer_result := Some (Domain.join writer))
      (fun () ->
         await_atomic split_ready;
         Eio.Switch.run (fun sw ->
           let summary_started = Atomic.make false in
           let summary_done = Atomic.make false in
           let summary, resolve_summary = Eio.Promise.create () in
           Eio.Fiber.fork ~sw (fun () ->
             Atomic.set summary_started true;
             let json =
               Persistence.fleet_summary_json ~now:20.0 ~base_path
             in
             Atomic.set summary_done true;
             Eio.Promise.resolve resolve_summary json);
           await_atomic summary_started;
           Eio.Fiber.yield ();
           Alcotest.(check bool)
             "summary blocks while one owner pair is split"
             false
             (Atomic.get summary_done);
           Atomic.set release true;
           let json = Eio.Promise.await summary in
           let keeper = keeper_summary keeper_name json in
           Alcotest.(check int)
             "summary pending count comes from completed pair"
             0
             (int_field "pending_count" keeper);
           Alcotest.(check int)
             "summary inflight count comes from completed pair"
             0
             (int_field "inflight_count" keeper)));
    require_some "split writer join" !writer_result
    |> require_ok "split writer update")
;;

let () =
  Eio_main.run (fun _env ->
    test_canonical_owner_and_cross_context_isolation ();
    test_cancelled_waiter_does_not_leak_owner_lock ();
    test_exception_does_not_poison_owner_or_other_lane ();
    test_fleet_summary_never_observes_split_owner_pair ());
  print_endline "test_keeper_event_queue_owner_lock: OK"
;;
