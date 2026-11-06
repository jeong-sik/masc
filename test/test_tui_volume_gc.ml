(* The TUI's reading of a masc_sandbox_volume_gc answer: what the first press
   shows, and when a second press may ask the server to reclaim. *)

module Gc = Masc_tui_volume_gc
module Answer = Masc.Keeper_volume_gc_answer

let verdict ?work ?build keeper_name kind outcome =
  { Answer.keeper_name; work_volume = work; build_volume = build; kind; outcome }
;;

let report ?(executed = false) ?(image_given = true) ?(foreign = []) keepers =
  { Answer.executed; image_given; foreign_volumes = foreign; keepers }
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

let test_the_call_asks_with_the_base_image () =
  let image = List.assoc "image" (Gc.arguments ~execute:false) in
  Alcotest.(check string) "the claims image is the catalog's base"
    "base" (match image with `String name -> name | _ -> "not a string");
  List.iter
    (fun execute ->
       match List.assoc "execute" (Gc.arguments ~execute) with
       | `Bool sent -> Alcotest.(check bool) "execute is sent as asked" execute sent
       | _ -> Alcotest.fail "execute is a boolean")
    [ false; true ]
;;

let test_only_a_report_with_candidates_can_be_confirmed () =
  let reclaimable label expected answer =
    Alcotest.(check (option (list string))) label expected (Gc.reclaimable answer)
  in
  reclaimable "a report with a candidate names it" (Some [ "retired" ])
    (Gc.answer_of_text ~is_error:false (text_of mixed));
  reclaimable "an executed answer is not confirmed again" None
    (Gc.answer_of_text ~is_error:false (text_of { mixed with Answer.executed = true }));
  reclaimable "a report without a candidate has nothing to confirm" None
    (Gc.answer_of_text ~is_error:false
       (text_of (report [ verdict "registered" Answer.Kept "kept (registered in this workspace)" ])));
  reclaimable "a refusal has nothing to confirm" None
    (Gc.answer_of_text ~is_error:true "Apple Container is not available on this host");
  reclaimable "an unreadable answer has nothing to confirm" None
    (Gc.answer_of_text ~is_error:false "{\"executed\":false}")
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
      , [ Alcotest.test_case "the call asks with the base image" `Quick
            test_the_call_asks_with_the_base_image
        ; Alcotest.test_case "only a report with candidates can be confirmed" `Quick
            test_only_a_report_with_candidates_can_be_confirmed
        ; Alcotest.test_case "an answer is read as a report, a refusal or unreadable" `Quick
            test_an_answer_is_read_as_a_report_a_refusal_or_unreadable
        ] )
    ]
;;
