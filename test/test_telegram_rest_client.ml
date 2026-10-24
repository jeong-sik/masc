open Alcotest
module R = Telegram_rest_client
let ok = function Ok value -> value | Error error -> fail (Format.asprintf "%a" R.pp_error error)
let client = R.create ~token:"123:secret" |> ok
let sent = {|{"ok":true,"result":{"message_id":91,"chat":{"id":-1001234567890},"message_thread_id":7,"text":"reply"}}|}
let error_json = {|{"ok":false,"error_code":429,"description":"123:secret","parameters":{"retry_after":17,"migrate_to_chat_id":-1001234567890}}|}
let test_poll_coordinates () =
  let seen=ref None in
  let post ~url ~body = seen:=Some(url,Yojson.Safe.from_string body);Ok(200,{|{"ok":true,"result":[]}|}) in
  check int "empty page" 0 (List.length (R.get_updates ~post client ~offset:2147483648L ~poll_timeout_sec:30 () |> ok));
  let url,body=Option.get !seen in
  check string "native endpoint" "https://api.telegram.org/bot123%3Asecret/getUpdates" url;
  check bool "exact offset" true (Yojson.Safe.Util.member "offset" body=`Int 2147483648);
  check bool "long poll timeout" true (Yojson.Safe.Util.member "timeout" body=`Int 30);
  check bool "explicit update subscription" true
    (Yojson.Safe.Util.member "allowed_updates" body=`List[`String "message";`String "edited_message"]);
  seen:=None;
  (match R.get_updates ~post client ~offset:(-1L) ~poll_timeout_sec:30 () with
   | Error (R.Invalid_request "offset") -> () | _ -> fail "destructive offset admitted");
  check bool "invalid request has no effect" true (!seen=None)
let test_credential_is_one_segment () =
  let client=R.create ~token:"123:secret/a?b#c%" |> ok in
  let seen=ref None in
  let post ~url ~body:_ = seen:=Some url;Ok(200,{|{"ok":true,"result":[]}|}) in
  ignore(R.get_updates ~post client ~poll_timeout_sec:0 () |> ok);
  check (option string) "credential cannot change path/query/fragment"
    (Some "https://api.telegram.org/bot123%3Asecret%2Fa%3Fb%23c%25/getUpdates") !seen
let test_update_decode () =
  let body={|{"ok":true,"result":[{"update_id":2147483648,"message":{"message_id":5,"chat":{"id":-1001234567890},"message_thread_id":7,"from":{"id":4503599627370495,"is_bot":false,"first_name":"Ada"},"text":"hello"}},{"update_id":2147483650,"edited_message":{"message_id":5,"chat":{"id":-1001234567890},"text":"edited"}},{"update_id":2147483651,"callback_query":{}}]}|} in
  match R.parse_updates_response ~status:200 ~body |> ok with
  | [{update_id=2147483648L;kind=R.Message m};{kind=R.Edited_message edited;_};{kind=R.Unsupported;_}] ->
    check int64 "signed chat" (-1001234567890L) m.chat_id;
    check (option int) "topic" (Some 7) m.message_thread_id;
    check int64 "52bit user" 4503599627370495L (Option.get m.from_user).id;
    check (option string) "edited content" (Some "edited") edited.text
  | _ -> fail "update kinds/identity changed"
let test_invalid_pages () =
  List.iter (fun body -> match R.parse_updates_response ~status:200 ~body with
    | Error (R.Invalid_response _) -> () | _ -> fail "malformed page admitted")
    [ {|{"ok":true,"result":[{"update_id":1},{"update_id":1}]}|};
      {|{"ok":true,"result":[{"update_id":2},{"update_id":1}]}|};
      {|{"ok":true,"result":[{"update_id":1},{"message":{}}]}|};
      {|{"ok":true,"result":[{"update_id":1,"message":null}]}|};
      {|{"ok":true,"result":[{"update_id":1,"message":{},"edited_message":{}}]}|};
      {|{"ok":true,"result":[{"update_id":1,"message":{},"callback_query":{}}]}|};
      {|{"ok":true,"result":[{"update_id":1,"poll":{},"callback_query":{}}]}|};
      {|{"ok":true,"result":[{"update_id":1,"callback_query":null}]}|};
      {|{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"chat":{"id":1,"id":2}}}]}|};
      {|{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"chat":{"id":1.0}}}]}|};
      {|{"ok":true,"ok":false,"result":[]}|};
      {|{"result":[]}|}; {|{"ok":true}|}; ""; "not json" ]
let test_native_send_and_edit () =
  let seen=ref [] in
  let post ~url ~body = seen:=(url,Yojson.Safe.from_string body)::!seen;Ok(200,sent) in
  let message=R.send_message ~post client ~chat_id:(-1001234567890L)
    ~message_thread_id:7 ~reply_to_message_id:6 ~text:"<unchanged> & 🙂" () |> ok in
  check int "actual message id" 91 message.message_id;
  let _,body=List.hd !seen in
  check bool "topic" true (Yojson.Safe.Util.member "message_thread_id" body=`Int 7);
  check bool "reply coordinates" true (Yojson.Safe.Util.member "reply_parameters" body=`Assoc["message_id",`Int 6]);
  check bool "plain authored bytes" true (Yojson.Safe.Util.member "text" body=`String "<unchanged> & 🙂");
  check bool "no parse mode invented" true (Yojson.Safe.Util.member "parse_mode" body=`Null);
  ignore(R.edit_message_text ~post client ~chat_id:message.chat_id ~message_id:91 ~text:"edited" () |> ok);
  let url,body=List.hd !seen in
  check string "edit endpoint" "https://api.telegram.org/bot123%3Asecret/editMessageText" url;
  check bool "exact existing message" true (Yojson.Safe.Util.member "message_id" body=`Int 91)
let test_failures_keep_typed_directives () =
  List.iter (fun status -> match R.parse_updates_response ~status ~body:error_json with
    | Error (R.Api_error {status=actual;code=429;retry_after=Some 17;migrate_to_chat_id=Some chat}) ->
      check int "actual status" status actual;check int64 "migration target" (-1001234567890L) chat
    | _ -> fail "retry directive lost") [200;429];
  (match R.parse_updates_response ~status:502 ~body:"secret HTML" with
   | Error (R.Http_status 502) -> () | _ -> fail "non-JSON HTTP error lost");
  let post ~url:_ ~body:_ = Error () in
  (match R.get_updates ~post client ~poll_timeout_sec:0 () with
   | Error R.Transport_failed -> () | _ -> fail "transport failure lost");
  let rendered=match R.parse_updates_response ~status:429 ~body:error_json with
    | Error error -> Format.asprintf "%a" R.pp_error error | Ok _ -> fail "API error admitted" in
  check string "error has only typed directives"
    "telegram API 429 (HTTP 429, retry_after=17, migrate_to_chat_id=-1001234567890)" rendered;
  List.iter (fun body -> match R.parse_updates_response ~status:429 ~body with
    | Error (R.Invalid_response "retry_after") -> () | _ -> fail "bad retry directive admitted")
    [ {|{"ok":false,"error_code":429,"parameters":{"retry_after":-1}}|};
      {|{"ok":false,"error_code":429,"parameters":{"retry_after":"17"}}|} ];
  (* A duplicate document is rejected by the shared JSON boundary before its
     envelope can authorize any API directive; only the HTTP status is trusted. *)
  (match R.parse_updates_response ~status:429
    ~body:{|{"ok":false,"error_code":429,"parameters":{"retry_after":1,"retry_after":2}}|} with
   | Error (R.Http_status 429) -> () | _ -> fail "duplicate retry directive admitted")
let () = run "Telegram Bot API"
  ["protocol",[test_case "poll coordinates before effects" `Quick test_poll_coordinates;
    test_case "credential path identity" `Quick test_credential_is_one_segment;
    test_case "lossless update coordinates" `Quick test_update_decode;
    test_case "reject whole malformed pages" `Quick test_invalid_pages;
    test_case "native reply and edit" `Quick test_native_send_and_edit;
    test_case "typed failure directives" `Quick test_failures_keep_typed_directives]]
