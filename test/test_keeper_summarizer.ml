(** Verify keeper_summarizer scrubs [STATE] blocks before summarization.

    Gen4 closure of the compaction-layer resonance. Gen3 (PR #7647) closed
    the prompt-injection layer; this test guards the OAS
    Budget_strategy.reduce_for_budget Emergency-phase compaction, which
    uses the summarizer injected via Builder.with_summarizer. *)

module KS = Masc_mcp.Keeper_summarizer

let msg ~role ~text : Agent_sdk.Types.message =
  { role
  ; content = [ Agent_sdk.Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let test_scrub_text_blocks_removes_state () =
  let input =
    msg
      ~role:Agent_sdk.Types.Assistant
      ~text:
        "Some reasoning.\n\
         [STATE]\n\
         DONE: 5.6B+ ep verified\n\
         NEXT: idle\n\
         [/STATE]\n\
         more text"
  in
  let scrubbed = KS.scrub_text_blocks input in
  let text =
    match scrubbed.content with
    | [ Agent_sdk.Types.Text s ] -> s
    | _ -> Alcotest.fail "expected single Text block"
  in
  Alcotest.(check bool)
    "[STATE] marker removed"
    false
    (Astring.String.is_infix ~affix:"[STATE]" text);
  Alcotest.(check bool)
    "DONE: removed"
    false
    (Astring.String.is_infix ~affix:"DONE:" text);
  Alcotest.(check bool)
    "surrounding prose preserved"
    true
    (Astring.String.is_infix ~affix:"Some reasoning." text);
  Alcotest.(check bool)
    "post-block prose preserved"
    true
    (Astring.String.is_infix ~affix:"more text" text)
;;

let test_summarizer_strips_state () =
  let messages =
    [ msg ~role:Agent_sdk.Types.User ~text:"please verify"
    ; msg
        ~role:Agent_sdk.Types.Assistant
        ~text:"[STATE]\nDONE: 5.6B+ ep verified across 30 episodes\n[/STATE]"
    ]
  in
  let summary = KS.keeper_summarizer messages in
  Alcotest.(check bool)
    "summary omits [STATE]"
    false
    (Astring.String.is_infix ~affix:"[STATE]" summary);
  Alcotest.(check bool)
    "summary omits DONE: 5.6B"
    false
    (Astring.String.is_infix ~affix:"DONE: 5.6B" summary);
  Alcotest.(check bool)
    "summary contains user fragment"
    true
    (Astring.String.is_infix ~affix:"please verify" summary)
;;

let test_non_text_blocks_untouched () =
  let tool_use : Agent_sdk.Types.content_block =
    Agent_sdk.Types.ToolUse
      { id = "t1"; name = "bash"; input = `Assoc [ "cmd", `String "ls" ] }
  in
  let m : Agent_sdk.Types.message =
    { role = Agent_sdk.Types.Assistant
    ; content = [ Agent_sdk.Types.Text "[STATE]\nDONE\n[/STATE]"; tool_use ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let scrubbed = KS.scrub_text_blocks m in
  let has_tool_use =
    List.exists
      (function
        | Agent_sdk.Types.ToolUse _ -> true
        | _ -> false)
      scrubbed.content
  in
  Alcotest.(check bool) "ToolUse block preserved" true has_tool_use
;;

let test_empty_messages () =
  let summary = KS.keeper_summarizer [] in
  Alcotest.(check string) "empty → No prior context marker" "[No prior context]" summary
;;

let () =
  Alcotest.run
    "keeper_summarizer"
    [ ( "scrub + summarize"
      , [ Alcotest.test_case
            "scrub_text_blocks removes [STATE]"
            `Quick
            test_scrub_text_blocks_removes_state
        ; Alcotest.test_case
            "keeper_summarizer output omits [STATE]"
            `Quick
            test_summarizer_strips_state
        ; Alcotest.test_case
            "non-Text blocks preserved"
            `Quick
            test_non_text_blocks_untouched
        ; Alcotest.test_case "empty messages" `Quick test_empty_messages
        ] )
    ]
;;
