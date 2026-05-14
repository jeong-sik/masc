(** Unit tests for Chronicle_librarian (RFC-0035 PR-5,
    Master Report Dim02 P1 §2.4). *)

open Masc_mcp.Chronicle_librarian
module CE = Masc_mcp.Chronicle_event

let make_event ?(id = "ev-x") ?(event_type = CE.Ev_keeper_step)
    ?(timestamp = 1_000) ?(session_id = "s1") ?(tags = []) ?(summary = "default")
    ?(detail = None) () : CE.t =
  {
    id;
    event_type;
    timestamp;
    actor = { kind = CE.Ak_keeper; id = "k1"; display_name = "Keeper" };
    target = { kind = CE.Tk_file; uri = "lib/x.ml"; range = None };
    content = { summary; detail; diff = None; metadata = [] };
    context = {
      session_id;
      parent_event_id = None;
      related_event_ids = [];
      tags;
      project_state = None;
    };
    intent = None;
  }

let test_tokenise_basic () =
  Alcotest.(check (list string))
    "alphanumeric and underscore preserved, others split"
    [ "hello"; "world_42"; "ok" ]
    (tokenise "Hello, world_42! Ok.");
  Alcotest.(check (list string))
    "single-char tokens dropped" [ "ab"; "cd" ] (tokenise "a ab. cd e f");
  Alcotest.(check int) "empty input yields empty list" 0
    (List.length (tokenise ""))

let test_search_empty () =
  let result = search empty ~query:[ "x" ] () in
  Alcotest.(check int) "empty store → empty result" 0 (List.length result)

let test_search_single_match () =
  let ev =
    make_event ~id:"e1" ~tags:[ "auth" ] ~summary:"fix login bug" ()
  in
  let s = of_list [ ev ] in
  let result = search s ~query:[ "login"; "bug" ] () in
  Alcotest.(check int) "single result" 1 (List.length result);
  let item, score = List.hd result in
  Alcotest.(check string) "id preserved" "e1" item.id;
  Alcotest.(check bool) "non-zero score on overlap" true (score > 0.0)

let test_search_orders_by_relevance () =
  let high =
    make_event ~id:"high" ~tags:[ "login"; "auth" ]
      ~summary:"login bug fix" ()
  in
  let mid = make_event ~id:"mid" ~tags:[ "login" ] ~summary:"misc" () in
  let low =
    make_event ~id:"low" ~tags:[ "deploy" ] ~summary:"release notes" ()
  in
  let s = of_list [ low; mid; high ] in
  let result = search s ~query:[ "login"; "bug" ] () in
  let order = List.map (fun (ev, _) -> ev.CE.id) result in
  Alcotest.(check (list string))
    "ordered descending by relevance"
    [ "high"; "mid"; "low" ]
    order

let test_search_respects_limit () =
  let evs =
    [ make_event ~id:"a" ~tags:[ "x" ] ()
    ; make_event ~id:"b" ~tags:[ "x" ] ()
    ; make_event ~id:"c" ~tags:[ "x" ] ()
    ]
  in
  let s = of_list evs in
  let result = search s ~query:[ "x" ] ~limit:2 () in
  Alcotest.(check int) "limit clamps result count" 2 (List.length result)

let test_recency_decay_with_default_now () =
  let stale =
    make_event ~id:"stale" ~tags:[ "feat" ] ~timestamp:1_000 ()
  in
  let fresh =
    make_event ~id:"fresh" ~tags:[ "feat" ]
      ~timestamp:(1_000 + (86_400 * 1000))
        (* one day later in ms *)
      ()
  in
  let s = of_list [ stale; fresh ] in
  let result = search s ~query:[ "feat" ] () in
  let order = List.map (fun (ev, _) -> ev.CE.id) result in
  Alcotest.(check (list string))
    "fresher event ranks ahead of older one"
    [ "fresh"; "stale" ]
    order

let test_search_explicit_now_overrides_default () =
  let ev =
    make_event ~id:"e" ~tags:[ "x" ] ~timestamp:1_000 ()
  in
  let s = of_list [ ev ] in
  let _, score_now =
    List.hd (search s ~query:[ "x" ] ~now_ms:1_001 ())
  in
  let _, score_far =
    List.hd
      (search s ~query:[ "x" ]
         ~now_ms:(1_000 + (86_400 * 1000 * 10))
         ())
  in
  Alcotest.(check bool)
    "fresh now → higher score than far now" true
    (score_now > score_far)

let test_filter_by_event_type () =
  let events =
    [ make_event ~id:"a" ~event_type:CE.Ev_keeper_step ()
    ; make_event ~id:"b" ~event_type:CE.Ev_test_passed ()
    ; make_event ~id:"c" ~event_type:CE.Ev_keeper_step ()
    ]
  in
  let s = of_list events in
  let kept = filter_by_event_type s [ CE.Ev_keeper_step ] in
  let ids = List.map (fun e -> e.CE.id) kept in
  Alcotest.(check (list string))
    "only keeper.step events" [ "a"; "c" ] ids

let test_filter_by_session () =
  let events =
    [ make_event ~id:"a" ~session_id:"s1" ()
    ; make_event ~id:"b" ~session_id:"s2" ()
    ; make_event ~id:"c" ~session_id:"s1" ()
    ]
  in
  let s = of_list events in
  let kept = filter_by_session s ~session_id:"s1" in
  let ids = List.map (fun e -> e.CE.id) kept in
  Alcotest.(check (list string)) "s1 only" [ "a"; "c" ] ids

let test_filter_by_time_range () =
  let events =
    [ make_event ~id:"early" ~timestamp:100 ()
    ; make_event ~id:"mid" ~timestamp:500 ()
    ; make_event ~id:"late" ~timestamp:900 ()
    ]
  in
  let s = of_list events in
  let kept = filter_by_time_range s ~from_ms:200 ~to_ms:800 in
  let ids = List.map (fun e -> e.CE.id) kept in
  Alcotest.(check (list string))
    "inside [200, 800] inclusive" [ "mid" ] ids

let test_add_preserves_insertion_order () =
  let s =
    empty
    |> Fun.flip add (make_event ~id:"first" ())
    |> Fun.flip add (make_event ~id:"second" ())
    |> Fun.flip add (make_event ~id:"third" ())
  in
  let ids = List.map (fun e -> e.CE.id) (to_list s) in
  Alcotest.(check (list string))
    "insertion order preserved"
    [ "first"; "second"; "third" ]
    ids

let () =
  Alcotest.run "chronicle_librarian"
    [
      ( "tokenise",
        [ Alcotest.test_case "basic" `Quick test_tokenise_basic ] );
      ( "search",
        [
          Alcotest.test_case "empty store" `Quick test_search_empty;
          Alcotest.test_case "single match" `Quick test_search_single_match;
          Alcotest.test_case "orders by relevance" `Quick
            test_search_orders_by_relevance;
          Alcotest.test_case "respects limit" `Quick
            test_search_respects_limit;
          Alcotest.test_case "recency decay default now" `Quick
            test_recency_decay_with_default_now;
          Alcotest.test_case "explicit now overrides default" `Quick
            test_search_explicit_now_overrides_default;
        ] );
      ( "filters",
        [
          Alcotest.test_case "by event_type" `Quick
            test_filter_by_event_type;
          Alcotest.test_case "by session" `Quick test_filter_by_session;
          Alcotest.test_case "by time range" `Quick
            test_filter_by_time_range;
        ] );
      ( "store",
        [
          Alcotest.test_case "add preserves order" `Quick
            test_add_preserves_insertion_order;
        ] );
    ]
