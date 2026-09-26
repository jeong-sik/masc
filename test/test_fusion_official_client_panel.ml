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

[models."claude-opus-5"]
api-name = "claude-opus-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-opus-5"]

[runtime.lanes.fusion-judge]
candidates = ["claude_code.claude-opus-5", "claude_code.claude-sonnet-5"]
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
let judge_lane_first = "claude_code.claude-opus-5"

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
  write_file ~path:oauth_source ~perm:0o600 "{}";
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
   | Ok (synthesis, _usage) ->
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
max-prompt-bytes = 1048576

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
  {|import json, os, sys

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

init = read()
send({"jsonrpc": "2.0", "id": init["id"], "result": {
    "serverInfo": {"name": "muse-session-server", "version": "1.3.0"},
    "userAgent": "muse/1.3.0", "museHome": "/tmp/muse", "platformFamily": "unix",
    "platformOs": "linux", "schema": {"version": 1, "fingerprint": "sha256:fixture"},
    "grantedCapabilities": [], "experimentalApi": False,
    "sessionDurability": "durable"}})
assert read()["method"] == "initialized"
opened = read()
assert opened["method"] == "session/start", opened
with open(os.path.join(HERE, "start-params.json"), "w") as handle:
    json.dump(opened["params"], handle)
send({"jsonrpc": "2.0", "id": opened["id"], "result": {
    "session": {"sessionId": "panel-session", "status": "idle", "turnCount": 0,
                "modelId": opened["params"]["modelId"],
                "workspaceRoot": opened["params"]["workspaceRoot"]},
    "viewCursor": "v:1"}})
turn = read()
assert turn["method"] == "turn/start", turn
turn_id = turn["params"]["commandId"]
text = [part["text"] for part in turn["params"]["input"] if part["type"] == "text"][0]
with open(os.path.join(HERE, "panel-prompt.txt"), "w") as handle:
    handle.write(text)
send({"jsonrpc": "2.0", "id": turn["id"], "result": {
    "commandId": turn_id, "status": "accepted", "turnId": turn_id,
    "startedNewTurn": True, "disposition": "started"}})
notify("turn/started", {"sessionId": "panel-session", "turnId": turn_id,
                        "commandId": turn_id, "viewCursor": "v:2"})
notify("item/completed", {"sessionId": "panel-session", "viewCursor": "v:3", "item": {
    "itemId": "m-1", "kind": "agentMessage", "turnId": turn_id, "revision": 1,
    "status": "completed", "text": "MUSE_PANEL_ANSWER"}})
notify("turn/completed", {"sessionId": "panel-session", "turnId": turn_id,
                          "terminal": "completed", "viewCursor": "v:4"})
for _ in sys.stdin:
    pass
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
    (Printf.sprintf "#!/bin/sh\nexec python3 %s\n" (Filename.quote host));
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
let test_muse_code_panelist_reaches_muse_serve () =
  with_muse_runtime ~muse_cli:muse_panel_launcher @@ fun ~base_dir ->
  let answer =
    in_eio_context (fun () ->
      Masc.Fusion_official_client.run_panelist ~base_dir ~runtime_id:muse_runtime_id
        ~system_prompt:"LENS-MARKER answer as a reviewer"
        ~prompt:"QUESTION-MARKER which candidate ships?" ())
  in
  (match answer with
   | Ok text -> check string "the agent message is the answer" "MUSE_PANEL_ANSWER" text
   | Error failure ->
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
   | Error failure ->
     failf "the Muse Code panelist failed: %s" (Fusion_types.show_panel_failure failure));
  let start = Yojson.Safe.from_file (Filename.concat base_dir "start-params.json") in
  let root = Yojson.Safe.Util.(start |> member "workspaceRoot" |> to_string) in
  check bool "the workspace root is not under the base path" false
    (is_within ~dir:base_dir root);
  let cwd, entries = muse_panel_cwd ~base_dir in
  check string "the host runs in the workspace root" root cwd;
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
     | [ Fusion_types.Failed { reason = Fusion_types.Unknown_route "nope.not-configured"; _ } ]
       -> ()
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

let selected_account_agy_script = {|#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(__file__).parent
account_dir = Path(os.environ["HOME"])
assert account_dir.is_relative_to(root / ".masc/official-clients/antigravity")
assert account_dir.name.startswith("fusion-")
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
before = credential.read_text()
assert before in ["SELECTED_A", "SELECTED_A_REFRESHED", "SELECTED_B"]
credential.write_text(before if before.endswith("_REFRESHED") else before + "_REFRESHED")
with (root / "selected-accounts.jsonl").open("a") as log:
    log.write(json.dumps({"home": str(account_dir), "cwd": str(workspace)}) + "\n")
assert sys.stdin.read()
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
    write_file ~path:account_a ~perm:0o600 "SELECTED_A";
    write_file ~path:account_b ~perm:0o600 "SELECTED_B";
    let config_path = Filename.concat base_dir "runtime.toml" in
    let select oauth_source =
      write_file ~path:config_path ~perm:0o600 (agy_fixture ~agy_cli ~oauth_source);
      match Runtime.init_default ~config_path with
      | Ok () -> () | Error detail -> fail detail in
    with_eio (fun ~sw:_ ~net:_ ->
      List.iter (fun (source, expected) ->
        select source;
        match Masc.Fusion_official_client.run_panelist ~base_dir ~runtime_id:agy_runtime
            ~system_prompt:"Return the fixture answer." ~prompt:"Selected account." () with
        | Ok text -> check string "selected account and native refresh observed" expected text
        | Error error -> fail (Fusion_agent_core.panel_failure_text error))
        [account_a, "SELECTED_A"; account_b, "SELECTED_B"; account_a, "SELECTED_A_REFRESHED"];
      check string "selected source A untouched" "SELECTED_A" (Fs_compat.load_file account_a);
      Unix.unlink account_a;
      check bool "missing selected source refuses instead of ambient fallback" true
        (Result.is_error (Masc.Fusion_official_client.run_panelist ~base_dir ~runtime_id:agy_runtime
           ~system_prompt:"" ~prompt:"Must refuse." ())));
    check string "ambient account untouched" "AMBIENT_MUST_NOT_BE_USED" (Fs_compat.load_file ambient_oauth);
    check string "selected source B untouched" "SELECTED_B" (Fs_compat.load_file account_b);
    let rows = Fs_compat.load_file (Filename.concat base_dir "selected-accounts.jsonl")
      |> String.split_on_char '\n' |> List.filter (fun row -> row <> "")
      |> List.map Yojson.Safe.from_string in
    let homes = List.map (fun row -> Yojson.Safe.Util.(row |> member "home" |> to_string)) rows in
    match homes with
    | [first; second; third] ->
      check bool "different selected accounts have distinct state" true (first <> second);
      check string "same account reuses refreshed state" first third
    | _ -> fail "only three admitted model turns should spawn")
;;

let () =
  run
    "fusion official-client panel"
    [ ( "panelist routing"
      , [ test_case
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
        ; test_case "Antigravity selected account and native refresh" `Quick
            test_antigravity_panel_selected_account_and_refresh
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
