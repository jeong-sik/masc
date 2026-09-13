(* Actual managed verifier -> named-runtime -> Claude Code process boundary.
   The fixture supplies model responses, never the reviewer callback. This proves
   typed verdict delivery, initial images and actual Read image tool results, not model judgement quality. *)
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
capture = %S
mode = %S
def record(value):
    with open(capture, 'a') as out:
        out.write(json.dumps(value)+'\n')
def emit(value):
    print(json.dumps(value), flush=True)
def receive():
    value = json.loads(sys.stdin.readline())
    record(value)
    return value
if 'auth' in sys.argv:
    emit({'loggedIn':True,'authMethod':'claude.ai','subscriptionType':'team','apiProvider':'firstParty'})
    sys.exit(0)
record({'argv':sys.argv,'cwd':os.getcwd()})
assert sys.argv[sys.argv.index('--tools')+1] == ''
assert '--setting-sources=' in sys.argv
session = next(x.split('=',1)[1] for x in sys.argv if x.startswith('--session-id='))
request = receive()
emit({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{}}})
receive()
def mcp(ident, method, params):
    emit({'type':'control_request','request_id':str(ident),'request':{'subtype':'mcp_message','server_name':'masc','message':{'jsonrpc':'2.0','id':ident,'method':method,'params':params}}})
    return receive()
mcp(1,'initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'fixture','version':'1'}})
emit({'type':'control_request','request_id':'initialized','request':{'subtype':'mcp_message','server_name':'masc','message':{'jsonrpc':'2.0','method':'notifications/initialized','params':{}}}})
receive()
mcp(2,'tools/list',{})
mcp(3,'tools/call',{'name':'tool_read_file','arguments':{'file_path':'proof.txt'}})
mcp(4,'tools/call',{'name':'tool_read_file','arguments':{'file_path':'proof.png'}})
if mode != 'missing':
    mcp(5,'tools/call',{'name':'report_review_verdict','arguments':{'verdict':'APPROVE','reason':'read-only fixture receipt'}})
if mode == 'duplicate':
    mcp(6,'tools/call',{'name':'report_review_verdict','arguments':{'verdict':'REJECT','reason':'duplicate'}})
emit({'type':'assistant','session_id':session,'uuid':'assistant','message':{'role':'assistant','model':'verifier-fixture','content':[{'type':'text','text':'APPROVE (prose is not a verdict)'}]}})
emit({'type':'result','subtype':'success','is_error':False,'session_id':session,'uuid':'result','result':'APPROVE (prose is not a verdict)','api_error_status':None})
for line in sys.stdin:
    pass
|} capture mode);
  Unix.chmod path 0o700;
  path, capture

let runtime_config command = Printf.sprintf {|
[providers.official]
protocol = "claude-code"
command = %S
is-non-interactive = true
[models.verifier]
api-name = "verifier-fixture"
max-context = 400000
tools-support = true
[models.verifier.capabilities]
supports-image-input = true
[official.verifier]
[runtime]
default = "official.verifier"
[runtime.exact_output_lanes.verifier_exact]
slots = []
cli_slots = ["official.verifier"]
|} command

let records path = In_channel.with_open_bin path In_channel.input_lines
  |> List.map Yojson.Safe.from_string
let member = Yojson.Safe.Util.member

let test_review ?(shadow_lane=false) mode =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let saved = Runtime.For_testing.snapshot () in
  let root = Filename.temp_file "verifier-official-" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore saved;
    Fs_compat.remove_tree root);
  let config = Workspace.default_config root in
  let proof_root = Filename.concat root Playground_paths.all_playgrounds_prefix in
  Fs_compat.mkdir_p proof_root;
  write (Filename.concat proof_root "proof.txt") "verified-file-receipt";
  write (Filename.concat proof_root "proof.png") (Base64.decode_exn png);
  let lookup_tools = match VAT.create_goal_proof ~config with
    | Ok tools -> tools | Error detail -> fail detail in
  let lookup = AR.Lookup_tools
    { schemas = VAT.schemas lookup_tools; dispatch = VAT.dispatch lookup_tools
    ; root_layout = ["proof.txt"] } in
  let command, capture = fixture_script root ~mode in
  let config_path = Filename.concat root "runtime.toml" in
  let forbidden_capture = Filename.concat root "forbidden-client-called" in
  let forbidden_command = Filename.concat root "forbidden-client" in
  write forbidden_command (Printf.sprintf "#!/bin/sh\nprintf called > %s\nexit 99\n"
    (Filename.quote forbidden_capture));
  Unix.chmod forbidden_command 0o700;
  let runtime_text = runtime_config command ^
    (if shadow_lane then Printf.sprintf {|
[providers.forbidden]
protocol = "claude-code"
command = %S
is-non-interactive = true
[forbidden.verifier]
[runtime.lanes."official.verifier"]
candidates = ["forbidden.verifier", "official.verifier"]
|} forbidden_command else "") in
  write config_path runtime_text;
  (match Runtime.init_default ~config_path with Ok () -> () | Error detail -> fail detail);
  if shadow_lane then (
    check bool "direct verifier binding admitted despite Keeper shadow lane" true
      (Result.is_ok (Runtime.verifier_cli_slot_admission ~runtime_id:"official.verifier"));
    match Runtime.resolve_assignment "official.verifier" with
    | `Lane lane -> check (list string) "ordinary Keeper routing keeps its lane order"
        ["forbidden.verifier"; "official.verifier"] (Runtime_lane.ordered_candidates lane)
    | _ -> fail "normal Keeper shadow lane disappeared");
  let declarations = match Runtime_toml.parse_string runtime_text with
    | Ok config -> config.Runtime_schema.exact_output_lane_decls
    | Error _ -> fail "fixture runtime declarations failed to parse" in
  let io : Agent_core.Exact_output.resolver_io = {getenv=(fun _ -> Ok None)} in
  let snapshot = match Agent_core.Exact_output.load_resolver_snapshot ~io () with
    | Ok snapshot -> snapshot | Error _ -> fail "embedded resolver snapshot unavailable" in
  (match Runtime.publish_exact_output_registry ~lanes:declarations snapshot with
   | Ok _ -> () | Error detail -> fail detail);
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
  (match mode, result.AR.verdict, result.gate with
   | "valid", Some (AR.Approve "read-only fixture receipt"), AR.Structured_tool -> ()
   | "missing", None, AR.Invalid_verdict -> ()
   | "duplicate", None, AR.Evaluator_unavailable -> ()
   | _ -> failf "unexpected verdict outcome: gate=%s detail=%s"
      (AR.gate_to_string result.gate) (Option.value ~default:"none" result.fallback_reason));
  let rows = records capture in
  let invocation = List.find (fun row -> member "argv" row <> `Null) rows in
  let argv = member "argv" invocation |> Yojson.Safe.Util.to_list in
  let managed = Prompt_registry.render_prompt_template Prompt_names.verification_system [] |> Result.get_ok in
  check bool "managed verifier contract reaches client" true (List.mem (`String managed) argv);
  let client_root = member "cwd" invocation |> Yojson.Safe.Util.to_string in
  check bool "client does not run in workspace" false (String.equal root client_root);
  check bool "private session root reclaimed after terminal result" false (Sys.file_exists client_root);
  let serialized = Yojson.Safe.to_string (`List rows) in
  check bool "real contained text reaches tool response" true
    (String_util.contains_substring serialized "verified-file-receipt");
  let images content = Yojson.Safe.Util.to_list content
    |> List.filter (fun block -> member "type" block = `String "image") in
  let user = List.find (fun row -> member "type" row = `String "user") rows in
  let initial_images = user |> member "message" |> member "content" |> images in
  check int "one initial image reaches client" 1 (List.length initial_images);
  let initial_source = List.hd initial_images |> member "source" in
  check string "initial image encoding" "base64"
    (initial_source |> member "type" |> Yojson.Safe.Util.to_string);
  check string "initial image media type" "image/png"
    (initial_source |> member "media_type" |> Yojson.Safe.Util.to_string);
  check string "exact initial image bytes" png
    (initial_source |> member "data" |> Yojson.Safe.Util.to_string);
  let image_reply = List.find (fun row ->
    member "type" row = `String "control_response"
    && (row |> member "response" |> member "request_id") = `String "4") rows in
  let reply = image_reply |> member "response" in
  check string "image control response succeeds" "success"
    (reply |> member "subtype" |> Yojson.Safe.Util.to_string);
  let mcp = reply |> member "response" |> member "mcp_response" in
  check int "image lookup response identity" 4 (mcp |> member "id" |> Yojson.Safe.Util.to_int);
  let result = mcp |> member "result" in
  check bool "image lookup did not fail" false (member "isError" result = `Bool true);
  let lookup_images = result |> member "content" |> images in
  check int "Read has its own visual block" 1 (List.length lookup_images);
  let lookup_image = List.hd lookup_images in
  check string "Read image media type" "image/png"
    (lookup_image |> member "mimeType" |> Yojson.Safe.Util.to_string);
  check string "exact Read image bytes" png
    (lookup_image |> member "data" |> Yojson.Safe.Util.to_string);
  check bool "workspace Skills not exposed" false
    (String_util.contains_substring serialized "masc_skill");
  check int "each tool result observed" (if mode = "missing" then 2 else if mode = "duplicate" then 4 else 3)
    (List.length !calls);
  check bool "verifier never invokes the shadow lane's first candidate" false
    (Sys.file_exists forbidden_capture);
  if mode = "valid" then (
    let second = review () in
    check bool "second independent review succeeds" true
      (second.verdict = Some (AR.Approve "read-only fixture receipt"));
    let invocations = records capture |> List.filter (fun row -> member "argv" row <> `Null) in
    check int "two fresh client launches" 2 (List.length invocations);
    List.iter (fun row ->
      check bool "every client directory reclaimed" false
        (Sys.file_exists (member "cwd" row |> Yojson.Safe.Util.to_string))) invocations)

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
    ["actual client dispatch", List.map (fun mode -> test_case mode `Quick (fun () -> test_review mode))
      ["valid"; "missing"; "duplicate"];
     "shadow lane", [test_case "verifier uses direct binding while Keeper routing retains its lane" `Quick
       (fun () -> test_review ~shadow_lane:true "valid")];
     "admission", [test_case "unsafe direct clients and lanes never spawn" `Quick
       test_unsafe_slots_refused_before_spawn]]
