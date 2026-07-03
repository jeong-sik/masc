(* test_keeper_chat_coalescing.ml — chat queue coalescing (task-759).

   Messages that accumulate while a keeper's turn is in flight must
   drain as ONE same-source FIFO batch and merge into a single message;
   different reply routes (dashboard vs Discord vs Slack, or different
   channel/user) must never merge. Also covers the read-only
   [Keeper_turn_admission.in_flight] accessor the consumer gates on. *)

open Masc

let failures = ref 0

let temp_dir prefix = Filename.temp_dir prefix ""

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let check name cond =
  if cond
  then Printf.printf "  ✓ %s\n%!" name
  else (
    incr failures;
    Printf.printf "  ✗ %s\n%!" name)
;;

let raises f =
  try
    f ();
    false
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ -> true
;;

let msg ?(attachments = []) ~content ~ts source =
  { Keeper_chat_queue.content; user_blocks = []; attachments; timestamp = ts; source }
;;

let attachment ~id =
  { Keeper_chat_store.id
  ; att_type = "file"
  ; name = id ^ ".txt"
  ; size = 1
  ; mime_type = "text/plain"
  ; data = "d"
  }
;;

let image_block ~attachment_id =
  Keeper_multimodal_input.User_image
    { attachment_id; name = attachment_id ^ ".png"; mime_type = "image/png"; size = None }
;;

let contents batch = List.map (fun m -> m.Keeper_chat_queue.content) batch

let chat_snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "chat-queue.json"
;;

let test_same_source () =
  Printf.printf "Test 1: same_source pairs reply routes correctly\n%!";
  let open Keeper_chat_queue in
  check "dashboard ~ dashboard" (same_source Dashboard Dashboard);
  check
    "same Discord channel+user"
    (same_source
       (Discord { channel_id = "c1"; user_id = "u1" })
       (Discord { channel_id = "c1"; user_id = "u1" }));
  check
    "different Discord user does not merge"
    (not
       (same_source
          (Discord { channel_id = "c1"; user_id = "u1" })
          (Discord { channel_id = "c1"; user_id = "u2" })));
  check
    "different Slack channel does not merge"
    (not
       (same_source
          (Slack { channel = "a"; user_id = "u" })
          (Slack { channel = "b"; user_id = "u" })));
  check
    "dashboard does not merge with Discord"
    (not (same_source Dashboard (Discord { channel_id = "c"; user_id = "u" })))
;;

let test_dequeue_batch_runs () =
  Printf.printf "Test 2: dequeue_batch drains same-source runs in FIFO order\n%!";
  let keeper_name = "coalesce-runs" in
  Keeper_chat_queue.clear ~keeper_name;
  let discord = Keeper_chat_queue.Discord { channel_id = "c"; user_id = "u" } in
  List.iter
    (Keeper_chat_queue.enqueue ~keeper_name)
    [ msg ~content:"d1" ~ts:1.0 Keeper_chat_queue.Dashboard
    ; msg ~content:"d2" ~ts:2.0 Keeper_chat_queue.Dashboard
    ; msg ~content:"x1" ~ts:3.0 discord
    ; msg ~content:"d3" ~ts:4.0 Keeper_chat_queue.Dashboard
    ];
  let first = Keeper_chat_queue.dequeue_batch ~keeper_name in
  check "first batch is the dashboard run" (contents first = [ "d1"; "d2" ]);
  let second = Keeper_chat_queue.dequeue_batch ~keeper_name in
  check "second batch stops at the route boundary" (contents second = [ "x1" ]);
  let third = Keeper_chat_queue.dequeue_batch ~keeper_name in
  check "third batch picks up the trailing dashboard message"
    (contents third = [ "d3" ]);
  check "queue is drained" (Keeper_chat_queue.dequeue_batch ~keeper_name = []);
  check "length is zero after drain" (Keeper_chat_queue.length ~keeper_name = 0)
;;

let test_merge_batch () =
  Printf.printf "Test 3: merge_batch coalesces content and attachments\n%!";
  let single = msg ~content:"only" ~ts:5.0 Keeper_chat_queue.Dashboard in
  (match Keeper_chat_queue.merge_batch [ single ] with
   | Some m -> check "singleton is returned unchanged" (m = single)
   | None -> check "singleton is returned unchanged" false);
  check "empty batch merges to None" (Keeper_chat_queue.merge_batch [] = None);
  let batch =
    [ msg ~content:"first" ~ts:1.0 ~attachments:[ attachment ~id:"a" ]
        Keeper_chat_queue.Dashboard
    ; { (msg ~content:"second" ~ts:2.0 Keeper_chat_queue.Dashboard) with
        Keeper_chat_queue.user_blocks = [ image_block ~attachment_id:"att-img" ] }
    ; msg ~content:"third" ~ts:3.0 ~attachments:[ attachment ~id:"b" ]
        Keeper_chat_queue.Dashboard
    ]
  in
  match Keeper_chat_queue.merge_batch batch with
  | None -> check "merged batch exists" false
  | Some m ->
    check
      "contents join in arrival order with blank lines"
      (String.equal m.Keeper_chat_queue.content "first\n\nsecond\n\nthird");
    check
      "attachments concatenate in order"
      (List.map
         (fun (a : Keeper_chat_store.attachment) -> a.Keeper_chat_store.id)
         m.Keeper_chat_queue.attachments
       = [ "a"; "b" ]);
    check
      "semantic user blocks concatenate in order"
      (Keeper_multimodal_input.modalities m.Keeper_chat_queue.user_blocks
       = [ "image" ]);
    check "timestamp is the first message's" (m.Keeper_chat_queue.timestamp = 1.0);
    check
      "source is the shared route"
      (Keeper_chat_queue.same_source m.Keeper_chat_queue.source
         Keeper_chat_queue.Dashboard)
;;

let test_in_flight_accessor () =
  Printf.printf "Test 4: in_flight reflects the slot the consumer gates on\n%!";
  Keeper_turn_admission.For_testing.reset ();
  let base_path = "/tmp/masc_test_chat_coalescing" in
  let keeper_name = "coalesce-keeper" in
  check
    "unknown keeper reads as free"
    (Keeper_turn_admission.in_flight ~base_path ~keeper_name = None);
  Eio.Switch.run (fun sw ->
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Keeper_turn_admission.run_serialized ~base_path ~keeper_name (fun () ->
           Eio.Promise.resolve set_started ();
           Eio.Promise.await release)));
    Eio.Promise.await started;
    (match Keeper_turn_admission.in_flight ~base_path ~keeper_name with
     | Some { Keeper_turn_admission.lane = Chat; _ } ->
       check "in-flight chat turn is visible" true
     | Some _ | None -> check "in-flight chat turn is visible" false);
    Eio.Promise.resolve set_release ());
  check
    "slot reads as free again after release"
    (Keeper_turn_admission.in_flight ~base_path ~keeper_name = None)
;;

let test_persistence_replay () =
  Printf.printf "Test 5: queued chat messages persist and replay after restart\n%!";
  let base_path = temp_dir "keeper-chat-queue-persistence" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "chat-queue-persistence" in
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.configure_persistence ~base_path;
      Keeper_chat_queue.enqueue
        ~keeper_name
        { (msg ~content:"persist-1" ~ts:1.0 ~attachments:[ attachment ~id:"persist-a" ]
             Keeper_chat_queue.Dashboard)
          with
          Keeper_chat_queue.user_blocks = [ image_block ~attachment_id:"persist-a" ]
        };
      Keeper_chat_queue.enqueue ~keeper_name
        (msg ~content:"persist-2" ~ts:2.0 Keeper_chat_queue.Dashboard);
      check
        "snapshot file is written"
        (Sys.file_exists (chat_snapshot_path ~base_path ~keeper_name));
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.configure_persistence ~base_path;
      check
        "restored keeper name is visible to consumer"
        (List.mem keeper_name (Keeper_chat_queue.all_keeper_names ()));
      let batch = Keeper_chat_queue.dequeue_batch ~keeper_name in
      check "replayed batch preserves FIFO content" (contents batch = [ "persist-1"; "persist-2" ]);
      check "queue is empty after replay drain" (Keeper_chat_queue.length ~keeper_name = 0);
      (match batch with
       | first :: _ ->
         check
           "replayed source route is preserved"
           (Keeper_chat_queue.same_source
              first.Keeper_chat_queue.source
              Keeper_chat_queue.Dashboard);
         check
           "replayed attachment survives"
           (List.map
              (fun (a : Keeper_chat_store.attachment) -> a.Keeper_chat_store.id)
              first.Keeper_chat_queue.attachments
            = [ "persist-a" ]);
         check
           "replayed semantic user block survives"
           (Keeper_multimodal_input.modalities first.Keeper_chat_queue.user_blocks
            = [ "image" ])
       | [] -> check "replayed batch is non-empty" false);
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.configure_persistence ~base_path;
      check
        "empty persisted queue does not replay after drain"
        (Keeper_chat_queue.dequeue_batch ~keeper_name = []))
;;

let test_persist_failure_does_not_acknowledge_dequeue () =
  Printf.printf "Test 6: failed dequeue persist keeps queue and snapshot aligned\n%!";
  let base_path = temp_dir "keeper-chat-queue-persist-failure" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "chat-queue-persist-failure" in
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.configure_persistence ~base_path;
      Keeper_chat_queue.enqueue ~keeper_name
        (msg ~content:"must-not-ack" ~ts:1.0 Keeper_chat_queue.Dashboard);
      Keeper_chat_queue.For_testing.fail_next_persist ();
      check
        "dequeue raises before acknowledging when snapshot rewrite fails"
        (raises (fun () -> ignore (Keeper_chat_queue.dequeue_batch ~keeper_name)));
      check
        "in-memory queue rolls back after failed dequeue persist"
        (Keeper_chat_queue.length ~keeper_name = 1);
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.configure_persistence ~base_path;
      check
        "stale snapshot replays the unacknowledged message exactly once"
        (contents (Keeper_chat_queue.dequeue_batch ~keeper_name) = [ "must-not-ack" ]))
;;

let test_configure_persistence_prepends_snapshot_to_live_queue () =
  Printf.printf "Test 7: restart snapshot prepends ahead of live bootstrap messages\n%!";
  let base_path = temp_dir "keeper-chat-queue-prepend" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "chat-queue-prepend" in
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.configure_persistence ~base_path;
      Keeper_chat_queue.enqueue ~keeper_name
        (msg ~content:"snapshot-before-restart" ~ts:1.0 Keeper_chat_queue.Dashboard);
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.enqueue ~keeper_name
        (msg ~content:"live-during-bootstrap" ~ts:2.0 Keeper_chat_queue.Dashboard);
      Keeper_chat_queue.configure_persistence ~base_path;
      check
        "snapshot messages are not dropped when live queue is non-empty"
        (contents (Keeper_chat_queue.dequeue_batch ~keeper_name)
         = [ "snapshot-before-restart"; "live-during-bootstrap" ]))
;;

let test_remove_matching_single_from_head_run () =
  Printf.printf "Test 8: remove_matching drops exactly one head-run match\n%!";
  let keeper_name = "remove-matching-single" in
  Keeper_chat_queue.clear ~keeper_name;
  let dash content ts = msg ~content ~ts Keeper_chat_queue.Dashboard in
  (* Two structurally identical dashboard messages plus a same-source tail, all
     inside one head run. Removing the duplicate target drops exactly one copy. *)
  let dup = dash "dup" 1.0 in
  List.iter (Keeper_chat_queue.enqueue ~keeper_name) [ dup; dup; dash "tail" 3.0 ];
  (match Keeper_chat_queue.remove_matching ~keeper_name dup with
   | `Removed -> check "duplicate head-run message reports Removed" true
   | `Not_found | `Persist_failed _ ->
     check "duplicate head-run message reports Removed" false);
  check "exactly one duplicate is removed" (Keeper_chat_queue.length ~keeper_name = 2);
  check
    "the other duplicate and tail survive in FIFO order"
    (contents (Keeper_chat_queue.dequeue_batch ~keeper_name) = [ "dup"; "tail" ]);
  (* A match in the middle of the head run is removed without touching the
     messages before it. *)
  Keeper_chat_queue.clear ~keeper_name;
  let mid = dash "mid" 2.0 in
  List.iter
    (Keeper_chat_queue.enqueue ~keeper_name)
    [ dash "head" 1.0; mid; dash "after" 3.0 ];
  (match Keeper_chat_queue.remove_matching ~keeper_name mid with
   | `Removed -> check "mid-run match reports Removed" true
   | `Not_found | `Persist_failed _ -> check "mid-run match reports Removed" false);
  check
    "mid-run removal keeps the surrounding messages"
    (contents (Keeper_chat_queue.dequeue_batch ~keeper_name) = [ "head"; "after" ])
;;

let test_remove_matching_not_found () =
  Printf.printf "Test 9: remove_matching reports Not_found off the head run\n%!";
  let absent = msg ~content:"anything" ~ts:1.0 Keeper_chat_queue.Dashboard in
  check
    "absent keeper reports Not_found"
    (Keeper_chat_queue.remove_matching ~keeper_name:"remove-matching-absent" absent
     = `Not_found);
  let keeper_name = "remove-matching-notfound" in
  Keeper_chat_queue.clear ~keeper_name;
  check
    "empty queue reports Not_found"
    (Keeper_chat_queue.remove_matching ~keeper_name absent = `Not_found);
  (* A dashboard head run followed by a Discord message: the Discord target is
     past the head-run boundary, so it is not removed and the queue is intact. *)
  let discord = Keeper_chat_queue.Discord { channel_id = "c"; user_id = "u" } in
  let beyond = msg ~content:"x1" ~ts:2.0 discord in
  List.iter
    (Keeper_chat_queue.enqueue ~keeper_name)
    [ msg ~content:"d1" ~ts:1.0 Keeper_chat_queue.Dashboard; beyond ];
  check
    "match beyond the head-run boundary reports Not_found"
    (Keeper_chat_queue.remove_matching ~keeper_name beyond = `Not_found);
  check "queue is unchanged after Not_found" (Keeper_chat_queue.length ~keeper_name = 2);
  check
    "an unqueued target reports Not_found"
    (Keeper_chat_queue.remove_matching ~keeper_name
       (msg ~content:"nope" ~ts:9.0 Keeper_chat_queue.Dashboard)
     = `Not_found);
  Keeper_chat_queue.clear ~keeper_name;
  let with_block =
    { (msg ~content:"same-text" ~ts:3.0 Keeper_chat_queue.Dashboard) with
      Keeper_chat_queue.user_blocks = [ image_block ~attachment_id:"img-1" ] }
  in
  let without_block = msg ~content:"same-text" ~ts:3.0 Keeper_chat_queue.Dashboard in
  Keeper_chat_queue.enqueue ~keeper_name with_block;
  check
    "same text/source/timestamp but different user_blocks reports Not_found"
    (Keeper_chat_queue.remove_matching ~keeper_name without_block = `Not_found);
  check
    "near-match payload stays queued"
    (match Keeper_chat_queue.dequeue_batch ~keeper_name with
     | [ msg ] ->
       Keeper_multimodal_input.modalities msg.Keeper_chat_queue.user_blocks = [ "image" ]
     | _ -> false)
;;

let test_remove_matching_persist_failure_aborts () =
  Printf.printf "Test 10: failed remove_matching persist leaves the queue intact\n%!";
  let base_path = temp_dir "keeper-chat-queue-remove-persist-failure" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "chat-queue-remove-persist-failure" in
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.configure_persistence ~base_path;
      let target = msg ~content:"keep-me" ~ts:1.0 Keeper_chat_queue.Dashboard in
      List.iter
        (Keeper_chat_queue.enqueue ~keeper_name)
        [ target; msg ~content:"keep-me-too" ~ts:2.0 Keeper_chat_queue.Dashboard ];
      Keeper_chat_queue.For_testing.fail_next_persist ();
      (match Keeper_chat_queue.remove_matching ~keeper_name target with
       | `Persist_failed _ ->
         check "snapshot rewrite failure reports Persist_failed" true
       | `Removed | `Not_found ->
         check "snapshot rewrite failure reports Persist_failed" false);
      check
        "in-memory queue rolls back after failed remove persist"
        (Keeper_chat_queue.length ~keeper_name = 2);
      Keeper_chat_queue.For_testing.reset ();
      Keeper_chat_queue.configure_persistence ~base_path;
      check
        "stale snapshot still replays both messages exactly once"
        (contents (Keeper_chat_queue.dequeue_batch ~keeper_name)
         = [ "keep-me"; "keep-me-too" ]))
;;

let test_remove_matching_dequeue_batch_exactly_once () =
  Printf.printf
    "Test 11: dequeue_batch and remove_matching answer each message once\n%!";
  (* Single-domain Eio serializes remove_matching and dequeue_batch through the
     shared per-keeper mutex; the two argument orders below enumerate the two
     possible linearizations. In each, the target must be answered by exactly
     one path — removed XOR present in the dequeued batch, never both, never
     neither — and the queue must drain fully. *)
  let discord = Keeper_chat_queue.Discord { channel_id = "c"; user_id = "u" } in
  let m1 = msg ~content:"m1" ~ts:1.0 discord in
  let m2 = msg ~content:"m2" ~ts:2.0 discord in
  let in_batch content batch =
    List.exists (fun m -> String.equal m.Keeper_chat_queue.content content) batch
  in
  let run_race label ~remove_first =
    let keeper_name = "remove-race-" ^ label in
    Keeper_chat_queue.clear ~keeper_name;
    List.iter (Keeper_chat_queue.enqueue ~keeper_name) [ m1; m2 ];
    let removed = ref `Not_found in
    let batch = ref [] in
    let do_remove () =
      removed := Keeper_chat_queue.remove_matching ~keeper_name m1
    in
    let do_dequeue () = batch := Keeper_chat_queue.dequeue_batch ~keeper_name in
    if remove_first
    then Eio.Fiber.both do_remove do_dequeue
    else Eio.Fiber.both do_dequeue do_remove;
    let m1_removed = !removed = `Removed in
    let m1_dequeued = in_batch "m1" !batch in
    check (label ^ ": m1 is answered by exactly one path") (m1_removed <> m1_dequeued);
    check (label ^ ": m2 ends up in the dequeued batch") (in_batch "m2" !batch);
    check (label ^ ": queue is fully drained") (Keeper_chat_queue.length ~keeper_name = 0)
  in
  run_race "remove-first" ~remove_first:true;
  run_race "dequeue-first" ~remove_first:false
;;

let () =
  Eio_main.run @@ fun _env ->
  test_same_source ();
  test_dequeue_batch_runs ();
  test_merge_batch ();
  test_in_flight_accessor ();
  test_persistence_replay ();
  test_persist_failure_does_not_acknowledge_dequeue ();
  test_configure_persistence_prepends_snapshot_to_live_queue ();
  test_remove_matching_single_from_head_run ();
  test_remove_matching_not_found ();
  test_remove_matching_persist_failure_aborts ();
  test_remove_matching_dequeue_batch_exactly_once ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_chat_coalescing checks passed\n%!"
;;
