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
  { input_tokens = 100; output_tokens = 7; cached_tokens = 50; reasoning_tokens = 3;
    prompt_tokens = None; cache_read_tokens = None; cache_write_tokens = None }
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
let test_native_tool_without_identity_does_not_open_a_block () =
  let observation = {(native_observation "ignored") with Runtime_native_tools.identity=None} in
  match Adapter.project_stream [turn_started; Serve.Native_tool_started observation;
    Serve.Native_tool_finished observation; Serve.Turn_finished {text=""}] with
  | [MessageStart _; MessageDelta _; MessageStop] -> ()
  | _ -> fail "identity-less native observation opened an unclosable stream block"
;;

let test_persistence_cause_survives_callback_protocol_projection () =
  check bool "typed persistence evidence survives callback wrapping" true
    (Adapter.recovery_failure_of_runtime_error ~current:Store.State_persistence_failed
      (Serve.Protocol_error {stage="session-ready callback"; detail="fixture persistence failure"})
      = Store.State_persistence_failed)
;;

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

let test_completed_message_suffix_is_forwarded_once () =
  let events = Adapter.project_stream [turn_started;
    Serve.Text_delta {item_id="first"; text="partial"};
    Serve.Text_completed {item_id="first"; text="partial rest"};
    Serve.Text_completed {item_id="first"; text="partial rest"};
    Serve.Turn_finished {text="partial rest"}] in
  let text = List.filter_map (function
    | Agent_core.Types.ContentBlockDelta {delta=TextDelta text; _} -> Some text
    | _ -> None) events |> String.concat "" in
  check string "completion and turn finalization never repeat a suffix" "partial rest" text
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

(* The turn's usage belongs to the model the host named for its calls, not
   the session's selection. *)
let test_usage_report_names_the_model_the_calls_ran_on () =
  match
    Adapter.usage_reports
      ~turn_count:4
      ~position:Keeper_usage_resolution.Resumed
      [ turn_started
      ; Serve.Model_call_reported
          { session_id; turn_id = "turn-1"; model = Some "muse-fixture-contributor" }
      ; Serve.Usage_reported { session_id; turn_id = "turn-1"; usage }
      ]
  with
  | [ report ] -> check string "model the calls ran on" "muse-fixture-contributor" report.model
  | reports -> failf "expected one report, got %d" (List.length reports)
;;

(* A named call, then one whose model the host did not name: the turn's
   usage is not the earlier model's. With no configured model the row falls
   back to the runtime id. *)
let test_usage_report_after_an_unnamed_call_is_not_the_earlier_model () =
  match
    Adapter.usage_reports
      ~turn_count:4
      ~position:Keeper_usage_resolution.Resumed
      [ turn_started
      ; Serve.Model_call_reported
          { session_id; turn_id = "turn-1"; model = Some "muse-fixture-contributor" }
      ; Serve.Model_call_reported { session_id; turn_id = "turn-1"; model = None }
      ; Serve.Usage_reported { session_id; turn_id = "turn-1"; usage }
      ]
  with
  | [ report ] -> check string "no model claimed for the last call" "muse.test" report.model
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
    Serve.Session_model_mismatch { requested = "muse-a"; resumed = Some "muse-b" }
  in
  List.iter
    (fun (label, error) -> check bool label true (starts_fresh_next error))
    [ "session lease held", lease_held
    ; "resume refused", refused_resume
    ; "resumed on another model", model_mismatch
    ; "returned another workspace", Serve.Session_workspace_mismatch
        {requested="/requested"; reported=Some "/other"}
    ; "returned an unsafe approval mode", Serve.Session_approval_mode_mismatch
        {requested=Msp.Prompt_unmatched; reported=Some Msp.Allow_all}
    ; "terminal nonretryable failure", Serve.Turn_failed
        {Msp.kind=Msp.Step_limit; message="fixture refusal"; retryable=false}
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

(* The serve client spawns [cli_path serve] in the Keeper's playground; the
   fixture's [muse] launcher runs this MSP host from the base path, where it
   records what it saw. It speaks one session per process: a start or a
   resume and one turn. fixture.json's
   [scenario] says what the turn does; [complete], the default, asks MASC to
   approve one MASC tool and one built-in read, calls the MASC tool through
   the session's MCP server and runs the built-in tool, recording each
   answer in decisions.log. The others each end the turn one way a real host
   can. *)
let muse_host_script =
  {|import json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "selected-home.txt"), "w") as handle:
    handle.write(os.environ["HOME"])
with open(os.path.join(HERE, "managed-config.txt"), "w") as handle:
    handle.write(os.environ["XDG_CONFIG_HOME"])
FIXTURE = json.load(open(os.path.join(HERE, "fixture.json")))
SESSION = FIXTURE["session_id"]
SCENARIO = FIXTURE.get("scenario", "complete")
CURSOR = [0]
COUNT_PATH = os.path.join(HERE, "host-turn-count.txt")
with open(os.path.join(HERE, "cwd.txt"), "w") as handle:
    handle.write(os.getcwd())

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
    if method == "turn/completed":
        with open(COUNT_PATH, "w") as handle:
            handle.write(str(completed_turns + 1))
    params["viewCursor"] = cursor()
    send({"jsonrpc": "2.0", "method": method, "params": params})

def drain():
    for _ in sys.stdin:
        pass
    sys.exit(0)

init = read()
assert init["method"] == "initialize", init
if SCENARIO == "hang_init":
    drain()
requested_capabilities = init["params"]["capabilities"]["requestedCapabilities"]
expected_capabilities = [] if SCENARIO == "text_only" or (FIXTURE.get("usage_read_only") and requested_capabilities == []) else ["sessionMcp"]
assert init["params"]["capabilities"]["requestedCapabilities"] == expected_capabilities, init
send({"jsonrpc": "2.0", "id": init["id"], "result": {
    "serverInfo": {"name": "muse-session-server", "version": "1.3.0"},
    "userAgent": "muse/1.3.0", "museHome": "/tmp/muse", "platformFamily": "unix",
    "platformOs": "linux", "schema": {"version": 1, "fingerprint": "sha256:fixture"},
    "grantedCapabilities": [] if SCENARIO == "deny_capability" else expected_capabilities,
    "experimentalApi": False,
    "sessionDurability": "durable"}})
if SCENARIO == "deny_capability":
    drain()
assert read()["method"] == "initialized"

opened = read()
if opened["method"] == "usage/read":
    assert FIXTURE.get("usage_read_only"), opened
    with open(os.path.join(HERE, "usage-read.log"), "a") as handle:
        handle.write("usage/read\n")
    send({"jsonrpc": "2.0", "id": opened["id"],
          "result": {"usage": FIXTURE.get("subscription_usage")}})
    drain()
if opened["method"] == "session/start":
    assert opened["params"]["approvalMode"] == "promptUnmatched", opened
    with open(os.path.join(HERE, "start-root.txt"), "w") as handle:
        handle.write(opened["params"]["workspaceRoot"])
    assert opened["params"]["workspaceRoot"] == FIXTURE["workspace_root"], opened
    mode = "start"
    completed_turns = 0
    with open(COUNT_PATH, "w") as handle:
        handle.write("0")
    # The session runs the model the start named, or the host default.
    model = opened["params"].get("modelId") or "muse-fixture-1"
else:
    assert opened["method"] == "session/resume", opened
    assert opened["params"]["sessionId"] == SESSION, opened
    mode = "resume"
    with open(COUNT_PATH) as handle:
        completed_turns = int(handle.read())
    # What the session's record names; null when it omits the model.
    model = FIXTURE.get("resume_model_id", "muse-fixture-1")
with open(os.path.join(HERE, "sessions.log"), "a") as handle:
    handle.write(mode + "\n")
servers = opened["params"].get("config", {}).get("mcpServers", {})
if SCENARIO == "text_only":
    assert servers == {}, servers
    server = None
else:
    server = servers["masc"]
    assert server["transport"] == "streamableHttp" and server["mode"] == "required", server
if SCENARIO == "hang_session":
    drain()
count_key = "start_turn_count" if mode == "start" else "resume_turn_count"
send({"jsonrpc": "2.0", "id": opened["id"], "result": {"session": {
    "sessionId": SESSION, "status": "idle",
    "turnCount": FIXTURE.get(count_key, completed_turns), "modelId": model,
    "approvalMode": {"mode": "promptUnmatched", "source": "startup", "lastCommandId": None},
    "workspaceRoot": FIXTURE["workspace_root"]}, "viewCursor": cursor()}})
if mode == "resume":
    approval = read()
    if approval["method"] == "session/setModel":
        # The selection applies to the session's next model calls. The host
        # can refuse it; the fixture says when.
        selected = approval["params"]["model"]["modelId"]
        assert approval["params"]["sessionId"] == SESSION, approval
        with open(os.path.join(HERE, "model-selections.log"), "a") as handle:
            handle.write(selected + "\n")
        if FIXTURE.get("refuse_selection", False):
            send({"jsonrpc": "2.0", "id": approval["id"],
                  "error": {"code": -32602, "message": "unknown model"}})
            drain()
        send({"jsonrpc": "2.0", "id": approval["id"], "result": {
            "commandId": approval["params"]["commandId"], "status": "accepted"}})
        approval = read()
    assert approval["method"] == "session/setApprovalMode", approval
    assert approval["params"]["mode"] == "promptUnmatched", approval
    send({"jsonrpc": "2.0", "id": approval["id"], "result": {
        "status": "accepted", "commandId": approval["params"]["commandId"], "applyOutcome": "noop",
        "effectiveMode": {"mode": "promptUnmatched", "source": "approvalReconfigure",
                          "lastCommandId": approval["params"]["commandId"]}}})

headers = dict(server["headers"]) if server else {}
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
if server is not None:
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
if "expected_effort" in FIXTURE:
    assert turn["params"]["reasoningEffort"] == FIXTURE["expected_effort"]
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
        if mode == "start" and "start_compaction" in FIXTURE:
            item("item/completed", {"itemId": "compact-1", "kind": "compaction",
                 "turnId": turn_id, "status": "completed", "revision": 1,
                 "trigger": "auto", "outcome": FIXTURE["start_compaction"]})
        if "subscription_usage" in FIXTURE and not FIXTURE.get("suppress_turn_usage_notification"):
            notify("usage/changed", FIXTURE["subscription_usage"])
        # One session/tokenUsage per model call; null names no model.
        for model in FIXTURE.get("call_models", []):
            usage = {"sessionId": SESSION, "turnId": turn_id,
                     "usage": {"inputTokens": 1, "outputTokens": 1,
                               "cachedTokens": 0, "reasoningTokens": 0},
                     "promptTokens": 1, "totalTokens": 2}
            if model is not None:
                usage["modelId"] = model
            notify("session/tokenUsage", usage)
        for usage in FIXTURE.get("model_usage", []):
            notify("session/tokenUsage", dict(usage, sessionId=SESSION, turnId=turn_id))

def tool_item(item_id, tool, call_id, status, revision, args="{}"):
    return {"itemId": item_id, "kind": "toolCall", "turnId": turn_id, "revision": revision,
            "status": status, "tool": tool, "callId": call_id, "args": args}

def item(method, value):
    notify(method, {"sessionId": SESSION, "item": value})

def built_in_tool(item_id, tool, call_id):
    item("item/started", tool_item(item_id, tool, call_id, "inProgress", 1))
    item("item/completed", tool_item(item_id, tool, call_id, "completed", 2))

# Real Muse choices plus adversarial approved variants placed first: matching
# the decision alone must not persist an attached tool's approval.
CHOICES = [
    {"choiceId": "wrong_scope_session", "label": "Session", "decision": "approved", "scope": "session"},
    {"choiceId": "future_scope", "label": "Future", "decision": "approved", "scope": "future"},
    {"choiceId": "allow_once", "label": "Allow once", "decision": "approved", "scope": "once"},
    {"choiceId": "allow_session", "label": "Allow for this session",
     "decision": "approvedForSession", "scope": "session"},
    {"choiceId": "allow_local_mcp_tool", "label": "Always allow this MCP tool",
     "decision": "approvedPolicyAmendment", "scope": "localPersistent"},
    {"choiceId": "abort", "label": "Reject", "decision": "abort", "scope": "once",
     "acceptsFeedback": True}]
ASKED = [0]

def ask(tool, subject):
    ASKED[0] += 1
    approval_id = "approval-%d" % ASKED[0]
    send({"jsonrpc": "2.0", "id": ASKED[0], "method": "approval/request", "params": {
        "sessionId": SESSION, "approvalId": approval_id, "turnId": turn_id,
        "taskId": approval_id, "itemId": approval_id, "toolCallId": "call-" + approval_id,
        "toolName": tool, "rawArgs": "{}", "viewCursor": cursor(), "subject": subject,
        "currentRequirementId": {"approvalId": approval_id, "sourceIndex": 0},
        "availableChoices": CHOICES, "protectedWrite": False, "judgeEscalated": False}})
    ack = read()
    assert ack.get("id") == ASKED[0] and ack.get("result") == {}, ack
    decide = read()
    assert decide["method"] == "approval/decide", decide
    send({"jsonrpc": "2.0", "id": decide["id"], "result": {
        "commandId": decide["params"]["commandId"], "status": "accepted",
        "approvalId": approval_id, "terminal": True}})
    with open(os.path.join(HERE, "decisions.log"), "a") as handle:
        handle.write("%s %s %s\n" % (tool, decide["params"]["choiceId"],
                                     "feedback" if decide["params"].get("feedback") else "-"))

if SCENARIO == "hang_before_ack":
    drain()
if SCENARIO == "refuse_turn":
    if "subscription_usage" in FIXTURE:
        notify("usage/changed", FIXTURE["subscription_usage"])
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
if SCENARIO == "later_unstreamed":
    item("item/started", {"itemId": "first", "kind": "agentMessage", "turnId": turn_id,
                          "revision": 1, "status": "inProgress", "text": ""})
    notify("item/delta", {"sessionId": SESSION, "itemId": "first", "field": "text", "delta": "checking."})
    item("item/completed", {"itemId": "first", "kind": "agentMessage", "turnId": turn_id,
                            "revision": 2, "status": "completed", "text": "checking."})
    item("item/completed", {"itemId": "later", "kind": "agentMessage", "turnId": turn_id,
                            "revision": 1, "status": "completed", "text": "final answer"})
    notify("turn/completed", {"sessionId": SESSION, "turnId": turn_id, "terminal": "completed"})
    drain()
if SCENARIO == "exit_mid_turn":
    item("item/started", tool_item("tc-1", "write_file", "call-native-1", "inProgress", 1))
    sys.exit(1)
if SCENARIO == "read_only_tool_failure":
    call_probe()
if SCENARIO in ["turn_failed", "turn_failed_with_usage", "read_only_tool_failure"]:
    built_in_tool("tc-1", "read_file", "call-native-1")
    terminal = {"sessionId": SESSION, "turnId": turn_id, "terminal": "failed",
                "error": {"kind": "modelError", "message": "provider returned 503",
                          "retryable": True}}
    if SCENARIO == "turn_failed_with_usage":
        terminal["usage"] = {"inputTokens": 10, "outputTokens": 2,
                             "cachedTokens": 0, "reasoningTokens": 0}
    notify("turn/completed", terminal)
    drain()
if SCENARIO == "text_only":
    item("item/completed", {"itemId": "m-1", "kind": "agentMessage", "turnId": turn_id,
                            "revision": 1, "status": "completed", "text": "TEXT_ONLY_OK"})
    notify("turn/completed", {"sessionId": SESSION, "turnId": turn_id, "terminal": "completed"})
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
ask("mcp__masc__masc_probe", {"kind": "tool", "toolName": "mcp__masc__masc_probe"})
call_probe()
item("item/completed", tool_item("tc-mcp", "mcp__masc__masc_probe", "call-mcp-1",
                                 "completed", 2, probe_args))
ask("mcp__unattached__masc_probe", {"kind": "tool", "toolName": "mcp__unattached__masc_probe"})
ask("mcp__masc__masc_probe", {"kind": "tool", "toolName": "bash"})
ask("mcp__masc__masc_probe", {"kind": "tool"})
ask("bash", {"kind": "shell", "command": "touch rejected"})
ask("read_file", {"kind": "fileAccess", "toolName": "read_file", "path": "/etc/hosts",
                  "access": "read"})
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

(* The executable the serve client spawns. It names the host script by its
   absolute path because the process runs in the playground. *)
let launcher ~base_path = Filename.concat base_path "muse"

(* A supported catalog protocol supplies model metadata only. These tests
   invoke the unexposed Muse adapter directly; top-level routing is separate. *)
let runtime_toml ~base_path =
  Printf.sprintf
    {|[providers.muse_fixture]
protocol = "claude-code"
command = %S
is-non-interactive = true

[models.fixture]
api-name = "muse-fixture-1"
max-context = 200000

[muse_fixture.fixture]

[runtime]
default = "muse_fixture.fixture"
|}
    (launcher ~base_path)
;;

let runtime_id = "muse_fixture.fixture"
let keeper_name = "muse-fixture"

(* The Keeper's root on the host under [profile]: the tree MASC's own file
   tools use for a Docker Keeper, the bookkeeping bundle for an endpoint-owned
   one. *)
let host_root ~base_path profile =
  Env_config_core.strip_trailing_slashes
    (Filename.concat base_path (Keeper_sandbox.host_root_rel_of_profile profile keeper_name))
;;

let playground ~base_path = host_root ~base_path Keeper_types_profile_sandbox.Docker

(* The keeper TOML with [profile_lines] after its instructions. *)
let declare_keeper ~base_path profile_lines =
  let path = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  write_file ~mode:0o600 path
    ("[keeper]\ninstructions = \"muse-fixture fixture instructions\"\n" ^ profile_lines)
;;

type observed_run =
  { outcome : Keeper_muse_runtime.attempt_outcome
  ; events : Agent_core.Types.sse_event list
  ; reports : Keeper_client_usage_report.t list
  ; transmitted : Keeper_official_client_host.transmitted_model_input list
  ; native_actions : (int * string) list
  }

(* [on_stream_event] sees each Keeper stream event as it is emitted;
   [on_transmitted] sees the transmission report after it is recorded. *)
let run_turn_with ?composed_context ?goal_blocks ?(accepts_image_input = false) ?model ?account_home ?workspace_root ?hooks ?tools ?on_official_client_tool_boundary
    ?(admission_timeout_s = 20.) ?(idle_timeout_s = 20.)
    ?(on_stream_event = fun (_ : Agent_core.Types.sse_event) -> ())
    ?(on_transmitted = fun (_ : Keeper_official_client_host.transmitted_model_input) -> ())
    ?(on_usage = fun (_ : Keeper_client_usage_report.t) -> ())
    ~base_path ~tool () =
  let events = ref [] in
  let reports = ref [] in
  let transmitted = ref [] in
  let native_actions = ref [] in
  let selected_home = Option.value account_home ~default:(Filename.concat base_path "account-home") in
  let config =
    { (Serve.default_config ()) with
      cli_path = launcher ~base_path
    ; model
    ; account_home = Some selected_home
    ; admission_timeout_s
    ; timeout_s = Some idle_timeout_s
    }
  in
  let outcome =
    Keeper_muse_runtime.run
      ?composed_context
      ~prompt_capacity:
        (Runtime_muse_prompt_capacity.start_prompt_bytes ~max_context:(Some 200_000))
      ~configured_reasoning_effort:(Runtime_inference.resolve_reasoning_effort ~runtime_id)
      ~turn_timeout_s:(Runtime_inference.resolve_turn_timeout_s ~runtime_id)
      ~quota_scope:(Runtime_quota_window.scope_of_muse_home selected_home)
      ~accepts_image_input
      ~runtime_id
      ~keeper_name
      ~pre_tool_rejects:(ref [])
      ~base_path
      ~workspace_root:(Option.value workspace_root ~default:(playground ~base_path))
      ~goal:"Call masc_probe once"
      ~goal_blocks
      ~system_prompt:"MUSE_FIXTURE_SYSTEM_PROMPT"
      ~tools:(Option.value tools ~default:[ tool ])
      ~initial_messages:[ user_message "MUSE_FIXTURE_HISTORY" ]
      ~model_input_projection:None
      ~on_transmitted_model_input:(fun input ->
        transmitted := input :: !transmitted;
        on_transmitted input)
      ~hooks
      ~context_injector:None
      ~context:(Some (Agent_core.Context.create ()))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ?on_official_client_tool_boundary
      ~on_native_action:(fun ~official_turn ~identity ~tool_name ->
        match identity with
        | Runtime_native_tools.Call_id call_id ->
          native_actions := (official_turn, call_id ^ ":" ^ tool_name) :: !native_actions
        | Runtime_native_tools.Provider_step _ -> fail "Muse Code reports call ids")
      ~on_usage_report:(fun report -> reports := report :: !reports; on_usage report)
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
   with the fixture keeper declared as a Docker Keeper and its playground
   stood up (a Keeper's turn creates it in production). Returns the
   runtime.toml path. *)
let prepare_scripted_host ~base_path =
  Unix.mkdir (Filename.concat base_path ".masc") 0o700;
  declare_keeper ~base_path
    "sandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
  Fs_compat.mkdir_p (playground ~base_path);
  let account_config = Filename.concat base_path "account-home/.config/muse" in
  Fs_compat.mkdir_p account_config;
  write_file ~mode:0o600 (Filename.concat account_config "auth.json")
    {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-LOCAL-ONLY"}}}|};
  let host = Filename.concat base_path "muse_host.py" in
  write_file ~mode:0o600 host muse_host_script;
  write_file ~mode:0o700 (launcher ~base_path)
    (Printf.sprintf "#!/bin/sh\nexec python3 %s\n" (Filename.quote host));
  write_file ~mode:0o600 (Filename.concat base_path "fixture.json")
    (Yojson.Safe.to_string
       (`Assoc
          [ "session_id", `String session_id
          ; "workspace_root", `String (playground ~base_path)
          ]));
  let runtime_path = Filename.concat base_path "runtime.toml" in
  write_file ~mode:0o600 runtime_path (runtime_toml ~base_path);
  runtime_path
;;

(* The Keeper's meta snapshot, which names the playground through the
   declared profile. *)
let persist_fixture_meta ~base_path =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ]) with
  | Error detail -> fail detail
  | Ok meta ->
    (match Keeper_meta_store.replace_snapshot (Workspace.default_config base_path) meta with
     | Ok () -> ()
     | Error detail -> failf "keeper meta persistence failed: %s" detail)
;;

(* The MASC tool the scripted host calls once; [observed_input] receives its
   arguments. *)
let masc_probe_tool ?descriptor observed_input =
  let marker : Agent_core.Types.tool_param =
    { name = "marker"; description = "Fixture marker"; param_type = String; required = true }
  in
  Agent_core.Tool.create
    ?descriptor
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
                  persist_fixture_meta ~base_path;
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

(* [root] is the workspace root the host expects; the Docker playground
   unless given. *)
let write_fixture ?root ~base_path members =
  let root =
    match root with
    | Some root -> root
    | None -> playground ~base_path
  in
  write_file ~mode:0o600 (Filename.concat base_path "fixture.json")
    (Yojson.Safe.to_string
       (`Assoc ([ "session_id", `String session_id; "workspace_root", `String root ] @ members)))
;;

(* [f] runs in a prepared workspace under the Eio environment and the fixture
   runtime.toml, with [fixture] added to fixture.json. *)
let with_scripted_host ?(fixture = []) ?(after = fun ~base_path:_ -> ()) f =
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
                  persist_fixture_meta ~base_path;
                  f ~base_path)));
          after ~base_path))
;;

let test_declared_muse_runtime_routes_keeper_turns () =
  with_scripted_host @@ fun ~base_path ->
  let runtime_path = Filename.concat base_path "runtime.toml" in
  let declaration = Printf.sprintf
    {|[providers.muse_fixture]
protocol = "muse-serve"
command = %S
account-home = %S
is-non-interactive = true
[models.fixture]
api-name = "muse-fixture-1"
max-context = 200000
reasoning-effort = "high"
turn-timeout-s = 0
tools-support = true
streaming = true
[muse_fixture.fixture]
[runtime]
default = "muse_fixture.fixture"
|} (launcher ~base_path) (Filename.concat base_path "account-home") in
  write_file ~mode:0o600 runtime_path declaration;
  (match Runtime.init_default ~config_path:runtime_path with
   | Ok () -> () | Error detail -> fail detail);
  let observed = ref `Null in
  let tool = masc_probe_tool observed in
  let env = match Eio_context.get_env_opt () with
    | Some env -> env | None -> fail "fixture Eio environment is missing" in
  write_fixture ~base_path ["expected_effort", `String "high"];
  let frozen_registry = Runtime.For_testing.snapshot () in
  let replacement = Filename.concat base_path "reloaded-runtime.toml" in
  write_file ~mode:0o600 replacement {|
[providers.reloaded]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"
[models.reloaded]
api-name = "synthetic-replacement"
max-context = 4096
[reloaded.reloaded]
[runtime]
default = "reloaded.reloaded"
|};
  let hooks = { Agent_core.Hooks.empty with before_turn_params = Some
    (function
      | Agent_core.Hooks.BeforeTurnParams { current_params; _ } ->
        check bool "hook receives frozen configured effort" true
          (current_params.reasoning_effort = Some Llm_provider.Reasoning_effort.High);
        (match Runtime.init_default ~config_path:replacement with
         | Ok () -> () | Error detail -> fail detail);
        check bool "hook reload removed the selected id" true
          (Option.is_none (Runtime.get_runtime_by_id runtime_id));
        Agent_core.Hooks.AdjustParams
          { current_params with
            system_prompt_override = Some "MUSE_ROUTED_EFFECTIVE_SYSTEM_PROMPT" }
      | _ -> fail "expected before_turn_params hook event") } in
  let run () = Eio.Switch.run (fun sw ->
    match Keeper_turn_driver.run_named ~raw_trace:None ~walk_owner:Keeper_turn_driver.One_shot_walk
      ~runtime_id ~keeper_name ~base_path ~goal:"Call masc_probe once"
      ~system_prompt:"" ~hooks
      ~tools:[tool] ~agent_core_tools:[tool]
      ~initial_messages:[user_message "MUSE_OLD_COMPLETED_QUESTION";
        { (user_message "MUSE_OLD_COMPLETED_ANSWER") with role=Assistant };
        user_message "MUSE_ROUTED_NEWEST_ATOM"]
      ~context:(Agent_core.Context.create ()) ~sw ~net:(Eio.Stdenv.net env) () with
    | Ok selected -> selected.Keeper_turn_driver.run_result
    | Error error -> fail (Agent_core.Error.to_string error)) in
  let first = run () in
  check string "routed reply" "MASC_MUSE_KEEPER_OK" (response_text first);
  check (option bool) "routed start" (Some false) first.session_resumed;
  check string "routed MCP tool reached MASC" {|{"marker":"from-muse"}|}
    (Yojson.Safe.to_string !observed);
  let _, _, first_count = settled_turn ~base_path in
  check int "routed first durable ordinal" 1 first_count;
  let prompt = read_text (Filename.concat base_path "start-prompt.txt") in
  check bool "effective hook instructions reach the client" true
    (String_util.contains_substring prompt "MUSE_ROUTED_EFFECTIVE_SYSTEM_PROMPT");
  check bool "native coordinate survives the hook override" true
    (String_util.contains_substring prompt "Muse native tools use host workspace");
  check bool "no-trace start retains the newest checkpoint atom" true
    (String_util.contains_substring prompt "MUSE_ROUTED_NEWEST_ATOM");
  List.iter (fun stale ->
    check bool "no-trace start excludes completed checkpoint history" false
      (String_util.contains_substring prompt stale))
    ["MUSE_OLD_COMPLETED_QUESTION"; "MUSE_OLD_COMPLETED_ANSWER"];
  Runtime.For_testing.restore frozen_registry;
  let second = run () in
  check (option bool) "routed resume" (Some true) second.session_resumed;
  let _, _, second_count = settled_turn ~base_path in
  check int "routed second durable ordinal" 2 second_count
;;

let test_subscription_exhaustion_is_account_scoped () =
  with_scripted_host (fun ~base_path ->
    Runtime_quota_window.reset_for_testing ();
    let scope = Runtime_quota_window.scope_of_muse_home (Filename.concat base_path "account-home") in
    let other = Runtime_quota_window.scope_of_muse_home (Filename.concat base_path "other-account") in
    let usage = `Assoc ["observedAtMs", `Int 100000; "tier", `String "fixture";
      "window", `Assoc ["usedPercent", `Int 100; "resetsAtMs", `Int 500000; "windowDurationMins", `Int 5];
      "weekly", `Assoc ["usedPercent", `Int 101; "resetsAtMs", `Int 900000]] in
    write_fixture ~base_path ["subscription_usage", usage];
    (match (run_turn ~base_path ~tool:(masc_probe_tool (ref `Null))).outcome.result with
     | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
    check (option (float 0.)) "successful turn retains latest provider reset" (Some 900.)
      (Runtime_quota_window.active_until ~scope ~now:100.);
    check bool "another selected account stays available" false
      (Runtime_quota_window.is_exhausted ~scope:other ~now:100.);
    let same_account = Runtime_quota_window.scope_of_muse_home (Filename.concat base_path "account-home") in
    check (list string) "same HOME candidates demote together" ["other";"first";"second"]
      (Runtime_quota_window.demote_order ~now:100.
        ~quota_scope_of:(function "other" -> Some other | "second" -> Some same_account | _ -> Some scope)
        ["first";"other";"second"]);
    check bool "provider reset expires exactly" false
      (Runtime_quota_window.is_exhausted ~scope ~now:900.);
    Runtime_quota_window.reset_for_testing ());
  with_scripted_host ~fixture:["scenario", `String "refuse_turn";
    "subscription_usage", `Assoc ["observedAtMs", `Int 100000; "tier", `String "fixture";
      "window", `Assoc ["usedPercent", `Int 100; "resetsAtMs", `Int 500000; "windowDurationMins", `Int 5];
      "weekly", `Assoc ["usedPercent", `Int 1; "resetsAtMs", `Int 900000]]]
    (fun ~base_path ->
      let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
      check bool "host refusal has no successful completion" true (Result.is_error run.outcome.result);
      let scope = Runtime_quota_window.scope_of_muse_home (Filename.concat base_path "account-home") in
      check (option (float 0.)) "pre-ack quota survives the rejected turn" (Some 500.)
        (Runtime_quota_window.active_until ~scope ~now:100.);
      Runtime_quota_window.reset_for_testing ())
;;

let test_muse_usage_read_rests_only_the_selected_account () =
  let usage = `Assoc
    [ "observedAtMs", `Int 100000
    ; "tier", `String "fixture"
    ; "window", `Assoc
        [ "usedPercent", `Int 20; "resetsAtMs", `Int 500000
        ; "windowDurationMins", `Int 5 ]
    ; "weekly", `Assoc
        [ "usedPercent", `Int 101; "resetsAtMs", `Int 900000 ]
    ]
  in
  with_scripted_host ~fixture:["usage_read_only", `Bool true;
    "subscription_usage", usage] (fun ~base_path ->
      Runtime_quota_window.reset_for_testing ();
      let account_home = Filename.concat base_path "account-home" in
      let scope = Runtime_quota_window.scope_of_muse_home account_home in
      let other = Runtime_quota_window.scope_of_muse_home
        (Filename.concat base_path "other-account") in
      let env = Option.get (Eio_context.get_env_opt ()) in
      let clock = Eio.Stdenv.clock env in
      let config =
        { (Serve.default_config ()) with
          cli_path = launcher ~base_path
        ; account_home = Some account_home
        }
      in
      (match Runtime_provider_usage_read.read_muse
               ~mgr:(Posix_spawn_process_mgr.foreground_mgr ~clock
                 ~grace_seconds:Process_eio.child_exit_grace_seconds)
               ~clock ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
               ~scope config with
       | Ok () -> ()
       | Error detail -> fail detail);
      check (option (float 0.)) "weekly reset recorded from usage/read"
        (Some 900.) (Runtime_quota_window.active_until ~scope ~now:100.);
      check bool "different account remains dispatchable" false
        (Runtime_quota_window.is_exhausted ~scope:other ~now:100.);
      check bool "no model session was started" false
        (Sys.file_exists (Filename.concat base_path "sessions.log"));
      check string "one provider usage request" "usage/read\n"
        (read_text (Filename.concat base_path "usage-read.log"));
      Runtime_quota_window.reset_for_testing ())
;;

(* Fail the actual MCP listener edge while retaining real process/filesystem
   resources. No runtime hook or public injection flag can bypass admission. *)
module Refusing_listen_net = struct
  type tag = [ `Generic | `Unix ]
  type t = { net : tag Eio.Net.ty Eio.Resource.t; attempts : int ref }
  let connect t ~sw address = Eio.Net.connect ~sw t.net address
  let getaddrinfo t ~service host = Eio.Net.getaddrinfo t.net ~service host
  let getnameinfo t = Eio.Net.getnameinfo t.net
  let listen t ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw:_ _address =
    incr t.attempts;
    raise (Unix.Unix_error (Unix.EACCES, "fixture MCP listen", "loopback"))
  let datagram_socket t ~reuse_addr ~reuse_port ~sw address =
    Eio.Net.datagram_socket t.net ~reuse_addr ~reuse_port ~sw address
end

let with_refusing_listener ~attempts f =
  let env = match Eio_context.get_env_opt () with
    | Some env -> env | None -> fail "scripted host needs Eio environment" in
  let net = Eio.Resource.T
      ({Refusing_listen_net.net=env#net; attempts}, Eio.Net.Pi.network (module Refusing_listen_net)) in
  let refused_env = object
    method net = net
    method stdin = env#stdin
    method stdout = env#stdout
    method stderr = env#stderr
    method domain_mgr = env#domain_mgr
    method process_mgr = env#process_mgr
    method clock = env#clock
    method mono_clock = env#mono_clock
    method fs = env#fs
    method cwd = env#cwd
    method secure_random = env#secure_random
    method debug = env#debug
    method backend_id = env#backend_id
  end in
  Eio_context.set_env refused_env;
  Fun.protect ~finally:(fun () -> Eio_context.set_env env) f
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

let test_failed_muse_turn_reads_typed_usage_without_replay () =
  List.iter (fun used_percent ->
    let now = Time_compat.now () in
    let resets_at_ms = int_of_float ((now +. 3600.) *. 1000.) in
    let usage = `Assoc
      [ "observedAtMs", `Int (int_of_float (now *. 1000.))
      ; "tier", `String "fixture"
      ; "window", `Assoc
          [ "usedPercent", `Int 20
          ; "resetsAtMs", `Int resets_at_ms
          ; "windowDurationMins", `Int 300 ]
      ; "weekly", `Assoc
          [ "usedPercent", `Int used_percent
          ; "resetsAtMs", `Int resets_at_ms ]
      ]
    in
    Runtime_quota_window.reset_for_testing ();
    with_scripted_host
      ~fixture:[ "scenario", `String "turn_failed"
               ; "usage_read_only", `Bool true
               ; "suppress_turn_usage_notification", `Bool true
               ; "subscription_usage", usage ]
      ~after:(fun ~base_path ->
        let scope = Runtime_quota_window.scope_of_muse_home
          (Filename.concat base_path "account-home") in
        let other = Runtime_quota_window.scope_of_muse_home
          (Filename.concat base_path "other-account") in
        let expected =
          if used_percent >= 100
          then Some (float_of_int resets_at_ms /. 1000.)
          else None
        in
        check (option (float 0.001)) "typed read controls selected account only"
          expected (Runtime_quota_window.active_until ~scope ~now);
        check bool "different account remains available" false
          (Runtime_quota_window.is_exhausted ~scope:other ~now);
        check string "one independent usage/read" "usage/read\n"
          (read_text (Filename.concat base_path "usage-read.log"));
        check string "failed model turn was not replayed" "start\n"
          (read_text (Filename.concat base_path "sessions.log"));
        check string "one turn/start reached the host" "1"
          (read_text (Filename.concat base_path "host-turn-count.txt")))
      (fun ~base_path ->
        let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
        check bool "model failure stays failed" true
          (Result.is_error run.outcome.result);
        check_effect "original uncertainty stays fenced"
          Keeper_provider_attempt_effect.Observation_unavailable run.outcome;
        (match Store.load ~base_path ~keeper_name with
         | Ok (Some { phase = Store.Settled settled
                    ; last_transient_release = Some release; _ }) ->
           check_failure "original recovery stays retryable"
             Store.Retryable_turn_failed release.failure;
           check string "original turn identity is retained"
             (started_turn_id ~base_path) settled.turn_id
         | _ -> fail "failed turn lost its durable session"));
    Runtime_quota_window.reset_for_testing ())
    [101; 20]
;;


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
    let failed_turn = started_turn_id ~base_path in
    (match Store.load ~base_path ~keeper_name with
     | Ok (Some {phase=Store.Settled settled; last_transient_release=Some release; _}) ->
       check_failure "failed terminal remains explicit" Store.Retryable_turn_failed release.failure;
       check string "first failed turn retains acknowledged session" session_id settled.session_id;
       check string "first failed turn retains its identity" failed_turn settled.turn_id
     | _ -> fail "retryable failed terminal lost its durable session");
    write_fixture ~base_path [];
    (match (run_turn ~base_path ~tool:(masc_probe_tool (ref `Null))).outcome.result with
     | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
    check (list string) "retryable failure continues the same durable session"
      ["start"; "resume"]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")))
;;

(* The host answers turn/start with an error: it did not take the turn, so
   the attempt stays effect-free. *)
let test_read_only_mcp_failure_does_not_invent_an_effect () =
  with_scripted_host ~fixture:(scenario "read_only_tool_failure") (fun ~base_path ->
    let observed = ref `Null in
    let tool = masc_probe_tool ~descriptor:(Agent_core.Tool.ordinary_descriptor
      ~call_effect:(fun _ -> Agent_core.Tool.Read_only) Agent_core.Tool_contract.Serial) observed in
    let run = run_turn ~base_path ~tool in
    check bool "read-only handler was invoked" true (!observed <> `Null);
    check bool "provider still failed" true (Result.is_error run.outcome.result);
    check_effect "read-only handler does not become an effect" Keeper_provider_attempt_effect.Observation_unavailable run.outcome)
;;

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
        ~on_stream_event:(function Agent_core.Types.MessageStart _ -> Eio.Fiber.yield () | _ -> ())
        ~on_official_client_tool_boundary:(fun () ->
          Ok (Some (Keeper_official_client_host.Repeated_tool_call
            { tool_name = "masc_probe"; repeated_count = 3 })))
        ~base_path
        ~tool:(masc_probe_tool (ref `Null))
        ()
    in
    (match run.outcome.result with
     | Ok { Runtime_agent.stop_reason =
              Runtime_agent.Yielded_after_repeated_tool_call { tool_name; repeated_count; _ }; _ } ->
       check string "stopped tool" "masc_probe" tool_name;
       check int "repetition count" 3 repeated_count
     | Ok _ -> fail "the stop did not retain its repeated-tool cause"
     | Error error -> fail (Agent_core.Error.to_string error));
    (match List.rev run.events with
     | Agent_core.Types.MessageStop :: MessageDelta _ :: _ -> ()
     | _ -> fail "successful host stop left its SSE message open");
    check int "host stop closes once" 1
      (List.length (List.filter (function Agent_core.Types.MessageStop -> true | _ -> false) run.events));
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

(* The response label, its canonical model and the usage row name the model
   the host named for the turn's last call. A last call with no model named
   claims none: the canonical model is absent and the label falls back to the
   configured model (muse-fixture-1). With no call reported, the session's
   model names them. *)
let test_turn_is_named_after_its_last_reported_call () =
  List.iter (fun (calls, label, canonical) ->
    with_scripted_host ~fixture:["call_models", `List calls] (fun ~base_path ->
      let tool = masc_probe_tool (ref `Null) in
      let run = run_turn_with ~model:"muse-fixture-1" ~base_path ~tool () in
      match run.outcome.result with
      | Error error -> fail (Agent_core.Error.to_string error)
      | Ok result ->
        check string "response label" label result.response.model;
        check (option string) "canonical model" canonical
          (Option.bind result.response.telemetry
             (fun telemetry -> telemetry.Agent_core.Types.canonical_model_id));
        check (list string) "usage row model" [label]
          (List.map (fun (report : Keeper_client_usage_report.t) -> report.model) run.reports)))
    [ [`String "muse-fixture-contributor"], "muse-fixture-contributor",
      Some "muse-fixture-contributor"
    ; [`String "muse-fixture-contributor"; `Null], "muse-fixture-1", None
    ; [], "muse-fixture-1", Some "muse-fixture-1" ]
;;

(* A changed model starts a fresh session. *)
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
    write_fixture ~base_path [ "resume_model_id", `String "muse-b" ];
    turn "second turn on muse-b" "muse-b";
    check (list string) "sessions the host opened" [ "start"; "start"; "resume" ]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n'
       |> List.filter (fun line -> line <> "")))
;;

(* The same configuration resumed selects the configured model before the
   turn, whatever the session reports: another model (Muse Code 1.4.0 reports
   its account default), none, or the configured one. A selection the host
   refuses fails the turn before dispatch. *)
let test_resumed_model_is_reselected_before_dispatch () =
  let lines path =
    if Sys.file_exists path
    then read_text path |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")
    else [] in
  let first_turn ~base_path ~tool =
    match (run_turn_with ~model:"muse-a" ~base_path ~tool ()).outcome.result with
    | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error) in
  List.iter (fun reported ->
    with_scripted_host (fun ~base_path ->
      let tool = masc_probe_tool (ref `Null) in
      first_turn ~base_path ~tool;
      write_fixture ~base_path ["resume_model_id", reported];
      (match (run_turn_with ~model:"muse-a" ~base_path ~tool ()).outcome.result with
       | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
      check (list string) "the configured model was selected" ["muse-a"]
        (lines (Filename.concat base_path "model-selections.log"));
      check (list string) "the same session continued" ["start"; "resume"]
        (lines (Filename.concat base_path "sessions.log"))))
    [`Null; `String "muse-a-contributor"; `String "muse-a"];
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    first_turn ~base_path ~tool;
    write_fixture ~base_path
      ["resume_model_id", `String "muse-a-contributor"; "refuse_selection", `Bool true];
    (match (run_turn_with ~model:"muse-a" ~base_path ~tool ()).outcome.result with
     | Error (Agent_core.Error.Provider (Llm_provider.Error.ProviderReportedError
         {error_type=Some "rpc_error"; _})) -> ()
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok _ -> fail "a selection the host refused was treated as matching");
    check (list string) "the configured model was asked for" ["muse-a"]
      (lines (Filename.concat base_path "model-selections.log"));
    check bool "refused selection fails before turn dispatch" false
      (Sys.file_exists (Filename.concat base_path "resume-prompt.txt")))
;;

(* ── Owner stops ─────────────────────────────────────────────────────── *)

(* The phase the store holds once the previous turn settled. *)
let settled_phase ~base_path =
  match Store.load ~base_path ~keeper_name with
  | Ok (Some { Store.phase = Store.Settled _ as phase; _ }) -> phase
  | Ok (Some _) -> fail "the first turn did not settle"
  | Ok None -> fail "no session was recorded"
  | Error detail -> fail detail
;;

(* An owner stop releases the claim as [Owner_stopped_turn] and restores the
   settlement from before the turn, so the next turn resumes that session
   instead of waiting on an operator. *)
let check_owner_stop ~base_path ~settled =
  match Store.load ~base_path ~keeper_name with
  | Ok (Some restored) ->
    check bool "the earlier settlement is restored" true (restored.Store.phase = settled);
    (match restored.Store.last_transient_release with
     | Some release ->
       check_failure "released as an owner stop" Store.Owner_stopped_turn
         release.Store.failure
     | None -> fail "no release was recorded")
  | Ok None -> fail "no session was recorded"
  | Error detail -> fail detail
;;

let settle_first_turn ~base_path ~tool =
  match (run_turn ~base_path ~tool).outcome.result with
  | Ok _ -> settled_phase ~base_path
  | Error error -> fail (Agent_core.Error.to_string error)
;;

(* The owner interrupts a turn by failing its switch ([Keeper_owner]), so the
   adapter sees [Cancelled Operator_interrupt]. That is a stop the owner
   asked for, not a dropped transport. *)
let test_an_operator_interrupt_keeps_the_settled_session () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    let settled = settle_first_turn ~base_path ~tool in
    write_fixture ~base_path (scenario "hang");
    (match
       Eio.Switch.run (fun turn_sw ->
         Eio.Fiber.fork ~sw:turn_sw (fun () ->
           let (_ : observed_run) =
             run_turn_with
               ~on_stream_event:(function
                 | Agent_core.Types.MessageStart _ ->
                   Eio.Switch.fail turn_sw Keeper_registry_types.Operator_interrupt
                 | _ -> ())
               ~base_path
               ~tool
               ()
           in
           fail "the interrupted turn returned"))
     with
     | () -> fail "the interrupted turn returned"
     | exception exn when Keeper_registry_types.is_operator_interrupt exn -> ());
    check_owner_stop ~base_path ~settled)
;;

(* The same interrupt raised bare by a callback the turn runs leaves as
   itself, not as an untyped exception turned into a provider error. *)
let test_an_operator_interrupt_a_callback_raises_keeps_the_settled_session () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    let settled = settle_first_turn ~base_path ~tool in
    (match
       run_turn_with
         ~on_transmitted:(fun _ -> raise Keeper_registry_types.Operator_interrupt)
         ~base_path
         ~tool
         ()
     with
     | exception exn when Keeper_registry_types.is_operator_interrupt exn -> ()
     | exception exn -> fail (Printexc.to_string exn)
     | (_ : observed_run) -> fail "the operator interrupt became a provider result");
    check_owner_stop ~base_path ~settled)
;;

(* ── Where the session works ─────────────────────────────────────────── *)

(* The session's [workspaceRoot] and the host's working directory are the
   Keeper's playground, not the base path that holds [.masc] and its auth
   tokens. *)
let test_the_session_works_in_the_keepers_playground () =
  with_scripted_host (fun ~base_path ->
    let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
    let root = playground ~base_path in
    check bool "the playground is not the base path" false (String.equal root base_path);
    check string "session/start names the playground" root
      (read_text (Filename.concat base_path "start-root.txt"));
    check string "the host runs in the playground" (Unix.realpath root)
      (read_text (Filename.concat base_path "cwd.txt"));
    match run.outcome.result with
    | Ok _ -> ()
    | Error error -> fail (Agent_core.Error.to_string error))
;;

(* Under the default [read] posture MASC approves exactly the tools the
   session's MASC server lists and rejects a built-in, and the start prompt
   says so. *)
let test_account_selection_starts_a_fresh_vendor_session () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    let first = Filename.concat base_path "account-home" in
    let second = Filename.concat base_path "second-account" in
    Fs_compat.mkdir_p (Filename.concat second ".config/muse");
    write_file ~mode:0o600 (Filename.concat second ".config/muse/auth.json")
      {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-LOCAL-ONLY"}}}|};
    List.iter (fun account_home ->
      let run = run_turn_with ~account_home ~base_path ~tool () in
      (match run.outcome.result with
       | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
      check string "process uses selected account" account_home
        (read_text (Filename.concat base_path "selected-home.txt")))
      [first; second; second];
    check (list string) "account switch starts, stable account resumes"
      ["start"; "start"; "resume"]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")))
;;

let test_source_relogin_starts_fresh_and_preserves_vendor_refresh () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    let run () = match (run_turn_with ~base_path ~tool ()).outcome.result with
      | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error) in
    run ();
    let managed = read_text (Filename.concat base_path "managed-config.txt") in
    let refreshed = {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-REFRESHED"}}}|} in
    write_file ~mode:0o600 (Filename.concat managed "muse/auth.json") refreshed;
    run ();
    check string "vendor refresh survives unchanged source" refreshed
      (read_text (Filename.concat managed "muse/auth.json"));
    write_file ~mode:0o600
      (Filename.concat base_path "account-home/.config/muse/auth.json")
      {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-RELOGIN"}}}|};
    run ();
    run ();
    check bool "relogin changes managed generation" false
      (String.equal managed (read_text (Filename.concat base_path "managed-config.txt")));
    check (list string) "refresh resumes, source sign-in starts fresh"
      ["start"; "resume"; "start"; "resume"]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")))
;;

let test_effective_system_override_starts_fresh () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    List.iter (fun text ->
      let hooks = { Agent_core.Hooks.empty with before_turn_params = Some
        (fun _ -> Agent_core.Hooks.AdjustParams
          { Agent_core.Hooks.default_turn_params with system_prompt_override = Some text }) } in
      match (run_turn_with ~hooks ~base_path ~tool ()).outcome.result with
      | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error))
      ["FIRST_EFFECTIVE_INSTRUCTION"; "SECOND_EFFECTIVE_INSTRUCTION"; "SECOND_EFFECTIVE_INSTRUCTION"];
    check (list string) "changed effective instructions start fresh"
      ["start"; "start"; "resume"]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n' |> List.filter (fun line -> line <> ""));
    check bool "second start receives changed instructions" true
      (String_util.contains_substring
        (read_text (Filename.concat base_path "start-prompt.txt"))
        "SECOND_EFFECTIVE_INSTRUCTION"))
;;

let test_hook_nudges_bind_the_session_but_carried_context_does_not () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    let calls = ref 0 in
    let hook_ordinals = ref [] in
    let observe_hook name turn = hook_ordinals := (name, turn) :: !hook_ordinals in
    List.iteri (fun index nudge ->
      hook_ordinals := [];
      let context = Printf.sprintf "TURN_LOCAL_CONTEXT_%d" index in
      let hooks = { Agent_core.Hooks.empty with
        before_turn = Some (fun event -> incr calls;
          (match event with Agent_core.Hooks.BeforeTurn {turn; _} -> observe_hook "before" turn
           | _ -> fail "unexpected before-turn hook event");
          match nudge with Some text -> Agent_core.Hooks.Nudge text | None -> Continue);
        before_turn_params = Some (fun event ->
          (match event with Agent_core.Hooks.BeforeTurnParams {turn; _} -> observe_hook "params" turn
           | _ -> fail "unexpected params hook event");
          Agent_core.Hooks.AdjustParams
            { Agent_core.Hooks.default_turn_params with extra_system_context = Some context });
        pre_tool_use = Some (fun event ->
          (match event with Agent_core.Hooks.PreToolUse {invocation; _} ->
             observe_hook "tool" (Agent_core.Tool_contract.Invocation.turn invocation)
           | _ -> fail "unexpected tool hook event"); Agent_core.Hooks.Continue);
        after_turn = Some (fun event ->
          (match event with Agent_core.Hooks.AfterTurn {turn; _} -> observe_hook "after" turn
           | _ -> fail "unexpected completion hook event"); Agent_core.Hooks.Continue) } in
      let run = run_turn_with ~hooks ~base_path ~tool () in
      (match run.outcome.result with
       | Ok result ->
         check int "vendor ordinal follows its actual session" (List.nth [1;1;2;1;2] index) result.turns
       | Error error -> fail (Agent_core.Error.to_string error));
      let expected_hook_turn = List.nth [1;2;2;3;2] index in
      check (list (pair string int)) "host hooks run once with the pre-reconciliation ordinal"
        (List.map (fun name -> name, expected_hook_turn) ["before"; "params"; "tool"; "after"])
        (List.rev !hook_ordinals);
      check int "one terminal usage observation" 1 (List.length run.reports);
      check bool "native action retains the vendor ordinal" true
        (List.mem (List.nth [1;1;2;1;2] index, "call-native-1:read_file") run.native_actions);
      List.iter (fun (report : Keeper_client_usage_report.t) ->
        check int "usage retains the vendor ordinal" (List.nth [1;1;2;1;2] index) report.official_turn)
        run.reports;
      let mode = if index = 0 || index = 1 || index = 3 then "start" else "resume" in
      let prompt = read_text (Filename.concat base_path (mode ^ "-prompt.txt")) in
      check bool "each turn transmits its current carried context" true
        (String_util.contains_substring prompt context);
      if index = 1 then (
        check bool "changed nudge seeded" true (String_util.contains_substring prompt "NUDGE_TWO");
        check bool "old nudge absent" false (String_util.contains_substring prompt "NUDGE_ONE"));
      if index = 3 then
        check bool "removed nudge absent" false (String_util.contains_substring prompt "NUDGE_TWO"))
      [Some "NUDGE_ONE"; Some "NUDGE_TWO"; Some "NUDGE_TWO"; None; None];
    check int "before hook runs once per attempt" 5 !calls;
    check (list string) "changed and removed nudge start; unchanged nudge and changing context resume"
      ["start"; "start"; "resume"; "start"; "resume"]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")))
;;

let check_resume_recall_blocks ~compaction ~resend_after_start () =
  let fixture = match compaction with
    | None -> []
    | Some outcome -> [ "start_compaction", `String outcome ] in
  with_scripted_host ~fixture (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    List.iteri (fun index recall ->
      let composed = ref None in
      let clock = Printf.sprintf "RECALL_CLOCK_%d" index in
      let blocks =
        [ Prompt_block_id.Memory_os_recall, recall
        ; Prompt_block_id.Temporal_summary, clock
        ; Prompt_block_id.Operator_note, "REPEATED_OPERATOR_NOTE" ] in
      let carrier = String.concat "\n\n" (List.map snd blocks) in
      let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (fun _ ->
        composed := Some { Keeper_official_client_host.carrier_sha256 =
          Digestif.SHA256.(digest_string carrier |> to_hex); blocks };
        Agent_core.Hooks.AdjustParams { Agent_core.Hooks.default_turn_params with
          extra_system_context = Some carrier }) } in
      let run = run_turn_with ~composed_context:(fun () -> !composed)
        ~hooks ~base_path ~tool () in
      (match run.outcome.result with
       | Ok result -> check int "same session advances" (index + 1) result.turns
       | Error error -> fail (Agent_core.Error.to_string error));
      let mode = if index = 0 then "start" else "resume" in
      let prompt = read_text (Filename.concat base_path (mode ^ "-prompt.txt")) in
      check bool "recall appears initially, when revised, or after compaction"
        (index = 0 || index = 2 || (resend_after_start && index = 1))
        (String_util.contains_substring prompt recall);
      check bool "current clock delivered" true (String_util.contains_substring prompt clock);
      check bool "identical operator note remains an instruction" true
        (String_util.contains_substring prompt "REPEATED_OPERATOR_NOTE"))
      ["RECALL_REVISION_ONE"; "RECALL_REVISION_ONE"; "RECALL_REVISION_TWO"; "RECALL_REVISION_TWO"])
;;

let test_resume_deduplicates_recall_blocks () =
  check_resume_recall_blocks ~compaction:None ~resend_after_start:false ()
;;

let test_resume_restores_recall_after_compaction () =
  check_resume_recall_blocks ~compaction:(Some "compacted") ~resend_after_start:true ()
;;

let test_resume_keeps_recall_after_noop_compaction () =
  check_resume_recall_blocks ~compaction:(Some "noop") ~resend_after_start:false ()
;;

let test_call_usage_survives_missing_terminal_aggregate () =
  let call = `Assoc
      [ "modelId", `String "muse-fixture-1"
      ; "promptTokens", `Int 150; "totalTokens", `Int 157
      ; "usage", `Assoc
          [ "inputTokens", `Int 100; "outputTokens", `Int 7
          ; "cachedTokens", `Int 50; "reasoningTokens", `Int 3
          ; "cacheReadTokens", `Int 40; "cacheWriteTokens", `Int 10 ] ] in
  with_scripted_host ~fixture:(scenario "text_only" @ [ "model_usage", `List [call; call] ])
    (fun ~base_path ->
      let tool = masc_probe_tool (ref `Null) in
      List.iter (fun expected_turn ->
        let run = run_turn_with ~tools:[] ~base_path ~tool () in
        (match run.outcome.result with
         | Ok result ->
           check int "session ordinal" expected_turn result.turns;
           (match result.response.usage with
            | Some usage ->
              check int "host counted-once input, not raw input" 300 usage.input_tokens;
              check int "two model calls" 14 usage.output_tokens;
              check int "cache reads" 80 usage.cache_read_input_tokens;
              check int "cache writes" 20 usage.cache_creation_input_tokens
            | None -> fail "per-call usage lost when terminal aggregate was absent")
         | Error error -> fail (Agent_core.Error.to_string error));
        match run.reports with
        | [report] ->
          check bool "usage is turn total, including on resume" true
            (report.usage_scope = Runtime_usage_scope.Turn_total);
          (match report.count with
           | Running_count usage -> check int "reported once, never session cumulative" 300 usage.input_tokens
           | Count_replaced -> fail "unexpected replacement")
        | _ -> fail "expected one usage report per completed turn") [1; 2])
;;

let test_text_only_session_does_not_require_session_mcp () =
  with_scripted_host ~fixture:(scenario "text_only") (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    List.iter (fun () ->
      let run = run_turn_with ~tools:[] ~base_path ~tool () in
      match run.outcome.result with
      | Ok result -> check string "text-only reply" "TEXT_ONLY_OK" (response_text result)
      | Error error -> fail (Agent_core.Error.to_string error)) [(); ()];
    check (list string) "text-only start and resume without capability"
      ["start"; "resume"]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")))
;;

let test_hook_tool_surface_controls_session_binding () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    let digests = ref [] in
    List.iter (fun disabled ->
      write_fixture ~base_path (scenario (if disabled then "text_only" else "complete"));
      let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (fun _ ->
        Agent_core.Hooks.AdjustParams {Agent_core.Hooks.default_turn_params with
          tool_choice=Some (if disabled then Agent_core.Types.None_ else Agent_core.Types.Auto)})} in
      let run = run_turn_with ~hooks ~base_path ~tool () in
      (match run.outcome.result with Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
      let stored = Store.load ~base_path ~keeper_name |> Result.get_ok |> Option.get in
      digests := stored.tool_surface_sha256 :: !digests)
      [true; true; false; false];
    check (list string) "prepared surface changes start fresh once"
      ["start"; "resume"; "start"; "resume"]
      (read_text (Filename.concat base_path "sessions.log") |> String.split_on_char '\n'
       |> List.filter (fun line -> line <> ""));
    match List.rev !digests with
    | [none1; none2; auto1; auto2] ->
      check string "stable disabled surface" none1 none2;
      check string "stable enabled surface" auto1 auto2;
      check bool "actual MCP surfaces have distinct binding digests" false (none1=auto1)
    | _ -> fail "four bindings expected")
;;

let test_later_unstreamed_message_reaches_live_consumers () =
  with_scripted_host ~fixture:(scenario "later_unstreamed") (fun ~base_path ->
    let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
    (match run.outcome.result with
     | Ok result -> check string "recorded final message" "final answer" (response_text result)
     | Error error -> fail (Agent_core.Error.to_string error));
    let text = List.filter_map (function
      | Agent_core.Types.ContentBlockDelta {delta=TextDelta text; _} -> Some text
      | _ -> None) run.events |> String.concat "" in
    check string "stream includes the distinct completed item exactly once"
      "checking.\n\nfinal answer" text)
;;

let test_bridge_setup_failure_preserves_previous_settlement () =
  List.iter (fun seeded -> with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    if seeded then (match (run_turn_with ~base_path ~tool ()).outcome.result with
      | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
    let before = Store.load ~base_path ~keeper_name |> Result.get_ok in
    let spawn_receipt = Filename.concat base_path "selected-home.txt" in
    if Sys.file_exists spawn_receipt then Unix.unlink spawn_receipt;
    let attempts = ref 0 in
    let run = with_refusing_listener ~attempts (fun () -> run_turn_with ~base_path ~tool ()) in
    check int "actual MCP listener edge reached" 1 !attempts;
    (match run.outcome.result with
     | Error (Agent_core.Error.Internal detail) ->
       check bool "bridge failure remains actionable" true
         (String_util.contains_substring detail "MCP bridge setup failed")
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok _ -> fail "refused local listener became successful provider turn");
    check bool "no native client spawned" false (Sys.file_exists spawn_receipt);
    check int "no prompt dispatched" 0 (List.length run.transmitted);
    check bool "local setup has no provider effect" true
      (run.outcome.effect_disposition=Keeper_provider_attempt_effect.No_effect_observed);
    let after = Store.load ~base_path ~keeper_name |> Result.get_ok |> Option.get in
    check bool "local setup cause is persisted as transient" true
      (Option.map (fun (r : Store.transient_release_record) -> r.failure)
         after.last_transient_release = Some Store.Pre_dispatch_failed);
    (match before with
     | None -> check bool "unused account claim returns ready" true (after.phase=Store.Ready)
     | Some before ->
       check bool "prior settlement stays authoritative" true (after.phase=before.phase);
       check int "failed setup does not advance ordinal" before.turn_count after.turn_count);
    match (run_turn_with ~base_path ~tool ()).outcome.result with
    | Ok result -> check (option bool) "next attempt retains conversation" (Some seeded) result.session_resumed
    | Error error -> fail (Agent_core.Error.to_string error))) [false; true]
;;

let test_capability_refusal_preserves_previous_settlement () =
  List.iter (fun seeded -> with_scripted_host (fun ~base_path ->
    let observed = ref `Null in
    let tool = masc_probe_tool observed in
    if seeded then ignore (settle_first_turn ~base_path ~tool);
    let before = Store.load ~base_path ~keeper_name |> Result.get_ok in
    observed := `Null;
    write_fixture ~base_path (scenario "deny_capability");
    let run = run_turn_with ~base_path ~tool () in
    (match run.outcome.result with
     | Error (Agent_core.Error.Provider
         (Llm_provider.Error.ProviderReportedError {error_type=Some "capability_not_granted"; _})) -> ()
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok _ -> fail "withheld sessionMcp admitted a turn");
    check bool "no dynamic tool ran" true (!observed = `Null);
    check int "no prompt dispatched" 0 (List.length run.transmitted);
    check_effect "capability refusal is effect-free" Keeper_provider_attempt_effect.No_effect_observed run.outcome;
    let after = Store.load ~base_path ~keeper_name |> Result.get_ok |> Option.get in
    check bool "known handshake refusal is transient" true
      (Option.map (fun (r : Store.transient_release_record) -> r.failure)
         after.last_transient_release = Some Store.Pre_dispatch_failed);
    (match before with
     | None -> check bool "fresh claim returns Ready" true (after.phase = Store.Ready)
     | Some before ->
       check bool "prior settlement preserved" true (before.phase = after.phase);
       check int "prior ordinal preserved" before.turn_count after.turn_count);
    write_fixture ~base_path [];
    match (run_turn_with ~base_path ~tool ()).outcome.result with
    | Ok result -> check (option bool) "retry resumes only existing conversation" (Some seeded) result.session_resumed
    | Error error -> fail (Agent_core.Error.to_string error))) [false; true]
;;

let test_retry_previous_refuses_an_externally_advanced_session () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    let first = settle_first_turn ~base_path ~tool in
    write_fixture ~base_path (scenario "exit_mid_turn");
    (match (run_turn_with ~base_path ~tool ()).outcome.result with
     | Error _ -> () | Ok _ -> fail "interrupted turn completed");
    let interrupted = Store.load ~base_path ~keeper_name |> Result.get_ok |> Option.get in
    let recovery_id = match interrupted.phase with
      | Store.Recovery_required {recovery_id; _} -> recovery_id
      | _ -> fail "interrupted turn lost recovery evidence" in
    (match Store.resolve_recovery ~base_path ~keeper_name ~expected:interrupted ~recovery_id
       ~resolution:Store.Retry_previous ~resolved_by:"fixture-operator" ~resolved_at:(Time_compat.now ()) with
     | Ok _ -> () | Error _ -> fail "operator could not restore previous settlement");
    check bool "operator selected the earlier settlement" true (settled_phase ~base_path = first);
    (* The prior ambiguous native turn completed outside this local claim. *)
    write_file ~mode:0o600 (Filename.concat base_path "host-turn-count.txt") "2";
    write_fixture ~base_path [];
    let old_turn_id = read_text (Filename.concat base_path "resume-turn-id.txt") in
    let run = run_turn_with ~base_path ~tool () in
    (match run.outcome.result with
     | Error _ -> () | Ok _ -> fail "advanced retained history accepted duplicate work");
    check int "no new prompt reached the host" 0 (List.length run.transmitted);
    check string "no new native turn replaced the prior command identity" old_turn_id
      (read_text (Filename.concat base_path "resume-turn-id.txt"));
    let failure, observed_turn = recovery_row ~base_path in
    check_failure "history mismatch retains recovery" Store.Protocol_failed failure;
    check (option string) "no new host turn was acknowledged" None observed_turn)
;;

(* A started session must be empty: a host that attaches turns to a fresh
   claim is refused before anything is dispatched. *)
let test_nonempty_start_is_refused () =
  with_scripted_host ~fixture:["start_turn_count", `Int 1] (fun ~base_path ->
    let run = run_turn ~base_path ~tool:(masc_probe_tool (ref `Null)) in
    (match run.outcome.result with
     | Error (Agent_core.Error.Provider (Llm_provider.Error.ParseError _)) -> ()
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok _ -> fail "a non-empty start admitted the goal");
    check_effect "refused start has no provider effect"
      Keeper_provider_attempt_effect.No_effect_observed run.outcome;
    check bool "refused start never dispatches" false
      (Sys.file_exists (Filename.concat base_path "start-prompt.txt"));
    let failure, observed_turn = recovery_row ~base_path in
    check_failure "a non-empty start needs adjudication" Store.Protocol_failed failure;
    check (option string) "no turn ran to name" None observed_turn)
;;

let test_owner_cancellation_after_completion_keeps_recovery () =
  List.iter (fun boundary -> with_scripted_host (fun ~base_path ->
    let observed = ref `Null in
    let tool = masc_probe_tool observed in
    ignore (settle_first_turn ~base_path ~tool);
    observed := `Null;
    let boundary_reached = ref false in
    (match Eio.Switch.run (fun turn_sw ->
       let stop () =
         boundary_reached := true;
         Eio.Switch.fail turn_sw Keeper_registry_types.Operator_interrupt;
         Eio.Fiber.yield () in
       let hooks = {Agent_core.Hooks.empty with after_turn =
         Some (fun _ -> if boundary = `Hook then stop (); Agent_core.Hooks.Continue)} in
       Eio.Fiber.fork ~sw:turn_sw (fun () ->
         ignore (run_turn_with ~base_path ~tool ~hooks
           ~on_usage:(fun _ -> if boundary = `Usage then stop ())
           ~on_stream_event:(function
             | Agent_core.Types.MessageStop when boundary = `Stream -> stop ()
             | _ -> ()) ());
         fail "completed turn cancellation returned normally")) with
     | () -> fail "completed turn cancellation was swallowed"
     | exception exn when Keeper_registry_types.is_operator_interrupt exn -> ());
    check bool "requested completion boundary reached" true !boundary_reached;
    check bool "provider already called the real MCP tool" true (!observed <> `Null);
    check string "host completed both turns" "2" (read_text (Filename.concat base_path "host-turn-count.txt"));
    let after = Store.load ~base_path ~keeper_name |> Result.get_ok |> Option.get in
    check int "completed ordinal was not rolled back" 2 after.turn_count;
    check bool "no transient owner release" true (after.last_transient_release = None);
    let failure, observed_turn = recovery_row ~base_path in
    check_failure "post-completion cancellation retains its cause"
      (match boundary with `Hook -> Store.Host_hook_failed | `Usage | `Stream -> Store.Transport_interrupted) failure;
    check (option string) "recovery names the completed native turn"
      (Some (read_text (Filename.concat base_path "resume-turn-id.txt"))) observed_turn)) [`Usage; `Stream; `Hook]
;;

let test_owner_cancellation_after_retryable_terminal_retains_turn () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    ignore (settle_first_turn ~base_path ~tool);
    write_fixture ~base_path (scenario "turn_failed_with_usage");
    let usage_seen = ref false in
    (match Eio.Switch.run (fun turn_sw ->
       Eio.Fiber.fork ~sw:turn_sw (fun () ->
         ignore (run_turn_with ~base_path ~tool
           ~on_usage:(fun _ ->
             usage_seen := true;
             Eio.Switch.fail turn_sw Keeper_registry_types.Operator_interrupt;
             Eio.Fiber.yield ()) ());
         fail "terminal usage cancellation returned normally")) with
     | () -> fail "terminal usage cancellation was swallowed"
     | exception exn when Keeper_registry_types.is_operator_interrupt exn -> ());
    check bool "terminal usage callback reached" true !usage_seen;
    let after = Store.load ~base_path ~keeper_name |> Result.get_ok |> Option.get in
    check int "retryable terminal ordinal preserved" 2 after.turn_count;
    (match after.phase, after.last_transient_release with
     | Store.Settled settled, Some release ->
       check_failure "known terminal cause survives owner stop" Store.Retryable_turn_failed release.failure;
       check string "failed native turn remains authoritative"
         (read_text (Filename.concat base_path "resume-turn-id.txt")) settled.turn_id
     | _ -> fail "known retryable terminal was undone by owner cancellation");
    write_fixture ~base_path [];
    match (run_turn_with ~base_path ~tool ()).outcome.result with
    | Ok result -> check (option bool) "matching failed history still resumes" (Some true) result.session_resumed
    | Error error -> fail (Agent_core.Error.to_string error))
;;

let test_host_stop_resume_requires_a_folded_native_terminal () =
  List.iter (fun native_terminal_folded ->
    with_scripted_host ~fixture:(scenario "stop_before_ack") (fun ~base_path ->
      let tool = masc_probe_tool (ref `Null) in
      let stopped = run_turn_with ~base_path ~tool
        ~on_official_client_tool_boundary:(fun () ->
          Ok (Some (Keeper_official_client_host.Repeated_tool_call
            { tool_name = "masc_probe"; repeated_count = 3 }))) () in
      (match stopped.outcome.result with
       | Ok { Runtime_agent.stop_reason =
                Runtime_agent.Yielded_after_repeated_tool_call { tool_name; repeated_count; _ }; _ } ->
         check string "stopped tool" "masc_probe" tool_name;
         check int "repetition count" 3 repeated_count
       | Ok _ -> fail "host stop lost its repeated-tool cause"
       | Error error -> fail (Agent_core.Error.to_string error));
      let _, _, local_count = settled_turn ~base_path in
      check int "host stop acknowledges one local turn" 1 local_count;
      check string "fixture emitted no native terminal" "0"
        (read_text (Filename.concat base_path "host-turn-count.txt"));
      (* A durable host may fold its shutdown terminal on reload. Only the
         actual resumed count proves that happened; local settlement does not. *)
      if native_terminal_folded then
        write_file ~mode:0o600 (Filename.concat base_path "host-turn-count.txt") "1";
      write_fixture ~base_path [];
      let resumed = run_turn_with ~base_path ~tool () in
      if native_terminal_folded then (
        match resumed.outcome.result with
        | Ok result -> check (option bool) "folded host stop resumes" (Some true) result.session_resumed
        | Error error -> fail (Agent_core.Error.to_string error))
      else (
        (match resumed.outcome.result with
         | Error (Agent_core.Error.Provider (Llm_provider.Error.ParseError _)) -> ()
         | Error error -> fail (Agent_core.Error.to_string error)
         | Ok _ -> fail "local host stop fabricated a native completed count");
        check int "unfolded host stop dispatches no new turn" 0 (List.length resumed.transmitted);
        let failure, _ = recovery_row ~base_path in
        check_failure "native history mismatch requires recovery" Store.Protocol_failed failure)))
    [false; true]
;;

let test_admission_timeout_restores_only_undispatched_claims () =
  List.iter (fun seeded ->
    List.iter (fun phase -> with_scripted_host (fun ~base_path ->
      let tool = masc_probe_tool (ref `Null) in
      if seeded then (match (run_turn_with ~base_path ~tool ()).outcome.result with
        | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
      let before = Store.load ~base_path ~keeper_name |> Result.get_ok in
      write_fixture ~base_path (scenario phase);
      let run = run_turn_with ~admission_timeout_s:1. ~idle_timeout_s:1. ~base_path ~tool () in
      (match phase, run.outcome.result with
       | "hang_before_ack", Error (Agent_core.Error.Internal detail)
         when String.starts_with ~prefix:"Muse Code was silent for " detail -> ()
       | ("hang_init" | "hang_session"), Error (Agent_core.Error.Api (Agent_core.Retry.Timeout _)) -> ()
       | _, Error error -> fail (Agent_core.Error.to_string error)
       | _, Ok _ -> fail "silent admission should time out");
      let after = Store.load ~base_path ~keeper_name |> Result.get_ok |> Option.get in
      if phase="hang_before_ack" then (
        check bool "written turn without ACK remains uncertain" true
          (run.outcome.effect_disposition=Keeper_provider_attempt_effect.Observation_unavailable);
        match after.phase with
        | Store.Recovery_required recovery ->
          check bool "written timeout needs recovery" true (recovery.failure=Store.Transport_interrupted)
        | _ -> fail "written turn was incorrectly released")
      else (
        check int "no turn input was dispatched" 0 (List.length run.transmitted);
        check bool "admission timeout has no provider effect" true
          (run.outcome.effect_disposition=Keeper_provider_attempt_effect.No_effect_observed);
        check bool "predispatch cause retained" true
          (Option.map (fun (r : Store.transient_release_record) -> r.failure) after.last_transient_release
           = Some Store.Pre_dispatch_failed);
        (match before with
         | None -> check bool "fresh claim returns Ready" true (after.phase=Store.Ready)
         | Some before ->
           check bool "previous settlement preserved" true (after.phase=before.phase);
           check int "previous ordinal preserved" before.turn_count after.turn_count);
        write_fixture ~base_path (scenario "complete");
        match (run_turn_with ~base_path ~tool ()).outcome.result with
        | Ok result -> check (option bool) "retry keeps valid conversation" (Some seeded) result.session_resumed
        | Error error -> fail (Agent_core.Error.to_string error))))
      ["hang_init"; "hang_session"; "hang_before_ack"]) [false; true]
;;

let test_changed_explicit_workspace_starts_fresh () =
  with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    (match (run_turn_with ~base_path ~tool ()).outcome.result with
     | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
    let workspace_root = Filename.concat base_path "second-workspace" in
    Fs_compat.mkdir_p workspace_root;
    write_fixture ~root:workspace_root ~base_path [];
    List.iter (fun () ->
      match (run_turn_with ~workspace_root ~base_path ~tool ()).outcome.result with
      | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error)) [(); ()];
    check (list string) "new workspace is a fresh session, then resumes"
      ["start"; "start"; "resume"]
      (read_text (Filename.concat base_path "sessions.log")
       |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")))
;;

let test_missing_selected_account_auth_requires_sign_in () =
  with_scripted_host (fun ~base_path ->
    let auth = Filename.concat base_path "account-home/.config/muse/auth.json" in
    Unix.unlink auth;
    let run = run_turn_with ~base_path ~tool:(masc_probe_tool (ref `Null)) () in
    (match run.outcome.result with
     | Error (Agent_core.Error.Provider (Llm_provider.Error.AuthError _)) -> ()
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok _ -> fail "missing selected account auth reached the client");
    check bool "no ambient-account client spawned" false
      (Sys.file_exists (Filename.concat base_path "selected-home.txt"));
    check bool "no vendor effect" true
      (run.outcome.effect_disposition = Keeper_provider_attempt_effect.No_effect_observed);
    check bool "no durable session claimed" true
      (match Store.load ~base_path ~keeper_name with Ok None -> true | _ -> false))
;;

let test_invalid_goal_media_never_claims_or_spawns () =
  let image media_type data = Agent_core.Types.Image
    {media_type; data; source_type=Agent_core.Types.Base64} in
  let invalid_blocks =
    [ [Agent_core.Types.Text "Call masc_probe once"; image "image/png" "!not-base64!"];
      [Agent_core.Types.Text "Call masc_probe once"; image "image/svg+xml" "aGVsbG8="];
      [Agent_core.Types.Text "Call masc_probe once"; image "image/png\255" "aGVsbG8="];
      [Agent_core.Types.Text "Call masc_probe once"; image "image/png" "\255"];
      [Agent_core.Types.Text "Call masc_probe once"; image "image/png" ""];
      [Agent_core.Types.Text "Call masc_probe once"; image "image/png" "aGVs\nbG8="];
      [Agent_core.Types.Text "invalid goal \255"] ] in
  List.iter (fun seeded -> with_scripted_host (fun ~base_path ->
    let tool = masc_probe_tool (ref `Null) in
    if seeded then (match (run_turn_with ~base_path ~tool ()).outcome.result with
      | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
    let before = Store.load ~base_path ~keeper_name |> Result.get_ok in
    let spawn_receipt = Filename.concat base_path "selected-home.txt" in
    if Sys.file_exists spawn_receipt then Unix.unlink spawn_receipt;
    List.iter (fun goal_blocks ->
      let run = run_turn_with ~accepts_image_input:true ~goal_blocks ~base_path ~tool () in
      (match run.outcome.result with
       | Error (Agent_core.Error.Config (InvalidConfig _)) -> ()
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok _ -> fail "invalid goal media reached the provider");
      check bool "invalid media does not spawn a client" false (Sys.file_exists spawn_receipt);
      check bool "invalid media leaves the durable session unchanged" true
        (before = (Store.load ~base_path ~keeper_name |> Result.get_ok));
      check bool "invalid media admits no provider effect" true
        (run.outcome.effect_disposition = Keeper_provider_attempt_effect.No_effect_observed))
      invalid_blocks)) [false; true]
;;

let test_native_none_is_refused_before_spawn () =
  with_scripted_host (fun ~base_path ->
    declare_keeper ~base_path
      "sandbox_profile = \"docker\"\nsandbox_image = \"base\"\n[keeper.tools]\nnative = \"none\"\n";
    let run = run_turn_with ~base_path ~tool:(masc_probe_tool (ref `Null)) () in
    (match run.outcome.result with
     | Error (Agent_core.Error.Config (InvalidConfig {field="required_native_posture"; _})) -> ()
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok _ -> fail "Muse silently degraded native none");
    check bool "no client spawned" false
      (Sys.file_exists (Filename.concat base_path "selected-home.txt")))
;;

let test_attached_mcp_approvals_are_exact () =
  with_scripted_host (fun ~base_path ->
    (match (run_turn ~base_path ~tool:(masc_probe_tool (ref `Null))).outcome.result with
     | Ok _ -> ()
     | Error error -> fail (Agent_core.Error.to_string error));
    check (list string) "answers"
      [ "mcp__masc__masc_probe allow_once -"; "mcp__unattached__masc_probe abort -";
        "mcp__masc__masc_probe abort -"; "mcp__masc__masc_probe abort -"; "bash abort -"; "read_file abort -" ]
      (read_text (Filename.concat base_path "decisions.log")
       |> String.split_on_char '\n'
       |> List.filter (fun line -> line <> ""));
    let start_prompt = read_text (Filename.concat base_path "start-prompt.txt") in
    List.iter
      (fun note ->
         check bool "the start prompt states the posture" true
           (String_util.contains_substring start_prompt note))
      (Adapter.native_posture_note Runtime_native_tools.Native_read))
;;

let () =
  run
    "keeper_muse_runtime"
    [ ( "stream"
      , [ test_case "identity-less native tool leaves no open block" `Quick test_native_tool_without_identity_does_not_open_a_block
        ; test_case "projection order" `Quick test_stream_order
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
        ; test_case "usage names the model the calls ran on" `Quick
            test_usage_report_names_the_model_the_calls_ran_on
        ; test_case "usage after an unnamed call is not the earlier model" `Quick
            test_usage_report_after_an_unnamed_call_is_not_the_earlier_model
        ; test_case "a turn is named after its last reported call" `Quick
            test_turn_is_named_after_its_last_reported_call
        ] )
    ; ( "errors"
      , [ test_case "callback failure keeps persistence cause" `Quick test_persistence_cause_survives_callback_protocol_projection
        ; test_case "session refusals start fresh next" `Quick
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
        ; test_case "declared Muse runtime routes and resumes Keeper turns" `Quick
            test_declared_muse_runtime_routes_keeper_turns
        ; test_case "subscription exhaustion uses selected account scope" `Quick
            test_subscription_exhaustion_is_account_scoped
        ; test_case "usage read rests the exhausted Muse account without a turn" `Quick
            test_muse_usage_read_rests_only_the_selected_account
        ; test_case "failed Muse turn reads typed usage without replay" `Quick
            test_failed_muse_turn_reads_typed_usage_without_replay
        ; test_case "prepared hook tool surface controls session binding" `Quick test_hook_tool_surface_controls_session_binding
        ; test_case "completed message suffix is forwarded once" `Quick test_completed_message_suffix_is_forwarded_once
        ; test_case "later unstreamed message reaches live consumers" `Quick test_later_unstreamed_message_reaches_live_consumers
        ; test_case "text-only host needs no session MCP" `Quick test_text_only_session_does_not_require_session_mcp
        ] )
    ; ( "turn endings"
      , [ test_case "MCP setup failure preserves previous settlement" `Quick test_bridge_setup_failure_preserves_previous_settlement
        ; test_case "capability refusal preserves previous settlement" `Quick test_capability_refusal_preserves_previous_settlement
        ; test_case "retry previous refuses externally advanced session" `Quick test_retry_previous_refuses_an_externally_advanced_session
        ; test_case "a non-empty started session is refused" `Quick
            test_nonempty_start_is_refused
        ; test_case "host stop resume requires folded native terminal" `Quick test_host_stop_resume_requires_a_folded_native_terminal
        ; test_case "admission timeout releases only undispatched claims" `Quick test_admission_timeout_restores_only_undispatched_claims
        ; test_case "read-only MCP failure preserves effect classification" `Quick test_read_only_mcp_failure_does_not_invent_an_effect
        ; test_case "a host that exits mid-turn leaves recovery" `Quick
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
        ; test_case "resumed model is re-selected before dispatch" `Quick
            test_resumed_model_is_reselected_before_dispatch
        ; test_case "a changed model starts a fresh session" `Quick
            test_a_changed_model_starts_a_fresh_session
        ] )
    ; ( "owner stops"
      , [ test_case "an operator interrupt keeps the settled session" `Quick
            test_an_operator_interrupt_keeps_the_settled_session
        ; test_case "an operator interrupt a callback raises keeps the settled session" `Quick
            test_an_operator_interrupt_a_callback_raises_keeps_the_settled_session
        ; test_case "owner cancellation after completion retains recovery" `Quick
            test_owner_cancellation_after_completion_keeps_recovery
        ; test_case "owner cancellation after retryable terminal retains turn" `Quick
            test_owner_cancellation_after_retryable_terminal_retains_turn
        ] )
    ; ( "account selection"
      , [ test_case "account switch starts fresh" `Quick test_account_selection_starts_a_fresh_vendor_session
        ; test_case "source relogin starts fresh, refresh survives" `Quick test_source_relogin_starts_fresh_and_preserves_vendor_refresh
        ; test_case "recall blocks deduplicated on native resume" `Quick test_resume_deduplicates_recall_blocks
        ; test_case "recall restored after host compaction" `Quick test_resume_restores_recall_after_compaction
        ; test_case "noop compaction preserves held recall" `Quick test_resume_keeps_recall_after_noop_compaction
        ; test_case "hook nudge identity and carried context" `Quick test_hook_nudges_bind_the_session_but_carried_context_does_not
        ; test_case "per-call usage survives missing terminal aggregate" `Quick test_call_usage_survives_missing_terminal_aggregate
        ; test_case "effective system override starts fresh" `Quick test_effective_system_override_starts_fresh
        ; test_case "missing selected auth requires sign-in before spawn" `Quick test_missing_selected_account_auth_requires_sign_in
        ; test_case "invalid goal media refuses before claim and spawn" `Quick test_invalid_goal_media_never_claims_or_spawns
        ; test_case "native none refuses before spawn" `Quick test_native_none_is_refused_before_spawn ])
    ; ( "workspace root"
      , [ test_case "the session works in the Keeper's playground" `Quick
            test_the_session_works_in_the_keepers_playground
        ; test_case "changed explicit root starts fresh" `Quick test_changed_explicit_workspace_starts_fresh
        ; test_case "attached MCP approvals are exact" `Quick
            test_attached_mcp_approvals_are_exact
        ] )
    ]
;;
