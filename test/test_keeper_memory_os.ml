(** Unit tests for the Keeper Memory OS types, librarian, and policy. *)

module Types = Masc.Keeper_memory_os_types
module Policy = Masc.Keeper_memory_os_policy
module Librarian = Masc.Keeper_librarian

let contains substring s =
  let sub_len = String.length substring in
  let str_len = String.length s in
  let rec aux i =
    if i + sub_len > str_len
    then false
    else if String.sub s i sub_len = substring
    then true
    else aux (i + 1)
  in
  if sub_len = 0 then true else aux 0
;;

let index_of substring s =
  let sub_len = String.length substring in
  let str_len = String.length s in
  let rec aux i =
    if i + sub_len > str_len
    then None
    else if String.sub s i sub_len = substring
    then Some i
    else aux (i + 1)
  in
  if sub_len = 0 then Some 0 else aux 0
;;

let fact_fixture ~now () =
  { Types.claim = "User prefers concise responses"
  ; Types.confidence = 0.9
  ; Types.category = "preference"
  ; Types.source = { Types.trace_id = "trace-123"; Types.turn = 5; Types.tool_call_id = None }
  ; Types.access_count = 2
  ; Types.first_seen = now -. 86400.0
  ; Types.last_accessed = now -. 3600.0
  ; Types.valid_until = None
  ; Types.schema_version = Types.schema_version
  }
;;

let test_json_roundtrip () =
  let now = 1_000_000.0 in
  let f = fact_fixture ~now () in
  let f2 = Option.get (Types.fact_of_json (Types.fact_to_json f)) in
  Alcotest.(check string) "claim round-trip" f.claim f2.Types.claim;
  Alcotest.(check (float 0.001)) "confidence round-trip" f.confidence f2.Types.confidence;
  Alcotest.(check int) "access_count round-trip" f.access_count f2.Types.access_count;
  Alcotest.(check (float 0.001)) "first_seen round-trip" f.first_seen f2.Types.first_seen;
  let e =
    { Types.trace_id = "trace-123"
    ; Types.generation = 1
    ; Types.episode_summary = "A short summary of the turn."
    ; Types.claims = [ f ]
    ; Types.open_items = [ "item1" ]
    ; Types.constraints = [ "c1" ]
    ; Types.preserved_tool_refs = [ "call_a" ]
    ; Types.source_turn_range = Some (5, 5)
    ; Types.created_at = now
    ; Types.schema_version = Types.schema_version
    }
  in
  let e2 = Option.get (Types.episode_of_json (Types.episode_to_json e)) in
  Alcotest.(check string)
    "episode summary round-trip"
    e.episode_summary
    e2.Types.episode_summary;
  Alcotest.(check int) "claims length" 1 (List.length e2.Types.claims);
  Alcotest.(check int) "open_items length" 1 (List.length e2.Types.open_items)
;;

let test_prompt_renders () =
  let msg : Agent_sdk.Types.message =
    { role = Agent_sdk.Types.User
    ; content = [ Agent_sdk.Types.Text "Please remember the project constraint." ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let inp : Librarian.input =
    { Librarian.trace_id = "trace-abc"
    ; Librarian.generation = 0
    ; Librarian.messages = [ msg ]
    }
  in
  let prompt = Librarian.prompt_of_input inp in
  Alcotest.(check bool)
    "contains episode_summary"
    true
    (contains "episode_summary" prompt);
  Alcotest.(check bool) "contains claims array" true (contains "\"claims\"" prompt);
  Alcotest.(check bool)
    "contains preserved_tool_refs"
    true
    (contains "preserved_tool_refs" prompt);
  Alcotest.(check bool) "placeholder replaced" false (contains "%s" prompt);
  Alcotest.(check bool)
    "contains conversation"
    true
    (contains "[user] Please remember the project constraint." prompt);
  match
    index_of "[user] Please remember the project constraint." prompt,
    index_of "Respond with ONLY the JSON object." prompt
  with
  | Some conversation_at, Some respond_at ->
    Alcotest.(check bool) "conversation before final instruction" true (conversation_at < respond_at)
  | _ -> Alcotest.fail "expected prompt sections"
;;

let test_prompt_omits_private_blocks () =
  let msg : Agent_sdk.Types.message =
    { role = Agent_sdk.Types.Assistant
    ; content =
        [ Agent_sdk.Types.Text "visible fact"
        ; Agent_sdk.Types.Thinking
            { thinking_type = "reasoning"; content = "hidden chain of thought" }
        ; Agent_sdk.Types.RedactedThinking "redacted reasoning blob"
        ; Agent_sdk.Types.ToolResult
            { tool_use_id = "call_1"
            ; content = "secret tool payload"
            ; is_error = false
            ; json = None
            ; content_blocks = None
            }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let inp : Librarian.input =
    { Librarian.trace_id = "trace-abc"
    ; Librarian.generation = 0
    ; Librarian.messages = [ msg ]
    }
  in
  let prompt = Librarian.prompt_of_input inp in
  Alcotest.(check bool) "keeps visible text" true (contains "visible fact" prompt);
  Alcotest.(check bool)
    "omits thinking content"
    false
    (contains "hidden chain of thought" prompt);
  Alcotest.(check bool)
    "omits redacted thinking"
    false
    (contains "redacted reasoning blob" prompt);
  Alcotest.(check bool)
    "omits tool payload"
    false
    (contains "secret tool payload" prompt);
  Alcotest.(check bool)
    "keeps tool provenance"
    true
    (contains "[tool result omitted: id=call_1 is_error=false]" prompt)
;;

let test_policy_score_and_retention () =
  let now = 1_000_000.0 in
  let f = fact_fixture ~now () in
  let score = Policy.score_fact ~now f in
  Alcotest.(check bool) "score positive" true (score > 0.0);
  let verdict = Policy.decide_retention score in
  Alcotest.(check bool) "high score -> KeepVerbatim" true (verdict = Policy.KeepVerbatim);
  let low =
    { f with
      Types.confidence = 0.1
    ; Types.access_count = 0
    ; Types.last_accessed = now -. 864_000.0
    }
  in
  let verdict_low = Policy.decide_retention (Policy.score_fact ~now low) in
  Alcotest.(check bool) "low score -> Discard" true (verdict_low = Policy.Discard)
;;

let test_bump_access () =
  let now = 1_000_000.0 in
  let f = fact_fixture ~now () in
  let bumped = Policy.bump_access_for_turn ~now [ f ] ~turn_text:"User prefers concise" in
  (match bumped with
   | [ got ] -> Alcotest.(check int) "access bumped" 3 got.Types.access_count
   | _ -> Alcotest.fail "expected one bumped fact");
  let not_bumped =
    Policy.bump_access_for_turn ~now [ f ] ~turn_text:"completely unrelated"
  in
  match not_bumped with
  | [ got ] -> Alcotest.(check int) "access unchanged" 2 got.Types.access_count
  | _ -> Alcotest.fail "expected one unchanged fact"
;;

let () =
  Alcotest.run
    "keeper_memory_os"
    [ ( "json"
      , [ Alcotest.test_case "fact and episode round-trip" `Quick test_json_roundtrip
        ; Alcotest.test_case "prompt renders schema" `Quick test_prompt_renders
        ; Alcotest.test_case
            "prompt omits private blocks"
            `Quick
            test_prompt_omits_private_blocks
        ] )
    ; ( "policy"
      , [ Alcotest.test_case "score and retention" `Quick test_policy_score_and_retention
        ; Alcotest.test_case "bump access" `Quick test_bump_access
        ] )
    ]
;;
