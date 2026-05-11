(** Task_stage unit tests *)

open Alcotest

let check_stage msg expected actual =
  check string msg (Task_stage.to_string expected) (Task_stage.to_string actual)

let test_roundtrip () =
  List.iter (fun stage ->
    let s = Task_stage.to_string stage in
    match Task_stage.of_string s with
    | Ok decoded -> check_stage (Printf.sprintf "roundtrip %s" s) stage decoded
    | Error e -> fail e
  ) Task_stage.all

let test_of_string_invalid () =
  match Task_stage.of_string "invalid_stage" with
  | Error _ -> ()
  | Ok _ -> fail "expected error for invalid stage"

let test_index_order () =
  (* [all] must be in ascending canonical order under [compare].
     Sorting it should be a no-op. *)
  let sorted = List.sort Task_stage.compare Task_stage.all in
  check (list string)
    "canonical [all] is sorted"
    (List.map Task_stage.to_string sorted)
    (List.map Task_stage.to_string Task_stage.all);
  check int "5 stages" 5 (List.length Task_stage.all)

let test_forward_transition () =
  check bool "decompose → inspect" true
    (Task_stage.can_transition ~current:Decompose ~target:Inspect);
  check bool "decompose → implement" true
    (Task_stage.can_transition ~current:Decompose ~target:Implement);
  check bool "inspect → review (skip)" true
    (Task_stage.can_transition ~current:Inspect ~target:Review)

let test_same_stage () =
  check bool "decompose → decompose (idempotent)" true
    (Task_stage.can_transition ~current:Decompose ~target:Decompose);
  check bool "verify → verify" true
    (Task_stage.can_transition ~current:Verify ~target:Verify)

let test_backward_forbidden () =
  check bool "review → decompose" false
    (Task_stage.can_transition ~current:Review ~target:Decompose);
  check bool "implement → inspect" false
    (Task_stage.can_transition ~current:Implement ~target:Inspect);
  check bool "verify → implement" false
    (Task_stage.can_transition ~current:Verify ~target:Implement)

let test_validate_transition_error () =
  match Task_stage.validate_transition ~current:Review ~target:Decompose with
  | Error msg ->
    check bool "error mentions backward" true
      (String.length msg > 0)
  | Ok () -> fail "expected error for backward transition"

let test_yojson_roundtrip () =
  List.iter (fun stage ->
    let json = Task_stage.to_yojson stage in
    match Task_stage.of_yojson json with
    | Ok decoded -> check_stage "yojson roundtrip" stage decoded
    | Error e -> fail e
  ) Task_stage.all

let test_task_with_stage () =
  let task : Types_core.task = {
    id = "T-001"; title = "test"; description = "";
    goal_id = None;
    task_status = Todo; priority = 3; files = [];
    created_at = "2026-01-01T00:00:00Z";
    worktree = None;
    created_by = None;
    stage = Some Task_stage.Implement;
    contract = None; handoff_context = None; cycle_count = 0; do_not_reclaim_reason = None;
  } in
  let json = Types_core.task_to_yojson task in
  match Types_core.task_of_yojson json with
  | Ok decoded ->
    check (option string) "stage preserved" (Some "implement")
      (Option.map Task_stage.to_string decoded.stage)
  | Error e -> fail e

let test_task_without_stage () =
  let task : Types_core.task = {
    id = "T-002"; title = "no stage"; description = "";
    goal_id = None;
    task_status = Todo; priority = 3; files = [];
    created_at = "2026-01-01T00:00:00Z";
    worktree = None;
    created_by = None;
    stage = None;
    contract = None; handoff_context = None; cycle_count = 0; do_not_reclaim_reason = None;
  } in
  let json = Types_core.task_to_yojson task in
  match Types_core.task_of_yojson json with
  | Ok decoded ->
    check bool "stage is None" true (Option.is_none decoded.stage)
  | Error e -> fail e

let () =
  Eio_main.run @@ fun _env ->
  run "Task_stage" [
    "serialization", [
      "string roundtrip", `Quick, test_roundtrip;
      "invalid string", `Quick, test_of_string_invalid;
      "yojson roundtrip", `Quick, test_yojson_roundtrip;
    ];
    "ordering", [
      "index order", `Quick, test_index_order;
      "forward allowed", `Quick, test_forward_transition;
      "same stage idempotent", `Quick, test_same_stage;
      "backward forbidden", `Quick, test_backward_forbidden;
      "validate error message", `Quick, test_validate_transition_error;
    ];
    "task_integration", [
      "task with stage", `Quick, test_task_with_stage;
      "task without stage (backward compat)", `Quick, test_task_without_stage;
    ];
  ]
