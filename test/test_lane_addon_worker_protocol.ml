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
mode = sys.argv[2] if len(sys.argv)>2 else ""
companion = mode in ["companion","companion-error","companion-bad-output","companion-version","companion-duplicate",
    "companion-open-output","companion-open-nested","companion-open-array","companion-open-union",
    "companion-extra-output","companion-extra-nested","companion-extra-array","companion-closed-union",
    "companion-controller-error"]
output_schema = schema
if mode == "companion-open-output":
    output_schema = dict(schema, additionalProperties=True)
if mode in ["companion-open-nested","companion-extra-nested"]:
    details = obj({"status":{"type":"string"}})
    if mode == "companion-open-nested": details["additionalProperties"] = True
    output_schema = obj({"value":{"type":"integer"},"details":details})
if mode in ["companion-open-array","companion-extra-array"]:
    item = obj({"status":{"type":"string"}})
    if mode == "companion-open-array": item["additionalProperties"] = True
    output_schema = obj({"value":{"type":"integer"},"details":{"type":"array","items":item}})
if mode in ["companion-open-union","companion-closed-union"]:
    branch = obj({"value":{"type":"integer"}})
    if mode == "companion-open-union": branch["additionalProperties"] = True
    output_schema = {"type":"object","oneOf":[branch,obj({"status":{"type":"string"}})]}
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
            {"name":"increment","inputSchema":schema,"outputSchema":output_schema},
            {"name":"lane_act","inputSchema":action}]}
        if len(sys.argv) > 2 and sys.argv[2] in ["host", "duplicate"]:
            result["tools"] += [{"name":name,"inputSchema":{"type":"object"}} for name in ["lane_host_requests","lane_host_result"]]
        if len(sys.argv) > 2 and sys.argv[2] == "duplicate":
            result["tools"].append({"name":"lane_host_requests","inputSchema":{"type":"object"}})
        if (len(sys.argv) > 2 and sys.argv[2] == "context") or companion:
            result["tools"].append({"name":"lane_call","inputSchema":{"type":"object"}})
        if companion:
            result["tools"] += [{"name":"lane_companion","inputSchema":{"type":"object"}}] * (2 if mode=="companion-duplicate" else 1)
        if mode.startswith("effects"):
            effect_schema = {"type":"object"}
            if mode != "effects-legacy":
                effect_schema["x-io.github.jeong-sik/masc.observation-effects"] = {"version":2 if mode=="effects-unsupported" else 1}
            effect_tool = {"name":"lane_tool_effects","inputSchema":effect_schema}
            result["tools"].append(effect_tool)
            if mode == "effects-ambiguous": result["tools"].append(effect_tool)
        if mode.startswith("legacy-action") or mode.startswith("legacy-export"):
            legacy_schema = dict(action if mode.startswith("legacy-action") else schema)
            if mode.endswith("-marked"):
                legacy_schema["x-io.github.jeong-sik/masc.observation-effects"] = {"version":1}
            result["tools"].append({"name":"lane_tool_effects","inputSchema":legacy_schema,"outputSchema":schema})
        if mode == "hinted":
            result["tools"][1]["annotations"] = {"readOnlyHint":True}
        if len(sys.argv) > 2 and sys.argv[2] in ["operator", "operator-duplicate"]:
            tool = {"name":"lane_operator","inputSchema":{"type":"object","additionalProperties":False,
                "properties":{"value":{"type":"string"},"fail":{"type":"boolean"}},"required":["value","fail"]}}
            result["tools"] += [tool] * (2 if sys.argv[2] == "operator-duplicate" else 1)
    elif method == "tools/call":
        params = request["params"]
        if len(sys.argv) > 1:
            with open(sys.argv[1],"a") as output: output.write(params["name"]+"\n")
        if params["name"] == "lane_companion":
            assert params["arguments"] == {"version":3}
            value = {"version":2 if mode=="companion-version" else 3,"tools":["increment"]}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":{"content":[],"structuredContent":value}}),flush=True)
            continue
        if params["name"] == "lane_tool_effects" and mode.startswith("effects"):
            assert params["arguments"] == {}
            declared = {"effects":{"increment":"reads_only"},"effects-may-change":{"increment":"may_change"},
                "effects-unknown":{"increment":"maybe"},"effects-unlisted":{"PRIVATE_EFFECT_SENTINEL":"reads_only"}}[mode]
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],
                "result":{"content":[],"structuredContent":{"tools":declared}}}),flush=True)
            continue
        if params["name"] == "lane_tool_effects" and mode.startswith("legacy-action"):
            result = {"content":[],"structuredContent":{"status":"confirmed","result":{"applied":1},
                "output":{"rows":[],"coverage":[]}}}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}),flush=True)
            continue
        if params["name"] == "lane_controller_snapshot" and mode == "companion-controller-error":
            result = {"content":[{"type":"text","text":"PRIVATE_CONTROLLER_MARKER"}],
                "structuredContent":{"private":"PRIVATE_CONTROLLER_MARKER"},"isError":True}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}),flush=True)
            continue
        if params["name"] == "lane_operator":
            private = params["arguments"]["value"]
            result = {"content":[{"type":"text","text":private}],"structuredContent":{"private":private},
                "_meta":{"private":private},"isError":params["arguments"]["fail"]}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}),flush=True)
            continue
        if params["name"] == "lane_observe": value = {"rows":[],"coverage":[]}
        elif params["name"] == "lane_host_requests": value = {"requests":[]}
        elif params["name"] == "lane_host_result": value = {"accepted":True}
        else:
            arguments = params["arguments"]
            if params["name"] == "lane_call":
                assert arguments["tool"] == "increment"
                assert arguments["caller"] == {"kind":"keeper","name":"receipt-finalizer"}
                if companion:
                    assert arguments["companion"]["invocation_id"] == "a"*64
                    assert arguments["companion"]["publication_id"] == "b"*64
                    assert "companion" not in arguments["arguments"]
                arguments = arguments["arguments"]
            value = {"value":arguments["value"]+1}
        result = {"content":[],"structuredContent":value}
        if companion and params["name"]=="lane_call":
            result["content"]=[{"type":"text","text":"PRIVATE_CAPABILITY_MARKER"}]
            result["_meta"]={"private":"a"*64}
            if mode=="companion-error": result["isError"]=True
            if mode=="companion-bad-output": result["structuredContent"]={"private":"PRIVATE_CAPABILITY_MARKER"}
            if mode=="companion-extra-output":
                result["structuredContent"].update({"app_link":"PRIVATE_APP_LINK_MARKER","token":"PRIVATE_TOKEN_MARKER"})
            if mode=="companion-extra-nested":
                result["structuredContent"]["details"]={"status":"ok","token":"PRIVATE_TOKEN_MARKER"}
            if mode=="companion-extra-array":
                result["structuredContent"]["details"]=[{"status":"ok","token":"PRIVATE_TOKEN_MARKER"}]
    else: raise RuntimeError(method)
    print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}),flush=True)
|}
let require = function Ok value -> value | Error _ -> fail "protocol operation failed"
let companion_context () =
  Lane_addon_call_context.companion_of_json (`Assoc ["socket_path",`String "/private/companion/s";
    "invocation_id",`String (String.make 64 'a');"max_message_bytes",`Int 4096;
    "publication_id",`String (String.make 64 'b')]) |> require

(* Only an opted-in private effect declaration makes an export Reads_only:
   an MCP readOnlyHint alone does not, and a malformed reply refuses Ready. *)
let negotiated_effects mode expected () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let calls=Filename.temp_file "effects-protocol-" ".calls" in
  Fun.protect ~finally:(fun () -> Sys.remove calls) (fun () ->
    let contract=require (Protocol.contract ~host_requests:false ~action_tool:None
      ~tool_invocation:Lane_addon_types.Direct ~exported_tools:["increment"] ~tool_hooks:[] ~max_reply_bytes:4096) in
    let protocol=Protocol.create ~instance_id:"effects-protocol" ~contract () in
    let client=require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:["-c";server;calls;mode] ~max_response_bytes:4096 ()) in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
      let initialized=Protocol.initialize protocol client in
      match expected with
      | None ->
          check bool "an unreadable declaration cannot publish Ready" true (Result.is_error initialized);
          if mode = "effects-unlisted" then
            check bool "private effect names cannot enter initialization errors" true
              (initialized = Error (Protocol.Protocol_failed "an observation effect declaration names an unlisted tool"));
          check bool "nothing is taken as read-only" true
            (Protocol.observation_effect protocol "increment" = Lane_addon_call_context.May_change)
      | Some declared ->
          require initialized;
          check bool "the export carries the declared effect" true
            (Protocol.observation_effect protocol "increment" = declared);
          check bool "the effect port is never exported" true
            (List.for_all (fun (tool:Mcp_protocol.Mcp_types.tool) ->
              tool.name<>Lane_addon_call_context.effects_tool) (Protocol.exported_tools protocol));
          if List.mem mode ["effects-legacy";"effects-unsupported";"effects-ambiguous"] then
            check string "unrecognized or ambiguous ports are never called" ""
              (In_channel.with_open_bin calls In_channel.input_all)))))

let effect_marker_contract () =
  let module C = Lane_addon_call_context in
  let marker = "x-io.github.jeong-sik/masc.observation-effects" in
  check bool "the current input schema opts in" true (C.supports_effects_tool C.effects_input_schema);
  check bool "duplicate markers do not opt in" false
    (C.supports_effects_tool (`Assoc [marker, `Assoc ["version", `Int 1]; marker, `Assoc ["version", `Int 1]]));
  check bool "extra marker fields do not opt in" false
    (C.supports_effects_tool (`Assoc [marker, `Assoc ["version", `Int 1; "extra", `Bool true]]))

let wide_effect_declaration () =
  let module C = Lane_addon_call_context in
  let names = List.init 30000 (fun n -> "tool-" ^ string_of_int n) in
  let declarations = List.map (fun name -> name, C.Reads_only) names in
  let decoded = require (C.effects_of_json ~listed:names (C.effects_to_json declarations)) in
  check int "all declared tools survive in order" (List.length declarations) (List.length decoded);
  check bool "declaration order and effects are preserved" true (decoded = declarations);
  check bool "duplicate names remain invalid" true
    (Result.is_error (C.effects_of_json ~listed:["tool"] (`Assoc ["tools", `Assoc [
      "tool", `String "reads_only"; "tool", `String "may_change"]])))

let legacy_effect_name mode () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let calls = Filename.temp_file "legacy-effect-name-" ".calls" in
  Fun.protect ~finally:(fun () -> Sys.remove calls) (fun () ->
    let action = mode = "legacy-action" in
    let action_tool = if action then Some Lane_addon_call_context.effects_tool else None in
    let exported_tools = if action then ["increment"] else [Lane_addon_call_context.effects_tool;"increment"] in
    let contract = require (Protocol.contract ~host_requests:false ~action_tool
      ~tool_invocation:Lane_addon_types.Direct ~exported_tools ~tool_hooks:[] ~max_reply_bytes:4096) in
    let protocol = Protocol.create ~instance_id:"legacy-effect-name" ~contract
      ~artifact_store:(Lane_addon_store.create ~root:(calls ^ ".store")) () in
    let client = require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:["-c";server;calls;mode] ~max_response_bytes:4096 ()) in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
      require (Protocol.initialize protocol client);
      check string "initialization does not call the legacy handler" "" (In_channel.with_open_bin calls In_channel.input_all);
      check bool "other exports retain conservative effects" true
        (Protocol.observation_effect protocol "increment" = Lane_addon_call_context.May_change);
      if action then (
        check bool "the configured action remains available" true (Option.is_some (Protocol.action_schema protocol));
        let result = require (Protocol.act protocol ~arguments:(Lane_addon_action.arguments
          ~instance_id:"legacy-effect-name" ~request_id:"action-1" ~action:(`Assoc ["kind", `String "increment"]))) in
        check bool "the explicit action still executes" true (result.status = Lane_addon_action.Package_confirmed))
      else (
        check bool "the explicitly exported tool remains available" true
          (List.exists (fun (tool:Mcp_protocol.Mcp_types.tool) -> tool.name = Lane_addon_call_context.effects_tool)
            (Protocol.exported_tools protocol));
        let result = require (Protocol.call_exported_tool protocol ~name:Lane_addon_call_context.effects_tool
          ~arguments:(`Assoc ["value", `Int 7])) in
        check bool "the explicit export still executes" true (result.structured_content = Some (`Assoc ["value", `Int 8])));
      check string "only the explicitly requested handler runs" "lane_tool_effects\n"
        (In_channel.with_open_bin calls In_channel.input_all)))))

let negotiated_companion mode () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let calls=Filename.temp_file "companion-protocol-" ".calls" in
  Fun.protect ~finally:(fun () -> Sys.remove calls) (fun () ->
    let contract=require (Protocol.contract ~host_requests:false ~action_tool:None
      ~tool_invocation:Lane_addon_types.Host_context ~exported_tools:["increment"] ~tool_hooks:[] ~max_reply_bytes:4096) in
    let protocol=Protocol.create ~instance_id:"companion-protocol" ~contract () in
    let client=require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:["-c";server;calls;mode] ~max_response_bytes:4096 ()) in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
      let initialized=Protocol.initialize protocol client in
      if List.mem mode ["companion-version";"companion-duplicate";"companion-open-output";
          "companion-open-nested";"companion-open-array";"companion-open-union"] then (
        check bool "invalid private negotiation cannot publish Ready" true (Result.is_error initialized);
        check (list string) "failed discovery exposes no companion tools" [] (Protocol.companion_tools protocol))
      else (
        require initialized;
        check (list string) "only named exports receive grants" ["increment"] (Protocol.companion_tools protocol);
        check bool "private port cannot be exported" true
          (List.for_all (fun (tool:Mcp_protocol.Mcp_types.tool) -> tool.name<>"lane_companion") (Protocol.exported_tools protocol));
        let seen=ref [] and finalized=ref 0 in
        let call ?companion ()=Protocol.call_exported_tool ?companion
          ~principal:(Lane_addon_call_context.Keeper "receipt-finalizer") ~on_result:(fun result -> seen:=result::!seen)
          ~finalize_result:(fun ~name:_ ~arguments:_ ~principal:_ ~(result:Mcp_protocol.Mcp_types.tool_result) ->
            incr finalized;
            check bool "private metadata never reaches the receipt finalizer" true (result._meta=None);
            let expected=match result.structured_content with Some value -> Yojson.Safe.to_string value
              | None -> "private companion operation failed" in
            check string "only validated public text reaches the receipt finalizer" expected
              (Agent_core.Mcp.text_of_tool_result result);
            Ok result)
          protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]) in
        check bool "named companion tool requires a private grant" true (Result.is_error (call ()));
        let context=companion_context () in
        check bool "private authority is checked inside RPC serialization" true
          (Result.is_error (call ~companion:{Protocol.context;admit=(fun () -> false)} ()));
        let result=call ~companion:{Protocol.context;admit=(fun () -> true)} () in
        if List.mem mode ["companion-bad-output";"companion-extra-output";
            "companion-extra-nested";"companion-extra-array"] then (
          check bool "public output validation is mandatory without configured hooks" true (Result.is_error result);
          check int "extra private fields never reach receipt finalization" 0 !finalized;
          check int "invalid private result reaches no public receipt callback" 0 (List.length !seen))
        else (
          let result=require result in
          check int "one public result reaches the finalizer" 1 !finalized;
          check int "one validated public receipt" 1 (List.length !seen);
          check bool "private metadata is discarded" true (result._meta=None);
          check bool "raw private text does not reach public results" true
            (Agent_core.Mcp.text_of_tool_result result=(if mode="companion-error" then "private companion operation failed" else "{\"value\":5}"));
          check bool "only public schema output survives" true
            (result.structured_content=(if mode="companion-error" then None else Some (`Assoc ["value",`Int 5]))));
        check string "rejected calls never entered the worker" "lane_companion\nlane_call\n"
          (In_channel.with_open_bin calls In_channel.input_all))))))

let companion_context_codec () =
  let module C=Lane_addon_call_context in
  let companion=companion_context () in
  let arguments=`Assoc ["value",`Int 4] in
  let wire=C.to_json_with_controller ~controller:None ~companion:(Some companion)
    ~principal:(C.Keeper "receipt-finalizer") ~tool:"increment" ~arguments in
  let decoded=C.of_json wire |> require in
  check bool "private context leaves original public arguments intact" true (decoded.arguments=arguments);
  check bool "private descriptor roundtrips only in control envelope" true (decoded.companion=Some companion);
  List.iter (fun name -> check bool "private port cannot escape through model or action declaration" true
    (Result.is_error (Protocol.contract ~host_requests:false ~action_tool:name
      ~tool_invocation:Lane_addon_types.Host_context ~exported_tools:(if name=None then ["lane_companion"] else [])
      ~tool_hooks:[] ~max_reply_bytes:4096))) [None;Some "lane_companion"]

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

let private_operator () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  List.iter (fun action_tool ->
    check bool "operator port cannot escape through export or action" true
      (Result.is_error (Protocol.contract ~host_requests:false ~action_tool
        ~tool_invocation:Lane_addon_types.Direct ~exported_tools:(if action_tool=None then ["lane_operator"] else [])
        ~tool_hooks:[] ~max_reply_bytes:4096))) [None;Some "lane_operator"];
  let calls=Filename.temp_file "addon-private-operator-" ".calls" in
  Fun.protect ~finally:(fun () -> Sys.remove calls) (fun () ->
    let contract=require (Protocol.contract ~host_requests:false ~action_tool:None
      ~tool_invocation:Lane_addon_types.Direct ~exported_tools:["increment"] ~tool_hooks:[] ~max_reply_bytes:4096) in
    let protocol=Protocol.create ~instance_id:"private-operator" ~contract () in
    let client=require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:["-c";server;calls;"operator"] ~max_response_bytes:4096 ()) in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
      require (Protocol.initialize protocol client);
      check bool "private discovery is separate from model exports" true
        (Option.is_some (Protocol.operator_schema protocol) && List.for_all
          (fun (tool:Mcp_protocol.Mcp_types.tool) -> tool.name<>"lane_operator") (Protocol.exported_tools protocol));
      let arguments=`Assoc ["value",`String "PRIVATE_MARKER";"fail",`Bool false] in
      check bool "public exported path cannot call private port" true
        (Result.is_error (Protocol.call_exported_tool protocol ~name:"lane_operator" ~arguments));
      check bool "private input validation emits no request or parser detail" true
        (Protocol.call_operator protocol ~admit:(fun () -> Ok ()) ~arguments:(`Assoc []) = Error Protocol.Operator_rejected);
      check bool "host authority is rechecked before dispatch" true
        (Protocol.call_operator protocol ~admit:(fun () -> Error Protocol.Operator_unavailable) ~arguments
          = Error Protocol.Operator_unavailable);
      check string "refused calls reached no worker" "" (In_channel.with_open_bin calls In_channel.input_all);
      let answer=require (Protocol.call_operator protocol ~admit:(fun () -> Ok ()) ~arguments) in
      check bool "only private structured result reaches operator caller" true (answer=`Assoc ["private",`String "PRIVATE_MARKER"]);
      let failed=Protocol.call_operator protocol ~admit:(fun () -> Ok ())
        ~arguments:(`Assoc ["value",`String "PRIVATE_FAILURE_MARKER";"fail",`Bool true]) in
      check bool "post-dispatch errors erase all content/meta/detail" true (failed=Error Protocol.Operator_outcome_unknown);
      check bool "unknown private outcome fences the original protocol" true (Protocol.revoked protocol);
      check bool "unknown call cannot be replayed" true
        (Protocol.call_operator protocol ~admit:(fun () -> Ok ()) ~arguments = Error Protocol.Operator_unavailable);
      check string "exact two explicit private dispatches" "lane_operator\nlane_operator\n"
        (In_channel.with_open_bin calls In_channel.input_all)))))

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

let with_finalizer_fixture ?(mode="context") ~hooks ~invocation run = Eio_main.run (fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () -> Eio.Switch.run (fun sw ->
    let calls=Filename.temp_file "addon-finalizer-" ".calls" in
    Fun.protect ~finally:(fun () -> Sys.remove calls) (fun () ->
      let contract=require (Protocol.contract ~host_requests:false ~action_tool:None
        ~tool_invocation:invocation ~exported_tools:["increment"] ~tool_hooks:hooks ~max_reply_bytes:4096) in
      let protocol=Protocol.create ~instance_id:"finalizer-test" ~contract () in
      let client=require (Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
        ~command:"python3" ~args:["-c";server;calls;mode] ~max_response_bytes:4096 ()) in
      Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
        require (Protocol.initialize protocol client);
        run protocol (fun () -> In_channel.with_open_bin calls In_channel.input_all))))))

let private_finalizer_failure ~raises () = with_finalizer_fixture ~mode:"companion" ~hooks:[]
  ~invocation:Lane_addon_types.Host_context (fun protocol calls ->
    let seen=ref 0 and finalized=ref 0 in
    let result=Protocol.call_exported_tool
      ~companion:{Protocol.context=companion_context ();admit=(fun () -> true)}
      ~principal:(Lane_addon_call_context.Keeper "receipt-finalizer")
      ~on_result:(fun _ -> incr seen)
      ~finalize_result:(fun ~name:_ ~arguments:_ ~principal:_ ~(result:Mcp_protocol.Mcp_types.tool_result) ->
        incr finalized;
        check bool "finalizer receives no worker private metadata" true (result._meta=None);
        check string "finalizer receives public text instead of worker private text" "{\"value\":5}"
          (Agent_core.Mcp.text_of_tool_result result);
        if raises then failwith "PRIVATE_FINALIZER_MARKER" else Error "PRIVATE_FINALIZER_MARKER")
      protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]) in
    (match result with
     | Error (Protocol.Protocol_failed detail) ->
       check string "private finalizer failure prose is erased" "private invocation finalization failed" detail
     | Ok _ | Error (Invalid_contract _|Host_refusal _|Invalid_observation _|Stopped) ->
       fail "private finalizer must return only a fixed protocol failure");
    check int "the public-safe receipt reaches finalization once" 1 !finalized;
    check int "no failed finalization reaches public receipt observers" 0 !seen;
    check string "finalizer failure does not replay the invocation" "lane_companion\nlane_call\n" (calls ()))

let private_finalizer_result_is_projected () = with_finalizer_fixture ~mode:"companion" ~hooks:[]
  ~invocation:Lane_addon_types.Host_context (fun protocol calls ->
    let seen=ref [] in
    let answer=require (Protocol.call_exported_tool
      ~companion:{Protocol.context=companion_context ();admit=(fun () -> true)}
      ~principal:(Lane_addon_call_context.Keeper "receipt-finalizer")
      ~on_result:(fun result -> seen:=result::!seen)
      ~finalize_result:(fun ~name:_ ~arguments:_ ~principal:_ ~(result:Mcp_protocol.Mcp_types.tool_result) ->
        check bool "raw worker metadata is absent before host receipt effects" true (result._meta=None);
        let module S=Mcp_protocol.Mcp_types in
        Ok {result with structured_content=Some (`Assoc ["value",`Int 9]);
          content=[S.TextContent {type_="text";text="PRIVATE_FINALIZER_TEXT_MARKER";annotations=None}];
          _meta=Some (`Assoc ["private",`String "PRIVATE_FINALIZER_META_MARKER"])})
      protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4])) in
    check bool "finalizer output metadata is projected away again" true (answer._meta=None);
    check string "finalizer output text is replaced by validated public data" "{\"value\":9}"
      (Agent_core.Mcp.text_of_tool_result answer);
    check bool "public observer sees only the final validated projection" true (!seen=[answer]);
    check string "one explicit companion invocation" "lane_companion\nlane_call\n" (calls ()))

let private_controller_failure ~host_refusal () = with_finalizer_fixture ~mode:"companion-controller-error" ~hooks:[]
  ~invocation:Lane_addon_types.Host_context (fun protocol calls ->
    let seen=ref 0 and finalized=ref 0 in
    let authorize ~release_controller:_ ~snapshot ~invoke:_ =
      match snapshot () with
      | Error detail ->
        check string "snapshot removes private text before any mediation error mapping"
          "private controller snapshot failed" detail;
        if host_refusal then Error (Lane_addon_call_context.Host_refusal (Unavailable detail))
        else Error (Lane_addon_call_context.Transport_error detail)
      | Ok _ -> fail "the fixture controller snapshot must expose an untrusted failure" in
    let result=Protocol.call_exported_tool ~authorize
      ~companion:{Protocol.context=companion_context ();admit=(fun () -> true)}
      ~principal:(Lane_addon_call_context.Keeper "receipt-finalizer")
      ~on_result:(fun _ -> incr seen)
      ~finalize_result:(fun ~name:_ ~arguments:_ ~principal:_ ~result -> incr finalized;Ok result)
      protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]) in
    (if host_refusal then
       match result with
       | Error (Protocol.Host_refusal (Lane_addon_call_context.Unavailable detail)) ->
         check string "actual host mediation preserves only the fixed snapshot refusal"
           "private controller snapshot failed" detail
       | Ok _ | Error (Invalid_contract _|Protocol_failed _|Invalid_observation _|Stopped
           |Host_refusal (Rejected _|Activity_disabled _|Activity_unobserved _)) ->
         fail "controller host refusal must contain only the fixed snapshot failure"
     else match result with
       | Error (Protocol.Protocol_failed detail) ->
         check string "controller-origin private prose is erased" "private invocation outcome unknown" detail
       | Ok _ | Error (Invalid_contract _|Host_refusal _|Invalid_observation _|Stopped) ->
         fail "private controller failure must remain a fixed transport failure");
    check int "raw controller failure reaches no public observer" 0 !seen;
    check int "raw controller failure reaches no finalizer" 0 !finalized;
    check string "failed controller admission sends no exported invocation"
      "lane_companion\nlane_controller_snapshot\n" (calls ()))

let finalized_receipt () = with_finalizer_fixture
  ~hooks:[Lane_addon_types.Validate_input;Validate_output] ~invocation:Lane_addon_types.Host_context
  (fun protocol calls ->
    let raw=ref [] and finalized=ref 0 in
    let arguments=`Assoc ["value",`Int 4] and principal=Lane_addon_call_context.Keeper "receipt-finalizer" in
    let finalize_result ~name ~arguments:observed_arguments ~principal:observed_principal
        ~(result:Mcp_protocol.Mcp_types.tool_result) =
      incr finalized;
      check string "finalizer sees public tool, not lane_call" "increment" name;
      check bool "finalizer keeps original arguments" true (observed_arguments=arguments);
      check bool "finalizer keeps verified original caller" true (observed_principal=principal);
      check int "raw observer runs before finalizer exactly once" 1 (List.length !raw);
      check bool "original raw result remains available" true
        (result.structured_content=Some (`Assoc ["value",`Int 5]) && !raw=[result]);
      ignore (require (Protocol.observe protocol ~binding:(`Assoc []) ~sources:(`Assoc [])));
      Ok {result with structured_content=Some (`Assoc ["value",`Int 9]);
        _meta=Some (`Assoc ["hostReceipt",`String "retained"])} in
    let answer=require (Protocol.call_exported_tool ~on_result:(fun result -> raw:=result :: !raw)
      ~finalize_result ~principal protocol ~name:"increment" ~arguments) in
    check int "finalizer runs once after invocation" 1 !finalized;
    check bool "caller gets the finalized receipt" true
      (answer.structured_content=Some (`Assoc ["value",`Int 9])
       && answer._meta=Some (`Assoc ["hostReceipt",`String "retained"]));
    check string "finalizer can reenter this protocol outside the RPC mutex"
      "lane_call\nlane_observe\n" (calls ()))

let finalized_output ~hooks ~accepted () = with_finalizer_fixture ~hooks
  ~invocation:Lane_addon_types.Direct (fun protocol calls ->
    let finalized=ref 0 and raw=ref None in
    let result=Protocol.call_exported_tool ~on_result:(fun result -> raw:=Some result)
      ~finalize_result:(fun ~name:_ ~arguments:_ ~principal:_ ~result ->
        incr finalized;Ok {result with structured_content=Some (`Assoc ["value",`String "host-invalid"])})
      protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]) in
    check int "finalizer is mandatory even with hooks disabled" 1 !finalized;
    check bool "raw receipt was observed before host transformation" true
      (Option.map (fun (result:Mcp_protocol.Mcp_types.tool_result) -> result.structured_content) !raw
        =Some (Some (`Assoc ["value",`Int 5])));
    check bool "output hook validates the final receipt" accepted
      (match result with Ok reply -> reply.structured_content=Some (`Assoc ["value",`String "host-invalid"])
       | Error (Protocol.Protocol_failed _) -> false
       | Error (Invalid_contract _|Host_refusal _|Invalid_observation _|Stopped) -> fail "unexpected refusal boundary");
    check string "validation never replays the effect" "increment\n" (calls ()))

exception Finalization_failed
let finalizer_refusal () = with_finalizer_fixture ~hooks:[] ~invocation:Lane_addon_types.Direct
  (fun protocol calls ->
    let raw=ref 0 and finalized=ref 0 in
    let refused=Protocol.call_exported_tool ~on_result:(fun _ -> incr raw)
      ~finalize_result:(fun ~name:_ ~arguments:_ ~principal:_ ~result:_ ->
        incr finalized;Error "artifact persistence refused")
      protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]) in
    check bool "host refusal is a post-dispatch protocol error" true
      (match refused with Error (Protocol.Protocol_failed _) -> true
       | Ok _|Error (Invalid_contract _|Host_refusal _|Invalid_observation _|Stopped) -> false);
    check int "raw effect receipt is still observed" 1 !raw;
    check int "refused finalizer runs only once" 1 !finalized;
    check string "host failure never repeats the worker call" "increment\n" (calls ());
    let raised=Protocol.call_exported_tool
      ~finalize_result:(fun ~name:_ ~arguments:_ ~principal:_ ~result:_ -> raise Finalization_failed)
      protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 8]) in
    check bool "unexpected host finalization exception stays a post-dispatch failure" true
      (match raised with Error (Protocol.Protocol_failed _) -> true
       | Ok _|Error (Invalid_contract _|Host_refusal _|Invalid_observation _|Stopped) -> false);
    check string "a second explicit call dispatches once without replay"
      "increment\nincrement\n" (calls ()))

let cancelled_finalizer () = with_finalizer_fixture ~hooks:[] ~invocation:Lane_addon_types.Direct
  (fun protocol calls ->
    let entered,enter=Eio.Promise.create () in
    let raw=ref 0 and cancelled=ref false in
    ignore (Eio.Fiber.first
      (fun () -> try
        ignore (Protocol.call_exported_tool ~on_result:(fun _ -> incr raw)
          ~finalize_result:(fun ~name:_ ~arguments:_ ~principal:_ ~result:_ ->
            Eio.Promise.resolve enter ();Eio.Fiber.await_cancel ())
          protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]));
        fail "blocked finalizer unexpectedly returned"
       with Eio.Cancel.Cancelled _ as exn -> cancelled:=true;raise exn)
      (fun () -> Eio.Promise.await entered) : unit);
    check bool "finalizer cancellation propagates" true !cancelled;
    check bool "cancelled finalization revokes original protocol" true (Protocol.revoked protocol);
    check bool "stale input cannot dispatch after cancellation" true
      (match Protocol.call_exported_tool protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 4]) with
       | Error Protocol.Stopped -> true
       | Ok _|Error (Invalid_contract _|Protocol_failed _|Host_refusal _|Invalid_observation _) -> false);
    check int "cancelled finalization keeps the one raw reply" 1 !raw;
    check string "cancelled effect is never replayed" "increment\n" (calls ()))

(* A call cancelled while it waits behind another call for the RPC mutex
   wrote nothing: the protocol keeps serving and the next call dispatches on
   the same session. *)
let queued_cancellation () = with_finalizer_fixture ~hooks:[] ~invocation:Lane_addon_types.Direct
  (fun protocol calls ->
    let holding,hold=Eio.Promise.create () and released,release=Eio.Promise.create () in
    let queued_dispatched=ref false and queued_returned=ref false in
    Eio.Switch.run (fun sw ->
      let first=Eio.Fiber.fork_promise ~sw (fun () ->
        Protocol.call_exported_tool ~on_result:(fun _ -> Eio.Promise.resolve hold (); Eio.Promise.await released)
          protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 1])) in
      Eio.Promise.await holding;
      Eio.Fiber.first
        (fun () -> ignore (Protocol.call_exported_tool ~on_dispatch:(fun () -> queued_dispatched:=true)
          protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 2]));
          queued_returned:=true)
        (fun () -> Eio.Fiber.yield (); Eio.Fiber.yield ());
      check bool "the queued call was cancelled, not answered" false !queued_returned;
      check bool "the queued call wrote nothing" false !queued_dispatched;
      check bool "its cancellation leaves the protocol serving" false (Protocol.revoked protocol);
      Eio.Promise.resolve release ();
      check bool "the held call completes" true
        (match Eio.Promise.await_exn first with Ok _ -> true | Error _ -> false));
    check bool "the next call dispatches on the same session" true
      (match Protocol.call_exported_tool protocol ~name:"increment" ~arguments:(`Assoc ["value",`Int 3]) with
       | Ok _ -> true
       | Error (Protocol.Invalid_contract _|Protocol_failed _|Host_refusal _|Invalid_observation _|Stopped) -> false);
    check string "only the held and the next call reached the worker" "increment\nincrement\n" (calls ()))

let actual_onepassword_package () = Eio_main.run (fun env ->
  let fixture_root=Filename.temp_dir "actual-onepassword-package-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree fixture_root) (fun () ->
  Eio.Switch.run (fun sw ->
  let source_directory=match List.find_opt (fun path -> Sys.file_exists (Filename.concat path "lane.toml"))
      [Filename.concat (Sys.getcwd ()) "../addons/onepassword";
       Filename.concat (Sys.getcwd ()) "addons/onepassword"] with
    | Some path -> path | None -> fail "actual 1Password package dependency is missing" in
  let directory=Filename.concat fixture_root "onepassword" in
  let copy source destination =
    Fs_compat.mkdir_p (Filename.dirname destination);
    let bytes=In_channel.with_open_bin source In_channel.input_all in
    Out_channel.with_open_bin destination (fun channel -> output_string channel bytes) in
  let copy_package relative = copy (Filename.concat source_directory relative)
      (Filename.concat directory relative) in
  (* Copy public package inputs, never a source checkout's private JSON config
     or environment. The fixture owns the interpreter and its absent config. *)
  Array.iter (fun name -> if Filename.check_suffix name ".py" then copy_package name)
    (Sys.readdir source_directory);
  List.iter copy_package ["lane.toml";"requirements.txt";"skills/onepassword/SKILL.md"];
  copy (Filename.concat (Filename.dirname source_directory) "protocol.py")
    (Filename.concat fixture_root "protocol.py");
  Eio.Process.run (Eio.Stdenv.process_mgr env)
    ["python3";"-m";"venv";"--without-pip";Filename.concat directory ".venv"];
  let package=Lane_addon_manifest.load ~path:(Filename.concat directory "lane.toml") |> require in
  let executable,arguments=match package.command with
    | executable::arguments -> executable,arguments
    | [] -> fail "actual package manifest command is empty" in
  check bool "manifest selects an owned package executable" true
    (Filename.is_relative executable && String.contains executable '/'
     && Sys.file_exists (Filename.concat package.directory executable));
  check bool "actual manifest executable passes production discovery" true
    (Native_addon_program.command_ready ~package_directory:package.directory executable);
  (* Process admission resolves the executable before applying the child cwd. *)
  let command=Filename.concat package.directory executable in
  let maximum=Lane_addon_types.max_reply_bytes package in
  let contract=Protocol.contract ~host_requests:false ~action_tool:package.action_tool
      ~tool_invocation:package.tool_invocation ~exported_tools:package.exported_tools
      ~tool_hooks:package.tool_hooks ~max_reply_bytes:maximum |> require in
  let protocol=Protocol.create ~instance_id:"actual-onepassword-package" ~contract () in
  let client=match Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command ~args:arguments
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / package.directory)
      ~max_response_bytes:maximum () with
    | Ok client -> client
    | Error error -> Alcotest.failf "actual package process start failed: %s"
        (Agent_core.Error.to_string error) in
  Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Protocol.close protocol)) (fun () ->
    require (Protocol.initialize protocol client);
    check (list string) "actual package schemas publish all declared exports"
      (List.sort String.compare package.exported_tools)
      (Protocol.exported_tools protocol |> List.map (fun (tool:Mcp_protocol.Mcp_types.tool) -> tool.name)
       |> List.sort String.compare);
    check (list string) "only start receives a companion grant" ["onepassword_login"]
      (Protocol.companion_tools protocol);
    let status=Protocol.call_exported_tool ~principal:Lane_addon_call_context.Operator protocol
        ~name:"onepassword_status" ~arguments:(`Assoc []) |> require in
    check bool "actual status traverses host input and output validators" true
      (status.structured_content=Some (`Assoc ["phase",`String "not_configured";
        "connected",`Bool false;"browser_login_available",`Bool false]))))))

let () = run "Addon engine-independent MCP admission"
  ["protocol",[test_case "actual 1Password package initializes through host validators" `Quick actual_onepassword_package;
    test_case "a call cancelled while queued for the RPC mutex leaves the session serving" `Quick queued_cancellation;
    test_case "actual standalone stdio server preserves admission and hook contracts" `Quick standalone_protocol;
    test_case "private companion context and reserved port" `Quick companion_context_codec;
    test_case "companion grants preserve only validated public replies" `Quick (negotiated_companion "companion");
    test_case "private worker errors lose raw text and metadata" `Quick (negotiated_companion "companion-error");
    test_case "a declared read comes from the private effect port" `Quick
      (negotiated_effects "effects" (Some Lane_addon_call_context.Reads_only));
    test_case "an explicit may_change is kept" `Quick
      (negotiated_effects "effects-may-change" (Some Lane_addon_call_context.May_change));
    test_case "an MCP readOnlyHint alone declares nothing" `Quick
      (negotiated_effects "hinted" (Some Lane_addon_call_context.May_change));
    test_case "an unknown observation effect refuses Ready" `Quick (negotiated_effects "effects-unknown" None);
    test_case "an effect for an unlisted tool refuses Ready" `Quick (negotiated_effects "effects-unlisted" None);
    test_case "an unmarked legacy private tool is not called" `Quick
      (negotiated_effects "effects-legacy" (Some Lane_addon_call_context.May_change));
    test_case "an unsupported marker is not called" `Quick
      (negotiated_effects "effects-unsupported" (Some Lane_addon_call_context.May_change));
    test_case "an ambiguous port is not called" `Quick
      (negotiated_effects "effects-ambiguous" (Some Lane_addon_call_context.May_change));
    test_case "effect marker requires a single supported version" `Quick effect_marker_contract;
    test_case "wide effect declarations retain all names" `Quick wide_effect_declaration;
    test_case "a legacy action takes precedence over the effect port" `Quick (legacy_effect_name "legacy-action");
    test_case "a legacy export takes precedence over the effect port" `Quick (legacy_effect_name "legacy-export");
    test_case "an export role takes precedence over an effect marker" `Quick (legacy_effect_name "legacy-export-marked");
    test_case "companion public output validation is mandatory" `Quick (negotiated_companion "companion-bad-output");
    test_case "companion output schema cannot declare an open object" `Quick (negotiated_companion "companion-open-output");
    test_case "companion output schema cannot declare a nested open object" `Quick (negotiated_companion "companion-open-nested");
    test_case "companion output schema cannot declare open array items" `Quick (negotiated_companion "companion-open-array");
    test_case "companion output schema cannot declare open union branches" `Quick (negotiated_companion "companion-open-union");
    test_case "closed companion union schema remains usable" `Quick (negotiated_companion "companion-closed-union");
    test_case "extra private fields cannot enter public receipts or finalizers" `Quick (negotiated_companion "companion-extra-output");
    test_case "nested private fields cannot enter public receipts or finalizers" `Quick (negotiated_companion "companion-extra-nested");
    test_case "private array item fields cannot enter public receipts or finalizers" `Quick (negotiated_companion "companion-extra-array");
    test_case "controller transport failures lose private prose" `Quick (private_controller_failure ~host_refusal:false);
    test_case "actual controller host refusals lose private prose" `Quick (private_controller_failure ~host_refusal:true);
    test_case "private finalizer errors are fixed" `Quick (private_finalizer_failure ~raises:false);
    test_case "private finalizer exceptions are fixed" `Quick (private_finalizer_failure ~raises:true);
    test_case "private finalizer output is projected again" `Quick private_finalizer_result_is_projected;
    test_case "unknown companion version cannot become Ready" `Quick (negotiated_companion "companion-version");
    test_case "duplicate companion port cannot become Ready" `Quick (negotiated_companion "companion-duplicate");
    test_case "private operator port never enters model exports or error detail" `Quick private_operator;
    test_case "host finalization retains original context and allows another RPC" `Quick finalized_receipt;
    test_case "selected output hook validates finalized receipt" `Quick
      (finalized_output ~hooks:[Lane_addon_types.Validate_output] ~accepted:false);
    test_case "finalization remains mandatory with all hooks disabled" `Quick
      (finalized_output ~hooks:[] ~accepted:true);
    test_case "host finalization refusal preserves raw receipt without replay" `Quick finalizer_refusal;
    test_case "host finalization cancellation revokes admission" `Quick cancelled_finalizer;
    test_case "late discovery failure retires action and observation admission" `Quick failed_discovery_retires_admission;
    test_case "discovery cancellation permanently retires admission" `Quick (discovery_race ~cancel:true);
    test_case "revoke during discovery prevents late publication" `Quick (discovery_race ~cancel:false);
    test_case "invalid contract never needs an execution engine" `Quick invalid_contract;
    test_case "selected private host ports use the retained connection" `Quick (host_port_admission ~selected:true ~advertised:"host");
    test_case "missing private host ports refuse Ready" `Quick (host_port_admission ~selected:true ~advertised:"missing");
    test_case "duplicate private host ports refuse Ready" `Quick (host_port_admission ~selected:true ~advertised:"duplicate");
    test_case "selection off refuses even advertised host ports" `Quick (host_port_admission ~selected:false ~advertised:"host")]]
