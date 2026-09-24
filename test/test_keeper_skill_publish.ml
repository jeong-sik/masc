open Alcotest
open Masc

module Service = Skill_catalog_snapshot_service
module Publish = Workspace_skill_publish

let require label = function
  | Ok value -> value
  | Error _ -> fail label
;;

(* Captured before any test installs a stub, so it is the boot default. *)
let default_hook = Atomic.get Workspace_hooks.keeper_skill_publish_fn

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let instruction ?(description = "Inspect the lane status.") name =
  Printf.sprintf
    "---\nname: %s\ndescription: %s\n---\nRead keeper_lane_status before reporting.\n"
    name
    description
;;

let keeper_name = "skill-author"

(* The seed config/runtime.toml value; the config is refused without it. *)
let resource_read_max_bytes = 65536

let config_text =
  Printf.sprintf
    "[skills]\n\
     resource-read-max-bytes = %d\n\
     [[skills.sources]]\n\
     id = %S\n\
     anchor = \"base-path\"\n\
     path = \".agents/skills\"\n\
     access = \"read-write\"\n"
    resource_read_max_bytes
    Server_keeper_skill_publish.project_agents_source_id
;;

(* The live order: project-masc is declared before project-agents, so a name
   it holds wins over a Keeper's package of the same name. *)
let earlier_source_id = "project-masc"

let config_text_with_earlier_source =
  Printf.sprintf
    "[skills]\n\
     resource-read-max-bytes = %d\n\
     [[skills.sources]]\n\
     id = %S\n\
     anchor = \"base-path\"\n\
     path = \".masc/skills\"\n\
     access = \"read-write\"\n\
     [[skills.sources]]\n\
     id = %S\n\
     anchor = \"base-path\"\n\
     path = \".agents/skills\"\n\
     access = \"read-write\"\n"
    resource_read_max_bytes
    earlier_source_id
    Server_keeper_skill_publish.project_agents_source_id
;;

type source_root_fixture =
  | Root_directory
  | Root_absent
  | Root_regular_file

let with_workspace
      ?(source_root = Root_directory)
      ?(config_text = config_text)
      ?(before_publish = fun ~base_path:_ -> ())
      f
  =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-skill-publish-" "" in
  let workspace = Service.workspace_of_base_path ~base_path |> require "workspace" in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.keeper_skill_publish_fn default_hook;
      Service.retire ~workspace;
      remove_tree base_path)
    (fun () ->
      (match source_root with
       | Root_absent -> ()
       | Root_directory ->
         Unix.mkdir (Filename.concat base_path ".agents") 0o700;
         Unix.mkdir (Filename.concat base_path ".agents/skills") 0o700
       | Root_regular_file ->
         Unix.mkdir (Filename.concat base_path ".agents") 0o700;
         Out_channel.with_open_bin (Filename.concat base_path ".agents/skills") (fun _ -> ()));
      before_publish ~base_path;
      let refresh () =
        Ok
          (Service.refresh
             ~workspace
             ~user_home:None
             ~read_config:(fun () -> Service.Config_text config_text))
      in
      (match refresh () with
       | Ok (Service.Published _ | Unchanged _) -> ()
       | Ok Workspace_retired | Error _ -> fail "fixture snapshot was not published");
      f ~base_path ~workspace ~config:(Workspace.default_config base_path) ~refresh)
;;

let args ?(package_id = "proposed") ?(evidence = [ `String "memory:fact-1" ]) source_text =
  `Assoc
    [ "package_id", `String package_id
    ; "source_text", `String source_text
    ; "evidence", `List evidence
    ]
;;

let call config args =
  let result = Keeper_skill_publish.handle ~config ~keeper_name ~args in
  match result.Keeper_tool_execution.data with
  | Some data -> result, data
  | None -> fail "missing typed result"
;;

let string_field name data = Yojson.Safe.Util.(member name data |> to_string)

let failed_with ~code ~class_ ~effect_disposition (result, data) =
  check bool "failure class" true
    (result.Keeper_tool_execution.disposition = Tool_result.Failed class_);
  check bool "effect disposition" true
    (result.Keeper_tool_execution.failure_effect_disposition = effect_disposition);
  check string "error code" code (string_field "error" data);
  check bool "message is kept" true (String.length (string_field "message" data) > 0)
;;

(* A stub that records every request it is handed. *)
let install_stub answer =
  let calls = ref [] in
  Atomic.set Workspace_hooks.keeper_skill_publish_fn (fun _config request ->
    calls := request :: !calls;
    answer request);
  calls
;;

let reference_of name source_text =
  let source_id =
    Skill_source_config.source_id_of_string
      Server_keeper_skill_publish.project_agents_source_id
    |> require "source id"
  in
  let package_id = Skill_reference.package_id_of_directory name |> require "package id" in
  Skill_reference.make
    ~identity:(Skill_reference.make_identity ~source_id ~package_id ~name)
    ~content_revision:(Skill_reference.content_revision_of_source_text source_text)
;;

let test_not_installed () =
  with_workspace
  @@ fun ~base_path:_ ~workspace:_ ~config ~refresh:_ ->
  call config (args (instruction "proposed"))
  |> failed_with
       ~code:"skill_publish_not_installed"
       ~class_:Tool_result.Dependency_unavailable
       ~effect_disposition:Tool_result.Proven_pre_effect
;;

let test_request_refused_before_hook () =
  with_workspace
  @@ fun ~base_path:_ ~workspace:_ ~config ~refresh:_ ->
  let calls = install_stub (fun _ -> fail "the hook must not be called") in
  let refused code request =
    call config request
    |> failed_with
         ~code
         ~class_:Tool_result.Policy_rejection
         ~effect_disposition:Tool_result.Proven_pre_effect
  in
  refused "invalid_evidence" (args ~evidence:[] (instruction "proposed"));
  refused "invalid_evidence" (args ~evidence:[ `String "  " ] (instruction "proposed"));
  refused "invalid_skill_publish_request" (args ~evidence:[ `Int 1 ] (instruction "proposed"));
  refused "invalid_package_id" (args ~package_id:".." (instruction "proposed"));
  refused "invalid_skill_publish_request" (`Assoc [ "package_id", `String "proposed" ]);
  check int "hook never called" 0 (List.length !calls)
;;

let test_outcomes_project_typed () =
  with_workspace
  @@ fun ~base_path:_ ~workspace:_ ~config ~refresh:_ ->
  let source_text = instruction "proposed" in
  let reference = reference_of "proposed" source_text in
  let calls =
    install_stub (fun _ ->
      Ok (Publish.Created_and_published { reference; snapshot_revision = "rev-1" }))
  in
  let result, data = call config (args source_text) in
  check bool "completed" true (result.disposition = Tool_result.Completed ());
  check string "status" "created_and_published" (string_field "status" data);
  check string "snapshot revision" "rev-1" (string_field "snapshot_revision" data);
  check bool "exact reference" true
    (Yojson.Safe.Util.member "reference" data = Skill_reference.to_yojson reference);
  (match !calls with
   | [ request ] ->
     check string "actor is the keeper" keeper_name request.actor;
     check (list string) "evidence passed as given" [ "memory:fact-1" ]
       (Publish.evidence_to_list request.evidence)
   | _ -> fail "expected exactly one hook call");
  ignore
    (install_stub (fun _ ->
       Ok (Publish.Created_but_unpublished { reference; reason = "refresh failed" })));
  let unpublished = call config (args source_text) in
  failed_with
    ~code:"created_but_unpublished"
    ~class_:Tool_result.Runtime_failure
    ~effect_disposition:Tool_result.Proven_post_effect
    unpublished;
  check string "reason" "refresh failed" (string_field "reason" (snd unpublished));
  let winner =
    Skill_reference.make_identity
      ~source_id:
        (Skill_source_config.source_id_of_string earlier_source_id |> require "source id")
      ~package_id:(Skill_reference.package_id_of_directory "proposed" |> require "package id")
      ~name:"proposed"
  in
  ignore
    (install_stub (fun _ ->
       Ok
         (Publish.Created_but_shadowed
            { reference; snapshot_revision = "rev-2"; winner })));
  let shadowed = call config (args source_text) in
  (* The write and the republish committed, so the call completes and the
     status says the rest. Every failure class carries a next move the model
     reads, and none of them is true of a package that was written. *)
  check bool "shadowed publish completes" true
    ((fst shadowed).disposition = Tool_result.Completed ());
  check string "shadowed status" "created_but_shadowed" (string_field "status" (snd shadowed));
  check bool "names the winner" true
    (Yojson.Safe.Util.member "winner" (snd shadowed) = Skill_reference.identity_to_yojson winner);
  check bool "keeps the exact reference" true
    (Yojson.Safe.Util.member "reference" (snd shadowed) = Skill_reference.to_yojson reference);
  check string "shadowed snapshot revision" "rev-2"
    (string_field "snapshot_revision" (snd shadowed));
  ignore
    (install_stub (fun _ ->
       Error
         (Server_keeper_skill_publish.refusal_of_editor_error
            Server_skill_editor.Package_already_exists)));
  call config (args source_text)
  |> failed_with
       ~code:"package_already_exists"
       ~class_:Tool_result.Policy_rejection
       ~effect_disposition:Tool_result.Proven_pre_effect;
  ignore
    (install_stub (fun _ ->
       Error
         (Server_keeper_skill_publish.refusal_of_editor_error
            Server_skill_editor.Source_read_only)));
  call config (args source_text)
  |> failed_with
       ~code:"source_read_only"
       ~class_:Tool_result.Dependency_unavailable
       ~effect_disposition:Tool_result.Proven_pre_effect;
  ignore
    (install_stub (fun _ ->
       Error
         (Server_keeper_skill_publish.refusal_of_editor_error
            (Server_skill_editor.Write_failed "disk full"))));
  call config (args source_text)
  |> failed_with
       ~code:"write_failed"
       ~class_:Tool_result.Runtime_failure
       ~effect_disposition:Tool_result.Effect_outcome_unknown
;;

(* The whole chain the server installs, with the editor, the project-agents
   source, the catalog snapshot and the audit ledger all real. Only the
   runtime.toml read is replaced by the fixture's config text. *)
let test_editor_publishes_and_never_overwrites () =
  with_workspace
  @@ fun ~base_path ~workspace ~config ~refresh ->
  Atomic.set Workspace_hooks.keeper_skill_publish_fn
    (Server_keeper_skill_publish.publish ~refresh);
  let descriptor =
    match Keeper_tool_runtime.descriptor_for_internal "keeper_skill_publish" with
    | Some descriptor -> descriptor
    | None -> fail "publish descriptor missing"
  in
  check bool "model can discover publish" true
    (List.mem "keeper_skill_publish" (Keeper_tool_descriptor.keeper_model_names descriptor));
  Masc_test_deps.init_unified_tool_registry ();
  let meta =
    Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ])
    |> require "Keeper fixture"
  in
  let context : Keeper_tool_runtime.context =
    { config; meta
    ; publication_recovery =
        { provider = Keeper_publication_recovery_availability.non_runtime_provider
        ; keeper_name = meta.name }
    ; ctx_work = Keeper_context_runtime.create ~eio:true ~system_prompt:"fixture"
    ; turn_sandbox_factory = None; sw = None; clock = None; proc_mgr = None
    ; net = None; mcp_session_id = None; continuation_channel = None
    ; gate_context = None; gate_grant = None; tool_use_id = None; trace_id = None
    ; result_projection = None
    ; capability_authority = Keeper_tool_runtime.Compatibility_meta }
  in
  let dispatch args =
    match Keeper_tool_runtime.handle context ~descriptor ~args with
    | Some result ->
      (match result.Keeper_tool_execution.data with
       | Some data -> result, data
       | None -> fail "missing typed result")
    | None -> fail "publish did not dispatch"
  in
  let original = instruction "proposed" in
  let result, data = dispatch (args original) in
  if result.Keeper_tool_execution.disposition <> Tool_result.Completed ()
  then fail ("publish did not complete: " ^ Yojson.Safe.to_string data);
  check string "status" "created_and_published" (string_field "status" data);
  let expected_reference = reference_of "proposed" original in
  check bool "reference names the project-agents package" true
    (Yojson.Safe.Util.member "reference" data = Skill_reference.to_yojson expected_reference);
  let path = Filename.concat base_path ".agents/skills/proposed/SKILL.md" in
  check string "SKILL.md bytes" original (read_file path);
  (match Service.current ~workspace with
   | Some snapshot ->
     check bool "catalog resolves the reference" true
       (Result.is_ok (Skill_catalog_snapshot.resolve_reference snapshot expected_reference))
   | None -> fail "no snapshot after publish");
  (match
     Audit_log.read_entries config
     |> List.filter (fun (entry : Audit_log.audit_entry) ->
       entry.action = Audit_log.Custom "skill_write")
   with
   | [ entry ] ->
     check string "audit actor" keeper_name entry.agent_id;
     check bool "audit evidence" true
       (Yojson.Safe.Util.member "evidence" entry.details = `List [ `String "memory:fact-1" ]);
     check bool "audit reference" true
       (Yojson.Safe.Util.member "reference" entry.details
        = Skill_reference.to_yojson expected_reference)
   | entries -> fail (Printf.sprintf "expected one skill_write row, got %d" (List.length entries)));
  dispatch (args (instruction ~description:"Replacement." "proposed"))
  |> failed_with
       ~code:"package_already_exists"
       ~class_:Tool_result.Policy_rejection
       ~effect_disposition:Tool_result.Proven_pre_effect;
  check string "existing SKILL.md untouched" original (read_file path)
;;

(* A workspace that has never had a Skill has no .agents/skills folder, and
   the live one did not: every publish was refused as source_not_ready. The
   first publish makes the declared folder and lands the package. *)
let test_first_publish_creates_the_source_folder () =
  with_workspace ~source_root:Root_absent
  @@ fun ~base_path ~workspace:_ ~config ~refresh ->
  Atomic.set Workspace_hooks.keeper_skill_publish_fn
    (Server_keeper_skill_publish.publish ~refresh);
  let original = instruction "first" in
  let result, data = call config (args ~package_id:"first" original) in
  if result.Keeper_tool_execution.disposition <> Tool_result.Completed ()
  then fail ("publish did not complete: " ^ Yojson.Safe.to_string data);
  check string "status" "created_and_published" (string_field "status" data);
  check string "SKILL.md bytes" original
    (read_file (Filename.concat base_path ".agents/skills/first/SKILL.md"))
;;

let mkdir_if_missing path = if not (Sys.file_exists path) then Unix.mkdir path 0o700

(* The live runtime.toml declares project-masc before project-agents. A Keeper
   that publishes a name project-masc already declares gets its package
   written and published, yet Keeper turns list Skills by name and see the
   project-masc one, so the answer has to say so and name it. *)
let test_publish_behind_an_earlier_source_names_the_winner () =
  let operator_text = instruction ~description:"The operator's procedure." "shared" in
  with_workspace
    ~config_text:config_text_with_earlier_source
    ~before_publish:(fun ~base_path ->
      let root = Filename.concat base_path ".masc/skills" in
      mkdir_if_missing (Filename.concat base_path ".masc");
      mkdir_if_missing root;
      Unix.mkdir (Filename.concat root "shared") 0o700;
      Out_channel.with_open_bin (Filename.concat root "shared/SKILL.md") (fun channel ->
        Out_channel.output_string channel operator_text))
  @@ fun ~base_path ~workspace:_ ~config ~refresh ->
  Atomic.set Workspace_hooks.keeper_skill_publish_fn
    (Server_keeper_skill_publish.publish ~refresh);
  let original = instruction "shared" in
  let result, data = call config (args ~package_id:"shared" original) in
  if result.Keeper_tool_execution.disposition <> Tool_result.Completed ()
  then fail ("shadowed publish did not complete: " ^ Yojson.Safe.to_string data);
  check string "shadowed status" "created_but_shadowed" (string_field "status" data);
  let winner = Yojson.Safe.Util.member "winner" data in
  check string "winner source" earlier_source_id (string_field "source_id" winner);
  check string "winner package" "shared" (string_field "package_id" winner);
  check bool "reference names the Keeper's package" true
    (Yojson.Safe.Util.member "reference" data
     = Skill_reference.to_yojson (reference_of "shared" original));
  check string "the Keeper's SKILL.md is written" original
    (read_file (Filename.concat base_path ".agents/skills/shared/SKILL.md"));
  (match
     Audit_log.read_entries config
     |> List.filter (fun (entry : Audit_log.audit_entry) ->
       entry.action = Audit_log.Custom "skill_write")
   with
   | [ entry ] ->
     check string "audit status" "created_but_shadowed" (string_field "status" entry.details)
   | entries -> fail (Printf.sprintf "expected one skill_write row, got %d" (List.length entries)));
  (* Control: the same two sources, a name project-masc does not declare. *)
  let fresh = instruction "fresh" in
  let result, data = call config (args ~package_id:"fresh" fresh) in
  if result.Keeper_tool_execution.disposition <> Tool_result.Completed ()
  then fail ("publish did not complete: " ^ Yojson.Safe.to_string data);
  check string "unshadowed status" "created_and_published" (string_field "status" data)
;;

(* The live 09-23 refusal said only "Skill source is not ready", and the
   Keeper guessed the source was undeclared when its folder was missing. A
   folder is now made when missing, so the refusal that remains is a declared
   path that is not a folder: the Keeper must be told which path and why. *)
let test_refusal_names_the_path_and_why () =
  with_workspace ~source_root:Root_regular_file
  @@ fun ~base_path ~workspace:_ ~config ~refresh ->
  let source_id =
    Skill_source_config.source_id_of_string
      Server_keeper_skill_publish.project_agents_source_id
    |> require "source id"
  in
  let error =
    match
      Server_skill_editor.create
        ~base_path
        ~source_id
        ~package_id:"blocked"
        ~source_text:(instruction "blocked")
        ~refresh
    with
    | Error error -> error
    | Ok _ -> fail "a regular file in place of the source folder must refuse"
  in
  (match error with
   | Server_skill_editor.Source_not_ready
       (Source_root_not_directory { resolved_path; kind = Unix.S_REG }) ->
     check string "names the declared path" "skills" (Filename.basename resolved_path)
   | other -> fail ("unexpected refusal: " ^ Server_skill_editor.error_to_string other));
  check bool "reason kind on the wire" true
    (Yojson.Safe.Util.(
       Server_skill_editor.error_to_yojson error |> member "reason" |> member "kind")
     = `String "not_directory");
  Atomic.set Workspace_hooks.keeper_skill_publish_fn
    (Server_keeper_skill_publish.publish ~refresh);
  let ((_, data) as outcome) = call config (args ~package_id:"blocked" (instruction "blocked")) in
  failed_with
    ~code:"source_not_ready"
    ~class_:Tool_result.Dependency_unavailable
    ~effect_disposition:Tool_result.Proven_pre_effect
    outcome;
  check string "Keeper reads the same reason"
    (Server_skill_editor.error_to_string error)
    (string_field "message" data)
;;

let () =
  Mirage_crypto_rng_unix.use_default ();
  run
    "Keeper Skill publication"
    [ ( "keeper_skill_publish"
      , [ test_case "refused when no publisher is installed" `Quick test_not_installed
        ; test_case "bad requests are refused before the publisher" `Quick
            test_request_refused_before_hook
        ; test_case "editor outcomes project typed" `Quick test_outcomes_project_typed
        ; test_case "editor path publishes and never overwrites" `Quick
            test_editor_publishes_and_never_overwrites
        ; test_case "first publish creates the source folder" `Quick
            test_first_publish_creates_the_source_folder
        ; test_case "publish behind an earlier source names the winner" `Quick
            test_publish_behind_an_earlier_source_names_the_winner
        ; test_case "refusal names the path and why" `Quick
            test_refusal_names_the_path_and_why
        ] )
    ]
;;
