(** Unit tests for dev tools — no MODEL required.
    Tests file_read, file_write, shell_exec with safety validation. *)

open Agent_sdk
open Masc_mcp

(* Helper: find tool by name from tool list *)
let find_tool name tools =
  List.find (fun (t : Tool.t) -> t.schema.name = name) tools

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

(* --- Tool structure tests --- *)

let test_tool_count () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  Alcotest.(check int) "3 dev tools" 3 (List.length tools)

let test_tool_names () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let names = List.map (fun (t : Tool.t) -> t.schema.name) tools in
  let expected = ["file_read"; "file_write"; "shell_exec"] in
  Alcotest.(check (list string)) "tool names match" expected names

let test_readonly_tool_names () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_readonly_tools ~proc_mgr ~clock () in
  let names = List.map (fun (t : Tool.t) -> t.schema.name) tools in
  let expected = ["file_read"; "shell_exec"] in
  Alcotest.(check (list string)) "readonly tool names match" expected names

(* --- file_read tests --- *)

let test_file_read_existing () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  (* Write a temp file first *)
  let path = Filename.concat "/tmp" "dev_tools_test_read.txt" in
  Out_channel.with_open_text path
    (fun oc -> Out_channel.output_string oc "hello world");
  let result = Tool.execute tool
    (`Assoc [("path", `String path)]) in
  (match result with
   | Ok { Agent_sdk.Types.content } ->
     Alcotest.(check string) "content matches" "hello world" content
   | Error { Agent_sdk.Types.message = e; _ } ->
     Alcotest.fail (Printf.sprintf "expected Ok, got Error: %s" e));
  Sys.remove path

let test_file_read_nonexistent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  let result = Tool.execute tool
    (`Assoc [("path", `String "/tmp/nonexistent_dev_tools_xyz.txt")]) in
  (match result with
   | Error _ -> ()  (* expected *)
   | Ok _ -> Alcotest.fail "should fail for nonexistent file")

let test_file_read_blocked_path () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  let result = Tool.execute tool
    (`Assoc [("path", `String "/etc/passwd")]) in
  (match result with
   | Error { Agent_sdk.Types.message = msg; _ } ->
     Alcotest.(check bool) "mentions blocked" true
       (String.length msg > 0 &&
        (try ignore (String.index msg 'b'); true
         with Not_found -> true))
   | Ok _ -> Alcotest.fail "should reject /etc/passwd")

let test_file_read_path_traversal () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  (* /tmp/../../etc/passwd normalizes to /etc/passwd — must be blocked *)
  let result = Tool.execute tool
    (`Assoc [("path", `String "/tmp/../../etc/passwd")]) in
  (match result with
   | Error _ -> ()  (* expected: path traversal blocked *)
   | Ok _ -> Alcotest.fail "should reject path traversal /tmp/../../etc/passwd")

let test_file_read_rejects_prefix_sibling () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  let home = Sys.getenv "HOME" in
  let result = Tool.execute tool
    (`Assoc [("path", `String (Filename.concat home "me-sibling/secret.txt"))]) in
  match result with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should reject sibling path that only shares a prefix"

let test_file_read_rejects_tmp_symlink_escape () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  let path = "/tmp/agent_swarm_symlink_read_escape" in
  (try Sys.remove path with Sys_error _ -> ());
  Unix.symlink "/etc/passwd" path;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let result = Tool.execute tool (`Assoc [("path", `String path)]) in
      match result with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "should reject /tmp symlink escaping outside allowlist")

let test_file_read_truncation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  (* Create a 101KB file *)
  let path = "/tmp/dev_tools_test_large.txt" in
  let large_content = String.make 101_000 'x' in
  Out_channel.with_open_text path
    (fun oc -> Out_channel.output_string oc large_content);
  let result = Tool.execute tool
    (`Assoc [("path", `String path)]) in
  (match result with
   | Ok { Agent_sdk.Types.content } ->
     Alcotest.(check bool) "truncated to ~100KB" true
       (String.length content <= 100_100);
     Alcotest.(check bool) "has truncation marker" true
       (let suffix = "[TRUNCATED at 100KB]" in
        String.length content >= String.length suffix &&
        String.sub content
          (String.length content - String.length suffix)
          (String.length suffix) = suffix)
   | Error { Agent_sdk.Types.message = e; _ } ->
     Alcotest.fail (Printf.sprintf "expected Ok (truncated), got Error: %s" e));
  Sys.remove path

(* --- file_write tests --- *)

let test_file_write_new () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_write" tools in
  let path = "/tmp/dev_tools_test_write.txt" in
  (if Sys.file_exists path then Sys.remove path);
  let result = Tool.execute tool
    (`Assoc [("path", `String path);
             ("content", `String "test content")]) in
  (match result with
   | Ok { Agent_sdk.Types.content = msg } ->
     Alcotest.(check bool) "mentions bytes" true
       (String.length msg > 0);
     let written = In_channel.with_open_text path In_channel.input_all in
     Alcotest.(check string) "file content" "test content" written
   | Error { Agent_sdk.Types.message = e; _ } ->
     Alcotest.fail (Printf.sprintf "expected Ok, got Error: %s" e));
  Sys.remove path

let test_file_write_blocked_path () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_write" tools in
  let result = Tool.execute tool
    (`Assoc [("path", `String "/etc/shadow_test");
             ("content", `String "bad")]) in
  (match result with
   | Error _ -> ()  (* expected *)
   | Ok _ -> Alcotest.fail "should reject /etc/ path")

let test_file_write_rejects_prefix_sibling () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_write" tools in
  let home = Sys.getenv "HOME" in
  let result = Tool.execute tool
    (`Assoc [("path", `String (Filename.concat home "me-sibling/out.txt"));
             ("content", `String "bad")]) in
  match result with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should reject sibling path that only shares a prefix"

let test_file_write_rejects_tmp_symlink_escape () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_write" tools in
  let path = "/tmp/agent_swarm_symlink_write_escape" in
  (try Sys.remove path with Sys_error _ -> ());
  Unix.symlink "/etc" path;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let result = Tool.execute tool
        (`Assoc [("path", `String (Filename.concat path "passwd_copy"));
                 ("content", `String "bad")]) in
      match result with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "should reject /tmp symlink escaping outside allowlist")

(* --- shell_exec tests --- *)

let test_shell_exec_echo () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool
    (`Assoc [("command", `String "echo hello")]) in
  (match result with
   | Ok { Agent_sdk.Types.content = output } ->
     Alcotest.(check string) "echo output" "hello\n" output
   | Error { Agent_sdk.Types.message = e; _ } ->
     Alcotest.fail (Printf.sprintf "expected Ok, got Error: %s" e))

let test_shell_exec_blocked_command () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool
    (`Assoc [("command", `String "rm -rf /")]) in
  (match result with
   | Error { Agent_sdk.Types.message = msg; _ } ->
     Alcotest.(check bool) "mentions blocked" true
       (String.length msg > 0)
   | Ok _ -> Alcotest.fail "should reject rm -rf /")

let test_tool_exec_observer_bridges_to_telemetry () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let fs = Eio.Stdenv.fs env in
  let base_dir = Filename.temp_file "dev_tools_telemetry_" "" in
  Sys.remove base_dir;
  Unix.mkdir base_dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Array.iter
              (fun name -> rm (Filename.concat path name))
              (Sys.readdir path);
            Unix.rmdir path)
          else
            Unix.unlink path
      in
      try rm base_dir with _ -> ())
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      let on_exec ~tool_name ~success ~duration_ms =
        Telemetry_eio.track_tool_called ~fs config ~tool_name ~success
          ~duration_ms ~agent_id:"llama-local-worker" ()
      in
      let tools =
        Worker_dev_tools.make_tools ~proc_mgr ~clock ~on_exec ()
      in
      let tmp_path = Filename.concat "/tmp" "dev_tools_observer_bridge.txt" in
      if Sys.file_exists tmp_path then Sys.remove tmp_path;
      let write_tool = find_tool "file_write" tools in
      let read_tool = find_tool "file_read" tools in
      let shell_tool = find_tool "shell_exec" tools in
      (match
         Tool.execute write_tool
           (`Assoc
             [ ("path", `String tmp_path); ("content", `String "bridge") ])
       with
      | Ok _ -> ()
      | Error { Agent_sdk.Types.message = e; _ } ->
          Alcotest.fail (Printf.sprintf "file_write failed: %s" e));
      (match Tool.execute read_tool (`Assoc [ ("path", `String tmp_path) ]) with
      | Ok _ -> ()
      | Error { Agent_sdk.Types.message = e; _ } ->
          Alcotest.fail (Printf.sprintf "file_read failed: %s" e));
      (match
         Tool.execute shell_tool
           (`Assoc [ ("command", `String "echo telemetry-ok") ])
       with
      | Ok _ -> ()
      | Error { Agent_sdk.Types.message = e; _ } ->
          Alcotest.fail (Printf.sprintf "shell_exec failed: %s" e));
      let summary = Telemetry_eio.summarize_tool_usage ~fs config in
      let stats name =
        match Hashtbl.find_opt summary.stats_by_tool name with
        | Some stats -> stats
        | None -> Alcotest.fail ("missing telemetry stats for " ^ name)
      in
      Alcotest.(check int) "telemetry total calls" 3 summary.total_calls;
      Alcotest.(check int) "file_write count" 1 (stats "file_write").count;
      Alcotest.(check int) "file_read count" 1 (stats "file_read").count;
      Alcotest.(check int) "shell_exec count" 1 (stats "shell_exec").count;
      Sys.remove tmp_path)

let test_shell_exec_rejects_shell_metacharacters () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool
    (`Assoc [("command", `String "echo hello; pwd")]) in
  (match result with
   | Error { Agent_sdk.Types.message = msg; _ } ->
       let normalized = String.lowercase_ascii msg in
       (* The error message must mention "blocked" or "chaining" to confirm
          the right rejection path fired. *)
       let has_blocked = String_util.contains_substring_ci normalized "blocked" in
       let has_chaining = String_util.contains_substring_ci normalized "chaining" in
       Alcotest.(check bool) "mentions blocking guidance" true
         (has_blocked || has_chaining)
   | Ok _ -> Alcotest.fail "should reject shell metacharacters")

let test_shell_exec_nonexistent_cmd () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool
    (`Assoc [("command", `String "nonexistent_cmd_xyz_123")]) in
  (match result with
   | Error _ -> ()  (* expected: exit code != 0 *)
   | Ok _ -> Alcotest.fail "should fail for nonexistent command")

let test_shell_exec_missing_param () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool (`Assoc []) in
  (match result with
   | Error { Agent_sdk.Types.message = msg; _ } ->
     Alcotest.(check bool) "error about missing command" true
       (String.length msg > 0)
   | Ok _ -> Alcotest.fail "should fail without command param")

let test_readonly_shell_exec_blocks_git () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_readonly_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool
    (`Assoc [("command", `String "git status")]) in
  match result with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "readonly shell should block git"

let test_workdir_enforcement () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock
    ~workdir:"/tmp/test_workdir" () in
  let tool = find_tool "file_write" tools in
  (* Writing inside workdir should succeed *)
  let ok_path = "/tmp/test_workdir/test.txt" in
  let result_ok = Tool.execute tool
    (`Assoc [("path", `String ok_path);
             ("content", `String "ok")]) in
  (match result_ok with
   | Ok _ -> ()
   | Error { Agent_sdk.Types.message = e; _ } -> Alcotest.fail (Printf.sprintf "workdir write failed: %s" e));
  (* Writing outside workdir (but inside ~/me) should be blocked *)
  let home = Sys.getenv "HOME" in
  let bad_path = Filename.concat home "me/should_not_write.txt" in
  let result_bad = Tool.execute tool
    (`Assoc [("path", `String bad_path);
             ("content", `String "bad")]) in
  (match result_bad with
   | Error _ -> ()  (* expected: blocked by workdir enforcement *)
   | Ok _ -> Alcotest.fail "should block writes outside workdir");
  (* Cleanup *)
  (if Sys.file_exists ok_path then Sys.remove ok_path);
  (try Unix.rmdir "/tmp/test_workdir" with _ -> ())

(* --- Test runner --- *)

let () =
  Alcotest.run "Dev Tools" [
    "structure", [
      Alcotest.test_case "tool count" `Quick test_tool_count;
      Alcotest.test_case "tool names" `Quick test_tool_names;
      Alcotest.test_case "readonly tool names" `Quick test_readonly_tool_names;
    ];
    "file_read", [
      Alcotest.test_case "read existing file" `Quick test_file_read_existing;
      Alcotest.test_case "read nonexistent file" `Quick test_file_read_nonexistent;
      Alcotest.test_case "read blocked path" `Quick test_file_read_blocked_path;
      Alcotest.test_case "path traversal blocked" `Quick test_file_read_path_traversal;
      Alcotest.test_case "prefix sibling blocked" `Quick test_file_read_rejects_prefix_sibling;
      Alcotest.test_case "tmp symlink escape blocked" `Quick
        test_file_read_rejects_tmp_symlink_escape;
      Alcotest.test_case "read truncation 100KB" `Quick test_file_read_truncation;
    ];
    "file_write", [
      Alcotest.test_case "write new file" `Quick test_file_write_new;
      Alcotest.test_case "write blocked path" `Quick test_file_write_blocked_path;
      Alcotest.test_case "write prefix sibling blocked" `Quick
        test_file_write_rejects_prefix_sibling;
      Alcotest.test_case "write tmp symlink escape blocked" `Quick
        test_file_write_rejects_tmp_symlink_escape;
    ];
    "shell_exec", [
      Alcotest.test_case "echo hello" `Quick test_shell_exec_echo;
      Alcotest.test_case "blocked command" `Quick test_shell_exec_blocked_command;
      Alcotest.test_case "observer bridges to telemetry" `Quick
        test_tool_exec_observer_bridges_to_telemetry;
      Alcotest.test_case "reject shell metacharacters" `Quick
        test_shell_exec_rejects_shell_metacharacters;
      Alcotest.test_case "nonexistent command" `Quick test_shell_exec_nonexistent_cmd;
      Alcotest.test_case "missing param" `Quick test_shell_exec_missing_param;
      Alcotest.test_case "readonly shell blocks git" `Quick
        test_readonly_shell_exec_blocks_git;
    ];
    "workdir", [
      Alcotest.test_case "workdir enforcement" `Quick test_workdir_enforcement;
    ];
    "validate_command_coding", [
      Alcotest.test_case "allows pipe" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "git log | head -5" with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("should allow pipe: " ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "allows redirect" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "dune build 2>&1" with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("should allow redirect: " ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "blocks semicolon" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "ls; rm -rf /" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block semicolon");
      Alcotest.test_case "blocks backtick" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "echo `whoami`" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block backtick");
      Alcotest.test_case "blocks dollar" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "echo $HOME" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block dollar");
      Alcotest.test_case "validates first command in pipe" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "evil_cmd | head" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block unknown first command");
      Alcotest.test_case "blocks unknown command after pipe" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "git status | rm -rf /" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block unknown command after pipe");
      Alcotest.test_case "blocks ampersand chaining" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "git log && rm -rf /" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block && chaining");
      Alcotest.test_case "blocks double-pipe chaining" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "git status || rm -rf /" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block || chaining");
      Alcotest.test_case "blocks process substitution" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "git diff >(/tmp/out)" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block process substitution");
      Alcotest.test_case "blocks file output redirect" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "echo hi > /tmp/out.txt" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block file output redirect");
      Alcotest.test_case "blocks file input redirect" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "cat < /etc/passwd" with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should block file input redirect");
      Alcotest.test_case "allows 2>&1 redirect" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "dune test 2>&1" with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("should allow 2>&1: " ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "single-command contract rejects pipe" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding_with_allowlist
            ~allow_pipes:false
            ~allowed_commands:["dune"; "git"; "head"]
            "dune build 2>&1 | tail -5"
        with
        | Error Worker_dev_tools.Pipes_not_allowed -> ()
        | Error reason -> Alcotest.fail ("wrong rejection: " ^ Worker_dev_tools.block_reason_to_string reason)
        | Ok () -> Alcotest.fail "should reject pipe under single-command contract");
      Alcotest.test_case "single-command contract keeps redirect" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding_with_allowlist
            ~allow_pipes:false
            ~allowed_commands:["dune"; "git"; "head"]
            "dune build 2>&1"
        with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("should allow direct build with fd redirect: " ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "single-command contract enforces custom allowlist" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding_with_allowlist
            ~allow_pipes:false
            ~allowed_commands:["git"]
            "dune build"
        with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "should reject command outside custom allowlist");
    ];
    "is_destructive_bash_operation", [
      Alcotest.test_case "blocks force push" `Quick (fun () ->
        Alcotest.(check bool) "force push" true
          (Worker_dev_tools.is_destructive_bash_operation "git push --force"));
      Alcotest.test_case "blocks push -f" `Quick (fun () ->
        Alcotest.(check bool) "push -f" true
          (Worker_dev_tools.is_destructive_bash_operation "git push -f origin feature"));
      Alcotest.test_case "blocks push to main" `Quick (fun () ->
        Alcotest.(check bool) "push main" true
          (Worker_dev_tools.is_destructive_bash_operation "git push origin main"));
      Alcotest.test_case "blocks push to master" `Quick (fun () ->
        Alcotest.(check bool) "push master" true
          (Worker_dev_tools.is_destructive_bash_operation "git push origin master"));
      Alcotest.test_case "blocks push refspec to main" `Quick (fun () ->
        Alcotest.(check bool) "push refspec main" true
          (Worker_dev_tools.is_destructive_bash_operation "git push origin HEAD:main"));
      Alcotest.test_case "blocks push refs heads main" `Quick (fun () ->
        Alcotest.(check bool) "push refs/heads/main" true
          (Worker_dev_tools.is_destructive_bash_operation "git push origin refs/heads/main"));
      Alcotest.test_case "blocks force with lease" `Quick (fun () ->
        Alcotest.(check bool) "force with lease" true
          (Worker_dev_tools.is_destructive_bash_operation "git push --force-with-lease origin feature/fix-1"));
      Alcotest.test_case "allows push to feature branch" `Quick (fun () ->
        Alcotest.(check bool) "push feature" false
          (Worker_dev_tools.is_destructive_bash_operation "git push origin feature/fix-1"));
      Alcotest.test_case "blocks git reset --hard" `Quick (fun () ->
        Alcotest.(check bool) "reset hard" true
          (Worker_dev_tools.is_destructive_bash_operation "git reset --hard HEAD~1"));
      Alcotest.test_case "allows git reset (soft)" `Quick (fun () ->
        Alcotest.(check bool) "reset soft" false
          (Worker_dev_tools.is_destructive_bash_operation "git reset HEAD~1"));
      Alcotest.test_case "blocks rm -rf" `Quick (fun () ->
        Alcotest.(check bool) "rm -rf" true
          (Worker_dev_tools.is_destructive_bash_operation "rm -rf /"));
      Alcotest.test_case "blocks rm -fr" `Quick (fun () ->
        Alcotest.(check bool) "rm -fr" true
          (Worker_dev_tools.is_destructive_bash_operation "rm -fr build"));
      Alcotest.test_case "allows rm single file" `Quick (fun () ->
        Alcotest.(check bool) "rm single" false
          (Worker_dev_tools.is_destructive_bash_operation "rm foo.txt"));
      Alcotest.test_case "allows rm -f single file" `Quick (fun () ->
        Alcotest.(check bool) "rm -f single file" false
          (Worker_dev_tools.is_destructive_bash_operation "rm -f foo.txt"));
      Alcotest.test_case "allows rm -f report txt" `Quick (fun () ->
        Alcotest.(check bool) "rm -f report.txt" false
          (Worker_dev_tools.is_destructive_bash_operation "rm -f report.txt"));
      Alcotest.test_case "allows git commit" `Quick (fun () ->
        Alcotest.(check bool) "git commit" false
          (Worker_dev_tools.is_destructive_bash_operation "git commit -m 'fix'"));
    ];
    "gh_pr_merge_target", [
      Alcotest.test_case "extracts numeric pr id" `Quick (fun () ->
        Alcotest.(check (option string)) "numeric target" (Some "5934")
          (Worker_dev_tools.gh_pr_merge_target "pr merge 5934"));
      Alcotest.test_case "extracts explicit branch target" `Quick (fun () ->
        Alcotest.(check (option string)) "branch target" (Some "feature/review-gate")
          (Worker_dev_tools.gh_pr_merge_target "pr merge feature/review-gate"));
      Alcotest.test_case "extracts explicit url target" `Quick (fun () ->
        Alcotest.(check (option string)) "url target"
          (Some "https://github.com/jeong-sik/masc-mcp/pull/5934")
          (Worker_dev_tools.gh_pr_merge_target
             "pr merge https://github.com/jeong-sik/masc-mcp/pull/5934"));
      Alcotest.test_case "skips repo flag value" `Quick (fun () ->
        Alcotest.(check (option string)) "repo flag skipped" (Some "5934")
          (Worker_dev_tools.gh_pr_merge_target
             "pr merge --repo jeong-sik/masc-mcp 5934"));
      Alcotest.test_case "returns none for current branch merge" `Quick (fun () ->
        Alcotest.(check (option string)) "implicit current branch" None
          (Worker_dev_tools.gh_pr_merge_target "pr merge --squash --delete-branch"));
      Alcotest.test_case "skips match-head-commit value" `Quick (fun () ->
        Alcotest.(check (option string)) "match-head-commit skipped" (Some "5934")
          (Worker_dev_tools.gh_pr_merge_target
             "pr merge --match-head-commit abc123 5934"));
    ];
    "sanitize_command_for_log", [
      Alcotest.test_case "redacts url credentials" `Quick (fun () ->
        let redacted =
          Worker_dev_tools.sanitize_command_for_log
            "git remote set-url origin https://TOKEN@github.com/org/repo.git"
        in
        Alcotest.(check bool) "token removed" false
          (contains_substring redacted "TOKEN@");
        Alcotest.(check bool) "placeholder added" true
          (contains_substring redacted "[REDACTED]@"));
      Alcotest.test_case "redacts inline auth token assignment" `Quick (fun () ->
        let redacted =
          Worker_dev_tools.sanitize_command_for_log
            "npm config set //registry.npmjs.org/:_authToken=secret-token"
        in
        Alcotest.(check bool) "secret removed" false
          (contains_substring redacted "secret-token");
        Alcotest.(check bool) "marker preserved" true
          (contains_substring redacted ":_authToken=[REDACTED]"));
      Alcotest.test_case "redacts sensitive flag values" `Quick (fun () ->
        let redacted =
          Worker_dev_tools.sanitize_command_for_log
            "gh api --token secret-value /user"
        in
        Alcotest.(check bool) "secret removed" false
          (contains_substring redacted "secret-value");
        Alcotest.(check bool) "placeholder added" true
          (contains_substring redacted "--token [REDACTED]"));
    ];
    "validate_gh_command", [
      Alcotest.test_case "accepts allowed subcommand with no repo flag" `Quick (fun () ->
        match Worker_dev_tools.validate_gh_command "pr list --state open" with
        | Ok () -> ()
        | Error msg -> Alcotest.failf "expected ok, got %s" msg);
      Alcotest.test_case "rejects shell chaining" `Quick (fun () ->
        match Worker_dev_tools.validate_gh_command "pr list && echo done" with
        | Ok () -> Alcotest.fail "expected chaining to be blocked"
        | Error msg ->
          Alcotest.(check bool) "chaining message" true
            (contains_substring msg "chaining"));
      Alcotest.test_case "rejects unknown top-level command" `Quick (fun () ->
        match Worker_dev_tools.validate_gh_command "auth token" with
        | Ok () -> Alcotest.fail "expected unknown to be blocked"
        | Error msg ->
          Alcotest.(check bool) "not in approved" true
            (contains_substring msg "not in the approved"));
      Alcotest.test_case "rejects repo delete" `Quick (fun () ->
        match Worker_dev_tools.validate_gh_command "repo delete jeong-sik/foo" with
        | Ok () -> Alcotest.fail "expected repo delete blocked"
        | Error msg ->
          Alcotest.(check bool) "blocked for safety" true
            (contains_substring msg "blocked for safety"));
      Alcotest.test_case "rejects repo archive (parity with legacy guard)" `Quick (fun () ->
        match Worker_dev_tools.validate_gh_command "repo archive jeong-sik/foo" with
        | Ok () -> Alcotest.fail "expected archive blocked"
        | Error msg ->
          Alcotest.(check bool) "archive blocked" true
            (contains_substring msg "blocked for safety"));
      Alcotest.test_case "skips org check when allowed_orgs empty" `Quick (fun () ->
        match
          Worker_dev_tools.validate_gh_command ~allowed_orgs:[]
            "pr view --repo evil/repo 1"
        with
        | Ok () -> ()
        | Error msg -> Alcotest.failf "expected ok (empty orgs), got %s" msg);
      Alcotest.test_case "allows repo in allowed_orgs" `Quick (fun () ->
        match
          Worker_dev_tools.validate_gh_command ~allowed_orgs:["jeong-sik"]
            "pr view --repo jeong-sik/masc-mcp 123"
        with
        | Ok () -> ()
        | Error msg -> Alcotest.failf "expected ok, got %s" msg);
      Alcotest.test_case "rejects repo outside allowed_orgs" `Quick (fun () ->
        match
          Worker_dev_tools.validate_gh_command ~allowed_orgs:["jeong-sik"]
            "pr view --repo evil-org/payload 1"
        with
        | Ok () -> Alcotest.fail "expected org outside allowlist to be blocked"
        | Error msg ->
          Alcotest.(check bool) "mentions not in allowed_orgs" true
            (contains_substring msg "not in allowed_orgs");
          Alcotest.(check bool) "mentions offending owner" true
            (contains_substring msg "evil-org"));
      Alcotest.test_case "rejects --repo=OWNER/NAME form" `Quick (fun () ->
        match
          Worker_dev_tools.validate_gh_command ~allowed_orgs:["jeong-sik"]
            "pr view --repo=evil-org/payload 1"
        with
        | Ok () -> Alcotest.fail "expected --repo= form to be blocked"
        | Error msg ->
          Alcotest.(check bool) "blocked" true
            (contains_substring msg "not in allowed_orgs"));
      Alcotest.test_case "rejects -R short flag outside allowlist" `Quick (fun () ->
        match
          Worker_dev_tools.validate_gh_command ~allowed_orgs:["jeong-sik"]
            "issue list -R evil-org/payload"
        with
        | Ok () -> Alcotest.fail "expected -R form to be blocked"
        | Error msg ->
          Alcotest.(check bool) "blocked" true
            (contains_substring msg "not in allowed_orgs"));
      Alcotest.test_case "allows no --repo flag with orgs configured" `Quick (fun () ->
        match
          Worker_dev_tools.validate_gh_command ~allowed_orgs:["jeong-sik"]
            "pr list --state open"
        with
        | Ok () -> ()
        | Error msg -> Alcotest.failf "expected ok (no --repo), got %s" msg);
    ];
    "extract_gh_repo_owner", [
      Alcotest.test_case "extracts from --repo flag" `Quick (fun () ->
        Alcotest.(check (option string)) "owner" (Some "jeong-sik")
          (Worker_dev_tools.extract_gh_repo_owner
             "pr view --repo jeong-sik/masc-mcp 1"));
      Alcotest.test_case "extracts from --repo= form" `Quick (fun () ->
        Alcotest.(check (option string)) "owner" (Some "jeong-sik")
          (Worker_dev_tools.extract_gh_repo_owner
             "pr view --repo=jeong-sik/masc-mcp 1"));
      Alcotest.test_case "extracts from -R short flag" `Quick (fun () ->
        Alcotest.(check (option string)) "owner" (Some "jeong-sik")
          (Worker_dev_tools.extract_gh_repo_owner
             "issue list -R jeong-sik/masc-mcp"));
      Alcotest.test_case "returns None without --repo flag" `Quick (fun () ->
        Alcotest.(check (option string)) "no flag" None
          (Worker_dev_tools.extract_gh_repo_owner "pr list --state open"));
      Alcotest.test_case "returns None for malformed slug" `Quick (fun () ->
        Alcotest.(check (option string)) "no slash" None
          (Worker_dev_tools.extract_gh_repo_owner "pr view --repo malformed"));
    ];
    "classify_gh_reversibility", [
      (* R0 — read-only *)
      Alcotest.test_case "R0: pr list" `Quick (fun () ->
        Alcotest.(check bool) "R0" true
          (Worker_dev_tools.classify_gh_reversibility "pr list --state open"
           = Worker_dev_tools.R0_Read));
      Alcotest.test_case "R0: pr view 123" `Quick (fun () ->
        Alcotest.(check bool) "R0" true
          (Worker_dev_tools.classify_gh_reversibility "pr view 123"
           = Worker_dev_tools.R0_Read));
      Alcotest.test_case "R0: issue list" `Quick (fun () ->
        Alcotest.(check bool) "R0" true
          (Worker_dev_tools.classify_gh_reversibility "issue list --state all"
           = Worker_dev_tools.R0_Read));
      Alcotest.test_case "R0: api GET (default)" `Quick (fun () ->
        Alcotest.(check bool) "R0" true
          (Worker_dev_tools.classify_gh_reversibility "api repos/jeong-sik/foo"
           = Worker_dev_tools.R0_Read));
      Alcotest.test_case "R0: status" `Quick (fun () ->
        Alcotest.(check bool) "R0" true
          (Worker_dev_tools.classify_gh_reversibility "status"
           = Worker_dev_tools.R0_Read));
      Alcotest.test_case "R0: search issues" `Quick (fun () ->
        Alcotest.(check bool) "R0" true
          (Worker_dev_tools.classify_gh_reversibility "search issues --sort created"
           = Worker_dev_tools.R0_Read));

      (* R1 — reversible mutation *)
      Alcotest.test_case "R1: pr create" `Quick (fun () ->
        Alcotest.(check bool) "R1" true
          (Worker_dev_tools.classify_gh_reversibility
             "pr create --title foo --body bar"
           = Worker_dev_tools.R1_Reversible));
      Alcotest.test_case "R1: pr merge" `Quick (fun () ->
        Alcotest.(check bool) "R1" true
          (Worker_dev_tools.classify_gh_reversibility "pr merge 123 --squash"
           = Worker_dev_tools.R1_Reversible));
      Alcotest.test_case "R1: issue close" `Quick (fun () ->
        Alcotest.(check bool) "R1" true
          (Worker_dev_tools.classify_gh_reversibility "issue close 456"
           = Worker_dev_tools.R1_Reversible));
      Alcotest.test_case "R1: api --method POST" `Quick (fun () ->
        Alcotest.(check bool) "R1" true
          (Worker_dev_tools.classify_gh_reversibility
             "api --method POST repos/jeong-sik/foo/issues"
           = Worker_dev_tools.R1_Reversible));
      Alcotest.test_case "R1: api with -f field (implicit POST)" `Quick (fun () ->
        Alcotest.(check bool) "R1" true
          (Worker_dev_tools.classify_gh_reversibility
             "api repos/jeong-sik/foo/issues -f title=test"
           = Worker_dev_tools.R1_Reversible));
      Alcotest.test_case "R1: label create" `Quick (fun () ->
        Alcotest.(check bool) "R1" true
          (Worker_dev_tools.classify_gh_reversibility "label create bug --color red"
           = Worker_dev_tools.R1_Reversible));
      Alcotest.test_case "R1: run cancel" `Quick (fun () ->
        Alcotest.(check bool) "R1" true
          (Worker_dev_tools.classify_gh_reversibility "run cancel 42"
           = Worker_dev_tools.R1_Reversible));

      (* R2 — irreversible *)
      Alcotest.test_case "R2: repo delete" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "repo delete jeong-sik/foo"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: repo archive" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "repo archive jeong-sik/foo"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: repo transfer" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "repo transfer jeong-sik/foo x"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: release delete" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "release delete v1.0"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: secret delete" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "secret delete MY_TOKEN"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: ssh-key delete" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "ssh-key delete 42"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: workflow disable" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "workflow disable ci.yml"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: auth logout" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "auth logout"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: api --method DELETE" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility
             "api --method DELETE repos/jeong-sik/foo/issues/1"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: graphql mutation deletePullRequest" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility
             "api graphql -f query=mutation{deletePullRequest(input:{pullRequestId:abc}){clientMutationId}}"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: graphql mutation transferRepository" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility
             "api graphql -f query=mutation{transferRepository(input:{}){clientMutationId}}"
           = Worker_dev_tools.R2_Irreversible));
    ];
    "structured_tool_hint_for_r2", [
      Alcotest.test_case "repo delete → board-post hint" `Quick (fun () ->
        match Worker_dev_tools.structured_tool_hint_for_r2 "repo delete x/y" with
        | Some msg ->
          Alcotest.(check bool) "mentions operator" true
            (contains_substring msg "operator")
        | None -> Alcotest.fail "expected Some hint");
      Alcotest.test_case "credential op → operator-only hint" `Quick (fun () ->
        match Worker_dev_tools.structured_tool_hint_for_r2 "secret delete TOK" with
        | Some msg ->
          Alcotest.(check bool) "mentions operator-only" true
            (contains_substring msg "operator-only")
        | None -> Alcotest.fail "expected Some hint");
      Alcotest.test_case "api R2 → generic hint" `Quick (fun () ->
        match Worker_dev_tools.structured_tool_hint_for_r2
                "api --method DELETE repos/x/y/releases/1" with
        | Some msg ->
          Alcotest.(check bool) "mentions gh api" true
            (contains_substring msg "gh api")
        | None -> Alcotest.fail "expected Some hint");
      Alcotest.test_case "no hint for unmapped R2" `Quick (fun () ->
        Alcotest.(check (option string)) "none"
          None
          (Worker_dev_tools.structured_tool_hint_for_r2 "workflow disable x.yml"));
    ];
  ]
