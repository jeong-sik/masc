(* RFC-0317 PR-1 — pure state-machine unit tests for Slack_gateway_state.

   No live WSS, no Eio. Drives Slack_gateway_state.step with typed inputs
   constructed in-process, and exercises parse_envelope / decode_event
   against fixture JSON. *)

open Alcotest
module S = Slack_gateway_state

(* ---------------------------------------------------------------- *)
(* Comparators (drop the float backoff_until_mono field, which is    *)
(* non-deterministic and irrelevant to transition correctness)       *)
(* ---------------------------------------------------------------- *)

let state_kind : S.connection_state -> string = function
  | S.Disconnected -> "disconnected"
  | S.Awaiting_hello -> "awaiting_hello"
  | S.Connected -> "connected"
  | S.Reconnect_pending _ -> "reconnect_pending"
  | S.Failed _ -> "failed"

let effect_summary : S.gateway_effect -> string = function
  | S.Apps_connections_open -> "apps_connections_open"
  | S.Open_wss _ -> "open_wss"
  | S.Close_wss -> "close_wss"
  | S.Send_ack _ -> "send_ack"
  | S.Emit_event _ -> "emit_event"
  | S.Schedule_backoff _ -> "schedule_backoff"
  | S.Log _ -> "log"

let effects_of t input =
  let (_t', effects) = S.step t ~now_mono:0.0 input in
  List.map effect_summary effects

let state_of t input =
  let (t', _effects) = S.step t ~now_mono:0.0 input in
  state_kind (S.state t')

let policy_equal a b =
  match (a, b) with
  | S.Mention_only, S.Mention_only -> true
  | S.Mention_or_thread, S.Mention_or_thread -> true
  | S.All, S.All -> true
  | S.User_only x, S.User_only y -> String.equal x y
  | _ -> false

let cfg ?(policy = S.All) ?bot_user_id () : S.config =
  { trigger_policy = policy; bot_user_id }

let mk_event_message ?(channel = "C1") ?(ts = "1700000000.000100")
    ?(user = "U1") ?(text = "hi") ?thread_ts ?(mentions = false) () =
  S.Message_create
    { channel_id = channel
    ; thread_ts
    ; user_id = user
    ; user_name = None
    ; text
    ; ts
    ; mentions_bot = mentions
    ; bot_id = None
    }

(* ---------------------------------------------------------------- *)
(* Trigger policy                                                   *)
(* ---------------------------------------------------------------- *)

let test_parse_trigger_policy_accepts () =
  let cases =
    [ "mention_only", S.Mention_only
    ; "mention_or_thread", S.Mention_or_thread
    ; "all", S.All
    ; "user_only:U123", S.User_only "U123"
    ]
  in
  List.iter
    (fun (input, expected) ->
      match S.parse_trigger_policy input with
      | Ok p when policy_equal p expected -> ()
      | Ok _ -> failf "parse_trigger_policy %S: wrong variant" input
      | Error msg -> failf "parse_trigger_policy %S: %s" input msg)
    cases

let test_parse_trigger_policy_rejects () =
  (* "all " is intentionally NOT here: parse_trigger_policy trims, so "all "
     is a valid [All] policy. Trim-tolerance is the contract. *)
  let bad = [ "mention"; "user_only:"; "USER_ONLY:1"; "everything"; "" ] in
  List.iter
    (fun input ->
      match S.parse_trigger_policy input with
      | Ok _ -> failf "expected Error for %S" input
      | Error _ -> ())
    bad

(* ---------------------------------------------------------------- *)
(* step: connection lifecycle                                       *)
(* ---------------------------------------------------------------- *)

let test_create_is_disconnected () =
  let t = S.create ~config:(cfg ()) in
  check string "fresh state" "disconnected" (state_kind (S.state t))

let test_connect_requested_opens_url () =
  let t = S.create ~config:(cfg ()) in
  check string "state -> awaiting_hello" "awaiting_hello"
    (state_of t S.Connect_requested);
  let (_t', effects) = S.step t ~now_mono:0.0 S.Connect_requested in
  check string "emits apps.connections.open" "apps_connections_open"
    (match effects with [ e ] -> effect_summary e | _ -> "wrong")

let test_open_url_after_fetch () =
  let t = S.create ~config:(cfg ()) in
  let (t, _) = S.step t ~now_mono:0.0 S.Connect_requested in
  check string "state stays awaiting_hello" "awaiting_hello"
    (state_of t (S.Apps_connections_open_succeeded { url = "wss://x" }));
  let (_t', effects) =
    S.step t ~now_mono:0.0
      (S.Apps_connections_open_succeeded { url = "wss://x" })
  in
  check string "emits Open_wss" "open_wss"
    (match effects with [ e ] -> effect_summary e | _ -> "wrong")

let test_hello_completes_handshake () =
  let t = S.create ~config:(cfg ()) in
  let (t, _) = S.step t ~now_mono:0.0 S.Connect_requested in
  let hello = { S.kind = S.Hello_env; envelope_id = None; event = None } in
  check string "state -> connected" "connected"
    (state_of t (S.Envelope_received hello))

let full_connect () =
  let t = S.create ~config:(cfg ()) in
  let (t, _) = S.step t ~now_mono:0.0 S.Connect_requested in
  let hello = { S.kind = S.Hello_env; envelope_id = None; event = None } in
  let (t, _) = S.step t ~now_mono:0.0 (S.Envelope_received hello) in
  t

(* ---------------------------------------------------------------- *)
(* step: per-envelope ack (the type-level guarantee)                 *)
(* ---------------------------------------------------------------- *)

let env_events_api ?envelope_id event =
  { S.kind = S.Events_api_env; envelope_id; event = Some event }

let test_events_api_acks_and_emits_under_all () =
  let t = full_connect () in
  let env =
    env_events_api ~envelope_id:"E1" (mk_event_message ~mentions:false ())
  in
  let l = effects_of t (S.Envelope_received env) in
  check string "ack + emit" "[send_ack; emit_event]"
    ("[" ^ String.concat "; " l ^ "]")

let test_events_api_no_ack_without_envelope_id () =
  (* Slack never omits it for events_api, but if it does we must not crash. *)
  let t = full_connect () in
  let env = env_events_api (mk_event_message ()) in
  let effects = effects_of t (S.Envelope_received env) in
  check bool "no send_ack in effects" false (List.mem "send_ack" effects)

let test_mention_only_suppresses_non_mention () =
  let t =
    S.create
      ~config:(cfg ~policy:S.Mention_only ~bot_user_id:"UBOT" ())
  in
  let (t, _) = S.step t ~now_mono:0.0 S.Connect_requested in
  let hello = { S.kind = S.Hello_env; envelope_id = None; event = None } in
  let (t, _) = S.step t ~now_mono:0.0 (S.Envelope_received hello) in
  let env =
    env_events_api ~envelope_id:"E2" (mk_event_message ~mentions:false ())
  in
  let effects = effects_of t (S.Envelope_received env) in
  check bool "acks" true (List.mem "send_ack" effects);
  check bool "no emit (not a mention)" false (List.mem "emit_event" effects)

let test_app_mention_always_emits () =
  let t =
    S.create
      ~config:(cfg ~policy:S.Mention_only ~bot_user_id:"UBOT" ())
  in
  let (t, _) = S.step t ~now_mono:0.0 S.Connect_requested in
  let hello = { S.kind = S.Hello_env; envelope_id = None; event = None } in
  let (t, _) = S.step t ~now_mono:0.0 (S.Envelope_received hello) in
  let ev =
    S.App_mention
      { channel_id = "C1"; thread_ts = None; user_id = "U1"; text = "hey"; ts = "1" }
  in
  let env = env_events_api ~envelope_id:"E3" ev in
  let effects = effects_of t (S.Envelope_received env) in
  check bool "emit (app_mention is a mention)" true
    (List.mem "emit_event" effects)

(* ---------------------------------------------------------------- *)
(* step: reconnect                                                   *)
(* ---------------------------------------------------------------- *)

let test_disconnect_envelope_reconnects () =
  let t = full_connect () in
  let env =
    { S.kind = S.Disconnect_env { reason = "too_many_connections" }
    ; envelope_id = Some "E4"
    ; event = None
    }
  in
  check string "state -> reconnect_pending" "reconnect_pending"
    (state_of t (S.Envelope_received env));
  let effects = effects_of t (S.Envelope_received env) in
  check bool "acks the disconnect envelope" true (List.mem "send_ack" effects);
  check bool "closes the stale wss" true (List.mem "close_wss" effects);
  check bool "schedules backoff" true (List.mem "schedule_backoff" effects)

let test_backoff_elapsed_reopens_url () =
  let t = full_connect () in
  let env =
    { S.kind = S.Disconnect_env { reason = "x" }
    ; envelope_id = Some "E5"
    ; event = None
    }
  in
  let (t, _) = S.step t ~now_mono:0.0 (S.Envelope_received env) in
  check string "state -> awaiting_hello (fresh apps.connections.open)"
    "awaiting_hello" (state_of t S.Backoff_elapsed);
  let (_t', effects) = S.step t ~now_mono:0.0 S.Backoff_elapsed in
  check string "emits apps.connections.open" "apps_connections_open"
    (match effects with [ e ] -> effect_summary e | _ -> "wrong")

let test_wss_closed_in_awaiting_hello_reconnects () =
  (* A connect-time failure surfaces as Wss_closed in Awaiting_hello. *)
  let t = S.create ~config:(cfg ()) in
  let (t, _) = S.step t ~now_mono:0.0 S.Connect_requested in
  check string "state -> reconnect_pending" "reconnect_pending"
    (state_of t (S.Wss_closed { reason = "tls handshake" }));
  let effects = effects_of t (S.Wss_closed { reason = "tls handshake" }) in
  check bool "schedules backoff" true (List.mem "schedule_backoff" effects)

(* ---------------------------------------------------------------- *)
(* parse_envelope / decode_event                                     *)
(* ---------------------------------------------------------------- *)

let test_parse_envelope_hello () =
  let json = `Assoc [ ("type", `String "hello") ] in
  match S.parse_envelope ~bot_user_id:None json with
  | Ok { S.kind = S.Hello_env; _ } -> ()
  | Ok _ -> fail "hello parsed to wrong kind"
  | Error e -> failf "hello parse error: %s" e

let test_parse_envelope_events_api_message () =
  let json =
    `Assoc
      [ ("type", `String "events_api")
      ; ("envelope_id", `String "EE1")
      ; ( "payload"
        , `Assoc
            [ ("type", `String "message")
            ; ("channel", `String "C9")
            ; ("user", `String "U9")
            ; ("text", `String "hello bot")
            ; ("ts", `String "1700000000.000200")
            ] )
      ]
  in
  match S.parse_envelope ~bot_user_id:None json with
  | Ok { S.kind = S.Events_api_env; envelope_id = Some "EE1"; event = Some _ } ->
    ()
  | Ok _ -> fail "events_api message: kind/event/envelope_id mismatch"
  | Error e -> failf "events_api parse error: %s" e

let test_parse_envelope_events_api_missing_payload_rejected () =
  let json = `Assoc [ ("type", `String "events_api") ] in
  match S.parse_envelope ~bot_user_id:None json with
  | Ok _ -> fail "events_api missing payload must be Error"
  | Error _ -> ()

let test_parse_envelope_disconnect_missing_payload_rejected () =
  let json = `Assoc [ ("type", `String "disconnect") ] in
  match S.parse_envelope ~bot_user_id:None json with
  | Ok _ -> fail "disconnect missing payload must be Error"
  | Error _ -> ()

let test_parse_envelope_unknown_type_rejected () =
  let json = `Assoc [ ("type", `String "totally_unknown") ] in
  match S.parse_envelope ~bot_user_id:None json with
  | Ok _ -> fail "unknown envelope type must be Error"
  | Error _ -> ()

let test_decode_event_message_missing_fields () =
  (* Missing channel/ts is a schema failure, not Ignored_event. *)
  let payload = `Assoc [ ("type", `String "message"); ("text", `String "x") ] in
  match S.decode_event ~bot_user_id:None ~event_type:"message" ~payload with
  | Error _ -> ()
  | Ok _ -> fail "message missing channel/ts must be Error"

let test_decode_event_reaction_ignored_as_turn () =
  (* decode_event yields the event; passes_policy (not decode) suppresses it. *)
  let payload =
    `Assoc
      [ ("type", `String "reaction_added")
      ; ("user", `String "U1")
      ; ("reaction", `String "thumbsup")
      ; ( "item"
        , `Assoc [ ("channel", `String "C1"); ("ts", `String "1.1") ] )
      ]
  in
  match S.decode_event ~bot_user_id:None ~event_type:"reaction_added" ~payload with
  | Ok (S.Reaction_added _) -> ()
  | Ok _ -> fail "expected Reaction_added"
  | Error e -> failf "reaction decode error: %s" e

let test_decode_event_reaction_missing_item_rejected () =
  let payload =
    `Assoc
      [ ("type", `String "reaction_added")
      ; ("user", `String "U1")
      ; ("reaction", `String "thumbsup")
      ]
  in
  match S.decode_event ~bot_user_id:None ~event_type:"reaction_added" ~payload with
  | Error _ -> ()
  | Ok _ -> fail "reaction_added missing item must be Error"

let test_decode_event_unknown_is_ignored_event () =
  let payload = `Assoc [ ("type", `String "channel_archive") ] in
  match S.decode_event ~bot_user_id:None ~event_type:"channel_archive" ~payload with
  | Ok (S.Ignored_event name) -> check string "name preserved" "channel_archive" name
  | Ok _ -> fail "unknown event must be Ignored_event, not silent"
  | Error e -> failf "unknown event became Error (should be Ignored): %s" e

(* ---------------------------------------------------------------- *)

let () =
  run "Slack_gateway_state"
    [ "trigger_policy"
      , [ test_case "parse accepts known policies" `Quick
            test_parse_trigger_policy_accepts
        ; test_case "parse rejects unknown / malformed" `Quick
            test_parse_trigger_policy_rejects
        ]
    ; "lifecycle"
      , [ test_case "create is Disconnected" `Quick test_create_is_disconnected
        ; test_case "Connect_requested -> Apps_connections_open" `Quick
            test_connect_requested_opens_url
        ; test_case "open url after fetch" `Quick test_open_url_after_fetch
        ; test_case "hello completes handshake" `Quick test_hello_completes_handshake
        ]
    ; "ack"
      , [ test_case "events_api acks + emits under All" `Quick
            test_events_api_acks_and_emits_under_all
        ; test_case "no ack when envelope_id absent" `Quick
            test_events_api_no_ack_without_envelope_id
        ; test_case "mention_only suppresses non-mention" `Quick
            test_mention_only_suppresses_non_mention
        ; test_case "app_mention always emits" `Quick test_app_mention_always_emits
        ]
    ; "reconnect"
      , [ test_case "disconnect envelope reconnects" `Quick
            test_disconnect_envelope_reconnects
        ; test_case "backoff elapsed reopens url (fresh)" `Quick
            test_backoff_elapsed_reopens_url
        ; test_case "wss_closed in Awaiting_hello reconnects" `Quick
            test_wss_closed_in_awaiting_hello_reconnects
        ]
    ; "parse"
      , [ test_case "parse hello" `Quick test_parse_envelope_hello
        ; test_case "parse events_api message" `Quick
            test_parse_envelope_events_api_message
        ; test_case "events_api missing payload rejected" `Quick
            test_parse_envelope_events_api_missing_payload_rejected
        ; test_case "disconnect missing payload rejected" `Quick
            test_parse_envelope_disconnect_missing_payload_rejected
        ; test_case "unknown envelope type rejected" `Quick
            test_parse_envelope_unknown_type_rejected
        ; test_case "decode message missing fields errors" `Quick
            test_decode_event_message_missing_fields
        ; test_case "decode reaction_added" `Quick
            test_decode_event_reaction_ignored_as_turn
        ; test_case "decode reaction_added missing item rejected" `Quick
            test_decode_event_reaction_missing_item_rejected
        ; test_case "decode unknown -> Ignored_event" `Quick
            test_decode_event_unknown_is_ignored_event
        ]
    ]
