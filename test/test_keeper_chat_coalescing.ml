(* test_keeper_chat_coalescing.ml — chat queue coalescing (task-759).

   Messages that accumulate while a keeper's turn is in flight must
   drain as ONE same-source FIFO batch and merge into a single message;
   different reply routes (dashboard vs Discord vs Slack, or different
   channel/user) must never merge. Also covers the read-only
   [Keeper_turn_admission.in_flight] accessor the consumer gates on. *)

open Masc

let failures = ref 0

let check name cond =
  if cond
  then Printf.printf "  ✓ %s\n%!" name
  else (
    incr failures;
    Printf.printf "  ✗ %s\n%!" name)
;;

let msg ?(attachments = []) ~content ~ts source =
  { Keeper_chat_queue.content; attachments; timestamp = ts; source }
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

let contents batch = List.map (fun m -> m.Keeper_chat_queue.content) batch

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
    ; msg ~content:"second" ~ts:2.0 Keeper_chat_queue.Dashboard
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

let () =
  Eio_main.run @@ fun _env ->
  test_same_source ();
  test_dequeue_batch_runs ();
  test_merge_batch ();
  test_in_flight_accessor ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_chat_coalescing checks passed\n%!"
;;
