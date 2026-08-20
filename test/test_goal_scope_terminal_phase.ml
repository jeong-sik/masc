(* [Keeper_runtime_contract.validate_active_goal_ids] is the single point where
   a keeper's declared goal scope meets the live goal store, and everything
   downstream reads [meta.active_goal_ids] after it has replaced the list: the
   claim-scope filter, [primary_goal_id_opt], and the [goal_ids] stamped on the
   runtime contract. The world observation and the unified prompt instead apply
   [Goal_phase.admits_self_directed_progress], so before this suite a Completed
   goal was scope for one set of readers and absent for the other.

   These cases live outside test_keeper_runtime_contract on purpose. That suite
   is one of four named in .github/workflows/ci.yml as red on main and
   deliberately unwired (#26075): its claim assertions fail with
   Eio_mutex.Poisoned under the test harness, so anything added there would not
   execute. This file touches only the validator, runs, and is wired. *)

open Alcotest
open Masc

let () = Workspace_metric_hooks.install ()

let make_config () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_goal_scope_terminal_phase_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  let config = Workspace.default_config dir in
  let _ = Workspace.init config ~agent_name:(Some "goal-scope-phase") in
  config
;;

let cleanup_config config =
  let _ = Workspace.reset config in
  ()
;;

let make_meta active_goal_ids =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "goal-scope-phase-keeper"
        ; "trace_id", `String "goal-scope-phase-trace"
        ; "active_goal_ids", `List (List.map (fun id -> `String id) active_goal_ids)
        ])
  with
  | Ok meta -> meta
  | Error e -> failf "make_meta failed: %s" e
;;

let put_goal config ~id ~phase =
  match Goal_store.upsert_goal config ~id ~title:("Goal " ^ id)
          ~metric:"m" ~target_value:"1" ~phase () with
  | Ok _ -> ()
  | Error msg -> failf "upsert_goal %s failed: %s" id msg
;;

let surviving config ids =
  Keeper_runtime_contract.validate_active_goal_ids ~config ~meta:(make_meta ids) ()
;;

(* Every terminal constructor is asserted rather than letting Completed stand in
   for the group. Blocked and Paused are the two that read as "still mine, just
   not now" -- which is exactly the reading that would justify keeping them in
   scope -- and [Goal_phase.admits_self_directed_progress] answers false for
   both, so the scope and the prompt agree on them too. *)
let test_every_terminal_phase_leaves_scope () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      let terminal =
        [ "goal-completed", Goal_phase.Completed
        ; "goal-dropped", Goal_phase.Dropped
        ; "goal-blocked", Goal_phase.Blocked
        ; "goal-paused", Goal_phase.Paused
        ]
      in
      put_goal config ~id:"goal-executing" ~phase:Goal_phase.Executing;
      List.iter (fun (id, phase) -> put_goal config ~id ~phase) terminal;
      check
        (list string)
        "only the executing goal survives"
        [ "goal-executing" ]
        (surviving config ("goal-executing" :: List.map fst terminal)))
;;

(* The live shape this closes, measured 2026-08-07: sangsu's only configured
   goal completed 2h12m after it entered scope and stayed there. Over the next
   2.5 days the runtime contract stamped goal_ids from the raw list for 5,362
   tool calls while the prompt, applying the phase predicate, showed no goal in
   any of those turns. An empty result is what makes the claim scope fall to
   all_tasks and the stamp read honestly, so emptiness is the assertion. *)
let test_a_scope_of_only_completed_goals_is_empty () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      put_goal config ~id:"goal-finished" ~phase:Goal_phase.Completed;
      check (list string) "nothing survives" [] (surviving config [ "goal-finished" ]))
;;

(* A goal that reaches a terminal phase and is reopened returns to scope on its
   own: the predicate is evaluated per turn against the store, never cached, so
   nothing has to undo the prune. *)
let test_reopening_a_goal_returns_it_to_scope () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      put_goal config ~id:"goal-cycles" ~phase:Goal_phase.Completed;
      check (list string) "out of scope while completed" [] (surviving config [ "goal-cycles" ]);
      put_goal config ~id:"goal-cycles" ~phase:Goal_phase.Executing;
      check
        (list string)
        "back in scope once executing again"
        [ "goal-cycles" ]
        (surviving config [ "goal-cycles" ]))
;;

(* An id absent from the store was already pruned before this change. Pinning it
   keeps the two prune reasons from collapsing back into one branch, which would
   report a Completed goal as invalid -- it is not. *)
let test_ids_absent_from_the_store_are_still_dropped () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      put_goal config ~id:"goal-real" ~phase:Goal_phase.Executing;
      check
        (list string)
        "unknown id dropped, executing goal kept"
        [ "goal-real" ]
        (surviving config [ "goal-real"; "goal-typo" ]))
;;

(* Order is the caller's declaration order and is load-bearing:
   [primary_goal_id_opt] takes the head of the surviving list. *)
let test_surviving_ids_keep_declaration_order () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      put_goal config ~id:"goal-first" ~phase:Goal_phase.Executing;
      put_goal config ~id:"goal-stale" ~phase:Goal_phase.Completed;
      put_goal config ~id:"goal-second" ~phase:Goal_phase.Executing;
      check
        (list string)
        "declaration order preserved across the prune"
        [ "goal-first"; "goal-second" ]
        (surviving config [ "goal-first"; "goal-stale"; "goal-second" ]))
;;

(* RFC-0387 stage 2: [Verifying] is NOT terminal and deliberately stays in
   scope — the gate holds the phase while the proof is judged out-of-band, and
   pruning it here would erase the goal from the keeper's view at exactly the
   moment the gate took over (stage-2 review P0-1). *)
let test_a_verifying_goal_stays_in_scope () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      put_goal config ~id:"goal-verifying" ~phase:Goal_phase.Verifying;
      check
        (list string)
        "a goal under proof review stays in scope"
        [ "goal-verifying" ]
        (surviving config [ "goal-verifying" ]))
;;

let () =
  run
    "goal_scope_terminal_phase"
    [ ( "validate_active_goal_ids"
      , [ test_case "every terminal phase leaves scope" `Quick
            test_every_terminal_phase_leaves_scope
        ; test_case "a verifying goal stays in scope" `Quick
            test_a_verifying_goal_stays_in_scope
        ; test_case "a scope of only completed goals is empty" `Quick
            test_a_scope_of_only_completed_goals_is_empty
        ; test_case "reopening a goal returns it to scope" `Quick
            test_reopening_a_goal_returns_it_to_scope
        ; test_case "ids absent from the store are still dropped" `Quick
            test_ids_absent_from_the_store_are_still_dropped
        ; test_case "surviving ids keep declaration order" `Quick
            test_surviving_ids_keep_declaration_order
        ] )
    ]
;;
