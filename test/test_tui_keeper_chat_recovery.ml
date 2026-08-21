open Alcotest

module Chat = Masc_tui_keeper_chat_projection
module Recovery = Masc_tui_keeper_chat_recovery

let request () = Chat.create_request ~keeper_name:"keeper.one" ~message:"hello"

let with_base name f =
  let base_path = Filename.temp_dir ("tui-chat-recovery-" ^ name) "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    f base_path)

let test_round_trip_and_clear () =
  with_base "roundtrip" @@ fun base_path ->
  let expected = request () in
  check (result unit string) "persist" (Ok ())
    (Recovery.persist_pending ~base_path expected);
  let path = Recovery.recovery_path ~base_path in
  check int "private mode" 0o600 ((Unix.stat path).st_perm land 0o777);
  (match Recovery.load_pending ~base_path with
   | Ok (Some observed) ->
       check bool "exact request" true (Chat.same_request_identity expected observed)
   | Ok None -> fail "persisted recovery request disappeared"
   | Error detail -> fail detail);
  check (result unit string) "clear" (Ok ())
    (Recovery.clear_pending ~base_path expected);
  check bool "removed" false (Fs_compat.file_exists path)

let test_conflict_fails_closed () =
  with_base "conflict" @@ fun base_path ->
  let first = request () in
  let second = request () in
  check (result unit string) "first persist" (Ok ())
    (Recovery.persist_pending ~base_path first);
  (match Recovery.persist_pending ~base_path second with
   | Error _ -> ()
   | Ok () -> fail "a second request replaced the active recovery fence");
  (match Recovery.clear_pending ~base_path second with
   | Error _ -> ()
   | Ok () -> fail "a different request cleared the active recovery fence");
  match Recovery.load_pending ~base_path with
  | Ok (Some observed) ->
      check bool "first fence retained" true
        (Chat.same_request_identity first observed)
  | Ok None -> fail "conflict removed the first fence"
  | Error detail -> fail detail

let test_malformed_fails_closed () =
  with_base "malformed" @@ fun base_path ->
  let path = Recovery.recovery_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path
    {|{"schema":"masc.tui_keeper_chat_recovery.v1","request_id":"bad","keeper_name":"keeper.one","message":"hello","extra":true}|};
  match Recovery.load_pending ~base_path with
  | Error _ -> ()
  | Ok _ -> fail "malformed recovery record was accepted"

let test_bounded_poll_budget () =
  check int "positive budget" 40 Recovery.max_reconciliation_polls;
  check bool "decrement" true
    (Recovery.next_reconciliation_poll ~remaining:2 = `Poll 1);
  check bool "stop at last attempt" true
    (Recovery.next_reconciliation_poll ~remaining:1 = `Stop);
  check bool "stop exhausted" true
    (Recovery.next_reconciliation_poll ~remaining:0 = `Stop)

let () =
  run "tui_keeper_chat_recovery"
    [ ( "recovery"
      , [ test_case "round trip and clear" `Quick test_round_trip_and_clear
        ; test_case "conflict fails closed" `Quick test_conflict_fails_closed
        ; test_case "malformed fails closed" `Quick test_malformed_fails_closed
        ; test_case "bounded poll budget" `Quick test_bounded_poll_budget
        ] )
    ]
