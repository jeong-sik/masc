(* The lifecycle log line is the only durable record of a rejected boot: the
   sentence explaining the rejection goes to the HTTP response, which is a
   transient toast in the TUI. Three separate gates answer [Rejected], so a
   line that says only [outcome=rejected] cannot tell an operator which one
   fired — observed 2026-08-30 on "keeper lifecycle boot name=analyst
   actor=masc-tui outcome=rejected duration_ms=0", which was undiagnosable. *)

module P = Server_dashboard_http_keeper_api_lifecycle_post

let line ?(action = "boot") ?(name = "analyst") ?(actor = "masc-tui")
    ?(duration_ms = 0) outcome =
  snd (P.lifecycle_log_line ~action ~name ~actor ~duration_ms outcome)

(* Same testable as test_log_severity_outcome_level: a mismatch prints the
   severity names rather than two opaque constructors. *)
let level_t =
  Alcotest.testable
    (fun fmt l -> Format.pp_print_string fmt (Log.level_to_string l))
    ( = )

let level outcome =
  fst
    (P.lifecycle_log_line ~action:"boot" ~name:"analyst" ~actor:"masc-tui"
       ~duration_ms:0 outcome)

let check_level what expected outcome =
  Alcotest.check level_t what expected (level outcome)

let test_success_has_no_reason_field () =
  Alcotest.(check string)
    "an accepted boot reads exactly as before"
    "keeper lifecycle boot name=analyst actor=masc-tui outcome=ok \
     duration_ms=0"
    (line P.Succeeded);
  Alcotest.(check string)
    "already_live likewise carries nothing extra"
    "keeper lifecycle boot name=analyst actor=masc-tui outcome=already_live \
     duration_ms=0"
    (line P.Already_live)

let test_rejection_names_its_gate () =
  let paused_meta =
    line
      (P.Rejected
         "keeper is operator-paused; commit Resume_owner through the directive \
          endpoint")
  in
  let paused_lane =
    line
      (P.Rejected
         "keeper registry lane is paused; commit Resume_owner through the \
          directive endpoint")
  in
  Alcotest.(check bool)
    "the operator-paused gate is readable from the line" true
    (Astring.String.is_infix ~affix:"reason=keeper is operator-paused"
       paused_meta);
  Alcotest.(check bool)
    "the registry-lane gate is readable from the line" true
    (Astring.String.is_infix ~affix:"reason=keeper registry lane is paused"
       paused_lane);
  Alcotest.(check bool)
    "and the two gates do not read alike" false
    (String.equal paused_meta paused_lane)

let test_dispatch_error_text_stays_on_one_line () =
  let l = P.Rejected "boot failed:\nlane unavailable\r\nretry later" |> line in
  Alcotest.(check bool)
    "no newline survives into the record" false
    (String.exists (function '\n' | '\r' -> true | _ -> false) l);
  Alcotest.(check string)
    "the text is preserved with blanks in place of the breaks"
    "keeper lifecycle boot name=analyst actor=masc-tui outcome=rejected \
     duration_ms=0 reason=boot failed: lane unavailable  retry later" l

let test_persist_failure_carries_its_error () =
  Alcotest.(check bool)
    "a persist failure says what failed" true
    (Astring.String.is_infix ~affix:"reason=owner registry write refused"
       (line (P.Persist_failed "owner registry write refused")))

let test_severity_follows_the_outcome () =
  check_level "success is Info" Log.Info P.Succeeded;
  check_level "already live is Info" Log.Info P.Already_live;
  check_level "a rejection is Warn" Log.Warn (P.Rejected "paused");
  check_level "a missing dispatch is Warn" Log.Warn P.Dispatch_none;
  check_level "a persist failure is Warn" Log.Warn (P.Persist_failed "io")

let test_fields_stay_in_order () =
  Alcotest.(check string)
    "action, name, actor, outcome, duration, then reason last"
    "keeper lifecycle shutdown name=alder actor=dashboard \
     outcome=dispatch_none duration_ms=17"
    (line ~action:"shutdown" ~name:"alder" ~actor:"dashboard" ~duration_ms:17
       P.Dispatch_none)

let () =
  Alcotest.run "keeper_lifecycle_log_line"
    [
      ( "reason",
        [
          Alcotest.test_case "success carries no reason" `Quick
            test_success_has_no_reason_field;
          Alcotest.test_case "rejection names its gate" `Quick
            test_rejection_names_its_gate;
          Alcotest.test_case "free text stays on one line" `Quick
            test_dispatch_error_text_stays_on_one_line;
          Alcotest.test_case "persist failure carries its error" `Quick
            test_persist_failure_carries_its_error;
        ] );
      ( "shape",
        [
          Alcotest.test_case "severity follows the outcome" `Quick
            test_severity_follows_the_outcome;
          Alcotest.test_case "fields stay in order" `Quick
            test_fields_stay_in_order;
        ] );
    ]
