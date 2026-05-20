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

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)

let rec cleanup_path path =
  if Sys.file_exists path then
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter
        (fun name -> cleanup_path (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
    | _ -> Sys.remove path

let registered_repo id local_path : Repo_manager_types.repository =
  { id
  ; name = id
  ; url = "https://github.com/example/" ^ id ^ ".git"
  ; local_path
  ; aliases = []
  ; default_branch = "main"
  ; credential_id = ""
  ; keepers = []
  ; status = Repo_manager_types.Active
  ; auto_sync = false
  ; sync_interval = 0
  ; created_at = 0L
  ; updated_at = 0L
  }

let with_registered_repo_fixture f =
  let base_path =
    Filename.concat
      (Sys.getcwd ())
      (Printf.sprintf "_worker_dev_tools_repo_mapping_%d" (Unix.getpid ()))
  in
  let workdir = Filename.temp_file "wdt_repo_mapping_cwd_" "" in
  Fun.protect
    ~finally:(fun () ->
      (try cleanup_path base_path with _ -> ());
      try cleanup_path workdir with _ -> ())
    (fun () ->
       if Sys.file_exists base_path then cleanup_path base_path;
       Sys.remove workdir;
       Unix.mkdir workdir 0o755;
       let repo_a_dir = Filename.concat base_path "repo-a" in
       let repo_b_dir = Filename.concat base_path "repo-b" in
       let target = Filename.concat repo_a_dir "lib/foo.ml" in
       ensure_dir (Filename.dirname target);
       ensure_dir repo_b_dir;
       ensure_dir workdir;
       (match
          Repo_store.save_all
            ~base_path
            [ registered_repo "repo-a" repo_a_dir
            ; registered_repo "repo-b" repo_b_dir
            ]
        with
        | Ok () -> ()
        | Error msg -> Alcotest.fail ("repo store setup failed: " ^ msg));
       let save_mapping keeper_id repository_ids =
         match
           Keeper_repo_mapping.save_mapping
             ~base_path
             { keeper_id; repository_ids; github_credential_id = None }
         with
         | Ok () -> ()
         | Error msg -> Alcotest.fail ("mapping setup failed: " ^ msg)
       in
       save_mapping "keeper-1" [ "repo-a" ];
       save_mapping "keeper-2" [ "repo-b" ];
       f ~base_path ~workdir ~target)

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
      let on_exec ~tool_name ~success ~duration_ms
          ?error_kind:_ ?error_message:_ () =
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

let test_shell_exec_respects_resource_gate () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Fun.protect
    ~finally:Tool_resource_gate.For_testing.reset
    (fun () ->
       Tool_resource_gate.For_testing.set_limits ~shell:1 ();
       with_env "MASC_TOOL_GATE_WAIT_TIMEOUT_SEC" "0.05" (fun () ->
         let blocker_started, unblock_blocker = Eio.Promise.create () in
         let release_blocker, resolve_release = Eio.Promise.create () in
         Eio.Fiber.both
           (fun () ->
              let result =
                Tool_resource_gate.with_permit
                  ~clock
                  ~tool_name:"keeper_bash"
                  ~arguments:(`Assoc [ "cmd", `String "sleep 1" ])
                  ~is_read_only:false
                  ~start_time:(Eio.Time.now clock)
                  (fun () ->
                     Eio.Promise.resolve unblock_blocker ();
                     Eio.Promise.await release_blocker;
                     Tool_result.quick_ok ~tool_name:"keeper_bash" "released")
              in
              Alcotest.(check bool) "blocker acquired shell lane" true result.success)
           (fun () ->
              Eio.Promise.await blocker_started;
              Fun.protect
                ~finally:(fun () -> Eio.Promise.resolve resolve_release ())
                (fun () ->
                   let tools = Worker_dev_tools.make_tools ~proc_mgr ~clock () in
                   let tool = find_tool "shell_exec" tools in
                   let result =
                     Tool.execute tool
                       (`Assoc [ "command", `String "echo gate-should-not-run" ])
                   in
                   match result with
                   | Error { Agent_sdk.Types.message = msg; recoverable; _ } ->
                     Alcotest.(check bool) "gate rejection is recoverable" true recoverable;
                     Alcotest.(check bool)
                       "message names resource gate saturation"
                       true
                       (contains_substring msg "tool_resource_gate_saturated");
                     Alcotest.(check bool)
                       "message names shell lane"
                       true
                       (contains_substring msg "class=shell")
                   | Ok { Agent_sdk.Types.content = output } ->
                     Alcotest.fail
                       (Printf.sprintf
                          "shell_exec bypassed saturated resource gate: %s"
                          output)))))

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
      Alcotest.test_case "resource gate saturation" `Quick
        test_shell_exec_respects_resource_gate;
    ];
    "workdir", [
      Alcotest.test_case "workdir enforcement" `Quick test_workdir_enforcement;
    ];
    "validate_command_coding", [
      Alcotest.test_case "allows pipe" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "git log | head -5" with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("should allow pipe: " ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "keeps escaped pipe inside quoted rg pattern" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding
            {|rg -n "task-259\|task-270\|task-272" repos/masc-mcp/.masc/backlog.json|}
        with
        | Ok () -> ()
        | Error e ->
          Alcotest.fail
            ("escaped regex pipe should not start a new command: "
             ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "keeps literal pipe inside single-quoted grep pattern"
        `Quick
        (fun () ->
          match
            Worker_dev_tools.validate_command_coding
              {|grep -E 'task-259|task-270' repos/masc-mcp/.masc/backlog.json|}
          with
          | Ok () -> ()
          | Error e ->
            Alcotest.fail
              ("quoted regex pipe should not start a new command: "
               ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "allows quoted regex alternation" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding
            "rg \"tool_policy\\|tool_preset\\|preset_policy\\|toolset\" --type=ml -l"
        with
        | Ok () -> ()
        | Error e ->
          Alcotest.fail
            ("should keep quoted regex alternation in the rg segment: "
             ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "allows quoted regex alternation before real pipe" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding
            "rg 'keeper.*tool|tool.*keeper' --type=ml -l | head -20"
        with
        | Ok () -> ()
        | Error e ->
          Alcotest.fail
            ("should split only the real pipeline: "
             ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "allows three-stage parsed pipeline" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding
            "rg 'keeper.*tool|tool.*keeper' --type=ml -l | head -20 | wc -l"
        with
        | Ok () -> ()
        | Error e ->
          Alcotest.fail
            ("should validate every parsed pipeline stage: "
             ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "allows wrapper redirect" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding
            "scripts/dune-local.sh build 2>&1"
        with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("should allow redirect: " ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "blocks parser-supported direct dune" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "dune build" with
        | Error Worker_dev_tools.Direct_dune_invocation -> ()
        | Error e -> Alcotest.fail ("wrong rejection: " ^ Worker_dev_tools.block_reason_to_string e)
        | Ok () -> Alcotest.fail "should reject bare dune");
      Alcotest.test_case "blocks direct dune" `Quick (fun () ->
        match Worker_dev_tools.validate_command_coding "dune build 2>&1" with
        | Error Worker_dev_tools.Direct_dune_invocation -> ()
        | Error e -> Alcotest.fail ("wrong rejection: " ^ Worker_dev_tools.block_reason_to_string e)
        | Ok () -> Alcotest.fail "should reject bare dune");
      Alcotest.test_case "blocks env-wrapped direct dune" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding
            "env DUNE_JOBS=1 dune build 2>&1"
        with
        | Error Worker_dev_tools.Direct_dune_invocation -> ()
        | Error e -> Alcotest.fail ("wrong rejection: " ^ Worker_dev_tools.block_reason_to_string e)
        | Ok () -> Alcotest.fail "should reject env-wrapped bare dune");
      Alcotest.test_case "blocks env option wrapped direct dune" `Quick (fun () ->
        List.iter
          (fun cmd ->
            match Worker_dev_tools.validate_command_coding cmd with
            | Error Worker_dev_tools.Direct_dune_invocation -> ()
            | Error e ->
              Alcotest.fail
                ("wrong rejection for " ^ cmd ^ ": "
                 ^ Worker_dev_tools.block_reason_to_string e)
            | Ok () -> Alcotest.fail ("should reject env-wrapped bare dune: " ^ cmd))
          [
            "env -- dune build";
            "env -C repos/masc-mcp dune build";
            "env --chdir repos/masc-mcp -- dune build";
            "env -i -- DUNE_JOBS=1 dune build";
          ]);
      Alcotest.test_case "blocks opam-exec direct dune" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding
            "opam exec -- dune build 2>&1"
        with
        | Error Worker_dev_tools.Direct_dune_invocation -> ()
        | Error e -> Alcotest.fail ("wrong rejection: " ^ Worker_dev_tools.block_reason_to_string e)
        | Ok () -> Alcotest.fail "should reject opam-exec bare dune");
      Alcotest.test_case "blocks opam exec option wrapped direct dune" `Quick (fun () ->
        List.iter
          (fun cmd ->
            match Worker_dev_tools.validate_command_coding cmd with
            | Error Worker_dev_tools.Direct_dune_invocation -> ()
            | Error e ->
              Alcotest.fail
                ("wrong rejection for " ^ cmd ^ ": "
                 ^ Worker_dev_tools.block_reason_to_string e)
            | Ok () -> Alcotest.fail ("should reject opam-exec bare dune: " ^ cmd))
          [
            "opam exec --switch default -- dune build";
            "opam exec --switch=default -- dune build";
            "opam exec --color never -- dune build";
          ]);
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
        match
          Worker_dev_tools.validate_command_coding
            "scripts/dune-local.sh test 2>&1"
        with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("should allow 2>&1: " ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "allows /dev/null fd sink through pipe" `Quick
        (fun () ->
           match
             Worker_dev_tools.validate_command_coding
               "rg \"task-317\" repos/masc-mcp/ --files-with-matches 2>/dev/null | head -5"
           with
           | Ok () -> ()
           | Error e ->
             Alcotest.fail
               ("should allow /dev/null sink: "
                ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "single-command contract rejects pipe" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding_with_allowlist
            ~allow_pipes:false
            ~allowed_commands:["dune-local.sh"; "git"; "head"]
            "scripts/dune-local.sh build 2>&1 | tail -5"
        with
        | Error Worker_dev_tools.Pipes_not_allowed -> ()
        | Error reason -> Alcotest.fail ("wrong rejection: " ^ Worker_dev_tools.block_reason_to_string reason)
        | Ok () -> Alcotest.fail "should reject pipe under single-command contract");
      Alcotest.test_case "single-command contract keeps redirect" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding_with_allowlist
            ~allow_pipes:false
            ~allowed_commands:["dune-local.sh"; "git"; "head"]
            "scripts/dune-local.sh build 2>&1"
        with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("should allow direct build with fd redirect: " ^ Worker_dev_tools.block_reason_to_string e));
      Alcotest.test_case "single-command contract enforces custom allowlist" `Quick (fun () ->
        match
          Worker_dev_tools.validate_command_coding_with_allowlist
            ~allow_pipes:false
            ~allowed_commands:["git"]
            "scripts/dune-local.sh build"
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
      Alcotest.test_case "rejects generic pr ready" `Quick (fun () ->
        match Worker_dev_tools.validate_gh_command "pr ready 123" with
        | Ok () -> Alcotest.fail "expected pr ready blocked"
        | Error msg ->
          Alcotest.(check bool) "ready blocked" true
            (contains_substring msg "blocked for safety"));
      Alcotest.test_case "rejects generic pr merge" `Quick (fun () ->
        match Worker_dev_tools.validate_gh_command "pr merge 123 --squash" with
        | Ok () -> Alcotest.fail "expected pr merge blocked"
        | Error msg ->
          Alcotest.(check bool) "merge blocked" true
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
      Alcotest.test_case "R2: pr merge" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "pr merge 123 --squash"
           = Worker_dev_tools.R2_Irreversible));
      Alcotest.test_case "R2: pr ready" `Quick (fun () ->
        Alcotest.(check bool) "R2" true
          (Worker_dev_tools.classify_gh_reversibility "pr ready 123"
           = Worker_dev_tools.R2_Irreversible));
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
    "validate_command_paths_redirect", [
      (* Field evidence (2026-04-17/18): 62 keeper_bash calls were rejected
         because the command mixed '/' paths with glob/brace/backslash/
         quote syntax. The terse rejection did not name the offending
         character or the correct tool, so small-LLM keepers retried the
         same pattern. Each new branch must point the keeper at the
         concrete replacement. *)
      Alcotest.test_case "content glob path suggests masc_code_search file_pattern"
        `Quick (fun () ->
          match Worker_dev_tools.validate_command_paths
                  ~workdir:"/tmp" "cat repos/*.ml" with
          | Error msg ->
            Alcotest.(check bool) "names glob char" true
              (contains_substring msg "Glob expansion");
            Alcotest.(check bool) "names masc_code_search" true
              (contains_substring msg "masc_code_search")
          | Ok () -> Alcotest.fail "content glob with path must be blocked");
      Alcotest.test_case "ls basename glob under workdir is allowed"
        `Quick (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "ls /tmp/repos/masc-mcp/.worktrees/keeper-sangsu-agent-task-238/lib/*.ml | head -30"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail ("safe ls glob unexpectedly rejected: " ^ msg));
      Alcotest.test_case "ls middle-segment glob is still blocked" `Quick
        (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "ls /tmp/repos/masc-mcp/.worktrees/*/lib/foo.ml"
          with
          | Error msg ->
            Alcotest.(check bool) "names glob char" true
              (contains_substring msg "Glob expansion")
          | Ok () -> Alcotest.fail "middle-segment glob must be blocked");
      Alcotest.test_case "brace path suggests per-target / rg" `Quick
        (fun () ->
          match Worker_dev_tools.validate_command_paths
                  ~workdir:"/tmp" "cat lib/{a,b}.ml" with
          | Error msg ->
            Alcotest.(check bool) "names brace" true
              (contains_substring msg "Brace expansion")
          | Ok () -> Alcotest.fail "brace with path must be blocked");
      Alcotest.test_case "regex pattern with backslash and path is allowed"
        `Quick (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "grep '\\.ml$' repos/"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail ("regex pattern unexpectedly rejected: " ^ msg));
      Alcotest.test_case "escaped path still names is_regex hint"
        `Quick (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "cat repos/foo\\ bar.ml"
          with
          | Error msg ->
            Alcotest.(check bool) "names escape" true
              (contains_substring msg "Backslash escaping");
            Alcotest.(check bool) "points at is_regex" true
              (contains_substring msg "is_regex")
          | Ok () -> Alcotest.fail "escaped path must be blocked");
      Alcotest.test_case "quoted path is still blocked" `Quick
        (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "cat 'repos/masc-mcp/lib/foo.ml'"
          with
          | Error msg ->
            Alcotest.(check bool) "names quote" true
              (contains_substring msg "Quoting")
          | Ok () -> Alcotest.fail "quoted path must be blocked");
      Alcotest.test_case "find -name glob pattern with path is allowed"
        `Quick (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "find repos/masc-mcp/.masc/config/keepers/ -type f -name '*.toml' 2>/dev/null"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail
              ("find -name pattern unexpectedly rejected: " ^ msg));
      Alcotest.test_case "rg quoted regex pattern with path is allowed"
        `Quick (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "rg \"Hashtbl\\.\" repos/masc-mcp/lib/ --count-matches -t ml"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail
              ("rg regex pattern unexpectedly rejected: " ^ msg));
      Alcotest.test_case "sed range script with path is allowed" `Quick
        (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "sed -n '1186,1190p' repos/masc-mcp/test/dune"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail
              ("sed range script unexpectedly rejected: " ^ msg));
      Alcotest.test_case "sed edit script with slash path is allowed" `Quick
        (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "sed -i '/include_file stanzas\\/test_ci_hardening_source.inc/d' repos/masc-mcp/test/dune"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail
              ("sed edit script unexpectedly rejected: " ^ msg));
      Alcotest.test_case "echo content redirect validates target only"
        `Quick (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "echo \"# Upload Canary Test\" > repos/masc-mcp/.worktrees/task/.canary-upload-test.md"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail
              ("echo redirect target unexpectedly rejected: " ^ msg));
      Alcotest.test_case "printf content redirect validates target only"
        `Quick (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "printf '%s\\n' 'content/with/slash' > repos/masc-mcp/.worktrees/task/file.ml"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail
              ("printf redirect target unexpectedly rejected: " ^ msg));
      Alcotest.test_case "quoted grep pattern after pipe is allowed" `Quick
        (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "cat .masc/backlog.json 2>/dev/null | grep -A5 'task-210'"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail
              ("quoted grep pattern unexpectedly rejected: " ^ msg));
      Alcotest.test_case "rg --glob quoted pattern through pipe is allowed"
        `Quick (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "rg -l \"awaiting_verification\" repos/masc-mcp/ --glob '*.json' 2>/dev/null | head -5"
          with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail
              ("rg --glob pipe command unexpectedly rejected: " ^ msg));
      Alcotest.test_case "rg --files validates path args" `Quick
        (fun () ->
          match
            Worker_dev_tools.validate_command_paths
              ~workdir:"/tmp"
              "rg --files /etc"
          with
          | Error msg ->
            Alcotest.(check bool) "outside path blocked" true
              (contains_substring msg "outside allowed directories")
          | Ok () -> Alcotest.fail "rg --files path must be validated");
      Alcotest.test_case "plain path with no rewrite syntax is allowed"
        `Quick (fun () ->
          match Worker_dev_tools.validate_command_paths
                  ~workdir:"/tmp" "cat lib/foo.ml" with
          | Ok () -> ()
          | Error msg ->
            Alcotest.fail ("plain path unexpectedly rejected: " ^ msg));
      Alcotest.test_case
        "absolute own-repo path is allowed from repo worktree cwd"
        `Quick
        (fun () ->
          let repo_root =
            Filename.concat
              (Sys.getcwd ())
              "_worker_dev_tools_repo_worktree_allow"
          in
          let target = Filename.concat repo_root "lib/foo.ml" in
          let workdir = Filename.concat repo_root ".worktrees/task" in
          let rec mkdir_p path =
            if path = "" || path = "." || path = "/" then ()
            else if Sys.file_exists path then ()
            else (
              mkdir_p (Filename.dirname path);
              Unix.mkdir path 0o755)
          in
          let rec cleanup path =
            if Sys.file_exists path then
              match Unix.lstat path with
              | { Unix.st_kind = Unix.S_DIR; _ } ->
                Array.iter
                  (fun name -> cleanup (Filename.concat path name))
                  (Sys.readdir path);
                Unix.rmdir path
              | _ -> Sys.remove path
          in
          Fun.protect
            ~finally:(fun () -> try cleanup repo_root with _ -> ())
            (fun () ->
              mkdir_p (Filename.dirname target);
              mkdir_p workdir;
              Out_channel.with_open_text (Filename.concat repo_root ".git")
                (fun oc -> output_string oc "gitdir: .git/worktrees/task\n");
              Out_channel.with_open_text target
                (fun oc -> output_string oc "let x = 1\n");
              match
                Worker_dev_tools.validate_command_paths
                  ~workdir
                  (Printf.sprintf "cat %s" target)
              with
              | Ok () -> ()
              | Error msg ->
                Alcotest.fail
                  ("own repo path from worktree cwd rejected: " ^ msg)));
      Alcotest.test_case
        "registered repo path is blocked without keeper context"
        `Quick
        (fun () ->
          with_registered_repo_fixture
            (fun ~base_path:_ ~workdir ~target ->
               match
                 Worker_dev_tools.validate_command_paths
                   ~workdir
                   (Printf.sprintf "cat %s" target)
               with
               | Error msg ->
                 Alcotest.(check bool)
                   "outside path blocked"
                   true
                   (contains_substring msg "outside allowed directories")
               | Ok () ->
                 Alcotest.fail
                   "registered repo path must still need keeper context"));
      Alcotest.test_case
        "registered repo path is allowed for mapped keeper"
        `Quick
        (fun () ->
          with_registered_repo_fixture
            (fun ~base_path ~workdir ~target ->
               match
                 Worker_dev_tools.validate_command_paths
                   ~keeper_id:"keeper-1"
                   ~base_path
                   ~workdir
                   (Printf.sprintf "cat %s" target)
               with
               | Ok () -> ()
               | Error msg ->
                 Alcotest.fail ("mapped repo path rejected: " ^ msg)));
      Alcotest.test_case
        "registered repo path is denied for mismatched keeper mapping"
        `Quick
        (fun () ->
          with_registered_repo_fixture
            (fun ~base_path ~workdir ~target ->
               match
                 Worker_dev_tools.validate_command_paths
                   ~keeper_id:"keeper-2"
                   ~base_path
                   ~workdir
                   (Printf.sprintf "cat %s" target)
               with
               | Error msg ->
                 Alcotest.(check bool)
                   "outside path blocked"
                   true
                   (contains_substring msg "outside allowed directories")
               | Ok () ->
                 Alcotest.fail "unmapped keeper must not inherit repo path access"));
      Alcotest.test_case "git -C missing worktree is cwd_not_directory"
        `Quick (fun () ->
          let workdir = Filename.temp_file "wdt_git_c_" "" in
          Sys.remove workdir;
          Unix.mkdir workdir 0o755;
          Fun.protect
            ~finally:(fun () -> try Unix.rmdir workdir with _ -> ())
            (fun () ->
              match
                Worker_dev_tools.validate_command_paths
                  ~workdir
                  "git -C repos/masc-mcp/.worktrees/missing status"
              with
              | Error msg ->
                Alcotest.(check bool)
                  "typed cwd error"
                  true
                  (contains_substring msg "cwd_not_directory")
              | Ok () -> Alcotest.fail "missing git -C directory must be blocked"));
      Alcotest.test_case "git -C existing worktree is allowed" `Quick
        (fun () ->
          let workdir = Filename.temp_file "wdt_git_c_ok_" "" in
          Sys.remove workdir;
          let target =
            Filename.concat workdir "repos/masc-mcp/.worktrees/task"
          in
          let rec mkdir_p path =
            if path = "" || path = "." || path = "/" then ()
            else if Sys.file_exists path then ()
            else (
              mkdir_p (Filename.dirname path);
              Unix.mkdir path 0o755)
          in
          mkdir_p target;
          let rec cleanup path =
            if Sys.file_exists path then
              match Unix.lstat path with
              | { Unix.st_kind = Unix.S_DIR; _ } ->
                Array.iter
                  (fun name -> cleanup (Filename.concat path name))
                  (Sys.readdir path);
                Unix.rmdir path
              | _ -> Sys.remove path
          in
          Fun.protect
            ~finally:(fun () -> try cleanup workdir with _ -> ())
            (fun () ->
              match
                Worker_dev_tools.validate_command_paths
                  ~workdir
                  "git -C repos/masc-mcp/.worktrees/task status"
              with
              | Ok () -> ()
              | Error msg ->
                Alcotest.fail ("existing git -C directory rejected: " ^ msg)));
    ];
    "command_blocked_hint_redirects", [
      (* Field evidence (2026-04-17/18): keeper_bash rejected `gh`, `docker`,
         `kubectl`, `ssh` calls with no redirect hint, which kept small-LLM
         keepers retrying the same blocked command. The new branches return a
         concrete alternative tool or an escalation path. *)
      Alcotest.test_case "gh → keeper_pr_* redirect" `Quick (fun () ->
        let msg =
          Worker_dev_tools.block_reason_to_string
            (Worker_dev_tools.Command_not_allowed "gh")
        in
        Alcotest.(check bool) "mentions keeper_pr_*" true
          (contains_substring msg "keeper_pr_");
        Alcotest.(check bool) "mentions masc_board_" true
          (contains_substring msg "masc_board_"));
      Alcotest.test_case "docker → escalation hint" `Quick (fun () ->
        let msg =
          Worker_dev_tools.block_reason_to_string
            (Worker_dev_tools.Command_not_allowed "docker")
        in
        Alcotest.(check bool) "mentions escalation via masc_board_post" true
          (contains_substring msg "masc_board_post"));
      Alcotest.test_case "ssh → network-primitive hint" `Quick (fun () ->
        let msg =
          Worker_dev_tools.block_reason_to_string
            (Worker_dev_tools.Command_not_allowed "ssh")
        in
        Alcotest.(check bool) "mentions masc_web_search" true
          (contains_substring msg "masc_web_search"));
      Alcotest.test_case "unknown command still gets keeper_tools_list pointer" `Quick (fun () ->
        let msg =
          Worker_dev_tools.block_reason_to_string
            (Worker_dev_tools.Command_not_allowed "xyzzy")
        in
        Alcotest.(check bool) "mentions keeper_tools_list" true
          (contains_substring msg "keeper_tools_list"));
      Alcotest.test_case "preserves existing source-code heuristic" `Quick (fun () ->
        let msg =
          Worker_dev_tools.block_reason_to_string
            (Worker_dev_tools.Command_not_allowed "Foo.bar")
        in
        Alcotest.(check bool) "still suggests masc_code_edit for A.B names"
          true
          (contains_substring msg "masc_code_"));
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
    "attribution", [
      Alcotest.test_case "Ok () → Passed with cmd in evidence" `Quick (fun () ->
        let attr =
          Worker_dev_tools.attribution_of_validation ~cmd:"ls -la" (Ok ())
        in
        Alcotest.(check string) "gate" "worker_dev_tools" attr.gate;
        Alcotest.(check bool) "origin=Det" true
          (attr.origin = Attribution.Det);
        Alcotest.(check bool) "outcome=Passed" true
          (match attr.outcome with Attribution.Passed -> true | _ -> false));
      Alcotest.test_case "Empty_command → Policy_failed" `Quick (fun () ->
        let attr =
          Worker_dev_tools.attribution_of_validation ~cmd:""
            (Error Worker_dev_tools.Empty_command)
        in
        match attr.outcome with
        | Attribution.Policy_failed { reason } ->
          Alcotest.(check bool) "reason mentions empty" true
            (contains_substring reason "empty")
        | _ -> Alcotest.fail "expected Policy_failed");
      Alcotest.test_case "Command_not_allowed carries command_name in evidence"
        `Quick (fun () ->
        let attr =
          Worker_dev_tools.attribution_of_validation
            ~cmd:"rm -rf /"
            (Error (Worker_dev_tools.Command_not_allowed "rm"))
        in
        match attr.evidence with
        | `Assoc fields ->
          Alcotest.(check (option string)) "command_name=rm"
            (Some "rm")
            (match List.assoc_opt "command_name" fields with
             | Some (`String s) -> Some s
             | _ -> None);
          Alcotest.(check (option string)) "block_reason tag"
            (Some "command_not_allowed")
            (match List.assoc_opt "block_reason" fields with
             | Some (`String s) -> Some s
             | _ -> None)
        | _ -> Alcotest.fail "evidence must be object");
      Alcotest.test_case "all 8 block_reason variants → Policy_failed" `Quick
        (fun () ->
        let variants =
          [
            Worker_dev_tools.Empty_command;
            Worker_dev_tools.Chain_or_redirect;
            Worker_dev_tools.Injection;
            Worker_dev_tools.Process_substitution;
            Worker_dev_tools.Unsafe_redirect;
            Worker_dev_tools.Pipes_not_allowed;
            Worker_dev_tools.Direct_dune_invocation;
            Worker_dev_tools.Command_not_allowed "foo";
          ]
        in
        List.iter (fun br ->
          let attr =
            Worker_dev_tools.attribution_of_validation ~cmd:"test"
              (Error br)
          in
          Alcotest.(check bool) "always Policy_failed" true
            (match attr.outcome with
             | Attribution.Policy_failed _ -> true
             | _ -> false)
        ) variants);
    ];
  ]
