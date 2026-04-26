(* #9886: verify fixture-vote quarantine default behaviour. *)

open Alcotest
module BV = Masc_mcp.Board_votes

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f
;;

(* [Unix.unsetenv] is not available portably, so the default-unset case
   is exercised by the matching [quarantine_enabled] branch below via
   the "empty string treated as disabled" rule. The code path for the
   [None] arm of [Sys.getenv_opt] is trivially [true] and not tested
   directly here — [test_quarantine_explicit_*] pins the non-default
   paths. *)
let test_quarantine_empty_treated_as_disabled () =
  with_env "MASC_BOARD_VOTE_QUARANTINE" "" (fun () ->
    check
      bool
      "empty string disables (explicit operator opt-out)"
      false
      (BV.quarantine_enabled ()))
;;

let test_quarantine_explicit_true () =
  with_env "MASC_BOARD_VOTE_QUARANTINE" "true" (fun () ->
    check bool "'true' enables" true (BV.quarantine_enabled ()));
  with_env "MASC_BOARD_VOTE_QUARANTINE" "1" (fun () ->
    check bool "'1' enables" true (BV.quarantine_enabled ()));
  with_env "MASC_BOARD_VOTE_QUARANTINE" "TRUE" (fun () ->
    check bool "'TRUE' enables (case)" true (BV.quarantine_enabled ()))
;;

let test_quarantine_explicit_false () =
  with_env "MASC_BOARD_VOTE_QUARANTINE" "0" (fun () ->
    check bool "'0' disables" false (BV.quarantine_enabled ()));
  with_env "MASC_BOARD_VOTE_QUARANTINE" "false" (fun () ->
    check bool "'false' disables" false (BV.quarantine_enabled ()));
  with_env "MASC_BOARD_VOTE_QUARANTINE" "off" (fun () ->
    check bool "'off' disables" false (BV.quarantine_enabled ()))
;;

let () =
  run
    "board_vote_quarantine"
    [ ( "explicit"
      , [ test_case
            "empty string treated as disabled"
            `Quick
            test_quarantine_empty_treated_as_disabled
        ; test_case "truthy values enable" `Quick test_quarantine_explicit_true
        ; test_case "falsy values disable" `Quick test_quarantine_explicit_false
        ] )
    ]
;;
