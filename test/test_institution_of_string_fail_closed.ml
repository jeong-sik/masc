(** Pin fail-closed parsing for [Institution_eio.outcome_of_string] and
    [mentor_of_string].  Pre-fix both helpers swallowed unknown input
    via a wildcard branch:

    {[
      let outcome_of_string = function
        | "success" -> `Success | "failure" -> `Failure
        | _ -> `Partial                              (* silent default *)

      let mentor_of_string = function
        | "random" -> `Random | "best_fit" -> `Best_fit
        | "round_robin" -> `Round_robin
        | _ -> `Best_fit                             (* silent default *)
    ]}

    The "Unknown -> Permissive Default" anti-pattern erases the
    diagnostic trail: typo, future-variant, or garbage payload all
    collapse onto a single healthy bucket.  Same class as
    [agent_status_of_string_r] (#10748) and the keeper runtime
    fail-closed sweep (#11256).

    Tests pin two contracts:

    1. Known canonical strings continue to parse to the matching
       polymorphic variant (regression guard).
    2. Unknown strings raise [Yojson.Safe.Util.Type_error] so callers
       that already absorb [Type_error] (e.g. [load_institution] at
       institution_eio.ml:336, [load_recent_episodes_jsonl] at :660,
       [load_and_format_for_welcome] at :617, and the MCP resource
       reader after this PR) drop the malformed entry instead of
       parading it as healthy [`Partial] / [`Best_fit]. *)

open Alcotest

module I = Masc_mcp.Institution_eio

(* --- outcome_of_string --------------------------------------------- *)

let test_outcome_known_success () =
  check bool "success" true (I.outcome_of_string "success" = `Success)

let test_outcome_known_failure () =
  check bool "failure" true (I.outcome_of_string "failure" = `Failure)

let test_outcome_known_partial () =
  check bool "partial" true (I.outcome_of_string "partial" = `Partial)

let test_outcome_unknown_raises () =
  match I.outcome_of_string "garbage_outcome" with
  | exception Yojson.Safe.Util.Type_error (msg, _) ->
      check bool "message references unknown outcome" true
        (Astring.String.is_infix ~affix:"unknown institution outcome" msg)
  | _ ->
      fail "expected Type_error for unknown outcome string"

let test_outcome_empty_raises () =
  match I.outcome_of_string "" with
  | exception Yojson.Safe.Util.Type_error _ -> ()
  | _ -> fail "expected Type_error for empty outcome string"

(* --- mentor_of_string ---------------------------------------------- *)

let test_mentor_known_random () =
  check bool "random" true (I.mentor_of_string "random" = `Random)

let test_mentor_known_best_fit () =
  check bool "best_fit" true (I.mentor_of_string "best_fit" = `Best_fit)

let test_mentor_known_round_robin () =
  check bool "round_robin" true
    (I.mentor_of_string "round_robin" = `Round_robin)

let test_mentor_unknown_raises () =
  match I.mentor_of_string "wise_owl" with
  | exception Yojson.Safe.Util.Type_error (msg, _) ->
      check bool "message references unknown mentor" true
        (Astring.String.is_infix ~affix:"unknown mentor assignment" msg)
  | _ ->
      fail "expected Type_error for unknown mentor string"

(* --- roundtrip via _to_string ------------------------------------- *)

let test_outcome_roundtrip () =
  let cases = [`Success; `Failure; `Partial] in
  List.iter
    (fun v ->
      let s = I.outcome_to_string v in
      check bool ("roundtrip " ^ s) true (I.outcome_of_string s = v))
    cases

let test_mentor_roundtrip () =
  let cases = [`Random; `Best_fit; `Round_robin] in
  List.iter
    (fun v ->
      let s = I.mentor_to_string v in
      check bool ("roundtrip " ^ s) true (I.mentor_of_string s = v))
    cases

let () =
  run "institution_of_string_fail_closed"
    [
      ( "outcome_of_string",
        [
          test_case "known: success" `Quick test_outcome_known_success;
          test_case "known: failure" `Quick test_outcome_known_failure;
          test_case "known: partial" `Quick test_outcome_known_partial;
          test_case "unknown raises Type_error" `Quick
            test_outcome_unknown_raises;
          test_case "empty raises Type_error" `Quick
            test_outcome_empty_raises;
          test_case "roundtrip" `Quick test_outcome_roundtrip;
        ] );
      ( "mentor_of_string",
        [
          test_case "known: random" `Quick test_mentor_known_random;
          test_case "known: best_fit" `Quick test_mentor_known_best_fit;
          test_case "known: round_robin" `Quick
            test_mentor_known_round_robin;
          test_case "unknown raises Type_error" `Quick
            test_mentor_unknown_raises;
          test_case "roundtrip" `Quick test_mentor_roundtrip;
        ] );
    ]
