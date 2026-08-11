open Alcotest
open Masc

module Intent = Keeper_continuation_delivery_intent
module Publisher = Keeper_continuation_delivery_publisher
module Recovery = Keeper_continuation_delivery_recovery
module Store = Keeper_continuation_delivery_store

type producer_family =
  | Fusion
  | Hitl
  | Connector
  | Schedule

let families = [ Fusion; Hitl; Connector; Schedule ]

let family_label = function
  | Fusion -> "fusion"
  | Hitl -> "hitl"
  | Connector -> "connector"
  | Schedule -> "schedule"
;;

let source_id family = family_label family ^ "-source-1"

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_config label f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "continuation-conformance-%s-%d-%06x"
         label
         (Unix.getpid ())
         (Random.bits ()))
  in
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio_main.run (fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         f (Workspace.default_config base_path)))
;;

let expect_intent = function
  | Ok value -> value
  | Error error -> fail (Intent.error_to_string error)
;;

let expect_store = function
  | Ok value -> value
  | Error error -> fail (Store.error_to_string error)
;;

let expect_publish = function
  | Ok value -> value
  | Error error -> fail (Publisher.error_to_string error)
;;

let dashboard_channel family =
  Keeper_continuation_channel.dashboard
    ~thread_id:("conformance-" ^ family_label family)
  |> Result.fold ~ok:Fun.id ~error:fail
;;

let slack_channel family =
  Keeper_continuation_channel.slack
    ~team_id:(Some "team-1")
    ~channel_id:("channel-" ^ family_label family)
    ~thread_ts:(Some ("thread-" ^ family_label family))
    ~user_id:"user-1"
  |> Result.fold ~ok:Fun.id ~error:fail
;;

let payload family channel : Keeper_event_queue.stimulus_payload =
  match family with
  | Fusion ->
    Keeper_event_queue.Fusion_completed
      { run_id = source_id family
      ; terminal = Fusion_succeeded "fusion result"
      ; board_post_id = "board-post-1"
      ; channel
      }
  | Hitl ->
    Keeper_event_queue.Hitl_resolved
      { approval_id = source_id family
      ; decision = Hitl_approved
      ; channel
      }
  | Connector ->
    Keeper_event_queue.Connector_attention
      { event_id = source_id family; channel }
  | Schedule ->
    Keeper_event_queue.Schedule_due
      { occurrence_id = source_id family
      ; schedule_instance_id = "schedule-instance-1"
      ; schedule_id = "schedule-1"
      ; due_at = 100.0
      ; payload_digest = "schedule-digest-1"
      ; title = Some "scheduled conformance"
      ; message = "run the scheduled conformance fixture"
      ; result_delivery = Some channel
      }
;;

let source_key (source : Intent.source_identity) =
  match source with
  | Intent.Fusion_completion { run_id } -> "fusion:" ^ run_id
  | Intent.Hitl_resolution { approval_id } -> "hitl:" ^ approval_id
  | Intent.Connector_attention { event_id } -> "connector:" ^ event_id
  | Intent.Schedule_occurrence { occurrence_id } -> "schedule:" ^ occurrence_id
;;

let intent_for family channel =
  let origin =
    Intent.origin_of_payload (payload family channel)
    |> Result.map_error Intent.error_to_string
    |> fun result ->
    Result.bind
      result
      (Option.to_result
         ~none:(family_label family ^ " lost its routable origin"))
    |> Result.fold ~ok:Fun.id ~error:fail
  in
  Intent.create
    ~keeper_name:"keeper-conformance"
    ~keeper_turn_id:42
    ~origin
    ~response_text:(family_label family ^ " final response")
  |> expect_intent
;;

let adapter ~append_count ~send_count send =
  { Publisher.now = (fun () -> 200.0)
  ; append_transcript =
      (fun ~config:_ _intent ->
         incr append_count;
         Ok (Publisher.Appended { row_id = "transcript-row" }))
  ; send_connector =
      (fun request ->
         incr send_count;
         send request)
  }
;;

let stored config intent =
  Store.load
    ~config
    ~keeper_name:intent.Intent.keeper_name
    ~intent_id:intent.Intent.intent_id
  |> expect_store
;;

let assert_recovery_releases_source config terminal =
  match
    Recovery.settle_existing
      ~config
      ~keeper_name:terminal.Intent.keeper_name
      ~origin:terminal.Intent.origin
  with
  | Recovery.Obligation_committed { intent; _ } ->
    check bool "recovery retains exact intent identity" true
      (Intent.Intent_id.equal intent.Intent.intent_id terminal.Intent.intent_id)
  | Recovery.No_obligation -> fail "durable obligation disappeared during recovery"
  | Recovery.Quarantine_required { detail; _ } -> fail detail
;;

let assert_ack_policy outcome =
  let intent, delivery_state =
    match outcome with
    | Publisher.Delivered intent ->
      intent, Keeper_unified_turn.Delivery_delivered
    | Publisher.Failed intent ->
      intent, Keeper_unified_turn.Delivery_failed
    | Publisher.Ambiguous intent ->
      intent, Keeper_unified_turn.Delivery_ambiguous
  in
  let completion =
    Keeper_unified_turn.Continuation_delivery_committed
      { intent_id = intent.Intent.intent_id; delivery_state }
  in
  check bool "durable outbox settlement releases the active source" true
    (Keeper_heartbeat_loop.continuation_delivery_authorizes_source_ack
       ~source_requires:true
       completion)
;;

let test_all_producers_leave_one_delivered_correlation_bundle () =
  with_temp_config "delivered" (fun config ->
    let append_count = ref 0 in
    let send_count = ref 0 in
    let adapter =
      adapter ~append_count ~send_count (fun _ ->
        Publisher.Sent { message_id = "unused" })
    in
    let delivered =
      List.map
        (fun family ->
           let pending = intent_for family (dashboard_channel family) in
           let outcome =
             Publisher.For_testing.publish_with_adapter
               ~adapter
               ~config
               pending
             |> expect_publish
           in
           assert_ack_policy outcome;
           match outcome with
           | Publisher.Delivered terminal ->
             let persisted = stored config terminal in
             check string "producer correlation survives"
               (family_label family ^ ":" ^ source_id family)
               (source_key persisted.Intent.origin.source);
             check int "turn correlation survives" 42
               persisted.Intent.keeper_turn_id;
             check int "response digest is retained" 64
               (String.length persisted.Intent.response.sha256);
             check string "terminal evidence is delivered" "delivered"
               (Intent.state_label persisted.Intent.state);
             let replay =
               Publisher.For_testing.publish_with_adapter
                 ~adapter
                 ~config
                 terminal
               |> expect_publish
             in
             (match replay with
              | Publisher.Delivered replayed ->
                check bool "terminal replay keeps intent identity" true
                  (Intent.Intent_id.equal
                     terminal.Intent.intent_id
                     replayed.Intent.intent_id)
              | Publisher.Failed _ | Publisher.Ambiguous _ ->
                fail "delivered replay changed terminal class");
             terminal
           | Publisher.Failed _ | Publisher.Ambiguous _ ->
             fail (family_label family ^ " did not deliver"))
        families
    in
    let unique_ids =
      delivered
      |> List.map (fun intent ->
        Intent.Intent_id.to_string intent.Intent.intent_id)
      |> List.sort_uniq String.compare
    in
    check int "four producer namespaces cannot collide" 4
      (List.length unique_ids);
    check int "one append-once projection per producer" 4 !append_count;
    check int "dashboard producers never call a connector" 0 !send_count)
;;

let test_all_producers_preserve_ambiguous_send_without_resend () =
  List.iter
    (fun family ->
       with_temp_config (family_label family ^ "-ambiguous") (fun config ->
         let append_count = ref 0 in
         let send_count = ref 0 in
         let adapter =
           adapter ~append_count ~send_count (function
             | Publisher.Slack { channel_id; content; reply_to_message_id } ->
               check string "exact connector channel"
                 ("channel-" ^ family_label family)
                 channel_id;
               check string "exact response content"
                 (family_label family ^ " final response")
                 content;
               check (option string) "exact thread destination"
                 (Some ("thread-" ^ family_label family))
                 reply_to_message_id;
               Publisher.Indeterminate { detail = "send timeout" }
             | Publisher.Discord _ -> fail "Slack route was changed to Discord")
         in
         let pending = intent_for family (slack_channel family) in
         let outcome =
           Publisher.For_testing.publish_with_adapter
             ~adapter
             ~config
             pending
           |> expect_publish
         in
         assert_ack_policy outcome;
         (match outcome with
          | Publisher.Ambiguous terminal ->
            check string "ambiguous evidence persists" "ambiguous"
              (Intent.state_label (stored config terminal).Intent.state);
            assert_recovery_releases_source config terminal;
            ignore
              (Publisher.For_testing.publish_with_adapter
                 ~adapter
                 ~config
                 terminal
               |> expect_publish
               : Publisher.outcome)
          | Publisher.Delivered _ | Publisher.Failed _ ->
            fail (family_label family ^ " lost ambiguous send evidence"));
         check int "ambiguous terminal replay never resends" 1 !send_count;
         check int "ambiguous send never fabricates transcript proof" 0
           !append_count))
    families
;;

let test_all_producers_preserve_rejection_and_release_source () =
  List.iter
    (fun family ->
       with_temp_config (family_label family ^ "-failed") (fun config ->
         let append_count = ref 0 in
         let send_count = ref 0 in
         let adapter =
           adapter ~append_count ~send_count (fun _ ->
             Publisher.Rejected { detail = "credential unavailable" })
         in
         let outcome =
           Publisher.For_testing.publish_with_adapter
             ~adapter
             ~config
             (intent_for family (slack_channel family))
           |> expect_publish
         in
         assert_ack_policy outcome;
         (match outcome with
          | Publisher.Failed terminal ->
            check string "rejection evidence persists" "failed"
              (Intent.state_label (stored config terminal).Intent.state);
            assert_recovery_releases_source config terminal
          | Publisher.Delivered _ | Publisher.Ambiguous _ ->
            fail (family_label family ^ " lost rejected send evidence"));
         check int "one rejected send per producer" 1 !send_count;
         check int "rejected send never appends a transcript" 0 !append_count))
    families
;;

let test_unrelated_corrupt_obligation_does_not_poison_exact_recovery () =
  with_temp_config "corrupt-peer" (fun config ->
    let append_count = ref 0 in
    let send_count = ref 0 in
    let adapter =
      adapter ~append_count ~send_count (fun _ ->
        Publisher.Sent { message_id = "unused" })
    in
    let terminal =
      match
        Publisher.For_testing.publish_with_adapter
          ~adapter
          ~config
          (intent_for Fusion (dashboard_channel Fusion))
        |> expect_publish
      with
      | Publisher.Delivered terminal -> terminal
      | Publisher.Failed _ | Publisher.Ambiguous _ ->
        fail "dashboard fixture did not deliver"
    in
    let active_dir =
      Store.For_testing.active_directory
        ~config
        ~keeper_name:terminal.Intent.keeper_name
      |> expect_store
    in
    let corrupt_path = Filename.concat active_dir "unrelated-corrupt-peer" in
    let channel = open_out_bin corrupt_path in
    output_string channel "{broken-json";
    close_out channel;
    let inventory =
      Store.inventory ~config ~keeper_name:terminal.Intent.keeper_name
      |> expect_store
    in
    check int "peer corruption remains observable" 1
      (List.length inventory.record_failures);
    assert_recovery_releases_source config terminal)
;;

let () =
  run
    "keeper continuation delivery conformance"
    [ ( "producer matrix"
      , [ test_case
            "all producers leave one delivered correlation bundle"
            `Quick
            test_all_producers_leave_one_delivered_correlation_bundle
        ; test_case
            "all producers preserve ambiguous send without resend"
            `Quick
            test_all_producers_preserve_ambiguous_send_without_resend
        ; test_case
            "all producers preserve rejection and release source"
            `Quick
            test_all_producers_preserve_rejection_and_release_source
        ; test_case
            "unrelated corrupt obligation does not poison exact recovery"
            `Quick
            test_unrelated_corrupt_obligation_does_not_poison_exact_recovery
        ] )
    ]
;;
