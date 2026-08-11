(** Tests for Resource Subscriptions - MCP 2025-11-25 Spec *)

open Alcotest

module Subscriptions = Masc.Subscriptions

(* Initialize RNG for crypto *)
let () = Mirage_crypto_rng_unix.use_default ()

(** Resource type conversion tests *)
let test_resource_type_roundtrip () =
  let types = [
    Subscriptions.Tasks;
    Subscriptions.Agents;
    Subscriptions.Messages;
    Subscriptions.Votes;
    Subscriptions.Custom "custom_resource";
  ] in
  List.iter (fun t ->
    let s = Subscriptions.resource_type_to_string t in
    let t' = Subscriptions.resource_type_of_string s in
    check bool ("roundtrip: " ^ s) true (t = t')
  ) types

let test_change_type_to_string () =
  check string "created" "created" (Subscriptions.change_type_to_string Subscriptions.Created);
  check string "updated" "updated" (Subscriptions.change_type_to_string Subscriptions.Updated);
  check string "deleted" "deleted" (Subscriptions.change_type_to_string Subscriptions.Deleted)

(** Subscription tests *)
let test_subscribe () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"claude"
    ~resource:Subscriptions.Tasks
    () in
  check bool "has id" true (String.length sub.id > 0);
  check string "subscriber" "claude" sub.subscriber;
  check bool "resource is Tasks" true (sub.resource = Subscriptions.Tasks);
  check (option string) "no filter" None sub.filter

let test_subscribe_with_filter () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"gemini"
    ~resource:Subscriptions.Tasks
    ~filter:"task-001"
    () in
  check (option string) "has filter" (Some "task-001") sub.filter

let test_unsubscribe () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"codex"
    ~resource:Subscriptions.Messages
    () in
  let id = sub.id in
  let result = Subscriptions.SubscriptionStore.unsubscribe id in
  check bool "unsubscribe success" true result;
  let found = Subscriptions.SubscriptionStore.get id in
  check bool "subscription removed" true (Option.is_none found)

let test_unsubscribe_not_found () =
  let result = Subscriptions.SubscriptionStore.unsubscribe "nonexistent_sub" in
  check bool "unsubscribe fails for unknown" false result

let test_get_subscription () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"agent1"
    ~resource:Subscriptions.Agents
    () in
  let found = Subscriptions.SubscriptionStore.get sub.id in
  check bool "found" true (Option.is_some found);
  check string "same id" sub.id (Option.get found).id

(** Matching tests *)
let test_find_matching_no_filter () =
  let _sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"watcher"
    ~resource:Subscriptions.Tasks
    () in
  let matches = Subscriptions.SubscriptionStore.find_matching
    ~resource:Subscriptions.Tasks
    ~resource_id:"any-task" in
  check bool "finds match" true (List.length matches > 0)

let test_find_matching_with_filter () =
  let _sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"specific_watcher"
    ~resource:Subscriptions.Tasks
    ~filter:"task-specific"
    () in
  let matches = Subscriptions.SubscriptionStore.find_matching
    ~resource:Subscriptions.Tasks
    ~resource_id:"task-specific" in
  check bool "finds specific match" true (List.exists (fun (s : Subscriptions.subscription) -> s.filter = Some "task-specific") matches)

let test_find_matching_wildcard () =
  let _sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"wildcard_watcher"
    ~resource:Subscriptions.Messages
    ~filter:"*"
    () in
  let matches = Subscriptions.SubscriptionStore.find_matching
    ~resource:Subscriptions.Messages
    ~resource_id:"any-message" in
  check bool "wildcard matches" true (List.exists (fun (s : Subscriptions.subscription) -> s.filter = Some "*") matches)

let test_find_matching_wrong_resource () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"tasks_only"
    ~resource:Subscriptions.Tasks
    () in
  let matches = Subscriptions.SubscriptionStore.find_matching
    ~resource:Subscriptions.Votes
    ~resource_id:"vote-001" in
  check bool "no match for different resource" false (List.exists (fun (s : Subscriptions.subscription) -> s.id = sub.id) matches)

(** Notification tests *)
let test_notify_change () =
  let _sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"notified_agent"
    ~resource:Subscriptions.Tasks
    () in
  let count = Subscriptions.notify_change
    ~resource:Subscriptions.Tasks
    ~change:Subscriptions.Created
    ~resource_id:"new-task"
    ~data:(`Assoc [("title", `String "Test Task")]) in
  check bool "at least one notified" true (count > 0)

let test_pop_notifications () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"poll_agent"
    ~resource:Subscriptions.Agents
    () in
  let _ = Subscriptions.notify_change
    ~resource:Subscriptions.Agents
    ~change:Subscriptions.Updated
    ~resource_id:"agent-001"
    ~data:(`Assoc [("status", `String "active")]) in
  let notifs = Subscriptions.SubscriptionStore.pop_notifications sub.id in
  check bool "has notifications" true (List.length notifs > 0);
  (* Second pop should be empty *)
  let notifs2 = Subscriptions.SubscriptionStore.pop_notifications sub.id in
  check int "notifications consumed" 0 (List.length notifs2)

(** JSON serialization *)
let test_subscription_to_json () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"json_agent"
    ~resource:Subscriptions.Tasks
    () in
  let json = Subscriptions.subscription_to_json sub in
  match json with
  | `Assoc fields ->
    check bool "has id" true (List.mem_assoc "id" fields);
    check bool "has subscriber" true (List.mem_assoc "subscriber" fields);
    check bool "has resource" true (List.mem_assoc "resource" fields)
  | _ -> fail "Expected Assoc"

let test_notification_to_json () =
  let notif : Subscriptions.notification = {
    subscription_id = "sub-123";
    resource = Subscriptions.Tasks;
    change = Subscriptions.Created;
    resource_id = "task-456";
    data = `Assoc [("title", `String "Test")];
    timestamp = Unix.gettimeofday ();
  } in
  let json = Subscriptions.notification_to_json notif in
  match json with
  | `Assoc fields ->
    check bool "has subscription_id" true (List.mem_assoc "subscription_id" fields);
    check bool "has change" true (List.mem_assoc "change" fields);
    check bool "has data" true (List.mem_assoc "data" fields)
  | _ -> fail "Expected Assoc"

(** Hook function tests *)
let test_notify_task_change () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"task_hook_agent"
    ~resource:Subscriptions.Tasks
    () in
  (* Notify task change - hook function returns unit *)
  Subscriptions.notify_task_change
    ~change:Subscriptions.Created
    ~task_id:"hook-task"
    ~data:(`Assoc []);
  (* Verify notification was queued *)
  let pending = Subscriptions.SubscriptionStore.pop_notifications sub.id in
  check bool "task notification queued" true (List.length pending > 0)

let test_notify_agent_change () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"agent_hook_agent"
    ~resource:Subscriptions.Agents
    () in
  (* Notify agent change - hook function returns unit *)
  Subscriptions.notify_agent_change
    ~change:Subscriptions.Updated
    ~agent_name:"agent-x"
    ~data:(`Assoc []);
  (* Verify notification was queued *)
  let pending = Subscriptions.SubscriptionStore.pop_notifications sub.id in
  check bool "agent notification queued" true (List.length pending > 0)

let test_notify_message () =
  let sub = Subscriptions.SubscriptionStore.subscribe
    ~subscriber:"msg_hook_agent"
    ~resource:Subscriptions.Messages
    () in
  (* Notify message - hook function returns unit *)
  Subscriptions.notify_message
    ~message_id:"msg-001"
    ~data:(`Assoc []);
  (* Verify notification was queued *)
  let pending = Subscriptions.SubscriptionStore.pop_notifications sub.id in
  check bool "message notification queued" true (List.length pending > 0)

(** Test suites *)
let type_tests = [
  "resource type roundtrip", `Quick, test_resource_type_roundtrip;
  "change type to string", `Quick, test_change_type_to_string;
]

let subscription_tests = [
  "subscribe", `Quick, test_subscribe;
  "subscribe with filter", `Quick, test_subscribe_with_filter;
  "unsubscribe", `Quick, test_unsubscribe;
  "unsubscribe not found", `Quick, test_unsubscribe_not_found;
  "get subscription", `Quick, test_get_subscription;
]

let matching_tests = [
  "find matching no filter", `Quick, test_find_matching_no_filter;
  "find matching with filter", `Quick, test_find_matching_with_filter;
  "find matching wildcard", `Quick, test_find_matching_wildcard;
  "find matching wrong resource", `Quick, test_find_matching_wrong_resource;
]

let notification_tests = [
  "notify change", `Quick, test_notify_change;
  "pop notifications", `Quick, test_pop_notifications;
]

let json_tests = [
  "subscription_to_json", `Quick, test_subscription_to_json;
  "notification_to_json", `Quick, test_notification_to_json;
]

let hook_tests = [
  "notify_task_change", `Quick, test_notify_task_change;
  "notify_agent_change", `Quick, test_notify_agent_change;
  "notify_message", `Quick, test_notify_message;
]

let test_concurrent_notification_queue_preserves_every_event () =
  let sub =
    Subscriptions.SubscriptionStore.subscribe
      ~subscriber:"concurrent-notification-test"
      ~resource:(Subscriptions.Custom "concurrent")
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Subscriptions.SubscriptionStore.unsubscribe sub.id : bool))
    (fun () ->
      let domain_count = 4 in
      let events_per_domain = 64 in
      let ready = Atomic.make 0 in
      let workers =
        List.init domain_count (fun domain_index ->
          Domain.spawn (fun () ->
            ignore (Atomic.fetch_and_add ready 1 : int);
            while Atomic.get ready < domain_count do
              Domain.cpu_relax ()
            done;
            for event_index = 1 to events_per_domain do
              let resource_id =
                Printf.sprintf "%d:%d" domain_index event_index
              in
              Subscriptions.SubscriptionStore.queue_notification
                sub.id
                { subscription_id = sub.id
                ; resource = Subscriptions.Custom "concurrent"
                ; change = Subscriptions.Updated
                ; resource_id
                ; data = `String resource_id
                ; timestamp = 0.0
                }
            done))
      in
      List.iter Domain.join workers;
      let notifications =
        Subscriptions.SubscriptionStore.pop_notifications sub.id
      in
      check int "every concurrent event retained"
        (domain_count * events_per_domain)
        (List.length notifications);
      let ids =
        notifications
        |> List.map (fun (notification : Subscriptions.notification) ->
          notification.resource_id)
        |> List.sort_uniq String.compare
      in
      check int "every concurrent event remains distinct"
        (domain_count * events_per_domain)
        (List.length ids))

let concurrency_tests =
  [ ( "concurrent queue retains every event"
    , `Quick
    , test_concurrent_notification_queue_preserves_every_event )
  ]

let () =
  run "Subscriptions" [
    "types", type_tests;
    "subscription", subscription_tests;
    "matching", matching_tests;
    "notification", notification_tests;
    "json", json_tests;
    "hooks", hook_tests;
    "concurrency", concurrency_tests;
  ]
