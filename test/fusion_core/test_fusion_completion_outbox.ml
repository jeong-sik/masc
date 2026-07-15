open Alcotest
module O = Fusion_completion_outbox

let require_ok = function
  | Ok value -> value
  | Error error -> fail (O.error_to_string error)
;;

let payload content = O.{ content; evidence_ref = Some "board/post-1" }
let completion content = O.Succeeded (payload content)
let address value = O.Completion_address.of_opaque_string value

let with_path f =
  let path = Filename.temp_file "fusion-completion-outbox" ".jsonl" in
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ()) (fun () -> f path)
;;

let test_durable_lifecycle () =
  with_path (fun path ->
    let operation_id = "fusion-17" in
    let expected_address = address {|{"surface":"opaque","id":"thread-9"}|} in
    let expected_completion = completion "synthesis" in
    Sys.remove path;
    let outbox = O.replay path in
    (match O.register_address outbox ~operation_id expected_address |> require_ok with
     | O.Registered -> ()
     | O.Already_registered -> fail "first address registration must be new");
    (match O.register_address outbox ~operation_id expected_address |> require_ok with
     | O.Already_registered -> ()
     | O.Registered -> fail "same address retry must be explicit");
    (match O.complete outbox ~operation_id expected_completion |> require_ok with
     | O.Queued -> ()
     | O.Already_pending | O.Already_delivered -> fail "first completion must queue");
    let replayed = O.replay path in
    (match O.pending replayed with
     | [ item ] ->
       check string "operation identity" operation_id item.operation_id;
       check bool "exact opaque address" true
         (O.Completion_address.equal expected_address item.address);
       check bool "exact completion" true (O.equal_completion expected_completion item.completion)
     | items -> failf "expected one replayed item, got %d" (List.length items));
    (match O.complete replayed ~operation_id expected_completion |> require_ok with
     | O.Already_pending -> ()
     | O.Queued | O.Already_delivered -> fail "replayed completion must remain pending");
    (match O.acknowledge replayed ~operation_id |> require_ok with
     | O.Acknowledged -> ()
     | O.Already_acknowledged -> fail "first acknowledgement must be new");
    let hydrated = O.replay path in
    check int "ack removes pending item" 0 (List.length (O.pending hydrated));
    match O.complete hydrated ~operation_id expected_completion |> require_ok with
    | O.Already_delivered -> ()
    | O.Queued | O.Already_pending -> fail "acknowledged completion must not queue twice")
;;

let test_conflicts_are_typed () =
  let outbox = O.create () in
  let operation_id = "fusion-conflict" in
  ignore (O.register_address outbox ~operation_id (address "route-a") |> require_ok);
  (match O.register_address outbox ~operation_id (address "route-b") with
   | Error (O.Address_conflict id) -> check string "address conflict id" operation_id id
   | Error error -> fail (O.error_to_string error)
   | Ok _ -> fail "conflicting address must not succeed");
  ignore (O.complete outbox ~operation_id (completion "first") |> require_ok);
  (match O.complete outbox ~operation_id (completion "second") with
   | Error (O.Completion_conflict id) -> check string "completion conflict id" operation_id id
   | Error error -> fail (O.error_to_string error)
   | Ok _ -> fail "conflicting completion must not succeed");
  match O.complete outbox ~operation_id:"missing" (completion "orphan") with
  | Error (O.Unknown_address id) -> check string "unknown address id" "missing" id
  | Error error -> fail (O.error_to_string error)
  | Ok _ -> fail "completion without an address must not succeed"
;;

let test_persistence_failure_is_fail_closed () =
  with_path (fun regular_file ->
    let outbox = O.create ~path:(Filename.concat regular_file "outbox.jsonl") () in
    match O.register_address outbox ~operation_id:"fusion-write-failure" (address "route") with
    | Error (O.Persistence_failed _) ->
      (match O.complete outbox ~operation_id:"fusion-write-failure" (completion "result") with
       | Error (O.Unknown_address _) -> ()
       | Error error -> fail (O.error_to_string error)
       | Ok _ -> fail "failed registration must not publish its address")
    | Error error -> fail (O.error_to_string error)
    | Ok _ -> fail "an undurable address must not be reported as registered")
;;

let () =
  run "fusion_completion_outbox"
    [ ( "durability"
      , [ test_case "replay exact pending and acknowledged identity" `Quick test_durable_lifecycle
        ; test_case "conflicts are typed failures" `Quick test_conflicts_are_typed
        ; test_case "persistence failure is fail-closed" `Quick
            test_persistence_failure_is_fail_closed
        ] )
    ]
