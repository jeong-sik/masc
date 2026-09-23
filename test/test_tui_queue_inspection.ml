module Inbox = Masc_tui_queue_inspection
let get = function Ok value -> value | Error error -> Alcotest.fail error
let contains text part = Astring.String.is_infix ~affix:part text
let test_pause_and_work_are_separate () =
  let snapshot = `Assoc ["keepers", `List [`Assoc [
    "state", `String "busy"; "paused", `Bool true;
    "waiting_on", `List [`Assoc ["source", `String "event_queue_pending";
      "what", `String "campaign wake"; "next_action", `String "keeper_drain_event_queue";
      "since", `Float 850.0;
      "detail", `Assoc ["source_ref", `String "exact-source"; "source_incarnation", `String "42"]]]]]] in
  let lines = get (Inbox.waiting_lines ~now:1000.0 snapshot) |> String.concat "\n" in
  List.iter (fun text -> Alcotest.(check bool) text true (contains lines text))
    ["consumption: paused"; "server work: busy"; "1 pending in 1 group"; "campaign wake";
     "waiting 2m30s"; "event exact-source 42"];
  Alcotest.(check bool) "a machine next_action label is not printed" false
    (contains lines "keeper_drain_event_queue");
  Alcotest.(check bool) "missing inventory is not an empty queue" true
    (Result.is_error (Inbox.waiting_lines ~now:1000.0 (`Assoc [])))

(* The server collapses one schedule's pending occurrences into one row with a
   count, the due span and every member's address in [detail]. The row shows
   the count the server put in [what], the span, and one address with how many
   more there are; the pending total counts members, not rows. When an operator
   chat holds the turn, the line above the rows says why nothing drains. *)
let test_a_schedule_group_reads_as_one_row_with_its_span () =
  let occurrence n = `Assoc ["source_ref", `String ("ref-" ^ n); "source_incarnation", `String n;
                             "due_at_unix", `Float (float_of_string n)] in
  let snapshot = `Assoc ["keepers", `List [`Assoc [
    "state", `String "busy"; "paused", `Bool false;
    "waiting_on", `List [
      `Assoc ["source", `String "event_queue_pending";
        "what", `String "\xec\x98\x88\xec\x95\xbd \xc3\x973"; "next_action", `String "keeper_drain_event_queue";
        "since", `Float 100.0;
        "detail", `Assoc ["source_ref", `String "ref-100"; "source_incarnation", `String "100";
          "group_count", `Int 3; "group_first_due_unix", `Float 100.0; "group_last_due_unix", `Float 700.0;
          "group_members", `List [occurrence "100"; occurrence "400"; occurrence "700"]]];
      `Assoc ["source", `String "chat_operation_running";
        "what", `String "operator chat"; "next_action", `String "keeper_owner_settle_operation";
        "since", `Float 900.0; "detail", `Assoc []]]]]] in
  let lines = get (Inbox.waiting_lines ~now:1000.0 snapshot) in
  let text = String.concat "\n" lines in
  List.iter (fun needle -> Alcotest.(check bool) needle true (contains text needle))
    ["4 pending in 2 groups"; "\xc3\x973"; " \xc2\xb7 due "; " \xe2\x86\x92 "; "waiting 15m00s";
     "event ref-100 100 \xc2\xb7 +2 more"; "autonomous turn: waits while the operator chat runs"];
  (match lines with
   | _header :: blocker :: _ ->
     Alcotest.(check bool) "the blocker line sits under the header" true
       (contains blocker "autonomous turn")
   | _ -> Alcotest.fail "expected a header and a blocker line")
let test_edit_retains_media_and_turn_context () =
  let module Input = Masc.Keeper_multimodal_input in
  let image = Input.User_image (Input.Url_ref {value="https://example.test/frame.png";mime_type=Some "image/png"}) in
  let input = Masc.Keeper_chat_operation_payload.input_to_json ~message:"old"
    ~user_blocks:[Input.User_text "old";image] ~turn_instructions:(Some "inspect the image")
    ~surface_context:(Some (`Assoc ["thread", `String "original"])) ~attachments:[] in
  let edited = get (Inbox.edited_input ~message:"new\nsecond line" (`Assoc ["input",input]))
    |> Masc.Keeper_chat_operation_payload.input_of_json |> get in
  Alcotest.(check string) "new text" "new\nsecond line" edited.message;
  Alcotest.(check bool) "media survives once; old text removed" true
    (edited.user_blocks = [Input.User_text "new\nsecond line";image]);
  Alcotest.(check (option string)) "turn instructions preserved" (Some "inspect the image") edited.turn_instructions;
  Alcotest.(check bool) "settled input cannot be edited" true
    (Result.is_error (Inbox.edited_input ~message:"new" (`Assoc ["input",`Null])))
let test_exact_event_commands () =
  (match get (Inbox.parse "priority-event ref 42 immediate") with
   | Inbox.Prioritize_event ("ref",42L,Keeper_event_queue.Immediate) -> ()
   | _ -> Alcotest.fail "lost exact event identity");
  Alcotest.(check bool) "unknown urgency rejected" true
    (Result.is_error (Inbox.parse "priority-event ref 42 fastest"));
  Alcotest.(check bool) "negative incarnation rejected" true
    (Result.is_error (Inbox.parse "cancel-event ref -1 reason"));
  Alcotest.(check bool) "cancellation requires reason" true
    (Result.is_error (Inbox.parse "cancel-event ref 42"))
let test_pagination_requires_identity () =
  Alcotest.(check (option string)) "empty page ends read" None
    (get (Inbox.next_sequence (`Assoc ["operations",`List []])));
  Alcotest.(check (option string)) "next page uses durable sequence" (Some "123")
    (get (Inbox.next_sequence (`Assoc ["operations",`List [`Assoc ["sequence",`String "123"]]])));
  Alcotest.(check bool) "missing cursor is an error" true
    (Result.is_error (Inbox.next_sequence (`Assoc ["operations",`List [`Assoc []]])))
let test_dashboard_sender_uses_typed_route () =
  let source = `Assoc ["schema", `String "masc.keeper_chat_operation.source.v2";
    "submitted_by", `String "masc-tui"; "thread_id", `String "keeper:alpha";
    "continuation_channel", `Assoc ["kind",`String "dashboard";"thread_id",`String "keeper:alpha"];
    "surface", `Assoc ["kind",`String "dashboard"]; "channel",`String "";
    "channel_user_id",`String ""; "channel_user_name",`String ""; "channel_workspace_id",`String "";
    "conversation_id",`Null; "external_message_id",`Null; "workspace_id",`Null;
    "extra_mentions",`List []; "sender_keeper",`Null;
    "user_row_origin",`String "needs_append"] in
  let input = Masc.Keeper_chat_operation_payload.input_to_json ~message:"hello"
    ~user_blocks:[] ~turn_instructions:None ~surface_context:None ~attachments:[] in
  let output = get (Inbox.operation_lines (`Assoc ["operations",`List [`Assoc [
    "operation_id",`String "tui-test"; "source",source; "input",input]]])) |> String.concat "\n" in
  Alcotest.(check bool) "dashboard route is named even with empty channel label" true (contains output "dashboard");
  Alcotest.(check bool) "submitting actor remains visible" true (contains output "masc-tui")
let () = Alcotest.run "TUI queue controls"
  ["inbox", [Alcotest.test_case "dashboard sender and route" `Quick test_dashboard_sender_uses_typed_route;
    Alcotest.test_case "paused running work remains visible" `Quick test_pause_and_work_are_separate;
    Alcotest.test_case "a schedule group reads as one row with its span" `Quick test_a_schedule_group_reads_as_one_row_with_its_span;
    Alcotest.test_case "editing preserves media and context" `Quick test_edit_retains_media_and_turn_context;
    Alcotest.test_case "event controls address an exact source" `Quick test_exact_event_commands;
    Alcotest.test_case "queue pagination rejects missing identity" `Quick test_pagination_requires_identity]]
