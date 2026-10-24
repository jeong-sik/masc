open Alcotest
module A=Telegram_rest_client
module C=Telegram_poll_custody
let ok = function Ok value -> value | Error error -> fail (Format.asprintf "%a" C.pp_error error)
let api_ok = function Ok value -> value | Error error -> fail (Format.asprintf "%a" A.pp_error error)
let with_cursor f =
  let dir=Filename.temp_dir "telegram-custody-" "" in
  let path=Filename.concat dir "cursor.json" in
  Fun.protect ~finally:(fun () -> Array.iter (fun name ->
    let file=Filename.concat dir name in
    if Sys.is_directory file then Unix.rmdir file else Sys.remove file) (Sys.readdir dir);Unix.rmdir dir)
    (fun () -> Eio_main.run (fun _ -> f path))
let client token = A.create ~token |> api_ok
let envelope json = Yojson.Safe.to_string (`Assoc["ok",`Bool true;"result",json])
let identity id = envelope (`Assoc["id",`Int id;"is_bot",`Bool true;"first_name",`String "Bot"])
let page ids = envelope (`List(List.map (fun id -> `Assoc["update_id",`Int id]) ids))
let transport ?(bot_id=777) ~offsets ids ~url ~body =
  match Filename.basename (Uri.path (Uri.of_string url)) with
  | "getMe" -> Ok (200,identity bot_id)
  | "getUpdates" ->
    offsets:=!offsets @ [Yojson.Safe.Util.member "offset" (Yojson.Safe.from_string body)];
    Ok(200,page ids)
  | method_name -> fail ("unexpected API method " ^ method_name)
let receipt ?(status=Gate_protocol.Queued) operation_id : Gate_protocol.outbound_message =
  {keeper_name="keeper";content="accepted";structured=None;turn_stats=None;
   message_request=Some {request_id=operation_id;destination_type="keeper";destination_id="keeper";
     channel="telegram";actor_id=None;status;modalities=["text"];transport=Some "telegram";metadata=[]}}
let accept ~operation_id _ = Ok (C.Accepted(receipt operation_id))
let offset_on_disk path = Yojson.Safe.Util.member "next_offset" (Yojson.Safe.from_string(Fs_compat.load_file path))
let test_frontier_restart_and_rotation () = with_cursor (fun path ->
  let offsets=ref [] in let post=transport ~offsets [10;11;12] in
  let t=C.open_cursor ~post ~client:(client "token-A") ~path () |> ok in
  let calls=ref [] in
  let stop ~operation_id update =
    calls:=!calls @ [update.A.update_id];
    if update.update_id=11L then Error "durable submit unavailable"
    else accept ~operation_id update in
  (match C.step ~post t ~poll_timeout_sec:0 ~accept:stop () with
   | Error(C.Acceptance_refused {update_id=11L;_}) -> () | _ -> fail "refusal frontier crossed");
  check (list int64) "later update never submitted" [10L;11L] !calls;
  check bool "only committed predecessor persisted" true (offset_on_disk path=`Int 11);
  let post=transport ~offsets [11;12] in
  let rotated=C.open_cursor ~post ~client:(client "token-B") ~path () |> ok in
  check int64 "actual bot identity survives credential rotation" 777L (C.bot_user_id rotated);
  let update={A.update_id=11L;kind=A.Unsupported} in
  check string "operation identity independent of token" (C.operation_id t update) (C.operation_id rotated update);
  let result=C.step ~post rotated ~poll_timeout_sec:0 ~accept () |> ok in
  check int "remaining accepted" 2 result.accepted;
  check (option int64) "next confirmed frontier" (Some 13L) result.next_offset;
  check bool "wire acknowledges only persisted predecessors" true (!offsets=[`Null;`Int 11]);
  check bool "final persisted offset" true (offset_on_disk path=`Int 13))
let test_unconfirmed_and_wrong_receipts () =
  List.iter (fun corrupt -> with_cursor (fun path ->
    let offsets=ref [] in let post=transport ~offsets [10;11] in
    let t=C.open_cursor ~post ~client:(client "token") ~path () |> ok in
    let accepted=ref [] in
    let accept ~operation_id update = accepted:=update.A.update_id::!accepted;Ok(C.Accepted(corrupt(receipt operation_id))) in
    (match C.step ~post t ~poll_timeout_sec:0 ~accept () with
     | Error(C.Acceptance_refused {update_id=10L;_}) -> () | _ -> fail "unconfirmed receipt accepted");
    check (list int64) "no later submit" [10L] !accepted;
    check bool "no cursor publication" false (Sys.file_exists path)))
    [ (fun m -> {m with Gate_protocol.message_request=None});
      (fun m -> {m with message_request=Option.map (fun r -> {r with Gate_protocol.request_id="wrong"}) m.message_request});
      (fun m -> {m with message_request=Option.map (fun r -> {r with Gate_protocol.channel="slack"}) m.message_request});
      (fun m -> {m with keeper_name="other"});
      (fun m -> {m with message_request=Option.map (fun r -> {r with Gate_protocol.status=Acceptance_uncertain}) m.message_request});
      (fun m -> {m with message_request=Option.map (fun r -> {r with Gate_protocol.status=Lost}) m.message_request}) ]
let test_wrong_bot_and_corrupt_cursor () = with_cursor (fun path ->
  let offsets=ref [] in let post=transport ~offsets [1] in
  List.iter (fun body ->
    Fs_compat.save_file path body;
    (match C.open_cursor ~post ~client:(client "token") ~path () with
     | Error(C.Cursor_refused _) -> () | _ -> fail "invalid cursor accepted"))
    [ {|{"schema_version":1,"bot_user_id":778,"next_offset":100}|};
      {|{"schema_version":1,"bot_user_id":777,"next_offset":-1}|};
      {|{"schema_version":1,"bot_user_id":777,"next_offset":2,"next_offset":99}|};
      {|{"schema_version":1,"bot_user_id":777,"next_offset":2,"extra":1}|};
      {|{"schema_version":0,"bot_user_id":777,"next_offset":2}|};
      {|{"schema_version":1,"bot_user_id":777}|};"not JSON" ];
  check int "invalid state never reaches getUpdates" 0 (List.length !offsets))
let test_stale_concurrent_page () = with_cursor (fun path ->
  let offsets=ref [] in let post=transport ~offsets [10] in
  let t=C.open_cursor ~post ~client:(client "token") ~path () |> ok in
  let submitted=ref 0 in
  let accept ~operation_id update = incr submitted;accept ~operation_id update in
  let interleaved_post ~url ~body =
    (* Another poll commits after this request's offset snapshot, before the
       first page can acquire the settlement lock. *)
    ignore(C.step ~post t ~poll_timeout_sec:0 ~accept () |> ok);
    post ~url ~body in
  let result=C.step ~post:interleaved_post t ~poll_timeout_sec:0 ~accept () |> ok in
  check int "actual submit exactly once" 1 !submitted;
  check int "stale page recognized as already committed" 1 result.already_committed;
  check int "stale page submits nothing" 0 result.accepted)
let test_storage_failure_does_not_ack () = with_cursor (fun path ->
  let offsets=ref [] in let post=transport ~offsets [10] in
  let t=C.open_cursor ~post ~client:(client "token") ~path () |> ok in
  let seen=ref [] in
  let blocked ~operation_id update = seen:=operation_id::!seen;Unix.mkdir path 0o700;accept ~operation_id update in
  (match C.step ~post t ~poll_timeout_sec:0 ~accept:blocked () with
   | Error(C.Storage_failed _) -> () | _ -> fail "failed cursor publication accepted");
  let before=List.length !offsets in
  (match C.step ~post t ~poll_timeout_sec:0 ~accept () with
   | Error(C.Storage_failed _) -> () | _ -> fail "unreadable cursor acknowledged");
  check int "unreadable state makes no HTTP call" before (List.length !offsets);
  Unix.rmdir path;
  let repeat ~operation_id update = seen:=operation_id::!seen;accept ~operation_id update in
  ignore(C.step ~post t ~poll_timeout_sec:0 ~accept:repeat () |> ok);
  match !seen with
  | [retry;first] -> check string "durable acceptor can deduplicate replay after failed cursor write" first retry
  | _ -> fail "missing replay attempts")
let test_explicit_ignore_and_overflow () = with_cursor (fun path ->
  let offsets=ref [] in let post=transport ~offsets [10] in
  let t=C.open_cursor ~post ~client:(client "token") ~path () |> ok in
  let result=C.step ~post t ~poll_timeout_sec:0 ~accept:(fun ~operation_id:_ _ -> Ok(C.Intentionally_ignored C.Unsupported_update)) () |> ok in
  check int "explicit ignore accounted" 1 result.ignored;
  check bool "explicit ignore persisted" true (offset_on_disk path=`Int 11);
  let post ~url:_ ~body:_ = Ok(200,envelope(`List[`Assoc["update_id",`Intlit(Int64.to_string Int64.max_int)]])) in
  let called=ref false in
  (match C.step ~post t ~poll_timeout_sec:0 ~accept:(fun ~operation_id update -> called:=true;accept ~operation_id update) () with
   | Error(C.Cursor_refused _) -> () | _ -> fail "overflow offset admitted");
  check bool "overflow refused before submit" false !called)
let () = run "Telegram poll custody"
  ["ownership",[test_case "durable refusal frontier restart and token rotation" `Quick test_frontier_restart_and_rotation;
    test_case "unconfirmed wrong receipts stay pending" `Quick test_unconfirmed_and_wrong_receipts;
    test_case "wrong bot corrupt state stops before HTTP" `Quick test_wrong_bot_and_corrupt_cursor;
    test_case "stale concurrent page does not resubmit" `Quick test_stale_concurrent_page;
    test_case "failed storage does not acknowledge" `Quick test_storage_failure_does_not_ack;
    test_case "explicit ignore and successor overflow" `Quick test_explicit_ignore_and_overflow]]
