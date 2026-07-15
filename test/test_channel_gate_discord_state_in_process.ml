(* RFC-0203 Phase 3 — unit tests for the in-process gateway helpers
   added to [Channel_gate_discord_state]:
   - [resolve_keeper_for_channel_result] (typed binding lookup)
   - [send_error] / [pp_send_error] (typed REST error wrapper)
   - [send_message] error path with [DISCORD_BOT_TOKEN] unset
   - [edit_message] error path with [DISCORD_BOT_TOKEN] unset
   - [trigger_typing] error path with [DISCORD_BOT_TOKEN] unset

   The happy path of Discord REST wrappers requires a live Discord API call
   and is left to operational verification. *)

open Alcotest
module State = Channel_gate_discord_state

let setenv k v = Unix.putenv k v
let unsetenv k = Unix.putenv k ""

(* ---------------------------------------------------------------- *)
(* resolve_keeper_for_channel_result                                *)
(* ---------------------------------------------------------------- *)

let test_lookup_blank_channel_id () =
  match State.resolve_keeper_for_channel_result ~channel_id:"" with
  | Ok None -> ()
  | Ok (Some _) -> fail "blank channel resolved a Keeper"
  | Error error ->
      fail (Format.asprintf "%a" State.pp_binding_lookup_error error)

let test_lookup_whitespace_channel_id () =
  match State.resolve_keeper_for_channel_result ~channel_id:"   " with
  | Ok None -> ()
  | Ok (Some _) -> fail "whitespace channel resolved a Keeper"
  | Error error ->
      fail (Format.asprintf "%a" State.pp_binding_lookup_error error)

let test_lookup_unbound_channel_returns_none () =
  (* No bind() called for this channel id and the binding store may
     be empty or missing; lookup must not raise either way. *)
  match
    State.resolve_keeper_for_channel_result
      ~channel_id:"channel-id-with-no-binding"
  with
  | Ok None -> ()
  | Ok (Some _) -> fail "unbound channel resolved a Keeper"
  | Error error ->
      fail (Format.asprintf "%a" State.pp_binding_lookup_error error)

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
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

let () =
  run "channel_gate_discord_state_in_process"
    [ ( "resolve_keeper_for_channel_result"
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
