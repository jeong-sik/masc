(* RFC-0320 W2b: connector provenance rides losslessly from the chat-dispatch
   payload through the [masc_keeper_msg] tool args to the approval queue.

   These tests pin the JSON-boundary crossing the keeper turn depends on
   ([Server_routes_http_keeper_stream.args_of_request] writes the field;
   [Keeper_turn] reads it back with [Keeper_continuation_channel.of_yojson]):

   - a routable continuation channel serializes via the typed codec and
     round-trips to the identical typed value (no lossy string classifier);
   - an [Unrouted] channel is omitted from the args, so the reader fail-closes
     to [None] instead of round-tripping a diagnostic placeholder;
   - the HTTP parse path carries only flat connector strings and is therefore
     fail-closed to [Unrouted] (it must not fabricate a typed channel). *)

open Alcotest
open Masc
module Stream = Server_routes_http_keeper_stream

let channel : Keeper_continuation_channel.t testable =
  testable
    (fun fmt c ->
      Format.pp_print_string fmt (Keeper_continuation_channel.describe c))
    (fun a b ->
      Yojson.Safe.equal
        (Keeper_continuation_channel.to_yojson a)
        (Keeper_continuation_channel.to_yojson b))

let payload_with (cc : Keeper_continuation_channel.t) :
    Stream.keeper_chat_stream_request =
  { Stream.name = "luna";
    message = "hello";
    user_blocks = [];
    timeout_sec = None;
    turn_instructions = None;
    surface_context = None;
    channel = "";
    channel_user_id = "";
    channel_user_name = "";
    channel_workspace_id = "";
    attachments = [];
    continuation_channel = cc;
  }

let cc_field args =
  match args with
  | `Assoc fields -> List.assoc_opt "continuation_channel" fields
  | _ -> None

(* Mirror of the keeper-turn read path: recover the typed channel from the
   serialized args, or [None] when absent/unparseable. *)
let recovered_channel args =
  match cc_field args with
  | Some json -> (
      match Keeper_continuation_channel.of_yojson json with
      | Ok c -> Some c
      | Error _ -> None)
  | None -> None

let discord_channel =
  Keeper_continuation_channel.Discord
    { guild_id = Some "g1";
      channel_id = "c1";
      parent_channel_id = None;
      thread_id = Some "t1";
      user_id = "u1";
    }

let dashboard_channel =
  Keeper_continuation_channel.Dashboard { thread_id = "keeper-consumer:luna" }

let test_discord_round_trips () =
  let args = Stream.For_testing.args_of_request (payload_with discord_channel) in
  check bool "continuation_channel present" true
    (Option.is_some (cc_field args));
  check (option channel) "discord channel recovered losslessly"
    (Some discord_channel) (recovered_channel args)

let test_dashboard_round_trips () =
  let args = Stream.For_testing.args_of_request (payload_with dashboard_channel) in
  check (option channel) "dashboard channel recovered losslessly"
    (Some dashboard_channel) (recovered_channel args)

let test_unrouted_is_omitted () =
  let args =
    Stream.For_testing.args_of_request
      (payload_with (Keeper_continuation_channel.unrouted "no connector"))
  in
  check bool "unrouted channel omitted from args" true
    (Option.is_none (cc_field args));
  check (option channel) "reader fail-closes to None" None
    (recovered_channel args)

let test_http_parse_is_unrouted () =
  (* Even a fully-populated connector HTTP body yields [Unrouted]: the flat
     strings cannot be reconstructed into the typed variant without a string
     classifier, so provenance is fail-closed on this path. *)
  let body =
    {|{"name":"luna","message":"hi","channel":"discord","channel_user_id":"u1","channel_workspace_id":"w1"}|}
  in
  match Stream.For_testing.parse_request body with
  | Error err -> fail ("expected parse to succeed: " ^ err)
  | Ok payload ->
      check bool "parsed channel is not routable" false
        (Keeper_continuation_channel.is_routable payload.continuation_channel);
      let args = Stream.For_testing.args_of_request payload in
      check bool "http path omits continuation_channel" true
        (Option.is_none (cc_field args))

(* The chat-consumer dispatch derives the typed continuation channel from the
   queued message's typed source via this SSOT projection. *)
let test_source_projection_dashboard () =
  check channel "dashboard source -> Dashboard with caller thread id"
    (Keeper_continuation_channel.Dashboard { thread_id = "keeper-consumer:luna" })
    (Keeper_chat_queue.continuation_channel_of_source
       ~dashboard_thread_id:"keeper-consumer:luna" Keeper_chat_queue.Dashboard)

let test_source_projection_discord () =
  check channel "discord source -> Discord with straight ids"
    (Keeper_continuation_channel.Discord
       { guild_id = None;
         channel_id = "c9";
         parent_channel_id = None;
         thread_id = None;
         user_id = "u9";
       })
    (Keeper_chat_queue.continuation_channel_of_source
       ~dashboard_thread_id:"unused"
       (Keeper_chat_queue.Discord { channel_id = "c9"; user_id = "u9" }))

let test_source_projection_slack () =
  check channel "slack source -> Slack (channel renamed to channel_id)"
    (Keeper_continuation_channel.Slack
       { team_id = None; channel_id = "C123"; thread_ts = None; user_id = "u9" })
    (Keeper_chat_queue.continuation_channel_of_source
       ~dashboard_thread_id:"unused"
       (Keeper_chat_queue.Slack { channel = "C123"; user_id = "u9" }))

let () =
  run "rfc0320_w2b_provenance"
    [
      ( "source-projection",
        [
          test_case "dashboard source projects to Dashboard" `Quick
            test_source_projection_dashboard;
          test_case "discord source projects to Discord" `Quick
            test_source_projection_discord;
          test_case "slack source projects to Slack" `Quick
            test_source_projection_slack;
        ] );
      ( "json-boundary",
        [
          test_case "discord channel round-trips losslessly" `Quick
            test_discord_round_trips;
          test_case "dashboard channel round-trips losslessly" `Quick
            test_dashboard_round_trips;
          test_case "unrouted channel is omitted (fail-closed)" `Quick
            test_unrouted_is_omitted;
          test_case "http parse path is unrouted" `Quick
            test_http_parse_is_unrouted;
        ] );
    ]
