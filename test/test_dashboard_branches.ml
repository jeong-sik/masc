module DB = Masc_mcp.Dashboard_branches

let check = Alcotest.check

let test_parse_branch_refs () =
  let refs =
    DB.parse_branch_refs "main\t0123456789abcdef\nfeature/a\tabcdef0123456789\n\nbad\n"
  in
  check
    Alcotest.(list (pair string string))
    "refs"
    [ "main", "0123456789abcdef"; "feature/a", "abcdef0123456789" ]
    refs
;;

let test_parse_ahead_behind () =
  check
    Alcotest.(option (pair int int))
    "ahead behind"
    (Some (2, 5))
    (DB.parse_ahead_behind "2\t5\n");
  check Alcotest.(option (pair int int)) "malformed" None (DB.parse_ahead_behind "x\t5\n")
;;

let test_status_of_counts () =
  check
    Alcotest.string
    "no upstream"
    "untracked"
    (DB.status_to_string (DB.status_of_counts ~has_upstream:false ~ahead:0 ~behind:0));
  check
    Alcotest.string
    "clean"
    "clean"
    (DB.status_to_string (DB.status_of_counts ~has_upstream:true ~ahead:0 ~behind:0));
  check
    Alcotest.string
    "ahead"
    "ahead"
    (DB.status_to_string (DB.status_of_counts ~has_upstream:true ~ahead:2 ~behind:0));
  check
    Alcotest.string
    "behind"
    "behind"
    (DB.status_to_string (DB.status_of_counts ~has_upstream:true ~ahead:0 ~behind:3));
  check
    Alcotest.string
    "diverged"
    "diverged"
    (DB.status_to_string (DB.status_of_counts ~has_upstream:true ~ahead:2 ~behind:3))
;;

let test_entry_to_json () =
  let json =
    DB.entry_to_json
      { DB.name = "feature/x"
      ; tag = Some "current"
      ; status = DB.Ahead
      ; ahead = 2
      ; behind = 0
      ; head = "abc123"
      ; keepers = [ "sangsu"; "younghee" ]
      }
  in
  let open Yojson.Safe.Util in
  check Alcotest.string "name" "feature/x" (json |> member "name" |> to_string);
  check Alcotest.string "status" "ahead" (json |> member "status" |> to_string);
  check Alcotest.int "ahead" 2 (json |> member "ahead" |> to_int);
  check
    Alcotest.(list string)
    "keepers"
    [ "sangsu"; "younghee" ]
    (json |> member "keepers" |> to_list |> List.map to_string)
;;

let () =
  Alcotest.run
    "dashboard_branches"
    [ ( "branches"
      , [ Alcotest.test_case "parse branch refs" `Quick test_parse_branch_refs
        ; Alcotest.test_case "parse ahead behind" `Quick test_parse_ahead_behind
        ; Alcotest.test_case "status of counts" `Quick test_status_of_counts
        ; Alcotest.test_case "entry json" `Quick test_entry_to_json
        ] )
    ]
;;
