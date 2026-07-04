(** Structural guard for keeper dashboard per-row failure isolation.

    [keepers_dashboard_json] builds rows in [Eio.Fiber.all]. A row-level
    exception must not cancel the whole dashboard response; it should log the
    worker failure and emit a degraded row when keeper meta can still be read.

    This is source-structural because the failure can come from many dashboard
    sub-readers, and mocking each reader would require widening private helper
    APIs. *)

open Alcotest

let target_file = "lib/dashboard/dashboard_http_keeper.ml"
let status_detail_file = "lib/keeper/keeper_status_detail.ml"
let context_runtime_file = "lib/keeper/keeper_context_runtime.ml"
let heartbeat_snapshot_file = "lib/keeper/keeper_heartbeat_snapshot.ml"

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

let test_context_max_fallback_uses_pure_runtime_budget () =
  let src = load_source target_file in
  check_contains
    "dashboard context max resolves runtime context budget"
    src
    "Keeper_context_runtime.resolve_max_context_resolution_of_meta m";
  check_contains
    "metrics zero context max falls back to runtime budget"
    src
    "if raw_context_max > 0 then raw_context_max else primary_max_context";
  check_contains
    "missing metrics ratio is recomputed from tokens and runtime budget"
    src
    "float_of_int context_tokens /. float_of_int context_max";
  check bool "summary fallback does not hardcode zero context max" false
    (contains ~needle:"let primary_max_context = 0 in" src)
  ; check bool "dashboard read path avoids turn resolver side effects" false
      (contains ~needle:"Keeper_turn_runtime_budget.resolved_max_context_for_turn" src)

let test_dashboard_row_context_budget_reports_runtime_source () =
  let src = load_source target_file in
  check_contains
    "dashboard row keeps max context resolution"
    src
    "let max_context_resolution =";
  check_contains
    "dashboard row context_budget is emitted"
    src
    "(\"context_budget\", context_budget)";
  check_contains
    "dashboard row context_budget includes runtime id"
    src
    "~runtime_id:(Keeper_meta_contract.runtime_id_of_meta m)";
  check_contains
    "dashboard row context_budget uses shared JSON SSOT"
    src
    "Keeper_context_runtime.context_budget_json_of_resolution"

let test_status_detail_context_budget_reports_runtime_source () =
  let src = load_source status_detail_file in
  check_contains
    "status detail resolves meta-aware context budget"
    src
    "Keeper_context_runtime.resolve_max_context_resolution_of_meta m";
  check_contains
    "status detail context budget includes runtime id"
    src
    "~runtime_id:(runtime_id_of_meta m)";
  check_contains
    "status detail context_budget uses shared JSON SSOT"
    src
    "Keeper_context_runtime.context_budget_json_of_resolution"

let test_context_budget_json_schema_lives_in_context_runtime () =
  let src = load_source context_runtime_file in
  check_contains
    "shared context budget JSON helper exists"
    src
    "let context_budget_json_of_resolution";
  check_contains "shared helper emits runtime id" src "\"runtime_id\"";
  check_contains
    "shared helper emits provider context window"
    src
    "\"provider_context_window\"";
  check_contains "shared helper emits budget source" src "\"budget_source\"";
  check_contains
    "shared helper emits requested override"
    src
    "\"requested_override\"";
  check_contains "shared helper emits primary budget" src "\"primary_budget\"";
  check_contains "shared helper emits runtime budget" src "\"runtime_budget\"";
  check_contains "shared helper emits turn budget" src "\"turn_budget\"";
  check_contains "shared helper emits effective budget" src "\"effective_budget\""

let test_heartbeat_snapshot_uses_runtime_effective_budget () =
  let src = load_source heartbeat_snapshot_file in
  check_contains
    "heartbeat snapshot resolves runtime id from meta"
    src
    "Keeper_meta_contract.runtime_id_of_meta meta_current";
  check_contains
    "heartbeat snapshot uses context resolver"
    src
    "Keeper_context_runtime.resolve_max_context_resolution";
  check_contains
    "heartbeat snapshot passes effective budget to checkpoint load"
    src
    "resolution.effective_budget";
  check bool "heartbeat snapshot avoids global default direct budget" false
    (contains ~needle:"Runtime.default_max_context ()" src)

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
            "context max fallback uses pure runtime budget"
            `Quick
            test_context_max_fallback_uses_pure_runtime_budget
        ; test_case
            "dashboard row context budget reports runtime source"
            `Quick
            test_dashboard_row_context_budget_reports_runtime_source
        ; test_case
            "status detail context budget reports runtime source"
            `Quick
            test_status_detail_context_budget_reports_runtime_source
        ; test_case
            "context budget JSON schema lives in context runtime"
            `Quick
            test_context_budget_json_schema_lives_in_context_runtime
        ; test_case
            "heartbeat snapshot uses runtime effective budget"
            `Quick
            test_heartbeat_snapshot_uses_runtime_effective_budget
        ] )
    ]
