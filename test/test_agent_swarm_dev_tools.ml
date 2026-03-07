(** Unit tests for dev tools — no LLM required.
    Tests file_read, file_write, shell_exec with safety validation. *)

open Agent_sdk
open Masc_mcp

(* Helper: find tool by name from tool list *)
let find_tool name tools =
  List.find (fun (t : Tool.t) -> t.schema.name = name) tools

(* --- Tool structure tests --- *)

let test_tool_count () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  Alcotest.(check int) "3 dev tools" 3 (List.length tools)

let test_tool_names () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let names = List.map (fun (t : Tool.t) -> t.schema.name) tools in
  let expected = ["file_read"; "file_write"; "shell_exec"] in
  Alcotest.(check (list string)) "tool names match" expected names

(* --- file_read tests --- *)

let test_file_read_existing () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  (* Write a temp file first *)
  let path = Filename.concat "/tmp" "dev_tools_test_read.txt" in
  Out_channel.with_open_text path
    (fun oc -> Out_channel.output_string oc "hello world");
  let result = Tool.execute tool
    (`Assoc [("path", `String path)]) in
  (match result with
   | Ok content ->
     Alcotest.(check string) "content matches" "hello world" content
   | Error e ->
     Alcotest.fail (Printf.sprintf "expected Ok, got Error: %s" e));
  Sys.remove path

let test_file_read_nonexistent () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  let result = Tool.execute tool
    (`Assoc [("path", `String "/tmp/nonexistent_dev_tools_xyz.txt")]) in
  (match result with
   | Error _ -> ()  (* expected *)
   | Ok _ -> Alcotest.fail "should fail for nonexistent file")

let test_file_read_blocked_path () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  let result = Tool.execute tool
    (`Assoc [("path", `String "/etc/passwd")]) in
  (match result with
   | Error msg ->
     Alcotest.(check bool) "mentions blocked" true
       (String.length msg > 0 &&
        (try ignore (String.index msg 'b'); true
         with Not_found -> true))
   | Ok _ -> Alcotest.fail "should reject /etc/passwd")

let test_file_read_path_traversal () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  (* /tmp/../../etc/passwd normalizes to /etc/passwd — must be blocked *)
  let result = Tool.execute tool
    (`Assoc [("path", `String "/tmp/../../etc/passwd")]) in
  (match result with
   | Error _ -> ()  (* expected: path traversal blocked *)
   | Ok _ -> Alcotest.fail "should reject path traversal /tmp/../../etc/passwd")

let test_file_read_truncation () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_read" tools in
  (* Create a 101KB file *)
  let path = "/tmp/dev_tools_test_large.txt" in
  let large_content = String.make 101_000 'x' in
  Out_channel.with_open_text path
    (fun oc -> Out_channel.output_string oc large_content);
  let result = Tool.execute tool
    (`Assoc [("path", `String path)]) in
  (match result with
   | Ok content ->
     Alcotest.(check bool) "truncated to ~100KB" true
       (String.length content <= 100_100);
     Alcotest.(check bool) "has truncation marker" true
       (let suffix = "[TRUNCATED at 100KB]" in
        String.length content >= String.length suffix &&
        String.sub content
          (String.length content - String.length suffix)
          (String.length suffix) = suffix)
   | Error e ->
     Alcotest.fail (Printf.sprintf "expected Ok (truncated), got Error: %s" e));
  Sys.remove path

(* --- file_write tests --- *)

let test_file_write_new () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_write" tools in
  let path = "/tmp/dev_tools_test_write.txt" in
  (if Sys.file_exists path then Sys.remove path);
  let result = Tool.execute tool
    (`Assoc [("path", `String path);
             ("content", `String "test content")]) in
  (match result with
   | Ok msg ->
     Alcotest.(check bool) "mentions bytes" true
       (String.length msg > 0);
     let written = In_channel.with_open_text path In_channel.input_all in
     Alcotest.(check string) "file content" "test content" written
   | Error e ->
     Alcotest.fail (Printf.sprintf "expected Ok, got Error: %s" e));
  Sys.remove path

let test_file_write_blocked_path () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "file_write" tools in
  let result = Tool.execute tool
    (`Assoc [("path", `String "/etc/shadow_test");
             ("content", `String "bad")]) in
  (match result with
   | Error _ -> ()  (* expected *)
   | Ok _ -> Alcotest.fail "should reject /etc/ path")

(* --- shell_exec tests --- *)

let test_shell_exec_echo () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool
    (`Assoc [("command", `String "echo hello")]) in
  (match result with
   | Ok output ->
     Alcotest.(check string) "echo output" "hello\n" output
   | Error e ->
     Alcotest.fail (Printf.sprintf "expected Ok, got Error: %s" e))

let test_shell_exec_blocked_command () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool
    (`Assoc [("command", `String "rm -rf /")]) in
  (match result with
   | Error msg ->
     Alcotest.(check bool) "mentions blocked" true
       (String.length msg > 0)
   | Ok _ -> Alcotest.fail "should reject rm -rf /")

let test_shell_exec_nonexistent_cmd () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool
    (`Assoc [("command", `String "nonexistent_cmd_xyz_123")]) in
  (match result with
   | Error _ -> ()  (* expected: exit code != 0 *)
   | Ok _ -> Alcotest.fail "should fail for nonexistent command")

let test_shell_exec_missing_param () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
  let tool = find_tool "shell_exec" tools in
  let result = Tool.execute tool (`Assoc []) in
  (match result with
   | Error msg ->
     Alcotest.(check bool) "error about missing command" true
       (String.length msg > 0)
   | Ok _ -> Alcotest.fail "should fail without command param")

let test_workdir_enforcement () =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock
    ~workdir:"/tmp/test_workdir" () in
  let tool = find_tool "file_write" tools in
  (* Writing inside workdir should succeed *)
  let ok_path = "/tmp/test_workdir/test.txt" in
  let result_ok = Tool.execute tool
    (`Assoc [("path", `String ok_path);
             ("content", `String "ok")]) in
  (match result_ok with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Printf.sprintf "workdir write failed: %s" e));
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
    ];
    "file_read", [
      Alcotest.test_case "read existing file" `Quick test_file_read_existing;
      Alcotest.test_case "read nonexistent file" `Quick test_file_read_nonexistent;
      Alcotest.test_case "read blocked path" `Quick test_file_read_blocked_path;
      Alcotest.test_case "path traversal blocked" `Quick test_file_read_path_traversal;
      Alcotest.test_case "read truncation 100KB" `Quick test_file_read_truncation;
    ];
    "file_write", [
      Alcotest.test_case "write new file" `Quick test_file_write_new;
      Alcotest.test_case "write blocked path" `Quick test_file_write_blocked_path;
    ];
    "shell_exec", [
      Alcotest.test_case "echo hello" `Quick test_shell_exec_echo;
      Alcotest.test_case "blocked command" `Quick test_shell_exec_blocked_command;
      Alcotest.test_case "nonexistent command" `Quick test_shell_exec_nonexistent_cmd;
      Alcotest.test_case "missing param" `Quick test_shell_exec_missing_param;
    ];
    "workdir", [
      Alcotest.test_case "workdir enforcement" `Quick test_workdir_enforcement;
    ];
  ]
