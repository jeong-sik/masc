(** Test Event_log canonical id and ordering (P2-2). *)

open Masc

module Id_set = Set.Make (String)

let event_log_test name f =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let mono_clock = Eio.Stdenv.mono_clock env in
      let net = Eio.Stdenv.net env in
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
          Event_log.For_testing.reset ();
          f ()))))
;;

let publish_returns_id () =
  let id =
    Event_log.publish ~source:"test" ~kind:"ping" (`Assoc [ ("x", `Int 1) ])
  in
  Alcotest.(check bool) "id non-empty" true (String.length id > 0);
  Alcotest.(check bool) "id contains underscore" true (String.contains id '_')
;;

let recent_newest_first () =
  let id1 =
    Event_log.publish ~source:"test" ~kind:"first" (`Assoc [ ("n", `Int 1) ])
  in
  Unix.sleepf 0.001;
  let id2 =
    Event_log.publish ~source:"test" ~kind:"second" (`Assoc [ ("n", `Int 2) ])
  in
  let recent = Event_log.recent 2 in
  Alcotest.(check int) "two events" 2 (List.length recent);
  Alcotest.(check string) "first recent is newest" id2 (List.hd recent).id;
  Alcotest.(check string) "second recent is older" id1 (List.nth recent 1).id
;;

let recent_since_id_pagination () =
  let _id1 =
    Event_log.publish ~source:"test" ~kind:"a" (`Assoc [ ("n", `Int 1) ])
  in
  Unix.sleepf 0.001;
  let id2 =
    Event_log.publish ~source:"test" ~kind:"b" (`Assoc [ ("n", `Int 2) ])
  in
  Unix.sleepf 0.001;
  let id3 =
    Event_log.publish ~source:"test" ~kind:"c" (`Assoc [ ("n", `Int 3) ])
  in
  let recent = Event_log.recent ~since_id:id3 1 in
  Alcotest.(check int) "one event after id3" 1 (List.length recent);
  Alcotest.(check string) "event is id2" id2 (List.hd recent).id
;;

let to_json_roundtrip () =
  let id =
    Event_log.publish ~source:"rest" ~kind:"tool_call"
      (`Assoc [ ("tool", `String "x") ])
  in
  match Event_log.recent 1 with
  | [ e ] ->
    let json = Event_log.to_json e in
    Alcotest.(check string) "json id" id
      (Safe_ops.json_string ~default:"" "id" json);
    Alcotest.(check string) "json source" "rest"
      (Safe_ops.json_string ~default:"" "source" json);
    Alcotest.(check string) "json kind" "tool_call"
      (Safe_ops.json_string ~default:"" "kind" json)
  | _ -> Alcotest.fail "expected one event"
;;

let event_id (e : Event_log.event) = e.id

(* Golden equivalence: publish past capacity and check the log keeps the
   newest [capacity] ids, newest-first. The oracle is the full publish
   history accumulated newest-first; the ring must expose a prefix of it. *)
let recent_overflow_matches_oracle () =
  let cap = Event_log.For_testing.capacity in
  let overflow = 137 in
  let total = cap + overflow in
  let history_newest_first = ref [] in
  for i = 1 to total do
    let id =
      Event_log.publish ~source:"overflow" ~kind:"e" (`Assoc [ ("i", `Int i) ])
    in
    history_newest_first := id :: !history_newest_first
  done;
  let expected k = List.of_seq (Seq.take k (List.to_seq !history_newest_first)) in
  let got k = List.map event_id (Event_log.recent k) in
  Alcotest.(check int) "capped at capacity" cap (List.length (got cap));
  Alcotest.(check (list string)) "full window equals newest cap"
    (expected cap) (got cap);
  Alcotest.(check (list string)) "small prefix equals newest 5"
    (expected 5) (got 5);
  Alcotest.(check (list string)) "single newest" (expected 1) (got 1)
;;

(* Boundary: exactly [capacity] retains everything; [capacity + 1] evicts
   the oldest while keeping the count capped and the newest event first. *)
let recent_capacity_and_over_boundary () =
  let cap = Event_log.For_testing.capacity in
  let history_newest_first = ref [] in
  for i = 1 to cap do
    let id =
      Event_log.publish ~source:"cap" ~kind:"e" (`Assoc [ ("i", `Int i) ])
    in
    history_newest_first := id :: !history_newest_first
  done;
  let at_cap = List.map event_id (Event_log.recent cap) in
  Alcotest.(check int) "capacity events retained" cap (List.length at_cap);
  Alcotest.(check (list string)) "newest-first at capacity"
    !history_newest_first at_cap;
  (* Last element of a newest-first list is the oldest event. *)
  let oldest_id = List.nth at_cap (cap - 1) in
  let over_id =
    Event_log.publish ~source:"cap" ~kind:"e" (`Assoc [ ("i", `Int (cap + 1)) ])
  in
  let over = Event_log.recent cap in
  Alcotest.(check int) "still capped one past capacity" cap (List.length over);
  Alcotest.(check string) "newest is the new event" over_id (List.hd over).id;
  Alcotest.(check bool) "oldest evicted one past capacity" false
    (List.mem oldest_id (List.map event_id over))
;;

(* Concurrent publishers: each fiber writes into its own result slot to
   avoid test-side contention; the log itself is the shared resource under
   test. Below capacity nothing is evicted, so every id must survive
   exactly once. *)
let concurrent_publish_no_loss () =
  let fibers = 4 in
  let per_fiber = 100 in
  let total = fibers * per_fiber in
  let results = Array.make fibers [] in
  let publisher i () =
    let local = ref [] in
    for j = 1 to per_fiber do
      let id =
        Event_log.publish ~source:"concurrent" ~kind:"e"
          (`Assoc [ ("fiber", `Int i); ("j", `Int j) ])
      in
      local := id :: !local
    done;
    results.(i) <- !local
  in
  Eio.Fiber.all (List.init fibers (fun i -> publisher i));
  let published = List.concat (Array.to_list results) in
  Alcotest.(check int) "all publishes captured" total (List.length published);
  let published_set = Id_set.of_seq (List.to_seq published) in
  Alcotest.(check int) "all ids unique" total (Id_set.cardinal published_set);
  let retained = List.map event_id (Event_log.recent total) in
  Alcotest.(check int) "log retained every publish" total (List.length retained);
  Alcotest.(check bool) "log holds exactly the published ids" true
    (Id_set.equal published_set (Id_set.of_seq (List.to_seq retained)))
;;

let () =
  Alcotest.run
    "Event_log P2-2"
    [ ( "canonical_event_log"
      , [ event_log_test "publish returns canonical id" publish_returns_id
        ; event_log_test "recent newest first" recent_newest_first
        ; event_log_test "recent since_id pagination" recent_since_id_pagination
        ; event_log_test "to_json roundtrip" to_json_roundtrip
        ; event_log_test "recent overflow matches oracle"
            recent_overflow_matches_oracle
        ; event_log_test "recent capacity and over boundary"
            recent_capacity_and_over_boundary
        ; event_log_test "concurrent publish no loss" concurrent_publish_no_loss
        ] )
    ]
;;
