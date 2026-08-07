(** A keeper is handed only the goals it can still progress.

    [keeper_meta.active_goal_ids] records which goals were assigned to a keeper.
    Nothing removes an id when the goal reaches a terminal phase, and
    [resolve_active_goal_ids] only checks that the id exists — so a Completed or
    Dropped goal stays on the list indefinitely.

    Two prompt surfaces read that list: [<available_goals>] in the system prompt
    (via {!Keeper_unified_prompt.active_goal_summaries}) and [### Active Goals]
    in the per-turn world state (via [world_observation.active_goals]). Both
    announced terminal goals as this keeper's work, on every turn, under
    headings that call them available.

    [Goal_phase.admits_self_directed_progress] is the exhaustive predicate for
    the question and had no callers. These tests pin both surfaces to it. *)

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
  ; parent_goal_id = None
  ; last_review_note = None
  ; last_review_at = None
  ; owner = None
  ; created_at = ts
  ; updated_at = ts
  }
;;

(* One goal per phase, so a future phase added to [Goal_phase.t] shows up here
   as an unclassified id rather than silently inheriting a neighbour's verdict. *)
let seed_all_phases config =
  Goal_store.write_state config
    { version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ goal_in Goal_phase.Executing "goal-executing" "still work"
        ; goal_in Goal_phase.Blocked "goal-blocked" "waiting on someone"
        ; goal_in Goal_phase.Paused "goal-paused" "set aside"
        ; goal_in Goal_phase.Completed "goal-completed" "already achieved"
        ; goal_in Goal_phase.Dropped "goal-dropped" "abandoned"
        ]
    }
;;

let meta_with_goals ids =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String "goal-phase-keeper"
         ; "trace_id", `String "test-trace-goal-phase"
         ; "active_goal_ids", `List (List.map (fun id -> `String id) ids)
         ])
  with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

let all_ids =
  [ "goal-executing"
  ; "goal-blocked"
  ; "goal-paused"
  ; "goal-completed"
  ; "goal-dropped"
  ]
;;

let test_system_prompt_surface_drops_terminal_goals () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let meta = meta_with_goals all_ids in
  let summaries = Keeper_unified_prompt.active_goal_summaries ~config ~meta in
  let ids = List.map fst summaries in
  check (list string) "only a progressable goal is offered" [ "goal-executing" ]
    ids;
  check (option string) "its title still resolves" (Some "still work")
    (List.assoc_opt "goal-executing" summaries)
;;

let test_world_observation_drops_terminal_goals () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let meta = meta_with_goals all_ids in
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config
      ~meta
  in
  check (list string) "the per-turn frame agrees with the system prompt"
    [ "goal-executing" ] observation.Keeper_world_observation.active_goals
;;

let test_unresolved_goal_id_stays_visible () =
  (* An assigned goal that no longer exists is a different fault. Dropping it
     alongside the terminal ones would replace a visible inconsistency with a
     silent one, so it keeps its bare-id rendering. *)
  with_workspace @@ fun config ->
  seed_all_phases config;
  let meta = meta_with_goals [ "goal-completed"; "goal-vanished" ] in
  let summaries = Keeper_unified_prompt.active_goal_summaries ~config ~meta in
  check (list string) "the terminal goal goes, the unknown id stays"
    [ "goal-vanished" ] (List.map fst summaries);
  check (option string) "unknown id renders with no title" (Some "")
    (List.assoc_opt "goal-vanished" summaries)
;;

let test_no_goals_surface_when_all_are_terminal () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let meta = meta_with_goals [ "goal-completed"; "goal-dropped" ] in
  check (list string) "no goal block rather than an empty-looking one" []
    (List.map fst (Keeper_unified_prompt.active_goal_summaries ~config ~meta));
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config
      ~meta
  in
  check (list string) "and the frame carries none either" []
    observation.Keeper_world_observation.active_goals
;;


(* RFC-0362 §4.3 — the owner consumer. The Goal carries the owner; the keeper's
   [active_goal_ids] is empty here on purpose, because it is empty for every
   keeper on the live workspace and the fact must surface without it.

   Three cases in one predicate: owned + executing + no linked Task surfaces;
   owned but terminal does not; owned, executing, but already carrying a Task
   does not (the owner has nothing to decide there). *)
let owner_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String "owner-keeper"
         ; "trace_id", `String "test-trace-owner"
         ; "active_goal_ids", `List []
         ])
  with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

let goal_owned_by owner phase id title =
  { (goal_in phase id title) with Goal_store.owner = Some owner }
;;

let test_owned_executing_goal_without_task_surfaces () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_owned_by "owner-keeper" Goal_phase.Executing "goal-mine" "mine to split"
          ; goal_owned_by "owner-keeper" Goal_phase.Completed "goal-done" "already achieved"
          ; goal_in Goal_phase.Executing "goal-unowned" "nobody holds this"
          ]
      };
    let found =
      Keeper_unified_prompt.owned_executing_goals_without_tasks
        ~config
        ~keeper_name:"owner-keeper"
    in
    check (list string) "only the owned, executing, task-less goal"
      [ "goal-mine" ]
      (List.map fst found))
;;

let test_owner_of_a_terminal_goal_is_told_nothing () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_owned_by "owner-keeper" Goal_phase.Completed "goal-done" "achieved" ]
      };
    check (list string) "terminal goals are not the owner's open work"
      []
      (List.map fst
         (Keeper_unified_prompt.owned_executing_goals_without_tasks
            ~config
            ~keeper_name:"owner-keeper")))
;;

let test_another_keepers_goal_is_not_surfaced () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_owned_by "someone-else" Goal_phase.Executing "goal-theirs" "not mine" ]
      };
    check (list string) "ownership is not shared"
      []
      (List.map fst
         (Keeper_unified_prompt.owned_executing_goals_without_tasks
            ~config
            ~keeper_name:"owner-keeper")))
;;

(* RFC-0362 §6 Q2. The owned list above renders for nobody while 15 of 16 live
   Goals are unowned, so ten executing Goals were visible at no surface. These
   pin the sighting and, more importantly, that it stays as narrow as the owned
   one: same phase filter, same "already has a Task" exclusion. *)

let unowned config = List.map fst (Keeper_unified_prompt.unowned_executing_goals_without_tasks ~config)

let test_unowned_executing_goal_without_task_surfaces () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_in Goal_phase.Executing "goal-open" "nobody holds this"
          ; goal_owned_by "someone" Goal_phase.Executing "goal-theirs" "taken"
          ]
      };
    check (list string) "only the unowned executing goal" [ "goal-open" ] (unowned config))
;;

(* The two lists partition the Goals: an owner sees theirs, everyone sees the
   ones nobody took, and no Goal appears in both. *)
let test_owned_and_unowned_lists_do_not_overlap () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_owned_by "owner-keeper" Goal_phase.Executing "goal-mine" "mine"
          ; goal_in Goal_phase.Executing "goal-open" "free"
          ]
      };
    let owned =
      List.map fst
        (Keeper_unified_prompt.owned_executing_goals_without_tasks
           ~config
           ~keeper_name:"owner-keeper")
    in
    check (list string) "owner sees only their own" [ "goal-mine" ] owned;
    check (list string) "everyone sees only the untaken one" [ "goal-open" ] (unowned config))
;;

let test_terminal_unowned_goal_is_not_surfaced () =
  with_workspace (fun config ->
    Goal_store.write_state config
      { version = 1
      ; updated_at = Masc_domain.now_iso ()
      ; goals =
          [ goal_in Goal_phase.Completed "goal-done" "achieved"
          ; goal_in Goal_phase.Dropped "goal-gone" "abandoned"
          ]
      };
    check (list string) "a finished Goal is not an invitation" [] (unowned config))
;;

(* The name says "without tasks". A Goal somebody is already working is not an
   invitation, whoever owns it. *)
let test_unowned_goal_with_a_linked_task_is_not_surfaced () =
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
      (unowned config))
;;

(* The helper cases above prove which Goals qualify. This proves a Keeper is
   actually handed them: the block is what closes RFC-0362 §6 Q2, and a correct
   list nobody renders is the state this change exists to end. *)
let test_unowned_goals_reach_the_rendered_turn () =
  with_workspace @@ fun config ->
  Goal_store.write_state config
    { version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ goal_in Goal_phase.Executing "goal-open" "nobody holds this"
        ; goal_in Goal_phase.Completed "goal-done" "already achieved"
        ]
    };
  let meta = meta_with_goals [] in
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
  let contains needle =
    let n = String.length needle and h = String.length world_state in
    let rec go i = i + n <= h && (String.sub world_state i n = needle || go (i + 1)) in
    n = 0 || go 0
  in
  check bool "the heading names the move the prompt already promises" true
    (contains "### Unowned Goals, no Task yet — taking one is a move you can make (1)");
  check bool "the goal is named with its title" true
    (contains "- goal-open — nobody holds this");
  check bool "a completed goal is not offered" false (contains "goal-done")
;;

let () =
  run "keeper_goal_phase_projection"
    [ ( "prompt surfaces"
      , [ test_case "system prompt drops terminal goals" `Quick
            test_system_prompt_surface_drops_terminal_goals
        ; test_case "world observation drops terminal goals" `Quick
            test_world_observation_drops_terminal_goals
        ; test_case "unresolved goal id stays visible" `Quick
            test_unresolved_goal_id_stays_visible
        ; test_case "all-terminal yields no goals at either surface" `Quick
            test_no_goals_surface_when_all_are_terminal
        ] )
    ; ( "rfc-0362 owner consumer"
      , [ test_case "owned executing goal without a task surfaces" `Quick
            test_owned_executing_goal_without_task_surfaces
        ; test_case "terminal owned goal is not open work" `Quick
            test_owner_of_a_terminal_goal_is_told_nothing
        ; test_case "another keeper's goal is not surfaced" `Quick
            test_another_keepers_goal_is_not_surfaced
        ] )
    ; ( "rfc-0362 q2 unowned sighting"
      , [ test_case "unowned executing goal without a task surfaces" `Quick
            test_unowned_executing_goal_without_task_surfaces
        ; test_case "owned and unowned lists do not overlap" `Quick
            test_owned_and_unowned_lists_do_not_overlap
        ; test_case "terminal unowned goal is not surfaced" `Quick
            test_terminal_unowned_goal_is_not_surfaced
        ; test_case "unowned goal with a linked task is not surfaced" `Quick
            test_unowned_goal_with_a_linked_task_is_not_surfaced
        ; test_case "unowned goals reach the rendered turn" `Quick
            test_unowned_goals_reach_the_rendered_turn
        ] )
    ]
;;
