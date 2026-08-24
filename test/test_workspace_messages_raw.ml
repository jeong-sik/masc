module Types = Masc_domain

open Masc

let with_test_env f =
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_messages_%d_%d" (Unix.getpid ())
       (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir
  with e ->
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir;
    raise e

let test_get_messages_raw_limit_and_order () =
  with_test_env (fun config ->
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Message 1" in
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Message 2" in
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Message 3" in
    let msgs = Workspace.get_messages_raw config ~since_seq:0 ~limit:2 in
    let contents = List.map (fun (msg : Masc_domain.message) -> msg.content) msgs in
    Alcotest.(check int) "limit respected" 2 (List.length msgs);
    Alcotest.(check (list string)) "newest messages first"
      ["Message 3"; "Message 2"] contents
  )

let test_get_messages_raw_since_seq_stops_early () =
  with_test_env (fun config ->
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Message 1" in
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Message 2" in
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Message 3" in
    let baseline = Workspace.get_messages_raw config ~since_seq:0 ~limit:10 in
    let cutoff_seq =
      match baseline with
      | _latest :: second :: _ -> second.seq
      | _ -> Alcotest.fail "expected at least two messages in baseline"
    in
    let msgs = Workspace.get_messages_raw config ~since_seq:cutoff_seq ~limit:10 in
    let contents = List.map (fun (msg : Masc_domain.message) -> msg.content) msgs in
    Alcotest.(check (list string)) "only newer than since_seq"
      ["Message 3"] contents
  )

let test_get_messages_raw_large_history_keeps_newest_window () =
  with_test_env (fun config ->
    for i = 1 to 20 do
      let _ =
        Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude"
          ~content:(Printf.sprintf "Message %d" i)
      in
      ()
    done;
    let msgs = Workspace.get_messages_raw config ~since_seq:5 ~limit:3 in
    let contents = List.map (fun (msg : Masc_domain.message) -> msg.content) msgs in
    Alcotest.(check (list string)) "large history keeps newest 3"
      [ "Message 20"; "Message 19"; "Message 18" ] contents
  )

let test_repeated_mention_delivers_each_canonical_event () =
  with_test_env (fun config ->
    let previous_activity = Atomic.get Workspace_hooks.activity_emit_fn in
    let previous_wake =
      Workspace_broadcast.For_testing.replace_on_broadcast_mention
        (fun _mention -> Workspace_broadcast.Passive)
    in
    Eio.Switch.run @@ fun sw ->
    Eio.Switch.on_release sw (fun () ->
      Atomic.set Workspace_hooks.activity_emit_fn previous_activity;
      Workspace_broadcast.set_on_broadcast_mention previous_wake);
    let publications = ref [] in
    let activities = ref [] in
    let wakes = ref [] in
    let channel = Workspace.broadcast_channel config in
    (match
       Workspace.backend_subscribe config ~channel
         ~callback:(fun message -> publications := message :: !publications)
     with
     | Ok () -> ()
     | Error error ->
         Alcotest.failf "subscribe failed: %s" (Backend_types.show_error error));
    Atomic.set Workspace_hooks.activity_emit_fn
      (fun _config ~actor:_ ?subject ~kind ~payload:_ ~tags:_ () ->
        let subject =
          Option.map
            (fun (entity : Workspace_hooks.activity_entity) -> entity.id)
            subject
        in
        activities := (kind, subject) :: !activities);
    Workspace_broadcast.set_on_broadcast_mention
      (fun delivery ->
        wakes := delivery.mention :: !wakes;
        Workspace_broadcast.Accepted);
    let content = "@gemini review the canonical event" in
    ignore (Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content);
    ignore (Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content);
    let persisted =
      Workspace.get_all_messages_raw config ~since_seq:0
      |> List.filter (fun (message : Masc_domain.message) ->
        String.equal message.msg_type "broadcast"
        && String.equal message.content content)
    in
    Alcotest.(check int) "durable messages" 2 (List.length persisted);
    (match persisted with
     | first :: second :: _ ->
         Alcotest.(check bool) "distinct durable sequence" true
           (first.seq <> second.seq)
     | _ -> Alcotest.fail "expected two durable messages");
    let durable_sequences =
      persisted
      |> List.map (fun (message : Masc_domain.message) -> message.seq)
      |> List.sort Int.compare
    in
    let published_sequences =
      !publications
      |> List.map (fun envelope ->
        match
          Yojson.Safe.from_string envelope
          |> Masc_domain.message_of_yojson
        with
        | Ok (message : Masc_domain.message) -> message.seq
        | Error error ->
          Alcotest.failf "published message failed typed decode: %s" error)
      |> List.sort Int.compare
    in
    Alcotest.(check (list int))
      "each publication carries its durable sequence"
      durable_sequences
      published_sequences;
    Alcotest.(check (list (pair string (option string))))
      "each broadcast emits exact activity kinds and mention subject"
      [ ( Event_kind.Message.to_string Event_kind.Message.Broadcast
        , None )
      ; ( Event_kind.Message.to_string Event_kind.Message.Mentioned
        , Some "gemini" )
      ; ( Event_kind.Message.to_string Event_kind.Message.Broadcast
        , None )
      ; ( Event_kind.Message.to_string Event_kind.Message.Mentioned
        , Some "gemini" )
      ]
      (List.rev !activities);
    Alcotest.(check (list (option string))) "mention wake hooks"
      [ Some "gemini"; Some "gemini" ] (List.rev !wakes))

let test_failed_authoritative_write_suppresses_fanout () =
  with_test_env (fun config ->
    let previous_activity = Atomic.get Workspace_hooks.activity_emit_fn in
    let previous_observer =
      Atomic.get Workspace_hooks.workspace_broadcast_observed_fn
    in
    let previous_mention =
      Workspace_broadcast.For_testing.replace_on_broadcast_mention (fun _ ->
        Workspace_broadcast.Passive)
    in
    let previous_write =
      Workspace_broadcast.For_testing.replace_write_json_commit
        (fun _config _path _json -> Error "injected authoritative failure")
    in
    Fun.protect
      ~finally:(fun () ->
        Atomic.set Workspace_hooks.activity_emit_fn previous_activity;
        Atomic.set
          Workspace_hooks.workspace_broadcast_observed_fn
          previous_observer;
        Workspace_broadcast.set_on_broadcast_mention previous_mention;
        let (_ :
          Workspace_utils_backend_setup.config ->
          string ->
          Yojson.Safe.t ->
          (Workspace_utils.write_json_commit, string) result) =
          Workspace_broadcast.For_testing.replace_write_json_commit
            previous_write
        in
        ())
      (fun () ->
        let publications = ref 0 in
        let activities = ref 0 in
        let mentions = ref 0 in
        let observations = ref 0 in
        (match
           Workspace.backend_subscribe
             config
             ~channel:(Workspace.broadcast_channel config)
             ~callback:(fun _ -> incr publications)
         with
         | Ok () -> ()
         | Error error ->
           Alcotest.failf "subscribe failed: %s" (Backend_types.show_error error));
        Atomic.set Workspace_hooks.activity_emit_fn
          (fun _config ~actor:_ ?subject:_ ~kind:_ ~payload:_ ~tags:_ () ->
            incr activities);
        Atomic.set Workspace_hooks.workspace_broadcast_observed_fn
          (fun ~msg_type:_ ~elapsed_s:_ -> incr observations);
        Workspace_broadcast.set_on_broadcast_mention (fun _ ->
          incr mentions;
          Workspace_broadcast.Accepted);
        (match
           Workspace.broadcast ~audience:Workspace_broadcast.System_record
             config
             ~from_agent:"claude"
             ~content:"passive message must not fan out"
         with
         | Error (Workspace_broadcast.Broadcast_not_persisted detail) ->
           Alcotest.(check string)
             "typed write failure"
             "injected authoritative failure"
             detail
         | Error error ->
           Alcotest.failf
             "write failure used the wrong error variant: %s"
             (Workspace.broadcast_error_to_string error)
         | Ok _ -> Alcotest.fail "failed write reported a committed broadcast");
        Alcotest.(check int) "backend publication suppressed" 0 !publications;
        Alcotest.(check int) "activity suppressed" 0 !activities;
        Alcotest.(check int) "mention callback suppressed" 0 !mentions;
        Alcotest.(check int) "success latency observation suppressed" 0 !observations))
;;

let with_failed_message_commit f =
  let previous_write =
    Workspace_broadcast.For_testing.replace_write_json_commit
      (fun _config _path _json -> Error "injected canonical message failure")
  in
  Fun.protect
    ~finally:(fun () ->
      let (_ :
        Workspace_utils_backend_setup.config ->
        string ->
        Yojson.Safe.t ->
        (Workspace_utils.write_json_commit, string) result) =
        Workspace_broadcast.For_testing.replace_write_json_commit previous_write
      in
      ())
    f

let test_durable_outbox_defers_failed_message_commit () =
  with_test_env (fun config ->
    let previous_wake =
      Workspace_broadcast.For_testing.replace_on_broadcast_mention
        (fun _delivery -> Workspace_broadcast.Accepted)
    in
    Fun.protect
      ~finally:(fun () -> Workspace_broadcast.set_on_broadcast_mention previous_wake)
      (fun () ->
         let delivery =
           with_failed_message_commit (fun () ->
             Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude"
               ~content:"@gemini recover me"
             |> Result.get_ok)
         in
         Alcotest.(check string)
           "durably queued mention is explicitly deferred"
           "deferred"
           (Workspace_broadcast.mention_delivery_kind delivery.mention_delivery);
         let report =
           Workspace_broadcast.reconcile_pending_mentions config
           |> Result.get_ok
         in
         Alcotest.(check int) "recovery accepts retained outbox" 1 report.accepted;
         let recovered =
           Workspace.get_all_messages_raw config ~since_seq:0
           |> List.filter (fun (message : Masc_domain.message) ->
             String.equal message.request_id delivery.request_id)
         in
         Alcotest.(check int) "one canonical message is recovered" 1
           (List.length recovered)))

let test_malformed_outbox_is_quarantined_before_successor_delivery () =
  with_test_env (fun config ->
    let previous_wake =
      Workspace_broadcast.For_testing.replace_on_broadcast_mention
        (fun _delivery -> Workspace_broadcast.Accepted)
    in
    Fun.protect
      ~finally:(fun () -> Workspace_broadcast.set_on_broadcast_mention previous_wake)
      (fun () ->
    let outbox_dir =
      Filename.concat (Workspace_utils.masc_root_dir config) "message-mention-outbox"
    in
    let malformed_path = Filename.concat outbox_dir "malformed.json" in
    let successor =
      with_failed_message_commit (fun () ->
        Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude"
          ~content:"@gemini follows quarantined row"
        |> Result.get_ok)
    in
    Workspace_utils.write_json config
      malformed_path
      (`Assoc [ "unexpected", `Bool true ]);
    Alcotest.(check string)
      "successor waits in the durable outbox"
      "deferred"
      (Workspace_broadcast.mention_delivery_kind successor.mention_delivery);
    let report =
      Workspace_broadcast.reconcile_pending_mentions config
      |> Result.get_ok
    in
    Alcotest.(check bool) "quarantine releases the global barrier" false
      report.global_barrier;
    Alcotest.(check int) "malformed outbox remains observable" 1 report.corrupt_rows;
    Alcotest.(check int) "successor is delivered after quarantine" 1 report.accepted;
    let receipt =
      match report.quarantine_receipts with
      | [ receipt ] -> receipt
      | receipts ->
        Alcotest.failf "expected one quarantine receipt, got %d" (List.length receipts)
    in
    (match receipt.reason with
     | Workspace_broadcast.Malformed_filename -> ()
     | _ -> Alcotest.fail "wrong typed quarantine reason");
    Alcotest.(check bool) "corrupt source removed" false (Sys.file_exists malformed_path);
    let quarantine_path =
      Filename.concat
        (Filename.concat
           (Workspace_utils.masc_root_dir config)
           "message-mention-outbox-quarantine")
        receipt.quarantine_name
    in
    Alcotest.(check bool) "quarantine evidence committed" true
      (Sys.file_exists quarantine_path);
    let evidence = Workspace_utils.read_json config quarantine_path in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "quarantine evidence schema"
      "masc.workspace_mention_outbox_quarantine.v1"
      (evidence |> member "schema" |> to_string);
    Alcotest.(check string) "quarantine evidence source"
      "malformed.json"
      (evidence |> member "source_name" |> to_string);
    Alcotest.(check string) "quarantine evidence reason"
      "malformed_filename"
      (evidence |> member "reason" |> to_string);
    Alcotest.(check string) "quarantine evidence raw digest"
      receipt.raw_sha256
      (evidence |> member "raw_sha256" |> to_string);
    let encoded_raw = evidence |> member "raw_base64" |> to_string in
    Alcotest.(check string) "quarantine evidence preserves raw row"
      (Yojson.Safe.to_string (`Assoc [ "unexpected", `Bool true ]))
      (encoded_raw |> Base64.decode_exn |> Yojson.Safe.from_string
       |> Yojson.Safe.to_string)))

let test_startup_schema_preflight_rejects_unpurged_message () =
  with_test_env (fun config ->
    let old_row =
      `Assoc
        [ "seq", `Int 1
        ; "from_agent", `String "claude"
        ; "content", `String "pre-current-schema"
        ; "timestamp", `Float 1.0
        ; "mention", `Null
        ; "msg_type", `String "broadcast"
        ]
    in
    Workspace_utils.write_json
      config
      (Filename.concat
         (Workspace_utils.messages_dir config)
         "000000001_claude_old_broadcast.json")
      old_row;
    match Workspace_broadcast.validate_current_message_schema config with
    | Ok () -> Alcotest.fail "unpurged old message schema passed startup preflight"
    | Error [ rejection ] ->
      (match rejection.kind with
       | Workspace_broadcast.Message_row_incompatible -> ()
       | _ -> Alcotest.fail "old message row had the wrong rejection kind")
    | Error rejections ->
      Alcotest.failf "expected one schema rejection, got %d" (List.length rejections))

(* The delivery handler is the only place that sees a committed message. The
   dispatcher used to answer [Passive] for an unmentioned broadcast without
   calling the handler at all, so anything the handler does for the fleet —
   projecting the message into every Keeper's window — was wired to a call
   that never happened. *)
let test_unmentioned_broadcast_reaches_the_delivery_handler () =
  with_test_env (fun config ->
    let seen = ref [] in
    let previous =
      Workspace_broadcast.For_testing.replace_on_broadcast_mention
        (fun (delivery : Workspace_broadcast.broadcast_delivery) ->
           seen := delivery.content :: !seen;
           Workspace_broadcast.Passive)
    in
    Fun.protect
      ~finally:(fun () -> Workspace_broadcast.set_on_broadcast_mention previous)
      (fun () ->
        match
          Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude"
            ~content:"fleet announcement with no mention"
        with
        | Error _ -> Alcotest.fail "broadcast was not persisted"
        | Ok delivery ->
          Alcotest.(check bool)
            "an unmentioned broadcast stays a passive mention delivery" true
            (delivery.mention_delivery = Workspace_broadcast.Passive);
          Alcotest.(check (list string))
            "the handler saw the committed message"
            [ "fleet announcement with no mention" ]
            !seen))

(* [limit] must count the messages a caller asked FOR, not the messages the
   store happened to read. When one agent's traffic fills the window, a caller
   that filters afterwards gets nothing back however large a window it asks
   for — every call site that filtered this way had grown its own multiplier
   (200, 2000, limit*5, limit*10 capped at 1000) and each one fails at some
   fleet size. The first assertion pins the behaviour that forced those
   multipliers; the rest pin the filtered read that removes the need for them. *)
let test_get_messages_matching_counts_matches_not_reads () =
  with_test_env (fun config ->
    let mine (m : Masc_domain.message) = String.equal m.from_agent "claude" in
    let say from_agent content =
      ignore
        (Workspace.broadcast
           ~audience:Workspace_broadcast.System_record
           config
           ~from_agent
           ~content)
    in
    say "claude" "mine 1";
    say "claude" "mine 2";
    for i = 1 to 20 do
      say "other" (Printf.sprintf "other %d" i)
    done;
    let unfiltered = Workspace.get_messages_raw config ~since_seq:0 ~limit:5 in
    Alcotest.(check int)
      "an unfiltered window of 5 holds none of this agent's messages"
      0
      (List.length (List.filter mine unfiltered));
    let matched =
      Workspace.get_messages_matching config ~since_seq:0 ~limit:5 ~keep:mine
    in
    Alcotest.(check int)
      "the filtered read returns every match under the limit"
      2
      (List.length matched);
    Alcotest.(check (list string))
      "matches come back newest first"
      [ "mine 2"; "mine 1" ]
      (List.map (fun (m : Masc_domain.message) -> m.content) matched))

let test_get_messages_matching_limit_bounds_matches () =
  with_test_env (fun config ->
    let mine (m : Masc_domain.message) = String.equal m.from_agent "claude" in
    let say from_agent content =
      ignore
        (Workspace.broadcast
           ~audience:Workspace_broadcast.System_record
           config
           ~from_agent
           ~content)
    in
    for i = 1 to 8 do
      say "claude" (Printf.sprintf "mine %d" i);
      say "other" (Printf.sprintf "other %d" i)
    done;
    let matched =
      Workspace.get_messages_matching config ~since_seq:0 ~limit:3 ~keep:mine
    in
    Alcotest.(check int) "limit bounds the matches" 3 (List.length matched);
    Alcotest.(check (list string))
      "and keeps the newest of them"
      [ "mine 8"; "mine 7"; "mine 6" ]
      (List.map (fun (m : Masc_domain.message) -> m.content) matched))

let () =
  Alcotest.run "Workspace raw message regression" [
    ("messages_raw", [
      Alcotest.test_case "limit and newest-first ordering" `Quick
        test_get_messages_raw_limit_and_order;
      Alcotest.test_case "since_seq filters older history" `Quick
        test_get_messages_raw_since_seq_stops_early;
      Alcotest.test_case "large history keeps newest window" `Quick
        test_get_messages_raw_large_history_keeps_newest_window;
      Alcotest.test_case "identical mentions each deliver" `Quick
        test_repeated_mention_delivers_each_canonical_event;
      Alcotest.test_case "failed write suppresses fanout" `Quick
        test_failed_authoritative_write_suppresses_fanout;
      Alcotest.test_case "durable outbox defers failed message commit" `Quick
        test_durable_outbox_defers_failed_message_commit;
      Alcotest.test_case "malformed outbox quarantines before successor" `Quick
        test_malformed_outbox_is_quarantined_before_successor_delivery;
      Alcotest.test_case "startup rejects unpurged message schema" `Quick
        test_startup_schema_preflight_rejects_unpurged_message;
      Alcotest.test_case "unmentioned broadcast reaches the delivery handler" `Quick
        test_unmentioned_broadcast_reaches_the_delivery_handler;
      Alcotest.test_case "filtered read counts matches not reads" `Quick
        test_get_messages_matching_counts_matches_not_reads;
      Alcotest.test_case "filtered read bounds matches by limit" `Quick
        test_get_messages_matching_limit_bounds_matches;
    ]);
  ]
