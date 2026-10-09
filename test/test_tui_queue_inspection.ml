module Inbox = Masc_tui_queue_inspection
let get = function Ok value -> value | Error error -> Alcotest.fail error
let contains text part = Astring.String.is_infix ~affix:part text
let test_pause_and_work_are_separate () =
  let snapshot = `Assoc ["global_waiting_on", `List []; "keepers", `List [`Assoc [
    "state", `String "busy"; "paused", `Bool true;
    "waiting_on", `List [`Assoc ["source", `String "event_queue_pending";
      "what", `String "campaign wake"; "next_action", `String "keeper_drain_event_queue";
      "since", `Float 850.0;
      "detail", `Assoc ["source_ref", `String "exact-source"; "source_incarnation", `String "42"]]]]]] in
  let lines = get (Inbox.waiting_lines ~now:1000.0 snapshot) |> String.concat "\n" in
  List.iter (fun text -> Alcotest.(check bool) text true (contains lines text))
    ["consumption: paused"; "inventory: busy"; "1 pending in 1 group"; "campaign wake";
     "unacknowledged 2m30s"; "event exact-source 42"];
  Alcotest.(check bool) "a machine next_action label is not printed" false
    (contains lines "keeper_drain_event_queue");
  Alcotest.(check bool) "missing inventory is not an empty queue" true
    (Result.is_error (Inbox.waiting_lines ~now:1000.0 (`Assoc [])))

let inventory rows = `Assoc ["global_waiting_on", `List []; "keepers", `List [`Assoc [
  "state", `String "waiting"; "paused", `Bool false; "waiting_on", `List rows]]]

let inventory_row ?(detail = []) ?due_at source what =
  `Assoc ["source", `String source; "what", `String what;
          "since", `Float 100.;
          "due_at", Option.fold ~none:`Null ~some:(fun at -> `Float at) due_at;
          "detail", `Assoc detail]

let test_unknown_inventory_data_is_not_pending () =
  List.iter (fun row ->
    Alcotest.(check bool) "invalid inventory remains unavailable" true
      (Result.is_error (Inbox.waiting_lines ~now:1000. (inventory [row]))))
    [ inventory_row "future_source" "unknown source"
    ; inventory_row "chat_operation_queued" "missing count"
    ; inventory_row ~detail:["queued_count", `Int (-1)] "chat_operation_queued" "negative count"
    ; inventory_row ~detail:["group_count", `String "three"] "event_queue_pending" "invalid group"
    ; inventory_row ~detail:["status", `String "unknown"] ~due_at:2000. "schedule_waiting" "unknown lifecycle"
    ; inventory_row ~detail:["status", `String "scheduled"] "schedule_waiting" "missing due instant"
    ]

let test_global_inventory_errors_are_visible () =
  let rows = [inventory_row "read_error" "schedule store unreadable";
              inventory_row "read_error" "approval store unreadable"] in
  let snapshot = `Assoc ["global_waiting_on", `List rows; "keepers", `List []] in
  let text = get (Inbox.waiting_lines ~now:1000. snapshot) |> String.concat "\n" in
  List.iter (fun needle -> Alcotest.(check bool) needle true (contains text needle))
    ["Workspace inventory: 0 pending · 2 unavailable";
     "schedule store unreadable · unavailable"; "approval store unreadable · unavailable"];
  Alcotest.(check bool) "missing global inventory is not an empty workspace" true
    (Result.is_error (Inbox.waiting_lines ~now:1000. (`Assoc ["keepers", `List []])))

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
let () = Alcotest.run "TUI queue controls"
  ["inbox", [Alcotest.test_case "global source failures remain visible" `Quick test_global_inventory_errors_are_visible;
    Alcotest.test_case "unknown inventory data is not pending" `Quick test_unknown_inventory_data_is_not_pending;
    Alcotest.test_case "paused running work remains visible" `Quick test_pause_and_work_are_separate;
    Alcotest.test_case "editing preserves media and context" `Quick test_edit_retains_media_and_turn_context;
    Alcotest.test_case "event controls address an exact source" `Quick test_exact_event_commands;
    Alcotest.test_case "queue pagination rejects missing identity" `Quick test_pagination_requires_identity]]
