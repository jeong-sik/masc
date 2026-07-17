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
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Message 1" in
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Message 2" in
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Message 3" in
    let msgs = Workspace.get_messages_raw config ~since_seq:0 ~limit:2 in
    let contents = List.map (fun (msg : Masc_domain.message) -> msg.content) msgs in
    Alcotest.(check int) "limit respected" 2 (List.length msgs);
    Alcotest.(check (list string)) "newest messages first"
      ["Message 3"; "Message 2"] contents
  )

let test_get_messages_raw_since_seq_stops_early () =
  with_test_env (fun config ->
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Message 1" in
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Message 2" in
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Message 3" in
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
        Workspace.broadcast config ~from_agent:"claude"
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
    let previous_wake = !Workspace_broadcast.on_broadcast_mention in
    Eio.Switch.run @@ fun sw ->
    Eio.Switch.on_release sw (fun () ->
      Atomic.set Workspace_hooks.activity_emit_fn previous_activity;
      Workspace_broadcast.on_broadcast_mention := previous_wake);
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
    Workspace_broadcast.on_broadcast_mention :=
      (fun mention -> wakes := mention :: !wakes);
    let content = "@gemini review the canonical event" in
    ignore (Workspace.broadcast config ~from_agent:"claude" ~content);
    ignore (Workspace.broadcast config ~from_agent:"claude" ~content);
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
    ]);
  ]
