(* The TUI's volume GC presses: what each press sends, and when the next
   press may ask the server to reclaim. *)

module Gc = Masc_tui_volume_gc
module Answer = Masc.Keeper_volume_gc_answer

let verdict ?work ?build keeper_name kind outcome =
  { Answer.keeper_name; work_volume = work; build_volume = build; kind; outcome }
;;

let report ?(executed = false) ?(image_given = true) ?(foreign = []) keepers =
  { Answer.executed; image_given; foreign_volumes = foreign; keepers; unlisted_keepers = [] }
;;

let text_of report = Yojson.Safe.to_string (Answer.to_json report)

let mixed =
  report
    ~foreign:[ "unrelated-volume" ]
    [ verdict ~work:"masc-keeper-work-registered" "registered" Answer.Kept
        "kept (registered in this workspace)"
    ; verdict ~build:"masc-keeper-build-retired" "retired" Answer.Reclaim_candidate
        "reclaim candidate"
    ]
;;

let phase =
  Alcotest.testable
    (fun ppf -> function
       | Gc.Idle -> Format.pp_print_string ppf "Idle"
       | Gc.Reporting -> Format.pp_print_string ppf "Reporting"
       | Gc.Armed names -> Format.fprintf ppf "Armed [%s]" (String.concat "; " names)
       | Gc.Reclaiming -> Format.pp_print_string ppf "Reclaiming")
    ( = )
;;

let sent label expected t =
  match Gc.press t, expected with
  | Gc.Send request, Some execute ->
    Alcotest.(check bool) label execute (Gc.execute request)
  | Gc.Still_running, None -> ()
  | Gc.Send _, None -> Alcotest.failf "%s: a press sent a request" label
  | Gc.Still_running, Some _ -> Alcotest.failf "%s: a press sent nothing" label
;;

(* The second press sends the names the report showed, so the server cannot
   reclaim a Keeper the operator did not see. *)
let test_the_call_asks_with_the_base_image_and_names_what_it_reclaims () =
  let report = Gc.arguments Gc.Report_request in
  let reclaim = Gc.arguments (Gc.Reclaim_request [ "retired" ]) in
  List.iter
    (fun arguments ->
       Alcotest.(check string) "the claims image is the catalog's base"
         "base" (match List.assoc "image" arguments with `String name -> name | _ -> "not a string"))
    [ report; reclaim ];
  let execute arguments =
    match List.assoc "execute" arguments with
    | `Bool sent -> sent
    | _ -> Alcotest.fail "execute is a boolean"
  in
  Alcotest.(check bool) "a report does not execute" false (execute report);
  Alcotest.(check bool) "a reclaim executes" true (execute reclaim);
  Alcotest.(check bool) "a report names no keeper" false (List.mem_assoc "keepers" report);
  Alcotest.(check (list string)) "a reclaim names the keepers it carries"
    [ "retired" ]
    (match List.assoc "keepers" reclaim with
     | `List names ->
       List.map (function `String name -> name | _ -> Alcotest.fail "a keeper name is a string") names
     | _ -> Alcotest.fail "keepers is a list")
;;

let test_only_an_armed_press_reclaims () =
  sent "the first press only reports" (Some false) Gc.initial;
  sent "a press while a report runs sends nothing" None
    (Gc.sending Gc.initial Gc.Report_request);
  let armed = Gc.answered (Gc.answer_of_text ~is_error:false (text_of mixed)) in
  (match Gc.press armed with
   | Gc.Send (Gc.Reclaim_request names) ->
     Alcotest.(check (list string)) "the armed press reclaims what the report listed"
       [ "retired" ] names
   | Gc.Send Gc.Report_request | Gc.Still_running ->
     Alcotest.fail "an armed press did not reclaim");
  sent "a press while a reclaim runs sends nothing" None
    (Gc.sending armed (Gc.Reclaim_request [ "retired" ]));
  sent "a press after another key reports again" (Some false) (Gc.disarm armed)
;;

let test_only_a_report_with_candidates_arms () =
  let after label expected answer =
    Alcotest.check phase label expected (Gc.answered answer).Gc.phase
  in
  after "a report with a candidate arms it" (Gc.Armed [ "retired" ])
    (Gc.answer_of_text ~is_error:false (text_of mixed));
  after "an executed answer is not armed again" Gc.Idle
    (Gc.answer_of_text ~is_error:false (text_of { mixed with Answer.executed = true }));
  after "a report without a candidate arms nothing" Gc.Idle
    (Gc.answer_of_text ~is_error:false
       (text_of (report [ verdict "registered" Answer.Kept "kept (registered in this workspace)" ])));
  after "a refusal arms nothing" Gc.Idle
    (Gc.answer_of_text ~is_error:true "Apple Container is not available on this host");
  after "an unreadable answer arms nothing" Gc.Idle
    (Gc.answer_of_text ~is_error:false "{\"executed\":false}");
  Alcotest.check phase "a reclaim with no answer arms nothing" Gc.Idle
    (Gc.unanswered (Gc.Reclaim_request [ "retired" ]) "timed out").Gc.phase
;;

let test_disarm_takes_back_only_an_armed_press () =
  let armed = Gc.answered (Gc.answer_of_text ~is_error:false (text_of mixed)) in
  Alcotest.check phase "another key takes the arm back" Gc.Idle (Gc.disarm armed).Gc.phase;
  Alcotest.check phase "a report in flight stays in flight" Gc.Reporting
    (Gc.disarm (Gc.sending Gc.initial Gc.Report_request)).Gc.phase;
  Alcotest.check phase "a reclaim in flight stays in flight" Gc.Reclaiming
    (Gc.disarm (Gc.sending armed (Gc.Reclaim_request [ "retired" ]))).Gc.phase
;;

let test_an_answer_is_read_as_a_report_a_refusal_or_unreadable () =
  let kind = function
    | Gc.Report _ -> "report"
    | Gc.Refused _ -> "refused"
    | Gc.Unreadable _ -> "unreadable"
  in
  Alcotest.(check string) "a tool error is a refusal" "refused"
    (kind (Gc.answer_of_text ~is_error:true (text_of mixed)));
  Alcotest.(check string) "text that is not JSON is unreadable" "unreadable"
    (kind (Gc.answer_of_text ~is_error:false "not json"));
  Alcotest.(check string) "JSON the codec refuses is unreadable" "unreadable"
    (kind (Gc.answer_of_text ~is_error:false "{\"executed\":false}"));
  Alcotest.(check string) "a decoded answer is a report" "report"
    (kind (Gc.answer_of_text ~is_error:false (text_of mixed)))
;;

let () =
  Alcotest.run
    "tui_volume_gc"
    [ ( "volume gc"
      , [ Alcotest.test_case "the call asks with the base image and names what it reclaims" `Quick
            test_the_call_asks_with_the_base_image_and_names_what_it_reclaims
        ; Alcotest.test_case "only an armed press reclaims" `Quick
            test_only_an_armed_press_reclaims
        ; Alcotest.test_case "only a report with candidates arms" `Quick
            test_only_a_report_with_candidates_arms
        ; Alcotest.test_case "disarm takes back only an armed press" `Quick
            test_disarm_takes_back_only_an_armed_press
        ; Alcotest.test_case "an answer is read as a report, a refusal or unreadable" `Quick
            test_an_answer_is_read_as_a_report_a_refusal_or_unreadable
        ] )
    ]
;;
