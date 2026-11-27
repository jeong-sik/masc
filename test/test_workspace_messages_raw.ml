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

let test_postcommit_observer_failure_keeps_durable_receipt () =
  with_test_env (fun config ->
    let previous = Atomic.get Workspace_hooks.on_workspace_message_mutation_fn in
    let observed = ref [] in
    Fun.protect ~finally:(fun () ->
      Atomic.set Workspace_hooks.on_workspace_message_mutation_fn previous)
      (fun () ->
        Atomic.set Workspace_hooks.on_workspace_message_mutation_fn
          (fun _config ~request_id ~mention_delivery:_ ->
            observed := request_id :: !observed;
            failwith "injected postcommit observation failure");
        let content = "The committed report remains available despite observer failure" in
        let receipt = match Workspace.broadcast ~audience:Workspace_broadcast.System_record
            config ~from_agent:"claude" ~content with
          | Ok receipt -> receipt
          | Error error -> Alcotest.failf "committed Broadcast lost its receipt: %s"
              (Workspace_broadcast.broadcast_error_to_string error) in
        let persisted = Workspace.get_all_messages_raw config ~since_seq:0
          |> List.filter (fun (message : Masc_domain.message) -> message.content=content) in
        match persisted with
        | [message] ->
            Alcotest.(check string) "receipt request id identifies the committed row"
              message.request_id receipt.request_id;
            Alcotest.(check int) "receipt sequence identifies the committed row"
              message.seq receipt.seq;
            Alcotest.(check (list string)) "postcommit observer actually raised for that row"
              [receipt.request_id] !observed
        | _ -> Alcotest.fail "expected exactly one durable Broadcast despite the raised observer"))

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
      Filename.concat (Workspace_utils.masc_dir config) "message-mention-outbox"
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
           (Workspace_utils.masc_dir config)
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

let test_get_messages_raw_large_directory_metered_yields_and_order () =
  with_test_env (fun config ->
    let template =
      match
        Workspace.broadcast
          ~audience:Workspace_broadcast.System_record
          config
          ~from_agent:"claude"
          ~content:"seed"
      with
      | Error error ->
        Alcotest.failf
          "seed broadcast failed: %s"
          (Workspace_broadcast.broadcast_error_to_string error)
      | Ok _ ->
        (match Workspace.get_messages_raw config ~since_seq:0 ~limit:1 with
         | [ msg ] -> msg
         | rows -> Alcotest.failf "expected 1 seed message, got %d" (List.length rows))
    in
    let msgs_dir = Workspace_utils.messages_dir config in
    let write_stub seq =
      let path =
        Filename.concat msgs_dir (Printf.sprintf "%09d_claude_stub.json" seq)
      in
      Out_channel.with_open_bin path (fun ch -> output_string ch "{}")
    in
    let write_msg seq content =
      let path =
        Filename.concat msgs_dir (Printf.sprintf "%09d_claude_broadcast.json" seq)
      in
      let msg =
        { template with
          seq
        ; content
        ; request_id = Printf.sprintf "req-%09d" seq
        }
      in
      Workspace_utils.write_json config path (Masc_domain.message_to_yojson msg)
    in
    for seq = 2 to 2480 do
      write_stub seq
    done;
    Out_channel.with_open_bin
      (Filename.concat msgs_dir "ignored_non_numeric.json")
      (fun ch -> output_string ch "{}");
    for seq = 2481 to 2500 do
      write_msg seq (Printf.sprintf "msg-%d" seq)
    done;
    Alcotest.(check int)
      "limit=0 returns empty immediately"
      0
      (List.length (Workspace.get_messages_raw config ~since_seq:0 ~limit:0));
    let top20 = Workspace.get_messages_raw config ~since_seq:0 ~limit:20 in
    Alcotest.(check (list int))
      "newest 20 messages selected in descending seq order"
      (List.init 20 (fun idx -> 2500 - idx))
      (List.map (fun (m : Masc_domain.message) -> m.seq) top20);
    let since2495 = Workspace.get_messages_raw config ~since_seq:2495 ~limit:20 in
    Alcotest.(check (list int))
      "since_seq filters older messages"
      [ 2500; 2499; 2498; 2497; 2496 ]
      (List.map (fun (m : Masc_domain.message) -> m.seq) since2495);
    Alcotest.(check (list int))
      "limit=1 returns the single newest message"
      [ 2500 ]
      (List.map
         (fun (m : Masc_domain.message) -> m.seq)
         (Workspace.get_messages_raw config ~since_seq:0 ~limit:1));
    (* Measure metered yielding during a cold 2501-file scan alone by using
       [since_seq:2500] after clearing the settled dir cache so the scan runs
       deterministically even on slow CI runners where >50ms may have elapsed
       since [write_msg 2500], without opening any message file via
       [Fs_compat.load_file]. *)
    Workspace.clear_message_dir_cache ();
    let done_flag = Atomic.make false in
    let rival_ticks = ref 0 in
    let empty_ref = ref [] in
    Eio.Fiber.both
      (fun () ->
         Fun.protect
           ~finally:(fun () -> Atomic.set done_flag true)
           (fun () ->
              empty_ref := Workspace.get_messages_raw config ~since_seq:2500 ~limit:1))
      (fun () ->
         while not (Atomic.get done_flag) do
           incr rival_ticks;
           Eio.Fiber.yield ()
         done);
    Alcotest.(check int)
      "since_seq at head returns empty without reading files"
      0
      (List.length !empty_ref);
    Alcotest.(check bool)
      "metered yield still cooperates on 2500-file scan"
      true
      (!rival_ticks >= 2);
    Alcotest.(check bool)
      "metered yield avoids per-file yield storm"
      true
      (!rival_ticks <= 20))

let write_fixture_message ~template ~msgs_dir ~filename ~seq ~from_agent ~content =
  let msg =
    { template with
      Masc_domain.seq
    ; from_agent
    ; content
    ; request_id = Printf.sprintf "req-%s" filename
    }
  in
  let path = Filename.concat msgs_dir filename in
  let json_str = Yojson.Safe.to_string (Masc_domain.message_to_yojson msg) in
  Out_channel.with_open_bin path (fun ch -> output_string ch json_str);
  path

let seed_template config =
  match
    Workspace.broadcast
      ~audience:Workspace_broadcast.System_record
      config
      ~from_agent:"claude"
      ~content:"seed"
  with
  | Error error ->
    Alcotest.failf
      "seed broadcast failed: %s"
      (Workspace_broadcast.broadcast_error_to_string error)
  | Ok _ ->
    (match Workspace.get_messages_raw config ~since_seq:0 ~limit:1 with
     | [ msg ] -> msg
     | rows -> Alcotest.failf "expected 1 seed message, got %d" (List.length rows))

let test_dir_cache_parity_with_select_recent_message_names () =
  with_test_env (fun config ->
    let template = seed_template config in
    let msgs_dir = Workspace_utils.messages_dir config in
    (* Remove the initial broadcast file so we control every filename explicitly. *)
    Array.iter (fun name -> Unix.unlink (Filename.concat msgs_dir name)) (Sys.readdir msgs_dir);
    let specs =
      [ "000000005_alpha_broadcast.json", 5, "alpha", "m5-a"
      ; "000000010_alpha_broadcast.json", 10, "alpha", "m10-a"
      ; "000000010_zeta_broadcast.json", 10, "zeta", "m10-z"
      ; "000000010_mid_broadcast.json", 10, "mid", "m10-m"
      ; "000000012_beta_broadcast.json", 12, "beta", "m12-b"
      ; "000000015_alpha_broadcast.json", 15, "alpha", "m15-a"
      ]
    in
    List.iter
      (fun (filename, seq, from_agent, content) ->
         ignore (write_fixture_message ~template ~msgs_dir ~filename ~seq ~from_agent ~content))
      specs;
    (* Add stray/ignored files that must be skipped identically. *)
    Out_channel.with_open_bin
      (Filename.concat msgs_dir "000000099_alpha_broadcast.json.tmp-atomic")
      (fun ch -> output_string ch "{}");
    Out_channel.with_open_bin
      (Filename.concat msgs_dir "invalid name with spaces_broadcast.json")
      (fun ch -> output_string ch "{}");
    Out_channel.with_open_bin
      (Filename.concat msgs_dir "not_a_message.json")
      (fun ch -> output_string ch "{}");
    let valid_names_asc =
      Sys.readdir msgs_dir
      |> Array.to_list
      |> List.filter Workspace.is_valid_filename
      |> List.sort String.compare
    in
    let valid_names_desc = List.rev valid_names_asc in
    let content_of_name name =
      match List.find_opt (fun (n, _, _, _) -> String.equal n name) specs with
      | Some (_, _, _, content) -> content
      | None -> Alcotest.failf "unexpected selected name %s" name
    in
    (* Let directory settle so cached path runs. *)
    Unix.sleepf 0.08;
    Workspace.clear_message_dir_cache ();
    (* Check parity across combinations of since_seq and limit, including tie-breaks. *)
    let cases =
      [ 0, 0
      ; 0, 1
      ; 0, 2
      ; 0, 3
      ; 0, 4
      ; 0, 10
      ; 5, 2
      ; 5, 4
      ; 9, 2
      ; 10, 5
      ; 12, 5
      ; 15, 5
      ]
    in
    List.iter
      (fun (since_seq, limit) ->
         let uncached_asc =
           Workspace.select_recent_message_names ~since_seq ~limit valid_names_asc
           |> List.map content_of_name
         in
         let uncached_desc =
           Workspace.select_recent_message_names ~since_seq ~limit valid_names_desc
           |> List.map content_of_name
         in
         Alcotest.(check (list string))
           (Printf.sprintf "select_recent_message_names order-independent since=%d limit=%d"
              since_seq limit)
           uncached_asc uncached_desc;
         let cached =
           Workspace.get_messages_raw config ~since_seq ~limit
           |> List.map (fun (m : Masc_domain.message) -> m.content)
         in
         Alcotest.(check (list string))
           (Printf.sprintf "cached get_messages_raw matches uncached since=%d limit=%d"
              since_seq limit)
           uncached_asc cached)
      cases;
    (* Verify tie-breaking order explicitly on seq=10: zeta > mid > alpha newest-first. *)
    let seq10_top2 =
      Workspace.get_messages_raw config ~since_seq:5 ~limit:4
      |> List.map (fun (m : Masc_domain.message) -> m.content)
    in
    Alcotest.(check (list string))
      "seq=10 tie-break newest-first is zeta then mid"
      [ "m15-a"; "m12-b"; "m10-z"; "m10-m" ]
      seq10_top2;
    (* Verify get_all_messages_raw oldest-first is exact reverse (alpha, mid, zeta). *)
    let all_since_5 =
      Workspace.get_all_messages_raw config ~since_seq:5
      |> List.map (fun (m : Masc_domain.message) -> m.content)
    in
    Alcotest.(check (list string))
      "get_all_messages_raw oldest-first reverses tie-break cleanly"
      [ "m10-a"; "m10-m"; "m10-z"; "m12-b"; "m15-a" ]
      all_since_5;
    (* Verify get_messages_matching hits same deterministic order. *)
    let matching_alpha =
      Workspace.get_messages_matching config ~since_seq:0 ~limit:3
        ~keep:(fun m -> String.equal m.from_agent "alpha")
      |> List.map (fun (m : Masc_domain.message) -> m.content)
    in
    Alcotest.(check (list string))
      "get_messages_matching preserves newest-first order"
      [ "m15-a"; "m10-a"; "m5-a" ]
      matching_alpha)

let test_dir_cache_hit_and_mutation_invalidation () =
  with_test_env (fun config ->
    let template = seed_template config in
    let msgs_dir = Workspace_utils.messages_dir config in
    Array.iter (fun name -> Unix.unlink (Filename.concat msgs_dir name)) (Sys.readdir msgs_dir);
    ignore
      (write_fixture_message ~template ~msgs_dir
         ~filename:"000000001_claude_broadcast.json" ~seq:1 ~from_agent:"claude" ~content:"msg-1");
    let p2 =
      write_fixture_message ~template ~msgs_dir
        ~filename:"000000002_claude_broadcast.json" ~seq:2 ~from_agent:"claude" ~content:"msg-2"
    in
    ignore
      (write_fixture_message ~template ~msgs_dir
         ~filename:"000000003_claude_broadcast.json" ~seq:3 ~from_agent:"claude" ~content:"msg-3");
    (* Wait past 50ms settle window, then clear cache to observe cold->warm transition. *)
    Unix.sleepf 0.08;
    Workspace.clear_message_dir_cache ();
    let h0, m0, c0 = Workspace.message_dir_cache_stats () in
    Alcotest.(check int) "cache starts empty after clear" 0 c0;
    (* Cold call on settled dir: miss + populate. *)
    let r1 = Workspace.get_messages_raw config ~since_seq:0 ~limit:3 in
    let h1, m1, c1 = Workspace.message_dir_cache_stats () in
    Alcotest.(check int) "cold call records 1 miss" (m0 + 1) m1;
    Alcotest.(check int) "cold call records 0 hits" h0 h1;
    Alcotest.(check int) "settled dir is cached" 1 c1;
    Alcotest.(check (list int)) "cold call returns seqs" [ 3; 2; 1 ]
      (List.map (fun (m : Masc_domain.message) -> m.seq) r1);
    (* Subsequent calls across all 3 query surfaces must hit the dir cache. *)
    let r2 = Workspace.get_messages_raw config ~since_seq:0 ~limit:2 in
    let r3 = Workspace.get_messages_raw config ~since_seq:3 ~limit:2 in
    let r4 =
      Workspace.get_messages_matching config ~since_seq:0 ~limit:2
        ~keep:(fun (m : Masc_domain.message) -> m.seq mod 2 = 1)
    in
    let r5 = Workspace.get_all_messages_raw config ~since_seq:1 in
    let h2, m2, c2 = Workspace.message_dir_cache_stats () in
    Alcotest.(check int) "4 warm calls all hit cache" (h1 + 4) h2;
    Alcotest.(check int) "0 extra misses on settled dir" m1 m2;
    Alcotest.(check int) "single dir entry remains cached" 1 c2;
    Alcotest.(check (list int)) "warm raw top2" [ 3; 2 ]
      (List.map (fun (m : Masc_domain.message) -> m.seq) r2);
    Alcotest.(check int) "warm raw at head is empty" 0 (List.length r3);
    Alcotest.(check (list int)) "warm matching odd seqs" [ 3; 1 ]
      (List.map (fun (m : Masc_domain.message) -> m.seq) r4);
    Alcotest.(check (list int)) "warm all oldest-first" [ 2; 3 ]
      (List.map (fun (m : Masc_domain.message) -> m.seq) r5);
    (* Adding a file invalidates immediately (even before 50ms settle). *)
    ignore
      (write_fixture_message ~template ~msgs_dir
         ~filename:"000000004_claude_broadcast.json" ~seq:4 ~from_agent:"claude" ~content:"msg-4");
    let r_added = Workspace.get_messages_raw config ~since_seq:0 ~limit:2 in
    let h3, m3, _ = Workspace.message_dir_cache_stats () in
    Alcotest.(check int) "file addition bypasses stale cache" h2 h3;
    Alcotest.(check int) "file addition increments miss" (m2 + 1) m3;
    Alcotest.(check (list int)) "newly added message visible immediately" [ 4; 3 ]
      (List.map (fun (m : Masc_domain.message) -> m.seq) r_added);
    (* Re-settle, warm cache again, then delete a file and verify immediate invalidation. *)
    Unix.sleepf 0.08;
    ignore (Workspace.get_messages_raw config ~since_seq:0 ~limit:4);
    let h4, m4, c4 = Workspace.message_dir_cache_stats () in
    Alcotest.(check int) "re-settled dir cached again" 1 c4;
    Unix.unlink p2;
    let r_removed = Workspace.get_messages_raw config ~since_seq:0 ~limit:4 in
    let h5, m5, _ = Workspace.message_dir_cache_stats () in
    Alcotest.(check int) "file removal bypasses stale cache" h4 h5;
    Alcotest.(check int) "file removal increments miss" (m4 + 1) m5;
    Alcotest.(check (list int)) "removed message disappears immediately" [ 4; 3; 1 ]
      (List.map (fun (m : Masc_domain.message) -> m.seq) r_removed))

let test_dir_cache_missing_nondir_and_symlink_eviction () =
  with_test_env (fun config ->
    let template = seed_template config in
    let msgs_dir = Workspace_utils.messages_dir config in
    ignore
      (write_fixture_message ~template ~msgs_dir
         ~filename:"000000002_claude_broadcast.json" ~seq:2 ~from_agent:"claude" ~content:"msg-2");
    Unix.sleepf 0.08;
    Workspace.clear_message_dir_cache ();
    ignore (Workspace.get_messages_raw config ~since_seq:0 ~limit:5);
    let _, _, c_warm = Workspace.message_dir_cache_stats () in
    Alcotest.(check int) "populated before removal" 1 c_warm;
    (* 1. Missing directory (ENOENT): returns [] and evicts cache entry. *)
    Array.iter (fun name -> Unix.unlink (Filename.concat msgs_dir name)) (Sys.readdir msgs_dir);
    Unix.rmdir msgs_dir;
    let missing_msgs = Workspace.get_messages_raw config ~since_seq:0 ~limit:5 in
    let _, _, c_missing = Workspace.message_dir_cache_stats () in
    Alcotest.(check int) "missing dir returns empty" 0 (List.length missing_msgs);
    Alcotest.(check int) "missing dir evicts cache entry" 0 c_missing;
    let missing_all = Workspace.get_all_messages_raw config ~since_seq:0 in
    Alcotest.(check int) "get_all_messages_raw missing dir returns empty" 0
      (List.length missing_all);
    (* 2. Regular file at msgs_dir (non-dir): fails closed with Sys_error, does not cache. *)
    Out_channel.with_open_bin msgs_dir (fun ch -> output_string ch "not a dir");
    let raised_sys_error =
      try
        ignore (Workspace.get_messages_raw config ~since_seq:0 ~limit:5);
        false
      with Sys_error _ -> true
    in
    let _, _, c_nondir = Workspace.message_dir_cache_stats () in
    Alcotest.(check bool) "regular file at msgs_dir fails closed with Sys_error"
      true raised_sys_error;
    Alcotest.(check int) "non-dir is never cached" 0 c_nondir;
    Unix.unlink msgs_dir;
    (* 3. Symlink to a real settled directory: reads uncached, never caches symlink. *)
    let target_dir = Filename.concat (Filename.dirname msgs_dir) "messages-symlink-target" in
    Unix.mkdir target_dir 0o755;
    Fun.protect
      ~finally:(fun () ->
        (try Unix.unlink msgs_dir with Unix.Unix_error _ -> ());
        (try
           Array.iter
             (fun name -> Unix.unlink (Filename.concat target_dir name))
             (Sys.readdir target_dir);
           Unix.rmdir target_dir
         with Sys_error _ | Unix.Unix_error _ -> ());
        (* Restore a clean empty messages dir so with_test_env cleanup succeeds. *)
        (try Unix.mkdir msgs_dir 0o755 with Unix.Unix_error _ -> ()))
      (fun () ->
        ignore
          (write_fixture_message ~template ~msgs_dir:target_dir
             ~filename:"000000007_claude_broadcast.json" ~seq:7 ~from_agent:"claude"
             ~content:"via-symlink");
        Unix.symlink target_dir msgs_dir;
        Unix.sleepf 0.08;
        let sym_msgs = Workspace.get_messages_raw config ~since_seq:0 ~limit:5 in
        let _, _, c_sym = Workspace.message_dir_cache_stats () in
        Alcotest.(check (list int)) "symlink target still readable uncached" [ 7 ]
          (List.map (fun (m : Masc_domain.message) -> m.seq) sym_msgs);
        Alcotest.(check int) "symlink dir is never cached" 0 c_sym;
        (* 4. Dangling symlink: returns [] cleanly without caching. *)
        Unix.unlink msgs_dir;
        Unix.symlink (Filename.concat (Filename.dirname msgs_dir) "does-not-exist") msgs_dir;
        let dangling_msgs = Workspace.get_messages_raw config ~since_seq:0 ~limit:5 in
        let _, _, c_dangling = Workspace.message_dir_cache_stats () in
        Alcotest.(check int) "dangling symlink returns empty" 0 (List.length dangling_msgs);
        Alcotest.(check int) "dangling symlink is never cached" 0 c_dangling))

let () =
  Alcotest.run "Workspace raw message regression" [
    ("messages_raw", [
      Alcotest.test_case "postcommit observer failure preserves durable receipt" `Quick
        test_postcommit_observer_failure_keeps_durable_receipt;
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
      Alcotest.test_case "large directory metered yields and order" `Quick
        test_get_messages_raw_large_directory_metered_yields_and_order;
      Alcotest.test_case "dir cache parity with uncached select_recent_message_names" `Quick
        test_dir_cache_parity_with_select_recent_message_names;
      Alcotest.test_case "dir cache hit on settled dir and mutation invalidation" `Quick
        test_dir_cache_hit_and_mutation_invalidation;
      Alcotest.test_case "dir cache missing non-dir and symlink eviction" `Quick
        test_dir_cache_missing_nondir_and_symlink_eviction;
    ]);
  ]
