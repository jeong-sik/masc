(** Verify keeper_summarizer scrubs [STATE] blocks before summarization.

    Gen4 closure of the compaction-layer resonance. Gen3 (PR #7647) closed
    the prompt-injection layer; this test guards the OAS
    Budget_strategy.reduce_for_budget Emergency-phase compaction, which
    uses the summarizer injected via Builder.with_summarizer. *)

module KS = Masc_mcp.Keeper_summarizer

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let repo_root () =
  let marker path = Filename.concat path "lib/keeper/keeper_agent_run.ml" in
  let has_marker path = Sys.file_exists (marker path) in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_marker root -> root
  | _ ->
      let rec ascend path =
        if has_marker path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then path else ascend parent
      in
      ascend (Sys.getcwd ())

let msg ~role ~text : Agent_sdk.Types.message =
  { role; content = [ Agent_sdk.Types.Text text ]; name = None; tool_call_id = None; metadata = [] }

let test_scrub_text_blocks_removes_state () =
  let input =
    msg ~role:Agent_sdk.Types.Assistant
      ~text:"Some reasoning.\n[STATE]\nDONE: 5.6B+ ep verified\nNEXT: idle\n[/STATE]\nmore text"
  in
  let scrubbed = KS.scrub_text_blocks input in
  let text =
    match scrubbed.content with
    | [ Agent_sdk.Types.Text s ] -> s
    | _ -> Alcotest.fail "expected single Text block"
  in
  Alcotest.(check bool) "[STATE] marker removed"
    false (Astring.String.is_infix ~affix:"[STATE]" text);
  Alcotest.(check bool) "DONE: removed"
    false (Astring.String.is_infix ~affix:"DONE:" text);
  Alcotest.(check bool) "surrounding prose preserved"
    true (Astring.String.is_infix ~affix:"Some reasoning." text);
  Alcotest.(check bool) "post-block prose preserved"
    true (Astring.String.is_infix ~affix:"more text" text)

let test_summarizer_strips_state () =
  let messages =
    [ msg ~role:Agent_sdk.Types.User ~text:"please verify";
      msg ~role:Agent_sdk.Types.Assistant
        ~text:"[STATE]\nDONE: 5.6B+ ep verified across 30 episodes\n[/STATE]";
    ]
  in
  let summary = KS.keeper_summarizer messages in
  Alcotest.(check bool) "summary omits [STATE]"
    false (Astring.String.is_infix ~affix:"[STATE]" summary);
  Alcotest.(check bool) "summary omits DONE: 5.6B"
    false (Astring.String.is_infix ~affix:"DONE: 5.6B" summary);
  Alcotest.(check bool) "summary contains user fragment"
    true (Astring.String.is_infix ~affix:"please verify" summary)

let test_non_text_blocks_untouched () =
  let tool_use : Agent_sdk.Types.content_block =
    Agent_sdk.Types.ToolUse
      { id = "t1"; name = "bash"; input = `Assoc [ ("cmd", `String "ls") ] }
  in
  let m : Agent_sdk.Types.message =
    { role = Agent_sdk.Types.Assistant;
      content = [ Agent_sdk.Types.Text "[STATE]\nDONE\n[/STATE]"; tool_use ];
      name = None; tool_call_id = None; metadata = [] }
  in
  let scrubbed = KS.scrub_text_blocks m in
  let has_tool_use =
    List.exists (function Agent_sdk.Types.ToolUse _ -> true | _ -> false)
      scrubbed.content
  in
  Alcotest.(check bool) "ToolUse block preserved" true has_tool_use

let test_empty_messages () =
  let summary = KS.keeper_summarizer [] in
  Alcotest.(check string) "empty → No prior context marker"
    "[No prior context]" summary

let test_keeper_dispatch_passes_keeper_summarizer () =
  let root = repo_root () in
  let rel_path = "lib/keeper/keeper_agent_run.ml" in
  let source = read_file (Filename.concat root rel_path) in
  let marker = "Keeper_turn_driver.run_named" in
  let required = "~summarizer:Keeper_summarizer.keeper_summarizer" in
  let rec search pos =
    match Astring.String.find_sub ~start:pos ~sub:marker source with
    | None -> false
    | Some idx ->
        let len = min 3000 (String.length source - idx) in
        let dispatch_block = String.sub source idx len in
        Astring.String.is_infix ~affix:required dispatch_block
        || search (idx + String.length marker)
  in
  Alcotest.(check bool)
    (Printf.sprintf
       "%s: keeper dispatch must pass Keeper_summarizer into OAS compaction"
       rel_path)
    true (search 0)

let () =
  Alcotest.run "keeper_summarizer"
    [ ( "scrub + summarize",
        [ Alcotest.test_case "scrub_text_blocks removes [STATE]" `Quick
            test_scrub_text_blocks_removes_state;
          Alcotest.test_case "keeper_summarizer output omits [STATE]" `Quick
            test_summarizer_strips_state;
          Alcotest.test_case "non-Text blocks preserved" `Quick
            test_non_text_blocks_untouched;
          Alcotest.test_case "empty messages" `Quick
            test_empty_messages;
          Alcotest.test_case "keeper dispatch passes summarizer" `Quick
            test_keeper_dispatch_passes_keeper_summarizer;
        ] );
    ]
