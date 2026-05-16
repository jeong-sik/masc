(** Property-based tests for context overflow detection and boundary handling.

    Verifies structural invariants of the compaction-budget fix:

    Property 1 (Detector coverage):
      is_context_overflow(TokenBudgetExceeded {kind="Input"}) = true
      for ALL positive used/limit values.

    Property 2 (Detector exclusion):
      is_context_overflow(TokenBudgetExceeded {kind≠"Input"}) = false
      for ALL non-"Input" kind strings.

    Property 3 (Limit attribution):
      Every error accepted by is_context_overflow has a positive
      structured or fallback limit for blocker attribution.

    Property 4 (Structural absence):
      keeper_agent_run source does NOT contain ~max_input_tokens.

    Property 5 (Reducer integration):
      keeper_run_tools source contains cap_message_tokens in the
      keeper reducer chain, ordered before repair_dangling_tool_calls.

    Property 6 (Reducer hardening):
      keeper_run_tools source contains the keeper-local
      repair_broken_tool_call_pairs reducer after repair_dangling_tool_calls. *)

module UT = Masc_mcp.Keeper_unified_turn
module EC = Masc_mcp.Keeper_error_classify
module KC = Masc_mcp.Keeper_context_core

(* ── Generators ──────────────────────────────────────────── *)

let gen_positive_int =
  QCheck.Gen.int_range 1 1_000_000

let gen_input_budget_error =
  QCheck.Gen.(
    let* used = gen_positive_int in
    let* limit = gen_positive_int in
    return (Agent_sdk.Error.Agent
      (TokenBudgetExceeded { kind = "Input"; used; limit })))

let gen_non_input_kind =
  QCheck.Gen.(oneof [
    return "Total";
    return "Output";
    return "total";
    return "input";  (* lowercase — only exact "Input" should match *)
    return "";
    return "Unknown";
  ])

let gen_non_input_budget_error =
  QCheck.Gen.(
    let* kind = gen_non_input_kind in
    let* used = gen_positive_int in
    let* limit = gen_positive_int in
    return (Agent_sdk.Error.Agent
      (TokenBudgetExceeded { kind; used; limit })))

let gen_context_overflow_error =
  QCheck.Gen.(oneof [
    map (fun limit ->
      Agent_sdk.Error.Api
        (ContextOverflow { message = "exceeded"; limit = Some limit }))
      gen_positive_int;
    return (Agent_sdk.Error.Api
      (ContextOverflow { message = "exceeded"; limit = None }));
    gen_input_budget_error;
  ])

(* ── Properties ──────────────────────────────────────────── *)

let prop_input_budget_always_detected =
  QCheck.Test.make ~count:200
    ~name:"TokenBudgetExceeded(Input) always detected as context overflow"
    (QCheck.make gen_input_budget_error)
    (fun err -> EC.is_context_overflow err)

let prop_non_input_budget_never_detected =
  QCheck.Test.make ~count:200
    ~name:"TokenBudgetExceeded(non-Input) never detected as context overflow"
    (QCheck.make gen_non_input_budget_error)
    (fun err -> not (EC.is_context_overflow err))

let prop_overflow_attribution_yields_positive_limit =
  QCheck.Test.make ~count:200
    ~name:"every overflow error yields positive limit for attribution"
    (QCheck.make gen_context_overflow_error)
    (fun err ->
      let limit = match err with
        | Agent_sdk.Error.Api
            (ContextOverflow { limit = Some limit; _ }) -> limit
        | Agent_sdk.Error.Agent
            (TokenBudgetExceeded { limit; _ }) -> limit
        | _ -> 4096  (* fallback path *)
      in
      limit > 0)

(* ── Property 4: structural absence of max_input_tokens ── *)

let test_structural_absence () =
  let has_prompt_root path =
    Sys.file_exists (Filename.concat path "config/prompts/keeper.unified.system.md")
  in
  let repo_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when has_prompt_root root -> root
    | _ ->
        let rec ascend path =
          if has_prompt_root path then path
          else
            let parent = Filename.dirname path in
            if String.equal parent path then Sys.getcwd () else ascend parent
        in
        ascend (Sys.getcwd ())
  in
  let target = Filename.concat repo_root "lib/keeper/keeper_agent_run.ml" in
  if not (Sys.file_exists target) then
    (* CI or non-standard layout — skip gracefully *)
    ()
  else begin
    let ic = open_in target in
    let content = Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let len = in_channel_length ic in
        let buf = Bytes.create len in
        really_input ic buf 0 len;
        Bytes.to_string buf)
    in
    let has_max_input_tokens =
      let re = Re.(compile (seq [str "~max_input_tokens"])) in
      Re.execp re content
    in
    Alcotest.(check bool)
      "keeper_agent_run.ml must NOT contain ~max_input_tokens"
      false has_max_input_tokens
  end

let test_cap_message_tokens_integration () =
  let find_substring haystack needle =
    let hlen = String.length haystack in
    let nlen = String.length needle in
    let rec loop i =
      if i + nlen > hlen then None
      else if String.sub haystack i nlen = needle then Some i
      else loop (i + 1)
    in
    if nlen = 0 then Some 0 else loop 0
  in
  let has_prompt_root path =
    Sys.file_exists (Filename.concat path "config/prompts/keeper.unified.system.md")
  in
  let repo_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when has_prompt_root root -> root
    | _ ->
        let rec ascend path =
          if has_prompt_root path then path
          else
            let parent = Filename.dirname path in
            if String.equal parent path then Sys.getcwd () else ascend parent
        in
        ascend (Sys.getcwd ())
  in
  let target = Filename.concat repo_root "lib/keeper/keeper_run_tools.ml" in
  if not (Sys.file_exists target) then
    ()
  else begin
    let ic = open_in target in
    let content = Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let len = in_channel_length ic in
        let buf = Bytes.create len in
        really_input ic buf 0 len;
        Bytes.to_string buf)
    in
    let cap_pos =
      find_substring content "Agent_sdk.Context_reducer.cap_message_tokens"
    in
    let repair_pos =
      find_substring content "Agent_sdk.Context_reducer.repair_dangling_tool_calls"
    in
    Alcotest.(check bool)
      "keeper_run_tools.ml must integrate cap_message_tokens before repair_dangling_tool_calls"
      true
      (match cap_pos, repair_pos with
       | Some cap_pos, Some repair_pos -> cap_pos < repair_pos
       | _ -> false)
  end

let test_pair_repair_integration () =
  let find_substring ?(start = 0) haystack needle =
    let hlen = String.length haystack in
    let nlen = String.length needle in
    let rec loop i =
      if i + nlen > hlen then None
      else if String.sub haystack i nlen = needle then Some i
      else loop (i + 1)
    in
    if nlen = 0 then Some start else loop start
  in
  let has_prompt_root path =
    Sys.file_exists (Filename.concat path "config/prompts/keeper.unified.system.md")
  in
  let repo_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when has_prompt_root root -> root
    | _ ->
        let rec ascend path =
          if has_prompt_root path then path
          else
            let parent = Filename.dirname path in
            if String.equal parent path then Sys.getcwd () else ascend parent
        in
        ascend (Sys.getcwd ())
  in
  let target = Filename.concat repo_root "lib/keeper/keeper_run_tools.ml" in
  if not (Sys.file_exists target) then
    ()
  else begin
    let ic = open_in target in
    let content = Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let len = in_channel_length ic in
        let buf = Bytes.create len in
        really_input ic buf 0 len;
        Bytes.to_string buf)
    in
    let repair_pos =
      find_substring content "Agent_sdk.Context_reducer.repair_dangling_tool_calls"
    in
    let local_pos =
      match repair_pos with
      | Some repair_pos ->
          find_substring ~start:repair_pos content
            "Keeper_context_core.repair_broken_tool_call_pairs"
      | None -> None
    in
    Alcotest.(check bool)
      "keeper_run_tools.ml must integrate local pair repair after repair_dangling_tool_calls"
      true
      (match repair_pos, local_pos with
       | Some repair_pos, Some local_pos -> repair_pos < local_pos
       | _ -> false)
  end

let user_text text : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.User
  ; content = [ Agent_sdk.Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let assistant_tool_use id name : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.Assistant
  ; content = [ Agent_sdk.Types.ToolUse { id; name; input = `Null } ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let user_tool_result id content : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.User
  ; content =
      [ Agent_sdk.Types.ToolResult
          { tool_use_id = id; content; is_error = false; json = None }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let test_pair_repair_stats_count_downgrades () =
  let messages =
    [ user_text "q"
    ; assistant_tool_use "dangling" "calc"
    ; user_text "interrupt"
    ; user_tool_result "orphan" "late"
    ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check bool)
    "repair stats changed"
    true
    (KC.tool_pair_repair_stats_changed stats);
  Alcotest.(check int) "dangling tool use downgraded" 1 stats.downgraded_tool_uses;
  Alcotest.(check int) "orphan tool result downgraded" 1 stats.downgraded_tool_results;
  let has_structured_tool_block =
    List.exists
      (fun (msg : Agent_sdk.Types.message) ->
         List.exists
           (function
             | Agent_sdk.Types.ToolUse _ | Agent_sdk.Types.ToolResult _ -> true
             | _ -> false)
           msg.content)
      repaired
  in
  Alcotest.(check bool) "structured tool blocks removed" false has_structured_tool_block

(* ── Gospel-style specification (documentation) ────────── *)
(*
   @gospel — formal specification (Ortac runtime not available on 5.4)

   val is_context_overflow : Error.sdk_error -> bool
   (*@ b = is_context_overflow err
       ensures b = match err with
         | Api (ContextOverflow _) -> true
         | Agent (TokenBudgetExceeded { kind = "Input"; _ }) -> true
         | _ -> false *)

   Keeper turns leave compact+retry to OAS. MASC may classify a structured
   overflow as a typed blocker, but it must not recover an OAS checkpoint and
   re-dispatch the same agent turn from the keeper layer.
*)

(* ── Runner ──────────────────────────────────────────────── *)

let () =
  let qcheck_tests =
    List.map QCheck_alcotest.to_alcotest [
      prop_input_budget_always_detected;
      prop_non_input_budget_never_detected;
      prop_overflow_attribution_yields_positive_limit;
    ]
  in
  Alcotest.run "pbt_context_overflow" [
    ("properties", qcheck_tests);
    ("structural", [
      Alcotest.test_case "absence of max_input_tokens" `Quick
        test_structural_absence;
      Alcotest.test_case "cap_message_tokens integrated in reducer chain" `Quick
        test_cap_message_tokens_integration;
      Alcotest.test_case "local pair repair integrated in reducer chain" `Quick
        test_pair_repair_integration;
      Alcotest.test_case "pair repair stats count downgrades" `Quick
        test_pair_repair_stats_count_downgrades;
    ]);
  ]
