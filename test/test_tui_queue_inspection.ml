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
let test_clear_names_no_message () =
  (match get (Inbox.parse "clear") with
   | Inbox.Clear -> ()
   | Inbox.Inspect | Inspect_peers _ | Pause | Resume | Cancel _ | Move_to_end _ | Edit _
   | Cancel_event _ | Prioritize_event _ -> Alcotest.fail "clear was read as another command");
  Alcotest.(check bool) "an argument is not silently ignored" true
    (Result.is_error (Inbox.parse "clear tui-01a13350-f5ce-7000-bf11-57eec0f43f1a"))
let test_pagination_requires_identity () =
  Alcotest.(check (option string)) "empty page ends read" None
    (get (Inbox.next_sequence (`Assoc ["operations",`List []])));
  Alcotest.(check (option string)) "next page uses durable sequence" (Some "123")
    (get (Inbox.next_sequence (`Assoc ["operations",`List [`Assoc ["sequence",`String "123"]]])));
  Alcotest.(check bool) "missing cursor is an error" true
    (Result.is_error (Inbox.next_sequence (`Assoc ["operations",`List [`Assoc []]])))

let test_peer_page_reads_once () =
  let reads = ref 0 in
  let result = get (Inbox.read_peer_page ~keeper_name:"receiver" ~read_page:(fun () ->
    incr reads; Ok (`Assoc ["operations", `List []]))) in
  Alcotest.(check int) "exactly one server page is read" 1 !reads;
  Alcotest.(check bool) "an empty page has no peer edges" true
    (result.queued_count = 0 && result.relations = []);
  let failures = ref 0 in
  let result = Inbox.read_peer_page ~keeper_name:"receiver" ~read_page:(fun () ->
    incr failures; Error "read failed") in
  Alcotest.(check int) "a failed read is not retried" 1 !failures;
  Alcotest.(check bool) "a failed page is not reported as an empty result" true
    (Result.is_error result)

let test_peer_page_workspace_admission () = Eio_main.run (fun _ ->
  let module Decode = Masc.Tui_decode in
  let expected : Decode.server_identity =
    { sid_version = "test"; sid_binary_commit = "test"; sid_binary_commit_age_s = None;
      sid_base_path = Decode.Canonical_path.of_path "/owned-workspace";
      sid_masc_root = Decode.Canonical_path.of_path "/owned-workspace/.masc";
      sid_executable_in_worktree = None; sid_state_ready = Some true; sid_uptime = None;
      sid_sse_clients = None; sid_gc = None; sid_scheduler = None } in
  let host = "localhost" and port = 8935 in
  let kept_reads = Masc_tui_kept_reads.create () in
  let seen = ref [] in
  let receipts = ref [Masc.Workspace.read_precondition_admission_header] in
  let send ~path ~headers:_ =
    seen := path :: !seen;
    Ok Masc_http_client.{status = 200; headers = !receipts; body = "{\"operations\":[]}"} in
  let read () =
    Masc_tui_workspace_read.with_binding ~host ~port ~expected
      ~proof:Request_precondition (fun () ->
        Inbox.read_peer_page ~keeper_name:"receiver" ~read_page:(fun () ->
          Masc_tui_workspace_read.read_json ~kept_reads
            ~address_of:(fun ~path -> Printf.sprintf "http://%s:%d%s" host port path)
            ~send ~decode:Decode.decode_json_response_body ~host ~port
            ~path:"/api/v1/keepers/receiver/chat/operations?state=queued")) in
  Alcotest.(check bool) "a workspace-attested peer page is admitted" true
    (Result.is_ok (read ()));
  Alcotest.(check int) "one request is sent" 1 (List.length !seen);
  let uri = Uri.of_string (List.hd !seen) in
  let query = Uri.query uri in
  Alcotest.(check string) "the request names the selected recipient"
    "/api/v1/keepers/receiver/chat/operations" (Uri.path uri);
  Alcotest.(check bool) "the GET carries the queue filter and both workspace roots" true
    (List.assoc_opt "state" query = Some ["queued"]
     && List.assoc_opt "expected_base_path" query = Some ["/owned-workspace"]
     && List.assoc_opt "expected_masc_root" query = Some ["/owned-workspace/.masc"]);
  receipts := [];
  Alcotest.(check bool) "a response without workspace admission is refused" true
    (Result.is_error (read ())))

let test_peer_relations_use_the_recorded_keeper_identity () =
  let target = "receiver" in
  let thread_id = "keeper:" ^ target in
  let source ~sender_keeper ~continuation_channel =
    Masc.Keeper_chat_operation_payload.source_to_json
      ~submitted_by:"sender" ~thread_id ~continuation_channel
      ~surface:Masc.Surface_ref.Agent ~channel:"agent" ~channel_user_id:""
      ~channel_user_name:"" ~channel_workspace_id:"" ~conversation_id:None
      ~external_message_id:None ~workspace_id:None ~extra_mentions:[]
      ~sender_keeper ~user_row_origin:Masc.Keeper_chat_store.Needs_append |> get in
  let sender = Masc.Keeper_identity.Keeper_id.of_string "sender" in
  let back = get (Keeper_continuation_channel.keeper ~keeper_name:"sender") in
  let dashboard = get (Keeper_continuation_channel.dashboard ~thread_id) in
  let operation id source = `Assoc ["operation_id", `String id;
    "state", `String "Queued"; "source", source] in
  let page = `Assoc ["operations", `List
    [operation "peer-1" (source ~sender_keeper:sender ~continuation_channel:back);
     operation "operator-1" (source ~sender_keeper:None ~continuation_channel:dashboard)]] in
  let snapshot = get (Inbox.peer_snapshot ~keeper_name:target page) in
  Alcotest.(check int) "both queued operations are accounted for" 2 snapshot.queued_count;
  Alcotest.(check bool) "only the recorded Keeper is a peer" true
    (snapshot.relations = [{ Inbox.operation_id = "peer-1"; sender = "sender";
      recipient = target; reply_to = Some "sender" }]);
  let wrong_state = `Assoc ["operations", `List
    [`Assoc ["operation_id", `String "peer-1"; "state", `String "Running";
      "source", source ~sender_keeper:sender ~continuation_channel:back]]] in
  Alcotest.(check bool) "running operation is not classified as queued" true
    (Result.is_error (Inbox.peer_snapshot ~keeper_name:target wrong_state));
  let moved = operation "peer-1" (source ~sender_keeper:sender ~continuation_channel:back) in
  Alcotest.(check bool) "a request seen twice is not counted twice" true
    (Result.is_error (Inbox.peer_snapshot ~keeper_name:target
      (`Assoc ["operations", `List [moved; moved]])));
  Alcotest.(check bool) "missing source is not classified as an empty relationship" true
    (Result.is_error (Inbox.peer_snapshot ~keeper_name:target
      (`Assoc ["operations", `List [`Assoc ["operation_id", `String "peer-1"; "state", `String "Queued"]]])))
let () = Alcotest.run "TUI queue controls"
  ["inbox", [Alcotest.test_case "global source failures remain visible" `Quick test_global_inventory_errors_are_visible;
    Alcotest.test_case "unknown inventory data is not pending" `Quick test_unknown_inventory_data_is_not_pending;
    Alcotest.test_case "paused running work remains visible" `Quick test_pause_and_work_are_separate;
    Alcotest.test_case "editing preserves media and context" `Quick test_edit_retains_media_and_turn_context;
    Alcotest.test_case "event controls address an exact source" `Quick test_exact_event_commands;
    Alcotest.test_case "clear takes no message id" `Quick test_clear_names_no_message;
    Alcotest.test_case "queued peer identities and scope" `Quick test_peer_relations_use_the_recorded_keeper_identity;
    Alcotest.test_case "peer relationships read one server page" `Quick test_peer_page_reads_once;
    Alcotest.test_case "peer page requires workspace admission" `Quick test_peer_page_workspace_admission;
    Alcotest.test_case "queue pagination rejects missing identity" `Quick test_pagination_requires_identity]]
