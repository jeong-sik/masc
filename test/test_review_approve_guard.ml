(* Exercises source-review and release admission against fake GitHub responses.
   Covers exact heads, independent approvals, blocking reviews and full release
   evidence without network access. *)

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let selftest () =
  let script =
    Filename.concat (source_root ()) "scripts/review/test_source_review_policy.py"
  in
  let rc = Sys.command (Printf.sprintf "python3 %s" (Filename.quote script)) in
  Alcotest.(check int) "approve-guard self-test exit status" 0 rc

let () =
  Alcotest.run "review_approve_guard"
    [ ("selftest", [ Alcotest.test_case "all cases" `Quick selftest ]) ]
