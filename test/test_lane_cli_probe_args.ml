(** What [Masc_lane_cli_probe_args.parse_args] accepts and rejects.

    Every rejection is an [Error] the executable turns into usage plus exit
    2; nothing here raises. Each case below is a shape the old inline parser
    used to crash on ([--trials abc]) or silently misrun ([--trials 0]). *)

module Args = Masc_lane_cli_probe_args

let parse_ok argv =
  match Args.parse_args argv with
  | Ok args -> args
  | Error detail -> Alcotest.fail ("expected Ok, got Error: " ^ detail)
;;

let parse_err argv =
  match Args.parse_args argv with
  | Ok _ -> Alcotest.fail "expected Error, got Ok"
  | Error detail -> detail
;;

let full_args_parse () =
  let args = parse_ok [ "--lane"; "hitl"; "--runtime"; "r1"; "--trials"; "5" ] in
  Alcotest.(check string) "lane" "hitl" args.Args.lane;
  Alcotest.(check string) "runtime" "r1" args.Args.runtime;
  Alcotest.(check int) "trials" 5 args.Args.trials
;;

let trials_default_to_three () =
  let args = parse_ok [ "--lane"; "hitl"; "--runtime"; "r1" ] in
  Alcotest.(check int) "default trials" 3 args.Args.trials
;;

let non_numeric_trials_reject () =
  let detail = parse_err [ "--lane"; "hitl"; "--runtime"; "r1"; "--trials"; "abc" ] in
  Alcotest.(check string)
    "names --trials"
    "invalid --trials \"abc\": expected a positive integer"
    detail
;;

let non_positive_trials_reject () =
  ignore (parse_err [ "--trials"; "0" ]);
  ignore (parse_err [ "--trials"; "-2" ])
;;

let unknown_argument_rejects () =
  ignore (parse_err [ "--lane"; "hitl"; "--bogus"; "x" ])
;;

let () =
  Alcotest.run
    "lane_cli_probe_args"
    [ ( "parse_args"
      , [ Alcotest.test_case "full args parse" `Quick full_args_parse
        ; Alcotest.test_case "trials default to three" `Quick trials_default_to_three
        ; Alcotest.test_case "non-numeric trials reject" `Quick non_numeric_trials_reject
        ; Alcotest.test_case "non-positive trials reject" `Quick non_positive_trials_reject
        ; Alcotest.test_case "unknown argument rejects" `Quick unknown_argument_rejects
        ] )
    ]
;;
