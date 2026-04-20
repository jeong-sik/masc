(** Tests for keeper_memory_policy strict horizon classifiers (#8826).

    Verifies that:
    - the strict [_opt] variants return [Some] only for documented
      vocabulary,
    - unknown wire strings return [None] (no silent permissive default),
    - the back-compat wrappers preserve the legacy [mid_term_horizon]
      fallback so existing callers see no behaviour change. *)

open Alcotest

module Policy = Masc_mcp.Keeper_memory_policy

let test_known_kinds_return_some () =
  check (option string) "next -> short_term"
    (Some Policy.short_term_horizon)
    (Policy.memory_horizon_of_kind_opt "next");
  check (option string) "open_question -> short_term"
    (Some Policy.short_term_horizon)
    (Policy.memory_horizon_of_kind_opt "open_question");
  check (option string) "progress -> short_term"
    (Some Policy.short_term_horizon)
    (Policy.memory_horizon_of_kind_opt "progress");
  check (option string) "goal -> mid_term"
    (Some Policy.mid_term_horizon)
    (Policy.memory_horizon_of_kind_opt "goal");
  check (option string) "decision -> mid_term"
    (Some Policy.mid_term_horizon)
    (Policy.memory_horizon_of_kind_opt "decision");
  check (option string) "constraints -> mid_term"
    (Some Policy.mid_term_horizon)
    (Policy.memory_horizon_of_kind_opt "constraints");
  check (option string) "long_term -> long_term"
    (Some Policy.long_term_horizon)
    (Policy.memory_horizon_of_kind_opt "long_term")

let test_unknown_kinds_return_none () =
  check (option string) "typo returns None"
    None
    (Policy.memory_horizon_of_kind_opt "goalss");
  check (option string) "future kind returns None"
    None
    (Policy.memory_horizon_of_kind_opt "hypothesis");
  check (option string) "empty string returns None"
    None
    (Policy.memory_horizon_of_kind_opt "");
  check (option string) "whitespace returns None"
    None
    (Policy.memory_horizon_of_kind_opt "   ")

let test_case_and_whitespace_normalised () =
  check (option string) "uppercase normalised"
    (Some Policy.mid_term_horizon)
    (Policy.memory_horizon_of_kind_opt "GOAL");
  check (option string) "leading/trailing whitespace trimmed"
    (Some Policy.short_term_horizon)
    (Policy.memory_horizon_of_kind_opt "  next  ")

let test_wrapper_preserves_legacy_default () =
  (* Back-compat: unknown kind still falls back to mid_term_horizon
     (with a warn line going to the log). *)
  check string "unknown kind -> mid_term legacy"
    Policy.mid_term_horizon
    (Policy.memory_horizon_of_kind "definitely_not_a_kind");
  check string "known kind unchanged"
    Policy.short_term_horizon
    (Policy.memory_horizon_of_kind "next")

let test_json_strict_classifier () =
  let json_with horizon =
    `Assoc [ ("horizon", `String horizon); ("kind", `String "next") ]
  in
  check (option string) "JSON short_term -> Some"
    (Some Policy.short_term_horizon)
    (Policy.memory_horizon_of_json_opt (json_with "short_term"));
  check (option string) "JSON mid_term -> Some"
    (Some Policy.mid_term_horizon)
    (Policy.memory_horizon_of_json_opt (json_with "mid_term"));
  check (option string) "JSON long_term -> Some"
    (Some Policy.long_term_horizon)
    (Policy.memory_horizon_of_json_opt (json_with "long_term"));
  check (option string) "JSON unknown -> None"
    None
    (Policy.memory_horizon_of_json_opt (json_with "unrecognised"));
  check (option string) "JSON missing horizon -> None"
    None
    (Policy.memory_horizon_of_json_opt (`Assoc [ ("kind", `String "next") ]))

let test_json_wrapper_falls_back_to_kind () =
  let json_unknown =
    `Assoc [ ("horizon", `String "unknown_horizon"); ("kind", `String "next") ]
  in
  check string "JSON unknown horizon falls through to kind classification"
    Policy.short_term_horizon
    (Policy.memory_horizon_of_json ~kind:"next" json_unknown);
  let json_known =
    `Assoc [ ("horizon", `String "long_term"); ("kind", `String "next") ]
  in
  check string "JSON known horizon takes precedence over kind"
    Policy.long_term_horizon
    (Policy.memory_horizon_of_json ~kind:"next" json_known)

let () =
  Alcotest.run "memory_horizon_classifier"
    [
      ( "strict classifier",
        [
          test_case "known kinds return Some" `Quick
            test_known_kinds_return_some;
          test_case "unknown kinds return None" `Quick
            test_unknown_kinds_return_none;
          test_case "case and whitespace normalised" `Quick
            test_case_and_whitespace_normalised;
          test_case "JSON strict classifier" `Quick test_json_strict_classifier;
        ] );
      ( "back-compat wrappers",
        [
          test_case "wrapper preserves legacy default" `Quick
            test_wrapper_preserves_legacy_default;
          test_case "JSON wrapper falls back to kind" `Quick
            test_json_wrapper_falls_back_to_kind;
        ] );
    ]
