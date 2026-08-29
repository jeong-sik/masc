open Alcotest

let test_references () =
  check string "Board post" "masc://board/post-42"
    (Masc_tui_link.reference Board_post "post-42");
  check string "goal path and escaped id" "masc://planning/goal%2Fone%20two"
    (Masc_tui_link.reference Goal "goal/one two");
  check string "task opens Overview namespace" "masc://overview/tasks/task-7"
    (Masc_tui_link.reference Task "task-7")

let test_osc52 () =
  let reference = "masc://fusion/run-9" in
  let expected = "\027]52;c;" ^ Base64.encode_string reference ^ "\007" in
  check string "OSC 52 clipboard sequence" expected
    (Masc_tui_link.osc52_copy reference)

(* What [reference] wrote, [parse] reads back -- including an id that needed
   escaping. A round trip is the property: the screens print these and follow
   them, so a pair that disagreed would send an operator somewhere else. *)
let test_round_trip () =
  List.iter
    (fun (kind, id) ->
      let written = Masc_tui_link.reference kind id in
      match Masc_tui_link.parse written with
      | Some (back_kind, back_id) ->
        check bool ("kind survives: " ^ written) true (back_kind = kind);
        check string ("id survives: " ^ written) id back_id
      | None -> failf "parse refused what reference wrote: %s" written)
    [ (Masc_tui_link.Board_post, "post-42")
    ; (Masc_tui_link.Goal, "goal/one two")
    ; (Masc_tui_link.Task, "task-7")
    ; (Masc_tui_link.Schedule, "sch-1")
    ; (Masc_tui_link.Fusion_run, "run-9")
    ; (Masc_tui_link.Keeper, "echo")
    ]

(* Anything else is refused. A reference that cannot be read back is not one
   this program wrote, and following a guess would go nowhere real. *)
let test_parse_refuses_what_it_did_not_write () =
  List.iter
    (fun text ->
      check bool ("refused: " ^ text) true
        (Option.is_none (Masc_tui_link.parse text)))
    [ "masc://unknown/thing"      (* a path this build has no surface for *)
    ; "masc://board/"             (* no identifier *)
    ; "masc://board"              (* no segment at all *)
    ; "https://example.invalid/x" (* not this scheme *)
    ; "masc://board/bad%zz"       (* an escape reference never emits *)
    ; "masc://board/trailing%"    (* a percent with nothing after it *)
    ]

(* Scanning a body takes only what this program could have written, in order,
   without repeats. A post that spells an id in prose is not linked to it. *)
let test_scan_reads_only_real_references () =
  let body =
    "see masc://overview/tasks/task-7 and masc://planning/goal-2\n\
     again masc://overview/tasks/task-7 (a repeat)\n\
     task-99 is written out but never linked\n\
     masc://nowhere/x is not a surface"
  in
  check
    (list (pair string string))
    "only the two real references, once each, in order"
    [ ("task", "task-7"); ("goal", "goal-2") ]
    (Masc_tui_link.scan body
     |> List.map (fun (kind, id) -> (Masc_tui_link.kind_label kind, id)));
  check (list (pair string string)) "a body with none answers empty" []
    (Masc_tui_link.scan "no references here, just task-1 in prose"
     |> List.map (fun (kind, id) -> (Masc_tui_link.kind_label kind, id)))

let () =
  run "tui_link"
    [ ( "reference"
      , [ test_case "canonical paths" `Quick test_references
        ; test_case "OSC 52" `Quick test_osc52
        ] )
    ; ( "parse"
      , [ test_case "round trip" `Quick test_round_trip
        ; test_case "refuses what it did not write" `Quick
            test_parse_refuses_what_it_did_not_write
        ; test_case "scan reads only real references" `Quick
            test_scan_reads_only_real_references
        ] )
    ]
