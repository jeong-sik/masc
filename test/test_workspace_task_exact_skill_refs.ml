open Alcotest

module Reference = Skill_reference
module Workspace = Workspace_core

let source_id value =
  match Skill_source_config.source_id_of_string value with
  | Ok source_id -> source_id
  | Error detail -> fail detail
;;

let package_id value =
  match Reference.package_id_of_directory value with
  | Ok package_id -> package_id
  | Error _ -> failf "invalid package fixture %S" value
;;

let reference ?(package = "review") ?(name = "review") character =
  let content_revision =
    match Reference.content_revision_of_string (String.make 64 character) with
    | Ok revision -> revision
    | Error _ -> fail "invalid content revision fixture"
  in
  Reference.make
    ~identity:
      (Reference.make_identity
         ~source_id:(source_id "project-masc")
         ~package_id:(package_id package)
         ~name)
    ~content_revision
;;

let references_json references =
  Reference.list_to_yojson references |> Yojson.Safe.to_string
;;

let check_references label expected actual =
  check string label (references_json expected) (references_json actual)
;;

let task_of config task_id =
  Workspace.read_backlog config
  |> fun backlog ->
  match List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id) backlog.tasks with
  | Some task -> task
  | None -> failf "task %s is missing" task_id
;;

let with_workspace operation =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = Filename.temp_dir "task-exact-skill-refs-" "" in
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Unix.rmdir root)
    (fun () -> operation config)
;;

let expect_transition = function
  | Ok _ -> ()
  | Error error -> fail (Masc_domain.show_masc_error error)
;;

let test_backlog_transition_and_archive_preserve_exact_references () =
  with_workspace @@ fun config ->
  let expected = [ reference 'a'; reference ~package:"verify" ~name:"verify" 'b' ] in
  let created =
    match
      Workspace.add_task_with_result
        ~skills:expected
        config
        ~title:"Exact Skill task"
        ~priority:3
        ~description:""
    with
    | Ok created -> created
    | Error error -> fail (Workspace.add_task_error_to_string error)
  in
  let task_id = created.task_id in
  check_references "backlog write/read" expected (task_of config task_id).skills;
  Workspace.transition_task_r
    config
    ~agent_name:"keeper-one"
    ~task_id
    ~action:Masc_domain.Claim
    ()
  |> expect_transition;
  Workspace.transition_task_r
    config
    ~agent_name:"keeper-one"
    ~task_id
    ~action:Masc_domain.Start
    ()
  |> expect_transition;
  let transitioned = task_of config task_id in
  check_references "state transitions" expected transitioned.skills;
  Workspace.append_archive_tasks config [ transitioned ];
  match
    Workspace.read_orphaned_nonterminal_tasks config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  with
  | Some archived -> check_references "archive write/read" expected archived.skills
  | None -> fail "archived nonterminal task was not readable"
;;

let () =
  run
    "Workspace Task exact Skill references"
    [ ( "durability"
      , [ test_case
            "backlog, transitions, and archive preserve exact references"
            `Quick
            test_backlog_transition_and_archive_preserve_exact_references
        ] )
    ]
;;
