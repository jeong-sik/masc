(** A keeper is shown only the Goals that are still open.

    Two prompt surfaces read the Goal store: [<available_goals>] in the system
    prompt (via {!Keeper_unified_prompt.active_goal_summaries_of_store}) and
    [### Active Goals] in the per-turn world state (via
    [world_observation.active_goals]). A Goal names no keeper, so both show the
    same list to everyone.

    [Goal_phase.admits_self_directed_progress] is the exhaustive predicate that
    decides membership — [Verifying] stays in, terminal phases drop out. These
    tests pin both surfaces to it. *)

open Alcotest
open Masc

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_goal_phase_%d_%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir
;;

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree dir)
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "test"));
      f config)
;;

let goal_in phase id title =
  let ts = Masc_domain.now_iso () in
  { Goal_store.id
  ; title
  ; metric = None
  ; target_value = None
  ; due_date = None
  ; priority = 3
  ; phase
  ; last_review_note = None
  ; last_review_at = None
  ; created_at = ts
  ; updated_at = ts
  }
;;

(* One goal per phase, so a future phase added to [Goal_phase.t] shows up here
   as an unclassified id rather than silently inheriting a neighbour's verdict.
   [Verifying] (RFC-0387 stage 2) admits self-directed progress — the gate
   holds the phase, not the work — so it survives alongside Executing. *)
let seed_all_phases config =
  Goal_store.write_state config
    { version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ goal_in Goal_phase.Executing "goal-executing" "still work"
        ; goal_in Goal_phase.Verifying "goal-verifying" "proof pending"
        ; goal_in Goal_phase.Blocked "goal-blocked" "waiting on someone"
        ; goal_in Goal_phase.Paused "goal-paused" "set aside"
        ; goal_in Goal_phase.Completed "goal-completed" "already achieved"
        ; goal_in Goal_phase.Dropped "goal-dropped" "abandoned"
        ]
    }
;;

(* Only terminal Goals: nothing on the surface, and nothing that could be
   mistaken for an empty list produced some other way. *)
let seed_terminal_phases_only config =
  Goal_store.write_state config
    { version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ goal_in Goal_phase.Completed "goal-completed" "already achieved"
        ; goal_in Goal_phase.Dropped "goal-dropped" "abandoned"
        ]
    }
;;

let keeper_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String "goal-phase-keeper"
         ; "trace_id", `String "test-trace-goal-phase"
         ])
  with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

let summary_ids summaries =
  List.map
    (fun (s : Keeper_unified_prompt.goal_summary) -> s.summary_goal_id)
    summaries
;;

let summary_title_opt goal_id summaries =
  match
    List.find_opt
      (fun (s : Keeper_unified_prompt.goal_summary) ->
        String.equal s.summary_goal_id goal_id)
      summaries
  with
  | Some s -> Some s.summary_title
  | None -> None
;;

let test_system_prompt_surface_drops_terminal_goals () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let _meta = keeper_meta () in
  let summaries = Keeper_unified_prompt.active_goal_summaries_of_store ~config in
  check (list string) "only progressable goals are offered"
    [ "goal-executing"; "goal-verifying" ]
    (summary_ids summaries);
  check (option string) "its title still resolves" (Some "still work")
    (summary_title_opt "goal-executing" summaries)
;;

let test_world_observation_drops_terminal_goals () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let meta = keeper_meta () in
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config
      ~meta
  in
  check (list string) "the per-turn frame agrees with the system prompt"
    [ "goal-executing"; "goal-verifying" ]
    observation.Keeper_world_observation.active_goals
;;

(* Terminal phases are the only thing that removes a Goal from the surface.
   Seed a store whose Goals are all terminal and neither surface offers any --
   an empty block rather than one that looks empty for a different reason. *)
let test_no_goals_surface_when_all_are_terminal () =
  with_workspace @@ fun config ->
  seed_terminal_phases_only config;
  let meta = keeper_meta () in
  check (list string) "no goal block rather than an empty-looking one" []
    (summary_ids (Keeper_unified_prompt.active_goal_summaries_of_store ~config));
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config
      ~meta
  in
  check (list string) "and the frame carries none either" []
    observation.Keeper_world_observation.active_goals
;;

(* An executing Goal that no Task serves is one fact addressed to every Keeper.

   Four exclusions in one predicate: terminal Goals are not open work, a Goal
   already carrying a Task is not an invitation, and [Verifying] is held back so
   a nudge to start new tasks cannot race the RFC-0387 proof gate. *)

let untasked config =
  List.map fst (Keeper_unified_prompt.executing_goals_without_tasks ~config)
;;

let test_executing_goal_without_task_surfaces () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_in Goal_phase.Executing "goal-open" "nobody started this"
          ; goal_in Goal_phase.Completed "goal-done" "already achieved"
          ]
      };
    check (list string) "only the executing, task-less goal" [ "goal-open" ]
      (untasked config))
;;

let test_terminal_goals_are_not_open_work () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_in Goal_phase.Completed "goal-done" "achieved"
          ; goal_in Goal_phase.Dropped "goal-gone" "abandoned"
          ]
      };
    check (list string) "a finished Goal is not an invitation" [] (untasked config))
;;

(* The proof gate holds the phase, not the work (RFC-0387 stage 2). A Goal
   awaiting its verdict is still progressible, but it is not "work with no Task
   yet" -- offering it here would invite new tasks against a pending proof. *)
let test_verifying_goal_is_held_back () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_in Goal_phase.Verifying "goal-judging" "proof pending"
          ; goal_in Goal_phase.Executing "goal-open" "has none"
          ]
      };
    check (list string) "a goal awaiting its verdict is not offered"
      [ "goal-open" ]
      (untasked config))
;;

let test_goal_with_a_linked_task_is_not_surfaced () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_in Goal_phase.Executing "goal-served" "already has work"
          ; goal_in Goal_phase.Executing "goal-open" "has none"
          ]
      };
    ignore
      (Workspace.add_task
         ~goal_id:"goal-served"
         config
         ~title:"Work on the served goal"
         ~priority:2
         ~description:"");
    check (list string) "a Goal with a Task is not an open invitation"
      [ "goal-open" ]
      (untasked config))
;;

(* The cases above prove which Goals qualify. This proves a Keeper is actually
   handed them: a correct list nobody renders is the state this block exists to
   end. *)
let rendered_world_state config =
  let meta = keeper_meta () in
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config ~meta
  in
  let { Keeper_unified_prompt.world_state; _ } =
    Keeper_unified_prompt.build_prompt
      ~meta
      ~config
      ~turn_decision:(Keeper_world_observation.keeper_cycle_decision ~meta observation)
      ~current_task:Keeper_world_observation_inputs.No_current_task
      ~observation
      ()
  in
  world_state
;;

let contains_in haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

let test_untasked_goals_reach_the_rendered_turn () =
  with_workspace @@ fun config ->
  Goal_store.write_state config
    { version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ goal_in Goal_phase.Executing "goal-open" "nobody started this"
        ; goal_in Goal_phase.Completed "goal-done" "already achieved"
        ]
    };
  let world = rendered_world_state config in
  check bool "the heading names the move the prompt already promises" true
    (contains_in world
       "### Executing Goals with no Task yet — picking one up is a move you can \
        make (1)");
  check bool "the goal is named with its title" true
    (contains_in world "- goal-open — nobody started this");
  check bool "a completed goal is not offered" false (contains_in world "goal-done")
;;

let () =
  run "keeper_goal_phase_projection"
    [ ( "prompt surfaces"
      , [ test_case "system prompt drops terminal goals" `Quick
            test_system_prompt_surface_drops_terminal_goals
        ; test_case "world observation drops terminal goals" `Quick
            test_world_observation_drops_terminal_goals
        ; test_case "all-terminal yields no goals at either surface" `Quick
            test_no_goals_surface_when_all_are_terminal
        ] )
    ; ( "executing goals with no task"
      , [ test_case "executing goal without a task surfaces" `Quick
            test_executing_goal_without_task_surfaces
        ; test_case "terminal goals are not open work" `Quick
            test_terminal_goals_are_not_open_work
        ; test_case "verifying goal is held back from the invitation" `Quick
            test_verifying_goal_is_held_back
        ; test_case "goal with a linked task is not surfaced" `Quick
            test_goal_with_a_linked_task_is_not_surfaced
        ; test_case "untasked goals reach the rendered turn" `Quick
            test_untasked_goals_reach_the_rendered_turn
        ] )
    ]
;;
