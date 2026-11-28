(* Unit tests for the in-process gateway helpers
   added to [Channel_gate_discord_state]:
   - [keeper_for_channel] (binding lookup)
   - [send_error] / [pp_send_error] (typed REST error wrapper)
   - [send_message] error path with [DISCORD_BOT_TOKEN] unset
   - [edit_message] error path with [DISCORD_BOT_TOKEN] unset
   - [trigger_typing] error path with [DISCORD_BOT_TOKEN] unset
   - the order [send_voice_message] posts in, and what each failure returns

   The happy path of Discord REST wrappers requires a live Discord API call
   and is left to operational verification. *)

open Alcotest
module State = Channel_gate_discord_state

let setenv k v = Unix.putenv k v
let unsetenv k = Unix.putenv k ""

(* ---------------------------------------------------------------- *)
(* keeper_for_channel                                               *)
(* ---------------------------------------------------------------- *)

let test_lookup_blank_channel_id () =
  check (result (option string) reject) "empty => None" (Ok None)
    (State.keeper_for_channel_result ~channel_id:"")

let test_lookup_whitespace_channel_id () =
  check (result (option string) reject) "whitespace => None" (Ok None)
    (State.keeper_for_channel_result ~channel_id:"   ")

let test_lookup_unbound_channel_returns_none () =
  (* No bind() called for this channel id and the binding store may
     be empty or missing; lookup must not raise either way. *)
  check (result (option string) reject) "no binding => None" (Ok None)
    (State.keeper_for_channel_result
       ~channel_id:"channel-id-with-no-binding")

(* ---------------------------------------------------------------- *)
(* send_error / pp_send_error                                       *)
(* ---------------------------------------------------------------- *)

let test_pp_missing_token () =
  let s = Format.asprintf "%a" State.pp_send_error State.Missing_token in
  check bool "mentions DISCORD_BOT_TOKEN" true
    (let needle = "DISCORD_BOT_TOKEN" in
     let n = String.length needle in
     let len = String.length s in
     let rec scan i =
       if i + n > len then false
       else if String.sub s i n = needle then true
       else scan (i + 1)
     in
     scan 0)

let test_pp_rest_error_wraps_inner_error () =
  let inner = Discord_rest_client.Network "DNS failure" in
  let s = Format.asprintf "%a" State.pp_send_error (State.Rest_error inner) in
  check bool "starts with 'discord rest error'" true
    (String.length s >= 19 && String.sub s 0 19 = "discord rest error:")

(* ---------------------------------------------------------------- *)
(* send_message — error path                                        *)
(* ---------------------------------------------------------------- *)

let test_send_message_without_token_returns_missing_token () =
  unsetenv "DISCORD_BOT_TOKEN";
  match State.send_message ~channel_id:"123" ~content:"hi" () with
  | Error State.Missing_token -> ()
  | Error other ->
    fail
      (Format.asprintf
         "expected Missing_token, got %a" State.pp_send_error other)
  | Ok _ -> fail "expected error, got Ok"

let test_send_message_with_whitespace_token_returns_missing_token () =
  setenv "DISCORD_BOT_TOKEN" "   ";
  (match State.send_message ~channel_id:"123" ~content:"hi" () with
   | Error State.Missing_token -> ()
   | Error other ->
     fail
       (Format.asprintf
          "expected Missing_token, got %a" State.pp_send_error other)
   | Ok _ -> fail "expected error, got Ok");
  unsetenv "DISCORD_BOT_TOKEN"

let test_trigger_typing_without_token_returns_missing_token () =
  unsetenv "DISCORD_BOT_TOKEN";
  match State.trigger_typing ~channel_id:"123" () with
  | Error State.Missing_token -> ()
  | Error other ->
    fail
      (Format.asprintf
         "expected Missing_token, got %a" State.pp_send_error other)
  | Ok () -> fail "expected error, got Ok"

let test_edit_message_without_token_returns_missing_token () =
  unsetenv "DISCORD_BOT_TOKEN";
  match
    State.edit_message ~channel_id:"123" ~message_id:"456" ~content:"hi" ()
  with
  | Error State.Missing_token -> ()
  | Error other ->
    fail
      (Format.asprintf
         "expected Missing_token, got %a" State.pp_send_error other)
  | Ok () -> fail "expected error, got Ok"

(* ---------------------------------------------------------------- *)
(* send_voice_message order                                         *)
(* ---------------------------------------------------------------- *)

let chunk content = { State.For_testing.content; allowed_user_mentions = [] }

let rest_error reason =
  State.Rest_error (Discord_rest_client.Other { request_id = ""; reason; body_bytes = 0 })

(* Stand-in senders that record each send; text ids count from text-0. *)
let post_sequence ?text_fails_at ?(voice_fails = false) chunks =
  let sent = ref [] in
  let send_text ~first (message : State.For_testing.outbound_message) =
    let index = List.length !sent in
    sent := Printf.sprintf "text %s first=%b" message.content first :: !sent;
    if Option.equal Int.equal text_fails_at (Some index) then Error (rest_error "text refused")
    else Ok (Printf.sprintf "text-%d" index)
  in
  let send_voice () =
    sent := "voice" :: !sent;
    if voice_fails then Error (rest_error "voice refused") else Ok "voice-0"
  in
  let result = State.For_testing.post_text_then_voice ~send_text ~send_voice chunks in
  (List.rev !sent, result)

let test_voice_goes_after_the_text () =
  let sent, result = post_sequence [ chunk "a"; chunk "b" ] in
  check (list string) "each chunk, the reply reference on the first only, then the voice"
    [ "text a first=true"; "text b first=false"; "voice" ] sent;
  match result with
  | Ok message_id -> check string "the voice message's id" "voice-0" message_id
  | Error error -> failf "expected the voice message's id, got %a" State.pp_post_error error

let test_voice_failure_after_the_text_names_the_text () =
  match post_sequence ~voice_fails:true [ chunk "a"; chunk "b" ] with
  | _, Error (State.Voice_failed_after_text { text_message_id; error = _ }) ->
    check string "the last text chunk's id" "text-1" text_message_id
  | _, Error (State.Send_failed _) -> fail "the text was posted, but the error does not say so"
  | _, Ok _ -> fail "a failed voice message returned Ok"

let test_text_failure_sends_no_voice () =
  let sent, result = post_sequence ~text_fails_at:1 [ chunk "a"; chunk "b" ] in
  check (list string) "the voice message is not sent" [ "text a first=true"; "text b first=false" ]
    sent;
  match result with
  | Error (State.Send_failed _) -> ()
  | Error (State.Voice_failed_after_text _) -> fail "a failed text chunk claimed the text was posted"
  | Ok _ -> fail "a failed text chunk returned Ok"

let test_voice_failure_without_text_is_a_send_failure () =
  match post_sequence ~voice_fails:true [] with
  | _, Error (State.Send_failed _) -> ()
  | _, Error (State.Voice_failed_after_text _) -> fail "no text was sent, but the error names one"
  | _, Ok _ -> fail "a failed voice message returned Ok"

(* ---------------------------------------------------------------- *)
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

let () =
  run "channel_gate_discord_state_in_process"
    [ ( "keeper_for_channel"
      , [ test_case "blank channel id => None" `Quick
            test_lookup_blank_channel_id
        ; test_case "whitespace channel id => None" `Quick
            test_lookup_whitespace_channel_id
        ; test_case "unbound channel => None" `Quick
            test_lookup_unbound_channel_returns_none
        ] )
    ; ( "send_error"
      , [ test_case "pp Missing_token mentions env var" `Quick
            test_pp_missing_token
        ; test_case "pp Rest_error wraps inner error" `Quick
            test_pp_rest_error_wraps_inner_error
        ] )
    ; ( "send_voice_message order"
      , [ test_case "the voice goes after the text" `Quick test_voice_goes_after_the_text
        ; test_case "a voice failure after the text names the text" `Quick
            test_voice_failure_after_the_text_names_the_text
        ; test_case "a text failure sends no voice" `Quick test_text_failure_sends_no_voice
        ; test_case "a voice failure without text is a send failure" `Quick
            test_voice_failure_without_text_is_a_send_failure
        ] )
    ; ( "send_message"
      , [ test_case "unset token => Missing_token" `Quick
            test_send_message_without_token_returns_missing_token
        ; test_case "whitespace token => Missing_token" `Quick
            test_send_message_with_whitespace_token_returns_missing_token
        ] )
    ; ( "edit_message"
      , [ test_case "unset token => Missing_token" `Quick
            test_edit_message_without_token_returns_missing_token
        ] )
    ; ( "trigger_typing"
      , [ test_case "unset token => Missing_token" `Quick
            test_trigger_typing_without_token_returns_missing_token
        ] )
    ]
