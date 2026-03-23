open Alcotest
open Masc_mcp

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let preset_json rel_path =
  Yojson.Safe.from_file (Filename.concat (source_root ()) rel_path)

let parse_preset rel_path =
  let json = preset_json rel_path in
  match Chain_parser.parse_chain json with
  | Error e -> failf "parse failed for %s: %s" rel_path e
  | Ok chain -> chain

let find_node chain node_id =
  match List.find_opt (fun (node : Chain_types.node) -> String.equal node.id node_id) chain.Chain_types.nodes with
  | Some node -> node
  | None -> failf "node %s not found" node_id

let test_pr_review_pipeline_has_clean_structural_stage () =
  let chain = parse_preset "data/chains/pr-review-pipeline.json" in
  let structural = find_node chain "structural-review" in
  (match structural.node_type with
   | Chain_types.Spawn { clean; pass_vars; inherit_cache; inner } ->
       check bool "spawn is clean" true clean;
       check bool "spawn does not inherit cache" false inherit_cache;
       check bool "passes pr_diff" true (List.mem "pr_diff" pass_vars);
       check bool "passes changed_files" true (List.mem "changed_files" pass_vars);
       (match inner.node_type with
        | Chain_types.Model { prompt; _ } ->
            check bool "prompt mentions fresh context" true
              (try
                 ignore
                   (Str.search_forward
                      (Str.regexp_string "fresh-context structural reviewer")
                      prompt 0);
                 true
               with Not_found -> false)
        | _ -> fail "inner node is not a model")
   | _ -> fail "structural-review is not a spawn node");
  let synth = find_node chain "synthesize-review" in
  check bool "synthesize depends on structural stage" true
    (match synth.depends_on with
     | Some deps -> List.mem "structural-review" deps
     | None -> false)

let test_deep_research_uses_grep_projection () =
  let chain = parse_preset "data/chains/deep-research.json" in
  let projection = find_node chain "search-results-grep" in
  (match projection.node_type with
   | Chain_types.Adapter { input_ref; transform; _ } ->
       check string "projection input" "search_results" input_ref;
       (match transform with
        | Chain_types.Custom "grep_projection" -> ()
        | _ -> fail "projection does not use grep_projection custom transform")
   | _ -> fail "search-results-grep is not an adapter");
  let extract = find_node chain "extract-facts" in
  (match extract.node_type with
   | Chain_types.Model { prompt; _ } ->
       check bool "extract prompt references projected results" true
         (try
            ignore
              (Str.search_forward
                 (Str.regexp_string "{{search_results_grep}}")
                 prompt 0);
            true
          with Not_found -> false)
   | _ -> fail "extract-facts is not a model node")

let () =
  run "Chain_presets"
    [
      ( "review_pipeline",
        [
          test_case "has clean structural stage" `Quick
            test_pr_review_pipeline_has_clean_structural_stage;
        ] );
      ( "deep_research",
        [
          test_case "uses grep projection" `Quick
            test_deep_research_uses_grep_projection;
        ] );
    ]
