(* Runs scripts/review/approve-guard-selftest.sh, which drives
   scripts/review/approve-guard.sh against a fake gh (no network) through
   every refusal the guard exists for: short/long SHA, Draft, moved head,
   non-main base, merged PR, pending / failed / cancelled / empty check-runs,
   a Draft-time suite whose check-run ids outrank the Ready-time suite, queued
   workflow run, a cancelled twin run, empty body, duplicate approval, and a
   posted review that reads back wrong. *)

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let selftest () =
  let script =
    Filename.concat (source_root ()) "scripts/review/approve-guard-selftest.sh"
  in
  let rc = Sys.command (Printf.sprintf "bash %s" (Filename.quote script)) in
  Alcotest.(check int) "approve-guard self-test exit status" 0 rc

let () =
  Alcotest.run "review_approve_guard"
    [ ("selftest", [ Alcotest.test_case "all cases" `Quick selftest ]) ]
