open Alcotest
open Masc
module Protocol = Lane_addon_worker_protocol

let server = {|import json,sys,os,time
schema = {"type":"object","properties":{"value":{"type":"integer"}},
    "required":["value"],"additionalProperties":False}
def obj(properties):
    return {"type":"object","properties":properties,"required":list(properties),"additionalProperties":False}
action = obj({"context":obj({"instance_id":{"type":"string"},"incarnation":{"type":"string"}}),
    "request_id":{"type":"string"},"action":obj({"kind":{"type":"string"}})})
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request: continue
    method = request["method"]
    if method == "initialize":
        result = {"protocolVersion":"2025-11-25","capabilities":{"tools":{}},
            "serverInfo":{"name":"standalone-protocol","version":"1"}}
    elif method == "tools/list":
        if len(sys.argv) > 2 and sys.argv[2] == "block":
            open(sys.argv[1]+".waiting","w").close()
            while not os.path.exists(sys.argv[1]+".release"): time.sleep(0.005)
        result = {"tools":[{"name":"lane_observe","inputSchema":{"type":"object"}},
            {"name":"increment","inputSchema":schema,"outputSchema":schema},
            {"name":"lane_act","inputSchema":action}]}
        if len(sys.argv) > 2 and sys.argv[2] in ["host", "duplicate"]:
            result["tools"] += [{"name":name,"inputSchema":{"type":"object"}} for name in ["lane_host_requests","lane_host_result"]]
        if len(sys.argv) > 2 and sys.argv[2] == "duplicate":
            result["tools"].append({"name":"lane_host_requests","inputSchema":{"type":"object"}})
    elif method == "tools/call":
        params = request["params"]
        if len(sys.argv) > 1:
            with open(sys.argv[1],"a") as output: output.write(params["name"]+"\n")
        if params["name"] == "lane_observe": value = {"rows":[],"coverage":[]}
        elif params["name"] == "lane_host_requests": value = {"requests":[]}
        elif params["name"] == "lane_host_result": value = {"accepted":True}
        else: value = {"value":params["arguments"]["value"]+1}
        result = {"content":[],"structuredContent":value}
    else: raise RuntimeError(method)
    print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}),flush=True)
|}
let require = function Ok value -> value | Error _ -> fail "protocol operation failed"

let standalone_protocol () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let contract = require (Protocol.contract ~host_requests:false ~action_tool:None ~tool_invocation:Lane_addon_types.Direct
    ~exported_tools:["increment"] ~tool_hooks:[Lane_addon_types.Validate_input;Validate_output]
    ~max_reply_bytes:4096) in
  let protocol = Protocol.create ~instance_id:"standalone-test" ~contract () in
  let client = require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
    ~command:"python3" ~args:["-c";server] ~max_response_bytes:4096 ()) in
  Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
    check bool "pending protocol cannot observe" true
      (Result.is_error (Protocol.observe protocol ~binding:(`Assoc []) ~sources:(`Assoc [])));
    require (Protocol.initialize protocol client);
    check int "engine-free connection advertises its export" 1 (List.length (Protocol.exported_tools protocol));
    check bool "another initialization cannot replace the connection" true
      (match Protocol.initialize protocol client with Error (Protocol.Invalid_contract _) -> true | _ -> false);
    let other = require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:["-c";server] ~max_response_bytes:4096 ()) in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Agent_core.Mcp.close other)) (fun () ->
      require (Agent_core.Mcp.initialize other);
      check bool "a distinct connection is also refused" true
        (Result.is_error (Protocol.initialize protocol other));
      check bool "refusal leaves the new connection owned by its caller" true
        (Result.is_ok (Agent_core.Mcp.call_tool_full other ~name:"increment" ~arguments:(`Assoc ["value",`Int 1]))));
    let answer = require (Protocol.call_exported_tool protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4])) in
    check bool "the original exact connection still serves calls" true
      (answer.structured_content = Some (`Assoc ["value",`Int 5]));
    check bool "input hook refuses malformed input before worker code" true
      (match Protocol.call_exported_tool protocol ~name:"increment" ~arguments:(`Assoc ["value",`String "bad"]) with
       | Error (Protocol.Host_refusal _) -> true | _ -> false);
    ignore (require (Protocol.observe protocol ~binding:(`Assoc []) ~sources:(`Assoc [])));
    Protocol.revoke protocol;
    check int "revocation withdraws all exports" 0 (List.length (Protocol.exported_tools protocol));
    check bool "stale call has no admission" true
      (match Protocol.call_exported_tool protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]) with
       | Error Protocol.Stopped -> true | _ -> false))))

let invalid_contract () =
  check bool "ambiguous exports are rejected before a connection exists" true
    (match Protocol.contract ~host_requests:false ~action_tool:None ~tool_invocation:Lane_addon_types.Direct
      ~exported_tools:["increment";"increment"] ~tool_hooks:[] ~max_reply_bytes:4096 with
     | Error (Protocol.Invalid_contract _) -> true | _ -> false)

let host_port_admission ~selected ~advertised () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let calls = Filename.temp_file "addon-host-port-" ".calls" in
  Fun.protect ~finally:(fun () -> Sys.remove calls) (fun () ->
    let contract = require (Protocol.contract ~host_requests:selected ~action_tool:None
      ~tool_invocation:Lane_addon_types.Direct ~exported_tools:[] ~tool_hooks:[] ~max_reply_bytes:4096) in
    let protocol = Protocol.create ~instance_id:"host-port-admission" ~contract () in
    let client = require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:["-c";server;calls;advertised] ~max_response_bytes:4096 ()) in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
      let initialized = Protocol.initialize protocol client in
      if selected && advertised<>"host" then (
        check bool "missing or duplicate private ports refuse Ready" true (Result.is_error initialized);
        check bool "failed discovery retires admission" true (Protocol.revoked protocol))
      else (
        require initialized;
        if selected then (
          check bool "private listing reaches the actual worker" true
            (require (Protocol.host_requests protocol) = `Assoc ["requests",`List []]);
          check bool "private result reaches the actual worker" true
            (require (Protocol.host_result protocol ~arguments:(`Assoc [])) = `Assoc ["accepted",`Bool true]);
          check int "private ports are not public exports" 0 (List.length (Protocol.exported_tools protocol));
          Protocol.revoke protocol;
          check bool "retirement refuses private listing" true (Result.is_error (Protocol.host_requests protocol)))
        else (
          check bool "unselected listing never dispatches" true (Result.is_error (Protocol.host_requests protocol));
          check bool "unselected delivery never dispatches" true
            (Result.is_error (Protocol.host_result protocol ~arguments:(`Assoc [])));
          check string "no tools/call reached the actual worker" "" (In_channel.with_open_bin calls In_channel.input_all)))))))

let failed_discovery_retires_admission () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let calls = Filename.temp_file "addon-admission-" ".calls" in
  Fun.protect ~finally:(fun () -> Sys.remove calls) (fun () ->
    let contract = require (Protocol.contract ~host_requests:false ~action_tool:(Some "lane_act")
      ~tool_invocation:Lane_addon_types.Direct ~exported_tools:["increment";"missing"]
      ~tool_hooks:[] ~max_reply_bytes:4096) in
    let protocol = Protocol.create ~instance_id:"late-discovery-failure" ~contract
      ~artifact_store:(Lane_addon_store.create ~root:(calls ^ ".store")) () in
    let client = require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:["-c";server;calls] ~max_response_bytes:4096 ()) in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
      check bool "valid action followed by a missing export fails initialization" true
        (Result.is_error (Protocol.initialize protocol client));
      check bool "failed discovery is permanently retired" true (Protocol.revoked protocol);
      check bool "partial action schema is never published" true (Protocol.action_schema protocol = None);
      check int "no partial exports are published" 0 (List.length (Protocol.exported_tools protocol));
      check bool "failed discovery cannot observe" true
        (match Protocol.observe protocol ~binding:(`Assoc []) ~sources:(`Assoc []) with
         | Error Protocol.Stopped -> true | _ -> false);
      check bool "failed discovery cannot act" true
        (match Protocol.act protocol ~arguments:(Lane_addon_action.arguments ~instance_id:"late-discovery-failure"
          ~request_id:"never-sent" ~action:(`Assoc ["kind",`String "increment"])) with
         | Error Protocol.Stopped -> true | _ -> false);
      check bool "failed discovery cannot be initialized again" true
        (Result.is_error (Protocol.initialize protocol client));
      check string "no tools/call reached the actual process" "" (In_channel.with_open_bin calls In_channel.input_all)))))

let discovery_race ~cancel () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
  let calls = Filename.temp_file "addon-discovery-" ".calls" in
  let waiting = calls ^ ".waiting" and release = calls ^ ".release" in
  Fun.protect ~finally:(fun () -> List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
    [calls;waiting;release]) (fun () ->
    let contract = require (Protocol.contract ~host_requests:false ~action_tool:None
      ~tool_invocation:Lane_addon_types.Direct ~exported_tools:["increment"]
      ~tool_hooks:[] ~max_reply_bytes:4096) in
    let protocol = Protocol.create ~instance_id:"discovery-race" ~contract () in
    let client = require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:["-c";server;calls;"block"] ~max_response_bytes:4096 ()) in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
      let rec await_discovery () = if Sys.file_exists waiting then () else
        (Eio.Time.sleep (Eio.Stdenv.clock env) 0.005; await_discovery ()) in
      let inspect () =
        await_discovery ();
        check int "initializing protocol publishes no exports" 0 (List.length (Protocol.exported_tools protocol));
        check bool "initializing protocol publishes no action schema" true (Protocol.action_schema protocol = None);
        check bool "initializing observer cannot dispatch" true
          (Result.is_error (Protocol.observe protocol ~binding:(`Assoc []) ~sources:(`Assoc [])));
        check bool "initializing action cannot dispatch" true
          (Result.is_error (Protocol.act protocol ~arguments:(`Assoc [])));
        check bool "initializing exported tool cannot dispatch" true
          (Result.is_error (Protocol.call_exported_tool protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 1])));
        check string "no tools/call crossed the discovery barrier" "" (In_channel.with_open_bin calls In_channel.input_all) in
      if cancel then (
        (match Eio.Fiber.first
          (fun () -> `Initialized (Protocol.initialize protocol client))
          (fun () -> inspect (); `Waiting) with
         | `Waiting -> () | `Initialized _ -> fail "initialization unexpectedly crossed the barrier");
        check bool "cancelled discovery stays retired" true (Protocol.revoked protocol))
      else (
        let result, resolved = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolved (Protocol.initialize protocol client));
        inspect ();
        Protocol.revoke protocol;
        Out_channel.with_open_bin release (fun _ -> ());
        check bool "late tools/list reply cannot publish Ready" true
          (match Eio.Promise.await result with Error Protocol.Stopped -> true | _ -> false));
      check int "retired discovery keeps exports unavailable" 0 (List.length (Protocol.exported_tools protocol));
      check bool "retired discovery cannot be revived" true (Result.is_error (Protocol.initialize protocol client)))))))

let () = run "Addon engine-independent MCP admission"
  ["protocol",[test_case "actual standalone stdio server preserves admission and hook contracts" `Quick standalone_protocol;
    test_case "late discovery failure retires action and observation admission" `Quick failed_discovery_retires_admission;
    test_case "discovery cancellation permanently retires admission" `Quick (discovery_race ~cancel:true);
    test_case "revoke during discovery prevents late publication" `Quick (discovery_race ~cancel:false);
    test_case "invalid contract never needs an execution engine" `Quick invalid_contract;
    test_case "selected private host ports use the retained connection" `Quick (host_port_admission ~selected:true ~advertised:"host");
    test_case "missing private host ports refuse Ready" `Quick (host_port_admission ~selected:true ~advertised:"missing");
    test_case "duplicate private host ports refuse Ready" `Quick (host_port_admission ~selected:true ~advertised:"duplicate");
    test_case "selection off refuses even advertised host ports" `Quick (host_port_admission ~selected:false ~advertised:"host")]]
