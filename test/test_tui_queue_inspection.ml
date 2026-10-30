module Inbox = Masc_tui_queue_inspection
let get = function Ok value -> value | Error error -> Alcotest.fail error
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
      (Result.is_error (Inbox.waiting_items ~now:1000. (inventory [row]))))
    [ inventory_row "future_source" "unknown source"
    ; inventory_row "chat_operation_queued" "missing count"
    ; inventory_row ~detail:["queued_count", `Int (-1)] "chat_operation_queued" "negative count"
    ; inventory_row ~detail:["group_count", `String "three"] "event_queue_pending" "invalid group"
    ; inventory_row ~detail:["status", `String "unknown"] ~due_at:2000. "schedule_waiting" "unknown lifecycle"
    ; inventory_row ~detail:["status", `String "scheduled"] "schedule_waiting" "missing due instant"
    ]

let test_global_inventory_errors_are_not_targets () =
  let rows = [inventory_row "read_error" "schedule store unreadable";
              inventory_row "read_error" "approval store unreadable"] in
  let snapshot = `Assoc ["global_waiting_on", `List rows; "keepers", `List []] in
  let items = get (Inbox.waiting_items ~now:1000. snapshot) in
  Alcotest.(check bool) "unavailable sources cannot be selected as operations" true
    (List.for_all (fun (item : Inbox.item) -> item.id = None) items);
  Alcotest.(check bool) "missing global inventory is not an empty workspace" true
    (Result.is_error (Inbox.waiting_items ~now:1000. (`Assoc ["keepers", `List []])))

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
   | Inbox.Prioritize_event (reference, incarnation, urgency) ->
     Alcotest.(check string) "source reference" "ref" reference;
     Alcotest.(check int64) "source incarnation" 42L incarnation;
     Alcotest.(check bool) "requested urgency" true (urgency = Keeper_event_queue.Immediate)
   | Inbox.Inspect | Inspect_peers _ | Pause | Resume | Clear | Cancel _ | Move_to_end _ | Run_next _
   | Edit _ | Cancel_event _ -> Alcotest.fail "lost exact event identity");
  Alcotest.(check bool) "unknown urgency rejected" true
    (Result.is_error (Inbox.parse "priority-event ref 42 fastest"));
  Alcotest.(check bool) "negative incarnation rejected" true
    (Result.is_error (Inbox.parse "cancel-event ref -1 reason"));
  Alcotest.(check bool) "cancellation requires reason" true
    (Result.is_error (Inbox.parse "cancel-event ref 42"))
let test_clear_names_no_message () =
  (match get (Inbox.parse "clear") with
   | Inbox.Clear -> ()
   | Inbox.Inspect | Inspect_peers _ | Pause | Resume | Cancel _ | Move_to_end _ | Run_next _ | Edit _
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
  let result = get (Inbox.read_peer_page ~keeper_name:"receiver" ~after_sequence:None ~read_page:(fun () ->
    incr reads; Ok (`Assoc ["operations", `List []]))) in
  Alcotest.(check int) "exactly one server page is read" 1 !reads;
  Alcotest.(check bool) "an empty page has no peer edges" true
    (result.snapshot.queued_count = 0 && result.snapshot.relations = [] && result.next_sequence = None);
  let failures = ref 0 in
  let result = Inbox.read_peer_page ~keeper_name:"receiver" ~after_sequence:None ~read_page:(fun () ->
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
        Inbox.read_peer_page ~keeper_name:"receiver" ~after_sequence:None ~read_page:(fun () ->
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
      (`Assoc ["operations", `List [`Assoc ["operation_id", `String "peer-1"; "state", `String "Queued"]]])));
  let sequenced sequence operation = match operation with
    | `Assoc fields -> `Assoc (("sequence", `String sequence) :: fields)
    | _ -> failwith "operation fixture must be an object" in
  let read after operations =
    Inbox.read_peer_page ~keeper_name:target ~after_sequence:after
      ~read_page:(fun () -> Ok (`Assoc ["operations", `List operations])) in
  let first = get (read None [sequenced "10" moved]) in
  Alcotest.(check (option string)) "the next read uses the observed sequence" (Some "10") first.next_sequence;
  Alcotest.(check bool) "a page cannot repeat its boundary" true
    (Result.is_error (read (Some "10") [sequenced "10" moved]));
  Alcotest.(check bool) "out-of-order page rows are rejected" true
    (Result.is_error (read None [sequenced "11" moved; sequenced "9"
      (operation "peer-2" (source ~sender_keeper:sender ~continuation_channel:back))]));
  let empty = get (read (Some "10") []) in
  Alcotest.(check (option string)) "an empty later page has no continuation" None empty.next_sequence

let item_ids items = List.filter_map (fun (item : Inbox.item) -> item.id) items

let test_waiting_item_identity_is_exact_and_scoped () =
  let event reference incarnation extra =
    inventory_row ~detail:(["source_ref", `String reference;
                            "source_incarnation", `String incarnation] @ extra)
      "event_queue_pending" "pending event" in
  let rows =
    [ event "event-one" "42" []
    ; event "aggregate-only" "43"
        ["group_count", `Int 2;
         "group_members", `List [`Assoc ["source_ref", `String "first-member";
                                          "source_incarnation", `String "43"];
                                `Assoc ["source_ref", `String "second-member";
                                        "source_incarnation", `String "44"]]]
    ; event "negative" "-1" []
    ; event "overflow" "9223372036854775808" []
    ; inventory_row ~detail:["operation_id", `String "active-operation"]
        "chat_operation_running" "active operation"
    ; inventory_row ~due_at:2000. ~detail:["status", `String "scheduled";
                                           "schedule_id", `String "job-a";
                                           "schedule_instance_id", `String "instance-a"]
        "schedule_waiting" "future schedule"
    ; inventory_row ~due_at:2000. ~detail:["status", `String "scheduled";
                                           "schedule_id", `String "job-without-instance"]
        "schedule_waiting" "missing schedule incarnation"
    ] in
  let ids = item_ids (get (Inbox.waiting_items ~now:1000. (inventory rows))) in
  Alcotest.(check bool) "single and grouped event identities remain exact" true
    (ids = [Inbox.Event ("event-one",42L);
            Inbox.Event ("first-member",43L);
            Inbox.Event ("second-member",44L);
            Inbox.Running_message "active-operation";
            Inbox.Schedule ("job-a", "instance-a")]);
  let global = `Assoc ["global_waiting_on", `List [event "global-event" "9" []];
                       "keepers", `List []] in
  Alcotest.(check bool) "a workspace-wide row is not a selected Keeper target" true
    (item_ids (get (Inbox.waiting_items ~now:1000. global)) = []);
  Alcotest.(check bool) "unknown source remains a read error" true
    (Result.is_error (Inbox.waiting_items ~now:1000.
      (inventory [inventory_row "future_source" "unknown source"])))

let test_group_members_require_complete_unique_addresses () =
  let member reference incarnation =
    `Assoc ["source_ref", `String reference; "source_incarnation", `String incarnation] in
  let first = member "event-first" "42" in
  let second = member "event-second" "43" in
  let grouped members =
    let detail = ["source_ref", `String "aggregate";
                  "source_incarnation", `String "41";
                  "group_count", `Int 2] in
    let detail = match members with
      | None -> detail | Some members -> detail @ ["group_members", members] in
    inventory_row ~detail "event_queue_pending" "scheduled occurrences" in
  let ids rows = item_ids (get (Inbox.waiting_items ~now:1000. (inventory rows))) in
  let valid = grouped (Some (`List [first; second])) in
  Alcotest.(check bool) "both exact member identities are selectable in source order" true
    (ids [valid] = [Inbox.Event ("event-first",42L); Inbox.Event ("event-second",43L)]);
  let global = `Assoc ["global_waiting_on", `List [valid]; "keepers", `List []] in
  Alcotest.(check bool) "workspace-wide groups never select this Keeper's events" true
    (item_ids (get (Inbox.waiting_items ~now:1000. global)) = []);
  let malformed =
    [ None
    ; Some `Null
    ; Some (`List [first])
    ; Some (`List [first; second; member "extra" "44"])
    ; Some (`List [first; first])
    ; Some (`List [first; `String "invalid"])
    ; Some (`List [first; `Assoc ["source_ref", `String "missing-incarnation"]])
    ; Some (`List [first; member "" "43"])
    ; Some (`List [first; member "negative" "-1"])
    ; Some (`List [first; member "overflow" "9223372036854775808"])
    ; Some (`List [first; `Assoc ["source_ref", `String "bad-due";
                                  "source_incarnation", `String "43";
                                  "due_at_unix", `String "unknown"]])
    ; Some (`List [first; second; `String "invalid-extra"])
    ] in
  List.iter (fun members ->
    Alcotest.(check bool) "incomplete, duplicate or malformed groups expose no member targets"
      true (ids [grouped members] = [])) malformed;
  let independent = inventory_row ~detail:["source_ref", `String "other";
                                           "source_incarnation", `String "7"]
      "event_queue_pending" "other event" in
  Alcotest.(check bool) "a bad group does not withdraw an independent exact event" true
    (ids [independent; grouped (Some (`List [first]))] = [Inbox.Event ("other",7L)])

let test_operation_items_keep_distinct_exact_ids () =
  let module Payload = Masc.Keeper_chat_operation_payload in
  let continuation_channel =
    get (Keeper_continuation_channel.dashboard ~thread_id:"keeper:queue-test") in
  let source = get (Payload.source_to_json ~submitted_by:"operator"
    ~thread_id:"keeper:queue-test" ~continuation_channel
    ~surface:(Masc.Surface_ref.Dashboard {session_id=None})
    ~channel:"" ~channel_user_id:"" ~channel_user_name:"" ~channel_workspace_id:""
    ~conversation_id:None ~external_message_id:None ~workspace_id:None ~extra_mentions:[]
    ~sender_keeper:None ~user_row_origin:Masc.Keeper_chat_store.Needs_append) in
  let input = Payload.input_to_json ~message:"same prefix\nactual message"
    ~user_blocks:[] ~turn_instructions:None ~surface_context:None ~attachments:[] in
  let operation id = `Assoc ["operation_id", `String id; "source", source; "input", input] in
  let response operations = `Assoc ["operations", `List operations] in
  let ids = item_ids (get (Inbox.operation_items
    (response [operation "queue-one"; operation "queue-two"]))) in
  Alcotest.(check bool) "identical message bodies do not merge operation targets" true
    (ids = [Inbox.Server_message "queue-one"; Inbox.Server_message "queue-two"]);
  Alcotest.(check bool) "an invalid operation cannot become a target" true
    (Result.is_error (Inbox.operation_items (response [operation ""])));
  Alcotest.(check bool) "duplicate operation across pages is not treated as two targets" true
    (Result.is_error (Inbox.operation_items (response [operation "queue-one"; operation "queue-one"])));
  Alcotest.(check bool) "a malformed input cannot become a target" true
    (Result.is_error (Inbox.operation_items (response
      [`Assoc ["operation_id", `String "queue-one"; "source", source; "input", `Null]])))

let () = Alcotest.run "TUI queue controls"
  ["inbox", [Alcotest.test_case "global source failures cannot be operation targets" `Quick test_global_inventory_errors_are_not_targets;
    Alcotest.test_case "unknown inventory data is not pending" `Quick test_unknown_inventory_data_is_not_pending;
    Alcotest.test_case "editing preserves media and context" `Quick test_edit_retains_media_and_turn_context;
    Alcotest.test_case "event controls address an exact source" `Quick test_exact_event_commands;
    Alcotest.test_case "clear takes no message id" `Quick test_clear_names_no_message;
    Alcotest.test_case "queued peer identities and scope" `Quick test_peer_relations_use_the_recorded_keeper_identity;
    Alcotest.test_case "peer relationships read one server page" `Quick test_peer_page_reads_once;
    Alcotest.test_case "peer page requires workspace admission" `Quick test_peer_page_workspace_admission;
    Alcotest.test_case "queue pagination rejects missing identity" `Quick test_pagination_requires_identity;
    Alcotest.test_case "waiting rows keep exact scoped identities" `Quick test_waiting_item_identity_is_exact_and_scoped;
    Alcotest.test_case "group members require complete unique addresses" `Quick test_group_members_require_complete_unique_addresses;
    Alcotest.test_case "server messages keep exact operation identities" `Quick test_operation_items_keep_distinct_exact_ids]]
