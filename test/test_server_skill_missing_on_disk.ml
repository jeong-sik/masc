open Alcotest
open Masc

(* RFC-0506: a Skill activated recently whose package is gone from every
   catalog source is detected at catalog publication and recorded as
   skill_missing_on_disk (WARN log line, audit row, runtime-observer event).
   These tests build a real workspace: one present Skill on disk, retained
   activation ledgers for both a present and a ghost name, and a snapshot
   published by the real service. *)

module Snapshot = Skill_catalog_snapshot
module Service = Skill_catalog_snapshot_service
module Ledger = Keeper_skill_activation_ledger
module Detection = Server_skill_missing_on_disk

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK ->
    Unix.unlink path
;;

let with_workspace operation =
  let root = Filename.temp_file "skill-missing-on-disk-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> operation root)
;;

let mkdir path = Unix.mkdir path 0o700;;

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

let config sources = "[skills]\nresource-read-max-bytes = 16384\n" ^ sources;;

let trace_id value =
  match Keeper_id.Trace_id.of_string value with
  | Ok value -> value
  | Error detail -> fail ("trace id fixture: " ^ detail)
;;

let fixture_source_id =
  match Skill_source_config.source_id_of_string "workspace-src" with
  | Ok value -> value
  | Error detail -> fail ("source id fixture: " ^ detail)
;;

let package_id value =
  match Skill_reference.package_id_of_directory value with
  | Ok value -> value
  | Error _ -> fail "invalid package fixture"
;;

let revision character =
  match Skill_reference.content_revision_of_string (String.make 64 character) with
  | Ok value -> value
  | Error _ -> fail "invalid revision fixture"
;;

let snapshot_revision =
  match Skill_catalog_snapshot.snapshot_revision_of_string (String.make 64 'f') with
  | Ok value -> value
  | Error _ -> fail "invalid snapshot revision fixture"
;;

let reference ~package character =
  Skill_reference.make
    ~identity:
      (Skill_reference.make_identity
         ~source_id:fixture_source_id
         ~package_id:(package_id package)
         ~name:package)
    ~content_revision:(revision character)
;;

let activation ~trace ~tool_use_id ~activated_at reference =
  match
    Ledger.make_activation
      ~identity:reference.Skill_reference.identity
      ~content_revision:reference.Skill_reference.content_revision
      ~snapshot_revision
      ~turn_ref:
        (Ids.Turn_ref.make
           ~trace_id:(Keeper_id.Trace_id.to_string trace)
           ~absolute_turn:1)
      ~runtime_id:"test.runtime"
      ~skill_tool_use_id:tool_use_id
      ~agent_core_turn:0
      ~invocation:
        (Ledger.Instruction_invocation
           { origin = Ledger.Session_instruction
           ; served_content =
               Ledger.Skill_body
                 { bytes = 4
                 ; sha256 = Agent_core_sha256.(digest_string "BODY" |> to_hex)
                 }
           })
      ~activated_at
  with
  | Ok activation -> activation
  | Error _ -> fail "activation fixture was rejected"
;;

let create_session config trace =
  Unix.mkdir
    (Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace))
    0o700
;;

let record config trace activation =
  match
    Ledger.record ~keeper_name:"skill-keeper-fixture" ~config ~trace_id:trace activation
  with
  | Ok _ -> ()
  | Error error -> fail (Ledger.store_error_to_string error)
;;

let snapshot_of base_path config_text =
  match Service.workspace_of_base_path ~base_path with
  | Error _ -> fail "invalid workspace fixture"
  | Ok workspace ->
    (match
       Service.refresh
         ~workspace
         ~user_home:None
         ~read_config:(fun () ->
            { Service.path = "/fixture/runtime.toml"; source_text = config_text })
     with
     | Service.Published snapshot | Unchanged snapshot -> snapshot
     | Workspace_retired -> fail "workspace retired during snapshot fixture")
;;

let test_detects_and_records_ghost_skill () =
  with_workspace @@ fun root ->
  write_skill root ~source:"src-skills" ~package:"present-skill" ~description:"Present" "body";
  let config_text = config (source_row "workspace-src" "src-skills") in
  let workspace_config = Workspace.default_config root in
  let recent = Time_codec.rfc3339_of_unix (Time_compat.now () -. 60.) in
  let present_trace = trace_id "trace-present" in
  let ghost_trace = trace_id "trace-ghost" in
  create_session workspace_config present_trace;
  record workspace_config present_trace
    (activation
       ~trace:present_trace
       ~tool_use_id:"toolu_present_01"
       ~activated_at:recent
       (reference ~package:"present-skill" 'a'));
  create_session workspace_config ghost_trace;
  record workspace_config ghost_trace
    (activation
       ~trace:ghost_trace
       ~tool_use_id:"toolu_ghost_02"
       ~activated_at:recent
       (reference ~package:"ghost-skill" 'b'));
  let snapshot = snapshot_of root config_text in
  check bool "present skill is effective in the catalog" true
    (Option.is_some (Snapshot.find_effective_by_name snapshot "present-skill"));
  check bool "ghost skill is absent from the catalog" true
    (Option.is_none (Snapshot.find_effective_by_name snapshot "ghost-skill"));
  let ghosts = Detection.detect_and_record ~base_path:root ~snapshot in
  check int "exactly one ghost is detected" 1 (List.length ghosts);
  (match ghosts with
   | [ ghost ] ->
     check string "ghost skill name" "ghost-skill" ghost.Detection.skill_name;
     check string "ghost source id" "workspace-src" ghost.Detection.source_id;
     check string "ghost last activation recorded verbatim" recent
       ghost.Detection.last_activated_at;
     check string "expected source path points where SKILL.md would live"
       (Filename.concat
          (Filename.concat (Filename.concat root "src-skills") "ghost-skill")
          "SKILL.md")
       ghost.Detection.expected_source_path
   | _ -> fail "expected exactly one ghost");
  (* The record actually landed: one skill_missing_on_disk audit row for the
     ghost. The printed row is the measured evidence for the RFC-0506
     completion criterion. *)
  let rows =
    Audit_log.read_entries workspace_config
    |> List.filter (fun (entry : Audit_log.audit_entry) ->
           entry.Audit_log.action = Audit_log.Custom Detection.event_type)
  in
  check bool "exactly one skill_missing_on_disk audit row exists" true
    (List.length rows = 1);
  List.iter
    (fun (entry : Audit_log.audit_entry) ->
       Printf.printf
         "skill_missing_on_disk measured audit row: %s\n%!"
         (Yojson.Safe.to_string entry.Audit_log.details))
    rows;
  (* A repeated publication with the same evidence must not duplicate rows. *)
  let second = Detection.detect_and_record ~base_path:root ~snapshot in
  check int "second publication records no duplicate" 0 (List.length second);
  let rows_after_second =
    Audit_log.read_entries workspace_config
    |> List.filter (fun (entry : Audit_log.audit_entry) ->
           entry.Audit_log.action = Audit_log.Custom Detection.event_type)
  in
  check bool "audit still holds exactly one row" true
    (List.length rows_after_second = 1)
;;

let test_window_excludes_old_and_keeps_unparseable () =
  with_workspace @@ fun root ->
  write_skill root ~source:"src-skills" ~package:"present-skill" ~description:"Present" "body";
  let config_text = config (source_row "workspace-src" "src-skills") in
  let snapshot = snapshot_of root config_text in
  let now = Time_compat.now () in
  let old = Time_codec.rfc3339_of_unix (now -. (8. *. 24. *. 3600.)) in
  let recent = Time_codec.rfc3339_of_unix (now -. 60.) in
  let present_ref = reference ~package:"present-skill" 'a' in
  let old_ref = reference ~package:"ghost-old" 'b' in
  let recent_ref = reference ~package:"ghost-recent" 'c' in
  let activations =
    [ (present_ref.Skill_reference.identity, recent)
    ; (old_ref.Skill_reference.identity, old)
    ; (recent_ref.Skill_reference.identity, recent)
    ]
  in
  let detected = Detection.ghosts ~now ~snapshot ~activations in
  check int "only the in-window ghost is detected" 1 (List.length detected);
  (match detected with
   | [ ghost ] ->
     check string "in-window ghost name" "ghost-recent" ghost.Detection.skill_name
   | _ -> fail "expected exactly the in-window ghost");
  let unparseable =
    Detection.ghosts
      ~now
      ~snapshot
      ~activations:[ (old_ref.Skill_reference.identity, "not-a-timestamp") ]
  in
  check int "unparseable timestamp still records" 1 (List.length unparseable)
;;

let () =
  run "Server_skill_missing_on_disk"
    [ ( "RFC-0506 ghost detection"
      , [ test_case "detects and records a ghost skill" `Quick
            test_detects_and_records_ghost_skill
        ; test_case "window excludes old activations, keeps unparseable" `Quick
            test_window_excludes_old_and_keeps_unparseable
        ] )
    ]
;;
