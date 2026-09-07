(* slack-lane (task-1418) — pure unit tests for the collection contract.

   No live token, no Eio. Pins three things the fiber relies on:
   the REST page parser, the collection filter, the ring buffer's
   dedupe/trim, and the config knob's fail-closed stance. *)

open Alcotest
module Rest = Slack_rest_client
module Lane = Slack_lane
module Poll = Server_slack_poll_lane

(* Substring search by hand: the stdlib surface differs across versions and
   the gateway keeps its own loop for the same reason. *)
let contains_sub ~needle ~haystack =
  let len = String.length needle in
  let hay_len = String.length haystack in
  let rec loop i =
    if i + len > hay_len then false
    else if String.sub haystack i len = needle then true
    else loop (i + 1)
  in
  loop 0
;;

(* ---------------------------------------------------------------- *)
(* conversations.history request builder                            *)
(* ---------------------------------------------------------------- *)

let test_build_request () =
  let url, headers, body =
    Rest.build_conversations_history_request ~token:"xoxb-test"
      ~channel_id:"C123" ~oldest:"1788708937.515994" ~limit:200
      ~cursor:"abc=" ()
  in
  check string "url" "https://slack.com/api/conversations.history" url;
  check bool "auth header"
    (List.exists
       (fun (k, v) ->
         k = "Authorization" && contains_sub ~needle:"Bearer xoxb-test" ~haystack:v)
       headers)
    true;
  check bool "channel param"
    (contains_sub ~needle:"channel=C123" ~haystack:body) true;
  check bool "oldest param"
    (contains_sub ~needle:"oldest=1788708937.515994" ~haystack:body) true;
  check bool "limit param" (contains_sub ~needle:"limit=200" ~haystack:body) true;
  check bool "cursor param" (contains_sub ~needle:"cursor=abc=" ~haystack:body) true
;;

let history_message ?(user = Some "U1") ?(bot_id = None) ?(subtype = None)
    ?(thread_ts = None) ~ts ~text () : Rest.history_message =
  { Rest.ts; user_id = user; bot_id; subtype; thread_ts; text }
;;

(* ---------------------------------------------------------------- *)
(* conversations.history response parsing                           *)
(* ---------------------------------------------------------------- *)

let error_kind = function
  | Rest.Network _ -> "network"
  | Rest.Http_status _ -> "http_status"
  | Rest.Slack_api { error = _ } -> "slack_api"
  | Rest.Other _ -> "other"

let test_parse_ok_page () =
  let body =
    {| { "ok": true,
         "messages": [
           { "ts": "1788708947.825569", "user": "U1", "text": "newest" },
           { "ts": "1788708940.000100", "user": "U2", "text": "older",
             "thread_ts": "1788708900.000001" },
           { "ts": "1788708938.000000", "bot_id": "B1", "text": "bot says" }
         ],
         "has_more": false,
         "response_metadata": { "next_cursor": "" } } |}
  in
  match Rest.parse_conversations_history_response ~status:200 ~body with
  | Error e -> failwith ("expected ok page, got " ^ error_kind e)
  | Ok page ->
    check int "message count" 3 (List.length page.Rest.messages);
    (match page.Rest.messages with
     | newest :: _ -> check string "newest first" "1788708947.825569" newest.Rest.ts
     | [] -> failwith "expected messages");
    (match List.nth page.Rest.messages 1 with
     | m ->
       (match m.Rest.thread_ts with
        | Some parent -> check string "thread reply flagged" "1788708900.000001" parent
        | None -> failwith "expected thread_ts"))
    ;
    check bool "has_more false" false page.Rest.has_more;
    check bool "blank cursor is None" (page.Rest.next_cursor = None) true
;;

let test_parse_slack_api_error () =
  let body = {| { "ok": false, "error": "missing_scope" } |} in
  match Rest.parse_conversations_history_response ~status:200 ~body with
  | Error (Rest.Slack_api { error }) -> check string "error label" "missing_scope" error
  | _ -> failwith "expected slack_api"
;;

let test_parse_http_status () =
  match
    Rest.parse_conversations_history_response ~status:429 ~body:"too many"
  with
  | Error (Rest.Http_status { code; _ }) -> check int "status" 429 code
  | _ -> failwith "expected http_status"
;;

let test_parse_message_without_ts () =
  (* Slack keys messages by ts; a page entry without one is a broken page,
     not a skippable row — parse fails closed. *)
  let body =
    {| { "ok": true, "messages": [ { "user": "U1", "text": "no ts" } ] } |}
  in
  match Rest.parse_conversations_history_response ~status:200 ~body with
  | Error (Rest.Other _) -> ()
  | _ -> failwith "expected other (missing ts)"
;;

(* ---------------------------------------------------------------- *)
(* collection filter                                                *)
(* ---------------------------------------------------------------- *)

let test_pollable_filter () =
  let bot = Some "U0BOT" in
  let yes ?user ?bot_id ?subtype ~ts ~text () =
    Poll.For_testing.pollable ~bot_user_id:bot
      (history_message ?user ?bot_id ?subtype ~ts ~text ())
  in
  check bool "plain human message" true (yes ~user:(Some "U1") ~ts:"1" ~text:"hi" ());
  check bool "bot author excluded" false
    (yes ~user:None ~bot_id:(Some "B1") ~ts:"2" ~text:"app post" ());
  check bool "subtype excluded" false
    (yes ~subtype:(Some "message_changed") ~ts:"3" ~text:"(edited)" ());
  check bool "mention stays on socket path" false
    (yes ~ts:"4" ~text:"<@U0BOT> hello" ());
  check bool "mention of someone else passes" true
    (yes ~ts:"5" ~text:"cc <@U9OTHER>" ());
  check bool "no bot identity known: mention check skipped" true
    (Poll.For_testing.pollable ~bot_user_id:None
       (history_message ~ts:"6" ~text:"<@U0BOT> hi" ()))
;;

(* ---------------------------------------------------------------- *)
(* ring buffer: order, dedupe, capacity                             *)
(* ---------------------------------------------------------------- *)

let lane_msg ~ts ~text : Lane.lane_message =
  { Lane.channel_id = "C1"; ts; user_id = "U1"; text; received_unix = 0.0 }

let test_lane_order_and_dedupe () =
  Lane.clear ();
  Lane.push_many ~channel_id:"C1"
    [ lane_msg ~ts:"1.000000" ~text:"first"
    ; lane_msg ~ts:"2.000000" ~text:"second"
    ; lane_msg ~ts:"2.000000" ~text:"second again (duplicate ts)"
    ]
    ~capacity:10;
  let recent = Lane.recent ~channel_id:"C1" ~limit:10 in
  check int "dedupe on ts" 2 (List.length recent);
  (match recent with
   | newest :: _ -> check string "newest first" "2.000000" newest.Lane.ts
   | [] -> failwith "expected messages");
  check bool "unbound channel is empty"
    (match Lane.recent ~channel_id:"C9" ~limit:10 with [] -> true | _ :: _ -> false)
    true
;;

let test_lane_capacity_trim () =
  Lane.clear ();
  let msgs =
    List.init 10 (fun i -> lane_msg ~ts:(Printf.sprintf "%02d.000000" i) ~text:"m")
  in
  Lane.push_many ~channel_id:"C1" msgs ~capacity:3;
  let recent = Lane.recent ~channel_id:"C1" ~limit:10 in
  check int "capacity trim keeps 3" 3 (List.length recent);
  (match recent with
   | newest :: _ -> check string "kept the newest" "09.000000" newest.Lane.ts
   | [] -> failwith "expected messages");
  (match Lane.channels () with
   | [ (_, count) ] -> check int "channel count" 3 count
   | _ -> failwith "expected one channel")
;;

(* ---------------------------------------------------------------- *)
(* config knob: fail closed                                         *)
(* ---------------------------------------------------------------- *)

let with_temp_toml content f =
  let path = Filename.temp_file "slack_lane_cfg" ".toml" in
  (match content with
   | Some text -> Out_channel.with_open_bin path (fun oc -> output_string oc text)
   | None -> ());
  (try f path
   with e ->
     (try Sys.remove path with _ -> ());
     raise e);
  try Sys.remove path with _ -> ()
;;

let config_case_label = function
  | Poll.Poll_disabled -> "disabled"
  | Poll.Poll_enabled _ -> "enabled"

let test_load_poll_config () =
  with_temp_toml
    (Some {| [slack]
poll_enabled = true
poll_interval_sec = 300
|})
    (fun path ->
      match Poll.load_poll_config ~path with
      | Error e ->
        failwith ("expected enabled: " ^ Poll.poll_config_error_to_string e)
      | Ok loaded ->
        (match loaded with
         | Poll.Poll_enabled { Poll.interval_sec } ->
           check bool "interval from toml" (interval_sec = 300.0) true
         | Poll.Poll_disabled ->
           failwith "expected enabled"));
  with_temp_toml
    (Some {| [slack]
poll_enabled = false
|})
    (fun path ->
      match Poll.load_poll_config ~path with
      | Ok loaded -> check string "disabled" "disabled" (config_case_label loaded)
      | Error e -> failwith ("expected disabled: " ^ Poll.poll_config_error_to_string e));
  with_temp_toml
    (Some {| [slack]
poll_enabled = true
|})
    (fun path ->
      (* No interval: the documented 900-second default. *)
      match Poll.load_poll_config ~path with
      | Ok (Poll.Poll_enabled { Poll.interval_sec }) ->
        check bool "default interval" (interval_sec = 900.0) true
      | _ -> failwith "expected enabled with default interval");
  with_temp_toml
    (Some {| [slack]
poll_enabled = true
poll_interval_sec = 30
|})
    (fun path ->
      (* Below 60 seconds is a typed error, never coerced. *)
      match Poll.load_poll_config ~path with
      | Error (Poll.Poll_interval_invalid _) -> ()
      | _ -> failwith "expected interval error");
  with_temp_toml
    (Some {| [slack]
poll_enabled = "yes"
|})
    (fun path ->
      match Poll.load_poll_config ~path with
      | Error (Poll.Poll_enabled_not_bool _) -> ()
      | _ -> failwith "expected not-bool error");
  with_temp_toml None (fun path ->
      (* Missing file: the lane is off, same as an absent key. *)
      Sys.remove path;
      match Poll.load_poll_config ~path with
      | Ok Poll.Poll_disabled -> ()
      | _ -> failwith "expected disabled for missing file")
;;

(* ---------------------------------------------------------------- *)

let () =
  run "slack_poll_lane"
    [ ( "request"
      , [ test_case "build" `Quick test_build_request ] )
    ; ( "parse"
      , [ test_case "ok page" `Quick test_parse_ok_page
        ; test_case "slack_api error" `Quick test_parse_slack_api_error
        ; test_case "http status" `Quick test_parse_http_status
        ; test_case "message without ts" `Quick test_parse_message_without_ts
        ] )
    ; ( "filter"
      , [ test_case "pollable" `Quick test_pollable_filter ] )
    ; ( "lane"
      , [ test_case "order and dedupe" `Quick test_lane_order_and_dedupe
        ; test_case "capacity trim" `Quick test_lane_capacity_trim
        ] )
    ; ( "config"
      , [ test_case "load_poll_config" `Quick test_load_poll_config ] )
    ]
;;
