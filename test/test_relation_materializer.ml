(** Test Relation_materializer retired hooks. *)

open Masc

let test_on_agent_session_ended_noop () =
  Relation_materializer.on_agent_session_ended ~leaving_agent:"alice"
    ~active_agents:[ "bob"; "charlie" ];
  Alcotest.(check unit) "noop does not raise" () ()
;;

let test_on_task_done_noop () =
  Relation_materializer.on_task_done ~assignee:"alice"
    ~active_agents:[ "bob"; "charlie" ];
  Alcotest.(check unit) "noop does not raise" () ()
;;

let () =
  Alcotest.run
    "Relation_materializer"
    [ ( "lifecycle_hooks"
      , [ Alcotest.test_case "session ended noop" `Quick
            test_on_agent_session_ended_noop
        ; Alcotest.test_case "task done noop" `Quick
            test_on_task_done_noop
        ] )
    ]
;;
