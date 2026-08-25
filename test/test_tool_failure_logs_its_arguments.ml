(** A failed tool call records what it was asked for, not just which keys.

    [params] carries key names. That answers what the model reached for and
    not what it asked for, so a repository audit could see a gh call fail and
    not learn which slug it named — "the keeper invented an org" and "the
    keeper never ran gh" read the same afterwards (#23822).

    The values are redacted before they are written, and only on the failure
    path: a successful call still logs keys alone. *)

let module_path = "lib/keeper/keeper_hooks_agent_core.ml"

(* The format string is wrapped across source lines, so the literal is
   matched by substring rather than exactly. *)
let test_the_failure_line_carries_the_arguments () =
  let n = Ast_grep.count_string_literals ~module_path ~needle:"failed_params=" in
  if n < 1 then
    Alcotest.failf
      "the tool_call log line must carry the failed call's arguments; \
       failed_params appears %d time(s) in %s"
      n module_path
;;

(* Redaction is what makes it safe to write them. Without it this turns every
   failed call into a place credentials can land.

   The count is exact, not a lower bound. Two sites in this module redact the
   same tool input — the log line here and the durable row below — and a
   >= 1 check passes while either one loses its redaction. *)
let redaction_sites = 2

let test_the_arguments_are_redacted_first () =
  let n =
    Ast_grep.count_calls ~module_path
      ~callee:"Observability_redact.redact_json_value"
  in
  if n <> redaction_sites then
    Alcotest.failf
      "every site writing a tool input must redact it first; \
       redact_json_value is called %d time(s), expected %d"
      n redaction_sites
;;

let () =
  Alcotest.run "tool_failure_logs_its_arguments"
    [ ( "argv record"
      , [ Alcotest.test_case "the failure line carries the arguments" `Quick
            test_the_failure_line_carries_the_arguments
        ; Alcotest.test_case "the arguments are redacted first" `Quick
            test_the_arguments_are_redacted_first
        ] )
    ]
