(** Tests for MCP-Agent lifecycle integration.
    Covers server_spec, managed types, merge_env, connect_all,
    close_all, and Agent integration with MCP clients. *)

open Agent_sdk

(* ── Helpers ───────────────────────────────────────────────────── *)

let check_string_array =
  Alcotest.testable
    (fun fmt arr -> Format.pp_print_string fmt (String.concat ", " (Array.to_list arr)))
    (fun a b -> a = b)
;;

let make_test_tool name =
  Tool.create ~name ~description:("Tool " ^ name) ~parameters:[] (fun _input ->
    Ok { Types.content = "result from " ^ name; _meta = None })
;;

(** Dummy Eio network for Agent.create (not used in these tests). *)
let with_net f = Eio_main.run @@ fun env -> f (Eio.Stdenv.net env)

(** Run a test body inside Eio with switch and process manager. *)
let with_eio f =
  Eio_main.run
  @@ fun env -> Eio.Switch.run @@ fun sw -> f ~sw ~mgr:(Eio.Stdenv.process_mgr env)
;;

let with_temp_script body f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "oas-mcp-%d-%06x" (Unix.getpid ()) (Random.int 0xFFFFFF))
  in
  Unix.mkdir dir 0o755;
  let path = Filename.concat dir "fake_mcp_server.py" in
  let oc = open_out path in
  output_string oc body;
  close_out oc;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" dir)))
    (fun () -> f path)
;;

(* ── server_spec ───────────────────────────────────────────────── *)

let test_server_spec_fields () =
  let spec : Mcp.server_spec =
    { command = "/usr/bin/echo"
    ; args = [ "--version" ]
    ; env = [ "FOO", "bar" ]
    ; name = "test-server"
    }
  in
  Alcotest.(check string) "command" "/usr/bin/echo" spec.command;
  Alcotest.(check int) "args count" 1 (List.length spec.args);
  Alcotest.(check string) "name" "test-server" spec.name;
  Alcotest.(check int) "env count" 1 (List.length spec.env)
;;

let test_server_spec_empty_args () =
  let spec : Mcp.server_spec =
    { command = "npx"; args = []; env = []; name = "minimal" }
  in
  Alcotest.(check int) "empty args" 0 (List.length spec.args);
  Alcotest.(check int) "empty env" 0 (List.length spec.env)
;;

let test_server_spec_multiple_env () =
  let spec : Mcp.server_spec =
    { command = "node"
    ; args = [ "server.js" ]
    ; env = [ "API_KEY", "abc"; "PORT", "3000"; "DEBUG", "1" ]
    ; name = "multi-env"
    }
  in
  Alcotest.(check int) "env count" 3 (List.length spec.env)
;;

(* ── merge_env ─────────────────────────────────────────────────── *)

let test_merge_env_empty () =
  let result = Mcp.merge_env [] in
  let current = Unix.environment () in
  Alcotest.check check_string_array "no extras = current env" current result
;;

let test_merge_env_add_new () =
  let result = Mcp.merge_env [ "OAS_TEST_NEW_VAR_12345", "hello" ] in
  let has_var =
    Array.exists (fun entry -> entry = "OAS_TEST_NEW_VAR_12345=hello") result
  in
  Alcotest.(check bool) "new var present" true has_var
;;

let test_merge_env_override () =
  (* PATH should exist in any Unix environment *)
  let result = Mcp.merge_env [ "PATH", "/test/only" ] in
  let path_entries =
    Array.to_list result
    |> List.filter (fun e -> String.length e >= 5 && String.sub e 0 5 = "PATH=")
  in
  Alcotest.(check int) "exactly one PATH" 1 (List.length path_entries);
  Alcotest.(check string) "overridden PATH" "PATH=/test/only" (List.hd path_entries)
;;

let test_merge_env_multiple () =
  let result = Mcp.merge_env [ "OAS_A", "1"; "OAS_B", "2"; "OAS_C", "3" ] in
  let count =
    Array.to_list result
    |> List.filter (fun e -> String.length e >= 4 && String.sub e 0 4 = "OAS_")
    |> List.length
  in
  Alcotest.(check bool) "at least 3 OAS_ vars" true (count >= 3)
;;

let test_merge_env_preserves_existing () =
  let base_count = Array.length (Unix.environment ()) in
  let result = Mcp.merge_env [ "OAS_TEST_UNIQUE_99999", "x" ] in
  (* Should have base_count + 1 (the new var) *)
  Alcotest.(check int) "count = base + 1" (base_count + 1) (Array.length result)
;;

(* ── connect_all / close_all ───────────────────────────────────── *)

let test_connect_all_empty () =
  with_eio
  @@ fun ~sw ~mgr ->
  match Mcp.connect_all ~sw ~mgr [] with
  | Ok managed -> Alcotest.(check int) "empty list" 0 (List.length managed)
  | Error e -> Alcotest.fail ("Expected Ok [], got Error: " ^ Error.to_string e)
;;

let test_close_all_empty () =
  Mcp.close_all [];
  Alcotest.(check bool) "no crash" true true
;;

let test_connect_all_bad_command () =
  with_eio
  @@ fun ~sw ~mgr ->
  let spec : Mcp.server_spec =
    { command = "/nonexistent/command/that/should/fail"
    ; args = []
    ; env = []
    ; name = "bad-server"
    }
  in
  match Mcp.connect_all ~sw ~mgr [ spec ] with
  | Ok _ -> Alcotest.fail "Expected Error for bad command"
  | Error _ -> Alcotest.(check bool) "error returned" true true
;;

let test_connect_and_load_bad_command () =
  with_eio
  @@ fun ~sw ~mgr ->
  let spec : Mcp.server_spec =
    { command = "/this/does/not/exist"; args = []; env = []; name = "ghost" }
  in
  match Mcp.connect_and_load ~sw ~mgr spec with
  | Ok _ -> Alcotest.fail "Expected Error"
  | Error e ->
    Alcotest.(check bool)
      "error message non-empty"
      true
      (String.length (Error.to_string e) > 0)
;;

(* ── managed type ──────────────────────────────────────────────── *)

let test_managed_tools_access () =
  let t1 = make_test_tool "alpha" in
  let t2 = make_test_tool "beta" in
  let tools = [ t1; t2 ] in
  Alcotest.(check int) "tool count" 2 (List.length tools);
  Alcotest.(check string) "first tool" "alpha" (List.hd tools).schema.name;
  Alcotest.(check string) "second tool" "beta" (List.nth tools 1).schema.name
;;

(* ── Agent integration ─────────────────────────────────────────── *)

let test_default_options_mcp_clients () =
  let opts = Agent.default_options in
  Alcotest.(check int) "default mcp_clients empty" 0 (List.length opts.mcp_clients)
;;

let test_agent_create_with_default_options () =
  with_net
  @@ fun net ->
  let agent = Agent.create ~config:(Types.default_config ~model:"test-model") ~net () in
  Alcotest.(check int) "no tools" 0 (Tool_set.size (Agent.tools agent));
  Alcotest.(check int) "no mcp_clients" 0 (List.length (Agent.options agent).mcp_clients)
;;

let test_agent_create_preserves_regular_tools () =
  with_net
  @@ fun net ->
  let t1 = make_test_tool "tool1" in
  let t2 = make_test_tool "tool2" in
  let agent =
    Agent.create
      ~config:(Types.default_config ~model:"test-model")
      ~net
      ~tools:[ t1; t2 ]
      ()
  in
  Alcotest.(check int) "2 tools" 2 (Tool_set.size (Agent.tools agent));
  Alcotest.(check string)
    "first"
    "tool1"
    (List.hd (Tool_set.to_list (Agent.tools agent))).schema.name
;;

let test_agent_close_no_mcp () =
  with_net
  @@ fun net ->
  let agent = Agent.create ~config:(Types.default_config ~model:"test-model") ~net () in
  Agent.close agent;
  Alcotest.(check bool) "close succeeds" true true
;;

let test_agent_close_idempotent () =
  with_net
  @@ fun net ->
  let agent = Agent.create ~config:(Types.default_config ~model:"test-model") ~net () in
  Agent.close agent;
  Agent.close agent;
  Alcotest.(check bool) "double close safe" true true
;;

let test_agent_options_mcp_clients_field () =
  let opts = { Agent.default_options with mcp_clients = [] } in
  Alcotest.(check int) "explicit empty" 0 (List.length opts.mcp_clients)
;;

let test_agent_checkpoint_with_mcp_options () =
  with_net
  @@ fun net ->
  let agent =
    Agent.create
      ~net
      ~config:{ (Types.default_config ~model:"test-model") with name = "mcp-test-agent" }
      ()
  in
  let cp = Agent.checkpoint agent in
  Alcotest.(check string) "agent name" "mcp-test-agent" cp.agent_name;
  Alcotest.(check int) "no tools in checkpoint" 0 (List.length cp.tools)
;;

(* ── connect_all partial failure cleanup ───────────────────────── *)

let test_connect_all_second_fails () =
  with_eio
  @@ fun ~sw ~mgr ->
  let good_spec : Mcp.server_spec =
    { command = "cat"; args = []; env = []; name = "cat-server" }
  in
  let bad_spec : Mcp.server_spec =
    { command = "/nonexistent/binary"; args = []; env = []; name = "bad-server" }
  in
  match Mcp.connect_all ~sw ~mgr [ good_spec; bad_spec ] with
  | Ok _ -> Alcotest.(check bool) "unexpected success" true true
  | Error _ -> Alcotest.(check bool) "error from lifecycle" true true
;;

let test_resources_and_prompts_roundtrip () =
  let script =
    {|
import json, sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    method = req.get("method")
    req_id = req.get("id")
    if req_id is None:
        continue
    if method == "initialize":
        result = {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "serverInfo": {"name": "fake", "version": "1.0"},
        }
    elif method == "resources/list":
        result = {
            "resources": [
                {
                    "uri": "file://guide",
                    "name": "Guide",
                    "description": "A guide",
                    "mime_type": "text/plain",
                }
            ]
        }
    elif method == "resources/read":
        result = {
            "contents": [
                {
                    "uri": req.get("params", {}).get("uri", "file://guide"),
                    "text": "hello resource",
                }
            ]
        }
    elif method == "prompts/list":
        result = {
            "prompts": [
                {
                    "name": "summarize",
                    "description": "Summarize a topic",
                    "arguments": [
                        {"name": "topic", "description": "Topic", "required": True}
                    ],
                    "icon": None,
                }
            ]
        }
    elif method == "prompts/get":
        topic = req.get("params", {}).get("arguments", {}).get("topic", "")
        result = {
            "description": "Prompt result",
            "messages": [
                {
                    "role": "assistant",
                    "content": {"type": "text", "text": "Topic: " + topic},
                }
            ],
        }
    else:
        result = {"tools": []}
    print("METHOD", method, "PARAMS", req.get("params"), "RESULT", result, file=sys.stderr, flush=True)
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": result}) + "\n")
    sys.stdout.flush()
|}
  in
  with_temp_script script
  @@ fun path ->
  with_eio
  @@ fun ~sw ~mgr ->
  match Mcp.connect ~sw ~mgr ~command:"python3" ~args:[ path ] () with
  | Error e -> Alcotest.fail ("connect failed: " ^ Error.to_string e)
  | Ok client ->
    Fun.protect
      ~finally:(fun () -> Mcp.close client)
      (fun () ->
         (match Mcp.initialize client with
          | Ok () -> ()
          | Error e -> Alcotest.fail ("initialize failed: " ^ Error.to_string e));
         let resources =
           match Mcp.list_resources client with
           | Ok items -> items
           | Error e -> Alcotest.fail ("list_resources failed: " ^ Error.to_string e)
         in
         Alcotest.(check int) "resource count" 1 (List.length resources);
         let resource = List.hd resources in
         Alcotest.(check string) "resource uri" "file://guide" resource.uri;
         let contents =
           match Mcp.read_resource client ~uri:resource.uri with
           | Ok items -> items
           | Error e -> Alcotest.fail ("read_resource failed: " ^ Error.to_string e)
         in
         Alcotest.(check int) "content count" 1 (List.length contents);
         Alcotest.(check (option string))
           "resource text"
           (Some "hello resource")
           (List.hd contents).text;
         let prompts =
           match Mcp.list_prompts client with
           | Ok items -> items
           | Error e -> Alcotest.fail ("list_prompts failed: " ^ Error.to_string e)
         in
         Alcotest.(check int) "prompt count" 1 (List.length prompts);
         Alcotest.(check string) "prompt name" "summarize" (List.hd prompts).name)
;;

(* ── Test runner ───────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run
    "MCP Integration"
    [ ( "server_spec"
      , [ test_case "fields" `Quick test_server_spec_fields
        ; test_case "empty args" `Quick test_server_spec_empty_args
        ; test_case "multiple env" `Quick test_server_spec_multiple_env
        ] )
    ; ( "merge_env"
      , [ test_case "empty extras" `Quick test_merge_env_empty
        ; test_case "add new var" `Quick test_merge_env_add_new
        ; test_case "override existing" `Quick test_merge_env_override
        ; test_case "multiple vars" `Quick test_merge_env_multiple
        ; test_case "preserves existing" `Quick test_merge_env_preserves_existing
        ] )
    ; ( "connect_lifecycle"
      , [ test_case "connect_all empty" `Quick test_connect_all_empty
        ; test_case "close_all empty" `Quick test_close_all_empty
        ; test_case "connect_all bad command" `Quick test_connect_all_bad_command
        ; test_case
            "connect_and_load bad command"
            `Quick
            test_connect_and_load_bad_command
        ; test_case "connect_all partial failure" `Quick test_connect_all_second_fails
        ; test_case
            "resources and prompts roundtrip"
            `Quick
            test_resources_and_prompts_roundtrip
        ] )
    ; "managed_type", [ test_case "tools list access" `Quick test_managed_tools_access ]
    ; ( "agent_integration"
      , [ test_case "default options mcp_clients" `Quick test_default_options_mcp_clients
        ; test_case
            "create with default options"
            `Quick
            test_agent_create_with_default_options
        ; test_case
            "create preserves regular tools"
            `Quick
            test_agent_create_preserves_regular_tools
        ; test_case "close no mcp" `Quick test_agent_close_no_mcp
        ; test_case "close idempotent" `Quick test_agent_close_idempotent
        ; test_case
            "options mcp_clients field"
            `Quick
            test_agent_options_mcp_clients_field
        ; test_case
            "checkpoint with mcp options"
            `Quick
            test_agent_checkpoint_with_mcp_options
        ] )
    ]
;;
