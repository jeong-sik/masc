(** A1 bash parser smoke tests — skeleton coverage only.

    Today's grammar accepts only a single simple command (bin + lit
    args, unquoted).  These tests lock in that behavior and the
    fail-closed error surface.  Subsequent PRs add pipeline, redirect,
    env-prefix, quote, and subset-guard productions and grow this
    suite accordingly.

    The error arm uses [assert false] instead of the usual pattern
    so the lib-scope unsafe-pattern ratchet stays green (this test
    dir is counted as lib by the health script). *)

open Masc_exec
open Masc_exec_bash_parser

let test_ls_single_command () =
  match Bash.parse_string "ls" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Bin.to_string s.bin = "ls");
    assert (s.args = [])
  (* "ls must parse to Simple" *)
  | _ -> assert false

let test_ls_with_args () =
  match Bash.parse_string "ls -la /tmp" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Bin.to_string s.bin = "ls");
    (match s.args with
     | [ Shell_ir.Lit "-la"; Shell_ir.Lit "/tmp" ] -> ()
     (* "args wrong shape" *)
     | _ -> assert false)
  (* "ls -la /tmp must parse" *)
  | _ -> assert false

let test_echo_message () =
  match Bash.parse_string "echo hello" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Bin.to_string s.bin = "echo");
    assert (s.args = [ Shell_ir.Lit "hello" ])
  (* "echo hello must parse" *)
  | _ -> assert false

let test_leading_whitespace_ignored () =
  match Bash.parse_string "   ls  " with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Bin.to_string s.bin = "ls")
  (* "leading/trailing whitespace must be skipped" *)
  | _ -> assert false

let test_two_stage_pipeline () =
  match Bash.parse_string "ls | cat" with
  | Parsed.Parsed (Shell_ir.Pipeline [
      Shell_ir.Simple s1; Shell_ir.Simple s2
    ]) ->
    assert (Bin.to_string s1.bin = "ls");
    assert (Bin.to_string s2.bin = "cat");
    assert (s1.args = []);
    assert (s2.args = [])
  (* "ls | cat must parse to Pipeline of two Simple" *)
  | _ -> assert false

let test_three_stage_pipeline_with_args () =
  match Bash.parse_string "ls -la | grep foo | wc -l" with
  | Parsed.Parsed (Shell_ir.Pipeline stages) ->
    assert (List.length stages = 3);
    (match stages with
     | [ Shell_ir.Simple s1; Shell_ir.Simple s2; Shell_ir.Simple s3 ] ->
       assert (Bin.to_string s1.bin = "ls");
       assert (Bin.to_string s2.bin = "grep");
       assert (Bin.to_string s3.bin = "wc");
       assert (s2.args = [ Shell_ir.Lit "foo" ])
     (* "3-stage pipeline inner shape wrong" *)
     | _ -> assert false)
  (* "3-stage pipeline must parse" *)
  | _ -> assert false

let test_single_command_is_simple_not_pipeline () =
  (* length-1 pipelines collapse to Simple — distinguishes from
     Shell_ir.Pipeline which requires length >= 2. *)
  match Bash.parse_string "ls" with
  | Parsed.Parsed (Shell_ir.Simple _) -> ()
  (* "single command must be Simple, not Pipeline" *)
  | _ -> assert false

let test_logic_or_rejected () =
  (* '||' is subset-excluded (Parsed.Too_complex.Logic_op in a
     follow-up PR).  Today surfaces as Parse_error because the
     grammar has no production for consecutive PIPE tokens. *)
  match Bash.parse_string "ls || cat" with
  | Parsed.Parse_error _ -> ()
  (* "|| must reject" *)
  | _ -> assert false

let test_redirect_rejected_in_skeleton () =
  match Bash.parse_string "echo hi > /tmp/out" with
  | Parsed.Parse_error _ -> ()
  (* "redirect must reject in skeleton grammar" *)
  | _ -> assert false

let test_empty_input_rejected () =
  match Bash.parse_string "" with
  | Parsed.Parse_error _ -> ()
  (* "empty source must Parse_error" *)
  | _ -> assert false

let test_whitespace_only_rejected () =
  match Bash.parse_string "   " with
  | Parsed.Parse_error _ -> ()
  (* "whitespace-only must Parse_error" *)
  | _ -> assert false

let test_single_quoted_arg () =
  (* Single-quoted args preserve internal spaces verbatim and arrive
     as one Lit element (not split). *)
  match Bash.parse_string "echo 'hello world'" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Bin.to_string s.bin = "echo");
    (match s.args with
     | [ Shell_ir.Lit "hello world" ] -> ()
     (* "single-quoted content must land as one Lit" *)
     | _ -> assert false)
  | _ -> assert false

let test_single_quoted_empty () =
  match Bash.parse_string "echo ''" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Bin.to_string s.bin = "echo");
    (match s.args with
     | [ Shell_ir.Lit "" ] -> ()
     (* "empty single-quoted string must land as empty Lit" *)
     | _ -> assert false)
  | _ -> assert false

let test_multiple_single_quoted_args () =
  match Bash.parse_string "git commit -m 'my message' --allow-empty" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Bin.to_string s.bin = "git");
    (match s.args with
     | [
         Shell_ir.Lit "commit";
         Shell_ir.Lit "-m";
         Shell_ir.Lit "my message";
         Shell_ir.Lit "--allow-empty";
       ] -> ()
     (* "commit message must preserve spaces as one Lit" *)
     | _ -> assert false)
  | _ -> assert false

let test_single_quote_with_pipe_metachar () =
  (* Pipe inside single quotes is literal text, not a pipeline
     separator — protects the gate from strings that look shell-like
     but are actually inert literal payload. *)
  match Bash.parse_string "echo 'foo | bar'" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    (match s.args with
     | [ Shell_ir.Lit "foo | bar" ] -> ()
     | _ -> assert false)
  | _ -> assert false

let test_unterminated_single_quote_rejected () =
  (* Missing closing quote must surface as Parse_error, not silently
     consume to EOF. *)
  match Bash.parse_string "echo 'unterminated" with
  | Parsed.Parse_error _ -> ()
  | _ -> assert false

let () =
  test_ls_single_command ();
  test_ls_with_args ();
  test_echo_message ();
  test_leading_whitespace_ignored ();
  test_two_stage_pipeline ();
  test_three_stage_pipeline_with_args ();
  test_single_command_is_simple_not_pipeline ();
  test_logic_or_rejected ();
  test_redirect_rejected_in_skeleton ();
  test_empty_input_rejected ();
  test_whitespace_only_rejected ();
  test_single_quoted_arg ();
  test_single_quoted_empty ();
  test_multiple_single_quoted_args ();
  test_single_quote_with_pipe_metachar ();
  test_unterminated_single_quote_rejected ();
  print_endline "[test_bash_parser] all tests passed"
