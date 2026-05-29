(* RFC-0203 Phase 2 — Discord_builtin_config unit tests. *)

open Alcotest
module C = Discord_builtin_config

let setenv k v = Unix.putenv k v
let unsetenv k = Unix.putenv k ""

(* ---------------------------------------------------------------- *)
(* builtin_enabled                                                  *)
(* ---------------------------------------------------------------- *)

let test_flag_default_false () =
  unsetenv "MASC_DISCORD_BUILTIN";
  check bool "default false" false (C.builtin_enabled ())

let test_flag_truthy () =
  setenv "MASC_DISCORD_BUILTIN" "true";
  check bool "true => enabled" true (C.builtin_enabled ());
  unsetenv "MASC_DISCORD_BUILTIN"

let test_flag_falsy () =
  setenv "MASC_DISCORD_BUILTIN" "false";
  check bool "false => disabled" false (C.builtin_enabled ());
  unsetenv "MASC_DISCORD_BUILTIN"

(* ---------------------------------------------------------------- *)
(* parse_policy                                                     *)
(* ---------------------------------------------------------------- *)

let test_parse_mention_only () =
  match C.parse_policy "mention_only" with
  | Ok Discord_gateway_client.Mention_only -> ()
  | _ -> fail "expected Mention_only"

let test_parse_all () =
  match C.parse_policy "all" with
  | Ok Discord_gateway_client.All -> ()
  | _ -> fail "expected All"

let test_parse_user_only_happy () =
  match C.parse_policy "user_only:1234567890" with
  | Ok (Discord_gateway_client.User_only id) ->
    check string "id pinned" "1234567890" id
  | _ -> fail "expected User_only with id"

let test_parse_user_only_missing_id () =
  match C.parse_policy "user_only:" with
  | Error C.User_only_missing_id -> ()
  | _ -> fail "expected User_only_missing_id"

let test_parse_user_only_no_colon () =
  match C.parse_policy "user_only" with
  | Error C.User_only_missing_id -> ()
  | _ -> fail "expected User_only_missing_id"

let test_parse_empty_string () =
  match C.parse_policy "" with
  | Error C.Empty -> ()
  | _ -> fail "expected Empty"

let test_parse_unknown_value () =
  match C.parse_policy "channel_only" with
  | Error (C.Unknown_value "channel_only") -> ()
  | _ -> fail "expected Unknown_value"

let test_parse_trims_whitespace () =
  match C.parse_policy "  mention_only  " with
  | Ok Discord_gateway_client.Mention_only -> ()
  | _ -> fail "expected Mention_only after trim"

(* ---------------------------------------------------------------- *)
(* trigger_policy — env resolution + safe fallback                  *)
(* ---------------------------------------------------------------- *)

let test_trigger_policy_default () =
  unsetenv "MASC_DISCORD_TRIGGER_POLICY";
  match C.trigger_policy () with
  | Discord_gateway_client.Mention_only -> ()
  | _ -> fail "expected Mention_only default"

let test_trigger_policy_user_only () =
  setenv "MASC_DISCORD_TRIGGER_POLICY" "user_only:42";
  (match C.trigger_policy () with
   | Discord_gateway_client.User_only "42" -> ()
   | _ -> fail "expected User_only 42");
  unsetenv "MASC_DISCORD_TRIGGER_POLICY"

let test_trigger_policy_invalid_falls_back_to_default () =
  setenv "MASC_DISCORD_TRIGGER_POLICY" "everything";
  (match C.trigger_policy () with
   | Discord_gateway_client.Mention_only -> ()
   | _ -> fail "expected silent fallback to Mention_only");
  unsetenv "MASC_DISCORD_TRIGGER_POLICY"

(* ---------------------------------------------------------------- *)
(* bot_token                                                        *)
(* ---------------------------------------------------------------- *)

let test_bot_token_unset () =
  unsetenv "DISCORD_BOT_TOKEN";
  check (option string) "unset => None" None (C.bot_token ())

let test_bot_token_present () =
  setenv "DISCORD_BOT_TOKEN" "Bot.test.token";
  check (option string) "set => Some" (Some "Bot.test.token") (C.bot_token ());
  unsetenv "DISCORD_BOT_TOKEN"

let test_bot_token_whitespace_trimmed () =
  setenv "DISCORD_BOT_TOKEN" "  ABC  ";
  check (option string) "whitespace trimmed" (Some "ABC") (C.bot_token ());
  unsetenv "DISCORD_BOT_TOKEN"

(* ---------------------------------------------------------------- *)
(* intents                                                          *)
(* ---------------------------------------------------------------- *)

let test_intents_exact_rfc_list () =
  let expected =
    [ Discord_gateway_client.Guilds
    ; Discord_gateway_client.Guild_messages
    ; Discord_gateway_client.Message_content
    ; Discord_gateway_client.Guild_message_reactions
    ; Discord_gateway_client.Direct_messages
    ; Discord_gateway_client.Direct_message_reactions
    ]
  in
  check int "intents count matches RFC §Modules"
    (List.length expected) (List.length C.intents);
  (* Bitmask of the intent list must be the same whether constructed
     from C.intents or from the explicit RFC list — guards against
     reordering or accidental member changes. *)
  check int "bitmask equality"
    (Discord_gateway_client.intents_bitmask expected)
    (Discord_gateway_client.intents_bitmask C.intents)

(* ---------------------------------------------------------------- *)
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

let () =
  run "discord_builtin_config"
    [ ( "builtin_enabled"
      , [ test_case "default false" `Quick test_flag_default_false
        ; test_case "truthy" `Quick test_flag_truthy
        ; test_case "falsy" `Quick test_flag_falsy
        ] )
    ; ( "parse_policy"
      , [ test_case "mention_only" `Quick test_parse_mention_only
        ; test_case "all" `Quick test_parse_all
        ; test_case "user_only happy" `Quick test_parse_user_only_happy
        ; test_case "user_only missing id (colon)" `Quick
            test_parse_user_only_missing_id
        ; test_case "user_only no colon" `Quick test_parse_user_only_no_colon
        ; test_case "empty string" `Quick test_parse_empty_string
        ; test_case "unknown value" `Quick test_parse_unknown_value
        ; test_case "trims whitespace" `Quick test_parse_trims_whitespace
        ] )
    ; ( "trigger_policy"
      , [ test_case "default = Mention_only" `Quick test_trigger_policy_default
        ; test_case "user_only via env" `Quick test_trigger_policy_user_only
        ; test_case "invalid falls back to default" `Quick
            test_trigger_policy_invalid_falls_back_to_default
        ] )
    ; ( "bot_token"
      , [ test_case "unset => None" `Quick test_bot_token_unset
        ; test_case "present" `Quick test_bot_token_present
        ; test_case "whitespace trimmed" `Quick test_bot_token_whitespace_trimmed
        ] )
    ; ( "intents"
      , [ test_case "exact RFC §Modules list" `Quick
            test_intents_exact_rfc_list
        ] )
    ]
