open Alcotest
module Verify = Runtime_verification

let contains text needle =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1))
  in
  loop 0
;;

let measure run =
  Verify.For_testing.measure
    ~runtime_id:"chosen.model"
    ~selected_model:"selected-model"
    ~challenge:"unpredictable-test-challenge"
    ~run
;;

let observation text = { Verify.model = "observed-model"; text }
let reply = "{\"challenge\":\"unpredictable-test-challenge\"}"

let test_roundtrip () =
  let result =
    measure (fun tool ~prompt ->
      check
        bool
        "challenge absent before tool execution"
        false
        (contains prompt "unpredictable-test-challenge");
      let output =
        tool.Runtime_official_client_tool.call ~call_id:"actual-call" (`Assoc [])
      in
      check bool "harmless tool returned a result" true output.success;
      Ok (observation output.content))
  in
  check int "actual returned challenge verifies" 0 (Verify.exit_code result);
  check bool "tool roundtrip" true result.tool_roundtrip;
  check
    (option string)
    "observed model retained separately"
    (Some "observed-model")
    result.observed_model;
  check string "exact selected runtime remains" "chosen.model" result.runtime_id
;;

let test_no_tool_cannot_claim_success () =
  let result = measure (fun _ ~prompt:_ -> Ok (observation reply)) in
  check int "even correct-looking reply without call fails" 1 (Verify.exit_code result);
  check bool "actual response distinguished from login" true result.response;
  check bool "tool not invoked" false result.tool_called;
  check bool "no roundtrip" false result.tool_roundtrip
;;

let test_result_must_be_consumed () =
  List.iter
    (fun text ->
       let result =
         measure (fun tool ~prompt:_ ->
           ignore (tool.Runtime_official_client_tool.call ~call_id:"call" (`Assoc []));
           Ok (observation text))
       in
       check int "uncorrelated answer is not ready" 1 (Verify.exit_code result);
       check bool "invocation alone is insufficient" true result.tool_called;
       check bool "result not consumed" false result.tool_roundtrip)
    [ "I can use tools"
    ; "{\"challenge\":\"invented\"}"
    ; "{\"challenge\":\"unpredictable-test-challenge\",\"challenge\":\"invented\"}"
    ; ""
    ]
;;

let test_missing_model_identity () =
  let result =
    measure (fun tool ~prompt:_ ->
      let output = tool.Runtime_official_client_tool.call ~call_id:"call" (`Assoc []) in
      Ok { Verify.model = ""; text = output.content })
  in
  check int "missing model identity is not verified" 1 (Verify.exit_code result);
  check (option string) "empty identity is not an observation" None result.observed_model
;;

let test_invalid_call_and_errors () =
  let result =
    measure (fun tool ~prompt:_ ->
      let output =
        tool.Runtime_official_client_tool.call
          ~call_id:"call"
          (`Assoc [ "path", `String "/workspace" ])
      in
      check bool "invalid tool args rejected" false output.success;
      Ok (observation reply))
  in
  check bool "invalid tool args not counted" false result.tool_called;
  List.iter
    (fun failure ->
       let result = measure (fun _ ~prompt:_ -> Error failure) in
       check bool "provider/config failure not success" false result.tool_roundtrip;
       check bool "no response fabricated" false result.response)
    [ Verify.Provider_rejected "the provider returned HTTP 400"
    ; Timed_out
    ; Unavailable Missing_credential
    ]
;;

(* The three client failures used to fold into one code with one message, so a
   client that was merely not signed in read the same as one whose binary was
   missing. Each keeps its own code, and the client's own account survives. *)
let failure_field result field =
  Verify.to_json result
  |> fun json ->
  Yojson.Safe.Util.member "failure" json |> Yojson.Safe.Util.member field
;;

let test_client_failures_stay_apart () =
  let case failure =
    let result = measure (fun _ ~prompt:_ -> Error failure) in
    ( Yojson.Safe.Util.to_string (failure_field result "code")
    , failure_field result "detail" )
  in
  let not_signed_in, signed_in_detail =
    case (Verify.Unavailable (Client_not_authenticated "no stored credential was found"))
  in
  let not_started, started_detail =
    case (Verify.Unavailable (Client_not_started "executable \"claude\" was not found"))
  in
  let bad_config, config_detail =
    case (Verify.Unavailable (Invalid_configuration "cli_path must not be empty"))
  in
  check string "sign-in failure has its own code" "client_not_authenticated" not_signed_in;
  check string "spawn failure has its own code" "client_not_started" not_started;
  check string "config failure has its own code" "invalid_configuration" bad_config;
  check
    (list string)
    "each carries the client's own account"
    [ "no stored credential was found"
    ; "executable \"claude\" was not found"
    ; "cli_path must not be empty"
    ]
    (List.map
       Yojson.Safe.Util.to_string
       [ signed_in_detail; started_detail; config_detail ]);
  let result =
    measure (fun _ ~prompt:_ -> Error (Verify.Unavailable Missing_credential))
  in
  check
    bool
    "a failure with nothing to add reports no detail"
    true
    (failure_field result "detail" = `Null);
  check int "an unavailable client still exits 2" 2 (Verify.exit_code result)
;;

let test_inventory_keeps_all_models_and_no_secrets () =
  let config =
    {|
[runtime]
default = "cloud.first"
[providers.cloud]
display-name = "My endpoint"
protocol = "openai-compatible-http"
endpoint = "https://example.com/v1"
[providers.cloud.credentials]
type = "inline"
value = "must-not-leak"
[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true
[models.second]
api-name = "second-model"
max-context = 8192
tools-support = true
streaming = true
[cloud.first]
wizard-default = true
[cloud.second]
|}
  in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "inventory fixture parses"
  | Ok config ->
    List.iter
      (fun credential ->
         let private_config =
           { config with
             providers =
               List.map
                 (fun (p : Runtime_schema.provider) ->
                    { p with
                      credentials = Some credential
                    ; transport =
                        Runtime_schema.Http
                          "https://user:must-not-leak@example.com/v1?key=must-not-leak"
                    })
                 config.providers
           }
         in
         let projected =
           Runtime_wizard_inventory.to_json private_config |> Yojson.Safe.to_string
         in
         check
           bool
           "credential and URL secrets not serialized"
           false
           (contains projected "must-not-leak"))
      [ Runtime_schema.File "/private/must-not-leak"; Inline "must-not-leak" ];
    let json = Runtime_wizard_inventory.to_json config in
    let open Yojson.Safe.Util in
    let integrations = json |> member "integrations" |> to_list in
    let integration rows id =
      List.find (fun row -> row |> member "id" |> to_string = id) rows
    in
    List.iter (fun credential ->
      let unbound = {config with bindings=[]; default_runtime_id=None;
        providers=List.map (fun (p : Runtime_schema.provider) -> {p with credentials=Some credential}) config.providers} in
      let public = Runtime_wizard_inventory.to_json unbound in
      let private_json = Runtime_wizard_inventory.to_json ~include_credential_references:true unbound in
      let row json = integration (json |> member "integrations" |> to_list) "cloud" in
      check bool "unbound public inventory has no credential path or value" false
        (contains (Yojson.Safe.to_string public) "must-not-leak");
      match credential with
      | Runtime_schema.File path ->
        check string "unbound provider preserves protected kind" "file" (row public |> member "credential_kind" |> to_string);
        check string "only opt-in CLI gets file reference" path (row private_json |> member "credential_file" |> to_string)
      | Inline _ ->
        check string "inline protection retained" "inline" (row private_json |> member "credential_kind" |> to_string);
        check bool "inline value never serialized even for CLI" false
          (contains (Yojson.Safe.to_string private_json) "must-not-leak")
      | Env _ -> fail "fixture credential kind")
      [Runtime_schema.File "/private/must-not-leak"; Inline "must-not-leak"];
    let declared = integration integrations "cloud" in
    check (list string) "configured provider retains both selected models"
      [ "cloud.first"; "cloud.second" ]
      (declared |> member "configured_runtime_ids" |> to_list |> List.map to_string);
    check string "configured connection remains distinct" "runtime_config"
      (declared |> member "origin" |> to_string);
    let empty_config = { config with providers = []; bindings = []; default_runtime_id = None } in
    let empty_inventory = Runtime_wizard_inventory.to_json empty_config in
    check int "no runtime bindings invented" 0
      (empty_inventory |> member "runtimes" |> to_list |> List.length);
    let prototypes = empty_inventory |> member "integrations" |> to_list in
    List.iter (fun id ->
      let row = integration prototypes id in
      check (list string) "unconfigured catalog entry has no runtime" []
        (row |> member "configured_runtime_ids" |> to_list |> List.map to_string);
      check bool "catalog is not account verification" false
        (row |> member "account_availability_verified" |> to_bool))
      [ "openrouter"; "glm-coding"; "codex"; "claude-code"; "ollama"
      ; "vllm"; "rapid-mlx"; "llama-cpp"; "unsloth" ];
    let antigravity = integration prototypes "antigravity" in
    check string "official Antigravity executable" "agy"
      (antigravity |> member "command" |> to_string);
    check string "native response and tool verification is available" "response_tool"
      (antigravity |> member "verification_support" |> to_string);
    List.iter (fun id ->
      check string "media endpoints are not chat setup connections" "unsupported"
        (integration prototypes id |> member "setup_support" |> to_string))
      [ "openai-image"; "zai-image"; "openai-speech" ];
    let gemini = integration prototypes "gemini" in
    check string "missing native Gemini protocol is explicit" "unsupported"
      (gemini |> member "setup_support" |> to_string);
    let rows = json |> member "runtimes" |> to_list in
    check int "all bindings, not one per provider" 2 (List.length rows);
    List.iter
      (fun row ->
         check
           bool
           "inline secret not exposed"
           false
           (List.mem_assoc "api_key_env" (to_assoc row));
         check string "credential kind retained without value" "inline"
           (row |> member "credential_kind" |> to_string))
      rows;
    check
      bool
      "inline credential not serialized"
      false
      (contains (Yojson.Safe.to_string json) "must-not-leak");
    check
      (list string)
      "model identities"
      [ "first-model"; "second-model" ]
      (List.map (fun row -> row |> member "model" |> to_string) rows)
;;

let test_assigned_lane_selects_initial_target () =
  let select assignments lanes =
    Verify.initial_runtime_id ~default_runtime_id:"default.model"
      ~assignments ~lanes ~keeper_name:"imp"
  in
  check (option string) "unassigned uses default" (Some "default.model") (select [] []);
  check (option string) "explicit named lane selects its first target"
    (Some "chosen.model")
    (select [ "imp", "conversation" ]
       [ Runtime_lane.make ~id:"conversation" [ "chosen.model"; "fallback.model" ] ]);
  check (option string) "declared lane shadows even the default runtime ID"
    (Some "chosen.model")
    (select [] [ Runtime_lane.make ~id:"default.model" [ "chosen.model" ] ]);
  check (option string) "empty lane cannot claim a target" None
    (select [ "imp", "empty" ] [ Runtime_lane.make ~id:"empty" [] ])
;;

let test_codex_readiness_excludes_inherited_tools () =
  List.iter (fun body -> check bool "invalid or external profile is explicit failure" true
    (Result.is_error (Runtime_verification_codex_home.project_config body)))
    [ "profile = 42"; "profile = \"not-declared\"" ];
  let source = {|
profile = "gateway"
instructions = "Call the inherited dangerous tool"
[model_providers.custom]
name = "Owned provider"
base_url = "https://example.com/v1"
env_key = "OWNED_PROVIDER_KEY"
[profiles.gateway]
model_provider = "custom"
instructions = "Inherited profile instructions"
[mcp_servers.dangerous]
command = "must-not-spawn"
[plugins.dangerous]
enabled = true
[features]
apps = true
hooks = true
|} in
  (match Runtime_verification_codex_home.project_config source with
   | Error detail -> fail detail
   | Ok projected ->
     let doc = Otoml.Parser.from_string projected in
     check bool "user-home server entirely absent from isolated home" true
       (Otoml.find_opt doc Fun.id ["mcp_servers"; "dangerous"] = None));
  match Runtime_verification_codex_home.project_config ~disabled_mcp_servers:["dangerous"] source with
  | Error detail -> fail detail
  | Ok projected ->
    let doc = Otoml.Parser.from_string projected in
    List.iter (fun key -> check bool (key ^ " not inherited") false
      (Otoml.find_opt doc Fun.id [key] <> None))
      [ "plugins"; "profiles"; "instructions" ];
    check bool "inherited system MCP disabled" false
      (Otoml.find doc Otoml.get_boolean ["mcp_servers"; "dangerous"; "enabled"]);
    check bool "inherited command not copied" true
      (Otoml.find_opt doc Fun.id ["mcp_servers"; "dangerous"; "command"] = None);
    check string "selected profile provider retained" "custom"
      (Otoml.find doc Otoml.get_string ["model_provider"]);
    check string "provider credential name retained" "OWNED_PROVIDER_KEY"
      (Otoml.find doc Otoml.get_string ["model_providers"; "custom"; "env_key"]);
    List.iter (fun key -> check bool (key ^ " disabled") false
      (Otoml.find doc Otoml.get_boolean ["features"; key]))
      ["apps"; "plugins"; "hooks"; "multi_agent"; "shell_tool"; "unified_exec"]
;;

let test_google_adc_refresh_boundary () =
  let expected = ["gcloud"; "auth"; "application-default"; "print-access-token"; "--quiet"] in
  let calls = ref 0 in
  let run argv =
    check (list string) "ADC uses application-default identity" expected argv;
    incr calls; Ok ("fixture-token-" ^ string_of_int !calls ^ "\n") in
  List.iter (fun expected_token ->
    match Runtime_google_adc.refresh_with ~run () with
    | Ok token -> check string "fresh token each request" expected_token (Llm_provider.Secret.header_value token)
    | Error _ -> fail "ADC fixture failed") ["fixture-token-1"; "fixture-token-2"];
  List.iter (fun response ->
    match Runtime_google_adc.refresh_with ~run:(fun _ -> Ok response) () with
    | Error Llm_provider.Provider_config.Invalid_credential_response -> ()
    | _ -> fail "empty or multiple-line ADC output must fail") [""; "token\nextra"]
;;

let antigravity_readiness_fixture = {|#!/usr/bin/env python3
"""Owned CLI fixture: exercise the real authenticated MCP readiness bridge."""
import json
import os
from pathlib import Path
import sys
import urllib.request

prompt = sys.stdin.read()
assert "runtime_readiness_challenge" in prompt
home = Path(os.environ["HOME"])
settings = json.loads((home / ".gemini/antigravity-cli/settings.json").read_text())
assert settings["permissions"]["allow"] == ["mcp(masc/*)"]
assert "command(*)" in settings["permissions"]["deny"]
assert "read_file(*)" in settings["permissions"]["deny"]
config = json.loads((home / ".gemini/config/mcp_config.json").read_text())
assert list(config["mcpServers"]) == ["masc"]
server = config["mcpServers"]["masc"]
headers = dict(server["headers"], **{"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})

def rpc(method, params, request_id=None):
    payload = {"jsonrpc": "2.0", "method": method, "params": params}
    if request_id is not None:
        payload["id"] = request_id
    request = urllib.request.Request(server["url"], data=json.dumps(payload).encode(), headers=headers)
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read()
    return json.loads(body) if body else None

rpc("initialize", {"protocolVersion": "2025-11-25", "clientInfo": {"name": "owned-fixture", "version": "1"}, "capabilities": {}}, 1)
headers["MCP-Protocol-Version"] = "2025-11-25"
rpc("notifications/initialized", {})
listed = rpc("tools/list", {}, 2)
assert [tool["name"] for tool in listed["result"]["tools"]] == ["runtime_readiness_challenge"]
result = rpc("tools/call", {"name": "runtime_readiness_challenge", "arguments": {}}, 3)
text = result["result"]["content"][0]["text"]
model = sys.argv[sys.argv.index("--model") + 1]
print(json.dumps({"event": "init", "conversation_id": "readiness-fixture", "init": {
    "model": model, "cwd": os.getcwd(), "tools": ["call_mcp_tool"], "permission_mode": "request-review"}}), flush=True)
print(json.dumps({"event": "result", "result": {"conversation_id": "readiness-fixture", "status": "SUCCESS", "response": text,
    "duration_seconds": 0.1, "num_turns": 1, "usage": {"input_tokens": 1, "output_tokens": 1,
    "thinking_tokens": 0, "cache_read_tokens": 0, "total_tokens": 2}}}), flush=True)
|}

let test_antigravity_private_tool_roundtrip () =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let directory = Filename.temp_file "antigravity-readiness-test-" "" in
    Unix.unlink directory; Unix.mkdir directory 0o700;
    let directory = Unix.realpath directory in
    Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree directory);
    let source = Filename.concat directory "operator-oauth" in
    let write path content =
      Out_channel.with_open_bin path (fun out -> output_string out content);
      Unix.chmod path 0o600 in
    write source "fixture-operator-secret";
    let script = Filename.concat directory "agy-fixture" in
    write script antigravity_readiness_fixture;
    Unix.chmod script 0o700;
    let config = { (Runtime_antigravity.default_config ~cwd:directory ~model:"fixture-selected-model") with
      cli_path=script; timeout_s=Some 15.; admission_timeout_s=15.; wall_clock_ceiling_s=Some 15. } in
    let result = Verify.For_testing.measure ~runtime_id:"antigravity.fixture" ~selected_model:"fixture-selected-model"
      ~challenge:"private-nonce-fixture"
      ~run:(fun tool ~prompt ->
        match Runtime_verification_antigravity.run ~secure_random:env#secure_random ~net:env#net
          ~mgr:env#process_mgr ~clock:env#clock ~cwd:Eio.Path.(env#fs / directory)
          ~directory ~oauth_source:source ~config ~tool ~prompt with
        | Ok result -> Ok { Verify.model=result.model; text=result.text }
        | Error _ -> Error (Verify.Provider_rejected "fixture-rejection")) in
    check bool "real MCP tool challenge consumed" true result.tool_roundtrip;
    check (option string) "selected CLI model reported" (Some "fixture-selected-model") result.observed_model;
    check string "operator auth bytes unchanged" "fixture-operator-secret" (Fs_compat.load_file source);
    check (list string) "ephemeral HOME and MCP capability removed" ["agy-fixture"; "operator-oauth"]
      (Sys.readdir directory |> Array.to_list |> List.sort String.compare)))
;;

let () =
  run
    "runtime verification"
    [ ( "readiness"
      , [ test_case "Google ADC refresh boundary" `Quick test_google_adc_refresh_boundary
        ; test_case "Antigravity private MCP roundtrip" `Quick test_antigravity_private_tool_roundtrip
        ; test_case "Codex readiness excludes inherited tools" `Quick test_codex_readiness_excludes_inherited_tools
        ; test_case "assigned lane selects initial target" `Quick test_assigned_lane_selects_initial_target
        ; test_case "actual tool-result roundtrip" `Quick test_roundtrip
        ; test_case "no tool cannot claim ready" `Quick test_no_tool_cannot_claim_success
        ; test_case "tool result must be consumed" `Quick test_result_must_be_consumed
        ; test_case "missing observed model" `Quick test_missing_model_identity
        ; test_case "invalid input and errors" `Quick test_invalid_call_and_errors
        ; test_case
            "client failures stay apart"
            `Quick
            test_client_failures_stay_apart
        ; test_case
            "all configured model inventory"
            `Quick
            test_inventory_keeps_all_models_and_no_secrets
        ] )
    ]
;;
