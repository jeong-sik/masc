(** Tests for Validation module - Input security *)


(* ===== Agent_id Tests ===== *)

let test_agent_id_valid () =
  (* Valid agent IDs *)
  let cases = ["claude"; "gemini"; "codex"; "agent-1"; "my_agent"; "Agent123"] in
  List.iter (fun s ->
    match Validation.Id_shape.validate s with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Printf.sprintf "Expected valid agent_id '%s': %s" s e)
  ) cases

let test_agent_id_empty () =
  match Validation.Id_shape.validate "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Expected error for empty agent_id"

let test_agent_id_path_traversal () =
  let cases = ["../admin"; "..\\admin"; "agent/subdir"; "agent\\subdir"] in
  List.iter (fun s ->
    match Validation.Id_shape.validate s with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (Printf.sprintf "Expected error for path traversal '%s'" s)
  ) cases

let test_agent_id_too_long () =
  let long_name = String.make 65 'a' in
  match Validation.Id_shape.validate long_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Expected error for too long agent_id"

let test_agent_id_invalid_chars () =
  let cases = ["agent@host"; "agent!"; "agent#1"; "agent$money"] in
  List.iter (fun s ->
    match Validation.Id_shape.validate s with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (Printf.sprintf "Expected error for invalid chars '%s'" s)
  ) cases

(* A keeper name carries dots (edgar.a.poe). RFC-0393 made a keeper name its
   own id instead of an encoded string, so the dot reaches this validator
   directly and a rejection here stops that keeper from claiming its own task.
   Board widened to the same character set in #8633 and called its pattern "a
   strict superset of both"; this is the half that never followed. *)
let test_agent_id_allows_dots () =
  let cases = ["edgar.a.poe"; "a.b"; "keeper:edgar.a.poe"; "x.y-z_1"] in
  List.iter (fun s ->
    match Validation.Id_shape.validate s with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Printf.sprintf "Expected valid agent_id '%s': %s" s e)
  ) cases

(* Widening the character set must not reopen traversal: ".." is still refused,
   and the check that refuses it is only reachable now that dots parse. *)
let test_agent_id_dot_traversal_still_refused () =
  let cases = [".."; "../x"; "..foo"] in
  List.iter (fun s ->
    match Validation.Id_shape.validate s with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (Printf.sprintf "Expected error for '%s'" s)
  ) cases

(* SSOT: board delegates to this validator instead of carrying its own copy.
   The copy drifted twice (#8625 length, #8633 pattern), each time caught up by
   hand. Agreement is asserted here so a third drift is a test failure. *)
let test_board_agent_id_agrees_with_validation () =
  let cases =
    [ "edgar.a.poe"; "claude"; "keeper:edgar.a.poe"; "agent-1"
    ; ""; ".."; "../x"; "agent/subdir"; "agent@host"; String.make 65 'a' ]
  in
  List.iter (fun s ->
    let canonical = Result.is_ok (Validation.Id_shape.validate s) in
    let board = Result.is_ok (Board_types.Agent_id.of_string s) in
    if canonical <> board
    then
      Alcotest.fail
        (Printf.sprintf
           "board and Validation disagree on '%s': Validation=%b board=%b"
           s canonical board)
  ) cases

(* ===== Task_id Tests ===== *)

let test_task_id_valid () =
  let cases = ["task-001"; "PK-12345"; "task:subtask"; "my_task_123"] in
  List.iter (fun s ->
    match Validation.Task_id.validate s with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Printf.sprintf "Expected valid task_id '%s': %s" s e)
  ) cases

let test_task_id_empty () =
  match Validation.Task_id.validate "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Expected error for empty task_id"

let test_task_id_path_traversal () =
  let cases = ["../task"; "task/../../etc"] in
  List.iter (fun s ->
    match Validation.Task_id.validate s with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (Printf.sprintf "Expected error for path traversal '%s'" s)
  ) cases

(* ===== Safe_path Tests ===== *)

let test_safe_path_valid () =
  let cases = ["file.txt"; "dir/file.txt"; "a/b/c.ml"] in
  List.iter (fun s ->
    match Validation.Safe_path.validate_relative s with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Printf.sprintf "Expected valid path '%s': %s" s e)
  ) cases

let test_safe_path_absolute () =
  match Validation.Safe_path.validate_relative "/etc/passwd" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Expected error for absolute path"

let test_safe_path_traversal () =
  let cases = ["../secret"; "foo/../../../etc/passwd"; ".."] in
  List.iter (fun s ->
    match Validation.Safe_path.validate_relative s with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (Printf.sprintf "Expected error for path traversal '%s'" s)
  ) cases

let test_sanitize_filename () =
  Alcotest.(check string) "removes slashes"
    "etc_passwd" (Validation.Safe_path.sanitize_filename "etc/passwd");
  Alcotest.(check string) "removes backslashes"
    "etc_passwd" (Validation.Safe_path.sanitize_filename "etc\\passwd");
  Alcotest.(check string) "removes dotdot"
    "__secret" (Validation.Safe_path.sanitize_filename "../secret")

(* ===== Safe_float Tests ===== *)

let test_safe_float_normal () =
  let f = Validation.Safe_float.validate 3.14 ~name:"pi" in
  Alcotest.(check (float 0.001)) "normal float" 3.14 f

let test_safe_float_nan () =
  let f = Validation.Safe_float.validate Float.nan ~name:"nan_test" in
  Alcotest.(check (float 0.001)) "nan becomes 0" 0.0 f

let test_safe_float_infinity () =
  let f = Validation.Safe_float.validate Float.infinity ~name:"inf_test" in
  Alcotest.(check (float 0.001)) "infinity becomes 0" 0.0 f

let test_safe_float_clamp () =
  Alcotest.(check (float 0.001)) "clamp low" 0.0
    (Validation.Safe_float.clamp (-1.0) ~min:0.0 ~max:1.0);
  Alcotest.(check (float 0.001)) "clamp high" 1.0
    (Validation.Safe_float.clamp 2.0 ~min:0.0 ~max:1.0);
  Alcotest.(check (float 0.001)) "clamp middle" 0.5
    (Validation.Safe_float.clamp 0.5 ~min:0.0 ~max:1.0)

(* ===== Rejection Stats Tests ===== *)

let test_rejection_stats () =
  Validation.reset_rejection_stats ();
  let (count1, _) = Validation.get_rejection_stats () in
  Alcotest.(check int) "initial count" 0 count1;

  (* Trigger a rejection *)
  let _ = Validation.Id_shape.validate "" in
  let (count2, time2) = Validation.get_rejection_stats () in
  Alcotest.(check int) "after rejection" 1 count2;
  Alcotest.(check bool) "time updated" true (time2 > 0.0);

  (* Reset *)
  Validation.reset_rejection_stats ();
  let (count3, _) = Validation.get_rejection_stats () in
  Alcotest.(check int) "after reset" 0 count3

(* ===== Test Suite ===== *)

let tests = [
  (* Agent_id *)
  Alcotest.test_case "agent_id valid" `Quick test_agent_id_valid;
  Alcotest.test_case "agent_id empty" `Quick test_agent_id_empty;
  Alcotest.test_case "agent_id path traversal" `Quick test_agent_id_path_traversal;
  Alcotest.test_case "agent_id too long" `Quick test_agent_id_too_long;
  Alcotest.test_case "agent_id invalid chars" `Quick test_agent_id_invalid_chars;
  (* Task_id *)
  Alcotest.test_case "task_id valid" `Quick test_task_id_valid;
  Alcotest.test_case "task_id empty" `Quick test_task_id_empty;
  Alcotest.test_case "task_id path traversal" `Quick test_task_id_path_traversal;
  (* Safe_path *)
  Alcotest.test_case "safe_path valid" `Quick test_safe_path_valid;
  Alcotest.test_case "safe_path absolute" `Quick test_safe_path_absolute;
  Alcotest.test_case "safe_path traversal" `Quick test_safe_path_traversal;
  Alcotest.test_case "sanitize_filename" `Quick test_sanitize_filename;
  (* Safe_float *)
  Alcotest.test_case "safe_float normal" `Quick test_safe_float_normal;
  Alcotest.test_case "safe_float nan" `Quick test_safe_float_nan;
  Alcotest.test_case "safe_float infinity" `Quick test_safe_float_infinity;
  Alcotest.test_case "safe_float clamp" `Quick test_safe_float_clamp;
  Alcotest.test_case "agent_id allows dots" `Quick test_agent_id_allows_dots;
  Alcotest.test_case "agent_id still refuses dot traversal" `Quick
    test_agent_id_dot_traversal_still_refused;
  Alcotest.test_case "board agent_id agrees with Validation" `Quick
    test_board_agent_id_agrees_with_validation;
  (* Stats *)
  Alcotest.test_case "rejection stats" `Quick test_rejection_stats;
]

let () =
  Alcotest.run "Validation" [
    "Security", tests;
  ]
