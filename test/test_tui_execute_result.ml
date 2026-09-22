(* An Execute result read for what a reader looks for first: how the command
   ended and what it printed. The fixture is the shape a live call returned
   (goo-yang-bong, 2026-09-22): the output sits in an envelope that also says
   where it ran, three times over, and none of that is read. *)

open Alcotest
module R = Masc_tui_execute_result

let live_result =
  {|{"ok":true,"status":{"kind":"exit","code":0},"cwd":"/p/goo-yang-bong",
     "execution_location":{"cwd":"/p/goo-yang-bong","cwd_source":"explicit_cwd",
       "scope":"playground_root","repo_name":null},
     "output_completeness":"capture_only",
     "output":"9feab5497  fix(test): pass\n272394615  feat(keeper): trim",
     "typed":true,"execution_time_ms":808,"via":"microvm"}|}

let digest = "9f3a12c4d5e6" ^ String.make 52 '0'

let stored_result =
  Printf.sprintf
    {|{"ok":true,"status":{"kind":"exit","code":0},"output_completeness":"complete",
       "output_artifact":{"_blob":{"sha256":%S,"bytes":48213,"mime":"text/plain","preview":"a"}},
       "stdout_artifact":{"_blob":{"sha256":%S,"bytes":48213,"mime":"text/plain","preview":"a"}},
       "typed":true,"execution_time_ms":2400}|}
    digest digest

let test_a_result_reads_into_its_parts () =
  match R.of_result live_result with
  | None -> fail "a result of the declared shape did not read"
  | Some result ->
      check bool "ok" true result.ok;
      check string "how it ended and how long it ran" "exit 0 \xc2\xb7 808 ms"
        (R.status_text result);
      check bool "what it printed, whole" true
        (match result.output with
         | Some (R.Printed "9feab5497  fix(test): pass\n272394615  feat(keeper): trim") -> true
         | Some (R.Printed _ | R.Stored _) | None -> false);
      check (option string) "no stderr on a command that worked" None result.stderr

(* Past the size a result carries inline, the output is an artifact; the
   reader is told where it went and how big it is, not given an empty
   output. *)
let test_a_stored_output_says_where_it_went () =
  match R.of_result stored_result with
  | None -> fail "a result whose output is an artifact did not read"
  | Some result -> (
      match result.output with
      | Some (R.Stored reference) ->
          check string "the short digest and the size"
            "artifact sha256:9f3a12c4d5e6\xe2\x80\xa6 \xc2\xb7 48213 bytes"
            (R.stored_text reference)
      | Some (R.Printed _) | None -> fail "the artifact was not read as the output")

let test_a_failure_says_its_stderr () =
  match
    R.of_result
      {|{"ok":false,"status":{"kind":"exit","code":2},"typed":true,
         "execution_time_ms":40,"output":"","stderr":"ls: nope: No such file",
         "error":"ls: nope: No such file"}|}
  with
  | Some result ->
      check bool "not ok" false result.ok;
      check string "the exit code" "exit 2 \xc2\xb7 40 ms" (R.status_text result);
      check (option string) "stderr" (Some "ls: nope: No such file") result.stderr
  | None -> fail "a failing result did not read"

(* A command stopped for time dies to a signal; the status says it was the
   limit, so a reader does not go looking for what else killed it. *)
let test_a_timeout_says_the_limit () =
  match
    R.of_result
      {|{"ok":false,"status":{"kind":"signal","signal":9},"typed":true,
         "timeout":{"limit_sec":30.0,"source":"default"},
         "execution_time_ms":30012,"output":""}|}
  with
  | Some result ->
      check string "the signal, the time and the limit"
        "signal 9 \xc2\xb7 30012 ms \xc2\xb7 timed out at 30 s" (R.status_text result)
  | None -> fail "a timed-out result did not read"

(* What does not match the shape the producer writes is not guessed at: the
   caller draws it as it arrived. *)
let test_what_is_not_the_declared_shape_does_not_read () =
  let ok_with extra =
    Printf.sprintf
      {|{"ok":true,"status":{"kind":"exit","code":0},"typed":true,"execution_time_ms":1%s}|}
      extra
  in
  List.iter
    (fun (why, text) -> check bool why true (Option.is_none (R.of_result text)))
    [ ("not JSON", "exit 0")
    ; ("an array", "[1,2]")
    ; ("no typed member", {|{"ok":true,"status":{"kind":"exit","code":0},"execution_time_ms":1}|})
    ; ( "a status kind nobody writes",
        {|{"ok":true,"status":{"kind":"vanished","code":0},"typed":true,"execution_time_ms":1}|} )
    ; ( "a duration that is not an integer",
        {|{"ok":true,"status":{"kind":"exit","code":0},"typed":true,"execution_time_ms":"1"}|} )
    ; ("an output that is not a string", ok_with {|,"output":3|})
    ; ("an artifact that is not a blob reference", ok_with {|,"output_artifact":"x"|})
    ; ( "an output both inline and stored",
        ok_with
          (Printf.sprintf
             {|,"output":"a","output_artifact":{"_blob":{"sha256":%S,"bytes":1,"mime":"text/plain","preview":"a"}}|}
             digest) )
    ; ("a stderr that is not a string", ok_with {|,"stderr":{}|})
    ; ("a timeout without its limit", ok_with {|,"timeout":{"source":"default"}|})
    ]

let () =
  run "tui_execute_result"
    [ ( "execute result",
        [ test_case "a result reads into its parts" `Quick test_a_result_reads_into_its_parts
        ; test_case "a stored output says where it went" `Quick
            test_a_stored_output_says_where_it_went
        ; test_case "a failure says its stderr" `Quick test_a_failure_says_its_stderr
        ; test_case "a timeout says the limit" `Quick test_a_timeout_says_the_limit
        ; test_case "what is not the declared shape does not read" `Quick
            test_what_is_not_the_declared_shape_does_not_read
        ] )
    ]
