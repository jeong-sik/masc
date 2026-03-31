open Alcotest

module T = Agent_sdk.Types
module R = Agent_sdk.Context_reducer

(** Helper: create a text message with given role. *)
let msg role text : T.message =
  { T.role; content = [T.Text text]; name = None; tool_call_id = None }

(** Helper: create a User message. *)
let user text = msg T.User text

(** Helper: create an Assistant message. *)
let assistant text = msg T.Assistant text

(** Helper: create an Assistant message with a ToolUse block. *)
let assistant_tool_use ~id ~name ~input : T.message =
  { T.role = T.Assistant;
    content = [T.ToolUse { id; name; input }];
    name = None; tool_call_id = None }

(** Helper: create a Tool result message. *)
let tool_result ~tool_use_id ~content : T.message =
  { T.role = T.Tool;
    content = [T.ToolResult { tool_use_id; content; is_error = false }];
    name = None; tool_call_id = None }

(** Build N turns of User+Assistant pairs. *)
let make_turns n =
  List.init n (fun i ->
    [ user (Printf.sprintf "Task %d. Do the thing." (i + 1));
      assistant (Printf.sprintf "Done task %d." (i + 1)) ]
  ) |> List.concat

(** Build a turn with tool calls. *)
let make_tool_turn ~turn_idx ~tool_name =
  let id = Printf.sprintf "tool_%d" turn_idx in
  [ user (Printf.sprintf "Run %s for task %d." tool_name turn_idx);
    assistant_tool_use ~id ~name:tool_name ~input:`Null;
    tool_result ~tool_use_id:id ~content:"ok";
    assistant (Printf.sprintf "Completed %s." tool_name) ]

(* ================================================================ *)
(* Test: fold preserves recent turns                                 *)
(* ================================================================ *)

let test_fold_preserves_recent () =
  let msgs = make_turns 10 in
  let reducer = Masc_mcp.Keeper_compaction.fold_completed_strategy ~keep_recent:3 () in
  let result = R.reduce reducer msgs in
  (* 10 turns, keep 3 => 7 folded into 1 stub + 3 recent turns (2 msgs each) = 7 msgs *)
  let expected_count = 1 + (3 * 2) in
  check int "message count after fold" expected_count (List.length result);
  (* First message should be the fold stub *)
  let first = List.hd result in
  check bool "stub is User role" true (first.role = T.User);
  let stub_text = T.text_of_message first in
  check bool "stub contains [Folded:" true
    (String.length stub_text > 0
     && let prefix = "[Folded:" in
        String.length stub_text >= String.length prefix
        && String.sub stub_text 0 (String.length prefix) = prefix);
  check bool "stub contains turn count" true
    (let pat = "7 turns" in
     try let _ = Str.search_forward (Str.regexp_string pat) stub_text 0 in true
     with Not_found -> false);
  (* Last 3 turns should be intact *)
  let last_6 = List.filteri (fun i _ -> i >= 1) result in
  let task_8_text = T.text_of_message (List.nth last_6 0) in
  check bool "recent turn 8 preserved" true
    (try let _ = Str.search_forward (Str.regexp_string "Task 8") task_8_text 0 in true
     with Not_found -> false)

(* ================================================================ *)
(* Test: fold stub format (task/outcome/artifacts)                   *)
(* ================================================================ *)

let test_fold_stub_format () =
  let msgs =
    make_tool_turn ~turn_idx:1 ~tool_name:"bash"
    @ make_tool_turn ~turn_idx:2 ~tool_name:"bash"
    @ make_tool_turn ~turn_idx:3 ~tool_name:"read_file"
    @ [user "Final question."; assistant "Here is the answer."]
  in
  let reducer = Masc_mcp.Keeper_compaction.fold_completed_strategy ~keep_recent:1 () in
  let result = R.reduce reducer msgs in
  let stub = List.hd result in
  let stub_text = T.text_of_message stub in
  check bool "contains Outcome:" true
    (try let _ = Str.search_forward (Str.regexp_string "Outcome:") stub_text 0 in true
     with Not_found -> false);
  check bool "contains Artifacts:" true
    (try let _ = Str.search_forward (Str.regexp_string "Artifacts:") stub_text 0 in true
     with Not_found -> false);
  check bool "contains bash calls" true
    (try let _ = Str.search_forward (Str.regexp_string "bash(") stub_text 0 in true
     with Not_found -> false);
  check bool "contains read_file calls" true
    (try let _ = Str.search_forward (Str.regexp_string "read_file(") stub_text 0 in true
     with Not_found -> false);
  check bool "outcome is success" true
    (try let _ = Str.search_forward (Str.regexp_string "Outcome: success") stub_text 0 in true
     with Not_found -> false)

(* ================================================================ *)
(* Test: turn boundary invariant (ToolUse/ToolResult not split)      *)
(* ================================================================ *)

let test_turn_boundary_invariant () =
  (* A single turn with ToolUse+ToolResult should not be split *)
  let msgs =
    make_tool_turn ~turn_idx:1 ~tool_name:"bash"
    @ [user "Done."; assistant "All done."]
  in
  let reducer = Masc_mcp.Keeper_compaction.fold_completed_strategy ~keep_recent:1 () in
  let result = R.reduce reducer msgs in
  (* Turn 1 (4 msgs) folded into stub, turn 2 (2 msgs) preserved *)
  check int "message count" 3 (List.length result);
  (* Verify no orphan ToolUse or ToolResult in the output *)
  let has_orphan = List.exists (fun (m : T.message) ->
    let has_tool_use = List.exists (function T.ToolUse _ -> true | _ -> false) m.content in
    let has_tool_result = List.exists (function T.ToolResult _ -> true | _ -> false) m.content in
    (* Stub messages should not contain raw ToolUse/ToolResult *)
    m.role = T.User && (has_tool_use || has_tool_result)
  ) result in
  check bool "no orphan tool blocks in stubs" false has_orphan

(* ================================================================ *)
(* Test: empty messages not folded                                   *)
(* ================================================================ *)

let test_empty_not_folded () =
  let reducer = Masc_mcp.Keeper_compaction.fold_completed_strategy ~keep_recent:5 () in
  let result = R.reduce reducer [] in
  check int "empty input => empty output" 0 (List.length result)

(* ================================================================ *)
(* Test: all within keep_recent => no folding                        *)
(* ================================================================ *)

let test_all_within_keep_recent () =
  let msgs = make_turns 3 in
  let reducer = Masc_mcp.Keeper_compaction.fold_completed_strategy ~keep_recent:5 () in
  let result = R.reduce reducer msgs in
  check int "no folding when within budget" (List.length msgs) (List.length result);
  (* Messages should be identical *)
  List.iter2 (fun (orig : T.message) (res : T.message) ->
    check string "message text preserved"
      (T.text_of_message orig) (T.text_of_message res)
  ) msgs result

(* ================================================================ *)
(* Test: fold vs SummarizeOld — fold is more structured              *)
(* ================================================================ *)

let test_fold_vs_summarize_old () =
  let msgs =
    make_tool_turn ~turn_idx:1 ~tool_name:"bash"
    @ make_tool_turn ~turn_idx:2 ~tool_name:"read_file"
    @ [user "Wrap up."; assistant "All done."]
  in
  (* Fold result *)
  let fold_reducer = Masc_mcp.Keeper_compaction.fold_completed_strategy ~keep_recent:1 () in
  let fold_result = R.reduce fold_reducer msgs in
  let fold_stub_text = T.text_of_message (List.hd fold_result) in
  (* SummarizeOld result *)
  let summarize_result =
    Masc_mcp.Context_compact_oas.summarize_old_messages ~keep_recent:2 msgs
  in
  let summarize_first_text =
    match summarize_result with
    | m :: _ -> T.text_of_message m
    | [] -> ""
  in
  (* Fold stub should contain structured fields that SummarizeOld lacks *)
  let has_outcome s =
    try let _ = Str.search_forward (Str.regexp_string "Outcome:") s 0 in true
    with Not_found -> false
  in
  let has_artifacts s =
    try let _ = Str.search_forward (Str.regexp_string "Artifacts:") s 0 in true
    with Not_found -> false
  in
  check bool "fold has Outcome:" true (has_outcome fold_stub_text);
  check bool "fold has Artifacts:" true (has_artifacts fold_stub_text);
  check bool "summarize lacks Outcome:" false (has_outcome summarize_first_text);
  check bool "summarize lacks Artifacts:" false (has_artifacts summarize_first_text)

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

(* ================================================================ *)
(* Persona-aware compaction tests (#4318)                           *)
(* ================================================================ *)

let test_keywords_for_profile () =
  let safety_kw = Masc_mcp.Keeper_compaction.keywords_for_profile "safety" in
  check bool "safety has 'risk'" true (List.mem "risk" safety_kw);
  let research_kw = Masc_mcp.Keeper_compaction.keywords_for_profile "research" in
  check bool "research has 'hypothesis'" true (List.mem "hypothesis" research_kw);
  let relationship_kw = Masc_mcp.Keeper_compaction.keywords_for_profile "relationship" in
  check bool "relationship has 'trust'" true (List.mem "trust" relationship_kw);
  let delivery_kw = Masc_mcp.Keeper_compaction.keywords_for_profile "delivery" in
  check bool "delivery has 'blocker'" true (List.mem "blocker" delivery_kw);
  let unknown_kw = Masc_mcp.Keeper_compaction.keywords_for_profile "unknown_profile" in
  check int "unknown profile => empty" 0 (List.length unknown_kw)

let test_persona_stub_includes_excerpts () =
  let msgs =
    [ user "I noticed trust is building between us.";
      assistant "Yes, the rapport has improved.";
      user "Let's discuss style preferences.";
      assistant "Sure, what tone do you prefer?" ]
    @ make_turns 2
    @ [user "Final."; assistant "Done."]
  in
  let reducer = Masc_mcp.Keeper_compaction.persona_fold_strategy
    ~keep_recent:1 ~soul_profile:"relationship" () in
  let result = R.reduce reducer msgs in
  let stub = List.hd result in
  let stub_text = T.text_of_message stub in
  check bool "stub has Key context section" true
    (try let _ = Str.search_forward (Str.regexp_string "Key context:") stub_text 0 in true
     with Not_found -> false);
  check bool "stub mentions trust" true
    (try let _ = Str.search_forward (Str.regexp_string "trust") stub_text 0 in true
     with Not_found -> false)

let test_persona_stub_no_excerpts_generic () =
  let msgs = make_turns 5 @ [user "Final."; assistant "Done."] in
  let reducer = Masc_mcp.Keeper_compaction.persona_fold_strategy
    ~keep_recent:1 ~soul_profile:"relationship" () in
  let result = R.reduce reducer msgs in
  let stub = List.hd result in
  let stub_text = T.text_of_message stub in
  (* No keywords matched => no Key context section *)
  check bool "no Key context when no keywords match" false
    (try let _ = Str.search_forward (Str.regexp_string "Key context:") stub_text 0 in true
     with Not_found -> false)

let test_persona_fold_backward_compat () =
  (* persona fold with empty soul_profile behaves like original fold *)
  let msgs = make_turns 5 in
  let persona_reducer = Masc_mcp.Keeper_compaction.persona_fold_strategy
    ~keep_recent:3 ~soul_profile:"" () in
  let original_reducer = Masc_mcp.Keeper_compaction.fold_completed_strategy
    ~keep_recent:3 () in
  let persona_result = R.reduce persona_reducer msgs in
  let original_result = R.reduce original_reducer msgs in
  check int "same message count" (List.length original_result) (List.length persona_result);
  (* Stub text should be identical since empty profile yields no keywords *)
  let persona_stub = T.text_of_message (List.hd persona_result) in
  let original_stub = T.text_of_message (List.hd original_result) in
  check string "stub text identical" original_stub persona_stub

let test_persona_fold_keeps_recent_10 () =
  let msgs = make_turns 15 in
  let reducer = Masc_mcp.Keeper_compaction.persona_fold_strategy
    ~keep_recent:10 ~soul_profile:"delivery" () in
  let result = R.reduce reducer msgs in
  (* 15 turns, keep 10 => 5 folded into stub + 10 recent (2 msgs each) = 21 msgs *)
  check int "1 stub + 20 recent msgs" 21 (List.length result)

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  run "keeper_compaction"
    [
      ( "fold_completed",
        [
          test_case "preserves recent turns" `Quick test_fold_preserves_recent;
          test_case "stub contains task/outcome/artifacts" `Quick test_fold_stub_format;
          test_case "turn boundary invariant" `Quick test_turn_boundary_invariant;
          test_case "empty messages not folded" `Quick test_empty_not_folded;
          test_case "all within keep_recent" `Quick test_all_within_keep_recent;
          test_case "fold vs SummarizeOld comparison" `Quick test_fold_vs_summarize_old;
        ] );
      ( "persona_fold",
        [
          test_case "keywords_for_profile" `Quick test_keywords_for_profile;
          test_case "stub includes excerpts" `Quick test_persona_stub_includes_excerpts;
          test_case "no excerpts for generic turns" `Quick test_persona_stub_no_excerpts_generic;
          test_case "backward compat with empty profile" `Quick test_persona_fold_backward_compat;
          test_case "keeps recent 10" `Quick test_persona_fold_keeps_recent_10;
        ] );
    ]
