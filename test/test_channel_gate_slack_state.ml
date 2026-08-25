(* masc#29079 — the Slack connector's status must not read healthy while it is
   structurally unable to answer, and "connected" must mean one thing.

   Two defects are pinned here:

   - [available] ignored SLACK_BOT_TOKEN. Slack has two credentials with
     different failure modes: without SLACK_APP_TOKEN the Socket Mode gateway
     never starts, without SLACK_BOT_TOKEN it starts and receives but every
     reply fails ([Channel_gate_slack_state.send_message] returns
     [Missing_token]). Only the first was part of the verdict, so an operator
     saw a live card for a connector that could not reply.
   - [connected] had two definitions in one module: [status_json] folded
     startup and binding-store health into it, while the
     [Channel_gate_connector.S] export read the socket alone. Routing and the
     dashboard could disagree. *)

open Alcotest
open Masc
module State = Channel_gate_slack_state
module U = Yojson.Safe.Util

external unsetenv : string -> unit = "masc_test_unsetenv"

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> unsetenv key)
    (fun () ->
      Unix.putenv key value;
      f ())
;;

let without_env key f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> unsetenv key)
    (fun () ->
      unsetenv key;
      f ())
;;

(* A private base path so the binding store reads cleanly and no test touches
   an operator's real .gate/runtime/slack. *)
let with_temp_base f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-slack-state-%d-%d"
         (Unix.getpid ())
         (Random.bits ()))
  in
  with_env Env_config_core.base_path_env_key base_path (fun () ->
    with_env Env_config_core.base_path_input_env_key base_path f)
;;

let status_of f =
  with_temp_base (fun () ->
    State.clear_startup_error ();
    Fun.protect ~finally:State.clear_startup_error (fun () -> f (State.status_json ())))
;;

let string_field status key = status |> U.member key |> U.to_string
let bool_field status key = status |> U.member key |> U.to_bool

let test_missing_bot_token_is_not_available () =
  with_env "SLACK_APP_TOKEN" "xapp-test" (fun () ->
    without_env "SLACK_BOT_TOKEN" (fun () ->
      status_of (fun status ->
        check bool "app token alone is not availability" false
          (bool_field status "available");
        check bool "app_token_present" true
          (bool_field status "app_token_present");
        check bool "bot_token_present" false
          (bool_field status "bot_token_present");
        check string "status uses connector vocabulary" "offline"
          (string_field status "status");
        (* The operator has to be able to read why. Before masc#29079 this
           field was empty whenever the socket was not in Disconnected. *)
        check bool "error names the missing credential" true
          (let error = string_field status "error" in
           let needle = "SLACK_BOT_TOKEN" in
           let n = String.length needle in
           let rec scan i =
             i + n <= String.length error
             && (String.equal (String.sub error i n) needle || scan (i + 1))
           in
           scan 0))))
;;

let test_missing_app_token_names_the_app_token () =
  without_env "SLACK_APP_TOKEN" (fun () ->
    without_env "SLACK_BOT_TOKEN" (fun () ->
      status_of (fun status ->
        check bool "not available" false (bool_field status "available");
        (* App token first: without it the gateway never starts at all, so it
           is the actionable one. *)
        check string "error names the app token" "SLACK_APP_TOKEN is unset or empty"
          (string_field status "error"))))
;;

let test_both_tokens_present_is_available () =
  with_env "SLACK_APP_TOKEN" "xapp-test" (fun () ->
    with_env "SLACK_BOT_TOKEN" "xoxb-test" (fun () ->
      status_of (fun status ->
        check bool "available with both credentials" true
          (bool_field status "available");
        (* No socket runs in this suite, so the transport is honestly down and
           the card reads disconnected rather than offline. *)
        check bool "not connected" false (bool_field status "connected");
        check string "status" "disconnected" (string_field status "status");
        check string "no error to report" "" (string_field status "error"))))
;;

(* Narrow on purpose, and named for what it can actually decide.

   The interesting case for the unified definition is transport-up +
   startup/binding-store-down, where the two old definitions disagreed. That
   case is unreachable here: [Slack_socket_client]'s published state is a
   module-private atomic written only by the run loop, so an in-process test
   cannot report [Connected] without a socket. Adding a setter for the test
   would be a backdoor into production state, so the divergence stays closed by
   construction (one function, [transport_connected]) rather than by this
   assertion. What this does catch is a status field that stops tracking the
   registry export at all — a hardcoded value, or a fold that ignores the
   transport. *)
let test_connected_field_mirrors_registry_export_when_transport_is_down () =
  with_env "SLACK_APP_TOKEN" "xapp-test" (fun () ->
    with_env "SLACK_BOT_TOKEN" "xoxb-test" (fun () ->
      with_temp_base (fun () ->
        State.clear_startup_error ();
        Fun.protect
          ~finally:State.clear_startup_error
          (fun () ->
            check bool "agree when healthy" (State.connected ())
              (bool_field (State.status_json ()) "connected");
            State.record_startup_error "invalid Slack trigger policy";
            check bool "agree under a startup error" (State.connected ())
              (bool_field (State.status_json ()) "connected")))))
;;

let test_startup_error_still_offline_with_reason () =
  (* Regression guard for the behaviour masc#29078's suite depends on: a
     recorded startup error stays the whole message and keeps the card offline,
     even though credentials are now part of [available]. *)
  with_env "SLACK_APP_TOKEN" "xapp-test" (fun () ->
    with_env "SLACK_BOT_TOKEN" "xoxb-test" (fun () ->
      with_temp_base (fun () ->
        State.record_startup_error "invalid Slack trigger policy";
        Fun.protect
          ~finally:State.clear_startup_error
          (fun () ->
            let status = State.status_json () in
            check bool "not available" false (bool_field status "available");
            check string "status" "offline" (string_field status "status");
            check string "startup error is the whole message"
              "invalid Slack trigger policy" (string_field status "error")))))
;;

let () =
  run "channel_gate_slack_state"
    [ ( "availability"
      , [ test_case "missing bot token => offline with reason" `Quick
            test_missing_bot_token_is_not_available
        ; test_case "missing app token => named first" `Quick
            test_missing_app_token_names_the_app_token
        ; test_case "both credentials => available" `Quick
            test_both_tokens_present_is_available
        ; test_case "startup error => offline, error preserved" `Quick
            test_startup_error_still_offline_with_reason
        ] )
    ; ( "connected field tracks the registry export"
      , [ test_case
            "status field mirrors the registry export (transport down)" `Quick
            test_connected_field_mirrors_registry_export_when_transport_is_down
        ] )
    ]
;;
