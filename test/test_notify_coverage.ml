(** Notify Module Coverage Tests

    Tests for the macOS mention notification:
    - the notifier boundary: which program a mention reaches, with what
      arguments, that no probe process runs first, and that a notifier that
      never returns is stopped at the module's bound
    - focus_payload record type
    - sanitize_token: shell-safe identifier sanitization
    - token_value: optional token extraction
    - is_truthy: boolean string parsing
    - escape_shell: shell string escaping
    - render_focus_template: template substitution
*)

open Alcotest

module Notify = Masc.Notify

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let source_file rel =
  let path = Filename.concat (source_root ()) rel in
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

(* ============================================================
   sanitize_token Tests
   ============================================================ *)

let test_sanitize_token_alphanumeric () =
  check string "alphanumeric" "abc123" (Notify.sanitize_token "abc123")

let test_sanitize_token_with_dash () =
  check string "with dash" "test-value" (Notify.sanitize_token "test-value")

let test_sanitize_token_with_underscore () =
  check string "with underscore" "test_value" (Notify.sanitize_token "test_value")

let test_sanitize_token_with_dot () =
  check string "with dot" "test.value" (Notify.sanitize_token "test.value")

let test_sanitize_token_removes_special () =
  check string "removes special" "testvalue" (Notify.sanitize_token "test@value!")

let test_sanitize_token_removes_spaces () =
  check string "removes spaces" "testvalue" (Notify.sanitize_token "test value")

let test_sanitize_token_empty () =
  check string "empty" "" (Notify.sanitize_token "")

let test_sanitize_token_all_special () =
  check string "all special" "" (Notify.sanitize_token "!@#$%^&*()")

let test_sanitize_token_mixed_case () =
  check string "mixed case" "TestValue" (Notify.sanitize_token "TestValue")

(* ============================================================
   token_value Tests
   ============================================================ *)

let test_token_value_some () =
  check string "some" "test" (Notify.token_value (Some "test"))

let test_token_value_none () =
  check string "none" "" (Notify.token_value None)

let test_token_value_sanitizes () =
  check string "sanitizes" "testvalue" (Notify.token_value (Some "test@value"))

let test_token_value_empty_some () =
  check string "empty some" "" (Notify.token_value (Some ""))

(* ============================================================
   is_truthy Tests
   ============================================================ *)

let test_is_truthy_1 () =
  check bool "1" true (Notify.is_truthy "1")

let test_is_truthy_true () =
  check bool "true" true (Notify.is_truthy "true")

let test_is_truthy_yes () =
  check bool "yes" true (Notify.is_truthy "yes")

let test_is_truthy_on () =
  check bool "on" true (Notify.is_truthy "on")

let test_is_truthy_y () =
  check bool "y" true (Notify.is_truthy "y")

let test_is_truthy_TRUE () =
  check bool "TRUE" true (Notify.is_truthy "TRUE")

let test_is_truthy_Yes () =
  check bool "Yes" true (Notify.is_truthy "Yes")

let test_is_truthy_0 () =
  check bool "0" false (Notify.is_truthy "0")

let test_is_truthy_false () =
  check bool "false" false (Notify.is_truthy "false")

let test_is_truthy_no () =
  check bool "no" false (Notify.is_truthy "no")

let test_is_truthy_empty () =
  check bool "empty" false (Notify.is_truthy "")

let test_is_truthy_whitespace () =
  check bool "with whitespace" true (Notify.is_truthy "  true  ")

(* ============================================================
   escape_shell Tests
   ============================================================ *)

let test_escape_shell_plain () =
  check string "plain" "test" (Notify.escape_shell "test")

let test_escape_shell_single_quote () =
  check string "single quote" "it'\\''s" (Notify.escape_shell "it's")

let test_escape_shell_newline () =
  check string "newline" "line1 line2" (Notify.escape_shell "line1\nline2")

let test_escape_shell_empty () =
  check string "empty" "" (Notify.escape_shell "")

let test_escape_shell_multiple_quotes () =
  check string "multiple quotes" "a'\\''b'\\''c" (Notify.escape_shell "a'b'c")

let test_escape_shell_special_chars () =
  (* Most special chars are kept as-is *)
  check string "special chars" "$PATH" (Notify.escape_shell "$PATH")

(* ============================================================
   render_focus_template Tests
   ============================================================ *)

let test_render_focus_template_target () =
  let payload : Notify.focus_payload = {
    target_agent = Some "claude";
    from_agent = None;
    task_id = None;
  } in
  let result = Notify.render_focus_template "focus {{target}}" payload in
  check string "target" "focus claude" result

let test_render_focus_template_from () =
  let payload : Notify.focus_payload = {
    target_agent = None;
    from_agent = Some "gemini";
    task_id = None;
  } in
  let result = Notify.render_focus_template "from {{from}}" payload in
  check string "from" "from gemini" result

let test_render_focus_template_task () =
  let payload : Notify.focus_payload = {
    target_agent = None;
    from_agent = None;
    task_id = Some "task-001";
  } in
  let result = Notify.render_focus_template "task {{task}}" payload in
  check string "task" "task task-001" result

let test_render_focus_template_all () =
  let payload : Notify.focus_payload = {
    target_agent = Some "claude";
    from_agent = Some "gemini";
    task_id = Some "task-001";
  } in
  let result = Notify.render_focus_template "{{target}} {{from}} {{task}}" payload in
  check string "all" "claude gemini task-001" result

let test_render_focus_template_none () =
  let payload : Notify.focus_payload = {
    target_agent = None;
    from_agent = None;
    task_id = None;
  } in
  let result = Notify.render_focus_template "empty: {{target}}{{from}}{{task}}" payload in
  check string "none" "empty: " result

let test_render_focus_template_no_placeholders () =
  let payload : Notify.focus_payload = {
    target_agent = Some "claude";
    from_agent = None;
    task_id = None;
  } in
  let result = Notify.render_focus_template "static text" payload in
  check string "no placeholders" "static text" result

let test_render_focus_template_sanitizes () =
  let payload : Notify.focus_payload = {
    target_agent = Some "claude@test";
    from_agent = None;
    task_id = None;
  } in
  let result = Notify.render_focus_template "agent: {{target}}" payload in
  check string "sanitizes" "agent: claudetest" result

(* ============================================================
   escape_applescript Tests
   ============================================================ *)

let test_escape_applescript_plain () =
  check string "plain" "test" (Notify.escape_applescript "test")

let test_escape_applescript_double_quote () =
  check string "double quote" "he said \\\"hello\\\"" (Notify.escape_applescript "he said \"hello\"")

let test_escape_applescript_backslash () =
  check string "backslash" "path\\\\to\\\\file" (Notify.escape_applescript "path\\to\\file")

let test_escape_applescript_newline () =
  check string "newline" "line1 line2" (Notify.escape_applescript "line1\nline2")

let test_escape_applescript_empty () =
  check string "empty" "" (Notify.escape_applescript "")

let test_escape_applescript_mixed () =
  check string "mixed" "say \\\"hi\\\" and \\\\" (Notify.escape_applescript "say \"hi\" and \\")

(* ============================================================
   agent_emoji Tests
   ============================================================ *)

let test_agent_emoji_llm_a () =
  Notify.register_agent_emoji "claude" "🟣";
  check string "claude" "🟣" (Notify.agent_emoji "claude")

let test_agent_emoji_f () =
  Notify.register_agent_emoji "gemini" "🔵";
  check string "gemini" "🔵" (Notify.agent_emoji "gemini")

let test_agent_emoji_a () =
  Notify.register_agent_emoji "codex" "🟢";
  check string "codex" "🟢" (Notify.agent_emoji "codex")

let test_agent_emoji_llama () =
  Notify.register_agent_emoji "llama" "🦙";
  check string "llama" "🦙" (Notify.agent_emoji "llama")

let test_agent_emoji_system () =
  check string "system" "⚙️" (Notify.agent_emoji "system")

let test_agent_emoji_unknown () =
  check string "unknown" "🤖" (Notify.agent_emoji "unknown-agent")

let test_agent_emoji_empty () =
  check string "empty" "🤖" (Notify.agent_emoji "")

(* ============================================================
   focus_payload Record Tests
   ============================================================ *)

let test_focus_payload_all_some () =
  let p : Notify.focus_payload = {
    target_agent = Some "claude";
    from_agent = Some "gemini";
    task_id = Some "task-001";
  } in
  check (option string) "target" (Some "claude") p.target_agent;
  check (option string) "from" (Some "gemini") p.from_agent;
  check (option string) "task" (Some "task-001") p.task_id

let test_focus_payload_all_none () =
  let p : Notify.focus_payload = {
    target_agent = None;
    from_agent = None;
    task_id = None;
  } in
  check (option string) "target" None p.target_agent;
  check (option string) "from" None p.from_agent;
  check (option string) "task" None p.task_id

let test_terminal_notifier_execute_requires_opt_in () =
  let src = source_file "lib/notify.ml" in
  check bool "execute opt-in env is present" true
    (String_util.contains_substring src "MASC_NOTIFY_ALLOW_SHELL_EXECUTE");
  check bool "focus builder defaults to no shell command" true
    (String_util.contains_substring src "if not (shell_execute_clicks_enabled ())");
  check bool "terminal-notifier execute is guarded" true
    (String_util.contains_substring src
       "Some cmd when shell_execute_clicks_enabled () -> base @ [\"-execute\"; cmd]")

(* ============================================================
   Notifier boundary
   ============================================================ *)

external unsetenv : string -> unit = "masc_test_unsetenv"

(* A directory that stands in for PATH for the length of one case: the
   programs the case plants there are the only ones the notifier lookup and
   spawn can find. The probes the module used to run, uname and which, are
   planted as marker writers, so a probe that still ran would leave a file. *)
let with_path_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "notify-path-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir dir 0o700;
  let previous = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" dir;
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some path -> Unix.putenv "PATH" path
       | None -> unsetenv "PATH");
      Array.iter
        (fun name -> try Sys.remove (Filename.concat dir name) with Sys_error _ -> ())
        (Sys.readdir dir);
      try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () -> f dir)

let plant dir name body =
  let path = Filename.concat dir name in
  Out_channel.with_open_bin path (fun oc -> output_string oc body);
  Unix.chmod path 0o700

(* Records each argument on its own line and exits 0, the shape of a
   notifier that posted. *)
let argv_recorder ~into =
  Printf.sprintf "#!/bin/sh\nfor a in \"$@\"; do printf '%%s\\n' \"$a\"; done > '%s'\nexit 0\n" into

let marker_writer ~marker = Printf.sprintf "#!/bin/sh\n: > '%s'\nexit 0\n" marker

let plant_probe_markers dir =
  plant dir "uname" (marker_writer ~marker:(Filename.concat dir "uname.ran"));
  plant dir "which" (marker_writer ~marker:(Filename.concat dir "which.ran"))

let check_no_probe_ran dir =
  check bool "uname was not spawned" false (Sys.file_exists (Filename.concat dir "uname.ran"));
  check bool "which was not spawned" false (Sys.file_exists (Filename.concat dir "which.ran"))

let recorded_argv path =
  if Sys.file_exists path
  then In_channel.with_open_bin path In_channel.input_all |> String.split_on_char '\n'
  else []

let with_eio f =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () -> f env)

let mention () =
  Notify.notify_mention ~from_agent:"gemini" ~target_agent:"claude" ~message:"hello there" ()

let test_a_mention_reaches_terminal_notifier_and_nothing_probes_first () =
  with_eio @@ fun _env ->
  with_path_dir @@ fun dir ->
  let argv_file = Filename.concat dir "argv" in
  plant dir "terminal-notifier" (argv_recorder ~into:argv_file);
  plant_probe_markers dir;
  mention ();
  let argv = recorded_argv argv_file in
  let has value = List.mem value argv in
  check bool "the mention's subtitle" true (has "@gemini mentioned you");
  check bool "the mention's body" true (has "hello there");
  check bool "grouped under masc" true (has "-group" && has "masc");
  check bool "a mention sounds" true (has "-sound" && has "default");
  check bool "no click command without opt-in" false (has "-execute");
  check_no_probe_ran dir

let test_without_terminal_notifier_the_post_goes_through_osascript () =
  with_eio @@ fun _env ->
  with_path_dir @@ fun dir ->
  let argv_file = Filename.concat dir "argv" in
  plant dir "osascript" (argv_recorder ~into:argv_file);
  plant_probe_markers dir;
  mention ();
  let argv = recorded_argv argv_file in
  check bool "an inline script" true (List.mem "-e" argv);
  let script = String.concat "\n" argv in
  check bool "the script posts the body" true
    (String_util.contains_substring script "display notification \"hello there\"");
  check bool "the script names the sender" true
    (String_util.contains_substring script "@gemini mentioned you");
  check_no_probe_ran dir

let test_a_host_with_no_notifier_starts_no_process () =
  with_eio @@ fun _env ->
  with_path_dir @@ fun dir ->
  plant_probe_markers dir;
  mention ();
  check_no_probe_ran dir

(* The bound is what turns a notifier that never returns into a failed
   notification instead of a held tool call: the fake sleeps far past it and
   the call comes back at the bound, not at the sleep. *)

(* How much later than the bound the call may return. After the bound the
   notifier is stopped: SIGTERM, a grace, SIGKILL, a grace
   ([Process_eio.child_exit_grace_seconds] each). The fake dies on the
   SIGTERM and comes back well inside that; the window admits the worst case
   plus a second for the runner. *)
let stop_slack_s = (2. *. Process_eio.child_exit_grace_seconds) +. 1.0

(* The bound is a policy value, not a measurement; the case only rejects one
   that could not serve as a bound: at or under a measured post, or a
   minute and longer, where a held tool call would already be the symptom. *)
let shortest_useful_bound_s = 1.0
let longest_useful_bound_s = 60.0

let test_a_notifier_that_never_returns_is_stopped_at_the_bound () =
  with_eio @@ fun env ->
  with_path_dir @@ fun dir ->
  let clock = Eio.Stdenv.clock env in
  plant dir "terminal-notifier" "#!/bin/sh\nexec /bin/sleep 600\n";
  let started = Eio.Time.now clock in
  mention ();
  let elapsed = Eio.Time.now clock -. started in
  let bound = Notify.notifier_timeout_sec in
  check bool "the bound sits between a measured post and a minute" true
    (bound > shortest_useful_bound_s && bound < longest_useful_bound_s);
  check bool
    (Printf.sprintf "returned at the bound (%.1fs), took %.1fs" bound elapsed)
    true
    (elapsed >= bound && elapsed < bound +. stop_slack_s)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Notify Coverage" [
    "sanitize_token", [
      test_case "alphanumeric" `Quick test_sanitize_token_alphanumeric;
      test_case "with dash" `Quick test_sanitize_token_with_dash;
      test_case "with underscore" `Quick test_sanitize_token_with_underscore;
      test_case "with dot" `Quick test_sanitize_token_with_dot;
      test_case "removes special" `Quick test_sanitize_token_removes_special;
      test_case "removes spaces" `Quick test_sanitize_token_removes_spaces;
      test_case "empty" `Quick test_sanitize_token_empty;
      test_case "all special" `Quick test_sanitize_token_all_special;
      test_case "mixed case" `Quick test_sanitize_token_mixed_case;
    ];
    "token_value", [
      test_case "some" `Quick test_token_value_some;
      test_case "none" `Quick test_token_value_none;
      test_case "sanitizes" `Quick test_token_value_sanitizes;
      test_case "empty some" `Quick test_token_value_empty_some;
    ];
    "is_truthy", [
      test_case "1" `Quick test_is_truthy_1;
      test_case "true" `Quick test_is_truthy_true;
      test_case "yes" `Quick test_is_truthy_yes;
      test_case "on" `Quick test_is_truthy_on;
      test_case "y" `Quick test_is_truthy_y;
      test_case "TRUE" `Quick test_is_truthy_TRUE;
      test_case "Yes" `Quick test_is_truthy_Yes;
      test_case "0" `Quick test_is_truthy_0;
      test_case "false" `Quick test_is_truthy_false;
      test_case "no" `Quick test_is_truthy_no;
      test_case "empty" `Quick test_is_truthy_empty;
      test_case "whitespace" `Quick test_is_truthy_whitespace;
    ];
    "escape_shell", [
      test_case "plain" `Quick test_escape_shell_plain;
      test_case "single quote" `Quick test_escape_shell_single_quote;
      test_case "newline" `Quick test_escape_shell_newline;
      test_case "empty" `Quick test_escape_shell_empty;
      test_case "multiple quotes" `Quick test_escape_shell_multiple_quotes;
      test_case "special chars" `Quick test_escape_shell_special_chars;
    ];
    "render_focus_template", [
      test_case "target" `Quick test_render_focus_template_target;
      test_case "from" `Quick test_render_focus_template_from;
      test_case "task" `Quick test_render_focus_template_task;
      test_case "all" `Quick test_render_focus_template_all;
      test_case "none" `Quick test_render_focus_template_none;
      test_case "no placeholders" `Quick test_render_focus_template_no_placeholders;
      test_case "sanitizes" `Quick test_render_focus_template_sanitizes;
    ];
    "escape_applescript", [
      test_case "plain" `Quick test_escape_applescript_plain;
      test_case "double quote" `Quick test_escape_applescript_double_quote;
      test_case "backslash" `Quick test_escape_applescript_backslash;
      test_case "newline" `Quick test_escape_applescript_newline;
      test_case "empty" `Quick test_escape_applescript_empty;
      test_case "mixed" `Quick test_escape_applescript_mixed;
    ];
    "agent_emoji", [
      test_case "claude" `Quick test_agent_emoji_llm_a;
      test_case "gemini" `Quick test_agent_emoji_f;
      test_case "codex" `Quick test_agent_emoji_a;
      test_case "llama" `Quick test_agent_emoji_llama;
      test_case "system" `Quick test_agent_emoji_system;
      test_case "unknown" `Quick test_agent_emoji_unknown;
      test_case "empty" `Quick test_agent_emoji_empty;
    ];
    "focus_payload", [
      test_case "all some" `Quick test_focus_payload_all_some;
      test_case "all none" `Quick test_focus_payload_all_none;
    ];
    "shell_execute_guard", [
      test_case "terminal-notifier execute requires opt-in" `Quick
        test_terminal_notifier_execute_requires_opt_in;
    ];
    "notifier boundary", [
      test_case "a mention reaches terminal-notifier and nothing probes first" `Quick
        test_a_mention_reaches_terminal_notifier_and_nothing_probes_first;
      test_case "without terminal-notifier the post goes through osascript" `Quick
        test_without_terminal_notifier_the_post_goes_through_osascript;
      test_case "a host with no notifier starts no process" `Quick
        test_a_host_with_no_notifier_starts_no_process;
      test_case "a notifier that never returns is stopped at the bound" `Slow
        test_a_notifier_that_never_returns_is_stopped_at_the_bound;
    ];
  ]
