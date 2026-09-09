module Lib = Masc

open Alcotest

(* Every agent/message/task source extractor asks [identity_matches] whether
   a row belongs to the queried agent, so what it accepts is what a timeline
   can find. RFC-0393: a keeper is written under its keeper_name, and the one
   other form is the Activity_graph entity key ("keeper:<name>") -- a kind
   namespace, not a second spelling. Both are matched whole, so an agent
   whose name is a prefix of another's cannot collect its rows. *)

let m = Lib.Tool_agent_timeline.identity_matches

let test_short_handle () =
  check bool "short handle matches" true (m ~agent_name:"albini" "albini")

let test_keeper_prefix () =
  check bool "keeper: prefix form matches" true
    (m ~agent_name:"albini" "keeper:albini")

let test_non_match () =
  check bool "different agent does not match" false
    (m ~agent_name:"albini" "fixture");
  check bool "a different agent's entity key does not match" false
    (m ~agent_name:"albini" "keeper:fixture");
  check bool "empty candidate does not match" false (m ~agent_name:"albini" "")

let test_exact_per_form_not_substring () =
  (* Identity is exact per form, never substring: guards against a future
     regression to a [String.contains]-style match. *)
  check bool "longer handle sharing a prefix does not match" false
    (m ~agent_name:"albini" "albini-2");
  check bool "entity key of a longer name does not match" false
    (m ~agent_name:"base" "keeper:database")

let () =
  run "Tool_agent_timeline identity_matches"
    [
      ( "identity",
        [
          test_case "short handle" `Quick test_short_handle;
          test_case "keeper: prefix" `Quick test_keeper_prefix;
          test_case "non-match" `Quick test_non_match;
          test_case "exact per-form, not substring" `Quick
            test_exact_per_form_not_substring;
        ] );
    ]
