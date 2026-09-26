open Alcotest
open Masc

module Serve = Runtime_muse_serve
module Msp = Runtime_muse_msp
module Store = Keeper_official_client_session_store
module Adapter = Keeper_muse_runtime.For_testing

let session_id = "0198f0aa-1111-7000-8000-0000000000aa"

let native_observation call_id : Runtime_native_tools.observation =
  { identity = Some (Runtime_native_tools.Call_id call_id)
  ; tool_name = Some "read_file"
  ; origin = Runtime_native_tools.Built_in
  }
;;

let turn_started =
  Serve.Turn_started { session_id; turn_id = "turn-1"; model = Some "muse-fixture-1" }
;;

let usage : Msp.token_usage =
  { input_tokens = 100; output_tokens = 7; cached_tokens = 50; reasoning_tokens = 3 }
;;

(* ── Stream projection ───────────────────────────────────────────────── *)

let test_stream_order () =
  let events =
    Adapter.project_stream
      [ turn_started
      ; Serve.Text_delta { item_id = "m-1"; text = "MASC_" }
      ; Serve.Native_tool_started (native_observation "call-1")
      ; Serve.Approval_decided
          { tool_name = "read_file"; subject = Msp.Subject_file_access; decision = Msp.Denied }
      ; Serve.Native_tool_finished (native_observation "call-1")
      ; Serve.Text_delta { item_id = "m-1"; text = "MUSE_OK" }
      ; Serve.Usage_reported { session_id; turn_id = "turn-1"; usage }
      ; Serve.Turn_finished { text = "MASC_MUSE_OK" }
      ]
  in
  match events with
  | [ Agent_core.Types.MessageStart { id = "turn-1"; model = "muse-fixture-1"; usage = None }
    ; ContentBlockDelta { index = 0; delta = TextDelta "MASC_" }
    ; ContentBlockStart { index = 1; content_type; tool_id = Some "call-1"; tool_name = Some "read_file" }
    ; ContentBlockStop { index = 1 }
    ; ContentBlockDelta { index = 0; delta = TextDelta "MUSE_OK" }
    ; MessageDelta { stop_reason = Some EndTurn; usage = None }
    ; MessageStop
    ] ->
    check string "native block" Runtime_native_tools.stream_content_type content_type
  | _ ->
    failf
      "unexpected stream (%d events): approvals, usage and subscription windows add \
       no block"
      (List.length events)
;;

(* A reply the host completed without streaming it still reaches the
   viewer when the turn ends. *)
let test_unstreamed_reply_is_forwarded_at_the_end () =
  match
    Adapter.project_stream
      [ turn_started
      ; Serve.Text_delta { item_id = "m-1"; text = "MASC_" }
      ; Serve.Turn_finished { text = "MASC_MUSE_OK" }
      ]
  with
  | [ MessageStart _
    ; ContentBlockDelta { delta = TextDelta "MASC_"; _ }
    ; ContentBlockDelta { delta = TextDelta "MUSE_OK"; _ }
    ; MessageDelta _
    ; MessageStop
    ] -> ()
  | events -> failf "the missing suffix was not forwarded (%d events)" (List.length events)
;;

(* Two agent messages in one turn read as two paragraphs, not one sentence:
   each delta names its message. *)
let test_a_second_message_starts_a_paragraph () =
  match
    Adapter.project_stream
      [ turn_started
      ; Serve.Text_delta { item_id = "m-1"; text = "checking." }
      ; Serve.Text_delta { item_id = "m-2"; text = "done" }
      ]
  with
  | [ MessageStart _
    ; ContentBlockDelta { delta = TextDelta "checking."; _ }
    ; ContentBlockDelta { delta = TextDelta "\n\ndone"; _ }
    ] -> ()
  | events -> failf "the second message did not open a paragraph (%d events)" (List.length events)
;;

let mcp_started call_id =
  Adapter.Mcp_tool_started
    { call_id; tool_name = "masc_probe"; arguments = `Assoc [ "marker", `String "x" ] }
;;

(* The bridge can answer a MASC tool before the serve client has read the
   [turn/start] answer. Those blocks wait for MessageStart. *)
let test_mcp_blocks_wait_for_message_start () =
  let events =
    Adapter.project_stream_inputs
      ~during:(fun _ -> [])
      [ mcp_started "mcp-1"
      ; Adapter.Mcp_tool_finished { call_id = "mcp-1" }
      ; Adapter.Serve_event turn_started
      ; Adapter.Serve_event (Serve.Turn_finished { text = "" })
      ]
  in
  match events with
  | [ MessageStart _
    ; ContentBlockStart { index = 1; content_type = "tool_use"; tool_id = Some "mcp-1"; _ }
    ; ContentBlockDelta { index = 1; delta = InputJsonSnapshot {|{"marker":"x"}|} }
    ; ContentBlockStop { index = 1 }
    ; MessageDelta _
    ; MessageStop
    ] -> ()
  | _ -> failf "held MCP blocks were not released after MessageStart (%d)" (List.length events)
;;

(* A tool call the bridge answers while MessageStart is being emitted is
   held and released in the same pass, after the message opened. *)
let test_mcp_block_arriving_during_message_start () =
  let events =
    Adapter.project_stream_inputs
      ~during:(function
        | Agent_core.Types.MessageStart _ ->
          [ mcp_started "mcp-2"; Adapter.Mcp_tool_finished { call_id = "mcp-2" } ]
        | _ -> [])
      [ Adapter.Serve_event turn_started ]
  in
  match events with
  | [ MessageStart _
    ; ContentBlockStart { tool_id = Some "mcp-2"; _ }
    ; ContentBlockDelta { delta = InputJsonSnapshot _; _ }
    ; ContentBlockStop _
    ] -> ()
  | _ -> failf "a block raced MessageStart (%d events)" (List.length events)
;;

(* ── Usage report ────────────────────────────────────────────────────── *)

let test_usage_report_is_the_turn_total () =
  match
    Adapter.usage_reports
      ~turn_count:4
      ~position:Keeper_usage_resolution.Resumed
      [ turn_started
      ; Serve.Subscription_usage_observed
          { observed_at_ms = 1
          ; tier = "pro"
          ; window = { used_percent = 10; resets_at_ms = 2; window_duration_mins = 300 }
          ; weekly = { weekly_used_percent = 3; weekly_resets_at_ms = 4 }
          }
      ; Serve.Usage_reported { session_id; turn_id = "turn-1"; usage }
      ]
  with
  | [ report ] ->
    check int "official turn" 4 report.official_turn;
    check string "keyed by the MSP turn id" "turn-1" report.response_id;
    check string "conversation" session_id report.conversation_id;
    check string "model the host reported" "muse-fixture-1" report.model;
    check bool "position" true (report.position = Keeper_usage_resolution.Resumed);
    check bool
      "summed across the turn's completions"
      true
      (report.usage_scope = Runtime_usage_scope.Turn_total);
    check (option int) "no vendor total" None report.vendor_total_tokens;
    (match report.count with
     | Keeper_client_usage_report.Running_count counted ->
       check int "input verbatim" 100 counted.input_tokens;
       check int "output verbatim" 7 counted.output_tokens;
       (* The cache convention is the provider's; the split is not claimed. *)
       check int "no cache read claimed" 0 counted.cache_read_input_tokens;
       check int "no cache write claimed" 0 counted.cache_creation_input_tokens
     | Keeper_client_usage_report.Count_replaced -> fail "a turn total is a running count")
  | reports -> failf "expected one report, got %d" (List.length reports)
;;

(* ── Error mapping ───────────────────────────────────────────────────── *)

let disposition error =
  Store.failure_disposition (Adapter.recovery_failure_of_runtime_error error)
;;

let starts_fresh_next error =
  match disposition error with
  | Store.Ambiguous | Store.Fatal -> true
  | Store.Transient -> false
;;

let exited ?(turn_accepted = false) status =
  Serve.Process_exited { status; detail = "stderr tail"; turn_accepted }
;;

(* A session another process holds, a refused resume and a resumed session on
   another model would be refused again on the same session. Each leaves a
   recovery observation, and the next claim then starts a fresh session. *)
let test_refusals_of_the_session_start_fresh_next () =
  let lease_held = exited (Some Serve.Exit_session_lease_held) in
  let refused_resume =
    Serve.Rpc_error { method_ = "session/resume"; code = -32004; message = "unknown session" }
  in
  let model_mismatch =
    Serve.Session_model_mismatch { requested = "muse-a"; resumed = "muse-b" }
  in
  List.iter
    (fun (label, error) -> check bool label true (starts_fresh_next error))
    [ "session lease held", lease_held
    ; "resume refused", refused_resume
    ; "resumed on another model", model_mismatch
    ];
  (match Adapter.runtime_error_to_core_error lease_held with
   | Agent_core.Error.Provider
       (Llm_provider.Error.ProviderTerminal
          { kind = Llm_provider.Http_client.Session_conflict; provider = "muse_serve"; _ }) -> ()
   | error -> failf "lease held is a session conflict: %s" (Agent_core.Error.to_string error));
  (* A spawn that never started the host changed nothing on its session. *)
  check bool "spawn failure releases the claim" true
    (disposition (Serve.Spawn_failed "ENOENT") = Store.Transient)
;;

let test_error_projection () =
  (match Adapter.runtime_error_to_core_error (Serve.Auth_required "run muse login") with
   | Agent_core.Error.Provider (Llm_provider.Error.AuthError { detail = "run muse login"; _ }) -> ()
   | error -> failf "auth: %s" (Agent_core.Error.to_string error));
  (match
     Adapter.runtime_error_to_core_error (exited (Some Serve.Exit_config_or_credential))
   with
   | Agent_core.Error.Provider (Llm_provider.Error.AuthError _) -> ()
   | error -> failf "exit 3: %s" (Agent_core.Error.to_string error));
  (match
     Keeper_internal_error.classify_masc_internal_error
       (Adapter.runtime_error_to_core_error (exited ~turn_accepted:true None))
   with
   | Some (Keeper_internal_error.Runtime_connection_closed { turn_accepted = true; _ }) -> ()
   | Some _ | None -> fail "an exited host after turn/start is a closed connection");
  (* Silent after turn/start: the host may still be running the turn, so the
     error stays off the rotation chain. *)
  (match
     Adapter.runtime_error_to_core_error (Serve.Timeout { seconds = 5.; turn_accepted = true })
   with
   | Agent_core.Error.Internal _ -> ()
   | error -> failf "accepted timeout: %s" (Agent_core.Error.to_string error));
  (match
     Adapter.runtime_error_to_core_error (Serve.Timeout { seconds = 5.; turn_accepted = false })
   with
   | Agent_core.Error.Api (Agent_core.Retry.Timeout _) -> ()
   | error -> failf "admission timeout: %s" (Agent_core.Error.to_string error));
  (* The host's [retryable] picks the class: the same input may succeed, so
     the failure is the provider's availability, not its verdict. *)
  (match
     Adapter.runtime_error_to_core_error
       (Serve.Turn_failed { Msp.kind = Msp.Model_error; message = "overloaded"; retryable = true })
   with
   | Agent_core.Error.Provider
       (Llm_provider.Error.ProviderUnavailable { provider = "muse_serve"; _ }) -> ()
   | error -> failf "retryable turn failure: %s" (Agent_core.Error.to_string error));
  match
    Adapter.runtime_error_to_core_error
      (Serve.Turn_failed { Msp.kind = Msp.Step_limit; message = "too many steps"; retryable = false })
  with
  | Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError { error_type = Some "stepLimit"; _ }) -> ()
  | error -> failf "final turn failure: %s" (Agent_core.Error.to_string error)
;;

(* Exit 2 and exit 5 refuse the configuration the host was started with, and
   the same configuration exits the same way again: configuration, not a
   dropped connection. Exit 3 is a refused login or settings file. *)
let test_documented_refusal_exits_are_not_dropped_connections () =
  List.iter
    (fun status ->
       match
         Adapter.runtime_error_to_core_error (exited ~turn_accepted:true (Some status))
       with
       | Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field = "muse_serve"; _ }) -> ()
       | error -> failf "a refusal exit: %s" (Agent_core.Error.to_string error))
    [ Serve.Exit_usage; Serve.Exit_sdk_surface_disabled ];
  let recovery status = Adapter.recovery_failure_of_runtime_error (exited (Some status)) in
  check bool "usage" true (recovery Serve.Exit_usage = Store.Protocol_failed);
  check bool "SDK surface disabled" true
    (recovery Serve.Exit_sdk_surface_disabled = Store.Provider_rejected);
  check bool "config or credential" true
    (recovery Serve.Exit_config_or_credential = Store.Provider_rejected);
  check bool "a crash is still a dropped transport" true
    (recovery (Serve.Exit_code 139) = Store.Transport_interrupted)
;;

(* ── Prompt ──────────────────────────────────────────────────────────── *)

let user_message text : Agent_core.Types.message =
  { role = User; content = [ Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

(* MSP has no system-prompt channel: a start carries the system prompt, the
   history and the goal in one prompt, in that order, and never measures
   more than the window charged for it. *)
let test_start_prompt_frames_and_fits_its_charge () =
  let system_prompt = "MUSE_SYSTEM_PROMPT" in
  let goal = "MUSE_GOAL" in
  let history = [ user_message "history-one"; user_message "history-two" ] in
  match Adapter.start_prompt ~system_prompt ~goal history with
  | Error detail -> fail detail
  | Ok prompt ->
    let positions =
      List.map
        (fun needle -> String_util.find_substring prompt needle)
        [ system_prompt; "history-one"; "history-two"; goal ]
    in
    (match positions with
     | [ Some system; Some first; Some second; Some goal_at ] ->
       check bool "system, history, goal in order" true
         (system < first && first < second && second < goal_at)
     | _ -> fail "a section is missing from the start prompt");
    let charged =
      Adapter.reserved_prompt_bytes ~system_prompt ~goal
      + List.fold_left
          (fun total message -> total + Adapter.measure_model_input_message_bytes message)
          0
          history
    in
    check bool "the prompt fits what the window charged" true (String.length prompt <= charged)
;;

(* ── One turn through a scripted [muse serve] ────────────────────────── *)

let write_file ~mode path contents =
  Out_channel.with_open_bin path (fun output -> output_string output contents);
  Unix.chmod path mode
;;

let temp_workspace () =
  let path = Filename.temp_file "masc-keeper-muse-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  Unix.realpath path
;;

(* The serve client spawns [cli_path serve] in the Keeper's base path; with
   [cli_path = "/bin/sh"] the [serve] file there runs this MSP host. It speaks
   one session per process: a start or a resume and one turn. fixture.json's
   [scenario] says what the turn does; [complete], the default, calls one
   MASC tool through the session's MCP server and runs one built-in tool.
   The others each end the turn one way a real host can. *)
let muse_host_script =
  {|import json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = json.load(open(os.path.join(HERE, "fixture.json")))
SESSION = FIXTURE["session_id"]
SCENARIO = FIXTURE.get("scenario", "complete")
CURSOR = [0]

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(97)
    return json.loads(line)

def cursor():
    CURSOR[0] += 1
    return "v:%d" % CURSOR[0]

def notify(method, params):
    params["viewCursor"] = cursor()
    send({"jsonrpc": "2.0", "method": method, "params": params})

def drain():
    for _ in sys.stdin:
        pass
    sys.exit(0)

init = read()
assert init["method"] == "initialize", init
assert init["params"]["capabilities"]["requestedCapabilities"] == ["sessionMcp"], init
send({"jsonrpc": "2.0", "id": init["id"], "result": {
    "serverInfo": {"name": "muse-session-server", "version": "1.3.0"},
    "userAgent": "muse/1.3.0", "museHome": "/tmp/muse", "platformFamily": "unix",
    "platformOs": "linux", "schema": {"version": 1, "fingerprint": "sha256:fixture"},
    "grantedCapabilities": ["sessionMcp"], "experimentalApi": False,
    "sessionDurability": "durable"}})
assert read()["method"] == "initialized"

opened = read()
if opened["method"] == "session/start":
    assert opened["params"]["approvalMode"] == "denyUnmatched", opened
    assert opened["params"]["workspaceRoot"] == FIXTURE["workspace_root"], opened
    mode = "start"
    # The session runs the model the start named, or the host default.
    model = opened["params"].get("modelId") or "muse-fixture-1"
else:
    assert opened["method"] == "session/resume", opened
    assert opened["params"]["sessionId"] == SESSION, opened
    mode = "resume"
    # What the session's record names; null when it omits the model.
    model = FIXTURE.get("resume_model_id", "muse-fixture-1")
with open(os.path.join(HERE, "sessions.log"), "a") as handle:
    handle.write(mode + "\n")
server = opened["params"]["config"]["mcpServers"]["masc"]
assert server["transport"] == "streamableHttp" and server["mode"] == "required", server
send({"jsonrpc": "2.0", "id": opened["id"], "result": {"session": {
    "sessionId": SESSION, "status": "idle", "turnCount": 0, "modelId": model,
    "workspaceRoot": FIXTURE["workspace_root"]}, "viewCursor": cursor()}})
if mode == "resume":
    approval = read()
    assert approval["method"] == "session/setApprovalMode", approval
    assert approval["params"]["mode"] == "denyUnmatched", approval
    send({"jsonrpc": "2.0", "id": approval["id"], "result": {}})

headers = dict(server["headers"])
headers["Content-Type"] = "application/json"
headers["Accept"] = "application/json, text/event-stream"

def post(message, protocol=None):
    current = dict(headers)
    if protocol is not None:
        current["MCP-Protocol-Version"] = protocol
    request = urllib.request.Request(server["url"], data=json.dumps(message).encode(),
                                     headers=current, method="POST")
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read()
        return None if not body else json.loads(body)

version = "2025-11-25"
post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": version, "capabilities": {},
    "clientInfo": {"name": "muse-fixture", "version": "1"}}})
post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, version)
tools = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, version)
assert [tool["name"] for tool in tools["result"]["tools"]] == ["masc_probe"], tools

def call_probe():
    called = post({"jsonrpc": "2.0", "id": "call-1", "method": "tools/call", "params": {
        "name": "masc_probe", "arguments": {"marker": "from-muse"}}}, version)
    assert called["result"]["content"][0]["text"] == "MASC_TOOL_RESULT", called

turn = read()
assert turn["method"] == "turn/start", turn
turn_id = turn["params"]["commandId"]
text = [part["text"] for part in turn["params"]["input"] if part["type"] == "text"][0]
with open(os.path.join(HERE, mode + "-prompt.txt"), "w") as handle:
    handle.write(text)
with open(os.path.join(HERE, mode + "-turn-id.txt"), "w") as handle:
    handle.write(turn_id)

def acknowledge(disposition="started"):
    send({"jsonrpc": "2.0", "id": turn["id"], "result": {
        "commandId": turn_id, "status": "accepted", "turnId": turn_id,
        "startedNewTurn": disposition == "started", "disposition": disposition}})
    if disposition == "started":
        notify("turn/started", {"sessionId": SESSION, "turnId": turn_id,
                                "commandId": turn_id})

def tool_item(item_id, tool, call_id, status, revision, args="{}"):
    return {"itemId": item_id, "kind": "toolCall", "turnId": turn_id, "revision": revision,
            "status": status, "tool": tool, "callId": call_id, "args": args}

def item(method, value):
    notify(method, {"sessionId": SESSION, "item": value})

def built_in_tool(item_id, tool, call_id):
    item("item/started", tool_item(item_id, tool, call_id, "inProgress", 1))
    item("item/completed", tool_item(item_id, tool, call_id, "completed", 2))

if SCENARIO == "refuse_turn":
    send({"jsonrpc": "2.0", "id": turn["id"],
          "error": {"code": -32602, "message": "fixture refusal"}})
    drain()
if SCENARIO == "queued":
    acknowledge("queued")
    drain()
if SCENARIO == "stop_before_ack":
    # The turn runs and calls MASC's tool before the serve client reads the
    # answer, which the host wrote first.
    call_probe()
    acknowledge()
    drain()
acknowledge()
if SCENARIO == "hang":
    drain()
if SCENARIO == "exit_mid_turn":
    item("item/started", tool_item("tc-1", "write_file", "call-native-1", "inProgress", 1))
    sys.exit(1)
if SCENARIO == "turn_failed":
    built_in_tool("tc-1", "read_file", "call-native-1")
    notify("turn/completed", {"sessionId": SESSION, "turnId": turn_id, "terminal": "failed",
                              "error": {"kind": "modelError",
                                        "message": "provider returned 503",
                                        "retryable": True}})
    drain()
assert SCENARIO == "complete", SCENARIO
item("item/started", {"itemId": "m-1", "kind": "agentMessage", "turnId": turn_id,
                      "revision": 1, "status": "inProgress", "text": ""})
notify("item/delta", {"sessionId": SESSION, "itemId": "m-1", "field": "text",
                      "delta": "MASC_"})
# A toolCall item names no MCP server, so the host reports MASC's own call as
# one too.
probe_args = json.dumps({"marker": "from-muse"})
item("item/started", tool_item("tc-mcp", "mcp__masc__masc_probe", "call-mcp-1",
                               "inProgress", 1, probe_args))
call_probe()
item("item/completed", tool_item("tc-mcp", "mcp__masc__masc_probe", "call-mcp-1",
                                 "completed", 2, probe_args))
built_in_tool("tc-1", "read_file", "call-native-1")
notify("item/delta", {"sessionId": SESSION, "itemId": "m-1", "field": "text",
                      "delta": "MUSE_KEEPER_OK"})
item("item/completed", {"itemId": "m-1", "kind": "agentMessage", "turnId": turn_id,
                        "revision": 2, "status": "completed", "text": "MASC_MUSE_KEEPER_OK"})
notify("turn/completed", {"sessionId": SESSION, "turnId": turn_id, "terminal": "completed",
                          "usage": {"inputTokens": 100, "outputTokens": 7,
                                    "cachedTokens": 50, "reasoningTokens": 3}})
drain()
|}
;;

(* Muse Code has no runtime.toml protocol before stack step 4/5. This
   declaration exists so [Runtime_inference] can answer the capacity the
   adapter requires; its provider is never spawned. *)
let runtime_toml =
  {|[providers.muse_fixture]
protocol = "codex-app-server"
command = "/bin/sh"
is-non-interactive = true

[models.fixture]
api-name = "muse-fixture-1"
max-context = 200000
max-prompt-bytes = 1048576

[muse_fixture.fixture]

[runtime]
default = "muse_fixture.fixture"
|}
;;

let runtime_id = "muse_fixture.fixture"
let keeper_name = "muse-fixture"

type observed_run =
  { outcome : Keeper_muse_runtime.attempt_outcome
  ; events : Agent_core.Types.sse_event list
  ; reports : Keeper_client_usage_report.t list
  ; transmitted : Keeper_official_client_host.transmitted_model_input list
  ; native_actions : (int * string) list
  }

(* [on_stream_event] sees each Keeper stream event as it is emitted. *)
let run_turn_with ?model ?on_official_client_tool_boundary
    ?(on_stream_event = fun (_ : Agent_core.Types.sse_event) -> ()) ~base_path ~tool () =
  let events = ref [] in
  let reports = ref [] in
  let transmitted = ref [] in
  let native_actions = ref [] in
  let config =
    { (Serve.default_config ()) with
      cli_path = "/bin/sh"
    ; model
    ; admission_timeout_s = 20.
    ; timeout_s = Some 20.
    }
  in
  let outcome =
    Keeper_muse_runtime.run
      ~accepts_image_input:false
      ~runtime_id
      ~keeper_name
      ~pre_tool_rejects:(ref [])
      ~base_path
      ~goal:"Call masc_probe once"
      ~goal_blocks:None
      ~system_prompt:"MUSE_FIXTURE_SYSTEM_PROMPT"
      ~tools:[ tool ]
      ~initial_messages:[ user_message "MUSE_FIXTURE_HISTORY" ]
      ~model_input_projection:None
      ~on_transmitted_model_input:(fun input -> transmitted := input :: !transmitted)
      ~hooks:None
      ~context_injector:None
      ~context:(Some (Agent_core.Context.create ()))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ?on_official_client_tool_boundary
      ~on_native_action:(fun ~official_turn ~identity ~tool_name ->
        match identity with
        | Runtime_native_tools.Call_id call_id ->
          native_actions := (official_turn, call_id ^ ":" ^ tool_name) :: !native_actions
        | Runtime_native_tools.Provider_step _ -> fail "Muse Code reports call ids")
      ~on_usage_report:(fun report -> reports := report :: !reports)
      ~event_bus:None
      ~raw_trace:None
      ~on_event:
        (Some
           (fun event ->
              events := event :: !events;
              on_stream_event event))
      ~config
      ()
  in
  { outcome
  ; events = List.rev !events
  ; reports = List.rev !reports
  ; transmitted = List.rev !transmitted
  ; native_actions = List.rev !native_actions
  }
;;

let run_turn ~base_path ~tool = run_turn_with ~base_path ~tool ()

let read_text path = In_channel.with_open_bin path In_channel.input_all

let response_text (result : Runtime_agent.run_result) =
  result.response.content
  |> List.filter_map (function Agent_core.Types.Text text -> Some text | _ -> None)
  |> String.concat ""
;;

let check_stream label events =
  match events with
  | Agent_core.Types.MessageStart { model = "muse-fixture-1"; _ } :: rest ->
    (match List.rev rest with
     | MessageStop :: MessageDelta { stop_reason = Some EndTurn; _ } :: _ ->
       let starts =
         List.filter_map
           (function Agent_core.Types.ContentBlockStart { content_type; _ } -> Some content_type | _ -> None)
           rest
       in
       let count value = List.length (List.filter (String.equal value) starts) in
       check int (label ^ ": one MASC tool block") 1 (count "tool_use");
       (* MSP names no MCP server on a [toolCall] item, so the host's item for
          MASC's own call is a built-in block beside [read_file]'s. *)
       check int (label ^ ": two built-in tool blocks") 2
         (count Runtime_native_tools.stream_content_type);
       check int (label ^ ": no other block") 3 (List.length starts)
     | _ -> fail (label ^ ": the stream did not end with EndTurn and MessageStop"))
  | _ -> fail (label ^ ": the stream did not open with MessageStart")
;;

let settled_turn ~base_path =
  match Store.load ~base_path ~keeper_name with
  | Ok (Some { client_kind = Store.Muse; phase = Store.Settled { session_id; turn_id }; turn_count; _ }) ->
    session_id, turn_id, turn_count
  | Ok (Some { client_kind = Store.Codex | Store.Claude_code | Store.Antigravity; _ }) ->
    fail "the session was recorded under another client"
  | Ok
      (Some
         { client_kind = Store.Muse
         ; phase =
             ( Store.Ready
             | Store.Start _
             | Store.Active _
             | Store.Turn_inflight _
             | Store.Recovery_required _ )
         ; _
         }) -> fail "the Muse Code session did not settle"
  | Ok None -> fail "no session was recorded"
  | Error detail -> fail detail
;;

(* A workspace holding the scripted host, its fixture and the runtime.toml,
   with the fixture keeper declared. Returns the runtime.toml path. *)
let prepare_scripted_host ~base_path =
  Unix.mkdir (Filename.concat base_path ".masc") 0o700;
  Masc_test_deps.declare_fixture_keeper ~base_path ~sandbox_profile:None keeper_name;
  write_file ~mode:0o600 (Filename.concat base_path "muse_host.py") muse_host_script;
  write_file ~mode:0o600 (Filename.concat base_path "serve") "exec python3 ./muse_host.py\n";
  write_file ~mode:0o600 (Filename.concat base_path "fixture.json")
    (Yojson.Safe.to_string
       (`Assoc [ "session_id", `String session_id; "workspace_root", `String base_path ]));
  let runtime_path = Filename.concat base_path "runtime.toml" in
  write_file ~mode:0o600 runtime_path runtime_toml;
  runtime_path
;;

(* The MASC tool the scripted host calls once; [observed_input] receives its
   arguments. *)
let masc_probe_tool observed_input =
  let marker : Agent_core.Types.tool_param =
    { name = "marker"; description = "Fixture marker"; param_type = String; required = true }
  in
  Agent_core.Tool.create
    ~name:"masc_probe"
    ~description:"Return a deterministic fixture marker"
    ~parameters:[ marker ]
    (fun input ->
       observed_input := input;
       Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
;;

let test_turn_through_scripted_host () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> try Fs_compat.remove_tree base_path with _ -> ())
    (fun () ->
      let runtime_path = prepare_scripted_host ~base_path in
      let observed_input = ref `Null in
      let tool = masc_probe_tool observed_input in
      let snapshot = Runtime.For_testing.snapshot () in
      Fun.protect
        ~finally:(fun () -> Runtime.For_testing.restore snapshot)
        (fun () ->
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Eio_context.set_env env;
              Eio_context.with_test_env
                ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env)
                ~mono_clock:(Eio.Stdenv.mono_clock env)
                ~sw
                (fun () ->
                  (match Runtime.init_default ~config_path:runtime_path with
                   | Ok () -> ()
                   | Error detail -> fail detail);
                  let first = run_turn ~base_path ~tool in
                  (match first.outcome.result with
                   | Error error -> fail (Agent_core.Error.to_string error)
                   | Ok result ->
                     check string "reply" "MASC_MUSE_KEEPER_OK" (response_text result);
                     check (option bool) "a started session" (Some false) result.session_resumed;
                     let turn_id = read_text (Filename.concat base_path "start-turn-id.txt") in
                     check string "response keyed by the MSP turn id" turn_id result.response.id;
                     let settled_session, settled_turn_id, turn_count = settled_turn ~base_path in
                     check string "settled session" session_id settled_session;
                     check string "settled turn" turn_id settled_turn_id;
                     check int "first ordinal" 1 turn_count;
                     (match result.runtime_observation with
                      | Some observation ->
                        check bool "turn total" true
                          (observation.usage_scope = Runtime_usage_scope.Turn_total)
                      | None -> fail "runtime observation missing"));
                  check bool "settled session returned" true
                    (Option.is_some first.outcome.settled_session);
                  check bool "the MASC tool closed the retry boundary" true
                    (first.outcome.effect_disposition = Keeper_provider_attempt_effect.Effect_attempted);
                  check string "tool input reached MASC"
                    {|{"marker":"from-muse"}|}
                    (Yojson.Safe.to_string !observed_input);
                  check_stream "start" first.events;
                  check (list (pair int string)) "built-in actions, MASC's own call among them"
                    [ 1, "call-mcp-1:mcp__masc__masc_probe"; 1, "call-native-1:read_file" ]
                    first.native_actions;
                  (match first.reports with
                   | [ report ] ->
                     check bool "reported as the turn total" true
                       (report.usage_scope = Runtime_usage_scope.Turn_total);
                     check string "report conversation" session_id report.conversation_id
                   | reports -> failf "expected one usage report, got %d" (List.length reports));
                  (match first.transmitted with
                   | [ Keeper_official_client_host.Whole_input_transmitted _ ] -> ()
                   | _ -> fail "a start transmits the whole input once");
                  let prompt = read_text (Filename.concat base_path "start-prompt.txt") in
                  check bool "system prompt framed into the start" true
                    (String_util.contains_substring prompt "MUSE_FIXTURE_SYSTEM_PROMPT");
                  check bool "history framed into the start" true
                    (String_util.contains_substring prompt "MUSE_FIXTURE_HISTORY");
                  (* The settled session is resumed: the host holds the
                     history, and a new bridge serves the next turn. *)
                  let second = run_turn ~base_path ~tool in
                  (match second.outcome.result with
                   | Error error -> fail (Agent_core.Error.to_string error)
                   | Ok result ->
                     check (option bool) "a resumed session" (Some true) result.session_resumed;
                     let turn_id = read_text (Filename.concat base_path "resume-turn-id.txt") in
                     let _, settled_turn_id, turn_count = settled_turn ~base_path in
                     check string "resumed turn settled" turn_id settled_turn_id;
                     check int "second ordinal" 2 turn_count);
                  (match second.transmitted with
                   | [ Keeper_official_client_host.Held_by_client_session ] -> ()
                   | _ -> fail "a resume leaves the history with the host");
                  check_stream "resume" second.events;
                  let resumed_prompt = read_text (Filename.concat base_path "resume-prompt.txt") in
                  check bool "a resume does not resend the system prompt" false
                    (String_util.contains_substring resumed_prompt "MUSE_FIXTURE_SYSTEM_PROMPT"))))))
;;

(* ── What each way a turn ends leaves behind ─────────────────────────── *)

let write_fixture ~base_path members =
  write_file ~mode:0o600 (Filename.concat base_path "fixture.json")
    (Yojson.Safe.to_string
       (`Assoc
          ([ "session_id", `String session_id; "workspace_root", `String base_path ]
           @ members)))
;;

(* [f] runs in a prepared workspace under the Eio environment and the fixture
   runtime.toml, with [fixture] added to fixture.json. *)
let with_scripted_host ?(fixture = []) f =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> try Fs_compat.remove_tree base_path with _ -> ())
    (fun () ->
      let runtime_path = prepare_scripted_host ~base_path in
      write_fixture ~base_path fixture;
      let snapshot = Runtime.For_testing.snapshot () in
      Fun.protect
        ~finally:(fun () -> Runtime.For_testing.restore snapshot)
        (fun () ->
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Eio_context.set_env env;
              Eio_context.with_test_env
                ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env)
                ~mono_clock:(Eio.Stdenv.mono_clock env)
                ~sw
                (fun () ->
                  (match Runtime.init_default ~config_path:runtime_path with
                   | Ok () -> ()
                   | Error detail -> fail detail);
                  f ~base_path)))))
;;

let scenario name = [ "scenario", `String name ]

(* The recovery row a failed turn left: its failure and the host turn it
   names. *)
let recovery_row ~base_path =
  match Store.load ~base_path ~keeper_name with
  | Ok (Some { phase = Store.Recovery_required { failure; observed_turn_id; _ }; _ }) ->
    failure, observed_turn_id
  | Ok
      (Some
         { phase =
             ( Store.Ready
             | Store.Start _
             | Store.Active _
             | Store.Turn_inflight _
             | Store.Settled _ )
         ; _
         }) -> fail "the failed turn left no recovery row"
  | Ok None -> fail "no session was recorded"
  | Error detail -> fail detail
;;

let check_failure label expected actual =
  check string label
    (Store.recovery_failure_to_string expected)
    (Store.recovery_failure_to_string actual)
;;

let check_effect label expected (outcome : Keeper_muse_runtime.attempt_outcome) =
  check string label
    (Keeper_provider_attempt_effect.to_string expected)
    (Keeper_provider_attempt_effect.to_string outcome.effect_disposition)
;;

let started_turn_id ~base_path = read_text (Filename.concat base_path "start-turn-id.txt")

(* The host exits after it started a built-in write. The recovery row names
   the turn the host acknowledged, and the attempt cannot claim it was
   effect-free. *)
let test_a_host_that_exits_mid_turn_leaves_recovery () =
  with_scripted_host ~fixture:(scenario "exit_mid_turn") (fun ~base_path ->
    let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
    (match run.outcome.result with
     | Ok _ -> fail "a host that exited cannot complete the turn"
     | Error error ->
       (match Keeper_internal_error.classify_masc_internal_error error with
        | Some (Keeper_internal_error.Runtime_connection_closed { turn_accepted = true; _ }) -> ()
        | Some _ | None -> failf "exit mid-turn: %s" (Agent_core.Error.to_string error)));
    check_effect "effects unknown" Keeper_provider_attempt_effect.Observation_unavailable
      run.outcome;
    let failure, observed_turn = recovery_row ~base_path in
    check_failure "a dropped transport" Store.Transport_interrupted failure;
    check (option string) "names the acknowledged turn"
      (Some (started_turn_id ~base_path)) observed_turn)
;;

(* The host fails the turn after a built-in read and judges the same input may
   succeed. The failure is the provider's availability, and the turn ran, so
   the attempt is not effect-free. *)
let test_a_failed_turn_after_a_built_in_tool_is_not_effect_free () =
  with_scripted_host ~fixture:(scenario "turn_failed") (fun ~base_path ->
    let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
    (match run.outcome.result with
     | Error (Agent_core.Error.Provider (Llm_provider.Error.ProviderUnavailable _)) -> ()
     | Error error -> failf "retryable failure: %s" (Agent_core.Error.to_string error)
     | Ok _ -> fail "a failed turn cannot succeed");
    check_effect "effects unknown" Keeper_provider_attempt_effect.Observation_unavailable
      run.outcome;
    let failure, observed_turn = recovery_row ~base_path in
    check_failure "a provider refusal" Store.Provider_rejected failure;
    check (option string) "names the turn" (Some (started_turn_id ~base_path)) observed_turn)
;;

(* The host answers turn/start with an error: it did not take the turn, so
   the attempt stays effect-free. *)
let test_a_refused_turn_start_stays_effect_free () =
  with_scripted_host ~fixture:(scenario "refuse_turn") (fun ~base_path ->
    let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
    (match run.outcome.result with
     | Error
         (Agent_core.Error.Provider
           (Llm_provider.Error.ProviderReportedError { error_type = Some "rpc_error"; _ })) -> ()
     | Error error -> failf "refused turn/start: %s" (Agent_core.Error.to_string error)
     | Ok _ -> fail "a refused turn cannot succeed");
    check_effect "no effect" Keeper_provider_attempt_effect.No_effect_observed run.outcome;
    let failure, observed_turn = recovery_row ~base_path in
    check_failure "a protocol failure" Store.Protocol_failed failure;
    check (option string) "no turn to name" None observed_turn)
;;

(* The host queued the turn/start instead of starting it. It took the
   command in, so the attempt cannot claim it was effect-free. *)
let test_a_queued_turn_start_is_not_effect_free () =
  with_scripted_host ~fixture:(scenario "queued") (fun ~base_path ->
    let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
    (match run.outcome.result with
     | Error (Agent_core.Error.Provider (Llm_provider.Error.ParseError _)) -> ()
     | Error error -> failf "queued turn/start: %s" (Agent_core.Error.to_string error)
     | Ok _ -> fail "a queued turn is not this turn");
    check_effect "effects unknown" Keeper_provider_attempt_effect.Observation_unavailable
      run.outcome;
    let failure, observed_turn = recovery_row ~base_path in
    check_failure "a protocol failure" Store.Protocol_failed failure;
    check (option string) "no acknowledged turn" None observed_turn)
;;

(* A MASC tool asks to stop the turn before the serve client has read the
   host's turn/start answer. The stop waits for the answer and settles the
   turn under the answer's turn id. *)
let test_a_stop_before_the_turn_start_answer_settles () =
  with_scripted_host ~fixture:(scenario "stop_before_ack") (fun ~base_path ->
    let run =
      run_turn_with
        ~on_official_client_tool_boundary:(fun () ->
          Ok (Some Keeper_official_client_host.Queued_chat_operation))
        ~base_path
        ~tool:(masc_probe_tool (ref `Null))
        ()
    in
    (match run.outcome.result with
     | Ok { Runtime_agent.stop_reason = Runtime_agent.Yielded_to_operation_queued _; _ } -> ()
     | Ok _ -> fail "the stop did not yield to the queued operation"
     | Error error -> fail (Agent_core.Error.to_string error));
    let settled_session, settled_turn_id, _ = settled_turn ~base_path in
    check string "settled session" session_id settled_session;
    check string "settled under the answer's turn id" (started_turn_id ~base_path)
      settled_turn_id)
;;

(* The Keeper fiber is cancelled while the host runs the turn. The claim does
   not stay in flight under this process's epoch, where it would refuse every
   later turn: it becomes a recovery row naming the turn. *)
let test_a_cancelled_turn_leaves_recovery () =
  with_scripted_host ~fixture:(scenario "hang") (fun ~base_path ->
    let message_started, start_message = Eio.Promise.create () in
    Eio.Fiber.first
      (fun () ->
         let (_ : observed_run) =
           run_turn_with
             ~on_stream_event:(function
               | Agent_core.Types.MessageStart _ ->
                 (match Eio.Promise.try_resolve start_message () with
                  | true | false -> ())
               | _ -> ())
             ~base_path
             ~tool:(masc_probe_tool (ref `Null))
             ()
         in
         fail "the hanging turn returned")
      (fun () -> Eio.Promise.await message_started);
    let failure, observed_turn = recovery_row ~base_path in
    check_failure "an unexplained cancel is a dropped transport" Store.Transport_interrupted
      failure;
    check (option string) "names the acknowledged turn"
      (Some (started_turn_id ~base_path)) observed_turn)
;;

(* A changed model starts a fresh session instead of resuming one the serve
   client would refuse. A resume on the same model runs even when the host's
   record names no model. *)
let test_a_changed_model_starts_a_fresh_session () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    let turn label model =
      match (run_turn_with ~model ~base_path ~tool ()).outcome.result with
      | Ok _ -> ()
      | Error error -> failf "%s: %s" label (Agent_core.Error.to_string error)
    in
    turn "first turn on muse-a" "muse-a";
    turn "first turn on muse-b" "muse-b";
    write_fixture ~base_path [ "resume_model_id", `Null ];
    turn "second turn on muse-b" "muse-b";
    check (list string) "sessions the host opened" [ "start"; "start"; "resume" ]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n'
       |> List.filter (fun line -> line <> "")))
;;

let () =
  run
    "keeper_muse_runtime"
    [ ( "stream"
      , [ test_case "projection order" `Quick test_stream_order
        ; test_case "unstreamed reply is forwarded at the end" `Quick
            test_unstreamed_reply_is_forwarded_at_the_end
        ; test_case "a second message starts a paragraph" `Quick
            test_a_second_message_starts_a_paragraph
        ; test_case "MCP blocks wait for MessageStart" `Quick test_mcp_blocks_wait_for_message_start
        ; test_case "MCP block arriving during MessageStart" `Quick
            test_mcp_block_arriving_during_message_start
        ] )
    ; ( "usage"
      , [ test_case "turn/completed usage is the turn total" `Quick
            test_usage_report_is_the_turn_total
        ] )
    ; ( "errors"
      , [ test_case "session refusals start fresh next" `Quick
            test_refusals_of_the_session_start_fresh_next
        ; test_case "error projection" `Quick test_error_projection
        ; test_case "documented refusal exits are not dropped connections" `Quick
            test_documented_refusal_exits_are_not_dropped_connections
        ] )
    ; ( "prompt"
      , [ test_case "start prompt frames and fits its charge" `Quick
            test_start_prompt_frames_and_fits_its_charge
        ] )
    ; ( "scripted host"
      , [ test_case "start and resume through muse serve with a MASC tool" `Quick
            test_turn_through_scripted_host
        ] )
    ; ( "turn endings"
      , [ test_case "a host that exits mid-turn leaves recovery" `Quick
            test_a_host_that_exits_mid_turn_leaves_recovery
        ; test_case "a failed turn after a built-in tool is not effect-free" `Quick
            test_a_failed_turn_after_a_built_in_tool_is_not_effect_free
        ; test_case "a refused turn/start stays effect-free" `Quick
            test_a_refused_turn_start_stays_effect_free
        ; test_case "a queued turn/start is not effect-free" `Quick
            test_a_queued_turn_start_is_not_effect_free
        ; test_case "a stop before the turn/start answer settles" `Quick
            test_a_stop_before_the_turn_start_answer_settles
        ; test_case "a cancelled turn leaves recovery" `Quick
            test_a_cancelled_turn_leaves_recovery
        ; test_case "a changed model starts a fresh session" `Quick
            test_a_changed_model_starts_a_fresh_session
        ] )
    ]
;;
