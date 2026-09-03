(** A keeper must not be offered its own authored tasks as claimable work.

    Without this exclusion the task board runs a closed positive feedback loop:
    a Keeper whose response to "an unclaimed task exists" is to create a
    routing or report task emits a new unclaimed Todo authored by itself, which
    re-satisfies the same trigger on the next observation. Observed live on
    2026-07-20: keeper "fixture-keeper" authored 367 of the active tasks, 272 of
    them the same four "Route g0700 #N" templates re-emitted once per iteration
    (#28..#90), none ever claimed since 2026-07-09. *)

module WOI = Masc.Keeper_world_observation_inputs

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ; "autoboot_enabled", `Bool false
        ])
  with
  | Ok meta -> meta
  | Error message -> Alcotest.fail ("meta fixture rejected: " ^ message)
;;

let task ?created_by ?(task_status = Masc_domain.Todo) id : Masc_domain.task =
  { id
  ; title = "Task " ^ id
  ; description = ""
  ; task_status
  ; priority = 3
  ; files = []
  ; created_at = "2026-07-20T00:00:00Z"
  ; created_by
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
  }
;;

(* [created_by] carries the keeper handle ([meta.name]), which is what the live
   backlog records ("fixture-keeper"), not the agent name. *)
let test_own_todo_is_self_authored () =
  let meta = make_meta "fixture-keeper" in
  Alcotest.(check bool)
    "a task authored by this keeper is self-authored"
    true
    (WOI.task_is_self_authored_todo
       ~meta
       (task ~created_by:"fixture-keeper" "task-1"))
;;

let test_other_keeper_task_is_not_self_authored () =
  let meta = make_meta "fixture-keeper" in
  Alcotest.(check bool)
    "a task authored by another keeper is not self-authored"
    false
    (WOI.task_is_self_authored_todo
       ~meta
       (task ~created_by:"omega" "task-2"))
;;

(* An unattributed task has no known author, so it must stay claimable rather
   than being silently withheld from everyone. *)
let test_unattributed_task_is_not_self_authored () =
  let meta = make_meta "fixture-keeper" in
  Alcotest.(check bool)
    "a task with no created_by is never excluded"
    false
    (WOI.task_is_self_authored_todo ~meta (task "task-3"))
;;

(* The agent name must not be mistaken for the author key: the live backlog
   stores "fixture-keeper", never "keeper-fixture-agent". Matching on the agent
   name would silently exclude nothing and leave the loop intact. *)
let test_agent_name_is_not_the_author_key () =
  let meta = make_meta "fixture-keeper" in
  Alcotest.(check bool)
    "agent-name-shaped author does not match the keeper handle"
    false
    (WOI.task_is_self_authored_todo
       ~meta
       (task ~created_by:"keeper-fixture-agent" "task-4"))
;;

let test_self_authored_verification_remains_eligible () =
  let meta = make_meta "fixture-keeper" in
  let task_status =
    Masc_domain.AwaitingVerification
      { assignee = "omega"
      ; started_at = "2026-07-20T00:00:00Z"
      ; submitted_at = "2026-07-20T01:00:00Z"
      ; intent = Complete_task
      ; verification_id = "verification-1"
      }
  in
  Alcotest.(check bool)
    "the task author may verify work submitted by another keeper"
    false
    (WOI.task_is_self_authored_todo
       ~meta
       (task ~created_by:"fixture-keeper" ~task_status "task-5"))
;;

let () =
  Alcotest.run
    "keeper_self_authored_task_exclusion"
    [ ( "task_is_self_authored_todo"
      , [ Alcotest.test_case "own Todo" `Quick test_own_todo_is_self_authored
        ; Alcotest.test_case
            "other keeper task"
            `Quick
            test_other_keeper_task_is_not_self_authored
        ; Alcotest.test_case
            "unattributed task"
            `Quick
            test_unattributed_task_is_not_self_authored
        ; Alcotest.test_case
            "agent name is not the author key"
            `Quick
            test_agent_name_is_not_the_author_key
        ; Alcotest.test_case
            "self-authored verification remains eligible"
            `Quick
            test_self_authored_verification_remains_eligible
        ] )
    ]
;;
