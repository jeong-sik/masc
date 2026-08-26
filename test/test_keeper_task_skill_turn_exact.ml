open Alcotest

module Reference = Skill_reference
module Snapshot = Skill_catalog_snapshot
module Selection = Masc.Keeper_task_skill_turn

let source_row ~id ~path =
  Printf.sprintf
    "[[skills.sources]]\nid = %S\nanchor = \"base-path\"\npath = %S\naccess = \"read-write\"\n"
    id
    path
;;

let config sources =
  let text =
    "[skills]\nactivation-lifetime = \"session\"\nprecedence = \"earlier-source-wins\"\n"
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

let document ?(disabled = false) ~name ~description body =
  Printf.sprintf
    "---\nname: %s\ndescription: %s\n%s---\n%s"
    name
    description
    (if disabled then "disable-model-invocation: true\n" else "")
    body
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

let run_skill_tool tool input =
  match tool.Agent_core.Tool.handler (Agent_core.Tool.Execution_env.create ()) input with
  | Ok output -> output.Agent_core.Llm_provider.Types.content
  | Error error -> error.Agent_core.Llm_provider.Types.message
;;

let test_disabled_explicit_reference_is_readable_without_global_discovery () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let snapshot =
    snapshot
      config
      [ [ ( "quiet"
          , document
              ~disabled:true
              ~name:"quiet"
              ~description:"explicit only"
              "QUIET_BODY" ) ] ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let reference = exact_reference snapshot ~source_id ~package_id:"quiet" ~name:"quiet" in
  let selected = resolve_one snapshot reference in
  check bool "global invocation remains disabled" false selected.skill.model_invocable;
  let global_catalog, diagnostics = Masc.Keeper_skill_catalog.of_snapshot snapshot in
  check int "no projection diagnostics" 0 (List.length diagnostics);
  check bool
    "disabled entry absent from global instruction discovery"
    false
    (List.exists
       (fun (skill : Masc.Keeper_skill_catalog.skill) ->
          match skill.reference with
          | Some candidate ->
            skill.model_invocable && Reference.equal reference candidate
          | None -> false)
       (Masc.Keeper_skill_catalog.skills global_catalog));
  let tool =
    Masc.Keeper_tool_composition_surface.For_testing.make_instruction_skill_tool
      ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
      ~instruction_skills:[ reference, selected.skill.description, selected.skill.body ]
      ()
  in
  let schema_tool =
    Masc.Keeper_tool_composition_surface.instruction_skill_schema_tool
      ~instruction_skills:[ reference, selected.skill.description, selected.skill.body ]
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
    (String_util.contains_substring exact_output "QUIET_BODY");
  let activation_attempts = ref 0 in
  let failing_tool =
    Masc.Keeper_tool_composition_surface.For_testing.make_instruction_skill_tool
      ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
      ~record_activation:(fun observed ->
        incr activation_attempts;
        ignore observed;
        Error Masc.Keeper_skill_activation_recorder.Turn_scope_mismatch)
      ~instruction_skills:
        [ reference, selected.skill.description, selected.skill.body ]
      ()
  in
  let failed_output =
    run_skill_tool failing_tool (Reference.to_yojson reference)
  in
  check int "activation attempted once" 1 !activation_attempts;
  check bool "body withheld when activation recording fails" false
    (String_util.contains_substring failed_output "QUIET_BODY");
  let legacy_output = run_skill_tool tool (`Assoc [ "name", `String "quiet" ]) in
  check bool "name fallback rejected" false
    (String_util.contains_substring legacy_output "QUIET_BODY")
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

let () =
  run
    "Keeper Task Skill frozen exact selection"
    [ ( "selection"
      , [ test_case "shadow exact ref selects shadow" `Quick
            test_shadow_reference_selects_shadow_not_effective_winner
        ; test_case "disabled explicit ref remains readable" `Quick
            test_disabled_explicit_reference_is_readable_without_global_discovery
        ; test_case "resolved body remains frozen" `Quick
            test_resolved_body_stays_frozen_after_new_snapshot
        ; test_case "revision mismatch remains typed" `Quick
            test_revision_mismatch_is_typed_before_tool_projection
        ] )
    ]
;;
