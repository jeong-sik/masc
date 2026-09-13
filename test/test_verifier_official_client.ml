(* Actual managed verifier -> named-runtime -> scoped Claude Code process boundary.
   The fixture supplies model responses, never the reviewer callback. This proves
   typed verdict delivery and initial image transport, not model judgement quality. *)
open Alcotest
open Masc
module AR = Task.Anti_rationalization
module VAT = Verification_authority_tools

let write path body = Out_channel.with_open_bin path (fun out -> output_string out body)
let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

let fixture_script root ~mode =
  let capture = Filename.concat root (mode ^ "-requests.jsonl") in
  let path = Filename.concat root (mode ^ "-claude") in
  write path (Printf.sprintf {|#!/usr/bin/env python3
import json, os, sys
if '--masc-warmup' in sys.argv:
    sys.exit(0)
if 'auth' in sys.argv and 'status' in sys.argv:
    print(json.dumps({'loggedIn':True,'authMethod':'claude.ai','subscriptionType':'team','apiProvider':'firstParty'}))
    sys.exit(0)
capture = %S
mode = %S
session = next(arg.split('=',1)[1] for arg in sys.argv if arg.startswith('--session-id='))
def record(value):
    with open(capture, 'a') as out:
        out.write(json.dumps(value)+'\n')
def emit(value):
    print(json.dumps(value), flush=True)
def read():
    value = json.loads(sys.stdin.readline())
    record(value)
    return value
record({'kind':'launch','argv':sys.argv,'cwd':os.getcwd()})
if mode == 'failed-candidate':
    sys.exit(17)
request = read()
emit({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{}}})
read()
def mcp(index, method, params):
    emit({'type':'control_request','request_id':'mcp-'+str(index),'request':{
        'subtype':'mcp_message','server_name':'masc','message':{
            'jsonrpc':'2.0','id':index,'method':method,'params':params}}})
    read()
mcp(0, 'initialize', {'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'fixture','version':'1'}})
emit({'type':'control_request','request_id':'mcp-ready','request':{
    'subtype':'mcp_message','server_name':'masc','message':{
        'jsonrpc':'2.0','method':'notifications/initialized','params':{}}}})
read()
mcp(1, 'tools/call', {'name':'tool_read_file','arguments':{'file_path':'proof.txt'}})
if mode == 'image-read':
    mcp(4, 'tools/call', {'name':'tool_read_file','arguments':{'file_path':'proof.png'}})
if mode != 'missing':
    mcp(2, 'tools/call', {'name':'report_review_verdict','arguments':{'verdict':'APPROVE','reason':'read-only fixture receipt'}})
if mode == 'duplicate':
    mcp(3, 'tools/call', {'name':'report_review_verdict','arguments':{'verdict':'REJECT','reason':'second verdict invalidates review'}})
text = 'APPROVE (free text is not a verdict)'
emit({'type':'assistant','session_id':session,'uuid':'assistant-1','message':{
    'role':'assistant','model':'verifier-fixture','content':[{'type':'text','text':text}]}})
emit({'type':'result','subtype':'success','is_error':False,'session_id':session,'uuid':'turn-1','result':text,'api_error_status':None})
for line in sys.stdin:
    pass
|} capture mode);
  Unix.chmod path 0o700;
  path, capture

let runtime_config ?endpoint ?(protocol = "claude-code") ?(tools_support = true)
    ?(default = "official.verifier")
    ?(slots = [])
    ?(cli_slots = ["official.verifier"]) command = Printf.sprintf {|
[providers.official]
protocol = %S
%s
is-non-interactive = true
[models.verifier]
api-name = "verifier-fixture"
max-context = 400000
tools-support = %b
streaming = false
[models.verifier.capabilities]
supports-image-input = true
[official.verifier]
[runtime]
default = %S
[runtime.exact_output_lanes.verifier_exact]
slots = [%s]
cli_slots = [%s]
|} protocol
  (match endpoint with
   | None -> Printf.sprintf "command = %S" command
   | Some endpoint -> Printf.sprintf "endpoint = %S" endpoint)
  tools_support default
  (String.concat ", " (List.map (Printf.sprintf "%S") slots))
  (String.concat ", " (List.map (Printf.sprintf "%S") cli_slots))

let records path = In_channel.with_open_bin path In_channel.input_lines
  |> List.map Yojson.Safe.from_string
let member = Yojson.Safe.Util.member

(* A closed CLI stdout supplies no effect observation, so that failure must
   stop the lane. These API-lane cases instead observe a real HTTP refusal
   before any tool call, which is the safe boundary for walking the next
   declared candidate. Every request remains on loopback. *)
let refusing_http_server ~sw ~net =
  let requests = ref [] in
  let callback _connection request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    requests := (Uri.path (Cohttp.Request.uri request), Yojson.Safe.from_string body) :: !requests;
    Cohttp_eio.Server.respond_string ~status:`Too_many_requests
      ~body:{|{"error":{"message":"fixture refusal before tool dispatch","type":"rate_limit_error"}}|} ()
  in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | `Unix _ -> fail "expected a loopback TCP listener" in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:raise);
  Printf.sprintf "http://127.0.0.1:%d" port, requests

let test_lane_authority_views () =
  let lane = Runtime_lane.make ~id:"judge" ["a";"b"]
    |> Runtime_lane.with_terminal_default ~runtime_id:"c" in
  let degraded = Runtime_lane.filter_candidates (fun id -> id = "c") lane in
  check (list string) "degradation preserves ordinary default" ["c"]
    (Runtime_lane.ordered_candidates degraded);
  check (list string) "degradation never promotes implicit default into authority" []
    (Runtime_lane.declared_candidates degraded);
  let explicit = Runtime_lane.make ~id:"judge" ["a";"c";"b"]
    |> Runtime_lane.with_terminal_default ~runtime_id:"c" in
  check (list string) "explicit default keeps its declared position" ["a";"c";"b"]
    (Runtime_lane.declared_candidates explicit);
  check (list string) "explicit default is not appended twice" ["a";"c";"b"]
    (Runtime_lane.ordered_candidates explicit)

let test_review mode =
  let api_lane = List.mem mode
    ["api-lane"; "api-lane-exhausted"; "api-lane-explicit-default"; "api-lane-tools-disabled";
     "api-lane-uncertain-cli"] in
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let saved = Runtime.For_testing.snapshot () in
  let saved_catalog = Llm_provider.Model_catalog.global () in
  let root = Filename.temp_file "verifier-official-" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore saved;
    (match saved_catalog with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Fs_compat.remove_tree root);
  let config = Workspace.default_config root in
  let http = if api_lane then Some (refusing_http_server ~sw ~net:env#net) else None in
  if api_lane then (
    let catalog_path = Filename.concat root "provider-models.toml" in
    write catalog_path
      (String.concat "\n" (List.map (fun provider -> Printf.sprintf
        "[[models]]\nid_prefix=\"verifier-fixture\"\nprovider_name=%S\nbase=\"openai_chat\"\nmax_context_tokens=400000\nmax_output_tokens=1024\nsupports_tools=%b\nsupports_image_input=true\nsupports_native_streaming=false\n"
        provider (mode <> "api-lane-tools-disabled")) ["first"; "official"]));
    match Llm_provider.Model_catalog.load_file catalog_path with
    | Ok catalog -> Llm_provider.Model_catalog.set_global catalog
    | Error detail -> fail detail);
  let proof_root = Filename.concat root Playground_paths.all_playgrounds_prefix in
  Fs_compat.mkdir_p proof_root;
  let proof = if mode = "large-read" then
      "verified-file-receipt\n" ^ String.make 18000 'x' ^ "\nlast-readable-proof-byte"
    else "verified-file-receipt" in
  write (Filename.concat proof_root "proof.txt") proof;
  write (Filename.concat proof_root "proof.png") (Base64.decode_exn png);
  let lookup_tools = match VAT.create_goal_proof ~config with
    | Ok tools -> tools | Error detail -> fail detail in
  let lookup = AR.Lookup_tools
    { schemas = VAT.schemas lookup_tools; dispatch = VAT.dispatch lookup_tools
    ; root_layout = ["proof.txt"] } in
  let command, capture = fixture_script root ~mode in
  let outside_command, outside_capture = fixture_script root ~mode:"outside-exact-lane" in
  let first_command, first_capture = fixture_script root ~mode:"failed-candidate" in
  let outside_id = if mode = "api-lane-tools-disabled"
    then "outside.capable" else "outside.verifier" in
  let outside_runtime = Printf.sprintf {|
[providers.outside]
protocol = "claude-code"
command = %S
is-non-interactive = true
[%s]
|} outside_command outside_id
    ^ (if mode = "api-lane-tools-disabled" then {|
[models.capable]
api-name = "verifier-fixture"
max-context = 400000
tools-support = true
|} else "") in
  let config_path = Filename.concat root "runtime.toml" in
  let runtime_text =
    match mode with
    | "unknown-slot" -> runtime_config ~cli_slots:["official.missing"] command
    | "missing-first" ->
      runtime_config ~cli_slots:["official.missing";"official.verifier"] command
    | "tools-disabled" -> runtime_config ~tools_support:false command
    | "unconfined" -> runtime_config ~protocol:"codex-app-server" command
    | "wrong-kind" ->
      runtime_config ~cli_slots:["http.verifier"] command ^ {|
[providers.http]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[http.verifier]
|}
    | "disabled-binding" ->
      runtime_config ~cli_slots:["official.disabled"] command ^ {|
[models.disabled]
api-name = "verifier-fixture"
max-context = 400000
tools-support = true
[official.disabled]
enabled = false
|}
    | "mixed" ->
      runtime_config ~cli_slots:["unconfined.verifier";"official.verifier"] command
      ^ Printf.sprintf {|
[providers.unconfined]
protocol = "codex-app-server"
command = %S
is-non-interactive = true
[unconfined.verifier]
|} command
    | "api-lane" | "api-lane-exhausted"
    | "api-lane-explicit-default" | "api-lane-tools-disabled" | "api-lane-uncertain-cli" ->
      let url, _ = Option.get http in
      let second_refuses = List.mem mode ["api-lane-exhausted"; "api-lane-explicit-default"] in
      runtime_config ~default:outside_id
        ~tools_support:(mode <> "api-lane-tools-disabled")
        ~slots:["judge.lane"] ~cli_slots:[]
        ?endpoint:(if second_refuses then Some (url ^ "/second") else None)
        ~protocol:(if second_refuses then "openai-compatible-http" else "claude-code") command
      ^ outside_runtime ^ Printf.sprintf {|
[providers.first]
%s
[first.verifier]
[runtime.lanes."judge.lane"]
candidates = ["first.verifier", "official.verifier"%s]
|} (if mode = "api-lane-uncertain-cli" then
      Printf.sprintf "protocol = \"claude-code\"\ncommand = %S\nis-non-interactive = true" first_command
    else Printf.sprintf "protocol = \"openai-compatible-http\"\nendpoint = %S" (url ^ "/first"))
        (if mode = "api-lane-explicit-default" then ", \"outside.verifier\"" else "")
    | "exact-order" ->
      runtime_config ~default:outside_id
        ~cli_slots:["first.verifier";"official.verifier"] command
      ^ outside_runtime ^ Printf.sprintf {|
[providers.first]
protocol = "claude-code"
command = %S
is-non-interactive = true
[first.verifier]
|} first_command
    | "api-tools-disabled" ->
      runtime_config ~tools_support:false ~slots:["api.verifier"] ~cli_slots:[] command ^ {|
[providers.api]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[api.verifier]
|}
    | "shadow" ->
      runtime_config ~default:"outside.verifier" command ^ outside_runtime ^ {|
[runtime.lanes."official.verifier"]
candidates = ["outside.verifier"]
|}
    | _ -> runtime_config command
  in
  write config_path runtime_text;
  (match Runtime.init_default ~config_path with Ok () -> () | Error detail -> fail detail);
  if api_lane then (
    let lane = Runtime.get_lane_by_id "judge.lane" |> Option.get in
    check (list string) "ordinary lane retains its terminal default"
      ["first.verifier";"official.verifier";outside_id]
      (Runtime_lane.ordered_candidates lane);
    check (list string) "authority view retains only explicitly declared candidates"
      (["first.verifier";"official.verifier"]
       @ if mode = "api-lane-explicit-default" then [outside_id] else [])
      (Runtime_lane.declared_candidates lane));
  if List.mem mode ["tools-disabled"; "unconfined"] then (
    let refused = Keeper_turn_driver_wrappers.run_named_with_masc_tools
      ~runtime_id:"official.verifier" ~keeper_name:"required-tools-probe"
      ~base_path:root ~goal:"Must reject before dispatch."
      ~system_prompt:"Explicit verifier contract."
      ~masc_tools:(VAT.schemas lookup_tools) ~dispatch:(VAT.dispatch lookup_tools)
      ~tool_requirement:Keeper_required_tools.Required
      ~required_native_posture:Runtime_native_tools.Native_none ~sw () in
    let expected = if mode = "tools-disabled"
      then Keeper_required_tools.Model_tools_disabled
      else Keeper_required_tools.Native_tools_cannot_be_disabled in
    (match refused with
     | Error error ->
       (match Keeper_required_tools.of_core_error error with
        | Some failure -> check bool "typed candidate rejection" true (failure.reason = expected)
        | None -> fail (Agent_core.Error.to_string error))
     | Ok _ -> fail "required tool posture was silently ignored by the wrapper");
    check bool "required posture rejects before client spawn" false (Sys.file_exists capture));
  if mode = "valid" then (
    let refused = Keeper_turn_driver.run_named ~runtime_id:"official.verifier"
      ~keeper_name:"arbitrary-transform-probe" ~base_path:root
      ~goal:"This request must be refused before spawn." ~system_prompt:"Explicit contract."
      ~tools:[] ~agent_core_tools:[] ~output_contract:Keeper_turn_driver.Tool_verdict
      ~provider_config_transform:(fun cfg -> Ok cfg) ~sw () in
    (match refused with
     | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field="provider_config_transform"; _})) -> ()
     | Error e -> fail (Agent_core.Error.to_string e)
     | Ok _ -> fail "arbitrary provider transform was silently dropped");
    check bool "unsupported arbitrary transform never spawned client" false (Sys.file_exists capture));
  let declarations = match Runtime_toml.parse_string runtime_text with
    | Ok config -> config.Runtime_schema.exact_output_lane_decls
    | Error _ -> fail "fixture runtime declarations failed to parse" in
  let io : Agent_core.Exact_output.resolver_io = {getenv=(fun _ -> Ok None)} in
  let catalog = if api_lane || mode = "api-tools-disabled" then
      Some (Agent_core.Exact_output.Full_replacement {source="verifier-route-fixture";contents=Printf.sprintf {|
[[providers]]
id = "fixture_exact"
kind = "openai_compat"
base_url = "http://127.0.0.1:1"
request_path = "/v1/chat/completions"
api_key_env = ""
capabilities_base = "openai_chat_extended"
[[models]]
id_prefix = "verifier-fixture"
provider_name = "fixture_exact"
max_context_tokens = 400000
max_output_tokens = 1024
supports_response_format_json = true
supports_structured_output = false
input_per_million = 1.0
[[targets]]
id = %S
provider_ref = "fixture_exact"
model_id = "verifier-fixture"
|} (if api_lane then "judge.lane" else "api.verifier")})
    else None in
  let snapshot = match Agent_core.Exact_output.load_resolver_snapshot ~io ?catalog () with
    | Ok snapshot -> snapshot | Error _ -> fail "embedded resolver snapshot unavailable" in
  (match Runtime.publish_exact_output_registry ~lanes:declarations snapshot with
   | Ok _ -> () | Error detail -> fail detail);
  let unavailable = List.mem mode
    ["unknown-slot";"tools-disabled";"unconfined";"wrong-kind";"disabled-binding";"api-tools-disabled";"api-lane-tools-disabled"] in
  check bool "readiness proves at least one actually compatible candidate"
    (not unavailable) (Result.is_ok (Runtime.verifier_exact_lane_readiness ()));
  (match Runtime.verifier_exact_lane_slot_ids () with
   | Error detail -> fail detail
   | Ok slots ->
     if mode = "missing-first" then
       check (list string) "invalid candidates retain their exact declared position"
         ["official.missing";"official.verifier"] slots);
  let previous_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slot_ids_fn in
  Atomic.set Workspace_hooks.get_verifier_exact_lane_slot_ids_fn Runtime.verifier_exact_lane_slot_ids;
  Eio.Switch.on_release sw (fun () ->
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slot_ids_fn previous_slots);
  let calls = ref [] in
  let review () = AR.run ~sw:(Some sw)
    ~log_info:(fun _ -> ()) ~log_warn:(fun _ -> ())
    ~render_prompt:(fun () -> Ok "Verify the supplied image and read proof.txt before reporting.")
    ~goal_blocks:[Agent_core.Types.Image
      { media_type="image/png"; data=png; source_type=Base64 }]
    ~lookup ~base_path:root
    ~on_tool_result:(fun ~input:_ result -> calls := result :: !calls) () in
  let result = review () in
  let launches rows = List.filter (fun row -> member "kind" row = `String "launch") rows in
  let check_failed_launch path =
    let rows = launches (records path) in
    check int "declared candidate actually dispatched and failed" 1 (List.length rows);
    List.iter (fun launch ->
      let cwd = member "cwd" launch |> Yojson.Safe.Util.to_string in
      check bool "failed candidate session root is removed" false (Sys.file_exists cwd)) rows in
  let check_http_refusals expected =
    let _, requests = Option.get http in
    let requests = List.rev !requests in
    (* Provider transport retry may repeat a request; each candidate's first
       appearance still proves the declared order across actual HTTP calls. *)
    let order = List.fold_left (fun seen (path, _) ->
      let candidate = match String.split_on_char '/' path with
        | "" :: candidate :: _ -> candidate | _ -> fail "unexpected fixture path" in
      if List.mem candidate seen then seen else seen @ [candidate]) [] requests in
    check (list string) "real pre-effect HTTP attempts follow declared order" expected order;
    List.iter (fun (_, body) ->
      let tools = member "tools" body |> Yojson.Safe.Util.to_list in
      check bool "failed API candidate was offered the verdict tool" true
        (List.exists (fun tool -> member "function" tool |> member "name"
           = `String "report_review_verdict") tools)) requests
  in
  if unavailable then (
    check bool "unavailable verifier is reported before dispatch" true
      (result.gate = AR.Evaluator_unavailable && result.verdict = None);
    check bool "unavailable verifier never spawns an official client" false (Sys.file_exists capture);
    check bool "capable ordinary default cannot make the exact lane available" false
      (Sys.file_exists outside_capture))
  else if mode = "api-lane-uncertain-cli" then (
    check bool "unobserved official-client exit remains effect fenced" true
      (result.gate = AR.Evaluator_unavailable && result.verdict = None);
    check_failed_launch first_capture;
    check bool "effect fence prevents next declared client and default" false
      (Sys.file_exists capture || Sys.file_exists outside_capture))
  else if mode = "api-lane-exhausted" then (
    check bool "exhausted declared candidates produce no verdict" true
      (result.gate = AR.Evaluator_unavailable && result.verdict = None);
    check_http_refusals ["first"; "second"];
    check bool "HTTP failures do not launch placeholder CLI fixtures" false
      (Sys.file_exists first_capture || Sys.file_exists capture);
    check bool "all declared candidates failing never dispatches implicit default" false
      (Sys.file_exists outside_capture))
  else (
  (match mode, result.AR.verdict, result.gate with
   | ("valid" | "mixed" | "exact-order" | "shadow" | "missing-first" | "large-read" | "image-read" | "api-lane" | "api-lane-explicit-default"), Some (AR.Approve "read-only fixture receipt"), AR.Structured_tool -> ()
   | "missing", None, AR.Invalid_verdict -> ()
   | "duplicate", None, AR.Evaluator_unavailable -> ()
   | _ -> failf "unexpected verdict outcome: gate=%s detail=%s"
      (AR.gate_to_string result.gate) (Option.value ~default:"none" result.fallback_reason));
  let explicit_default = mode = "api-lane-explicit-default" in
  let rows = records (if explicit_default then outside_capture else capture) in
  check string "compatible official client owns the verdict"
    (if explicit_default then outside_id else "official.verifier")
    result.evaluator_runtime;
  check bool "default dispatch requires explicit declaration" explicit_default
    (Sys.file_exists outside_capture);
  if mode = "exact-order" then check_failed_launch first_capture;
  if api_lane then (
    check_http_refusals (if explicit_default then ["first"; "second"] else ["first"]);
    check bool "API lane never launches a failed CLI placeholder" false
      (Sys.file_exists first_capture));
  if explicit_default then
    check bool "second refusal came from HTTP, not a failed CLI" false (Sys.file_exists capture);
  let launch = List.hd (launches rows) in
  let argv = member "argv" launch |> Yojson.Safe.Util.to_list
    |> List.map Yojson.Safe.Util.to_string in
  let rec argument key = function
    | flag :: value :: _ when flag = key -> value
    | _ :: rest -> argument key rest
    | [] -> fail ("missing CLI argument " ^ key) in
  let managed = Prompt_registry.render_prompt_template Prompt_names.verification_system [] |> Result.get_ok in
  check string "managed verifier contract reaches official client"
    managed (argument "--system-prompt" argv);
  check string "built-in tools cannot bypass authority lookups" "" (argument "--tools" argv);
  check bool "disk instructions and hooks remain disabled" true (List.mem "--setting-sources=" argv);
  let input = List.find (fun row -> member "type" row = `String "user") rows in
  let images = member "message" input |> member "content" |> Yojson.Safe.Util.to_list
    |> List.filter (fun item -> member "type" item = `String "image") in
  check int "one actual initial image" 1 (List.length images);
  check string "exact initial image bytes" png
    (List.hd images |> member "source" |> member "data" |> Yojson.Safe.Util.to_string);
  check bool "real scoped filesystem result reaches client" true
    (List.exists (fun row ->
      member "type" row = `String "control_response"
      && String_util.contains_substring (Yojson.Safe.to_string row) "verified-file-receipt") rows);
  if mode = "large-read" then (
    check bool "large authority read remains inspectable on the actual client wire" true
      (List.exists (fun row -> String_util.contains_substring
         (Yojson.Safe.to_string row) "last-readable-proof-byte") rows);
    check bool "large read does not become an inaccessible session-local marker" false
      (List.exists (fun row -> String_util.contains_substring
         (Yojson.Safe.to_string row) Tool_output.marker_prefix) rows));
  if mode = "image-read" then (
    let response = List.find (fun row ->
      member "type" row = `String "control_response"
      && member "request_id" (member "response" row) = `String "mcp-4") rows in
    check bool "actual image lookup carries the exact PNG on the client wire" true
      (String_util.contains_substring (Yojson.Safe.to_string response) png);
    check string "image lookup does not change the producer file" (Base64.decode_exn png)
      (In_channel.with_open_bin (Filename.concat proof_root "proof.png") In_channel.input_all));
  List.iter (fun launch ->
    let cwd = member "cwd" launch |> Yojson.Safe.Util.to_string in
    check bool "review never uses producer workspace as cwd" false (cwd = root);
    check bool "settled review session root is removed" false (Sys.file_exists cwd))
    (launches rows);
  check string "producer runtime configuration is unchanged" runtime_text
    (In_channel.with_open_bin config_path In_channel.input_all);
  check int "each tool result observed" (if mode = "missing" then 1 else if mode = "duplicate" || mode = "image-read" then 3 else 2)
    (List.length !calls);
  if mode = "valid" then (
    let second = review () in
    check bool "second independent review succeeds" true
      (second.verdict = Some (AR.Approve "read-only fixture receipt"));
    let rows = records capture in
    let launches = launches rows in
    check int "both reviews started fresh sessions" 2 (List.length launches);
    List.iter (fun launch ->
      let cwd = member "cwd" launch |> Yojson.Safe.Util.to_string in
      check bool "every completed review session root is removed" false (Sys.file_exists cwd))
      launches))


let test_unsafe_slots_refused_before_spawn () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let saved = Runtime.For_testing.snapshot () in
  let root = Filename.temp_file "verifier-refusal-" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  Eio.Switch.on_release sw (fun () -> Runtime.For_testing.restore saved; Fs_compat.remove_tree root);
  let command, capture = fixture_script root ~mode:"must-not-run" in
  let config_path = Filename.concat root "runtime.toml" in
  let replace needle replacement text =
    let length = String.length needle in
    let rec scan offset =
      if offset + length > String.length text then text
      else if String.sub text offset length = needle then
        String.sub text 0 offset ^ replacement
        ^ String.sub text (offset + length) (String.length text - offset - length)
      else scan (offset + 1)
    in scan 0 in
  let credential_path = Filename.concat root "fixture-oauth.json" in
  write credential_path "{}";
  let antigravity_config =
    replace "command =" "timeout-s = 30.0\ncommand ="
      (replace "claude-code" "antigravity-cli" (runtime_config command))
    ^ Printf.sprintf "\n[providers.official.credentials]\ntype = \"file\"\npath = %S\n" credential_path
  in
  let cases =
    [ "Codex", replace "claude-code" "codex-app-server" (runtime_config command), "official.verifier"
    ; "Antigravity", antigravity_config, "official.verifier"
    ; "disabled tools", replace "tools-support = true" "tools-support = false" (runtime_config command), "official.verifier"
    ; "unsupported media", replace "supports-image-input = true" "supports-image-input = false" (runtime_config command), "official.verifier"
    ; "missing runtime", runtime_config command, "missing.runtime"
    ; "lane", runtime_config command ^ "\n[runtime.lanes.verifier_lane]\ncandidates = [\"official.verifier\"]\n", "verifier_lane"
    ] in
  List.iter (fun (label,text,slot) ->
    write config_path text;
    (match Runtime.init_default ~config_path with Ok () -> () | Error e -> fail e);
    check bool (label ^ " CLI admission") (label <> "unsupported media")
      (Result.is_error (Runtime.verifier_cli_slot_admission ~runtime_id:slot));
    let result = AR.run ~evaluator_runtime:slot ~sw:(Some sw)
      ~log_info:(fun _ -> ()) ~log_warn:(fun _ -> ())
      ~render_prompt:(fun () -> Ok "A prose approval must never authorize this review.")
      ~goal_blocks:[Agent_core.Types.Image
        { media_type="image/png"; data=png; source_type=Base64 }]
      ~lookup:AR.No_lookup_surface ~base_path:root () in
    check bool (label ^ " explicit override cannot bypass admission") true
      (result.verdict = None && result.gate = AR.Evaluator_unavailable);
    check bool (label ^ " no client invocation") false (Sys.file_exists capture)) cases

let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts");
  Workspace_metric_hooks.install ();
  Alcotest.run "official-client completion verifier"
    ["lane authority", [test_case "declared and effective views" `Quick test_lane_authority_views];
     "actual client dispatch", List.map (fun mode -> test_case mode `Quick (fun () -> test_review mode))
      ["valid"; "missing"; "duplicate"; "unknown-slot"; "tools-disabled";
       "unconfined"; "wrong-kind"; "disabled-binding"; "mixed"; "exact-order"; "shadow"; "missing-first"; "large-read"; "image-read";
       "api-lane"; "api-tools-disabled"; "api-lane-exhausted";
       "api-lane-explicit-default"; "api-lane-tools-disabled"; "api-lane-uncertain-cli"];
     "admission", [test_case "unsafe direct clients and lanes never spawn" `Quick
       test_unsafe_slots_refused_before_spawn]]
