open Alcotest
open Masc

module Intent = Keeper_continuation_delivery_intent
module Publisher = Keeper_continuation_delivery_publisher
module Store = Keeper_continuation_delivery_store

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_config f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "continuation-delivery-publisher-%d-%06x"
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

let dashboard_intent () =
  let channel =
    Keeper_continuation_channel.dashboard ~thread_id:"dashboard-thread-1"
    |> Result.fold ~ok:Fun.id ~error:fail
  in
  let origin = Intent.fusion_origin ~run_id:"fusion-dashboard-1" channel |> expect_intent in
  Intent.create
    ~keeper_name:"keeper-publisher"
    ~keeper_turn_id:9
    ~origin
    ~response_text:"dashboard final answer"
  |> expect_intent
;;

let discord_intent () =
  let channel =
    Keeper_continuation_channel.discord
      ~guild_id:(Some "guild-1")
      ~channel_id:"channel-1"
      ~parent_channel_id:None
      ~thread_id:None
      ~user_id:"user-1"
    |> Result.fold ~ok:Fun.id ~error:fail
  in
  let origin =
    Intent.connector_attention_origin ~event_id:"event-discord-1" channel
    |> expect_intent
  in
  Intent.create
    ~keeper_name:"keeper-publisher"
    ~keeper_turn_id:10
    ~origin
    ~response_text:"discord final answer"
  |> expect_intent
;;

let adapter ?(append = fun _ -> Ok (Publisher.Appended { row_id = "row-1" }))
      ?(send = fun _ -> Publisher.Sent { message_id = "message-1" })
      ?(now = fun () -> 100.0) () =
  { Publisher.now
  ; append_transcript = (fun ~config:_ intent -> append intent)
  ; send_connector = send
  }
;;

let stored config intent =
  Store.load
    ~config
    ~keeper_name:intent.Intent.keeper_name
    ~intent_id:intent.Intent.intent_id
  |> expect_store
;;

let test_dashboard_pending_delivers_once () =
  with_temp_config (fun config ->
    let append_count = ref 0 in
    let adapter =
      adapter
        ~append:(fun _ ->
          incr append_count;
          Ok (Publisher.Appended { row_id = "row-dashboard" }))
        ()
    in
    let intent = dashboard_intent () in
    (match
       Publisher.For_testing.publish_with_adapter ~adapter ~config intent
       |> expect_publish
     with
     | Publisher.Delivered delivered ->
       check string "delivered state persisted" "delivered"
         (Intent.state_label (stored config delivered).Intent.state)
     | Publisher.Failed _ | Publisher.Ambiguous _ ->
       fail "dashboard projection did not deliver");
    check int "one transcript append" 1 !append_count)
;;

let test_dashboard_attempting_is_safe_to_resume () =
  with_temp_config (fun config ->
    let pending = dashboard_intent () in
    ignore (Store.persist ~config pending |> expect_store : Store.persist_outcome);
    let attempting = Intent.start_attempt ~started_at:50.0 pending |> expect_intent in
    ignore (Store.persist ~config attempting |> expect_store : Store.persist_outcome);
    let append_count = ref 0 in
    let adapter =
      adapter
        ~append:(fun _ ->
          incr append_count;
          Ok (Publisher.Already_present { row_id = "row-dashboard" }))
        ()
    in
    (match
       Publisher.For_testing.publish_with_adapter ~adapter ~config attempting
       |> expect_publish
     with
     | Publisher.Delivered _ -> ()
     | Publisher.Failed _ | Publisher.Ambiguous _ ->
       fail "dashboard recovery did not deliver");
    check int "append-once replay was attempted once" 1 !append_count)
;;

let test_external_send_and_transcript_deliver () =
  with_temp_config (fun config ->
    let send_count = ref 0 in
    let append_count = ref 0 in
    let adapter =
      adapter
        ~send:(fun request ->
          incr send_count;
          (match request with
           | Publisher.Discord { channel_id; content; reply_to_message_id } ->
             check string "exact Discord channel" "channel-1" channel_id;
             check string "exact response" "discord final answer" content;
             check (option string) "no fabricated reply id" None reply_to_message_id
           | Publisher.Slack _ -> fail "Discord intent routed to Slack");
          Publisher.Sent { message_id = "discord-message-1" })
        ~append:(fun _ ->
          incr append_count;
          Ok (Publisher.Appended { row_id = "row-discord" }))
        ()
    in
    let intent = discord_intent () in
    (match
       Publisher.For_testing.publish_with_adapter ~adapter ~config intent
       |> expect_publish
     with
     | Publisher.Delivered delivered ->
       (match delivered.Intent.state with
        | Intent.Delivered { connector_message_id = Some message_id; _ } ->
          check string "connector receipt retained" "discord-message-1" message_id
        | _ -> fail "delivered intent lost connector receipt")
     | Publisher.Failed _ | Publisher.Ambiguous _ ->
       fail "known-success connector delivery did not settle");
    check int "one connector send" 1 !send_count;
    check int "one transcript append" 1 !append_count)
;;

let test_external_attempting_suppresses_resend () =
  with_temp_config (fun config ->
    let pending = discord_intent () in
    ignore (Store.persist ~config pending |> expect_store : Store.persist_outcome);
    let attempting = Intent.start_attempt ~started_at:50.0 pending |> expect_intent in
    ignore (Store.persist ~config attempting |> expect_store : Store.persist_outcome);
    let send_count = ref 0 in
    let append_count = ref 0 in
    let adapter =
      adapter
        ~send:(fun _ ->
          incr send_count;
          Publisher.Sent { message_id = "duplicate" })
        ~append:(fun _ ->
          incr append_count;
          Ok (Publisher.Appended { row_id = "duplicate" }))
        ()
    in
    (match
       Publisher.For_testing.publish_with_adapter ~adapter ~config attempting
       |> expect_publish
     with
     | Publisher.Ambiguous _ -> ()
     | Publisher.Delivered _ | Publisher.Failed _ ->
       fail "recovered external attempt was not marked ambiguous");
    check int "external resend suppressed" 0 !send_count;
    check int "no transcript proof fabricated" 0 !append_count)
;;

let test_external_failure_classes () =
  let run expected send =
    with_temp_config (fun config ->
      let intent = discord_intent () in
      let result =
        Publisher.For_testing.publish_with_adapter
          ~adapter:(adapter ~send ())
          ~config
          intent
        |> expect_publish
      in
      let actual =
        match result with
        | Publisher.Delivered _ -> "delivered"
        | Publisher.Failed _ -> "failed"
        | Publisher.Ambiguous _ -> "ambiguous"
      in
      check string "typed external failure" expected actual)
  in
  run "failed" (fun _ -> Publisher.Rejected { detail = "missing credential" });
  run "ambiguous" (fun _ -> Publisher.Indeterminate { detail = "timeout" })
;;

let test_sent_then_transcript_failure_is_ambiguous () =
  with_temp_config (fun config ->
    let intent = discord_intent () in
    let result =
      Publisher.For_testing.publish_with_adapter
        ~adapter:
          (adapter
             ~send:(fun _ -> Publisher.Sent { message_id = "message-1" })
             ~append:(fun _ -> Error "disk unavailable")
             ())
        ~config
        intent
      |> expect_publish
    in
    match result with
    | Publisher.Ambiguous _ -> ()
    | Publisher.Delivered _ | Publisher.Failed _ ->
      fail "post-send transcript failure lost ambiguity")
;;

let () =
  run
    "keeper continuation delivery publisher"
    [ ( "publisher"
      , [ test_case
            "dashboard pending delivers"
            `Quick
            test_dashboard_pending_delivers_once
        ; test_case
            "dashboard attempting resumes"
            `Quick
            test_dashboard_attempting_is_safe_to_resume
        ; test_case
            "external known success"
            `Quick
            test_external_send_and_transcript_deliver
        ; test_case
            "external attempting suppresses resend"
            `Quick
            test_external_attempting_suppresses_resend
        ; test_case
            "external typed failure classes"
            `Quick
            test_external_failure_classes
        ; test_case
            "post-send transcript failure"
            `Quick
            test_sent_then_transcript_failure_is_ambiguous
        ] )
    ]
;;
