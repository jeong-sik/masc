module AQ = Masc.Keeper_approval_queue
module Rules = Keeper_approval_queue_rules_types
module Result_types = Masc.Keeper_approval_queue_result
module Chat = Masc.Keeper_chat_store

let unwrap format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)
;;

let with_workspace run =
  let base_path = Filename.temp_file "native_continuation_projection" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect
    ~finally:(fun () -> AQ.For_testing.reset_runtime_state (); remove base_path)
    (fun () ->
      ignore (AQ.install_persistence ~base_path |> unwrap Result_types.install_error_to_string);
      run base_path)
;;

let test_native_receipt_preserves_unspent_grant () =
  with_workspace @@ fun base_path ->
  let keeper_name = "native-receipt-owner" in
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String keeper_name; "trace_id", `String "native-receipt"])
    |> unwrap Fun.id
  in
  Masc.Keeper_meta_store.replace_snapshot (Masc.Workspace.default_config base_path) meta
  |> unwrap Fun.id;
  let submission =
    AQ.submit_pending ~base_path ~keeper_name ~tool_name:"external-effect"
      ~input:(`Assoc ["target", `String "native-receipt"])
      ~call_summary:None ()
    |> unwrap Result_types.storage_error_to_string
  in
  let approval_id = submission.approval_id in
  ignore (AQ.resolve_with_policy ~base_path ~id:approval_id
    ~decision:Rules.Decision.Approve ~source:Rules.Human_operator ()
    |> unwrap AQ.resolve_error_to_string);
  let resolution =
    Masc.Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
    |> unwrap Fun.id
    |> Keeper_event_queue.to_list
    |> List.find_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Hitl_resolved resolution
        when resolution.approval_id = approval_id -> Some resolution
      | _ -> None)
    |> function
    | Some resolution -> resolution
    | None -> Alcotest.fail "approved wake was not delivered"
  in
  (match AQ.ensure_settled_continuation_chat_projection ~base_path ~keeper_name ~resolution with
   | Ok AQ.Continuation_projection_not_ready -> ()
   | Ok AQ.Continuation_projection_recorded -> Alcotest.fail "unspent replay settled"
   | Error detail -> Alcotest.fail detail);
  let wrong_keeper = "native-receipt-other" in
  (match AQ.record_native_continuation_delivery ~base_path ~keeper_name:wrong_keeper ~resolution with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "another Keeper recorded the native receipt");
  Alcotest.(check int) "wrong Keeper has no chat rows" 0
    (List.length (Chat.load_all ~base_dir:base_path ~keeper_name:wrong_keeper));
  let record () =
    match AQ.record_native_continuation_delivery ~base_path ~keeper_name ~resolution with
    | Ok AQ.Continuation_projection_recorded -> ()
    | Ok AQ.Continuation_projection_not_ready -> Alcotest.fail "native instruction waited for replay"
    | Error detail -> Alcotest.fail detail
  in
  record ();
  record ();
  let rows =
    Chat.load_all ~base_dir:base_path ~keeper_name
    |> List.filter (fun (message : Chat.chat_message) ->
      match message.approval_lifecycle with
      | Some lifecycle -> lifecycle.approval_id = approval_id
        && Chat.approval_lifecycle_is_continuation lifecycle.phase
      | None -> false)
  in
  Alcotest.(check int) "one native continuation row" 1 (List.length rows);
  Alcotest.(check bool) "intake sees settlement" true
    (AQ.continuation_settled_chat_projection_present ~base_path ~keeper_name ~approval_id);
  let delivery = AQ.approved_resolution_delivery ~base_path ~id:approval_id
    |> unwrap Result_types.grant_error_to_string in
  (match delivery.state, delivery.replay_outcome with
   | Result_types.Resolution_unconsumed, None -> ()
   | _ -> Alcotest.fail "recording a native receipt changed the tool grant or replay");
  Alcotest.(check string) "receipt keeps tool identity" "external-effect"
    delivery.request.tool_name
;;

let () =
  Alcotest.run "Native continuation projection"
    ["native instruction", [Alcotest.test_case
       "receipt is owner scoped and idempotent without consuming the tool grant"
       `Quick test_native_receipt_preserves_unspent_grant]]
;;
