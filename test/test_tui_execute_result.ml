(* An Execute result read against the output schema its descriptor declares.
   The fixture is the shape a live call returned (goo-yang-bong, 2026-09-22):
   the command's output sat inside an envelope whose cwd appeared three times,
   and the full calls drew all of it as JSON with the output buried in it. *)

open Alcotest
module R = Masc_tui_execute_result

let live_result =
  {|{"ok":true,"status":{"kind":"exit","code":0},"cwd":"/p/goo-yang-bong",
     "execution_location":{"cwd":"/p/goo-yang-bong","cwd_source":"explicit_cwd",
       "scope":"playground_root","repo_name":null},
     "output_completeness":"capture_only",
     "output":"9feab5497  fix(test): pass\n272394615  feat(keeper): trim",
     "typed":true,"execution_time_ms":808,"via":"microvm"}|}

let test_a_result_reads_into_its_parts () =
  match R.of_result live_result with
  | None -> fail "a result of the declared shape did not read"
  | Some result ->
      check bool "ok" true result.ok;
      check string "how it ended and how long it ran" "exit 0 \xc2\xb7 808 ms"
        (R.status_text result);
      check (option string) "what it printed, whole"
        (Some "9feab5497  fix(test): pass\n272394615  feat(keeper): trim")
        result.output;
      check (option string) "the rest on one line, nested members by path"
        (Some
           "cwd=/p/goo-yang-bong \xc2\xb7 execution_location.cwd=/p/goo-yang-bong \
            \xc2\xb7 execution_location.cwd_source=explicit_cwd \xc2\xb7 \
            execution_location.scope=playground_root \xc2\xb7 \
            execution_location.repo_name=null \xc2\xb7 \
            output_completeness=capture_only \xc2\xb7 typed=true \xc2\xb7 via=microvm")
        (R.rest_text result)

(* The exit report copies a failing command's stderr into [error] as well;
   drawn twice it would be the same paragraph twice. An [error] that says
   something else is a fact of its own and stays. *)
let test_a_failure_says_its_stderr_once () =
  let failing error =
    Printf.sprintf
      {|{"ok":false,"status":{"kind":"signal","signal":9},"typed":true,
         "execution_time_ms":1200,"stderr":"killed","error":%S}|}
      error
  in
  (match R.of_result (failing "killed") with
   | Some result ->
       check string "a signal says which" "signal 9 \xc2\xb7 1200 ms" (R.status_text result);
       check (option string) "stderr is its own field" (Some "killed") result.stderr;
       check (option string) "the copy under error is not repeated"
         (Some "typed=true") (R.rest_text result)
   | None -> fail "a failing result did not read");
  match R.of_result (failing "timed out after 30s") with
  | Some result ->
      check (option string) "a different error stays"
        (Some "typed=true \xc2\xb7 error=timed out after 30s") (R.rest_text result)
  | None -> fail "a failing result did not read"

(* What does not match the schema is not guessed at: the caller draws it as
   it arrived. *)
let test_what_is_not_the_declared_shape_does_not_read () =
  List.iter
    (fun (why, text) -> check bool why true (Option.is_none (R.of_result text)))
    [ ("not JSON", "exit 0")
    ; ("an array", "[1,2]")
    ; ("no typed member", {|{"ok":true,"status":{"kind":"exit","code":0},"execution_time_ms":1}|})
    ; ( "a status kind nobody writes",
        {|{"ok":true,"status":{"kind":"vanished","code":0},"typed":true,"execution_time_ms":1}|} )
    ; ( "a duration that is not an integer",
        {|{"ok":true,"status":{"kind":"exit","code":0},"typed":true,"execution_time_ms":"1"}|} )
    ]

let () =
  run "tui_execute_result"
    [ ( "execute result",
        [ test_case "a result reads into its parts" `Quick test_a_result_reads_into_its_parts
        ; test_case "a failure says its stderr once" `Quick test_a_failure_says_its_stderr_once
        ; test_case "what is not the declared shape does not read" `Quick
            test_what_is_not_the_declared_shape_does_not_read
        ] )
    ]
