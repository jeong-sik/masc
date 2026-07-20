(** A keeper must not be offered its own authored tasks as claimable work.

    Without this exclusion the task board runs a closed positive feedback loop:
    a persona whose response to "an unclaimed task exists" is to create a
    routing or report task emits a new unclaimed Todo authored by itself, which
    re-satisfies the same trigger on the next observation. Observed live on
    2026-07-20: keeper "taskmaster" authored 367 of the active tasks, 272 of
    them the same four "Route g0700 #N" templates re-emitted once per iteration
    (#28..#90), none ever claimed since 2026-07-09. *)

module WOI = Masc.Keeper_world_observation_inputs

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
        ; "trace_id", `String ("trace-" ^ name)
        ; "autoboot_enabled", `Bool false
        ])
  with
  | Ok meta -> meta
  | Error message -> Alcotest.fail ("meta fixture rejected: " ^ message)
;;

let task ?created_by id : Masc_domain.task =
  { id
  ; title = "Task " ^ id
  ; description = ""
  ; task_status = Todo
  ; priority = 3
  ; files = []
  ; created_at = "2026-07-20T00:00:00Z"
  ; created_by
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }
;;

(* [created_by] carries the keeper handle ([meta.name]), which is what the live
   backlog records ("taskmaster"), not the agent name. *)
let test_own_task_is_self_authored () =
  let meta = make_meta "taskmaster" in
  Alcotest.(check bool)
    "a task authored by this keeper is self-authored"
    true
    (WOI.task_is_self_authored ~meta (task ~created_by:"taskmaster" "task-1"))
;;

let test_other_keeper_task_is_not_self_authored () =
  let meta = make_meta "taskmaster" in
  Alcotest.(check bool)
    "a task authored by another keeper is not self-authored"
    false
    (WOI.task_is_self_authored ~meta (task ~created_by:"executor" "task-2"))
;;

(* An unattributed task has no known author, so it must stay claimable rather
   than being silently withheld from everyone. *)
let test_unattributed_task_is_not_self_authored () =
  let meta = make_meta "taskmaster" in
  Alcotest.(check bool)
    "a task with no created_by is never excluded"
    false
    (WOI.task_is_self_authored ~meta (task "task-3"))
;;

(* The agent name must not be mistaken for the author key: the live backlog
   stores "taskmaster", never "keeper-taskmaster-agent". Matching on the agent
   name would silently exclude nothing and leave the loop intact. *)
let test_agent_name_is_not_the_author_key () =
  let meta = make_meta "taskmaster" in
  Alcotest.(check bool)
    "agent-name-shaped author does not match the keeper handle"
    false
    (WOI.task_is_self_authored
       ~meta
       (task ~created_by:"keeper-taskmaster-agent" "task-4"))
;;

let () =
  Alcotest.run
    "keeper_self_authored_task_exclusion"
    [ ( "task_is_self_authored"
      , [ Alcotest.test_case "own task" `Quick test_own_task_is_self_authored
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
        ] )
    ]
;;
