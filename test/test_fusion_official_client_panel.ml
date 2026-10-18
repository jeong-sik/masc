open Alcotest

(* The panel split in Fusion_panel keys entirely on [is_official_client]: a true
   sends the panelist to the spawn path, a false sends it to build_agent. Before
   this existed, official-client panelists reached build_agent, failed provider
   resolution, and never answered — a panel made only of them ended in
   Panels_unavailable, and a mixed panel completed on quorum with those seats
   silently empty.

   Pinning the predicate alone would not notice the split being dropped from
   fusion_panel.ml, so the last test drives Fusion_panel.run for real and judges
   by whether the client process was spawned, not by what the error said.

   The repo seed has its claude_code provider commented out, so the fixture
   declares its own rather than asserting against a config that happens not to
   have one today. *)

let fixture ~claude_cli =
  Printf.sprintf
    {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[providers.claude_code]
display-name = "Claude Code Max Subscription"
protocol = "claude-code"
command = "%s"
is-non-interactive = true

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[stub-http.stub-model]

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-sonnet-5"]

[models."claude-opus-5-5"]
api-name = "claude-opus-5-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-opus-5-5"]

[runtime.lanes.fusion-judge]
candidates = ["claude_code.claude-opus-5-5", "claude_code.claude-sonnet-5"]
|}
    claude_cli
;;

(* The judge prompt is rendered from the registry, so resolution must point at
   the repo's own prompt files or the render raises inside the dune sandbox. *)
let () =
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  Masc.Prompt_defaults.init ()
;;

let official_client_runtime = "claude_code.claude-sonnet-5"
let agent_core_runtime = "stub-http.stub-model"
let judge_lane = "fusion-judge"
let judge_lane_first = "claude_code.claude-opus-5-5"

let write_file ~path ~perm contents =
  let channel = open_out_gen [ Open_creat; Open_trunc; Open_wronly ] perm path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)
;;

(* A stand-in for the Claude Code CLI that records the fact of its own execution
   and nothing else. The marker path is baked into the script because the claude
   adapter runs the client under a restricted environment allowlist, so a value
   passed through the environment would not survive to the child. *)
let stub_cli_script ~marker = Printf.sprintf "#!/bin/sh\n: > '%s'\nexit 0\n" marker

let with_initialized_runtime ~claude_cli f =
  let path = Filename.temp_file "fusion-official-client" ".toml" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       write_file ~path ~perm:0o600 (fixture ~claude_cli);
       match Runtime.init_default ~config_path:path with
       | Error detail -> failf "fixture runtime must initialize: %s" detail
       | Ok () -> f ())
;;

(* /usr/bin/true is enough for the tests that only read the runtime table: they
   classify a runtime without executing it. *)
let with_classification_runtime f = with_initialized_runtime ~claude_cli:"/usr/bin/true" f

let test_official_client_runtime_is_routed_to_the_spawn_path () =
  with_classification_runtime (fun () ->
    check
      bool
      "a claude-code binding is an official-client panelist"
      true
      (Masc.Fusion_official_client.is_official_client ~runtime_id:official_client_runtime))
;;

let test_agent_core_runtime_stays_on_the_async_agent_path () =
  with_classification_runtime (fun () ->
    check
      bool
      "an HTTP binding is not an official-client panelist"
      false
      (Masc.Fusion_official_client.is_official_client ~runtime_id:agent_core_runtime))
;;

(* An unknown id must not be claimed by this path. The Agent_core path already
   reports it precisely ("no provider config"); routing it here would replace
   that message with a spawn-side one that names the wrong subsystem. *)
let test_unknown_runtime_is_not_claimed_by_the_spawn_path () =
  with_classification_runtime (fun () ->
    check
      bool
      "an unconfigured id is left to the Agent_core path to report"
      false
      (Masc.Fusion_official_client.is_official_client ~runtime_id:"nope.not-configured"))
;;

let test_official_client_panel_honors_no_deadline () =
  with_classification_runtime (fun () ->
    check bool "turn-timeout-s = 0 removes the panel turn deadline" true
      (Option.is_none
         (Masc.Fusion_official_client.For_testing.resolved_timeout_s
            ~runtime_id:official_client_runtime
            ~override_s:None
            ~default_timeout_s:300.0)))
;;

let test_unbounded_claude_panel_keeps_login_probe_bounded () =
  let turn_config =
    { (Runtime_claude_code.default_config ~cwd:"/tmp") with timeout_s = None }
  in
  let probe_config =
    Masc.Fusion_official_client.For_testing.bounded_claude_probe_config
      ~fallback_timeout_s:17.0
      turn_config
  in
  match probe_config.timeout_s with
  | Some seconds -> check (float 0.0) "probe fallback" 17.0 seconds
  | None -> fail "unbounded panel turn leaked into the Claude login probe"
;;

let panel_group models : Fusion_policy.panel_group =
  { models
  ; label = ""
  ; system_prompt = "Answer in one word."
  ; web_tools = false
  ; max_output_tokens = None
        ; timeout_s = None
  }
;;

(* Judged by the marker, not by the error text. The stub CLI emits no result
   event, so this panelist fails either way — what separates "routed to the
   spawn path" from "routed to build_agent" is whether the client ran at all.
   Delete the official branch in fusion_panel.ml and the marker stops
   appearing. *)
let test_official_client_panelist_reaches_its_client () =
  let base_dir = Filename.temp_dir "fusion-official-client-run" "" in
  let marker = Filename.concat base_dir "spawned" in
  let claude_cli = Filename.concat base_dir "stub-claude" in
  let observed_trace = ref None in
  write_file ~path:claude_cli ~perm:0o700 (stub_cli_script ~marker);
  with_initialized_runtime ~claude_cli (fun () ->
    let outcomes =
      Eio_main.run (fun env ->
        Eio_context.set_env env;
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~sw
            (fun () ->
               Masc.Fusion_panel.run
                 ~base_dir
                 ~sw
                 ~net:(Eio.Stdenv.net env)
                 ~groups:[ panel_group [ official_client_runtime ] ]
                 ~prompt:"ping"
                 ~on_tool_trace:(fun trace -> observed_trace := Some trace)
                 ())))
    in
    check bool "the official client was executed" true (Sys.file_exists marker);
    (* One declared panelist stays one reported outcome. A panelist dropped
       rather than run is the failure mode that survives a quorum. *)
    check int "the panelist is accounted for in the outcomes" 1 (List.length outcomes);
    match !observed_trace with
    | Some
        { Fusion_types.observed_actors = []
        ; events = []
        ; dropped_events = 0
        ; gaps =
            [ { actor = Fusion_types.Panel_actor actor
              ; reason = Fusion_types.Official_client_uninstrumented
              }
            ]
        } ->
      check string "official-client trace gap names the actor"
        official_client_runtime actor
    | Some _ -> fail "official-client execution must publish one explicit trace gap"
    | None -> fail "official-client execution did not publish Tool trace coverage")
;;

(* A judge seat is routed by the same predicate as a panel seat. Judged by the
   marker, as above: the stub emits no result event, so the judge fails either
   way, and what separates the two routes is whether the client ran at all.
   Remove the official branch from fusion_judge.ml and the marker stops
   appearing while the failure turns into [Build_error]. *)
let test_official_client_judge_reaches_its_client () =
  let base_dir = Filename.temp_dir "fusion-official-client-judge" "" in
  let marker = Filename.concat base_dir "spawned" in
  let claude_cli = Filename.concat base_dir "stub-claude" in
  let observed_trace = ref None in
  let actor =
    Fusion_types.Judge_actor
      { role = Fusion_types.Single; identity = official_client_runtime }
  in
  write_file ~path:claude_cli ~perm:0o700 (stub_cli_script ~marker);
  with_initialized_runtime ~claude_cli (fun () ->
    let result =
      Eio_main.run (fun env ->
        Eio_context.set_env env;
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~sw
            (fun () ->
               Masc.Fusion_judge.run
                 ~base_dir
                 ~sw
                 ~net:(Eio.Stdenv.net env)
                 ~judge_system_prompt:"Judge the panel."
                 ~judge_model:official_client_runtime
                 ~question:"ping"
                 ~panel:
                   [ Fusion_types.Answered
                       { model = agent_core_runtime
                       ; answer = "pong"
                       ; usage = Fusion_types.zero_usage
                       }
                   ]
                 ~web_tools:false
                 ~tool_trace:(actor, fun trace -> observed_trace := Some trace)
                 ())))
    in
    check bool "the official client was executed" true (Sys.file_exists marker);
    (match result with
     | Ok _ -> fail "the stub client emits no result, so no synthesis can come back"
     | Error (Fusion_types.Build_error detail, _) ->
       failf "an official-client judge must not reach build_agent: %s" detail
     | Error (_, usage) ->
       check bool "an official client reports no token usage" true
         (Fusion_types.equal_usage usage Fusion_types.zero_usage));
    match !observed_trace with
    | Some
        { Fusion_types.observed_actors = []
        ; events = []
        ; dropped_events = 0
        ; gaps = [ { actor = gap_actor; reason = Fusion_types.Official_client_uninstrumented } ]
        } ->
      check bool "the trace gap names the judge actor" true
        (Fusion_types.equal_tool_trace_actor actor gap_actor)
    | Some _ -> fail "an official-client judge must publish one explicit trace gap"
    | None -> fail "an official-client judge did not publish Tool trace coverage")
;;

(* Antigravity has no system-prompt channel, so the one-shot turn has to carry
   the instructions in its input. The stub records exactly what it received on
   stdin and answers with a valid judge synthesis, which also drives the
   official-client judge through a successful parse. *)
let agy_runtime = "agy.gemini"

let shell_quote text =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' text) ^ "'"
;;

let agy_fixture ~agy_cli ~oauth_source =
  Printf.sprintf
    {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[stub-http.stub-model]

[providers.agy]
protocol = "antigravity-cli"
command = %S
is-non-interactive = true
timeout-s = 10.0
credentials = { type = "file", path = %S }

[models.gemini]
api-name = "gemini-fixture"
max-context = 128000

[agy.gemini]
|}
    agy_cli
    oauth_source
;;

let judge_synthesis_json ~answer =
  `Assoc
    [ Fusion_judge_parse.wire_field_consensus, `List []
    ; Fusion_judge_parse.wire_field_contradictions, `List []
    ; Fusion_judge_parse.wire_field_partial_coverage, `List []
    ; Fusion_judge_parse.wire_field_unique_insights, `List []
    ; Fusion_judge_parse.wire_field_blind_spots, `List []
    ; Fusion_judge_parse.wire_field_resolved_answer, `String answer
    ; ( Fusion_judge_parse.wire_field_decision
      , `Assoc
          [ Fusion_judge_parse.wire_field_decision_kind
          , `String Fusion_judge_parse.wire_decision_answer
          ; Fusion_judge_parse.wire_field_answer, `String answer
          ] )
    ]
;;

let recording_agy_script ~input_path ~response =
  let init =
    `Assoc
      [ "event", `String "init"
      ; "conversation_id", `String "fusion-agy"
      ; ( "init"
        , `Assoc
            [ "model", `String "gemini-fixture"
            ; "tools", `List []
            ; "permission_mode", `String "always-proceed"
            ] )
      ]
  in
  let result =
    `Assoc
      [ "event", `String "result"
      ; ( "result"
        , `Assoc
            [ "conversation_id", `String "fusion-agy"
            ; "status", `String "SUCCESS"
            ; "response", `String response
            ; "num_turns", `Int 1
            ; ( "usage"
              , `Assoc
                  [ "input_tokens", `Int 100
                  ; "output_tokens", `Int 7
                  ; "thinking_tokens", `Int 3
                  ; "cache_read_tokens", `Int 50
                  ; "total_tokens", `Int 107
                  ] )
            ] )
      ]
  in
  Printf.sprintf "#!/bin/sh\nset -eu\ncat > %s\npython3 -c %s %s\nprintf '%%s\\n' %s\n"
    (shell_quote input_path)
    (shell_quote "import json,os,sys; frame=json.loads(sys.argv[1]); frame['init']['cwd']=os.getcwd(); print(json.dumps(frame))")
    (shell_quote (Yojson.Safe.to_string init))
    (shell_quote (Yojson.Safe.to_string result))
;;

let index_of ~needle haystack =
  let n = String.length needle in
  let rec scan i =
    if i + n > String.length haystack
    then None
    else if String.equal (String.sub haystack i n) needle
    then Some i
    else scan (i + 1)
  in
  scan 0
;;

(* [lstat], not [Sys.is_directory]: a symlink the client leaves behind is
   removed as a link, never followed out of the temporary directory. *)
let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Sys.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let frame_label = function
  | Ok label -> String.trim label
  | Error detail -> failf "the Antigravity frame label must load: %s" detail
;;

let test_antigravity_judge_receives_its_system_prompt () =
  let snapshot = Runtime.For_testing.snapshot () in
  let base_dir = Filename.temp_dir "fusion-agy-judge" "" |> Unix.realpath in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      remove_tree base_dir)
  @@ fun () ->
  let input_path = Filename.concat base_dir "agy-input" in
  let agy_cli = Filename.concat base_dir "agy" in
  let oauth_source = Filename.concat base_dir "oauth.json" in
  let config_path = Filename.concat base_dir "runtime.toml" in
  let lens = "LENS-MARKER judge through the lens of restart safety" in
  let question = "QUESTION-MARKER which candidate ships?" in
  write_file ~path:oauth_source ~perm:0o600 (Masc_test_deps.antigravity_oauth_fixture "fixture");
  write_file ~path:agy_cli ~perm:0o700
    (recording_agy_script ~input_path
       ~response:(Yojson.Safe.to_string (judge_synthesis_json ~answer:"ship B")));
  write_file ~path:config_path ~perm:0o600 (agy_fixture ~agy_cli ~oauth_source);
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> failf "antigravity fixture must initialize: %s" detail);
  let result =
    Eio_main.run (fun env ->
      Eio_context.set_env env;
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~sw
          (fun () ->
             Masc.Fusion_judge.run
               ~base_dir
               ~sw
               ~net:(Eio.Stdenv.net env)
               ~judge_system_prompt:lens
               ~judge_model:agy_runtime
               ~question
               ~panel:
                 [ Fusion_types.Answered
                     { model = agent_core_runtime
                     ; answer = "B keeps restart evidence"
                     ; usage = Fusion_types.zero_usage
                     }
                 ]
               ~web_tools:false
               ())))
  in
  (match result with
   | Ok (synthesis, usage) ->
     check int "cache-inclusive Antigravity judge input" 150 usage.Fusion_types.input_tokens;
     check int "Antigravity judge output" 7 usage.output_tokens;
     check string "the client's synthesis is parsed" "ship B"
       synthesis.Fusion_types.resolved_answer
   | Error (failure, _usage) ->
     failf "the Antigravity judge should synthesize, got %s"
       (Fusion_types.judge_failure_text failure));
  let input =
    let channel = open_in_bin input_path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  let system_label = frame_label (Masc.Antigravity_input_frame.system_instructions_label ()) in
  let goal_label = frame_label (Masc.Antigravity_input_frame.current_goal_label ()) in
  let position label needle =
    match index_of ~needle input with
    | Some at -> at
    | None -> failf "%s never reached the Antigravity client" label
  in
  let order =
    [ position "the instructions label" system_label
    ; position "the judge system prompt" "LENS-MARKER"
    ; position "the goal label" goal_label
    ; position "the question" "QUESTION-MARKER"
    ]
  in
  check (list int) "instructions label, lens, goal label, question, in that order"
    (List.sort Int.compare order) order
;;

let muse_fixture ~muse_cli ~account_home =
  Printf.sprintf
    {|
[runtime]
default = "muse_code.muse-spark"

[providers.muse_code]
protocol = "muse-serve"
command = "%s"
account-home = "%s"
is-non-interactive = true

[models.muse-spark]
api-name = "muse-spark-1.3"
max-context = 1007997
reasoning-effort = "high"

[muse_code.muse-spark]
|}
    muse_cli
    account_home
;;

let muse_runtime_id = "muse_code.muse-spark"

(* The serve client runs [cli_path serve] in the panelist's own workspace;
   the [muse] launcher in [base_dir] starts this MSP host from there. It
   records its working directory, the session start and the turn's text next
   to itself, then answers. *)
let muse_panel_host_script =
  {|import atexit, json, os, signal, sys

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "cwd.json"), "w") as handle:
    json.dump({"cwd": os.getcwd(), "entries": sorted(os.listdir(".")),
               "home": os.environ.get("HOME"),
               "config_home": os.environ.get("XDG_CONFIG_HOME")}, handle)

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(97)
    return json.loads(line)

def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})

assert "--no-session-log" not in sys.argv
storage_keys = ["XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "TMPDIR"]
storage_paths = [os.environ[key] for key in storage_keys]
for path in storage_paths:
    with open(os.path.join(path, "fixture-native-state"), "w") as handle:
        handle.write("synthetic session state")
with open(os.path.join(HERE, "native-storage.json"), "w") as handle:
    json.dump(storage_paths, handle)
# The client closes stdin and then sends SIGTERM at once. Closing stdin ends
# the loop at the bottom and starts the exit, so the handler's SystemExit could
# land inside record_exit after open(..., "w") had emptied the file (#39889).
# SIGTERM is ignored once the exit has begun, and the receipt is renamed into
# place so a reader never sees it half written.
def record_exit():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    receipt = os.path.join(HERE, "native-storage-at-exit.json")
    with open(receipt + ".tmp", "w") as handle:
        json.dump([os.path.isfile(os.path.join(path, "fixture-native-state")) for path in storage_paths], handle)
    os.replace(receipt + ".tmp", receipt)
atexit.register(record_exit)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
control_path = os.path.join(HERE, "fixture-control.json")
control = json.load(open(control_path)) if os.path.exists(control_path) else {}
init = read()
send({"jsonrpc": "2.0", "id": init["id"], "result": {
    "serverInfo": {"name": "muse-session-server", "version": "1.3.0"},
    "userAgent": "muse/1.3.0", "museHome": os.path.join(os.environ["XDG_DATA_HOME"], "muse"), "platformFamily": "unix",
    "platformOs": "linux", "schema": {"version": 1, "fingerprint": "sha256:fixture"},
    "grantedCapabilities": [], "experimentalApi": False,
    "sessionDurability": control.get("durability", "durable")}})
assert read()["method"] == "initialized"
opened = read()
assert opened["method"] == "session/start", opened
with open(os.path.join(HERE, "start-params.json"), "w") as handle:
    json.dump(opened["params"], handle)
send({"jsonrpc": "2.0", "id": opened["id"], "result": {
    "session": {"sessionId": "panel-session", "status": "idle", "turnCount": 0,
                "approvalMode": {"mode": "promptUnmatched", "source": "startup", "lastCommandId": None},
                "modelId": opened["params"]["modelId"],
                "workspaceRoot": opened["params"]["workspaceRoot"]},
    "viewCursor": "v:1"}})
if control.get("fail_model") == opened["params"]["modelId"]:
    control["terminal"] = "failed"
    control["error"] = {"kind": "modelError", "message": "paid candidate failure", "retryable": False}
turn = read()
assert turn["method"] == "turn/start", turn
assert turn["params"]["reasoningEffort"] == "high", turn
turn_id = turn["params"]["commandId"]
text = [part["text"] for part in turn["params"]["input"] if part["type"] == "text"][0]
with open(os.path.join(HERE, "panel-prompt.txt"), "w") as handle:
    handle.write(text)
send({"jsonrpc": "2.0", "id": turn["id"], "result": {
    "commandId": turn_id, "status": "accepted", "turnId": turn_id,
    "startedNewTurn": True, "disposition": "started"}})
notify("turn/started", {"sessionId": "panel-session", "turnId": turn_id,
                        "commandId": turn_id, "viewCursor": "v:2"})
notify("usage/changed", {"observedAtMs": 100000, "tier": "fixture",
    "window": {"usedPercent": 100, "resetsAtMs": 500000, "windowDurationMins": 5},
    "weekly": {"usedPercent": 99, "resetsAtMs": 900000}})
if not control.get("missing_reply", False):
    notify("item/completed", {"sessionId": "panel-session", "viewCursor": "v:3", "item": {
        "itemId": "m-1", "kind": "agentMessage", "turnId": turn_id, "revision": 1,
        "status": "completed", "text": control.get("answers", {}).get(opened["params"]["modelId"], "MUSE_PANEL_ANSWER")}})
notify("turn/completed", {"sessionId": "panel-session", "turnId": turn_id,
                          "terminal": control.get("terminal", "completed"), "viewCursor": "v:4",
                          "error": control.get("error"),
                          "usage": {"inputTokens": 11, "outputTokens": 7, "cachedTokens": 3, "reasoningTokens": 2}})
for _ in sys.stdin:
    pass
signal.signal(signal.SIGTERM, signal.SIG_IGN)
|}
;;

let with_muse_runtime ~muse_cli f =
  let snapshot = Runtime.For_testing.snapshot () in
  let base_dir = Filename.temp_dir "fusion-muse" "" in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      remove_tree base_dir)
  @@ fun () ->
  let config_path = Filename.concat base_dir "runtime.toml" in
  let account_home = Filename.concat (Unix.realpath base_dir) "selected-account" in
  Unix.mkdir account_home 0o700;
  let account_config = Filename.concat account_home ".config/muse" in
  Fs_compat.mkdir_p account_config;
  write_file ~path:(Filename.concat account_config "auth.json") ~perm:0o600
    {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-LOCAL-ONLY"}}}|};
  write_file ~path:config_path ~perm:0o600
    (muse_fixture ~muse_cli:(muse_cli ~base_dir) ~account_home);
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> failf "muse-serve fixture must initialize: %s" detail);
  f ~base_dir
;;

let in_eio_context f =
  Eio_main.run (fun env ->
    Eio_context.set_env env;
    Eio.Switch.run (fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        f))
;;

(* A host that records where it runs, reads the initialize request and exits
   without answering it, so the panelist's call returns an error. *)
let muse_failing_host_script =
  {|import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "cwd.json"), "w") as handle:
    json.dump({"cwd": os.getcwd(), "entries": sorted(os.listdir(".")),
               "home": os.environ.get("HOME"),
               "config_home": os.environ.get("XDG_CONFIG_HOME")}, handle)
sys.stdin.readline()
sys.exit(1)
|}
;;

(* The executable the serve client spawns. It names the host by its absolute
   path because the process runs in the panelist's own workspace. *)
let muse_panel_launcher_with ~host_script ~base_dir =
  let host = Filename.concat base_dir "muse_host.py" in
  write_file ~path:host ~perm:0o600 host_script;
  let cli = Filename.concat base_dir "muse" in
  write_file ~path:cli ~perm:0o700
    (Printf.sprintf "#!/bin/sh\nexec python3 %s \"$@\"\n" (Filename.quote host));
  cli
;;

let muse_panel_launcher ~base_dir =
  muse_panel_launcher_with ~host_script:muse_panel_host_script ~base_dir
;;

(* The directory the host ran in, as it recorded it. *)
let muse_panel_cwd ~base_dir =
  let host = Yojson.Safe.from_file (Filename.concat base_dir "cwd.json") in
  ( Yojson.Safe.Util.(host |> member "cwd" |> to_string)
  , Yojson.Safe.Util.(host |> member "entries" |> to_list |> List.map to_string) )
;;

(* Whether [path] is [dir] or sits under it, spelled either way [dir] can be. *)
let is_within ~dir path =
  List.exists
    (fun root -> String.equal path root || String.starts_with ~prefix:(root ^ "/") path)
    [ dir; Unix.realpath dir ]
;;

(* A Muse Code panelist runs one [muse serve] turn: the group prompt is framed
   ahead of the question in the labels a keeper start uses, the binding's
   api-name is the session's model, and the agent message is the answer. *)
let check_muse_native_storage_cleanup ~base_dir =
  let paths = Yojson.Safe.from_file (Filename.concat base_dir "native-storage.json")
    |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string in
  let at_exit = Yojson.Safe.from_file (Filename.concat base_dir "native-storage-at-exit.json")
    |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_bool in
  check (list bool) "native files still exist when child exits" (List.map (fun _ -> true) paths) at_exit;
  List.iter (fun path ->
    check bool "native storage is outside selected account" false (is_within ~dir:base_dir path);
    check bool "native storage removed after child exit" false (Sys.file_exists path)) paths
;;

let test_muse_code_panelist_reaches_muse_serve () =
  with_muse_runtime ~muse_cli:muse_panel_launcher @@ fun ~base_dir ->
  let answer =
    in_eio_context (fun () ->
      Masc.Fusion_official_client.run_panelist ~base_dir ~runtime_id:muse_runtime_id
        ~system_prompt:"LENS-MARKER answer as a reviewer"
        ~prompt:"QUESTION-MARKER which candidate ships?" ())
  in
  (match answer with
   | Ok (text, usage) ->
     check int "Muse input spend" 11 usage.Fusion_types.input_tokens;
     check int "Muse output spend" 7 usage.output_tokens;
     check string "the agent message is the answer" "MUSE_PANEL_ANSWER" text
   | Error (failure, _) ->
     failf "the Muse Code panelist failed: %s" (Fusion_types.show_panel_failure failure));
  let start =
    Yojson.Safe.from_file (Filename.concat base_dir "start-params.json")
  in
  let member name = Yojson.Safe.Util.member name start in
  check string "the binding's api-name is the session model" "muse-spark-1.3"
    (Yojson.Safe.Util.to_string (member "modelId"));
  check string "unmatched tools require an explicit host decision" "promptUnmatched"
    (Yojson.Safe.Util.to_string (member "approvalMode"));
  let prompt =
    let channel = open_in_bin (Filename.concat base_dir "panel-prompt.txt") in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  let system_label = frame_label (Masc.Antigravity_input_frame.system_instructions_label ()) in
  let goal_label = frame_label (Masc.Antigravity_input_frame.current_goal_label ()) in
  let position label needle =
    match index_of ~needle prompt with
    | Some at -> at
    | None -> failf "%s never reached muse serve" label
  in
  let order =
    [ position "the instructions label" system_label
    ; position "the group prompt" "LENS-MARKER"
    ; position "the goal label" goal_label
    ; position "the question" "QUESTION-MARKER"
    ]
  in
  check (list int) "instructions label, group prompt, goal label, question, in that order"
    (List.sort Int.compare order) order
;;

let test_muse_missing_reply_is_consumer_failure () =
  with_muse_runtime ~muse_cli:muse_panel_launcher (fun ~base_dir ->
    write_file ~path:(Filename.concat base_dir "fixture-control.json") ~perm:0o600
      {|{"missing_reply":true}|};
    let runtime = match Runtime.get_runtime_by_id muse_runtime_id with
      | Some runtime -> runtime | None -> fail "Muse fixture missing" in
    match in_eio_context (fun () -> Masc.Fusion_official_client.run_with_images
        ~images:[] ~base_dir ~runtime ~system_prompt:"" ~prompt:"reply" ()) with
    | Error Masc.Fusion_official_client.Missing_reply -> ()
    | Error failure -> fail (Masc.Fusion_official_client.failure_detail ~runtime_id:muse_runtime_id failure)
    | Ok _ -> fail "missing assistant message became a successful panel reply")
;;

let test_muse_frozen_candidate_and_quota_scope () =
  with_muse_runtime ~muse_cli:muse_panel_launcher (fun ~base_dir ->
    Runtime_quota_window.reset_for_testing ();
    let selected = match Runtime.get_runtime_by_id muse_runtime_id with
      | Some runtime -> runtime | None -> fail "Muse fixture missing" in
    let replacement_path = Filename.concat base_dir "reload.toml" in
    write_file ~path:replacement_path ~perm:0o600 {|
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
    (match Runtime.init_default ~config_path:replacement_path with
     | Ok () -> () | Error detail -> fail detail);
    check bool "selected id removed from registry" true
      (Option.is_none (Runtime.get_runtime_by_id muse_runtime_id));
    (match in_eio_context (fun () -> Masc.Fusion_official_client.run_with_images
       ~images:[] ~base_dir ~runtime:selected ~system_prompt:"" ~prompt:"ping" ()) with
     | Ok response -> check string "frozen model/effort/budget still run" "MUSE_PANEL_ANSWER" response.text
     | Error failure -> fail (Masc.Fusion_official_client.failure_detail ~runtime_id:muse_runtime_id failure));
    check (option (float 0.)) "Fusion charges captured account scope only" (Some 500.)
      (Runtime_quota_window.active_until ~scope:selected.quota_scope ~now:100.);
    check bool "other HOME is unaffected" false (Runtime_quota_window.is_exhausted
      ~scope:(Runtime_quota_window.scope_of_muse_home (Filename.concat base_dir "other")) ~now:100.);
    check bool "Fusion provider reset expires" false
      (Runtime_quota_window.is_exhausted ~scope:selected.quota_scope ~now:500.);
    Runtime_quota_window.reset_for_testing ())
;;

(* A Muse Code panelist's session works in a fresh empty directory, not in
   [base_dir], which holds [.masc]: the host's working directory and the
   session's workspace root are that directory, and it is gone once the call
   ends. *)
let test_muse_code_panelist_works_in_its_own_directory () =
  with_muse_runtime ~muse_cli:muse_panel_launcher @@ fun ~base_dir ->
  (match
     in_eio_context (fun () ->
       Masc.Fusion_official_client.run_panelist ~base_dir ~runtime_id:muse_runtime_id
         ~system_prompt:"" ~prompt:"ping" ())
   with
   | Ok _ -> ()
   | Error (failure, _) ->
     failf "the Muse Code panelist failed: %s" (Fusion_types.show_panel_failure failure));
  let start = Yojson.Safe.from_file (Filename.concat base_dir "start-params.json") in
  let root = Yojson.Safe.Util.(start |> member "workspaceRoot" |> to_string) in
  check bool "the workspace root is not under the base path" false
    (is_within ~dir:base_dir root);
  let cwd, entries = muse_panel_cwd ~base_dir in
  check string "the host runs in the workspace root" root cwd;
  check_muse_native_storage_cleanup ~base_dir;
  let observed = Yojson.Safe.from_file (Filename.concat base_dir "cwd.json") in
  let account_home = Filename.concat (Unix.realpath base_dir) "selected-account" in
  check string "Fusion selects its configured account HOME" account_home
    Yojson.Safe.Util.(observed |> member "home" |> to_string);
  check bool "Fusion uses managed policy instead of source settings" false
    (String.equal (Filename.concat account_home ".config")
       Yojson.Safe.Util.(observed |> member "config_home" |> to_string));
  check (list string) "the workspace starts empty" [] entries;
  check bool "the workspace is removed after the call" false (Sys.file_exists root)
;;

(* A call that ends in an error removes its directory too. *)
let test_muse_code_panelist_removes_its_directory_after_a_failure () =
  with_muse_runtime
    ~muse_cli:(muse_panel_launcher_with ~host_script:muse_failing_host_script)
  @@ fun ~base_dir ->
  (match
     in_eio_context (fun () ->
       Masc.Fusion_official_client.run_panelist ~base_dir ~runtime_id:muse_runtime_id
         ~system_prompt:"" ~prompt:"ping" ())
   with
   | Error _ -> ()
   | Ok _ -> fail "a host that exited before the handshake answered");
  let cwd, _ = muse_panel_cwd ~base_dir in
  check bool "the host ran outside the base path" false (is_within ~dir:base_dir cwd);
  check bool "the workspace is removed after the failed call" false (Sys.file_exists cwd)
;;

(* Cancelling a queued panel before dispatch must not allocate a workspace or
   start its client. The isolated temp directory makes leaked acquisition
   observable without depending on the generated filename. *)
let test_cancelled_muse_panel_does_not_leave_a_workspace () =
  with_muse_runtime ~muse_cli:muse_panel_launcher @@ fun ~base_dir ->
  let temporary = Filename.concat base_dir "panel-temp" in
  Unix.mkdir temporary 0o700;
  let previous = Filename.get_temp_dir_name () in
  Fun.protect ~finally:(fun () -> Filename.set_temp_dir_name previous) (fun () ->
    Filename.set_temp_dir_name temporary;
    let cancelled = in_eio_context (fun () ->
      try
        Eio.Cancel.sub (fun cancellation ->
          Eio.Cancel.cancel cancellation Exit;
          let result = Masc.Fusion_official_client.run_panelist
              ~base_dir ~runtime_id:muse_runtime_id ~system_prompt:"" ~prompt:"ping" () in
          match result with
          | Ok _ | Error _ -> false)
      with Eio.Cancel.Cancelled _ -> true) in
    check bool "owner cancellation propagates" true cancelled;
    check (list string) "cancelled dispatch leaves no temporary workspace" []
      (Sys.readdir temporary |> Array.to_list);
    check bool "cancelled dispatch never starts the host" false
      (Sys.file_exists (Filename.concat base_dir "cwd.json")))
;;

(* [muse serve] has no output-schema channel. A caller that needs the client
   to hold its answer to a schema is refused before the client runs, judged by
   the stub's marker and not only by the refusal. *)
let test_muse_code_refuses_an_output_schema_before_spawning () =
  let marker = ref "" in
  let muse_cli ~base_dir =
    marker := Filename.concat base_dir "spawned";
    let cli = Filename.concat base_dir "muse" in
    write_file ~path:cli ~perm:0o700 (stub_cli_script ~marker:!marker);
    cli
  in
  with_muse_runtime ~muse_cli @@ fun ~base_dir ->
  let runtime =
    match Runtime.get_runtime_by_id muse_runtime_id with
    | Some runtime -> runtime
    | None -> fail "the muse-serve fixture runtime did not resolve"
  in
  let result =
    in_eio_context (fun () ->
      Masc.Fusion_official_client.run_with_images ~images:[] ~base_dir ~runtime
        ~system_prompt:"" ~output_schema:(`Assoc [ "type", `String "object" ])
        ~prompt:"ping" ())
  in
  (match result with
   | Error (Masc.Fusion_official_client.Setup_failure _) -> ()
   | Error failure ->
     failf "expected a setup refusal, got %s"
       (Masc.Fusion_official_client.failure_detail ~runtime_id:muse_runtime_id failure)
   | Ok _ -> fail "a schema-held answer was accepted from muse serve");
  check bool "the client never ran" false (Sys.file_exists !marker)
;;

(* Each client's own timeout reaches Fusion as [Timeout], and every other
   client failure stays [Provider_error]. The detail line keeps what the
   projection folds away. *)
let test_client_timeouts_project_to_timeout () =
  let project failure =
    Masc.Fusion_official_client.panel_failure ~runtime_id:official_client_runtime failure
  in
  let is_timeout failure =
    Fusion_types.equal_panel_failure (project failure) Fusion_types.Timeout
  in
  check bool "Claude turn timeout" true
    (is_timeout (Masc.Fusion_official_client.Claude_failure (Runtime_claude_code.Timeout 3.0)));
  check bool "Claude admission timeout" true
    (is_timeout
       (Masc.Fusion_official_client.Claude_admission_failure (Runtime_claude_code.Timeout 3.0)));
  check bool "Codex timeout" true
    (is_timeout
       (Masc.Fusion_official_client.Codex_failure
          (Runtime_codex_app_server.Timeout { seconds = 3.0; turn_accepted = false })));
  check bool "Antigravity timeout" true
    (is_timeout
       (Masc.Fusion_official_client.Antigravity_failure (Runtime_antigravity.Timeout 3.0)));
  check bool "Muse Code timeout" true
    (is_timeout
       (Masc.Fusion_official_client.Muse_failure
          (Runtime_muse_serve.Timeout { seconds = 3.0; turn_accepted = true })));
  check bool "a Muse Code turn failure stays a provider error" false
    (is_timeout
       (Masc.Fusion_official_client.Muse_failure
          (Runtime_muse_serve.Auth_required "no login")));
  let turn_failed =
    Masc.Fusion_official_client.Claude_failure (Runtime_claude_code.Turn_failed "boom")
  in
  (match project turn_failed with
   | Fusion_types.Provider_error _ -> ()
   | other ->
     failf "a non-timeout client failure must stay Provider_error, got %s"
       (Fusion_types.show_panel_failure other));
  let detail =
    Masc.Fusion_official_client.failure_detail ~runtime_id:official_client_runtime
      (Masc.Fusion_official_client.Claude_failure (Runtime_claude_code.Timeout 3.0))
  in
  check bool "the detail line names the runtime" true
    (String.starts_with ~prefix:(official_client_runtime ^ ": ") detail);
  (* The adapter renders the idle seconds; the projection has no room for them. *)
  check bool "the detail line keeps the timeout's seconds" true
    (Option.is_some (index_of ~needle:"3.000s" detail))
;;

let test_setup_failure_attribution_is_single () =
  let runtime_id = official_client_runtime in
  let attributed = runtime_id ^ ": quota" in
  let failure = Masc.Fusion_official_client.Setup_failure "quota" in
  check string "the setup detail names the runtime once" attributed
    (Masc.Fusion_official_client.failure_detail ~runtime_id failure);
  match Masc.Fusion_official_client.panel_failure ~runtime_id failure with
  | Fusion_types.Provider_error detail ->
    check string "the panel failure names the runtime once" attributed detail
  | _ -> fail "a setup provider error changed its panel failure kind"
;;

(* A stand-in that appends one line per execution, so a test can count how
   many times the client ran across several candidates. *)
let appending_cli_script ~log = Printf.sprintf "#!/bin/sh\necho spawned >> '%s'\nexit 0\n" log

let count_lines path =
  if not (Sys.file_exists path)
  then 0
  else (
    let channel = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () ->
         let rec count n =
           match input_line channel with
           | _ -> count (n + 1)
           | exception End_of_file -> n
         in
         count 0))
;;

let with_eio f =
  Eio_main.run (fun env ->
    Eio_context.set_env env;
    Eio.Switch.run (fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        (fun () -> f ~sw ~net:(Eio.Stdenv.net env))))
;;

let sample_panel =
  [ Fusion_types.Answered
      { model = agent_core_runtime; answer = "pong"; usage = Fusion_types.zero_usage }
  ]
;;

let test_panel_paid_failures_survive_exhaustion_and_fallback () =
  List.iter (fun all_failed ->
    with_muse_runtime ~muse_cli:muse_panel_launcher (fun ~base_dir ->
      let config_path = Filename.concat base_dir "runtime.toml" in
      Out_channel.with_open_gen [Open_append; Open_text] 0o600 config_path (fun channel ->
        output_string channel {|
[models.muse-fallback]
api-name = "muse-fallback"
max-context = 1007997
reasoning-effort = "high"
[muse_code.muse-fallback]
[runtime.lanes.paid-seat]
candidates = ["muse_code.muse-spark", "muse_code.muse-fallback"]
|});
      (match Runtime.init_default ~config_path with Ok () -> () | Error detail -> fail detail);
      let control = if all_failed then
          ["terminal", `String "failed";
           "error", `Assoc ["kind", `String "modelError"; "message", `String "paid failure"; "retryable", `Bool false]]
        else ["fail_model", `String "muse-spark-1.3"] in
      write_file ~path:(Filename.concat base_dir "fixture-control.json") ~perm:0o600
        (Yojson.Safe.to_string (`Assoc control));
      let routes = ref [] in
      let outcomes = with_eio (fun ~sw ~net ->
        Masc.Fusion_panel.run ~base_dir ~sw ~net ~groups:[panel_group ["paid-seat"]]
          ~prompt:"paid attempts" ~on_seat_routes:(fun value -> routes := value) ()) in
      let outcome, usage = match all_failed, outcomes with
        | true, [Fusion_types.Failed error as outcome] -> outcome, error.usage
        | false, [Fusion_types.Answered answer as outcome] -> outcome, answer.usage
        | _ -> fail "expected failed seat or successful fallback" in
      check int "both paid attempts retain input exactly once" 22 usage.Fusion_types.input_tokens;
      check int "both paid attempts retain output exactly once" 14 usage.output_tokens;
      check bool "typed outcome wire retains usage" true
        (Fusion_types.panel_outcome_of_yojson (Fusion_types.panel_outcome_to_yojson outcome) = Ok outcome);
      (match !routes with
       | [route] -> check int "candidate failure count" (if all_failed then 2 else 1)
           (List.length route.Fusion_types.failed_attempts)
       | _ -> fail "one seat route expected"))) [true; false]
;;

let test_muse_failed_terminals_retain_usage () =
  List.iter (fun terminal ->
    with_muse_runtime ~muse_cli:muse_panel_launcher (fun ~base_dir ->
      write_file ~path:(Filename.concat base_dir "fixture-control.json") ~perm:0o600
        (Yojson.Safe.to_string (`Assoc ["terminal", `String terminal;
          "error", `Assoc ["kind", `String "modelError"; "message", `String "fixture failure";
                            "retryable", `Bool false]]));
      (match in_eio_context (fun () ->
         Masc.Fusion_official_client.run_panelist ~base_dir ~runtime_id:muse_runtime_id
           ~system_prompt:"" ~prompt:"paid attempt" ()) with
       | Error (_, usage) ->
         check int (terminal ^ " panel input retained") 11 usage.Fusion_types.input_tokens;
         check int (terminal ^ " panel output retained") 7 usage.output_tokens
       | Ok _ -> fail "failed or cancelled vendor terminal became success");
      let result = with_eio (fun ~sw ~net ->
        Masc.Fusion_judge.run ~base_dir ~sw ~net ~judge_model:muse_runtime_id
          ~judge_system_prompt:"Return a synthesis" ~question:"Select an answer"
          ~panel:sample_panel ~web_tools:false ()) in
      (match result with
       | Error (_, usage) ->
         check int (terminal ^ " judge input retained") 11 usage.Fusion_types.input_tokens;
         check int (terminal ^ " judge output retained") 7 usage.output_tokens
       | Ok _ -> fail "failed or cancelled judge became success");
      check_muse_native_storage_cleanup ~base_dir))
    ["failed"; "cancelled"]
;;

let test_muse_stateless_host_keeps_durable_protocol () =
  with_muse_runtime ~muse_cli:muse_panel_launcher (fun ~base_dir ->
    write_file ~path:(Filename.concat base_dir "fixture-control.json") ~perm:0o600
      {|{"durability":"ephemeral"}|};
    let runtime = match Runtime.get_runtime_by_id muse_runtime_id with
      | Some runtime -> runtime | None -> fail "Muse fixture missing" in
    (match in_eio_context (fun () ->
       Masc.Fusion_official_client.run_with_images ~images:[] ~base_dir ~runtime
         ~system_prompt:"" ~prompt:"must not persist" ()) with
     | Error (Masc.Fusion_official_client.Muse_failure
         Runtime_muse_serve.Session_not_durable) -> ()
     | Error failure -> fail (Masc.Fusion_official_client.failure_detail ~runtime_id:muse_runtime_id failure)
     | Ok _ -> fail "ephemeral host cannot provide durable completion notifications");
    check bool "no durable session is started" false
      (Sys.file_exists (Filename.concat base_dir "start-params.json"));
    let cwd, _ = muse_panel_cwd ~base_dir in
    check bool "refused host workspace removed" false (Sys.file_exists cwd))
;;

let failed_usage_host_script =
  {|import json, os, sys
mode = os.path.basename(sys.argv[0])
def send(x): print(json.dumps(x), flush=True)
if mode == "claude":
    if "auth" in sys.argv:
        send({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty"})
        sys.exit(0)
    sid = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--session-id="))
    initialize = json.loads(sys.stdin.readline())
    send({"type":"control_response", "response":{"subtype":"success",
        "request_id":initialize["request_id"], "response":{}}})
    sys.stdin.readline()
    send({"type":"assistant","parent_tool_use_id":None, "session_id":sid, "uuid":"assistant-1", "message":{
        "role":"assistant", "model":"paid-fixture", "content":[{"type":"text", "text":"paid partial"}]}})
    send({"type":"result", "subtype":"error_during_execution", "is_error":True,
        "session_id":sid, "uuid":"turn-1", "errors":["paid failure"], "result":"paid failure",
        "usage":{"input_tokens":11,"output_tokens":7,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}})
elif mode == "agy":
    sys.stdin.read()
    send({"event":"init", "conversation_id":"paid", "init":{"model":"paid-fixture", "cwd":os.getcwd(),
        "tools":[],"permission_mode":"always-proceed"}})
    send({"event":"result", "result":{"conversation_id":"paid", "status":"ERROR", "error":"paid failure",
        "response":"", "num_turns":1, "usage":{"input_tokens":11,"output_tokens":7,"cache_read_tokens":3,"thinking_tokens":0,"total_tokens":18}}})
else:
    admitted_effort = False
    def counts(i,o): return {"inputTokens":i,"cachedInputTokens":0,"outputTokens":o,"reasoningOutputTokens":0,"totalTokens":i+o}
    def usage(total,last):
        send({"method":"thread/tokenUsage/updated", "params":{"threadId":"thread-1","turnId":"turn-1",
            "tokenUsage":{"total":total,"last":last}}})
    for line in sys.stdin:
        req=json.loads(line)
        if "id" not in req: continue
        method=req["method"]
        if method=="initialize": result={"userAgent":"fixture"}
        elif method=="account/read": result={"account":{"type":"chatgpt","planType":"pro"},"requiresOpenaiAuth":True}
        elif method=="thread/start": result={"thread":{"id":"thread-1"},"model":"paid-fixture"}
        elif method=="model/list":
            assert mode=="codex-effort" and req["params"]["includeHidden"] is True
            admitted_effort = True
            result={"data":[{"id":"paid-ui","model":"paid-fixture","displayName":"Paid fixture","isDefault":True,
                "supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}],
                "defaultReasoningEffort":"high"}],"nextCursor":None}
        elif method=="turn/start":
            if mode=="codex-effort":
                assert admitted_effort and req["params"]["effort"]=="high"
                with open(os.path.join(os.path.dirname(__file__),"effort-wire.jsonl"),"a") as captured:
                    captured.write(json.dumps(req["params"]["effort"])+"\n")
            result={"turn":{"id":"turn-1"}}
        else: raise AssertionError(method)
        send({"id":req["id"],"result":result})
        if method=="turn/start":
            usage(counts(11,7),counts(11,7))
            usage(counts(11,7),counts(11,7))
            if mode=="codex-fill":
                filled=counts(0,0);filled["totalTokens"]=4096
                usage(filled,filled)
                usage(counts(2,1),counts(2,1))
            send({"method":"turn/completed", "params":{"threadId":"thread-1",
                "turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"paid failure"}}}})
for line in sys.stdin: pass
|}
;;

let test_all_official_client_failed_usage () =
  List.iter (fun (mode, protocol, input_tokens) ->
    let root = Filename.temp_dir "fusion-paid-failure" "" in
    let snapshot = Runtime.For_testing.snapshot () in
    Fun.protect ~finally:(fun () -> Runtime.For_testing.restore snapshot; remove_tree root) (fun () ->
      let host = Filename.concat root "host.py" in
      let cli = Filename.concat root mode in
      write_file ~path:cli ~perm:0o700
        (Printf.sprintf "#!/bin/sh\nexec python3 %s \"$@\"\n" (shell_quote host));
      (* Explicit fixture mode; no inherited environment controls the child. *)
      write_file ~path:host ~perm:0o600
        ("import sys\nsys.argv[0]=" ^ Printf.sprintf "%S" mode ^ "\n" ^ failed_usage_host_script);
      let auth = Filename.concat root "auth.json" in
      write_file ~path:auth ~perm:0o600 (Masc_test_deps.antigravity_oauth_fixture "paid-failure");
      let config_path = Filename.concat root "runtime.toml" in
      write_file ~path:config_path ~perm:0o600 (Printf.sprintf {|
[providers.paid]
protocol = %S
command = %S
is-non-interactive = true
%s
[models.fixture]
api-name = "paid-fixture"
max-context = 4096
tools-support = true
%s
[paid.fixture]
[runtime]
default = "paid.fixture"
|} protocol cli (if mode="agy" then
    Printf.sprintf "timeout-s = 5.0\ncredentials = { type = \"file\", path = %S }" auth
  else "") (if mode="codex-effort" then "reasoning-effort = \"ultra\"" else ""));
      (match Runtime.init_default ~config_path with Ok () -> () | Error detail -> fail detail);
      let check_usage usage =
        check int (mode ^ " failed input") input_tokens usage.Fusion_types.input_tokens;
        check int (mode ^ " failed output") 7 usage.output_tokens in
      (match in_eio_context (fun () -> Masc.Fusion_official_client.run_panelist
         ~base_dir:root ~runtime_id:"paid.fixture" ~system_prompt:"" ~prompt:"paid attempt" ()) with
       | Error (_, usage) -> check_usage usage
       | Ok _ -> fail "paid failure unexpectedly succeeded");
      (match with_eio (fun ~sw ~net -> Masc.Fusion_judge.run ~base_dir:root ~sw ~net
         ~judge_model:"paid.fixture" ~judge_system_prompt:"Return synthesis" ~question:"Choose"
         ~panel:sample_panel ~web_tools:false ()) with
       | Error (_, usage) -> check_usage usage
       | Ok _ -> fail "paid judge failure unexpectedly succeeded");
      if mode="codex-effort" then (
        let efforts = Fs_compat.load_file (Filename.concat root "effort-wire.jsonl")
          |> String.split_on_char '\n' |> List.filter (fun row -> row <> "")
          |> List.map (fun row -> Yojson.Safe.Util.to_string (Yojson.Safe.from_string row)) in
        check (list string) "panel and judge carry configured effort through live admission"
          ["high"; "high"] efforts)))
    ["claude", "claude-code", 16; "codex", "codex-app-server", 11;
     "codex-fill", "codex-app-server", 11; "codex-effort", "codex-app-server", 11;
     "agy", "antigravity-cli", 14]
;;

let test_muse_judge_parse_failure_retains_reported_usage () =
  with_muse_runtime ~muse_cli:muse_panel_launcher @@ fun ~base_dir ->
  let result = with_eio (fun ~sw ~net ->
    Masc.Fusion_judge.run ~base_dir ~sw ~net ~judge_model:muse_runtime_id
      ~judge_system_prompt:"Return a synthesis" ~question:"Select an answer"
      ~panel:sample_panel ~web_tools:false ()) in
  match result with
  | Error (Fusion_types.Parse_error _, usage) ->
    check int "paid malformed answer input retained" 11 usage.Fusion_types.input_tokens;
    check int "paid malformed answer output retained" 7 usage.output_tokens
  | Error (failure, _) -> fail (Fusion_types.judge_failure_text failure)
  | Ok _ -> fail "plain Muse fixture answer was parsed as synthesis"
;;

let run_single_judge ~base_dir ~route ~on_route =
  with_eio (fun ~sw ~net ->
    Masc.Fusion_judge.run
      ~base_dir
      ~sw
      ~net
      ~judge_system_prompt:"Judge the panel."
      ~judge_model:route
      ~question:"ping"
      ~panel:sample_panel
      ~web_tools:false
      ~seat_route:(Fusion_types.Single, on_route)
      ())
;;

let test_judge_blank_synthesis_uses_the_next_candidate () =
  List.iter (fun blank ->
    with_muse_runtime ~muse_cli:muse_panel_launcher (fun ~base_dir ->
      let config_path = Filename.concat base_dir "runtime.toml" in
      Out_channel.with_open_gen [Open_append; Open_text] 0o600 config_path (fun channel ->
        output_string channel {|
[models.muse-fallback]
api-name = "muse-fallback"
max-context = 1007997
reasoning-effort = "high"
[muse_code.muse-fallback]
[runtime.lanes.blank-judge]
candidates = ["muse_code.muse-spark", "muse_code.muse-fallback"]
|});
      (match Runtime.init_default ~config_path with
       | Ok () -> () | Error detail -> fail detail);
      let response answer = `String (Yojson.Safe.to_string (judge_synthesis_json ~answer)) in
      write_file ~path:(Filename.concat base_dir "fixture-control.json") ~perm:0o600
        (Yojson.Safe.to_string (`Assoc ["answers", `Assoc
          ["muse-spark-1.3", response blank; "muse-fallback", response "Supported answer"]]));
      let route = ref None in
      (match run_single_judge ~base_dir ~route:"blank-judge"
          ~on_route:(fun observed -> route := Some observed) with
       | Ok (synthesis, usage) ->
         check string "fallback supplies the conclusion" "Supported answer"
           synthesis.Fusion_types.resolved_answer;
         check int "both candidates retain paid input" 22 usage.input_tokens;
         check int "both candidates retain paid output" 14 usage.output_tokens
       | Error (failure, _) -> fail (Fusion_types.judge_failure_text failure));
      match !route with
      | Some { Fusion_types.answered_by = Some "muse_code.muse-fallback"
             ; failed_attempts =
                 [{ Fusion_types.attempt_runtime = "muse_code.muse-spark"
                  ; attempt_failure = Fusion_types.Judge_attempt_failed (Fusion_types.Parse_error _) }]
             ; _ } -> ()
      | Some observed -> failf "unexpected fallback evidence: %s"
          (Fusion_types.show_seat_route observed)
      | None -> fail "judge did not record candidate attempts"))
    [""; " \t\n"]
;;

(* A judge seat naming a lane tries every candidate, in the lane's order, when
   each one fails. The spawn count is compared with a baseline measured on a
   one-candidate seat in the same test rather than with an assumed number of
   processes per candidate. *)
let test_judge_lane_walks_candidates_in_order () =
  let base_dir = Filename.temp_dir "fusion-judge-lane" "" in
  let log = Filename.concat base_dir "spawns" in
  let claude_cli = Filename.concat base_dir "stub-claude" in
  write_file ~path:claude_cli ~perm:0o700 (appending_cli_script ~log);
  with_initialized_runtime ~claude_cli (fun () ->
    let _baseline = run_single_judge ~base_dir ~route:official_client_runtime ~on_route:ignore in
    let per_candidate = count_lines log in
    check bool "a one-candidate seat runs its client" true (per_candidate > 0);
    let recorded = ref None in
    let result =
      run_single_judge ~base_dir ~route:judge_lane ~on_route:(fun route -> recorded := Some route)
    in
    check int "both lane candidates ran their client" (3 * per_candidate) (count_lines log);
    (match result with
     | Ok _ -> fail "the stub clients emit no result, so no synthesis can come back"
     | Error _ -> ());
    match !recorded with
    | Some
        { Fusion_types.seat = Fusion_types.Judge_seat Fusion_types.Single
        ; route
        ; answered_by = None
        ; failed_attempts
        } ->
      check string "the seat route is the lane name" judge_lane route;
      check
        (list string)
        "candidates are tried in lane order"
        [ judge_lane_first; official_client_runtime ]
        (List.map
           (fun (attempt : Fusion_types.seat_attempt) -> attempt.attempt_runtime)
           failed_attempts)
    | Some other -> failf "unexpected seat route %s" (Fusion_types.show_seat_route other)
    | None -> fail "the judge seat did not report its route")
;;

(* The same walk on a panel seat. Without it a panel that tried only the first
   candidate would pass every other test. *)
let test_panel_lane_walks_candidates_in_order () =
  let base_dir = Filename.temp_dir "fusion-panel-lane" "" in
  let log = Filename.concat base_dir "spawns" in
  let claude_cli = Filename.concat base_dir "stub-claude" in
  write_file ~path:claude_cli ~perm:0o700 (appending_cli_script ~log);
  with_initialized_runtime ~claude_cli (fun () ->
    let run_panel route on_routes =
      with_eio (fun ~sw ~net ->
        Masc.Fusion_panel.run
          ~base_dir
          ~sw
          ~net
          ~groups:[ panel_group [ route ] ]
          ~prompt:"ping"
          ~on_seat_routes:on_routes
          ())
    in
    let _baseline = run_panel official_client_runtime ignore in
    let per_candidate = count_lines log in
    check bool "a one-candidate seat runs its client" true (per_candidate > 0);
    let routes = ref [] in
    let outcomes = run_panel judge_lane (fun seat_routes -> routes := seat_routes) in
    check int "both lane candidates ran their client" (3 * per_candidate) (count_lines log);
    (match outcomes with
     | [ Fusion_types.Failed { failed_model; _ } ] ->
       check string "the seat identity is the lane name" judge_lane failed_model
     | other ->
       failf "expected one failed seat, got [%s]"
         (String.concat "; " (List.map Fusion_types.show_panel_outcome other)));
    match !routes with
    | [ { Fusion_types.seat = Fusion_types.Panel_seat seat; answered_by = None; failed_attempts; _ } ]
      ->
      check string "the route names the seat" judge_lane seat;
      check
        (list string)
        "candidates are tried in lane order"
        [ judge_lane_first; official_client_runtime ]
        (List.map
           (fun (attempt : Fusion_types.seat_attempt) -> attempt.attempt_runtime)
           failed_attempts)
    | other ->
      failf "expected one seat route, got [%s]"
        (String.concat "; " (List.map Fusion_types.show_seat_route other)))
;;

(* A route that names neither a lane nor a runtime fails the seat without an
   attempt, and says so in the typed reason rather than as a build error. *)
let test_unknown_route_fails_without_an_attempt () =
  with_classification_runtime (fun () ->
    let routes = ref [] in
    let outcomes =
      with_eio (fun ~sw ~net ->
        Masc.Fusion_panel.run
          ~base_dir:(Filename.get_temp_dir_name ())
          ~sw
          ~net
          ~groups:[ panel_group [ "nope.not-configured" ] ]
          ~prompt:"ping"
          ~on_seat_routes:(fun seat_routes -> routes := seat_routes)
          ())
    in
    (match outcomes with
     | [ Fusion_types.Failed
            { reason = Fusion_types.Unknown_route "nope.not-configured"
            ; usage
            ; _
            } ] ->
       check bool "an unattempted seat burnt nothing"
         true
         (Fusion_types.equal_usage usage Fusion_types.zero_usage)
     | other ->
       failf "expected one Unknown_route failure, got [%s]"
         (String.concat "; " (List.map Fusion_types.show_panel_outcome other)));
    match !routes with
    | [ { Fusion_types.route = "nope.not-configured"; answered_by = None; failed_attempts = []; _ } ]
      -> ()
    | other ->
      failf "expected one unattempted seat route, got [%s]"
        (String.concat "; " (List.map Fusion_types.show_seat_route other)))
;;

(* The walk stops at the first answer and never calls a later candidate. *)
let test_walk_stops_at_the_first_answer () =
  let tried = ref [] in
  let attempt runtime =
    tried := runtime :: !tried;
    if String.equal runtime "b" then Ok "answer" else Error ("failed " ^ runtime)
  in
  (match Masc.Fusion_seat.walk { Masc.Fusion_seat.first = "a"; rest = [ "b"; "c" ] } ~attempt with
   | Masc.Fusion_seat.Answered { answer; runtime; failed } ->
     check string "the answer is the answering candidate's" "answer" answer;
     check string "the answering candidate is named" "b" runtime;
     check (list (pair string string)) "earlier failures are kept" [ "a", "failed a" ] failed
   | Masc.Fusion_seat.Exhausted _ -> fail "candidate b answers");
  check (list string) "a later candidate is never tried" [ "a"; "b" ] (List.rev !tried);
  match
    Masc.Fusion_seat.walk
      { Masc.Fusion_seat.first = "a"; rest = [ "b" ] }
      ~attempt:(fun runtime -> Error runtime)
  with
  | Masc.Fusion_seat.Exhausted { last; failed } ->
    check string "the last failure is the last candidate's" "b" last;
    check (list (pair string string)) "every attempt is kept in order" [ "a", "a"; "b", "b" ] failed
  | Masc.Fusion_seat.Answered _ -> fail "no candidate answers"
;;

(* The message has to name which handle is absent. It did not, and that cost a
   build cycle: publishing Eio_context.set_env in bin/fusion_run left the text
   identical, so the clock being the other half was invisible until the code was
   read. Each arm is asserted separately — a single "some message came back"
   check would pass with all three arms collapsed into one string. *)
let detail_for ~env ~clock =
  match
    Masc.Fusion_official_client.For_testing.missing_handle_detail
      ~env_present:env
      ~clock_present:clock
  with
  | Some detail -> detail
  | None -> "<none>"
;;

let test_both_handles_present_has_no_complaint () =
  check
    (option string)
    "a resolvable context produces no failure detail"
    None
    (Masc.Fusion_official_client.For_testing.missing_handle_detail
       ~env_present:true
       ~clock_present:true)
;;

let test_each_absent_handle_is_named () =
  let neither = detail_for ~env:false ~clock:false in
  let env_missing = detail_for ~env:false ~clock:true in
  let clock_missing = detail_for ~env:true ~clock:false in
  check bool "the three arms are distinct" true
    (neither <> env_missing && env_missing <> clock_missing && neither <> clock_missing);
  let mentions haystack needle =
    let n = String.length needle in
    let rec scan i =
      i + n <= String.length haystack
      && (String.sub haystack i n = needle || scan (i + 1))
    in
    scan 0
  in
  check bool "a missing env names env" true (mentions env_missing "env");
  check bool "a missing env does not blame the clock" false (mentions env_missing "clock");
  check bool "a missing clock names clock" true (mentions clock_missing "clock");
  check bool "both absent names both" true
    (mentions neither "env" && mentions neither "clock")
;;

let test_official_client_usage_preserves_vendor_cache_conventions () =
  let module Usage = Masc.Fusion_official_client.For_testing in
  let claude = Usage.claude_usage
      { Runtime_claude_code.input_tokens = 100; output_tokens = 7;
        cache_creation_input_tokens = 20; cache_read_input_tokens = 50 } in
  check int "Claude exclusive input adds both cache components" 170 claude.Fusion_types.input_tokens;
  check int "Claude reported output unchanged" 7 claude.output_tokens;
  let tokens = { Runtime_codex_app_server.input_tokens = 100; cached_input_tokens = 50;
    cache_write_input_tokens = 20; output_tokens = 7; reasoning_output_tokens = 3; total_tokens = 107 } in
  let codex = Usage.codex_usage (Runtime_codex_app_server.Thread_count
      {last = Request_usage tokens; thread_total = tokens}) in
  check int "Codex inclusive input does not double count cache" 100 codex.Fusion_types.input_tokens;
  check int "Codex inclusive output does not double count reasoning" 7 codex.output_tokens;
  check bool "replaced counter is not charged as an observed total" true
    (Fusion_types.equal_usage Fusion_types.zero_usage
      (Usage.codex_usage Runtime_codex_app_server.Thread_count_replaced))
;;

let selected_account_agy_script = {|#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(__file__).parent
account_dir = Path(os.environ["HOME"])
# A one-shot call owns a HOME that lives with it: below a temporary root of its
# own, never below the runtime state directory.
assert not account_dir.is_relative_to((root / ".masc").resolve())
assert any(part.startswith("masc-antigravity-panelist-") for part in account_dir.parts)
assert account_dir.parent.name == "panelist"
assert account_dir.stat().st_mode & 0o777 == 0o700
workspace = Path.cwd()
assert workspace == account_dir / "native-workspace"
assert workspace.stat().st_mode & 0o777 == 0o700
assert "--sandbox" in sys.argv and "--disable-slash-commands" in sys.argv
assert sys.argv[sys.argv.index("--mode") + 1] == "plan"
assert [sys.argv[i + 1] for i, value in enumerate(sys.argv) if value == "--add-dir"] == [str(workspace)]
assert not (account_dir / ".gemini/config/mcp_config.json").exists()
policy = json.loads((account_dir / ".gemini/antigravity-cli/settings.json").read_text())["permissions"]
assert policy["allow"] == ["mcp(masc/*)", "read_file(" + str(workspace) + ")"]
assert policy["deny"] == ["write_file(*)", "command(*)", "read_url(*)", "execute_url(*)"]
assert "XDG_CONFIG_HOME" not in os.environ
credential = account_dir / ".gemini/antigravity-cli/antigravity-oauth-token"
assert credential.stat().st_mode & 0o777 == 0o600
document = json.loads(credential.read_text())
# The seed carries a revision after the colon; a call sees the seed it was given.
before = document["token"]["access_token"].split(":")[0]
assert before in ["SELECTED_A", "SELECTED_A_REFRESHED", "SELECTED_B", "SELECTED_C", "SELECTED_C_REFRESHED"]
document["token"]["access_token"] = before if before.endswith("_REFRESHED") else before + "_REFRESHED"
credential.write_text(json.dumps(document))
assert sys.stdin.read()
# Prompt EOF follows on_spawned publication. Observe the actual Fusion spawn
# manager's group without creating or changing a process group in this CLI.
panel_root = next(path for path in account_dir.parents
                  if path.name.startswith("masc-antigravity-panelist-"))
owner = json.loads((panel_root / "process-owner.json").read_text())
pid, pgid = os.getpid(), os.getpgrp()
assert pgid == pid
assert owner["state"] == "process_group" and owner["pgid"] == pgid
with (root / "selected-accounts.jsonl").open("a") as log:
    log.write(json.dumps({"home": str(account_dir), "cwd": str(workspace),
                         "pid": pid, "pgid": pgid}) + "\n")
model = sys.argv[sys.argv.index("--model") + 1]
print(json.dumps({"event": "init", "conversation_id": "panel-fixture", "init": {
    "model": model, "cwd": str(workspace), "tools": [], "permission_mode": "request-review"}}), flush=True)
print(json.dumps({"event": "result", "result": {"conversation_id": "panel-fixture", "status": "SUCCESS",
    "response": before, "num_turns": 1, "usage": {"input_tokens": 1, "output_tokens": 1,
    "thinking_tokens": 0, "cache_read_tokens": 0, "total_tokens": 2}}}), flush=True)
|}

let test_antigravity_panel_selected_account_and_refresh () =
  let snapshot = Runtime.For_testing.snapshot () in
  let base_dir = Filename.temp_dir "fusion-agy-account" "" |> Unix.realpath in
  let saved_env = List.map (fun key -> key, Sys.getenv_opt key) ["HOME"; "XDG_CONFIG_HOME"] in
  Fun.protect ~finally:(fun () ->
    List.iter (fun (key, value) -> Unix.putenv key (match value with Some value -> value | None -> "")) saved_env;
    Runtime.For_testing.restore snapshot;
    remove_tree base_dir) (fun () ->
    let panel_tmp = Filename.concat base_dir "panel-tmp" in
    Unix.mkdir panel_tmp 0o700;
    let saved_tmp = Filename.get_temp_dir_name () in
    Filename.set_temp_dir_name panel_tmp;
    Fun.protect ~finally:(fun () -> Filename.set_temp_dir_name saved_tmp) @@ fun () ->
    let ambient = Filename.concat base_dir "ambient" in
    Fs_compat.mkdir_p (Filename.concat ambient ".gemini/antigravity-cli");
    let ambient_oauth = Filename.concat ambient ".gemini/antigravity-cli/antigravity-oauth-token" in
    write_file ~path:ambient_oauth ~perm:0o600 "AMBIENT_MUST_NOT_BE_USED";
    Unix.putenv "HOME" ambient;
    Unix.putenv "XDG_CONFIG_HOME" (Filename.concat ambient ".config");
    let agy_cli = Filename.concat base_dir "agy" in
    write_file ~path:agy_cli ~perm:0o700 selected_account_agy_script;
    let account_a = Filename.concat base_dir "account-a.oauth" in
    let account_b = Filename.concat base_dir "account-b.oauth" in
    write_file ~path:account_a ~perm:0o600 (Masc_test_deps.antigravity_oauth_fixture "SELECTED_A");
    write_file ~path:account_b ~perm:0o600 (Masc_test_deps.antigravity_oauth_fixture "SELECTED_B");
    let config_path = Filename.concat base_dir "runtime.toml" in
    let select oauth_source =
      write_file ~path:config_path ~perm:0o600 (agy_fixture ~agy_cli ~oauth_source);
      match Runtime.init_default ~config_path with
      | Ok () -> () | Error detail -> fail detail in
    with_eio (fun ~sw:_ ~net:_ ->
      List.iter (fun (source, expected) ->
        select source;
        let runtime = Runtime.get_runtime_by_id agy_runtime |> Option.get in
        match Masc.Fusion_official_client.run_with_images ~images:[] ~base_dir ~runtime
            ~system_prompt:"Return the fixture answer." ~prompt:"Selected account." () with
        | Ok response -> check string "selected account and native refresh observed" expected response.text
        | Error error -> fail (Masc.Fusion_official_client.failure_detail ~runtime_id:agy_runtime error))
        [account_a, "SELECTED_A"; account_b, "SELECTED_B"; account_a, "SELECTED_A"];
      check string "selected source A untouched" (Masc_test_deps.antigravity_oauth_fixture "SELECTED_A") (Fs_compat.load_file account_a);
      write_file ~path:account_a ~perm:0o600
        (Masc_test_deps.antigravity_oauth_fixture ~revision:"source-refresh" "SELECTED_A");
      let runtime = Runtime.get_runtime_by_id agy_runtime |> Option.get in
      (match Masc.Fusion_official_client.run_with_images ~images:[] ~base_dir ~runtime
          ~system_prompt:"" ~prompt:"Retain this account across source refresh." () with
       | Ok response -> check string "a call starts from the selected source, not from an earlier call's refresh"
           "SELECTED_A" response.text
       | Error error -> fail (Masc.Fusion_official_client.failure_detail ~runtime_id:agy_runtime error));
      write_file ~path:account_a ~perm:0o600 (Masc_test_deps.antigravity_oauth_fixture "SELECTED_C");
      List.iter (fun expected ->
        let runtime = Runtime.get_runtime_by_id agy_runtime |> Option.get in
        match Masc.Fusion_official_client.run_with_images ~images:[] ~base_dir ~runtime
            ~system_prompt:"" ~prompt:"Externally re-logged account." () with
        | Ok response -> check string "same-path re-login is selected" expected response.text
        | Error error -> fail (Masc.Fusion_official_client.failure_detail ~runtime_id:agy_runtime error))
        ["SELECTED_C"; "SELECTED_C"];
      Unix.unlink account_a;
      check bool "missing selected source refuses instead of ambient fallback" true
        (Result.is_error (Masc.Fusion_official_client.run_panelist ~base_dir ~runtime_id:agy_runtime
           ~system_prompt:"" ~prompt:"Must refuse." ())));
    check string "ambient account untouched" "AMBIENT_MUST_NOT_BE_USED" (Fs_compat.load_file ambient_oauth);
    check string "selected source B untouched" (Masc_test_deps.antigravity_oauth_fixture "SELECTED_B") (Fs_compat.load_file account_b);
    let rows = Fs_compat.load_file (Filename.concat base_dir "selected-accounts.jsonl")
      |> String.split_on_char '\n' |> List.filter (fun row -> row <> "")
      |> List.map Yojson.Safe.from_string in
    List.iter
      (fun row ->
         let pid = Yojson.Safe.Util.(row |> member "pid" |> to_int) in
         let pgid = Yojson.Safe.Util.(row |> member "pgid" |> to_int) in
         check int "actual Fusion CLI leads its published foreground process group" pid pgid)
      rows;
    let homes = List.map (fun row -> Yojson.Safe.Util.(row |> member "home" |> to_string)) rows in
    match homes with
    | [_; _; _; _; _; _] ->
      check int "every call has a HOME of its own" 6
        (List.length (List.sort_uniq String.compare homes));
      List.iter
        (fun home ->
           let root_name =
             home |> Filename.dirname |> Filename.dirname |> Filename.dirname |> Filename.dirname |> Filename.basename
           in
           check (option int) "panelist root stamps this process's pid"
             (Some (Unix.getpid ()))
             (Masc.Fusion_official_client.For_testing.antigravity_panel_root_owner_pid root_name);
           check bool "the HOME is removed with its call" false (Sys.file_exists home))
        homes;
      check bool "no per-account state is kept under the runtime state directory" false
        (Sys.file_exists (Filename.concat base_dir ".masc/official-clients"));
      check (list string) "no temporary root outlives its call, refused ones included" []
        (Array.to_list (Sys.readdir panel_tmp))
    | _ -> fail "only six admitted model turns should spawn")
;;

(* One past the largest pid any supported platform allocates (Linux caps
   pid_max at 4194304; macOS at 99999), so no process can hold it and
   [Unix.kill] answers ESRCH. *)
let dead_pid = 4194305

let test_sweep_stale_antigravity_panel_roots () =
  let parse = Masc.Fusion_official_client.For_testing.antigravity_panel_root_owner_pid in
  check (option int) "decimal pid with nonce parsed"
    (Some dead_pid)
    (parse "masc-antigravity-panelist-4194305-a1b2c3");
  List.iter
    (fun name ->
       check (option int) (name ^ " rejected") None (parse name))
    [ "masc-antigravity-panelist-a1b2c3"
    ; "masc-antigravity-panelist-0x10-a1b2c3"
    ; "masc-antigravity-panelist-+123-a1b2c3"
    ; "masc-antigravity-panelist-1_000-a1b2c3"
    ; "masc-antigravity-panelist--5-a1b2c3"
    ; "masc-antigravity-panelist-0-a1b2c3"
    ; "masc-antigravity-panelist-4242-"
    ; "masc-antigravity-panelist--a1b2c3"
    ; "masc-muse-panelist-4194305-a1b2c3"
    ];
  let temp_dir = Filename.temp_dir "fusion-agy-sweep" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> remove_tree temp_dir) @@ fun () ->
  let plant_root ?(perm = 0o700) name =
    let root = Filename.concat temp_dir name in
    Unix.mkdir root perm;
    let oauth_dir =
      List.fold_left Filename.concat root [ "official-clients"; "antigravity"; "panelist"; "rev"; ".gemini"; "antigravity-cli" ]
    in
    Fs_compat.mkdir_p oauth_dir;
    write_file
      ~path:(Filename.concat oauth_dir "antigravity-oauth-token")
      ~perm:0o600
      (Masc_test_deps.antigravity_oauth_fixture "ORPHAN_SECRET");
    root
  in
  let initialized_root name =
    let root = plant_root name in
    (match Masc.Antigravity_panel_root_owner.initialize ~root with
     | Ok () -> ()
     | Error detail -> fail detail);
    root
  in
  let dead_root = initialized_root (Printf.sprintf "masc-antigravity-panelist-%d-dead01" dead_pid) in
  let live_self_root =
    initialized_root (Printf.sprintf "masc-antigravity-panelist-%d-live01" (Unix.getpid ()))
  in
  let live_init_root = initialized_root "masc-antigravity-panelist-1-init01" in
  let legacy_root = plant_root "masc-antigravity-panelist-legacy01" in
  let non_private_dead_root =
    let root = initialized_root (Printf.sprintf "masc-antigravity-panelist-%d-open01" dead_pid) in
    Unix.chmod root 0o755;
    root
  in
  let absent_owner = plant_root (Printf.sprintf "masc-antigravity-panelist-%d-absent01" dead_pid) in
  let pending_owner = initialized_root (Printf.sprintf "masc-antigravity-panelist-%d-pending01" dead_pid) in
  (match Masc.Antigravity_panel_root_owner.before_spawn ~root:pending_owner with
   | Ok () -> ()
   | Error detail -> fail detail);
  let corrupt_owner = initialized_root (Printf.sprintf "masc-antigravity-panelist-%d-corrupt01" dead_pid) in
  (* Corrupt the persisted ownership record without coupling the fixture to
     its file name. This root contains only the record and the OAuth tree. *)
  Array.iter
    (fun name ->
       let path = Filename.concat corrupt_owner name in
       if (Unix.lstat path).Unix.st_kind = Unix.S_REG then
         write_file ~path ~perm:0o600 "not a valid process ownership record")
    (Sys.readdir corrupt_owner);
  let symlink_target = Filename.concat temp_dir "outside-target" in
  Unix.mkdir symlink_target 0o700;
  let symlink_path =
    Filename.concat temp_dir (Printf.sprintf "masc-antigravity-panelist-%d-link01" dead_pid)
  in
  Unix.symlink symlink_target symlink_path;
  Masc.Fusion_official_client.sweep_stale_antigravity_panel_roots ~temp_dir ();
  check bool "dead-process 0700 panelist root and OAuth copy removed" false
    (Sys.file_exists dead_root);
  List.iter
    (fun (label, root) -> check bool label true (Sys.file_exists root))
    [ "absent ownership is retained", absent_owner
    ; "spawn pending ownership is retained", pending_owner
    ; "malformed ownership is retained", corrupt_owner
    ];
  check bool "live self-process panelist root kept" true
    (Sys.file_exists (Filename.concat live_self_root "official-clients/antigravity/panelist/rev/.gemini/antigravity-cli/antigravity-oauth-token"));
  check bool "live other-user (pid 1 / EPERM) panelist root kept" true
    (Sys.file_exists live_init_root);
  check bool "unattributed legacy panelist root kept" true
    (Sys.file_exists legacy_root);
  check bool "non-0700 directory is not removed" true
    (Sys.file_exists non_private_dead_root);
  check bool "symlink target is untouched" true
    (Sys.file_exists symlink_target);
  check bool "symlink entry itself is untouched" true
    (try ignore (Unix.lstat symlink_path : Unix.stats); true with Unix.Unix_error _ -> false)
;;

(* The supervisor outlives the simulated MASC creator. On Linux it adopts
   orphaned descendants so a container's pid 1 cannot leave fixture zombies;
   launchd performs that reaping on macOS. Commands acknowledge exact process
   transitions rather than relying on a delay before running the sweep. *)
let orphaned_antigravity_fixture = {|import ctypes, errno, json, os, select, signal, sys, time

if sys.platform.startswith("linux"):
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")

# Reserve descriptor 3, then explicitly close it in the CLI. Retention must
# survive clients that do not preserve an inherited descriptor lease.
reserved = os.open(os.devnull, os.O_RDONLY)
if reserved != 3:
    os.dup2(reserved, 3)
    os.close(reserved)
ready_read, ready_write = os.pipe()
start_read, start_write = os.pipe()
leader_read, leader_write = os.pipe()
descendant_read, descendant_write = os.pipe()
creator = os.fork()
if creator == 0:
    os.setpgid(0, 0)
    root = os.path.join(sys.argv[1], "masc-antigravity-panelist-%d-orphan" % os.getpid())
    os.mkdir(root, 0o700)
    home = os.path.join(root, "home")
    os.mkdir(home, 0o700)
    credential = os.path.join(home, "antigravity-oauth-token")
    with open(credential, "w") as handle:
        handle.write("ORPHAN_OAUTH_COPY")
    os.chmod(credential, 0o600)
    leader = os.fork()
    if leader == 0:
        # Until the supervisor knows our PID, remain in the creator's group
        # so startup cleanup can terminate us even without a ready message.
        assert os.read(start_read, 1) == b"x"
        os.setpgid(0, 0)
        os.close(3)
        if len(sys.argv) > 2 and sys.argv[2] == "fail-startup":
            os._exit(71)
        try:
            os.fstat(3)
            raise AssertionError("descriptor 3 stayed open")
        except OSError as error:
            assert error.errno == errno.EBADF
        os.environ["HOME"] = home
        descendant = os.fork()
        if descendant == 0:
            assert os.read(descendant_read, 1) == b"x"
            assert os.path.isdir(os.environ["HOME"])
            with open(credential) as handle:
                assert handle.read() == "ORPHAN_OAUTH_COPY"
            os._exit(0)
        os.write(ready_write, (json.dumps({"descendant": descendant, "fd3_closed": True}) + "\n").encode())
        assert os.read(leader_read, 1) == b"x"
        assert os.path.isdir(os.environ["HOME"])
        with open(credential) as handle:
            assert handle.read() == "ORPHAN_OAUTH_COPY"
        os._exit(0)
    os.write(ready_write, (json.dumps({"creator": os.getpid(), "leader": leader,
        "root": root, "home": home, "credential": credential}) + "\n").encode())
    os.close(ready_write)
    while True:
        signal.pause()

# Establish the cleanup group before any startup wait. The CLI cannot leave
# it until its PID is published and acknowledged over start_write.
os.setpgid(creator, creator)
os.close(ready_write)
creator_alive = True
leader = None
group_alive = True

def read_line(fd):
    deadline = time.monotonic() + 10
    contents = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError("fixture handshake did not arrive")
        value = os.read(fd, 1)
        if not value:
            raise EOFError("fixture handshake closed before readiness")
        if value == b"\n":
            return contents.decode()
        contents.extend(value)

def emit(value):
    print(value, flush=True)

def wait_child(pid):
    deadline = time.monotonic() + 10
    while True:
        if sys.platform.startswith("linux"):
            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited:
                assert os.waitstatus_to_exitcode(status) == 0
                return
        else:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
        if time.monotonic() >= deadline:
            raise TimeoutError("fixture child was not reaped")
        time.sleep(0.01)

def group_exists():
    try:
        os.killpg(leader, 0)
        return True
    except ProcessLookupError:
        return False

def terminate_supervisor(_signal, _frame):
    raise InterruptedError("fixture supervisor terminated")

signal.signal(signal.SIGTERM, terminate_supervisor)
try:
    info = json.loads(read_line(ready_read))
    leader = info["leader"]
    if len(sys.argv) > 2:
        print(json.dumps(info), file=sys.stderr, flush=True)
    os.write(start_write, b"x")
    info.update(json.loads(read_line(ready_read)))
    emit(json.dumps(info))
    assert read_line(0) == "kill-creator"
    os.kill(creator, signal.SIGKILL)
    _, status = os.waitpid(creator, 0)
    creator_alive = False
    assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL
    emit("creator-reaped")
    assert read_line(0) == "exit-leader"
    os.write(leader_write, b"x")
    wait_child(leader)
    assert group_exists()
    emit("descendant-retained")
    assert read_line(0) == "exit-descendant"
    os.write(descendant_write, b"x")
    wait_child(info["descendant"])
    assert not group_exists()
    group_alive = False
    emit("group-reaped")
finally:
    # EOF/timeout and the OCaml finalizer's SIGTERM can arrive together.
    # Once cleanup starts, termination must not interrupt group reaping.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    # These are only groups and PIDs created by this fixture. Killing both
    # groups also covers a CLI failure before it establishes its own PGID.
    for pgid in ([creator] if creator_alive else []) + ([leader] if leader and group_alive else []):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 10
    while True:
        try:
            waited, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if not waited:
            if time.monotonic() >= deadline:
                raise TimeoutError("fixture cleanup did not reap its children")
            time.sleep(0.01)
|}

let test_sweep_retains_orphaned_antigravity_process_group () =
  let temp_dir = Filename.temp_dir "fusion-agy-orphan" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> remove_tree temp_dir) @@ fun () ->
  let script = Filename.concat temp_dir "orphan-fixture.py" in
  write_file ~path:script ~perm:0o600 orphaned_antigravity_fixture;
  let output, input, errors =
    Unix.open_process_args_full "python3" [| "python3"; script; temp_dir |] (Unix.environment ())
  in
  let status = ref None in
  Fun.protect
    ~finally:(fun () ->
      match !status with
      | Some _ -> ()
      | None ->
        (* SIGTERM interrupts startup as well as command waits; the helper's
           finally block kills and reaps only its own fixture processes. *)
        close_out_noerr input;
        (try Unix.kill (Unix.process_full_pid (output, input, errors)) Sys.sigterm
         with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
        ignore (Unix.close_process_full (output, input, errors)))
    (fun () ->
       let receive () =
         let readable, _, _ = Unix.select [ Unix.descr_of_in_channel output ] [] [] 15.0 in
         if readable = [] then fail "orphan fixture did not acknowledge its transition";
         match input_line output with
         | line -> line
         | exception End_of_file ->
           failf "orphan fixture exited: %s" (In_channel.input_all errors)
       in
       let info = Yojson.Safe.from_string (receive ()) in
       let string_field key = Yojson.Safe.Util.(info |> member key |> to_string) in
       let int_field key = Yojson.Safe.Util.(info |> member key |> to_int) in
       let root = string_field "root" in
       let home = string_field "home" in
       let credential = string_field "credential" in
       check bool "CLI explicitly closed descriptor 3" true
         Yojson.Safe.Util.(info |> member "fd3_closed" |> to_bool);
       let publish = function Ok () -> () | Error detail -> fail detail in
       publish (Masc.Antigravity_panel_root_owner.initialize ~root);
       publish (Masc.Antigravity_panel_root_owner.before_spawn ~root);
       publish (Masc.Antigravity_panel_root_owner.spawned ~root ~pid:(int_field "leader"));
       let command command expected =
         output_string input (command ^ "\n");
         flush input;
         check string "fixture transition" expected (receive ())
       in
       let sweep () =
         Masc.Fusion_official_client.sweep_stale_antigravity_panel_roots ~temp_dir ()
       in
       let retained label =
         sweep ();
         check bool (label ^ ": HOME retained") true (Sys.file_exists home);
         check string (label ^ ": OAuth copy retained") "ORPHAN_OAUTH_COPY"
           (Fs_compat.load_file credential)
       in
       command "kill-creator" "creator-reaped";
       check (option int) "root names the killed creator" (Some (int_field "creator"))
         (Masc.Fusion_official_client.For_testing.antigravity_panel_root_owner_pid
            (Filename.basename root));
       check bool "creator PID is absent before the sweep" true
         (match Unix.kill (int_field "creator") 0 with
          | () -> false
          | exception Unix.Unix_error (Unix.ESRCH, _, _) -> true);
       retained "creator SIGKILL with live CLI";
       command "exit-leader" "descendant-retained";
       retained "CLI leader exited with same-group descendant";
       command "exit-descendant" "group-reaped";
       sweep ();
       check bool "root removed after the final process-group member exits" false
         (Sys.file_exists root);
       let result = Unix.close_process_full (output, input, errors) in
       status := Some result;
       check bool "fixture completed successfully" true (result = Unix.WEXITED 0))
;;

let () =
  run
    "fusion official-client panel"
    [ ( "panelist routing"
      , [ test_case "vendor token usage conventions" `Quick
            test_official_client_usage_preserves_vendor_cache_conventions
        ; test_case
            "official-client runtime is routed to the spawn path"
            `Quick
            test_official_client_runtime_is_routed_to_the_spawn_path
        ; test_case
            "Agent_core runtime stays on the Async_agent path"
            `Quick
            test_agent_core_runtime_stays_on_the_async_agent_path
        ; test_case
            "unknown runtime is not claimed by the spawn path"
            `Quick
            test_unknown_runtime_is_not_claimed_by_the_spawn_path
        ; test_case
            "official-client panel honors no deadline"
            `Quick
            test_official_client_panel_honors_no_deadline
        ; test_case
            "unbounded Claude panel keeps login probe bounded"
            `Quick
            test_unbounded_claude_panel_keeps_login_probe_bounded
        ; test_case
            "client timeouts project to Timeout"
            `Quick
            test_client_timeouts_project_to_timeout
        ; test_case
            "setup failures attribute the runtime once"
            `Quick
            test_setup_failure_attribution_is_single
        ] )
    ; ( "eio context diagnostics"
      , [ test_case
            "both handles present produces no complaint"
            `Quick
            test_both_handles_present_has_no_complaint
        ; test_case
            "each absent handle is named"
            `Quick
            test_each_absent_handle_is_named
        ] )
    ; ( "panel execution"
      , [ test_case
            "official-client panelist reaches its client"
            `Quick
            test_official_client_panelist_reaches_its_client
        ; test_case
            "official-client judge reaches its client"
            `Quick
            test_official_client_judge_reaches_its_client
        ; test_case
            "Antigravity judge receives its system prompt"
            `Quick
            test_antigravity_judge_receives_its_system_prompt
        ; test_case
            "Muse Code panelist reaches muse serve"
            `Quick
            test_muse_code_panelist_reaches_muse_serve
        ; test_case "Muse missing reply is a consumer failure" `Quick
            test_muse_missing_reply_is_consumer_failure
        ; test_case "Muse frozen candidate and account quota" `Quick test_muse_frozen_candidate_and_quota_scope
        ; test_case "paid failed seats and successful fallbacks retain usage" `Quick
            test_panel_paid_failures_survive_exhaustion_and_fallback
        ; test_case "Muse failed and cancelled turns retain paid usage" `Quick
            test_muse_failed_terminals_retain_usage
        ; test_case "Muse stateless storage keeps durable protocol" `Quick
            test_muse_stateless_host_keeps_durable_protocol
        ; test_case "all official clients retain failed-turn spend" `Quick test_all_official_client_failed_usage
        ; test_case "Muse judge parse failure retains paid usage" `Quick
            test_muse_judge_parse_failure_retains_reported_usage
        ; test_case "blank Judge synthesis uses the next candidate" `Quick
            test_judge_blank_synthesis_uses_the_next_candidate
        ; test_case
            "Muse Code panelist works in its own directory"
            `Quick
            test_muse_code_panelist_works_in_its_own_directory
        ; test_case
            "Muse Code panelist removes its directory after a failure"
            `Quick
            test_muse_code_panelist_removes_its_directory_after_a_failure
        ; test_case
            "Muse Code refuses an output schema before spawning"
            `Quick
            test_muse_code_refuses_an_output_schema_before_spawning
        ; test_case "cancelled Muse panel leaves no workspace" `Quick
            test_cancelled_muse_panel_does_not_leave_a_workspace
        ; test_case "Antigravity selected account and native refresh" `Quick
            test_antigravity_panel_selected_account_and_refresh
        ; test_case "Antigravity orphan CLI and descendant retain HOME after creator SIGKILL" `Quick
            test_sweep_retains_orphaned_antigravity_process_group
        ; test_case "stale Antigravity panelist roots of dead processes are swept" `Quick
            test_sweep_stale_antigravity_panel_roots
        ] )
    ; ( "seat routes"
      , [ test_case
            "judge lane walks candidates in order"
            `Quick
            test_judge_lane_walks_candidates_in_order
        ; test_case
            "panel lane walks candidates in order"
            `Quick
            test_panel_lane_walks_candidates_in_order
        ; test_case
            "unknown route fails without an attempt"
            `Quick
            test_unknown_route_fails_without_an_attempt
        ; test_case
            "walk stops at the first answer"
            `Quick
            test_walk_stops_at_the_first_answer
        ] )
    ]
;;
