(* RFC-0317 — the server's resolved-config trigger-policy parser for the Slack
   gateway must delegate to the single canonical grammar in
   [Slack_gateway_state], so production config and the (separately test-covered)
   grammar cannot drift. Mirror of [test_server_discord_trigger_policy].

   These assertions pin the wrapper's contract: an empty value is unset
   (=> default), the four valid forms parse through to the same variant the
   strict grammar yields, and an unparseable value (or empty user_only id)
   falls back to the default rather than producing a half-formed policy. *)

open Alcotest
module G = Server_slack_in_process_gateway

let ps p = Slack_gateway_state.trigger_policy_to_string p
let default_str = ps G.default_trigger_policy

let test_empty_is_default () =
  check string "empty => default" default_str (ps (G.parse_trigger_policy ""))

let test_whitespace_is_default () =
  check string "whitespace => default" default_str
    (ps (G.parse_trigger_policy "   "))

let test_valid_values_parse_through () =
  (* Each valid form yields exactly what the strict grammar yields,
     proving the wrapper delegates rather than re-implementing. *)
  List.iter
    (fun raw ->
      let expected =
        match Slack_gateway_state.parse_trigger_policy raw with
        | Ok p -> ps p
        | Error msg -> failf "strict grammar rejected %S: %s" raw msg
      in
      check string (Printf.sprintf "%S parses through" raw) expected
        (ps (G.parse_trigger_policy raw)))
    [ "mention_only"; "mention_or_thread"; "all"; "user_only:U123" ]

let test_unknown_falls_back_to_default () =
  (* A typo must not produce a policy the operator did not write. The wrapper
     logs (via Log.Server) and returns the default. *)
  check string "typo => default" default_str
    (ps (G.parse_trigger_policy "mention_ony"))

let test_user_only_empty_id_falls_back () =
  (* The strict grammar rejects an empty id; the wrapper falls back to the
     default instead of constructing User_only "". *)
  check string "user_only: empty id => default" default_str
    (ps (G.parse_trigger_policy "user_only:"))

let () =
  run "server_slack_trigger_policy"
    [ ( "parse_trigger_policy"
      , [ test_case "empty => default" `Quick test_empty_is_default
        ; test_case "whitespace => default" `Quick test_whitespace_is_default
        ; test_case "valid values parse through strict grammar" `Quick
            test_valid_values_parse_through
        ; test_case "unknown => default (no silent coercion)" `Quick
            test_unknown_falls_back_to_default
        ; test_case "user_only empty id => default" `Quick
            test_user_only_empty_id_falls_back
        ] )
    ]
