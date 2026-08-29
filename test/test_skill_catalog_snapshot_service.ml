open Alcotest

module Snapshot = Skill_catalog_snapshot
module Service = Skill_catalog_snapshot_service

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let with_workspace f =
  let path = Filename.temp_file "skill-snapshot-service-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let mkdir path = Unix.mkdir path 0o700

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let write_skill root ~source ~package ~description body =
  let source_path = Filename.concat root source in
  if not (Sys.file_exists source_path) then mkdir source_path;
  let package_path = Filename.concat source_path package in
  mkdir package_path;
  write_file
    (Filename.concat package_path "SKILL.md")
    (Printf.sprintf
       "---\nname: %s\ndescription: %s\n---\n%s"
       package
       description
       body)
;;

let source_row id path =
  Printf.sprintf
    "[[skills.sources]]\nid = %S\nanchor = \"base-path\"\npath = %S\naccess = \"read-write\"\n"
    id
    path
;;

let config sources =
  "[skills]\nresource-read-max-bytes = 65536\n"
  ^ sources
;;

let snapshot = function
  | Service.Published snapshot
  | Unchanged snapshot -> snapshot
  | Workspace_retired -> fail "workspace retired during snapshot fixture"
;;

let workspace base_path =
  match Service.workspace_of_base_path ~base_path with
  | Ok workspace -> workspace
  | Error _ -> failf "invalid workspace fixture %S" base_path
;;

let refresh base_path config_text =
  Service.refresh
    ~workspace:(workspace base_path)
    ~user_home:None
    ~read_config:(fun () -> Service.Config_text config_text)
;;

let test_valid_and_malformed_sources_coexist () =
  with_workspace @@ fun base_path ->
  write_skill base_path ~source:"one" ~package:"valid" ~description:"Valid" "body";
  let broken_root = Filename.concat base_path "two" in
  mkdir broken_root;
  let broken_package = Filename.concat broken_root "broken" in
  mkdir broken_package;
  write_file (Filename.concat broken_package "SKILL.md") "---\nname: broken\n---\nbody";
  let snapshot =
    refresh
      base_path
      (config (source_row "one" "one" ^ source_row "two" "two"))
    |> snapshot
  in
  check int "valid Skill remains" 1 (List.length (Snapshot.entries snapshot));
  check int "malformed Skill diagnosed" 1 (List.length (Snapshot.rejections snapshot));
  check bool
    "published snapshot is current"
    true
    (match Service.current ~workspace:(workspace base_path) with
     | Some current ->
       String.equal
         (Snapshot.snapshot_revision current |> Snapshot.snapshot_revision_to_string)
         (Snapshot.snapshot_revision snapshot |> Snapshot.snapshot_revision_to_string)
     | None -> false)
;;

let test_missing_and_symlink_sources_are_typed () =
  with_workspace @@ fun base_path ->
  let real = Filename.concat base_path "real" in
  mkdir real;
  Unix.symlink real (Filename.concat base_path "linked");
  let snapshot =
    refresh
      base_path
        (config
           (source_row "missing" "missing" ^ source_row "linked" "linked"))
    |> snapshot
  in
  match Snapshot.sources snapshot with
  | [ { observation = Snapshot.Source_missing _; _ }
    ; { observation = Source_not_directory { kind = Unix.S_LNK; _ }; _ }
    ] -> ()
  | _ -> fail "missing and symlink source observations were not preserved"
;;

let test_unreadable_package_does_not_drop_sibling () =
  with_workspace @@ fun base_path ->
  write_skill base_path ~source:"skills" ~package:"valid" ~description:"Valid" "body";
  let outside = Filename.concat base_path "outside" in
  mkdir outside;
  Unix.symlink outside (Filename.concat (Filename.concat base_path "skills") "linked");
  let snapshot =
    refresh base_path (config (source_row "skills" "skills"))
    |> snapshot
  in
  check int "valid sibling remains" 1 (List.length (Snapshot.entries snapshot));
  check int "symlink package diagnosed" 1 (List.length (Snapshot.rejections snapshot))
;;

let test_unchanged_and_workspace_isolation () =
  with_workspace @@ fun first ->
  with_workspace @@ fun second ->
  let text = config (source_row "skills" "skills") in
  let first_publication =
    refresh first text
  in
  let second_publication =
    refresh second text
  in
  (match
     refresh first text
   with
   | Service.Unchanged _ -> ()
   | Published _ | Workspace_retired -> fail "identical refresh was republished");
  check bool
    "first workspace current"
    true
    (Option.is_some (Service.current ~workspace:(workspace first)));
  check bool
    "second workspace current"
    true
    (Option.is_some (Service.current ~workspace:(workspace second)));
  check bool
    "separate immutable values"
    true
    (snapshot first_publication != snapshot second_publication)
;;

let test_rejected_config_replaces_previous_snapshot () =
  with_workspace @@ fun base_path ->
  let valid = config (source_row "skills" "skills") in
  ignore
    (refresh base_path valid);
  let rejected =
    refresh base_path "[skills]\nactivation-lifetme = \"turn\"\n"
    |> snapshot
  in
  match Snapshot.config_state rejected with
  | Snapshot.Config_rejected _ -> ()
  | Configured _ | Config_unreadable _ ->
    fail "malformed config left the previous snapshot visible"
;;

let test_refresh_is_serialized_and_latest_call_wins () =
  with_workspace @@ fun base_path ->
  let workspace = workspace base_path in
  let mutex = Mutex.create () in
  let condition = Condition.create () in
  let old_reader_started = ref false in
  let release_old_reader = ref false in
  let old_refresh =
    Domain.spawn (fun () ->
      Service.refresh
        ~workspace
        ~user_home:None
        ~read_config:(fun () ->
          Mutex.lock mutex;
          old_reader_started := true;
          Condition.broadcast condition;
          while not !release_old_reader do
            Condition.wait condition mutex
          done;
          Mutex.unlock mutex;
          Service.Config_unreadable "old read failed"))
  in
  Mutex.lock mutex;
  while not !old_reader_started do
    Condition.wait condition mutex
  done;
  Mutex.unlock mutex;
  let valid_text = config (source_row "skills" "skills") in
  let new_refresh =
    Domain.spawn (fun () ->
      Service.refresh
        ~workspace
        ~user_home:None
        ~read_config:(fun () -> Service.Config_text valid_text))
  in
  Mutex.lock mutex;
  release_old_reader := true;
  Condition.broadcast condition;
  Mutex.unlock mutex;
  ignore (Domain.join old_refresh);
  ignore (Domain.join new_refresh);
  match Service.current ~workspace with
  | Some current ->
    (match Snapshot.config_state current with
     | Snapshot.Configured _ -> ()
     | Config_rejected _ | Config_unreadable _ ->
       fail "older unreadable observation replaced the newer config")
  | None -> fail "serialized refresh did not publish"
;;

let test_workspace_alias_and_retirement () =
  with_workspace @@ fun base_path ->
  (match Service.find_workspace_of_base_path ~base_path with
   | Ok None -> ()
   | Ok (Some _) -> fail "lookup-only access created a workspace slot"
   | Error _ -> fail "valid workspace lookup failed");
  let direct = workspace base_path in
  let masc_alias = workspace (Filename.concat base_path ".masc") in
  ignore
    (Service.refresh
       ~workspace:direct
       ~user_home:None
       ~read_config:(fun () ->
         Service.Config_text (config (source_row "skills" "skills"))));
  check bool
    "canonical alias shares current snapshot"
    true
    (Option.is_some (Service.current ~workspace:masc_alias));
  Service.retire ~workspace:direct;
  check bool
    "retired slot removed"
    true
    (Option.is_none (Service.current ~workspace:masc_alias));
  (match Service.find_workspace_of_base_path ~base_path with
   | Ok None -> ()
   | Ok (Some _) -> fail "retired workspace remained registered"
   | Error _ -> fail "valid retired workspace lookup failed")
;;

let test_current_and_retire_do_not_wait_for_refresh_io () =
  with_workspace @@ fun base_path ->
  let workspace = workspace base_path in
  ignore
    (Service.refresh
       ~workspace
       ~user_home:None
       ~read_config:(fun () ->
         Service.Config_text (config (source_row "skills" "skills"))));
  let mutex = Mutex.create () in
  let condition = Condition.create () in
  let reader_started = ref false in
  let release_reader = ref false in
  let refreshing =
    Domain.spawn (fun () ->
      Service.refresh
        ~workspace
        ~user_home:None
        ~read_config:(fun () ->
          Mutex.lock mutex;
          reader_started := true;
          Condition.broadcast condition;
          while not !release_reader do
            Condition.wait condition mutex
          done;
          Mutex.unlock mutex;
          Service.Config_unreadable "refresh completed after retirement"))
  in
  Mutex.lock mutex;
  while not !reader_started do
    Condition.wait condition mutex
  done;
  Mutex.unlock mutex;
  check bool
    "current remains readable during config I/O"
    true
    (Option.is_some (Service.current ~workspace));
  Service.retire ~workspace;
  Mutex.lock mutex;
  release_reader := true;
  Condition.broadcast condition;
  Mutex.unlock mutex;
  (match Domain.join refreshing with
   | Service.Workspace_retired -> ()
   | Published _ | Unchanged _ ->
     fail "refresh published after workspace retirement");
  check bool
    "retired workspace has no current snapshot"
    true
    (Option.is_none (Service.current ~workspace))
;;

let () =
  run
    "skill_catalog_snapshot_service"
    [ ( "service"
      , [ test_case "malformed source isolation" `Quick
            test_valid_and_malformed_sources_coexist
        ; test_case "missing and symlink source" `Quick
            test_missing_and_symlink_sources_are_typed
        ; test_case "unreadable package sibling" `Quick
            test_unreadable_package_does_not_drop_sibling
        ; test_case "unchanged and workspace isolation" `Quick
            test_unchanged_and_workspace_isolation
        ; test_case "rejected config replaces snapshot" `Quick
            test_rejected_config_replaces_previous_snapshot
        ; test_case "serialized latest refresh wins" `Quick
            test_refresh_is_serialized_and_latest_call_wins
        ; test_case "workspace alias and retirement" `Quick
            test_workspace_alias_and_retirement
        ; test_case "current and retire stay independent from refresh I/O" `Quick
            test_current_and_retire_do_not_wait_for_refresh_io
        ] )
    ]
;;
