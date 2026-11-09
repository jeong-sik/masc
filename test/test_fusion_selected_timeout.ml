open Alcotest

type client = Claude | Codex | Antigravity | Muse
type reload = Replace of float option | Remove

let client_name = function
  | Claude -> "Claude" | Codex -> "Codex"
  | Antigravity -> "Antigravity" | Muse -> "Muse"

let client_mode = function
  | Claude -> "claude" | Codex -> "codex"
  | Antigravity -> "agy" | Muse -> "muse"

let client_protocol = function
  | Claude -> "claude-code" | Codex -> "codex-app-server"
  | Antigravity -> "antigravity-cli" | Muse -> "muse-serve"

let write_file ~path ~perm contents =
  let channel = open_out_gen [Open_creat; Open_trunc; Open_wronly] perm path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)
;;

let shell_quote text =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' text) ^ "'"
;;

(* Each controlled host completes admission and receives the model input before
   pausing. A timeout must therefore be the selected model-idle window, not a
   failed login or a process that never consumed its request. *)
let host_script = {|import json, os, sys, time
MODE = sys.argv[1]
ARGS = sys.argv[2:]
HERE = os.path.dirname(os.path.abspath(__file__))
ANSWER = "FUSION_SELECTED_TIMEOUT"

def record(phase):
    with open(os.path.join(HERE, "trace.jsonl"), "a") as handle:
        handle.write(json.dumps({"client": MODE, "phase": phase}) + "\n")

def send(frame):
    print(json.dumps(frame), flush=True)

def read():
    line = sys.stdin.readline()
    assert line, "missing client frame"
    return json.loads(line)

def pause_after_input():
    time.sleep(0.4)

if MODE == "claude":
    if "auth" in ARGS and "status" in ARGS:
        send({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"})
        sys.exit(0)
    session = next(arg.split("=", 1)[1] for arg in ARGS if arg.startswith("--session-id="))
    model = ARGS[ARGS.index("--model") + 1]
    request = read()
    assert request["type"] == "control_request" and request["request"]["subtype"] == "initialize"
    send({"type": "control_response", "response": {"subtype": "success", "request_id": request["request_id"], "response": {}}})
    assert read()["type"] == "user"
    record("turn_received")
    send({"type": "system", "subtype": "init", "session_id": session})
    pause_after_input()
    send({"type": "assistant", "parent_tool_use_id": None, "session_id": session, "uuid": "timeout-assistant", "message": {
        "role": "assistant", "model": model, "content": [{"type": "text", "text": ANSWER}]}})
    send({"type": "result", "subtype": "success", "is_error": False, "session_id": session,
        "uuid": "timeout-result", "result": ANSWER, "api_error_status": None})
elif MODE == "codex":
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        if method == "initialize":
            result = {"userAgent": "timeout-fixture"}
        elif method == "account/read":
            result = {"account": {"type": "chatgpt", "planType": "pro"}, "requiresOpenaiAuth": True}
        elif method == "model/list":
            result = {"data": [{"id": "timeout-fixture", "model": "timeout-fixture", "displayName": "Timeout fixture",
                "isDefault": True, "supportedReasoningEfforts": [{"reasoningEffort": "low", "description": "Low"}],
                "defaultReasoningEffort": "low"}], "nextCursor": None}
        elif method == "thread/start":
            result = {"thread": {"id": "thread-1"}, "model": "timeout-fixture"}
        elif method == "turn/start":
            result = {"turn": {"id": "turn-1"}}
            record("turn_received")
        else:
            raise AssertionError(method)
        send({"id": request["id"], "result": result})
        if method == "turn/start":
            pause_after_input()
            item = {"type": "agentMessage", "id": "message-1", "text": ANSWER, "phase": "final_answer"}
            send({"method": "item/completed", "params": {"threadId": "thread-1", "turnId": "turn-1", "item": item}})
            send({"method": "turn/completed", "params": {"threadId": "thread-1", "turn": {
                "id": "turn-1", "items": [item], "status": "completed"}}})
            break
elif MODE == "agy":
    assert sys.stdin.read(), "missing Antigravity prompt"
    record("turn_received")
    send({"event": "init", "conversation_id": "timeout-agy", "init": {
        "model": "timeout-fixture", "cwd": os.getcwd(), "tools": [], "permission_mode": "always-proceed"}})
    pause_after_input()
    send({"event": "result", "result": {"conversation_id": "timeout-agy", "status": "SUCCESS",
        "response": ANSWER, "num_turns": 1, "usage": {
            "input_tokens": 1, "output_tokens": 1, "thinking_tokens": 0, "cache_read_tokens": 0, "total_tokens": 2}}})
elif MODE == "muse":
    initialized = read()
    assert initialized["method"] == "initialize"
    send({"jsonrpc": "2.0", "id": initialized["id"], "result": {
        "serverInfo": {"name": "muse-session-server", "version": "1.3.0"},
        "userAgent": "muse/1.3.0", "museHome": os.path.join(os.environ["XDG_DATA_HOME"], "muse"),
        "platformFamily": "unix", "platformOs": "linux", "schema": {"version": 1, "fingerprint": "sha256:fixture"},
        "grantedCapabilities": [], "experimentalApi": False, "sessionDurability": "durable"}})
    assert read()["method"] == "initialized"
    opened = read()
    assert opened["method"] == "session/start"
    send({"jsonrpc": "2.0", "id": opened["id"], "result": {
        "session": {"sessionId": "timeout-session", "status": "idle", "turnCount": 0,
            "approvalMode": {"mode": "promptUnmatched", "source": "startup", "lastCommandId": None},
            "modelId": opened["params"]["modelId"], "workspaceRoot": opened["params"]["workspaceRoot"]},
        "viewCursor": "v:1"}})
    turn = read()
    assert turn["method"] == "turn/start"
    record("turn_received")
    turn_id = turn["params"]["commandId"]
    # The host certifies a completed turn from its durable history, so it asks
    # the controlled host for a backward view page once the terminal arrives.
    # The host retains the events it sent, as a real session does.
    retained = []
    def notify(method, params):
        event = {"method": method, "params": params}
        if method in ("turn/started", "item/completed"):
            position = {"id": "timeout-record-%d" % (len(retained) + 1), "sequence": len(retained) + 1}
            params["sourceRange"] = {"stream": {"kind": "run", "id": "timeout-run"},
                                     "first": position, "last": position}
            retained.append(event)
        send({"jsonrpc": "2.0", **event})
    send({"jsonrpc": "2.0", "id": turn["id"], "result": {"commandId": turn_id,
        "status": "accepted", "turnId": turn_id, "startedNewTurn": True, "disposition": "started"}})
    notify("turn/started", {
        "sessionId": "timeout-session", "turnId": turn_id, "commandId": turn_id, "viewCursor": "v:2"})
    pause_after_input()
    notify("item/completed", {
        "sessionId": "timeout-session", "viewCursor": "v:3", "item": {"itemId": "m-1", "kind": "agentMessage",
            "turnId": turn_id, "revision": 1, "status": "completed", "text": ANSWER}})
    notify("turn/completed", {
        "sessionId": "timeout-session", "turnId": turn_id, "terminal": "completed", "viewCursor": "v:4", "error": None,
        "usage": {"inputTokens": 1, "outputTokens": 1, "cachedTokens": 0, "reasoningTokens": 0}})
    for line in sys.stdin:
        request = json.loads(line)
        if request.get("method") == "view/page":
            assert request["params"]["sessionId"] == "timeout-session"
            assert request["params"]["cursor"] == "v:4" and request["params"]["direction"] == "backward"
            send({"jsonrpc": "2.0", "id": request["id"], "result": {"events": retained, "nextCursor": None}})
else:
    raise AssertionError(MODE)
for line in sys.stdin:
    pass
|}
;;

let runtime_fixture ~client ~cli_path ~account_home ~oauth_source ~model_key ~declared =
  let credential = match client with
    | Antigravity -> Printf.sprintf "timeout-s = 3.0\ncredentials = { type = \"file\", path = %S }" oauth_source
    | Claude | Codex | Muse -> Printf.sprintf "account-home = %S" account_home in
  let timeout = match declared with
    | None -> "" | Some seconds -> Printf.sprintf "turn-timeout-s = %.17g" seconds in
  Printf.sprintf {|
[runtime]
default = "native.%s"
[providers.native]
protocol = %S
command = %S
is-non-interactive = true
%s
[models.%s]
api-name = "timeout-fixture"
max-context = 4096
tools-support = true
streaming = true
%s
[native.%s]
|} model_key (client_protocol client) cli_path credential model_key timeout model_key
;;

let in_eio_context f =
  Eio_main.run (fun env ->
    Eio_context.set_env env;
    Eio.Switch.run (fun sw -> Eio_context.with_test_env
      ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw f))
;;

let test_selected_timeout ~client ~selected_timeout ~reload ~override_s ~expect_timeout () =
  let root = Filename.temp_dir "fusion-selected-timeout-" "" |> Unix.realpath in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let eio_snapshot = Eio_context.snapshot_state () in
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some root) @@ fun () ->
  Fun.protect ~finally:(fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    Eio_context.restore_state eio_snapshot;
    Fs_compat.remove_tree root) @@ fun () ->
  let host = Filename.concat root "host.py" in
  let cli_path = Filename.concat root "native-fixture" in
  let account_home = Filename.concat root "selected-account" in
  let oauth_source = Filename.concat root "oauth.json" in
  let config_path = Filename.concat root "runtime.toml" in
  Fs_compat.mkdir_p (Filename.concat account_home ".config/muse");
  write_file ~path:(Filename.concat account_home ".config/muse/auth.json") ~perm:0o600
    {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-LOCAL-ONLY"}}}|};
  write_file ~path:oauth_source ~perm:0o600 (Masc_test_deps.antigravity_oauth_fixture "timeout-fixture");
  write_file ~path:host ~perm:0o600 host_script;
  write_file ~path:cli_path ~perm:0o700 (Printf.sprintf
    "#!/bin/sh\nexec python3 %s %s \"$@\"\n" (shell_quote host) (shell_quote (client_mode client)));
  let load ~model_key ~declared =
    write_file ~path:config_path ~perm:0o600
      (runtime_fixture ~client ~cli_path ~account_home ~oauth_source ~model_key ~declared);
    match Runtime.init_default ~config_path with
    | Ok () -> () | Error detail -> failf "native timeout fixture must initialize: %s" detail in
  load ~model_key:"fixture" ~declared:selected_timeout;
  let selected : Runtime_instance.t = match Runtime.get_runtime_by_id "native.fixture" with
    | Some runtime -> runtime | None -> fail "selected native runtime must exist" in
  check (option (float 0.)) "the selected declaration came from the loaded catalog"
    selected_timeout selected.model.turn_timeout_s;
  (match reload with
   | Replace declared ->
     load ~model_key:"fixture" ~declared;
     let current = Runtime.get_runtime_by_id "native.fixture" |> Option.get in
     check (option (float 0.)) "the live catalog actually changed" declared current.model.turn_timeout_s
   | Remove ->
     load ~model_key:"replacement" ~declared:None;
     check bool "the selected runtime was removed from live lookup" true
       (Option.is_none (Runtime.get_runtime_by_id "native.fixture")));
  let result = in_eio_context (fun () -> Masc.Fusion_official_client.run_with_images
    ~images:[] ~base_dir:root ~runtime:selected ~system_prompt:""
    ?timeout_s:override_s ~prompt:"Return the fixture marker." ()) in
  let phases = Fs_compat.load_file (Filename.concat root "trace.jsonl")
    |> String.split_on_char '\n' |> List.filter (fun row -> row <> "")
    |> List.map (fun row -> Yojson.Safe.from_string row |> Yojson.Safe.Util.member "phase" |> Yojson.Safe.Util.to_string) in
  check bool "the native child consumed its model input before the model-idle wait" true
    (List.mem "turn_received" phases);
  (match result with
   | Error failure when expect_timeout ->
     (match Masc.Fusion_official_client.panel_failure ~runtime_id:"native.fixture" failure with
      | Fusion_types.Timeout -> ()
      | _ -> fail (Masc.Fusion_official_client.failure_detail ~runtime_id:"native.fixture" failure))
   | Ok response when not expect_timeout ->
     check string "native terminal marker" "FUSION_SELECTED_TIMEOUT" response.text
   | Ok _ -> fail "the selected model-idle deadline was replaced by a later live lookup"
   | Error failure -> fail (Masc.Fusion_official_client.failure_detail ~runtime_id:"native.fixture" failure))
;;

let cases client =
  List.map (fun (name, selected_timeout, reload, override_s, expect_timeout) ->
    test_case (client_name client ^ " " ^ name) `Quick
      (test_selected_timeout ~client ~selected_timeout ~reload ~override_s ~expect_timeout))
    ["selected unbounded survives a live positive timeout", Some 0., Replace (Some 0.1), None, false;
     "selected positive survives a live unbounded timeout", Some 0.1, Replace (Some 0.), None, true;
     "selected absence ignores a newly declared live timeout", None, Replace (Some 0.1), None, false;
     "selected positive survives runtime removal", Some 0.1, Remove, None, true;
     "explicit short preset overrides the selected default", Some 1.2, Replace (Some 1.2), Some 0.1, true;
     "explicit long preset overrides the selected default", Some 0.1, Replace (Some 0.1), Some 1.2, false]
;;

let () =
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  Masc.Prompt_defaults.init ();
  Masc_test_deps.publish_single_user_access ();
  run "Fusion selected model idle"
    ["selected timeout", List.concat_map cases [Claude; Codex; Antigravity; Muse]]
;;
