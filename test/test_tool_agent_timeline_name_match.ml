module Lib = Masc

open Alcotest

(* Regression for the agent-timeline global-zero bug: the agent/message/task
   source extractors compared the queried short handle ("albini") against
   store fields that persist the full actor id ("keeper-albini-agent"), so a
   live agent's rows were silently dropped. All extractors now route identity
   comparison through [identity_matches], which accepts every persisted form. *)

let m = Lib.Tool_agent_timeline.identity_matches

let test_short_handle () =
  check bool "short handle matches" true (m ~agent_name:"albini" "albini")

let test_full_actor_id () =
  check bool "full actor id matches (store form)" true
    (m ~agent_name:"albini" "keeper-albini-agent")

let test_keeper_prefix () =
  check bool "keeper: prefix form matches" true
    (m ~agent_name:"albini" "keeper:albini")

let test_non_match () =
  check bool "different agent does not match" false
    (m ~agent_name:"albini" "keeper-taskmaster-agent");
  check bool "empty candidate does not match" false (m ~agent_name:"albini" "")

let test_exact_per_form_not_substring () =
  (* Identity is exact per form, never substring: guards against a future
     regression to a [String.contains]-style match. *)
  check bool "longer handle sharing a prefix does not match" false
    (m ~agent_name:"albini" "albini-2");
  check bool "actor id of a different agent does not match" false
    (m ~agent_name:"base" "keeper-database-agent")

let () =
  run "Tool_agent_timeline identity_matches"
    [
      ( "identity",
        [
          test_case "short handle" `Quick test_short_handle;
          test_case "full actor id" `Quick test_full_actor_id;
          test_case "keeper: prefix" `Quick test_keeper_prefix;
          test_case "non-match" `Quick test_non_match;
          test_case "exact per-form, not substring" `Quick
            test_exact_per_form_not_substring;
        ] );
    ]
