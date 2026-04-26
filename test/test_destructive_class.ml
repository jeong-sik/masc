(* Tick 13: typed destructive classification.

   Core covenant: every row in Eval_gate.destructive_patterns must
   classify to exactly one destructive_class via the AST-shadow
   mapping.  If Eval_gate adds a new pattern and Worker_dev_tools
   does not, this test fails loudly — preventing silent coverage
   drift between the regex allowlist and the typed classifier. *)

open Alcotest

let classify = Masc_mcp.Worker_dev_tools.classify_destructive
let class_to_string = Masc_mcp.Worker_dev_tools.destructive_class_to_string

let class_name_of_cmd cmd =
  match classify cmd with
  | Some (cls, _) -> class_to_string cls
  | None -> "no_match"
;;

let test_all_patterns_classify () =
  let patterns = Masc_mcp.Eval_gate.destructive_patterns in
  List.iter
    (fun (pat, desc) ->
       match classify pat with
       | Some _ -> ()
       | None ->
         fail
           (Printf.sprintf
              "Eval_gate pattern %S (%s) has no destructive_class mapping"
              pat
              desc))
    patterns
;;

let test_longest_match_wins () =
  (* rm -rf should hit Recursive_delete via the "rm -rf" prefix, not
     "rm -r" — both map to Recursive_delete anyway but the first
     match in declaration order should be the longer one. *)
  match classify "rm -rf /tmp/foo" with
  | Some (_, sub) -> check string "matched substring" "rm -rf" sub
  | None -> fail "expected match"
;;

let test_case_insensitive () =
  check string "uppercase SQL" "sql_destructive" (class_name_of_cmd "DROP TABLE users")
;;

let test_no_match_for_benign () =
  check string "ls benign" "no_match" (class_name_of_cmd "ls -la")
;;

let test_class_names_stable () =
  let open Masc_mcp.Worker_dev_tools in
  check
    string
    "recursive_delete"
    "recursive_delete"
    (destructive_class_to_string Recursive_delete);
  check
    string
    "forced_git_mutation"
    "forced_git_mutation"
    (destructive_class_to_string Forced_git_mutation);
  check
    string
    "system_control"
    "system_control"
    (destructive_class_to_string System_control)
;;

let test_coverage_count () =
  (* Plan Phase 5 cites 19 destructive patterns. *)
  let patterns = Masc_mcp.Eval_gate.destructive_patterns in
  check int "19 destructive patterns" 19 (List.length patterns)
;;

let () =
  run
    "destructive_class"
    [ ( "covenant"
      , [ test_case "every eval_gate pattern classifies" `Quick test_all_patterns_classify
        ; test_case "19 patterns present" `Quick test_coverage_count
        ] )
    ; ( "matching"
      , [ test_case "longest substring wins" `Quick test_longest_match_wins
        ; test_case "case insensitive" `Quick test_case_insensitive
        ; test_case "benign command → no_match" `Quick test_no_match_for_benign
        ] )
    ; "wire", [ test_case "class names stable" `Quick test_class_names_stable ]
    ]
;;
