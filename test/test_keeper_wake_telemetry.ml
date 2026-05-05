open Alcotest

module WT = Masc_mcp.Keeper_wake_telemetry
module Types = Agent_sdk.Types

let text_msg role s : Masc_domain.message =
  { role; content = [ Masc_domain.Text s ]; name = None; tool_call_id = None; metadata = [] }

let tool_use_msg id name input : Masc_domain.message =
  {
    role = Masc_domain.Assistant;
    content = [ Masc_domain.ToolUse { id; name; input } ];
    name = None;
    tool_call_id = None;
      metadata = [];
  }

let tool_result_msg ~tool_use_id ~content : Masc_domain.message =
  {
    role = Masc_domain.Tool;
    content =
      [ Masc_domain.ToolResult { tool_use_id; content; is_error = false; json = None } ];
    name = None;
    tool_call_id = Some tool_use_id;
      metadata = [];
  }

let sum_counts counts =
  List.fold_left (fun acc (_, n) -> acc + n) 0 counts

let test_text_only_message () =
  let m = text_msg Masc_domain.User "hello" in
  check int "text length only" 5 (WT.bytes_of_message m)

let test_tool_use_bytes () =
  let m = tool_use_msg "abc" "grep" (`Assoc [ ("q", `String "foo") ]) in
  let expected =
    String.length "abc"
    + String.length "grep"
    + String.length (Yojson.Safe.to_string (`Assoc [ ("q", `String "foo") ]))
  in
  check int "tool_use bytes" expected (WT.bytes_of_message m)

let test_tool_result_bytes () =
  let m = tool_result_msg ~tool_use_id:"abc" ~content:"hello world" in
  check int "tool_result bytes"
    (String.length "abc" + String.length "hello world")
    (WT.bytes_of_message m)

let test_thinking_and_redacted () =
  let m : Masc_domain.message =
    {
      role = Masc_domain.Assistant;
      content =
        [
          Masc_domain.Thinking { thinking_type = "extended"; content = "ponder" };
          Masc_domain.RedactedThinking "redacted-blob";
        ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  check int "thinking uses content; redacted uses literal length"
    (String.length "ponder" + String.length "redacted-blob")
    (WT.bytes_of_message m)

let test_role_key_mapping () =
  check string "system -> system" "system" (WT.role_key Masc_domain.System);
  check string "user -> user" "user" (WT.role_key Masc_domain.User);
  check string "assistant -> assistant" "assistant"
    (WT.role_key Masc_domain.Assistant);
  check string "tool -> tool" "tool" (WT.role_key Masc_domain.Tool)

let test_role_counts_adds_pending_user_on_empty_history () =
  let counts = WT.role_counts_with_pending_user [] in
  check (list (pair string int))
    "empty history yields only the pending user turn"
    [ ("user", 1) ] counts

let test_role_counts_sum_matches_message_count () =
  let history =
    [
      text_msg Masc_domain.System "sys";
      text_msg Masc_domain.User "first question";
      text_msg Masc_domain.Assistant "first answer";
      text_msg Masc_domain.User "second question";
      text_msg Masc_domain.Assistant "second answer";
    ]
  in
  let sizes =
    WT.compute_sizes ~system_prompt:"" ~tools:[] ~history_messages:history
      ~user_message:"third"
  in
  check int "message_count equals sum of role_counts" sizes.message_count
    (sum_counts sizes.role_counts);
  check int "message_count = history + 1 pending" 6 sizes.message_count;
  let user_count =
    try List.assoc "user" sizes.role_counts with Not_found -> 0
  in
  check int "user count reflects 2 history + 1 pending" 3 user_count

let test_compute_sizes_bytes_breakdown () =
  let history =
    [
      text_msg Masc_domain.User "A";    (* 1 byte *)
      text_msg Masc_domain.Assistant "BB";  (* 2 bytes *)
    ]
  in
  let tools = [] in
  let sizes =
    WT.compute_sizes ~system_prompt:"sys" ~tools ~history_messages:history
      ~user_message:"CCCC" (* 4 bytes *)
  in
  check int "system_prompt_bytes" 3 sizes.system_prompt_bytes;
  check int "tool_defs_bytes (empty)" 0 sizes.tool_defs_bytes;
  check int "messages_bytes (1 + 2 + 4)" 7 sizes.messages_bytes;
  check int "approx_body_bytes = sp + tools + msgs" (3 + 0 + 7)
    sizes.approx_body_bytes;
  check int "tool_count" 0 sizes.tool_count

let test_compute_sizes_invariant_across_shapes () =
  (* Random-ish mixtures: every call must satisfy the invariant. *)
  let samples : Masc_domain.message list list =
    [
      [];
      [ text_msg Masc_domain.User "x" ];
      [ text_msg Masc_domain.System "s"; text_msg Masc_domain.User "u" ];
      List.init 20 (fun i ->
        if i mod 2 = 0 then text_msg Masc_domain.User (string_of_int i)
        else text_msg Masc_domain.Assistant (string_of_int i));
      [
        text_msg Masc_domain.Assistant "think";
        tool_use_msg "id1" "search" (`Assoc [ ("q", `String "x") ]);
        tool_result_msg ~tool_use_id:"id1" ~content:"result payload";
        text_msg Masc_domain.Assistant "final";
      ];
    ]
  in
  List.iter
    (fun history ->
      let sizes =
        WT.compute_sizes ~system_prompt:"p" ~tools:[] ~history_messages:history
          ~user_message:"u"
      in
      check int
        (Printf.sprintf
           "invariant holds for history of length %d"
           (List.length history))
        sizes.message_count
        (sum_counts sizes.role_counts))
    samples

let test_role_counts_are_stably_sorted () =
  let history =
    [
      text_msg Masc_domain.Assistant "a";
      text_msg Masc_domain.Tool "t";
      text_msg Masc_domain.System "s";
    ]
  in
  let counts = WT.role_counts_with_pending_user history in
  let keys = List.map fst counts in
  let sorted_keys = List.sort String.compare keys in
  check (list string) "role_counts keys are sorted for stable JSON output"
    sorted_keys keys

let () =
  run "Keeper_wake_telemetry"
    [
      ( "bytes_of_message",
        [
          test_case "text-only content" `Quick test_text_only_message;
          test_case "tool_use serialization bytes" `Quick test_tool_use_bytes;
          test_case "tool_result id + content bytes" `Quick
            test_tool_result_bytes;
          test_case "thinking + redacted thinking" `Quick
            test_thinking_and_redacted;
        ] );
      ( "role_key",
        [ test_case "all roles map to stable strings" `Quick test_role_key_mapping ] );
      ( "role_counts_with_pending_user",
        [
          test_case "empty history still counts the pending user turn" `Quick
            test_role_counts_adds_pending_user_on_empty_history;
          test_case "assoc list is stably sorted by key" `Quick
            test_role_counts_are_stably_sorted;
        ] );
      ( "compute_sizes",
        [
          test_case "byte breakdown matches inputs" `Quick
            test_compute_sizes_bytes_breakdown;
          test_case "role_counts sum matches message_count" `Quick
            test_role_counts_sum_matches_message_count;
          test_case "invariant holds across mixed content shapes" `Quick
            test_compute_sizes_invariant_across_shapes;
        ] );
    ]
