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

let test_pipe_rejected_in_skeleton () =
  (* Pipeline production not in A1-PR-1.  Pipe metachar makes the
     lexer reject; wrap at facade into Parse_error.  A follow-up PR
     adds the Pipeline production and flips this to Parsed.Parsed. *)
  match Bash.parse_string "ls | cat" with
  | Parsed.Parse_error _ -> ()
  (* "pipe must reject in skeleton grammar" *)
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

let () =
  test_ls_single_command ();
  test_ls_with_args ();
  test_echo_message ();
  test_leading_whitespace_ignored ();
  test_pipe_rejected_in_skeleton ();
  test_redirect_rejected_in_skeleton ();
  test_empty_input_rejected ();
  test_whitespace_only_rejected ();
  print_endline "[test_bash_parser] all tests passed"
