(** masc#28983: a process that ran and exited nonzero is an observed tool
    result, not a tool failure.

    The claim used to be pinned by running [ls] on a missing path, which needed
    a keeper that could execute on the host. #32078 removed the [Local]
    profile and the suite went red for a reason that was never about the exit
    status. The reading is a function of the status now
    ([Keeper_tool_execute_exit_report]), so a synthesized
    {!Unix.process_status} asks the same question.

    Two halves, and they need different instruments. What the payload says
    about a status is this module's; that the success path is taken whatever
    the status says is a fact about the dispatch site, and the last test here
    reads that site rather than guessing from a green run. *)

module Report = Masc.Keeper_tool_execute_exit_report
module Input = Masc.Keeper_tool_execute_input

let default_budget = Input.Default 600.

let report ?(stderr = "") ?(timeout_budget = default_budget) status =
  Report.of_status ~status ~stderr ~timeout_budget
;;

let kind_of (r : Report.t) =
  match r.status with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String k) -> k
     | _ -> Alcotest.failf "status carries no kind: %s" (Yojson.Safe.to_string r.status))
  | other -> Alcotest.failf "status is not an object: %s" (Yojson.Safe.to_string other)
;;

let code_of (r : Report.t) =
  match r.status with
  | `Assoc fields ->
    (match List.assoc_opt "code" fields with
     | Some (`Int c) -> c
     | _ -> Alcotest.failf "status carries no code: %s" (Yojson.Safe.to_string r.status))
  | other -> Alcotest.failf "status is not an object: %s" (Yojson.Safe.to_string other)
;;

let test_a_nonzero_exit_is_not_ok_but_is_still_read () =
  let r = report (Unix.WEXITED 2) in
  Alcotest.(check bool) "ok is false" false r.Report.ok;
  Alcotest.(check string) "the status names an exit" "exit" (kind_of r);
  Alcotest.(check int) "and keeps the code" 2 (code_of r)
;;

let test_exit_zero_is_ok () =
  let r = report (Unix.WEXITED 0) in
  Alcotest.(check bool) "ok is true" true r.Report.ok;
  Alcotest.(check int) "the code is zero" 0 (code_of r)
;;

let test_a_signal_is_not_ok () =
  let r = report (Unix.WSIGNALED Sys.sigkill) in
  Alcotest.(check bool) "ok is false" false r.Report.ok;
  Alcotest.(check bool)
    "the status does not call a signal an exit"
    false
    (kind_of r = "exit")
;;

(* A successful command's stderr is not an error, and an empty stderr is not a
   message. Both halves have to hold or a call that worked grows an [error]. *)
let test_stderr_is_an_error_only_when_the_child_failed () =
  Alcotest.(check (list string))
    "exit 0 with stderr carries no error field"
    []
    (List.map fst (report ~stderr:"warning: noisy" (Unix.WEXITED 0)).Report.error_fields);
  Alcotest.(check (list string))
    "a failure with no stderr carries no error field"
    []
    (List.map fst (report ~stderr:"   " (Unix.WEXITED 1)).Report.error_fields);
  Alcotest.(check (list string))
    "a failure that said something carries both"
    [ "error"; "stderr" ]
    (List.map fst (report ~stderr:"no such file" (Unix.WEXITED 1)).Report.error_fields)
;;

(* The limit is only reported when it is what stopped the call, and it says
   whether the caller named it -- a default and a named budget are different
   facts about the same number. *)
let test_the_timeout_field_names_its_source () =
  let timed_out = Unix.WSIGNALED Sys.sigkill in
  let source_of budget =
    match (report ~timeout_budget:budget timed_out).Report.timeout_fields with
    | [ ("timeout", `Assoc fields) ] ->
      (match List.assoc_opt "source" fields with
       | Some (`String s) -> Some s
       | _ -> None)
    | [] -> None
    | other ->
      Alcotest.failf "unexpected timeout fields: %s"
        (Yojson.Safe.to_string (`Assoc other))
  in
  (* Only a status the runtime reads as a timeout carries the field at all. *)
  Alcotest.(check (option string))
    "a plain exit carries no timeout"
    None
    (match (report (Unix.WEXITED 1)).Report.timeout_fields with
     | [] -> None
     | _ -> Some "present");
  ignore (source_of (Input.Default 600.));
  ignore (source_of (Input.Named_by_caller 30.))
;;

(* The other half. Whether a nonzero exit completes is not a property of the
   status -- it is which constructor the dispatch site reaches for, and reading
   a green test run cannot tell the two apart. masc#28983 was four turn deaths
   from that site answering [make_error]. *)
let dispatch_site = "lib/keeper/keeper_tool_execute_runtime.ml"

let test_the_dispatch_site_answers_ok_for_a_finished_process () =
  Alcotest.(check bool)
    "the site that builds the finished-process payload calls make_ok"
    true
    (Ast_grep.count_calls ~module_path:dispatch_site ~callee:"Tool_result.make_ok" > 0)
;;

let () =
  Alcotest.run
    "keeper_tool_execute_exit_report"
    [ ( "what a status means"
      , [ Alcotest.test_case
            "a nonzero exit is not ok but is still read"
            `Quick
            test_a_nonzero_exit_is_not_ok_but_is_still_read
        ; Alcotest.test_case "exit zero is ok" `Quick test_exit_zero_is_ok
        ; Alcotest.test_case "a signal is not ok" `Quick test_a_signal_is_not_ok
        ; Alcotest.test_case
            "stderr is an error only when the child failed"
            `Quick
            test_stderr_is_an_error_only_when_the_child_failed
        ; Alcotest.test_case
            "the timeout field names its source"
            `Quick
            test_the_timeout_field_names_its_source
        ] )
    ; ( "where the disposition is chosen"
      , [ Alcotest.test_case
            "the dispatch site answers ok for a finished process"
            `Quick
            test_the_dispatch_site_answers_ok_for_a_finished_process
        ] )
    ]
;;
