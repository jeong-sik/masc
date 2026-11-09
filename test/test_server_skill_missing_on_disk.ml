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

let with_ghost_workspace ~activated_at operation =
  with_workspace @@ fun root ->
  write_skill root ~source:"src-skills" ~package:"present-skill" ~description:"Present" "body";
  let workspace_config = Workspace.default_config root in
  let trace = trace_id "trace-dedup-ghost" in
  create_session workspace_config trace;
  record workspace_config trace
    (activation ~trace ~tool_use_id:"toolu_dedup_01" ~activated_at
       (reference ~package:"ghost-skill" 'b'));
  let snapshot = snapshot_of root (config (source_row "workspace-src" "src-skills")) in
  operation root workspace_config trace snapshot
;;

let ghost_rows workspace_config =
  Audit_log.read_entries_matching
    ~keep:(fun (entry : Audit_log.audit_entry) ->
       String.equal entry.agent_id "skill-catalog"
       && entry.action = Audit_log.Custom Detection.event_type
       && entry.outcome = Audit_log.Success)
    workspace_config
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

let test_observation_identity_and_reactivation () =
  let recent = Time_codec.rfc3339_of_unix (Time_compat.now () -. 120.) in
  with_ghost_workspace ~activated_at:recent @@ fun root workspace_config trace snapshot ->
  let prior_row ~agent_id ~action ~outcome ~skill_name ~source_id =
    Audit_log.append_entry workspace_config
      { Audit_log.timestamp = Time_compat.now ()
      ; agent_id
      ; action
      ; details =
          `Assoc
            [ "skill_name", `String skill_name
            ; "source_id", `String source_id
            ; "last_activated_at", `String recent
            ]
      ; outcome
      ; cost_estimate = None
      ; token_count = None
      ; trace_id = None
      }
  in
  let append_prior =
    prior_row ~action:(Audit_log.Custom Detection.event_type)
      ~skill_name:"ghost-skill" ~source_id:"workspace-src"
  in
  append_prior ~agent_id:"another-observer" ~outcome:Audit_log.Success;
  append_prior ~agent_id:"skill-catalog" ~outcome:(Audit_log.Failure "not recorded");
  prior_row ~agent_id:"skill-catalog" ~action:(Audit_log.Custom "another-event")
    ~outcome:Audit_log.Success ~skill_name:"ghost-skill" ~source_id:"workspace-src";
  prior_row ~agent_id:"skill-catalog" ~action:(Audit_log.Custom Detection.event_type)
    ~outcome:Audit_log.Success ~skill_name:"ghost-skill" ~source_id:"another-source";
  prior_row ~agent_id:"skill-catalog" ~action:(Audit_log.Custom Detection.event_type)
    ~outcome:Audit_log.Success ~skill_name:"another-skill" ~source_id:"workspace-src";
  check int "only the exact successful observer key suppresses a ghost" 1
    (List.length (Detection.detect_and_record ~base_path:root ~snapshot));
  let newer = Time_codec.rfc3339_of_unix (Time_compat.now () -. 60.) in
  record workspace_config trace
    (activation ~trace ~tool_use_id:"toolu_dedup_02" ~activated_at:newer
       (reference ~package:"ghost-skill" 'b'));
  check int "a fresh activation records a fresh observation" 1
    (List.length (Detection.detect_and_record ~base_path:root ~snapshot));
  check int "that activation is then suppressed" 0
    (List.length (Detection.detect_and_record ~base_path:root ~snapshot));
  with_ghost_workspace ~activated_at:recent @@ fun other_root other_config _ other_snapshot ->
  check int "another workspace owns an independent observation" 1
    (List.length (Detection.detect_and_record ~base_path:other_root ~snapshot:other_snapshot));
  check int "its audit has one observation" 1 (List.length (ghost_rows other_config))
;;

let test_failed_append_can_retry () =
  let recent = Time_codec.rfc3339_of_unix (Time_compat.now () -. 60.) in
  with_ghost_workspace ~activated_at:recent @@ fun root workspace_config _ snapshot ->
  let audit_path = Filename.concat (Workspace.masc_dir workspace_config) Audit_log.store_dirname in
  (* A regular file at the store directory blocks the real audit append,
     without relying on uid-specific permission behavior. *)
  write_file audit_path "blocked audit directory";
  ignore (Detection.detect_and_record ~base_path:root ~snapshot);
  check int "failed append leaves no successful observation key" 0
    (List.length (ghost_rows workspace_config));
  Sys.remove audit_path;
  check int "the same observation is retried after storage recovers" 1
    (List.length (Detection.detect_and_record ~base_path:root ~snapshot));
  check int "one successful observation is now retained" 1
    (List.length (ghost_rows workspace_config));
  check int "the successful retry suppresses further duplicates" 0
    (List.length (Detection.detect_and_record ~base_path:root ~snapshot))
;;

let test_concurrent_observations_use_canonical_workspace () =
  let recent = Time_codec.rfc3339_of_unix (Time_compat.now () -. 60.) in
  with_ghost_workspace ~activated_at:recent @@ fun root workspace_config _ snapshot ->
  let alias = Filename.concat root "." in
  ignore (Workspace.default_config alias);
  let events = Atomic.make 0 in
  let subscriber = "ghost-observation-concurrency" in
  Sse.subscribe_external ~id:subscriber
    ~runtime_authority:(Sse.runtime_authority_exn ~base_path:root)
    ~callback:(fun (event : Sse.external_event) ->
       match event.ext_payload with
       | `Assoc fields when List.assoc_opt "type" fields = Some (`String Detection.event_type) ->
         Atomic.incr events
       | _ -> ()) ();
  Fun.protect
    ~finally:(fun () -> Sse.unsubscribe_external subscriber)
    (fun () ->
       let ready = Atomic.make 0 and go = Atomic.make false in
       let observe base_path =
         Atomic.incr ready;
         while not (Atomic.get go) do Domain.cpu_relax () done;
         Detection.detect_and_record ~base_path ~snapshot
       in
       let first = Domain.spawn (fun () -> observe root) in
       let second = Domain.spawn (fun () -> observe alias) in
       while Atomic.get ready < 2 do Domain.cpu_relax () done;
       Atomic.set go true;
       let recorded = List.length (Domain.join first) + List.length (Domain.join second) in
       check int "concurrent observers record one fresh ghost" 1 recorded;
       check int "one audit row survives" 1 (List.length (ghost_rows workspace_config));
       check int "one runtime-observer event is sent" 1 (Atomic.get events))
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
        ; test_case "observation identity, reactivation and workspace scope" `Quick
            test_observation_identity_and_reactivation
        ; test_case "failed audit append can retry" `Quick
            test_failed_append_can_retry
        ; test_case "concurrent observations share a canonical workspace" `Quick
            test_concurrent_observations_use_canonical_workspace
        ] )
    ]
;;
