(** Test Relation_materializer GraphQL batching (P2-3). *)

open Masc

let batch_empty_peers () =
  let mutation =
    Relation_materializer.build_batch_mutation ~agent:"alice" ~peers:[]
      ~context:"test"
  in
  Alcotest.(check string) "empty peers -> empty mutation body" "mutation {  }"
    mutation
;;

let batch_includes_agent_and_peers () =
  let mutation =
    Relation_materializer.build_batch_mutation ~agent:"alice"
      ~peers:[ "bob"; "charlie" ] ~context:"session"
  in
  Alcotest.(check bool) "contains mutation keyword" true
    (String_util.contains_substring mutation "mutation");
  Alcotest.(check bool) "contains agent alice" true
    (String_util.contains_substring mutation "alice");
  Alcotest.(check bool) "contains peer bob" true
    (String_util.contains_substring mutation "bob");
  Alcotest.(check bool) "contains peer charlie" true
    (String_util.contains_substring mutation "charlie");
  Alcotest.(check bool) "contains context" true
    (String_util.contains_substring mutation "session");
  Alcotest.(check bool) "contains alias c0" true
    (String_util.contains_substring mutation "c0:");
  Alcotest.(check bool) "contains alias c1" true
    (String_util.contains_substring mutation "c1:")
;;

let batch_escapes_quotes () =
  let mutation =
    Relation_materializer.build_batch_mutation ~agent:"a\"lice"
      ~peers:[ "bo\"b" ] ~context:"c\"tx"
  in
  Alcotest.(check bool) "escaped agent quote" true
    (String_util.contains_substring mutation "a\\\"lice");
  Alcotest.(check bool) "escaped peer quote" true
    (String_util.contains_substring mutation "bo\\\"b");
  Alcotest.(check bool) "escaped context quote" true
    (String_util.contains_substring mutation "c\\\"tx")
;;

let () =
  Alcotest.run
    "Relation_materializer P2-3"
    [ ( "graphql_batching"
      , [ Alcotest.test_case "empty peers" `Quick batch_empty_peers
        ; Alcotest.test_case "includes agent and peers" `Quick
            batch_includes_agent_and_peers
        ; Alcotest.test_case "escapes quotes" `Quick batch_escapes_quotes
        ] )
    ]
;;
