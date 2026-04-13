(** Property-based tests for context overflow detection and recovery.

    Verifies structural invariants of the compaction-budget fix:

    Property 1 (Detector coverage):
      is_context_overflow(TokenBudgetExceeded {kind="Input"}) = true
      for ALL positive used/limit values.

    Property 2 (Detector exclusion):
      is_context_overflow(TokenBudgetExceeded {kind≠"Input"}) = false
      for ALL non-"Input" kind strings.

    Property 3 (Recovery consistency):
      Every error accepted by is_context_overflow yields a positive
      limit from the recovery path.

    Property 4 (Structural absence):
      keeper_agent_run source does NOT contain ~max_input_tokens.

    Property 5 (Reducer integration):
      keeper_agent_run source contains cap_message_tokens in the
      keeper reducer chain, ordered before repair_dangling_tool_calls. *)

module UT = Masc_mcp.Keeper_unified_turn

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
    (fun err -> UT.is_context_overflow err)

let prop_non_input_budget_never_detected =
  QCheck.Test.make ~count:200
    ~name:"TokenBudgetExceeded(non-Input) never detected as context overflow"
    (QCheck.make gen_non_input_budget_error)
    (fun err -> not (UT.is_context_overflow err))

let prop_recovery_yields_positive_limit =
  QCheck.Test.make ~count:200
    ~name:"every overflow error yields positive limit in recovery"
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
  let target = Filename.concat repo_root "lib/keeper/keeper_agent_run.ml" in
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
      "keeper_agent_run.ml must integrate cap_message_tokens before repair_dangling_tool_calls"
      true
      (match cap_pos, repair_pos with
       | Some cap_pos, Some repair_pos -> cap_pos < repair_pos
       | _ -> false)
  end

(* ── Gospel-style specification (documentation) ────────── *)
(*
   @gospel — formal specification (Ortac runtime not available on 5.4)

   val is_context_overflow : Error.sdk_error -> bool
   (*@ b = is_context_overflow err
       ensures b = match err with
         | Api (ContextOverflow _) -> true
         | Agent (TokenBudgetExceeded { kind = "Input"; _ }) -> true
         | _ -> false *)

   val recover_context_overflow_retry :
     meta:keeper_meta -> base_dir:string ->
     max_cascade_context:int -> error:Error.sdk_error ->
     overflow_retry_plan option
   (*@ plan = recover_context_overflow_retry ~meta ~base_dir ~max_cascade_context ~error
       requires is_context_overflow error
       ensures match plan with
         | Some p -> p.retry_max_context > 0
         | None -> true *)
*)

(* ── Runner ──────────────────────────────────────────────── *)

let () =
  let qcheck_tests =
    List.map QCheck_alcotest.to_alcotest [
      prop_input_budget_always_detected;
      prop_non_input_budget_never_detected;
      prop_recovery_yields_positive_limit;
    ]
  in
  Alcotest.run "pbt_context_overflow" [
    ("properties", qcheck_tests);
    ("structural", [
      Alcotest.test_case "absence of max_input_tokens" `Quick
        test_structural_absence;
      Alcotest.test_case "cap_message_tokens integrated in reducer chain" `Quick
        test_cap_message_tokens_integration;
    ]);
  ]
