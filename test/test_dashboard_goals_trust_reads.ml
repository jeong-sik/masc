(** RFC-0474 L4e: the goals tree reads a Keeper's runtime trust only when a
    goal's task is assigned to that Keeper, and once per build. Reading every
    Keeper's snapshot first was what made the tree slow: on 2026-10-28 the 40
    snapshots took 7.3 s of a 7.5 s tree, and the 19 Keepers any goal named
    took 2.0 s of them. *)

open Alcotest
open Masc

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun output -> output_string output content)
;;

let write_keeper config name =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    "[keeper]\ninstructions = \"test keeper\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
  let meta_path = Keeper_types_profile.keeper_meta_path config name in
  mkdir_p (Filename.dirname meta_path);
  write_file meta_path
    (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name ()))
;;

let get_ok to_string = function
  | Ok value -> value
  | Error error -> fail (to_string error)
;;

let assign config ~task_id ~assignee =
  let backlog = get_ok Fun.id (Workspace_backlog.read_backlog_r config) in
  let claimed_at = Masc_domain.now_iso () in
  Workspace_backlog.write_backlog config
    { backlog with
      tasks =
        List.map
          (fun (task : Masc_domain.task) ->
             if String.equal task.id task_id
             then
               { task with
                 task_status = Masc_domain.Claimed { assignee; claimed_at }
               }
             else task)
          backlog.tasks
    }
;;

let test_reads_trust_once_for_assigned_keepers_only () =
  let base_path = Filename.temp_dir "dashboard-goals-trust-reads" "" in
  Fun.protect ~finally:(fun () -> rm_rf base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None);
  List.iter (write_keeper config) [ "alpha"; "beta" ];
  let goal title =
    get_ok Goal_store.write_error_to_string
      (Goal_store.upsert_goal config ~title ~metric:"tasks" ~target_value:"1" ())
    |> fst
  in
  let assigned_task (goal : Goal_store.goal) title =
    let created =
      get_ok Workspace.add_task_error_to_string
        (Workspace.add_task_with_result ~goal_id:goal.id config ~title
           ~priority:3 ~description:"evidence")
    in
    assign config ~task_id:created.task_id ~assignee:"alpha"
  in
  (* Both goals' tasks belong to alpha; beta is a Keeper no goal names. *)
  assigned_task (goal "First") "First task";
  assigned_task (goal "Second") "Second task";
  let asked = ref [] in
  let read_trust ~config:_ ~(meta : Keeper_meta_contract.keeper_meta) =
    asked := meta.name :: !asked;
    `Assoc
      [ "turn_id", `Int 7
      ; ( "latest_causal_event"
        , `Assoc
            [ "ts", `String "2026-10-28T08:00:00Z"; "ts_unix", `Float 1793174400. ] )
      ]
  in
  let goals =
    get_ok Goal_store.unavailable_to_string (Goal_store.list_goals_result config ())
  in
  let forest =
    get_ok Fun.id
      (Dashboard_goals.build_forest_with_trust_reader ~read_trust ~config ~goals
         ~tasks:(Workspace.get_tasks_safe config) ~pending_approvals:[])
  in
  check int "both goals are projected" 2 (List.length forest);
  check (list string) "trust is read once, for the assigned Keeper only"
    [ "alpha" ] !asked;
  List.iter
    (fun (node : Dashboard_goals.tree_node) ->
       check (list string) "the goal names its assigned Keeper" [ "alpha" ]
         node.linked_keeper_names;
       check (option string) "the trust read names the latest Keeper" (Some "alpha")
         node.latest_keeper_ref;
       check (option int) "the trust read names the latest turn" (Some 7)
         node.latest_turn_ref)
    forest
;;

let () =
  run "dashboard_goals_trust_reads"
    [ ( "build_forest"
      , [ test_case "reads trust once, for assigned Keepers only" `Quick
            test_reads_trust_once_for_assigned_keepers_only
        ] )
    ]
;;
