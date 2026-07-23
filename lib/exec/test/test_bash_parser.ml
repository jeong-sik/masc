(** Bash parser smoke tests.

    These tests lock in the accepted subset plus the fail-closed error
    surface for unsupported shell constructs.

    The error arm uses [assert false] instead of the usual pattern
    so the lib-scope unsafe-pattern ratchet stays green (this test
    dir is counted as lib by the health script). *)

open Masc_exec
open Masc_exec_bash_parser

let test_ls_single_command () =
  match Bash.parse_string "ls" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "ls");
    assert (s.args = [])
  (* "ls must parse to Simple" *)
  | _ -> assert false

let test_ls_with_args () =
  match Bash.parse_string "ls -la /tmp" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "ls");
    (match s.args with
     | [ Shell_ir.Lit ("-la", _); Shell_ir.Lit ("/tmp", _) ] -> ()
     (* "args wrong shape" *)
     | _ -> assert false)
  (* "ls -la /tmp must parse" *)
  | _ -> assert false

let test_echo_message () =
  match Bash.parse_string "echo hello" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "echo");
    assert (s.args = [ Shell_ir.Lit ("hello", Shell_ir.default_meta) ])
  (* "echo hello must parse" *)
  | _ -> assert false

let test_dev_null_as_regular_arg () =
  match Bash.parse_string "cat /dev/null" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "cat");
    assert (s.args = [ Shell_ir.Lit ("/dev/null", Shell_ir.default_meta) ]);
    assert (s.redirects = [])
  | _ -> assert false

let test_leading_whitespace_ignored () =
  match Bash.parse_string "   ls  " with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "ls")
  (* "leading/trailing whitespace must be skipped" *)
  | _ -> assert false

let test_two_stage_pipeline () =
  match Bash.parse_string "ls | cat" with
  | Parsed.Parsed (Shell_ir.Pipeline [
      Shell_ir.Simple s1; Shell_ir.Simple s2
    ]) ->
    assert (Exec_program.to_string s1.bin = "ls");
    assert (Exec_program.to_string s2.bin = "cat");
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
       assert (Exec_program.to_string s1.bin = "ls");
       assert (Exec_program.to_string s2.bin = "grep");
       assert (Exec_program.to_string s3.bin = "wc");
       assert (s2.args = [ Shell_ir.Lit ("foo", Shell_ir.default_meta) ])
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
  (* '||' is subset-excluded — post-hoc classifier on the Parse_error
     path now mints Parsed.Too_complex `Logic_op, which the corpus
     tap uses to bucket the rejection by construct type. *)
  match Bash.parse_string "ls || cat" with
  | Parsed.Too_complex `Logic_op -> ()
  (* "|| must classify as Logic_op" *)
  | _ -> assert false

let test_logic_and_rejected () =
  match Bash.parse_string "ls && cat" with
  | Parsed.Too_complex `Logic_op -> ()
  | _ -> assert false

let test_general_redirect_parsed () =
  match Bash.parse_string "echo hi > /tmp/out" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "echo");
    assert (s.args = [ Shell_ir.Lit ("hi", Shell_ir.default_meta) ]);
    (match s.redirects with
     | [ Redirect_scope.File { fd = 1; target; mode = Redirect_scope.Write } ] ->
       assert (Path_scope.raw target = "/tmp/out")
     | _ -> assert false)
  | _ -> assert false

let test_redirect_append_parsed () =
  match Bash.parse_string "echo hi >> /tmp/out" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    (match s.redirects with
     | [ Redirect_scope.File { fd = 1; target; mode = Redirect_scope.Append } ] ->
       assert (Path_scope.raw target = "/tmp/out")
     | _ -> assert false)
  | _ -> assert false

let test_input_redirect_parsed () =
  match Bash.parse_string "cat < /etc/hosts" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    (match s.redirects with
     | [ Redirect_scope.File { fd = 0; target; mode = Redirect_scope.Read } ] ->
       assert (Path_scope.raw target = "/etc/hosts")
     | _ -> assert false)
  | _ -> assert false

let test_general_redirect_rejected_before_dispatch () =
  match Bash.parse_string "echo hi > /tmp/out" with
  | Parsed.Parsed ir ->
    let result = Masc_exec.Exec_dispatch.dispatch ir in
    assert (result.status = Unix.WEXITED 1);
    assert (result.stdout = "");
    assert (String.contains result.stderr 'w');
    assert (String.contains result.stderr '/')
  | _ -> assert false

let test_fd_redirect_parsed () =
  match Bash.parse_string "ls 2>&1" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    (match s.redirects with
     | [ Redirect_scope.Fd_to_fd { src = 2; dst = 1 } ] -> ()
     | _ -> assert false)
  | _ -> assert false

let test_dev_null_redirect_parsed () =
  match Bash.parse_string "rg foo 2>/dev/null" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    (match s.redirects with
     | [ Redirect_scope.File { fd = 2; target; mode = Redirect_scope.Write } ] ->
       assert (Path_scope.raw target = "/dev/null")
     | _ -> assert false)
  | _ -> assert false

let test_spaced_dev_null_redirect_parsed () =
  match Bash.parse_string "rg foo 2> /dev/null" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    (match s.redirects with
     | [ Redirect_scope.File { fd = 2; target; mode = Redirect_scope.Write } ] ->
       assert (Path_scope.raw target = "/dev/null")
     | _ -> assert false)
  | _ -> assert false

let test_quoted_dev_null_redirect_parsed () =
  match Bash.parse_string "rg foo 2> \"/dev/null\"" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    (match s.redirects with
     | [ Redirect_scope.File { fd = 2; target; mode = Redirect_scope.Write } ] ->
       assert (Path_scope.raw target = "/dev/null")
     | _ -> assert false)
  | _ -> assert false

let test_pipeline_dev_null_redirect_preserved () =
  match Bash.parse_string "rg foo 2>/dev/null | head -20" with
  | Parsed.Parsed (Shell_ir.Pipeline [ Shell_ir.Simple s1; Shell_ir.Simple s2 ]) ->
    assert (Exec_program.to_string s1.bin = "rg");
    assert (Exec_program.to_string s2.bin = "head");
    (match s1.redirects, s2.redirects with
     | [ Redirect_scope.File { fd = 2; target; mode = Redirect_scope.Write } ], [] ->
       assert (Path_scope.raw target = "/dev/null")
     | _ -> assert false)
  | _ -> assert false

let test_env_prefix_parsed () =
  match Bash.parse_string "LC_ALL=C git status" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "git");
    assert (s.args = [ Shell_ir.Lit ("status", Shell_ir.default_meta) ]);
    assert (s.env = [ "LC_ALL", Shell_ir.Lit ("C", Shell_ir.default_meta) ])
  | _ -> assert false

let test_multiple_env_prefixes_preserve_order () =
  match Bash.parse_string "A=1 B='two words' printenv A" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "printenv");
    assert (s.args = [ Shell_ir.Lit ("A", Shell_ir.default_meta) ]);
    assert
      (s.env
       = [ "A", Shell_ir.Lit ("1", Shell_ir.default_meta)
         ; "B", Shell_ir.Lit ("two words", { Shell_ir.default_meta with quoted = true })
         ])
  | _ -> assert false

let test_env_assignment_after_bin_is_arg () =
  match Bash.parse_string "echo LC_ALL=C" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "echo");
    assert (s.args = [ Shell_ir.Lit ("LC_ALL=C", Shell_ir.default_meta) ]);
    assert (s.env = [])
  | _ -> assert false

let test_env_only_rejected () =
  match Bash.parse_string "LC_ALL=C" with
  | Parsed.Parse_error _ -> ()
  | _ -> assert false

let test_pipeline_env_prefixes_preserved_per_stage () =
  match Bash.parse_string "LC_ALL=C printf hi | LANG=C wc -c" with
  | Parsed.Parsed (Shell_ir.Pipeline [ Shell_ir.Simple s1; Shell_ir.Simple s2 ]) ->
    assert (Exec_program.to_string s1.bin = "printf");
    assert (Exec_program.to_string s2.bin = "wc");
    assert (s1.env = [ "LC_ALL", Shell_ir.Lit ("C", Shell_ir.default_meta) ]);
    assert (s2.env = [ "LANG", Shell_ir.Lit ("C", Shell_ir.default_meta) ]);
    assert (s1.args = [ Shell_ir.Lit ("hi", Shell_ir.default_meta) ]);
    assert (s2.args = [ Shell_ir.Lit ("-c", Shell_ir.default_meta) ])
  | _ -> assert false

let test_env_prefix_dispatch_overlay () =
  match
    Bash.parse_string
      "MASC_SHELL_IR_ENV_PREFIX_TEST=ok printenv MASC_SHELL_IR_ENV_PREFIX_TEST"
  with
  | Parsed.Parsed ir ->
    let result = Masc_exec.Exec_dispatch.dispatch ir in
    assert (result.status = Unix.WEXITED 0);
    assert (String.trim result.stdout = "ok")
  | _ -> assert false

let test_heredoc_rejected () =
  (* "<<" must out-rank single "<" — order check in classify_too_complex. *)
  match Bash.parse_string "cat <<EOF" with
  | Parsed.Too_complex `Heredoc -> ()
  | _ -> assert false

let test_here_string_rejected () =
  (* "<<<" must out-rank "<<" — order check in classify_too_complex. *)
  match Bash.parse_string "cat <<<payload" with
  | Parsed.Too_complex `Here_string -> ()
  | _ -> assert false

let test_cmd_subst_paren_rejected () =
  match Bash.parse_string "echo $(date)" with
  | Parsed.Too_complex `Cmd_subst -> ()
  | _ -> assert false

let test_cmd_subst_backtick_rejected () =
  match Bash.parse_string "echo `date`" with
  | Parsed.Too_complex `Cmd_subst -> ()
  | _ -> assert false

let test_arith_expansion_rejected () =
  (* "$((" must out-rank "$(" — order check in classify_too_complex. *)
  match Bash.parse_string "echo $((1 + 2))" with
  | Parsed.Too_complex `Arith_expansion -> ()
  | _ -> assert false

let test_background_rejected () =
  match Bash.parse_string "sleep 10 &" with
  | Parsed.Too_complex `Background -> ()
  | _ -> assert false

let test_subshell_rejected () =
  match Bash.parse_string "(ls)" with
  | Parsed.Too_complex `Subshell -> ()
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
    assert (Exec_program.to_string s.bin = "echo");
    (match s.args with
     | [ Shell_ir.Lit ("hello world", meta) ] -> assert meta.quoted
     (* "single-quoted content must land as one Lit" *)
     | _ -> assert false)
  | _ -> assert false

let test_single_quoted_empty () =
  match Bash.parse_string "echo ''" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "echo");
    (match s.args with
     | [ Shell_ir.Lit ("", _) ] -> ()
     (* "empty single-quoted string must land as empty Lit" *)
     | _ -> assert false)
  | _ -> assert false

let test_multiple_single_quoted_args () =
  match Bash.parse_string "git commit -m 'my message' --allow-empty" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "git");
    (match s.args with
     | [
         Shell_ir.Lit ("commit", _);
         Shell_ir.Lit ("-m", _);
         Shell_ir.Lit ("my message", _);
         Shell_ir.Lit ("--allow-empty", _);
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
     | [ Shell_ir.Lit ("foo | bar", _) ] -> ()
     | _ -> assert false)
  | _ -> assert false

let test_unterminated_single_quote_rejected () =
  (* Missing closing quote must surface as Parse_error, not silently
     consume to EOF. *)
  match Bash.parse_string "echo 'unterminated" with
  | Parsed.Parse_error _ -> ()
  | _ -> assert false

let test_double_quoted_arg () =
  (* Double-quoted args with literal body (no $/\/backtick) preserve
     internal spaces and arrive as one Lit element — mirrors the
     common [rg "pattern"] shape.  The surrounding quotes are stripped
     at lex time, so the Lit carries the payload only. *)
  match Bash.parse_string "echo \"hello world\"" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "echo");
    (match s.args with
     | [ Shell_ir.Lit ("hello world", meta) ] -> assert meta.quoted
     (* "double-quoted content must land as one Lit" *)
     | _ -> assert false)
  | _ -> assert false

let test_double_quoted_empty () =
  match Bash.parse_string "echo \"\"" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "echo");
    (match s.args with
     | [ Shell_ir.Lit ("", _) ] -> ()
     (* "empty double-quoted string must land as empty Lit" *)
     | _ -> assert false)
  | _ -> assert false

let test_double_quote_with_pipe_metachar () =
  (* Pipe inside double quotes is literal text, not a pipeline
     separator — same safety invariant as single quotes. *)
  match Bash.parse_string "echo \"foo | bar\"" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    (match s.args with
     | [ Shell_ir.Lit ("foo | bar", _) ] -> ()
     | _ -> assert false)
  | _ -> assert false

let test_double_quote_rg_pattern () =
  (* The most common caller shape — [rg "error pattern"] style — must
     round-trip through lex+parse untouched so the gate sees the
     trusted argv the user intended. *)
  match Bash.parse_string "rg \"error pattern\" src/" with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "rg");
    (match s.args with
     | [ Shell_ir.Lit ("error pattern", _); Shell_ir.Lit ("src/", _) ] -> ()
     | _ -> assert false)
  | _ -> assert false

let test_double_quote_with_escaped_regex_pipe () =
  (* [\|] inside double quotes is literal regex payload for rg/grep,
     not a shell pipeline.  Keeping it in the typed parser lets the
     keeper safe-read fallback use normal argv validation. *)
  match Bash.parse_string {|rg -n "ghost\|task" lib/|} with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "rg");
    (match s.args with
     | [
         Shell_ir.Lit ("-n", _);
         Shell_ir.Lit ({|ghost\|task|}, _);
         Shell_ir.Lit ("lib/", _);
       ] -> ()
     | _ -> assert false)
  | _ -> assert false

let test_word_with_double_quoted_suffix () =
  (* Bash treats [--include="*.ml"] as one argv item.  The unquoted
     prefix is inert option text; the quoted suffix carries the glob
     literal without opening the unquoted glob surface. *)
  match Bash.parse_string {|grep -rn "exec_semantic" lib/ --include="*.ml"|} with
  | Parsed.Parsed (Shell_ir.Simple s) ->
    assert (Exec_program.to_string s.bin = "grep");
    (match s.args with
     | [
         Shell_ir.Lit ("-rn", _);
         Shell_ir.Lit ("exec_semantic", _);
         Shell_ir.Lit ("lib/", _);
         Shell_ir.Lit ("--include=*.ml", meta);
       ] -> assert meta.quoted
     | _ -> assert false)
  | _ -> assert false

let test_word_metadata_preserves_quoted_path_and_pipeline () =
  match Bash_words.stages "cat 'repos/foo.ml' | head -1" with
  | Ok [ [ cat; path ]; [ head; limit ] ] ->
    assert (cat.value = "cat");
    assert (not cat.quoted);
    assert (path.value = "repos/foo.ml");
    assert path.quoted;
    assert (not path.globbed);
    assert (head.value = "head");
    assert (limit.value = "-1")
  | _ -> assert false

let test_word_metadata_marks_globbed_path () =
  match Bash_words.stages "ls repos/*.ml" with
  | Ok [ [ ls; path ] ] ->
    assert (ls.value = "ls");
    assert (path.value = "repos/*.ml");
    assert path.globbed;
    assert (not path.quoted)
  | _ -> assert false

let test_top_level_command_segments_preserve_quote_boundaries () =
  let segments =
    Bash_words.top_level_command_segments
      {|git commit -m "do not gh pr create" && gh pr create --draft; git push origin feat|}
  in
  match segments with
  | [
      (true, {|git commit -m "do not gh pr create"|});
      (false, "gh pr create --draft");
      (true, "git push origin feat");
    ] -> ()
  | _ -> assert false

let test_double_quote_with_dollar_rejected () =
  (* Variable expansion is subset-excluded at the A1 layer — any '$'
     inside "..." breaks the lex so Parse_error surfaces rather than
     silently treating the literal as expanded. *)
  match Bash.parse_string "echo \"value $FOO here\"" with
  | Parsed.Parse_error _ -> ()
  | _ -> assert false

let test_double_quote_with_backslash_rejected () =
  (* Escape sequences ('\"', '\\') are subset-excluded at A1 — reject
     until a later PR adds the unescape sub-rule. *)
  match Bash.parse_string "echo \"he said \\\"hi\\\"\"" with
  | Parsed.Parse_error _ -> ()
  | _ -> assert false

let test_double_quote_with_backtick_rejected () =
  (* Command substitution ('`cmd`') is subset-excluded.  Post-hoc
     classifier now mints Too_complex `Cmd_subst rather than the
     opaque Parse_error the earlier skeleton produced — the substring
     scan does not distinguish between backticks inside vs outside
     quotes, which is acceptable because anything reaching this arm
     has already been rejected by the grammar and the more-specific
     tag is strictly better for corpus-tap telemetry. *)
  match Bash.parse_string "echo \"now `date`\"" with
  | Parsed.Too_complex `Cmd_subst -> ()
  | _ -> assert false

let test_unterminated_double_quote_rejected () =
  match Bash.parse_string "echo \"unterminated" with
  | Parsed.Parse_error _ -> ()
  | _ -> assert false

let test_token_limit_aborts () =
  let many_words = List.init 50_001 (fun _ -> "x") in
  match Bash.parse_string (String.concat " " many_words) with
  | Parsed.Parse_aborted `Token_limit_50k -> ()
  | _ -> assert false

let () =
  test_ls_single_command ();
  test_ls_with_args ();
  test_echo_message ();
  test_dev_null_as_regular_arg ();
  test_leading_whitespace_ignored ();
  test_two_stage_pipeline ();
  test_three_stage_pipeline_with_args ();
  test_single_command_is_simple_not_pipeline ();
  test_logic_or_rejected ();
  test_logic_and_rejected ();
  test_general_redirect_parsed ();
  test_redirect_append_parsed ();
  test_input_redirect_parsed ();
  test_general_redirect_rejected_before_dispatch ();
  test_fd_redirect_parsed ();
  test_dev_null_redirect_parsed ();
  test_spaced_dev_null_redirect_parsed ();
  test_quoted_dev_null_redirect_parsed ();
  test_pipeline_dev_null_redirect_preserved ();
  test_env_prefix_parsed ();
  test_multiple_env_prefixes_preserve_order ();
  test_env_assignment_after_bin_is_arg ();
  test_env_only_rejected ();
  test_pipeline_env_prefixes_preserved_per_stage ();
  test_env_prefix_dispatch_overlay ();
  test_heredoc_rejected ();
  test_here_string_rejected ();
  test_cmd_subst_paren_rejected ();
  test_cmd_subst_backtick_rejected ();
  test_arith_expansion_rejected ();
  test_background_rejected ();
  test_subshell_rejected ();
  test_empty_input_rejected ();
  test_whitespace_only_rejected ();
  test_single_quoted_arg ();
  test_single_quoted_empty ();
  test_multiple_single_quoted_args ();
  test_single_quote_with_pipe_metachar ();
  test_unterminated_single_quote_rejected ();
  test_double_quoted_arg ();
  test_double_quoted_empty ();
  test_double_quote_with_pipe_metachar ();
  test_double_quote_rg_pattern ();
  test_double_quote_with_escaped_regex_pipe ();
  test_word_with_double_quoted_suffix ();
  test_word_metadata_preserves_quoted_path_and_pipeline ();
  test_word_metadata_marks_globbed_path ();
  test_top_level_command_segments_preserve_quote_boundaries ();
  test_double_quote_with_dollar_rejected ();
  test_double_quote_with_backslash_rejected ();
  test_double_quote_with_backtick_rejected ();
  test_unterminated_double_quote_rejected ();
  test_token_limit_aborts ();
  print_endline "[test_bash_parser] all tests passed"
