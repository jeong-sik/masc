(* The position arithmetic both askers share (the keeper_code_query tool and
   the /api/v1/lsp/question route). Pinned at the SSOT so a change shows here
   once, not as two surfaces disagreeing about where a name sits. *)

let check = Alcotest.check
let str = Alcotest.string
let int = Alcotest.int

let test_columns_finds_every_start () =
  Alcotest.(check (list int))
    "every start, including overlaps" [ 4; 16 ]
    (Lsp_position.columns_of ~line:"let combine x = combine 1" ~symbol:"combine");
  Alcotest.(check (list int))
    "an empty symbol matches nowhere" []
    (Lsp_position.columns_of ~line:"let x = 1" ~symbol:"")

let test_column_of_picks_the_occurrence () =
  (match
     Lsp_position.column_of ~line:"let a = a + a" ~symbol:"a" ~occurrence:3
       ~line_number:7
   with
   | Ok column -> check int "third occurrence" 12 column
   | Error e -> Alcotest.fail e);
  (match
     Lsp_position.column_of ~line:"let a = a + a" ~symbol:"a" ~occurrence:4
       ~line_number:7
   with
   | Ok _ -> Alcotest.fail "occurrence past the end answered"
   | Error message ->
       check str "the error counts the occurrences"
         "\"a\" occurs 3 time(s) on line 7, so there is no occurrence 4"
         message);
  match
    Lsp_position.column_of ~line:"let a = 1" ~symbol:"zz" ~occurrence:1
      ~line_number:2
  with
  | Ok _ -> Alcotest.fail "a missing symbol answered"
  | Error message ->
      check str "the error quotes the line"
        "\"zz\" is not on line 2, which reads: let a = 1" message

let test_line_of_file_reads_the_file () =
  let path = Filename.temp_file "lsp-position" ".ml" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      let oc = open_out path in
      output_string oc "first\nsecond\n";
      close_out oc;
      (match Lsp_position.line_of_file ~path ~line_index:1 with
       | Ok line -> check str "the second line" "second" line
       | Error e -> Alcotest.fail e);
      match Lsp_position.line_of_file ~path ~line_index:9 with
      | Ok _ -> Alcotest.fail "a line past the end answered"
      | Error message ->
          check Alcotest.bool "the error says the line is past the end" true
            (String.ends_with ~suffix:"line 10 is past its end" message))

let () =
  Alcotest.run "lsp_position"
    [ ( "positions",
        [ Alcotest.test_case "columns finds every start" `Quick
            test_columns_finds_every_start;
          Alcotest.test_case "column_of picks the occurrence" `Quick
            test_column_of_picks_the_occurrence;
          Alcotest.test_case "line_of_file reads the file" `Quick
            test_line_of_file_reads_the_file;
        ] );
    ]
