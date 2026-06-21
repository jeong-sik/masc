(** Structural guard for keeper dashboard per-row failure isolation.

    [keepers_dashboard_json] builds rows in [Eio.Fiber.all]. A row-level
    exception must not cancel the whole dashboard response; it should log the
    worker failure and emit a degraded row when keeper meta can still be read.

    This is source-structural because the failure can come from many dashboard
    sub-readers, and mocking each reader would require widening private helper
    APIs. *)

open Alcotest

let target_file = "lib/dashboard/dashboard_http_keeper.ml"

let load_source rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  if not (Sys.file_exists path)
  then failwith (Printf.sprintf "source file not found: %s" path)
  else (
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> In_channel.input_all ic))

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0
    then true
    else if idx + needle_len > haystack_len
    then false
    else if String.sub haystack idx needle_len = needle
    then true
    else loop (idx + 1)
  in
  loop 0

let check_contains label src needle =
  check bool label true (contains ~needle src)

let test_worker_exception_falls_back_to_degraded_row () =
  let src = load_source target_file in
  check_contains
    "degraded row helper exists"
    src
    "let degraded_keeper_dashboard_row";
  check_contains
    "per-worker row variable protects Fiber.all"
    src
    "let row =\n      try";
  check_contains
    "cancellation still propagates"
    src
    "| Eio.Cancel.Cancelled _ as exn -> raise exn";
  check_contains
    "worker exception logs"
    src
    "keeper dashboard worker error (%s): %s";
  check_contains
    "fallback reason is surfaced"
    src
    "keeper_dashboard_worker_exception";
  check_contains
    "FD-shaped exception reaches pressure guard"
    src
    "Keeper_fd_pressure.note_exception ~site:\"keeper_dashboard.worker\" exn";
  check_contains
    "row result is assigned after guarded build"
    src
    "results.(idx) <- row"

let test_degraded_row_shape_keeps_dashboard_contract () =
  let src = load_source target_file in
  check_contains "degraded status field" src "(\"status\", `String \"degraded\")";
  check_contains "degraded diagnostic field" src "(\"diagnostic\", diagnostic)";
  check_contains "runtime trust fallback field" src "(\"runtime_trust\", runtime_trust)";
  check_contains "agent field remains present" src "(\"agent\", `Null)";
  check_contains "runtime identity field remains present" src "(\"runtime_id\", runtime_id_json)"

let test_checkpoint_context_max_uses_runtime_budget () =
  let src = load_source target_file in
  check_contains
    "checkpoint fallback resolves runtime context max"
    src
    "Keeper_turn_runtime_budget.resolved_max_context_for_turn";
  check bool "summary fallback does not hardcode zero context max" false
    (contains ~needle:"let primary_max_context = 0 in" src)

let () =
  run
    "dashboard_keeper_worker_degrade_source"
    [ ( "worker_failure"
      , [ test_case
            "worker exception falls back to degraded row"
            `Quick
            test_worker_exception_falls_back_to_degraded_row
        ; test_case
            "degraded row keeps dashboard contract"
            `Quick
            test_degraded_row_shape_keeps_dashboard_contract
        ; test_case
            "checkpoint context max uses runtime budget"
            `Quick
            test_checkpoint_context_max_uses_runtime_budget
        ] )
    ]
