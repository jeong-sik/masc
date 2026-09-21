open Alcotest

module Reference = Skill_reference
module Snapshot = Skill_catalog_snapshot
module Selection = Masc.Keeper_task_skill_turn
module Inputs = Masc.Keeper_world_observation_inputs

let source_row ~id ~path =
  Printf.sprintf
    "[[skills.sources]]\nid = %S\nanchor = \"base-path\"\npath = %S\naccess = \"read-write\"\n"
    id
    path
;;

let config_with_resource_read_max_bytes resource_read_max_bytes sources =
  let text =
    Printf.sprintf
      "[skills]\nresource-read-max-bytes = %d\n"
      resource_read_max_bytes
    ^ sources
  in
  match Skill_source_config.parse_text text with
  | Ok config -> config
  | Error diagnostics ->
    fail
      (String.concat
         "; "
         (List.map Skill_source_config.diagnostic_to_string diagnostics))
;;

let config = config_with_resource_read_max_bytes 65536

let document ~name ~description body =
  Printf.sprintf "---\nname: %s\ndescription: %s\n---\n%s" name description body
;;

let composition_document ~name ~node_id =
  document
    ~name
    ~description:"exact composition"
    (Printf.sprintf
       "```toml composition\n[[compositions]]\nname = %S\ndescription = \"exact composition\"\nexecution = \"inline\"\n[[compositions.nodes]]\nid = %S\ntool = \"keeper_lane_status\"\n[compositions.nodes.input]\nkind = \"literal\"\nvalue = {}\n```"
       name
       node_id)
;;

let scan ~base_path source candidates =
  let resolved = Skill_source_config.resolve ~base_path ~user_home:None source in
  let resolved_path =
    match resolved.resolution with
    | Skill_source_config.Resolved path -> path
    | _ -> fail "fixture source did not resolve"
  in
  { Snapshot.source = resolved
  ; observation = Source_ready { resolved_path; candidates = List.length candidates }
  ; candidates =
      List.map
        (fun (directory, source_text) ->
           Snapshot.Candidate_document { directory; source_text })
        candidates
  }
;;

let snapshot config candidates_by_source =
  let scans =
    match config.Skill_source_config.sources, candidates_by_source with
    | [ first; second ], [ first_candidates; second_candidates ] ->
      [ scan ~base_path:"/workspace" first first_candidates
      ; scan ~base_path:"/workspace" second second_candidates
      ]
    | [ only ], [ candidates ] -> [ scan ~base_path:"/workspace" only candidates ]
    | _ -> fail "fixture source/candidate arity differs"
  in
  match Snapshot.configured ~config scans with
  | Ok snapshot -> snapshot
  | Error _ -> fail "fixture snapshot was rejected"
;;

let package directory =
  match Reference.package_id_of_directory directory with
  | Ok package -> package
  | Error _ -> fail "fixture package is invalid"
;;

let exact_reference snapshot ~source_id ~package_id ~name =
  let identity =
    Reference.make_identity ~source_id ~package_id:(package package_id) ~name
  in
  match Snapshot.find_exact snapshot identity with
  | Some entry -> Snapshot.entry_reference entry
  | None -> fail "fixture exact entry is absent"
;;

let one_selected selection =
  match selection.Selection.selected with
  | [ selected ] -> selected
  | selected -> failf "expected one selected Skill, got %d" (List.length selected)
;;

let resolve_one snapshot reference =
  match Selection.resolve ~snapshot [ reference ] with
  | Ok selection -> one_selected selection
  | Error error -> fail (Selection.error_to_string error)
;;

let instruction_skill reference (skill : Masc.Keeper_skill_catalog.skill) =
  Masc.Keeper_tool_composition_surface.instruction_skill
    ~reference
    ~description:skill.description
    ~body:skill.body
    ()
;;

let parsed_skill name =
  match
    Masc.Keeper_skill_catalog.parse_skill
      ~directory:name
      (document ~name ~description:(name ^ " description") (name ^ " body"))
  with
  | Ok skill -> skill
  | Error error -> fail (Masc.Keeper_skill_catalog.error_to_string error)
;;

let test_keeper_name_selection_filters_global_and_task_exactly () =
  let global, rejected =
    Masc.Keeper_skill_catalog.partition_documents
      [ "guide", document ~name:"guide" ~description:"guide" "GUIDE"
      ; "review", document ~name:"review" ~description:"review" "REVIEW"
      ]
  in
  check int "global fixture has no rejection" 0 (List.length rejected);
  let task = [ parsed_skill "task-only" ] in
  let names projection =
    Masc.Keeper_skill_catalog.skills projection.Masc.Keeper_skill_catalog.catalog
    |> List.map (fun (skill : Masc.Keeper_skill_catalog.skill) -> skill.name)
  in
  let selected =
    Masc.Keeper_skill_catalog.project_turn
      ~names:(Some [ "guide"; "missing" ])
      ~global
      ~task
  in
  check (list string) "exact global selection" [ "guide" ] (names selected);
  check bool "Task cannot bypass Keeper selection" false (List.mem "task-only" (names selected));
  (match Masc.Keeper_skill_catalog.configured_names_unavailable selected with
   | [ unavailable ] ->
     let json = Masc.Keeper_skill_catalog.configured_name_unavailable_to_yojson unavailable in
     check string "unknown name" "missing" Yojson.Safe.Util.(member "name" json |> to_string);
     check string
       "typed reason"
       "not_in_turn_skill_catalog"
       Yojson.Safe.Util.(member "reason" json |> to_string)
   | unavailable -> failf "expected one unavailable name, got %d" (List.length unavailable));
  let task_selected =
    Masc.Keeper_skill_catalog.project_turn ~names:(Some [ "task-only" ]) ~global ~task
  in
  check (list string) "Task Skill selected by the same name rule" [ "task-only" ] (names task_selected);
  let none = Masc.Keeper_skill_catalog.project_turn ~names:(Some []) ~global ~task in
  check (list string) "explicit empty selects none" [] (names none);
  let all = Masc.Keeper_skill_catalog.project_turn ~names:None ~global ~task in
  check (list string) "absent selection keeps Task-first all" [ "task-only"; "guide"; "review" ] (names all)
;;

let test_keeper_name_selection_filters_prompt_and_activation_task_views () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let skill_snapshot =
    snapshot
      config
      [ [ "guide", document ~name:"guide" ~description:"guide" "GUIDE"
        ; ( "task-only"
          , document ~name:"task-only" ~description:"task-only" "TASK" )
        ]
      ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let task_reference =
    exact_reference
      skill_snapshot
      ~source_id
      ~package_id:"task-only"
      ~name:"task-only"
  in
  let selection =
    match
      Selection.resolve_for_task
        ~snapshot:skill_snapshot
        ~task_id:"task-held"
        [ task_reference ]
    with
    | Ok selection -> selection
    | Error error -> fail (Selection.error_to_string error)
  in
  let global, _ = Masc.Keeper_skill_catalog.of_snapshot skill_snapshot in
  let projection =
    Masc.Keeper_skill_catalog.project_turn
      ~names:(Some [ "guide" ])
      ~global
      ~task:(Selection.skills selection)
  in
  let executable = Selection.executable_selection ~projection selection in
  check int
    "activation provenance excludes the filtered Task Skill"
    0
    (List.length executable.selected);
  match
    Selection.exact_task_surfaces
      ~snapshot:skill_snapshot
      ~tool_deny:[]
      ~sandbox_profile:Masc.Keeper_types_profile.Docker
      ~skill_names:(Some [ "guide" ])
      ~selection
      ~current_task:Inputs.No_current_task
      ~held_task_skills:
        [ { Inputs.held_task_id = "task-held"
          ; held_skills = [ task_reference ]
          }
        ]
  with
  | [ ( "task-held"
      , [ { Masc.Keeper_skill_catalog.availability =
              Masc.Keeper_skill_catalog.Exact_unavailable _
          ; _
          }
        ] ) ] ->
    ()
  | surfaces ->
    failf
      "filtered prompt surface diverged: %s"
      (Yojson.Safe.to_string
         (`List
            (List.concat_map
               (fun (_, entries) ->
                  List.map Masc.Keeper_skill_catalog.exact_surface_to_yojson entries)
               surfaces)))
;;

let test_denied_node_tool_withholds_task_composition_from_prompt () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let skill_snapshot =
    snapshot
      config
      [ [ "lane-read", composition_document ~name:"lane-read" ~node_id:"lane" ] ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let task_reference =
    exact_reference
      skill_snapshot
      ~source_id
      ~package_id:"lane-read"
      ~name:"lane-read"
  in
  let selection =
    match
      Selection.resolve_for_task
        ~snapshot:skill_snapshot
        ~task_id:"task-001"
        [ task_reference ]
    with
    | Ok selection -> selection
    | Error error -> fail (Selection.error_to_string error)
  in
  let surfaces ~tool_deny =
    Selection.exact_task_surfaces
      ~snapshot:skill_snapshot
      ~tool_deny
      ~sandbox_profile:Masc.Keeper_types_profile.Docker
      ~skill_names:None
      ~selection
      ~current_task:Inputs.No_current_task
      ~held_task_skills:
        [ { Inputs.held_task_id = "task-001"; held_skills = [ task_reference ] } ]
  in
  (match surfaces ~tool_deny:[] with
   | [ ( "task-001"
       , [ { Masc.Keeper_skill_catalog.availability =
               Masc.Keeper_skill_catalog.Composition_tool { tool_name }
           ; _
           }
         ] ) ] ->
     check string "an admitted Task composition is advertised as its tool"
       "keeper_compose_lane-read" tool_name
   | _ -> fail "an admitted Task composition was not advertised as a composition");
  match surfaces ~tool_deny:[ "keeper_lane_status" ] with
  | [ ( "task-001"
      , [ { Masc.Keeper_skill_catalog.availability =
              Masc.Keeper_skill_catalog.Exact_unavailable { diagnostic }
          ; _
          }
        ] ) ] ->
    check string "the prompt row names the node tool the surface does not admit"
      "composition tool \"keeper_compose_lane-read\" runs node tools this turn's \
       surface does not admit: keeper_lane_status"
      diagnostic
  | _ -> fail "a withheld Task composition was still advertised as callable"
;;

let test_shadow_reference_selects_shadow_not_effective_winner () =
  let config =
    config
      (source_row ~id:"first" ~path:"first"
       ^ source_row ~id:"second" ~path:"second")
  in
  let snapshot =
    snapshot
      config
      [ [ "review", document ~name:"review" ~description:"winner" "WINNER_BODY" ]
      ; [ "review", document ~name:"review" ~description:"shadow" "SHADOW_BODY" ]
      ]
  in
  let source_id =
    match config.sources with
    | [ _; second ] -> second.id
    | _ -> fail "expected two sources"
  in
  let reference = exact_reference snapshot ~source_id ~package_id:"review" ~name:"review" in
  let selected = resolve_one snapshot reference in
  check string "shadow body" "SHADOW_BODY" selected.skill.body;
  check bool "exact reference preserved" true (Reference.equal reference selected.reference)
;;

let test_held_shadow_composition_wins_with_exact_collision_evidence () =
  let config =
    config
      (source_row ~id:"first" ~path:"first"
       ^ source_row ~id:"second" ~path:"second")
  in
  let skill_snapshot =
    snapshot
      config
      [ [ "review", composition_document ~name:"review" ~node_id:"global" ]
      ; [ "review", composition_document ~name:"review" ~node_id:"task" ]
      ]
  in
  let task_source_id =
    match config.sources with
    | [ _; task_source ] -> task_source.id
    | _ -> fail "expected two sources"
  in
  let task_reference =
    exact_reference
      skill_snapshot
      ~source_id:task_source_id
      ~package_id:"review"
      ~name:"review"
  in
  let task_selection =
    match
      Selection.resolve_for_task
        ~snapshot:skill_snapshot
        ~task_id:"task-held"
        [ task_reference ]
    with
    | Ok selection -> selection
    | Error error -> fail (Selection.error_to_string error)
  in
  let task_partition = Selection.partition task_selection in
  check (list string) "held Task provenance retained" [ "task-held" ]
    (one_selected task_selection).task_ids;
  check int "not exposed through keeper_skill" 0
    (List.length task_partition.instructions);
  check int "one exact Task composition" 1
    (List.length task_partition.compositions);
  let global, _ = Masc.Keeper_skill_catalog.of_snapshot skill_snapshot in
  let projected =
    Masc.Keeper_skill_catalog.project_turn
      ~names:None
      ~global
      ~task:(Selection.skills task_selection)
  in
  let composition_references =
    Masc.Keeper_skill_catalog.skills projected.catalog
    |> List.filter_map (fun (skill : Masc.Keeper_skill_catalog.skill) ->
         match skill.reference, skill.surface with
         | Some reference, Masc.Keeper_skill_catalog.Composition _ -> Some reference
         | None, _ | Some _, Masc.Keeper_skill_catalog.Instruction -> None)
  in
  check int "one executable composition tool" 1 (List.length composition_references);
  check bool "Task exact identity has priority" true
    (match composition_references with
     | [ reference ] -> Reference.equal task_reference reference
     | _ -> false);
  check int "global collision is typed unavailable" 1
    (List.length projected.unavailable);
  let prompt_surfaces =
    Masc.Keeper_skill_catalog.exact_surfaces
      projected
      ~task:(Selection.skills task_selection)
  in
  check bool "prompt names the exact composition tool" true
    (match prompt_surfaces with
     | [ surface ] ->
       let json = Masc.Keeper_skill_catalog.exact_surface_to_yojson surface in
       Yojson.Safe.Util.(member "kind" json |> to_string) = "composition"
       && Yojson.Safe.Util.(member "tool_name" json |> to_string)
          = "keeper_compose_review"
     | _ -> false);
  check bool "collision names both exact identities" true
    (match projected.unavailable with
     | [ Masc.Keeper_skill_catalog.Composition_tool_name_collision
           { selected; unavailable; _ } ] ->
       Reference.equal selected task_reference
       && not (Reference.equal unavailable task_reference)
     | _ -> false)
  ;
  let current_source_id =
    match config.sources with
    | current_source :: _ -> current_source.id
    | [] -> fail "expected a current source"
  in
  let current_reference =
    exact_reference
      skill_snapshot
      ~source_id:current_source_id
      ~package_id:"review"
      ~name:"review"
  in
  let resolve_task task_id reference =
    match
      Selection.resolve_for_task
        ~snapshot:skill_snapshot
        ~task_id
        [ reference ]
    with
    | Ok selection -> selection
    | Error error -> fail (Selection.error_to_string error)
  in
  let current = resolve_task "task-current" current_reference in
  let held = resolve_task "task-held" task_reference in
  let merged = Selection.merge [ current; held ] in
  let collision_projection =
    Masc.Keeper_skill_catalog.project_turn
      ~names:None
      ~global
      ~task:(Selection.skills merged)
  in
  let held_prompt =
    Masc.Keeper_skill_catalog.exact_surfaces
      collision_projection
      ~task:(Selection.skills held)
  in
  check bool "held collision is explicit prompt unavailability" true
    (match held_prompt with
     | [ surface ] ->
       let json = Masc.Keeper_skill_catalog.exact_surface_to_yojson surface in
       Yojson.Safe.Util.(member "kind" json |> to_string) = "unavailable"
       && not (Yojson.Safe.Util.member "diagnostic" json = `Null)
     | _ -> false)
;;

let test_malformed_exact_composition_is_frozen_instruction () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let malformed =
    document
      ~name:"broken"
      ~description:"malformed exact composition"
      "```toml composition\n[[compositions]]\nname =\n```"
  in
  let skill_snapshot = snapshot config [ [ "broken", malformed ] ] in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let reference =
    exact_reference
      skill_snapshot
      ~source_id
      ~package_id:"broken"
      ~name:"broken"
  in
  let selection =
    match Selection.resolve ~snapshot:skill_snapshot [ reference ] with
    | Ok selection -> selection
    | Error error -> fail (Selection.error_to_string error)
  in
  let selected = one_selected selection in
  check bool "frozen body retained" true
    (String_util.contains_substring selected.skill.body "name =");
  check bool "typed composition diagnostic retained" true
    (match selected.diagnostic with
     | Some (Masc.Keeper_skill_catalog.Composition_rejected _) -> true
     | Some _ | None -> false);
  let partition = Selection.partition selection in
  check int "fallback admitted to keeper_skill" 1
    (List.length partition.instructions);
  check int "malformed composition is not executable" 0
    (List.length partition.compositions)
;;

let test_shared_exact_reference_retains_every_task_id () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let skill_snapshot =
    snapshot
      config
      [ [ "guide", document ~name:"guide" ~description:"shared" "BODY" ] ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let reference =
    exact_reference
      skill_snapshot
      ~source_id
      ~package_id:"guide"
      ~name:"guide"
  in
  let resolve task_id =
    match Selection.resolve_for_task ~snapshot:skill_snapshot ~task_id [ reference ] with
    | Ok selection -> selection
    | Error error -> fail (Selection.error_to_string error)
  in
  let merged = Selection.merge [ resolve "task-a"; resolve "task-b" ] in
  check int "one exact selection" 1 (List.length merged.selected);
  check (list string) "all Task ids retained" [ "task-a"; "task-b" ]
    (one_selected merged).task_ids
;;

let run_skill_tool tool input =
  let invocation =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"task-skill-turn-exact"
      ~turn:0
      ~schedule:
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
      ~completion:(Agent_core.Tool.completion tool)
  in
  match
    tool.Agent_core.Tool.handler
      (Agent_core.Tool.Execution_env.create ~invocation ())
      input
  with
  | Ok output -> output.Agent_core.Llm_provider.Types.content
  | Error error -> error.Agent_core.Llm_provider.Types.message
;;

let test_exact_reference_consumer_rejects_name_fallback () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let snapshot =
    snapshot
      config
      [ [ "guide", document ~name:"guide" ~description:"exact" "EXACT_BODY" ] ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let reference = exact_reference snapshot ~source_id ~package_id:"guide" ~name:"guide" in
  let selected = resolve_one snapshot reference in
  let tool =
    Masc.Keeper_tool_composition_surface.For_testing.make_instruction_skill_tool
      ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
      ~instruction_skills:[ instruction_skill reference selected.skill ]
      ()
  in
  let schema_tool =
    Masc.Keeper_tool_composition_surface.instruction_skill_schema_tool
      ~instruction_skills:[ instruction_skill reference selected.skill ]
  in
  check string
    "executable and effective-surface descriptions match"
    tool.schema.description
    schema_tool.schema.description;
  check string
    "executable and effective-surface schemas match"
    (Option.map Yojson.Safe.to_string tool.schema.input_schema
     |> Option.value ~default:"absent")
    (Option.map Yojson.Safe.to_string schema_tool.schema.input_schema
     |> Option.value ~default:"absent");
  let exact_output = run_skill_tool tool (Reference.to_yojson reference) in
  check bool "exact input reads body" true
    (String_util.contains_substring exact_output "EXACT_BODY");
  let activation_attempts = ref 0 in
  let failing_tool =
    Masc.Keeper_tool_composition_surface.For_testing.make_instruction_skill_tool
      ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
      ~record_activation:(fun ~invocation:_ ~content:_ observed ->
        incr activation_attempts;
        ignore observed;
        Error Masc.Keeper_skill_activation_recorder.Turn_scope_mismatch)
      ~instruction_skills:[ instruction_skill reference selected.skill ]
      ()
  in
  let failed_output =
    run_skill_tool failing_tool (Reference.to_yojson reference)
  in
  check int "activation attempted once" 1 !activation_attempts;
  check bool "body withheld when activation recording fails" false
    (String_util.contains_substring failed_output "EXACT_BODY");
  let legacy_output = run_skill_tool tool (`Assoc [ "name", `String "guide" ]) in
  check bool "name fallback rejected" false
    (String_util.contains_substring legacy_output "EXACT_BODY")
;;

let test_resolved_body_stays_frozen_after_new_snapshot () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let original =
    snapshot config [ [ "guide", document ~name:"guide" ~description:"guide" "FROZEN_BODY" ] ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let reference = exact_reference original ~source_id ~package_id:"guide" ~name:"guide" in
  let selected = resolve_one original reference in
  let _later =
    snapshot config [ [ "guide", document ~name:"guide" ~description:"guide" "LATER_BODY" ] ]
  in
  check string "turn keeps captured body" "FROZEN_BODY" selected.skill.body
;;

let test_resource_is_read_only_when_exact_file_is_requested () =
  let source_root = Filename.temp_dir "keeper-skill-resource-" "" in
  let skill_root = Filename.concat source_root "guide" in
  let references = Filename.concat skill_root "references" in
  Fs_compat.mkdir_p references;
  let resource = Filename.concat references "PROOF.md" in
  let oversized_resource = Filename.concat references "TOO-LARGE.md" in
  let boundary_resource = Filename.concat references "BOUNDARY.md" in
  let boundary_contents =
    String.make Masc.Tool_bridge.default_externalize_threshold_bytes '"'
  in
  Fs_compat.save_file resource "12345678";
  Fs_compat.save_file oversized_resource "123456789";
  Fs_compat.save_file boundary_resource boundary_contents;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree source_root)
    (fun () ->
       let config =
         config_with_resource_read_max_bytes
           8
           (source_row ~id:"only" ~path:"skills")
       in
       let resource_read_max_bytes =
         match config.resource_read_max_bytes with
         | Some value -> value
         | None -> fail "resource read bound fixture is missing"
       in
       let skill_snapshot =
         snapshot
           config
           [ [ "guide", document ~name:"guide" ~description:"guide" "BODY" ] ]
       in
       let source_id =
         match config.sources with
         | [ source ] -> source.id
         | _ -> fail "expected one source"
       in
       let reference =
         exact_reference
           skill_snapshot
           ~source_id
           ~package_id:"guide"
           ~name:"guide"
       in
       let selected = resolve_one skill_snapshot reference in
       let instruction =
         Masc.Keeper_tool_composition_surface.instruction_skill
           ~resource_location:
             Masc.Keeper_tool_composition_surface.
               { source_root; directory = "guide"; resource_read_max_bytes }
           ~reference
           ~description:selected.skill.description
           ~body:selected.skill.body
           ()
       in
       let tool =
         Masc.Keeper_tool_composition_surface.For_testing.make_instruction_skill_tool
           ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
           ~instruction_skills:[ instruction ]
           ()
       in
       let input =
         match Reference.to_yojson reference with
         | `Assoc fields ->
           `Assoc (("file", `String "references/PROOF.md") :: fields)
         | _ -> assert false
       in
       let output = run_skill_tool tool input in
       check string "requested resource is the exact provider wire body" "12345678" output;
       let escaped =
         match Reference.to_yojson reference with
         | `Assoc fields -> `Assoc (("file", `String "../OUTSIDE.md") :: fields)
         | _ -> assert false
       in
       let escaped_output = run_skill_tool tool escaped in
       check bool
         "parent traversal never reaches the resource reader"
         false
         (String_util.contains_substring escaped_output "12345678");
       let activation_attempts = ref 0 in
       let bounded_tool =
         Masc.Keeper_tool_composition_surface.For_testing.make_instruction_skill_tool
           ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
           ~record_activation:(fun ~invocation:_ ~content:_ _ ->
             incr activation_attempts;
             Error Masc.Keeper_skill_activation_recorder.Turn_scope_mismatch)
           ~instruction_skills:[ instruction ]
           ()
       in
       let oversized =
         match Reference.to_yojson reference with
         | `Assoc fields ->
           `Assoc (("file", `String "references/TOO-LARGE.md") :: fields)
         | _ -> assert false
       in
       let oversized_output = run_skill_tool bounded_tool oversized in
       check int "oversized resource records no activation" 0 !activation_attempts;
       check bool "oversized resource reports typed bound" true
         (String_util.contains_substring oversized_output "too_large"
          && String_util.contains_substring oversized_output "max_bytes");
       check bool "oversized resource returns no contents" false
         (String_util.contains_substring oversized_output "123456789");
       let duplicate =
         match Reference.to_yojson reference with
         | `Assoc fields ->
           `Assoc
             (("file", `String "references/PROOF.md")
              :: ("file", `String "references/OTHER.md")
              :: fields)
         | _ -> assert false
       in
       let duplicate_output = run_skill_tool tool duplicate in
       check bool "duplicate resource fields are typed rejection" true
         (String_util.contains_substring duplicate_output "at most one");
       check bool "duplicate resource fields read nothing" false
         (String_util.contains_substring duplicate_output "12345678");
       let boundary_config =
         config_with_resource_read_max_bytes
           Masc.Tool_bridge.default_externalize_threshold_bytes
           (source_row ~id:"only" ~path:"skills")
       in
       let boundary_snapshot =
         snapshot
           boundary_config
           [ [ "guide", document ~name:"guide" ~description:"guide" "BODY" ] ]
       in
       let boundary_reference =
         exact_reference
           boundary_snapshot
           ~source_id
           ~package_id:"guide"
           ~name:"guide"
       in
       let boundary_selected = resolve_one boundary_snapshot boundary_reference in
       let boundary_read_max_bytes =
         match boundary_config.resource_read_max_bytes with
         | Some value -> value
         | None -> fail "boundary resource read bound fixture is missing"
       in
       let boundary_instruction =
         Masc.Keeper_tool_composition_surface.instruction_skill
           ~resource_location:
             Masc.Keeper_tool_composition_surface.
               { source_root
               ; directory = "guide"
               ; resource_read_max_bytes = boundary_read_max_bytes
               }
           ~reference:boundary_reference
           ~description:boundary_selected.skill.description
           ~body:boundary_selected.skill.body
           ()
       in
       let boundary_tool =
         Masc.Keeper_tool_composition_surface.For_testing.make_instruction_skill_tool
           ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
           ~instruction_skills:[ boundary_instruction ]
           ()
       in
       let boundary_input =
         match Reference.to_yojson boundary_reference with
         | `Assoc fields ->
           `Assoc (("file", `String "references/BOUNDARY.md") :: fields)
         | _ -> assert false
       in
       let boundary_output = run_skill_tool boundary_tool boundary_input in
       check int
         "escape-heavy boundary content keeps exact wire length"
         Masc.Tool_bridge.default_externalize_threshold_bytes
         (String.length boundary_output);
       check string
         "escape-heavy boundary content is not replaced by an artifact marker"
         boundary_contents
         boundary_output)
;;

let test_revision_mismatch_is_typed_before_tool_projection () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let snapshot =
    snapshot config [ [ "guide", document ~name:"guide" ~description:"guide" "BODY" ] ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let current = exact_reference snapshot ~source_id ~package_id:"guide" ~name:"guide" in
  let stale_revision =
    match Reference.content_revision_of_string (String.make 64 'f') with
    | Ok revision -> revision
    | Error _ -> fail "stale revision fixture is invalid"
  in
  let stale = Reference.make ~identity:current.identity ~content_revision:stale_revision in
  match Selection.resolve ~snapshot [ stale ] with
  | Error
      (Selection.Reference_resolution_failed
         { error = Snapshot.Content_revision_mismatch _; _ } as typed) ->
    check string
      "typed code"
      "task_skill_content_revision_mismatch"
      (Selection.error_code typed);
    (match Selection.of_core_error (Selection.core_error typed) with
     | Some recovered -> check string "typed carrier" (Selection.error_code typed) (Selection.error_code recovered)
     | None -> fail "typed error carrier was lost")
  | Error error -> failf "wrong typed error: %s" (Selection.error_to_string error)
  | Ok _ -> fail "stale reference resolved"
;;

let test_jev_advice_reaches_the_model_without_selecting_or_authorizing () =
  let open Masc in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let log_root = Filename.temp_dir "skill-jev-tool-log-" "" in
  Keeper_tool_call_log.reset_for_testing ();
  Eio.Switch.on_release sw (fun () ->
    Keeper_tool_call_log.reset_for_testing ();
    Fs_compat.remove_tree log_root);
  Keeper_tool_call_log.init ~base_path:log_root ();
  let fixture_config = config (source_row ~id:"only" ~path:"skills") in
  let frozen_body = "FROZEN_SKILL_BODY" ^ String.make Keeper_tool_call_log.max_output_len 'x' in
  let captured_snapshot = snapshot fixture_config
      [ [ "guide", document ~name:"guide" ~description:"exact" frozen_body ] ] in
  let source_id = (List.hd fixture_config.sources).id in
  let reference = exact_reference captured_snapshot ~source_id ~package_id:"guide" ~name:"guide" in
  let selected = resolve_one captured_snapshot reference in
  let response ?(extra_answers = []) decision = Yojson.Safe.to_string (`Assoc
    [ "model", `String "fixture-jev"
    ; "answers", `Assoc ([ "applicability", `Assoc
        [ "type", `String "choice"; "choice", `String decision
        ; "confidence", `Float 1.0
        ; "probabilities", `Assoc
            (List.map
               (fun option -> option, `Float (if String.equal option decision then 1.0 else 0.0))
               [ "applicable"; "not_applicable"; "insufficient_context" ]) ] ]
        @ extra_answers) ]) in
  let server = Exact_output_fixture.start_server ~sw ~net ~clock
      (Exact_output_fixture.Replies
        [ response "not_applicable"; response "applicable"; response "insufficient_context"
        ; response "not-an-offered-choice"
        ; response ~extra_answers:[ "surplus", `Bool true ] "applicable"
        ; "not-json"; response "applicable" ]) in
  let policy = { Runtime_schema.default_typesafeai with
      skill_applicability = true; lane_endpoint = server.base_url } in
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-skill-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy policy @@ fun () ->
  let captured = ref None in
  let call_number = ref 0 in
  let persist ~case ~success ~output =
    incr call_number;
    let call_id = Printf.sprintf "skill-jev-%d-%s" !call_number case in
    Keeper_tool_call_log.log_call ~keeper_name:"skill-fixture" ~tool_name:"keeper_skill"
      ~input:(Reference.to_yojson reference) ~output_text:output ~success ~duration_ms:0.
      ~execution_id:(Ids.Execution_id.of_string call_id)
      ~tool_use_id:call_id ()
  in
  let tool = Masc.Keeper_tool_composition_surface.make_instruction_skill_tool
      ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
      ~assess_applicability:(fun ~reference ~body ->
        Masc.Typesafeai_skill_applicability.assess ~clock ~keeper_id:"skill-fixture"
          ~context:(Some (`Assoc [ "request", `String "inspect the current task" ]))
          ~reference ~body ())
      ~on_result:(fun ~input:_ result -> captured := Some result)
      ~instruction_skills:[ instruction_skill reference selected.skill ] () in
  let invoke expected =
    let output = run_skill_tool tool (Reference.to_yojson reference) in
    check bool "model still receives the frozen Skill body" true
      (String_util.contains_substring output "FROZEN_SKILL_BODY");
    check bool "advice reaches actual Agent-Core content" true
      (String_util.contains_substring output expected);
    persist ~case:expected ~success:true ~output;
    let metadata = Tool_result.metadata (Option.get !captured) |> Option.get in
    let open Yojson.Safe.Util in
    check bool "model advice delivery is explicit" true
      (metadata |> member "applicability_advice_in_model_content" |> to_bool);
    output, metadata |> member "skill_applicability"
  in
  let judged_output, judged = invoke "not_applicable" in
  let open Yojson.Safe.Util in
  check string "negative advice is not a tool failure" "judged" (judged |> member "status" |> to_string);
  check string "returned model is retained" "fixture-jev" (judged |> member "model" |> to_string);
  check string "exact reference is retained" (Yojson.Safe.to_string (Reference.to_yojson reference))
    (judged |> member "reference" |> Yojson.Safe.to_string);
  check bool "model advice does not invite an invented confidence threshold" false
    (String_util.contains_substring judged_output "confidence");
  ignore (invoke "applicable");
  ignore (invoke "insufficient_context");
  let _, invalid = invoke "advice unavailable" in
  check string "bad choice remains explicit" "invalid_answer" (invalid |> member "status" |> to_string);
  let _, surplus = invoke "advice unavailable" in
  check string "a surplus answer violates the one-question response contract"
    "invalid_answer" (surplus |> member "status" |> to_string);
  check int "the invalid receipt retains both returned answers" 2
    (surplus |> member "returned_answers" |> to_assoc |> List.length);
  let _, failed = invoke "advice unavailable" in
  check string "service decode failure remains explicit" "failed" (failed |> member "status" |> to_string);
  let activation_failed_tool = Masc.Keeper_tool_composition_surface.make_instruction_skill_tool
      ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
      ~assess_applicability:(fun ~reference ~body ->
        Masc.Typesafeai_skill_applicability.assess ~clock ~keeper_id:"skill-fixture"
          ~context:(Some (`Assoc [ "request", `String "inspect the current task" ]))
          ~reference ~body ())
      ~record_activation:(fun ~invocation:_ ~content:_ _ ->
        Error Masc.Keeper_skill_activation_recorder.Turn_scope_mismatch)
      ~on_result:(fun ~input:_ result -> captured := Some result)
      ~instruction_skills:[ instruction_skill reference selected.skill ] () in
  let refused = run_skill_tool activation_failed_tool (Reference.to_yojson reference) in
  check bool "activation failure still withholds the Skill body" false
    (String_util.contains_substring refused "FROZEN_SKILL_BODY");
  check bool "received assessment also crosses the actual failed Agent-Core wire" true
    (String_util.contains_substring refused "fixture-jev");
  check bool "failed wire names advice withholding" true
    (String_util.contains_substring refused "withheld_activation_failure");
  persist ~case:"activation-failed" ~success:false ~output:refused;
  let result = Option.get !captured in
  check bool "a received JEV answer is not successful activation" false (Tool_result.is_success result);
  let metadata = Tool_result.metadata result |> Option.get in
  check string "received assessment survives activation failure" "judged"
    (metadata |> member "skill_applicability" |> member "status" |> to_string);
  check string "received model provenance survives activation failure" "fixture-jev"
    (metadata |> member "skill_applicability" |> member "model" |> to_string);
  check bool "activation failure does not claim advice delivery" false
    (metadata |> member "applicability_advice_in_model_content" |> to_bool);
  check string "failed delivery names its boundary" "withheld_activation_failure"
    (metadata |> member "applicability_projection" |> to_string);
  check bool "existing activation failure evidence remains" true
    (Tool_result.data result |> member "skill_activation_error" <> `Null);
  let sent = Exact_output_fixture.post_count server in
  let no_context_tool = Masc.Keeper_tool_composition_surface.make_instruction_skill_tool
      ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
      ~assess_applicability:(fun ~reference ~body ->
        Masc.Typesafeai_skill_applicability.assess ~clock ~keeper_id:"skill-fixture"
          ~context:None ~reference ~body ())
      ~on_result:(fun ~input:_ result -> captured := Some result)
      ~instruction_skills:[ instruction_skill reference selected.skill ] () in
  let unchanged_body = run_skill_tool no_context_tool (Reference.to_yojson reference) in
  check string "missing Context leaves the exact Skill body unchanged" frozen_body unchanged_body;
  check int "missing Context sends no request" sent (Exact_output_fixture.post_count server);
  let unavailable_metadata = Tool_result.metadata (Option.get !captured) |> Option.get in
  check string "missing Context remains observable" "unavailable"
    (unavailable_metadata |> member "skill_applicability" |> member "status" |> to_string);
  check string "missing Context reason remains explicit" "turn_context_unavailable"
    (unavailable_metadata |> member "skill_applicability" |> member "reason" |> to_string);
  check bool "no preflight judgment is presented to the model" false
    (unavailable_metadata |> member "applicability_advice_in_model_content" |> to_bool);
  ignore (run_skill_tool tool (`Assoc [ "name", `String "guide" ]));
  check int "unavailable reference does not call JEV" sent (Exact_output_fixture.post_count server);
  List.iter (fun policy ->
    Masc_test_deps.with_typesafeai_policy policy (fun () ->
      let output = run_skill_tool tool (Reference.to_yojson reference) in
      check bool "policy skip leaves body readable" true
        (String_util.contains_substring output "FROZEN_SKILL_BODY");
      check bool "policy skip does not invent a model judgment" false
        (String_util.contains_substring output "JEV applicability advice");
      check int "excluded or disabled review sends no request" sent (Exact_output_fixture.post_count server)))
    [ { policy with excluded_keepers = [ "skill-fixture" ] }
    ; { policy with skill_applicability = false } ];
  let sent_bodies = Atomic.get server.requests in
  List.iter (fun encoded ->
    let state = Yojson.Safe.from_string encoded |> member "state" in
    check string "request uses frozen content" frozen_body
      (state |> member "skill" |> member "body" |> to_string)) sent_bodies;
  let rows = match Keeper_tool_call_log.read_recent ~keeper_name:"skill-fixture" ~n:10 () with
    | Ok rows -> rows
    | Error (Keeper_tool_call_log.Index_unavailable detail) -> fail detail in
  check int "every actual projected result reached the durable log" 7 (List.length rows);
  List.iter (fun row ->
    let output = member "output" row |> Yojson.Safe.to_string in
    check bool "durable output retains applicability despite a long body" true
      (String_util.contains_substring output "applicability");
    Printf.printf "SKILL_APPLICABILITY_TOOL_CALL %s\n%!" (Yojson.Safe.to_string row)) rows;
  let near_body = String.make Common.max_tool_result_wire_bytes 'x' in
  let near_snapshot = snapshot fixture_config
      [ [ "guide", document ~name:"guide" ~description:"near limit" near_body ] ] in
  let near_reference = exact_reference near_snapshot ~source_id ~package_id:"guide" ~name:"guide" in
  let near_selected = resolve_one near_snapshot near_reference in
  let near_server = Exact_output_fixture.start_server ~sw ~net ~clock
      (Exact_output_fixture.Reply (response "applicable")) in
  Masc_test_deps.with_typesafeai_policy { policy with lane_endpoint = near_server.base_url }
    (fun () ->
      let near_tool = Masc.Keeper_tool_composition_surface.make_instruction_skill_tool
          ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
          ~assess_applicability:(fun ~reference ~body ->
            Masc.Typesafeai_skill_applicability.assess ~clock ~keeper_id:"skill-fixture"
              ~context:(Some (`Assoc [ "request", `String "inspect the current task" ]))
              ~reference ~body ())
          ~on_result:(fun ~input:_ result -> captured := Some result)
          ~instruction_skills:[ instruction_skill near_reference near_selected.skill ] () in
      let output = run_skill_tool near_tool (Reference.to_yojson near_reference) in
      check string "advice cannot displace a body at the existing inline boundary" near_body output;
      let metadata = Tool_result.metadata (Option.get !captured) |> Option.get in
      check string "non-delivery is explicit, not claimed as consumed advice" "omitted_inline_limit"
        (metadata |> member "applicability_projection" |> to_string);
      check bool "projection does not claim model receipt" false
        (metadata |> member "applicability_advice_in_model_content" |> to_bool));
  let blocked = Exact_output_fixture.start_server ~sw ~net ~clock
      ~on_request_before_reply:(fun () -> Eio.Fiber.await_cancel ())
      (Exact_output_fixture.Reply (response "applicable")) in
  Masc_test_deps.with_typesafeai_policy { policy with lane_endpoint = blocked.base_url } @@ fun () ->
  captured := None;
  let cancellation, resolve_cancellation = Eio.Promise.create () in
  let pending = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun context ->
      Eio.Promise.resolve resolve_cancellation context;
      run_skill_tool tool (Reference.to_yojson reference))) in
  let await failure promise = Exact_output_fixture.await_within_fixture_budget ~clock ~failure promise in
  let context = await "Skill review did not start" cancellation in
  await "Skill review did not reach JEV" blocked.first_request_arrived;
  Eio.Cancel.cancel context (Failure "fixture cancelled Skill applicability");
  (match await "cancelled Skill review did not return" pending with
   | Error (Eio.Cancel.Cancelled _) -> ()
   | Error error -> fail (Printexc.to_string error)
   | Ok _ -> fail "cancellation was converted to a successful Skill read");
  check bool "cancelled advice does not publish a successful tool result" true (Option.is_none !captured)
;;

let () =
  run
    "Keeper Task Skill frozen exact selection"
    [ ( "selection"
      , [ test_case "shadow exact ref selects shadow" `Quick
            test_shadow_reference_selects_shadow_not_effective_winner
        ; test_case "Keeper names filter global and Task Skills" `Quick
            test_keeper_name_selection_filters_global_and_task_exactly
        ; test_case "Keeper names filter prompt and activation Task views" `Quick
            test_keeper_name_selection_filters_prompt_and_activation_task_views
        ; test_case "denied node tool withholds Task composition from prompt" `Quick
            test_denied_node_tool_withholds_task_composition_from_prompt
        ; test_case "held shadow composition collision is exact" `Quick
            test_held_shadow_composition_wins_with_exact_collision_evidence
        ; test_case "malformed exact composition falls back" `Quick
            test_malformed_exact_composition_is_frozen_instruction
        ; test_case "shared exact ref retains all Task ids" `Quick
            test_shared_exact_reference_retains_every_task_id
        ; test_case "exact ref consumer rejects name fallback" `Quick
            test_exact_reference_consumer_rejects_name_fallback
        ; test_case "resolved body remains frozen" `Quick
            test_resolved_body_stays_frozen_after_new_snapshot
        ; test_case "resource read is exact and deferred" `Quick
            test_resource_is_read_only_when_exact_file_is_requested
        ; test_case "JEV advice reaches model without changing selection" `Quick
            test_jev_advice_reaches_the_model_without_selecting_or_authorizing
        ; test_case "revision mismatch remains typed" `Quick
            test_revision_mismatch_is_typed_before_tool_projection
        ] )
    ]
;;
