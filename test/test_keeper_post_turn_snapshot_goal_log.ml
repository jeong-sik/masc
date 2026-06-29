open Masc

module Post_turn = Keeper_post_turn.For_testing

let test_invalid_snapshot_goal_fingerprint_is_redacted () =
  let goal_id =
    "long persona continuity goal that must never be dumped into warn logs"
  in
  let fingerprint = Post_turn.invalid_snapshot_goal_fingerprint goal_id in
  Alcotest.(check int) "fingerprint length" 12 (String.length fingerprint);
  Alcotest.(check bool)
    "fingerprint is hex"
    true
    (String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       fingerprint);
  let msg =
    Post_turn.invalid_snapshot_goal_warning_message
      ~keeper_name:"sangsu"
      ~goal_id
  in
  Alcotest.(check bool)
    "message omits raw goal"
    false
    (String_util.contains_substring msg goal_id);
  Alcotest.(check bool)
    "message includes hash"
    true
    (String_util.contains_substring msg "invalid_goal_hash=")

let test_invalid_snapshot_goal_log_dedupe () =
  Post_turn.reset_invalid_snapshot_goal_log_dedupe ();
  Fun.protect
    ~finally:Post_turn.reset_invalid_snapshot_goal_log_dedupe
    (fun () ->
       Alcotest.(check bool)
         "first occurrence logs"
         true
         (Post_turn.should_log_invalid_snapshot_goal
            ~keeper_name:"sangsu"
            ~goal_id:"ghost-goal");
       Alcotest.(check bool)
         "duplicate suppressed"
         false
         (Post_turn.should_log_invalid_snapshot_goal
            ~keeper_name:"sangsu"
            ~goal_id:"ghost-goal");
       Alcotest.(check bool)
         "different keeper logs"
         true
         (Post_turn.should_log_invalid_snapshot_goal
            ~keeper_name:"verifier"
            ~goal_id:"ghost-goal"))

let test_metric_name_is_first_class () =
  Alcotest.(check string)
    "metric name"
    "masc_keeper_state_snapshot_invalid_goal_total"
    Keeper_metrics.(to_string StateSnapshotInvalidGoal)

let () =
  Alcotest.run
    "keeper_post_turn_snapshot_goal_log"
    [ ( "invalid-goal"
      , [ Alcotest.test_case
            "fingerprint redacts raw goal"
            `Quick
            test_invalid_snapshot_goal_fingerprint_is_redacted
        ; Alcotest.test_case
            "dedupe suppresses repeated warning"
            `Quick
            test_invalid_snapshot_goal_log_dedupe
        ; Alcotest.test_case
            "metric name is registered"
            `Quick
            test_metric_name_is_first_class
        ] )
    ]
