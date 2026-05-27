(** test_keeper_topk_llm — Verify TopK_llm integration in keeper tool selection.

    Tests the OAS Tool_selector.TopK_llm strategy as wired by the keeper's
    before_turn_hook. Uses mock rerank_fn closures (no LLM calls).

    @since 2.255.0 — PR-4: TopK_llm activation *)

open Masc_mcp

(* ── Helpers ─────────────────────────────────────────────── *)

(** Create a minimal OAS Tool.t from name and description. *)
let make_tool name description : Agent_sdk.Tool.t =
  Agent_sdk.Tool.create ~name ~description ~parameters:[]
    (fun _input -> Ok { content = "ok" })

(** A mock rerank_fn that returns the first [k] candidates in order. *)
let mock_rerank_passthrough ~context:_ ~candidates =
  List.map fst candidates

(** A mock rerank_fn that reverses candidate order (verifies reranking effect). *)
let mock_rerank_reverse ~context:_ ~candidates =
  List.rev_map fst candidates

(** A mock rerank_fn that always selects tools containing a keyword. *)
let mock_rerank_keyword keyword ~context:_ ~candidates =
  let klen = String.length keyword in
  List.filter_map (fun (name, _desc) ->
    let nlen = String.length name in
    if nlen < klen then None
    else
      let found = ref false in
      for i = 0 to nlen - klen do
        if String.sub name i klen = keyword then found := true
      done;
      if !found then Some name else None
  ) candidates

(** A mock rerank_fn that always raises. *)
let mock_rerank_failing ~context:_ ~candidates:_ =
  failwith "LLM unavailable"

(* ── Test tools ──────────────────────────────────────────── *)

let test_tools = [
  make_tool "keeper_board_post" "Post a message to the board";
  make_tool "keeper_board_get" "Read a board post by ID";
  make_tool "keeper_board_list" "List recent board posts";
  make_tool "tool_read_file" "Read a file from the filesystem";
  make_tool "tool_edit_file" "Edit a file on the filesystem";
  make_tool "tool_search_files" "Execute a structured read-only shell operation";
  make_tool "tool_execute" "Execute a shell command";
  make_tool "keeper_memory_search" "Search agent memory";
  make_tool "keeper_broadcast" "Broadcast a message to all agents";
  make_tool "keeper_tasks_list" "List all tasks";
  make_tool "keeper_task_claim" "Claim a task";
  make_tool "keeper_task_done" "Mark a task as done";
  make_tool "keeper_context_status" "Check context window usage";
  make_tool "keeper_tools_list" "List available tools";
  make_tool "keeper_stay_silent" "Do nothing (no-op tool)";
  make_tool "keeper_tool_search" "Search for tools by keyword";
  make_tool "tool_search_files" "Search code in the repository";
  make_tool "tool_read_file" "Read code from a source file";
  make_tool "tool_search_files" "List functions and classes from a source file";
  make_tool "tool_edit_file" "Edit code files";
  make_tool "tool_execute" "Create a git worktree";
]

let test_search_index () =
  let tool_entries =
    List.map
      (fun (tool : Agent_sdk.Tool.t) ->
        Agent_sdk.Tool_index.
          {
            name = tool.schema.name;
            description = tool.schema.description;
            group = None;
            aliases = [];
          })
      test_tools
  in
  Agent_sdk.Tool_index.build
    ~config:{ Agent_sdk.Tool_index.default_config with top_k = 10 }
    tool_entries

let test_search_index_with_production_aliases tools =
  let tool_entries =
    List.map Keeper_agent_tool_surface.tool_index_entry_of_tool tools
  in
  Agent_sdk.Tool_index.build
    ~config:{ Agent_sdk.Tool_index.default_config with top_k = 10 }
    tool_entries

let deterministic_prefilter_for ~query_text ~selection_limit =
  Keeper_tool_selection.deterministic_prefilter_names
    ~search_index:(test_search_index ())
    ~query_text
    ~selection_limit
    ~core:(Agent_tool_dispatch_runtime.effective_core_tools ())

let deterministic_prefilter_for_tools ~tools ~query_text ~selection_limit =
  Keeper_tool_selection.deterministic_prefilter_names
    ~search_index:(test_search_index_with_production_aliases tools)
    ~query_text
    ~selection_limit
    ~core:(Agent_tool_dispatch_runtime.effective_core_tools ())

(* ── Tests ───────────────────────────────────────────────── *)

let test_topk_llm_basic_selection () =
  let strategy = Agent_sdk.Tool_selector.TopK_llm {
    k = 5;
    bm25_prefilter_n = 15;
    always_include = ["keeper_context_status"];
    confidence_threshold = 0.0;
    rerank_fn = mock_rerank_passthrough;
  } in
  let selected = Agent_sdk.Tool_selector.select_names
    ~strategy ~context:"post a message on the board" ~tools:test_tools in
  Alcotest.(check bool) "non-empty result" true (selected <> []);
  Alcotest.(check bool) "always_include present"
    true (List.mem "keeper_context_status" selected);
  Alcotest.(check bool) "at most k+always results"
    true (List.length selected <= 6)

let test_topk_llm_rerank_effect () =
  let passthrough_strategy = Agent_sdk.Tool_selector.TopK_llm {
    k = 3;
    bm25_prefilter_n = 10;
    always_include = [];
    confidence_threshold = 0.0;
    rerank_fn = mock_rerank_passthrough;
  } in
  let reverse_strategy = Agent_sdk.Tool_selector.TopK_llm {
    k = 3;
    bm25_prefilter_n = 10;
    always_include = [];
    confidence_threshold = 0.0;
    rerank_fn = mock_rerank_reverse;
  } in
  let context = "read a file from disk" in
  let pass_names = Agent_sdk.Tool_selector.select_names
    ~strategy:passthrough_strategy ~context ~tools:test_tools in
  let rev_names = Agent_sdk.Tool_selector.select_names
    ~strategy:reverse_strategy ~context ~tools:test_tools in
  (* Reranking should change the result set when candidates > k *)
  Alcotest.(check bool) "reranking changes results"
    true (pass_names <> rev_names || List.length test_tools <= 3)

let test_topk_llm_fallback_on_failure () =
  let strategy = Agent_sdk.Tool_selector.TopK_llm {
    k = 3;
    bm25_prefilter_n = 10;
    always_include = ["keeper_stay_silent"];
    confidence_threshold = 0.0;
    rerank_fn = mock_rerank_failing;
  } in
  (* Should not raise — OAS catches the exception and falls back to BM25 *)
  let selected = Agent_sdk.Tool_selector.select_names
    ~strategy ~context:"search code" ~tools:test_tools in
  Alcotest.(check bool) "fallback returns results" true (selected <> []);
  Alcotest.(check bool) "always_include survives failure"
    true (List.mem "keeper_stay_silent" selected)

let test_topk_llm_confidence_gate () =
  let call_count = ref 0 in
  let counting_rerank ~context:_ ~candidates =
    incr call_count;
    List.map fst candidates
  in
  let strategy = Agent_sdk.Tool_selector.TopK_llm {
    k = 3;
    bm25_prefilter_n = 10;
    always_include = [];
    confidence_threshold = 999.0;  (* Impossibly high — will always skip LLM *)
    rerank_fn = counting_rerank;
  } in
  let _selected = Agent_sdk.Tool_selector.select_names
    ~strategy ~context:"anything" ~tools:test_tools in
  Alcotest.(check int) "LLM not called when confidence below threshold"
    0 !call_count

let test_topk_llm_empty_tools () =
  let strategy = Agent_sdk.Tool_selector.TopK_llm {
    k = 5;
    bm25_prefilter_n = 10;
    always_include = [];
    confidence_threshold = 0.0;
    rerank_fn = mock_rerank_passthrough;
  } in
  let selected = Agent_sdk.Tool_selector.select_names
    ~strategy ~context:"anything" ~tools:[] in
  Alcotest.(check (list string)) "empty tools -> empty result" [] selected

let test_topk_llm_keyword_rerank () =
  let strategy = Agent_sdk.Tool_selector.TopK_llm {
    k = 5;
    bm25_prefilter_n = 20;
    always_include = [];
    confidence_threshold = 0.0;
    rerank_fn = mock_rerank_keyword "board";
  } in
  let selected = Agent_sdk.Tool_selector.select_names
    ~strategy ~context:"board post message" ~tools:test_tools in
  (* All selected should contain "board" *)
  let contains_board name =
    let nlen = String.length name in
    if nlen < 5 then false
    else
      let found = ref false in
      for i = 0 to nlen - 5 do
        if String.sub name i 5 = "board" then found := true
      done;
      !found
  in
  List.iter (fun name ->
    Alcotest.(check bool)
      (Printf.sprintf "%s contains 'board'" name)
      true (contains_board name)
  ) selected

let test_topk_llm_always_include_survives () =
  let strategy = Agent_sdk.Tool_selector.TopK_llm {
    k = 2;
    bm25_prefilter_n = 5;
    always_include = ["keeper_stay_silent"; "keeper_context_status"];
    confidence_threshold = 0.0;
    rerank_fn = (fun ~context:_ ~candidates ->
      (* Return only board tools — always_include should still appear *)
      List.filter_map (fun (name, _) ->
        if String.length name > 6 && String.sub name 0 6 = "keeper" then Some name
        else None
      ) candidates
      |> List.filteri (fun i _ -> i < 1));
  } in
  let selected = Agent_sdk.Tool_selector.select_names
    ~strategy ~context:"do something" ~tools:test_tools in
  Alcotest.(check bool) "always_include[0] present"
    true (List.mem "keeper_stay_silent" selected);
  Alcotest.(check bool) "always_include[1] present"
    true (List.mem "keeper_context_status" selected)

let test_selection_boundary_preserves_deterministic_floor () =
  let deterministic_prefilter = ["tool_read_file"; "keeper_board_post"] in
  let llm_selected = ["keeper_board_post"] in
  let merged =
    Keeper_tool_selection.merge_tool_selection_boundary
      ~core:["keeper_context_status"]
      ~deterministic_prefilter
      ~llm_selected
      ~discovered:["keeper_tool_search"]
  in
  Alcotest.(check bool) "input carries duplicate across boundary" true
    (List.mem "keeper_board_post" deterministic_prefilter
     && List.mem "keeper_board_post" llm_selected);
  let board_post_count =
    List.fold_left (fun acc name ->
      if name = "keeper_board_post" then acc + 1 else acc
    ) 0 merged
  in
  Alcotest.(check int) "merged list contains 4 unique tools" 4
    (List.length merged);
  Alcotest.(check int) "duplicate removed from merged result" 1
    board_post_count;
  Alcotest.(check (list string))
    "deterministic floor survives even when llm omits most tools"
    [ "tool_read_file";
      "keeper_board_post";
      "keeper_tool_search";
      "keeper_context_status";
    ]
    merged

let test_selection_boundary_appends_llm_only_extras () =
  let merged =
    Keeper_tool_selection.merge_tool_selection_boundary
      ~core:["keeper_context_status"]
      ~deterministic_prefilter:["tool_read_file"]
      ~llm_selected:["tool_execute"; "tool_read_file"; "keeper_board_post"]
      ~discovered:["keeper_tool_search"]
  in
  let index_of name =
    let rec loop i = function
      | [] -> None
      | x :: xs -> if x = name then Some i else loop (i + 1) xs
    in
    loop 0 merged
  in
  let discovered_ix = index_of "keeper_tool_search" in
  let llm_extra_ix = index_of "tool_execute" in
  Alcotest.(check bool) "deterministic tool stays ahead of llm extra"
    true
    (match discovered_ix, llm_extra_ix with
     | Some d, Some e -> d < e
     | _ -> false);
  Alcotest.(check (list string))
    "llm extras append after deterministic floor without duplicates"
    [ "tool_read_file";
      "keeper_tool_search";
      "keeper_context_status";
      "tool_execute";
      "keeper_board_post";
    ]
    merged

let test_selection_boundary_sorts_discovered () =
  (* discovered arrives in Hashtbl.fold order (non-deterministic).
     merge_tool_selection_boundary must sort it for stable output. *)
  let merged_ab =
    Keeper_tool_selection.merge_tool_selection_boundary
      ~core:["core_tool"]
      ~deterministic_prefilter:[]
      ~llm_selected:[]
      ~discovered:["tool_b"; "tool_a"]
  in
  let merged_ba =
    Keeper_tool_selection.merge_tool_selection_boundary
      ~core:["core_tool"]
      ~deterministic_prefilter:[]
      ~llm_selected:[]
      ~discovered:["tool_a"; "tool_b"]
  in
  Alcotest.(check (list string))
    "discovered order is stable regardless of input order"
    merged_ab merged_ba;
  Alcotest.(check (list string))
    "discovered is sorted alphabetically before core"
    ["tool_a"; "tool_b"; "core_tool"]
    merged_ab

let test_deterministic_prefilter_surfaces_source_navigation () =
  let selected =
    deterministic_prefilter_for
      ~query_text:"search code in the repository"
      ~selection_limit:3
  in
  Alcotest.(check bool) "source search appears without llm rerank"
    true (List.mem "tool_search_files" selected)

let test_deterministic_prefilter_surfaces_source_read_for_explicit_read_intent () =
  let selected =
    deterministic_prefilter_for
      ~query_text:"read source file contents"
      ~selection_limit:5
  in
  Alcotest.(check bool) "source read appears for explicit read intent"
    true (List.mem "tool_read_file" selected)

let test_deterministic_prefilter_surfaces_source_read_for_source_path_hint () =
  let selected =
    deterministic_prefilter_for
      ~query_text:"open lib/keeper/agent_tool_execute_runtime.ml"
      ~selection_limit:5
  in
  Alcotest.(check bool) "source read appears for source path hint"
    true (List.mem "tool_read_file" selected)

let test_deterministic_prefilter_surfaces_source_symbols_for_explicit_symbol_intent
    () =
  let selected =
    deterministic_prefilter_for
      ~query_text:"show function symbols"
      ~selection_limit:5
  in
  Alcotest.(check bool) "source symbols appears for explicit symbol intent"
    true (List.mem "tool_search_files" selected);
  Alcotest.(check bool) "source read stays out of symbol-only intent"
    false (List.mem "tool_read_file" selected)

let test_deterministic_prefilter_hides_source_navigation_without_source_intent () =
  let selected =
    deterministic_prefilter_for
      ~query_text:"show me activity overview for the room"
      ~selection_limit:5
  in
  Alcotest.(check bool) "source search stays hidden for non-source query"
    false (List.mem "tool_search_files" selected);
  Alcotest.(check bool) "source read stays hidden for non-source query"
    false (List.mem "tool_read_file" selected);
  Alcotest.(check bool) "source symbols stays hidden for non-source query"
    false (List.mem "tool_search_files" selected)

let test_deterministic_prefilter_hides_source_read_for_generic_file_read () =
  let selected =
    deterministic_prefilter_for
      ~query_text:"read file contents"
      ~selection_limit:5
  in
  Alcotest.(check bool) "source read stays hidden for generic file read"
    false (List.mem "tool_read_file" selected)

let test_deterministic_prefilter_surfaces_execute_for_explicit_pr_request () =
  let pr_status_tools =
    test_tools
    @ [
        make_tool "Execute"
          "Execute typed argv for git and gh pull request inspection";
      ]
  in
  let selected =
    deterministic_prefilter_for_tools
      ~tools:pr_status_tools
      ~query_text:
        "Use gh pr view through Execute for PR #13526. Do not use identity probes."
      ~selection_limit:10
  in
  let visible =
    Keeper_tool_selection.merge_tool_selection_boundary
      ~core:(Agent_tool_dispatch_runtime.effective_core_tools ())
      ~deterministic_prefilter:selected
      ~llm_selected:[]
      ~discovered:[]
  in
  Alcotest.(check bool) "Execute appears in final visible surface"
    true (List.mem "Execute" visible)

let test_execute_aliases_cover_draft_pr_workflow () =
  let aliases =
    Keeper_agent_tool_surface.tool_search_aliases "Execute"
  in
  Alcotest.(check bool) "Execute aliases mention draft PR"
    true (List.mem "draft" aliases);
  Alcotest.(check bool) "Execute aliases mention pull request"
    true (List.mem "pull" aliases);
  Alcotest.(check bool) "Execute aliases include Korean create intent"
    true (List.mem "생성" aliases)

let test_shell_aliases_do_not_cover_draft_pr_workflow () =
  let aliases =
    Keeper_agent_tool_surface.tool_search_aliases "tool_search_files"
  in
  Alcotest.(check bool) "tool_search_files aliases do not mention draft"
    false (List.mem "draft" aliases);
  Alcotest.(check bool) "tool_search_files aliases do not mention pull request"
    false (List.mem "pull" aliases);
  Alcotest.(check bool) "tool_search_files aliases omit Korean create intent"
    false (List.mem "생성" aliases)

let test_public_aliases_reuse_internal_search_aliases () =
  Alcotest.(check (list string))
    "Execute shares tool_execute aliases"
    (Keeper_agent_tool_surface.tool_search_aliases "tool_execute")
    (Keeper_agent_tool_surface.tool_search_aliases "Execute");
  Alcotest.(check (list string))
    "SearchFiles shares tool_search_files aliases"
    (Keeper_agent_tool_surface.tool_search_aliases "tool_search_files")
    (Keeper_agent_tool_surface.tool_search_aliases "SearchFiles")

let test_deterministic_prefilter_surfaces_execute_for_draft_pr_request () =
  let pr_create_tools =
    [ make_tool "Execute"
        "Execute typed argv for git and gh operations including draft pull \
         request creation"
    ; make_tool "keeper_tool_search" "Search for tools by keyword"
    ; make_tool "keeper_context_status" "Check context window usage"
    ]
  in
  let selected =
    deterministic_prefilter_for_tools
      ~tools:pr_create_tools
      ~query_text:
        "branch push 완료. gh pr create 대신 draft 풀리퀘스트 생성해야 함"
      ~selection_limit:10
  in
  let visible =
    Keeper_tool_selection.merge_tool_selection_boundary
      ~core:(Agent_tool_dispatch_runtime.effective_core_tools ())
      ~deterministic_prefilter:selected
      ~llm_selected:[]
      ~discovered:[]
  in
  Alcotest.(check bool) "Execute appears in visible surface"
    true (List.mem "Execute" visible);
  Alcotest.(check bool) "tool_search_files stays out of visible surface"
    false (List.mem "tool_search_files" visible);
  Alcotest.(check bool) "legacy github_pr_ surface stays out of visible surface"
    false (List.exists (String.starts_with ~prefix:"github_pr_") visible)

let test_tool_search_partition_returns_allowed_core_hits () =
  let partition =
    Keeper_run_tools.partition_tool_search_hits
      ~core:
        [ "keeper_tool_search";
          "Execute";
        ]
      ~core_always:["keeper_tool_search"]
      ~allowed:["Execute"]
      ~retrieved:
        [ "Execute", 1.0 ]
      ~max_results:10
  in
  Alcotest.(check (list string))
    "allowed core hits are visible search results"
    [ "Execute" ]
    (List.map fst partition.visible_core_hits);
  Alcotest.(check (list string))
    "core hits are not rediscovered"
    [] (List.map fst partition.discoverable_hits);
  Alcotest.(check int) "no policy filtering" 0 partition.filtered_by_policy

let test_tool_search_partition_filters_policy_denied_core_hits () =
  let partition =
    Keeper_run_tools.partition_tool_search_hits
      ~core:["Execute"]
      ~core_always:["keeper_tool_search"]
      ~allowed:["keeper_board_post"]
      ~retrieved:
        [ "Execute", 1.0;
          "keeper_board_post", 0.8;
        ]
      ~max_results:10
  in
  Alcotest.(check (list string))
    "policy-denied core hit is not exposed"
    [] (List.map fst partition.visible_core_hits);
  Alcotest.(check (list string))
    "allowed non-core hit remains discoverable"
    [ "keeper_board_post" ]
    (List.map fst partition.discoverable_hits);
  Alcotest.(check int) "one policy-filtered hit" 1 partition.filtered_by_policy

let test_tool_surface_truncation_dedupes_essential_tools () =
  let truncated =
    Keeper_run_tools.truncate_tool_surface_names
      ~max_tools:4
      ~essential_names:[ "keeper_context_status"; "keeper_task_done" ]
      [
        "keeper_context_status";
        "keeper_task_done";
        "keeper_board_get";
        "keeper_task_done";
        "tool_search_files";
        "tool_read_file";
      ]
  in
  Alcotest.(check (list string))
    "required essential is not double-counted in truncated surface"
    [
      "keeper_context_status";
      "keeper_task_done";
      "keeper_board_get";
      "tool_search_files";
    ]
    truncated

let test_keeper_config_defaults () =
  (* Default: LLM rerank disabled *)
  Alcotest.(check bool) "llm_rerank disabled by default"
    false (Keeper_config.keeper_llm_rerank_enabled ());
  (* Default cascade name *)
  let cascade = Keeper_config.keeper_llm_rerank_cascade () in
  Alcotest.(check string) "default cascade name"
    "route.llm_rerank" cascade

(* ── Suite ───────────────────────────────────────────────── *)

let () =
  Alcotest.run "keeper_topk_llm" [
    "topk_llm_selection", [
      Alcotest.test_case "basic selection" `Quick
        test_topk_llm_basic_selection;
      Alcotest.test_case "rerank effect" `Quick
        test_topk_llm_rerank_effect;
      Alcotest.test_case "fallback on rerank failure" `Quick
        test_topk_llm_fallback_on_failure;
      Alcotest.test_case "confidence gate skips LLM" `Quick
        test_topk_llm_confidence_gate;
      Alcotest.test_case "empty tools" `Quick
        test_topk_llm_empty_tools;
      Alcotest.test_case "keyword reranker" `Quick
        test_topk_llm_keyword_rerank;
      Alcotest.test_case "always_include survives" `Quick
        test_topk_llm_always_include_survives;
      Alcotest.test_case "deterministic floor preserved" `Quick
        test_selection_boundary_preserves_deterministic_floor;
      Alcotest.test_case "llm extras append after floor" `Quick
        test_selection_boundary_appends_llm_only_extras;
      Alcotest.test_case "discovered sorted for stable order" `Quick
        test_selection_boundary_sorts_discovered;
      Alcotest.test_case "deterministic prefilter surfaces source navigation" `Quick
        test_deterministic_prefilter_surfaces_source_navigation;
      Alcotest.test_case "deterministic prefilter surfaces source read" `Quick
        test_deterministic_prefilter_surfaces_source_read_for_explicit_read_intent;
      Alcotest.test_case "deterministic prefilter surfaces source read for path hint" `Quick
        test_deterministic_prefilter_surfaces_source_read_for_source_path_hint;
      Alcotest.test_case "deterministic prefilter surfaces source symbols" `Quick
        test_deterministic_prefilter_surfaces_source_symbols_for_explicit_symbol_intent;
      Alcotest.test_case "deterministic prefilter hides source navigation" `Quick
        test_deterministic_prefilter_hides_source_navigation_without_source_intent;
      Alcotest.test_case "deterministic prefilter hides source read for generic file read" `Quick
        test_deterministic_prefilter_hides_source_read_for_generic_file_read;
      Alcotest.test_case "deterministic prefilter surfaces pr status tools" `Quick
        test_deterministic_prefilter_surfaces_execute_for_explicit_pr_request;
      Alcotest.test_case "Execute aliases cover draft PR workflow" `Quick
        test_execute_aliases_cover_draft_pr_workflow;
      Alcotest.test_case "tool_search_files aliases exclude draft PR workflow" `Quick
        test_shell_aliases_do_not_cover_draft_pr_workflow;
      Alcotest.test_case "public aliases reuse internal search aliases" `Quick
        test_public_aliases_reuse_internal_search_aliases;
      Alcotest.test_case "visible Execute covers draft PR request" `Quick
        test_deterministic_prefilter_surfaces_execute_for_draft_pr_request;
      Alcotest.test_case "tool_search returns allowed core hits" `Quick
        test_tool_search_partition_returns_allowed_core_hits;
      Alcotest.test_case "tool_search filters denied core hits" `Quick
        test_tool_search_partition_filters_policy_denied_core_hits;
      Alcotest.test_case "tool surface truncation dedupes essential tools" `Quick
        test_tool_surface_truncation_dedupes_essential_tools;
    ];
    "keeper_config", [
      Alcotest.test_case "config defaults" `Quick
        test_keeper_config_defaults;
    ];
  ]
