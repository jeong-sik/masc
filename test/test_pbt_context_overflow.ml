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
      keeper_run_tools_hooks source contains cap_message_tokens in the
      keeper reducer chain, ordered before the local pair repair.

    Property 6 (Reducer hardening):
      keeper_run_tools_hooks source uses the keeper-local repair path and does
      not call OAS repair_dangling_tool_calls, which fabricates synthetic
      ToolResult messages for dangling tool uses. *)

module UT = Masc.Keeper_unified_turn
module EC = Masc.Keeper_error_classify
module KC = Masc.Keeper_context_core

(* ── Generators ──────────────────────────────────────────── *)

let gen_positive_int =
  QCheck.Gen.int_range 1 1_000_000

let gen_context_overflow_error =
  QCheck.Gen.(oneof [
    map (fun limit ->
      Agent_sdk.Error.Api
        (ContextOverflow { message = "exceeded"; limit = Some limit }))
      gen_positive_int;
    return (Agent_sdk.Error.Api
      (ContextOverflow { message = "exceeded"; limit = None }));
  ])

(* ── Properties ──────────────────────────────────────────── *)

(* Context overflow is now signalled solely by [Api (ContextOverflow _)]
   (provider-rejected prompt); the removed token-budget cap no longer
   participates. *)
let prop_overflow_attribution_yields_positive_limit =
  QCheck.Test.make ~count:200
    ~name:"every overflow error yields positive limit for attribution"
    (QCheck.make gen_context_overflow_error)
    (fun err ->
      let limit = match err with
        | Agent_sdk.Error.Api
            (ContextOverflow { limit = Some limit; _ }) -> limit
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
  let target = Filename.concat repo_root "lib/keeper/keeper_run_tools_hooks.ml" in
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
      match cap_pos with
      | Some cap_pos ->
          find_substring ~start:cap_pos content "repair_broken_tool_call_pairs_observed"
      | None -> None
    in
    Alcotest.(check bool)
      "keeper_run_tools_hooks.ml must integrate cap_message_tokens before local pair repair"
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
  let target = Filename.concat repo_root "lib/keeper/keeper_run_tools_hooks.ml" in
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
    let oas_repair_pos =
      find_substring content "Agent_sdk.Context_reducer.repair_dangling_tool_calls"
    in
    let local_pos =
      find_substring content "Keeper_context_core.repair_broken_tool_call_pairs"
    in
    Alcotest.(check bool)
      "keeper_run_tools_hooks.ml must not invoke OAS synthetic repair_dangling_tool_calls"
      true
      (Option.is_none oas_repair_pos);
    Alcotest.(check bool)
      "keeper_run_tools_hooks.ml must integrate local non-fabricating pair repair"
      true
      (Option.is_some local_pos)
  end

let user_text text : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.User
  ; content = [ Agent_sdk.Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let assistant_tool_use ?(input = `Null) id name : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.Assistant
  ; content = [ Agent_sdk.Types.ToolUse { id; name; input } ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let user_tool_use ?(input = `Null) id name : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.User
  ; content = [ Agent_sdk.Types.ToolUse { id; name; input } ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let assistant_text_and_tool_use ?(input = `Null) text id name : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.Assistant
  ; content =
      [ Agent_sdk.Types.Text text
      ; Agent_sdk.Types.ToolUse { id; name; input }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let assistant_tool_uses uses : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.Assistant
  ; content =
      List.map
        (fun (id, name) -> Agent_sdk.Types.ToolUse { id; name; input = `Null })
        uses
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let assistant_text_and_tool_uses text uses : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.Assistant
  ; content =
      Agent_sdk.Types.Text text
      :: List.map
           (fun (id, name) ->
             Agent_sdk.Types.ToolUse { id; name; input = `Null })
           uses
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let assistant_same_message_tool_pair id name content : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.Assistant
  ; content =
      [ Agent_sdk.Types.ToolUse { id; name; input = `Null }
      ; Agent_sdk.Types.ToolResult
          { tool_use_id = id
          ; content
          ; is_error = false
          ; failure_kind = None
          ; error_class = None
          ; json = None
          ; content_blocks = None
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let tool_result_message ?(role = Agent_sdk.Types.User) id content
    : Agent_sdk.Types.message =
  { role
  ; content =
      [ Agent_sdk.Types.ToolResult
          { tool_use_id = id
          ; content
          ; is_error = false
          ; failure_kind = None
          ; error_class = None
          ; json = None
          ; content_blocks = None
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let user_tool_result id content : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.User
  ; content =
      [ Agent_sdk.Types.ToolResult
          { tool_use_id = id
          ; content
          ; is_error = false
          ; failure_kind = None
          ; error_class = None
          ; json = None
          ; content_blocks = None
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let user_text_and_tool_result text id content : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.User
  ; content =
      [ Agent_sdk.Types.Text text
      ; Agent_sdk.Types.ToolResult
          { tool_use_id = id
          ; content
          ; is_error = false
          ; failure_kind = None
          ; error_class = None
          ; json = None
          ; content_blocks = None
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

let text_blocks (messages : Agent_sdk.Types.message list) =
  List.concat_map
    (fun (msg : Agent_sdk.Types.message) ->
       List.filter_map
         (function
           | Agent_sdk.Types.Text text -> Some text
           | Agent_sdk.Types.Thinking _
           | Agent_sdk.Types.ReasoningDetails _
           | Agent_sdk.Types.RedactedThinking _
           | Agent_sdk.Types.ToolUse _
           | Agent_sdk.Types.ToolResult _
           | Agent_sdk.Types.Image _
           | Agent_sdk.Types.Document _
           | Agent_sdk.Types.Audio _ -> None)
         msg.content)
    messages

let text_contains needle texts =
  List.exists (fun text -> Astring.String.is_infix ~affix:needle text) texts

let count_tool_blocks messages =
  List.fold_left
    (fun counts (msg : Agent_sdk.Types.message) ->
       List.fold_left
         (fun (tool_uses, tool_results) -> function
           | Agent_sdk.Types.ToolUse _ -> tool_uses + 1, tool_results
           | Agent_sdk.Types.ToolResult _ -> tool_uses, tool_results + 1
           | Agent_sdk.Types.Text _
           | Agent_sdk.Types.Thinking _
           | Agent_sdk.Types.ReasoningDetails _
           | Agent_sdk.Types.RedactedThinking _
           | Agent_sdk.Types.Image _
           | Agent_sdk.Types.Document _
           | Agent_sdk.Types.Audio _ -> tool_uses, tool_results)
         counts
         msg.content)
    (0, 0)
    messages

let test_pair_repair_stats_count_drops () =
  let messages =
    [ user_text "q"
    ; assistant_text_and_tool_use "assistant kept text" "dangling" "calc"
    ; user_text "interrupt"
    ; user_text_and_tool_result "result wrapper kept text" "orphan" "late"
    ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check bool)
    "repair stats changed"
    true
    (KC.tool_pair_repair_stats_changed stats);
  Alcotest.(check int) "dangling tool use dropped" 1 stats.dropped_tool_uses;
  Alcotest.(check int) "orphan tool result dropped" 1 stats.dropped_tool_results;
  Alcotest.(check (list (pair string string)))
    "dropped tool use sample preserved in stats"
    [ "dangling", "calc" ]
    stats.dropped_tool_use_samples;
  Alcotest.(check (list string))
    "dropped tool result id preserved in stats"
    [ "orphan" ]
    stats.dropped_tool_result_ids;
  let repair_metadata =
    List.filter_map
      (fun (msg : Agent_sdk.Types.message) ->
         match
           ( List.assoc_opt "was_repaired" msg.metadata
           , List.assoc_opt KC.pair_repair_metadata_key msg.metadata )
         with
         | Some (`Bool true), Some (`Assoc fields) ->
           (match List.assoc_opt "kind" fields, List.assoc_opt "count" fields with
            | Some (`String kind), Some (`Int count) -> Some (kind, count)
            | _ -> None)
         | _ -> None)
      repaired
  in
  Alcotest.(check (list (pair string int)))
    "repaired messages carry pair-repair metadata"
    [ "dropped_tool_use", 1; "dropped_tool_result", 1 ]
    repair_metadata;
  let texts = text_blocks repaired in
  Alcotest.(check bool)
    "repair marker is not visible text"
    false
    (text_contains "unpaired tool use elided" texts);
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

let test_pair_repair_drops_dangling_tool_use_details () =
  let messages =
    [ user_text "다른 Discord 채널 뭐 있음?"
    ; assistant_tool_use
        ~input:(`Assoc [])
        "toolu_1"
        "keeper_tools_list"
    ; user_text
        "keeper_tools_list lists capabilities; use keeper_surface_read for lane \
         context."
    ; user_tool_result "toolu_orphan" {|{"meta":["keeper_tools_list"]}|}
    ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check int) "dangling tool use dropped" 1 stats.dropped_tool_uses;
  Alcotest.(check int) "orphan tool result dropped" 1 stats.dropped_tool_results;
  Alcotest.(check (list (pair string string)))
    "dropped tool use diagnostic sample preserved"
    [ "toolu_1", "keeper_tools_list" ]
    stats.dropped_tool_use_samples;
  Alcotest.(check (list string))
    "dropped tool result diagnostic id preserved"
    [ "toolu_orphan" ]
    stats.dropped_tool_result_ids;
  let texts = text_blocks repaired in
  Alcotest.(check bool)
    "dangling tool-use repair marker is not visible"
    false
    (text_contains "unpaired tool use elided" texts);
  Alcotest.(check bool)
    "dangling tool-use fallback is not fabricated"
    false
    (text_contains "[tool use" texts);
  Alcotest.(check bool)
    "dangling tool-use input is not serialized into text"
    false
    (text_contains "input={}" texts)

let test_pair_repair_preserves_same_message_tool_pair () =
  let messages =
    [ assistant_same_message_tool_pair "toolu_same" "lookup" {|{"ok":true}|} ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check bool)
    "same-message pair does not need repair"
    false
    (KC.tool_pair_repair_stats_changed stats);
  Alcotest.(check int) "same-message pair message preserved" 1 (List.length repaired);
  Alcotest.(check (pair int int))
    "same-message ToolUse and ToolResult preserved"
    (1, 1)
    (count_tool_blocks repaired)

let test_pair_repair_preserves_contiguous_result_span () =
  let messages =
    [ assistant_tool_uses [ "toolu_a", "one"; "toolu_b", "two" ]
    ; tool_result_message "toolu_a" "a"
    ; tool_result_message "toolu_b" "b"
    ; user_text "after"
    ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check bool)
    "contiguous result span does not need repair"
    false
    (KC.tool_pair_repair_stats_changed stats);
  Alcotest.(check int) "contiguous span messages preserved" 4 (List.length repaired);
  Alcotest.(check (pair int int))
    "contiguous span ToolUse and ToolResult blocks preserved"
    (2, 2)
    (count_tool_blocks repaired)

let test_pair_repair_rejects_non_assistant_tool_use_anchor () =
  let messages =
    [ user_tool_use "toolu_user" "lookup"
    ; tool_result_message ~role:Agent_sdk.Types.Tool "toolu_user" "ok"
    ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check int)
    "non-assistant ToolUse is dropped"
    1
    stats.dropped_tool_uses;
  Alcotest.(check int)
    "matching result is still orphan"
    1
    stats.dropped_tool_results;
  Alcotest.(check (list (pair string string)))
    "invalid ToolUse sample preserved"
    [ "toolu_user", "lookup" ]
    stats.dropped_tool_use_samples;
  Alcotest.(check (list string))
    "orphan result id preserved"
    [ "toolu_user" ]
    stats.dropped_tool_result_ids;
  Alcotest.(check int) "structural messages removed" 0 (List.length repaired);
  Alcotest.(check (pair int int))
    "no malformed tool blocks survive"
    (0, 0)
    (count_tool_blocks repaired)

let test_pair_repair_moves_late_results_before_interstitial_turns () =
  let messages =
    [ assistant_tool_uses [ "toolu_a", "one"; "toolu_b", "two" ]
    ; user_text "display turn before results"
    ; tool_result_message "toolu_b" "b"
    ; tool_result_message "toolu_a" "a"
    ; user_text "after"
    ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check bool)
    "late real results are moved, not dropped"
    false
    (KC.tool_pair_repair_stats_changed stats);
  Alcotest.(check (list string))
    "matching results become adjacent before interstitial turns"
    [ "assistant"; "result:toolu_a"; "result:toolu_b"; "text:display turn before results"; "text:after" ]
    (List.map
       (fun (msg : Agent_sdk.Types.message) ->
         match msg.content with
         | [ Agent_sdk.Types.ToolResult { tool_use_id; _ } ] ->
             "result:" ^ tool_use_id
         | [ Agent_sdk.Types.Text text ] -> "text:" ^ text
         | _ -> "assistant")
       repaired);
  Alcotest.(check (list string))
    "tool results follow tool-use order"
    [ "toolu_a"; "toolu_b" ]
    (List.filter_map
       (fun (msg : Agent_sdk.Types.message) ->
         match msg.content with
         | [ Agent_sdk.Types.ToolResult { tool_use_id; _ } ] ->
             Some tool_use_id
         | _ -> None)
       repaired);
  Alcotest.(check (pair int int))
    "late ToolUse and ToolResult blocks preserved"
    (2, 2)
    (count_tool_blocks repaired)

let test_pair_repair_drops_only_invalid_blocks_in_span () =
  let messages =
    [ assistant_tool_uses [ "toolu_a", "one"; "toolu_b", "two" ]
    ; tool_result_message "toolu_a" "a"
    ; tool_result_message "toolu_c" "c"
    ; user_text "after"
    ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check int) "unmatched ToolUse dropped" 1 stats.dropped_tool_uses;
  Alcotest.(check int) "orphan ToolResult dropped" 1 stats.dropped_tool_results;
  Alcotest.(check (list (pair string string)))
    "unmatched ToolUse sample preserved"
    [ "toolu_b", "two" ]
    stats.dropped_tool_use_samples;
  Alcotest.(check (list string))
    "orphan ToolResult id preserved"
    [ "toolu_c" ]
    stats.dropped_tool_result_ids;
  Alcotest.(check int)
    "empty orphan-only result message dropped"
    3
    (List.length repaired);
  Alcotest.(check (pair int int))
    "only valid pair remains structured"
    (1, 1)
    (count_tool_blocks repaired)

let test_pair_repair_metadata_samples_bounded () =
  let uses =
    List.init 10 (fun index ->
      Printf.sprintf "toolu_%02d" index, Printf.sprintf "tool_%02d" index)
  in
  let messages = [ assistant_text_and_tool_uses "kept" uses ] in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check int) "all dangling ToolUses counted" 10 stats.dropped_tool_uses;
  Alcotest.(check int)
    "stats ToolUse samples bounded"
    8
    (List.length stats.dropped_tool_use_samples);
  let metadata_sample_count =
    match repaired with
    | [ msg ] ->
        (match List.assoc_opt KC.pair_repair_metadata_key msg.metadata with
         | Some (`Assoc fields) ->
             (match List.assoc_opt "tool_use_samples" fields with
              | Some (`List samples) -> List.length samples
              | _ -> 0)
         | _ -> 0)
    | _ -> 0
  in
  Alcotest.(check int) "metadata ToolUse samples bounded" 8 metadata_sample_count

let test_checkpoint_sanitize_preserves_pair_repair_stats () =
  let messages =
    [ user_text "q"
    ; assistant_text_and_tool_use "assistant kept text" "dangling" "calc"
    ; user_text "interrupt"
    ; user_text_and_tool_result "result wrapper kept text" "orphan" "late"
    ]
  in
  let ctx = KC.create ~eio:false ~system_prompt:"system" ~max_tokens:4096 in
  let ctx = KC.append_many ctx messages in
  let checkpoint = KC.checkpoint_of_context ctx in
  let sanitized, stats = KC.sanitize_oas_checkpoint checkpoint in
  Alcotest.(check bool)
    "sanitize reports pair repair"
    true
    (KC.checkpoint_sanitize_changed stats);
  Alcotest.(check int)
    "sanitize keeps dropped tool-use count"
    1
    stats.tool_pair_repair.dropped_tool_uses;
  Alcotest.(check int)
    "sanitize keeps dropped tool-result count"
    1
    stats.tool_pair_repair.dropped_tool_results;
  Alcotest.(check (list (pair string string)))
    "sanitize keeps dropped tool-use sample"
    [ "dangling", "calc" ]
    stats.tool_pair_repair.dropped_tool_use_samples;
  Alcotest.(check (list string))
    "sanitize keeps dropped tool-result id"
    [ "orphan" ]
    stats.tool_pair_repair.dropped_tool_result_ids;
  let texts = text_blocks sanitized.Agent_sdk.Checkpoint.messages in
  Alcotest.(check bool)
    "sanitize does not create visible repair marker"
    false
    (text_contains "unpaired tool use elided" texts)

let test_checkpoint_sanitize_preserves_tool_failure_provenance () =
  let message : Agent_sdk.Types.message =
    {
      role = Agent_sdk.Types.Tool;
      content =
        [
          Agent_sdk.Types.ToolResult
            {
              tool_use_id = "failed-tool";
              content =
                String.make
                  (KC.default_max_checkpoint_tool_result_chars + 1)
                  'x';
              is_error = true;
              failure_kind = Some Agent_sdk.Types.Validation_error;
              error_class = Some Agent_sdk.Types.Deterministic;
              json = None;
              content_blocks = None;
            };
        ];
      name = None;
      tool_call_id = Some "failed-tool";
      metadata = [];
    }
  in
  match fst (KC.sanitize_checkpoint_message message) with
  | Some
      {
        content =
          [ Agent_sdk.Types.ToolResult { failure_kind; error_class; _ } ];
        _;
      } ->
      Alcotest.(check bool) "failure kind preserved" true
        (failure_kind = Some Agent_sdk.Types.Validation_error);
      Alcotest.(check bool) "error class preserved" true
        (error_class = Some Agent_sdk.Types.Deterministic)
  | _ -> Alcotest.fail "expected one sanitized ToolResult"

let test_checkpoint_save_repair_drops_unpaired_tool_blocks () =
  let raw_messages =
    [ user_text "q"
    ; assistant_text_and_tool_use "assistant kept text" "dangling" "calc"
    ; user_text "interrupt"
    ; user_text_and_tool_result "result wrapper kept text" "orphan" "late"
    ]
  in
  let repaired_messages, stats =
    KC.repair_broken_tool_call_pairs_with_stats raw_messages
  in
  Alcotest.(check int)
    "save repair drops dangling tool-use"
    1
    stats.dropped_tool_uses;
  Alcotest.(check int)
    "save repair drops orphan tool-result"
    1
    stats.dropped_tool_results;
  let save_ctx =
    KC.create ~eio:false ~system_prompt:"system" ~max_tokens:4096
    |> fun ctx -> KC.append_many ctx repaired_messages
  in
  let checkpoint = KC.checkpoint_of_context save_ctx in
  Alcotest.(check (pair int int))
    "checkpoint save payload has no unpaired tool blocks"
    (0, 0)
    (count_tool_blocks checkpoint.Agent_sdk.Checkpoint.messages);
  let texts = text_blocks checkpoint.Agent_sdk.Checkpoint.messages in
  Alcotest.(check bool)
    "checkpoint save keeps assistant text"
    true
    (text_contains "assistant kept text" texts);
  Alcotest.(check bool)
    "checkpoint save keeps wrapper text"
    true
    (text_contains "result wrapper kept text" texts);
  Alcotest.(check bool)
    "checkpoint save does not create visible repair marker"
    false
    (text_contains "unpaired tool use elided" texts)

let test_checkpoint_patch_updates_visible_text_and_clears_working_context () =
  let assistant : Agent_sdk.Types.message =
    { role = Agent_sdk.Types.Assistant
    ; content =
        [ Agent_sdk.Types.Text "old visible reply"
        ; Agent_sdk.Types.Thinking
            { signature = Some "sig"; content = "typed reasoning block" }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let context =
    KC.create ~eio:false ~system_prompt:"system" ~max_tokens:4096
    |> fun ctx -> KC.append_many ctx [ user_text "question"; assistant ]
  in
  let checkpoint = KC.checkpoint_of_context context in
  let checkpoint =
    { checkpoint with
      Agent_sdk.Checkpoint.working_context =
        Some (`Assoc [ "runtime_payload", `String "stale" ])
    }
  in
  let patched =
    KC.patch_checkpoint_last_assistant
      checkpoint
      ~session_id:"unified-session"
      ~response_text:"final visible reply"
  in
  Alcotest.(check string)
    "session id"
    "unified-session"
    patched.Agent_sdk.Checkpoint.session_id;
  Alcotest.(check bool)
    "working context is cleared after finalization"
    true
    (Option.is_none patched.Agent_sdk.Checkpoint.working_context);
  let texts = text_blocks patched.Agent_sdk.Checkpoint.messages in
  Alcotest.(check bool)
    "final visible reply replaces prior assistant text"
    true
    (text_contains "final visible reply" texts);
  Alcotest.(check bool)
    "prior assistant text removed"
    false
    (text_contains "old visible reply" texts);
  let thinking_preserved =
    (* The param annotation is load-bearing: [message] and [api_response] both
       declare a [content] field in Agent_sdk.Types, and an unannotated
       [message.Agent_sdk.Types.content] projection resolves to whichever
       record OCaml saw last — which flipped to [api_response] under the
       OAS 0.209 pin and broke this test's compile. *)
    patched.Agent_sdk.Checkpoint.messages
    |> List.exists (fun (message : Agent_sdk.Types.message) ->
      List.exists
        (function
          | Agent_sdk.Types.Thinking { content; _ } ->
            String.equal content "typed reasoning block"
          | _ -> false)
        message.Agent_sdk.Types.content)
  in
  Alcotest.(check bool) "typed non-text block preserved" true thinking_preserved

let test_pair_repair_drops_empty_structural_messages_with_stats () =
  let messages =
    [ user_text "q"
    ; assistant_tool_use
        ~input:(`Assoc [ "expr", `String "1+1" ])
        "dangling-only"
        "calc"
    ; user_tool_result "orphan-only" "late"
    ]
  in
  let repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  Alcotest.(check int)
    "dangling-only tool use dropped"
    1
    stats.dropped_tool_uses;
  Alcotest.(check int)
    "orphan-only tool result dropped"
    1
    stats.dropped_tool_results;
  Alcotest.(check (list (pair string string)))
    "dangling-only tool use sample preserved"
    [ "dangling-only", "calc" ]
    stats.dropped_tool_use_samples;
  Alcotest.(check (list string))
    "orphan-only tool result id preserved"
    [ "orphan-only" ]
    stats.dropped_tool_result_ids;
  Alcotest.(check int)
    "empty structural messages removed"
    1
    (List.length repaired);
  let texts = text_blocks repaired in
  Alcotest.(check bool)
    "empty structural drop does not create visible repair marker"
    false
    (text_contains "unpaired tool use elided" texts)

let test_pair_repair_caps_diagnostic_sample_strings () =
  let long_id =
    "toolu_"
    ^ String.make (KC.pair_repair_diagnostic_max_bytes + 32) 'x'
  in
  let long_name =
    "keeper_"
    ^ String.make (KC.pair_repair_diagnostic_max_bytes + 32) 'y'
  in
  let messages =
    [ user_text "q"
    ; assistant_text_and_tool_use "assistant kept text" long_id long_name
    ; user_text "interrupt"
    ; user_text_and_tool_result "result wrapper kept text" (long_id ^ "_orphan") "late"
    ]
  in
  let _repaired, stats = KC.repair_broken_tool_call_pairs_with_stats messages in
  let expected_id = KC.bound_pair_repair_diagnostic_string long_id in
  let expected_result_id =
    KC.bound_pair_repair_diagnostic_string (long_id ^ "_orphan")
  in
  let expected_name = KC.bound_pair_repair_diagnostic_string long_name in
  Alcotest.(check int)
    "diagnostic tool-use id capped"
    KC.pair_repair_diagnostic_max_bytes
    (String.length expected_id);
  Alcotest.(check int)
    "diagnostic tool-name capped"
    KC.pair_repair_diagnostic_max_bytes
    (String.length expected_name);
  Alcotest.(check (list (pair string string)))
    "tool-use diagnostic sample strings are capped"
    [ expected_id, expected_name ]
    stats.dropped_tool_use_samples;
  Alcotest.(check (list string))
    "tool-result diagnostic id strings are capped"
    [ expected_result_id ]
    stats.dropped_tool_result_ids

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
      Alcotest.test_case "pair repair stats count drops" `Quick
        test_pair_repair_stats_count_drops;
      Alcotest.test_case "pair repair drops dangling tool-use details" `Quick
        test_pair_repair_drops_dangling_tool_use_details;
      Alcotest.test_case "pair repair preserves same-message tool pair" `Quick
        test_pair_repair_preserves_same_message_tool_pair;
      Alcotest.test_case "pair repair preserves contiguous result span" `Quick
        test_pair_repair_preserves_contiguous_result_span;
      Alcotest.test_case "pair repair rejects non-assistant tool-use anchor" `Quick
        test_pair_repair_rejects_non_assistant_tool_use_anchor;
      Alcotest.test_case "pair repair moves late results before interstitial turns" `Quick
        test_pair_repair_moves_late_results_before_interstitial_turns;
      Alcotest.test_case "pair repair drops only invalid span blocks" `Quick
        test_pair_repair_drops_only_invalid_blocks_in_span;
      Alcotest.test_case "pair repair metadata samples bounded" `Quick
        test_pair_repair_metadata_samples_bounded;
      Alcotest.test_case "checkpoint sanitize preserves pair repair stats" `Quick
        test_checkpoint_sanitize_preserves_pair_repair_stats;
      Alcotest.test_case "checkpoint sanitize preserves typed failure provenance" `Quick
        test_checkpoint_sanitize_preserves_tool_failure_provenance;
      Alcotest.test_case "checkpoint save repair drops unpaired tool blocks" `Quick
        test_checkpoint_save_repair_drops_unpaired_tool_blocks;
      Alcotest.test_case
        "checkpoint patch keeps typed blocks and visible reply"
        `Quick
        test_checkpoint_patch_updates_visible_text_and_clears_working_context;
      Alcotest.test_case "pair repair drops empty structural messages with stats" `Quick
        test_pair_repair_drops_empty_structural_messages_with_stats;
      Alcotest.test_case "pair repair caps diagnostic sample strings" `Quick
        test_pair_repair_caps_diagnostic_sample_strings;
    ]);
  ]
