(** #9794: regression tests for [Env_config.AntiRationalization.fail_mode_of_string].

    The fail_mode config decides whether the verifier-unavailable path in
    [Anti_rationalization.review] approves (liveness-favored, original
    behavior) or rejects (safety-favored). This test pins the parsing
    contract — synonyms, casing, defaulting — so a future refactor that
    accidentally narrows or widens the recognized aliases surfaces here
    rather than as a silently-flipped policy in production. *)

open Alcotest

module AR = Env_config.AntiRationalization

let mode = testable
  (fun ppf m -> Format.fprintf ppf "%s" (AR.fail_mode_to_string m))
  (fun a b -> AR.fail_mode_to_string a = AR.fail_mode_to_string b)

let test_open_default_for_unknown () =
  check mode "garbage -> Open" AR.Open (AR.fail_mode_of_string "garbage");
  check mode "empty string -> Open" AR.Open (AR.fail_mode_of_string "");
  check mode "whitespace-only -> Open" AR.Open (AR.fail_mode_of_string "  \t ")

let test_open_explicit () =
  check mode "open -> Open" AR.Open (AR.fail_mode_of_string "open");
  check mode "OPEN -> Open" AR.Open (AR.fail_mode_of_string "OPEN");
  check mode "Open trimmed" AR.Open (AR.fail_mode_of_string "  open  ")

let test_closed_synonyms () =
  check mode "closed -> Closed" AR.Closed (AR.fail_mode_of_string "closed");
  check mode "reject -> Closed" AR.Closed (AR.fail_mode_of_string "reject");
  check mode "fail_closed -> Closed" AR.Closed (AR.fail_mode_of_string "fail_closed");
  check mode "deny -> Closed" AR.Closed (AR.fail_mode_of_string "deny")

let test_closed_case_and_whitespace () =
  check mode "CLOSED uppercase -> Closed"
    AR.Closed (AR.fail_mode_of_string "CLOSED");
  check mode "  Closed  trimmed -> Closed"
    AR.Closed (AR.fail_mode_of_string "  Closed  ");
  check mode "Reject mixed case -> Closed"
    AR.Closed (AR.fail_mode_of_string "Reject")

let test_round_trip () =
  check mode "Open round-trip"
    AR.Open (AR.fail_mode_of_string (AR.fail_mode_to_string AR.Open));
  check mode "Closed round-trip"
    AR.Closed (AR.fail_mode_of_string (AR.fail_mode_to_string AR.Closed))

let () =
  run "anti_rationalization fail_mode (#9794)" [
    ("default", [
       test_case "unknown values default to Open (liveness)" `Quick
         test_open_default_for_unknown;
     ]);
    ("explicit_open", [
       test_case "open keyword and case variants" `Quick test_open_explicit;
     ]);
    ("closed_synonyms", [
       test_case "closed/reject/fail_closed/deny all map to Closed" `Quick
         test_closed_synonyms;
       test_case "casing and whitespace tolerated" `Quick
         test_closed_case_and_whitespace;
     ]);
    ("invariants", [
       test_case "to_string then of_string is identity" `Quick test_round_trip;
     ]);
  ]
