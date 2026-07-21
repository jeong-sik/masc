(* RFC-0351 S1: deterministic offline checkpoint purge. The rules were
   measured live on the analyst checkpoint (1,315 -> 579 messages, -28.0%
   bytes); these tests pin the rule contract so the checked-in tool cannot
   drift from what was validated. *)

module Purge = Masc.Keeper_checkpoint_purge
module Types = Agent_sdk.Types

let text_message role text : Types.message =
  { role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }

let block_message role content : Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }

let tool_use id : Types.content_block =
  Types.ToolUse { id; name = "test_tool"; input = `Assoc [ "id", `String id ] }

let tool_result ?(content = "raw tool output") id : Types.content_block =
  Types.ToolResult
    { tool_use_id = id
    ; content
    ; outcome = Types.Tool_succeeded
    ; json = Some (`Assoc [ "ok", `Bool true ])
    ; content_blocks = None
    }

let cycle id =
  [ block_message Types.Assistant [ tool_use id ]
  ; { (block_message Types.Tool [ tool_result id ]) with tool_call_id = Some id }
  ]

let unsigned_thinking text : Types.content_block =
  Types.Thinking { content = text; signature = None }

let signed_thinking text : Types.content_block =
  Types.Thinking { content = text; signature = Some "sig" }

(* Trailing distinct filler so the interesting prefix sits outside the
   protected tail without disabling the tail protection itself. *)
let filler n =
  List.init n (fun i -> text_message Types.User (Printf.sprintf "filler-%d" i))

let no_tail_config = { Purge.default_config with keep_recent_messages = 0 }

let run ?(config = no_tail_config) messages =
  match Purge.purge_messages ~config messages with
  | Ok result -> result
  | Error _ -> Alcotest.fail "purge rejected a structurally valid fixture"

let message_texts messages =
  List.map
    (fun (m : Types.message) ->
       String.concat
         "|"
         (List.map
            (function
              | Types.Text t -> t
              | Types.Thinking _ -> "<thinking>"
              | Types.ToolUse { id; _ } -> "use:" ^ id
              | Types.ToolResult { tool_use_id; content; _ } ->
                "result:" ^ tool_use_id ^ ":" ^ content
              | _ -> "<other>")
            m.content))
    messages

let test_duplicate_collapse_keeps_first_and_last () =
  let wake = text_message Types.User "(autonomous wake)" in
  let messages =
    [ wake
    ; text_message Types.Assistant "reply-a"
    ; wake
    ; text_message Types.Assistant "reply-b"
    ; wake
    ; wake
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "two middles dropped" 2 report.duplicates_dropped;
  Alcotest.(check (list string))
    "first and last occurrence survive in order"
    [ "(autonomous wake)"; "reply-a"; "reply-b"; "(autonomous wake)" ]
    (message_texts purged)

let test_duplicates_below_threshold_survive () =
  let wake = text_message Types.User "(autonomous wake)" in
  let messages = [ wake; text_message Types.Assistant "reply"; wake ] in
  let _purged, report = run messages in
  Alcotest.(check int) "pair is under the threshold" 0 report.duplicates_dropped

let test_duplicate_tool_cycles_are_never_collapsed () =
  (* Byte-identical cycles differ only in tool_use_id here — but even truly
     repeated payloads must stay: R1 is scoped to text-only ordinary
     messages. *)
  let messages = cycle "a" @ cycle "b" @ cycle "c" in
  let purged, report = run messages in
  Alcotest.(check int) "no cycle collapsed" 0 report.duplicates_dropped;
  Alcotest.(check int) "all cycle messages survive" 6 (List.length purged)

let test_reasoning_strip_scope () =
  let messages =
    [ block_message Types.Assistant [ unsigned_thinking "t1"; Types.Text "answer" ]
    ; block_message Types.Assistant [ unsigned_thinking "t2" ]
    ; block_message Types.Assistant [ signed_thinking "t3"; Types.Text "signed" ]
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "unsigned blocks stripped" 2 report.reasoning_blocks_stripped;
  Alcotest.(check int) "thinking-only message dropped" 1 report.reasoning_messages_dropped;
  Alcotest.(check (list string))
    "text survives; signed thinking is untouched"
    [ "answer"; "<thinking>|signed" ]
    (message_texts purged)

let test_reasoning_inside_tool_cycle_is_kept () =
  let messages =
    [ block_message Types.Assistant [ unsigned_thinking "pre-tool"; tool_use "a" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ]
  in
  let _purged, report = run messages in
  Alcotest.(check int)
    "a tool-use message keeps its reasoning"
    0
    report.reasoning_blocks_stripped

let test_tool_result_clear_preserves_pairing () =
  let messages = cycle "a" @ [ text_message Types.User "after" ] in
  let purged, report = run messages in
  Alcotest.(check int) "one result cleared" 1 report.tool_results_cleared;
  (match List.nth purged 1 with
   | { Types.content = [ Types.ToolResult { tool_use_id; content; json; content_blocks; outcome } ]; _ } ->
     Alcotest.(check string) "pairing id kept" "a" tool_use_id;
     Alcotest.(check string)
       "content replaced by the marker"
       Purge.cleared_tool_result_content
       content;
     Alcotest.(check bool) "json dropped" true (Option.is_none json);
     Alcotest.(check bool) "blocks dropped" true (Option.is_none content_blocks);
     (match outcome with
      | Types.Tool_succeeded -> ()
      | _ -> Alcotest.fail "typed outcome must survive the clear")
   | _ -> Alcotest.fail "cleared cycle lost its ToolResult block");
  match Masc.Keeper_compaction_unit.validate purged with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "cleared cycle no longer validates"

let test_protected_tail_is_byte_exact () =
  let wake = text_message Types.User "(autonomous wake)" in
  let config = { Purge.default_config with keep_recent_messages = 4 } in
  let tail =
    [ wake
    ; wake
    ; wake
    ; block_message Types.Assistant [ unsigned_thinking "tail"; Types.Text "t" ]
    ]
  in
  let messages = filler 3 @ tail in
  let purged, report = run ~config messages in
  Alcotest.(check int) "tail duplicates survive" 0 report.duplicates_dropped;
  Alcotest.(check int) "tail reasoning survives" 0 report.reasoning_blocks_stripped;
  Alcotest.(check int) "nothing dropped" 7 (List.length purged)

let test_cycle_overlapping_protected_tail_is_untouched () =
  let config = { Purge.default_config with keep_recent_messages = 1 } in
  (* The cycle's final message falls inside the protected tail; the whole
     cycle must be exempt from R3. *)
  let messages = [ text_message Types.User "head" ] @ cycle "a" in
  let _purged, report = run ~config messages in
  Alcotest.(check int) "overlapping cycle not cleared" 0 report.tool_results_cleared

let test_purge_is_idempotent () =
  let wake = text_message Types.User "(autonomous wake)" in
  let messages =
    [ wake; wake; wake ]
    @ cycle "a"
    @ [ block_message Types.Assistant [ unsigned_thinking "t"; Types.Text "x" ] ]
    @ [ wake ]
  in
  let once, _ = run messages in
  let twice, second_report = run once in
  Alcotest.(check (list string))
    "second purge is the identity"
    (message_texts once)
    (message_texts twice);
  Alcotest.(check int) "no further duplicates" 0 second_report.duplicates_dropped;
  Alcotest.(check int)
    "no further reasoning"
    0
    second_report.reasoning_blocks_stripped;
  Alcotest.(check int) "no further clears" 0 second_report.tool_results_cleared

let test_broken_structure_is_refused () =
  let orphan =
    { (block_message Types.Tool [ tool_result "ghost" ]) with
      tool_call_id = Some "ghost"
    }
  in
  match Purge.purge_messages ~config:no_tail_config [ orphan ] with
  | Error (Purge.Invalid_input_structure _) -> ()
  | Ok _ -> Alcotest.fail "orphan tool_result was accepted"
  | Error _ -> Alcotest.fail "orphan tool_result misclassified"

let test_config_bounds_are_enforced () =
  (match
     Purge.purge_messages
       ~config:{ no_tail_config with dup_threshold = 1 }
       [ text_message Types.User "x" ]
   with
   | Error (Purge.Invalid_config _) -> ()
   | _ -> Alcotest.fail "dup_threshold 1 was accepted");
  match
    Purge.purge_messages
      ~config:{ no_tail_config with keep_recent_messages = -1 }
      [ text_message Types.User "x" ]
  with
  | Error (Purge.Invalid_config _) -> ()
  | _ -> Alcotest.fail "negative keep_recent_messages was accepted"

let test_checkpoint_fields_pass_through () =
  let checkpoint =
    Agent_sdk.Checkpoint.
      { version = checkpoint_version
      ; session_id = "trace-purge-fixture"
      ; agent_name = "purge-fixture"
      ; model = "test-model"
      ; system_prompt = None
      ; messages =
          [ text_message Types.User "(autonomous wake)"
          ; text_message Types.User "(autonomous wake)"
          ; text_message Types.User "(autonomous wake)"
          ]
      ; usage = Types.empty_usage
      ; turn_count = 41
      ; created_at = 1_700_000_000.0
      ; tools = []
      ; tool_choice = None
      ; disable_parallel_tool_use = false
      ; temperature = None
      ; top_p = None
      ; top_k = None
      ; min_p = None
      ; enable_thinking = None
      ; preserve_thinking = None
      ; response_format = Types.Off
      ; thinking_budget = None
      ; reasoning_effort = None
      ; cache_system_prompt = false
      ; context = Agent_sdk.Context.create_sync ()
      ; mcp_sessions = []
      ; working_context = None
      }
  in
  match Purge.purge ~config:no_tail_config checkpoint with
  | Error _ -> Alcotest.fail "checkpoint purge failed"
  | Ok (purged, report) ->
    Alcotest.(check int) "one middle dropped" 1 report.duplicates_dropped;
    Alcotest.(check string)
      "session identity unchanged"
      checkpoint.session_id
      purged.Agent_sdk.Checkpoint.session_id;
    Alcotest.(check int)
      "turn watermark unchanged"
      checkpoint.turn_count
      purged.Agent_sdk.Checkpoint.turn_count

let () =
  Alcotest.run
    "keeper checkpoint purge"
    [ ( "rules"
      , [ Alcotest.test_case
            "duplicate collapse keeps first and last"
            `Quick
            test_duplicate_collapse_keeps_first_and_last
        ; Alcotest.test_case
            "duplicates below threshold survive"
            `Quick
            test_duplicates_below_threshold_survive
        ; Alcotest.test_case
            "tool cycles are never collapsed"
            `Quick
            test_duplicate_tool_cycles_are_never_collapsed
        ; Alcotest.test_case "reasoning strip scope" `Quick test_reasoning_strip_scope
        ; Alcotest.test_case
            "reasoning inside a tool cycle is kept"
            `Quick
            test_reasoning_inside_tool_cycle_is_kept
        ; Alcotest.test_case
            "tool result clear preserves pairing"
            `Quick
            test_tool_result_clear_preserves_pairing
        ] )
    ; ( "boundaries"
      , [ Alcotest.test_case
            "protected tail is byte exact"
            `Quick
            test_protected_tail_is_byte_exact
        ; Alcotest.test_case
            "cycle overlapping the tail is untouched"
            `Quick
            test_cycle_overlapping_protected_tail_is_untouched
        ; Alcotest.test_case "purge is idempotent" `Quick test_purge_is_idempotent
        ; Alcotest.test_case
            "broken structure is refused"
            `Quick
            test_broken_structure_is_refused
        ; Alcotest.test_case
            "config bounds are enforced"
            `Quick
            test_config_bounds_are_enforced
        ; Alcotest.test_case
            "checkpoint fields pass through"
            `Quick
            test_checkpoint_fields_pass_through
        ] )
    ]
