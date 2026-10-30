(* The /api/v1/git/log row format, pinned at the parser. *)

module W = Server_routes_http_routes_workspace.For_testing_log

let check_json = Alcotest.(check string)

let row line =
  match W.git_log_row_of_line line with
  | Some json -> Yojson.Safe.to_string json
  | None -> "none"

let test_a_row_splits_on_the_first_three_tabs () =
  check_json "plain row"
    {|{"hash":"abc1234","timestamp_ms":1787000000000,"author":"alpha","subject":"fix: a thing"}|}
    (row "abc1234\t1787000000\talpha\tfix: a thing");
  check_json "a subject keeps its own tabs"
    {|{"hash":"abc1234","timestamp_ms":1787000000000,"author":"alpha","subject":"a\tb"}|}
    (row "abc1234\t1787000000\talpha\ta\tb")

let test_a_malformed_row_is_dropped () =
  check_json "three fields is not a row" "none" (row "abc\t1787000000\talpha");
  check_json "empty line is not a row" "none" (row "");
  check_json "a non-epoch second field is not a row" "none"
    (row "abc1234\t2026-08-25\talpha\tfix: a thing")

let () =
  Alcotest.run "workspace-git-log"
    [ ( "rows"
      , [ Alcotest.test_case "a row splits on the first three tabs" `Quick
            test_a_row_splits_on_the_first_three_tabs
        ; Alcotest.test_case "a malformed row is dropped" `Quick
            test_a_malformed_row_is_dropped
        ] )
    ]
