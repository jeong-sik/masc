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
    ]
;;
