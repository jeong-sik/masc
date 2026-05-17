(** Tests for RFC-0092 Phase A typed-advisor counter wiring.

    Pins the contract that [Legendary_counters.incr_typed_advisor]
    routes each [Shell_ir_validator.advisory] variant to the right
    counter atom and that the snapshot/JSON shape includes the three
    new fields under stable names operators / dashboards will grep. *)

module L = Masc_mcp.Legendary_counters
module V = Masc_mcp.Shell_ir_validator

let test_initial_zero () =
  L.reset ();
  let s = L.snapshot () in
  Alcotest.(check int) "typed_advisor_allow" 0 s.typed_advisor_allow;
  Alcotest.(check int) "typed_advisor_reject" 0 s.typed_advisor_reject;
  Alcotest.(check int)
    "typed_advisor_cannot_parse"
    0
    s.typed_advisor_cannot_parse
;;

let test_allow_increments_allow () =
  L.reset ();
  L.incr_typed_advisor V.Allow;
  L.incr_typed_advisor V.Allow;
  let s = L.snapshot () in
  Alcotest.(check int) "allow = 2" 2 s.typed_advisor_allow;
  Alcotest.(check int) "reject = 0" 0 s.typed_advisor_reject;
  Alcotest.(check int)
    "cannot_parse = 0"
    0
    s.typed_advisor_cannot_parse
;;

let test_reject_increments_reject () =
  L.reset ();
  L.incr_typed_advisor
    (V.Reject
       { reason = V.Command_not_in_allowlist "foo"; diagnostic = "foo" });
  let s = L.snapshot () in
  Alcotest.(check int) "allow = 0" 0 s.typed_advisor_allow;
  Alcotest.(check int) "reject = 1" 1 s.typed_advisor_reject;
  Alcotest.(check int)
    "cannot_parse = 0"
    0
    s.typed_advisor_cannot_parse
;;

let test_cannot_parse_increments_cannot_parse () =
  L.reset ();
  L.incr_typed_advisor (V.Cannot_parse { kind = V.Parse_error });
  let s = L.snapshot () in
  Alcotest.(check int)
    "cannot_parse = 1"
    1
    s.typed_advisor_cannot_parse
;;

let test_reset_clears () =
  L.incr_typed_advisor V.Allow;
  L.incr_typed_advisor
    (V.Reject
       { reason = V.Command_not_in_allowlist "x"; diagnostic = "x" });
  L.incr_typed_advisor (V.Cannot_parse { kind = V.Parse_error });
  L.reset ();
  let s = L.snapshot () in
  Alcotest.(check int) "post-reset allow" 0 s.typed_advisor_allow;
  Alcotest.(check int) "post-reset reject" 0 s.typed_advisor_reject;
  Alcotest.(check int)
    "post-reset cannot_parse"
    0
    s.typed_advisor_cannot_parse
;;

let test_json_shape () =
  (* Operator dashboards / runbook greps depend on these exact field
     names — pin them. *)
  L.reset ();
  L.incr_typed_advisor V.Allow;
  let json = L.snapshot_to_json (L.snapshot ()) in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool)
    "has typed_advisor_allow"
    true
    (Astring.String.is_infix ~affix:"\"typed_advisor_allow\":1" s);
  Alcotest.(check bool)
    "has typed_advisor_reject"
    true
    (Astring.String.is_infix ~affix:"\"typed_advisor_reject\":0" s);
  Alcotest.(check bool)
    "has typed_advisor_cannot_parse"
    true
    (Astring.String.is_infix
       ~affix:"\"typed_advisor_cannot_parse\":0"
       s)
;;

let test_env_flag_default_off () =
  (* Flag must be off by default — production observers should not
     pay any cost until an operator explicitly opts in. *)
  let prev = Sys.getenv_opt "MASC_BASH_TYPED_ADVISOR" in
  Unix.putenv "MASC_BASH_TYPED_ADVISOR" "";
  let off = Masc_mcp.Gate_diff_types.typed_advisor_log_enabled () in
  Unix.putenv "MASC_BASH_TYPED_ADVISOR" "1";
  let on = Masc_mcp.Gate_diff_types.typed_advisor_log_enabled () in
  (match prev with
   | None -> Unix.putenv "MASC_BASH_TYPED_ADVISOR" ""
   | Some v -> Unix.putenv "MASC_BASH_TYPED_ADVISOR" v);
  Alcotest.(check bool) "empty env → off" false off;
  Alcotest.(check bool) "\"1\" env → on" true on
;;

let () =
  Alcotest.run
    "typed_advisor_counters"
    [ ( "buckets"
      , [ Alcotest.test_case "initial zero" `Quick test_initial_zero
        ; Alcotest.test_case "Allow → allow" `Quick test_allow_increments_allow
        ; Alcotest.test_case
            "Reject → reject"
            `Quick
            test_reject_increments_reject
        ; Alcotest.test_case
            "Cannot_parse → cannot_parse"
            `Quick
            test_cannot_parse_increments_cannot_parse
        ; Alcotest.test_case "reset clears" `Quick test_reset_clears
        ] )
    ; ( "json_shape"
      , [ Alcotest.test_case
            "three fields under stable names"
            `Quick
            test_json_shape
        ] )
    ; ( "env_flag"
      , [ Alcotest.test_case
            "default off, \"1\" turns on"
            `Quick
            test_env_flag_default_off
        ] )
    ]
;;
