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
  make_tool "keeper_fs_read" "Read a file from the filesystem";
  make_tool "keeper_fs_edit" "Edit a file on the filesystem";
  make_tool "keeper_shell" "Execute a read-only shell command";
  make_tool "keeper_bash" "Execute a shell command";
  make_tool "keeper_github" "Interact with GitHub API";
  make_tool "keeper_memory_search" "Search agent memory";
  make_tool "keeper_broadcast" "Broadcast a message to all agents";
  make_tool "keeper_tasks_list" "List all tasks";
  make_tool "keeper_task_claim" "Claim a task";
  make_tool "keeper_task_done" "Mark a task as done";
  make_tool "keeper_context_status" "Check context window usage";
  make_tool "keeper_tools_list" "List available tools";
  make_tool "keeper_stay_silent" "Do nothing (no-op tool)";
  make_tool "keeper_tool_search" "Search for tools by keyword";
  make_tool "masc_code_search" "Search code in the repository";
  make_tool "masc_code_edit" "Edit code files";
  make_tool "masc_worktree_create" "Create a git worktree";
]

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
  let deterministic_prefilter = ["keeper_fs_read"; "keeper_board_post"] in
  let llm_selected = ["keeper_board_post"] in
  let merged =
    Keeper_tool_disclosure.merge_tool_selection_boundary
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
    [ "keeper_context_status";
      "keeper_fs_read";
      "keeper_board_post";
      "keeper_tool_search";
    ]
    merged

let test_selection_boundary_appends_llm_only_extras () =
  let merged =
    Keeper_tool_disclosure.merge_tool_selection_boundary
      ~core:["keeper_context_status"]
      ~deterministic_prefilter:["keeper_fs_read"]
      ~llm_selected:["keeper_bash"; "keeper_fs_read"; "keeper_board_post"]
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
  let llm_extra_ix = index_of "keeper_bash" in
  Alcotest.(check bool) "deterministic tool stays ahead of llm extra"
    true
    (match discovered_ix, llm_extra_ix with
     | Some d, Some e -> d < e
     | _ -> false);
  Alcotest.(check (list string))
    "llm extras append after deterministic floor without duplicates"
    [ "keeper_context_status";
      "keeper_fs_read";
      "keeper_tool_search";
      "keeper_bash";
      "keeper_board_post";
    ]
    merged

let test_selection_boundary_sorts_discovered () =
  (* discovered arrives in Hashtbl.fold order (non-deterministic).
     merge_tool_selection_boundary must sort it for stable output. *)
  let merged_ab =
    Keeper_tool_disclosure.merge_tool_selection_boundary
      ~core:["core_tool"]
      ~deterministic_prefilter:[]
      ~llm_selected:[]
      ~discovered:["tool_b"; "tool_a"]
  in
  let merged_ba =
    Keeper_tool_disclosure.merge_tool_selection_boundary
      ~core:["core_tool"]
      ~deterministic_prefilter:[]
      ~llm_selected:[]
      ~discovered:["tool_a"; "tool_b"]
  in
  Alcotest.(check (list string))
    "discovered order is stable regardless of input order"
    merged_ab merged_ba;
  Alcotest.(check (list string))
    "discovered is sorted alphabetically after core"
    ["core_tool"; "tool_a"; "tool_b"]
    merged_ab

let test_deterministic_prefilter_surfaces_code_tools () =
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
  let search_index =
    Agent_sdk.Tool_index.build
      ~config:{ Agent_sdk.Tool_index.default_config with top_k = 10 }
      tool_entries
  in
  let selected =
    Keeper_tool_disclosure.deterministic_prefilter_names
      ~search_index
      ~query_text:"search code in the repository"
      ~selection_limit:3
      ~core:(Keeper_exec_tools.effective_core_tools ())
  in
  Alcotest.(check bool) "code search appears without llm rerank"
    true (List.mem "masc_code_search" selected)

let test_prune_boring_tools_after_recent_polling () =
  let visible_tools =
    [ "masc_status"; "keeper_tasks_list"; "keeper_context_status";
      "keeper_stay_silent"; "keeper_fs_edit"; "masc_code_search" ]
  in
  let recent_entries =
    [ `Assoc [ ("tool", `String "masc_status") ] ]
  in
  let pruned =
    Keeper_tool_disclosure.prune_boring_tools_after_recent_polling
      ~visible_tools ~recent_entries
  in
  Alcotest.(check (list string))
    "recent polling hides boring tools but keeps productive tools"
    [ "keeper_stay_silent"; "keeper_fs_edit"; "masc_code_search" ]
    pruned

let test_prune_boring_tools_keeps_set_when_last_tool_productive () =
  let visible_tools =
    [ "masc_status"; "keeper_tasks_list"; "keeper_stay_silent"; "keeper_fs_edit" ]
  in
  let recent_entries =
    [ `Assoc [ ("tool", `String "keeper_fs_edit") ] ]
  in
  let pruned =
    Keeper_tool_disclosure.prune_boring_tools_after_recent_polling
      ~visible_tools ~recent_entries
  in
  Alcotest.(check (list string))
    "productive last tool does not hide boring tools"
    visible_tools pruned

let test_masc_board_list_is_boring () =
  Alcotest.(check bool) "masc_board_list is boring"
    true (Keeper_tool_registry.is_boring_tool "masc_board_list")

(** Build a minimal assistant message with ToolUse content blocks. *)
let assistant_msg_with_tools (tool_names : string list) : Agent_sdk.Types.message =
  let content =
    List.map
      (fun name ->
        Agent_sdk.Types.ToolUse { id = "id_" ^ name; name; input = `Assoc [] })
      tool_names
  in
  { role = Agent_sdk.Types.Assistant; content; name = None; tool_call_id = None }

let test_prune_boring_tools_from_messages_single_boring () =
  (* A single boring tool call should not trigger forced silence *)
  let messages = [ assistant_msg_with_tools [ "keeper_board_list" ] ] in
  let visible_tools =
    [ "masc_status"; "keeper_stay_silent"; "keeper_fs_edit"; "keeper_board_list" ]
  in
  let pruned =
    Keeper_tool_disclosure.prune_boring_tools_from_messages
      ~visible_tools ~messages ()
  in
  (* Single boring call prunes boring tools but keeps productive ones *)
  Alcotest.(check bool) "productive tools still visible"
    true (List.mem "keeper_fs_edit" pruned);
  Alcotest.(check bool) "keeper_stay_silent still visible"
    true (List.mem "keeper_stay_silent" pruned)

let test_prune_boring_tools_from_messages_consecutive_streak () =
  (* 3 consecutive boring-only turns should force keeper_stay_silent *)
  let messages = [
    assistant_msg_with_tools [ "keeper_board_list" ];
    assistant_msg_with_tools [ "masc_status" ];
    assistant_msg_with_tools [ "keeper_tasks_list" ];
  ] in
  let visible_tools =
    [ "masc_status"; "keeper_stay_silent"; "keeper_fs_edit";
      "keeper_board_list"; "keeper_tasks_list" ]
  in
  let pruned =
    Keeper_tool_disclosure.prune_boring_tools_from_messages
      ~visible_tools ~messages ()
  in
  Alcotest.(check (list string))
    "consecutive boring streak forces silence-only"
    [ "keeper_stay_silent" ] pruned

let test_prune_boring_tools_from_messages_mixed_breaks_streak () =
  (* A productive tool in the middle breaks the streak *)
  let messages = [
    assistant_msg_with_tools [ "keeper_board_list" ];
    assistant_msg_with_tools [ "keeper_fs_edit" ];
    assistant_msg_with_tools [ "masc_status" ];
  ] in
  let visible_tools =
    [ "masc_status"; "keeper_stay_silent"; "keeper_fs_edit";
      "keeper_board_list" ]
  in
  let pruned =
    Keeper_tool_disclosure.prune_boring_tools_from_messages
      ~visible_tools ~messages ()
  in
  (* Last tool is boring so single-call pruning fires, but streak is
     broken by keeper_fs_edit so forced-silence does NOT apply *)
  Alcotest.(check bool) "productive tools still visible after broken streak"
    true (List.mem "keeper_fs_edit" pruned);
  Alcotest.(check bool) "keeper_stay_silent visible"
    true (List.mem "keeper_stay_silent" pruned)

let test_prune_boring_tools_from_messages_no_history () =
  (* No messages: no pruning *)
  let visible_tools =
    [ "masc_status"; "keeper_stay_silent"; "keeper_fs_edit" ]
  in
  let pruned =
    Keeper_tool_disclosure.prune_boring_tools_from_messages
      ~visible_tools ~messages:[] ()
  in
  Alcotest.(check (list string))
    "no message history means no pruning"
    visible_tools pruned

let test_recent_tool_names_from_messages () =
  let messages = [
    assistant_msg_with_tools [ "keeper_board_list"; "keeper_fs_edit" ];
    { role = Agent_sdk.Types.User;
      content = [ Agent_sdk.Types.Text "hello" ];
      name = None; tool_call_id = None };
    assistant_msg_with_tools [ "masc_status" ];
  ] in
  let names =
    Keeper_tool_disclosure.recent_tool_names_from_messages ~max_messages:3 messages
  in
  Alcotest.(check (list string))
    "extracts tool names from assistant messages in order"
    [ "keeper_board_list"; "keeper_fs_edit"; "masc_status" ] names

let test_keeper_config_defaults () =
  (* Default: LLM rerank disabled *)
  Alcotest.(check bool) "llm_rerank disabled by default"
    false (Keeper_config.keeper_llm_rerank_enabled ());
  (* Default cascade name *)
  let cascade = Keeper_config.keeper_llm_rerank_cascade () in
  Alcotest.(check string) "default cascade name"
    "tool_rerank" cascade

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
      Alcotest.test_case "deterministic prefilter surfaces code tools" `Quick
        test_deterministic_prefilter_surfaces_code_tools;
      Alcotest.test_case "recent polling prunes boring tools" `Quick
        test_prune_boring_tools_after_recent_polling;
      Alcotest.test_case "productive last tool keeps boring tools visible" `Quick
        test_prune_boring_tools_keeps_set_when_last_tool_productive;
      Alcotest.test_case "masc_board_list is boring" `Quick
        test_masc_board_list_is_boring;
    ];
    "boring_tools_from_messages", [
      Alcotest.test_case "single boring call prunes but keeps productive" `Quick
        test_prune_boring_tools_from_messages_single_boring;
      Alcotest.test_case "consecutive boring streak forces silence" `Quick
        test_prune_boring_tools_from_messages_consecutive_streak;
      Alcotest.test_case "mixed history breaks streak" `Quick
        test_prune_boring_tools_from_messages_mixed_breaks_streak;
      Alcotest.test_case "no history means no pruning" `Quick
        test_prune_boring_tools_from_messages_no_history;
      Alcotest.test_case "recent_tool_names_from_messages extracts correctly" `Quick
        test_recent_tool_names_from_messages;
    ];
    "keeper_config", [
      Alcotest.test_case "config defaults" `Quick
        test_keeper_config_defaults;
    ];
  ]
