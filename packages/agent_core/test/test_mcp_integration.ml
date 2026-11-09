(** Tests for MCP-Agent lifecycle integration.
    Covers sampling over stdio, managed types, and Agent integration
    with MCP clients. *)

open Agent_core

(* ── Helpers ───────────────────────────────────────────────────── *)

let make_test_tool name =
  Tool.create ~name ~description:("Tool " ^ name) ~parameters:[] (fun _input ->
    Ok { Types.content = "result from " ^ name; content_blocks = None; _meta = None })
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
      (Printf.sprintf "agent-core-mcp-%d-%06x" (Unix.getpid ()) (Random.int 0xFFFFFF))
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

(* ── sampling ──────────────────────────────────────────────────── *)

let sampling_server = {|import json, sys
def send(value):
    print(json.dumps(value), flush=True)
advertised = False
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        advertised = "sampling" in request["params"]["capabilities"]
        send({"jsonrpc":"2.0", "id":request["id"], "result":{
            "protocolVersion":request["params"]["protocolVersion"],
            "capabilities":{"tools":{}}, "serverInfo":{"name":"sampling-fixture","version":"1"}}})
    elif method == "tools/call":
        send({"jsonrpc":"2.0", "id":"sample-1", "method":"sampling/createMessage", "params":{
            "messages":[{"role":"user","content":{"type":"text","text":"Compare the supplied alternatives."}}],
            "includeContext":"none", "maxTokens":64}})
        reply = json.loads(sys.stdin.readline())
        assert reply["id"] == "sample-1", reply
        send({"jsonrpc":"2.0", "id":request["id"], "result":{
            "content":[{"type":"text","text":"sampling round trip"}], "isError":False,
            "structuredContent":{"advertised":advertised,"reply":reply}}})
|}
;;

let sampling_round_trip ?sampling_handler ?(after_reply = fun _ -> ()) () =
  with_temp_script sampling_server (fun path ->
    with_eio (fun ~sw ~mgr ->
      let client = match Mcp.connect ~sw ~mgr ~command:"python3" ~args:[path]
          ~env:[||] ?sampling_handler () with
        | Ok client -> client
        | Error error -> Alcotest.fail (Error.to_string error) in
      Fun.protect ~finally:(fun () -> Mcp.close client) (fun () ->
        (match Mcp.initialize client with
         | Ok () -> () | Error error -> Alcotest.fail (Error.to_string error));
        match Mcp.call_tool_full client ~name:"compose" ~arguments:(`Assoc []) with
        | Ok result ->
            (match result.structured_content with
             | Some value -> after_reply client; value | None -> Alcotest.fail "missing callback round-trip evidence")
        | Error error -> Alcotest.fail (Error.to_string error))))
;;

let test_sampling_is_host_owned_over_stdio () =
  let calls = ref 0 in
  let sampling_handler (params : Mcp_protocol.Sampling.create_message_params) =
    incr calls;
    Alcotest.(check int) "requested provider output limit reaches host" 64 params.max_tokens;
    Alcotest.(check bool) "no extra server context requested" true
      (params.include_context=Some Mcp_protocol.Sampling.None_);
    (match params.messages with
     | [{role=Mcp_protocol.Sampling.User;
         content=Mcp_protocol.Sampling.Text {text;_}}] ->
         Alcotest.(check string) "exact package prompt reaches host"
           "Compare the supplied alternatives." text
     | _ -> Alcotest.fail "sampling prompt changed at the subprocess boundary");
    Ok {Mcp_protocol.Sampling.role=Assistant;
      content=Text {type_="text";text="Host-selected fixture response"};
      model="host-fixture-model";stop_reason=Some "endTurn";_meta=None} in
  let result = sampling_round_trip ~sampling_handler () in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "sampling capability advertised only for registered host" true
    (result |> member "advertised" |> to_bool);
  Alcotest.(check int) "one package request invokes host once" 1 !calls;
  let reply = result |> member "reply" |> member "result" in
  Alcotest.(check string) "host model selection crosses back to package"
    "host-fixture-model" (reply |> member "model" |> to_string);
  Alcotest.(check string) "host answer crosses back to package"
    "Host-selected fixture response" (reply |> member "content" |> member "text" |> to_string)
;;

let test_sampling_denial_is_returned_to_package () =
  let result = sampling_round_trip ~sampling_handler:(fun _ -> Error "host policy rejected this request") () in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "host refusal is a protocol error, not a synthetic answer"
    "host policy rejected this request" (result |> member "reply" |> member "error" |> member "message" |> to_string)
;;

exception Sampling_callback_failure
exception Sampling_callback_cancelled

let test_sampling_exception_preserves_stdio () =
  let calls = ref 0 in
  let sampling_handler _ =
    incr calls;
    if !calls = 1 then raise Sampling_callback_failure
    else Ok {Mcp_protocol.Sampling.role=Assistant;
      content=Text {type_="text";text="Recovered callback"};
      model="host-fixture-model";stop_reason=None;_meta=None} in
  let open Yojson.Safe.Util in
  let after_reply client =
    match Mcp.call_tool_full client ~name:"compose" ~arguments:(`Assoc []) with
    | Error error -> Alcotest.fail (Error.to_string error)
    | Ok result ->
        let value = match result.structured_content with
          | Some value -> value | None -> Alcotest.fail "missing subsequent tool response" in
        Alcotest.(check string) "next tool and sampling replies remain framed"
          "Recovered callback"
          (value |> member "reply" |> member "result" |> member "content" |> member "text" |> to_string) in
  let result = sampling_round_trip ~sampling_handler ~after_reply () in
  Alcotest.(check string) "callback exception reaches the package as an error"
    (Printexc.to_string Sampling_callback_failure)
    (result |> member "reply" |> member "error" |> member "message" |> to_string);
  Alcotest.(check int) "same connection handled both callbacks" 2 !calls
;;

let test_sampling_cancellation_propagates () =
  let propagated =
    try
      ignore (sampling_round_trip ~sampling_handler:(fun _ ->
        raise (Eio.Cancel.Cancelled Sampling_callback_cancelled)) ());
      false
    with Eio.Cancel.Cancelled Sampling_callback_cancelled -> true in
  Alcotest.(check bool) "callback cancellation is not a protocol error" true propagated
;;

let test_sampling_is_disabled_without_host_handler () =
  let result = sampling_round_trip () in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "unconfigured connection never advertises model access" false
    (result |> member "advertised" |> to_bool);
  Alcotest.(check bool) "unconfigured model request is explicitly rejected" true
    (result |> member "reply" |> member "error" <> `Null)
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

let test_agent_create_with_default_options () =
  with_net
  @@ fun net ->
  let agent = Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~config:(Types.default_config ~model:"test-model") ~net () in
  Alcotest.(check int) "no tools" 0 (Tool_set.size (Agent.tools agent))
;;

let test_agent_create_preserves_regular_tools () =
  with_net
  @@ fun net ->
  let t1 = make_test_tool "tool1" in
  let t2 = make_test_tool "tool2" in
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
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

let test_agent_checkpoint_with_mcp_options () =
  with_net
  @@ fun net ->
  let agent =
    Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
      ~net
      ~config:{ (Types.default_config ~model:"test-model") with name = "mcp-test-agent" }
      ()
  in
  let cp = Agent.checkpoint agent in
  Alcotest.(check string) "agent name" "mcp-test-agent" cp.agent_name;
  Alcotest.(check int) "no tools in checkpoint" 0 (List.length cp.tools)
;;

(* ── Test runner ───────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run
    "MCP Integration"
    [ ( "sampling_boundary"
      , [ test_case "host model access round trip over stdio" `Quick test_sampling_is_host_owned_over_stdio
        ; test_case "host denial reaches the package" `Quick test_sampling_denial_is_returned_to_package
        ; test_case "callback exception preserves stdio framing" `Quick test_sampling_exception_preserves_stdio
        ; test_case "callback cancellation propagates" `Quick test_sampling_cancellation_propagates
        ; test_case "no handler means no advertised sampling" `Quick test_sampling_is_disabled_without_host_handler ] )
    ; "managed_type", [ test_case "tools list access" `Quick test_managed_tools_access ]
    ; ( "agent_integration"
      , [ test_case
            "create with default options"
            `Quick
            test_agent_create_with_default_options
        ; test_case
            "create preserves regular tools"
            `Quick
            test_agent_create_preserves_regular_tools
        ; test_case
            "checkpoint with mcp options"
            `Quick
            test_agent_checkpoint_with_mcp_options
        ] )
    ]
;;
