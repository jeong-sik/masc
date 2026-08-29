open Alcotest
open Masc

module Reference = Skill_reference
module Service = Skill_catalog_snapshot_service
module Snapshot = Skill_catalog_snapshot
module Workspace = Masc.Workspace

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let with_workspace operation =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "task-skill-published-" "" in
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some "author"));
  Fun.protect
    ~finally:(fun () ->
      (match Service.find_workspace_of_base_path ~base_path with
       | Ok (Some workspace) -> Service.retire ~workspace
       | Ok None | Error _ -> ());
      if Sys.file_exists base_path then remove_tree base_path)
    (fun () ->
       operation
         base_path
         config
         { Task.Tool.config; agent_name = "author"; sw = None })
;;

let mkdir path = Unix.mkdir path 0o700

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let write_skill base_path ~source ~package ~name ~description body =
  let source_path = Filename.concat base_path source in
  if not (Sys.file_exists source_path) then mkdir source_path;
  let package_path = Filename.concat source_path package in
  mkdir package_path;
  write_file
    (Filename.concat package_path "SKILL.md")
    (Printf.sprintf
       "---\nname: %s\ndescription: %s\n---\n%s"
       name
       description
       body)
;;

let source_row id path =
  Printf.sprintf
    "[[skills.sources]]\nid = %S\nanchor = \"base-path\"\npath = %S\naccess = \"read-write\"\n"
    id
    path
;;

let config_text sources =
  "[skills]\nresource-read-max-bytes = 65536\n"
  ^ sources
;;

let publish_once base_path text =
  let workspace =
    match Service.workspace_of_base_path ~base_path with
    | Ok workspace -> workspace
    | Error _ -> fail "workspace registration failed"
  in
  let observations = ref 0 in
  let publication =
    Service.refresh
      ~workspace
      ~user_home:None
      ~read_config:(fun () ->
        incr observations;
        Service.Config_text text)
  in
  let snapshot =
    match publication with
    | Service.Published snapshot | Unchanged snapshot -> snapshot
    | Workspace_retired -> fail "workspace retired during publication"
  in
  workspace, snapshot, observations
;;

let source_id value =
  match Skill_source_config.source_id_of_string value with
  | Ok source_id -> source_id
  | Error detail -> fail detail
;;

let package_id value =
  match Reference.package_id_of_directory value with
  | Ok package_id -> package_id
  | Error _ -> fail "invalid package fixture"
;;

let revision character =
  match Reference.content_revision_of_string (String.make 64 character) with
  | Ok revision -> revision
  | Error _ -> fail "invalid revision fixture"
;;

let synthetic_reference ?(source = "workspace") ?(package = "review")
      ?(name = "review") ?(content_revision = revision 'a') () =
  Reference.make
    ~identity:
      (Reference.make_identity
         ~source_id:(source_id source)
         ~package_id:(package_id package)
         ~name)
    ~content_revision
;;

let add_task ctx ~title skills =
  Task.Tool.handle_add_task
    ~tool_name:"masc_add_task"
    ~start_time:0.0
    ctx
    (`Assoc
      [ "title", `String title
      ; "skills", Reference.list_to_yojson skills
      ])
;;

let rejection result =
  (match Tool_result.failure_class result with
   | Some Tool_result.Workflow_rejection -> ()
   | Some _ | None -> fail "Skill rejection lost Workflow_rejection class");
  match Tool_result.data result with
  | `Assoc fields ->
    (match List.assoc_opt "skill_rejection" fields with
     | Some (`Assoc rejection) -> rejection
     | Some _ | None -> fail "Skill rejection lost its typed payload")
  | _ -> fail "Skill rejection data was not an object"
;;

let rejection_code result =
  match List.assoc_opt "code" (rejection result) with
  | Some (`String code) -> code
  | Some _ | None -> fail "Skill rejection code missing"
;;

let check_references label expected actual =
  check
    string
    label
    (Reference.list_to_yojson expected |> Yojson.Safe.to_string)
    (Reference.list_to_yojson actual |> Yojson.Safe.to_string)
;;

let only_task config =
  match (Workspace.read_backlog config).tasks with
  | [ task ] -> task
  | tasks -> failf "expected one task, got %d" (List.length tasks)
;;

let test_empty_skills_need_no_snapshot_service () =
  with_workspace @@ fun base_path config ctx ->
  (match Service.find_workspace_of_base_path ~base_path with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "test workspace unexpectedly registered");
  let result = add_task ctx ~title:"No Skill task" [] in
  check bool "empty declaration succeeds" true (Tool_result.is_success result);
  check int "stored empty declaration" 0 (List.length (only_task config).skills);
  (match Service.find_workspace_of_base_path ~base_path with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "empty declaration touched snapshot service")
;;

let test_shadow_reference_uses_one_published_observation () =
  with_workspace @@ fun base_path config ctx ->
  write_skill
    base_path
    ~source:"first-skills"
    ~package:"review"
    ~name:"review"
    ~description:"First"
    "first body";
  write_skill
    base_path
    ~source:"second-skills"
    ~package:"review"
    ~name:"review"
    ~description:"Second"
    "second body";
  let _workspace, snapshot, observations =
    publish_once
      base_path
      (config_text
         (source_row "first" "first-skills"
          ^ source_row "second" "second-skills"))
  in
  let shadow =
    Snapshot.entries snapshot
    |> List.find_opt (fun (entry : Snapshot.entry) ->
      String.equal
        (Skill_source_config.source_id_to_string entry.identity.source_id)
        "second")
    |> function
    | Some entry -> Snapshot.entry_reference entry
    | None -> fail "shadow exact entry missing"
  in
  remove_tree (Filename.concat base_path "first-skills");
  remove_tree (Filename.concat base_path "second-skills");
  let result = add_task ctx ~title:"Shadow Skill task" [ shadow ] in
  if not (Tool_result.is_success result)
  then fail (Tool_result.message result);
  check int "one config observation" 1 !observations;
  check_references "stored unchanged" [ shadow ] (only_task config).skills;
  let response_skills =
    match Json_util.assoc_member_opt "skills" (Tool_result.data result) with
    | Some json ->
      (match Reference.list_of_yojson json with
       | Ok references -> references
       | Error _ -> fail "success returned non-canonical skills")
    | None -> fail "success omitted canonical skills"
  in
  check_references "returned unchanged" [ shadow ] response_skills
;;

let test_uninitialized_snapshot_is_typed () =
  with_workspace @@ fun base_path _config ctx ->
  (match Service.workspace_of_base_path ~base_path with
   | Ok _workspace -> ()
   | Error _ -> fail "workspace registration failed");
  let result = add_task ctx ~title:"Uninitialized" [ synthetic_reference () ] in
  check string
    "typed code"
    "skill_snapshot_uninitialized"
    (rejection_code result)
;;

let test_unregistered_snapshot_is_typed () =
  with_workspace @@ fun base_path _config ctx ->
  (match Service.find_workspace_of_base_path ~base_path with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "test workspace unexpectedly registered");
  let result = add_task ctx ~title:"Unregistered" [ synthetic_reference () ] in
  check string
    "typed code"
    "skill_snapshot_not_registered"
    (rejection_code result)
;;

let test_unknown_identity_and_revision_mismatch_are_typed () =
  with_workspace @@ fun base_path config ctx ->
  write_skill
    base_path
    ~source:"skills"
    ~package:"review"
    ~name:"review"
    ~description:"Review"
    "body";
  let _workspace, snapshot, _observations =
    publish_once base_path (config_text (source_row "workspace" "skills"))
  in
  let observed =
    match Snapshot.entries snapshot with
    | [ entry ] -> Snapshot.entry_reference entry
    | _ -> fail "expected one published Skill"
  in
  let unknown =
    Reference.make
      ~identity:
        (Reference.make_identity
           ~source_id:observed.identity.source_id
           ~package_id:(package_id "absent")
           ~name:"absent")
      ~content_revision:observed.content_revision
  in
  let unknown_result = add_task ctx ~title:"Unknown" [ unknown ] in
  check string
    "unknown identity code"
    "skill_reference_identity_not_found"
    (rejection_code unknown_result);
  let requested_revision =
    let candidate = revision '0' in
    if Reference.equal_content_revision candidate observed.content_revision
    then revision '1'
    else candidate
  in
  let stale =
    Reference.make
      ~identity:observed.identity
      ~content_revision:requested_revision
  in
  let stale_result = add_task ctx ~title:"Stale" [ stale ] in
  let stale_rejection = rejection stale_result in
  check string
    "revision mismatch code"
    "skill_reference_revision_mismatch"
    (match List.assoc_opt "code" stale_rejection with
     | Some (`String code) -> code
     | Some _ | None -> fail "revision mismatch code missing");
  check string
    "observed revision remains typed"
    (Reference.content_revision_to_string observed.content_revision)
    (match List.assoc_opt "observed_content_revision" stale_rejection with
     | Some (`String revision) -> revision
     | Some _ | None -> fail "observed revision missing");
  check int "rejected Tasks were not stored" 0 (List.length (Workspace.read_backlog config).tasks)
;;

let test_legacy_string_payload_is_typed () =
  with_workspace @@ fun _base_path _config ctx ->
  let result =
    Task.Tool.handle_add_task
      ~tool_name:"masc_add_task"
      ~start_time:0.0
      ctx
      (`Assoc
        [ "title", `String "Legacy"
        ; "skills", `List [ `String "review" ]
        ])
  in
  let structured = rejection result in
  check string
    "payload code"
    "invalid_skill_reference_payload"
    (match List.assoc_opt "code" structured with
     | Some (`String code) -> code
     | Some _ | None -> fail "payload code missing");
  match List.assoc_opt "reason" structured with
  | Some (`Assoc reason) ->
    check string
      "legacy shape"
      "expected_object"
      (match List.assoc_opt "kind" reason with
       | Some (`String kind) -> kind
       | Some _ | None -> fail "payload reason kind missing")
  | Some _ | None -> fail "payload reason missing"
;;

let () =
  run
    "Task Skill published resolution"
    [ ( "authoring"
      , [ test_case
            "empty skills bypass snapshot service"
            `Quick
            test_empty_skills_need_no_snapshot_service
        ; test_case
            "shadow exact reference uses one published observation"
            `Quick
            test_shadow_reference_uses_one_published_observation
        ; test_case
            "unregistered snapshot is typed"
            `Quick
            test_unregistered_snapshot_is_typed
        ; test_case
            "uninitialized snapshot is typed"
            `Quick
            test_uninitialized_snapshot_is_typed
        ; test_case
            "unknown identity and revision mismatch are typed"
            `Quick
            test_unknown_identity_and_revision_mismatch_are_typed
        ; test_case
            "legacy string payload is typed"
            `Quick
            test_legacy_string_payload_is_typed
        ] )
    ]
;;
