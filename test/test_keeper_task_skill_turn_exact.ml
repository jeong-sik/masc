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
  | Ok config ->
    (* The bound is derived now (task-1779 B); tests that exercise the
       oversize path set a smaller one through the test seam. *)
    Skill_source_config.For_testing.with_resource_read_max_bytes
      resource_read_max_bytes
      config
  | Error diagnostics ->
    fail
      (String.concat
         "; "
         (List.map Skill_source_config.diagnostic_to_string diagnostics))
;;

let config = config_with_resource_read_max_bytes 16384

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

(* An instruction body over the inline read boundary projects as
   [Entry_unavailable] (#39138). Turn setup fails the turn on any Task Skill
   resolution Error, so an Error here would stop every turn of a Keeper
   holding the Task, held Tasks included. The snapshot holds the Skill, so it
   is a known Skill that is unavailable: the selection resolves, the readable
   Skill stays selected, and the prompt row names the size refusal. *)
let test_oversized_task_skill_is_unavailable_not_a_failed_turn () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let oversized_body = String.make (Common.max_tool_result_wire_bytes + 1) 'x' in
  let skill_snapshot =
    snapshot
      config
      [ [ "guide", document ~name:"guide" ~description:"guide" "GUIDE"
        ; "huge", document ~name:"huge" ~description:"huge" oversized_body
        ]
      ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let guide_reference =
    exact_reference skill_snapshot ~source_id ~package_id:"guide" ~name:"guide"
  in
  let huge_reference =
    exact_reference skill_snapshot ~source_id ~package_id:"huge" ~name:"huge"
  in
  let held_task_skills =
    [ { Inputs.held_task_id = "task-held"
      ; held_skills = [ huge_reference; guide_reference ]
      }
    ]
  in
  let selection =
    match
      Selection.resolve_observations
        ~snapshot:skill_snapshot
        ~current_task:Inputs.No_current_task
        ~held_task_skills
    with
    | Ok selection -> selection
    | Error error ->
      failf
        "a pinned oversized Skill failed the turn's Task Skill resolution: %s"
        (Selection.error_to_string error)
  in
  check
    (list string)
    "the readable Task Skill stays selected"
    [ "guide" ]
    (List.map
       (fun (selected : Selection.selected) -> selected.skill.name)
       selection.Selection.selected);
  let reason =
    match selection.Selection.unprojectable with
    | [ { Selection.reference
        ; reason =
            (Selection.Catalog_entry_unprojectable
               (Masc.Keeper_skill_catalog.Body_too_large_to_read
                  { skill; bytes; max_bytes }) as reason)
        ; task_ids
        }
      ] ->
      check bool "the unavailable row is the pinned reference" true
        (Reference.equal reference huge_reference);
      check string "the size refusal names the Skill" "huge" skill;
      check int "the refusal carries the inline read boundary"
        Common.max_tool_result_wire_bytes max_bytes;
      check bool "the refused body is over that boundary" true (bytes > max_bytes);
      check (list string) "the row keeps the Task that pinned it" [ "task-held" ] task_ids;
      Selection.unavailable_reason_to_string reason
    | _ -> fail "the oversized Task Skill was not kept as one typed unavailable row"
  in
  let surfaces =
    match
      Selection.exact_task_surfaces
        ~snapshot:skill_snapshot
        ~tool_deny:[]
        ~sandbox_profile:Masc.Keeper_types_profile.Docker
        ~skill_names:None
        ~selection
        ~current_task:Inputs.No_current_task
        ~held_task_skills
    with
    | [ ("task-held", surfaces) ] -> surfaces
    | tasks -> failf "expected one held Task surface, got %d" (List.length tasks)
  in
  let surface_of reference =
    List.find_opt
      (fun (surface : Masc.Keeper_skill_catalog.exact_surface) ->
         Reference.equal surface.reference reference)
      surfaces
  in
  check int "the Task lists both pinned Skills and nothing else" 2 (List.length surfaces);
  (match surface_of guide_reference with
   | Some { availability = Masc.Keeper_skill_catalog.Instruction_tool; _ } -> ()
   | Some _ | None -> fail "the readable Task Skill is not offered through keeper_skill");
  match surface_of huge_reference with
  | Some { availability = Masc.Keeper_skill_catalog.Exact_unavailable { diagnostic }; _ } ->
    check string "the prompt row gives the size refusal as the reason" reason diagnostic
  | Some _ | None ->
    failf
      "the Task's prompt surface did not list the oversized Skill as unavailable: %s"
      (Yojson.Safe.to_string
         (`List (List.map Masc.Keeper_skill_catalog.exact_surface_to_yojson surfaces)))
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
  let merged = match Selection.resolve_observations ~snapshot:skill_snapshot
      ~current_task:Inputs.No_current_task ~held_task_skills:
        [{Inputs.held_task_id="task-a";held_skills=[reference;reference]};
         {Inputs.held_task_id="task-b";held_skills=[reference]}] with
    | Ok selection -> selection | Error error -> fail (Selection.error_to_string error) in
  check int "one exact selection" 1 (List.length merged.selected);
  check (list string) "all Task ids retained" [ "task-a"; "task-b" ]
    (one_selected merged).task_ids
;;

let test_task_binding_reuses_only_exact_frozen_inputs () =
  let skill_config = config (source_row ~id:"only" ~path:"skills") in
  let first = snapshot skill_config
      [["lane",composition_document ~name:"lane" ~node_id:"original"]] in
  let source_id = match skill_config.sources with
    | [source] -> source.id | _ -> fail "one original Skill source" in
  let reference = exact_reference first ~source_id ~package_id:"lane" ~name:"lane" in
  let held_task_skills =
    [{Inputs.held_task_id="task-a";held_skills=[reference]};
     {Inputs.held_task_id="task-b";held_skills=[reference]}] in
  let selection = match Selection.resolve_observations ~snapshot:first
      ~current_task:Inputs.No_current_task ~held_task_skills with
    | Ok selection -> selection | Error error -> fail (Selection.error_to_string error) in
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  let bind ~snapshot descriptors selection =
    match Selection.bind_surface ~snapshot ~descriptors selection with
    | Ok selection -> selection | Error error -> fail (Selection.error_to_string error) in
  let bound,prepared = bind ~snapshot:first descriptors selection in
  check int "the shared exact Skill remains one executable composition" 1
    (List.length (Selection.partition bound).compositions);
  let interleaved = snapshot skill_config
      [["other",document ~name:"other" ~description:"another workspace preparation" "OTHER"]] in
  ignore (Masc.Keeper_skill_catalog.of_snapshot ~descriptors interleaved);
  let reused,after_interleaving = bind ~snapshot:first (List.map Fun.id descriptors) bound in
  check bool "the prompt and execution keep one immutable binding without reprojecting" true (bound == reused);
  check bool "another preparation cannot evict the original turn's catalog and inventory" true
    (prepared == after_interleaving);
  check bool "the retained inventory still names the exact original Skill" true
    (List.exists (function
       | Masc.Keeper_skill_inventory.Valid valid -> Reference.equal reference valid.reference
       | Invalid _ -> false) (Masc.Keeper_skill_inventory.items after_interleaving.inventory));
  check (list string) "reuse keeps all exact Task provenance" ["task-a";"task-b"] (one_selected reused).task_ids;
  let surfaces = Selection.exact_task_surfaces ~snapshot:first ~tool_deny:[]
      ~sandbox_profile:Masc.Keeper_types_profile.Docker ~skill_names:None ~selection:reused
      ~current_task:Inputs.No_current_task ~held_task_skills in
  check (list string) "both original Task prompt surfaces survive reuse" ["task-a";"task-b"]
    (List.map fst surfaces);
  let independently_prepared = match Selection.resolve_for_task ~snapshot:first ~descriptors
      ~task_id:"task-c" [reference] with
    | Ok selection -> selection | Error error -> fail (Selection.error_to_string error) in
  let mixed_preparations = Selection.merge [bound;independently_prepared] in
  check bool "a later Task reuses the same owned source and actual Tool preparation" true
    (match independently_prepared.preparation with
     | Some next -> next == prepared
     | None -> false);
  check bool "merging Tasks with the same binding retains its shared preparation" true
    (match mixed_preparations.preparation with
     | Some next -> next == prepared
     | None -> false);
  let rebound_preparations,merged_preparation = bind ~snapshot:first descriptors mixed_preparations in
  check (list string) "reprojection keeps every original Task while unifying the preparation"
    ["task-a";"task-b";"task-c"] (one_selected rebound_preparations).task_ids;
  check bool "merged Task binding returns the original shared catalog and inventory" true
    (merged_preparation == prepared);
  let without_lane = List.filter (fun (descriptor : Masc.Keeper_tool_descriptor.t) ->
    not (List.mem "keeper_lane_status" (Masc.Keeper_tool_descriptor.keeper_model_names descriptor))) descriptors in
  check bool "the fixture really changes Tool authority" true (List.length without_lane < List.length descriptors);
  let changed_tools,changed_preparation = bind ~snapshot:first without_lane bound in
  check int "changed authority cannot retain the old executable composition" 0
    (List.length (Selection.partition changed_tools).compositions);
  check bool "changed Tool authority retains its actual projection diagnostic" true
    (Option.is_some (one_selected changed_tools).diagnostic);
  check int "paired preparation cannot advertise the composition withheld by new Tool authority" 0
    (List.length (Masc.Keeper_skill_catalog.composition_entries changed_preparation.catalog));
  let mixed_binding = Selection.merge [selection;changed_tools] in
  check bool "bound and unbound projections cannot share a reuse proof" true
    (Option.is_none mixed_binding.preparation);
  let rebound_mixed,_ = bind ~snapshot:first without_lane mixed_binding in
  check int "unbound selection cannot smuggle a missing Tool through merged authority" 0
    (List.length (Selection.partition rebound_mixed).compositions);
  let later = snapshot skill_config
      [["lane",composition_document ~name:"lane" ~node_id:"later"]] in
  let changed_source,_ = bind ~snapshot:later descriptors bound in
  check int "same Tool objects do not hide a changed frozen source" 0 (List.length changed_source.selected);
  check int "the original pin becomes explicitly unavailable against the new source" 1
    (List.length changed_source.unprojectable);
  let later_reference = exact_reference later ~source_id ~package_id:"lane" ~name:"lane" in
  let later_selection = match Selection.resolve_for_task ~snapshot:later ~task_id:"task-later" [later_reference] with
    | Ok selection -> selection | Error error -> fail (Selection.error_to_string error) in
  let later_preparation = Selection.prepare_surface ~snapshot:later ~descriptors later_selection in
  check bool "observing another frozen source derives another preparation" false
    (prepared == later_preparation);
  check bool "a new observation does not overwrite the original turn preparation" true
    (prepared == Selection.prepare_surface ~snapshot:first ~descriptors bound);
  let original_again = match Selection.resolve_for_task ~snapshot:first ~descriptors
      ~task_id:"task-original-again" [reference] with
    | Ok selection -> selection | Error error -> fail (Selection.error_to_string error) in
  let refused_again,_ = bind ~snapshot:later descriptors original_again in
  let mixed = Selection.merge
      [bound; later_selection; original_again; bound;
       changed_source; refused_again; changed_source] in
  let check_owners label expected actual =
    check (list string) label (List.sort String.compare expected) (List.sort String.compare actual) in
  let original_owners = ["task-a"; "task-b"; "task-original-again"] in
  check int "different frozen revisions of one Skill stay distinct" 2 (List.length mixed.selected);
  check_owners "all original owners stay on their original pinned revision" original_owners
    (Selection.task_ids_for_reference mixed reference);
  check_owners "the later Task owns only its later pin" ["task-later"]
    (Selection.task_ids_for_reference mixed later_reference);
  (match List.find_opt (fun (row : Selection.selected) -> Reference.equal row.reference reference)
           mixed.selected with
   | Some original ->
     check bool "duplicate selection retains the first frozen Skill object" true
       (original.skill == (one_selected bound).skill)
   | None -> fail "the original pinned Skill disappeared while combining Task owners");
  (match mixed.unprojectable with
   | [row] ->
     check bool "selected and refused evidence keep their own original pin" true
       (Reference.equal row.reference reference);
     check_owners "repeated refusals retain all exact original Task owners" original_owners row.task_ids
   | rows -> failf "expected one original refusal, got %d" (List.length rows));
  check bool "mixed source selections have no single reusable projection input" true
    (Option.is_none mixed.preparation);
  let restored,restored_preparation = bind ~snapshot:first descriptors mixed in
  check int "mixed sources reproject instead of borrowing the first binding" 1 (List.length restored.selected);
  check int "the later revision cannot be offered from the original snapshot" 1 (List.length restored.unprojectable);
  check_owners "source repair does not drop owners from previously refused evidence" original_owners
    (Selection.task_ids_for_reference restored reference);
  (match restored.unprojectable with
   | [row] ->
     check bool "source repair cannot retarget the later Task to the original revision" true
       (Reference.equal row.reference later_reference);
     check_owners "only the later Task retains the later-pin refusal" ["task-later"] row.task_ids
   | rows -> failf "expected one later-pin refusal after repair, got %d" (List.length rows));
  check bool "restored exact pins share the original preparation without borrowing the later source" true
    (restored_preparation == prepared);
  let unreadable = Snapshot.config_unreadable ~detail:"source unavailable after the original selection" in
  check bool "matching Tool authority cannot hide an unreadable replacement snapshot" true
    (match Selection.bind_surface ~snapshot:unreadable ~descriptors bound with
     | Error (Selection.Skill_config_unreadable _) -> true
     | Error _ | Ok _ -> false);
  check bool "a different Task without pins can still bind the unreadable observation without stale Skills" true
    (match Selection.bind_surface ~snapshot:unreadable ~descriptors Selection.empty with
     | Ok (unrelated,preparation) -> unrelated.selected=[] && unrelated.unprojectable=[]
         && Masc.Keeper_skill_catalog.prepared_snapshot preparation.projection==unreadable
         && Masc.Keeper_skill_catalog.composition_entries preparation.catalog=[]
     | Error _ -> false)
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

(* A Task pins a Skill by exact content revision. Editing or deleting that
   Skill afterwards must not stop the turn: the pin is a known Skill that is
   unavailable this turn, shown as such, while the Task's other Skills and the
   Keeper's other Tasks keep working. *)
let stale_revision =
  match Reference.content_revision_of_string (String.make 64 'f') with
  | Ok revision -> revision
  | Error _ -> fail "stale revision fixture is invalid"
;;

let two_skill_snapshot () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let snapshot =
    snapshot
      config
      [ [ "guide", document ~name:"guide" ~description:"guide" "BODY"
        ; "other", document ~name:"other" ~description:"other" "OTHER"
        ]
      ]
  in
  let source_id =
    match config.sources with
    | [ source ] -> source.id
    | _ -> fail "expected one source"
  in
  let reference name =
    exact_reference snapshot ~source_id ~package_id:name ~name
  in
  snapshot, reference "guide", reference "other"
;;

let resolve_ok ~snapshot ~task_id references =
  match Selection.resolve_for_task ~snapshot ~task_id references with
  | Ok selection -> selection
  | Error error ->
    failf "a stale pin failed the turn's Task Skill resolution: %s"
      (Selection.error_to_string error)
;;

let test_stale_revision_pin_does_not_stop_resolution () =
  let snapshot, guide, other = two_skill_snapshot () in
  let stale = Reference.make ~identity:guide.identity ~content_revision:stale_revision in
  let selection = resolve_ok ~snapshot ~task_id:"task-1" [ stale; other ] in
  check (list string) "the other pinned Skill stays selected" [ "other" ]
    (List.map (fun (s : Selection.selected) -> s.skill.name) selection.Selection.selected);
  match selection.Selection.unprojectable with
  | [ row ] ->
    check bool "the unavailable row is the stale pin" true
      (Reference.equal row.Selection.reference stale);
    check (list string) "the row keeps the Task that pinned it" [ "task-1" ]
      row.Selection.task_ids;
    (match row.Selection.reason with
     | Selection.Pin_unresolved
         (Snapshot.Content_revision_mismatch { requested; observed; _ }) ->
       check bool "the row names the pinned revision" true
         (Reference.equal_content_revision requested stale_revision);
       check bool "the row names the current revision" true
         (Reference.equal_content_revision observed guide.content_revision)
     | Selection.Pin_unresolved (Snapshot.Identity_not_found _)
     | Selection.Catalog_entry_unprojectable _ ->
       fail "a stale revision pin was not a content revision mismatch");
    check string "the wire code names the mismatch"
      "task_skill_content_revision_mismatch"
      (Selection.unavailable_reason_code row.Selection.reason)
  | rows -> failf "expected one unavailable row, got %d" (List.length rows)
;;

let test_current_pin_still_projects () =
  let snapshot, guide, _ = two_skill_snapshot () in
  let selection = resolve_ok ~snapshot ~task_id:"task-1" [ guide ] in
  check int "no unavailable row for a current pin" 0
    (List.length selection.Selection.unprojectable);
  check int "the current pin is selected" 1
    (List.length selection.Selection.selected)
;;

let test_stale_pin_is_listed_unavailable_on_the_prompt_surface () =
  let snapshot, guide, other = two_skill_snapshot () in
  let stale = Reference.make ~identity:guide.identity ~content_revision:stale_revision in
  let held_task_skills =
    [ { Inputs.held_task_id = "task-held"; held_skills = [ stale; other ] }
    ; { Inputs.held_task_id = "task-shared"; held_skills = [ other; stale ] }
    ; { Inputs.held_task_id = "task-empty"; held_skills = [] }
    ; { Inputs.held_task_id = "task-held"; held_skills = [] }
    ]
  in
  let selection =
    match
      Selection.resolve_observations
        ~snapshot
        ~current_task:Inputs.No_current_task
        ~held_task_skills
    with
    | Ok selection -> selection
    | Error error ->
      failf "a stale pin failed the turn's Task Skill resolution: %s"
        (Selection.error_to_string error)
  in
  (* The frozen selection may outlive a different Task observation. Its extra
     owner must not create a prompt Task, while shared pins retain every
     actual owner and a late Task cannot borrow another Task's exact pin. *)
  let selection = Selection.merge
      [selection; resolve_ok ~snapshot ~task_id:"task-outside" [guide]] in
  let project ~skill_names held_task_skills =
    Selection.exact_task_surfaces
        ~snapshot
        ~tool_deny:[]
        ~sandbox_profile:Masc.Keeper_types_profile.Docker
        ~skill_names
        ~selection
        ~current_task:Inputs.No_current_task
        ~held_task_skills
  in
  let tasks = project ~skill_names:None held_task_skills in
  check int "repeated observations do not duplicate a Task owner" 3 (List.length tasks);
  check bool "a frozen owner absent from observation cannot add a prompt Task" true
    (Option.is_none (List.assoc_opt "task-outside" tasks));
  let surfaces_for tasks task_id =
    match List.assoc_opt task_id tasks with
    | Some surfaces -> surfaces
    | None -> failf "missing original Task %s" task_id
  in
  check int "an observed Task without pins cannot borrow a shared pin" 0
    (List.length (surfaces_for tasks "task-empty"));
  let availability_of surfaces reference =
    List.find_map
      (fun (surface : Masc.Keeper_skill_catalog.exact_surface) ->
         if Reference.equal surface.reference reference
         then Some surface.availability
         else None)
      surfaces
  in
  let check_shared_owner tasks task_id ~withheld =
    let surfaces = surfaces_for tasks task_id in
    check int "one exact pin and one stale pin belong to each original Task" 2
      (List.length surfaces);
    check bool "a different Task's readable pin is not inherited" true
      (Option.is_none (availability_of surfaces guide));
    (match availability_of surfaces other, withheld with
     | Some Masc.Keeper_skill_catalog.Instruction_tool, false
     | Some (Masc.Keeper_skill_catalog.Exact_unavailable _), true -> ()
     | (Some _ | None), _ -> fail "shared pin ignored its executable turn policy");
    match availability_of surfaces stale with
    | Some (Masc.Keeper_skill_catalog.Exact_unavailable _) -> ()
    | Some _ | None -> fail "an original Task lost its stale-pin refusal"
  in
  List.iter (fun task_id -> check_shared_owner tasks task_id ~withheld:false)
    ["task-held"; "task-shared"];
  let withheld = project ~skill_names:(Some []) held_task_skills in
  List.iter (fun task_id -> check_shared_owner withheld task_id ~withheld:true)
    ["task-held"; "task-shared"];
  let later = project ~skill_names:None
      [{Inputs.held_task_id="task-later"; held_skills=[other]}] in
  check int "a later observation keeps only its own Task" 1 (List.length later);
  check int "a late Task reference is not resolved by the frozen surface projection" 0
    (List.length (surfaces_for later "task-later"))
;;

let test_deleted_skill_pin_does_not_stop_resolution () =
  let _, guide, other = two_skill_snapshot () in
  let config = config (source_row ~id:"only" ~path:"skills") in
  let after_delete =
    snapshot config [ [ "other", document ~name:"other" ~description:"other" "OTHER" ] ]
  in
  let selection = resolve_ok ~snapshot:after_delete ~task_id:"task-1" [ guide; other ] in
  check int "the surviving Skill stays selected" 1
    (List.length selection.Selection.selected);
  match selection.Selection.unprojectable with
  | [ { Selection.reason = Selection.Pin_unresolved (Snapshot.Identity_not_found _); _ } ] ->
    ()
  | _ -> fail "the deleted Skill is not one identity-not-found row"
;;

(* The same pin under a snapshot whose configuration is unreadable or
   rejected is not a stale pin: that snapshot has no entries, so the pin would
   read as deleted. Resolution fails, unlike the stale-revision case above. *)
let test_unusable_skill_config_stops_resolution_unlike_a_stale_pin () =
  let _, guide, _ = two_skill_snapshot () in
  let expect_error ~label ~snapshot check_error =
    match Selection.resolve_for_task ~snapshot ~task_id:"task-1" [ guide ] with
    | Error error -> check_error error
    | Ok selection ->
      failf "%s: resolution kept going with %d unavailable row(s)" label
        (List.length selection.Selection.unprojectable)
  in
  expect_error
    ~label:"unreadable"
    ~snapshot:(Snapshot.config_unreadable ~detail:"disk gone")
    (function
      | Selection.Skill_config_unreadable { detail } ->
        check string "the unreadable detail is carried" "disk gone" detail
      | Selection.Skill_config_rejected _
      | Selection.Tool_surface_unavailable _
      | Selection.Skill_source_unreadable _
      | Selection.Skill_entry_unreadable _ ->
        fail "unreadable configuration was not the unreadable error");
  expect_error
    ~label:"rejected"
    ~snapshot:(Snapshot.config_rejected ~source_text:"not toml" ~diagnostics:[])
    (function
      | Selection.Skill_config_rejected _ -> ()
      | Selection.Skill_config_unreadable _
      | Selection.Tool_surface_unavailable _
      | Selection.Skill_source_unreadable _
      | Selection.Skill_entry_unreadable _ ->
        fail "rejected configuration was not the rejected error");
  (match
     Selection.resolve_for_task
       ~snapshot:(Snapshot.config_unreadable ~detail:"disk gone")
       ~task_id:"task-1"
       []
   with
   | Ok selection ->
     check int "no pin, nothing to misreport" 0
       (List.length selection.Selection.unprojectable)
   | Error error ->
     failf "a Task with no pin failed on an unreadable configuration: %s"
       (Selection.error_to_string error))
;;

(* A configured snapshot whose scan of the pinned Skill's source failed holds
   no entry for the pin, but the Skill may still exist there: resolving it as
   deleted would run the turn without its procedure. *)
let test_unreadable_source_stops_resolution_unlike_a_stale_pin () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let source =
    match config.sources with
    | [ source ] -> source
    | _ -> fail "expected one source"
  in
  let resolved = Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source in
  let snapshot =
    match
      Snapshot.configured ~config
        [ { Snapshot.source = resolved
          ; observation =
              Snapshot.Source_unavailable
                { resolved_path = "/workspace/skills"
                ; operation = Snapshot.Read_source_directory
                ; detail = "fixture"
                }
          ; candidates = []
          }
        ]
    with
    | Ok snapshot -> snapshot
    | Error _ -> fail "fixture snapshot was rejected"
  in
  let identity =
    Reference.make_identity ~source_id:source.id ~package_id:(package "guide") ~name:"guide"
  in
  let reference = Reference.make ~identity ~content_revision:stale_revision in
  (match Selection.resolve_for_task ~snapshot ~task_id:"task-1" [ reference ] with
   | Ok selection ->
     failf "resolution kept going with %d unavailable row(s)"
       (List.length selection.Selection.unprojectable)
   | Error error ->
     (match error with
      | Selection.Skill_source_unreadable { source_id; observation = _ } ->
        check string "the unreadable source is named" "only" source_id;
        check string "the wire code names the unreadable source"
          "task_skill_source_unreadable" (Selection.error_code error)
      | Selection.Skill_config_rejected _
      | Selection.Skill_config_unreadable _
      | Selection.Tool_surface_unavailable _
      | Selection.Skill_entry_unreadable _ ->
        fail "an unreadable source was not the source-unreadable error"))
;;

(* The source scanned, but the pinned package's document could not be read:
   same unknown, same typed failure, naming the pin rather than the source. *)
let test_unreadable_candidate_stops_resolution_unlike_a_stale_pin () =
  let config = config (source_row ~id:"only" ~path:"skills") in
  let source =
    match config.sources with
    | [ source ] -> source
    | _ -> fail "expected one source"
  in
  let resolved = Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source in
  let resolved_path =
    match resolved.resolution with
    | Skill_source_config.Resolved path -> path
    | _ -> fail "fixture source did not resolve"
  in
  let snapshot =
    match
      Snapshot.configured ~config
        [ { Snapshot.source = resolved
          ; observation = Snapshot.Source_ready { resolved_path; candidates = 1 }
          ; candidates =
              [ Snapshot.Candidate_unreadable
                  { directory = "guide"; path = "guide/SKILL.md"; detail = "fixture" }
              ]
          }
        ]
    with
    | Ok snapshot -> snapshot
    | Error _ -> fail "fixture snapshot was rejected"
  in
  let identity =
    Reference.make_identity ~source_id:source.id ~package_id:(package "guide") ~name:"guide"
  in
  let reference = Reference.make ~identity ~content_revision:stale_revision in
  (match Selection.resolve_for_task ~snapshot ~task_id:"task-1" [ reference ] with
   | Ok selection ->
     failf "resolution kept going with %d unavailable row(s)"
       (List.length selection.Selection.unprojectable)
   | Error error ->
     (match error with
      | Selection.Skill_entry_unreadable { reference = failed; path; detail } ->
        check bool "the unreadable pin is named" true (Reference.equal failed reference);
        check string "the unreadable path is carried" "guide/SKILL.md" path;
        check string "the unreadable detail is carried" "fixture" detail;
        check string "the wire code names the unreadable entry"
          "task_skill_entry_unreadable" (Selection.error_code error)
      | Selection.Skill_config_rejected _
      | Selection.Skill_config_unreadable _
      | Selection.Tool_surface_unavailable _
      | Selection.Skill_source_unreadable _ ->
        fail "an unreadable candidate was not the entry-unreadable error"))
;;

(* A source unconfigured after the Task pinned it has no scan in the snapshot:
   nothing can still hold the Skill, so the pin reads as deleted. *)
let test_pin_into_unconfigured_source_reads_as_deleted () =
  let snapshot, _, _ = two_skill_snapshot () in
  let elsewhere =
    match Skill_source_config.source_id_of_string "elsewhere" with
    | Ok id -> id
    | Error detail -> fail detail
  in
  let identity =
    Reference.make_identity ~source_id:elsewhere ~package_id:(package "guide") ~name:"guide"
  in
  let reference = Reference.make ~identity ~content_revision:stale_revision in
  let selection = resolve_ok ~snapshot ~task_id:"task-1" [ reference ] in
  (match selection.Selection.unprojectable with
   | [ { Selection.reason = Selection.Pin_unresolved (Snapshot.Identity_not_found _); _ } ] -> ()
   | _ -> fail "a pin into an unconfigured source is not one identity-not-found row")
;;

let test_jev_advice_reaches_the_model_without_selecting_or_authorizing () =
  let open Masc in
  let prompts_root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat prompts_root "config/prompts");
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let prompt_overrides =
    [Prompt_names.skill_applicability, "managed-applicability-policy-fixture"
    ;Prompt_names.skill_applicability_advice, "managed-applicability-advice {{decision}}"
    ;Prompt_names.skill_applicability_projection, "{{advice}}\n\nmanaged-skill-body"] in
  let install_overrides () = List.iter (fun (key, body) ->
    match Prompt_registry.set_override key body with Ok () -> () | Error detail -> fail detail) prompt_overrides in
  install_overrides ();
  Eio.Switch.on_release sw (fun () -> List.iter (fun (key, _) -> Prompt_registry.clear_prompt_override key) prompt_overrides);
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
        ; response ~extra_answers:[ "surplus", `Assoc [ "type", `String "noul"; "noul", `Float 1.0 ] ] "applicable"
        ; "not-json"; response "applicable" ]) in
  let policy = { Runtime_schema.default_typesafeai with
      skill_applicability = true;
      destinations = ({ Runtime_schema.typesafe_destination with endpoint = server.base_url }, []) } in
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-skill-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy policy @@ fun () ->
  let captured = ref None in
  let call_number = ref 0 in
  let persist ~case ~wire_outcome ~output =
    incr call_number;
    let call_id = Printf.sprintf "skill-jev-%d-%s" !call_number case in
    Keeper_tool_call_log.log_call ~keeper_name:"skill-fixture" ~tool_name:"keeper_skill"
      ~input:(Reference.to_yojson reference) ~output_text:output ~wire_outcome ~duration_ms:0.
      ~execution_id:(Ids.Execution_id.of_string call_id)
      ~tool_use_id:call_id ()
  in
  let received_assessment = ref None in
  let tool = Masc.Keeper_tool_composition_surface.make_instruction_skill_tool
      ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
      ~assess_applicability:(fun ~reference ~body ->
        let assessment = Masc.Typesafeai_skill_applicability.assess ~clock ~keeper_id:"skill-fixture"
          ~context:(Some (`Assoc [ "request", `String "inspect the current task" ]))
          ~reference ~body () in
        received_assessment := Some assessment; assessment)
      ~on_result:(fun ~input:_ result -> captured := Some result)
      ~instruction_skills:[ instruction_skill reference selected.skill ] () in
  let invoke expected =
    let output = run_skill_tool tool (Reference.to_yojson reference) in
    check bool "model still receives the frozen Skill body" true
      (String_util.contains_substring output "FROZEN_SKILL_BODY");
    check bool "advice reaches actual Agent-Core content" true
      (String_util.contains_substring output expected);
    persist ~case:expected ~wire_outcome:Tool_result.Ok ~output;
    let metadata = Tool_result.metadata (Option.get !captured) |> Option.get in
    let open Yojson.Safe.Util in
    check bool "model advice delivery is explicit" true
      (metadata |> member "applicability_advice_in_model_content" |> to_bool);
    output, metadata |> member "skill_applicability"
  in
  let judged_output, judged = invoke "not_applicable" in
  check bool "managed advice reaches actual Agent-Core content" true
    (String_util.contains_substring judged_output "managed-applicability-advice");
  check bool "managed projection reaches actual Agent-Core content" true
    (String_util.contains_substring judged_output "managed-skill-body");
  let open Yojson.Safe.Util in
  check string "negative advice is not a tool failure" "judged" (judged |> member "status" |> to_string);
  check string "returned model is retained" "fixture-jev" (judged |> member "model" |> to_string);
  check string "exact reference is retained" (Yojson.Safe.to_string (Reference.to_yojson reference))
    (judged |> member "reference" |> Yojson.Safe.to_string);
  check bool "model advice does not invite an invented confidence threshold" false
    (String_util.contains_substring judged_output "confidence");
  let retained_assessment = Option.get !received_assessment in
  let activation_config = Workspace.default_config log_root in
  let activation_trace = Keeper_id.Trace_id.of_string "skill-body-projection" |> Result.get_ok in
  Fs_compat.mkdir_p (Keeper_fs.keeper_session_dir activation_config (Keeper_id.Trace_id.to_string activation_trace));
  let recorder = Keeper_skill_activation_recorder.make ~trace_id:activation_trace
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string activation_trace) ~absolute_turn:0)
      ~runtime_id:(fun () -> Some "fixture-runtime")
      ~snapshot_revision:(Snapshot.snapshot_revision captured_snapshot) ~task_selection:Selection.empty
      |> Result.get_ok in
  let projection_tool = Keeper_tool_composition_surface.make_instruction_skill_tool
      ~config:activation_config
      ~assess_applicability:(fun ~reference:_ ~body:_ -> retained_assessment)
      ~record_activation:(fun ~invocation ~content reference ->
        (match content with Keeper_skill_activation_recorder.Body body ->
          check string "activation records the exact original body" frozen_body body
         | Keeper_skill_activation_recorder.Resource _ -> fail "expected the original Skill body");
        Keeper_skill_activation_recorder.record_instruction ~config:activation_config recorder ~invocation ~content reference)
      ~on_result:(fun ~input:_ result -> captured := Some result)
      ~instruction_skills:[instruction_skill reference selected.skill] () in
  Fun.protect ~finally:install_overrides (fun () ->
    Prompt_registry.set_override Prompt_names.skill_applicability_projection "{{advice}}" |> Result.get_ok;
    let output = run_skill_tool projection_tool (Reference.to_yojson reference) in
    check bool "an advice-only override still returns the complete frozen body" true
      (String.ends_with ~suffix:frozen_body output);
    let actual_body = String.sub output (String.length output - String.length frozen_body) (String.length frozen_body) in
    check bool "the structural body projection is a successful Skill read" true
      (Tool_result.is_success (Option.get !captured));
    let metadata = Tool_result.metadata (Option.get !captured) |> Option.get in
    check int "metadata describes the actual returned body bytes" (String.length actual_body)
      (metadata |> member "bytes" |> to_int);
    let actual_sha = Agent_core_sha256.(digest_string actual_body |> to_hex) in
    check string "metadata describes the actual returned body digest" actual_sha
      (metadata |> member "sha256" |> to_string);
    let ledger = Keeper_skill_activation_ledger.load ~config:activation_config ~trace_id:activation_trace |> Result.get_ok in
    match Keeper_skill_activation_ledger.activations ledger with
    | [{Keeper_skill_activation_ledger.invocation=Keeper_skill_activation_ledger.Instruction_invocation
          {served_content=Keeper_skill_activation_ledger.Skill_body {bytes;sha256};_};_}] ->
      check int "durable activation records the returned body bytes" (String.length actual_body) bytes;
      check string "durable activation records the returned body digest" actual_sha sha256
    | _ -> fail "expected one exact body activation");
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
  persist ~case:"activation-failed" ~wire_outcome:Tool_result.Error ~output:refused;
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
    let json = Yojson.Safe.from_string encoded in
    check string "managed applicability question reaches the actual request"
      (Prompt_registry.render_prompt_template Prompt_names.skill_applicability [] |> Result.get_ok)
      (json |> member "questions" |> member "applicability" |> member "instructions" |> to_string);
    List.iter (fun (label, key) ->
      check string "managed applicability meaning reaches the exact criterion"
        (Prompt_registry.render_prompt_template key [] |> Result.get_ok)
        (json |> member "questions" |> member "applicability" |> member "criteria" |> member label |> to_string))
      ["applicable", Prompt_names.skill_applicability_applicable;
       "not_applicable", Prompt_names.skill_applicability_not_applicable;
       "insufficient_context", Prompt_names.skill_applicability_insufficient_context];
    let state = member "state" json in
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
  Masc_test_deps.with_typesafeai_policy { policy with
      destinations = ({ Runtime_schema.typesafe_destination with endpoint = near_server.base_url }, []) }
    (fun () ->
      let received_assessment = ref None in
      let near_tool = Masc.Keeper_tool_composition_surface.make_instruction_skill_tool
          ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
          ~assess_applicability:(fun ~reference ~body ->
            let assessment = Masc.Typesafeai_skill_applicability.assess ~clock ~keeper_id:"skill-fixture"
              ~context:(Some (`Assoc [ "request", `String "inspect the current task" ]))
              ~reference ~body () in
            received_assessment := Some assessment; assessment)
          ~on_result:(fun ~input:_ result -> captured := Some result)
          ~instruction_skills:[ instruction_skill near_reference near_selected.skill ] () in
      let output = run_skill_tool near_tool (Reference.to_yojson near_reference) in
      check string "advice cannot displace a body at the existing inline boundary" near_body output;
      let metadata = Tool_result.metadata (Option.get !captured) |> Option.get in
      check string "non-delivery is explicit, not claimed as consumed advice" "omitted_inline_limit"
        (metadata |> member "applicability_projection" |> to_string);
      check bool "projection does not claim model receipt" false
        (metadata |> member "applicability_advice_in_model_content" |> to_bool);
      let empty_prompts = Filename.concat log_root "empty-prompts" in
      Fs_compat.mkdir_p empty_prompts;
      Fun.protect ~finally:(fun () ->
        Prompt_registry.clear (); Prompt_registry.set_markdown_dir (Filename.concat prompts_root "config/prompts");
        install_overrides ()) (fun () ->
        let retained_assessment = Option.get !received_assessment in
        Prompt_registry.clear (); Prompt_registry.set_markdown_dir empty_prompts;
        let cached_tool = Masc.Keeper_tool_composition_surface.make_instruction_skill_tool
          ~config:(Masc.Workspace.default_config (Sys.getcwd ()))
          ~assess_applicability:(fun ~reference:_ ~body:_ -> retained_assessment)
          ~on_result:(fun ~input:_ result -> captured := Some result)
          ~instruction_skills:[ instruction_skill near_reference near_selected.skill ] () in
        let output = run_skill_tool cached_tool (Reference.to_yojson near_reference) in
        check string "missing advice policy leaves the frozen body unchanged" near_body output;
        let metadata = Tool_result.metadata (Option.get !captured) |> Option.get in
        check string "projection render failure remains explicit" "unavailable"
          (metadata |> member "applicability_projection" |> to_string);
        check bool "projection failure retains a render reason" true
          (metadata |> member "applicability_projection_error" <> `Null);
        let sent = Exact_output_fixture.post_count near_server in
        ignore (run_skill_tool near_tool (Reference.to_yojson near_reference));
        check int "missing question policy makes no model request" sent (Exact_output_fixture.post_count near_server);
        let metadata = Tool_result.metadata (Option.get !captured) |> Option.get in
        check string "missing question is observed as unavailable" "unavailable"
          (metadata |> member "skill_applicability" |> member "status" |> to_string)));

  let blocked = Exact_output_fixture.start_server ~sw ~net ~clock
      ~on_request_before_reply:(fun () -> Eio.Fiber.await_cancel ())
      (Exact_output_fixture.Reply (response "applicable")) in
  Masc_test_deps.with_typesafeai_policy { policy with
      destinations = ({ Runtime_schema.typesafe_destination with endpoint = blocked.base_url }, []) } @@ fun () ->
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

let preparation_for_cache_scenario ~snapshot ~descriptors =
  match Selection.resolve_surface ~descriptors ~snapshot [] with
  | Error error -> fail (Selection.error_to_string error)
  | Ok (_, preparation) -> preparation
;;

let cache_scenario_snapshot name =
  snapshot (config (source_row ~id:"only" ~path:"skills"))
    [[name, document ~name ~description:"owned preparation" "BODY"]]
;;

let test_interleaved_preparation_keeps_each_exact_tool_binding () =
  let frozen = cache_scenario_snapshot "interleaved" in
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  let original = preparation_for_cache_scenario ~snapshot:frozen ~descriptors in
  let first, rest = match descriptors with
    | first :: rest -> first, rest
    | [] -> fail "the canonical Tool fixture is empty" in
  let replacement = { first with description = first.description ^ " replacement object" } in
  let replaced = preparation_for_cache_scenario ~snapshot:frozen ~descriptors:(replacement :: rest) in
  check bool "equal Tool names and ids do not reuse a replaced authority object" false
    (original == replaced);
  let reordered = preparation_for_cache_scenario ~snapshot:frozen ~descriptors:(List.rev descriptors) in
  check bool "descriptor ordering is part of the frozen binding" false (original == reordered);
  let other = cache_scenario_snapshot "other" in
  ignore (preparation_for_cache_scenario ~snapshot:other ~descriptors);
  Gc.full_major ();
  let restored = preparation_for_cache_scenario ~snapshot:frozen ~descriptors:(List.map Fun.id descriptors) in
  check bool "a fresh list of the same owned Tools reuses the original full preparation" true
    (restored == original);
  check bool "the inventory and catalog share that exact preparation" true
    (restored.inventory == original.inventory && restored.catalog == original.catalog);
  check bool "the replacement binding survives independent interleaving too" true
    (replaced == preparation_for_cache_scenario ~snapshot:frozen ~descriptors:(replacement :: rest))
;;

let test_simultaneous_cold_preparation_is_shared () =
  let frozen = cache_scenario_snapshot "parallel-cold" in
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  let ready = Semaphore.Counting.make 0 and start = Semaphore.Counting.make 0 in
  let prepare () =
    Semaphore.Counting.release ready;
    Semaphore.Counting.acquire start;
    preparation_for_cache_scenario ~snapshot:frozen ~descriptors in
  let left = Domain.spawn prepare and right = Domain.spawn prepare in
  Semaphore.Counting.acquire ready;
  Semaphore.Counting.acquire ready;
  Semaphore.Counting.release start;
  Semaphore.Counting.release start;
  let left = Domain.join left and right = Domain.join right in
  check bool "both callers receive one complete immutable product" true (left == right);
  check bool "the shared inventory belongs to the original frozen source" true
    (Snapshot.snapshot_revision frozen = Masc.Keeper_skill_inventory.snapshot_revision left.inventory)
;;

let[@inline never] unowned_preparation_snapshot () =
  let frozen = cache_scenario_snapshot "unowned-source" in
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  let preparation = preparation_for_cache_scenario ~snapshot:frozen ~descriptors in
  let source = Weak.create 1 and product = Weak.create 1 in
  Weak.set source 0 (Some frozen);
  Weak.set product 0 (Some preparation);
  source, product
;;

let[@inline never] unowned_preparation_descriptor frozen =
  let canonical = match Masc.Keeper_tool_descriptor.all_descriptors () with
    | first :: _ -> first
    | [] -> fail "the canonical Tool fixture is empty" in
  let descriptor = { canonical with description = canonical.description ^ " unowned object" } in
  let preparation = preparation_for_cache_scenario ~snapshot:frozen ~descriptors:[descriptor] in
  let authority = Weak.create 1 and product = Weak.create 1 in
  Weak.set authority 0 (Some descriptor);
  Weak.set product 0 (Some preparation);
  authority, product
;;

let test_preparation_cache_does_not_own_retired_inputs () =
  let source, source_product = unowned_preparation_snapshot () in
  let active_source = cache_scenario_snapshot "active-source" in
  let descriptor, descriptor_product = unowned_preparation_descriptor active_source in
  Gc.full_major ();
  check bool "canonical Tools do not keep an unowned source alive" false (Weak.check source 0);
  check bool "the derived product does not retain its own dead source key" false (Weak.check source_product 0);
  check bool "an owned source does not keep an unowned Tool object alive" false (Weak.check descriptor 0);
  check bool "the derived product does not retain its own dead Tool key" false (Weak.check descriptor_product 0);
  check int "the independently owned source remains usable" 1 (List.length (Snapshot.entries active_source))
;;

let test_preparation_observes_actual_cold_and_reused_products () =
  Eio_main.run @@ fun _ ->
  let module O = Masc.Keeper_skill_preparation_observation in
  let frozen = cache_scenario_snapshot "observed-products" in
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  let reports = ref [] in
  let result = O.capture_result ~on_report:(fun report -> reports := report :: !reports) (fun () ->
    let first = preparation_for_cache_scenario ~snapshot:frozen ~descriptors in
    let again = preparation_for_cache_scenario ~snapshot:frozen ~descriptors:(List.map Fun.id descriptors) in
    check bool "measurement retains actual product sharing" true (first == again);
    Ok ()) in
  check bool "measurement retains the operation result" true (result = Ok ());
  let report = match !reports with [report] -> report | _ -> fail "one complete preparation report expected" in
  check bool "actual fiber coverage" true (report.coverage = O.Fiber_capture);
  let count component decision = List.filter (fun (sample : O.sample) ->
      sample.component = component && sample.decision = Some decision) report.samples |> List.length in
  check int "one actual projection construction" 1 (count O.Projection O.Constructed);
  check int "one actual projection reuse" 1 (count O.Projection O.Reused);
  check int "one actual full product construction" 1 (count O.Task_product O.Constructed);
  check int "one actual full product reuse" 1 (count O.Task_product O.Reused);
  check int "both retained surface uses are distinct from cache lookups" 2 (count O.Retained_turn_surface O.Reused);
  List.iter (fun (sample : O.sample) ->
    check bool "only this original source is sampled" true
      (sample.snapshot_revision = Snapshot.snapshot_revision frozen);
    check bool "sample completion is actual, within this capture" true
      (match sample.finished_ns with Some finished -> sample.entered_ns <= finished && finished <= report.elapsed_ns | None -> false);
    match sample.component with
    | O.Retained_turn_surface ->
      check bool "retained handles do not invent a lock acquisition" true (Option.is_none sample.lock_acquired_ns)
    | O.Projection | O.Task_product ->
      check bool "actual lookup and acquisition precede the decision" true
        (match sample.lookup_finished_ns,sample.lock_acquired_ns,sample.decision_ns with
         | Some lookup,Some acquired,Some decided -> sample.entered_ns <= lookup && lookup <= acquired && acquired <= decided
         | _ -> false)) report.samples
;;

let test_preparation_capture_isolates_nested_work_and_preserves_cancellation () =
  Eio_main.run @@ fun _ ->
  let module O = Masc.Keeper_skill_preparation_observation in
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  let outer = cache_scenario_snapshot "outer-observation" and inner = cache_scenario_snapshot "inner-observation" in
  let reports = ref [] in
  let capture name operation = O.capture_result ~on_report:(fun report -> reports := (name,report)::!reports) operation in
  (try
    Eio.Cancel.sub (fun context ->
      ignore (capture "outer" (fun () ->
        ignore (preparation_for_cache_scenario ~snapshot:outer ~descriptors);
        ignore (capture "inner" (fun () ->
          ignore (preparation_for_cache_scenario ~snapshot:inner ~descriptors); Ok ()));
        Eio.Cancel.cancel context Exit;
        Eio.Fiber.yield ();
        Ok ()))
    );
    fail "caller cancellation was swallowed"
   with Eio.Cancel.Cancelled _ -> ());
  let outside = List.assoc "outer" !reports and inside = List.assoc "inner" !reports in
  check bool "cancelled outer work is not reported as success" true (outside.outcome = O.Cancelled);
  check bool "settled nested work keeps its own result" true (inside.outcome = O.Returned);
  List.iter (fun (sample : O.sample) -> check bool "nested work cannot borrow outer clock or source" true
    (sample.snapshot_revision = Snapshot.snapshot_revision inner)) inside.samples;
  List.iter (fun (sample : O.sample) ->
    check bool "original samples survive cancellation without nested attribution" true
      (sample.snapshot_revision = Snapshot.snapshot_revision outer && sample.outcome = O.Returned)) outside.samples;
  let unreadable = Snapshot.config_unreadable ~detail:"fixture unavailable" in
  let failed = O.capture_result ~on_report:(fun report -> reports := ("error",report)::!reports)
      (fun () -> Selection.resolve_surface ~descriptors ~snapshot:unreadable
        [(match Snapshot.entries outer with entry::_ -> Snapshot.entry_reference entry | [] -> fail "missing fixture entry")]) in
  check bool "a typed preparation error stays an error" true (Result.is_error failed);
  let error = List.assoc "error" !reports in
  check bool "failure before cache access is not an empty successful preparation" true
    (error.outcome = O.Returned_error && error.samples = []);
  let left_entered,enter_left = Eio.Promise.create () and right_entered,enter_right = Eio.Promise.create () in
  Eio.Fiber.both
    (fun () -> ignore (capture "left" (fun () ->
      ignore (preparation_for_cache_scenario ~snapshot:outer ~descriptors);
      Eio.Promise.resolve enter_left ();
      Eio.Promise.await right_entered;
      Ok ())))
    (fun () -> ignore (capture "right" (fun () ->
      ignore (preparation_for_cache_scenario ~snapshot:inner ~descriptors);
      Eio.Promise.resolve enter_right ();
      Eio.Promise.await left_entered;
      Ok ())));
  List.iter (fun (name,source) ->
    let report = List.assoc name !reports in
    check bool "overlapping original work retains its own settled capture" true
      (report.outcome = O.Returned && report.samples <> []);
    List.iter (fun (sample : O.sample) ->
      check bool "parallel work cannot borrow sibling source or clock scope" true
        (sample.snapshot_revision = Snapshot.snapshot_revision source)) report.samples)
    ["left",outer;"right",inner]
;;

let test_preparation_manifest_retains_original_turn_and_private_boundaries () =
  Eio_main.run @@ fun _ ->
  Eio.Switch.run @@ fun sw ->
  let module R = Masc.Keeper_skill_preparation_runtime_observation in
  let module M = Masc.Keeper_runtime_manifest in
  let root = Filename.temp_file "masc-preparation-observation-" "" in
  Sys.remove root;
  Fs_compat.mkdir_p root;
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
  let config = Masc.Workspace.default_config root in
  let keeper_name = "observed" in
  let turn_ref = Ids.Turn_ref.make ~trace_id:"original-preparation-trace" ~absolute_turn:7 in
  let owner = Masc.Keeper_interrupt_token.fresh () in
  let preview = Masc.Keeper_turn_preview_owner.with_owner ~interrupt_token:owner ~observation:(Masc.Keeper_turn_preview_owner.create_turn_observation ()) (fun () ->
    Masc.Keeper_turn_preview.reset ~keeper_name ~execution_scope:None ~turn_ref:(Some turn_ref)
      ~now:0. ~redaction:Masc.Keeper_secret_redaction.empty) in
  let frozen = cache_scenario_snapshot "persisted-observation" in
  let descriptors = Masc.Keeper_tool_descriptor.all_descriptors () in
  let selection = match R.with_turn_result ~preview ~config ~keeper_name ~turn_ref ~phase:R.Direct_task_resolution
      (fun () ->
        check bool "actual resolution publishes its active owned Skill scope" true
          (match Masc.Keeper_turn_preview.current_for_turn ~keeper_name ~interrupt_token:owner with
           | Some {preparation=Some {phase=Skill_preparation;state=Preparation_active;turn_ref=Some observed;_};_} ->
             Ids.Turn_ref.equal observed turn_ref
           | Some _ | None -> false);
        Selection.resolve ~descriptors ~snapshot:frozen []) with
    | Ok selection -> selection | Error error -> fail (Selection.error_to_string error) in
  ignore (R.with_turn_result ~preview ~config ~keeper_name ~turn_ref ~phase:R.Executable_setup
    (fun () -> Selection.bind_surface ~snapshot:frozen ~descriptors selection));
  check bool "the carried writer retains the producer's original identity" true
    (Masc.Keeper_turn_preview.original_turn_ref preview = Some turn_ref);
  let path = M.path_for_trace config ~keeper_name ~trace_id:(Ids.Turn_ref.trace_id turn_ref) in
  let rows = In_channel.with_open_bin path In_channel.input_lines |> List.map (fun line ->
    match M.decode_persisted_row (Yojson.Safe.from_string line) with
    | Ok (M.Active_row row) -> row
    | Ok (M.Unsupported_row _) | Error _ -> fail "actual preparation row did not decode") in
  check int "one record per actual resolution/setup boundary" 2 (List.length rows);
  List.iter (fun (row : M.t) ->
    check bool "original identity and event survive durable readback" true
      (row.event = M.Skill_preparation_observed && row.trace_id = Ids.Turn_ref.trace_id turn_ref && row.keeper_turn_id = Some 7);
    let public = M.public_to_json row in
    check string "public observation retains the original turn reference"
      (Ids.Turn_ref.to_string turn_ref)
      Yojson.Safe.Util.(public |> member "decision" |> member "skill_preparation" |> member "turn_ref" |> to_string)) rows;
  check bool "observations do not prove turn completion" false (M.is_finished_turn rows);
  let module Scan = Server_dashboard_http_keeper_runtime_manifest_scan in
  let scan = List.fold_left Scan.update_runtime_manifest_scan
      (Scan.make_runtime_manifest_scan ~path ~limit:(List.length rows)
        ~scan_line_limit:(List.length rows) ~scan_scope:"test") rows in
  check int "preparation records do not count as context injection" 0 scan.context_injected_count;
  check int "the direct consumer retains actual preparation records" 2
    (Hashtbl.find scan.event_counts "skill_preparation_observed");
  let edges = Server_dashboard_http_keeper_runtime_lens_clock_edges.clock_edge_jsons scan in
  check int "actual preparation clock edges survive the API projection" 2 (List.length edges);
  List.iter (fun edge -> check bool "wall-clock row timestamps do not become measured edges" true
    Yojson.Safe.Util.(member "started_at" edge = `Null && member "finished_at" edge = `Null)) edges;
  let public = M.public_projection_of_decision (`Assoc ["skill_preparation",`Assoc
      ["phase",`String "fixture";"document_body",`String "PRIVATE_BODY"
      ;"samples",`List [`Assoc ["component",`String "projection";"tool_input",`String "PRIVATE_INPUT"]]]]) in
  check bool "new public scope omits document text and Tool input" true
    Yojson.Safe.Util.(member "skill_preparation" public |> fun payload ->
      member "document_body" payload = `Null && member "tool_input" (payload |> member "samples" |> to_list |> List.hd) = `Null)
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
        ; test_case "oversized Task Skill is unavailable, not a failed turn" `Quick
            test_oversized_task_skill_is_unavailable_not_a_failed_turn
        ; test_case "held shadow composition collision is exact" `Quick
            test_held_shadow_composition_wins_with_exact_collision_evidence
        ; test_case "malformed exact composition falls back" `Quick
            test_malformed_exact_composition_is_frozen_instruction
        ; test_case "shared exact ref retains all Task ids" `Quick
            test_shared_exact_reference_retains_every_task_id
        ; test_case "Task binding reuses only exact frozen source and Tool authority" `Quick
            test_task_binding_reuses_only_exact_frozen_inputs
        ; test_case "interleaved preparation keeps each exact Tool binding" `Quick
            test_interleaved_preparation_keeps_each_exact_tool_binding
        ; test_case "simultaneous cold preparation is shared" `Quick
            test_simultaneous_cold_preparation_is_shared
        ; test_case "preparation cache does not own retired inputs" `Quick
            test_preparation_cache_does_not_own_retired_inputs
        ; test_case "preparation observes actual cold and reused products" `Quick
            test_preparation_observes_actual_cold_and_reused_products
        ; test_case "preparation capture isolates nested work and preserves cancellation" `Quick
            test_preparation_capture_isolates_nested_work_and_preserves_cancellation
        ; test_case "preparation manifest retains original turn and private boundaries" `Quick
            test_preparation_manifest_retains_original_turn_and_private_boundaries
        ; test_case "exact ref consumer rejects name fallback" `Quick
            test_exact_reference_consumer_rejects_name_fallback
        ; test_case "resolved body remains frozen" `Quick
            test_resolved_body_stays_frozen_after_new_snapshot
        ; test_case "resource read is exact and deferred" `Quick
            test_resource_is_read_only_when_exact_file_is_requested
        ; test_case "JEV advice reaches model without changing selection" `Quick
            test_jev_advice_reaches_the_model_without_selecting_or_authorizing
        ; test_case "stale revision pin does not stop resolution" `Quick
            test_stale_revision_pin_does_not_stop_resolution
        ; test_case "current pin still projects" `Quick
            test_current_pin_still_projects
        ; test_case "stale pin is listed unavailable on the prompt surface" `Quick
            test_stale_pin_is_listed_unavailable_on_the_prompt_surface
        ; test_case "deleted Skill pin does not stop resolution" `Quick
            test_deleted_skill_pin_does_not_stop_resolution
        ; test_case "unusable Skill configuration stops resolution, a stale pin does not" `Quick
            test_unusable_skill_config_stops_resolution_unlike_a_stale_pin
        ; test_case "unreadable source stops resolution, a stale pin does not" `Quick
            test_unreadable_source_stops_resolution_unlike_a_stale_pin
        ; test_case "unreadable candidate stops resolution, a stale pin does not" `Quick
            test_unreadable_candidate_stops_resolution_unlike_a_stale_pin
        ; test_case "pin into an unconfigured source reads as deleted" `Quick
            test_pin_into_unconfigured_source_reads_as_deleted
        ] )
    ]
;;
