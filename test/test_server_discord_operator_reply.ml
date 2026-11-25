open Alcotest
open Masc

module Reply = Server_discord_operator_reply.For_testing

let with_root f =
  let path = Filename.temp_file "discord-operator-reply-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let root = Unix.realpath path in
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> Eio_main.run (fun _ -> f root))

let keeper = "reviewer"
let operation_id = "discord-reply-fixture"
let text_field name value = name, `String value
let status_json = `Assoc [ text_field "operation_id" operation_id ]

let payload content =
  `Assoc
    [ text_field "operation_id" operation_id; text_field "keeper_name" keeper
    ; text_field "chat_id" "original-row"; text_field "content" content ]

let resolve_origin ~keeper_name ~chat_id =
  check string "selected Keeper" keeper keeper_name;
  check string "selected chat row" "original-row" chat_id;
  Ok ("110", "220", Some "100")

let bound ~keeper_name ~channel_id =
  String.equal keeper_name keeper && String.equal channel_id "110"

let submit ~sw ~root ?(binding_allows = bound) ~send content =
  Reply.submit ~sw ~root ~actor:"operator" ~resolve_origin ~binding_allows ~send (payload content)

let state expected (code, json) =
  check int "HTTP status" expected (Httpun.Status.to_code code);
  Yojson.Safe.Util.(json |> member "state" |> to_string)

let check_status expected response =
  check int "HTTP status" expected (Httpun.Status.to_code (fst response))

let test_duplicate_during_send () =
  with_root (fun root ->
    let started, mark_started = Eio.Promise.create () in
    let release, release_send = Eio.Promise.create () in
    let calls = ref 0 in
    let send ~channel_id ~message_id ~content =
      incr calls;
      check string "actual thread" "110" channel_id;
      check string "native reply target" "220" message_id;
      check string "exact UTF-8 content and whitespace" " 한글\n" content;
      Eio.Promise.resolve mark_started ();
      Eio.Promise.await release;
      Ok "330"
    in
    Eio.Switch.run (fun sw ->
      check string "admission" "sending" (submit ~sw ~root ~send " 한글\n" |> state 202);
      Eio.Promise.await started;
      check string "replayed in flight" "sending" (submit ~sw ~root ~send " 한글\n" |> state 200);
      check_status 409 (submit ~sw ~root ~send "different");
      check_status 404 (Reply.status ~root ~actor:"other-operator" status_json);
      Eio.Promise.resolve release_send ());
    let receipt = Reply.status ~root ~actor:"operator" status_json in
    check string "settled" "delivered" (state 200 receipt);
    check string "created Discord ID" "330"
      Yojson.Safe.Util.(snd receipt |> member "message_id" |> to_string);
    Eio.Switch.run (fun sw ->
      check string "terminal replay" "delivered" (submit ~sw ~root ~send " 한글\n" |> state 200));
    check int "one network effect" 1 !calls)

let test_unknown_does_not_resend () =
  with_root (fun root ->
    let calls = ref 0 in
    let send ~channel_id:_ ~message_id:_ ~content:_ =
      incr calls;
      Error (Discord_rest_client.Network "response lost")
    in
    check_status 404 (Reply.status ~root ~actor:"operator" status_json);
    Eio.Switch.run (fun sw -> check_status 202 (submit ~sw ~root ~send "one message"));
    Eio.Switch.run (fun sw ->
      check string "unknown replay" "outcome_unknown" (submit ~sw ~root ~send "one message" |> state 200));
    check int "no second send" 1 !calls)

let test_rebinding_before_dispatch () =
  with_root (fun root ->
    let calls = ref 0 in
    let binding_allows ~keeper_name:_ ~channel_id:_ = incr calls; !calls = 1 in
    let send ~channel_id:_ ~message_id:_ ~content:_ = fail "reply to rebound channel" in
    Eio.Switch.run (fun sw ->
      check_status 202 (submit ~sw ~root ~binding_allows ~send "one message"));
    let receipt = Reply.status ~root ~actor:"operator" status_json in
    check string "settled" "refused" (state 200 receipt);
    check string "refusal reason" "binding_changed"
      Yojson.Safe.Util.(snd receipt |> member "reason" |> to_string))

let test_invalid_payload () =
  with_root (fun root ->
    let send ~channel_id:_ ~message_id:_ ~content:_ = fail "invalid input reached transport" in
    Eio.Switch.run (fun sw ->
      check_status 400 (submit ~sw ~root ~send (String.make 2001 'x'));
      check_status 400 (submit ~sw ~root ~send " ");
      let forged =
        match payload "text" with
        | `Assoc fields -> `Assoc (text_field "channel_id" "999" :: fields)
        | _ -> fail "invalid test fixture"
      in
      check_status 400
        (Reply.submit ~sw ~root ~actor:"operator" ~resolve_origin ~binding_allows:bound ~send forged));
    check_status 404 (Reply.status ~root ~actor:"operator" status_json))

let test_stored_origin () =
  with_root (fun base_dir ->
    let persist channel_id parent_channel_id thread_id speaker_authority =
      let surface =
        Surface_ref.Discord { guild_id = Some "42"; channel_id; channel_name = None;
                              parent_channel_id; thread_id }
      in
      let speaker = Keeper_chat_store.{ speaker_authority; speaker_id = Some "43"; speaker_name = Some "same" } in
      Keeper_chat_store.append_user_message ~base_dir ~keeper_name:keeper ~content:"incoming"
        ~surface ~external_message_id:"220" ~speaker ()
    in
    persist "110" (Some "100") (Some "110") External;
    persist "111" (Some "100") (Some "999") External;
    persist "112" None None Owner;
    let rows =
      match Keeper_chat_store.load_captured_result ~base_dir ~keeper_name:keeper ~select:(fun _ -> true) with
      | Ok rows -> List.map Keeper_chat_store.captured_row_message rows
      | Error _ -> fail "the real chat store did not return the rows"
    in
    let origins =
      List.filter_map (fun (row : Keeper_chat_store.chat_message) -> Reply.origin_from_chat ~chat_id:row.id row) rows
    in
    check (list (triple string string (option string))) "one verified reply route"
      ["110", "220", Some "100"] origins)

let () =
  run "Discord operator reply"
    [ "delivery",
      [ test_case "equivalent in-flight and terminal retries" `Quick test_duplicate_during_send
      ; test_case "ambiguous response stays unknown" `Quick test_unknown_does_not_resend
      ; test_case "binding changes before dispatch" `Quick test_rebinding_before_dispatch
      ; test_case "invalid text and forged route" `Quick test_invalid_payload
      ; test_case "persisted external row establishes route" `Quick test_stored_origin ] ]
