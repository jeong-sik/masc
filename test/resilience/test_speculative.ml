(* Cycle 27 / Tier A11 — Resilience.Speculative tests. *)

module S = Resilience.Speculative
module R_outcome = Shared_types.Resilience_outcome

(* ─── budget_policy ───────────────────────────────────────────── *)

let test_default_budget () =
  let b = S.default_budget in
  assert (b.time_cap_ms = 30_000);
  assert (b.tokens_cap = None);
  assert (b.branches_max = 4)

(* ─── execute: no-branch / first-success / all-fail / cap ─────── *)

let test_execute_empty_branches () =
  let _outcome, selection =
    S.execute ~budget:S.default_budget []
  in
  assert (selection.winner_index = None);
  assert (selection.attempted = 0);
  assert (selection.errors = [])

let test_execute_first_branch_wins () =
  let branches : int S.branch list =
    [ (fun () -> Ok 42); (fun () -> Ok 99) ]
  in
  let outcome, selection = S.execute ~budget:S.default_budget branches in
  assert (selection.winner_index = Some 0);
  assert (selection.attempted = 1);
  assert (selection.errors = []);
  match R_outcome.value_opt outcome with
  | Some 42 -> ()
  | _ -> assert false

let test_execute_second_branch_wins_after_first_fails () =
  let branches : string S.branch list =
    [ (fun () -> Error "transport"); (fun () -> Ok "ok-from-2") ]
  in
  let outcome, selection = S.execute ~budget:S.default_budget branches in
  assert (selection.winner_index = Some 1);
  assert (selection.attempted = 2);
  assert (selection.errors = [ "transport" ]);
  match R_outcome.value_opt outcome with
  | Some "ok-from-2" -> ()
  | _ -> assert false

let test_execute_all_branches_fail () =
  let branches : int S.branch list =
    [
      (fun () -> Error "e1");
      (fun () -> Error "e2");
      (fun () -> Error "e3");
    ]
  in
  let outcome, selection = S.execute ~budget:S.default_budget branches in
  assert (selection.winner_index = None);
  assert (selection.attempted = 3);
  assert (selection.errors = [ "e1"; "e2"; "e3" ]);
  assert (R_outcome.is_graceful outcome)

let test_execute_branches_max_truncates () =
  let counter = ref 0 in
  let f i () =
    incr counter;
    Error (Printf.sprintf "fail-%d" i)
  in
  let branches : int S.branch list =
    [ f 0; f 1; f 2; f 3; f 4 ]
  in
  let budget = { S.default_budget with branches_max = 2 } in
  let _outcome, selection = S.execute ~budget branches in
  assert (selection.attempted = 2);
  assert (!counter = 2);
  assert (selection.errors = [ "fail-0"; "fail-1" ])

let test_execute_branches_max_zero () =
  let counter = ref 0 in
  let branches : int S.branch list =
    [
      (fun () ->
        incr counter;
        Ok 1);
    ]
  in
  let budget = { S.default_budget with branches_max = 0 } in
  let _outcome, selection = S.execute ~budget branches in
  assert (selection.attempted = 0);
  assert (!counter = 0);
  assert (selection.errors = [])

let test_execute_full_success_sets_outcome_class () =
  let branches : int S.branch list = [ (fun () -> Ok 7) ] in
  let outcome, _ = S.execute ~budget:S.default_budget branches in
  assert (R_outcome.is_full outcome)

let () =
  test_default_budget ();
  test_execute_empty_branches ();
  test_execute_first_branch_wins ();
  test_execute_second_branch_wins_after_first_fails ();
  test_execute_all_branches_fail ();
  test_execute_branches_max_truncates ();
  test_execute_branches_max_zero ();
  test_execute_full_success_sets_outcome_class ();
  print_endline "test_speculative: all assertions passed"
