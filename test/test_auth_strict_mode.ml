(** test_auth_strict_mode — pure parser of [Auth_strict_mode] (Phase A F2).

    The runtime [current ()] reads [MASC_AUTH_STRICT] from the process
    environment and is therefore not unit-testable in isolation.  We pin
    [of_string] / [to_label] here because Phase B PR-2 will branch real
    behavior on this variant, so a silent rename or unknown-handling change
    must fail at the test boundary rather than in production telemetry. *)

open Masc_mcp

let mode_testable =
  Alcotest.testable
    (fun fmt -> function
      | Auth_strict_mode.Off -> Format.fprintf fmt "Off"
      | Auth_strict_mode.Dry_run -> Format.fprintf fmt "Dry_run"
      | Auth_strict_mode.Strict -> Format.fprintf fmt "Strict")
    ( = )

let test_of_string_off () =
  List.iter
    (fun raw ->
      Alcotest.check mode_testable (Printf.sprintf "%S -> Off" raw)
        Auth_strict_mode.Off (Auth_strict_mode.of_string raw))
    [ "off"; "OFF"; "Off"; "0"; "false"; "FALSE"; "  off  " ]

let test_of_string_strict () =
  List.iter
    (fun raw ->
      Alcotest.check mode_testable
        (Printf.sprintf "%S -> Strict" raw)
        Auth_strict_mode.Strict
        (Auth_strict_mode.of_string raw))
    [ "strict"; "STRICT"; "Strict"; "1"; "true"; "TRUE"; "  strict  " ]

let test_of_string_dry_run () =
  List.iter
    (fun raw ->
      Alcotest.check mode_testable
        (Printf.sprintf "%S -> Dry_run" raw)
        Auth_strict_mode.Dry_run
        (Auth_strict_mode.of_string raw))
    [ "dry_run"; "Dry_Run"; "DRY-RUN"; "dry-run"; "" ]

let test_of_string_unknown_defaults_dry_run () =
  (* Operator omissions and typos must not silently disable measurement.
     Unknown values fall through to Dry_run so the [would_reject] counter
     keeps firing and we notice the misconfiguration. *)
  List.iter
    (fun raw ->
      Alcotest.check mode_testable
        (Printf.sprintf "%S -> Dry_run (unknown)" raw)
        Auth_strict_mode.Dry_run
        (Auth_strict_mode.of_string raw))
    [ "yes"; "no"; "enabled"; "disabled"; "2"; "STRIKT" ]

let test_to_label_canonical () =
  Alcotest.(check string) "Off label" "off"
    (Auth_strict_mode.to_label Auth_strict_mode.Off);
  Alcotest.(check string) "Dry_run label" "dry_run"
    (Auth_strict_mode.to_label Auth_strict_mode.Dry_run);
  Alcotest.(check string) "Strict label" "strict"
    (Auth_strict_mode.to_label Auth_strict_mode.Strict)

let test_to_label_round_trips_through_of_string () =
  List.iter
    (fun mode ->
      let label = Auth_strict_mode.to_label mode in
      Alcotest.check mode_testable
        (Printf.sprintf "round-trip via label %S" label)
        mode
        (Auth_strict_mode.of_string label))
    [ Auth_strict_mode.Off; Auth_strict_mode.Dry_run; Auth_strict_mode.Strict ]

let () =
  Alcotest.run "auth_strict_mode"
    [
      ( "of_string",
        [
          Alcotest.test_case "Off canonical + aliases" `Quick
            test_of_string_off;
          Alcotest.test_case "Strict canonical + aliases" `Quick
            test_of_string_strict;
          Alcotest.test_case "Dry_run canonical + aliases" `Quick
            test_of_string_dry_run;
          Alcotest.test_case "unknown -> Dry_run" `Quick
            test_of_string_unknown_defaults_dry_run;
        ] );
      ( "to_label",
        [
          Alcotest.test_case "canonical labels" `Quick test_to_label_canonical;
          Alcotest.test_case "round-trip" `Quick
            test_to_label_round_trips_through_of_string;
        ] );
    ]
