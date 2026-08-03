(** Pin the {!Env_config_keeper.KeeperBootstrap} polling
    interval contract. Two values were extracted from inline
    literals at [server_bootstrap_loops.ml]:

    - line 157  0.25  → lazy_startup_poll_interval_sec
    - line 240  0.25  → keeper_listener_retry_interval_sec
    The two [0.25] values shared a literal but encode *different*
    intents (lazy-startup polling vs. listener-retry backoff). The
    SSOT keeps them as separate knobs so future operator overrides
    can tune one without affecting the other.

    Properties pinned:

    1. Defaults preserve the pre-extraction literals (regression
       guard against silent shifts that would change autoboot wall-
       clock or burn CPU on busy-poll).
    2. Polling intervals have a >= 0.05s floor (50ms) so an operator
       typo doesn't accidentally turn the loop into a CPU sink.
    3. Keeper bootstrap starts as soon as lazy startup completes; there is no
       artificial settle delay. *)

open Alcotest

module KB = Env_config_keeper.KeeperBootstrap
module Boot = Server_bootstrap_loops.For_testing
module Chat_queue = Masc.Keeper_chat_queue

let approx = float 0.001

let test_default_lazy_startup_poll () =
  check approx
    "lazy_startup_poll_interval_sec default (was inline 0.25)"
    0.25 KB.lazy_startup_poll_interval_sec

let test_default_listener_retry () =
  check approx
    "keeper_listener_retry_interval_sec default (was inline 0.25)"
    0.25 KB.keeper_listener_retry_interval_sec

let test_polling_floor () =
  check bool
    "lazy_startup_poll_interval_sec must satisfy the documented \
     >= 0.05s floor (else the loop becomes a CPU sink)"
    true
    (KB.lazy_startup_poll_interval_sec >= 0.05);
  check bool
    "keeper_listener_retry_interval_sec must satisfy the documented \
     >= 0.05s floor"
    true
    (KB.keeper_listener_retry_interval_sec >= 0.05)

let test_discord_queue_projection_matches_gateway_context () =
  let queued : Chat_queue.queued_message =
    {
      content = "hello";
      user_blocks = [];
      attachments = [];
      timestamp = 0.0;
      source =
        Chat_queue.Discord
          { channel_id = "discord-channel-1"; user_id = "discord-user-9" };
      user_row_origin = Masc.Keeper_chat_store.Already_persisted_upstream;
    }
  in
  let projection = Boot.queued_chat_projection queued in
  check string "connector label" "discord" projection.payload_channel;
  check string "actor id" "discord-user-9" projection.payload_channel_user_id;
  check string "workspace id uses Discord channel id" "discord-channel-1"
    projection.payload_channel_workspace_id;
  check string "agent identity matches gate channel actor"
    "gate:discord:discord-channel-1:discord-user-9"
    projection.agent_name

let test_slack_queue_projection_matches_gateway_context () =
  let queued : Chat_queue.queued_message =
    { content = "hello"
    ; user_blocks = []
    ; attachments = []
    ; timestamp = 0.0
    ; source =
        Chat_queue.Slack
          { channel_id = "C-SLACK"
          ; user_id = "U-SLACK"
          ; user_name = "Slack User"
          ; team_id = Some "T-SLACK"
          ; thread_ts = Some "171.001"
          }
    ; user_row_origin = Masc.Keeper_chat_store.Already_persisted_upstream
    }
  in
  let projection = Boot.queued_chat_projection queued in
  check string "connector label" "slack" projection.payload_channel;
  check string "actor id" "U-SLACK" projection.payload_channel_user_id;
  check string "actor name" "Slack User" projection.payload_channel_user_name;
  check string "workspace id uses Slack channel id" "C-SLACK"
    projection.payload_channel_workspace_id;
  check string "agent identity matches gate channel actor"
    "gate:slack:C-SLACK:U-SLACK" projection.agent_name;
  match Chat_queue.continuation_channel_of_message_source queued.source with
  | Keeper_continuation_channel.Slack { team_id; channel_id; thread_ts; user_id } ->
    check (option string) "team retained" (Some "T-SLACK") team_id;
    check string "channel retained" "C-SLACK" channel_id;
    check (option string) "thread retained" (Some "171.001") thread_ts;
    check string "user retained" "U-SLACK" user_id
  | _ -> fail "Slack source must project to a Slack continuation"

let () =
  run "env_config_keeper_bootstrap_intervals"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "lazy_startup_poll = 0.25" `Quick
            test_default_lazy_startup_poll;
          test_case "listener_retry = 0.25" `Quick
            test_default_listener_retry;
        ] );
      ( "polling floors",
        [
          test_case ">= 0.05s floor on both polling intervals" `Quick
            test_polling_floor;
        ] );
      ( "queued chat projection",
        [
          test_case "Discord queue source keeps connector context" `Quick
            test_discord_queue_projection_matches_gateway_context;
          test_case "Slack queue source keeps connector context" `Quick
            test_slack_queue_projection_matches_gateway_context;
        ] );
    ]
